import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
@testable import CmuxNextTerminal
import Foundation
import IOSurface
import Testing

/// SWITCH FRAMES item 2 (STATUS 8158, the lead 2026-11-03): a Cmd-digit switch back to a workspace whose terminals the
/// warm set evicted made each pane a new terminal, one new surface per display frame (`ContentPresentationScheduler`).
/// The panes that waited for their surface showed nothing (12 panes: up to 12 frames of empty panes), and a pane that got
/// its surface showed its saved frame on a second layer over it (`TerminalFrameHold`'s held view: +46 ms of Core
/// Animation commit in a 12-pane switch, #32941). Chrome shows a tab's last frame at once and the renderer catches up.
///
/// Each revealed pane shows its saved frame from the first frame after the key, on exactly one layer: the frame alone
/// while the pane waits for its terminal, then the terminal's own surface layer, whose live frame replaces it in place.
/// Never zero layers with a frame (an empty pane), never two (a layer over the terminal).
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct SwitchShowsSavedFramesTests {
    private typealias Terminal = (pane: String, tab: String, surface: SurfaceID)

    /// The layers under `host` that show a frame (a terminal's IOSurface or a picture).
    static func frameLayers(in host: NSView) -> [CALayer] {
        func walk(_ layer: CALayer) -> [CALayer] {
            let own: [CALayer] = layer.contents.map { contents in
                let type = CFGetTypeID(contents as CFTypeRef)
                return type == IOSurfaceGetTypeID() || type == CGImage.typeID ? [layer] : []
            } ?? []
            return own + (layer.sublayers ?? []).flatMap(walk)
        }
        return host.layer.map(walk) ?? []
    }

    @Test func aSwitchBackToEvictedTerminalsShowsEachPanesSavedFrameOnOneLayerFromTheFirstFrame() async throws {
        let drew = WindowDrawPolicy.drawsWhenOccluded
        WindowDrawPolicy.drawsWhenOccluded = true
        defer { WindowDrawPolicy.drawsWhenOccluded = drew }
        try await PinnedPageTests.withApp { services, connection in
            try await PinnedPageTests.until({ !services.windows.registry.isLaunching }, within: .seconds(60))
            let controller = try #require(services.windows.active)
            let window = try #require(controller.window)
            window.setFrame(NSRect(x: 0, y: 0, width: 1100, height: 760), display: true)

            // A workspace with two terminals side by side.
            let id = try #require(await services.windows.createWorkspace(into: controller.state.id))
            @MainActor func terminals() -> [Terminal] {
                guard controller.workspaceContent?.workspace.id == id, let content = controller.workspaceContent else { return [] }
                return content.panes.values.compactMap { pane in
                    guard pane.pane.handle.rawValue < ProvisionalPane.firstHandle, let tab = pane.currentTabKey, case .terminal? = pane.currentContent,
                          let model = pane.pane.tabs.first(where: { $0.id == tab && $0.kind == .pty && !ProvisionalTab.isProvisional(surface: $0.surface) })
                    else { return nil }
                    return (pane.paneKey, tab, model.surface)
                }
            }
            try await PinnedPageTests.until({
                if controller.workspaceContent?.workspace.id != id { services.windows.show(workspaceID: id, in: controller.state) }
                return terminals().count == 1
            }, report: { "waiting for the workspace's terminal" })
            var terminal = ActionInvocation(origin: .user)
            terminal.opensTerminal = true
            #expect(services.registry.perform("splitRight", invocation: terminal))
            try await PinnedPageTests.until({ terminals().count == 2 }, report: { "waiting for the split's terminal" })
            let shells = terminals()
            for shell in shells {
                try await connection.send(shell.surface, text: "echo saved$((3*3))\r")
                let shown = try? await connection.request(WaitForTextRequest(surface: shell.surface, pattern: "saved9", timeoutMs: 20_000), timeout: .seconds(25))
                try #require(shown?.matched == true, "the shell of \(shell.tab) never answered")
            }
            // Each terminal presents the frame with its output (the frame the warm set keeps).
            try await PinnedPageTests.until({
                shells.allSatisfy { services.cache.terminals[$0.tab]?.session.surfaceHasContent == true
                    && services.cache.terminals[$0.tab]?.session.surfaceView.presentedFrame != nil }
            }, report: { "waiting for both terminals' frames" })
            try await Task.sleep(for: .milliseconds(300)) // the frame with the echo lands

            // Another workspace shows; the warm set evicts both hidden terminals (their saved frames stay).
            let other = try #require(await services.windows.createWorkspace(into: controller.state.id))
            try await PinnedPageTests.until({
                if controller.workspaceContent?.workspace.id != other { services.windows.show(workspaceID: other, in: controller.state) }
                return controller.workspaceContent?.workspace.id == other && controller.workspaceContent?.panes.isEmpty == false
            }, report: { "waiting for the other workspace" })
            // The workspace hibernates (its parked panes let go): the warm set closes both terminals, their saved frames stay.
            var saved: [String: IOSurface] = [:]
            for shell in shells {
                saved[shell.pane] = try #require(services.cache.terminals[shell.tab]?.session.surfaceView.presentedFrame, "\(shell.tab) has no frame")
            }
            services.hibernateWorkspace(id)
            try await PinnedPageTests.until({ shells.allSatisfy { !services.cache.hasContent(for: $0.tab) } },
                                            report: { "the hidden workspace kept a terminal" })
            for shell in shells {
                try #require(services.cache.lastFrames[shell.tab] != nil, "no saved frame of \(shell.tab): \(services.cache.lastFrames.report)")
            }

            // The switch's turn: the frame Core Animation commits at its end is the first frame after the key.
            services.windows.show(workspaceID: id, in: controller.state)
            let content = try #require(controller.workspaceContent)
            #expect(content.workspace.id == id, "the window did not show the workspace in this turn")
            for shell in shells {
                let pane = try #require(content.paneController(key: shell.pane))
                let layers = Self.frameLayers(in: pane.view.contentHost)
                let kinds = layers.map { String(describing: type(of: $0)) }
                #expect(layers.count == 1, "pane \(shell.pane) shows its frame on \(layers.count) layers in the first frame after the key (0: an empty pane; 2: a layer over its terminal): \(kinds)")
                #expect(layers.first.map { ($0.contents as CFTypeRef?) === saved[shell.pane] } == true,
                        "pane \(shell.pane) does not show its saved frame in the first frame after the key")
                if let session = services.cache.terminals[shell.tab]?.session, session.view.isDescendant(of: pane.view.contentHost) {
                    #expect(layers.first === session.surfaceView.layer,
                            "pane \(shell.pane)'s saved frame is on a layer over its terminal, not the terminal's own surface layer")
                }
            }

            // Each later frame until both terminals show their live content: one layer with a frame per pane.
            var violations: [String] = []
            let by = ContinuousClock.now.advanced(by: .seconds(15))
            while ContinuousClock.now < by {
                try await Task.sleep(for: .milliseconds(2))
                var live = 0
                for shell in shells {
                    guard let pane = content.paneController(key: shell.pane) else { continue }
                    let count = Self.frameLayers(in: pane.view.contentHost).count
                    if count != 1, violations.count < 8 { violations.append("\(shell.pane): \(count) layers") }
                    if let session = services.cache.terminals[shell.tab]?.session, session.view.isDescendant(of: pane.view.contentHost),
                       let frame = session.surfaceView.presentedFrame, frame !== saved[shell.pane], !session.showsHeldFrame { live += 1 }
                }
                if live == shells.count { break }
            }
            #expect(violations.isEmpty, "a frame between the switch and the live content showed a pane on other than one layer: \(violations)")
            var screens: [String] = []
            for shell in shells { screens.append((try? await connection.request(ReadScreenRequest(surface: shell.surface), timeout: .seconds(5)))?.text ?? "") }
            #expect(screens.allSatisfy { $0.contains("saved9") }, "a terminal lost its content after the switch: \(screens)")
        }
    }
}
