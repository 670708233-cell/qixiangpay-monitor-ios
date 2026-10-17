import Foundation
import UIKit

/// GeeTest v4 滑块纯协议求解器（iOS 版）。
/// 算法与 Android 版 Gt4Solver.kt 逐位对齐：load→缺口检测→轨迹生成→w 加密→verify。
enum Gt4Solver {

    static var log: ((String) -> Void)?
    private static func L(_ s: String) { log?(s) }

    private static let GT = "https://gcaptcha4.geetest.com"
    private static let STATIC = "https://static.geetest.com/"
    static let CID = "8b13c2396479db80a1523c8bc89e22f4"

    /// 1024bit 模数（浏览器 hook 实捕，服务端验收 score=1）
    private static let RSA_N =
        "00C1E3934D1614465B33053E7F48EE4EC87B14B95EF88947713D25EECBFF7E74C7977D02DC1D9451F79DD5D1C10C29ACB6A9B4D6FB7D0A0279B6719E1772565F09AF627715919221AEF91899CAE08C0D686D748B20A3603BE2318CA6BC2B59706592A9219D0BF05C9F65023A21D2330807252AE0066D59CEEFA5F2748EA80BAB81"
    private static let SCALE = 1.0059466666666665

    struct Seccode {
        let captchaId: String, lotNumber: String, passToken: String, genTime: String, captchaOutput: String
    }

    private struct LoadResp {
        let lot: String, payload: String, processToken: String
        let powDatetime: String, bgUrl: String, sliceUrl: String
    }

    /// 完整求解：load→下载→检测→尝试→verify。成功返回 Seccode，失败 nil。
    static func solve() -> Seccode? {
        do {
            let lr = try load()
            L("[gt4] lot=\(String(lr.lot.prefix(12)))..")
            let bg = try httpData(STATIC + lr.bgUrl)
            let sl = try httpData(STATIC + lr.sliceUrl)
            guard let base = detectGap(bg: bg, sl: sl) else {
                L("[gt4] 缺口检测失败")
                return nil
            }
            L("[gt4] 检测 setLeft≈\(base)")
            var payload = lr.payload
            var ptk = lr.processToken
            for d in [2, 0, 4, 6, -2, 8] {
                let sl2 = base + d
                let v = try verify(lot: lr.lot, payload: payload, ptk: ptk,
                                   powDatetime: lr.powDatetime, setLeft: sl2)
                guard let data = v["data"] as? [String: Any] else { continue }
                if (data["result"] as? String) == "success" {
                    L("[gt4] verify SUCCESS setLeft=\(sl2) score=\(data["score"] as? String ?? "")")
                    guard let sec = data["seccode"] as? [String: Any] else { return nil }
                    return Seccode(
                        captchaId: sec["captcha_id"] as? String ?? "",
                        lotNumber: sec["lot_number"] as? String ?? "",
                        passToken: sec["pass_token"] as? String ?? "",
                        genTime: sec["gen_time"] as? String ?? "",
                        captchaOutput: sec["captcha_output"] as? String ?? "")
                }
                L("[gt4] fail(setLeft=\(sl2)) fc=\(data["fail_count"] as? Int ?? 0)")
                if let p = data["payload"] as? String, !p.isEmpty { payload = p }
                if let t = data["process_token"] as? String, !t.isEmpty { ptk = t }
                Thread.sleep(forTimeInterval: 0.8)
            }
            return nil
        } catch {
            L("[gt4] 异常: \(error)")
            return nil
        }
    }

    // MARK: - 协议

    /// JSONP 剥壳：cb({...}) → {...}
    private static func jsonp(_ body: String, _ cb: String) -> String {
        guard let r = body.range(of: "\(cb)(") else { return body }
        var s = String(body[r.upperBound...])
        if s.hasSuffix(")") { s.removeLast() }
        return s
    }

    private static func load() throws -> LoadResp {
        let cb = "geetest_\(Int64(Date().timeIntervalSince1970 * 1000))"
        let qs = "/load?callback=\(cb)&captcha_id=\(CID)&challenge=\(UUID().uuidString)" +
                 "&client_type=web&risk_type=slide&lang=en-us"
        let body = try String(data: httpData(GT + qs), encoding: .utf8) ?? ""
        let json = jsonp(body, cb)
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let d = obj["data"] as? [String: Any],
              let lot = d["lot_number"] as? String else {
            throw RuntimeError("load 解析失败")
        }
        let pow = d["pow_detail"] as? [String: Any]
        return LoadResp(
            lot: lot,
            payload: d["payload"] as? String ?? "",
            processToken: d["process_token"] as? String ?? "",
            powDatetime: pow?["datetime"] as? String ?? "",
            bgUrl: d["bg"] as? String ?? "",
            sliceUrl: d["slice"] as? String ?? "")
    }

    private static func verify(lot: String, payload: String, ptk: String,
                               powDatetime: String, setLeft: Int) throws -> [String: Any] {
        let td = makeTd(setLeft: setLeft)
        let w = buildW(setLeft: setLeft, lot: lot, powDatetime: powDatetime, tdB64: td.b64, passtime: td.passtime)
        let cb = "geetest_\(Int64(Date().timeIntervalSince1970 * 1000))"
        let qs = "/verify?callback=\(cb)&captcha_id=\(CID)&client_type=web&lot_number=\(lot)" +
                 "&payload=\(payload)&process_token=\(ptk)&payload_protocol=1&pt=1&w=\(w)&td=\(td.b64)"
        let body = try String(data: httpData(GT + qs), encoding: .utf8) ?? ""
        let json = jsonp(body, cb)
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw RuntimeError("verify 解析失败")
        }
        return obj
    }

    // MARK: - 轨迹（td）

    private static func makeTd(setLeft: Int) -> (b64: String, passtime: Int) {
        let bgW = 300.03125
        let x0r = 0.1333 + (Double.random(in: -0.5...0.5) * 0.008)
        let y0r = 0.8909 + (Double.random(in: -0.5...0.5) * 0.006)
        let s = Int64(Date().timeIntervalSince1970 * 1000)
        let steps = 16 + Int.random(in: 0..<9)
        var pts = ""
        func pt(_ t: Int, _ x: Double, _ y: Double, _ st: Int) {
            if !pts.isEmpty { pts += "," }
            pts += "[\(t),\(String(format: "%.4f", x)),\(String(format: "%.4f", y)),\(st)]"
        }
        pt(0, x0r, y0r, 0); pt(0, x0r, y0r, 3)
        var t = 0
        for i in 1...steps {
            let f = Double(i) / Double(steps)
            let ease = f < 0.85 ? f * f * (3 - 2 * f) * 1.02 : 1.02 - 0.02 * ((f - 0.85) / 0.15)
            t += 18 + Int.random(in: 0..<24)
            pt(t, min(0.96, x0r + (Double(setLeft) / bgW) * ease), y0r + (Double.random(in: -0.5...0.5) * 0.008), 1)
        }
        t += 2 + Int.random(in: 0..<4)
        pt(t, min(0.96, x0r + Double(setLeft) / bgW), y0r, 2)
        let json = "{\"m\":1,\"w\":\(bgW),\"h\":261.53125,\"s\":\(s),\"e\":\(s + Int64(t)),\"p\":[\(pts)]}"
        let gz = Crypto.gzip(Data(json.utf8))
        return (Crypto.b64url(gz), t)
    }

    // MARK: - w 生成（payload 手工按序拼接 → AES+RSA）

    private static func buildW(setLeft: Int, lot: String, powDatetime: String, tdB64: String, passtime: Int) -> String {
        let key = Crypto.randHex(16)
        let powTail = Crypto.randHex(16)
        let powMsg = "1|0|md5|\(powDatetime)|\(CID)|\(lot)||\(powTail)"
        let powSign = Crypto.md5Hex(Data(powMsg.utf8))
        let tdSign = Crypto.hmacSha256Hex(key: Data(lot.utf8), msg: Data(tdB64.utf8))
        let ur = Double(setLeft) / SCALE + 2
        let hp1 = Crypto.randHex(2).uppercased() + Crypto.randHex(2)
        let hp2v = Crypto.randHex(2).uppercased() + Crypto.randHex(2)

        var p = ""
        p += "{\"setLeft\":\(setLeft)"
        p += ",\"passtime\":\(passtime)"
        p += ",\"userresponse\":\(ur)"
        p += ",\"device_id\":\"\""
        p += ",\"lot_number\":\"\(lot)\""
        p += ",\"pow_msg\":\"\(powMsg)\""
        p += ",\"pow_sign\":\"\(powSign)\""
        p += ",\"geetest\":\"captcha\""
        p += ",\"lang\":\"zh\""
        p += ",\"ep\":\"123\""
        p += ",\"biht\":\"1426265548\""
        p += ",\"\(hp1)\":\"\(hp2v)\""
        p += ",\"\(Crypto.substring(lot, 12, 20))\":{\"\(Crypto.substring(lot, 16, 24))\":\"\(Crypto.substring(lot, 22, 28))\"}"
        p += ",\"em\":{\"ph\":0,\"cp\":0,\"ek\":\"11\",\"wd\":1,\"nt\":0,\"si\":0,\"sc\":0}"
        p += ",\"td_sign\":\"\(tdSign)\"}"

        guard let aes = Crypto.aesCbcPkcs7Encrypt(Data(p.utf8), key: Data(key.utf8),
                                                  iv: Data("0000000000000000".utf8)) else { return "" }
        let aesHex = aes.hex
        guard let rsa = Crypto.rsaPkcs1Encrypt(Data(key.utf8), modulusHex: RSA_N, e: 65537) else { return "" }
        var rsaHex = rsa.hex
        if rsaHex.count % 2 == 1 { rsaHex = "0" + rsaHex }
        return aesHex + rsaHex
    }

    // MARK: - 缺口检测（绝对暗度阈值形状 IoU，与 Android 版同参数）

    static func detectGap(bg: Data, sl: Data) -> Int? {
        guard let bgImg = UIImage(data: bg)?.cgImage, let slImg = UIImage(data: sl)?.cgImage else { return nil }
        guard let bgPx = rgba(bgImg), let slPx = rgba(slImg) else { return nil }
        let W = bgPx.w, H = bgPx.h
        var vArr = [UInt8](repeating: 0, count: W * H)
        for y in 0..<H { for x in 0..<W {
            let i = (y * W + x) * 4
            vArr[y * W + x] = max(bgPx.data[i], bgPx.data[i + 1], bgPx.data[i + 2])
        } }
        // 中位数
        var hist = [Int](repeating: 0, count: 256)
        for v in vArr { hist[Int(v)] += 1 }
        var acc = 0, med = 128
        let total = W * H
        for i in 0...255 { acc += hist[i]; if acc >= total / 2 { med = i; break } }

        // slice alpha 掩码及 bbox
        let sw = slPx.w, sh = slPx.h
        var x0 = sw, x1 = -1, y0 = sh, y1 = -1
        var alpha = [Bool](repeating: false, count: sw * sh)
        for y in 0..<sh { for x in 0..<sw {
            if slPx.data[(y * sw + x) * 4 + 3] > 60 {
                alpha[y * sw + x] = true
                if x < x0 { x0 = x }; if x > x1 { x1 = x }
                if y < y0 { y0 = y }; if y > y1 { y1 = y }
            }
        } }
        if x1 < 0 { return nil }
        let aw = x1 - x0 + 1, ah = y1 - y0 + 1
        // 关键防御：slice bbox 超出背景图尺寸时 0...(H-ah) 会 fatalError（catch 接不住）
        guard ah >= 1, aw >= 1, H >= ah, W >= aw else {
            L("[gt4] 尺寸异常 bg=\(W)x\(H) slice_bbox=\(aw)x\(ah)（跳过本轮）")
            return nil
        }
        var area = 0
        var am = [[Bool]](repeating: [Bool](repeating: false, count: aw), count: ah)
        for r in 0..<ah { for c in 0..<aw {
            am[r][c] = alpha[(y0 + r) * sw + x0 + c]
            if am[r][c] { area += 1 }
        } }

        var bestIou = 0.0, bestDx = 0
        for thrOff in [60, 80, 100] {
            let thr = med - thrOff
            if thr < 40 { continue }
            // dark + erode 2x2
            var dark = [Bool](repeating: false, count: W * H)
            for y in 0..<H { for x in 0..<W { dark[y * W + x] = Int(vArr[y * W + x]) < thr } }
            var ero = [Bool](repeating: false, count: W * H)
            for y in 0..<(H - 1) { for x in 0..<(W - 1) {
                ero[y * W + x] = dark[y * W + x] && dark[y * W + x + 1] && dark[(y + 1) * W + x] && dark[(y + 1) * W + x + 1]
            } }
            // integral image
            var sat = [Int](repeating: 0, count: (W + 1) * (H + 1))
            for y in 0..<H {
                var rowSum = 0
                for x in 0..<W {
                    rowSum += ero[y * W + x] ? 1 : 0
                    sat[(y + 1) * (W + 1) + x + 1] = sat[y * (W + 1) + x + 1] + rowSum
                }
            }
            func rectSum(_ rx: Int, _ ry: Int, _ rw: Int, _ rh: Int) -> Int {
                let x2 = rx + rw, y2 = ry + rh
                return sat[y2 * (W + 1) + x2] - sat[ry * (W + 1) + x2] - sat[y2 * (W + 1) + rx] + sat[ry * (W + 1) + rx]
            }
            for dy in 0...(H - ah) { for dx in 0...(W - aw) {
                let inter = rectSum(dx, dy, aw, ah)
                if inter > area / 2 {
                    let iou = Double(inter) / Double(area)
                    if iou > bestIou { bestIou = iou; bestDx = dx }
                }
            } }
        }
        L("[gt4] IoU=\(String(format: "%.3f", bestIou)) at(\(bestDx),-) med=\(med)")
        return bestDx - x0
    }

    // MARK: - 工具

    struct Px { let data: [UInt8]; let w: Int; let h: Int }

    private static func rgba(_ cg: CGImage) -> Px? {
        let w = cg.width, h = cg.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ok = data.withUnsafeMutableBytes { p -> Bool in
            guard let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? Px(data: data, w: w, h: h) : nil
    }

    private static func httpData(_ urlStr: String) throws -> Data {
        guard let url = URL(string: urlStr) else { throw RuntimeError("bad url") }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue(ApiClient.UA, forHTTPHeaderField: "User-Agent")
        req.setValue("https://qixiangpay.cn/", forHTTPHeaderField: "Referer")
        let (data, resp) = try ApiClient.sessionSync(req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw RuntimeError("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1) \(urlStr)")
        }
        return data
    }
}

struct RuntimeError: Error { let message: String; init(_ m: String) { message = m } }
