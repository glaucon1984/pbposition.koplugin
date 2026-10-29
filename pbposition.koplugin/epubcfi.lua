--[[--
EPUB CFI codec for CREngine xpointers, in plain Lua.

PBReader (the PocketBook firmware reader) keeps its reading position as an
EPUB Canonical Fragment Identifier into the *source* EPUB, e.g.
`epubcfi(/6/14!/4/2/36/1:0)`: spine element of the OPF, 7th spine item,
chapter body, 1st element child, 18th element inside it, its first text
chunk, offset 0. KOReader's CREngine keeps the current place as an xpointer
into its own DOM, e.g. `/body/DocFragment[7]/body/div/p[18]/text().0`, with
per-tag ordinals. This module maps between the two by reading the OPF and the
chapter XHTML from the EPUB itself, through a `read(path)` function the
caller supplies (in KOReader: `document:getDocumentFileContent`).

Verified rules (see the project README):
  * spine step = 2 x (1-based index of <spine> among <package>'s element children)
  * spine item step = 2 x DocFragment ordinal (1-based)
  * body step = 2 x (1-based index of <body> among <html>'s element children)
  * element step 2m = the m-th element child, counting all element siblings
  * text step 2m+1 = the text chunk after m element siblings, ":offset" chars in
  * CREngine's boxing elements never appear in normalized xpointers; a
    non-normalized xpointer (old DOM version) falls back to the chapter start
  * `epubcfi(/6/14!)` (nothing after the "!") is the start of that chapter

No KOReader dependencies, so it runs under plain LuaJIT for tests.
]]

local EpubCfi = {}
EpubCfi.__index = EpubCfi

-- CREngine's internal wrapper elements; only present in non-normalized xpointers.
local BOXING = {
    autoBoxing = true, floatBox = true, inlineBox = true, tabularBox = true,
    mathBox = true, pseudoElem = true,
}

-- HTML void elements: a sloppy XHTML may leave them unclosed.
local VOID = {
    br = true, hr = true, img = true, input = true, meta = true, link = true,
    base = true, area = true, col = true, embed = true, param = true,
    source = true, track = true, wbr = true,
}

-- Elements CREngine renders inline by default: a leading whitespace-only text
-- chunk is kept there, while a block element drops it.
local INLINE = {
    a = true, abbr = true, b = true, bdi = true, bdo = true, big = true,
    cite = true, code = true, del = true, dfn = true, em = true, font = true,
    i = true, ins = true, kbd = true, mark = true, q = true, s = true,
    samp = true, small = true, span = true, strike = true, strong = true,
    sub = true, sup = true, time = true, tt = true, u = true, var = true,
}

-- Small helpers -------------------------------------------------------------

local function utf8len(s)
    local _, n = s:gsub("[^\128-\191]", "")
    return n
end

local NAMED_ENTITIES = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = "\194\160" }

local function utf8char(cp)
    if cp < 0x80 then return string.char(cp) end
    if cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
    end
    if cp < 0x10000 then
        return string.char(0xE0 + math.floor(cp / 0x1000), 0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
    end
    return string.char(0xF0 + math.floor(cp / 0x40000), 0x80 + math.floor(cp / 0x1000) % 0x40,
        0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
end

local function decodeEntities(s)
    if not s:find("&", 1, true) then return s end
    return (s:gsub("&(#?[%w]+);", function(e)
        if e:sub(1, 2) == "#x" or e:sub(1, 2) == "#X" then
            local cp = tonumber(e:sub(3), 16)
            return cp and utf8char(cp) or nil
        elseif e:sub(1, 1) == "#" then
            local cp = tonumber(e:sub(2))
            return cp and utf8char(cp) or nil
        end
        return NAMED_ENTITIES[e]
    end))
end

local function urlDecode(s)
    return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

local function dirname(path)
    return path:match("^(.*/)") or ""
end

-- Resolve href against the directory of the file that references it.
local function joinPath(dir, href)
    href = href:gsub("#.*$", "")
    href = urlDecode(decodeEntities(href))
    if href:sub(1, 1) == "/" then href = href:sub(2); dir = "" end
    local parts = {}
    for seg in (dir .. href):gmatch("[^/]+") do
        if seg == ".." then
            if #parts > 0 then table.remove(parts) end
        elseif seg ~= "." then
            table.insert(parts, seg)
        end
    end
    return table.concat(parts, "/")
end

-- Attribute lookup on the raw attribute text of a start tag.
local function attr(attrs, name)
    name = name:gsub("%W", "%%%0") -- "full-path": "-" is a quantifier in patterns
    local v = attrs:match("[%s/]" .. name .. "%s*=%s*\"([^\"]*)\"")
        or attrs:match("[%s/]" .. name .. "%s*=%s*'([^']*)'")
    return v and decodeEntities(v) or nil
end

local function localName(qname)
    qname = qname:lower()
    return qname:match("^[^:]*:(.*)$") or qname
end

-- Minimal XML/XHTML tokenizer ---------------------------------------------
-- Builds a tree of { name=, attrs=, children={} }; text pieces are strings,
-- one per parser text run (a comment between two text runs gives two pieces,
-- as in CREngine, where each run becomes its own text node).

local function parseXml(s)
    local root = { name = "#document", attrs = "", children = {} }
    local stack = { root }
    local len = #s
    local pos = 1

    local function current() return stack[#stack] end
    local function addText(t)
        if t == "" then return end
        local ch = current().children
        ch[#ch + 1] = t
    end
    local function closeTo(name)
        for i = #stack, 2, -1 do
            if stack[i].name == name then
                for _ = #stack, i, -1 do table.remove(stack) end
                return
            end
        end
    end

    while pos <= len do
        local lt = s:find("<", pos, true)
        if not lt then
            addText(s:sub(pos))
            break
        end
        if lt > pos then addText(s:sub(pos, lt - 1)) end
        local c = s:sub(lt + 1, lt + 1)
        if s:sub(lt, lt + 3) == "<!--" then
            local e = s:find("-->", lt + 4, true)
            pos = e and e + 3 or len + 1
        elseif s:sub(lt, lt + 8) == "<![CDATA[" then
            local e = s:find("]]>", lt + 9, true)
            addText(s:sub(lt + 9, (e or len + 1) - 1))
            pos = e and e + 3 or len + 1
        elseif c == "!" or c == "?" then
            local e = s:find(">", lt + 1, true)
            pos = e and e + 1 or len + 1
        elseif c == "/" then
            local e = s:find(">", lt + 2, true) or len + 1
            local name = s:sub(lt + 2, e - 1):match("^%s*([^%s]+)")
            if name then closeTo(localName(name)) end
            pos = e + 1
        else
            -- Start tag: find the closing ">" outside quotes.
            local e = s:find(">", lt + 1, true)
            while e do
                local inner = s:sub(lt + 1, e - 1)
                local _, dq = inner:gsub('"', "")
                local _, sq = inner:gsub("'", "")
                if dq % 2 == 0 and sq % 2 == 0 then break end
                e = s:find(">", e + 1, true)
            end
            e = e or len + 1
            local tag = s:sub(lt + 1, e - 1)
            pos = e + 1
            local selfclose = tag:sub(-1) == "/"
            if selfclose then tag = tag:sub(1, -2) end
            local qname = tag:match("^([^%s/>]+)")
            if qname then
                local node = {
                    name = localName(qname),
                    attrs = " " .. tag:sub(#qname + 1),
                    children = {},
                }
                local ch = current().children
                ch[#ch + 1] = node
                if not selfclose and not VOID[node.name] then
                    stack[#stack + 1] = node
                end
            end
        end
    end
    return root
end

local function elementChildren(node)
    local out = {}
    for _, ch in ipairs(node.children) do
        if type(ch) == "table" then out[#out + 1] = ch end
    end
    return out
end

local function firstChild(node, name)
    for _, ch in ipairs(node.children) do
        if type(ch) == "table" and ch.name == name then return ch end
    end
end

-- Depth-first search for the first element with this name.
local function findElement(node, name, depth)
    depth = depth or 0
    if depth > 8 then return nil end
    for _, ch in ipairs(node.children) do
        if type(ch) == "table" then
            if ch.name == name then return ch end
            local f = findElement(ch, name, depth + 1)
            if f then return f end
        end
    end
end

-- CREngine's parser flushes a text run into a new text node every this many
-- characters (lvxml.cpp TEXT_SPLIT_SIZE), on a word boundary near it.
local TEXT_SPLIT_SIZE = 8192

-- The text of an element's children, in both numberings at once.
-- A CFI text chunk is all the text between two element siblings:
-- chunk index m = number of element siblings before it (CFI step 2m+1),
-- offsets count from the chunk start. CREngine instead keeps one text node
-- per parser run (pieces split by comments, CDATA or the 8K flush), numbered
-- text()[ordinal], and drops a whitespace-only run that would be the first
-- child of a block element (ordinal nil here).
-- Returns { {m=, length=, pieces={ {ordinal=|nil, base=, length=} ... }} ... }
local function textChunks(node)
    local chunks = {}
    local elementsBefore = 0
    local textOrdinal = 0
    local chunk
    local noChildYet = true -- CREngine: _element->getChildCount()==0
    for _, ch in ipairs(node.children) do
        if type(ch) == "table" then
            elementsBefore = elementsBefore + 1
            chunk = nil
            noChildYet = false
        else
            if not chunk then
                chunk = { m = elementsBefore, length = 0, pieces = {} }
                chunks[#chunks + 1] = chunk
            end
            local len = utf8len(decodeEntities(ch))
            local kept = true
            if noChildYet and not INLINE[node.name] and ch:match("^%s*$") then
                kept = false
            end
            local remaining = len
            repeat
                local plen = math.min(remaining, TEXT_SPLIT_SIZE)
                if kept then textOrdinal = textOrdinal + 1 end
                chunk.pieces[#chunk.pieces + 1] = {
                    ordinal = kept and textOrdinal or nil,
                    base = chunk.length,
                    length = plen,
                }
                chunk.length = chunk.length + plen
                remaining = remaining - plen
            until remaining <= 0
            if kept then noChildYet = false end
        end
    end
    return chunks
end

-- The chunk and piece holding CREngine text node `ordinal` of this element.
local function findPieceByOrdinal(node, ordinal)
    for _, chunk in ipairs(textChunks(node)) do
        for _, piece in ipairs(chunk.pieces) do
            if piece.ordinal == ordinal then return chunk, piece end
        end
    end
end

-- Constructor and EPUB structure ------------------------------------------

--- @param read function(path) -> string|nil: a file inside the EPUB, path
--- relative to the archive root (already %-decoded).
function EpubCfi.new(read)
    return setmetatable({ read = read, chapters = {} }, EpubCfi)
end

function EpubCfi:readFile(path)
    local ok, data = pcall(self.read, path)
    if ok and data and data ~= "" then return data end
    return nil
end

--- The OPF: spine step and the spine items, cached.
--- @return table|nil {spine_step=, items={ {idref=, href=, path=} ... }, opf_path=}, error
function EpubCfi:package()
    if self.pkg then return self.pkg end
    if self.pkg_err then return nil, self.pkg_err end
    local function fail(msg)
        self.pkg_err = msg
        return nil, msg
    end
    local container = self:readFile("META-INF/container.xml")
    if not container then return fail("no META-INF/container.xml") end
    local opf_path
    local croot = parseXml(container)
    local cont = findElement(croot, "container") or croot
    local rootfiles = findElement(cont, "rootfiles")
    if rootfiles then
        for _, rf in ipairs(elementChildren(rootfiles)) do
            if rf.name == "rootfile" then
                local p = attr(rf.attrs, "full-path")
                local mt = attr(rf.attrs, "media-type")
                if p and (not opf_path or mt == "application/oebps-package+xml") then
                    opf_path = p
                end
            end
        end
    end
    if not opf_path then return fail("no rootfile in container.xml") end
    opf_path = urlDecode(opf_path)
    local opf = self:readFile(opf_path)
    if not opf then return fail("cannot read OPF " .. opf_path) end
    local oroot = parseXml(opf)
    local package = findElement(oroot, "package")
    if not package then return fail("no <package> in " .. opf_path) end

    local spine_step, manifest, spine
    local idx = 0
    for _, ch in ipairs(elementChildren(package)) do
        idx = idx + 1
        if ch.name == "spine" and not spine then
            spine = ch
            spine_step = 2 * idx
        elseif ch.name == "manifest" and not manifest then
            manifest = ch
        end
    end
    if not spine or not manifest then return fail("OPF without spine or manifest") end

    local hrefs = {}
    for _, item in ipairs(elementChildren(manifest)) do
        if item.name == "item" then
            local id, href = attr(item.attrs, "id"), attr(item.attrs, "href")
            if id and href then hrefs[id] = href end
        end
    end
    local dir = dirname(opf_path)
    local items = {}
    for _, ref in ipairs(elementChildren(spine)) do
        if ref.name == "itemref" then
            local idref = attr(ref.attrs, "idref")
            local href = idref and hrefs[idref]
            items[#items + 1] = {
                idref = idref,
                href = href,
                path = href and joinPath(dir, href) or nil,
            }
        end
    end
    self.pkg = { spine_step = spine_step, items = items, opf_path = opf_path }
    return self.pkg
end

--- The chapter made into DocFragment[k] (1-based), parsed, cached.
--- @return table|nil {path=, body=, body_step=}, error
function EpubCfi:chapter(k)
    local cached = self.chapters[k]
    if cached then return cached end
    local pkg, err = self:package()
    if not pkg then return nil, err end
    local item = pkg.items[k]
    if not item or not item.path then return nil, "no spine item " .. tostring(k) end
    local src = self:readFile(item.path)
    if not src and item.href then
        -- raw (still %-encoded) href, as crengine tries both forms too
        src = self:readFile(dirname(pkg.opf_path) .. item.href:gsub("#.*$", ""))
    end
    if not src then return nil, "cannot read " .. item.path end
    local root = parseXml(src)
    local html = firstChild(root, "html")
    local body, body_step
    if html then
        local i = 0
        for _, ch in ipairs(elementChildren(html)) do
            i = i + 1
            if ch.name == "body" then
                body, body_step = ch, 2 * i
                break
            end
        end
    end
    if not body then
        body = findElement(root, "body")
        body_step = 4
    end
    if not body then return nil, "no <body> in " .. item.path end
    local info = { path = item.path, body = body, body_step = body_step }
    self.chapters[k] = info
    return info
end

function EpubCfi:spineCount()
    local pkg = self:package()
    return pkg and #pkg.items or nil
end

-- Parsing the two string forms ---------------------------------------------

-- "/body/DocFragment[14]/body/div[2]/p[12]/text().120" ->
-- steps { {name=, idx=} ... }, offset (or nil)
local function parseXPointer(xp)
    local path, offset = xp:match("^(.-)%.(%d+)$")
    if not path then path = xp end
    local steps = {}
    for seg in path:gmatch("[^/]+") do
        local name, idx = seg:match("^([^%[]+)%[(%d+)%]$")
        if not name then name = seg end
        steps[#steps + 1] = { name = name, idx = tonumber(idx) or 1 }
    end
    return steps, tonumber(offset)
end

--- Strip "epubcfi(" ... ")" and any PBReader prefix, drop [assertions].
--- @return string|nil the bare path, e.g. "/6/14!/4/2/36/1:0"
function EpubCfi.barePath(cfi)
    if type(cfi) ~= "string" then return nil end
    local inner = cfi:match("epubcfi%((.-)%)%s*$") or cfi:match("epubcfi%((.*)$")
    if not inner then return nil end
    -- "^" escapes a special character; neutralize escaped brackets first
    inner = inner:gsub("%^(.)", function(c)
        if c == "[" then return "\1" elseif c == "]" then return "\2" end
        return c
    end)
    inner = inner:gsub("%b[]", "")
    inner = inner:gsub("[\1\2]", "")
    return inner
end

function EpubCfi.isCfi(position)
    return type(position) == "string" and position:find("epubcfi(", 1, true) ~= nil
end

--- "epubcfi(/6/14!/4/2/36/1:0)" -> "epubcfi(/6/14!)" (the start of that chapter)
function EpubCfi.chapterStart(cfi)
    local path = EpubCfi.barePath(cfi)
    if not path then return nil end
    local head = path:match("^(/%d+/%d+)!")
    return head and ("epubcfi(" .. head .. "!)") or nil
end

-- xpointer -> CFI ----------------------------------------------------------

--- @param xp string CREngine xpointer (normalized form)
--- @return string|nil cfi "epubcfi(...)", boolean exact (false when only the
---   chapter or an ancestor could be expressed), string|nil note
function EpubCfi:fromXPointer(xp)
    if type(xp) ~= "string" or xp == "" then return nil, false, "empty xpointer" end
    local steps, offset = parseXPointer(xp)
    if #steps < 2 or steps[1].name ~= "body" or steps[2].name ~= "DocFragment" then
        return nil, false, "not a DocFragment xpointer: " .. xp
    end
    local k = steps[2].idx
    local pkg = self:package()
    local spine_step = pkg and pkg.spine_step or 6
    local head = string.format("/%d/%d!", spine_step, 2 * k)
    local fallback = "epubcfi(" .. head .. ")"
    if not pkg then return fallback, false, "no OPF, spine step assumed 6" end
    if k > #pkg.items then return fallback, false, "DocFragment beyond spine" end
    if #steps < 3 or steps[3].name ~= "body" then
        return fallback, false, "xpointer not inside the chapter body"
    end
    for i = 3, #steps do
        if BOXING[steps[i].name] then
            return fallback, false, "non-normalized xpointer"
        end
    end
    local chapter, err = self:chapter(k)
    if not chapter then return fallback, false, err end

    local path = head .. "/" .. chapter.body_step
    local node = chapter.body
    local exact = true
    local note
    for i = 4, #steps do
        local step = steps[i]
        if step.name == "text()" then
            if i ~= #steps then
                exact, note = false, "text() not last"
                break
            end
            local chunk, piece = findPieceByOrdinal(node, step.idx)
            if not chunk then
                exact, note = false, "text node not found"
                break
            end
            local off = offset or 0
            if off > piece.length then off = piece.length end
            path = path .. string.format("/%d:%d", 2 * chunk.m + 1, piece.base + off)
        else
            local seen, position, target = 0, 0, nil
            for _, ch in ipairs(elementChildren(node)) do
                position = position + 1
                if ch.name == step.name then
                    seen = seen + 1
                    if seen == step.idx then target = ch; break end
                end
            end
            if not target then
                exact, note = false, "element not found: " .. step.name .. "[" .. step.idx .. "]"
                break
            end
            path = path .. "/" .. (2 * position)
            node = target
        end
    end
    return "epubcfi(" .. path .. ")", exact, note
end

-- CFI -> xpointer ----------------------------------------------------------

--- @param cfi string "epubcfi(...)" with or without PBReader's prefix
--- @return string|nil xpointer, boolean exact, string|nil note
function EpubCfi:toXPointer(cfi)
    local path = EpubCfi.barePath(cfi)
    if not path then return nil, false, "not a CFI" end
    local bang = path:find("!", 1, true)
    local spinePart = bang and path:sub(1, bang - 1) or path
    local chapterPart = bang and path:sub(bang + 1) or ""
    local nums = {}
    for n in spinePart:gmatch("/(%d+)") do nums[#nums + 1] = tonumber(n) end
    local N = nums[2]
    if not N or N <= 0 or N % 2 == 1 then return nil, false, "no spine item step" end
    local k = N / 2
    local xp = string.format("/body/DocFragment[%d]", k)
    local pkg = self:package()
    if pkg and k > #pkg.items then return nil, false, "spine item beyond spine" end
    local steps = {}
    for n, off in chapterPart:gmatch("/(%d+):?(%d*)") do
        steps[#steps + 1] = { n = tonumber(n), off = tonumber(off) }
    end
    if #steps == 0 then return xp, true end
    local chapter, err = self:chapter(k)
    xp = xp .. "/body"
    if not chapter then return xp, false, err end
    -- steps[1] is the <body>, whatever its number
    local node = chapter.body
    local exact = true
    local note
    for i = 2, #steps do
        local step = steps[i]
        if step.n % 2 == 0 then
            local m = step.n / 2
            local elems = elementChildren(node)
            local target = elems[m]
            if not target then
                exact, note = false, "element step beyond children"
                break
            end
            local ord = 0
            for j = 1, m do
                if elems[j].name == target.name then ord = ord + 1 end
            end
            xp = xp .. string.format("/%s[%d]", target.name, ord)
            node = target
        else
            local m = (step.n - 1) / 2
            local chunk
            for _, c in ipairs(textChunks(node)) do
                if c.m == m then chunk = c; break end
            end
            -- the piece holding the offset, or the next kept one after it
            local piece
            if chunk then
                local off = step.off or 0
                for j, p in ipairs(chunk.pieces) do
                    local inside = off < p.base + p.length or j == #chunk.pieces
                    if inside and p.ordinal then
                        piece = p
                        break
                    end
                end
            end
            if piece then
                local off = (step.off or 0) - piece.base
                if off < 0 then off = 0 end
                if off > piece.length then off = piece.length end
                xp = xp .. string.format("/text()[%d].%d", piece.ordinal, off)
            else
                -- No text node there: the next element child, if any.
                local elems = elementChildren(node)
                local nextEl = elems[m + 1]
                if nextEl then
                    local ord = 0
                    for j = 1, m + 1 do
                        if elems[j].name == nextEl.name then ord = ord + 1 end
                    end
                    xp = xp .. string.format("/%s[%d]", nextEl.name, ord)
                end
                exact, note = false, "no text node there"
            end
            if i ~= #steps then exact, note = false, "text step not last" end
            break
        end
    end
    return xp, exact, note
end

-- Exposed for tests
EpubCfi._parseXml = parseXml
EpubCfi._parseXPointer = parseXPointer
EpubCfi._textChunks = textChunks
EpubCfi._joinPath = joinPath

return EpubCfi
