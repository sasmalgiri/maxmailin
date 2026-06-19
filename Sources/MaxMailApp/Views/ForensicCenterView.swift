import SwiftUI
import MaxMailCore
#if canImport(AppKit)
import AppKit
#endif

/// Three-tab forensic operations panel:
///   - Audit trail: paged AuditLog readback + chain verification.
///   - Bates production: config + assign + signed CSV export.
///   - GDPR disclosure: data-subject report + erasure flow.
///
/// All actions go through `MailViewModel.forensic` and therefore through
/// the same HMAC-chained AuditLog, so anything done here is recorded.
struct ForensicCenterView: View {
    @Environment(MailViewModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private enum Tab: String, CaseIterable, Identifiable {
        case audit = "Audit Trail"
        case bates = "Bates"
        case gdpr  = "GDPR"
        var id: String { rawValue }
        var systemImage: String {
            switch self {
            case .audit: return "list.bullet.rectangle"
            case .bates: return "number.square"
            case .gdpr:  return "person.text.rectangle"
            }
        }
    }

    @State private var selectedTab: Tab = .audit

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Forensic Center")
                    .font(.title2).bold()
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Picker("", selection: $selectedTab) {
                ForEach(Tab.allCases) { tab in
                    Label(tab.rawValue, systemImage: tab.systemImage).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)

            Divider().padding(.top, 8)

            Group {
                switch selectedTab {
                case .audit: AuditTrailTab()
                case .bates: BatesTab()
                case .gdpr:  GDPRTab()
                }
            }
        }
        .frame(minWidth: 720, minHeight: 540)
    }
}

// MARK: - Audit trail

private struct AuditTrailTab: View {
    @Environment(MailViewModel.self) private var model

    @State private var entries: [AuditEntry] = []
    @State private var status: String = ""
    @State private var isVerifying = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button {
                    Task { await refresh() }
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                Button {
                    Task { await verify() }
                } label: {
                    if isVerifying {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Verify chain", systemImage: "checkmark.seal")
                    }
                }
                .disabled(isVerifying)

                Spacer()
                Text("\(entries.count) entries")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !status.isEmpty {
                Text(status)
                    .font(.callout)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 6))
            }

            Table(entries) {
                TableColumn("When") { entry in
                    Text(entry.occurredAt, format: .dateTime.month().day().hour().minute().second())
                        .font(.caption).monospacedDigit()
                }
                TableColumn("Actor") { entry in
                    Text(entry.actor).font(.caption)
                }
                TableColumn("Action") { entry in
                    Text(entry.action).font(.caption)
                }
                TableColumn("Subject") { entry in
                    Text("\(entry.subjectKind):\(entry.subjectID)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                TableColumn("Hash") { entry in
                    Text(entry.entryHash.prefix(10) + "…")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .help(entry.entryHash)
                }
            }
        }
        .padding()
        .task { await refresh() }
    }

    private func refresh() async {
        guard let forensic = model.forensic else { return }
        do {
            entries = try await forensic.auditLog.entries(limit: 500)
        } catch {
            status = "Reload failed: \(error.localizedDescription)"
        }
    }

    private func verify() async {
        guard let forensic = model.forensic else { return }
        isVerifying = true
        defer { isVerifying = false }
        do {
            let v = try await forensic.auditLog.verify()
            if v.isIntact {
                status = "Chain intact — \(v.totalEntries) entries verified"
            } else {
                status = "Chain BROKEN at entry id \(v.firstTamperedID ?? -1) (total \(v.totalEntries))"
            }
        } catch {
            status = "Verify failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Bates

private struct BatesTab: View {
    @Environment(MailViewModel.self) private var model

    @State private var prefix: String = "MAILIN"
    @State private var startNumber: String = "1"
    @State private var padding: String = "6"
    @State private var assignedCount: Int64 = 0
    @State private var status: String = ""
    @State private var isBusy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Bates Numbering")
                .font(.headline)
            Text("Bates numbers are citation-stable identifiers for legal production. Once assigned, a Bates number never changes.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Prefix").font(.caption).foregroundStyle(.secondary)
                    TextField("Prefix", text: $prefix).frame(width: 140)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Start").font(.caption).foregroundStyle(.secondary)
                    TextField("Start", text: $startNumber).frame(width: 80)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Padding").font(.caption).foregroundStyle(.secondary)
                    TextField("Padding", text: $padding).frame(width: 60)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("First").font(.caption).foregroundStyle(.secondary)
                    Text(previewFirst()).font(.body.monospaced())
                }
            }
            .textFieldStyle(.roundedBorder)

            HStack(spacing: 8) {
                Button {
                    Task { await saveConfig() }
                } label: {
                    Label("Save config", systemImage: "tray.and.arrow.down")
                }
                Button {
                    Task { await assign() }
                } label: {
                    if isBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Assign to unnumbered", systemImage: "wand.and.stars")
                    }
                }
                .disabled(isBusy)
                Button {
                    Task { await exportIndex() }
                } label: {
                    Label("Export signed bundle…", systemImage: "square.and.arrow.up")
                }
                .disabled(assignedCount == 0 || isBusy)
                Spacer()
                Text("\(assignedCount) assigned")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !status.isEmpty {
                Text(status)
                    .font(.callout)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 6))
            }

            Spacer()
        }
        .padding()
        .task { await loadConfig() }
    }

    private func previewFirst() -> String {
        let n = Int64(startNumber) ?? 1
        let pad = Int(padding) ?? 6
        return BatesNumberingManager.format(
            n, config: BatesConfig(prefix: prefix, startNumber: n, zeroPadding: pad)
        )
    }

    private func loadConfig() async {
        guard let forensic = model.forensic else { return }
        do {
            let cfg = try await forensic.bates.config()
            prefix = cfg.prefix
            startNumber = String(cfg.startNumber)
            padding = String(cfg.zeroPadding)
            assignedCount = try await forensic.bates.count()
        } catch {
            status = "Load failed: \(error.localizedDescription)"
        }
    }

    private func saveConfig() async {
        guard let forensic = model.forensic else { return }
        let cfg = BatesConfig(
            prefix: prefix,
            startNumber: Int64(startNumber) ?? 1,
            zeroPadding: Int(padding) ?? 6
        )
        do {
            try await forensic.bates.setConfig(cfg)
            status = "Config saved"
        } catch {
            status = "Save failed: \(error.localizedDescription)"
        }
    }

    private func assign() async {
        guard let forensic = model.forensic else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let report = try await forensic.bates.assignNumbers(
                accountID: model.selectedAccount?.id,
                actor: model.selectedAccount?.address ?? "examiner"
            )
            assignedCount = try await forensic.bates.count()
            if report.newlyAssignedCount == 0 {
                status = "Nothing to assign — all messages are numbered"
            } else {
                status = "Assigned \(report.newlyAssignedCount) numbers: " +
                    "\(report.firstBatesNumber ?? "?") → \(report.lastBatesNumber ?? "?")"
            }
        } catch {
            status = "Assign failed: \(error.localizedDescription)"
        }
    }

    private func exportIndex() async {
        guard let forensic = model.forensic else { return }
        guard let dir = pickDirectory(prompt: "Choose Bates bundle location") else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let bundle = dir.appendingPathComponent(
                "BatesIndex-\(bundleTimestamp())", isDirectory: true
            )
            _ = try await forensic.bates.exportBatesIndex(
                actor: model.selectedAccount?.address ?? "examiner",
                bundleName: bundle.lastPathComponent,
                bundleRoot: bundle,
                signer: forensic.exportSigner
            )
            status = "Exported to \(bundle.path)"
        } catch {
            status = "Export failed: \(error.localizedDescription)"
        }
    }

}

private func bundleTimestamp() -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyyMMdd-HHmmss"
    return f.string(from: Date())
}

// MARK: - GDPR

private struct GDPRTab: View {
    @Environment(MailViewModel.self) private var model

    @State private var subject: String = ""
    @State private var report: GDPRAccessReport?
    @State private var messages: [MailStore.GDPRMessageRef] = []
    @State private var status: String = ""
    @State private var isBusy = false
    @State private var showEraseConfirm = false
    @State private var eraseReason: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("GDPR Article 15 / 17")
                .font(.headline)
            Text("Article 15: produce every record involving the data subject. Article 17: erase them. Both actions are recorded on the audit chain.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField("Data subject email (e.g. alice@example.com)",
                          text: $subject)
                    .textFieldStyle(.roundedBorder)
                Button {
                    Task { await generate() }
                } label: {
                    if isBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Generate report", systemImage: "doc.text.magnifyingglass")
                    }
                }
                .disabled(subject.isEmpty || isBusy)
            }

            if let r = report {
                summaryCard(r)
                HStack(spacing: 8) {
                    Button {
                        Task { await exportBundle() }
                    } label: {
                        Label("Export signed bundle…", systemImage: "square.and.arrow.up")
                    }
                    .disabled(isBusy)
                    Button(role: .destructive) {
                        showEraseConfirm = true
                    } label: {
                        Label("Erase all data for subject…", systemImage: "trash")
                    }
                    .disabled(isBusy)
                }
            }

            if !status.isEmpty {
                Text(status)
                    .font(.callout)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 6))
            }

            Spacer()
        }
        .padding()
        .alert("Erase all data for \(subject)?", isPresented: $showEraseConfirm) {
            TextField("Rationale (recorded on audit chain)", text: $eraseReason)
            Button("Cancel", role: .cancel) {}
            Button("Erase", role: .destructive) {
                Task { await erase() }
            }
        } message: {
            Text("This permanently deletes every message involving the subject. The rationale is written to the audit chain BEFORE deletion so the record survives the cascade.")
        }
    }

    private func summaryCard(_ r: GDPRAccessReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 16) {
                statBlock("Total", "\(r.totalMessages)")
                statBlock("As sender", "\(r.messagesAsSender)")
                statBlock("As recipient", "\(r.messagesAsRecipient)")
                statBlock("With attachments", "\(r.messagesWithAttachments)")
            }
            if let e = r.earliestDate, let l = r.latestDate {
                Text("Date range: \(e, format: .dateTime.month().day().year()) → \(l, format: .dateTime.month().day().year())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !r.distinctCorrespondents.isEmpty {
                Text("Top correspondents:")
                    .font(.caption.weight(.semibold))
                ForEach(r.distinctCorrespondents.prefix(5), id: \.address) { c in
                    Text("• \(c.address) — \(c.messageCount) messages")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 8))
    }

    private func statBlock(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading) {
            Text(value).font(.title3.monospacedDigit().bold())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func generate() async {
        guard let forensic = model.forensic else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let (r, msgs) = try await forensic.gdpr.generate(
                dataSubject: subject,
                actor: model.selectedAccount?.address ?? "examiner",
                accountID: model.selectedAccount?.id
            )
            report = r
            messages = msgs
            status = "Generated — \(r.totalMessages) messages found"
        } catch {
            status = "Generation failed: \(error.localizedDescription)"
        }
    }

    private func exportBundle() async {
        guard let forensic = model.forensic,
              let r = report else { return }
        guard let dir = pickDirectory(prompt: "Choose disclosure bundle location") else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let bundle = dir.appendingPathComponent(
                "GDPR-\(safe(subject))-\(bundleTimestamp())",
                isDirectory: true
            )
            _ = try await forensic.gdpr.exportBundle(
                actor: model.selectedAccount?.address ?? "examiner",
                bundleName: bundle.lastPathComponent,
                bundleRoot: bundle,
                report: r,
                messages: messages,
                signer: forensic.exportSigner
            )
            status = "Exported to \(bundle.path)"
        } catch {
            status = "Export failed: \(error.localizedDescription)"
        }
    }

    private func erase() async {
        guard let forensic = model.forensic else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let r = try await forensic.gdpr.eraseAllForSubject(
                emailAddress: subject,
                actor: model.selectedAccount?.address ?? "examiner",
                reason: eraseReason.isEmpty ? "unspecified" : eraseReason,
                accountID: model.selectedAccount?.id
            )
            status = "Erased \(r.messagesDeleted) messages (\(r.messagesFailed) failed)"
            report = nil
            messages = []
            eraseReason = ""
        } catch {
            status = "Erase failed: \(error.localizedDescription)"
        }
    }

    private func safe(_ s: String) -> String {
        s.replacingOccurrences(of: "@", with: "_at_")
            .replacingOccurrences(of: "/", with: "_")
    }
}

// MARK: - Directory picker

/// Mac directory picker. Returns nil on cancel. UIKit fallback isn't
/// wired yet — Forensic Center is Mac-only in this slice.
private func pickDirectory(prompt: String) -> URL? {
    #if canImport(AppKit)
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    panel.prompt = prompt
    return panel.runModal() == .OK ? panel.url : nil
    #else
    return nil
    #endif
}
