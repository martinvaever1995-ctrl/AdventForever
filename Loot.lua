-------------------------------------------------------------------------------
--  Loot.lua -- loot sessions. The addon decides nothing: it collects responses
--  and shows effort, and the officers pick who gets the item.
--
--  Loot authority (master looter, or raid leader without master loot):
--    corpse opened (or /af item) -> ITEMS to the raid -> RESP whispers back ->
--    candidates grouped by response, effort shown -> officer clicks a player:
--    master loot hands the item over, or without master loot the holder is told
--    to trade it.
--  Everyone: ITEMS -> popup (Main spec / Off spec / Pass) -> RESP to the sender.
--  Officers: every award goes in the ledger as "won this week" (information only).
-------------------------------------------------------------------------------
local _, AF = ...
local Loot = AF:NewModule("Loot")

Loot.MS, Loot.OS, Loot.PASS = 1, 2, 3
Loot.RESPONSE_TEXT = { "Main spec", "Off spec", "Pass" }

-- Equip slot -> inventory slots to compare against.
local SLOTS = {
    INVTYPE_HEAD = { 1 }, INVTYPE_NECK = { 2 }, INVTYPE_SHOULDER = { 3 }, INVTYPE_BODY = { 4 },
    INVTYPE_CHEST = { 5 }, INVTYPE_ROBE = { 5 }, INVTYPE_WAIST = { 6 }, INVTYPE_LEGS = { 7 },
    INVTYPE_FEET = { 8 }, INVTYPE_WRIST = { 9 }, INVTYPE_HAND = { 10 }, INVTYPE_FINGER = { 11, 12 },
    INVTYPE_TRINKET = { 13, 14 }, INVTYPE_CLOAK = { 15 }, INVTYPE_WEAPON = { 16, 17 },
    INVTYPE_SHIELD = { 17 }, INVTYPE_2HWEAPON = { 16 }, INVTYPE_WEAPONMAINHAND = { 16 },
    INVTYPE_WEAPONOFFHAND = { 17 }, INVTYPE_HOLDABLE = { 17 }, INVTYPE_RANGED = { 18 },
    INVTYPE_THROWN = { 18 }, INVTYPE_RANGEDRIGHT = { 18 }, INVTYPE_RELIC = { 18 }, INVTYPE_TABARD = { 19 },
}

-- Links of what the player has equipped where this item would go.
function Loot.EquippedFor(link)
    local equipLoc = select(4, C_Item.GetItemInfoInstant(link))
    local out = {}
    for _, slot in ipairs(SLOTS[equipLoc] or {}) do
        local equipped = GetInventoryItemLink("player", slot)
        if equipped then table.insert(out, equipped) end
    end
    return out
end

local function Ilvl(link)
    local level = link and C_Item.GetDetailedItemLevelInfo and C_Item.GetDetailedItemLevelInfo(link)
    if not level and link then level = select(4, C_Item.GetItemInfo(link)) end
    return level
end

-- Item level gain over what's equipped in that slot: against the weaker of two
-- (rings, trinkets, one-handers). Returns diff, or nil when it can't be said
-- (no equip slot, or item levels not known yet); emptySlot = nothing equipped.
function Loot.IlvlDiff(link, equipped)
    local equipLoc = link and select(4, C_Item.GetItemInfoInstant(link))
    if not equipLoc or equipLoc == "" or not SLOTS[equipLoc] then return nil end
    local level = Ilvl(link)
    if not level then return nil end
    if #equipped < #SLOTS[equipLoc] then return level, true end   -- a slot is empty: all gain
    local weakest
    for _, other in ipairs(equipped) do
        local l = Ilvl(other)
        if not l then return nil end
        weakest = weakest and math.min(weakest, l) or l
    end
    return level - weakest, false
end

-------------------------------------------------------------------------------
--  Can this class use the item? (classic proficiencies, at max level)
-------------------------------------------------------------------------------
local ARMOR, WEAPON = 4, 2      -- item class IDs
-- Armor subclass -> classes that can wear it.
local ARMOR_USERS = {
    [1] = "ALL",                                                           -- cloth
    [2] = { DRUID = 1, ROGUE = 1, HUNTER = 1, SHAMAN = 1, WARRIOR = 1, PALADIN = 1 },   -- leather
    [3] = { HUNTER = 1, SHAMAN = 1, WARRIOR = 1, PALADIN = 1 },              -- mail
    [4] = { WARRIOR = 1, PALADIN = 1 },                                      -- plate
    [6] = { WARRIOR = 1, PALADIN = 1, SHAMAN = 1 },                          -- shield
    [7] = { PALADIN = 1 }, [8] = { DRUID = 1 }, [9] = { SHAMAN = 1 },        -- libram, idol, totem
}
local ARMOR_NAMES = { [2] = "leather", [3] = "mail", [4] = "plate", [6] = "shields", [7] = "librams",
    [8] = "idols", [9] = "totems" }
-- Weapon subclass -> classes that can use it.
local WEAPON_USERS = {
    [0] = { WARRIOR = 1, PALADIN = 1, HUNTER = 1, SHAMAN = 1 },                                     -- one-handed axes
    [1] = { WARRIOR = 1, PALADIN = 1, HUNTER = 1, SHAMAN = 1 },                                     -- two-handed axes
    [2] = { WARRIOR = 1, HUNTER = 1, ROGUE = 1 },                                                   -- bows
    [3] = { WARRIOR = 1, HUNTER = 1, ROGUE = 1 },                                                   -- guns
    [4] = { WARRIOR = 1, PALADIN = 1, ROGUE = 1, PRIEST = 1, SHAMAN = 1, DRUID = 1 },               -- one-handed maces
    [5] = { WARRIOR = 1, PALADIN = 1, SHAMAN = 1, DRUID = 1 },                                      -- two-handed maces
    [6] = { WARRIOR = 1, PALADIN = 1, HUNTER = 1 },                                                 -- polearms
    [7] = { WARRIOR = 1, PALADIN = 1, HUNTER = 1, ROGUE = 1, MAGE = 1, WARLOCK = 1 },               -- one-handed swords
    [8] = { WARRIOR = 1, PALADIN = 1, HUNTER = 1 },                                                 -- two-handed swords
    [10] = { WARRIOR = 1, HUNTER = 1, PRIEST = 1, SHAMAN = 1, MAGE = 1, WARLOCK = 1, DRUID = 1 },   -- staves
    [13] = { WARRIOR = 1, HUNTER = 1, ROGUE = 1, SHAMAN = 1, DRUID = 1 },                           -- fist weapons
    [15] = { WARRIOR = 1, HUNTER = 1, ROGUE = 1, PRIEST = 1, SHAMAN = 1, MAGE = 1, WARLOCK = 1, DRUID = 1 },   -- daggers
    [16] = { WARRIOR = 1, HUNTER = 1, ROGUE = 1 },                                                  -- thrown
    [18] = { WARRIOR = 1, HUNTER = 1, ROGUE = 1 },                                                  -- crossbows
    [19] = { PRIEST = 1, MAGE = 1, WARLOCK = 1 },                                                   -- wands
}

-- Class files allowed by the item's "Classes: ..." line (nil if it has none).
local function AllowedClasses(link)
    local pattern = ITEM_CLASSES_ALLOWED and "^" .. ITEM_CLASSES_ALLOWED:gsub("%%s", "(.+)") .. "$"
    if not pattern then return nil end
    local lines
    if C_TooltipInfo and C_TooltipInfo.GetHyperlink then
        local ok, data = pcall(C_TooltipInfo.GetHyperlink, link)
        lines = ok and data and data.lines
    end
    if not lines then return nil end
    for _, line in ipairs(lines) do
        local text = line.leftText
        local list = type(text) == "string" and not AF:IsSecret(text) and text:match(pattern)
        if list then
            local allowed = {}
            for name in list:gmatch("[^,]+") do
                name = name:match("^%s*(.-)%s*$")
                for file, localized in pairs(LOCALIZED_CLASS_NAMES_MALE or {}) do
                    if localized == name then allowed[file] = true end
                end
                for file, localized in pairs(LOCALIZED_CLASS_NAMES_FEMALE or {}) do
                    if localized == name then allowed[file] = true end
                end
            end
            return allowed
        end
    end
end

-- false plus a reason when classFile can't use the item; true otherwise (also
-- when we can't tell).
function Loot.CanUse(link, classFile)
    if type(link) ~= "string" or not classFile then return true end
    local allowed = AllowedClasses(link)
    if allowed and next(allowed) and not allowed[classFile] then
        return false, "Class-restricted item"
    end
    local _, _, _, equipLoc, _, classID, subclassID = C_Item.GetItemInfoInstant(link)
    local users = (classID == ARMOR and ARMOR_USERS[subclassID]) or (classID == WEAPON and WEAPON_USERS[subclassID])
    if not users or users == "ALL" or users[classFile] then return true end
    local className = (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[classFile]) or classFile
    if classID == ARMOR then
        return false, ("%ss can't use %s"):format(className, ARMOR_NAMES[subclassID] or "this armor")
    end
    local subclassInfo = C_Item.GetItemSubClassInfo or GetItemSubClassInfo
    local weaponName = subclassInfo and select(2, pcall(subclassInfo, classID, subclassID))
    return false, ("%ss can't use %s"):format(className, type(weaponName) == "string" and weaponName:lower() or "this weapon")
end

-- Notes from other players can't carry chat codes into our windows.
local function CleanNote(note)
    if type(note) ~= "string" then return nil end
    note = note:gsub("|", ""):gsub("^%s+", ""):gsub("%s+$", "")
    if note == "" then return nil end
    return note:sub(1, 60)
end
Loot.CleanNote = CleanNote

local TEST_OFFICERS = { "Aldric Thornwood", "Mira Ashgrove" }
local TEST_NOTES = { "BiS", "small upgrade", "BiS for tanking", "for my off spec set", "huge upgrade",
    "2-piece bonus", "sidegrade" }

-- Items won this raid week, from the officers' ledger (empty on raider clients).
function Loot:WonThisWeek(name)
    return AF.Ledger:Won(AF.Standings.CurrentWeek(), name)
end

-------------------------------------------------------------------------------
--  Loot authority side
-------------------------------------------------------------------------------
local sessions, order = {}, {}     -- sid -> session; sids oldest first
local seen = {}                    -- corpse+item keys already announced
local pending = {}                 -- loot slot -> { session, name } awaiting LOOT_SLOT_CLEARED
local incoming = {}                -- raider side: popups waiting for an answer, oldest first
local counter = 0

function Loot:Sessions() return order, sessions end

function Loot:StartSessions(links, sources)
    if not IsInGroup() then return AF:Print("You need to be in a group.") end
    if not AF:IsLootAuthority() then
        return AF:Print("Only the master looter (or raid leader without master loot) can start loot sessions.")
    end
    local items = {}
    for i, link in ipairs(links) do
        counter = counter + 1
        local sid = ("%d-%d"):format(time() % 1000000, counter)
        sessions[sid] = { sid = sid, link = link, source = sources and sources[i], responses = {}, votes = {},
            authority = AF.playerName }
        table.insert(order, sid)
        table.insert(items, { sid = sid, link = link })
    end
    AF.Comm:Send("ITEMS", { items = items, timeout = AF.Config:Get("responseTimeout") }, "RAID")
    AF.UI:ShowLootWindow(items[1] and items[1].sid)
end

-------------------------------------------------------------------------------
--  Test mode (/af test): a local session with made-up raiders and your popup,
--  to try the windows alone. Nothing is sent, recorded or announced.
-------------------------------------------------------------------------------
local TEST_RAIDERS = {
    { "Brakka Stonefist", "WARRIOR" }, { "Sylvi Dawnwhisper", "MAGE" }, { "Hollin Brightshield", "PALADIN" },
    { "Morrow Ashveil", "WARLOCK" }, { "Thessa Moonbrook", "PRIEST" }, { "Grimtusk Ravenhide", "HUNTER" },
    { "Vexa Nightthorn", "ROGUE" }, { "Oakroot Mossheart", "DRUID" }, { "Zulgar Stormcaller", "SHAMAN" },
    { "Ironhide Gravelbeard", "WARRIOR" }, { "Lumen Fairwind", "PRIEST" }, { "Quill Emberfall", "MAGE" },
}

local function EquippedLinks()
    local links = {}
    for slot = 1, 18 do
        local link = GetInventoryItemLink("player", slot)
        if link then table.insert(links, link) end
    end
    return links
end

-- Made-up awards for the Loot tab, in memory only (gone after /reload). They
-- look like ledger "won" events, marked test = true.
local testWins = {}
local TEST_HISTORY = 15

local function AddTestWin(name, classFile, link, response, t)
    table.insert(testWins, { k = "won", id = "test-win-" .. (#testWins + 1), n = name, classFile = classFile,
        l = link, r = response, t = t, w = AF.Standings.WeekOf(t), by = "Test", test = true })
end

local function FillTestHistory(gear)
    if #testWins > 0 or #gear == 0 then return end
    local now = GetServerTime()
    for _ = 1, TEST_HISTORY do
        local raider = TEST_RAIDERS[math.random(#TEST_RAIDERS)]
        local response = Loot.RESPONSE_TEXT[math.random(1, 3) == 3 and 2 or 1]   -- mostly Main spec
        AddTestWin(raider[1], raider[2], gear[math.random(#gear)], response, now - math.random(0, 8 * 7 * 86400))
    end
end

-- Items won in the last `weeks` weeks, newest first: the ledger's (officers) plus
-- any test awards.
function Loot:RecentWins(weeks)
    local list = AF.Ledger:CanRecord() and AF.Ledger:Wins(weeks) or {}
    local oldest = AF.Standings.CurrentWeek() - weeks + 1
    for _, e in ipairs(testWins) do
        if e.w >= oldest then table.insert(list, e) end
    end
    table.sort(list, function(a, b) return a.t > b.t end)
    return list
end

function Loot:HasTestWins() return #testWins > 0 end

function Loot:StartTest(link)
    local gear = EquippedLinks()
    link = link or gear[math.random(#gear)]
    if not link then return AF:Print("Equip something, or use /af test <shift-click an item>.") end
    FillTestHistory(gear)

    counter = counter + 1
    local sid = ("test-%d"):format(counter)
    local session = { sid = sid, link = link, responses = {}, votes = {}, test = true, fake = {},
        authority = AF.playerName }
    local slotGear = Loot.EquippedFor(link)
    for _, raider in ipairs(TEST_RAIDERS) do
        local weeks, effort = {}, 0
        for i = 1, 4 do
            weeks[i] = math.random(0, 10) * 10
            effort = effort + weeks[i]
        end
        local response = math.random(1, 5)          -- 4 and 5: no answer yet
        local won = {}
        if #gear > 0 and math.random() < 0.25 then won[1] = gear[math.random(#gear)] end
        table.insert(session.fake, {
            name = raider[1], classFile = raider[2], weeks = weeks, effort = effort,
            response = response <= 3 and response or nil,
            equipped = (response <= 3 and math.random() < 0.8) and slotGear or {},
            note = (response <= 2 and math.random() < 0.5) and TEST_NOTES[math.random(#TEST_NOTES)] or nil,
            wish = (response <= 2 and math.random() < 0.4) and math.random(1, AF.Wishlist.MAX) or nil,
            won = won,
        })
    end
    -- Two made-up officers vote for someone who wants it.
    local wanting = {}
    for _, fake in ipairs(session.fake) do
        if fake.response == Loot.MS or fake.response == Loot.OS then table.insert(wanting, fake.name) end
    end
    for _, officer in ipairs(TEST_OFFICERS) do
        if #wanting > 0 and math.random() < 0.8 then session.votes[officer] = wanting[math.random(#wanting)] end
    end
    sessions[sid] = session
    table.insert(order, sid)

    table.insert(incoming, { sid = sid, link = link, from = AF.playerName, test = true,
        expires = GetTime() + AF.Config:Get("responseTimeout") })
    AF.UI:ShowLootWindow(sid)
    AF.UI:ShowPopup()
    AF:Print("Test loot session started. Answer the popup, then award someone in the loot window. Nothing is sent or recorded.")
end

AF.Comm:On("RESP", function(sender, data)
    if type(data) ~= "table" then return end
    local session = sessions[data.sid]
    if not session or session.awarded or not AF:GroupUnit(sender) then return end
    if data.r ~= Loot.MS and data.r ~= Loot.OS and data.r ~= Loot.PASS then return end
    local eq = {}
    for _, link in ipairs(type(data.eq) == "table" and data.eq or {}) do
        if type(link) == "string" then table.insert(eq, link) end
    end
    local wish = type(data.w) == "number" and data.w >= 1 and data.w <= AF.Wishlist.MAX and math.floor(data.w) or nil
    session.responses[sender] = { r = data.r, eq = eq, note = CleanNote(data.n), wish = wish }
    AF:Fire("LOOT_UPDATED", session.sid)
end)

-------------------------------------------------------------------------------
--  The council: whoever hands out the loot plus every officer in the group.
--  They all get the responses and the votes; the rest of the raid doesn't.
-------------------------------------------------------------------------------
function Loot:Council(authority)
    local out, seen = {}, {}
    local function Add(name)
        if name and not seen[name] then
            seen[name] = true
            table.insert(out, name)
        end
    end
    Add(authority)
    for _, name in ipairs(AF:GroupMembers()) do
        if AF.Config:IsOfficer(name) then Add(name) end
    end
    return out
end

local function CanVote(session)
    return session.authority == AF.playerName or AF.Config:IsOfficer(AF.playerName)
end
Loot.CanVote = CanVote

-- Votes for (or takes back a vote for) a candidate. One vote per officer per item.
function Loot:Vote(sid, candidate)
    local session = sessions[sid]
    if not session or session.awarded then return end
    if not CanVote(session) then return AF:Print("Only officers vote.") end
    local choice = session.votes[AF.playerName] ~= candidate and candidate or false
    if session.test then
        session.votes[AF.playerName] = choice or nil
        return AF:Fire("LOOT_UPDATED", sid)
    end
    for _, name in ipairs(self:Council(session.authority)) do
        AF.Comm:Send("VOTE", { sid = sid, c = choice }, "WHISPER", name)
    end
end

AF.Comm:On("VOTE", function(sender, data)
    if type(data) ~= "table" then return end
    local session = sessions[data.sid]
    if not session or session.awarded then return end
    if sender ~= session.authority and not AF.Config:IsOfficer(sender) then return end
    if type(data.c) == "string" then
        session.votes[sender] = data.c
    elseif data.c == false then
        session.votes[sender] = nil
    end
    AF:Fire("LOOT_UPDATED", session.sid)
end)

-- candidate name -> { voter, ... } (sorted)
local function VotesByCandidate(session)
    local out = {}
    for voter, candidate in pairs(session.votes or {}) do
        out[candidate] = out[candidate] or {}
        table.insert(out[candidate], voter)
    end
    for _, voters in pairs(out) do table.sort(voters) end
    return out
end

-- Everyone in the group with what officers need to decide. Grouped Main spec,
-- Off spec, Pass, then no answer; within a group by effort, highest first. The
-- order is only a visual aid: any player can be awarded.
local GROUP = { [Loot.MS] = 1, [Loot.OS] = 2, [Loot.PASS] = 3 }

local function SortCandidates(list)
    table.sort(list, function(a, b)
        if a.group ~= b.group then return a.group < b.group end
        if a.effort ~= b.effort then return a.effort > b.effort end
        return a.name < b.name
    end)
    return list
end

local function TestCandidates(session)
    local list = {}
    local votes = VotesByCandidate(session)
    for _, fake in ipairs(session.fake) do
        local resp = fake.response
        table.insert(list, {
            name = fake.name, response = resp, equipped = fake.equipped, won = fake.won, note = fake.note, wish = fake.wish,
            member = { classFile = fake.classFile, weeks = fake.weeks, effort = fake.effort },
            effort = fake.effort, group = resp and GROUP[resp] or 4, voters = votes[fake.name] or {},
            cantUse = resp and resp ~= Loot.PASS and select(2, Loot.CanUse(session.link, fake.classFile)) or nil,
        })
    end
    -- You, with your real numbers, once you answer the popup.
    local mine = session.responses[AF.playerName]
    local me = AF.Standings:Get(AF.playerName)
    table.insert(list, {
        name = AF.playerName, response = mine and mine.r, equipped = mine and mine.eq or {}, won = {},
        note = mine and mine.note, wish = AF.Wishlist:MyRank(session.link), voters = votes[AF.playerName] or {},
        member = me, effort = me and me.effort or -1, group = mine and GROUP[mine.r] or 4,
        cantUse = mine and mine.r ~= Loot.PASS and select(2, Loot.CanUse(session.link, select(2, UnitClass("player")))) or nil,
    })
    return SortCandidates(list)
end

function Loot:Candidates(sid)
    local session = sessions[sid]
    if not session then return {} end
    if session.test then return TestCandidates(session) end
    local list = {}
    local names = AF:GroupMembers()
    local inGroup = {}
    for _, name in ipairs(names) do inGroup[name] = true end
    for name in pairs(session.responses) do
        if not inGroup[name] then table.insert(names, name) end   -- answered, then left
    end
    local votes = VotesByCandidate(session)
    for _, name in ipairs(names) do
        local resp = session.responses[name]
        local member = AF.Standings:Get(name)
        local unit = AF:GroupUnit(name)
        local classFile = (member and member.classFile) or (unit and select(2, UnitClass(unit)))
        table.insert(list, {
            name = name,
            response = resp and resp.r,
            equipped = resp and resp.eq or {},
            note = resp and resp.note,
            -- Rank on their wishlist: from their answer, else from the list we have.
            wish = resp and resp.wish or AF.Wishlist:RankOf(name, session.link),
            member = member,
            effort = member and member.effort or -1,
            won = self:WonThisWeek(name),
            group = resp and GROUP[resp.r] or 4,
            voters = votes[name] or {},
            -- Why they can't use it, when they asked for it anyway.
            cantUse = resp and resp.r ~= Loot.PASS and select(2, Loot.CanUse(session.link, classFile)) or nil,
        })
    end
    return SortCandidates(list)
end

local function Finalize(session, name, viaTrade)
    session.awarded = name
    local resp = session.responses[name]
    local respText = resp and Loot.RESPONSE_TEXT[resp.r] or "no response"
    if AF.Ledger:CanRecord() then
        AF.Ledger:RecordWin(name, session.link, respText)
    else
        AF:Print("You're not an officer, so this award isn't recorded under items won this week.")
    end

    local text = ("%s -> %s (%s)"):format(session.link, AF:ShortName(name), respText)
    if viaTrade then text = text .. " - please trade it to them" end
    if AF:IsChatLocked() then
        AF:Print(text)
    else
        local send = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
        send(text, IsInRaid() and "RAID" or "PARTY")
    end
    session.byTrade = viaTrade
    AF.Comm:Send("AWARDED", { sid = session.sid, to = name, l = session.link, trade = viaTrade or nil }, "RAID")
    AF:Fire("LOOT_UPDATED", session.sid)
end

-- The loot window slot holding this session's item, if the corpse is open.
local function FindLootSlot(session)
    local fallback
    for slot = 1, GetNumLootItems() do
        if LootSlotHasItem(slot) and GetLootSlotLink(slot) == session.link and not pending[slot] then
            local source = GetLootSourceInfo(slot)
            if not session.source or source == session.source then return slot end
            fallback = fallback or slot
        end
    end
    return fallback
end

-- Returns "given" (master loot; recorded once it lands), "trade" (recorded, the
-- holder trades it), or nil plus a reason.
function Loot:Award(sid, name)
    local session = sessions[sid]
    if not session then return nil, "That session is gone." end
    if session.awarded then return nil, "Already awarded to " .. AF:ShortName(session.awarded) .. "." end
    if session.authority ~= AF.playerName then
        return nil, AF:ShortName(session.authority) .. " hands out this item. You can vote with the Vote button."
    end
    if session.test then
        session.awarded = name
        local response, classFile = session.responses[name] and session.responses[name].r, nil
        for _, fake in ipairs(session.fake) do
            if fake.name == name then response, classFile = fake.response, fake.classFile end
        end
        AddTestWin(name, classFile, session.link, response and Loot.RESPONSE_TEXT[response] or "no response", GetServerTime())
        AF:Printf("(test) %s -> %s. Nothing was sent or recorded.", session.link, AF:ShortName(name))
        AF:Fire("LOOT_UPDATED", sid)
        return "test"
    end
    if AF:HasMasterLoot() and AF:GetMasterLooter() == AF.playerName then
        local slot = FindLootSlot(session)
        if slot then
            for i = 1, 40 do
                local candidate = GetMasterLootCandidate(slot, i)
                if candidate and AF:SameName(candidate, name) then
                    pending[slot] = { session = session, name = name }
                    GiveMasterLoot(slot, i)
                    return "given"
                end
            end
            return nil, AF:ShortName(name) .. " can't receive this item (out of range, or not on the loot list)."
        end
    end
    Finalize(session, name, true)
    return "trade"
end

-- Who holds a traded item, and whether it was delivered (from HOLD / TRADED).
function Loot:SetTradeState(sid, holder, delivered)
    local session = sessions[sid]
    if not session then return end
    session.holder = holder or session.holder
    session.delivered = session.delivered or delivered
    AF:Fire("LOOT_UPDATED", sid)
end

function Loot:ClearAwarded()
    for i = #order, 1, -1 do
        local sid = order[i]
        if sessions[sid].awarded then
            sessions[sid] = nil
            table.remove(order, i)
        end
    end
    AF:Fire("LOOT_UPDATED")
end

AF:RegisterEvent("LOOT_OPENED", function()
    if not IsInRaid() or not AF:HasMasterLoot() or AF:GetMasterLooter() ~= AF.playerName then return end
    local threshold = GetLootThreshold()
    local links, sources, dupes = {}, {}, {}
    for slot = 1, GetNumLootItems() do
        if LootSlotHasItem(slot) then
            local link = GetLootSlotLink(slot)
            local quality = select(5, GetLootSlotInfo(slot))
            if link and not AF:IsSecret(link) and quality and quality >= threshold then
                local source = GetLootSourceInfo(slot) or "?"
                local base = source .. link
                dupes[base] = (dupes[base] or 0) + 1
                local key = base .. "#" .. dupes[base]
                if not seen[key] then
                    seen[key] = true
                    table.insert(links, link)
                    table.insert(sources, source)
                end
            end
        end
    end
    if #links > 0 then Loot:StartSessions(links, sources) end
end)

AF:RegisterEvent("LOOT_SLOT_CLEARED", function(_, slot)
    local p = pending[slot]
    if not p then return end
    pending[slot] = nil
    Finalize(p.session, p.name, false)
end)

AF:RegisterEvent("LOOT_CLOSED", function()
    for slot, p in pairs(pending) do
        AF:Printf("%s didn't reach %s (bags full?). Award it again.", p.session.link, AF:ShortName(p.name))
        pending[slot] = nil
    end
end)

-------------------------------------------------------------------------------
--  Raider side
-------------------------------------------------------------------------------
function Loot:Incoming() return incoming end

AF.Comm:On("ITEMS", function(sender, data)
    if type(data) ~= "table" or type(data.items) ~= "table" then return end
    if sender ~= AF:GetLootAuthority() then return end   -- only the loot authority starts sessions
    local timeout = tonumber(data.timeout) or 60
    -- Officers keep their own copy of each item, to see the responses and vote.
    local council = sender ~= AF.playerName and AF.Config:IsOfficer(AF.playerName)
    local first
    for _, item in ipairs(data.items) do
        if type(item.sid) == "string" and type(item.link) == "string" then
            table.insert(incoming, { sid = item.sid, link = item.link, from = sender, expires = GetTime() + timeout })
            if council and not sessions[item.sid] then
                sessions[item.sid] = { sid = item.sid, link = item.link, responses = {}, votes = {},
                    authority = sender, mirror = true }
                table.insert(order, item.sid)
                first = first or item.sid
            end
        end
    end
    if first then AF.UI:ShowLootWindow(first) end
    AF.UI:ShowPopup()
end)

function Loot:Respond(entry, response, note)
    note = CleanNote(note)
    if entry.test then
        local session = sessions[entry.sid]
        if session then
            session.responses[AF.playerName] = { r = response, eq = Loot.EquippedFor(entry.link), note = note,
                wish = AF.Wishlist:MyRank(entry.link) }
        end
        AF:Fire("LOOT_UPDATED", entry.sid)
    else
        local payload = { sid = entry.sid, r = response, eq = Loot.EquippedFor(entry.link), n = note,
            w = AF.Wishlist:MyRank(entry.link) }
        for _, name in ipairs(self:Council(entry.from)) do
            AF.Comm:Send("RESP", payload, "WHISPER", name)
        end
    end
    for i, e in ipairs(incoming) do
        if e == entry then table.remove(incoming, i) break end
    end
    AF.UI:ShowPopup()
end

function Loot:DropExpired()
    local now = GetTime()
    for i = #incoming, 1, -1 do
        if incoming[i].expires < now then table.remove(incoming, i) end
    end
end

AF.Comm:On("AWARDED", function(sender, data)
    if type(data) ~= "table" then return end
    for i = #incoming, 1, -1 do
        if incoming[i].sid == data.sid and incoming[i].from == sender then table.remove(incoming, i) end
    end
    local copy = sessions[data.sid]
    if copy and copy.mirror and copy.authority == sender and type(data.to) == "string" then
        copy.awarded, copy.byTrade = data.to, data.trade and true or nil
        AF:Fire("LOOT_UPDATED", data.sid)
    end
    AF.UI:ShowPopup()
end)
