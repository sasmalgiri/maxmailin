# maxmailin

A full-fledged Apple-platform mail client with the AI and forensic
capabilities of [`mailin`](https://github.com/sasmalgiri/mailin) layered
on top, and a bounded-RAM storage engine measured to ingest **10 M
messages at 10.8 k msg/sec while resident memory stays under 100 MB**
(see [Measured scale](#measured-scale-2026-06)).

> Where `mailin` is an offline, evidence-grade archive viewer (bounded by RAM and a 500 MB store cap), `maxmailin` is built foundation-up for live accounts (IMAP / JMAP / planned Gmail API + Microsoft Graph) and multi-million-message archives — using a SQLite + FTS5 core, content-addressed blob storage, and streaming everywhere.

## Status

Mac-only desktop client with the full forensic suite, threading, snooze,
spam, and the Add-Account wizard. 230+ unit tests, all green.

- **MaxMailCore** — SQLite + per-month FTS5 shards (denormalised
  UNINDEXED columns so search never JOINs back to `messages`),
  content-addressed BlobStore, streaming mbox + .emlx parsers with
  RFC 5322 + MIME multipart, JMAP / IMAP / SMTP wire layers, HMAC-chained
  audit log, signed export bundles, ChainOfCustody / Bates / GDPR /
  InvestigationReport / EncryptedStorage / Duplicate / Entity engines.
- **MaxMailApp** — SwiftUI three-pane (folders / list / detail) on macOS.
  Persistent store at `~/Library/Application Support/maxmailin/mail.sqlite`.
  Reachable from the toolbar or ⌘K: mbox import, JMAP / IMAP push,
  Insights dashboard, Forensic Center, Add-Account wizard.
- **maxmail-stress** — synthetic scale harness + `--mbox` real-archive ingest.

## Measured scale (2026-06)

Numbers below are from a release-build `maxmail-stress` run on this machine,
not extrapolation. Harness writes synthetic mail through the same
`MailStore.bulkIngest` path the .mbox importer uses.

| Corpus | Ingest | RSS peak | DB file | List paginate | FTS5 search (all time, p50) |
|--------|--------|----------|---------|---------------|-----------------------------|
| **1 M messages** | 11,084 msg/sec | 80.7 MB | 1.95 GB | 0.10 ms/page | 271 ms |
| **10 M messages** | 10,818 msg/sec | 92.2 MB | 19.65 GB | 0.11 ms/page | 8.41 s |

Reproduce:

```
swift build -c release --product maxmail-stress
.build/release/maxmail-stress -n 10000000 -b 10000 -q 100
```

### What this measures, honestly

- **Ingest** sustains ~11k msg/sec from 0 → 10 M with no degradation.
  Memory stays bounded at ~92 MB resident throughout — the entire archive
  never lives in RAM, which is what "scales to 1 TB" actually requires.
  Extrapolated to 1 TB at ~70 KB/msg ≈ 14 M messages, the storage layer
  is ready; the limit at that point is disk space, not the engine.
- **List pagination** stays sub-millisecond per 50-row page even at 10 M
  because keyset (`WHERE date_unix < ?`) hits the existing index.
- **Search (all-time, p50)** is the honest weak spot. At 1 M the
  user-facing search is interactive (~270 ms); at 10 M an unwindowed
  search across every month-shard sits around 8 s because the
  cross-shard merge cost grows super-linearly with shard count.
  Mitigation in the UI is to default search to a date window
  ("last 30 days") — that path scans only the relevant shards and
  the existing `since:` filter pushes the cost back to interactive.
- **RSS at start / after queries**: 25 / 235 MB. The post-query bump
  is one-time and comes from Apple framework caches; ingest itself
  never grows.

## Architecture

```
┌─────────────────────────────────────────────────┐
│                    App (TBD)                    │  SwiftUI app — Mac/iPad/iPhone/Vision
├─────────────────────────────────────────────────┤
│  Account Providers   │  AI / Forensic Modules   │  IMAP, JMAP, Gmail API, Graph, iCloud
├─────────────────────────────────────────────────┤
│                  MaxMailCore                    │  ← you are here
│  ┌────────────┐  ┌─────────────┐  ┌──────────┐  │
│  │ MailStore  │  │ FTS5 Index  │  │ BlobStore│  │
│  │  (SQLite)  │  │             │  │ (SHA-256)│  │
│  └────────────┘  └─────────────┘  └──────────┘  │
└─────────────────────────────────────────────────┘
```

## Foundational rules (non-negotiable)

1. **The whole archive never lives in RAM.** Cursors, pages, streams — never `[Message]` for the full mailbox.
2. **SQLite + FTS5 is the source of truth** for messages and search. No JSON-blob persistence.
3. **Bodies and attachments are blobs**, content-addressed by SHA-256, deduplicated.
4. **Ingest is idempotent and streaming** — re-ingesting the same message is a no-op.
5. **Every store API is `async`** and runs through one actor per store instance.

## Comparison to `mailin`

| | `mailin` | `maxmailin` |
|---|---|---|
| Store | single JSON.lz, 500 MB cap | SQLite WAL, unbounded |
| Index | in-RAM dictionaries | FTS5 on disk, incremental |
| Memory ceiling | grows with mailbox | bounded, predictable |
| Network | no entitlement | live accounts (later phase) |
| AI/forensic features | rich (port them on top of new core) | will inherit them |

## Project layout

```
Sources/
  MaxMailCore/
    SQLite/    → thin sqlite3 C-API wrapper
    Models/    → IngestMessage, MessageHeader, AttachmentIn/Ref, SearchHit
    Store/     → MailStore actor, BlobStore (SHA-256 content-addressed)
    Import/    → MboxStream (mmap), RFC5322Parser, MIMEParser, MboxImporter
  MaxMailStress/    → CLI scale harness (synthetic + --mbox)
  MaxMailApp/       → SwiftUI app (macOS first cut: three-pane, import, search)
Tests/MaxMailCoreTests/
```

## Running the app

Fastest dev loop (SPM debug, no bundle):

```
make run
# or:  swift run maxmail-app
```

Build a proper `.app` bundle (release-optimized + ad-hoc codesigned):

```
make app
open build/maxmailin.app
```

Install into `/Applications`:

```
make install
```

Then use **Import mbox…** in the toolbar (or ⌘I) to bring an archive in.
The store persists at `~/Library/Application Support/maxmailin/mail.sqlite`.

### Real JMAP account

1. Toolbar → **gear** → enter session URL (e.g. `https://api.fastmail.com/.well-known/jmap`),
   bearer token, and sender email. Token lives in the system Keychain.
2. Toolbar → **Refresh** (⌘R) syncs mailboxes via `Email/changes` (or
   `Email/query` + `Email/get` on first run).
3. ⌘N to compose, right-click any message to Reply / Forward / mark read.

## License

Proprietary — same as `mailin`.
