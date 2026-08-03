import Foundation

// MARK: - Chain / Block

public struct VexChainInfo: Sendable {
    public let chainId: String
    public let headBlockNum: UInt64
    public let headBlockId: String
    public let headBlockTime: String
    public let lastIrreversibleBlockNum: UInt64
    public let lastIrreversibleBlockId: String
}

public struct VexBlock: Sendable {
    public let blockNum: UInt64
    public let id: String
    public let timestamp: String
    public let refBlockPrefix: UInt32
}

public struct VexResourceLimit: Sendable {
    public let used: Int64
    public let available: Int64
    public let max: Int64
}

public struct VexAccountInfo: Sendable {
    public let accountName: String
    public let ramQuota: Int64
    public let ramUsage: Int64
    public let cpuWeight: Int64
    public let netWeight: Int64
    public let cpuLimit: VexResourceLimit
    public let netLimit: VexResourceLimit
}

// MARK: - Token / Balance

public struct VexBalance: Sendable, CustomStringConvertible {
    public let account: String
    public let amount: Double
    public let symbol: String

    public var description: String {
        let s = String(format: "%.4f", amount)
        return "\(s.trimmingTrailingZeros) \(symbol)"
    }
}

public struct VexToken: Sendable {
    public let symbol: String
    public let amount: Double
    public let precision: Int
    public let contract: String

    public func asAsset() -> String {
        String(format: "%.\(precision)f %@", amount, symbol)
    }
}

// MARK: - Transaction / History

public struct VexActionTrace: Sendable {
    public let contract: String
    public let actionName: String
    public let returnValueHex: String
    public let returnValueData: String?
    public let console: String
}

public struct VexTransferResult: Sendable {
    public let transactionId: String
    public let blockNum: UInt64
    public let blockTime: String
    public let traces: [VexActionTrace]

    public var returnValueHex: String? { traces.first?.returnValueHex.nilIfEmpty }
    public var returnValueData: String? { traces.first?.returnValueData }
}

public struct VexAction: Sendable {
    public let transactionId: String
    public let blockNum: UInt64
    public let timestamp: String
    public let contract: String
    public let action: String
    public let from: String
    public let to: String
    public let quantity: String
    public let symbol: String
    public let memo: String
    public let irreversible: Bool
}

public struct VexTransaction: Sendable {
    public let transactionId: String
    public let blockNum: UInt64
    public let blockTime: String
    public let irreversible: Bool
    public let actions: [VexAction]
}

public struct VexTableResult: @unchecked Sendable {
    public let rows: [[String: Any]]
    public let more: Bool
    public let nextKey: String
}

// MARK: - Requests

public struct VexTransferRequest: Sendable {
    public let from: String
    public let to: String
    /// Already formatted as "1.0000 VEX"
    public let quantity: String
    public let memo: String
    public let permission: String

    public init(from: String, to: String, quantity: String, memo: String = "", permission: String = "active") {
        self.from = from; self.to = to; self.quantity = quantity
        self.memo = memo; self.permission = permission
    }
}

// MARK: - Serializer types (public for signAction API)

public struct VexAuthorization: Sendable {
    public let actor: String
    public let permission: String

    public init(actor: String, permission: String) {
        self.actor = actor; self.permission = permission
    }
}

struct PackedAction: Sendable {
    let account: String
    let name: String
    let authorization: [VexAuthorization]
    let data: [UInt8]
}

// MARK: - Error

public struct VexaniumError: Error, CustomStringConvertible {
    public let description: String
    public init(_ message: String) { self.description = message }
}

// MARK: - Helpers

private extension String {
    var trimmingTrailingZeros: String {
        guard contains(".") else { return self }
        var s = self
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    var nilIfEmpty: String? { isEmpty ? nil : self }
}
