-------------------------------------------------------------------------------
--  Professions.lua -- the guild's profession directory: who can craft what, and
--  everyone's profession levels. Everyone sees it.
--
--  Your client reads your recipes when you open a profession window (and your
--  profession levels from your skills). Recipes are only ever added: a filtered
--  or half-collapsed window can't make you lose any. A profession you drop
--  leaves the list once the skills show it gone.
--
--  AF.db.crafters = { [character] = { t = server time, p = { [profession] =
--      { r = level, m = max level, i = { itemIDs made }, s = { spellIDs without an item (enchants) } } } } }
--  AF.db.ownCrafters = { [character] = true } -- this account's characters
--
--  Sharing (all of it on Comm's slow lane, except the two tiny messages):
--    after a change     PROF with our character to the guild
--    after login        PROFD: a digest of everything we have (name -> t) and which
--                       names are ours. Others who are behind on our characters
--                       answer PROFQ { own }; we send our characters to the guild once.
--                       Others who have newer data than we do answer PROFH { n = how
--                       many characters }; we ask the one with most (PROFQ { all }),
--                       and it whispers us everything newer than our digest.
-------------------------------------------------------------------------------
local _, AF = ...
local Professions = AF:NewModule("Professions")

local PRUNE_DAYS = 120          -- forget characters not updated for this long
local SEND_DELAY = 10           -- seconds of quiet after a change before telling the guild
local DIGEST_DELAY = 40         -- after login
local OFFER_WAIT = 6            -- seconds to collect PROFH answers
local OWN_WAIT = 5              -- seconds to collect PROFQ { own } requests

-- Profession names as the skills list shows them (English client).
local PROFESSIONS = {
    Alchemy = true, Blacksmithing = true, Enchanting = true, Engineering = true, Herbalism = true,
    Leatherworking = true, Mining = true, Skinning = true, Tailoring = true, Jewelcrafting = true,
    Inscription = true, Cooking = true, ["First Aid"] = true, Fishing = true,
}

local index                     -- id -> { { name, prof }, ... }; id < 0 is a spell
local sendTimer, ownTimer, offerTimer
local digests = {}              -- sender -> the digest they sent (to answer PROFQ { all })
local offers = {}               -- sender -> how many newer characters they have for us

local function Store()
    AF.db.crafters = AF.db.crafters or {}
    return AF.db.crafters
end

local function Own()
    AF.db.ownCrafters = AF.db.ownCrafters or {}
    return AF.db.ownCrafters
end

local function Changed()
    index = nil
    AF:Fire("PROFESSIONS_UPDATED")
end

-------------------------------------------------------------------------------
--  Compact lists: sorted IDs as base-36 gaps, "a,3,1b,..." (a few bytes per recipe)
-------------------------------------------------------------------------------
local DIGITS = "0123456789abcdefghijklmnopqrstuvwxyz"

local function Base36(n)
    if n == 0 then return "0" end
    local out = ""
    while n > 0 do
        local d = n % 36
        out = DIGITS:sub(d + 1, d + 1) .. out
        n = math.floor(n / 36)
    end
    return out
end

local function Encode(ids)
    local sorted = {}
    for _, id in ipairs(ids) do table.insert(sorted, id) end
    table.sort(sorted)
    local out, last = {}, 0
    for _, id in ipairs(sorted) do
        table.insert(out, Base36(id - last))
        last = id
    end
    return table.concat(out, ",")
end

local function Decode(text)
    local ids, last = {}, 0
    if type(text) ~= "string" then return ids end
    for part in text:gmatch("[^,]+") do
        local gap = tonumber(part, 36)
        if not gap or gap < 0 then return {} end
        last = last + gap
        if last > 0 then table.insert(ids, last) end
    end
    return ids
end

local function Pack(entry)
    local p = {}
    for prof, d in pairs(entry.p) do p[prof] = { r = d.r, m = d.m, i = Encode(d.i), s = Encode(d.s) } end
    return { t = entry.t, p = p }
end

local function Unpack(packed)
    if type(packed) ~= "table" or type(packed.t) ~= "number" or type(packed.p) ~= "table" then return nil end
    local p = {}
    for prof, d in pairs(packed.p) do
        if type(prof) == "string" and #prof <= 40 and type(d) == "table" then
            p[prof] = { r = tonumber(d.r) or 0, m = tonumber(d.m) or 0, i = Decode(d.i), s = Decode(d.s) }
        end
    end
    return { t = packed.t, p = p }
end

-------------------------------------------------------------------------------
--  Our own professions
-------------------------------------------------------------------------------
local function Mine()
    local store = Store()
    local me = store[AF.playerName]
    if not me then
        me = { t = 0, p = {} }
        store[AF.playerName] = me
    end
    Own()[AF.playerName] = true
    return me
end

local function SendOwn(names)
    local out = {}
    for name in pairs(names) do
        if Store()[name] then out[name] = Pack(Store()[name]) end
    end
    if next(out) then AF.Comm:Send("PROF", out, "GUILD", nil, true) end
end

-- Marks our data changed and tells the guild after a quiet moment.
local function Touch()
    Mine().t = GetServerTime()
    Changed()
    if sendTimer then sendTimer:Cancel() end
    sendTimer = C_Timer.NewTimer(SEND_DELAY, function()
        sendTimer = nil
        SendOwn({ [AF.playerName] = true })
    end)
end

-- Adds recipes to a profession; returns true if anything changed.
local function Merge(prof, rank, max, items, spells)
    local entry = Mine().p
    local d = entry[prof]
    local changed = false
    if not d then
        d = { r = 0, m = 0, i = {}, s = {} }
        entry[prof] = d
        changed = true
    end
    if rank and rank > 0 and (rank ~= d.r or (max or 0) ~= d.m) then
        d.r, d.m = rank, max or d.m
        changed = true
    end
    for key, list in pairs({ i = items, s = spells }) do
        local have = {}
        for _, id in ipairs(d[key]) do have[id] = true end
        for _, id in ipairs(list) do
            if not have[id] then
                have[id] = true
                table.insert(d[key], id)
                changed = true
            end
        end
    end
    return changed
end

local function ItemIDOf(link)
    return type(link) == "string" and tonumber(link:match("item:(%d+)"))
end

local function SpellIDOf(link)
    return type(link) == "string" and tonumber(link:match("enchant:(%d+)") or link:match("spell:(%d+)"))
end

local function Call(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a, b, c, d, e, f, g = pcall(fn, ...)
    if ok then return a, b, c, d, e, f, g end
end

local function Linked()
    if Call(_G.IsTradeSkillLinked) then return true end
    local api = C_TradeSkillUI
    return api and (Call(api.IsTradeSkillLinked) or Call(api.IsTradeSkillGuild) or Call(api.IsNPCCrafting)) and true or false
end

-- Classic trade skill window (everything but Enchanting).
local function ScanTradeSkill()
    local prof, rank, max = Call(_G.GetTradeSkillLine)
    if type(prof) ~= "string" or prof == "" or prof == "UNKNOWN" or AF:IsSecret(prof) then return false end
    local items, spells, collapsed = {}, {}, false
    for i = 1, Call(_G.GetNumTradeSkills) or 0 do
        local name, kind, _, expanded = Call(_G.GetTradeSkillInfo, i)
        if kind == "header" or kind == "subheader" then
            if expanded == false then collapsed = true end
        elseif name then
            local id = ItemIDOf(Call(_G.GetTradeSkillItemLink, i))
            if id then
                table.insert(items, id)
            else
                local spell = SpellIDOf(Call(_G.GetTradeSkillRecipeLink, i))
                if spell then table.insert(spells, spell) end
            end
        end
    end
    if collapsed then Call(_G.ExpandTradeSkillSubClass, 0) end   -- the update that follows rescans
    return Merge(prof, rank, max, items, spells)
end

-- Classic craft window (Enchanting).
local function ScanCraft()
    local prof, rank, max = Call(_G.GetCraftDisplaySkillLine)
    if type(prof) ~= "string" or prof == "" or AF:IsSecret(prof) then return false end
    local items, spells, collapsed = {}, {}, false
    for i = 1, Call(_G.GetNumCrafts) or 0 do
        local name, _, kind, _, expanded = Call(_G.GetCraftInfo, i)
        if kind == "header" then
            if expanded == false then collapsed = true end
        elseif name then
            local link = Call(_G.GetCraftItemLink, i)
            local id = ItemIDOf(link)
            if id then
                table.insert(items, id)
            else
                local spell = SpellIDOf(link) or SpellIDOf(Call(_G.GetCraftRecipeLink, i))
                if spell then table.insert(spells, spell) end
            end
        end
    end
    if collapsed then Call(_G.ExpandCraftSkillLine, 0) end
    return Merge(prof, rank, max, items, spells)
end

-- Newer clients: C_TradeSkillUI.
local function ScanModern()
    local api = C_TradeSkillUI
    if not api or type(api.GetAllRecipeIDs) ~= "function" then return false end
    local info = Call(api.GetBaseProfessionInfo) or Call(api.GetChildProfessionInfo)
    local prof = info and info.professionName
    if type(prof) ~= "string" or prof == "" then return false end
    local items, spells = {}, {}
    for _, recipeID in ipairs(Call(api.GetAllRecipeIDs) or {}) do
        local recipe = Call(api.GetRecipeInfo, recipeID)
        if recipe and recipe.learned then
            local schematic = Call(api.GetRecipeSchematic, recipeID, false)
            local id = schematic and schematic.outputItemID
            if type(id) == "number" and id > 0 then
                table.insert(items, id)
            else
                table.insert(spells, recipeID)
            end
        end
    end
    return Merge(prof, info.skillLevel, info.maxSkillLevel, items, spells)
end

local scanPending
local function ScanSoon(scanner)
    if scanPending then return end
    scanPending = true
    C_Timer.After(1, function()
        scanPending = false
        if not AF.playerName or Linked() then return end
        local ok, changed = pcall(scanner)
        if ok and changed then Touch() end
    end)
end

for _, event in ipairs({ "TRADE_SKILL_SHOW", "TRADE_SKILL_UPDATE" }) do
    AF:RegisterEvent(event, function()
        ScanSoon(type(_G.GetNumTradeSkills) == "function" and ScanTradeSkill or ScanModern)
    end)
end
for _, event in ipairs({ "TRADE_SKILL_LIST_UPDATE", "TRADE_SKILL_DATA_SOURCE_CHANGED" }) do
    AF:RegisterEvent(event, function() ScanSoon(ScanModern) end)
end
for _, event in ipairs({ "CRAFT_SHOW", "CRAFT_UPDATE" }) do
    AF:RegisterEvent(event, function() ScanSoon(ScanCraft) end)
end

-- Profession levels from the skills list (gathering and secondary professions
-- too), and dropped professions. Returns true if anything changed.
local function ScanSkills()
    local found, complete = {}, true
    if type(_G.GetNumSkillLines) == "function" then
        for i = 1, Call(_G.GetNumSkillLines) or 0 do
            local name, header, expanded, rank, _, _, max = Call(_G.GetSkillLineInfo, i)
            if header then
                if not expanded then complete = false end
            elseif type(name) == "string" and PROFESSIONS[name] then
                found[name] = { rank, max }
            end
        end
    elseif type(_G.GetProfessions) == "function" then
        for _, i in ipairs({ Call(_G.GetProfessions) }) do
            if type(i) == "number" then
                local name, _, rank, max = Call(_G.GetProfessionInfo, i)
                if type(name) == "string" then found[name] = { rank, max } end
            end
        end
    else
        return false
    end
    local changed = false
    for name, level in pairs(found) do
        if Merge(name, level[1], level[2], {}, {}) then changed = true end
    end
    if complete then
        local p = Mine().p
        for name in pairs(p) do
            if PROFESSIONS[name] and not found[name] then
                p[name] = nil
                changed = true
            end
        end
    end
    return changed
end

local skillsPending
AF:RegisterEvent("SKILL_LINES_CHANGED", function()
    if skillsPending or not AF.playerName then return end
    skillsPending = true
    C_Timer.After(2, function()
        skillsPending = false
        local ok, changed = pcall(ScanSkills)
        if ok and changed then Touch() end
    end)
end)

-------------------------------------------------------------------------------
--  Reading the directory
-------------------------------------------------------------------------------
-- Whether a character belongs in the directory: in the guild (once the roster
-- is known) or one of ours.
local function Listed(name)
    if Own()[name] then return true end
    local roster = AF.Standings:All()
    return next(roster) == nil or roster[name] ~= nil
end

local function Online(name)
    if name == AF.playerName then return true end
    local m = AF.Standings:All()[name]
    return m and m.online or false
end

local function BuildIndex()
    index = {}
    for name, entry in pairs(Store()) do
        if Listed(name) then
            for prof, d in pairs(entry.p) do
                for _, id in ipairs(d.i) do
                    index[id] = index[id] or {}
                    table.insert(index[id], { name = name, prof = prof })
                end
                for _, id in ipairs(d.s) do
                    index[-id] = index[-id] or {}
                    table.insert(index[-id], { name = name, prof = prof })
                end
            end
        end
    end
end

local function SortCrafters(list)
    local out = {}
    for _, c in ipairs(list) do
        table.insert(out, { name = c.name, prof = c.prof, online = Online(c.name) })
    end
    table.sort(out, function(a, b)
        if a.online ~= b.online then return a.online end
        return a.name < b.name
    end)
    return out
end

-- Who can make an item: { { name, prof, online }, ... }, online first.
function Professions:CraftersOf(itemID)
    if not index then BuildIndex() end
    return SortCrafters(index[itemID] or {})
end

-- The name of a directory entry (id < 0: a spell such as an enchant), or nil
-- while the game hasn't loaded it yet.
function Professions.NameOf(id)
    if id > 0 then
        if C_Item.GetItemNameByID then return C_Item.GetItemNameByID(id) end
        return (C_Item.GetItemInfo(id))
    end
    if C_Spell and C_Spell.GetSpellName then return C_Spell.GetSpellName(-id) end
    return GetSpellInfo and (GetSpellInfo(-id)) or nil
end

-- Everything matching a search, by name: { { id, name, crafters }, ... }.
function Professions:Search(text)
    if not index then BuildIndex() end
    text = text:lower()
    local out = {}
    for id, crafters in pairs(index) do
        local name = Professions.NameOf(id)
        if name and name:lower():find(text, 1, true) then
            table.insert(out, { id = id, name = name, crafters = SortCrafters(crafters) })
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

-- Every character's professions: { { name, prof, r, m, n (recipes), online }, ... }.
function Professions:Players()
    local out = {}
    for name, entry in pairs(Store()) do
        if Listed(name) then
            for prof, d in pairs(entry.p) do
                table.insert(out, { name = name, prof = prof, r = d.r, m = d.m, n = #d.i + #d.s,
                    online = Online(name) })
            end
        end
    end
    table.sort(out, function(a, b)
        if a.prof ~= b.prof then return a.prof < b.prof end
        if a.r ~= b.r then return a.r > b.r end
        return a.name < b.name
    end)
    return out
end

-------------------------------------------------------------------------------
--  Sharing
-------------------------------------------------------------------------------
local function Digest()
    local d, own = {}, {}
    for name, entry in pairs(Store()) do d[name] = entry.t end
    for name in pairs(Own()) do own[name] = true end
    return { d = d, o = own }
end

-- Characters we have newer data for than a digest says.
local function NewerThan(digest)
    local out = {}
    for name, entry in pairs(Store()) do
        local theirs = digest[name]
        if entry.t > 0 and Listed(name) and (type(theirs) ~= "number" or theirs < entry.t) then out[name] = true end
    end
    return out
end

AF.Comm:On("PROF", function(sender, data)
    if type(data) ~= "table" then return end
    local store, own, changed = Store(), Own(), false
    for name, packed in pairs(data) do
        -- Our own characters' data is ours alone.
        local entry = type(name) == "string" and not own[name] and Unpack(packed)
        if entry and (not store[name] or store[name].t < entry.t) then
            store[name] = entry
            changed = true
        end
    end
    if changed then Changed() end
end)

AF.Comm:On("PROFD", function(sender, data)
    if sender == AF.playerName or type(data) ~= "table" or type(data.d) ~= "table" then return end
    digests[sender] = data.d
    -- Behind on their own characters: ask them to send them.
    local store = Store()
    for name in pairs(type(data.o) == "table" and data.o or {}) do
        local theirs = data.d[name]
        if type(theirs) == "number" and (not store[name] or store[name].t < theirs) then
            AF.Comm:Send("PROFQ", { own = true }, "WHISPER", sender)
            break
        end
    end
    -- Ahead of them on anyone: say how far.
    local n = 0
    for _ in pairs(NewerThan(data.d)) do n = n + 1 end
    if n > 0 then
        C_Timer.After(1 + math.random() * 3, function() AF.Comm:Send("PROFH", { n = n }, "WHISPER", sender) end)
    end
end)

AF.Comm:On("PROFH", function(sender, data)
    if type(data) ~= "table" or type(data.n) ~= "number" or not offerTimer then return end
    offers[sender] = data.n
end)

AF.Comm:On("PROFQ", function(sender, data)
    if type(data) ~= "table" then return end
    if data.own then
        -- Several people may ask at once: one send to the guild covers them all.
        if not ownTimer then
            ownTimer = C_Timer.NewTimer(OWN_WAIT, function()
                ownTimer = nil
                SendOwn(Own())
            end)
        end
    elseif data.all and digests[sender] then
        local out = {}
        for name in pairs(NewerThan(digests[sender])) do out[name] = Pack(Store()[name]) end
        digests[sender] = nil
        if next(out) then AF.Comm:Send("PROF", out, "WHISPER", sender, true) end
    end
end)

local function SendDigest()
    if not IsInGuild() then return end
    wipe(offers)
    AF.Comm:Send("PROFD", Digest(), "GUILD", nil, true)
    -- The digest goes on the slow lane; give it time to arrive before counting offers.
    offerTimer = C_Timer.NewTimer(OFFER_WAIT + 15, function()
        offerTimer = nil
        local best, most = nil, 0
        for name, n in pairs(offers) do
            if n > most then best, most = name, n end
        end
        if best then AF.Comm:Send("PROFQ", { all = true }, "WHISPER", best) end
    end)
end

function Professions:Init()
    local cutoff = GetServerTime() - PRUNE_DAYS * 86400
    for name, entry in pairs(Store()) do
        if type(entry) ~= "table" or type(entry.p) ~= "table" or ((entry.t or 0) > 0 and entry.t < cutoff) then
            Store()[name] = nil
        end
    end
end

function Professions:Enable()
    C_Timer.After(10, function()
        local ok, changed = pcall(ScanSkills)
        if ok and changed then Touch() end
    end)
    C_Timer.After(DIGEST_DELAY, SendDigest)
end

-- For /af debug: which recipe API this client has, and what we know.
function Professions.ApiReport()
    local api = (type(_G.GetNumTradeSkills) == "function" and "classic trade skills")
        or (C_TradeSkillUI and C_TradeSkillUI.GetAllRecipeIDs and "C_TradeSkillUI") or "none"
    local craft = type(_G.GetNumCrafts) == "function"
    local mine, characters = 0, 0
    local me = AF.playerName and Store()[AF.playerName]
    for _, d in pairs(me and me.p or {}) do mine = mine + #d.i + #d.s end
    for _ in pairs(Store()) do characters = characters + 1 end
    return api, craft, mine, characters
end

-------------------------------------------------------------------------------
--  Item tooltips: who can make it
-------------------------------------------------------------------------------
local SHOWN = 4

local function AddTooltipLines(tooltip, link)
    if not link or AF:IsSecret(link) or not AF.playerName then return end
    local id = ItemIDOf(link)
    if not id then return end
    local crafters = Professions:CraftersOf(id)
    if #crafters == 0 then return end
    local names = {}
    for i = 1, math.min(SHOWN, #crafters) do
        local c = crafters[i]
        table.insert(names, c.online and ("|cff4fe0a6%s|r"):format(AF:ShortName(c.name)) or AF:ShortName(c.name))
    end
    if #crafters > SHOWN then table.insert(names, ("+%d more"):format(#crafters - SHOWN)) end
    tooltip:AddLine("Crafted by: " .. table.concat(names, ", "), 0.53, 0.75, 1, true)
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip)
        if tooltip ~= GameTooltip and tooltip ~= ItemRefTooltip then return end
        local ok, _, link = pcall(tooltip.GetItem, tooltip)
        if ok then AddTooltipLines(tooltip, link) end
    end)
else
    for _, tooltip in ipairs({ GameTooltip, ItemRefTooltip }) do
        tooltip:HookScript("OnTooltipSetItem", function(self)
            local _, link = self:GetItem()
            AddTooltipLines(self, link)
        end)
    end
end

AF:On("STANDINGS_UPDATED", function() index = nil end)
