import Foundation
import WebKit
import UIKit

// MARK: - 内置浏览器

@MainActor
@Observable
final class BrowserService: NSObject {
    struct Tab: Identifiable {
        let id = UUID()
        var title: String
        var url: URL?
    }

    private(set) var webView: WKWebView
    private(set) var tabs: [Tab] = [Tab(title: "新标签页", url: nil)]
    private(set) var currentTabIndex = 0
    private(set) var isLoading = false

    private var loadContinuation: CheckedContinuation<Void, Error>?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.isInspectable = true
    }

    func open(_ rawURL: String) async throws {
        let normalized = rawURL.hasPrefix("http") ? rawURL : "https://\(rawURL)"
        guard let url = URL(string: normalized) else { throw ToolError.badInput("网址不对：\(rawURL)") }

        isLoading = true
        defer { isLoading = false }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            loadContinuation = continuation
            webView.load(URLRequest(url: url))
            tabs[currentTabIndex].url = url
        }
        tabs[currentTabIndex].title = webView.title ?? url.host ?? "网页"
    }

    func readableText(limit: Int = 8000) async throws -> String {
        let script = """
        (function() {
          const clone = document.body.cloneNode(true);
          clone.querySelectorAll('script,style,noscript,svg').forEach(n => n.remove());
          return (clone.innerText || '').replace(/\\n{3,}/g, '\\n\\n').trim();
        })()
        """
        let value = try await webView.evaluateJavaScript(script)
        let text = (value as? String) ?? ""
        return String(text.prefix(limit))
    }

    func click(selector: String) async throws {
        let escaped = selector.replacingOccurrences(of: "'", with: "\\'")
        let script = """
        (function() {
          const el = document.querySelector('\(escaped)');
          if (!el) return 'not_found';
          el.scrollIntoView({block: 'center'});
          el.click();
          return 'ok';
        })()
        """
        let result = try await webView.evaluateJavaScript(script) as? String
        guard result == "ok" else { throw ToolError.badInput("找不到元素 \(selector)") }
    }

    func type(selector: String, text: String) async throws {
        let escapedSelector = selector.replacingOccurrences(of: "'", with: "\\'")
        let escapedText = text.replacingOccurrences(of: "'", with: "\\'")
        let script = """
        (function() {
          const el = document.querySelector('\(escapedSelector)');
          if (!el) return 'not_found';
          el.focus();
          el.value = '\(escapedText)';
          el.dispatchEvent(new Event('input', {bubbles: true}));
          return 'ok';
        })()
        """
        let result = try await webView.evaluateJavaScript(script) as? String
        guard result == "ok" else { throw ToolError.badInput("找不到输入框 \(selector)") }
    }

    func snapshot() async -> Data? {
        let configuration = WKSnapshotConfiguration()
        configuration.rect = webView.bounds
        let image = try? await webView.takeSnapshot(configuration: configuration)
        return image?.jpegData(compressionQuality: 0.6)
    }

    func goBack() { if webView.canGoBack { webView.goBack() } }

    func newTab() {
        tabs.append(Tab(title: "新标签页", url: nil))
        currentTabIndex = tabs.count - 1
        webView.load(URLRequest(url: URL(string: "about:blank")!))
    }
}

extension BrowserService: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        loadContinuation?.resume()
        loadContinuation = nil
        if let url = webView.url { tabs[currentTabIndex].url = url }
        tabs[currentTabIndex].title = webView.title ?? "网页"
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        loadContinuation?.resume(throwing: error)
        loadContinuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        loadContinuation?.resume(throwing: error)
        loadContinuation = nil
    }
}

// MARK: - 抓网页

@MainActor
final class WebFetchTool: AgentTool {
    var definition: ToolDefinition {
        ToolDefinition(
            name: "web_fetch",
            summary: "抓取一个网页并抽取正文，不执行 JavaScript。",
            surface: .native,
            risk: .safe,
            parameters: .jsonSchema(properties: [
                "url": .stringParam("要抓的网址"),
                "max_chars": .numberParam("最多返回多少字符，默认 8000")
            ], required: ["url"])
        )
    }

    func call(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutcome {
        guard let raw = arguments["url"]?.stringValue else { throw ToolError.badInput("缺少 url") }
        let normalized = raw.hasPrefix("http") ? raw : "https://\(raw)"
        guard let url = URL(string: normalized) else { throw ToolError.badInput("网址不对") }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 27_0 like Mac OS X) pogent/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return .failed("抓取失败：HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        let html = String(data: data, encoding: .utf8) ?? ""
        let text = Self.plainText(from: html)
        let limit = arguments["max_chars"]?.intValue ?? 8000
        return .ok("抓到 \(text.count) 字", payload: .object([
            "url": .string(normalized),
            "bytes": .number(Double(data.count))
        ]), modelText: String(text.prefix(limit)))
    }

    static func plainText(from html: String) -> String {
        var text = html
        text = text.replacingOccurrences(of: "(?is)<script.*?</script>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?is)<style.*?</style>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?is)<(br|/p|/div|/li|/h[1-6])>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?is)<[^>]+>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - 浏览器工具

@MainActor
final class BrowserTool: AgentTool {
    private let browser: BrowserService

    init(browser: BrowserService) { self.browser = browser }

    var definition: ToolDefinition {
        ToolDefinition(
            name: "browser",
            summary: "用内置浏览器打开网页、读正文、点按元素、填表单、截图。带登录态。",
            surface: .native,
            risk: .sensitive,
            parameters: .jsonSchema(properties: [
                "action": .stringParam("open | read | click | type | screenshot"),
                "url": .stringParam("open 时的网址"),
                "selector": .stringParam("CSS 选择器"),
                "text": .stringParam("type 时要填的内容")
            ], required: ["action"])
        )
    }

    func call(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutcome {
        switch arguments["action"]?.stringValue ?? "read" {
        case "open":
            guard let url = arguments["url"]?.stringValue else { throw ToolError.badInput("缺少 url") }
            try await browser.open(url)
            let text = (try? await browser.readableText(limit: 3000)) ?? ""
            return .ok("已打开 \(browser.tabs[browser.currentTabIndex].title)", modelText: String(text.prefix(3000)))
        case "read":
            let text = try await browser.readableText()
            return .ok("读到 \(text.count) 字", modelText: text)
        case "click":
            guard let selector = arguments["selector"]?.stringValue else { throw ToolError.badInput("缺少 selector") }
            try await browser.click(selector: selector)
            try? await Task.sleep(for: .milliseconds(600))
            let text = (try? await browser.readableText(limit: 2000)) ?? ""
            return .ok("已点按 \(selector)", modelText: String(text.prefix(2000)))
        case "type":
            guard let selector = arguments["selector"]?.stringValue,
                  let text = arguments["text"]?.stringValue else {
                throw ToolError.badInput("需要 selector 和 text")
            }
            try await browser.type(selector: selector, text: text)
            return .ok("已填 \(selector)")
        case "screenshot":
            let data = await browser.snapshot()
            return .ok("已截图", payload: .object([
                "image_base64": .string(data?.base64EncodedString() ?? "")
            ]))
        default:
            throw ToolError.badInput("未知 action")
        }
    }
}
