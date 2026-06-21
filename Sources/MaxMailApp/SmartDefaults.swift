import Foundation
import MaxMailCore

/// Pure helpers that pre-fill UI fields from context so the user can
/// invoke a forensic action with zero typing in the common case.
///
/// Design rule: every default produced here is overrideable — if the
/// user types over it, that's the final value. Smart defaults must
/// never silently win against a typed value.
enum SmartDefaults {

    // MARK: - Save locations

    /// `~/Documents/maxmailin/` — created lazily so NSOpenPanel can
    /// land there without the user having to manually mkdir. Falls
    /// back to a temp dir if the user has no Documents folder
    /// (sandboxed contexts) so callers don't have to handle nil.
    static func defaultExportDirectory() -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("maxmailin", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Identifiers

    /// `yyyyMMdd-HHmmss` — used in every bundle name so two exports
    /// in the same session don't collide and so the lexicographic
    /// sort in Finder matches chronological order.
    static func timestamp(at date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }

    /// `2026-06-20` — used in human-facing rationale text.
    static func isoDay(at date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    // MARK: - String sanitisers

    /// Make a string safe to embed in a directory or file name on
    /// macOS / iOS. Replaces `@`, `/`, `:`, whitespace with `_`. Used
    /// to turn a data-subject address into a bundle name segment.
    static func safeFilenameSegment(_ raw: String) -> String {
        let badChars = CharacterSet(charactersIn: "@/\\:\t \n")
        return raw.components(separatedBy: badChars)
            .filter { !$0.isEmpty }
            .joined(separator: "_")
    }

    // MARK: - Forensic action defaults

    /// Pre-filled GDPR erasure rationale. Investigators almost always
    /// have a written subject request — the date stamp gives them an
    /// auditable starting point they can specialise.
    static func eraseReason(for address: String, at date: Date = Date()) -> String {
        "Subject request from \(address) on \(isoDay(at: date))"
    }

    /// Pre-filled custody event description that mentions the
    /// message's own subject so the audit chain has signal beyond
    /// "Tagged from detail view." Empty subjects fall back to a
    /// generic note (no audit row should ever record an empty
    /// description).
    static func custodyDescription(
        kindLabel: String, subject: String
    ) -> String {
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "\(kindLabel) from detail view"
        }
        return "\(kindLabel): \(trimmed)"
    }

    /// Bates bundle name like `BatesIndex-20260620-093015`.
    static func batesBundleName(at date: Date = Date()) -> String {
        "BatesIndex-\(timestamp(at: date))"
    }

    /// GDPR bundle name like `GDPR-alice_at_acme.com-20260620-093015`.
    static func gdprBundleName(subject: String, at date: Date = Date()) -> String {
        "GDPR-\(safeFilenameSegment(subject))-\(timestamp(at: date))"
    }

    /// Full case bundle name like `Case-20260620-093015`.
    static func caseBundleName(at date: Date = Date()) -> String {
        "Case-\(timestamp(at: date))"
    }
}
