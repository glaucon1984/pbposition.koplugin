--[[--
PBReader position: keep the PocketBook library row of the open EPUB in step
with KOReader, including the place PBReader opens at.

Writes happen on book close, suspend, KOReader's periodic settings save and
explicit flushes (all arrive as the SaveSettings event), never per page turn.
At open (and after resume) a position written by PBReader since the plugin's
last write is offered, not applied silently.
]]

local Device = require("device")

if not Device:isPocketBook() then
    return { disabled = true, }
end

local ConfirmBox = require("ui/widget/confirmbox")
local DocSettings = require("docsettings")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

local EpubCfi = require("epubcfi")
local LibraryDB = require("librarydb")

local LAST_KEY = "pbposition_last" -- doc_settings: { ts=, position= } last written or acknowledged

local function currentProfileName()
    local ffi = require("ffi")
    local inkview = ffi.load("inkview")
    local name = inkview.GetCurrentProfile()
    if name ~= nil then return ffi.string(name) end
    return nil
end

-- One connection for the whole process (file manager and reader instances).
local db = LibraryDB.new{ profile_name_func = currentProfileName }

local PBPosition = WidgetContainer:extend{
    name = "pbposition",
    is_doc_only = false,
}

function PBPosition:init()
    self.ui.menu:registerToMainMenu(self)
    self:resetDocumentState()
end

function PBPosition:resetDocumentState()
    self.ready = false
    self.codec = nil
    self.book = nil       -- { id=, profile= } or false when the library has no row
    self.last = nil       -- last data written this session
    self.status = nil     -- last result, for the Status dialog
    self.offered_ts = nil -- PBReader position_ts already offered for this book
end

-- Settings -------------------------------------------------------------------

function PBPosition:isEnabled()
    return G_reader_settings:nilOrTrue("pbposition_enabled")
end

function PBPosition:offersNewer()
    return G_reader_settings:nilOrTrue("pbposition_offer")
end

function PBPosition:addToMainMenu(menu_items)
    menu_items.pbposition = {
        text = _("PBReader position"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Write position and progress for PBReader"),
                help_text = _("On book close, suspend and settings save, write the reading position PBReader opens at and the progress shown on the home screen into the PocketBook library database. EPUBs listed in the library only."),
                checked_func = function() return self:isEnabled() end,
                callback = function()
                    G_reader_settings:flipNilOrTrue("pbposition_enabled")
                end,
            },
            {
                text = _("Offer a newer PBReader position when opening"),
                help_text = _("When PBReader saved a position after this plugin's last write, ask whether to go there instead of jumping silently."),
                enabled_func = function() return self:isEnabled() end,
                checked_func = function() return self:offersNewer() end,
                callback = function()
                    G_reader_settings:flipNilOrTrue("pbposition_offer")
                end,
                separator = true,
            },
            {
                text = _("Write now"),
                enabled_func = function() return self.ready end,
                callback = function()
                    local ok, msg = self:sync("manual", true)
                    UIManager:show(InfoMessage:new{ text = msg, timeout = ok and 2 or 5 })
                end,
            },
            {
                text = _("Status"),
                keep_menu_open = true,
                callback = function()
                    UIManager:show(InfoMessage:new{ text = self:statusText() })
                end,
            },
        },
    }
end

function PBPosition:statusText()
    local lines = {}
    table.insert(lines, T(_("Library database: %1"), db.db_path))
    if db:disabled() then
        table.insert(lines, _("Database access disabled for this session after repeated errors."))
    end
    if not self.ui.document then
        table.insert(lines, _("No book open."))
    elseif not self:isEpub() then
        table.insert(lines, _("Not an EPUB: positions are written for EPUBs only."))
    elseif self.book == false then
        table.insert(lines, _("This book is not in the PocketBook library (no row to update)."))
    elseif self.book then
        table.insert(lines, T(_("Library book id %1, profile %2."), self.book.id, self.book.profile))
    end
    if self.last then
        table.insert(lines, T(_("Last write: page %1 of %2, %3"), self.last.cpage + 1, self.last.npage,
            self.last.position or _("no position (chapter could not be mapped)")))
    end
    if self.status then table.insert(lines, self.status) end
    return table.concat(lines, "\n")
end

-- Document identity -----------------------------------------------------------

function PBPosition:isEpub()
    local doc = self.ui.document
    if not doc or not self.ui.rolling or not doc.file then return false end
    return doc.file:lower():match("%.epub$") ~= nil
end

function PBPosition:isActive()
    return self:isEnabled() and self.ready and self:isEpub() and not db:disabled()
end

-- Folder (no trailing slash) and file name, as the library stores them.
function PBPosition:folderAndFile()
    local folder, file = util.splitFilePathName(self.ui.document.file)
    folder = folder:gsub("/+$", "")
    return folder, file
end

function PBPosition:bookRow()
    if self.book ~= nil then return self.book or nil end
    local folder, file = self:folderAndFile()
    local id = db:bookId(folder, file)
    if not id then
        logger.info("PBPosition: not in the PocketBook library, nothing to update:", folder .. "/" .. file)
        self.book = false
        return nil
    end
    self.book = { id = id, profile = db:profileId() }
    return self.book
end

function PBPosition:getCodec()
    if not self.codec then
        local doc = self.ui.document
        self.codec = EpubCfi.new(function(path) return doc:getDocumentFileContent(path) end)
    end
    return self.codec
end

-- Position mapping ------------------------------------------------------------

--- PBReader's position string for the current top-of-page xpointer.
--- @return string|nil position, boolean exact, string|nil note
function PBPosition:positionFromXPointer(xp)
    local doc = self.ui.document
    local codec = self:getCodec()
    local cfi, exact, note = codec:fromXPointer(xp)
    if not exact and type(doc.getEPubCFIFromXPointer) == "function" then
        -- Newer KOReader: CREngine can express the location itself. Keep our
        -- spine and body steps (the engine assumes /6 and /4) and drop the
        -- id assertions the engine adds.
        local ok, builtin = pcall(doc.getEPubCFIFromXPointer, doc, xp)
        local bare = ok and EpubCfi.barePath(builtin)
        local after = bare and bare:match("!/%d+(.*)$")
        if cfi and after then
            local head = EpubCfi.barePath(cfi):match("^(/%d+/%d+!/%d+)")
            if head then
                cfi, exact, note = "epubcfi(" .. head .. after .. ")", true, "engine CFI"
            end
        end
    end
    if not cfi then return nil, false, note end
    return LibraryDB.POSITION_PREFIX .. cfi, exact, note
end

--- KOReader xpointer for a PBReader position, degraded to the chapter start
--- when the exact place does not resolve in this rendering.
function PBPosition:xpointerFromPosition(position)
    if not EpubCfi.isCfi(position) then return nil end
    local doc = self.ui.document
    local codec = self:getCodec()
    local xp = codec:toXPointer(position)
    if not xp then return nil end
    local count = codec:spineCount()
    local k = tonumber(xp:match("^/body/DocFragment%[(%d+)%]"))
    if not k or (count and k > count) then return nil end
    -- getTextFromXPointer returns nil when the xpointer does not resolve
    if xp:find("/text()", 1, true) or xp:match("%]/[%w]+%[%d+%]$") then
        local ok, text = pcall(doc.getTextFromXPointer, doc, xp)
        if not ok or text == nil then
            xp = string.format("/body/DocFragment[%d]", k)
        end
    end
    return xp
end

-- Collecting what to write ------------------------------------------------------

function PBPosition:collect()
    local doc = self.ui.document
    local xp = doc:getXPointer()
    if not xp or xp == "" then return nil end
    local page = self.ui:getCurrentPage()
    local total
    local flow = doc:getPageFlow(page)
    if flow == 0 then
        total = doc:getTotalPagesInFlow(0)
        page = doc:getPageNumberInFlow(page)
    else
        total = doc:getPageCount()
    end
    if not total or total < 1 then return nil end
    local summary = self.ui.doc_settings:readSetting("summary")
    local completed = (summary and summary.status == "complete") or page >= total
    local now = os.time()
    local position, exact, note = self:positionFromXPointer(xp)
    return {
        xpointer = xp,
        cpage = math.max(page - 1, 0),
        npage = total,
        completed = completed and 1 or 0,
        opentime = now,
        position = position,
        position_ts = position and now or nil,
        exact = exact,
        note = note,
    }
end

-- The write ------------------------------------------------------------------------

--- @param source string for the log
--- @param force boolean write even when nothing changed
--- @return boolean ok, string message
function PBPosition:sync(source, force)
    if not self:isActive() then return false, _("PBReader position is off or not applicable.") end
    local data = self:collect()
    if not data then return false, _("No position to write.") end
    if not force and self.last and self.last.xpointer == data.xpointer
        and self.last.completed == data.completed then
        return true, _("Nothing changed since the last write.")
    end
    local book = self:bookRow()
    if not book then return false, _("This book is not in the PocketBook library.") end
    if not self.backup_checked then
        self.backup_checked = true
        if not db:backupOnce() then
            logger.warn("PBPosition: could not back up the library database; writing anyway")
        end
    end
    local t0 = os.clock()
    local ok = db:writeRow(book.id, book.profile, data)
    local ms = math.floor((os.clock() - t0) * 1000 + 0.5)
    if not ok then
        self.status = _("Last write failed; see crash.log.")
        return false, _("Database write failed.")
    end
    self.last = data
    if data.position then
        self.ui.doc_settings:saveSetting(LAST_KEY, { ts = data.position_ts, position = data.position })
    end
    logger.info(string.format("PBPosition: wrote book %d profile %d page %d/%d completed %d position %s%s in %d ms (%s)",
        book.id, book.profile, data.cpage + 1, data.npage, data.completed,
        tostring(data.position), data.exact and "" or (" [" .. tostring(data.note) .. "]"), ms, source))
    self.status = T(_("Last write: %1, %2 ms."), source, ms)
    return true, T(_("Written: page %1 of %2%3"), data.cpage + 1, data.npage,
        data.position and "" or _(", position not mapped"))
end

-- pocketbooktools (if still enabled) handles the same events after us and its
-- REPLACE INTO wipes `position`: put the pair back once this dispatch is over.
function PBPosition:repairAfterOthers()
    local last, book = self.last, self.book
    if not last or not last.position or not book then return end
    local PluginLoader = require("pluginloader")
    if not PluginLoader:getPluginInstance("pocketbooktools") then return end
    UIManager:nextTick(function()
        if db:writePosition(book.id, book.profile, last.position, last.position_ts) then
            logger.dbg("PBPosition: position re-written after pocketbooktools")
        end
    end)
end

-- Offering PBReader's newer position ------------------------------------------------

-- The moment our knowledge of this book dates from: our last write, else the
-- sidecar's modification time (the book was read in KOReader before this
-- plugin), else 0 (first opening in KOReader).
function PBPosition:baselineTimestamp()
    local last = self.ui.doc_settings:readSetting(LAST_KEY)
    if last and last.ts then return last.ts, last.position end
    local sidecar = DocSettings:findSidecarFile(self.ui.document.file)
    if sidecar then
        local lfs = require("libs/libkoreader-lfs")
        local mtime = lfs.attributes(sidecar, "modification")
        if mtime then return mtime, nil end
    end
    return 0, nil
end

function PBPosition:offerNewerPosition(trigger)
    if not self:isActive() or not self:offersNewer() then return end
    local book = self:bookRow()
    if not book then return end
    local row = db:readRow(book.id, book.profile)
    if not row or not row.position or not row.position_ts then return end
    if not EpubCfi.isCfi(row.position) then return end
    local baseline_ts, baseline_position = self:baselineTimestamp()
    if row.position_ts <= baseline_ts or row.position == baseline_position then return end
    if self.offered_ts == row.position_ts then return end
    self.offered_ts = row.position_ts

    local function acknowledge()
        self.ui.doc_settings:saveSetting(LAST_KEY, { ts = row.position_ts, position = row.position })
    end
    local xp = self:xpointerFromPosition(row.position)
    if not xp then
        logger.info("PBPosition: PBReader position not mappable, ignoring:", row.position)
        acknowledge()
        return
    end
    local doc = self.ui.document
    local page = doc:getPageFromXPointer(xp)
    if page == self.ui:getCurrentPage() then
        acknowledge()
        return
    end
    local chapter = self.ui.toc and self.ui.toc:getTocTitleByPage(xp) or ""
    local where = chapter ~= "" and T(_("%1, page %2 of %3"), chapter, page, doc:getPageCount())
        or T(_("page %1 of %2"), page, doc:getPageCount())
    logger.info("PBPosition: PBReader has a newer position", row.position, "->", xp, "page", page, "(" .. trigger .. ")")
    UIManager:show(ConfirmBox:new{
        text = T(_("PBReader has a newer reading position for this book:\n%1 (%2).\n\nGo there?"),
            where, os.date("%Y-%m-%d %H:%M", row.position_ts)),
        ok_text = _("Go there"),
        cancel_text = _("Stay here"),
        ok_callback = function()
            acknowledge()
            self.ui:handleEvent(Event:new("GotoXPointer", xp))
        end,
        cancel_callback = acknowledge,
    })
end

-- Events ------------------------------------------------------------------------

function PBPosition:onReaderReady()
    self:resetDocumentState()
    if not self:isEpub() then return end
    self.ready = true
    -- Give the reader a moment to settle before possibly showing a dialog.
    UIManager:scheduleIn(0.5, function()
        if self.ready then self:offerNewerPosition("open") end
    end)
end

function PBPosition:onSaveSettings()
    self:sync("save")
end

function PBPosition:onSuspend()
    if self:isActive() then
        self:sync("suspend")
        self:repairAfterOthers()
    end
end

function PBPosition:onResume()
    if self:isActive() then
        UIManager:scheduleIn(1, function()
            if self.ready then self:offerNewerPosition("resume") end
        end)
    end
end

function PBPosition:onCloseDocument()
    if self:isActive() then
        self:sync("close")
        self:repairAfterOthers()
    end
    self.ready = false
    self.codec = nil
end

return PBPosition
