import Testing
import ShepitCore

@Suite struct CallDetectionTests {
    static let zoom = CallApp(name: "Zoom", bundleID: "us.zoom.xos")
    static let chrome = CallApp(name: "Google Chrome", bundleID: "com.google.Chrome")
    static let watched = [zoom, chrome]
    static let ownPID: Int32 = 500

    static func process(_ bundleID: String?, pid: Int32 = 100, input: Bool = true) -> AudioInputProcess {
        AudioInputProcess(pid: pid, bundleID: bundleID, isRunningInput: input)
    }

    // MARK: Matching

    @Test func appMatchesItsOwnBundleID() {
        #expect(Self.zoom.matches(bundleID: "us.zoom.xos"))
    }

    /// Browsers capture audio in helper processes with their own bundle IDs.
    @Test func appMatchesItsHelperProcesses() {
        #expect(Self.chrome.matches(bundleID: "com.google.Chrome.helper"))
    }

    @Test func appDoesNotMatchLookalikeBundleID() {
        #expect(!Self.chrome.matches(bundleID: "com.google.ChromeCanary"))
        #expect(!Self.zoom.matches(bundleID: "us.zoom"))
    }

    @Test func matchingIgnoresCase() {
        #expect(Self.zoom.matches(bundleID: "US.Zoom.XOS"))
    }

    // MARK: Active call apps

    @Test func listedAppRunningInputIsActive() {
        let active = CallDetection.activeApps(
            in: [Self.process("us.zoom.xos"), Self.process("com.apple.Music", pid: 101)],
            watching: Self.watched, ownPID: Self.ownPID
        )

        #expect(active == ["Zoom"])
    }

    @Test func listedAppNotRunningInputIsNotActive() {
        let active = CallDetection.activeApps(
            in: [Self.process("us.zoom.xos", input: false)], watching: Self.watched, ownPID: Self.ownPID
        )

        #expect(active.isEmpty)
    }

    /// Shepit's own dictation must never look like a call, whatever the list contains.
    @Test func ownProcessIsIgnored() {
        let active = CallDetection.activeApps(
            in: [Self.process("dev.yegor.shepit", pid: Self.ownPID)],
            watching: [CallApp(name: "Shepit", bundleID: "dev.yegor.shepit")],
            ownPID: Self.ownPID
        )

        #expect(active.isEmpty)
    }

    @Test func severalHelpersOfOneAppCountOnce() {
        let active = CallDetection.activeApps(
            in: [Self.process("com.google.Chrome.helper", pid: 1), Self.process("com.google.Chrome.helper", pid: 2)],
            watching: Self.watched, ownPID: Self.ownPID
        )

        #expect(active == ["Google Chrome"])
    }

    @Test func processWithoutBundleIDIsIgnored() {
        #expect(CallDetection.activeApps(in: [Self.process(nil)], watching: Self.watched, ownPID: Self.ownPID).isEmpty)
    }

    // MARK: Changes

    @Test func newlyActiveAppStartsCall() {
        #expect(CallDetection.changes(from: [], to: ["Zoom"]) == [.callStarted(app: "Zoom")])
    }

    @Test func noLongerActiveAppEndsCall() {
        #expect(CallDetection.changes(from: ["Zoom"], to: []) == [.callEnded(app: "Zoom")])
    }

    @Test func unchangedAppsProduceNothing() {
        #expect(CallDetection.changes(from: ["Zoom"], to: ["Zoom"]).isEmpty)
    }

    @Test func endingsComeBeforeStartsInNameOrder() {
        #expect(CallDetection.changes(from: ["Zoom", "Slack"], to: ["Teams", "FaceTime"]) == [
            .callEnded(app: "Slack"), .callEnded(app: "Zoom"),
            .callStarted(app: "FaceTime"), .callStarted(app: "Teams"),
        ])
    }

    // MARK: Defaults

    @Test func defaultsCoverCallAppsAndBrowsers() {
        let names = Set(CallApp.defaults.map(\.name))

        #expect(names.isSuperset(of: ["Zoom", "Microsoft Teams", "Slack", "FaceTime", "Telegram", "Google Chrome", "Safari"]))
    }
}
