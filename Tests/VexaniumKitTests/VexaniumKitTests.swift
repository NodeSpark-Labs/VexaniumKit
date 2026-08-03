import XCTest
@testable import VexaniumKit

final class VexaniumKitTests: XCTestCase {

    // MARK: - RIPEMD160

    func testRipemd160KnownVector() {
        // RIPEMD-160("") = 9c1185a5c5e9fc54612808977ee8f548b2258d31
        let result = RIPEMD160.hash([])
        XCTAssertEqual(result.map { String(format: "%02x", $0) }.joined(),
                       "9c1185a5c5e9fc54612808977ee8f548b2258d31")
    }

    func testRipemd160AbcVector() {
        // RIPEMD-160("abc") = 8eb208f7e05d987a9b044a8e98c6b087f15a0bfc
        let result = RIPEMD160.hash(Array("abc".utf8))
        XCTAssertEqual(result.map { String(format: "%02x", $0) }.joined(),
                       "8eb208f7e05d987a9b044a8e98c6b087f15a0bfc")
    }

    // MARK: - Base58

    func testBase58RoundTrip() throws {
        let original = Array("Hello VEX!".utf8)
        let encoded = VexBase58.encode(original)
        let decoded = try VexBase58.decode(encoded)
        XCTAssertEqual(decoded, original)
    }

    func testBase58CheckRoundTrip() throws {
        let data = [UInt8](repeating: 0xAB, count: 32)
        let encoded = VexBase58.encodeCheck(data)
        let decoded = try VexBase58.decodeCheck(encoded)
        XCTAssertEqual(decoded, data)
    }

    func testBase58CheckK1RoundTrip() throws {
        let data = [UInt8](repeating: 0xCD, count: 65)
        let encoded = VexBase58.encodeCheck(data, keyType: "K1")
        let decoded = try VexBase58.decodeCheck(encoded, keyType: "K1")
        XCTAssertEqual(decoded, data)
    }

    // MARK: - Key derivation (WIF round-trip)

    func testWifRoundTrip() throws {
        // Standard uncompressed WIF key
        let wif = "5HueCGU8rMjxECyDialwujzqDTbgGADshsFNncMNwMrBGBbDcEd"
        let key = try VexaniumKey.fromWif(wif)
        XCTAssertEqual(key.privateKeyData.count, 32)
    }

    // MARK: - Serializer - packName

    func testPackNameEosio() {
        // "eosio" should pack to a known constant
        let packed = VexSerializer.packName("eosio")
        XCTAssertEqual(packed, 6138663577826885632)
    }

    func testPackNameTransfer() {
        let packed = VexSerializer.packName("transfer")
        XCTAssertEqual(packed, 14829575313431724032)
    }

    // MARK: - Signing digest

    func testSigningDigestLength() throws {
        let chainId = String(repeating: "a", count: 64)
        let packedTx = [UInt8](repeating: 0x00, count: 100)
        let digest = try vexSigningDigest(chainId: chainId, packedTx: packedTx)
        XCTAssertEqual(digest.count, 32)
    }

    // MARK: - Data hex extension

    func testDataVexHex() {
        let data = Data([0xDE, 0xAD, 0xBE, 0xEF])
        XCTAssertEqual(data.vexHex, "deadbeef")
    }

    func testDataFromVexHex() {
        let data = Data(vexHex: "deadbeef")
        XCTAssertEqual(data, Data([0xDE, 0xAD, 0xBE, 0xEF]))
    }

    // MARK: - BIP39 seed (known vector)

    func testBip39SeedKnownVector() throws {
        // BIP39 test vector: all-zeros mnemonic → known seed
        let mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        let seed = try VexHD.bip39Seed(mnemonic: mnemonic, passphrase: "TREZOR")
        XCTAssertEqual(seed.count, 64)
        // Known first 4 bytes of this specific test vector seed
        XCTAssertEqual(seed.prefix(4).map { String(format: "%02x", $0) }.joined(), "c55257")
        // Note: only first 3 bytes checked — see BIP39 test vectors for full expected value
    }
}
