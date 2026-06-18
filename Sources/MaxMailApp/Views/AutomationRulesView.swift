import SwiftUI
import MaxMailCore

/// Rules manager. Lists existing rules for the selected account and
/// offers a small editor for add / edit / delete. Mirrors Mail.app's
/// Rules pane in spirit, with the simpler condition model that
/// RuleConditions / RuleActions actually supports.
struct AutomationRulesView: View {
    @Environment(MailViewModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var rules: [AutomationRule] = []
    @State private var editing: AutomationRule?
    @State private var isSweeping = false
    @State private var sweepStatus: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if rules.isEmpty {
                ContentUnavailableView(
                    "No rules yet",
                    systemImage: "line.3.horizontal.decrease.circle",
                    description: Text("Add a rule to auto-flag, mark read, or sort messages into a folder as they arrive.")
                )
                .frame(minHeight: 280)
            } else {
                List {
                    ForEach(rules) { rule in
                        RuleRow(rule: rule)
                            .contentShape(Rectangle())
                            .onTapGesture { editing = rule }
                    }
                }
                .listStyle(.inset)
            }
            footer
        }
        .frame(minWidth: 560, minHeight: 460)
        .task { await reload() }
        .sheet(item: $editing, onDismiss: { Task { await reload() } }) { rule in
            RuleEditor(rule: rule, accountID: model.selectedAccount?.id ?? 0)
                .environment(model)
        }
    }

    private var header: some View {
        HStack {
            Text("Rules").font(.title2).bold()
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding()
    }

    private var footer: some View {
        HStack {
            Button("New rule…") {
                editing = AutomationRule(
                    accountID: model.selectedAccount?.id ?? 0,
                    name: "Untitled",
                    conditions: RuleConditions(),
                    actions: RuleActions()
                )
            }
            Spacer()
            if let s = sweepStatus {
                Text(s).font(.caption).foregroundStyle(.secondary)
            }
            Button(isSweeping ? "Sweeping…" : "Apply now") {
                Task { await sweep() }
            }
            .disabled(isSweeping || rules.isEmpty)
        }
        .padding()
    }

    private func reload() async {
        guard let store = model.store, let acc = model.selectedAccount else { return }
        do { rules = try await store.rules(accountID: acc.id) }
        catch { model.errorMessage = error.localizedDescription }
    }

    private func sweep() async {
        guard let store = model.store, let acc = model.selectedAccount else { return }
        isSweeping = true
        defer { isSweeping = false }
        do {
            let n = try await store.applyRulesBatch(accountID: acc.id, batchSize: 500)
            sweepStatus = "Applied to \(n) messages"
            await model.loadHeaders()
            await model.loadFolders()
        } catch {
            sweepStatus = "Failed: \(error.localizedDescription)"
        }
    }
}

private struct RuleRow: View {
    let rule: AutomationRule

    var body: some View {
        HStack {
            Image(systemName: rule.enabled
                  ? "checkmark.circle.fill"
                  : "circle")
                .foregroundStyle(rule.enabled ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name)
                Text(summary(rule))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    private func summary(_ r: AutomationRule) -> String {
        var bits: [String] = []
        if !r.conditions.fromContains.isEmpty {
            bits.append("from ‘\(r.conditions.fromContains.joined(separator: ", "))’")
        }
        if !r.conditions.subjectContains.isEmpty {
            bits.append("subject ‘\(r.conditions.subjectContains.joined(separator: ", "))’")
        }
        if !r.conditions.bodyContains.isEmpty {
            bits.append("body ‘\(r.conditions.bodyContains.joined(separator: ", "))’")
        }
        if r.conditions.hasAttachment == true { bits.append("has attachment") }
        var actions: [String] = []
        if r.actions.markSeen     { actions.append("mark read") }
        if r.actions.markFlagged  { actions.append("flag") }
        if let f = r.actions.moveToFolder, !f.isEmpty { actions.append("→ \(f)") }
        let cond = bits.joined(separator: " \(r.conditions.combinator == .and ? "and" : "or") ")
        let act  = actions.joined(separator: ", ")
        return "[\(cond)] → \(act)"
    }
}

private struct RuleEditor: View {
    @Environment(MailViewModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State var rule: AutomationRule
    let accountID: Int64

    @State private var fromCSV = ""
    @State private var subjectCSV = ""
    @State private var bodyCSV = ""
    @State private var attachmentMode: AttachmentMode = .dontCare
    @State private var moveToFolder = ""

    enum AttachmentMode: String, CaseIterable, Identifiable {
        case dontCare = "Either"
        case yes = "Has attachment"
        case no  = "No attachment"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(rule.id == 0 ? "New rule" : "Edit rule")
                    .font(.title2).bold()
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
            Divider()
            Form {
                Section("Rule") {
                    TextField("Name", text: $rule.name)
                    Toggle("Enabled", isOn: $rule.enabled)
                    Picker("Match", selection: $rule.conditions.combinator) {
                        Text("All conditions").tag(RuleConditions.Combinator.and)
                        Text("Any condition").tag(RuleConditions.Combinator.or)
                    }
                }
                Section("Conditions (comma-separated terms)") {
                    TextField("From contains", text: $fromCSV)
                    TextField("Subject contains", text: $subjectCSV)
                    TextField("Body contains", text: $bodyCSV)
                    Picker("Attachment", selection: $attachmentMode) {
                        ForEach(AttachmentMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
                Section("Actions") {
                    Toggle("Mark as read", isOn: $rule.actions.markSeen)
                    Toggle("Flag (star)", isOn: $rule.actions.markFlagged)
                    TextField("Move to folder (blank = stay in INBOX)", text: $moveToFolder)
                }
            }
            .formStyle(.grouped)
            HStack {
                if rule.id != 0 {
                    Button("Delete", role: .destructive) {
                        Task { await delete() }
                    }
                }
                Spacer()
                Button("Save") {
                    Task { await save() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(rule.name.isEmpty)
            }
            .padding()
        }
        .frame(width: 560, height: 560)
        .onAppear {
            fromCSV     = rule.conditions.fromContains.joined(separator: ", ")
            subjectCSV  = rule.conditions.subjectContains.joined(separator: ", ")
            bodyCSV     = rule.conditions.bodyContains.joined(separator: ", ")
            attachmentMode = rule.conditions.hasAttachment.map { $0 ? .yes : .no } ?? .dontCare
            moveToFolder = rule.actions.moveToFolder ?? ""
        }
    }

    private func save() async {
        rule.accountID = accountID
        rule.conditions.fromContains    = parseCSV(fromCSV)
        rule.conditions.subjectContains = parseCSV(subjectCSV)
        rule.conditions.bodyContains    = parseCSV(bodyCSV)
        rule.conditions.hasAttachment = {
            switch attachmentMode {
            case .dontCare: return nil
            case .yes: return true
            case .no:  return false
            }
        }()
        rule.actions.moveToFolder = moveToFolder.trimmingCharacters(in: .whitespaces).isEmpty
            ? nil
            : moveToFolder.trimmingCharacters(in: .whitespaces)

        guard let store = model.store else { return }
        do {
            if rule.id == 0 {
                _ = try await store.addRule(rule)
            } else {
                try await store.updateRule(rule)
            }
            dismiss()
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    private func delete() async {
        guard let store = model.store, rule.id != 0 else { return }
        do {
            try await store.deleteRule(ruleID: rule.id)
            dismiss()
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    private func parseCSV(_ s: String) -> [String] {
        s.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
