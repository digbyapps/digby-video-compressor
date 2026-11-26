import SwiftUI
import AppKit
import DigbyCore

@main
struct DigbyVideoCompressorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Digby Video Compressor", id: "main") {
            ContentView()
                .environment(model)
                .tint(Brand.accent)
                .frame(minWidth: 940, minHeight: 640)
                .task {
                    if DebugSnapshot.layoutOnly { await DebugSnapshot.startForLayout(model) } else { await model.start() }
                    DebugSnapshot.scheduleIfRequested(model: model)
                }
                .onOpenURL { model.add(urls: [$0]) }
        }
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Digby Video Compressor") { AboutWindow.show() }
            }
            CommandGroup(replacing: .newItem) {
                Button("Open Videos…") { model.presentOpenPanel() }.keyboardShortcut("o")
            }
            CommandMenu("Compression") {
                Button("Compress Selected") { model.compressSelected() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!model.canCompressSelected)
                Button("Compress All") { model.compressAll() }
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                Divider()
                Button("Cancel Selected") { model.cancelSelected() }
                    .keyboardShortcut(".", modifiers: .command)
                Divider()
                Button("Show Engine Log") { model.revealLog() }
            }
        }

        Settings {
            PreferencesView().environment(model).tint(Brand.accent)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var openedURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Finder → right-click a video or folder → Services / Quick Actions → "Compress with Digby"
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
    }

    @objc func compressFiles(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = (pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else { error.pointee = "No videos were selected." as NSString; return }
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            AppModel.shared?.add(urls: urls)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if AppModel.shared?.isBusy == true {
            let alert = NSAlert()
            alert.messageText = "Stop compressing and quit?"
            alert.informativeText = "The video being compressed will be stopped and nothing half-finished is kept. Videos still waiting will be offered to resume next time you open Digby."
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Keep Compressing")
            if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        // No orphaned encoders, no half-written files left behind.
        AppModel.shared?.reportStoppedHandoffs()
        AppModel.shared?.saveQueue()
        ProcessRegistry.shared.terminateAll()
        TempWorkspace.sweepStale(olderThan: 0)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in AppModel.shared?.add(urls: urls) }
    }
}
