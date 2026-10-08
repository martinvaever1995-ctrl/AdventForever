# AdventForever — Spec (v2)

## Goal
A WoW addon that helps officers distribute raid loot by showing each player's **effort**:
raiding, guild bank contributions and honor over the last 4 raid weeks.
The addon ranks nothing and decides nothing. It shows information, and the GM/officers
decide who gets each item.
Every guild member installs it. Members report data, and officers' clients are authoritative.

## Decisions
- Game version: WoW: Forever (beta client 1.60.1, interface `16001`). Midnight-style addon
  restrictions apply: values can be secret and addon/chat messages locked down during encounters.
- Officers are guild ranks `0..officerRank` (the GM sets `officerRank`). Only officers record
  effort, edit config and send snapshots. No officer or public notes are used.
- Addon name: AdventForever (`/af`, addon message prefix `AdvForever`).

## Effort score
- Each raid week gets a **weekly score out of 100**. The week is keyed to the server's
  weekly reset.
- **Effort = sum of the last 4 weekly scores** (max 400). This is a rolling window:
  at reset the oldest week drops off and a new week starts at 0. There is no decay.
- Weekly score = raid + guild bank + honor, each capped:
  - **Raids (max 50):** 50 × (boss kills the player was present for ÷ guild boss kills
    that week). The current week's raid score changes as the guild kills more bosses.
    - **Guild kill:** a raid boss kill where at least `guildKillShare` % (default 75) of the
      raid are guild members. The kill event stores the guild members present and the raid size.
    - **Recording:**
      - Every officer in the raid records the kill.
      - A raid leader who isn't an officer sends a report. It's stored and resent until an
        officer confirms it.
      - All of them derive the id `kill:<encounter>:<difficulty>:<raid leader>#<week>`, so the
        kill counts once. A repeat kill of the same boss by the same group in a week also
        counts once.
    - **Bench:** officers keep a bench list (`/af bench`). Each officer recording a kill also
      records bench credit (`bench:<kill id>:<player>#1`) for the players on their list.
    - **Fallback:** if ENCOUNTER_END values are secret, an officer records the kill with
      `/af kill <boss>`.
  - **Removing events:** officers click an event in the Log tab to record a `void` for it. The
    event stops counting everywhere; nothing is deleted.
  - **Guild bank (max 30), gold and items combined:**
    - Gold: configurable rate, default 1 point per 50g. Withdrawals count against it.
    - Items: only items on the officer-maintained **wanted list** count. Each entry has an
      item ID and a gold value per unit, converted at the gold rate. Unlisted items give 0.
    - Two sources:
      - **The player's own client:** while the bank is open it counts confirmed gold deposits
        and withdrawals, and wanted items leaving or entering the bags. It reports the net
        when the bank closes. Reports are stored until an officer confirms them, and resent
        on login and every 5 minutes.
        - Officers record a report as `dep:<player>#<report number>`, so every officer
          recording it makes the same event.
      - **Officers' clients:** they read the money log and item logs when opening the bank and
        record entries the ledger doesn't have. Entries are matched by player, amount and time
        within 3 hours, because the log only gives times to the hour.
    - Per player, week and kind (gold, or each wanted item), the larger of the two sources'
      net totals counts, never their sum.
  - **Corrections:** `/af adjust` adds a +/− correction per player, week and category on top of
    the tracked value. The result is clamped to 0..cap.
  - **Honor (max 20):** linear from 0 to 20 against a configurable weekly honor target
    (`honorTarget`, default 5,000 until we know Forever's numbers).
    - Reported by the player's own client. It takes the highest of:
      - the weekly honor stats (`GetPVPThisWeekStats`)
      - honor-currency gains it saw itself (kept per character and week)
      - the currency's own "earned this week", if the client fills it in
    - Sent when it changes, at most every 5 minutes, until an officer confirms it.
    - Officers record `honor:<player>:<week>#<honor>`; the highest report per player and week
      counts.
    - **Self-reported, no verification (decided).** Forever has `GetInspectHonorData` but no
      `RequestInspectHonorData`. The inspect data holds only today/yesterday/lifetime values, with
      no weekly figure, and in testing it returned zeros. So there is no reliable way to check
      another player's weekly honor.
    - Honor earned before a player runs the addon, or on a client without it, isn't seen.
      Officers can correct it with `/af adjust <name> honor <points>`.
- Effort is information only. It never decides or blocks loot.
- **Mains and alts:** effort is per player (main + alts).
  - **Counting:** raids count a kill once if any of the player's characters was present or
    benched. Bank gold and honor add up across characters, and so do corrections. The caps
    apply per player.
  - **Linking:**
    - Saved data is account-wide, so the addon knows which characters share an account. The
      first is the main; the player can change it.
    - Each character reports only itself (`LINK`). Officers record `link:<character>#<time the
      main was chosen>`, so resends dedupe.
    - An officer's client records its own account's characters directly.
    - Officers link and unlink by hand. Officer links beat self reports; the newest wins
      within each. Links never expire.
  - **Raiders:** snapshots carry `m = { alt = main }`. Alts show their main's effort, marked
    "alt", and the Effort tab hides alts by default.

## Storage
An officers' event log is the only real record. Raiders see snapshots of it, and exports
keep a copy outside the game. Nothing is stored in guild notes.

- **Ledger: event log in officers' SavedVariables.**
  - Every officer action is an event: unique id, officer, server time, raid week, kind, details.
    Kinds today:
    - `cat`: player, category, correction points (+/−). The latest event per
      week/player/category wins.
    - `won`: player, item. Information only.
    - `dep`: player, source (`self` or `log`), copper or item ID and count (negative =
      withdrawn).
    - `kill`: encounter, boss name, difficulty, guild members present, raid size.
    - `bench`: player, kill id (counts as present).
    - `void`: id of an event to ignore.
    - `honor`: player, this week's honor as their client reported it (the highest counts).
  - Scores, the per-category breakdown and items won are all worked out from the events.
  - Ids are `<install token>#<sequence>`, so a reinstalled client never reuses an id.
  - New events go to the guild as they happen. On login an officer sends a digest (per week and
    origin: count and highest sequence). Online officers reply with the events it is missing and
    their own digest, so both sides catch up. Events are never edited, so merging is a union.
  - Only events from officers (rank ≤ `officerRank`) are accepted. Events are kept 8 weeks.
  - The ledger doubles as the audit log (`/af log`).
- **Snapshots, saved by every client:** `{ time, week W, player = "w1,w2,w3,w4" }`, newest
  week first, where `W` is the raid week `w1` belongs to.
  - A detail field `sd` adds per player the raid/bank/honor split for each of the 4 weeks, and
    this week's raw numbers: guild kills attended/total, gold counted, honor. Raiders' Me tab
    uses it. Older clients ignore it.
  - An officer sends one to the guild 10 s after recording something (several changes in a row
    become one), 45 s after login (once the ledger sync has landed), and after changing the caps.
  - A raider who logs in asks for one. One online officer answers on GUILD; the others hold back.
  - Clients keep the newest snapshot from an officer. Readers shift it by the resets since `W`,
    so it rolls over at reset.
  - Officers' own views always come from their ledger. Raiders' views come from the snapshot,
    labelled with its time and the officer who sent it.
- **Export / import:** `/af export` turns the whole ledger into a text string to keep outside
  the game. `/af import` merges a string back in (duplicates are skipped) and shares the new
  events with online officers.
- **Known limits:**
  - The ledger lives only in officers' WTF folders. Every officer holds a full copy, and
    exports are the backup.
  - A raider with no saved snapshot sees nothing until an officer is online.
- **Shared config:** category caps, gold rate, wanted list, honor target, popup timeout and
  officer ranks. Versioned and broadcast to the guild.
  - Editable by officers in an options window. Clients accept config only from officers, and
    accept `officerRank` only from the GM.
  - A client asks for newer config on login; one online officer answers.

## Loot flow
1. The **loot authority** is the master looter when master loot is on, otherwise the raid leader.
   - With master loot: opening a corpse broadcasts every item at or above the loot threshold.
   - Without master loot (Forever may not have it): the authority starts a session by hand,
     with `/af item <links>`, for items someone is holding.
2. Members get a popup: Main spec / Off spec / Pass. It shows their equipped item(s) in that
   slot and their own effort.
3. The loot window lists **every** raid member's response, grouped Main spec → Off spec →
   Pass → no answer, and within each group sorted by effort, highest first. The sort is a
   visual aid only. For each player it shows:
   - effort score
   - the per-week breakdown (tooltip adds the per-category split where the officer tracked it)
   - items won this raid week
   - the item they have equipped in that slot
4. An officer clicks any player to award; anyone can be awarded anything.
   - Master loot gives the item. It is recorded once it reaches the player.
   - Without master loot, the award is recorded and the holder is told in raid chat to trade it.
   - Every award is announced in raid chat and recorded in the ledger as "won this week".

## Windows
- **Standings:** every member with this week, the three previous weeks and total effort.
  Sortable, with a raid-only filter. The tooltip shows the per-category breakdown for officers.
- **Me:** your own effort. Shows:
  - the total, with a bar
  - this week per category, with what's still available (e.g. "At 2 of 3 guild kills", "120g
    more fills it", "3,000 of 5,000 honor")
  - the last 4 weeks per category
  - reports still waiting for an officer
- **Rules:** how each category is scored, filled in with the guild's current caps, rates, 75%
  rule, honor target and wanted-list size.
- **Loot history (officers):** every award from the ledger for the last 4 or 8 weeks, filterable
  by player or item.
  - **Items view:** when, player, item and response. Clicking an award removes it.
  - **Players view:** items won, Main/Off spec counts and the latest item. Sortable.
  - The loot window tooltip adds "Won in the last 4 weeks: N".
- **Loot:** as above.
- **Options:** caps, rates, honor target, wanted list and officer ranks. Officers edit;
  everyone can view.
- **Version check:** on login and raid join; outdated players are warned.

## Build steps
1. Effort storage (officers' ledger, snapshots for raiders, export/import), standings window,
   loot UI, options (caps), manual `/af adjust`. **Done, awaiting in-game test.**
2. Guild bank: self-reported deposits, officer log reads, gold rate, wanted list (Bank tab).
   **Done, awaiting in-game test.**
3. Raid tracking: guild kills (75% rule), presence per player, bench credit, `/af kill`,
   removing events from the Log tab. **Done, awaiting in-game test.**
4. Honor: self-reported weekly honor and the honor target. **Done, awaiting in-game test.**
   Self-reported only: Forever can't request another player's weekly honor.

5. Mains and alts. **Done, awaiting in-game test.**
   - Recruit tab: guildless players running the (internal) addon are found through a hidden,
     password-protected realm channel (`AdvForeverNet`) and through groups. Only guildless
     players and inviting ranks join the channel. Inviters get an Invite button. Players are
     kept 14 days and drop off once in the guild. There's no opt-out (decided). **Done,
     awaiting in-game test.**
6. Trade tracking (no master loot). **Done, awaiting in-game test.**
   - **Holder detection:** `AWARDED` carries the item and a trade flag. The client with the item
     in its bags, looted in the last 2 hours (read from its own "You receive loot" lines),
     becomes the holder and sends `HOLD`.
   - **Trades window:** time left, in range, a Trade button, and the item placed into the trade
     automatically.
   - **Done:** the completed trade (`ERR_TRADE_COMPLETE`) sends `TRADED`. The loot window shows
     waiting / delivered / holder unknown. Pending trades survive a reload.
7. Notes and item level difference. **Done, awaiting in-game test.**
   - The popup has an optional note (max 60 characters), sent with the response; chat codes
     are stripped.
   - Item level difference against the weaker equipped item of the slot (rings, trinkets,
     one-handers), or "empty slot". It's shown in the popup and in the loot window's Equipped
     column, and the loot window has a Note column.
8. Officer votes. **Done, awaiting in-game test.**
   - The council is the loot authority plus every officer in the group.
   - Raiders whisper responses to the whole council.
   - Officers keep a copy of each session (from `ITEMS`) and vote (`VOTE`, whispered to the
     council). One vote per officer per item; voting again takes it back.
   - Only the authority awards; for others a row click votes. Votes don't change the sort.
   - `/af test` adds two fake officers' votes.
9. Goals for wanted items. **Done, awaiting in-game test.**
   - `config.goals[itemID] = { n = target, since }`. Re-adding an item keeps `since`, so progress
     continues; a goal of `0` removes it.
   - Progress = guild-wide deposits since `since` (`Ledger:DepositedSince`, larger source per
     character and week). Raiders get it in snapshots (`g`).
   - The Bank tab shows the Goal column (bar, "120 / 200" or done), with unfinished goals sorted
     first by how much is still needed.
   - Limit: deposits older than 8 weeks fall out of the ledger.
10. Login nudge. **Done, awaiting in-game test.**
    - 55 s after login, guild members with numbers (officers' ledger, or a snapshot) get a card:
      - last week, this week and effort
      - open raid, bank and honor points
      - the most-needed bank goal
      - pending trades
    - Click opens the Me tab. It fades after 15 s (it stays while hovered).
    - Per-player off switch in the Me tab (`prefs.nudge`); `/af nudge` shows it on demand.
11. Dungeons with guildies. **Done, awaiting in-game test.**
    - 4th category, `dungeonMax` 20, so the weekly max is 120 and effort max 480. Caps may total
      up to 200.
    - A run is a final-boss `ENCOUNTER_END` in a party instance with ≥ `dungeonGuildMin` (3)
      guild members. It's worth `dungeonPerRun` (2.5) points, rounded down per week.
    - Final bosses: a built-in table of the classic dungeons (encounter IDs as Forever reports
      them; one per wing for SM, DM and Strat), plus `config.finals` that officers mark with
      `/af final`. Marking also counts a kill from the last 15 minutes.
    - Each guild member in the group reports (`RUN`, resent until `RUNACK`); officers record
      `run` events (`dun:<reporter>#<kill time>`).
    - The ledger groups reports into runs: same dungeon, within 10 minutes, a shared player.
      Runs count per player (main + alts).
    - Snapshot detail now carries 4 numbers per week plus runs (older 3-number snapshots are
      still read).

## Later
- Export string for an external web dashboard (history, charts, rules page).

## Technical notes
- Lua addon, no external calls. Uses `C_ChatInfo.SendAddonMessage` with a registered prefix on
  GUILD/RAID/WHISPER, with a compact serializer and chunking. Sending waits out
  `C_ChatInfo.InChatMessagingLockdown()` and throttling.
- Officer checks are client-side: the sender's guild rank against `officerRank`.
- Secret values from the game (`issecretvalue`) are never stored or sent.
- Modules: Core, Comm, Config, Standings, Ledger, Loot, UI (+ Attendance, Bank, Honor in later steps).
