import XCTest

class TestRunnerTests: XCTestCase {
    private let port = 63846
    private var loop: EventLoop!
    private var server: HTTPServer!
    private var runtimeUnitTestsExpectation: XCTestExpectation!

    override func setUp() {
        continueAfterFailure = false

        // Standalone (not via self.expectation(...)) so we can drive it through
        // XCTWaiter alongside the crash watchdog without tripping the
        // XCTestCase "must waitForExpectations" rule.
        runtimeUnitTestsExpectation = XCTestExpectation(description: "Jasmine tests")

        loop = try! SelectorEventLoop(selector: try! KqueueSelector())
        self.server = DefaultHTTPServer(eventLoop: loop!, port: port) {
            (
                environ: [String: Any],
                startResponse: @escaping ((String, [(String, String)]) -> Void),
                sendBody: @escaping ((Data) -> Void)
            ) in

            let method: String? = environ["REQUEST_METHOD"] as! String?
            if method != "POST" {
                XCTFail("invalid request method")
                startResponse("204 No Content", [])
                sendBody(Data())
                self.runtimeUnitTestsExpectation.fulfill()
            } else {
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
            }
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
        app.launchEnvironment["REPORT_BASEURL"] = "http://[::1]:\(port)/junit_report"
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
                XCTFail("TestRunner exited before reporting Jasmine results (likely crashed). Check ~/Library/Logs/DiagnosticReports/TestRunner-*.ips for the stack.")
            }
            return
        case .timedOut:
            XCTFail("Asynchronous wait failed: exceeded \(Int(jasmineTestsTimeout)) seconds with unfulfilled \"Jasmine tests\" expectation")
        default:
            XCTFail("Unexpected XCTWaiter result: \(result.rawValue)")
        }
    }
}
