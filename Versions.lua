-------------------------------------------------------------------------------
--  Versions.lua -- who runs which version, and whether the raid is ready.
--
--  Every client says its version to the guild after login and to the raid when
--  it joins one (VER). Hearing a newer version brings up the update card once per
--  session; officers whisper outdated players once (addon message, no chat).
--
--  /af versions asks the group (VERQ 2). Current clients answer with RDY: their
--  version, durability (repair %, the lowest item) and flask / elixir buffs.
--  Older clients answer VERQ with VER alone, so they show a version but no
--  readiness. Range is checked on our side.
-------------------------------------------------------------------------------
local _, AF = ...
local Versions = AF:NewModule("Versions")

local ANSWER_WAIT = 5           -- seconds to wait for answers before calling someone "not installed"
local REMIND_TEXT = "Your AdventForever is out of date (%s; the current one is %s). Please update it through WowUp, CurseForge or Wago."
local INSTALL_TEXT = "Please install AdventForever (CurseForge, Wago or WowUp). The guild uses it for effort and loot."

local versions = {}             -- full name -> version number
local ready = {}                -- full name -> { d = repair %, low = lowest item %, f = flask, e = { elixirs }, at = GetTime() }
local queriedAt                 -- GetTime() of the last /af versions question
local waiting = false
local newest = AF.VERSION       -- highest version seen this session
local replied = {}
local wasInRaid = false

function Versions.String(v)
    return ("%d.%d.%d"):format(math.floor(v / 10000), math.floor(v / 100) % 100, v % 100)
end

function Versions.Newest() return newest end

-------------------------------------------------------------------------------
--  Our own readiness
-------------------------------------------------------------------------------
-- Repair % over all equipped items (what the game's durability figure shows) and
-- the lowest single item, or nil with nothing that wears.
local function Durability()
    if type(GetInventoryItemDurability) ~= "function" then return nil end
    local cur, max, low = 0, 0, nil
    for slot = 1, 19 do
        local c, m = GetInventoryItemDurability(slot)
        if type(c) == "number" and type(m) == "number" and m > 0 and not AF:IsSecret(c) then
            cur, max = cur + c, max + m
            local pct = c / m * 100
            if not low or pct < low then low = pct end
        end
    end
    if max == 0 then return nil end
    return math.floor(cur / max * 100 + 0.5), math.floor(low + 0.5)
end

local function BuffNames()
    local out = {}
    for i = 1, 40 do
        local name
        if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
            local aura = C_UnitAuras.GetAuraDataByIndex("player", i, "HELPFUL")
            if not aura then break end
            name = aura.name
        elseif UnitBuff then
            name = UnitBuff("player", i)
            if not name then break end
        else
            break
        end
        if type(name) == "string" and not AF:IsSecret(name) then table.insert(out, name) end
    end
    return out
end

-- Battle and guardian elixirs whose buff isn't called "... Elixir" / "Elixir of ...".
local ELIXIR_BUFFS = {
    ["Greater Agility"] = true, ["Greater Intellect"] = true, ["Agility"] = true, ["Intellect"] = true,
    ["Greater Armor"] = true, ["Health II"] = true, ["Mana Regeneration"] = true,
    ["Spirit of Zanza"] = true, ["Swiftness of Zanza"] = true, ["Sheen of Zanza"] = true,
}

-- The flask we have up (name) and our elixirs (names).
local function Consumables()
    local flask, elixirs = nil, {}
    for _, name in ipairs(BuffNames()) do
        if name:find("Flask") then
            flask = name
        elseif name:find("Elixir") or ELIXIR_BUFFS[name] then
            table.insert(elixirs, name)
        end
    end
    return flask, elixirs
end

local function OwnReadiness()
    local d, low = Durability()
    local f, e = Consumables()
    return { v = AF.VERSION, d = d, low = low, f = f, e = e }
end

-------------------------------------------------------------------------------
--  Messages
-------------------------------------------------------------------------------
local function Seen(sender, version, channel)
    versions[sender] = version
    if version > newest then
        newest = version
        AF:Printf("|cffff5555A newer version (%s) is out; you have %s. Please update.|r",
            Versions.String(version), AF.VERSION_STRING)
        AF:Fire("NEWER_VERSION", version)
    elseif version < AF.VERSION and channel ~= "WHISPER" and AF.Ledger:CanRecord() and not replied[sender] then
        -- Officers tell outdated players directly, once per session.
        replied[sender] = true
        AF.Comm:Send("VER", AF.VERSION, "WHISPER", sender)
    end
    AF:Fire("VERSIONS_UPDATED")
end

AF.Comm:On("VER", function(sender, version, channel)
    if type(version) ~= "number" or sender == AF.playerName then return end
    Seen(sender, version, channel)
end)

AF.Comm:On("RDY", function(sender, r)
    if type(r) ~= "table" or type(r.v) ~= "number" then return end
    ready[sender] = {
        d = type(r.d) == "number" and r.d or nil,
        low = type(r.low) == "number" and r.low or nil,
        f = type(r.f) == "string" and r.f or nil,
        e = type(r.e) == "table" and r.e or {},
        at = GetTime(),
    }
    if sender == AF.playerName then
        versions[sender] = r.v
        return AF:Fire("VERSIONS_UPDATED")
    end
    Seen(sender, r.v, "WHISPER")
end)

-- payload 2: the asker wants readiness too (older askers send true and get VER).
AF.Comm:On("VERQ", function(sender, payload)
    if payload == 2 then
        AF.Comm:Send("RDY", OwnReadiness(), "WHISPER", sender)
    else
        AF.Comm:Send("VER", AF.VERSION, "WHISPER", sender)
    end
end)

-------------------------------------------------------------------------------
--  Asking the group
-------------------------------------------------------------------------------
function Versions:Query()
    if not IsInGroup() then return false end
    queriedAt = GetTime()
    waiting = true
    AF.Comm:Send("VERQ", 2, "RAID")
    AF.Comm:Send("RDY", OwnReadiness(), "WHISPER", AF.playerName)   -- our own row, the same way
    C_Timer.After(ANSWER_WAIT, function()
        waiting = false
        AF:Fire("VERSIONS_UPDATED")
    end)
    AF:Fire("VERSIONS_UPDATED")
    return true
end

function Versions:Waiting() return waiting end

local function InRange(unit)
    if UnitIsUnit(unit, "player") then return true end
    if type(UnitInRange) ~= "function" then return nil end
    local ok, inRange, checked = pcall(UnitInRange, unit)
    if not ok or AF:IsSecret(inRange) or AF:IsSecret(checked) then return nil end
    if checked == false then return nil end
    return inRange and true or false
end

local ORDER = { missing = 1, outdated = 2, offline = 3, waiting = 4, current = 5 }

-- One row per group member:
--   name, class, unit, state ("current", "outdated", "missing", "waiting", "offline"),
--   v (version or nil), r (readiness from this question, or nil), range (true/false/nil)
function Versions:Rows()
    local rows = {}
    for _, name in ipairs(AF:GroupMembers()) do
        local unit = AF:GroupUnit(name)
        local v = name == AF.playerName and AF.VERSION or versions[name]
        local r = ready[name]
        if r and (not queriedAt or r.at < queriedAt) then r = nil end
        local online = not unit or UnitIsConnected(unit)
        local state
        if not online then
            state = "offline"
        elseif not v then
            state = waiting and "waiting" or "missing"
        elseif v < newest then
            state = "outdated"
        else
            state = "current"
        end
        table.insert(rows, {
            name = name, unit = unit, class = unit and select(2, UnitClass(unit)),
            state = state, v = v, r = r, range = unit and online and InRange(unit) or nil,
        })
    end
    table.sort(rows, function(a, b)
        if ORDER[a.state] ~= ORDER[b.state] then return ORDER[a.state] < ORDER[b.state] end
        return a.name < b.name
    end)
    return rows
end

-------------------------------------------------------------------------------
--  Reminders (officers): a whisper to every guild member in the group who is
--  outdated or hasn't got the addon
-------------------------------------------------------------------------------
local function Whisper(text, target)
    local send = C_ChatInfo and C_ChatInfo.SendChatMessage or SendChatMessage
    return pcall(send, text, "WHISPER", nil, target)
end

function Versions:Remind()
    if not AF.Ledger:CanRecord() then return AF:Print("Only officers can send reminders.") end
    if AF:IsChatLocked() then return AF:Print("Chat is locked right now (combat); try again after the pull.") end
    local sent = 0
    for _, row in ipairs(self:Rows()) do
        if row.name ~= AF.playerName and AF.Standings:All()[row.name] then
            local text
            if row.state == "outdated" then
                text = REMIND_TEXT:format(Versions.String(row.v), Versions.String(newest))
            elseif row.state == "missing" then
                text = INSTALL_TEXT
            end
            if text and Whisper(text, row.name) then sent = sent + 1 end
        end
    end
    AF:Printf(sent > 0 and "Reminded %d player%s." or "Nobody to remind.", sent, sent == 1 and "" or "s")
end

-------------------------------------------------------------------------------
--  Saying our version
-------------------------------------------------------------------------------
function Versions:Enable()
    C_Timer.After(10, function() AF.Comm:Send("VER", AF.VERSION, "GUILD") end)
    wasInRaid = IsInRaid()
end

AF:RegisterEvent("GROUP_ROSTER_UPDATE", function()
    local inRaid = IsInRaid()
    if inRaid and not wasInRaid then
        C_Timer.After(3, function() AF.Comm:Send("VER", AF.VERSION, "RAID") end)
    end
    wasInRaid = inRaid
    AF:Fire("VERSIONS_UPDATED")
end)
