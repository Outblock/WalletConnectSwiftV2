import Foundation
import Combine

actor AuthResponder {
    enum Errors: Error {
        case recordForIdNotFound
        case malformedAuthRequestParams
    }
    private let networkingInteractor: NetworkInteracting
    private let kms: KeyManagementService
    private let rpcHistory: RPCHistory
    private let verifyContextStore: CodableStore<VerifyContext>
    private let logger: ConsoleLogging
    private let walletErrorResponder: WalletErrorResponder
    private let pairingRegisterer: PairingRegisterer
    private let metadata: AppMetadata
    private let sessionStore: WCSessionStorage
    private let sessionNamespaceBuilder: SessionNamespaceBuilder
    private let sessionSettledPublisherSubject = PassthroughSubject<Session, Never>()
    var sessionSettledPublisher: AnyPublisher<Session, Never> {
        return sessionSettledPublisherSubject.eraseToAnyPublisher()
    }

    init(
        networkingInteractor: NetworkInteracting,
        logger: ConsoleLogging,
        kms: KeyManagementService,
        rpcHistory: RPCHistory,
        verifyContextStore: CodableStore<VerifyContext>,
        walletErrorResponder: WalletErrorResponder,
        pairingRegisterer: PairingRegisterer,
        metadata: AppMetadata,
        sessionStore: WCSessionStorage,
        sessionNamespaceBuilder: SessionNamespaceBuilder
    ) {
        self.networkingInteractor = networkingInteractor
        self.logger = logger
        self.kms = kms
        self.rpcHistory = rpcHistory
        self.verifyContextStore = verifyContextStore
        self.walletErrorResponder = walletErrorResponder
        self.pairingRegisterer = pairingRegisterer
        self.metadata = metadata
        self.sessionStore = sessionStore
        self.sessionNamespaceBuilder = sessionNamespaceBuilder
    }

    func respond(requestId: RPCID, auths: [Cacao]) async throws {
        let (sessionAuthenticateRequestParams, pairingTopic) = try getsessionAuthenticateRequestParams(requestId: requestId)
        let (responseTopic, responseKeys) = try generateAgreementKeys(requestParams: sessionAuthenticateRequestParams)


        try kms.setAgreementSecret(responseKeys, topic: responseTopic)

        let peerParticipant = sessionAuthenticateRequestParams.requester

        let sessionSelfPubKey = try kms.createX25519KeyPair()
        let sessionSelfPubKeyHex = sessionSelfPubKey.hexRepresentation
        let sessionKeys = try kms.performKeyAgreement(selfPublicKey: sessionSelfPubKey, peerPublicKey: peerParticipant.publicKey)

        let sessionTopic = sessionKeys.derivedTopic()
        try kms.setAgreementSecret(sessionKeys, topic: sessionTopic)

        let selfParticipant = Participant(publicKey: sessionSelfPubKeyHex, metadata: metadata)
        let responseParams = SessionAuthenticateResponseParams(responder: selfParticipant, cacaos: auths)

        let response = RPCResponse(id: requestId, result: responseParams)
        try await networkingInteractor.respond(topic: responseTopic, response: response, protocolMethod: SessionAuthenticatedProtocolMethod(), envelopeType: .type1(pubKey: responseKeys.publicKey.rawRepresentation))


        let session = try createSession(
            response: responseParams,
            pairingTopic: pairingTopic,
            request: sessionAuthenticateRequestParams,
            sessionTopic: sessionTopic
        )

        pairingRegisterer.activate(
            pairingTopic: pairingTopic,
            peerMetadata: sessionAuthenticateRequestParams.requester.metadata
        )

        verifyContextStore.delete(forKey: requestId.string)
        sessionSettledPublisherSubject.send(session)
    }

    func respondError(requestId: RPCID) async throws {
        try await walletErrorResponder.respondError(AuthError.userRejeted, requestId: requestId)
        verifyContextStore.delete(forKey: requestId.string)
    }

    private func getsessionAuthenticateRequestParams(requestId: RPCID) throws -> (request: SessionAuthenticateRequestParams, topic: String) {
        guard let record = rpcHistory.get(recordId: requestId)
        else { throw Errors.recordForIdNotFound }

        let request = record.request
        guard let authRequestParams = try request.params?.get(SessionAuthenticateRequestParams.self)
        else { throw Errors.malformedAuthRequestParams }

        return (request: authRequestParams, topic: record.topic)
    }

    private func generateAgreementKeys(requestParams: SessionAuthenticateRequestParams) throws -> (topic: String, keys: AgreementKeys) {
        let peerPubKey = try AgreementPublicKey(hex: requestParams.requester.publicKey)
        let topic = peerPubKey.rawRepresentation.sha256().toHexString()
        let selfPubKey = try kms.createX25519KeyPair()
        let keys = try kms.performKeyAgreement(selfPublicKey: selfPubKey, peerPublicKey: peerPubKey.hexRepresentation)
        return (topic, keys)
    }


    private func createSession(
        response: SessionAuthenticateResponseParams,
        pairingTopic: String,
        request: SessionAuthenticateRequestParams,
        sessionTopic: String
    ) throws -> Session {


        let selfParticipant = response.responder
        let peerParticipant = request.requester

        let expiry = Date()
            .addingTimeInterval(TimeInterval(WCSession.defaultTimeToLive))
            .timeIntervalSince1970

        let relay = RelayProtocolOptions(protocol: "irn", data: nil)

        let sessionNamespaces = try sessionNamespaceBuilder.buildSessionNamespaces(cacaos: response.cacaos)

        let settleParams = SessionType.SettleParams(
            relay: relay,
            controller: selfParticipant,
            namespaces: sessionNamespaces,
            sessionProperties: nil,
            expiry: Int64(expiry)
        )

        let session = WCSession(
            topic: sessionTopic,
            pairingTopic: pairingTopic,
            timestamp: Date(),
            selfParticipant: selfParticipant,
            peerParticipant: peerParticipant,
            settleParams: settleParams,
            requiredNamespaces: [:],
            acknowledged: true
        )

        sessionStore.setSession(session)
        Task {
            logger.debug("subscribing to session topic: \(sessionTopic)")
            try await networkingInteractor.subscribe(topic: sessionTopic)
        }

        return session.publicRepresentation()
    }
}
