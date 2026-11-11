# Haggler

A gold-making add-on for WoW: Forever (Interface 16001) covering crafting, selling, bags and flips.

Prices from [AHledger](https://ahledger.com).

## Status

Build step 3 of 8. Done so far:

- The host layer and the engine core (step 1).
- The AH scan, own-sales counting, price rules and item tooltips (step 2).
- Item value, bag badges and totals, and trade window values with a loss warning (step 3).

Settings are changed with `/hag`; there is no settings panel yet.

- **Value**: an item is worth its rule price after the 5% AH cut and the deposit risk, and never less than the vendor price.
- **Bags**: badges show items to vendor and values that are guesses, with an optional value per button and a bag total. Works in Blizzard bags, BagPad 1.4.0, Bagnon 12.1.8 and Baganator 846, whichever is loaded.
- **Trade**: shows a value per slot and a total per side, plus a warning when you give more than you get beyond the convenience fee. In confirm mode, the Trade button needs a second click. Friends and guild members get their own policy. Completed trades go to the ledger.

## Layout

| Path | What it is |
| --- | --- |
| `Host/` | Haggler's own host layer, shaped like Concord's API: `AddModule`, `Provide` / `Get`, the bus, settings schemas and the generated `/hag` commands |
| `Host/Tokens.lua` | Generated from the Concord design system by `tools/sync-design.sh`; do not edit |
| `Engine/` | UI-free: the WoW API wrapper, saved data and migrations, the AHledger price table, calculation rules and price steps, item value, trade verdicts and the ledger |
| `Host/BagHosts/` | One adapter per bag add-on (Blizzard, BagPad, Bagnon, Baganator), detected at runtime |
| `Features/` | One module per feature: pricing, value, scan, tooltip, bags, trade |
| `media/icons/` | Icon atlases generated from the Concord design system by `tools/sync-design.sh`; do not edit |
| `Haggler.lua` | Bootstrap: opens the saved data on `ADDON_LOADED` and starts the host |
| `tests/` | luajit specs |

## Price data

Haggler reads AHledger's price table as it is. The desktop app writes `Data/PriceTable.lua` in AHledger's own saved shape:

```lua
HagglerPriceTable = {
	['forever/normal/alliance/us'] = { updated = 1762800000, count = 15234, text = 'AHL1|forever/normal/alliance/us|1762800000|15234\n2589:1200:950:340:1180:1250:800:1900:1505\n...' },
}
```

- The key is the market key, `forever/<ruleset>/<faction>/<region>`.
- `updated` is unix seconds, and `count` is the number of rows.
- `text` is the table exactly as AHledger serves it. Each row is `id:median:min:qty:m7:m30:lo:hi:sold`. Prices are in copper, and `sold` is units sold a day times ten.

`PriceData.newLibrary():AddSavedTables(HagglerPriceTable)` loads it without changing anything, and `PriceData.parse` reads each `text`. Empty fields mean unknown, and any fields after `sold` are ignored.

## Development

```bash
luacheck -q .
```

```bash
stylua --check .
```

```bash
luajit tests/run.lua
```

To refresh the design tokens from the Concord design system:

```bash
tools/sync-design.sh
```

## Credits

Prices from [AHledger](https://ahledger.com). Their data is free for personal and community use with this linked credit.
