-------------------------------------------------------------------------------
--  GuildLoot.lua -- guild loot in raids: the raid leader gets every good item and
--  hands it out with the loot window, so nobody can need on it first.
--
--  In a guild raid (a raid instance, at least guildKillShare % guild members, no
--  master loot), on group loot rolls for items of AUTO_QUALITY or better:
--    - raiders pass automatically (and see it in chat)
--    - the raid leader needs (or greeds when need isn't possible) and confirms
--      the bind-on-pickup question for those rolls
--    - items the raid leader loots start loot sessions automatically, a few
--      seconds' worth at a time
--  Officers' clients watch the roll lines in loot chat and warn when someone
--  other than the raid leader rolls on, or wins, such an item.
--  Players without the addon can't be made to pass; the warnings show them.
-------------------------------------------------------------------------------
local _, AF = ...
local GuildLoot = AF:NewModule("GuildLoot")

local AUTO_QUALITY = Enum and Enum.ItemQuality and Enum.ItemQuality.Rare or 3
local NEED, GREED, PASS = 1, 2, 0
local SESSION_BATCH = 3         -- seconds: drops this close become one round of loot sessions

local autoRolled = {}           -- rollID -> roll type we chose (to confirm bind-on-pickup)
local batch, batchTimer = {}, nil

-------------------------------------------------------------------------------
--  Is this a guild raid?
-------------------------------------------------------------------------------
local function RaidLeader()
    for i = 1, GetNumGroupMembers() do
        if UnitIsGroupLeader("raid" .. i) then return AF:UnitFullName("raid" .. i) end
    end
end

-- In a raid instance, enough guild members, and the raid leader hands out loot.
function GuildLoot.Active()
    if not IsInRaid() or AF:HasMasterLoot() then return false end
    local _, instanceType = IsInInstance()
    if instanceType ~= "raid" then return false end
    local members, guild = AF:GroupMembers(), 0
    for _, name in ipairs(members) do
        if AF.Standings:All()[name] then guild = guild + 1 end
    end
    return #members > 0 and guild / #members * 100 >= AF.Config:Get("guildKillShare")
end

local function IAmLeader() return UnitIsGroupLeader("player") end

-------------------------------------------------------------------------------
--  Rolling
-------------------------------------------------------------------------------
local function Roll(rollID)
    if type(RollOnLoot) ~= "function" then return end
    local _, _, _, quality, _, canNeed, canGreed = GetLootRollItemInfo(rollID)
    if AF:IsSecret(quality) or type(quality) ~= "number" or quality < AUTO_QUALITY then return end
    local link = GetLootRollItemLink(rollID) or "the item"
    if IAmLeader() then
        local choice = canNeed and NEED or (canGreed and GREED) or nil
        if not choice then
            return AF:Printf("|cffffd055Guild loot: you can't roll on %s. Someone else will get it.|r", link)
        end
        autoRolled[rollID] = choice
        RollOnLoot(rollID, choice)
    else
        RollOnLoot(rollID, PASS)
        AF:Printf("Passed on %s: the raid leader hands out guild loot.", link)
    end
end

AF:RegisterEvent("START_LOOT_ROLL", function(_, rollID)
    if AF:IsSecret(rollID) or not GuildLoot.Active() then return end
    AF:WhenUnrestricted(function() Roll(rollID) end)
end)

-- The "this item will bind to you" question, for the rolls we made ourselves.
AF:RegisterEvent("CONFIRM_LOOT_ROLL", function(_, rollID, rollType)
    if autoRolled[rollID] and autoRolled[rollID] == rollType and type(ConfirmLootRoll) == "function" then
        ConfirmLootRoll(rollID, rollType)
        autoRolled[rollID] = nil
        if StaticPopup_Hide then StaticPopup_Hide("CONFIRM_LOOT_ROLL", rollID) end
    end
end)

-------------------------------------------------------------------------------
--  The raid leader's loot becomes loot sessions
-------------------------------------------------------------------------------
local function LineStart(format)
    if type(format) ~= "string" then return nil end
    local start = format:match("^(.-)%%s")
    return start ~= "" and start or nil
end
local LOOTED = LineStart(LOOT_ITEM_SELF)

local function StartBatch()
    batchTimer = nil
    local links = batch
    batch = {}
    if #links > 0 and GuildLoot.Active() and IAmLeader() then
        AF:Printf("Guild loot: starting loot sessions for %d item%s.", #links, #links == 1 and "" or "s")
        AF.Loot:StartSessions(links)
    end
end

local function OwnLoot(text)
    if not LOOTED or text:find(LOOTED, 1, true) ~= 1 then return end
    local link = text:match("(|c[^|]*|Hitem:.-|h|r)")
    local quality = link and C_Item.GetItemQualityByID and C_Item.GetItemQualityByID(link)
    if not quality or quality < AUTO_QUALITY then return end
    table.insert(batch, link)
    if batchTimer then batchTimer:Cancel() end
    batchTimer = C_Timer.NewTimer(SESSION_BATCH, StartBatch)
end

-------------------------------------------------------------------------------
--  Warnings for officers: someone else rolled on, or won, a guild item
-------------------------------------------------------------------------------
-- Turns a game format string ("%s has selected Need for: %s") into a pattern
-- capturing the name and the item, whatever order the language puts them in.
-- order[k] = which of the format's arguments (1 = name, 2 = item) capture k holds.
local function RollPattern(format)
    if type(format) ~= "string" then return nil end
    local out, order, i, auto = { "^" }, {}, 1, 0
    while i <= #format do
        local n, stop = format:match("^%%(%d)%$s()", i)
        if n then                                   -- "%1$s": a numbered argument
            table.insert(order, tonumber(n))
            table.insert(out, "(.+)")
            i = stop
        elseif format:sub(i, i + 1) == "%s" then    -- "%s": the next argument
            auto = auto + 1
            table.insert(order, auto)
            table.insert(out, "(.+)")
            i = i + 2
        else
            local c = format:sub(i, i)
            if c:match("[%^%$%(%)%%%.%[%]%*%+%-%?]") then c = "%" .. c end
            table.insert(out, c)
            i = i + 1
        end
    end
    table.insert(out, "$")
    return table.concat(out), order
end

local WATCH = {}
for _, key in ipairs({ "LOOT_ROLL_NEED", "LOOT_ROLL_GREED", "LOOT_ROLL_WON" }) do
    local pattern, order = RollPattern(_G[key])
    if pattern then table.insert(WATCH, { key = key, pattern = pattern, order = order }) end
end

local function PlainName(text)
    return AF:FullName((text:gsub("|H.-|h(.-)|h", "%1"):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")))
end

local function Watch(text)
    if not AF.Ledger:CanRecord() then return end
    for _, w in ipairs(WATCH) do
        local captures = { text:match(w.pattern) }
        if #captures >= 2 then
            local args = {}
            for k, argIndex in ipairs(w.order) do args[argIndex] = captures[k] end
            local name, link = args[1], args[2]
            local quality = link and C_Item.GetItemQualityByID and C_Item.GetItemQualityByID(link)
            local who = name and PlainName(name)
            if quality and quality >= AUTO_QUALITY and who and who ~= RaidLeader() then
                if w.key == "LOOT_ROLL_WON" then
                    AF:Printf("|cffff5555Guild loot: %s won %s instead of the raid leader.|r", AF:ShortName(who), link)
                else
                    AF:Printf("|cffff5555Guild loot: %s rolled %s on %s.|r", AF:ShortName(who),
                        w.key == "LOOT_ROLL_NEED" and "Need" or "Greed", link)
                end
            end
            return
        end
    end
end

AF:RegisterEvent("CHAT_MSG_LOOT", function(_, text)
    if AF:IsSecret(text) or type(text) ~= "string" or not GuildLoot.Active() then return end
    if IAmLeader() then OwnLoot(text) end
    Watch(text)
end)

-- For /af debug.
function GuildLoot.Status()
    return GuildLoot.Active(), type(RollOnLoot) == "function", #WATCH
end
