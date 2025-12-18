import XCTest

class TestRunnerTests: XCTestCase {
    private let port = 63846
    private var loop: EventLoop!
    private var server: HTTPServer!
    private var runtimeUnitTestsExpectation: XCTestExpectation!

    override func setUp() {
        continueAfterFailure = false

        runtimeUnitTestsExpectation = self.expectation(description: "Jasmine tests")

        loop = try! SelectorEventLoop(selector: try! KqueueSelector())
        self.server = DefaultHTTPServer(eventLoop: loop!, interface: "127.0.0.1", port: port) {
            (
                environ: [String: Any],
                startResponse: @escaping ((String, [(String, String)]) -> Void),
                sendBody: @escaping ((Data) -> Void)
            ) in
            let method = (environ["REQUEST_METHOD"] as? String) ?? ""
            let path = (environ["PATH_INFO"] as? String) ?? "/"
            let query = (environ["QUERY_STRING"] as? String) ?? ""

            // Serve tiny ESM modules for runtime HTTP loader tests.
            if method == "GET" {
                if path == "/esm/query.mjs" || path == "/ns/m/query.mjs" {
                    func jsStringLiteral(_ s: String) -> String {
                        return s
                            .replacingOccurrences(of: "\\", with: "\\\\")
                            .replacingOccurrences(of: "\"", with: "\\\"")
                            .replacingOccurrences(of: "\n", with: "\\n")
                            .replacingOccurrences(of: "\r", with: "\\r")
                    }
                    let nowMs = Int(Date().timeIntervalSince1970 * 1000.0)
                    let body = """
                    export const path = \"\(jsStringLiteral(path))\";
                    export const query = \"\(jsStringLiteral(query))\";
                    export const evaluatedAt = \(nowMs);
                    export default { path, query, evaluatedAt };
                    """
                    startResponse("200 OK", [("Content-Type", "application/javascript; charset=utf-8")])
                    sendBody(body.data(using: .utf8) ?? Data())
                    return
                }

                if path == "/esm/timeout.mjs" {
                    // Intentionally delay the response so the runtime HTTP loader hits its request timeout.
                    // This avoids ATS issues from testing against external plain-http URLs.
                    var delayMs = 6500
                    if let pair = query
                        .split(separator: "&")
                        .first(where: { $0.hasPrefix("delayMs=") }),
                       let v = Int(pair.split(separator: "=").last ?? "") {
                        delayMs = v
                    }
                    Thread.sleep(forTimeInterval: Double(delayMs) / 1000.0)

                    let nowMs = Int(Date().timeIntervalSince1970 * 1000.0)
                    let body = "export const evaluatedAt = \(nowMs); export default { evaluatedAt };"
                    startResponse("200 OK", [("Content-Type", "application/javascript; charset=utf-8")])
                    sendBody(body.data(using: .utf8) ?? Data())
                    return
                }

                // HMR hot.data test modules – serve the same helper code for .mjs and .js variants
                if path == "/esm/hmr/hot-data-ext.mjs" || path == "/esm/hmr/hot-data-ext.js" {
                    let body = """
                    // HMR hot.data test module (served by XCTest)
                    export function getHot() {
                        return (typeof import.meta !== "undefined" && import.meta) ? import.meta.hot : undefined;
                    }
                    export function getHotData() {
                        const hot = getHot();
                        return hot ? hot.data : undefined;
                    }
                    export function setHotValue(value) {
                        const hot = getHot();
                        if (!hot || !hot.data) { throw new Error("import.meta.hot.data is not available"); }
                        hot.data.value = value;
                        return hot.data.value;
                    }
                    export function getHotValue() {
                        const hot = getHot();
                        return hot && hot.data ? hot.data.value : undefined;
                    }
                    export function testHotApi() {
                        const hot = getHot();
                        const result = {
                            ok: false,
                            hasHot: !!hot,
                            hasData: !!(hot && hot.data),
                            hasAccept: !!(hot && typeof hot.accept === "function"),
                            hasDispose: !!(hot && typeof hot.dispose === "function"),
                            hasDecline: !!(hot && typeof hot.decline === "function"),
                            hasInvalidate: !!(hot && typeof hot.invalidate === "function"),
                            pruneIsFalse: !!(hot && hot.prune === false),
                        };
                        try {
                            if (hot && typeof hot.accept === "function") { hot.accept(function () {}); }
                            if (hot && typeof hot.dispose === "function") { hot.dispose(function () {}); }
                            if (hot && typeof hot.decline === "function") { hot.decline(); }
                            if (hot && typeof hot.invalidate === "function") { hot.invalidate(); }
                            result.ok = result.hasHot && result.hasData && result.hasAccept && result.hasDispose && result.hasDecline && result.hasInvalidate && result.pruneIsFalse;
                        } catch (e) {
                            result.error = String(e);
                        }
                        return result;
                    }
                    console.log("HMR hot.data ext module loaded (via XCTest server)");
                    """
                    startResponse("200 OK", [("Content-Type", "application/javascript; charset=utf-8")])
                    sendBody(body.data(using: .utf8) ?? Data())
                    return
                }

                startResponse("404 Not Found", [("Content-Type", "text/plain; charset=utf-8")])
                sendBody(Data("Not Found".utf8))
                return
            }

            // Collect Jasmine JUnit report.
            if method == "POST" && path == "/junit_report" {
                var buffer = Data()
                let input = environ["swsgi.input"] as! SWSGIInput
                var finished = false
                input { data in
                    buffer.append(data)
                    if data.isEmpty && !finished {
                        finished = true

                        let report = XCTAttachment(uniformTypeIdentifier: "junit.xml", name: "junit.xml", payload: buffer, userInfo: nil)
                        report.lifetime = .keepAlways
                        self.add(report)

                        startResponse("204 No Content", [])
                        sendBody(Data())
                        self.runtimeUnitTestsExpectation.fulfill()
                    }
                }
                return
            }

            startResponse("404 Not Found", [("Content-Type", "text/plain; charset=utf-8")])
            sendBody(Data("Not Found".utf8))
        }

        try! server.start()

        DispatchQueue.global(qos: .background).async {
            self.loop.runForever()
        }
    }

    override func tearDown() {
        server.stopAndWait()
        loop.stop()
    }

    func testRuntime() {
        let app = XCUIApplication()
        app.launchEnvironment["REPORT_BASEURL"] = "http://127.0.0.1:\(port)/junit_report"
        app.launch()

        wait(for: [runtimeUnitTestsExpectation], timeout: 300.0, enforceOrder: true)
    }
}
