# Bundled libraries

Copied unchanged; Haggler loads them from its TOC before its own files and reaches them only
through `ns.wow:Library(name)` (LibStub). A newer copy loaded by another add-on wins, as LibStub
intends.

| Library | Version | Author | Licence |
| --- | --- | --- | --- |
| LibStub | minor 2 (r103) | Kaelten, Cladhaire, ckknight, Mikk, Ammo, Nevcairiel, joshborke | Public domain (stated in the file's header) |
| CallbackHandler-1.0 | minor 8 (r26) | Nevcairiel and the Ace3 team | BSD 3-clause, as part of Ace3 (the file itself carries no licence text) |
| LibDataBroker-1.1 | minor 4 | tekkub | No licence stated in the file, and upstream (tekkub/libdatabroker-1-1) states none either; distributed freely with add-ons since 2008. Kept bundled; release step 8 confirms the licence |

Source of these copies: the copies bundled with another installed add-on (not AHledger).
