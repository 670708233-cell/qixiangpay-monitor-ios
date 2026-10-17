import Foundation

/// 七星支付协议客户端：csrf→滑块→login→user_token→orderList。
/// 与 Android 版 ApiClient.kt 行为对齐：手动 cookie jar、手动重定向（截获每跳 Set-Cookie）、登录态持久化。
enum ApiClient {

    static let BASE = "https://qixiangpay.cn"
    /// 与 Android 版同 UA，减少服务端风控变量
    static let UA = "Mozilla/5.0 (Linux; Android 13; Pixel 6) AppleWebKit/537.36" +
        " (KHTML, like Gecko) Chrome/155.0.0.0 Mobile Safari/537.36"

    static var log: ((String) -> Void)?
    private static func L(_ s: String) { log?(s) }

    /// 实际会话主机：apex 404（CDN 边缘差异）时切 www
    static var BASE_EFF = BASE

    private static var cookies: [String: String] = [:]
    private static let jarLock = NSLock()
    private static let defaults = UserDefaults.standard

    /// 手动跟随重定向的 session（delegate 把 30x 截停）
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.httpShouldSetCookies = false
        return URLSession(configuration: cfg, delegate: RedirectStopper(), delegateQueue: nil)
    }()

    private final class RedirectStopper: NSObject, URLSessionDataDelegate {
        func urlSession(_ s: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil) // 手动跟随，便于截获中间跳的 Set-Cookie
        }
    }

    // MARK: - 登录态持久化（对应 Android sess.xml）

    static func persistCookies() {
        jarLock.lock(); defer { jarLock.unlock() }
        defaults.set(cookies, forKey: "sess_cookies")
        L("[auth] 登录态已缓存: \(cookies.keys.sorted().joined(separator: ","))")
    }

    @discardableResult
    static func restoreCookies() -> Bool {
        jarLock.lock(); defer { jarLock.unlock() }
        if !cookies.isEmpty { return true }
        guard let j = defaults.dictionary(forKey: "sess_cookies") as? [String: String],
              !j.isEmpty, j["user_token"] != nil else { return false }
        cookies = j
        L("[auth] 使用缓存登录态 user_token=\(String((j["user_token"] ?? "").prefix(16)))..")
        return true
    }

    static func resetSession() {
        jarLock.lock(); defer { jarLock.unlock() }
        cookies.removeAll()
        defaults.removeObject(forKey: "sess_cookies")
    }

    static func hasToken() -> Bool {
        jarLock.lock(); defer { jarLock.unlock() }
        return cookies["user_token"] != nil
    }

    static func tokenPreview() -> String {
        jarLock.lock(); defer { jarLock.unlock() }
        return String((cookies["user_token"] ?? "").prefix(16))
    }

    // MARK: - HTTP

    @discardableResult
    private static func req(_ urlStr: String, method: String = "GET",
                            form: [String: String]? = nil, ajax: Bool = false) -> String {
        var url = urlStr
        var m = method
        var body = form
        for _ in 0..<6 {
            guard let u = URL(string: url) else { return "" }
            var r = URLRequest(url: u)
            r.httpMethod = m
            r.timeoutInterval = 20
            r.setValue(UA, forHTTPHeaderField: "User-Agent")
            r.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
                       forHTTPHeaderField: "Accept") // WAF 铁律：无 Accept 一律 404
            r.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
            jarLock.lock()
            if !cookies.isEmpty {
                r.setValue(cookies.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; "),
                           forHTTPHeaderField: "Cookie")
            }
            jarLock.unlock()
            if ajax {
                r.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
                r.setValue("\(BASE_EFF)/user/login.php", forHTTPHeaderField: "Referer")
                r.setValue(BASE, forHTTPHeaderField: "Origin")
            }
            if let b = body, m == "POST" {
                r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                r.httpBody = formEncode(b).data(using: .utf8)
            }
            guard let (data, resp) = try? sessionSync(r) else { return "" }
            let http = resp as? HTTPURLResponse
            absorbCookies(resp, url: u)
            let code = http?.statusCode ?? 0
            if code >= 400 {
                L("[http] \(code) \(m) \(url)")
            }
            if (301...308).contains(code) {
                guard let loc = http?.value(forHTTPHeaderField: "Location") else { return "" }
                url = URL(string: loc, relativeTo: u)?.absoluteString ?? ""
                m = "GET"; body = nil
                continue
            }
            return String(data: data, encoding: .utf8) ?? ""
        }
        return ""
    }

    static func sessionSync(_ r: URLRequest) throws -> (Data, URLResponse) {
        var d: Data!; var resp: URLResponse!; var err: Error!
        let sem = DispatchSemaphore(value: 0)
        session.dataTask(with: r) { a, b, c in d = a; resp = b; err = c; sem.signal() }.resume()
        sem.wait()
        if let e = err { throw e }
        return (d, resp)
    }

    private static func absorbCookies(_ resp: URLResponse, url: URL) {
        guard let http = resp as? HTTPURLResponse else { return }
        let list = HTTPCookie.cookies(withResponseHeaderFields: http.allHeaderFields as? [String: String] ?? [:], for: url)
        jarLock.lock(); defer { jarLock.unlock() }
        for c in list where c.value != "deleted" {
            cookies[c.name] = c.value
        }
    }

    private static func formEncode(_ form: [String: String]) -> String {
        form.map { k, v -> String in
            let ek = k.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? k
            let ev = v.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? v
            return "\(ek)=\(ev)"
        }.joined(separator: "&")
    }

    // MARK: - 业务

    /// 登录页取 csrf_token（同时种 PHPSESSID）。apex 失败自动切 www
    static func getCsrf() throws -> String {
        let re = try NSRegularExpression(pattern: "name=\"csrf_token\"\\s+value=\"([0-9a-f]+)\"")
        for host in [BASE, "https://www.qixiangpay.cn"] {
            let html = req("\(host)/user/login.php")
            if let m = re.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let rg = Range(m.range(at: 1), in: html) {
                BASE_EFF = host
                return String(html[rg])
            }
            L("[http] \(host) 无 csrf，尝试镜像域名")
        }
        BASE_EFF = BASE
        throw RuntimeError("csrf_token 未找到（apex+www 均失败）")
    }

    /// 登录：seccode 四元组 + 账密。成功把 user_token 写入 jar 并缓存
    static func login(user: String, pass: String, csrf: String, sec: Gt4Solver.Seccode) -> Bool {
        let txt = req("\(BASE_EFF)/user/ajaxa.php?act=login", method: "POST", form: [
            "type": "1", "user": user, "pass": pass, "csrf_token": csrf,
            "captcha_id": sec.captchaId, "lot_number": sec.lotNumber,
            "pass_token": sec.passToken, "gen_time": sec.genTime,
            "captcha_output": sec.captchaOutput,
        ], ajax: true)
        L("[login] \(txt)")
        guard let j = try? JSONSerialization.jsonObject(with: Data(txt.utf8)) as? [String: Any] else { return false }
        let ok = (j["code"] as? Int) == 0
        if ok { persistCookies() }
        return ok
    }

    /// 已支付订单列表。失败（未登录等）抛异常由调用方处理
    static func orderList(dstatus: String, page: String, limit: String) throws -> [String: Any] {
        let txt = req("\(BASE_EFF)/user/ajax2.php?act=orderList", method: "POST", form: [
            "paytype": "0", "dstatus": dstatus, "page": page, "limit": limit,
        ], ajax: true)
        guard let j = try? JSONSerialization.jsonObject(with: Data(txt.utf8)) as? [String: Any] else {
            throw RuntimeError("orderList 非法响应: \(txt.prefix(120))")
        }
        return j
    }
}
