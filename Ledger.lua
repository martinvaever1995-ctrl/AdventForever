-------------------------------------------------------------------------------
--  Ledger.lua -- the officers' shared event log, the real record of effort.
--
--  Every event: { id, o, s, by, t, w, k, ... }
--    o/s  origin and its sequence number; id = o#s. Officer actions use the
--         officer install's token. Things several clients can report use an
--         origin everyone derives the same way, so they all make the same event
--         and it counts once:
--           deposit reports  "dep:<player>"            # report number
--           guild kills      "kill:<boss>:<diff>:<leader>" # raid week
--           bench credit     "bench:<kill id>:<player>"   # 1
--    by   the officer who recorded it, t server time, w raid week, k kind:
--    "cat"   n = player, c = category, v = correction (+/-) on top of what is
--            tracked; the newest per week/player/category counts
--    "won"   n = player, l = item link (items won, information only)
--    "dep"   n = player, src = "self" | "log", a = copper, or i = itemID, q = count,
--            l = link (negative = withdrawn)
--    "kill"  enc = encounter ID (0 if entered by hand), en = boss name, d = difficulty,
--            p = { guild members present }, size = raid size
--    "bench" n = player, ref = kill id (bench players count as present)
--    "run"   enc, en = final boss, map, mn = dungeon, p = { guild members in the group };
--            reports of the same run (same dungeon, 10 minutes, shared player) count once
--    "honor" n = player, h = this week's honor as their client reported it
--            (origin "honor:<player>:<week>", sequence = h; the highest counts)
--    "link"  n = character, m = its main (m == n: a main), src = "self" | "officer";
--            officer links beat self reports, newest wins; kept until changed
--    "void"  ref = id of an event to ignore (an officer removed it)
--  Scores, breakdowns and items won are all worked out from the events.
--
--  Officers' clients send new events to the guild as they happen, and on login
--  swap whatever they are missing with the officers online (per week and origin:
--  a count and the highest sequence number). Events are never edited, so merging
--  is just a union. Raiders get the totals as snapshots (see Standings.lua), and
--  /af export / /af import keep a copy outside the game.
-------------------------------------------------------------------------------
local _, AF = ...
local Ledger = AF:NewModule("Ledger")

local KEEP_WEEKS = 8        -- weeks of events kept (the window is 4)
local BATCH = 15            -- events per sync message
local SYNC_SETTLE = 45      -- seconds after login until our ledger counts as synced

local events                -- id -> event (SavedVariables)
local buckets = {}          -- week -> origin -> { count, max }
local cats = {}             -- week -> name -> category -> { event, ... }
local won = {}              -- week -> name -> { event, ... } oldest first
local deps = {}             -- week -> name -> { event, ... }
local kills = {}            -- week -> { event, ... }
local present = {}          -- kill id -> { name = true } (raid members at the kill)
local benched = {}          -- kill id -> name -> bench event
local voided = {}           -- event id -> true
local honors = {}           -- week -> name -> { event, ... }
local links = {}            -- character -> { link event, ... }
local runs = {}             -- week -> { run event, ... }
local runGroups = {}        -- week -> runs grouped into real runs (cache; cleared on changes)
local RUN_MERGE = 600       -- seconds: reports this close (same dungeon, shared players) are one run

-- Links (who is whose alt) and removals stay until changed; everything else is
-- kept KEEP_WEEKS weeks.
local TIMELESS = { link = true, void = true }

Ledger.readyAt = math.huge

local function Newer(a, b)
    if a.t ~= b.t then return a.t > b.t end
    return a.id > b.id
end

local function Live(e) return not voided[e.id] end

local function ListFor(store, week, name)
    store[week] = store[week] or {}
    local list = store[week][name] or {}
    store[week][name] = list
    return list
end

local function Index(e)
    local byOrigin = buckets[e.w] or {}
    buckets[e.w] = byOrigin
    local b = byOrigin[e.o] or { count = 0, max = 0 }
    byOrigin[e.o] = b
    b.count = b.count + 1
    b.max = math.max(b.max, e.s)

    if e.k == "cat" then
        cats[e.w] = cats[e.w] or {}
        local byName = cats[e.w][e.n] or {}
        cats[e.w][e.n] = byName
        byName[e.c] = byName[e.c] or {}
        table.insert(byName[e.c], e)
    elseif e.k == "won" then
        local list = ListFor(won, e.w, e.n)
        table.insert(list, e)
        table.sort(list, function(a, b) return Newer(b, a) end)
    elseif e.k == "dep" then
        table.insert(ListFor(deps, e.w, e.n), e)
    elseif e.k == "kill" then
        kills[e.w] = kills[e.w] or {}
        table.insert(kills[e.w], e)
        local set = {}
        for _, name in ipairs(e.p) do set[name] = true end
        present[e.id] = set
    elseif e.k == "bench" then
        benched[e.ref] = benched[e.ref] or {}
        benched[e.ref][e.n] = e
    elseif e.k == "honor" then
        table.insert(ListFor(honors, e.w, e.n), e)
    elseif e.k == "link" then
        links[e.n] = links[e.n] or {}
        table.insert(links[e.n], e)
    elseif e.k == "run" then
        runs[e.w] = runs[e.w] or {}
        table.insert(runs[e.w], e)
        runGroups[e.w] = nil
    elseif e.k == "void" then
        voided[e.ref] = true
        wipe(runGroups)
    end
end

local function Valid(e)
    if type(e) ~= "table" or type(e.o) ~= "string" or type(e.s) ~= "number" or e.id ~= e.o .. "#" .. e.s then return false end
    if type(e.t) ~= "number" or type(e.w) ~= "number" or type(e.by) ~= "string" then return false end
    local k = e.k
    if k == "kill" then
        if type(e.enc) ~= "number" or type(e.en) ~= "string" or type(e.p) ~= "table" or type(e.size) ~= "number" then return false end
        for _, name in ipairs(e.p) do
            if type(name) ~= "string" then return false end
        end
        return true
    end
    if k == "void" then return type(e.ref) == "string" end
    if type(e.n) ~= "string" then return false end
    if k == "cat" then return AF.Standings.CATEGORY_TEXT[e.c] ~= nil and type(e.v) == "number" end
    if k == "won" then return type(e.l) == "string" end
    if k == "bench" then return type(e.ref) == "string" end
    if k == "honor" then return type(e.h) == "number" end
    if k == "run" then
        if type(e.enc) ~= "number" or type(e.map) ~= "number" or type(e.en) ~= "string" or type(e.p) ~= "table" then
            return false
        end
        for _, name in ipairs(e.p) do
            if type(name) ~= "string" then return false end
        end
        return true
    end
    if k == "link" then return type(e.m) == "string" and (e.src == "self" or e.src == "officer") end
    if k == "dep" then
        return (e.src == "self" or e.src == "log")
            and (type(e.a) == "number" or (type(e.i) == "number" and type(e.q) == "number"))
    end
    return false
end

-- Adds an event we haven't seen, if it's inside the weeks we keep.
local function Add(e)
    local current = AF.Standings.CurrentWeek()
    if events[e.id] or e.w > current + 1 then return false end
    if e.w < current - KEEP_WEEKS and not TIMELESS[e.k] then return false end
    events[e.id] = e
    Index(e)
    -- Our own events coming back (restored saved data): never reuse their numbers.
    if e.o == AF.db.origin and e.s > AF.db.seq then AF.db.seq = e.s end
    return true
end

-------------------------------------------------------------------------------
--  Recording
-------------------------------------------------------------------------------
function Ledger:CanRecord()
    return AF.Config:IsOfficer(AF.playerName)
end

-- Records an event under our own origin, or under the one given (reports from
-- several clients). Returns the event, or nil if it was already in the ledger.
local function Record(fields, origin, seq)
    if not Ledger:CanRecord() then
        AF:Print("Only officers can record effort.")
        return nil
    end
    if not origin then
        AF.db.seq = AF.db.seq + 1
        origin, seq = AF.db.origin, AF.db.seq
    end
    fields.o, fields.s, fields.by = origin, seq, AF.playerName
    fields.id = origin .. "#" .. seq
    fields.t = fields.t or GetServerTime()
    fields.w = fields.w or AF.Standings.WeekOf(fields.t)
    if not Add(fields) then return nil end
    AF.Comm:Send("EV", fields, "GUILD")
    AF:Fire("LEDGER_UPDATED")
    AF.Standings:QueueSnapshot()
    return fields
end

-- Sets this week's correction for a category (+/-, at most the cap either way).
function Ledger:SetCategory(name, category, value, reason)
    local cap = AF.Config:Get(category .. "Max")
    value = math.max(-cap, math.min(cap, math.floor(value + 0.5)))
    return Record({ k = "cat", n = name, c = category, v = value, r = reason })
end

function Ledger:RecordWin(name, link, reason)
    return Record({ k = "won", n = name, l = link, r = reason })
end

-- fields: n, src, t, and a or i/q (l optional). origin/seq: see the header.
function Ledger:RecordDeposit(fields, origin, seq)
    fields.k = "dep"
    return Record(fields, origin, seq)
end

-- report: enc, en, d, p, size, t, o, s (see Attendance.lua).
function Ledger:RecordKill(report)
    return Record({ k = "kill", enc = report.enc, en = report.en, d = report.d, p = report.p,
        size = report.size, t = report.t }, report.o, report.s)
end

-- A player's weekly honor as their client reported it. The honor amount is the
-- sequence number, so officers recording the same report make the same event.
function Ledger:RecordHonor(name, week, honor)
    return Record({ k = "honor", n = name, h = honor, w = week }, "honor:" .. name .. ":" .. week, honor)
end

-- Links a character to a main (m == n: it is a main itself). src "self" is the
-- character's own report (origin "link:<character>", sequence = when the main
-- was chosen, so resends make the same event); "officer" is a manual link.
function Ledger:RecordLink(name, main, src, chosenAt)
    if src == "self" then
        return Record({ k = "link", n = name, m = main, src = "self", t = chosenAt }, "link:" .. name, chosenAt)
    end
    return Record({ k = "link", n = name, m = main, src = "officer" })
end

function Ledger:RecordBench(killId, name, week)
    return Record({ k = "bench", n = name, ref = killId, w = week }, "bench:" .. killId .. ":" .. name, 1)
end

-- Removes an event from every score by recording a void for it.
function Ledger:Void(target, reason)
    if voided[target.id] then return nil end
    return Record({ k = "void", ref = target.id, w = target.w, r = reason })
end

function Ledger:Get(id) return events[id] end
function Ledger:IsVoided(id) return voided[id] == true end

-------------------------------------------------------------------------------
--  Mains and alts
-------------------------------------------------------------------------------
-- The link that counts for a character: officers' links beat the character's
-- own report; within each, the newest wins.
local function CurrentLink(name)
    local best
    for _, e in ipairs(links[name] or {}) do
        if Live(e) then
            local better = not best
                or (e.src == "officer" and best.src ~= "officer")
                or (e.src == best.src and Newer(e, best))
            if better then best = e end
        end
    end
    return best
end

-- The main a character belongs to (itself if it is a main or isn't linked).
function Ledger:MainOf(name)
    local seen = { [name] = true }
    local current = name
    for _ = 1, 4 do      -- follow at most a few hops, and never round in a loop
        local link = CurrentLink(current)
        if not link or link.m == current or seen[link.m] then break end
        seen[link.m] = true
        current = link.m
    end
    return current
end

-- A player's characters: the main first, then the alts (sorted).
function Ledger:Characters(name)
    local main = self:MainOf(name)
    local alts = {}
    for char in pairs(links) do
        if char ~= main and self:MainOf(char) == main then table.insert(alts, char) end
    end
    table.sort(alts)
    table.insert(alts, 1, main)
    return alts, main
end

-- Every character linked to another main: { alt = main }.
function Ledger:AltMap()
    local out = {}
    for char in pairs(links) do
        local main = self:MainOf(char)
        if main ~= char then out[char] = main end
    end
    return out
end

-------------------------------------------------------------------------------
--  Reading. Everything is per player: the main and all alts together.
-------------------------------------------------------------------------------
-- Gold counted for one character's deposits in a week. Their own client's reports
-- and the bank log can both see the same deposit, so per source we add up the
-- net, and per kind (gold, each wanted item) count the larger source, never both.
local function CharGold(week, name)
    local list = deps[week] and deps[week][name]
    if not list then return nil end
    local totals = { self = {}, log = {} }    -- source -> "gold" or itemID -> net amount
    local any = false
    for _, e in ipairs(list) do
        if Live(e) then
            any = true
            local key, amount = "gold", e.a
            if not e.a then key, amount = e.i, e.q end
            totals[e.src][key] = (totals[e.src][key] or 0) + amount
        end
    end
    if not any then return nil end
    local wanted = AF.Config:Get("wanted")
    local gold = 0
    local keys = {}
    for _, byKey in pairs(totals) do
        for key in pairs(byKey) do keys[key] = true end
    end
    for key in pairs(keys) do
        local amount = math.max(totals.self[key] or 0, totals.log[key] or 0, 0)
        if key == "gold" then
            gold = gold + amount / 10000
        else
            gold = gold + amount * (wanted[key] or 0)
        end
    end
    return gold
end

-- Highest live honor report for one character and week, or nil.
local function CharHonor(week, name)
    local best
    for _, e in ipairs(honors[week] and honors[week][name] or {}) do
        if Live(e) and (not best or e.h > best) then best = e.h end
    end
    return best
end

-- Adds up a per-character number over a player's characters (nil if none has one).
local function SumOver(chars, fn, week)
    local total
    for _, char in ipairs(chars) do
        local v = fn(week, char)
        if v then total = (total or 0) + v end
    end
    return total
end

-- How many of an item the whole guild deposited since a time (goal progress).
-- Per character and week, the larger of the two sources counts, never both.
function Ledger:DepositedSince(itemID, since)
    local total = 0
    for _, byName in pairs(deps) do
        for _, list in pairs(byName) do
            local bySource = { self = 0, log = 0 }
            for _, e in ipairs(list) do
                if Live(e) and e.i == itemID and e.t >= since then
                    bySource[e.src] = bySource[e.src] + e.q
                end
            end
            total = total + math.max(bySource.self, bySource.log, 0)
        end
    end
    return total
end

-- Gold counted for a player's deposits in a week (all their characters).
function Ledger:DepositGold(week, name)
    return SumOver(self:Characters(name), CharGold, week)
end

-- A player's honor this week (all their characters).
function Ledger:WeekHonor(week, name)
    return SumOver(self:Characters(name), CharHonor, week)
end

-- Guild kills a player was at (any of their characters, or benched) in a week,
-- and all guild kills. A kill counts once even if two of their characters were there.
function Ledger:RaidAttendance(week, name)
    local chars = self:Characters(name)
    local here, total = 0, 0
    for _, kill in ipairs(kills[week] or {}) do
        if Live(kill) then
            total = total + 1
            for _, char in ipairs(chars) do
                local bench = benched[kill.id] and benched[kill.id][char]
                if present[kill.id][char] or (bench and Live(bench)) then
                    here = here + 1
                    break
                end
            end
        end
    end
    return here, total
end

-- The player's correction for a category: each character's newest, added up.
local function Correction(chars, week, category)
    local total
    for _, char in ipairs(chars) do
        local list = cats[week] and cats[week][char] and cats[week][char][category]
        local best
        for _, e in ipairs(list or {}) do
            if Live(e) and (not best or Newer(e, best)) then best = e end
        end
        if best then total = (total or 0) + best.v end
    end
    return total
end

-- { raid = n, bank = n, honor = n }: tracked points plus corrections, capped per
-- player (main and alts together); nil if the ledger knows nothing about that
-- player and week. Asking for an alt gives its main's numbers.
function Ledger:Breakdown(week, name)
    local chars = self:Characters(name)
    local here, total = self:RaidAttendance(week, name)
    local gold = self:DepositGold(week, name)
    local honor = self:WeekHonor(week, name)
    local tracked = {
        raid = total > 0 and math.floor(AF.Config:Get("raidMax") * here / total + 0.5) or nil,
        bank = gold and math.floor(gold / AF.Config:Get("goldPerPoint")) or nil,
        honor = honor and math.floor(AF.Config:Get("honorMax") * math.min(1, honor / AF.Config:Get("honorTarget"))) or nil,
    }
    local runCount = self:DungeonRuns(week, name)
    if runCount > 0 then tracked.dungeon = math.floor(runCount * AF.Config:Get("dungeonPerRun")) end
    local out, known = {}, false
    for _, category in ipairs(AF.Standings.CATEGORIES) do
        local auto = tracked[category]
        local correction = Correction(chars, week, category)
        if auto or correction then
            local cap = AF.Config:Get(category .. "Max")
            out[category] = math.max(0, math.min(cap, (auto or 0) + (correction or 0)))
            known = true
        end
    end
    return known and out or nil
end

-- Weekly score and whether the ledger knows anything about that week.
function Ledger:WeekScore(week, name)
    local b = self:Breakdown(week, name)
    if not b then return 0, false end
    local total = 0
    for _, v in pairs(b) do total = total + v end
    return math.min(total, AF.Standings.WeekMax()), true
end

-------------------------------------------------------------------------------
--  Dungeon runs. Every guild member in the group reports the same run, so the
--  reports are grouped: same dungeon, within RUN_MERGE seconds, sharing a player.
-------------------------------------------------------------------------------
local function RunGroups(week)
    if runGroups[week] then return runGroups[week] end
    local list = {}
    for _, e in ipairs(runs[week] or {}) do
        if Live(e) then table.insert(list, e) end
    end
    table.sort(list, function(a, b) return a.t < b.t end)
    local groups = {}
    for _, e in ipairs(list) do
        local joined
        for _, g in ipairs(groups) do
            if g.map == e.map and e.t - g.t <= RUN_MERGE then
                for _, name in ipairs(e.p) do
                    if g.members[name] then joined = g break end
                end
            end
            if joined then break end
        end
        if joined then
            for _, name in ipairs(e.p) do joined.members[name] = true end
        else
            local members = {}
            for _, name in ipairs(e.p) do members[name] = true end
            table.insert(groups, { map = e.map, mn = e.mn, boss = e.en, t = e.t, members = members })
        end
    end
    runGroups[week] = groups
    return groups
end

-- How many runs a player (any of their characters) did in a week.
function Ledger:DungeonRuns(week, name)
    local chars = self:Characters(name)
    local count = 0
    for _, g in ipairs(RunGroups(week)) do
        for _, char in ipairs(chars) do
            if g.members[char] then
                count = count + 1
                break
            end
        end
    end
    return count
end

-- A run reported by a guild member in the group (origin "dun:<reporter>",
-- sequence = time of the kill, so resends make the same event).
function Ledger:RecordRun(report, reporter)
    return Record({ k = "run", enc = report.enc, en = report.en, map = report.map, mn = report.mn,
        p = report.p, t = report.t }, "dun:" .. reporter, report.t)
end

-- Items a player (any of their characters) won in a week.
function Ledger:Won(week, name)
    local out = {}
    for _, char in ipairs(self:Characters(name)) do
        for _, e in ipairs(won[week] and won[week][char] or {}) do
            if Live(e) then table.insert(out, e.l) end
        end
    end
    return out
end

-- Items won in the last `weeks` weeks (removed ones left out), newest first.
function Ledger:Wins(weeks)
    local oldest = AF.Standings.CurrentWeek() - weeks + 1
    local out = {}
    for week, byName in pairs(won) do
        if week >= oldest then
            for _, list in pairs(byName) do
                for _, e in ipairs(list) do
                    if Live(e) then table.insert(out, e) end
                end
            end
        end
    end
    table.sort(out, Newer)
    return out
end

-- A player's bank-log deposit events in the weeks we keep, removed ones
-- included (so a removed entry isn't recorded again on the next read).
function Ledger:LogDeposits(name)
    local out = {}
    for _, byName in pairs(deps) do
        for _, e in ipairs(byName[name] or {}) do
            if e.src == "log" then table.insert(out, e) end
        end
    end
    return out
end

-- The newest events, newest first.
function Ledger:Recent(count)
    local list = {}
    for _, e in pairs(events) do table.insert(list, e) end
    table.sort(list, Newer)
    for i = #list, count + 1, -1 do list[i] = nil end
    return list
end

function Ledger:Count()
    local n = 0
    for _ in pairs(events) do n = n + 1 end
    return n
end

-- Everyone with points, deposits or raid attendance in the last `weeks` weeks.
function Ledger:Players(weeks)
    local current = AF.Standings.CurrentWeek()
    local seen, out = {}, {}
    local function Note(name)
        for _, who in ipairs({ name, self:MainOf(name) }) do   -- an alt's activity shows on its main too
            if not seen[who] then
                seen[who] = true
                table.insert(out, who)
            end
        end
    end
    for week = current - weeks + 1, current do
        for _, store in ipairs({ cats, deps, honors }) do
            for name in pairs(store[week] or {}) do Note(name) end
        end
        for _, kill in ipairs(kills[week] or {}) do
            for name in pairs(present[kill.id]) do Note(name) end
            for name in pairs(benched[kill.id] or {}) do Note(name) end
        end
        for _, run in ipairs(runs[week] or {}) do
            for _, name in ipairs(run.p) do Note(name) end
        end
    end
    return out
end

-------------------------------------------------------------------------------
--  Sync between officers
-------------------------------------------------------------------------------
local function Digest()
    local d = {}
    for week, byOrigin in pairs(buckets) do
        d[week] = {}
        for origin, b in pairs(byOrigin) do d[week][origin] = { c = b.count, m = b.max } end
    end
    return d
end

-- Every event in a (week, origin) group where we have more than they do.
local function MissingFrom(theirs)
    if type(theirs) ~= "table" then theirs = {} end
    local wanted = {}
    for week, byOrigin in pairs(buckets) do
        for origin, mine in pairs(byOrigin) do
            local t = type(theirs[week]) == "table" and theirs[week][origin]
            if type(t) ~= "table" or mine.count > (tonumber(t.c) or 0) or mine.max > (tonumber(t.m) or 0) then
                wanted[week .. "\001" .. origin] = true
            end
        end
    end
    local out = {}
    for _, e in pairs(events) do
        if wanted[e.w .. "\001" .. e.o] then table.insert(out, e) end
    end
    return out
end

local function SendEvents(list, target)
    for i = 1, #list, BATCH do
        local batch = {}
        for j = i, math.min(i + BATCH - 1, #list) do table.insert(batch, list[j]) end
        AF.Comm:Send("EVS", batch, "WHISPER", target)
    end
end

local function FromOfficer(sender)
    return sender ~= AF.playerName and Ledger:CanRecord() and AF.Config:IsOfficer(sender)
end

local function Receive(list)
    local added = 0
    for _, e in ipairs(list) do
        if Valid(e) and Add(e) then added = added + 1 end
    end
    if added > 0 then AF:Fire("LEDGER_UPDATED") end
    return added
end

AF.Comm:On("EV", function(sender, e)
    if FromOfficer(sender) then Receive({ e }) end
end)

AF.Comm:On("EVS", function(sender, list)
    if FromOfficer(sender) and type(list) == "table" then Receive(list) end
end)

-- An officer logged in: send what they lack, and our digest so they can do the same.
AF.Comm:On("SYNCQ", function(sender, digest)
    if not FromOfficer(sender) then return end
    C_Timer.After(0.5 + math.random() * 3, function()
        AF.Comm:Send("SYNCD", Digest(), "WHISPER", sender)
        SendEvents(MissingFrom(digest), sender)
    end)
end)

AF.Comm:On("SYNCD", function(sender, digest)
    if FromOfficer(sender) then SendEvents(MissingFrom(digest), sender) end
end)

-------------------------------------------------------------------------------
--  Export / import: a copy of the ledger as text, kept outside the game
-------------------------------------------------------------------------------
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local EXPORT_PREFIX = "AFLEDGER1:"

local function Encode(s)
    local out = {}
    for i = 1, #s, 3 do
        local a, b, c = s:byte(i, i + 2)
        local n = a * 65536 + (b or 0) * 256 + (c or 0)
        local d1, d2 = math.floor(n / 262144) % 64, math.floor(n / 4096) % 64
        local d3, d4 = math.floor(n / 64) % 64, n % 64
        out[#out + 1] = B64:sub(d1 + 1, d1 + 1) .. B64:sub(d2 + 1, d2 + 1)
            .. (b and B64:sub(d3 + 1, d3 + 1) or "=") .. (c and B64:sub(d4 + 1, d4 + 1) or "=")
    end
    return table.concat(out)
end

local function Decode(s)
    if #s % 4 ~= 0 then return nil end
    local out = {}
    for i = 1, #s, 4 do
        local n, pad = 0, 0
        for j = i, i + 3 do
            local ch = s:sub(j, j)
            if ch == "=" then
                pad = pad + 1
                n = n * 64
            else
                n = n * 64 + (B64:find(ch, 1, true) - 1)
            end
        end
        local bytes = string.char(math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256)
        out[#out + 1] = bytes:sub(1, 3 - pad)
    end
    return table.concat(out)
end

function Ledger:Export()
    local list = {}
    for _, e in pairs(events) do table.insert(list, e) end
    table.sort(list, function(a, b) return Newer(b, a) end)
    return EXPORT_PREFIX .. Encode(AF.Comm.Serialize(list)), #list
end

-- Merges an export into the ledger and shares the new events with officers
-- online. Returns added count, or nil plus a reason.
function Ledger:Import(text)
    if not self:CanRecord() then return nil, "Only officers can import." end
    text = (text or ""):gsub("%s", "")
    if text:sub(1, #EXPORT_PREFIX) ~= EXPORT_PREFIX then return nil, "That isn't an AdventForever ledger export." end
    local raw = Decode(text:sub(#EXPORT_PREFIX + 1):gsub("[^%w%+/=]", ""))
    local list = raw and AF.Comm.Deserialize(raw)
    if type(list) ~= "table" then return nil, "The export is damaged (copied only part of it?)." end
    local added = {}
    for _, e in ipairs(list) do
        if Valid(e) and Add(e) then table.insert(added, e) end
    end
    if #added > 0 then
        for i = 1, #added, BATCH do
            local batch = {}
            for j = i, math.min(i + BATCH - 1, #added) do table.insert(batch, added[j]) end
            AF.Comm:Send("EVS", batch, "GUILD")
        end
        AF:Fire("LEDGER_UPDATED")
        AF.Standings:QueueSnapshot()
    end
    return #added
end

-------------------------------------------------------------------------------
--  Startup
-------------------------------------------------------------------------------
function Ledger:Init()
    local db = AF.db
    db.events = db.events or {}
    db.seq = db.seq or 0
    -- One token per install, so a reinstalled client never reuses old event ids.
    db.origin = db.origin or ("%x%04x"):format(time(), math.random(0, 0xffff))
    events = db.events
end

function Ledger:Enable()
    local oldest = AF.Standings.CurrentWeek() - KEEP_WEEKS
    for id, e in pairs(events) do
        if not Valid(e) or (e.w < oldest and not TIMELESS[e.k]) then events[id] = nil else Index(e) end
    end
    Ledger.readyAt = GetTime() + SYNC_SETTLE
    -- Wait for the guild roster so we know who the officers are.
    C_Timer.After(20, function()
        if Ledger:CanRecord() then AF.Comm:Send("SYNCQ", Digest(), "GUILD") end
    end)
end
