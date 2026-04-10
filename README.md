# ConsumableHelper

A lightweight World of Warcraft addon that displays recommended consumables and enchants for your current class and spec, with one-click Auction House searching.

## Features

- **Spec-aware recommendations** — Automatically detects your class and specialization and filters consumables and enchants to show only what's relevant to you.
- **Auction House integration** — Click any item to instantly search for it in the Auction House.
- **Tabbed interface** — Switch between Consumables, Enchants, and Utility tabs.
- **Auto-show** — The panel appears alongside the Auction House when opened, and hides when it closes.
- **Slash command toggle** — Use `/consumablehelper` or `/ch` to open the window anywhere.
- **Spec testing** — Use `/ch show <class> <spec>` to show recommendations for any class/spec combination, with fuzzy matching for abbreviations (e.g., `/ch show paladin ret`).
- **Debug mode** — `/ch debug` toggles verbose logging for troubleshooting.

## Installation

1. Download or clone this repository into your WoW addons folder:
   ```
   World of Warcraft/_retail_/Interface/AddOns/ConsumableHelper
   ```
2. Restart WoW or type `/reload` in-game.

## Usage

- Open the **Auction House** — the ConsumableHelper panel will appear to the right.
- Click an item row to search the AH for that item.
- Switch between **Consumables**, **Enchants**, and **Utility** tabs.
- Use `/ch` to toggle the window outside of the Auction House.
- Test different specs with `/ch show <class> <spec>` (e.g., `/ch show paladin ret` for Paladin Retribution).
- Reset test mode with `/ch reset`.

## Slash Commands

| Command | Description |
|---|---|
| `/consumablehelper` or `/ch` | Toggle the ConsumableHelper window |
| `/ch debug` | Toggle debug logging |
| `/ch show <class> <spec>` | Simulate recommendations for a specific class/spec (e.g., `/ch show paladin ret`) |
| `/ch reset` | Reset test mode back to your current spec |

## License

All Rights Reserved — see [LICENSE](LICENSE) for details.
