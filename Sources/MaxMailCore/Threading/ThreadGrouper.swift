import Foundation

/// One mail thread — a connected component in the message-id graph
/// implied by `In-Reply-To` + `References` headers.
///
/// `messageRowIDs` is date-ascending so callers can render them as a
/// chronological reply chain. The root is the earliest message; the
/// latest reply drives `latestDate` (which the list view uses for
/// sort order). `unreadCount` lets the list show "3 unread of 12"
/// without re-scanning the chain.
public struct MailThread: Sendable, Identifiable, Equatable {
    public let id: String              // canonical messageID of the root
    public let subject: String         // taken from the root, with Re:/Fwd: stripped for grouping
    public let displaySubject: String  // root's actual subject, with prefixes intact
    public let messageRowIDs: [Int64]
    public let latestDate: Date
    public let participants: [String]  // distinct from-addresses, oldest-first
    public let unreadCount: Int

    public var count: Int { messageRowIDs.count }
}

/// Cluster threadable headers into MailThreads using the RFC 5322
/// `In-Reply-To` + `References` graph. The algorithm is union-find
/// over message-ids: every reply links the replier's message-id to
/// its parent (or to all referenced ancestors), and every connected
/// component becomes one thread.
///
/// Two scope choices worth calling out:
///  - **Re:/Fwd: stripping is only used for membership tie-break.**
///    Threads aren't ever joined purely by subject — JWZ's "subject
///    fallback" introduces hard-to-debug merges in real corpora.
///  - **Whole-list cluster, not paged.** Callers pass the full page
///    they want to render; the grouper doesn't reach back to older
///    pages. The result is that an in-flight reply to a very old
///    thread shows up as a one-message thread on the current page,
///    which is the same behaviour Mail.app exhibits.
public enum ThreadGrouper {

    /// Group the supplied headers into threads. Headers can be in any
    /// order; the returned threads are ordered by their `latestDate`
    /// descending (newest activity first), which is the order
    /// MessageListView wants for display.
    public static func group(_ rows: [MailStore.ThreadableHeader]) -> [MailThread] {
        guard !rows.isEmpty else { return [] }

        var parent: [String: String] = [:]   // union-find
        func find(_ x: String) -> String {
            var cur = x
            while let p = parent[cur], p != cur { cur = p }
            // Path compression — flatten chain so the next find is O(1).
            var walker = x
            while let p = parent[walker], p != cur {
                parent[walker] = cur
                walker = p
            }
            return cur
        }
        func union(_ a: String, _ b: String) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }

        // Seed every message-id as its own component.
        for row in rows {
            if parent[row.messageID] == nil {
                parent[row.messageID] = row.messageID
            }
        }
        // Link replies to parents + all referenced ancestors. Parents
        // / references that aren't in the page get pulled in as
        // placeholder nodes so a reply to an off-page root still
        // clusters with siblings on this page.
        for row in rows {
            if let irt = row.inReplyTo, !irt.isEmpty {
                if parent[irt] == nil { parent[irt] = irt }
                union(row.messageID, irt)
            }
            for ref in row.references {
                if parent[ref] == nil { parent[ref] = ref }
                union(row.messageID, ref)
            }
        }

        // Bucket on-page rows by their connected component root.
        var buckets: [String: [MailStore.ThreadableHeader]] = [:]
        for row in rows {
            let root = find(row.messageID)
            buckets[root, default: []].append(row)
        }

        let threads: [MailThread] = buckets.values.compactMap { group in
            let sorted = group.sorted { $0.header.date < $1.header.date }
            guard let rootRow = sorted.first else { return nil }
            var participants: [String] = []
            var seen = Set<String>()
            for row in sorted where !row.header.fromAddress.isEmpty {
                if seen.insert(row.header.fromAddress).inserted {
                    participants.append(row.header.fromAddress)
                }
            }
            let unread = group.reduce(0) { acc, r in
                acc + (r.header.flags.contains(.seen) ? 0 : 1)
            }
            return MailThread(
                id: rootRow.messageID,
                subject: stripReplyPrefix(rootRow.header.subject),
                displaySubject: rootRow.header.subject,
                messageRowIDs: sorted.map(\.header.id),
                latestDate: sorted.last?.header.date ?? rootRow.header.date,
                participants: participants,
                unreadCount: unread
            )
        }
        return threads.sorted { $0.latestDate > $1.latestDate }
    }

    /// Strip leading `Re:`, `Fwd:`, `Fw:` (any combination, repeated)
    /// for the grouper's tie-break logic. Display subjects keep their
    /// prefixes — only the canonical form is normalised.
    public static func stripReplyPrefix(_ subject: String) -> String {
        var s = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["re:", "fwd:", "fw:"]
        while true {
            let lower = s.lowercased()
            if let match = prefixes.first(where: { lower.hasPrefix($0) }) {
                s = String(s.dropFirst(match.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                break
            }
        }
        return s
    }
}
