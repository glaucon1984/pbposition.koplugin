-- PC tests for epubcfi.lua. Run from the repo root:
--   luajit test/run.lua                 synthetic fixture only
--   luajit test/run.lua <unzipped-epub>  also exercise a real, unpacked EPUB
package.path = "pbposition.koplugin/?.lua;" .. package.path
local EpubCfi = require("epubcfi")

local failures = 0
local function check(cond, msg)
    if cond then
        print("ok   " .. msg)
    else
        failures = failures + 1
        print("FAIL " .. msg)
    end
end
local function eq(a, b, msg)
    check(a == b, msg .. " [" .. tostring(a) .. " == " .. tostring(b) .. "]")
end

-- Synthetic fixture ---------------------------------------------------------
-- OPF with <guide> before <spine> (spine step 8), chapter 1 with <head>
-- (body step 4), chapter 2 without (body step 2), an unlinear item,
-- %-encoded href, comments, a void <br>, entities, a leading whitespace chunk.
local files = {}
files["META-INF/container.xml"] = [[<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OPS/book%20one.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>]]
files["OPS/book one.opf"] = [[<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
  <metadata><dc:title xmlns:dc="http://purl.org/dc/elements/1.1/">T</dc:title></metadata>
  <manifest>
    <item id="c1" href="text/ch%201.xhtml" media-type="application/xhtml+xml"/>
    <item id="c2" href="text/ch2.xhtml" media-type="application/xhtml+xml"/>
    <item id="notes" href="../notes.xhtml" media-type="application/xhtml+xml"/>
    <item id="css" href="style.css" media-type="text/css"/>
  </manifest>
  <guide><reference type="cover" href="text/ch%201.xhtml"/></guide>
  <spine toc="ncx">
    <itemref idref="c1"/>
    <itemref idref="notes" linear="no"/>
    <itemref idref="c2"/>
  </spine>
</package>]]
files["OPS/text/ch 1.xhtml"] = [[<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml">
<head><title>One</title><link rel="stylesheet" href="../style.css"/></head>
<body class="x" data-x="a > b">
  <div class="chapter">
    <h1 id="h">Chapter <span>One</span></h1>
    <!-- a comment -->
    <p>First paragraph &amp; more.</p>
    <p>Second <i>para</i>graph<br>with a void br and an &#x2014; dash.</p>
    <img src="a.png"/>
    <p>Third paragraph.</p>
    <p>Alpha <!-- split --> beta</p>
  </div>
  <div class="second"><p>In the second div.</p></div>
</body>
</html>]]
files["notes.xhtml"] = "<html><body><p>n</p></body></html>"
files["OPS/text/ch2.xhtml"] = [[<html xmlns="http://www.w3.org/1999/xhtml">
<body>
<p>No head here.</p>
<p>Two.</p>
</body>
</html>]]

local codec = EpubCfi.new(function(path) return files[path] end)

local pkg, err = codec:package()
check(pkg ~= nil, "package parsed " .. tostring(err))
eq(pkg.spine_step, 8, "spine step computed from <guide> before <spine>")
eq(#pkg.items, 3, "three spine items, non-linear included")
eq(pkg.items[1].path, "OPS/text/ch 1.xhtml", "%-encoded href resolved against OPF dir")
eq(pkg.items[2].path, "notes.xhtml", "../ href resolved")
eq(codec:chapter(1).body_step, 4, "body step 4 with <head>")
eq(codec:chapter(3).body_step, 2, "body step 2 without <head>")

-- element steps: body > div[1] (1st element child -> /2) > p[2] (h1,p,p -> 3rd element -> /6)
local cfi, exact, note = codec:fromXPointer("/body/DocFragment[1]/body/div/p[2]/text().7")
eq(cfi, "epubcfi(/8/2!/4/2/6/1:7)", "xpointer with text offset -> CFI")
check(exact, "exact mapping " .. tostring(note))

-- text after the <i>: p[2] children: "Second ", <i>, "graph", <br>, "with a void..."
cfi, exact = codec:fromXPointer("/body/DocFragment[1]/body/div/p[2]/text()[2].3")
eq(cfi, "epubcfi(/8/2!/4/2/6/3:3)", "second text chunk -> odd step 3")
cfi, exact = codec:fromXPointer("/body/DocFragment[1]/body/div/p[2]/text()[3].999")
eq(cfi, "epubcfi(/8/2!/4/2/6/5:29)", "third text chunk after <br>, offset clamped (entity decoded)")

-- a comment splits one CFI chunk into two CREngine text nodes: offsets add up
cfi, exact = codec:fromXPointer("/body/DocFragment[1]/body/div/p[4]/text()[2].2")
eq(cfi, "epubcfi(/8/2!/4/2/12/1:8)", "second text node after a comment -> same chunk, offset 6+2")
check(exact, "exact")
eq(codec:toXPointer("epubcfi(/8/2!/4/2/12/1:8)"), "/body/DocFragment[1]/body/div[1]/p[4]/text()[2].2", "chunk offset 8 -> 2nd node, offset 2")
eq(codec:toXPointer("epubcfi(/8/2!/4/2/12/1:3)"), "/body/DocFragment[1]/body/div[1]/p[4]/text()[1].3", "chunk offset 3 -> 1st node")
eq(codec:toXPointer("epubcfi(/8/2!/4/2/12/1:99)"), "/body/DocFragment[1]/body/div[1]/p[4]/text()[2].5", "offset past the end clamps to the last node")

-- element pointer without text (top of page at an element)
cfi, exact = codec:fromXPointer("/body/DocFragment[1]/body/div[2]/p")
eq(cfi, "epubcfi(/8/2!/4/4/2)", "second div, its p")
check(exact, "exact")

-- img is the 4th element child of div[1] -> /8
cfi = codec:fromXPointer("/body/DocFragment[1]/body/div/img")
eq(cfi, "epubcfi(/8/2!/4/2/8)", "void element counted as an element sibling")

-- chapter without head, DocFragment[3]
cfi, exact = codec:fromXPointer("/body/DocFragment[3]/body/p[2]/text().0")
eq(cfi, "epubcfi(/8/6!/2/4/1:0)", "chapter 3, body step 2")

-- fallbacks
cfi, exact, note = codec:fromXPointer("/body/DocFragment[1]/body/div/p[9]/text().0")
eq(cfi, "epubcfi(/8/2!/4/2)", "missing element -> nearest ancestor")
check(not exact, "inexact: " .. tostring(note))
cfi, exact, note = codec:fromXPointer("/body/DocFragment[1]/body/autoBoxing/p/text().0")
eq(cfi, "epubcfi(/8/2!)", "non-normalized xpointer -> chapter start")
cfi, exact, note = codec:fromXPointer("/body/DocFragment[7]/body/p")
eq(cfi, "epubcfi(/8/14!)", "DocFragment beyond spine -> chapter start with computed spine step")
eq(codec:fromXPointer("/body/div/p"), nil, "not a DocFragment xpointer -> nil")

-- reverse
local xp
xp, exact, note = codec:toXPointer("pbr:/webkit?##epubcfi(/8/2!/4/2/6/1:7)")
eq(xp, "/body/DocFragment[1]/body/div[1]/p[2]/text()[1].7", "CFI -> xpointer with PBReader prefix")
check(exact, "exact " .. tostring(note))
xp = codec:toXPointer("epubcfi(/8/2!/4[body]/2/6/3:3)")
eq(xp, "/body/DocFragment[1]/body/div[1]/p[2]/text()[2].3", "assertion stripped, 2nd text chunk")
xp = codec:toXPointer("epubcfi(/6/2!/1)")
eq(xp, "/body/DocFragment[1]/body", "PBReader cover value /6/2!/1 -> chapter body")
xp, exact = codec:toXPointer("epubcfi(/8/2!)")
eq(xp, "/body/DocFragment[1]", "chapter start -> DocFragment")
check(exact, "exact")
xp, exact = codec:toXPointer("epubcfi(/8/2!/4/1:0)")
eq(xp, "/body/DocFragment[1]/body/div[1]", "whitespace chunk the engine drops -> next element")
check(not exact, "inexact")
xp = codec:toXPointer("epubcfi(/8/6!/2/4/1:2)")
eq(xp, "/body/DocFragment[3]/body/p[2]/text()[1].2", "chapter without head")
eq(codec:toXPointer("pbr:/page?page=0"), nil, "non-CFI position -> nil")
eq(codec:toXPointer("epubcfi(/8/3!/4)"), nil, "odd spine item step -> nil")
eq(EpubCfi.chapterStart("pbr:/webkit?##epubcfi(/6/14!/4/2/36/1:0)"), "epubcfi(/6/14!)", "chapterStart")
eq(EpubCfi.barePath("epubcfi(/6/14!/4[a^]b]/2)"), "/6/14!/4/2", "escaped bracket inside assertion")

-- round trips over every text chunk of chapter 1
local function walk(node, xpath, visit)
    local ords = {}
    local texts = 0
    for _, ch in ipairs(node.children) do
        if type(ch) == "table" then
            ords[ch.name] = (ords[ch.name] or 0) + 1
            local p = xpath .. "/" .. ch.name .. "[" .. ords[ch.name] .. "]"
            visit(p)
            walk(ch, p, visit)
        end
    end
    for _, c in ipairs(EpubCfi._textChunks(node)) do
        for _, piece in ipairs(c.pieces) do
            if piece.ordinal then
                texts = texts + 1
                visit(xpath .. "/text()[" .. piece.ordinal .. "]." .. math.min(2, piece.length))
            end
        end
    end
end
local rt_total, rt_ok = 0, 0
walk(codec:chapter(1).body, "/body/DocFragment[1]/body", function(p)
    local c, ex = codec:fromXPointer(p)
    local back = codec:toXPointer(c)
    rt_total = rt_total + 1
    if ex and back == p then rt_ok = rt_ok + 1 else print("   round trip differs: " .. p .. " -> " .. tostring(c) .. " -> " .. tostring(back)) end
end)
eq(rt_ok, rt_total, "round trips on the synthetic chapter")

-- Real EPUB (unpacked directory) -------------------------------------------
local dir = arg[1]
if dir then
    print("\n== real EPUB at " .. dir)
    local real = EpubCfi.new(function(path)
        local f = io.open(dir .. "/" .. path, "rb")
        if not f then return nil end
        local d = f:read("*a")
        f:close()
        return d
    end)
    local t0 = os.clock()
    local rpkg, rerr = real:package()
    check(rpkg ~= nil, "package " .. tostring(rerr))
    if rpkg then
        print(string.format("   OPF %s, spine step %d, %d spine items, parsed in %.1f ms",
            rpkg.opf_path, rpkg.spine_step, #rpkg.items, (os.clock() - t0) * 1000))
        local total, ok = 0, 0
        local bodySteps = {}
        for k = 1, #rpkg.items do
            local t1 = os.clock()
            local ch, cerr = real:chapter(k)
            if not ch then
                print("   chapter " .. k .. ": " .. tostring(cerr))
            else
                bodySteps[ch.body_step] = (bodySteps[ch.body_step] or 0) + 1
                local n, good = 0, 0
                walk(ch.body, "/body/DocFragment[" .. k .. "]/body", function(p)
                    local c, ex = real:fromXPointer(p)
                    local back = real:toXPointer(c)
                    n = n + 1
                    if ex and back == p then good = good + 1
                    elseif n - good <= 2 then print("   differs: " .. p .. " -> " .. tostring(c) .. " -> " .. tostring(back)) end
                end)
                total, ok = total + n, ok + good
                if k <= 3 or k == #rpkg.items then
                    print(string.format("   chapter %d %s: body step %d, %d pointers, %d round-tripped, %.1f ms",
                        k, ch.path, ch.body_step, n, good, (os.clock() - t1) * 1000))
                end
            end
        end
        local bs = {}
        for step, count in pairs(bodySteps) do bs[#bs + 1] = step .. "x" .. count end
        print("   body steps: " .. table.concat(bs, ", "))
        eq(ok, total, "round trips over the whole book")
        -- a sample like the handoff's: chapter 7, body, 1st element, 18th element inside, text 0
        local sample = real:fromXPointer("/body/DocFragment[7]/body/div/p[18]/text().0")
        print("   sample /body/DocFragment[7]/body/div/p[18]/text().0 -> " .. tostring(sample))
    end
end

print(failures == 0 and "\nALL OK" or ("\n" .. failures .. " FAILURE(S)"))
os.exit(failures == 0 and 0 or 1)
