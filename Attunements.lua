-------------------------------------------------------------------------------
--  Attunements.lua -- who is attuned to what. Everyone sees it.
--
--  An attunement is done when any of its quests is completed or its key item
--  is owned (bags, bank or key ring). The classic ones are built in; officers
--  hide the ones Forever doesn't use and add new ones (Config.attunes).
--
--  Every client checks its own character after login, after turning in a quest,
--  when its bags change and when the list changes, and tells the guild (ATT) when
--  its result changed. AF.db.attuned = { [character] = { t, d = { [key] = true/false } } };
--  a key missing from d means "not checked yet" (e.g. added after they were last on).
--
--  After login a client says how many characters it knows (ATTQ); someone who
--  knows more sends the guild everything (one answer: the others stay quiet when
--  they see it).
-------------------------------------------------------------------------------
local _, AF = ...
local Attunements = AF:NewModule("Attunements")

Attunements.MAX = 8             -- columns in the overview

-- Built in, in raid order.
local BUILT_IN = {
    { key = "ubrs", n = "Upper Blackrock Spire", s = "UBRS", q = { 4743 }, i = 12344 },   -- Seal of Ascension
    { key = "mc", n = "Molten Core", s = "MC", q = { 7848 } },                            -- Attunement to the Core
    { key = "ony", n = "Onyxia's Lair", s = "Ony", q = { 6502, 6602 }, i = 16309 },       -- Drakefire Amulet
    { key = "bwl", n = "Blackwing Lair", s = "BWL", q = { 7761 } },                       -- Blackhand's Command
    { key = "naxx", n = "Naxxramas", s = "Naxx", q = { 9121, 9122, 9123 } },              -- The Dread Citadel
}

local CHECK_DELAY = 3
local checkTimer, answerTimer

local function Store()
    AF.db.attuned = AF.db.attuned or {}
    return AF.db.attuned
end

-- The attunements in use: { { key, n, s, q, i, builtIn }, ... }, built-in ones
-- first, then the officers' in the order they were added.
function Attunements:List()
    local out = {}
    local off = AF.Config:Get("attunesOff")
    for _, a in ipairs(BUILT_IN) do
        if not off[a.key] then
            table.insert(out, { key = a.key, n = a.n, s = a.s, q = a.q, i = a.i, builtIn = true })
        end
    end
    local added = {}
    for key, a in pairs(AF.Config:Get("attunes")) do
        table.insert(added, { key = key, n = a.n, s = a.s, q = a.q, i = a.i })
    end
    table.sort(added, function(a, b) return a.key < b.key end)
    for _, a in ipairs(added) do table.insert(out, a) end
    while #out > Attunements.MAX do table.remove(out) end
    return out
end

function Attunements:HiddenCount()
    local n = 0
    for _ in pairs(AF.Config:Get("attunesOff")) do n = n + 1 end
    return n
end

-------------------------------------------------------------------------------
--  Our own status
-------------------------------------------------------------------------------
local function QuestDone(id)
    local fn = (C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted) or _G.IsQuestFlaggedCompleted
    if type(fn) ~= "function" then return false end
    local ok, done = pcall(fn, id)
    return ok and done == true
end

local function ItemOwned(id)
    local fn = (C_Item and C_Item.GetItemCount) or _G.GetItemCount
    if type(fn) ~= "function" then return false end
    local ok, count = pcall(fn, id, true)      -- true: the bank too
    return ok and type(count) == "number" and count > 0
end

function Attunements.IsDone(a)
    for _, q in ipairs(a.q or {}) do
        if QuestDone(q) then return true end
    end
    return a.i ~= nil and ItemOwned(a.i)
end

local function Send(names)
    local out = {}
    for name in pairs(names) do out[name] = Store()[name] end
    if next(out) then AF.Comm:Send("ATT", out, "GUILD") end
end

-- Checks every attunement; tells the guild if anything changed (or force).
local function Check(force)
    checkTimer = nil
    if not AF.playerName then return end
    local d = {}
    for _, a in ipairs(Attunements:List()) do d[a.key] = Attunements.IsDone(a) end
    local mine = Store()[AF.playerName]
    local changed = not mine
    if mine then
        for key, done in pairs(d) do
            if mine.d[key] ~= done then changed = true end
        end
    end
    if changed then
        Store()[AF.playerName] = { t = GetServerTime(), d = d }
        AF:Fire("ATTUNEMENTS_UPDATED")
    end
    if changed or force then Send({ [AF.playerName] = true }) end
end

local function CheckSoon()
    if checkTimer then checkTimer:Cancel() end
    checkTimer = C_Timer.NewTimer(CHECK_DELAY, function() Check(false) end)
end

AF:RegisterEvent("QUEST_TURNED_IN", CheckSoon)
AF:RegisterEvent("BAG_UPDATE_DELAYED", CheckSoon)
AF:RegisterEvent("BANKFRAME_OPENED", CheckSoon)
AF:On("CONFIG_UPDATED", function()
    CheckSoon()
    AF:Fire("ATTUNEMENTS_UPDATED")
end)

-------------------------------------------------------------------------------
--  Everyone's status
-------------------------------------------------------------------------------
-- true / false, or nil when we don't know (no data, or not checked yet).
function Attunements:Status(name, key)
    local entry = Store()[name]
    if entry then return entry.d[key] end
end

-- The characters to show: guild members we have data for (all of them while
-- the roster isn't loaded).
function Attunements:Players()
    local roster = AF.Standings:All()
    local any = next(roster) ~= nil
    local out = {}
    for name in pairs(Store()) do
        if not any or roster[name] then table.insert(out, name) end
    end
    return out
end

-------------------------------------------------------------------------------
--  Sharing
-------------------------------------------------------------------------------
local function Count()
    local n = 0
    for _ in pairs(Store()) do n = n + 1 end
    return n
end

local function Own()
    local own = {}
    for _, name in ipairs(AF.Alts:AccountCharacters()) do own[name] = true end
    if AF.playerName then own[AF.playerName] = true end
    return own
end

AF.Comm:On("ATT", function(sender, data)
    if type(data) ~= "table" or sender == AF.playerName then return end
    local store, own, changed, n = Store(), Own(), false, 0
    for name, entry in pairs(data) do
        n = n + 1
        local ok = type(name) == "string" and not own[name] and type(entry) == "table"
            and type(entry.t) == "number" and type(entry.d) == "table"
        if ok and (not store[name] or store[name].t < entry.t) then
            local d = {}
            for key, done in pairs(entry.d) do
                if type(key) == "string" and type(done) == "boolean" then d[key] = done end
            end
            store[name] = { t = entry.t, d = d }
            changed = true
        end
    end
    -- Someone answered an ATTQ with at least as much as we would: stay quiet.
    if answerTimer and n >= Count() then
        answerTimer:Cancel()
        answerTimer = nil
    end
    if changed then AF:Fire("ATTUNEMENTS_UPDATED") end
end)

AF.Comm:On("ATTQ", function(sender, theirCount)
    if sender == AF.playerName or type(theirCount) ~= "number" or answerTimer then return end
    if Count() <= theirCount then return end
    answerTimer = C_Timer.NewTimer(3 + math.random() * 9, function()
        answerTimer = nil
        AF.Comm:Send("ATT", Store(), "GUILD", nil, true)
    end)
end)

function Attunements:Enable()
    C_Timer.After(20, function() Check(true) end)
    C_Timer.After(30, function()
        if IsInGuild() then AF.Comm:Send("ATTQ", Count(), "GUILD") end
    end)
end

-------------------------------------------------------------------------------
--  Officers: adding and removing
-------------------------------------------------------------------------------
-- requirement: quest IDs ("7848" or "6502, 6602") or a shift-clicked key item.
function Attunements:Add(name, short, requirement)
    name = (name or ""):match("^%s*(.-)%s*$")
    short = (short or ""):match("^%s*(.-)%s*$")
    if name == "" or #name > 40 then return nil, "Give the attunement a name (up to 40 letters)." end
    if short == "" or #short > 5 then return nil, "Give it a short label for the column (up to 5 letters)." end
    if #self:List() >= Attunements.MAX then
        return nil, ("There can be at most %d attunements. Remove one first."):format(Attunements.MAX)
    end
    local def = { n = name, s = short, q = {} }
    local item = type(requirement) == "string" and requirement:match("item:(%d+)")
    if item then
        def.i = tonumber(item)
    else
        for id in (requirement or ""):gmatch("%d+") do table.insert(def.q, tonumber(id)) end
    end
    if #def.q == 0 and not def.i then
        return nil, "Type the quest ID(s) that finish it (e.g. 7848), or shift-click its key item."
    end
    return AF.Config:SetAttune(("c%d"):format(GetServerTime()), def)
end

function Attunements:Remove(key)
    return AF.Config:SetAttune(key, nil)
end

function Attunements:RestoreBuiltIn()
    return AF.Config:SetAttune(nil, nil, true)
end
