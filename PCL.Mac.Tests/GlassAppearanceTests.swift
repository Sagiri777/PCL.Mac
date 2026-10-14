import AppKit
import Combine
import Testing
@testable import PCL_Mac

@Suite(.serialized)
@MainActor
struct GlassAppearanceTests {
    @Test func repeatedVisualRefreshDoesNotInvalidateSubscribers() {
        let glass = GlassSettings()
        glass.reloadThemeDerived()
        var notifications = 0
        let subscription = glass.objectWillChange.sink { notifications += 1 }
        defer { subscription.cancel() }

        for _ in 0..<20 {
            glass.reloadThemeDerived()
        }

        #expect(notifications == 0)
    }

    @Test func windowConfigurationSynchronizesGlassInsetsAndPublishesOnce() {
        let settings = AppSettings.shared
        let originalWidth = settings.glassFrameWidth
        defer {
            settings.glassFrameWidth = originalWidth
            settings.refreshWindowConfiguration()
        }
        settings.refreshVisuals()
        var notifications = 0
        let subscription = GlassSettings.shared.objectWillChange.sink { notifications += 1 }
        defer { subscription.cancel() }
        let previousRevision = settings.appearanceRevision
        let updatedWidth = originalWidth == 20 ? 14.0 : 20.0

        settings.glassFrameWidth = updatedWidth
        settings.refreshWindowConfiguration()

        #expect(GlassSettings.shared.appearance.frameWidth == updatedWidth)
        #expect(settings.appearanceRevision == previousRevision &+ 1)
        #expect(notifications == 1)
        settings.refreshVisuals()
        #expect(notifications == 1)
    }

    @Test func glassFrameChangesPreserveTheInteriorSizeAndRestoreOnExit() {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 980, height: 650),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let originalFrame = window.frame
        let coordinator = WindowAccessor.Coordinator()

        coordinator.enterGlassMode(window: window, frameWidth: 14)
        coordinator.enterGlassMode(window: window, frameWidth: 24)

        #expect(window.frame.width == originalFrame.width + 20)
        #expect(window.frame.height == originalFrame.height + 20)
        coordinator.enterGlassMode(window: window, frameWidth: 24)
        #expect(window.frame.width == originalFrame.width + 20)

        coordinator.leaveGlassMode(window: window)
        #expect(window.frame == originalFrame)
    }
}
