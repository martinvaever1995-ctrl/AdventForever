-------------------------------------------------------------------------------
--  Core.lua -- namespace, event and message dispatch, saved data, permissions,
--  the audit log and slash commands. Every other module hangs off AF.
-------------------------------------------------------------------------------
local ADDON_NAME, AF = ...
_G.AdventForever = AF

AF.VERSION = 20003          -- major * 10000 + minor * 100 + patch; bump with ## Version
AF.VERSION_STRING = "2.0.3"
AF.PREFIX = "AdvForever"    -- addon message prefix (max 16 chars)
AF.PREFIX_BULK = "AdvForeverBulk"   -- the slow lane for large data (Comm.lua)

-------------------------------------------------------------------------------
--  Events and internal messages
-------------------------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
local eventHandlers, messageHandlers = {}, {}

local function SafeCall(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then geterrorhandler()(err) end
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
    for _, fn in ipairs(eventHandlers[event]) do SafeCall(fn, event, ...) end
end)

-- Returns false (and does nothing) for events this client doesn't have.
function AF:RegisterEvent(event, fn)
    if not eventHandlers[event] then
        if not pcall(eventFrame.RegisterEvent, eventFrame, event) then return false end
        eventHandlers[event] = {}
    end
    table.insert(eventHandlers[event], fn)
    return true
end

-- Internal messages between modules (e.g. "STANDINGS_UPDATED").
function AF:On(message, fn)
    messageHandlers[message] = messageHandlers[message] or {}
    table.insert(messageHandlers[message], fn)
end

function AF:Fire(message, ...)
    for _, fn in ipairs(messageHandlers[message] or {}) do SafeCall(fn, ...) end
end

-------------------------------------------------------------------------------
--  Output
-------------------------------------------------------------------------------
function AF:Printf(fmt, ...)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99AdventForever|r: " .. fmt:format(...))
end

function AF:Print(text) self:Printf("%s", tostring(text)) end

-------------------------------------------------------------------------------
--  Secret values (Midnight-style restrictions on the Forever client): anything
--  the game hands us during an encounter may be unreadable.
-------------------------------------------------------------------------------
function AF:IsSecret(v)
    return issecretvalue ~= nil and issecretvalue(v) or false
end

-- True while the game is holding back addon actions (combat / encounter lockdown).
function AF:IsRestricted()
    if C_RestrictedActions and C_RestrictedActions.IsAddOnRestrictionActive and Enum.AddOnRestrictionType then
        local ok, active = pcall(C_RestrictedActions.IsAddOnRestrictionActive, Enum.AddOnRestrictionType.Combat)
        if ok and active then return true end
    end
    return InCombatLockdown()
end

function AF:IsChatLocked()
    return C_ChatInfo and C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown() or false
end

-- Runs fn now, or as soon as restrictions lift (polled; cheap and survives missed events).
function AF:WhenUnrestricted(fn)
    if not self:IsRestricted() then return fn() end
    local ticker
    ticker = C_Timer.NewTicker(1, function()
        if not AF:IsRestricted() then
            ticker:Cancel()
            SafeCall(fn)
        end
    end)
end

-------------------------------------------------------------------------------
--  Names. WoW Forever characters have a surname, and the game spells names
--  differently per source:
--    guild roster / addon message senders: "First Surname", "First-Surname",
--      sometimes with "-Realm" after it
--    UnitFullName(unit): first, surname as two values
--    raid roster: can be the first name alone (so we read units instead)
--  Every character gets one key, "First Surname" (own realm stripped, the first
--  dash read as the separator). That is also what whispers are addressed to.
-------------------------------------------------------------------------------
local DASH = 45

-- Our realm without spaces or dashes. GetNormalizedRealmName can be nil early in
-- the login, so fall back to normalizing GetRealmName ourselves.
local function Realm()
    local realm = GetNormalizedRealmName()
    if realm and realm ~= "" then return realm end
    realm = GetRealmName()
    return realm and realm ~= "" and (realm:gsub("[%s%-]", "")) or nil
end

local function Readable(v)
    return type(v) == "string" and v ~= "" and not AF:IsSecret(v)
end

local function StripRealm(name)
    local realm = Realm()
    if not realm then return name end
    local n, r = #name, #realm
    if n > r + 1 and name:byte(n - r) == DASH and name:sub(n - r + 1) == realm then
        return name:sub(1, n - r - 1)
    end
    return name
end

-- The key for a name from any text source.
function AF:FullName(name)
    if not Readable(name) then return nil end
    return (StripRealm(name):gsub("%-", " ", 1))
end

-- The key for a unit.
function AF:UnitFullName(unit)
    local first, second = UnitFullName(unit)
    if not Readable(first) or self:IsSecret(second) then return nil end
    if Readable(second) and second ~= Realm() then return first .. " " .. second end
    return first
end

-- Keys are already display names ("First Surname").
function AF:ShortName(name)
    return name or "?"
end

-- Whether two names are the same character, allowing one of them to be the
-- first name alone (some raid APIs on Forever give only that).
function AF:SameName(a, b)
    a, b = self:FullName(a), self:FullName(b)
    if not a or not b then return false end
    if a == b then return true end
    local firstA, firstB = a:match("^[^ ]+"), b:match("^[^ ]+")
    return firstA == firstB and (a == firstA or b == firstB)
end

-- Raid/party unit token for a full name, if they are in our group.
function AF:GroupUnit(fullName)
    if self:UnitFullName("player") == fullName then return "player" end
    local prefix = IsInRaid() and "raid" or "party"
    for i = 1, GetNumGroupMembers() do
        local unit = prefix .. i
        if self:UnitFullName(unit) == fullName then return unit end
    end
end

-- Full names of everyone in the raid (or party), including us.
function AF:GroupMembers()
    local out = {}
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            local name = self:UnitFullName("raid" .. i)
            if name then table.insert(out, name) end
        end
    else
        table.insert(out, self.playerName)
        for i = 1, GetNumSubgroupMembers() do
            local name = self:UnitFullName("party" .. i)
            if name then table.insert(out, name) end
        end
    end
    return out
end

-------------------------------------------------------------------------------
--  Permissions and loot authority
-------------------------------------------------------------------------------
function AF:IsGM()
    return IsInGuild() and IsGuildLeader() and true or false
end

function AF:RequestRoster()
    if C_GuildInfo and C_GuildInfo.GuildRoster then C_GuildInfo.GuildRoster()
    elseif GuildRoster then GuildRoster() end
end

-- The master looter's full name, or nil when master loot isn't on (or doesn't exist).
function AF:GetMasterLooter()
    local method, partyML, raidML
    if C_PartyInfo and C_PartyInfo.GetLootMethod then
        method, partyML, raidML = C_PartyInfo.GetLootMethod()
    elseif GetLootMethod then
        method, partyML, raidML = GetLootMethod()
    else
        return nil
    end
    local isMaster = method == "master"
        or (Enum.LootMethod and Enum.LootMethod.Masterlooter ~= nil and method == Enum.LootMethod.Masterlooter)
    if not isMaster then return nil end
    if raidML then return self:UnitFullName("raid" .. raidML) end
    if partyML == 0 then return self.playerName end
    if partyML then return self:UnitFullName("party" .. partyML) end
end

function AF:HasMasterLoot()
    return GiveMasterLoot ~= nil and self:GetMasterLooter() ~= nil
end

-- Who runs loot and attendance for this group: the master looter when master loot
-- is on, otherwise the group leader.
function AF:GetLootAuthority()
    local ml = self:GetMasterLooter()
    if ml then return ml end
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            if UnitIsGroupLeader("raid" .. i) then return self:UnitFullName("raid" .. i) end
        end
    elseif IsInGroup() then
        if UnitIsGroupLeader("player") then return self.playerName end
        for i = 1, GetNumSubgroupMembers() do
            if UnitIsGroupLeader("party" .. i) then return self:UnitFullName("party" .. i) end
        end
    end
end

function AF:IsLootAuthority()
    return self:GetLootAuthority() == self.playerName
end

-------------------------------------------------------------------------------
--  Startup
-------------------------------------------------------------------------------
AF.modules = {}

function AF:NewModule(name)
    local module = {}
    self[name] = module
    table.insert(self.modules, module)
    return module
end

AF:RegisterEvent("ADDON_LOADED", function(_, name)
    if name ~= ADDON_NAME then return end
    AdventForeverDB = AdventForeverDB or {}
    local db = AdventForeverDB
    db.log, db.breakdown, db.won, db.bossAwards, db.lastDecay = nil, nil, nil, nil, nil   -- replaced by the ledger
    db.bench = db.bench or {}
    AF.db = db
    for _, module in ipairs(AF.modules) do
        if module.Init then SafeCall(module.Init, module) end
    end
end)

AF:RegisterEvent("PLAYER_LOGIN", function()
    AF.playerName = AF:UnitFullName("player")
    for _, module in ipairs(AF.modules) do
        if module.Enable then SafeCall(module.Enable, module) end
    end
end)

-- The realm can still be missing at PLAYER_LOGIN; by now the game knows it.
AF:RegisterEvent("PLAYER_ENTERING_WORLD", function()
    local name = AF:UnitFullName("player")
    if name and name ~= AF.playerName then
        AF.playerName = name
        AF:RequestRoster()
    end
end)

-- What the addon thinks of you; for when officer checks or names look wrong.
function AF:Debug()
    local _, rankName, rankIndex = GetGuildInfo("player")
    local member = self.Standings:All()[self.playerName]
    local count = 0
    for _ in pairs(self.Standings:All()) do count = count + 1 end
    self:Printf("You: %s | realm: %s / %s", tostring(self.playerName), tostring(GetNormalizedRealmName()), tostring(GetRealmName()))
    self:Printf("Guild rank: %s (index %s) | GM: %s | officer ranks 0-%d",
        tostring(rankName), tostring(rankIndex), tostring(self:IsGM()), self.Config:Get("officerRank"))
    local guildRaid, canRoll, rollLines = self.GuildLoot.Status()
    self:Printf("Guild loot: guild raid now: %s | can roll by addon: %s | roll lines understood: %d of 3",
        guildRaid and "yes" or "no", canRoll and "yes" or "NO", rollLines)
    local recruitRole, channelState, canJoin, canInvite = self.Recruit.Status()
    self:Printf("Recruiting: role %s | channel %s | can join channels: %s | guild invite function: %s",
        recruitRole, channelState, canJoin and "yes" or "NO", canInvite and "yes" or "NO")
    local h = self.Honor.ApiReport()
    self:Printf("Honor: this week %d (from %s) | weekly stats: %s | honor currency: %s | inspect honor: %s (event: %s)",
        h.honor, h.source, h.weeklyStats and "yes" or "no", tostring(h.currency),
        h.inspect and "YES" or "no", tostring(h.inspectEvent))
    local craftApi, craftWindow, myRecipes, crafters = self.Professions.ApiReport()
    self:Printf("Professions: recipe API %s | enchanting window API: %s | your recipes: %d | characters known: %d",
        craftApi, craftWindow and "yes" or "no", myRecipes, crafters)
    local bankApi, interaction, pendingDeposits = self.Bank.ApiReport()
    self:Printf("Guild bank API: %s | bank window event: %s | your unconfirmed deposit reports: %d",
        bankApi, interaction and "interaction manager" or "GUILDBANKFRAME", pendingDeposits)
    self:Printf("Roster: %d members | you found in roster: %s | officer: %s",
        count, member and ("yes, rank " .. member.rankIndex) or "NO", tostring(self.Ledger:CanRecord()))
    if not member then
        local sample = next(self.Standings:All())
        self:Printf("Example roster name: %s", tostring(sample))
    end
end

-------------------------------------------------------------------------------
--  Slash commands
-------------------------------------------------------------------------------
local HELP = {
    "/af - main window (Effort, Me, Rules, Loot, Log, Bank and Options tabs)",
    "/af history - who won what, by item or by player (Loot tab, officers)",
    "/af trades - items you have to trade to a winner, and items coming to you",
    "/af nudge - show the login summary again (turn it off in the Me tab)",
    "/af recruit - guildless players who run AdventForever, with an invite button (ranks that can invite)",
    "/af main - make this character your main (your other characters on this account become its alts)",
    "/af link <alt> <main>, /af unlink <name> - link characters by hand, e.g. across accounts (officers)",
    "/af me - your own effort, split by category, and what's left this week",
    "/af rules - how effort is scored, with the guild's current numbers",
    "/af loot - loot window (master looter / raid leader)",
    "/af item <shift-click item> - start a loot session for an item by hand",
    "/af adjust <name> <raid|bank|honor> <+/-points> [reason] - correct this week's points in a category (officers)",
    "/af log - ledger events (Log tab, officers)",
    "/af bank - guild bank rules and the wanted list (Bank tab)",
    "/af invite - raid invites: everyone online at chosen ranks / minimum effort, and guildies who whisper a keyword",
    "/af minimap - show or hide the minimap button (left-click opens, right-click for a menu, drag to move)",
    "/af attune - who in the guild is attuned to which raid (officers add or remove attunements there)",
    "/af crafters [item] - who in the guild can craft something; without a search, everyone's professions",
    "/af wish [shift-click item] - your wishlist (up to 10 items, ranked; only officers see it), or add an item to it",
    "/af bench add|remove <name>, /af bench list|clear - players on your bench get credit for guild kills you record (officers)",
    "/af kill <boss> - record a guild kill for your group by hand, if the game hid it (officers)",
    "/af final - mark (or unmark) the dungeon boss you just killed as the dungeon's final boss (officers)",
    "/af test [shift-click item] - try the loot popup and loot window alone (nothing is sent)",
    "/af versions (or /af check) - who in your group has the addon and which version, with durability, flasks / elixirs and range",
    "/af options - effort rules (officers edit, everyone can view); /af config prints them",
    "/af export, /af import - copy the ledger out as text / merge a copy back in (officers)",
}

-- Finds a guild member's full name from what the user typed ("bob" -> "Bob-Realm").
-- Typing the first name is enough when only one guild member has it.
-- Returns the key, or nil plus a message.
function AF:ResolveName(input)
    local wanted = self:FullName(input)
    if not wanted then return nil, "Type a name." end
    wanted = wanted:lower()
    local matches = {}
    for key in pairs(self.Standings:All()) do
        if key:lower() == wanted then return key end
        if key:lower():match("^[^ ]+") == wanted then table.insert(matches, key) end
    end
    if #matches == 1 then return matches[1] end
    if #matches > 1 then
        table.sort(matches)
        return nil, ("More than one %s: %s. Type it as First-Surname."):format(input, table.concat(matches, ", "))
    end
    return nil, input .. " is not in the guild."
end

local function NeedOfficer()
    if AF.Ledger:CanRecord() then return true end
    AF:Print("Only officers can do that (ranks set in /af options).")
    return false
end

local commands = {}

commands.help = function()
    for _, line in ipairs(HELP) do AF:Print(line) end
end

commands.loot = function() AF.UI:ToggleLootWindow() end

commands.item = function(args)
    local links = {}
    for link in args:gmatch("|c[^|]*|Hitem:.-|h|r") do table.insert(links, link) end
    if #links == 0 then return AF:Print("Usage: /af item <shift-click one or more items>") end
    AF.Loot:StartSessions(links)
end

commands.adjust = function(args)
    if not NeedOfficer() then return end
    local who, category, points, reason = args:match("^(%S+)%s+(%a+)%s+([%+%-]?%d+)%s*(.*)$")
    category = category and category:lower()
    if not who or not AF.Standings.CATEGORY_TEXT[category] then
        return AF:Print("Usage: /af adjust <name> <raid|bank|honor> <+/- points this week> [reason]  (0 removes the correction)")
    end
    local name, err = AF:ResolveName(who)
    if not name then return AF:Print(err) end
    name = AF.Standings:MainOf(name)     -- corrections belong to the player, i.e. their main
    local cap = AF.Config:Get(category .. "Max")
    points = math.max(-cap, math.min(cap, tonumber(points)))
    if AF.Ledger:SetCategory(name, category, points, reason ~= "" and reason or "manual") then
        local b = AF.Ledger:Breakdown(AF.Standings.CurrentWeek(), name) or {}
        AF:Printf("%s: %s correction %+d this week, %s now %d.", AF:ShortName(name), category, points,
            category, b[category] or 0)
    end
end

commands.bench = function(args)
    local action, who = args:match("^(%S*)%s*(.-)$")
    action = action:lower()
    local bench = AF.db.bench
    if action == "add" or action == "remove" then
        local name, err = AF:ResolveName(who)
        if not name then return AF:Print(err) end
        bench[name] = action == "add" or nil
        AF:Printf("%s %s the bench.", AF:ShortName(name), action == "add" and "added to" or "removed from")
    elseif action == "clear" then
        wipe(bench)
        AF:Print("Bench cleared.")
    else
        local names = {}
        for name in pairs(bench) do table.insert(names, AF:ShortName(name)) end
        table.sort(names)
        AF:Printf("Bench (%d): %s", #names, #names > 0 and table.concat(names, ", ") or "empty")
    end
end

commands.log = function() AF.UI:ShowLog() end
commands.bank = function() AF.UI:ShowBank() end
commands.me = function() AF.UI:ShowMe() end
commands.history = function() AF.UI:ShowLootHistory() end

commands.main = function() AF.Alts:SetMain() end
commands.recruit = function() AF.UI:ShowRecruit() end
commands.trades = function() AF.UI:ToggleTrades() end
commands.nudge = function()
    if not AF.UI:ShowNudge() then AF:Print("No numbers yet: wait until an officer is online (or the ledger has synced).") end
end

commands.link = function(args)
    local altInput, mainInput = args:match("^(%S+)%s+(%S+)$")
    if not altInput then return AF:Print("Usage: /af link <alt> <main>") end
    local alt, err = AF:ResolveName(altInput)
    if not alt then return AF:Print(err) end
    local main, err2 = AF:ResolveName(mainInput)
    if not main then return AF:Print(err2) end
    AF.Alts:OfficerLink(alt, main)
end

commands.unlink = function(args)
    local name, err = AF:ResolveName(args)
    if not name then return AF:Print(err) end
    AF.Alts:OfficerLink(name, name)
end
commands.rules = function() AF.UI:ShowRules() end
commands.attune = function() AF.UI:ShowAttunements() end
commands.invite = function() AF.UI:ShowInvites() end
commands.minimap = function() AF.UI:ToggleMinimap() end
commands.crafters = function(args)
    AF.UI:ShowCrafters()
    if args ~= "" then AF.UI:SearchCrafters(args) end
end
commands.wish = function(args)
    if args == "" then return AF.UI:ShowWishlist() end
    local rank, err = AF.Wishlist:Add(args)
    if not rank then return AF:Print(err) end
    AF:Printf("Added to your wishlist at #%d.", rank)
end
commands.kill = function(args) AF.Attendance:Manual(args) end
commands.final = function() AF.Dungeons:ToggleFinal() end

commands.debug = function() AF:Debug() end

commands.test = function(args)
    AF.Loot:StartTest(args:match("|c[^|]*|Hitem:.-|h|r"))
end

commands.versions = function() AF.UI:ShowVersions() end
commands.check = commands.versions
commands.config = function() AF.Config:PrintConfig() end
commands.options = function() AF.UI:ToggleOptions() end

commands.export = function()
    if not NeedOfficer() then return end
    local text, count = AF.Ledger:Export()
    AF.UI:ShowTextWindow("Ledger export", ("%d events. Press Ctrl+A, Ctrl+C and save it somewhere outside the game."):format(count), text)
end

commands.import = function()
    if not NeedOfficer() then return end
    AF.UI:ShowTextWindow("Ledger import", "Paste an export (Ctrl+V), then click Import. Events you already have are skipped.", "",
        function(text)
            local added, err = AF.Ledger:Import(text)
            if not added then return AF:Print(err) end
            AF:Printf("Imported %d new events.", added)
        end)
end

SLASH_ADVENTFOREVER1 = "/af"
SLASH_ADVENTFOREVER2 = "/adventforever"
SlashCmdList.ADVENTFOREVER = function(input)
    local cmd, args = (input or ""):match("^%s*(%S*)%s*(.-)%s*$")
    cmd = cmd:lower()
    if cmd == "" then return AF.UI:ToggleStandings() end
    local fn = commands[cmd]
    if fn then fn(args) else commands.help() end
end
