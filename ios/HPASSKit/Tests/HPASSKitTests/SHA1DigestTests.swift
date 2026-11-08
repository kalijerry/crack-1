import XCTest
@testable import HPASSKit

final class SHA1DigestTests: XCTestCase {
    private func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

    /// 纯 Swift 实现必须和标准测试向量一致（Windows / Linux 上编译评估工具时用它）。
    func testPortableMatchesKnownVectors() {
        XCTAssertEqual(hex(SHA1Digest.portable(Array("abc".utf8))), "a9993e364706816aba3e25717850c26c9cd0d89d")
        XCTAssertEqual(hex(SHA1Digest.portable([])), "da39a3ee5e6b4b0d3255bfef95601890afd80709")
        let long = Array("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)
        XCTAssertEqual(hex(SHA1Digest.portable(long)), "84983e441c3bd26ebaae4aa1f95129e5e54670f1")
        XCTAssertEqual(SHA1Digest.portable(long), SHA1Digest.hash(long))
    }
}
