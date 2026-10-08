//
//  Copyright (c) 2020-2021 MobileCoin. All rights reserved.
//

// swiftlint:disable multiline_function_chains
// swiftlint:disable function_default_parameter_at_end type_body_length file_length

import Foundation

public final class MobileCoinClient {
    /// - Returns: `InvalidInputError` when `accountKey` isn't configured to use Fog.
    public static func make(accountKey: AccountKey, config: Config)
        -> Result<MobileCoinClient, InvalidInputError>
    {
        guard let accountKey = AccountKeyWithFog(accountKey: accountKey) else {
            let errorMessage = "Accounts without fog URLs are not currently supported."
            logger.error(errorMessage, logFunction: false)
            return .failure(InvalidInputError(errorMessage))
        }

        return .success(MobileCoinClient(accountKey: accountKey, config: config))
    }

    private let accountLock: ReadWriteDispatchLock<Account>
    private let serialQueue: DispatchQueue
    private let callbackQueue: DispatchQueue

    private let txOutSelectionStrategy: TxOutSelectionStrategy
    private let mixinSelectionStrategy: MixinSelectionStrategy
    private let fogQueryScalingStrategy: FogQueryScalingStrategy

    private let serviceProvider: ServiceProvider
    private let fogResolverManager: FogResolverManager
    private let metaFetcher: BlockchainMetaFetcher

    private let defaultRng = MobileCoinDefaultRng()
    private let fogSyncChecker: FogSyncCheckable

    let mistyswap: Mistyswap

    static let latestBlockVersion = BlockVersion.legacy

    init(accountKey: AccountKeyWithFog, config: Config) {
        logger.info("""
            Initializing \(Self.self):
            \(Self.configDescription(accountKey: accountKey, config: config))
            """, logFunction: false)

        self.serialQueue = DispatchQueue(label: "com.mobilecoin.\(Self.self)")
        self.callbackQueue = config.callbackQueue ?? DispatchQueue.main
        self.fogSyncChecker = config.fogSyncCheckable
        self.accountLock = .init(Account(accountKey: accountKey, syncChecker: fogSyncChecker))
        self.txOutSelectionStrategy = config.txOutSelectionStrategy
        self.mixinSelectionStrategy = config.mixinSelectionStrategy
        self.fogQueryScalingStrategy = config.fogQueryScalingStrategy

        let grpcFactory = GrpcProtocolConnectionFactory()
        let httpFactory = HttpProtocolConnectionFactory(
            httpRequester: config.networkConfig.httpRequester)

        self.serviceProvider = DefaultServiceProvider(
            networkConfig: config.networkConfig,
            targetQueue: serialQueue,
            grpcConnectionFactory: grpcFactory,
            httpConnectionFactory: httpFactory)

        self.fogResolverManager = FogResolverManager(
            fogReportAttestation: config.networkConfig.fogReportAttestation,
            serviceProvider: serviceProvider,
            targetQueue: serialQueue)

        self.metaFetcher = BlockchainMetaFetcher(
            blockchainService: serviceProvider.blockchainService,
            metaCacheTTL: config.metaCacheTTL,
            targetQueue: serialQueue)

        self.mistyswap = Mistyswap(
            mistyswap: serviceProvider.mistyswapService
        )
    }

    public var balances: Balances {
        accountLock.readSync { $0.cachedBalances }
    }

    public var accountTokenIds: Set<TokenId> {
        accountLock.readSync { $0.cachedTxOutTokenIds }
    }

    public func recoverTransactions<Contact: PublicAddressProvider>(
        contacts: Set<Contact>
    ) -> [HistoricalTransaction] where Contact: Hashable {
        recoverTransactions(allAccountActivity().txOuts, contacts: contacts)
    }

    public func recoverContactTransactions<Contact: PublicAddressProvider>(
        contact: Contact
    ) -> [HistoricalTransaction] where Contact: Hashable {
        recoverTransactions(contacts: Set([contact]))
    }

    public func recoverTransactions<Contact: PublicAddressProvider>(
        _ transactions: Set<OwnedTxOut>,
        contacts: Set<Contact>
    ) -> [HistoricalTransaction] where Contact: Hashable {
        Self.recoverTransactions(transactions, contacts: contacts)
    }

    public func recoverContactTransactions<Contact: PublicAddressProvider>(
        _ transactions: Set<OwnedTxOut>,
        contact: Contact
    ) -> [HistoricalTransaction] where Contact: Hashable {
        recoverTransactions(transactions, contacts: Set([contact]))
    }

    public func allAccountActivity() -> AccountActivity {
        accountLock.readSync { $0.allCachedAccountActivity }
    }

    public func accountActivity(for tokenId: TokenId) -> AccountActivity {
        accountLock.readSync { $0.cachedAccountActivity(for: tokenId) }
    }

    public func balance(for tokenId: TokenId = .MOB) -> Balance {
        accountLock.readSync { $0.cachedBalance(for: tokenId) }
    }

    public func setTransportProtocol(_ transportProtocol: TransportProtocol) {
        serviceProvider.setTransportProtocolOption(transportProtocol.option)
    }

    public func setConsensusBasicAuthorization(username: String, password: String) {
        let credentials = BasicCredentials(username: username, password: password)
        serviceProvider.setConsensusAuthorization(credentials: credentials)
    }

    public func setFogBasicAuthorization(username: String, password: String) {
        let credentials = BasicCredentials(username: username, password: password)
        serviceProvider.setFogUserAuthorization(credentials: credentials)
    }

    public func updateBalances(
        completion: @escaping (Result<Balances, BalanceUpdateError>) -> Void
    ) {
        Account.BalanceUpdater(
            account: accountLock,
            fogViewService: serviceProvider.fogViewService,
            fogKeyImageService: serviceProvider.fogKeyImageService,
            fogBlockService: serviceProvider.fogBlockService,
            fogQueryScalingStrategy: fogQueryScalingStrategy,
            targetQueue: serialQueue
        ).updateBalances { result in
            self.callbackQueue.async {
                completion(result)
            }
        }
    }

    public func amountTransferable(
        tokenId: TokenId,
        feeLevel: FeeLevel = .minimum,
        completion: @escaping (Result<UInt64, BalanceTransferEstimationFetcherError>) -> Void
    ) {
        Account.TransactionEstimator(
            account: accountLock,
            metaFetcher: metaFetcher,
            txOutSelectionStrategy: txOutSelectionStrategy,
            targetQueue: serialQueue
        ).amountTransferable(tokenId: tokenId, feeLevel: feeLevel, completion: completion)
    }

    public func estimateTotalFee(
        toSendAmount amount: Amount,
        feeLevel: FeeLevel = .minimum,
        completion: @escaping (Result<UInt64, TransactionEstimationFetcherError>) -> Void
    ) {
        Account.TransactionEstimator(
            account: accountLock,
            metaFetcher: metaFetcher,
            txOutSelectionStrategy: txOutSelectionStrategy,
            targetQueue: serialQueue
        ).estimateTotalFee(toSendAmount: amount, feeLevel: feeLevel, completion: completion)
    }

    public func requiresDefragmentation(
        toSendAmount amount: Amount,
        feeLevel: FeeLevel = .minimum,
        completion: @escaping (Result<Bool, TransactionEstimationFetcherError>) -> Void
    ) {
        Account.TransactionEstimator(
            account: accountLock,
            metaFetcher: metaFetcher,
            txOutSelectionStrategy: txOutSelectionStrategy,
            targetQueue: serialQueue
        ).requiresDefragmentation(toSendAmount: amount, feeLevel: feeLevel, completion: completion)
    }

    public func createProofOfReserveSignedContingentInput(
        txOutPubKeyBytes: Data,
        completion: @escaping (
            Result<SignedContingentInput, SignedContingentInputCreationError>
        ) -> Void
    ) {
        guard let rngSeed = defaultRng.generateRngSeed() else {
            completion(.failure(
                SignedContingentInputCreationError.invalidInput("Couldn't create 32byte RNG seed")))
            return
        }

        Account.SCIOperations(
            account: accountLock,
            fogMerkleProofService: serviceProvider.fogMerkleProofService,
            fogResolverManager: fogResolverManager,
            metaFetcher: metaFetcher,
            txOutSelectionStrategy: txOutSelectionStrategy,
            mixinSelectionStrategy: mixinSelectionStrategy,
            rngSeed: rngSeed,
            targetQueue: serialQueue
        ).createProofOfReserveSignedContingentInput(
            txOutPubKeyBytes: txOutPubKeyBytes,
            completion: completion
        )
    }

    public func createSignedContingentInput(
        recipient: PublicAddress,
        amountToSend: Amount,
        amountToReceive: Amount,
        completion: @escaping (
            Result<SignedContingentInput, SignedContingentInputCreationError>
        ) -> Void
    ) {
        guard let rngSeed = defaultRng.generateRngSeed() else {
            completion(.failure(
                SignedContingentInputCreationError.invalidInput("Couldn't create 32byte RNG seed")))
            return
        }
        Account.SCIOperations(
            account: accountLock,
            fogMerkleProofService: serviceProvider.fogMerkleProofService,
            fogResolverManager: fogResolverManager,
            metaFetcher: metaFetcher,
            txOutSelectionStrategy: txOutSelectionStrategy,
            mixinSelectionStrategy: mixinSelectionStrategy,
            rngSeed: rngSeed,
            targetQueue: serialQueue
        ).createSignedContingentInput(
            to: recipient,
            memoType: .unused,
            amountToSend: amountToSend,
            amountToReceive: amountToReceive
        ) { result in
            self.callbackQueue.async {
                completion(result)
            }
        }
    }

    public func prepareCancelSignedContingentInputTransaction(
        signedContingentInput: SignedContingentInput,
        feeLevel: FeeLevel,
        completion: @escaping (
            Result<PendingSinglePayloadTransaction, SignedContingentInputCancelationError>
        ) -> Void
    ) {
        guard let rngSeed = defaultRng.generateRngSeed() else {
            completion(.failure(SignedContingentInputCancelationError.unknownError(
                "Couldn't create 32byte RNG seed")))
            return
        }
        Account.SCIOperations(
            account: accountLock,
            fogMerkleProofService: serviceProvider.fogMerkleProofService,
            fogResolverManager: fogResolverManager,
            metaFetcher: metaFetcher,
            txOutSelectionStrategy: txOutSelectionStrategy,
            mixinSelectionStrategy: mixinSelectionStrategy,
            rngSeed: rngSeed,
            targetQueue: serialQueue
        ).prepareCancelSignedContingentInputTransaction(
            signedContingentInput: signedContingentInput,
            feeLevel: feeLevel
        ) { result in
            self.callbackQueue.async {
                completion(result)
            }
        }
    }

    public func prepareTransaction(
        to recipient: PublicAddress,
        memoType: MemoType = .recoverable,
        amount: Amount,
        fee: UInt64,
        completion: @escaping (
            Result<PendingSinglePayloadTransaction, TransactionPreparationError>
        ) -> Void
    ) {
        prepareTransaction(
            to: recipient,
            memoType: memoType,
            amount: amount,
            fee: fee,
            rng: MobileCoinChaCha20Rng(),
            completion: completion)
    }

    public func prepareTransaction(
        to recipient: PublicAddress,
        memoType: MemoType = .recoverable,
        amount: Amount,
        fee: UInt64,
        rng: MobileCoinRng,
        completion: @escaping (
            Result<PendingSinglePayloadTransaction, TransactionPreparationError>
        ) -> Void
    ) {
        guard let rngSeed = rng.generateRngSeed() else {
            completion(.failure(
                TransactionPreparationError.invalidInput("Could not create 32 byte RNG seed")))
            return
        }
        Account.TransactionOperations(
            account: accountLock,
            fogMerkleProofService: serviceProvider.fogMerkleProofService,
            fogResolverManager: fogResolverManager,
            metaFetcher: metaFetcher,
            txOutSelectionStrategy: txOutSelectionStrategy,
            mixinSelectionStrategy: mixinSelectionStrategy,
            rngSeed: rngSeed,
            targetQueue: serialQueue
        ).prepareTransaction(
            to: recipient,
            memoType: memoType,
            amount: amount,
            fee: fee
        ) { result in
            self.callbackQueue.async {
                completion(result)
            }
        }
    }

    public func prepareTransaction(
        to recipient: PublicAddress,
        memoType: MemoType = .recoverable,
        amount: Amount,
        feeLevel: FeeLevel = .minimum,
        completion: @escaping (
            Result<PendingSinglePayloadTransaction, TransactionPreparationError>
        ) -> Void
    ) {
        prepareTransaction(
            to: recipient,
            memoType: memoType,
            amount: amount,
            feeLevel: feeLevel,
            rng: MobileCoinChaCha20Rng(),
            completion: completion)
    }

    public func prepareTransaction(
        to recipient: PublicAddress,
        memoType: MemoType = .recoverable,
        amount: Amount,
        feeLevel: FeeLevel = .minimum,
        rng: MobileCoinRng,
        completion: @escaping (
            Result<PendingSinglePayloadTransaction, TransactionPreparationError>
        ) -> Void
    ) {
        guard let rngSeed = rng.generateRngSeed() else {
            completion(.failure(
                TransactionPreparationError.invalidInput("Could not create 32-byte RNG seed")))
            return
        }
        Account.TransactionOperations(
            account: accountLock,
            fogMerkleProofService: serviceProvider.fogMerkleProofService,
            fogResolverManager: fogResolverManager,
            metaFetcher: metaFetcher,
            txOutSelectionStrategy: txOutSelectionStrategy,
            mixinSelectionStrategy: mixinSelectionStrategy,
            rngSeed: rngSeed,
            targetQueue: serialQueue
        ).prepareTransaction(
            to: recipient,
            memoType: memoType,
            amount: amount,
            feeLevel: feeLevel
        ) { result in
            self.callbackQueue.async {
                completion(result)
            }
        }
    }

    public func prepareDefragmentationStepTransactions(
        toSendAmount amount: Amount,
        recoverableMemo: Bool = false,
        feeLevel: FeeLevel = .minimum,
        completion: @escaping (Result<[Transaction], DefragTransactionPreparationError>) -> Void
    ) {
        prepareDefragmentationStepTransactions(
            toSendAmount: amount,
            recoverableMemo: recoverableMemo,
            feeLevel: feeLevel,
            rngSeed: RngSeed(),
            completion: completion)
    }

    public func prepareDefragmentationStepTransactions(
        toSendAmount amount: Amount,
        recoverableMemo: Bool = false,
        feeLevel: FeeLevel = .minimum,
        rngSeed: RngSeed,
        completion: @escaping (Result<[Transaction], DefragTransactionPreparationError>) -> Void
    ) {
        Account.TransactionOperations(
            account: accountLock,
            fogMerkleProofService: serviceProvider.fogMerkleProofService,
            fogResolverManager: fogResolverManager,
            metaFetcher: metaFetcher,
            txOutSelectionStrategy: txOutSelectionStrategy,
            mixinSelectionStrategy: mixinSelectionStrategy,
            rngSeed: rngSeed,
            targetQueue: serialQueue
        ).prepareDefragmentationStepTransactions(
            toSendAmount: amount,
            recoverableMemo: recoverableMemo,
            feeLevel: feeLevel) { result in
            self.callbackQueue.async {
                completion(result)
            }
        }
    }

    public func submitDefragStepTransactions(
        transactions: [Transaction],
        completion: @escaping (Result<[UInt64], SubmitTransactionError>) -> Void
    ) {
        transactions.mapAsync({ transaction, callback in
            self.submitTransaction(transaction: transaction, completion: callback)
        },
        serialQueue: serialQueue,
        completion: { result in
            completion(result.map { $0.compactMap { $0 } })
        })
    }

    public func prepareTransaction(
        presignedInput: SignedContingentInput,
        fee: Amount,
        completion: @escaping (Result<PendingTransaction, TransactionPreparationError>)
        -> Void
    ) {
        guard let rngSeed = defaultRng.generateRngSeed() else {
            completion(.failure(
                TransactionPreparationError.invalidInput(
                    "Could not create 32-byte RNG seed")))
            return
        }

        Account.TransactionOperations(
            account: accountLock,
            fogMerkleProofService: serviceProvider.fogMerkleProofService,
            fogResolverManager: fogResolverManager,
            metaFetcher: metaFetcher,
            txOutSelectionStrategy: txOutSelectionStrategy,
            mixinSelectionStrategy: mixinSelectionStrategy,
            rngSeed: rngSeed,
            targetQueue: serialQueue
        ).preparePresignedInputTransaction(
            presignedInput: presignedInput,
            memoType: .unused,
            fee: fee) { result in
            self.callbackQueue.async {
                completion(result)
            }
        }
    }

    public func prepareTransaction(
        presignedInput: SignedContingentInput,
        feeLevel: FeeLevel = .minimum,
        completion: @escaping (Result<PendingTransaction, TransactionPreparationError>)
        -> Void
    ) {
        guard let rngSeed = defaultRng.generateRngSeed() else {
            completion(.failure(
                TransactionPreparationError.invalidInput(
                    "Could not create 32-byte RNG seed")))
            return
        }

        Account.TransactionOperations(
            account: accountLock,
            fogMerkleProofService: serviceProvider.fogMerkleProofService,
            fogResolverManager: fogResolverManager,
            metaFetcher: metaFetcher,
            txOutSelectionStrategy: txOutSelectionStrategy,
            mixinSelectionStrategy: mixinSelectionStrategy,
            rngSeed: rngSeed,
            targetQueue: serialQueue
        ).preparePresignedInputTransaction(
            presignedInput: presignedInput,
            memoType: .unused,
            feeLevel: feeLevel) { result in
            self.callbackQueue.async {
                completion(result)
            }
        }
    }

    /// Prepare a partial-fill swap transaction (MCIP-42 taker side).
    ///
    /// The taker pays `payCounterAmount` in the SCI's COUNTER token and receives
    /// `fillBaseAmount` in the SCI's BASE token. `sciChangeBaseAmount` is the SCI's
    /// unfilled remainder (i.e. `sci.partialFillMaxBase - fillBaseAmount`); the caller
    /// computes it from the wire-level metadata DEQS already exposes.
    ///
    /// The fee is always in MOB. When BASE == MOB it is deducted from the taker's
    /// receive output; when COUNTER == MOB it is deducted from the taker's change.
    public func prepareTransaction(
        presignedInput: SignedContingentInput,
        fillBaseAmount: Amount,
        sciChangeBaseAmount: Amount,
        payCounterAmount: Amount,
        fee: Amount,
        completion: @escaping (Result<PendingTransaction, TransactionPreparationError>)
        -> Void
    ) {
        guard let rngSeed = defaultRng.generateRngSeed() else {
            completion(.failure(
                TransactionPreparationError.invalidInput(
                    "Could not create 32-byte RNG seed")))
            return
        }

        Account.TransactionOperations(
            account: accountLock,
            fogMerkleProofService: serviceProvider.fogMerkleProofService,
            fogResolverManager: fogResolverManager,
            metaFetcher: metaFetcher,
            txOutSelectionStrategy: txOutSelectionStrategy,
            mixinSelectionStrategy: mixinSelectionStrategy,
            rngSeed: rngSeed,
            targetQueue: serialQueue
        ).preparePartialFillSwapTransaction(
            presignedInput: presignedInput,
            fillBaseAmount: fillBaseAmount,
            sciChangeBaseAmount: sciChangeBaseAmount,
            payCounterAmount: payCounterAmount,
            fee: fee) { result in
            self.callbackQueue.async {
                completion(result)
            }
        }
    }

    /// Multi-SCI partial-fill swap (MCIP-42 taker side).
    ///
    /// Aggregates `presignedInputs.count` SCIs into a single atomic transaction. All SCIs
    /// MUST share `(baseTokenId, counterTokenId)`; the wrapper enforces this defensively.
    /// `fillBaseAmounts[i]` and `sciChangeBaseAmounts[i]` align 1-to-1 with `presignedInputs[i]`.
    /// `payCounterAmount` is the SUMMED counter cost across all SCIs (for input selection).
    public func prepareTransaction(
        presignedInputs: [SignedContingentInput],
        fillBaseAmounts: [Amount],
        sciChangeBaseAmounts: [Amount],
        payCounterAmount: Amount,
        fee: Amount,
        completion: @escaping (Result<PendingTransaction, TransactionPreparationError>)
        -> Void
    ) {
        guard let rngSeed = defaultRng.generateRngSeed() else {
            completion(.failure(
                TransactionPreparationError.invalidInput(
                    "Could not create 32-byte RNG seed")))
            return
        }

        Account.TransactionOperations(
            account: accountLock,
            fogMerkleProofService: serviceProvider.fogMerkleProofService,
            fogResolverManager: fogResolverManager,
            metaFetcher: metaFetcher,
            txOutSelectionStrategy: txOutSelectionStrategy,
            mixinSelectionStrategy: mixinSelectionStrategy,
            rngSeed: rngSeed,
            targetQueue: serialQueue
        ).preparePartialFillSwapTransaction(
            presignedInputs: presignedInputs,
            fillBaseAmounts: fillBaseAmounts,
            sciChangeBaseAmounts: sciChangeBaseAmounts,
            payCounterAmount: payCounterAmount,
            fee: fee) { result in
            self.callbackQueue.async {
                completion(result)
            }
        }
    }

    public func submitTransaction(
        transaction: Transaction,
        completion: @escaping (Result<UInt64, SubmitTransactionError>) -> Void
    ) {
        TransactionSubmitter(
            consensusService: serviceProvider.consensusService,
            metaFetcher: metaFetcher,
            syncChecker: accountLock.accessWithoutLocking.syncCheckerLock
        ).submitTransaction(transaction) { result in
            self.callbackQueue.async {
                completion(result)
            }
        }
    }

    public func txOutStatus(
        of transaction: Transaction,
        completion: @escaping (Result<TransactionStatus, ConnectionError>) -> Void
    ) {
        TransactionStatusTxOutChecker(
            account: accountLock,
            fogUntrustedTxOutService: serviceProvider.fogUntrustedTxOutService
        ).checkStatus(transaction) { result in
            self.callbackQueue.async {
                completion(result)
            }
        }
    }

    public func status(
        of transaction: Transaction,
        requireInBalance: Bool = true,
        completion: @escaping (Result<TransactionStatus, ConnectionError>) -> Void
    ) {
        TransactionStatusChecker(
            account: accountLock,
            fogUntrustedTxOutService: serviceProvider.fogUntrustedTxOutService,
            fogKeyImageService: serviceProvider.fogKeyImageService,
            targetQueue: serialQueue
        ).checkStatus(transaction, requireInBalance: requireInBalance) { result in
            self.callbackQueue.async {
                completion(result)
            }
        }
    }

    public func status(of receipt: Receipt) -> Result<ReceiptStatus, InvalidInputError> {
        ReceiptStatusChecker(account: accountLock).status(receipt)
    }

    public func blockVersion(
        _ completion: @escaping (Result<BlockVersion, ConnectionError>) -> Void
    ) {
        metaFetcher.blockVersion {
            completion($0)
        }
    }

}

// Compiled into the pinned SDK's MobileCoinClient.swift by prepare_wallet_sdk.py.
// Uses its existing attested transports and output decryption. Setup exports
// only the account view key and spend PUBLIC key, never subaddress private keys.
// Verified outputs enter
// the SDK's local cache for its existing fee estimation and transaction builder.
import CryptoKit
import Clibsodium
import LibMobileCoin
#if canImport(LibMobileCoinCommon)
import LibMobileCoinCommon
#endif

// OwnedTxOut and its memo/key fields are immutable value types. The pinned SDK
// predates Sendable annotations; this permits the verified read result to cross
// from its callback queue into the app's wallet actor.
extension OwnedTxOut: @unchecked Sendable {}

/// Why a single published pointer was refused, in the one place that decides
/// it. The app classifies these to tell a payment that never arrived from one
/// this account cannot read, and those need opposite responses. Spelling the
/// message twice is how that classification quietly stops matching and every
/// refusal starts failing whole accounts again.
public enum FireAccountOutputRefusal {
    /// The ledger does not have this output. An abandoned checkout looks
    /// exactly like this: a payment the site expected that was never made.
    public static let absentFromLedger = "An account payment is not available on the ledger"
    public static let outsideLedger = "Account output outside ledger"
    /// The ledger has it, but it does not belong to the account and subaddress
    /// the site named. This is an anomaly and never a normal state.
    public static let ownershipMismatch = "Account output ownership mismatch"
    public static let identityMismatch = "Account output identity mismatch"
}

/// What a pointer read found. Outputs the ledger does not have are reported
/// rather than thrown: a shop that publishes an expected payment for a checkout
/// nobody completed is in a normal state, not a broken one, and treating it as
/// a failure means re-proving every abandoned checkout on every refresh.
public struct FireAccountOutputReading: Sendable {
    public let owned: [OwnedTxOut]
    /// Public keys the ledger has no record of.
    public let absent: [Data]
}

public struct FireAccountOutputPointer {
    public let publicKey: Data
    public let subaddressIndex: UInt64
    public init(publicKey: Data, subaddressIndex: UInt64) {
        self.publicKey = publicKey
        self.subaddressIndex = subaddressIndex
    }
}

extension AccountKey {
    /// Watch-only setup. Never combine this account view key with a subaddress
    /// view private key: together those reveal the account spend private key.
    public func fireViewOnlyAccountBody() throws -> Data {
        // The pinned libmobilecoin public-from-private FFI copies the secret
        // scalar unchanged. Use libsodium's actual Ristretto base multiplication.
        guard sodium_init() >= 0 else { throw InvalidInputError("Cryptography unavailable") }
        var publicKey = Data(count: 32)
        let result = spendPrivateKey.data.withUnsafeBytes { spend in
            publicKey.withUnsafeMutableBytes { output in
                crypto_scalarmult_ristretto255_base(output.bindMemory(to: UInt8.self).baseAddress!,
                    spend.bindMemory(to: UInt8.self).baseAddress!)
            }
        }
        guard result == 0, publicKey != spendPrivateKey.data, RistrettoPublic(publicKey) != nil else {
            throw InvalidInputError("Invalid account public key")
        }
        return try JSONSerialization.data(withJSONObject: [
            "account_view_key_hex": viewPrivateKey.data.hexEncodedString(),
            "account_spend_public_key_hex": publicKey.hexEncodedString()
        ], options: [.sortedKeys])
    }

    public func fireConnectionToken(identity: String, version: UInt32) -> String {
        let message = Data("fire-pool-token-v\(version):\(identity)".utf8)
        // Match the extension's established wire contract: context is the
        // HMAC key; the account spending scalar is the message.
        let mac = HMAC<SHA256>.authenticationCode(for: spendPrivateKey.data, using: SymmetricKey(data: message))
        let text = Data(mac).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "firepool_v\(version)_" + text
    }
    public func fireReceivingAccount(subaddressIndex: UInt64) -> AccountKey {
        AccountKey(viewPrivateKey: viewPrivateKey, spendPrivateKey: spendPrivateKey,
                   fogInfo: fogInfo, subaddressIndex: subaddressIndex)
    }

    // Kept internal so offline fixtures exercise exactly the ownership check
    // used for attested outputs without making arbitrary ledger imports public.
    func fireVerifyAccountOutput(_ output: TxOut, pointer: FireAccountOutputPointer,
                                 globalIndex: UInt64, block: BlockMetadata) -> KnownTxOut? {
        guard output.publicKey.data == pointer.publicKey else { return nil }
        let key = fireReceivingAccount(subaddressIndex: pointer.subaddressIndex)
        let ledger = LedgerTxOut(PartialTxOut(output), globalIndex: globalIndex, block: block)
        guard let decrypted = ledger.decrypt(accountKey: key),
              decrypted.subaddressIndex == pointer.subaddressIndex,
              decrypted.commitment == output.commitment else { return nil }
        return decrypted
    }
}

extension MobileCoinClient {
    /// Server pointers supply only a location. Resolve the public key, fetch the
    /// actual output through the attested ledger service, then check ownership,
    /// commitment, amount and spent status with this account's own keys.
    public func fireReadAccountOutputs(
        _ pointers: [FireAccountOutputPointer],
        completion: @escaping (Result<FireAccountOutputReading, ConnectionError>) -> Void
    ) {
        guard !pointers.isEmpty else { completion(.success(FireAccountOutputReading(owned: [], absent: []))); return }
        guard pointers.count <= 100,
              pointers.allSatisfy({ $0.subaddressIndex < UInt64(UInt32.max) && RistrettoPublic($0.publicKey) != nil }),
              Set(pointers.map(\.publicKey)).count == pointers.count else {
            completion(.failure(.invalidServerResponse("Invalid account output pointers")))
            return
        }
        let account = accountLock.readSync { $0.accountKey }
        let keys = pointers.compactMap { RistrettoPublic($0.publicKey) }
        FogUntrustedTxOutFetcher(fogUntrustedTxOutService: serviceProvider.fogUntrustedTxOutService)
            .getTxOuts(outputPublicKeys: keys) { located in
                switch located {
                case .failure(let error): completion(.failure(error))
                case .success(let response):
                    guard response.results.count == pointers.count else {
                        completion(.failure(.invalidServerResponse(FireAccountOutputRefusal.absentFromLedger)))
                        return
                    }
                    // Separate what the ledger has from what it does not. Only
                    // the former can be verified, and only the former needs to
                    // be: an output that does not exist holds no money and
                    // proves nothing about this account.
                    let located = zip(pointers, response.results).filter { $0.1.resultCode == .found }
                    let absent = zip(pointers, response.results)
                        .filter { $0.1.resultCode != .found }.map { $0.0.publicKey }
                    guard !located.isEmpty else {
                        completion(.success(FireAccountOutputReading(owned: [], absent: absent)))
                        return
                    }
                    let indices = located.map { $0.1.txOutGlobalIndex }
                    FogMerkleProofFetcher(fogMerkleProofService: self.serviceProvider.fogMerkleProofService,
                                         targetQueue: self.serialQueue)
                        .getOutputs(globalIndices: indices, merkleRootBlock: 0, maxNumIndicesPerQuery: 100) { fetched in
                            switch fetched {
                            case .failure(let error):
                                if case .connectionError(let inner) = error { completion(.failure(inner)) }
                                else { completion(.failure(.invalidServerResponse(FireAccountOutputRefusal.outsideLedger))) }
                            case .success(let outputs):
                                var owned: [KnownTxOut] = []
                                for (pointer, location) in located {
                                    guard location.txOutPubkey.data == pointer.publicKey,
                                          let output = outputs[location.txOutGlobalIndex]?.0,
                                          output.publicKey.data == pointer.publicKey else {
                                        completion(.failure(.invalidServerResponse(FireAccountOutputRefusal.identityMismatch)))
                                        return
                                    }
                                    guard let decrypted = account.fireVerifyAccountOutput(output, pointer: pointer,
                                        globalIndex: location.txOutGlobalIndex,
                                        block: BlockMetadata(index: location.blockIndex, timestamp: location.timestampDate)) else {
                                        completion(.failure(.invalidServerResponse(FireAccountOutputRefusal.ownershipMismatch)))
                                        return
                                    }
                                    owned.append(decrypted)
                                }
                                self.fireCheckAccountOutputs(owned, absent: absent, completion: completion)
                            }
                        }
                }
            }
    }

    private func fireCheckAccountOutputs(
        _ outputs: [KnownTxOut],
        absent: [Data],
        completion: @escaping (Result<FireAccountOutputReading, ConnectionError>) -> Void
    ) {
        var request = FogLedger_CheckKeyImagesRequest()
        request.queries = outputs.map {
            var query = FogLedger_KeyImageQuery()
            query.keyImage = External_KeyImage($0.keyImage)
            query.startBlock = 0
            return query
        }
        serviceProvider.fogKeyImageService.checkKeyImages(request: request) { response in
            completion(response.flatMap { answer in
                var result: [OwnedTxOut] = []
                var trackers: [TxOutTracker] = []
                for output in outputs {
                    guard let status = answer.results.first(where: { $0.keyImage.data == output.keyImage.data }),
                          answer.numBlocks > output.block.index else {
                        return .failure(.invalidServerResponse("Incomplete account spent status"))
                    }
                    let spent: BlockMetadata?
                    switch status.keyImageResultCodeEnum {
                    case .spent:
                        guard status.spentAt >= output.block.index, status.spentAt < answer.numBlocks else {
                            return .failure(.invalidServerResponse("Invalid account spent block"))
                        }
                        spent = BlockMetadata(index: status.spentAt, timestampStatus: status.timestampStatus)
                    case .notSpent: spent = nil
                    default: return .failure(.invalidServerResponse("Account spent status unavailable"))
                    }
                    result.append(OwnedTxOut(output, receivedBlock: output.block, spentBlock: spent))
                    let tracker = TxOutTracker(output)
                    tracker.keyImageTracker.spentStatus = spent.map { .spent(block: $0) }
                        ?? .unspent(knownToBeUnspentBlockCount: answer.numBlocks)
                    trackers.append(tracker)
                }
                // Only the verified, complete batch can become spendable. This
                // same Account owns the keys used by the SDK transaction builder.
                self.accountLock.writeSync { account in
                    account.fireCacheVerifiedTrackers(trackers, blockCount: answer.numBlocks)
                }
                return .success(FireAccountOutputReading(owned: result, absent: absent))
            })
        }
    }
}

extension Account {
    func fireCacheVerifiedTrackers(_ trackers: [TxOutTracker], blockCount: UInt64) {
        for tracker in trackers {
            if let index = allTxOutTrackers.firstIndex(where: {
                $0.knownTxOut.publicKey == tracker.knownTxOut.publicKey
            }) {
                let previous = allTxOutTrackers[index]
                if !previous.isSpent && previous.keyImageTracker.nextKeyImageQueryBlockIndex <= blockCount {
                    allTxOutTrackers[index] = tracker
                }
            } else { allTxOutTrackers.append(tracker) }
        }
    }
}
