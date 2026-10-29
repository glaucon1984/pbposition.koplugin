--[[--
The PocketBook library database (`explorer-3.db`): book lookup and the
`books_settings` row PBReader and the home screen read.

Facts this relies on (verified on an Era Lite, firmware U710.6.11.2124):
  * `/mnt/ext1/system/explorer-3/explorer-3.db`, SQLite in WAL mode, owned by
    the firmware; `explorer-3.db.lock` next to it is the firmware's own lock.
  * `folders.name` is the directory without trailing slash, `files.filename`
    the file name, `files.book_id` the book; `profiles(id, name)`, the device
    usually has one profile `(1, 'default')`.
  * `books_settings(bookid, profileid, position TEXT, position_ts INTEGER,
    cpage, npage, opentime, completed, completed_ts, favorite, favorite_ts,
    custom)`, primary key (bookid, profileid). Triggers fill `completed_ts`.
    `cpage` is 0-based, `opentime` and `position_ts` are unix seconds.
  * PBReader restores its place from `position`; for EPUBs that is
    `pbr:/webkit?##epubcfi(...)`.
  * An UPSERT, never `REPLACE INTO`: REPLACE deletes the row first and wipes
    `favorite` and `position`.
]]

local logger = require("logger")

local LibraryDB = {}
LibraryDB.__index = LibraryDB

LibraryDB.DB_PATH = "/mnt/ext1/system/explorer-3/explorer-3.db"
LibraryDB.BACKUP_PATH = LibraryDB.DB_PATH .. ".before-pbposition"
LibraryDB.POSITION_PREFIX = "pbr:/webkit?##"
LibraryDB.BUSY_TIMEOUT_MS = 2000
LibraryDB.MAX_ERRORS = 3

local function num(v)
    if v == nil then return nil end
    return tonumber(v) -- int64 cdata from ljsqlite3 -> Lua number
end

--- @param opts table|nil { db_path=, backup_path=, profile_name_func=function() -> string|nil }
function LibraryDB.new(opts)
    opts = opts or {}
    return setmetatable({
        db_path = opts.db_path or LibraryDB.DB_PATH,
        backup_path = opts.backup_path or LibraryDB.BACKUP_PATH,
        profile_name_func = opts.profile_name_func,
        conn = nil,
        errors = 0,
        profile_id = nil,
    }, LibraryDB)
end

function LibraryDB:disabled()
    return self.errors >= LibraryDB.MAX_ERRORS
end

function LibraryDB:_fail(what, err)
    self.errors = self.errors + 1
    logger.warn("PBPosition: database", what, "failed:", tostring(err),
        self:disabled() and "(giving up for this session)" or "")
end

--- Opens the connection on first use. Returns the connection or nil.
function LibraryDB:open()
    if self.conn then return self.conn end
    if self:disabled() then return nil end
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(self.db_path, "mode") ~= "file" then
        logger.info("PBPosition: no library database at", self.db_path)
        self.errors = LibraryDB.MAX_ERRORS
        return nil
    end
    local ok, err = pcall(function()
        local SQ3 = require("lua-ljsqlite3/init")
        local conn = SQ3.open(self.db_path)
        conn:set_busy_timeout(LibraryDB.BUSY_TIMEOUT_MS)
        self.conn = conn
    end)
    if not ok then
        self:_fail("open", err)
        return nil
    end
    return self.conn
end

function LibraryDB:close()
    if self.conn then
        pcall(function() self.conn:close() end)
        self.conn = nil
    end
end

--- One-time snapshot of the database before the plugin's first write.
--- `VACUUM INTO` gives a consistent copy including the WAL; a plain file copy
--- (plus the -wal file) is the fallback.
function LibraryDB:backupOnce()
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(self.backup_path, "mode") == "file" then return true end
    local conn = self:open()
    if not conn then return false end
    local ok, err = pcall(function()
        conn:exec(string.format("VACUUM INTO '%s'", self.backup_path:gsub("'", "''")))
    end)
    if ok and lfs.attributes(self.backup_path, "mode") == "file" then
        logger.info("PBPosition: library database backed up to", self.backup_path)
        return true
    end
    logger.warn("PBPosition: VACUUM INTO failed (" .. tostring(err) .. "), copying the file instead")
    local ffiutil = require("ffi/util")
    local cerr = ffiutil.copyFile(self.db_path, self.backup_path)
    if cerr then
        logger.warn("PBPosition: database copy failed:", cerr)
        return false
    end
    if lfs.attributes(self.db_path .. "-wal", "mode") == "file" then
        ffiutil.copyFile(self.db_path .. "-wal", self.backup_path .. "-wal")
    end
    return true
end

-- Runs a prepared statement with bound values and returns the first row (or nil).
function LibraryDB:_row(sql, ...)
    local conn = self:open()
    if not conn then return nil, "no connection" end
    local row
    local args = { ... }
    local ok, err = pcall(function()
        local stmt = conn:prepare(sql)
        stmt:reset():bind(unpack(args))
        row = stmt:step()
        stmt:close()
    end)
    if not ok then
        self:_fail("query", err)
        return nil, err
    end
    self.errors = 0
    return row
end

--- The profile id for the current inkview profile, cached; 1 when unknown.
function LibraryDB:profileId()
    if self.profile_id then return self.profile_id end
    local name
    if self.profile_name_func then
        local ok, n = pcall(self.profile_name_func)
        if ok then name = n end
    end
    local id = 1
    if name and name ~= "" then
        local row = self:_row("SELECT id FROM profiles WHERE name = ? LIMIT 1", name)
        if row and row[1] then id = num(row[1]) end
    end
    self.profile_id = id
    return id
end

--- The library's book id for a file, or nil when the library has not indexed it.
--- @param folder string directory without trailing slash
--- @param filename string
function LibraryDB:bookId(folder, filename)
    local frow = self:_row("SELECT id FROM folders WHERE name = ? LIMIT 1", folder)
    if not frow or not frow[1] then return nil end
    local brow = self:_row("SELECT book_id FROM files WHERE folder_id = ? AND filename = ? LIMIT 1",
        frow[1], filename)
    if not brow or not brow[1] then return nil end
    return num(brow[1])
end

--- The books_settings row for a book, or nil when there is none.
--- @return table|nil { position=, position_ts=, cpage=, npage=, opentime=, completed=, favorite= }
function LibraryDB:readRow(book_id, profile_id)
    local row = self:_row([[
        SELECT position, position_ts, cpage, npage, opentime, completed, favorite
        FROM books_settings WHERE bookid = ? AND profileid = ? LIMIT 1
    ]], book_id, profile_id)
    if not row then return nil end
    return {
        position = row[1],
        position_ts = num(row[2]),
        cpage = num(row[3]),
        npage = num(row[4]),
        opentime = num(row[5]),
        completed = num(row[6]),
        favorite = num(row[7]),
    }
end

--- UPSERT of the progress fields and, when given, the position pair.
--- @param data table { cpage= (0-based), npage=, completed= 0/1, opentime=,
---   position= (full "pbr:/webkit?##epubcfi(...)" string) or nil, position_ts= or nil }
--- @return boolean success
function LibraryDB:writeRow(book_id, profile_id, data)
    local conn = self:open()
    if not conn then return false end
    local ffi = require("ffi")
    local function I(n) return ffi.new("int64_t", n) end
    local sql, args
    if data.position then
        sql = [[
            INSERT INTO books_settings (bookid, profileid, cpage, npage, completed, opentime, position, position_ts)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(bookid, profileid) DO UPDATE SET
                cpage = excluded.cpage, npage = excluded.npage, completed = excluded.completed,
                opentime = excluded.opentime, position = excluded.position, position_ts = excluded.position_ts
        ]]
        args = { I(book_id), I(profile_id), I(data.cpage), I(data.npage), I(data.completed),
            I(data.opentime), data.position, I(data.position_ts) }
    else
        sql = [[
            INSERT INTO books_settings (bookid, profileid, cpage, npage, completed, opentime)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(bookid, profileid) DO UPDATE SET
                cpage = excluded.cpage, npage = excluded.npage, completed = excluded.completed,
                opentime = excluded.opentime
        ]]
        args = { I(book_id), I(profile_id), I(data.cpage), I(data.npage), I(data.completed), I(data.opentime) }
    end
    local ok, err = pcall(function()
        local stmt = conn:prepare(sql)
        stmt:reset():bind(unpack(args)):step()
        stmt:close()
    end)
    if not ok then
        self:_fail("write", err)
        return false
    end
    self.errors = 0
    return true
end

--- Writes only the position pair (used to repair a row another plugin replaced).
function LibraryDB:writePosition(book_id, profile_id, position, position_ts)
    local conn = self:open()
    if not conn then return false end
    local ffi = require("ffi")
    local ok, err = pcall(function()
        local stmt = conn:prepare([[
            UPDATE books_settings SET position = ?, position_ts = ?
            WHERE bookid = ? AND profileid = ?
        ]])
        stmt:reset():bind(position, ffi.new("int64_t", position_ts),
            ffi.new("int64_t", book_id), ffi.new("int64_t", profile_id)):step()
        stmt:close()
    end)
    if not ok then
        self:_fail("position update", err)
        return false
    end
    self.errors = 0
    return true
end

return LibraryDB
