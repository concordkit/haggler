# Haggler (powered by AHledger)

A gold-making add-on for WoW: Forever (Interface 16001) covering crafting, selling, bags and flips.

Prices from [AHledger](https://ahledger.com).

## Status

Build step 1 of 8: the host layer, the engine core and their tests. There is no UI yet; `/hag` lists and changes settings.

## Layout

| Path | What it is |
| --- | --- |
| `Host/` | Haggler's own host layer, shaped like Concord's API: `AddModule`, `Provide` / `Get`, the bus, settings schemas and the generated `/hag` commands |
| `Host/Tokens.lua` | Generated from the Concord design system by `tools/sync-tokens.sh`; do not edit |
| `Engine/` | UI-free: the WoW API wrapper, saved data and migrations, the AHledger price table, calculation rules and price steps |
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
tools/sync-tokens.sh
```

## Credits

Prices from [AHledger](https://ahledger.com). Their data is free for personal and community use with this linked credit.
