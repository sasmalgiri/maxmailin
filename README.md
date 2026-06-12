# maxmailin

A full-fledged Apple-platform mail client that scales to **1 TB+** archives, with the AI and forensic capabilities of [`mailin`](https://github.com/sasmalgiri/mailin) layered on top.

> Where `mailin` is an offline, evidence-grade archive viewer (bounded by RAM and a 500 MB store cap), `maxmailin` is built foundation-up for live accounts (IMAP / JMAP / Gmail API / Microsoft Graph) and terabyte-scale mailboxes — using a SQLite + FTS5 core, content-addressed blob storage, and streaming everywhere.

## Status

Phase 1 — **storage foundation**. Nothing here is a usable app yet. The first thing being built is the core data layer (`MaxMailCore`) that the entire client will sit on top of.

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
Sources/MaxMailCore/
  SQLite/      → thin sqlite3 C-API wrapper
  Models/      → MailMessage, MailFolder, Account types
  Store/       → MailStore actor (schema, ingest, query, search)
Tests/MaxMailCoreTests/
```

## License

Proprietary — same as `mailin`.
