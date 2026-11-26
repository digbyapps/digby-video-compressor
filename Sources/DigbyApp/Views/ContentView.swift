import SwiftUI
import DigbyCore

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var dropTargeted = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 270, max: 340)
        } detail: {
            VStack(spacing: 0) {
                Banners()
                ZStack {
                    if case .failed(let msg) = model.engineState {
                        EngineMissingView(message: msg)
                    } else if let item = model.selected {
                        ItemDetailView(item: item).id(item.id)
                    } else {
                        DropZoneView(isTargeted: dropTargeted) { model.presentOpenPanel() }
                            .padding(36)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Brand.canvas)
            .toolbarBackground(Brand.canvas, for: .windowToolbar)
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls: urls); return !urls.isEmpty
        } isTargeted: { dropTargeted = $0 }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.presentOpenPanel() } label: { Label("Add Videos", systemImage: "plus") }
                    .help("Add videos or folders (⌘O)")
                if model.items.count > 1 {
                    PresetMenu(targets: model.items.filter { !$0.isActive }, label: "Preset for All")
                    Button { model.compressAll() } label: {
                        Label(model.prefs.outputMode == .replaceOriginals ? "Compress All and Replace" : "Compress All",
                              systemImage: "square.stack.3d.down.forward")
                    }
                    .help("Compress every video in the list that isn’t done yet (⇧⌘↩)")
                    .disabled(model.compressibleItems.isEmpty)
                }
                if model.batch?.entries.isEmpty == false {
                    Button { model.showBatchReport = true } label: { Label("Batch Report", systemImage: "list.bullet.rectangle") }
                        .help("What happened to each video in the last batch")
                }
            }
        }
        .alert(item: $model.alert) { a in Alert(title: Text(a.title), message: Text(a.message)) }
        .confirmationDialog(replaceTitle, isPresented: Binding(get: { model.replaceConfirmation != nil }, set: { if !$0 { model.replaceConfirmation = nil } }),
                            titleVisibility: .visible) {
            Button("Compress and Replace", role: .destructive) { model.confirmReplace() }
            Button("Cancel", role: .cancel) { model.replaceConfirmation = nil }
        } message: {
            Text("Each original goes to the Trash only after its compressed copy is finished, checked (it plays, has the same length and sound, and is smaller) and in place with the original’s name and dates. Videos that wouldn’t get smaller are left alone. Other files and folders aren’t touched.")
        }
        .sheet(isPresented: $model.showBatchReport) { if let b = model.batch { BatchReportView(batch: b).environment(model) } }
        .overlay {
            if dropTargeted && model.selected != nil {
                RoundedRectangle(cornerRadius: Brand.cardRadius, style: .continuous).strokeBorder(Brand.accent, style: StrokeStyle(lineWidth: 2.5, dash: [10, 6]))
                    .background(Brand.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: Brand.cardRadius, style: .continuous))
                    .padding(8).allowsHitTesting(false)
            }
        }
        .onAppear { Notifier.requestPermission() }
        .onChange(of: model.selection) { _, _ in if let s = model.selected { model.ensureEstimate(s) } }
    }

    var replaceTitle: String {
        let n = model.replaceConfirmation?.count ?? 0
        return "Replace \(n) original\(n == 1 ? "" : "s") with compressed versions?"
    }
}

/// Notices above the detail pane: skipped files, a batch to resume.
struct Banners: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(spacing: 0) {
            if let report = model.lastSession { LastSessionSummary(report: report) }
            if let n = model.skipNotice {
                Banner(symbol: "line.3.horizontal.decrease.circle.fill", tint: .secondary, text: n.summary) {
                    Button("Add Anyway") { model.addSkippedAnyway() }
                    Button("OK") { model.skipNotice = nil }
                }
            }
        }
    }

    struct Banner<Buttons: View>: View {
        var symbol: String; var tint: Color; var text: String
        @ViewBuilder var buttons: Buttons
        var body: some View {
            HStack(spacing: 10) {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
                Spacer()
                buttons.controlSize(.small)
            }
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(Brand.accent.opacity(0.06))
            .overlay(alignment: .bottom) { Divider() }
        }
    }
}

/// After reopening: what the last session finished, what closing stopped, what failed (and why), what was cancelled.
struct LastSessionSummary: View {
    @Environment(AppModel.self) private var model
    var report: LastSessionReport
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.clockwise.circle").foregroundStyle(Brand.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(report.headline).font(.callout)
                    Text(report.tally).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(expanded ? "Hide" : "Details") { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } }
                    .buttonStyle(.borderless).controlSize(.small)
                Button("Dismiss") { model.dismissResume() }.controlSize(.small)
                    .help("Close this. Videos not resumed are forgotten (the originals are untouched).")
                if !report.resumable.isEmpty {
                    Button("Resume All") { model.resumeSavedQueue() }.buttonStyle(.borderedProminent).tint(Brand.accent).controlSize(.small)
                }
            }
            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(report.items) { row in Row(row: row) }
                }
                .padding(.leading, 26)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .background(Brand.accent.opacity(0.06))
        .overlay(alignment: .bottom) { Divider() }
    }

    struct Row: View {
        @Environment(AppModel.self) private var model
        var row: LastSessionItem
        var body: some View {
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(tint).frame(width: 14)
                Text(row.name).lineLimit(1).truncationMode(.middle)
                if let r = row.reason { Text(r).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail) }
                Spacer(minLength: 8)
                if row.canResume {
                    Button(row.outcome == .failed ? "Try Again" : "Resume") { model.resumeSavedQueue([row.id]) }.buttonStyle(.borderless)
                }
                if row.outcome == .stopped || row.outcome == .failed {
                    Button("Remove") { model.removeFromLastSession(row.id) }.buttonStyle(.borderless).foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        }
        var symbol: String {
            switch row.outcome {
            case .finished: "checkmark.circle"
            case .stopped: "pause.circle"
            case .failed: "exclamationmark.circle"
            case .cancelled: "xmark.circle"
            }
        }
        var tint: Color {
            switch row.outcome {
            case .finished: .green
            case .stopped: Brand.accent
            case .failed: .orange
            case .cancelled: .secondary
            }
        }
    }
}

struct EngineMissingView: View {
    var message: String
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 44)).foregroundStyle(.orange)
            Text("The encoding engine couldn’t start").font(.display(24, weight: .regular)).tracking(em: -0.02, size: 24)
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            Text("Reinstalling Digby Video Compressor usually fixes this.").font(.callout).foregroundStyle(.tertiary)
        }.padding(40)
    }
}
