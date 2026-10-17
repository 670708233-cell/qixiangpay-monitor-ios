import Foundation
import CommonCrypto
import CryptoKit
import Security
import zlib

/// 加密工具：AES-CBC-PKCS7、RSA-PKCS1v15（裸模数+指数）、MD5、HMAC-SHA256、gzip。
/// 与 Android 版 Gt4Solver 的加密部分逐位对齐。
enum Crypto {

    // MARK: - AES-CBC

    static func aesCbcPkcs7Encrypt(_ data: Data, key: Data, iv: Data) -> Data? {
        guard key.count == kCCKeySizeAES128, iv.count == kCCBlockSizeAES128 else { return nil }
        var out = Data(count: data.count + kCCBlockSizeAES128)
        var outLen = 0
        let status = out.withUnsafeMutableBytes { ob in
            data.withUnsafeBytes { ib in
                key.withUnsafeBytes { kb in
                    iv.withUnsafeBytes { vb in
                        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(kCCOptionPKCS7Padding),
                                kb.baseAddress, key.count, vb.baseAddress,
                                ib.baseAddress, data.count,
                                ob.baseAddress, ob.count, &outLen)
                    }
                }
            }
        }
        guard status == kCCSuccess, outLen > 0 else { return nil }
        return out.prefix(outLen)
    }

    // MARK: - RSA（PKCS#1 DER 手工构造 → SecKey）

    static func rsaPkcs1Encrypt(_ plain: Data, modulusHex: String, e: Int) -> Data? {
        guard let n = Data(hex: modulusHex) else { return nil }
        var exp = Data()
        var v = e
        while v > 0 { exp.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
        // PKCS#1: SEQUENCE { INTEGER n, INTEGER e }
        let body = derInteger(n) + derInteger(exp)
        let seq = Data([0x30]) + derLen(body.count) + body
        var error: Unmanaged<CFError>?
        guard let secKey = SecKeyCreateWithData(seq as CFData,
                [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary,
                &error) else { return nil }
        guard let enc = SecKeyCreateEncryptedData(secKey, .rsaEncryptionPKCS1,
                plain as CFData, &error) else { return nil }
        return enc as Data
    }

    private static func derInteger(_ v: Data) -> Data {
        var d = v
        while d.count > 1 && d.first == 0 { d.removeFirst() }
        if let f = d.first, f >= 0x80 { d.insert(0, at: 0) }
        if d.count < 128 { return Data([0x02, UInt8(d.count)]) + d }
        return Data([0x02]) + derLen(d.count) + d
    }

    private static func derLen(_ n: Int) -> Data {
        if n < 128 { return Data([UInt8(n)]) }
        var len = n, bytes = Data()
        while len > 0 { bytes.insert(UInt8(len & 0xFF), at: 0); len >>= 8 }
        return Data([UInt8(0x80 | bytes.count)]) + bytes
    }

    // MARK: - 哈希

    static func md5Hex(_ data: Data) -> String {
        Data(Insecure.MD5.hash(data: data)).hex
    }

    static func hmacSha256Hex(key: Data, msg: Data) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: msg, using: SymmetricKey(data: key))
        return Data(mac).hex
    }

    // MARK: - gzip（td 轨迹压缩，RFC1952）

    static func gzip(_ data: Data) -> Data {
        var stream = z_stream()
        let rc = deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8,
                               Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard rc == Z_OK else { return data }  // 理论不达；失败退回原文，verify 失败也不能崩 app
        defer { deflateEnd(&stream) }
        var out = Data()
        var src = [UInt8](data)
        let chunk = 32768
        var dst = [UInt8](repeating: 0, count: chunk)
        var status: Int32 = Z_OK
        let srcCount = src.count
        src.withUnsafeMutableBytes { ip in
            stream.next_in = ip.baseAddress?.assumingMemoryBound(to: UInt8.self)
            stream.avail_in = UInt32(srcCount)
            repeat {
                dst.withUnsafeMutableBytes { op in
                    stream.next_out = op.baseAddress?.assumingMemoryBound(to: UInt8.self)
                    stream.avail_out = UInt32(chunk)
                    status = deflate(&stream, Z_FINISH)
                }
                let produced = chunk - Int(stream.avail_out)
                if produced > 0 { out.append(contentsOf: dst[0..<produced]) }
                // Z_BUF_ERROR（输入耗尽且无进展）或零产出：终止防死循环
                if status != Z_OK || produced == 0 { break }
            } while status == Z_OK
        }
        return out
    }

    // MARK: - 编码工具

    /// base64url 无 padding（对应 Android Base64.URL_SAFE|NO_PADDING|NO_WRAP）
    static func b64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func randHex(_ n: Int) -> String {
        let cs = Array("0123456789abcdef")
        return String((0..<n).map { _ in cs.randomElement()! })
    }

    static func hex(_ data: Data) -> String { data.hex }

    /// Kotlin s.substring(a, b) 语义：[a, b)。越界返回空串（lot_number 异常短时防崩溃）
    static func substring(_ s: String, _ a: Int, _ b: Int) -> String {
        let arr = Array(s)
        guard a >= 0, b <= arr.count, a < b else { return "" }
        return String(arr[a..<b])
    }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }

    init?(hex: String) {
        let h = hex.count % 2 == 1 ? "0" + hex : hex
        var d = Data(capacity: h.count / 2)
        var i = h.startIndex
        while i < h.endIndex {
            guard let b = UInt8(h[i...h.index(after: i)], radix: 16) else { return nil }
            d.append(b)
            i = h.index(i, offsetBy: 2)
        }
        self = d
    }
}
