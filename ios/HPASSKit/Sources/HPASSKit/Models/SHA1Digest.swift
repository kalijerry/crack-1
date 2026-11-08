import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// SHA-1 摘要（只用于 uuid5 这类非安全用途）。苹果平台走 CryptoKit，其他平台（Windows / Linux 上编译评估工具）用纯 Swift 实现。
enum SHA1Digest {
    static func hash(_ bytes: [UInt8]) -> [UInt8] {
        #if canImport(CryptoKit)
        return Array(Insecure.SHA1.hash(data: bytes))
        #else
        return portable(bytes)
        #endif
    }

    /// FIPS 180-4 SHA-1。
    static func portable(_ input: [UInt8]) -> [UInt8] {
        var h0: UInt32 = 0x6745_2301, h1: UInt32 = 0xEFCD_AB89, h2: UInt32 = 0x98BA_DCFE
        var h3: UInt32 = 0x1032_5476, h4: UInt32 = 0xC3D2_E1F0
        var msg = input
        let bitLen = UInt64(input.count) &* 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        for i in (0..<8).reversed() { msg.append(UInt8((bitLen >> (UInt64(i) * 8)) & 0xFF)) }
        var w = [UInt32](repeating: 0, count: 80)
        for chunk in stride(from: 0, to: msg.count, by: 64) {
            for i in 0..<16 {
                let b = chunk + i * 4
                w[i] = UInt32(msg[b]) << 24 | UInt32(msg[b + 1]) << 16 | UInt32(msg[b + 2]) << 8 | UInt32(msg[b + 3])
            }
            for i in 16..<80 {
                let x = w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]
                w[i] = (x << 1) | (x >> 31)
            }
            var a = h0, b = h1, c = h2, d = h3, e = h4
            for i in 0..<80 {
                let f: UInt32, k: UInt32
                switch i {
                case 0..<20: f = (b & c) | (~b & d); k = 0x5A82_7999
                case 20..<40: f = b ^ c ^ d; k = 0x6ED9_EBA1
                case 40..<60: f = (b & c) | (b & d) | (c & d); k = 0x8F1B_BCDC
                default: f = b ^ c ^ d; k = 0xCA62_C1D6
                }
                let t = ((a << 5) | (a >> 27)) &+ f &+ e &+ k &+ w[i]
                e = d; d = c; c = (b << 30) | (b >> 2); b = a; a = t
            }
            h0 = h0 &+ a; h1 = h1 &+ b; h2 = h2 &+ c; h3 = h3 &+ d; h4 = h4 &+ e
        }
        var out: [UInt8] = []
        for v in [h0, h1, h2, h3, h4] { for s in [24, 16, 8, 0] { out.append(UInt8((v >> UInt32(s)) & 0xFF)) } }
        return out
    }
}
