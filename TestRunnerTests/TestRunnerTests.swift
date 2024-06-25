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
        let app = XCUIApplication()
        app.launchEnvironment["REPORT_BASEURL"] = "http://[::1]:\(port)/junit_report"
        app.launch()

        wait(for: [runtimeUnitTestsExpectation], timeout: 300.0, enforceOrder: true)
    }
}
