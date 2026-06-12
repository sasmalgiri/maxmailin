import Foundation
import MaxMailCore
#if canImport(Darwin)
import Darwin.Mach
#endif

// MARK: - CLI

struct StressOptions {
    var count: Int = 100_000
    var batchSize: Int = 5_000
    var searchQueries: Int = 25
    var sinceDays: Int? = nil
    var keepDB: Bool = false
    var dbPath: String?
    var mboxPath: String? = nil

    static func parse(_ args: [String]) -> StressOptions {
        var opts = StressOptions()
        var i = 1
        while i < args.count {
            let a = args[i]
            switch a {
            case "-n", "--count":
                i += 1
                opts.count = Int(args[i]) ?? opts.count
            case "-b", "--batch":
                i += 1
                opts.batchSize = Int(args[i]) ?? opts.batchSize
            case "-q", "--queries":
                i += 1
                opts.searchQueries = Int(args[i]) ?? opts.searchQueries
            case "--since-days":
                i += 1
                opts.sinceDays = Int(args[i])
            case "--mbox":
                i += 1
                opts.mboxPath = args[i]
            case "--keep":
                opts.keepDB = true
            case "--db":
                i += 1
                opts.dbPath = args[i]
            case "-h", "--help":
                print(usage)
                exit(0)
            default:
                FileHandle.standardError.write(Data("Unknown arg: \(a)\n".utf8))
                exit(2)
            }
            i += 1
        }
        return opts
    }
}

let usage = """
maxmail-stress — scale + import harness for MaxMailCore

Usage: maxmail-stress [-n COUNT] [-b BATCH] [-q QUERIES] [--since-days N]
                      [--mbox PATH] [--keep] [--db PATH]

  -n, --count       N    Synthetic messages to ingest (default 100000)
  -b, --batch       N    Messages per transaction (default 5000)
  -q, --queries     N    Number of random search queries to run (default 25)
      --since-days  N    Constrain searches to messages newer than N synthetic days
      --mbox      PATH   Skip synthetic generation and import this real mbox file
      --keep             Don't delete the SQLite file at exit
      --db        PATH   Use this database path instead of a temp dir
"""

// MARK: - Memory measurement (resident set, MB)

func residentMemoryMB() -> Double {
    #if canImport(Darwin)
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
    let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    guard kerr == KERN_SUCCESS else { return 0 }
    return Double(info.resident_size) / (1024 * 1024)
    #else
    return 0
    #endif
}

// MARK: - Synthetic generator
// A pool of realistic-ish English tokens used to build subjects and bodies.
// The bodies are intentionally varied so FTS5 has real work to do.

let nounPool = [
    "invoice", "deadline", "budget", "proposal", "agreement", "contract",
    "meeting", "schedule", "project", "release", "incident", "review",
    "report", "audit", "compliance", "policy", "request", "approval",
    "payment", "discount", "renewal", "subscription", "shipment", "delivery",
    "feedback", "summary", "decision", "action", "milestone", "deliverable",
    "specification", "requirement", "vendor", "partner", "stakeholder",
]

let verbPool = [
    "review", "approve", "send", "share", "update", "finalize", "draft",
    "circulate", "schedule", "cancel", "postpone", "deliver", "ship",
    "process", "confirm", "decline", "investigate", "escalate", "resolve",
]

let adjPool = [
    "urgent", "quarterly", "annual", "preliminary", "final", "revised",
    "internal", "external", "confidential", "public", "draft", "tentative",
]

let domains = ["example.com", "acme.co", "globex.com", "initech.io", "umbrella.org",
               "stark.industries", "wayne.enterprises", "soylent.green"]

let folders = ["INBOX", "Sent", "Archive", "Projects", "Receipts", "Drafts"]

@inline(__always)
func pick<T>(_ a: [T], rng: inout SystemRandomNumberGenerator) -> T {
    a[Int.random(in: 0..<a.count, using: &rng)]
}

func makeBody(_ idx: Int, rng: inout SystemRandomNumberGenerator) -> String {
    let sentenceCount = 3 + Int.random(in: 0...5, using: &rng)
    var sentences: [String] = []
    sentences.reserveCapacity(sentenceCount)
    for _ in 0..<sentenceCount {
        let len = 6 + Int.random(in: 0...10, using: &rng)
        var words: [String] = []
        words.reserveCapacity(len)
        for _ in 0..<len {
            let bucket = Int.random(in: 0..<10, using: &rng)
            switch bucket {
            case 0...4: words.append(pick(nounPool, rng: &rng))
            case 5...7: words.append(pick(verbPool, rng: &rng))
            default:    words.append(pick(adjPool, rng: &rng))
            }
        }
        sentences.append(words.joined(separator: " ").capitalized + ".")
    }
    sentences.append("Reference number: \(idx).")
    return sentences.joined(separator: " ")
}

func makeMessage(accountID: Int64, index: Int, rng: inout SystemRandomNumberGenerator) -> IngestMessage {
    let subject = "\(pick(adjPool, rng: &rng).capitalized) \(pick(nounPool, rng: &rng)) #\(index)"
    let from = "\(pick(["alice", "bob", "carol", "dave", "eve", "frank"], rng: &rng))@\(pick(domains, rng: &rng))"
    let to = ["\(pick(["team", "ops", "legal", "finance"], rng: &rng))@\(pick(domains, rng: &rng))"]
    let folder = pick(folders, rng: &rng)
    let body = makeBody(index, rng: &rng)
    let date = Date(timeIntervalSinceReferenceDate: Double(index) * 60)
    return IngestMessage(
        accountID: accountID,
        folder: folder,
        messageID: "<msg-\(index)@stress.local>",
        subject: subject,
        fromAddress: from,
        toAddresses: to,
        date: date,
        sizeBytes: Int64(body.utf8.count + 256),
        plainBody: body
    )
}

// MARK: - Pretty printing

func fmt(_ n: Int) -> String {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    return f.string(from: NSNumber(value: n)) ?? "\(n)"
}
func fmt(_ n: Int64) -> String { fmt(Int(n)) }

func mb(_ bytes: Int64) -> String {
    String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
}

func ms(_ seconds: Double) -> String {
    String(format: "%.2f ms", seconds * 1000)
}

func rate(_ count: Int, seconds: Double) -> String {
    guard seconds > 0 else { return "∞ /s" }
    return "\(fmt(Int(Double(count) / seconds))) /s"
}

// MARK: - Run

let opts = StressOptions.parse(CommandLine.arguments)

let dbURL: URL = {
    if let path = opts.dbPath { return URL(fileURLWithPath: path) }
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("maxmail-stress-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("mail.sqlite")
}()

print("""
─────────────────────────────────────────────────────────────
 MaxMailCore stress harness
─────────────────────────────────────────────────────────────
 DB     : \(dbURL.path)
 Count  : \(fmt(opts.count)) messages
 Batch  : \(fmt(opts.batchSize)) per transaction
 Queries: \(opts.searchQueries) random FTS5 searches
─────────────────────────────────────────────────────────────
""")

let memBefore = residentMemoryMB()
print(String(format: "Memory at start: %.1f MB", memBefore))

let store = try MailStore(url: dbURL)
let accountID = try await store.upsertAccount(name: "Stress", address: "stress@local", kind: "synthetic")

// Ingest (synthetic generator or real mbox)
let t0 = Date()
var rng = SystemRandomNumberGenerator()
var ingested = 0
var batchPeakMem: Double = memBefore

if let mboxPath = opts.mboxPath {
    let url = URL(fileURLWithPath: mboxPath)
    let importer = MboxImporter(store: store, accountID: accountID,
                                options: .init(batchSize: opts.batchSize, folder: "INBOX"))
    let (got, skipped) = try await importer.importFile(at: url) { p in
        let pct = p.percentComplete * 100
        let rate = p.secondsElapsed > 0 ? Int(Double(p.messagesIngested) / p.secondsElapsed) : 0
        print(String(format: "  mbox %.1f%% — %@ ingested (%@ skipped)  %@/s",
                     pct, fmt(Int(p.messagesIngested)),
                     fmt(Int(p.messagesSkipped)), fmt(rate)))
        batchPeakMem = max(batchPeakMem, residentMemoryMB())
    }
    ingested = Int(got)
    print("  done: \(fmt(Int(got))) ingested, \(fmt(Int(skipped))) duplicates")
} else {
    var batch: [IngestMessage] = []
    batch.reserveCapacity(opts.batchSize)
    for i in 0..<opts.count {
        batch.append(makeMessage(accountID: accountID, index: i, rng: &rng))
        if batch.count >= opts.batchSize {
            _ = try await store.bulkIngest(batch)
            ingested += batch.count
            batch.removeAll(keepingCapacity: true)
            batchPeakMem = max(batchPeakMem, residentMemoryMB())
            let elapsed = -t0.timeIntervalSinceNow
            if ingested % (opts.batchSize * 4) == 0 || ingested == opts.count {
                print(String(format: "  ingested %@ / %@  (%.1fs, %@ ingest)",
                             fmt(ingested), fmt(opts.count), elapsed,
                             rate(ingested, seconds: elapsed)))
            }
        }
    }
    if !batch.isEmpty {
        _ = try await store.bulkIngest(batch)
        ingested += batch.count
    }
}
let ingestSeconds = -t0.timeIntervalSinceNow
let memAfterIngest = residentMemoryMB()

// Checkpoint WAL into the main DB so the file-size number reflects reality.
try await store.checkpoint()

let stats = try await store.stats()

print("""

─────────────────────────────────────────────────────────────
 Ingest complete
─────────────────────────────────────────────────────────────
 Inserted          : \(fmt(ingested))
 Wall time         : \(String(format: "%.2f", ingestSeconds))s
 Throughput        : \(rate(ingested, seconds: ingestSeconds))
 DB file size      : \(mb(stats.dbFileBytes))
 Bytes per message : \(String(format: "%.0f B", Double(stats.dbFileBytes) / Double(max(ingested, 1))))
 RSS peak (ingest) : \(String(format: "%.1f MB", batchPeakMem))
 RSS now           : \(String(format: "%.1f MB", memAfterIngest))
─────────────────────────────────────────────────────────────
""")

// Header pagination latency — keyset paginate the full folder in 50-row pages and time it.
let pageSize = 50
var pages = 0
var lastDate: Date? = nil
let pageT0 = Date()
while true {
    let page = try await store.headers(in: "INBOX", accountID: accountID, before: lastDate, limit: pageSize)
    if page.isEmpty { break }
    pages += 1
    lastDate = page.last?.date
    if pages > 50 { break } // cap so the harness doesn't try to paginate all 1M
}
let pageSeconds = -pageT0.timeIntervalSinceNow
print("""
 Pagination (INBOX)
   Pages walked  : \(pages) × \(pageSize) rows
   Wall time     : \(ms(pageSeconds)) total → \(ms(pageSeconds / Double(max(pages, 1))))/page
""")

// Search latency
let searchTerms = nounPool + verbPool
var latencies: [Double] = []
latencies.reserveCapacity(opts.searchQueries)

// The synthetic generator uses `index * 60` seconds since reference date.
// "N synthetic days" translates back to a since-date by counting backward
// from the last-ingested message's timestamp.
let since: Date? = opts.sinceDays.map { days in
    let lastDate = Date(timeIntervalSinceReferenceDate: Double(opts.count - 1) * 60)
    return lastDate.addingTimeInterval(-Double(days) * 86400)
}
for _ in 0..<opts.searchQueries {
    let q = "\(pick(searchTerms, rng: &rng)) \(pick(searchTerms, rng: &rng))"
    let qT0 = Date()
    _ = try await store.search(q, since: since, limit: 50)
    latencies.append(-qT0.timeIntervalSinceNow)
}
latencies.sort()
let p50 = latencies[latencies.count / 2]
let p95 = latencies[(latencies.count * 95) / 100]
let max_ = latencies.last ?? 0
let mean = latencies.reduce(0, +) / Double(latencies.count)

let windowLabel = opts.sinceDays.map { "last \($0)d" } ?? "all time"
print("""
 Search (FTS5, top-50 with snippet, weighted BM25, \(windowLabel))
   Queries       : \(opts.searchQueries)
   Mean / p50    : \(ms(mean)) / \(ms(p50))
   p95 / max     : \(ms(p95)) / \(ms(max_))
─────────────────────────────────────────────────────────────
 RSS final       : \(String(format: "%.1f MB", residentMemoryMB()))
─────────────────────────────────────────────────────────────
""")

if !opts.keepDB && opts.dbPath == nil {
    try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent())
}
