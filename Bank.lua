-------------------------------------------------------------------------------
--  Bank.lua -- guild bank deposits, from two sources:
--
--  Your own client: while the guild bank is open it counts the gold you deposit
--  and withdraw, and how many wanted items leave or enter your bags. When you
--  close the bank it reports the net to the guild (DEP). Officers record it
--  under "dep:<you>#<report>", so every officer makes the same event, and
--  confirm it (DEPACK). Reports wait in saved data until confirmed, and are
--  resent on login and every few minutes.
--
--  Officers' clients: opening the guild bank reads its money and item logs and
--  records entries the ledger doesn't have yet (matched by player, amount and
--  time; the log only gives times to the hour). This covers players without
--  the addon.
--
--  Both sources can see the same deposit; the ledger counts the larger of the
--  two per player, week and item (Ledger:DepositGold), never both.
-------------------------------------------------------------------------------
local _, AF = ...
local Bank = AF:NewModule("Bank")

local CONFIRM_WINDOW = 3        -- seconds to see our money change after a deposit/withdraw call
local MATCH_WINDOW = 3 * 3600   -- log entries this close in time to a recorded one are the same
local RESEND_INTERVAL = 300
local MONEY_LOG_TAB = (MAX_GUILDBANK_TABS or 8) + 1

local bankOpen = false
local session                   -- { gold, start = { itemID = count }, slotsChanged }
local pendingGold               -- a deposit/withdraw call waiting for our money to change

-------------------------------------------------------------------------------
--  Describing deposits
-------------------------------------------------------------------------------
local function ItemLink(itemID)
    return select(2, C_Item.GetItemInfo(itemID)) or ("item " .. itemID)
end

function Bank.Describe(d)
    if d.a then
        local gold = d.a / 10000
        return ("%s%sg"):format(gold >= 0 and "+" or "", gold % 1 == 0 and gold or ("%.2f"):format(gold))
    end
    return ("%s%d x %s"):format(d.q >= 0 and "+" or "", d.q, d.l or ItemLink(d.i))
end

-------------------------------------------------------------------------------
--  Your own deposits
-------------------------------------------------------------------------------
local function WantedCounts()
    local counts = {}
    for itemID in pairs(AF.Config:Get("wanted")) do counts[itemID] = C_Item.GetItemCount(itemID) end
    return counts
end

local function Pending()
    AF.db.pendingDeposits = AF.db.pendingDeposits or {}
    return AF.db.pendingDeposits
end

function Bank:SendPending()
    local mine = {}
    for _, d in ipairs(Pending()) do
        if d.n == AF.playerName then table.insert(mine, d) end
    end
    if #mine > 0 then AF.Comm:Send("DEP", mine, "GUILD") end
end

local reportCounter = 0

local function Report(d)
    reportCounter = (reportCounter + 1) % 100
    d.n = AF.playerName
    d.t = GetServerTime()
    d.s = d.t * 100 + reportCounter      -- unique per character, even after a reinstall
    table.insert(Pending(), d)
    AF:Printf("Guild bank: reported %s.", Bank.Describe(d))
end

local function OnOpen()
    if bankOpen then return end
    bankOpen = true
    session = { gold = 0, start = WantedCounts(), slotsChanged = false }
    if AF.Ledger:CanRecord() then Bank:ReadLogs() end
end

local function OnClose()
    if not bankOpen then return end
    bankOpen = false
    local s = session
    session, pendingGold = nil, nil
    if not s then return end
    local reported = false
    if s.gold ~= 0 then
        Report({ a = s.gold })
        reported = true
    end
    if s.slotsChanged then
        local now = WantedCounts()
        for itemID, before in pairs(s.start) do
            local deposited = before - (now[itemID] or 0)
            if deposited ~= 0 then
                Report({ i = itemID, q = deposited, l = select(2, C_Item.GetItemInfo(itemID)) })
                reported = true
            end
        end
    end
    if reported then Bank:SendPending() end
end

local function WatchMoney(fnName, sign)
    if type(_G[fnName]) ~= "function" then return end
    hooksecurefunc(fnName, function(copper)
        if session and type(copper) == "number" and copper > 0 then
            pendingGold = { amount = copper, sign = sign, money = GetMoney(), at = GetTime() }
        end
    end)
end
WatchMoney("DepositGuildBankMoney", 1)
WatchMoney("WithdrawGuildBankMoney", -1)

-- The call only asks; count it once our own money actually moved by that much.
AF:RegisterEvent("PLAYER_MONEY", function()
    local p = pendingGold
    if not p or not session then return end
    if GetTime() - p.at > CONFIRM_WINDOW then pendingGold = nil return end
    if GetMoney() - p.money == -p.sign * p.amount then
        session.gold = session.gold + p.sign * p.amount
        pendingGold = nil
    end
end)

AF:RegisterEvent("GUILDBANKBAGSLOTS_CHANGED", function()
    if session then session.slotsChanged = true end
end)

-- The guild bank window, on clients with the interaction manager and without.
local GUILD_BANKER = Enum.PlayerInteractionType and Enum.PlayerInteractionType.GuildBanker
AF:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", function(_, kind)
    if GUILD_BANKER and kind == GUILD_BANKER then OnOpen() end
end)
AF:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", function(_, kind)
    if GUILD_BANKER and kind == GUILD_BANKER then OnClose() end
end)
AF:RegisterEvent("GUILDBANKFRAME_OPENED", OnOpen)
AF:RegisterEvent("GUILDBANKFRAME_CLOSED", OnClose)

-------------------------------------------------------------------------------
--  Officers: recording reports
-------------------------------------------------------------------------------
local function ValidReport(d, sender)
    if type(d) ~= "table" or d.n ~= sender or type(d.s) ~= "number" or type(d.t) ~= "number" then return false end
    if d.a ~= nil then return type(d.a) == "number" and d.a ~= 0 end
    return type(d.i) == "number" and type(d.q) == "number" and d.q ~= 0
end

AF.Comm:On("DEP", function(sender, list)
    if type(list) ~= "table" or not AF.Ledger:CanRecord() then return end
    local acks = {}
    for _, d in ipairs(list) do
        if ValidReport(d, sender) then
            AF.Ledger:RecordDeposit({ n = sender, src = "self", t = d.t, a = d.a, i = d.i, q = d.q,
                l = type(d.l) == "string" and d.l or nil }, "dep:" .. sender, d.s)
            table.insert(acks, d.s)
        end
    end
    if #acks > 0 then AF.Comm:Send("DEPACK", acks, "WHISPER", sender) end
end)

AF.Comm:On("DEPACK", function(sender, acks)
    if type(acks) ~= "table" or not AF.Config:IsOfficer(sender) then return end
    local done = {}
    for _, s in ipairs(acks) do done[s] = true end
    local pending = Pending()
    for i = #pending, 1, -1 do
        if pending[i].n == AF.playerName and done[pending[i].s] then table.remove(pending, i) end
    end
end)

-------------------------------------------------------------------------------
--  Officers: reading the bank logs
-------------------------------------------------------------------------------
local function SecondsAgo(years, months, days, hours)
    return ((((years or 0) * 12 + (months or 0)) * 30 + (days or 0)) * 24 + (hours or 0)) * 3600
end

function Bank:ReadLogs()
    if not QueryGuildBankLog then return end
    QueryGuildBankLog(MONEY_LOG_TAB)
    for tab = 1, (GetNumGuildBankTabs and GetNumGuildBankTabs() or 0) do QueryGuildBankLog(tab) end
end

local function LogEntries()
    local now = GetServerTime()
    local entries = {}
    local function Add(entry, kind, name, ...)
        local sign = (kind == "deposit" and 1) or (kind == "withdraw" and -1)
        name = AF:FullName(name)
        if not sign or not name then return end
        entry.n = name
        entry.t = now - SecondsAgo(...) - 1800     -- the log rounds to the hour; take the middle
        if entry.a then entry.a = entry.a * sign else entry.q = entry.q * sign end
        table.insert(entries, entry)
    end
    if GetNumGuildBankMoneyTransactions then
        for i = 1, GetNumGuildBankMoneyTransactions() do
            local kind, name, amount, years, months, days, hours = GetGuildBankMoneyTransaction(i)
            if type(amount) == "number" and amount > 0 then
                Add({ a = amount }, kind, name, years, months, days, hours)
            end
        end
    end
    if GetNumGuildBankTransactions then
        local wanted = AF.Config:Get("wanted")
        for tab = 1, (GetNumGuildBankTabs and GetNumGuildBankTabs() or 0) do
            for i = 1, GetNumGuildBankTransactions(tab) do
                local kind, name, link, count, _, _, years, months, days, hours = GetGuildBankTransaction(tab, i)
                local itemID = link and C_Item.GetItemInfoInstant(link)
                if itemID and wanted[itemID] and type(count) == "number" and count > 0 then
                    Add({ i = itemID, q = count, l = link }, kind, name, years, months, days, hours)
                end
            end
        end
    end
    return entries
end

-- Records log entries the ledger doesn't have. Each recorded log event can
-- match one entry per read, so two identical deposits stay two.
function Bank:ProcessLogs()
    if not AF.Ledger:CanRecord() then return end
    local added = 0
    local used = {}
    local known = {}
    for _, entry in ipairs(LogEntries()) do
        known[entry.n] = known[entry.n] or AF.Ledger:LogDeposits(entry.n)
        local match
        for _, e in ipairs(known[entry.n]) do
            if not used[e.id] and e.a == entry.a and e.i == entry.i and e.q == entry.q
                and math.abs(e.t - entry.t) <= MATCH_WINDOW then
                match = e
                break
            end
        end
        if match then
            used[match.id] = true
        else
            local e = AF.Ledger:RecordDeposit({ n = entry.n, src = "log", t = entry.t, a = entry.a,
                i = entry.i, q = entry.q, l = entry.l })
            if e then
                used[e.id] = true
                table.insert(known[entry.n], e)
                added = added + 1
            end
        end
    end
    if added > 0 then AF:Printf("Guild bank log: recorded %d new entries.", added) end
end

-- The logs arrive one tab at a time; process once they've stopped arriving.
local logTimer
AF:RegisterEvent("GUILDBANKLOG_UPDATE", function()
    if not bankOpen or not AF.Ledger:CanRecord() then return end
    if logTimer then logTimer:Cancel() end
    logTimer = C_Timer.NewTimer(1.5, function()
        logTimer = nil
        Bank:ProcessLogs()
    end)
end)

-------------------------------------------------------------------------------
--  Startup
-------------------------------------------------------------------------------
function Bank:Enable()
    C_Timer.After(30, function() Bank:SendPending() end)
    C_Timer.NewTicker(RESEND_INTERVAL, function() Bank:SendPending() end)
end

-- Which guild bank functions this client has (for /af debug).
function Bank.ApiReport()
    local names = { "DepositGuildBankMoney", "WithdrawGuildBankMoney", "QueryGuildBankLog",
        "GetNumGuildBankMoneyTransactions", "GetGuildBankMoneyTransaction", "GetNumGuildBankTransactions",
        "GetGuildBankTransaction", "GetNumGuildBankTabs" }
    local missing = {}
    for _, name in ipairs(names) do
        if type(_G[name]) ~= "function" then table.insert(missing, name) end
    end
    return #missing == 0 and "all present" or ("missing: " .. table.concat(missing, ", ")),
        GUILD_BANKER ~= nil, #Pending()
end
