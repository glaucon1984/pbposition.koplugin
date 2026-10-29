local _ = require("gettext")
return {
    fullname = _("PBReader position"),
    version = "0.1.0",
    description = _([[Keeps the PocketBook library in step with KOReader for EPUBs: on book close, suspend and settings flush it writes the reading position PBReader opens at (an EPUB CFI) together with the progress fields (page, page count, finished, last opened) into the firmware's library database, so the home screen shows the right progress and PBReader continues where KOReader left off. At open it can offer a newer position read in PBReader. Replaces the progress write of pocketbooktools.koplugin; PocketBook only.]]),
}
