# AdventForever

Shows officers each player's **effort** when handing out raid loot. The addon ranks and
decides nothing; officers pick who gets each item.

Effort is the sum of the last 4 weekly scores (0–100 each, max 400). A week's score is
raids (max 50) + guild bank (max 30) + honor (max 20); the caps are set in `/af options`.

## Mains and alts
Effort counts per player: a main and all their alts together, with the weekly caps applying
to the player as a whole. A raid kill counts once even if two of your characters were there.
- **Automatic:** characters you log in on the same WoW account link themselves. The first one
  is your main; change it with "Make this my main" in the Me tab (or `/af main`).
- **Officers:** an officer's client records links for its own account straight away. Other
  players' characters link when they log in while an officer is online.
- **By hand:** officers can use `/af link <alt> <main>` and `/af unlink <name>`, e.g. for
  someone on two accounts. An officer's link always wins.
- **Display:** alts show "alt" and their main's effort. The Effort tab hides alts unless
  "Show alts" is ticked.

## Trades (no master loot)
When an item is awarded by trade, the client that has it in its bags (and looted it recently)
becomes the holder and tells the raid.
- **Holder:** the Trades window (`/af trades`) shows each item to trade, the winner, the time
  left of the 2-hour trade window and whether they're in range. There are warnings at 30 and
  10 minutes left.
- **Trading:** opening a trade with the winner puts the item in; you check it and accept.
- **Winner:** sees "[item] from <holder>".
- **Done:** a completed trade is detected and shows as "delivered" in the officers' loot window.

## Recruiting
Guildless players who run the addon show up in the Recruit tab (`/af recruit`) for guild ranks
that can invite, with an Invite button.
- **The hidden channel:** guildless players and inviting ranks join a hidden realm chat channel.
  Guildless players announce themselves there every 10 minutes and to any group they join.
  Ordinary guild members don't join it.
- **Notice:** inviters get a chat message the first time someone turns up.
- **The list:** players are kept 14 days and leave the list once they're in the guild.

## Raids
A boss kill counts as a **guild kill** when at least 75% of the raid are guild members
(configurable). Raid points for a week = 50 × guild kills you were at ÷ all guild kills.
- Officers in the raid record the kill automatically. A raid leader who isn't an officer
  sends it to the officers; if none are online, it's resent until one confirms it.
- Players on an officer's bench (`/af bench add <name>`) get credit for the kills that officer
  records.
- If the game hides the encounter result, an officer records it with `/af kill <boss>`.
- Mistakes (a test kill, a wrong deposit): click the event in the Log tab to remove it.

## Honor
Honor points = 20 × this week's honor ÷ the weekly honor target (set in Options), capped at 20.
Your own client works out this week's honor and reports it to the officers when it changes,
at most every 5 minutes. A report waits until an officer confirms it. `/af debug` shows your
honor this week, where the number comes from, and whether this client can inspect other
players' honor.

## Guild bank
Gold and items on the wanted list count toward the bank score at 1 point per 50 gold
(configurable). Wanted items count at their gold value each. Withdrawals count against it.
- Your own client reports your deposits when you close the guild bank. If no officer is
  online, the report waits and is resent until one confirms it.
- Officers' clients read the guild bank logs when they open the bank. That catches deposits
  from players without the addon.
- Both sources can see the same deposit. Per player, week and item, the larger of the two
  totals counts, never both.

## Where the data lives
- **Ledger:** the real record. It's an event log in every officer's saved data. Officers' clients
  share new events as they happen and swap missing ones when an officer logs in.
- **Snapshots:** officers send the guild a summary of everyone's weekly scores. Every client
  saves the latest one, so raiders can see effort while no officer is online. The effort
  window says how old it is and which officer sent it.
- **Backup:** `/af export` gives the whole ledger as text to save outside the game;
  `/af import` merges it back in. Export now and then: the ledger only exists in officers' WTF
  folders.

No officer or public notes are used.

## Look
A flat dark theme with a teal accent. With EllesmereUI installed, its third-party skinning
styles the addon instead, using your EllesmereUI theme, font and accent color. You can turn
that off per addon in EllesmereUI's options.

## Guild setup
- Install the addon on every member's client.
- The GM sets which ranks count as officers (`/af options`, default ranks 0–1).

## Commands
| Command | Who |
|---|---|
| `/af` | Main window: Effort, Me, Rules, Log, Bank and Options tabs |
| `/af history` | Officers: who won what in the last 4 or 8 weeks, by item or by player (Loot tab) |
| `/af me` | Your own effort: the split per category, what's left this week, the last 4 weeks |
| `/af rules` | How effort is scored, with the guild's current numbers |
| `/af loot` | Loot window |
| `/af item <shift-click items>` | Start a loot session by hand (loot authority) |
| `/af adjust <name> <raid\|bank\|honor> <+/-points> [reason]` | Officers: correct this week's points in a category (0 removes the correction) |
| `/af bank` | Guild bank rules and the wanted list (officers edit) |
| `/af attune` | Who in the guild is attuned to which raid (officers add or remove attunements) |
| `/af crafters [item]` | Who in the guild can craft something, or everyone's professions |
| `/af wish [item]` | Your wishlist (up to 10 ranked items, seen only by officers), or add an item to it |
| `/af bench add\|remove <name>`, `/af bench list\|clear` | Officers: bench players credited for the kills you record |
| `/af kill <boss>` | Officers: record a guild kill for your group by hand |
| `/af options` / `/af config` | Effort rules (officers edit, everyone views) / print them |
| `/af log` | Officers: ledger events (Log tab) |
| `/af export` / `/af import` | Officers: back up / restore the ledger |
| `/af versions` (or `/af check`) | Who in your group has the addon and which version, with durability, flasks / elixirs and range |

## Loot
The **loot authority** is the master looter when master loot is on, otherwise the raid leader.
Responses are grouped Main spec → Off spec → Pass → no answer and sorted by effort within
each group, purely as a visual aid. Each row shows effort, the 4 weekly scores, items won
this raid week (officers' clients only), and the equipped item. Hover a row for details.
Click anyone to award.

## Repository
- The addon's code sits at the top level (the `.toc`, the `.lua` files and `Media/`), so the
  repository can be cloned straight into `Interface/AddOns/`.
- `docs/SPEC.md`: the design spec. `docs/curseforge-description.md`: the CurseForge page text.
- `CHANGELOG.md`: release notes.
- `.pkgmeta` keeps `docs/` and this README out of the packaged download.
- `Media/Inter-*.ttf` is the Inter font (SIL Open Font License, see `Media/Inter-OFL.txt`). The
  license file must ship with the font.
