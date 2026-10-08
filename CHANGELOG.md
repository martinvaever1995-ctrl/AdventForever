# AdventForever

## v2.0.2 (beta)

### Versions and raid readiness
- `/af versions` (or `/af check`) opens a window listing everyone in your group:
  - their **addon version**: green when current, orange when outdated, red when not installed
  - their **repair** percentage (the tooltip shows the lowest item)
  - whether they have a **flask or elixirs** up (the tooltip names them)
  - whether they're **in range**
- Officers get a **Remind** button that whispers every guild member in the group who is
  outdated or hasn't got the addon.
- When a newer version is out, a small **update card** tells you once per session, instead of
  a chat line that's easy to miss.
- Players on 2.0.1 or older still show their version, but not their repair or buffs.

### Wishlists
- The new **Wishlist** tab: rank up to 10 items you want, most wanted first. Shift-click an
  item into the box, or use `/af wish <shift-click item>`. Move items up and down, or remove them.
- Only officers see your list. It reaches them when you change it and when you or they log in.
- When an item on your wishlist drops, the loot popup says **On your wishlist (#2)** and plays
  a sound.
- In the loot window, officers see each player's wishlist rank for the item next to their
  note (**wish #2**).
- Officers get a **Guild** view in the Wishlist tab: every wished-for item, how many players
  want it and who (with their rank and effort).
- Item tooltips show officers who has the item on their wishlist. Raiders see their own rank.

### Crafters
- The new **Crafters** tab (`/af crafters`) is the guild's profession directory:
  - **Search** for an item or enchant (or shift-click one) to see who in the guild can make it.
    Online crafters are shown in green, and clicking a result whispers the first one online.
  - With no search, it lists everyone's **professions** with their skill level and number of
    recipes, gathering professions included.
- Your recipes are read when you open a profession window, and your skill levels when you log
  in. Recipes are only ever added, so a filtered window can't lose any.
- Item tooltips show **Crafted by:** with up to 4 guild members, online ones first.
- The directory is shared quietly in the background. Large data waits behind everything else,
  so it never delays loot, votes or effort updates.

### Attunements
- The new **Attunements** tab (`/af attune`) shows who in the guild is attuned to what, as a grid:
  a filled square means attuned, and **?** means not known yet. Players with the most
  attunements are listed first.
- Hover a column to see what it takes and how many are attuned, or a player to see all of
  theirs.
- Built in: Upper Blackrock Spire, Molten Core, Onyxia's Lair, Blackwing Lair and Naxxramas.
  An attunement counts when its quest is done or its key item is in your bags, bank or key ring.
- Officers can **remove** an attunement the guild doesn't need (click its column) and **add**
  new ones as WoW: Forever releases them: a name, a short label, and the quest IDs that
  finish it or its key item. "Restore classic ones" brings back removed built-in ones.
- Your client checks your attunements after login, after you turn in a quest and when your
  bags change, and shares them with the guild.

## v2.0.1 (beta)

### Guild loot in raids
- In a guild raid (a raid instance with at least 75% guild members), raiders **automatically
  pass** on Rare and better items, and the **raid leader automatically needs**. The raid leader
  gets every good item and hands it out with the loot window, so nobody can need on it first.
- Items the raid leader receives start loot sessions by themselves.
- Officers get a warning in chat if anyone else rolls on, or wins, such an item. Players without
  the addon can't be made to pass, but the warning shows it.
- `/af debug` shows whether this client allows rolling by addon.

## v2.0.0

First release. AdventForever tracks each player's **effort** (raids, guild bank, honor and
dungeons with guildies) and shows it to officers when they hand out loot. The addon never
decides who gets an item: officers do.

### Effort
- Each raid week you can score up to 120 points: **Raids** (up to 50), **Guild bank** (up to
  30), **Honor** (up to 20) and **Dungeons** (up to 20).
- Your effort is the sum of the last 4 weeks (max 480). The oldest week drops off at the
  weekly reset, so there's no decay.
- Officers can set the caps, the gold rate, the honor target and the guild kill rule in
  Options.

### Raids
- A boss kill counts as a **guild kill** when at least 75% of the raid are guild members.
- Your raid score is your share of the guild's kills that week.
- Kills record themselves. If the game hides the result, an officer can enter it with
  `/af kill <boss>`.
- Officers can put players on the bench (`/af bench add <name>`), and bench players get credit
  for kills.

### Guild bank
- Gold deposits count toward your score, and so do items on the officers' **wanted list**,
  at their listed value. Withdrawals count against it.
- Your own client reports your deposits when you close the bank. Officers' clients also read
  the bank log, so deposits from players without the addon count too, and no deposit is
  counted twice.
- The new **Bank** tab shows the rules and the wanted list. Officers can add and remove items.
- **Goals:** officers can set a target for a wanted item (e.g. "200 Arcanite Bars"). The Bank tab
  shows the guild's progress with a bar, and items still needed are listed first.

### Honor
- Your client counts the honor you earn while the addon is running and reports it to the
  officers.
- The full honor score is reached at a weekly honor target the officers set.

### Dungeons with guildies
- Finishing a dungeon (its last boss) with at least 3 guild members in the group earns 2.5
  points, up to 20 a week.
- Your own client reports the run, and a run counts once however many of you report it.
- Final bosses of the classic dungeons are built in. Officers mark the final boss of new
  dungeons with `/af final` after killing it.

### Mains and alts
- Effort counts per player: your main and all your alts together, with the caps applying to
  you as a whole.
- Characters on the same WoW account link themselves. Pick your main with "Make this my
  main" in the Me tab, or `/af main`.
- Officers can link and unlink characters by hand (`/af link`, `/af unlink`), for example
  for players on two accounts.

### Loot
- **Loot popup:** Main spec / Off spec / Pass, your equipped item for that slot, the
  **item level difference** (+8 ilvl), a countdown, and an optional **note** (e.g. "BiS").
- **Loot window** for the master looter or raid leader:
  - responses grouped by type and sorted by effort, as a guide only
  - each player's effort, the last 4 weeks, items won this week, equipped items with the item
    level difference, and their note
  - click anyone to award
- **Officer votes:** every officer in the raid gets the loot window with all responses and can
  vote for a candidate. Votes are shown as a count, with the voters' names in the tooltip, and
  only go to the officers. Whoever hands out the loot still makes the call.
- Without master loot, the raid leader starts a session with `/af item <shift-click>`.
- **Trades:** when an item is awarded by trade, the player holding it gets a Trades window
  (`/af trades`) showing:
  - who to trade it to
  - the time left of the 2-hour trade window
  - whether the winner is in range

  Opening the trade puts the item in for you. Delivery is tracked, and the officers see it in
  the loot window.
- **Loot history** (officers, Loot tab): who won what over the last 4 or 8 weeks, by item or
  by player.

### Windows
- A flat, modern look: sidebar navigation with the Advent logo and icons, content on cards
  with crisp black outlines, gradient bars, and the Inter font. With EllesmereUI installed,
  it follows your EllesmereUI theme, font and accent color.
- Officer pages (Loot history, Log, Recruit, Options) only show for officers.
- The main window (`/af`) has these tabs:
  - **Effort:** everyone's effort, sortable
  - **Me:** your own effort per category and what's left this week
  - **Rules:** how scoring works, with the guild's current numbers
  - **Loot:** loot history
  - **Log:** every recorded event; officers can click one to remove a mistake
  - **Bank:** the bank rules and wanted list
  - **Options:** the rules settings
  - **Recruit:** guildless players with the addon
- Windows remember where you left them.

### Login summary
- About a minute after you log in, a small card shows:
  - your effort last week and this week
  - what's still open this week (raids, bank, honor)
  - what the guild needs most from the bank goals
  - any items you have to trade
- Click it to open the Me tab. Turn it off with the checkbox in the Me tab; `/af nudge` shows it
  again.

### Recruiting
- Guildless players who run the addon show up in the **Recruit** tab for guild ranks that can
  invite, with an **Invite** button.

### For officers
- All effort is kept in a shared **ledger** that syncs between officers when they log in.
  Raiders get a summary from whichever officer is online.
- `/af export` and `/af import` back up and restore the ledger as text. Export now and then.
- `/af adjust <name> <raid|bank|honor> <+/-points>` corrects a player's points for this week.
- `/af test` runs a practice loot session with made-up raiders. Nothing is sent or recorded.
- `/af debug` shows what the addon sees: your rank, the roster, and which game features work
  on this client.

### Notes
- Made for WoW: Forever (interface 16001).
- Everyone in the guild should install it. Officers are guild ranks 0–1 by default; the GM
  can change this in Options.
- Type `/af help` for all commands.
