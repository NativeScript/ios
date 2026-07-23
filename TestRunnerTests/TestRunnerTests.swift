import XCTest

class TestRunnerTests: XCTestCase {
    private let port = 63846
    private var loop: EventLoop!
    private var server: HTTPServer!
    private var runtimeUnitTestsExpectation: XCTestExpectation!

    // Most recent spec reported by the in-app Jasmine progress beacon (see the
    // /progress handler below). When the suite hangs and never POSTs results,
    // this names the spec that was running when the JS thread stalled.
    private let progressLock = NSLock()
    private var lastSpecSeen = "(no spec reported yet)"

    override func setUp() {
        continueAfterFailure = false

        // Standalone (not via self.expectation(...)) so we can drive it through
        // XCTWaiter alongside the crash watchdog without tripping the
        // XCTestCase "must waitForExpectations" rule.
        runtimeUnitTestsExpectation = XCTestExpectation(description: "Jasmine tests")

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

            // Progress beacon from the in-app Jasmine reporter (fire-and-forget):
            // records the spec currently running so a hang/timeout can report
            // where the JS suite stalled, even though no JUnit report is POSTed.
            if method == "GET" && path == "/progress" {
                if let specParam = query
                    .split(separator: "&")
                    .first(where: { $0.hasPrefix("spec=") }) {
                    let raw = String(specParam.dropFirst("spec=".count))
                    let decoded = raw.removingPercentEncoding ?? raw
                    self.progressLock.lock()
                    self.lastSpecSeen = decoded
                    self.progressLock.unlock()
                }
                startResponse("204 No Content", [])
                sendBody(Data())
                return
            }

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
                    // Delay the response WITHOUT blocking the event loop. A
                    // Thread.sleep here runs on the server's single event-loop
                    // thread and WEDGES it: the loader's ~5s client timeout fires
                    // first, the client resets the connection, and the blocked
                    // loop never recovers — so every later module fetch fails with
                    // "could not connect" and the whole HTTP-ESM suite times out.
                    // Schedule the response on the loop instead; the loader still
                    // hits its client-side timeout because delayMs (6500) exceeds
                    // the request timeout, and the server stays responsive.
                    var delayMs = 6500
                    if let pair = query
                        .split(separator: "&")
                        .first(where: { $0.hasPrefix("delayMs=") }),
                       let v = Int(pair.split(separator: "=").last ?? "") {
                        delayMs = v
                    }
                    self.loop.call(withDelay: Double(delayMs) / 1000.0) {
                        let nowMs = Int(Date().timeIntervalSince1970 * 1000.0)
                        let body = "export const evaluatedAt = \(nowMs); export default { evaluatedAt };"
                        startResponse("200 OK", [("Content-Type", "application/javascript; charset=utf-8")])
                        sendBody(body.data(using: .utf8) ?? Data())
                    }
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
        // Headroom for CI: some specs (HttpEsmLoaderTests, RemoteModuleSecurityTests)
        // perform live network I/O against intentionally-unreachable/slow hosts
        // (e.g. 192.0.2.1 timeout-test, esm.sh). Each can burn up to NSURLSession's
        // ~60s request timeout, so under slower CI networks the full suite can run
        // past a 300s budget and never POST results -> false timeout. 600s avoids
        // that while still failing fast on a genuine hang.
        let jasmineTestsTimeout: TimeInterval = 600

        let app = XCUIApplication()
        app.launchEnvironment["REPORT_BASEURL"] = "http://127.0.0.1:\(port)/junit_report"
        app.launch()

        // Watchdog: if the runtime crashes (e.g. EXC_BAD_ACCESS) it never
        // POSTs results, and a plain `wait(for:)` would sit out the full
        // timeout. Fulfill the same expectation from the watchdog when the
        // app process leaves the running state, and track the crash via a
        // flag so we can still distinguish the two outcomes after the wait.
        var didCrash = false
        let crashWatchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            if app.state == .notRunning {
                didCrash = true
                self.runtimeUnitTestsExpectation.fulfill()
            }
        }
        // The XCUITest run loop spins in default mode during wait(for:); add
        // the timer to common modes too in case anything switches it.
        RunLoop.main.add(crashWatchdog, forMode: .common)

        let result = XCTWaiter().wait(
            for: [runtimeUnitTestsExpectation],
            timeout: jasmineTestsTimeout
        )
        crashWatchdog.invalidate()

        switch result {
        case .completed:
            if didCrash {
                XCTFail("TestRunner exited before reporting Jasmine results (the runtime CRASHED). Check the 'test-diagnostics' artifact (DiagnosticReports/TestRunner-*.ips) for the native stack.")
            }
            return
        case .timedOut:
            progressLock.lock()
            let lastSpec = lastSpecSeen
            progressLock.unlock()
            XCTFail("Ran past \(Int(jasmineTestsTimeout))s with the \"Jasmine tests\" expectation unfulfilled while the app was STILL RUNNING -> the JS suite HUNG (deadlock or never-settled async); it did not crash. Last spec reported by the in-app beacon: \"\(lastSpec)\". Also see the 'test-diagnostics' artifact (simulator.logarchive).")
        default:
            XCTFail("Unexpected XCTWaiter result: \(result.rawValue)")
        }
    }
}
