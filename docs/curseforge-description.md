# AdventForever

**Guild effort, shown at loot time.** AdventForever tracks how much each of us puts into the
guild (raiding, the guild bank, PvP and dungeons together) and shows it to the officers when
they hand out loot.

The addon never decides who gets an item. **Officers do.** AdventForever makes sure they have
the full picture, and that everyone can see how it's counted.

---

## What you get as a raider

- **A loot popup** when an item drops. Answer **Main spec**, **Off spec** or **Pass** in one
  click. The popup also shows:
  - what you're wearing in that slot
  - how much of an upgrade the item is (**+8 ilvl**)
  - room for a short note, like "BiS"
- **Your own effort** in the **Me** tab: points per category this week, what's still
  available, and your last 4 weeks.
- **The rules, in plain words**, in the **Rules** tab, always with the guild's current
  numbers.
- **Trade reminders:** if you're holding an item someone else won, the addon shows who it's
  for, how long you have left to trade it, and puts it in the trade window for you.
- **Alts count with your main:** your characters on the same account link themselves.

You don't need to do anything else: install it and play.

## How effort works

Every raid week you can score up to **120 points**:

| Category | Up to | How |
|---|---|---|
| **Raids** | 50 | Your share of the guild's boss kills that week |
| **Guild bank** | 30 | Gold and wanted items you deposit |
| **Honor** | 20 | Honor you earn, up to a weekly target |
| **Dungeons** | 20 | 2.5 per dungeon finished with 3+ guild members |

Your **effort** is the sum of your last 4 weeks (max 480). At the weekly reset the oldest week
drops off, so recent effort always counts most, and nobody gets locked out by old numbers.

A boss kill counts as a guild kill when at least 75% of the raid are guild members. Bench
players get credit too.

## What officers get

- **A loot window:**
  - every response grouped by Main / Off / Pass and sorted by effort
  - each player's weekly history, items won this week, equipped gear, item level difference,
    and their note
  - click anyone to award
- **Works without master loot:** start a session with `/af item`, and the addon tracks the
  trade until it's delivered.
- **Loot history:** who won what over the last 4 or 8 weeks, by item or by player.
- **Guild bank tracking** from both the depositor's client and the bank log, with an editable
  wanted list.
- **A shared ledger:** every point and award is recorded and synced between officers. Mistakes
  can be removed with a click, and everything can be exported as a backup.
- **Recruiting:** guildless players who run the addon show up with an **Invite** button.

## Getting started

1. Install AdventForever. Everyone in the guild should have it.
2. Type **`/af`** to open the main window.
3. On an alt? Open the **Me** tab and make sure the right character is your main.

That's it. Points come in on their own as you raid, deposit and PvP.

## Commands

| Command | What it does |
|---|---|
| `/af` | Main window |
| `/af me` | Your own effort |
| `/af rules` | How effort is scored |
| `/af trades` | Items you have to trade, or that are coming to you |
| `/af main` | Make this character your main |
| `/af help` | All commands, including the officer ones |

## FAQ

**Does a high score mean I get the item?**
No. Effort is information for the officers. They make the call, and the loot window only sorts
as a guide.

**I deposited gold but my score didn't change.**
Points are whole numbers: with 1 point per 50 gold, a small deposit can still be 0 points. Your
deposit is counted in the Me tab even before it adds a point.

**Why does my number say "as of …"?**
Raiders see the numbers the last online officer sent. They update as soon as an officer is
online.

**I play two accounts.**
Ask an officer to link your characters with `/af link`.

## Requirements

- **WoW: Forever**
- **Optional:** EllesmereUI. With it, AdventForever matches your EllesmereUI theme, font and
  accent color.

*An internal addon for our guild.*
