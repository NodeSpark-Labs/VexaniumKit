import Foundation

// MARK: - Chain API

/// Antelope Chain API client (nodeos v1 API).
/// All methods are async and throw `VexaniumError` on failure.
public final class VexaniumApi: Sendable {
    public let nodeUrl: String

    public init(nodeUrl: String) {
        self.nodeUrl = nodeUrl.hasSuffix("/") ? String(nodeUrl.dropLast()) : nodeUrl
    }

    // MARK: Chain endpoints

    public func getInfo() async throws -> VexChainInfo {
        let d = try await post("/v1/chain/get_info", body: [:])
        return try VexChainInfo(json: d)
    }

    public func getBlock(_ blockNum: UInt64) async throws -> VexBlock {
        let d = try await post("/v1/chain/get_block", body: ["block_num_or_id": blockNum])
        return try VexBlock(json: d)
    }

    public func getAccount(_ name: String) async throws -> VexAccountInfo {
        let d = try await post("/v1/chain/get_account", body: ["account_name": name])
        return try VexAccountInfo(json: d)
    }

    public func getAbi(_ accountName: String) async throws -> [String: Any] {
        try await post("/v1/chain/get_abi", body: ["account_name": accountName])
    }

    /// Returns balance strings like ["1.5000 VEX"].
    public func getCurrencyBalance(contract: String, account: String, symbol: String? = nil) async throws -> [String] {
        var body: [String: Any] = ["code": contract, "account": account]
        if let sym = symbol { body["symbol"] = sym }
        let d = try await postArray("/v1/chain/get_currency_balance", body: body)
        return d.compactMap { $0 as? String }
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
        var body: [String: Any] = [
            "code": code, "scope": scope, "table": table,
            "limit": limit, "json": true, "reverse": reverse,
            "index_position": indexPos
        ]
        if let lb = lowerBound { body["lower_bound"] = lb }
        if let ub = upperBound { body["upper_bound"] = ub }
        if !keyType.isEmpty { body["key_type"] = keyType }
        let d = try await post("/v1/chain/get_table_rows", body: body)
        return VexTableResult(
            rows: (d["rows"] as? [[String: Any]]) ?? [],
            more: (d["more"] as? Bool) ?? false,
            nextKey: (d["next_key"] as? String) ?? ""
        )
    }

    public func pushTransaction(packedTrxHex: String, signatures: [String]) async throws -> VexTransferResult {
        let body: [String: Any] = [
            "signatures": signatures,
            "compression": "none",
            "packed_context_free_data": "",
            "packed_trx": packedTrxHex
        ]
        let d = try await post("/v1/chain/push_transaction", body: body)
        let processed = d["processed"] as? [String: Any]
        let tracesArr = processed?["action_traces"] as? [[String: Any]] ?? []
        return VexTransferResult(
            transactionId: (d["transaction_id"] as? String) ?? (d["id"] as? String) ?? "",
            blockNum: (processed?["block_num"] as? UInt64) ?? 0,
            blockTime: (processed?["block_time"] as? String) ?? "",
            traces: tracesArr.map(VexActionTrace.init(json:))
        )
    }

    // MARK: Raw access

    public func post(_ path: String, body: [String: Any]) async throws -> [String: Any] {
        let data = try await sendPost(path: path, body: body)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VexaniumError("Non-object JSON response from \(path)")
        }
        if let err = obj["error"] as? [String: Any] {
            let details = (err["details"] as? [[String: Any]])?.first?["message"] as? String ?? ""
            let what = (err["what"] as? String) ?? ""
            throw VexaniumError(details.isEmpty ? (what.isEmpty ? "Unknown RPC error" : what) : details)
        }
        return obj
    }

    private func postArray(_ path: String, body: [String: Any]) async throws -> [Any] {
        let data = try await sendPost(path: path, body: body)
        guard let arr = try JSONSerialization.jsonObject(with: data) as? [Any] else {
            throw VexaniumError("Expected JSON array from \(path)")
        }
        return arr
    }

    private func sendPost(path: String, body: [String: Any]) async throws -> Data {
        guard let url = URL(string: "\(nodeUrl)\(path)") else {
            throw VexaniumError("Invalid URL: \(nodeUrl)\(path)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400, http.statusCode != 500 {
            throw VexaniumError("HTTP \(http.statusCode) from \(path)")
        }
        return data
    }

    public func get(_ path: String) async throws -> [String: Any] {
        guard let url = URL(string: "\(nodeUrl)\(path)") else {
            throw VexaniumError("Invalid URL: \(nodeUrl)\(path)")
        }
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VexaniumError("Non-object JSON response from \(path)")
        }
        return obj
    }

    // MARK: Constants

    public static let systemContract = "vexcore"
    public static let tokenContract  = "vex.token"
    public static let nativeSymbol   = "VEX"
}

// MARK: - Hyperion History API

/// Hyperion History v2 client.
public final class VexaniumHyperion: Sendable {
    public let hyperionUrl: String

    public init(hyperionUrl: String) {
        self.hyperionUrl = hyperionUrl.hasSuffix("/") ? String(hyperionUrl.dropLast()) : hyperionUrl
    }

    public func getActions(
        account: String,
        filter: String? = nil,
        limit: Int = 20,
        skip: Int = 0,
        after: String? = nil,
        before: String? = nil,
        sort: String = "desc"
    ) async throws -> [VexAction] {
        var path = "/v2/history/get_actions?account=\(account)&limit=\(limit)&skip=\(skip)&sort=\(sort)"
        if let f = filter { path += "&filter=\(f.urlEncoded)" }
        if let a = after  { path += "&after=\(a)" }
        if let b = before { path += "&before=\(b)" }
        let d = try await get(path)
        return ((d["actions"] as? [[String: Any]]) ?? []).map(VexAction.init(json:))
    }

    public func getTransfers(
        account: String,
        contract: String = VexaniumApi.tokenContract,
        symbol: String? = nil,
        limit: Int = 20,
        skip: Int = 0,
        sort: String = "desc"
    ) async throws -> [VexAction] {
        let filter = "\(contract):transfer".urlEncoded
        var path = "/v2/history/get_actions?account=\(account)&filter=\(filter)&limit=\(limit)&skip=\(skip)&sort=\(sort)"
        if let sym = symbol { path += "&symbol=\(sym)" }
        let d = try await get(path)
        return ((d["actions"] as? [[String: Any]]) ?? []).map(VexAction.init(json:))
    }

    public func getTransaction(_ txId: String) async throws -> VexTransaction {
        let d = try await get("/v2/history/get_transaction?id=\(txId)")
        return VexTransaction(json: d)
    }

    public func getKeyAccounts(_ publicKey: String) async throws -> [String] {
        let d = try await get("/v2/state/get_key_accounts?public_key=\(publicKey.trimmingCharacters(in: .whitespaces))")
        return (d["account_names"] as? [String]) ?? []
    }

    public func getTokens(_ account: String) async throws -> [VexToken] {
        let d = try await get("/v2/state/get_tokens?account=\(account.trimmingCharacters(in: .whitespaces))")
        return ((d["tokens"] as? [[String: Any]]) ?? []).compactMap { dict in
            guard let symbol = dict["symbol"] as? String, !symbol.isEmpty else { return nil }
            return VexToken(
                symbol: symbol,
                amount: (dict["amount"] as? Double) ?? 0,
                precision: (dict["precision"] as? Int) ?? 4,
                contract: (dict["contract"] as? String) ?? ""
            )
        }
    }

    public func isHealthy() async -> Bool {
        (try? await get("/v2/health"))?["status"] as? String == "OK"
    }

    public func get(_ path: String) async throws -> [String: Any] {
        guard let url = URL(string: "\(hyperionUrl)\(path)") else {
            throw VexaniumError("Invalid URL: \(hyperionUrl)\(path)")
        }
        let (data, resp) = try await URLSession.shared.data(from: url)
        if let http = resp as? HTTPURLResponse, !http.isSuccess {
            throw VexaniumError("Hyperion error \(http.statusCode) from \(path)")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VexaniumError("Non-object JSON response from \(path)")
        }
        return obj
    }
}

// MARK: - JSON init helpers (private)

extension VexChainInfo {
    init(json: [String: Any]) throws {
        guard let chainId = json["chain_id"] as? String else { throw VexaniumError("Missing chain_id") }
        self.init(
            chainId: chainId,
            headBlockNum: (json["head_block_num"] as? UInt64) ?? UInt64((json["head_block_num"] as? Int) ?? 0),
            headBlockId: (json["head_block_id"] as? String) ?? "",
            headBlockTime: (json["head_block_time"] as? String) ?? "",
            lastIrreversibleBlockNum: (json["last_irreversible_block_num"] as? UInt64) ?? UInt64((json["last_irreversible_block_num"] as? Int) ?? 0),
            lastIrreversibleBlockId: (json["last_irreversible_block_id"] as? String) ?? ""
        )
    }
}

extension VexBlock {
    init(json: [String: Any]) throws {
        guard let id = json["id"] as? String else { throw VexaniumError("Missing block id") }
        let blockNum = (json["block_num"] as? UInt64) ?? UInt64((json["block_num"] as? Int) ?? 0)
        let prefix = (json["ref_block_prefix"] as? UInt32)
            ?? UInt32(truncatingIfNeeded: (json["ref_block_prefix"] as? Int) ?? 0)
        self.init(
            blockNum: blockNum, id: id,
            timestamp: (json["timestamp"] as? String) ?? "",
            refBlockPrefix: prefix
        )
    }
}

extension VexAccountInfo {
    init(json: [String: Any]) throws {
        func limit(_ d: [String: Any]?) -> VexResourceLimit {
            VexResourceLimit(
                used:      Int64((d?["used"]      as? Int) ?? 0),
                available: Int64((d?["available"] as? Int) ?? 0),
                max:       Int64((d?["max"]       as? Int) ?? 0)
            )
        }
        self.init(
            accountName: (json["account_name"] as? String) ?? "",
            ramQuota:    Int64((json["ram_quota"]  as? Int) ?? 0),
            ramUsage:    Int64((json["ram_usage"]  as? Int) ?? 0),
            cpuWeight:   Int64((json["cpu_weight"] as? Int) ?? 0),
            netWeight:   Int64((json["net_weight"] as? Int) ?? 0),
            cpuLimit:    limit(json["cpu_limit"] as? [String: Any]),
            netLimit:    limit(json["net_limit"] as? [String: Any])
        )
    }
}

extension VexActionTrace {
    init(json: [String: Any]) {
        let act = json["act"] as? [String: Any]
        let decoded = json["return_value_data"].map { "\($0)" }
        self.init(
            contract:        (act?["account"]   as? String) ?? "",
            actionName:      (act?["name"]      as? String) ?? "",
            returnValueHex:  (json["return_value_hex_data"] as? String) ?? "",
            returnValueData: decoded?.nilIfEmpty,
            console:         (json["console"]   as? String) ?? ""
        )
    }
}

extension VexAction {
    init(json: [String: Any]) {
        let act  = json["act"]  as? [String: Any]
        let data = act?["data"] as? [String: Any]
        let qty  = ((data?["quantity"] as? String) ?? "0 ").trimmingCharacters(in: .whitespaces)
        let parts = qty.split(separator: " ")
        self.init(
            transactionId: (json["trx_id"]    as? String) ?? "",
            blockNum:      UInt64((json["block_num"] as? Int) ?? 0),
            timestamp:     (json["@timestamp"] as? String) ?? "",
            contract:      (act?["account"]  as? String) ?? "",
            action:        (act?["name"]     as? String) ?? "",
            from:          (data?["from"]    as? String) ?? "",
            to:            (data?["to"]      as? String) ?? "",
            quantity:      parts.first.map(String.init) ?? "0",
            symbol:        parts.count > 1 ? String(parts[1]) : "",
            memo:          (data?["memo"]    as? String) ?? "",
            irreversible:  (json["irreversible"] as? Bool) ?? false
        )
    }
}

extension VexTransaction {
    init(json: [String: Any]) {
        let actions = (json["actions"] as? [[String: Any]]) ?? []
        self.init(
            transactionId: (json["trx_id"]       as? String) ?? "",
            blockNum:      UInt64((json["block_num"] as? Int) ?? 0),
            blockTime:     (json["@timestamp"]    as? String) ?? "",
            irreversible:  (json["irreversible"]  as? Bool) ?? false,
            actions:       actions.map(VexAction.init(json:))
        )
    }
}

// MARK: - Helpers

private extension String {
    var urlEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? self
    }

    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private extension HTTPURLResponse {
    var isSuccess: Bool { (200..<300).contains(statusCode) }
}
