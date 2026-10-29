# pbposition.koplugin — PBReader position sync for KOReader on PocketBook

A [KOReader](https://koreader.rocks) plugin for PocketBook e-readers. When you
read an EPUB in KOReader it writes, into the firmware's library database, the
place **PBReader** (the stock reader) opens the book at, together with the
progress the home screen shows. Open the same book in PBReader and it
continues where KOReader left off; open it in KOReader after reading a bit in
PBReader and the plugin offers the newer position.

It replaces the library-progress sync of
[pocketbooktools.koplugin](https://github.com/reuerendo/pocketbooktools.koplugin)
(same row, same fields, plus the position) and does not depend on it; see
[Replacing pocketbooktools](#replacing-pocketbooktools).

Written for the PocketBook Era Lite (PB710, firmware U710.6.11.2124,
KOReader v2026.07.2) and verified there on 2026-10-29 with pocketbooktools
removed: KOReader's place comes up in PBReader and a newer PBReader position
is offered in KOReader. The CFI mapping was also checked on the PC against two
real EPUBs (every pointer round-trips). Other devices and firmware
generations are untested; see [Testing](#testing).

## What it writes

The library database `/mnt/ext1/system/explorer-3/explorer-3.db` has one row
per book and profile in `books_settings`. The plugin owns that row for the book
being read and writes all of these in one statement:

| Column | Value |
|---|---|
| `cpage`, `npage` | current page − 1 (the column is 0-based) and the page count, from KOReader's linear flow |
| `completed` | 1 when KOReader's status is *Finished* or the last page is reached |
| `opentime` | now (orders the home screen's "last read") |
| `position` | `pbr:/webkit?##epubcfi(/6/14!/4/2/36/1:0)`: an EPUB CFI into the source EPUB, which is what PBReader restores its place from |
| `position_ts` | now, when a position was written |

It is an UPSERT (`INSERT … ON CONFLICT DO UPDATE`), so `favorite` and anything
else in the row survive. Before its first write the plugin copies the database
once to `explorer-3.db.before-pbposition` (`VACUUM INTO`, consistent with the
WAL; a plain copy as fallback).

It writes when KOReader saves the book's settings: on book close, when the
device goes to sleep (the firmware's background event flushes settings), on
KOReader's periodic auto-save (default every 15 min) and on an explicit
"save book metadata". Never per page turn; a write that would repeat the last
one is skipped. Each write is logged in `crash.log` as
`PBPosition: wrote book 497 profile 1 page 143/496 … in 20 ms (save)`.

Books the library has not indexed (just copied, or outside the library
folders) have no `files` row and are skipped quietly. Non-EPUB formats are not
touched: PBReader uses other position schemes for them.

## The newer-position offer

PBReader writes `position` as soon as a book is opened there. When you open a
book in KOReader and the row's `position_ts` is newer than the plugin's last
write (or, before any write, newer than KOReader's own sidecar file), a dialog
names the chapter and page and asks *Go there* / *Stay here*. Nothing jumps
silently. The same check runs after the device wakes up. It can be turned off
in the menu.

## Install

1. Copy the `pbposition.koplugin` folder (the one with `main.lua`) to
   `applications/koreader/plugins/` on the device (`L:\applications\koreader\plugins\pbposition.koplugin\` over USB).
2. Restart KOReader. The menu is under *Tools → PBReader position* (wrench
   tab), with the two toggles, *Write now* and *Status*.
3. **Remove or disable `pocketbooktools.koplugin`** if you have it; see the
   next section.

### Replacing pocketbooktools

This plugin takes over pocketbooktools' library-progress feature: it writes
the same `books_settings` row with the same progress fields (`cpage`,
`npage`, `completed`, `opentime`) and adds `position` / `position_ts`, from
the same KOReader events, with no dependency on pocketbooktools being
installed. Two things it does differently on purpose: it uses an UPSERT where
pocketbooktools uses `REPLACE INTO` (which deletes the row first and so wipes
`position` and `favorite` on every write), and it writes `cpage` 0-based for
every page (pocketbooktools only maps page 1 to 0; every other page is written
1-based, one page ahead).

So **remove pocketbooktools, or disable it** (*Tools → More tools → Plugin
management*), and let this plugin own the row. Its other features
(PocketBook-style dialogs, book summary, collection cleanup, the boot-logo
page snapshot) go with it; this plugin does not reimplement them.

If both are left enabled, the row still ends up right: plugins receive
events in path order, pocketbooktools' REPLACE runs after this plugin's
write, and this plugin re-writes the position pair from the next UI tick
after the close and suspend events when it sees pocketbooktools loaded. That
is a safety net, not the intended setup.

## How the position is built

PBReader's CFI points into the source EPUB, so it is independent of layout.
KOReader's CREngine keeps the current place as an xpointer into its own DOM
(`/body/DocFragment[7]/body/div/p[18]/text().0`), with per-tag ordinals and
one `DocFragment` per spine item. The plugin reads the OPF and the chapter's
XHTML straight out of the open EPUB (`document:getDocumentFileContent`, no
unpacking) and maps:

1. **Spine step:** 2 × the position of `<spine>` among `<package>`'s element
   children, read from the OPF (`/6` for the usual order; some books put
   `<guide>` first).
2. **Spine item:** `/2k` for `DocFragment[k]`.
3. **Body step:** 2 × the position of `<body>` among `<html>`'s children,
   from the chapter source (`/4` with a `<head>`, `/2` without).
4. **Elements:** each even step `2m` is the m-th element child counting all
   element siblings; the xpointer's `p[18]` becomes the index of that `<p>`
   among all its siblings.
5. **Text:** odd step `2m+1` is the text after `m` element siblings, with
   `:offset` characters in. CREngine makes one text node per parser text run
   (a comment or an 8 K flush splits them), the CFI counts all text between
   two elements as one chunk; the plugin keeps both numberings.
6. **Fallbacks:** an element that cannot be found gives the nearest ancestor
   that could; a non-normalized xpointer (books with a very old DOM version)
   or an unreadable chapter gives `epubcfi(/6/14!)`, the start of that
   chapter, which PBReader accepts.

On KOReader builds that have CREngine's own CFI encoder
(`getEPubCFIFromXPointer`, newer than v2026.07.1) it is used when the Lua
mapping is not exact, with the spine and body steps above, since the engine
assumes `/6` and `/4`.

Offsets are approximate (entity decoding and whitespace handling differ a
little), so PBReader lands in the right paragraph, roughly the right line. The
reverse mapping (PBReader → KOReader) degrades to the chapter start when the
exact place does not resolve.

## Testing

The on-device plan, from the hand-off that specified this plugin:

1. Copy `explorer-3.db` **plus** `explorer-3.db-wal` and `-shm` from the
   mounted device to the PC and read the test book's row before and after
   each step, e.g.

   ```bash
   python -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); print(c.execute(\"select b.bookid,b.cpage,b.npage,b.completed,b.opentime,b.position,b.position_ts from books_settings b join files f on f.book_id=b.bookid where f.filename like ?\", ('%'+sys.argv[2]+'%',)).fetchall())" explorer-3.db "Neuromante"
   ```

2. In KOReader: open the book, go to a chapter, put the device to sleep once,
   wake it, close the book. The row must have
   `position = pbr:/webkit?##epubcfi(…)` and a fresh `position_ts`;
   `crash.log` has the `PBPosition: wrote …` lines (one per suspend/close,
   none per page turn).
3. Open the book in PBReader: it must land in that chapter, within a
   paragraph. Page a little in PBReader and close it.
4. Open it in KOReader again: the dialog must name the chapter and page
   PBReader was at and offer to go there; *Stay here* must not re-ask.
5. If one is at hand, repeat with a book whose chapters have no `<head>` or
   whose OPF has `<guide>` before `<spine>`; the two computed steps are what
   differs from PBReader's own values then.
6. Only if pocketbooktools is still installed: with it enabled as well,
   repeat 2 and check `position` is still there after a close. The intended
   setup is without it.

The first write also creates `explorer-3.db.before-pbposition`; deleting that
file makes the plugin back up again.

### On the PC

`test/run.lua` exercises the codec under plain LuaJIT with a synthetic EPUB
(spine step 8, chapters with and without `<head>`, comments, void elements,
entities) and, given the directory of an unpacked EPUB, round-trips every
element and text node of every chapter:

```bash
luajit test/run.lua /path/to/unzipped.epub
```

## Limitations

- EPUB only; PocketBook only (the plugin disables itself elsewhere).
- Text offsets are approximate; the paragraph is exact for ordinary XHTML.
- The firmware layout (`explorer-3.db`, `books_settings`, the
  `pbr:/webkit?##` prefix) is what the Era Lite firmware U710.6.11.2124 uses;
  other firmware generations are untested.
- After three consecutive database errors the plugin stops touching the
  database for the session (*Status* says so).

## License

AGPL-3.0-or-later, like KOReader. Reference for the row and CFI rules: the
Kobalt PocketBook port's `epub_cfi.cpp` / `explorer_progress.cpp`.
