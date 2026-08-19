import XCTest
@testable import Recorder

private final class FakePipe {
    let name: String
    init(name: String) { self.name = name }
}

@MainActor
private final class Counter {
    private var current = 0
    private(set) var maxConcurrent = 0
    func enter() { current += 1; maxConcurrent = max(maxConcurrent, current) }
    func leave() { current -= 1 }
}

@MainActor
final class ModelHostTests: XCTestCase {

    private func makeHost(
        onDisk: Set<String> = [],
        failLoadFor: Set<String> = [],
        progress: [Double] = []
    ) -> ModelHost<FakePipe> {
        ModelHost<FakePipe>(
            isDownloaded: { onDisk.contains($0) },
            download: { name, report in
                for value in progress { report(value) }
                return URL(fileURLWithPath: "/tmp/\(name)")
            },
            load: { name, _ in
                if failLoadFor.contains(name) {
                    throw NSError(
                        domain: "test", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "boom"]
                    )
                }
                return FakePipe(name: name)
            }
        )
    }

    func testStartsUnloaded() {
        let host = makeHost()
        XCTAssertEqual(host.state, .unloaded)
        XCTAssertNil(host.loadedModel)
    }

    func testReportsNotDownloadedWhenMissingAndDownloadNotAllowed() async {
        let host = makeHost()
        await host.loadModel("tiny", downloadIfNeeded: false)
        XCTAssertEqual(host.state, .notDownloaded("tiny"))
        XCTAssertNil(host.loadedModel)
    }

    func testLoadsAModelAlreadyOnDisk() async {
        let host = makeHost(onDisk: ["base"])
        await host.loadModel("base", downloadIfNeeded: false)
        XCTAssertEqual(host.state, .ready)
        XCTAssertEqual(host.loadedModel, "base")
    }

    func testDownloadsThenLoadsWhenAllowed() async {
        let host = makeHost(progress: [0.5, 1.0])
        await host.loadModel("large", downloadIfNeeded: true)
        XCTAssertEqual(host.state, .ready)
        XCTAssertEqual(host.loadedModel, "large")
    }

    func testAFailedFirstLoadSurfacesAsFailed() async {
        let host = makeHost(onDisk: ["bad"], failLoadFor: ["bad"])
        await host.loadModel("bad", downloadIfNeeded: false)
        XCTAssertEqual(host.state, .failed("boom"))
        XCTAssertNil(host.loadedModel)
    }

    func testAFailedSwitchKeepsThePreviousModelServing() async {
        let host = makeHost(onDisk: ["base", "bad"], failLoadFor: ["bad"])
        await host.loadModel("base", downloadIfNeeded: false)
        XCTAssertEqual(host.loadedModel, "base")

        await host.loadModel("bad", downloadIfNeeded: false)
        XCTAssertEqual(host.state, .ready)
        XCTAssertEqual(host.loadedModel, "base")
        XCTAssertNotNil(host.loadFailureMessage)
    }

    func testReloadingTheLoadedModelIsANoOp() async throws {
        let host = makeHost(onDisk: ["base"])
        await host.loadModel("base", downloadIfNeeded: false)
        let first = try await host.awaitReady(timeout: 1)
        await host.loadModel("base", downloadIfNeeded: false)
        let second = try await host.awaitReady(timeout: 1)
        XCTAssertIdentical(first, second)
    }

    func testWithPipeSerializesOverlappingWork() async {
        let host = makeHost(onDisk: ["base"])
        await host.loadModel("base", downloadIfNeeded: false)

        let overlaps = Counter()
        var tasks: [Task<Void, Never>] = []
        for _ in 0..<8 {
            tasks.append(Task { @MainActor in
                try? await host.withPipe { _ in
                    overlaps.enter()
                    try? await Task.sleep(for: .milliseconds(5))
                    overlaps.leave()
                }
            })
        }
        for task in tasks {
            await task.value
        }
        XCTAssertEqual(overlaps.maxConcurrent, 1)
    }

    func testAwaitReadyThrowsWhenLoadingFailed() async {
        let host = makeHost(onDisk: ["bad"], failLoadFor: ["bad"])
        await host.loadModel("bad", downloadIfNeeded: false)
        do {
            _ = try await host.awaitReady(timeout: 1)
            XCTFail("expected awaitReady to throw")
        } catch {
            XCTAssertTrue(error is ModelHost<FakePipe>.HostError)
        }
    }
}
