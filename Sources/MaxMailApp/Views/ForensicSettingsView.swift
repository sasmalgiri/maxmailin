import SwiftUI
import MaxMailCore
#if canImport(AppKit)
import AppKit
#endif

/// Settings pane for the HMAC chain itself:
///   - Display whether the chain secret is persisted in the Keychain
///     (vs a process-ephemeral fallback).
///   - Rotate the secret. Past entries stop verifying — confirmation
///     required.
///   - Export a full case bundle (audit.csv + BatesIndex.csv + signed
///     manifest) for end-of-matter archival.
struct ForensicSettingsView: View {
    @Environment(MailViewModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var verifyStatus: String = ""
    @State private var rotateConfirm = false
    @State private var exportStatus: String = ""
    @State private var isBusy = false

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text("Forensic")
                    .font(.title2).bold()
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            Form {
                Section("Chain secret") {
                    if let forensic = model.forensic {
                        if forensic.secretIsPersisted {
                            Label("Persisted in Keychain", systemImage: "key.fill")
                                .foregroundStyle(.green)
                        } else {
                            Label("Ephemeral (Keychain unavailable)",
                                  systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("New audit entries are still signed, but entries written in earlier launches won't verify against this in-memory secret. Investigate why the Keychain write failed before relying on this for forensic work.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Label("Not initialised", systemImage: "questionmark.circle")
                            .foregroundStyle(.orange)
                    }
                    Button(role: .destructive) {
                        rotateConfirm = true
                    } label: {
                        Label("Rotate secret…", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(model.forensic == nil)
                }

                Section("Chain integrity") {
                    Button {
                        Task { await verify() }
                    } label: {
                        if isBusy {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Verify entire chain", systemImage: "checkmark.seal")
                        }
                    }
                    .disabled(isBusy || model.forensic == nil)
                    if !verifyStatus.isEmpty {
                        Text(verifyStatus)
                            .font(.caption)
                    }
                }

                Section("Case bundle") {
                    Button {
                        Task { await exportBundle() }
                    } label: {
                        Label("Export full case bundle…",
                              systemImage: "square.and.arrow.up")
                    }
                    .disabled(isBusy || model.forensic == nil || model.store == nil)
                    Text("Writes audit.csv + BatesIndex.csv + signed manifest to a directory you pick. Use this for end-of-matter archival or to hand a sealed case file to an external auditor.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !exportStatus.isEmpty {
                        Text(exportStatus)
                            .font(.caption)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .padding()
        .frame(width: 520, height: 520)
        .alert("Rotate chain secret?", isPresented: $rotateConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Rotate", role: .destructive) {
                rotate()
            }
        } message: {
            Text("The new secret will go into the Keychain immediately. Every audit entry written under the previous secret will fail verification from now on. You can't undo this.")
        }
    }

    private func verify() async {
        guard let forensic = model.forensic else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let v = try await forensic.auditLog.verify()
            verifyStatus = v.isIntact
                ? "Chain intact — \(v.totalEntries) entries"
                : "Chain BROKEN at entry id \(v.firstTamperedID ?? -1) (total \(v.totalEntries))"
        } catch {
            verifyStatus = "Verify failed: \(error.localizedDescription)"
        }
    }

    private func rotate() {
        guard let store = model.store else { return }
        let next = ForensicCoordinator.rotate(store: store)
        model.forensic = next
        verifyStatus = "Secret rotated — previous entries will now fail verify"
    }

    private func exportBundle() async {
        guard let forensic = model.forensic,
              let store = model.store else { return }
        guard let dir = pickDirectory(prompt: "Choose case bundle location") else { return }
        isBusy = true
        defer { isBusy = false }
        let name = SmartDefaults.caseBundleName()
        let bundle = dir.appendingPathComponent(name, isDirectory: true)
        do {
            try await forensic.exportFullCaseBundle(
                store: store,
                actor: model.selectedAccount?.address ?? "examiner",
                bundleName: name,
                bundleRoot: bundle
            )
            exportStatus = "Exported to \(bundle.path)"
        } catch {
            exportStatus = "Export failed: \(error.localizedDescription)"
        }
    }

}

private func pickDirectory(prompt: String) -> URL? {
    #if canImport(AppKit)
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    panel.prompt = prompt
    panel.directoryURL = SmartDefaults.defaultExportDirectory()
    return panel.runModal() == .OK ? panel.url : nil
    #else
    return nil
    #endif
}
