import Foundation
import SQLite3
import SwiftSonic

/// One SQLite catalog per account. Connections are short lived and work runs off MainActor.
/// Complete snapshots reconcile rows transactionally; unchanged payloads keep their search index.
nonisolated enum LibraryCatalogStore {
    struct StoreError: Error { let message: String }
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func open(_ url: URL) throws -> OpaquePointer {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db else { if let db { sqlite3_close(db) }; throw StoreError(message: "Cannot open catalog") }
        sqlite3_busy_timeout(db, 5000)
        do {
            try exec(db, """
                CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, payload TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS entries (kind TEXT NOT NULL, id TEXT NOT NULL, ordinal INTEGER NOT NULL,
                    payload TEXT NOT NULL, terms TEXT NOT NULL, visible INTEGER NOT NULL DEFAULT 1, PRIMARY KEY(kind,id));
                CREATE VIRTUAL TABLE IF NOT EXISTS search USING fts5(terms, tokenize='trigram');
                CREATE TRIGGER IF NOT EXISTS entries_ai AFTER INSERT ON entries BEGIN
                    INSERT INTO search(rowid,terms) VALUES(new.rowid,new.terms); END;
                CREATE TRIGGER IF NOT EXISTS entries_ad AFTER DELETE ON entries BEGIN
                    DELETE FROM search WHERE rowid=old.rowid; END;
                CREATE TRIGGER IF NOT EXISTS entries_au AFTER UPDATE OF terms ON entries WHEN old.terms != new.terms BEGIN
                    DELETE FROM search WHERE rowid=old.rowid;
                    INSERT INTO search(rowid,terms) VALUES(new.rowid,new.terms); END;
                """)
            return db
        } catch { sqlite3_close(db); throw error }
    }
    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw StoreError(message: String(cString: sqlite3_errmsg(db))) }
    }
    private static func statement(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var value: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &value, nil) == SQLITE_OK, let value else {
            throw StoreError(message: String(cString: sqlite3_errmsg(db)))
        }
        return value
    }
    private static func bind(_ value: String, to stmt: OpaquePointer, at index: Int32) {
        _ = value.withCString { sqlite3_bind_text(stmt, index, $0, -1, transient) }
    }
    private static func string(_ stmt: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(stmt, column).map { String(cString: $0) } ?? ""
    }
    private static func run(_ db: OpaquePointer, _ stmt: OpaquePointer) throws {
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw StoreError(message: String(cString: sqlite3_errmsg(db))) }
    }

    static func storedTokens(at url: URL) throws -> [String: [String: [String]]] {
        let db = try open(url); defer { sqlite3_close(db) }
        let stmt = try statement(db, "SELECT kind,id,terms FROM entries")
        defer { sqlite3_finalize(stmt) }
        var result: [String: [String: [String]]] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            result[string(stmt, 0), default: [:]][string(stmt, 1)] = string(stmt, 2).components(separatedBy: "\n")
        }
        return result
    }

    static func save(_ snapshot: LibraryIndexService.Snapshot, to url: URL) throws {
        let db = try open(url); defer { sqlite3_close(db) }
        try exec(db, "BEGIN IMMEDIATE; CREATE TEMP TABLE seen(kind TEXT, id TEXT, PRIMARY KEY(kind,id));")
        do {
            let upsert = try statement(db, """
                INSERT INTO entries(kind,id,ordinal,payload,terms,visible) VALUES(?,?,?,?,?,?)
                ON CONFLICT(kind,id) DO UPDATE SET ordinal=excluded.ordinal,payload=excluded.payload,
                    terms=excluded.terms,visible=excluded.visible
                WHERE entries.payload != excluded.payload OR entries.ordinal != excluded.ordinal OR entries.visible != excluded.visible
                """)
            let seen = try statement(db, "INSERT OR IGNORE INTO seen VALUES(?,?)")
            let existing = try statement(db, "SELECT payload,terms FROM entries WHERE kind=? AND id=?")
            defer { sqlite3_finalize(upsert); sqlite3_finalize(seen); sqlite3_finalize(existing) }
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            func insert<T: Encodable>(_ values: [T], kind: String, id: (T) -> String, text: (T) -> String, visible: (T) -> Bool = { _ in true }) throws {
                for (index, value) in values.enumerated() {
                    try Task.checkCancellation()
                    sqlite3_reset(upsert); sqlite3_clear_bindings(upsert)
                    bind(kind, to: upsert, at: 1); bind(id(value), to: upsert, at: 2)
                    sqlite3_bind_int64(upsert, 3, Int64(index))
                    let payload = String(decoding: try encoder.encode(value), as: UTF8.self)
                    sqlite3_reset(existing); bind(kind, to: existing, at: 1); bind(id(value), to: existing, at: 2)
                    let unchanged = sqlite3_step(existing) == SQLITE_ROW && string(existing, 0) == payload
                    let terms = unchanged ? string(existing, 1) : HangulRomanization.searchTokens(text(value)).joined(separator: "\n")
                    bind(payload, to: upsert, at: 4)
                    bind(terms, to: upsert, at: 5)
                    sqlite3_bind_int(upsert, 6, visible(value) ? 1 : 0)
                    try run(db, upsert)
                    sqlite3_reset(seen); bind(kind, to: seen, at: 1); bind(id(value), to: seen, at: 2); try run(db, seen)
                }
            }
            let presented = snapshot.albumCatalog.map { Set(AtmosAlbumPolicy.presented($0).map(\.id)) }
            try insert(snapshot.artists, kind: "artist", id: { $0.id }, text: { $0.name })
            try insert(snapshot.albums, kind: "album", id: { $0.id }, text: { "\($0.name) \($0.artist ?? "")" }, visible: { presented?.contains($0.id) ?? true })
            try insert(snapshot.playlists, kind: "playlist", id: { $0.id }, text: { $0.name })
            try insert(snapshot.songs, kind: "song", id: { $0.id }, text: { "\($0.title) \($0.artist ?? "") \($0.albumName ?? "") \($0.genre ?? "")" })
            try exec(db, "DELETE FROM entries WHERE NOT EXISTS(SELECT 1 FROM seen WHERE seen.kind=entries.kind AND seen.id=entries.id)")
            var metadata = snapshot
            metadata.artists = []; metadata.albums = []; metadata.playlists = []; metadata.songs = []
            let stmt = try statement(db, "INSERT OR REPLACE INTO metadata VALUES('snapshot',?)")
            defer { sqlite3_finalize(stmt) }
            bind(String(decoding: try encoder.encode(metadata), as: UTF8.self), to: stmt, at: 1)
            try run(db, stmt)
            try Task.checkCancellation()
            try exec(db, "COMMIT")
        } catch { try? exec(db, "ROLLBACK"); throw error }
    }

    static func load(from url: URL) throws -> LibraryIndexService.Snapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let db = try open(url); defer { sqlite3_close(db) }
        let stmt = try statement(db, "SELECT payload FROM metadata WHERE key='snapshot'")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        var snapshot = try JSONDecoder().decode(LibraryIndexService.Snapshot.self, from: Data(string(stmt, 0).utf8))
        func rows<T: Decodable>(_ kind: String, as: T.Type) throws -> [T] {
            let stmt = try statement(db, "SELECT payload FROM entries WHERE kind=? ORDER BY ordinal")
            defer { sqlite3_finalize(stmt) }; bind(kind, to: stmt, at: 1)
            var rows: [T] = []
            while sqlite3_step(stmt) == SQLITE_ROW { rows.append(try JSONDecoder().decode(T.self, from: Data(string(stmt, 0).utf8))) }
            return rows
        }
        snapshot.artists = try rows("artist", as: LibraryIndexService.IndexedArtist.self)
        snapshot.albums = try rows("album", as: LibraryIndexService.IndexedAlbum.self)
        snapshot.playlists = try rows("playlist", as: LibraryIndexService.IndexedPlaylist.self)
        snapshot.songs = try rows("song", as: DisplayableSong.self)
        return snapshot
    }

    static func search(_ query: String, limit: Int, at url: URL) throws -> LibraryIndexService.LocalHits {
        let db = try open(url); defer { sqlite3_close(db) }
        let tokens = HangulRomanization.searchTokens(query)
        func rows<T: Decodable>(_ kind: String, as: T.Type) throws -> [T] {
            guard !tokens.isEmpty, limit > 0 else { return [] }
            // Trigrams preserve substring semantics, including Hangul. One/two-character
            // queries use SQLite substring matching, since FTS has no trigram for them.
            let clauses = tokens.map { $0.count >= 3 ? "rowid IN (SELECT rowid FROM search WHERE search MATCH ?)" : "instr(terms,?) > 0" }
            let stmt = try statement(db, "SELECT payload FROM entries WHERE kind=? AND visible=1 AND (\(clauses.joined(separator: " OR "))) ORDER BY ordinal LIMIT ?")
            defer { sqlite3_finalize(stmt) }; bind(kind, to: stmt, at: 1)
            for (i, token) in tokens.enumerated() {
                bind(token.count >= 3 ? "\"" + token.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : token, to: stmt, at: Int32(i + 2))
            }
            sqlite3_bind_int64(stmt, Int32(tokens.count + 2), Int64(limit))
            var result: [T] = []
            var status = sqlite3_step(stmt)
            while status == SQLITE_ROW {
                try Task.checkCancellation()
                result.append(try JSONDecoder().decode(T.self, from: Data(string(stmt, 0).utf8)))
                status = sqlite3_step(stmt)
            }
            guard status == SQLITE_DONE else { throw StoreError(message: String(cString: sqlite3_errmsg(db))) }
            return result
        }
        return try .init(artists: rows("artist", as: LibraryIndexService.IndexedArtist.self),
                         albums: rows("album", as: LibraryIndexService.IndexedAlbum.self),
                         playlists: rows("playlist", as: LibraryIndexService.IndexedPlaylist.self),
                         songs: rows("song", as: DisplayableSong.self))
    }
}
