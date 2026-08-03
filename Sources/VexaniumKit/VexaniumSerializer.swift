import Foundation

// MARK: - Antelope binary serializer

final class VexSerializer {
    private var buf = [UInt8]()

    func uint8(_ v: Int) { buf.append(UInt8(v & 0xFF)) }

    func uint16(_ v: Int) {
        buf.append(UInt8(v & 0xFF))
        buf.append(UInt8((v >> 8) & 0xFF))
    }

    func uint32(_ v: UInt64) {
        buf.append(UInt8(v & 0xFF))
        buf.append(UInt8((v >> 8) & 0xFF))
        buf.append(UInt8((v >> 16) & 0xFF))
        buf.append(UInt8((v >> 24) & 0xFF))
    }

    func int64(_ v: Int64) {
        uint32(UInt64(bitPattern: v) & 0xFFFFFFFF)
        uint32((UInt64(bitPattern: v) >> 32) & 0xFFFFFFFF)
    }

    func uint64(_ v: UInt64) {
        uint32(v & 0xFFFFFFFF)
        uint32((v >> 32) & 0xFFFFFFFF)
    }

    func varuint32(_ v: UInt64) {
        var n = v
        while true {
            let b = Int(n & 0x7F)
            n >>= 7
            if n == 0 { buf.append(UInt8(b)); break }
            else { buf.append(UInt8(b | 0x80)) }
        }
    }

    func byteArray(_ data: [UInt8]) {
        varuint32(UInt64(data.count))
        buf.append(contentsOf: data)
    }

    func rawBytes(_ data: [UInt8]) { buf.append(contentsOf: data) }

    /// Antelope name: 64-bit packed value, stored little-endian.
    func name(_ n: String) { uint64(VexSerializer.packName(n)) }

    func string(_ s: String) { byteArray(Array(s.utf8)) }

    /// Antelope asset: int64 amount + 8-byte symbol cell (1-byte precision + up to 7 ASCII chars + NUL padding).
    /// Example: "1.0000 VEX" → amount=10000, precision=4
    func asset(_ quantity: String) throws {
        let parts = quantity.trimmingCharacters(in: .whitespaces).split(separator: " ")
        guard parts.count == 2 else { throw VexaniumError("Invalid asset format: \(quantity)") }
        let amountStr = String(parts[0])
        let symbol    = String(parts[1])
        let dotIdx = amountStr.firstIndex(of: ".")
        let precision = dotIdx.map { amountStr.distance(from: amountStr.index(after: $0), to: amountStr.endIndex) } ?? 0
        let digits = amountStr.replacingOccurrences(of: ".", with: "")
        guard let amount = Int64(digits) else { throw VexaniumError("Invalid asset amount: \(amountStr)") }
        int64(amount)
        let symBytes = Array(symbol.utf8)
        guard symBytes.count <= 7 else { throw VexaniumError("Symbol too long: \(symbol)") }
        buf.append(UInt8(precision))
        buf.append(contentsOf: symBytes)
        buf.append(contentsOf: [UInt8](repeating: 0, count: 7 - symBytes.count))
    }

    func toBytes() -> [UInt8] { buf }

    // MARK: - packName

    private static let charmap: [Character] = Array(".12345abcdefghijklmnopqrstuvwxyz")

    static func packName(_ name: String) -> UInt64 {
        var v: UInt64 = 0
        let chars = Array(name)
        for i in 0..<min(chars.count, 12) {
            guard let idx = charmap.firstIndex(of: chars[i]) else { continue }
            v |= UInt64(idx) << UInt64(64 - 5 * (i + 1))
        }
        if chars.count == 13 {
            if let idx = charmap.firstIndex(of: chars[12]) {
                v |= UInt64(idx) & 0x0F
            }
        }
        return v
    }
}

// MARK: - Action data packers

func packTransferData(from: String, to: String, quantity: String, memo: String) throws -> [UInt8] {
    let s = VexSerializer()
    s.name(from); s.name(to)
    try s.asset(quantity)
    s.string(memo)
    return s.toBytes()
}

func packTransaction(
    expirationEpoch: UInt64,
    refBlockNum: Int,
    refBlockPrefix: UInt32,
    actions: [PackedAction]
) throws -> [UInt8] {
    let s = VexSerializer()
    s.uint32(expirationEpoch)
    s.uint16(refBlockNum)
    s.uint32(UInt64(refBlockPrefix))
    s.varuint32(0)  // max_net_usage_words
    s.uint8(0)      // max_cpu_usage_ms
    s.varuint32(0)  // delay_sec
    s.varuint32(0)  // context_free_actions
    s.varuint32(UInt64(actions.count))
    for action in actions {
        s.name(action.account)
        s.name(action.name)
        s.varuint32(UInt64(action.authorization.count))
        for auth in action.authorization {
            s.name(auth.actor)
            s.name(auth.permission)
        }
        s.byteArray(action.data)
    }
    s.varuint32(0)  // transaction_extensions
    return s.toBytes()
}

func packBuyRamBytesData(payer: String, receiver: String, bytes: Int) -> [UInt8] {
    let s = VexSerializer()
    s.name(payer); s.name(receiver); s.uint32(UInt64(bytes))
    return s.toBytes()
}

func packSellRamData(account: String, bytes: Int64) -> [UInt8] {
    let s = VexSerializer()
    s.name(account); s.int64(bytes)
    return s.toBytes()
}

func packDelegateBwData(from: String, receiver: String, stakeNet: String, stakeCpu: String, transfer: Bool = false) throws -> [UInt8] {
    let s = VexSerializer()
    s.name(from); s.name(receiver)
    try s.asset(stakeNet); try s.asset(stakeCpu)
    s.uint8(transfer ? 1 : 0)
    return s.toBytes()
}

func packUndelegateBwData(from: String, receiver: String, unstakeNet: String, unstakeCpu: String) throws -> [UInt8] {
    let s = VexSerializer()
    s.name(from); s.name(receiver)
    try s.asset(unstakeNet); try s.asset(unstakeCpu)
    return s.toBytes()
}

func packVoteProducerData(voter: String, proxy: String, producers: [String]) -> [UInt8] {
    let s = VexSerializer()
    s.name(voter); s.name(proxy)
    let sorted = producers.sorted()
    s.varuint32(UInt64(sorted.count))
    for p in sorted { s.name(p) }
    return s.toBytes()
}

func packPowerupData(payer: String, receiver: String, days: Int, netFrac: Int64, cpuFrac: Int64, maxPayment: String) throws -> [UInt8] {
    let s = VexSerializer()
    s.name(payer); s.name(receiver)
    s.uint32(UInt64(days))
    s.int64(netFrac); s.int64(cpuFrac)
    try s.asset(maxPayment)
    return s.toBytes()
}

// MARK: - ISO → epoch seconds

func isoToEpochSeconds(_ iso: String) throws -> UInt64 {
    let clean = String(iso.prefix(19))  // drop sub-seconds
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    // fallback: manual parse
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    df.timeZone = TimeZone(identifier: "UTC")
    guard let date = df.date(from: clean) ?? formatter.date(from: iso) else {
        throw VexaniumError("Cannot parse ISO date: \(iso)")
    }
    return UInt64(date.timeIntervalSince1970)
}
