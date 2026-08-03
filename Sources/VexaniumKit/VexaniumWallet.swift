import Foundation

/// High-level Vexanium wallet operations.
///
/// ```swift
/// let api      = VexaniumApi(nodeUrl: "https://api.vexanium.com")
/// let hyperion = VexaniumHyperion(hyperionUrl: "https://hyperion.vexanium.com")
/// let key      = try VexaniumKey.fromWif("5J...")
/// let wallet   = VexaniumWallet(accountName: "myaccount", key: key, api: api, hyperion: hyperion)
///
/// let balance = try await wallet.getBalance()
/// let result  = try await wallet.transfer(VexTransferRequest(from: "myaccount", to: "other", quantity: "1.0000 VEX"))
/// print(result.transactionId)
/// ```
public actor VexaniumWallet {
    public let accountName: String
    private let key: VexaniumKey
    private let api: VexaniumApi
    private let hyperion: VexaniumHyperion
    private let permission: String
    private var abiCache: [String: [String: Any]] = [:]

    private static let txExpirySeconds: UInt64 = 120

    public init(
        accountName: String,
        key: VexaniumKey,
        api: VexaniumApi,
        hyperion: VexaniumHyperion,
        permission: String = "active"
    ) {
        self.accountName = accountName
        self.key = key
        self.api = api
        self.hyperion = hyperion
        self.permission = permission
    }

    // MARK: - Queries

    public func getBalance(
        contract: String = VexaniumApi.tokenContract,
        symbol: String = VexaniumApi.nativeSymbol
    ) async throws -> VexBalance {
        let balances = try await api.getCurrencyBalance(contract: contract, account: accountName, symbol: symbol)
        guard let raw = balances.first else { return VexBalance(account: accountName, amount: 0, symbol: symbol) }
        let parts = raw.trimmingCharacters(in: .whitespaces).split(separator: " ")
        return VexBalance(
            account: accountName,
            amount:  Double(parts.first ?? "0") ?? 0,
            symbol:  parts.count > 1 ? String(parts[1]) : symbol
        )
    }

    public func getAllBalances(contract: String = VexaniumApi.tokenContract) async throws -> [VexBalance] {
        let balances = try await api.getCurrencyBalance(contract: contract, account: accountName)
        return balances.map { raw in
            let parts = raw.trimmingCharacters(in: .whitespaces).split(separator: " ")
            return VexBalance(
                account: accountName,
                amount:  Double(parts.first ?? "0") ?? 0,
                symbol:  parts.count > 1 ? String(parts[1]) : "?"
            )
        }
    }

    public func getAccountInfo() async throws -> VexAccountInfo {
        try await api.getAccount(accountName)
    }

    // MARK: - History

    public func getTransferHistory(
        contract: String = VexaniumApi.tokenContract,
        symbol: String? = nil,
        limit: Int = 20,
        skip: Int = 0
    ) async throws -> [VexAction] {
        try await hyperion.getTransfers(
            account: accountName, contract: contract,
            symbol: symbol, limit: limit, skip: skip
        )
    }

    public func getActionHistory(
        filter: String? = nil,
        limit: Int = 20,
        skip: Int = 0
    ) async throws -> [VexAction] {
        try await hyperion.getActions(account: accountName, filter: filter, limit: limit, skip: skip)
    }

    public func getTransaction(_ txId: String) async throws -> VexTransaction {
        try await hyperion.getTransaction(txId)
    }

    public func getTableRows(
        code: String, scope: String, table: String,
        limit: Int = 10,
        lowerBound: String? = nil,
        upperBound: String? = nil,
        indexPos: Int = 1,
        keyType: String = "",
        reverse: Bool = false
    ) async throws -> VexTableResult {
        try await api.getTableRows(
            code: code, scope: scope, table: table,
            limit: limit, lowerBound: lowerBound, upperBound: upperBound,
            indexPos: indexPos, keyType: keyType, reverse: reverse
        )
    }

    // MARK: - Transfer

    public func transfer(_ request: VexTransferRequest) async throws -> VexTransferResult {
        let actionData = try packTransferData(
            from: request.from, to: request.to,
            quantity: request.quantity, memo: request.memo
        )
        let action = PackedAction(
            account: VexaniumApi.tokenContract,
            name: "transfer",
            authorization: [VexAuthorization(
                actor: request.from,
                permission: request.permission.isEmpty ? permission : request.permission
            )],
            data: actionData
        )
        return try await pushPackedAction(action)
    }

    // MARK: - Resource management

    public func buyRamBytes(_ bytes: Int, receiver: String? = nil) async throws -> VexTransferResult {
        let recv = receiver ?? accountName
        let data = packBuyRamBytesData(payer: accountName, receiver: recv, bytes: bytes)
        return try await pushAction(contract: VexaniumApi.systemContract, name: "buyrambytes", data: data)
    }

    public func sellRam(_ bytes: Int64) async throws -> VexTransferResult {
        let data = packSellRamData(account: accountName, bytes: bytes)
        return try await pushAction(contract: VexaniumApi.systemContract, name: "sellram", data: data)
    }

    public func delegateBw(
        stakeCpu: String, stakeNet: String,
        receiver: String? = nil, transfer: Bool = false
    ) async throws -> VexTransferResult {
        let recv = receiver ?? accountName
        let data = try packDelegateBwData(from: accountName, receiver: recv, stakeNet: stakeNet, stakeCpu: stakeCpu, transfer: transfer)
        return try await pushAction(contract: VexaniumApi.systemContract, name: "delegatebw", data: data)
    }

    public func undelegateBw(
        unstakeCpu: String, unstakeNet: String,
        receiver: String? = nil
    ) async throws -> VexTransferResult {
        let recv = receiver ?? accountName
        let data = try packUndelegateBwData(from: accountName, receiver: recv, unstakeNet: unstakeNet, unstakeCpu: unstakeCpu)
        return try await pushAction(contract: VexaniumApi.systemContract, name: "undelegatebw", data: data)
    }

    public func voteProducer(producers: [String] = [], proxy: String = "") async throws -> VexTransferResult {
        let data = packVoteProducerData(voter: accountName, proxy: proxy, producers: producers)
        return try await pushAction(contract: VexaniumApi.systemContract, name: "voteproducer", data: data)
    }

    public func powerup(
        netFrac: Int64, cpuFrac: Int64, maxPayment: String,
        days: Int = 1, receiver: String? = nil
    ) async throws -> VexTransferResult {
        let recv = receiver ?? accountName
        let data = try packPowerupData(payer: accountName, receiver: recv, days: days, netFrac: netFrac, cpuFrac: cpuFrac, maxPayment: maxPayment)
        return try await pushAction(contract: VexaniumApi.systemContract, name: "powerup", data: data)
    }

    // MARK: - Generic action

    /// Sign and broadcast any Antelope action from a plain data map.
    /// The contract ABI is fetched live (cached per session) to encode the fields.
    public func pushAntelopeAction(
        contract: String,
        actionName: String,
        data: [String: Any]
    ) async throws -> VexTransferResult {
        let abi = try await cachedAbi(contract: contract)
        let encoded = try encodeAbiAction(abi: abi, actionName: actionName, data: data)
        return try await pushAction(contract: contract, name: actionName, data: encoded)
    }

    /// Build and sign an action without broadcasting. Returns (packedTxHex, [signature]).
    public func signAction(
        contract: String, actionName: String, actionData: [UInt8],
        extraAuth: [VexAuthorization] = []
    ) async throws -> (packedTrxHex: String, signatures: [String]) {
        let auth = [VexAuthorization(actor: accountName, permission: permission)] + extraAuth
        let (hex, sigs) = try await buildAndSign(
            actions: [PackedAction(account: contract, name: actionName, authorization: auth, data: actionData)]
        )
        return (hex, sigs)
    }

    public var publicKey: String { get throws { try key.publicKeyString } }

    // MARK: - Utility

    /// Format amount as Antelope asset string. Example: formatQuantity(1.5, 4, "VEX") → "1.5000 VEX"
    public static func formatQuantity(_ amount: Double, precision: Int = 4, symbol: String = "VEX") -> String {
        String(format: "%.\(precision)f %@", amount, symbol)
    }

    // MARK: - Private helpers

    private func pushAction(contract: String, name: String, data: [UInt8]) async throws -> VexTransferResult {
        let action = PackedAction(
            account: contract, name: name,
            authorization: [VexAuthorization(actor: accountName, permission: permission)],
            data: data
        )
        return try await pushPackedAction(action)
    }

    private func pushPackedAction(_ action: PackedAction) async throws -> VexTransferResult {
        let (hex, sigs) = try await buildAndSign(actions: [action])
        return try await api.pushTransaction(packedTrxHex: hex, signatures: sigs)
    }

    private func buildAndSign(actions: [PackedAction]) async throws -> (String, [String]) {
        let info = try await api.getInfo()
        let refBlock = try await api.getBlock(info.lastIrreversibleBlockNum)
        let expiration = UInt64(Date().timeIntervalSince1970) + Self.txExpirySeconds
        let refBlockNum = Int(refBlock.blockNum & 0xFFFF)
        let packedTx = try packTransaction(
            expirationEpoch: expiration,
            refBlockNum: refBlockNum,
            refBlockPrefix: refBlock.refBlockPrefix,
            actions: actions
        )
        let digest = try vexSigningDigest(chainId: info.chainId, packedTx: packedTx)
        let sig = try key.sign(digest)
        return (Data(packedTx).vexHex, [sig])
    }

    private func cachedAbi(contract: String) async throws -> [String: Any] {
        if let cached = abiCache[contract] { return cached }
        let abi = try await api.getAbi(contract)
        abiCache[contract] = abi
        return abi
    }
}

// MARK: - ABI encoder (for generic actions)

private func encodeAbiAction(abi: [String: Any], actionName: String, data: [String: Any]) throws -> [UInt8] {
    let abiContent = (abi["abi"] as? [String: Any]) ?? abi

    var typeAliases = [String: String]()
    if let types = abiContent["types"] as? [[String: Any]] {
        for t in types {
            if let newType = t["new_type_name"] as? String, let type_ = t["type"] as? String {
                typeAliases[newType] = type_
            }
        }
    }

    var structMap = [String: [String: Any]]()
    if let structs = abiContent["structs"] as? [[String: Any]] {
        for s in structs {
            if let name = s["name"] as? String { structMap[name] = s }
        }
    }

    var actionType = actionName
    if let actions = abiContent["actions"] as? [[String: Any]] {
        for a in actions {
            if a["name"] as? String == actionName, let t = a["type"] as? String {
                actionType = t; break
            }
        }
    }

    let s = VexSerializer()
    try abiEncodeStruct(s, typeName: actionType, data: data, structs: structMap, aliases: typeAliases)
    return s.toBytes()
}

private func resolveType(_ type: String, aliases: [String: String]) -> String {
    var t = type; var seen = Set<String>()
    while let next = aliases[t], seen.insert(t).inserted { t = next }
    return t
}

private func abiEncodeStruct(
    _ s: VexSerializer, typeName: String, data: [String: Any],
    structs: [String: [String: Any]], aliases: [String: String]
) throws {
    guard let struct_ = structs[typeName] else {
        throw VexaniumError("Unknown ABI struct: \(typeName)")
    }
    if let base = struct_["base"] as? String, !base.isEmpty {
        try abiEncodeStruct(s, typeName: base, data: data, structs: structs, aliases: aliases)
    }
    guard let fields = struct_["fields"] as? [[String: Any]] else { return }
    for field in fields {
        guard let fname = field["name"] as? String,
              let ftype = field["type"] as? String else { continue }
        try abiEncodeField(s, name: fname, type: resolveType(ftype, aliases: aliases),
                           value: data[fname], structs: structs, aliases: aliases)
    }
}

private func abiEncodeField(
    _ s: VexSerializer, name: String, type fieldType: String, value: Any?,
    structs: [String: [String: Any]], aliases: [String: String]
) throws {
    if fieldType.hasSuffix("[]") {
        let elemType = resolveType(String(fieldType.dropLast(2)), aliases: aliases)
        let list: [Any?]
        switch value {
        case let a as [Any]: list = a
        case nil: list = []
        default: throw VexaniumError("Expected array for '\(name)'")
        }
        s.varuint32(UInt64(list.count))
        for elem in list {
            try abiEncodeField(s, name: name, type: elemType, value: elem, structs: structs, aliases: aliases)
        }
        return
    }
    if fieldType.hasSuffix("?") {
        let elemType = resolveType(String(fieldType.dropLast()), aliases: aliases)
        if value == nil { s.uint8(0) }
        else { s.uint8(1); try abiEncodeField(s, name: name, type: elemType, value: value, structs: structs, aliases: aliases) }
        return
    }

    func strVal() throws -> String {
        guard let v = value else { throw VexaniumError("Missing field '\(name)' (type \(fieldType))") }
        return "\(v)"
    }
    func intVal() throws -> Int64 {
        switch value {
        case let n as Int: return Int64(n)
        case let n as Int64: return n
        case let n as Double: return Int64(n)
        case let s as String: if let v = Int64(s) { return v }; throw VexaniumError("Non-numeric '\(name)': \(s)")
        default: throw VexaniumError("Missing numeric '\(name)'")
        }
    }

    switch fieldType {
    case "bool":
        let v: Int
        switch value {
        case let b as Bool: v = b ? 1 : 0
        case let n as Int:  v = n != 0 ? 1 : 0
        case let str as String: v = ["true","1","yes"].contains(str.lowercased()) ? 1 : 0
        default: v = 0
        }
        s.uint8(v)
    case "uint8","int8":    s.uint8(Int(try intVal()))
    case "uint16","int16":  s.uint16(Int(try intVal()))
    case "uint32","int32":  s.uint32(UInt64(bitPattern: try intVal()))
    case "uint64":          s.uint64(UInt64(bitPattern: try intVal()))
    case "int64":           s.int64(try intVal())
    case "float32":         s.uint32(UInt64(Float(try strVal())?.bitPattern ?? 0))
    case "float64":         s.int64(Int64(bitPattern: Double(try strVal())?.bitPattern ?? 0))
    case "name":            s.name(try strVal())
    case "string":          s.string(value.map { "\($0)" } ?? "")
    case "asset":           try s.asset(try strVal())
    case "checksum256":
        let hex = try strVal().replacingOccurrences(of: "0x", with: "")
        s.rawBytes((0..<32).map { UInt8(hex.dropFirst($0*2).prefix(2).description, radix: 16) ?? 0 })
    case "bytes":
        let hex = try strVal().replacingOccurrences(of: "0x", with: "")
        s.byteArray((0..<hex.count/2).map { UInt8(hex.dropFirst($0*2).prefix(2).description, radix: 16) ?? 0 })
    case "time_point":           s.int64(try intVal())
    case "time_point_sec":       s.uint32(UInt64(bitPattern: try intVal()))
    case "block_timestamp_type": s.uint32(UInt64(bitPattern: try intVal()))
    default:
        if structs[fieldType] != nil {
            guard let nested = value as? [String: Any] else {
                throw VexaniumError("Expected object for '\(name)' (type \(fieldType))")
            }
            try abiEncodeStruct(s, typeName: fieldType, data: nested, structs: structs, aliases: aliases)
        } else {
            throw VexaniumError("Unsupported ABI type '\(fieldType)' for field '\(name)'")
        }
    }
}
