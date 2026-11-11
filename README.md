# Haggler

Gold-making rules and display for WoW: Forever. **Prices from [AHledger](https://ahledger.com).**

Haggler doesn't scan or upload anything itself. AHledger scans the auction house and contributes
the data; AHledger sync uploads it and brings back the shared price table. Haggler reads what
AHledger holds:

- `AHledgerAPI.GetPrice` — the public in-game API (median, lowest buyout, 7- and 30-day figures, sales per day)
- `AHledgerDB.scans` — your own full scans, for listing depth and flips
- `AHledgerDB.recipes` — recipes AHledger records while a profession window is open (keep AHledger's *Crafting margins* option on)

On first load Haggler switches AHledger's display options off once (`/hag quiet` does it again).

## Commands

- `/hag` — status: scan read, price mode, sell log
- `/hag mode realistic | median | lowest`
- `/hag flips [count]` — listings under the vendor price in your latest scan
- `/hag quiet`

## Development

```bash
luacheck .
for t in tests/*_spec.lua; do luajit "$t"; done
```

Installed by a symlink: `Interface/AddOns/Haggler` → this folder.

## Credit

AHledger's data is free for personal and community use with the credit "Prices from AHledger"
linked to ahledger.com; commercial use needs a licence from them. Haggler bundles none of
AHledger's code.
