-------------------------------------------------------------------------------
--  UI.lua -- the main window (Effort / Log / Options tabs), the loot window,
--  the raider's loot popup, the export/import window and the award dialog.
--  Look and widgets come from Theme.lua.
-------------------------------------------------------------------------------
local _, AF = ...
local UI = AF:NewModule("UI")
local Theme = AF.Theme
local C = Theme.C

local WEEK_LABELS = { "This week", "Last week", "2 weeks ago", "3 weeks ago" }
local ROLE_KEY = { "ms", "os", "pass" }
local SHORT_RESPONSE = { "Main", "Off", "Pass" }
local function MaxEffort() return AF.Standings.WEEKS * AF.Standings.WeekMax() end

-------------------------------------------------------------------------------
--  Helpers
-------------------------------------------------------------------------------
local function ClassColor(classFile)
    local c = classFile and RAID_CLASS_COLORS[classFile]
    if c then return c.r, c.g, c.b end
    return C.text[1], C.text[2], C.text[3]
end

local function ClassOf(name, member)
    if member and member.classFile then return member.classFile end
    local unit = AF:GroupUnit(name)
    return unit and select(2, UnitClass(unit))
end

-- "+8 ilvl" in green, "-4 ilvl" in red, from Loot.IlvlDiff.
function UI.DiffText(diff, emptySlot)
    if not diff then return "" end
    if emptySlot then return "|cff4fe0a6empty slot|r" end
    if diff > 0 then return ("|cff4fe0a6+%d ilvl|r"):format(diff) end
    if diff < 0 then return ("|cffff6b6b%d ilvl|r"):format(diff) end
    return "|cff8b8d92same ilvl|r"
end

local function WeekMax()
    local total = 0
    for _, category in ipairs(AF.Standings.CATEGORIES) do total = total + AF.Config:Get(category .. "Max") end
    return math.max(1, total)
end

-- The 4-week window in the tooltip, with the category split where the ledger has it.
local function AddEffortLines(name, weeks)
    local current = AF.Standings.CurrentWeek()
    for i = 1, AF.Standings.WEEKS do
        local detail = ""
        local b = AF.Ledger:Breakdown(current - i + 1, name)
        if b then
            local parts = {}
            for _, category in ipairs(AF.Standings.CATEGORIES) do
                if b[category] then
                    local part = ("%s %d"):format(AF.Standings.CATEGORY_TEXT[category], b[category])
                    if category == "raid" then
                        local here, total = AF.Ledger:RaidAttendance(current - i + 1, name)
                        if total > 0 then part = part .. (" (%d/%d kills)"):format(here, total) end
                    elseif category == "honor" then
                        local honor = AF.Ledger:WeekHonor(current - i + 1, name)
                        if honor then part = part .. (" (%s honor)"):format(BreakUpLargeNumbers(honor)) end
                    end
                    table.insert(parts, part)
                end
            end
            if #parts > 0 then detail = "  |cff8b8d92(" .. table.concat(parts, ", ") .. ")|r" end
        end
        GameTooltip:AddDoubleLine(WEEK_LABELS[i], weeks[i] .. detail, 0.8, 0.8, 0.8, 1, 1, 1)
    end
end

local function EffortTooltip(owner, name, member)
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    GameTooltip:AddLine(AF:ShortName(name), ClassColor(ClassOf(name, member)))
    local alts, main = AF.Standings:AltsOf(name)
    if main ~= name then
        GameTooltip:AddLine("Alt of " .. AF:ShortName(main) .. ", effort counted together", 0.6, 0.6, 0.62)
    elseif #alts > 0 then
        local names = {}
        for _, alt in ipairs(alts) do table.insert(names, AF:ShortName(alt)) end
        GameTooltip:AddLine("Alts: " .. table.concat(names, ", "), 0.6, 0.6, 0.62, true)
    end
    if member then
        AddEffortLines(name, member.weeks)
        local r, g, b = Theme.Accent()
        GameTooltip:AddDoubleLine("Effort (4 weeks)", member.effort, r, g, b, r, g, b)
    end
end

-------------------------------------------------------------------------------
--  Main window: tabs
-------------------------------------------------------------------------------
local main
local Effort, Me, Rules, LootTab, Log, BankTab, Options, RecruitTab = {}, {}, {}, {}, {}, {}, {}, {}

local SIDEBAR_W = 150
local CONTENT_W = 480

-- Sidebar pages: the page index (the panels' order below) with its label and
-- icon. Officer pages sit under their own heading and stay hidden for everyone else.
local NAV = {
    { page = 1, label = "Effort", icon = "effort" },
    { page = 2, label = "Me", icon = "me" },
    { page = 3, label = "Rules", icon = "rules" },
    { page = 6, label = "Bank", icon = "bank" },
    { page = 4, label = "Loot history", icon = "loot", officer = true },
    { page = 5, label = "Log", icon = "log", officer = true },
    { page = 8, label = "Recruit", icon = "recruit", officer = true },
    { page = 7, label = "Options", icon = "options", officer = true },
}

local function ShowPage(index)
    for i, panel in ipairs(main.panels) do panel:SetShown(i == index) end
    main.panels[index].page:Refresh()
end

local function CreateMain()
    main = Theme.Window("AdventForeverMain", "", SIDEBAR_W + CONTENT_W, 584)
    main.panels = {}
    for i, page in ipairs({ Effort, Me, Rules, LootTab, Log, BankTab, Options, RecruitTab }) do
        local panel = CreateFrame("Frame", nil, main)
        panel:SetPoint("TOPLEFT", SIDEBAR_W, -25)
        panel:SetPoint("BOTTOMRIGHT")
        panel.page = page
        page:Build(panel)
        panel:Hide()
        main.panels[i] = panel
    end
    main.nav = Theme.Sidebar(main, NAV, SIDEBAR_W, ShowPage, function() return AF.Ledger:CanRecord() end)
    main:SetScript("OnShow", function() main.nav:Select(main.nav.selected or 1) end)
end

-- Officer pages come and go with officer status (it's known once the roster loads).
local function RefreshNav()
    if not main then return end
    main.nav:Layout()
    local selected = main.nav.selected
    if selected and not main.nav.buttons[selected]:IsShown() and main:IsShown() then main.nav:Select(1) end
end

function UI:ShowMain(tab)
    if not main then CreateMain() end
    main:Show()
    main.nav:Select(tab or main.nav.selected or 1)
end

function UI:ToggleStandings()
    if main and main:IsShown() then main:Hide() else self:ShowMain(1) end
end

function UI:ToggleOptions() self:ShowMain(7) end
function UI:ShowBank() self:ShowMain(6) end
function UI:ShowLog() self:ShowMain(5) end
function UI:ShowLootHistory() self:ShowMain(4) end
function UI:ShowMe() self:ShowMain(2) end
function UI:ShowRules() self:ShowMain(3) end
function UI:ShowRecruit() self:ShowMain(8) end

local function Visible(page) return main and main:IsShown() and page.panel and page.panel:IsShown() end

-------------------------------------------------------------------------------
--  Effort tab
-------------------------------------------------------------------------------
local sortKey, sortDesc = "effort", true
local raidOnly, hideEmpty, showAlts = false, true, false

local function SortValue(m, key)
    if key == "name" then return AF:ShortName(m.name) end
    if key == "weeks" then return m.weeks[1] end
    return m.effort
end

function Effort:Build(panel)
    self.panel = panel
    local raid = Theme.Check(panel, "Raid only", raidOnly, function(v) raidOnly = v; self:Refresh() end)
    raid:SetPoint("TOPLEFT", 14, -12)
    local empty = Theme.Check(panel, "Hide 0 effort", hideEmpty, function(v) hideEmpty = v; self:Refresh() end)
    empty:SetPoint("LEFT", raid, "RIGHT", 80, 0)
    local alts = Theme.Check(panel, "Show alts", showAlts, function(v) showAlts = v; self:Refresh() end)
    alts:SetPoint("LEFT", empty, "RIGHT", 96, 0)
    self.status = Theme.Text(panel, 11, C.dim)
    self.status:SetPoint("TOPRIGHT", -14, -13)
    self.status:SetJustifyH("RIGHT")

    self.list = Theme.List(panel, {
        left = 14, top = -36, rows = 17, rowHeight = 22,
        emptyText = "Nobody to show yet.",
        columns = {
            { key = "name", label = "Name", width = 170 },
            { key = "weeks", label = "Weeks", width = 56, widget = function(row) return Theme.WeekBars(row, 12) end },
            { key = "effort", label = "Effort", width = 168, widget = function(row) return Theme.Bar(row, 160, 6) end },
            { key = "value", label = "", width = 58, justify = "RIGHT" },
        },
        onHeader = function(key)
            if key == "value" then key = "effort" end
            if sortKey == key then sortDesc = not sortDesc else sortKey, sortDesc = key, key ~= "name" end
            self:Refresh()
        end,
        render = function(row, m)
            row.cells.name:SetText(AF:ShortName(m.name) .. (m.main ~= m.name and "  |cff8b8d92alt|r" or ""))
            row.cells.name:SetTextColor(ClassColor(m.classFile))
            row.cells.weeks:SetWeeks(m.weeks, WeekMax())
            row.cells.effort:SetValue(m.effort / MaxEffort())
            row.cells.value:SetText(m.effort)
        end,
        onRowEnter = function(row, m)
            EffortTooltip(row, m.name, m)
            GameTooltip:Show()
        end,
    })
end

function Effort:Refresh()
    if not self.panel then return end
    local inGroup
    if raidOnly then
        inGroup = {}
        for _, name in ipairs(AF:GroupMembers()) do inGroup[name] = true end
    end
    local data = {}
    for name in pairs(AF.Standings:All()) do
        local m = AF.Standings:Get(name)
        local isAlt = m.main ~= name
        if (not raidOnly or inGroup[name]) and (not hideEmpty or m.effort > 0)
            and (showAlts or not isAlt or (raidOnly and inGroup[name])) then   -- alts in the raid always show
            table.insert(data, m)
        end
    end
    table.sort(data, function(a, b)
        local x, y = SortValue(a, sortKey), SortValue(b, sortKey)
        if x == y then return a.name < b.name end
        if sortDesc then return x > y end
        return x < y
    end)
    self.list:SetData(data)
    self.list:MarkSorted(sortKey)

    if AF.Ledger:CanRecord() then
        self.status:SetText(("%d shown  ·  ledger %d events"):format(#data, AF.Ledger:Count()))
    else
        local by, t = AF.Standings:SnapshotInfo()
        self.status:SetText(by and ("as of %s from %s"):format(date("%m-%d %H:%M", t), AF:ShortName(by))
            or "waiting for an officer")
    end
end

-------------------------------------------------------------------------------
--  Me tab: your own effort, split by category, and what's left this week
-------------------------------------------------------------------------------
local CATEGORY_ORDER = { "raid", "bank", "honor", "dungeon" }

local function AccentHex()
    local r, g, b = Theme.Accent()
    return ("|cff%02x%02x%02x"):format(r * 255, g * 255, b * 255)
end

local function UntilReset()
    local s = C_DateAndTime.GetSecondsUntilWeeklyReset()
    local days, hours = math.floor(s / 86400), math.floor(s % 86400 / 3600)
    if days > 0 then return ("%dd %dh"):format(days, hours) end
    return ("%dh %dm"):format(hours, math.floor(s % 3600 / 60))
end

local function Gold(value)
    return BreakUpLargeNumbers(math.floor(value)) .. "g"
end

-- One line on how a category is scored, with the guild's current numbers.
function UI.CategoryHelp(category)
    local get = function(key) return AF.Config:Get(key) end
    if category == "raid" then
        return ("Your share of the guild's boss kills this week (a guild kill needs %d%% guild members). Every kill you miss lowers it."):format(get("guildKillShare"))
    elseif category == "bank" then
        return ("1 point per %dg deposited; wanted items count at their listed value. Withdrawals count against it."):format(get("goldPerPoint"))
    elseif category == "honor" then
        return ("Scales with your honor this week; %s honor gives the full score."):format(BreakUpLargeNumbers(get("honorTarget")))
    end
    return ("%g points per dungeon finished (its last boss) with %d+ guild members in the group."):format(
        get("dungeonPerRun"), get("dungeonGuildMin"))
end

function Me:Build(panel)
    self.panel = panel
    -- Who you are: name, main/alt, and where the numbers come from.
    self.name = Theme.Text(panel, 14, nil, nil, true)
    self.name:SetPoint("TOPLEFT", 16, -14)
    self.chars = Theme.Text(panel, 11, C.dim)
    self.chars:SetPoint("LEFT", self.name, "RIGHT", 8, -1)
    self.chars:SetWidth(170)
    self.source = Theme.Text(panel, 11, C.dim)
    self.source:SetPoint("TOPRIGHT", -16, -16)
    self.source:SetJustifyH("RIGHT")
    self.mainButton = Theme.Button(panel, "Make this my main", 124, 20)
    self.mainButton:SetPoint("RIGHT", self.source, "LEFT", -10, 0)
    self.mainButton:SetScript("OnClick", function() AF.Alts:SetMain() end)

    -- The total, on its own card.
    local totalCard = Theme.Card(panel, 448, 72)
    totalCard:SetPoint("TOPLEFT", 16, -40)
    Theme.Label(totalCard, "Effort · last 4 weeks"):SetPoint("TOPLEFT", 12, -10)
    self.reset = Theme.Text(totalCard, 11, C.dim)
    self.reset:SetPoint("TOPRIGHT", -12, -10)
    self.reset:SetJustifyH("RIGHT")
    self.total = Theme.Text(totalCard, 24, C.bright, nil, true)
    self.total:SetPoint("TOPLEFT", 12, -24)
    Theme.Accented(self.total, 1, "text")
    self.totalOf = Theme.Text(totalCard, 12, C.dim)
    self.totalOf:SetPoint("BOTTOMLEFT", self.total, "BOTTOMRIGHT", 6, 3)
    self.totalBar = Theme.Bar(totalCard, 424, 6)
    self.totalBar:SetPoint("BOTTOMLEFT", 12, 12)

    -- This week, one card per category, two by two.
    self.rows = {}
    for i, category in ipairs(CATEGORY_ORDER) do
        local card = Theme.Card(panel, 220, 86)
        card:SetPoint("TOPLEFT", 16 + ((i - 1) % 2) * 228, -120 - math.floor((i - 1) / 2) * 94)
        local row = {}
        Theme.Label(card, AF.Standings.CATEGORY_TEXT[category]):SetPoint("TOPLEFT", 12, -10)
        row.value = Theme.Text(card, 20, C.bright, nil, true)
        row.value:SetPoint("TOPLEFT", 12, -24)
        row.cap = Theme.Text(card, 12, C.dim)
        row.cap:SetPoint("BOTTOMLEFT", row.value, "BOTTOMRIGHT", 5, 2)
        row.bar = Theme.Bar(card, 196, 5)
        row.bar:SetPoint("TOPLEFT", 12, -52)
        row.detail = Theme.Text(card, 11, C.dim)
        row.detail:SetPoint("TOPLEFT", 12, -64)
        row.detail:SetWidth(196)
        card:EnableMouse(true)
        card:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(AF.Standings.CATEGORY_TEXT[category], 1, 1, 1)
            GameTooltip:AddLine(UI.CategoryHelp(category), 0.8, 0.8, 0.8, true)
            GameTooltip:Show()
        end)
        card:SetScript("OnLeave", function() GameTooltip:Hide() end)
        self.rows[category] = row
    end

    -- The last 4 weeks, as a small table on a card.
    local historyCard = Theme.Card(panel, 448, 134)
    historyCard:SetPoint("TOPLEFT", 16, -310)
    Theme.Label(historyCard, "Last 4 weeks"):SetPoint("TOPLEFT", 12, -10)
    local columns = { { "Week", 110, "LEFT" }, { "Raids", 58 }, { "Bank", 58 }, { "Honor", 58 }, { "Dungeons", 70 }, { "Total", 70 } }
    self.table = {}
    for r = 0, 4 do
        local y = -30 - r * 20
        local cells, x = {}, 12
        for c, col in ipairs(columns) do
            local fs = r == 0 and Theme.Label(historyCard, col[1]) or Theme.Text(historyCard, 12)
            fs:SetPoint("TOPLEFT", x, y)
            fs:SetWidth(col[2])
            fs:SetJustifyH(col[3] or "RIGHT")
            cells[c] = fs
            x = x + col[2]
        end
        self.table[r] = cells
    end
    local line = Theme.Line(historyCard)
    line:SetPoint("TOPLEFT", 12, -44)
    line:SetSize(424, 1)

    self.note = Theme.Text(panel, 11, C.dim)
    self.note:SetPoint("TOPLEFT", 16, -456)
    self.note:SetWidth(448)
    self.note:SetWordWrap(true)

    -- Per player, not a guild rule: the summary shown at login.
    local nudge = Theme.Check(panel, "Show this summary when I log in", UI.NudgeEnabled(), function(on)
        AF.db.prefs = AF.db.prefs or {}
        AF.db.prefs.nudge = on
    end)
    nudge:SetPoint("BOTTOMLEFT", 16, 14)
end

function Me:Refresh()
    if not self.panel then return end
    local name = AF.playerName
    local member = AF.Standings:Get(name)
    self.name:SetText(AF:ShortName(name))
    self.name:SetTextColor(ClassColor(member and member.classFile))

    -- Main and alts: what the officers have, plus what this account picked.
    local alts, main = AF.Standings:AltsOf(name)
    local chosen = AF.Alts:ChosenMain()
    if main ~= name then
        self.chars:SetText("alt of " .. AF:ShortName(main))
    elseif #alts > 0 then
        self.chars:SetText(("main  ·  %d alt%s"):format(#alts, #alts == 1 and "" or "s"))
    else
        self.chars:SetText(chosen ~= name and ("alt of " .. AF:ShortName(chosen) .. " (not confirmed yet)") or "main")
    end
    self.mainButton:SetShown(chosen ~= name)
    if not member then
        self.total:SetText("-")
        self.totalBar:SetValue(0)
        self.note:SetText("You need to be in the guild to have effort.")
        return
    end

    if AF.Ledger:CanRecord() then
        self.source:SetText("from your ledger")
    else
        local by, t = AF.Standings:SnapshotInfo()
        self.source:SetText(by and ("as of %s from %s"):format(date("%m-%d %H:%M", t), AF:ShortName(by))
            or "waiting for an officer")
    end
    self.total:SetText(member.effort)
    self.totalOf:SetText(("/ %d effort over the last 4 weeks"):format(MaxEffort()))
    self.totalBar:SetValue(member.effort / MaxEffort())
    self.reset:SetText("resets in " .. UntilReset())

    local d = AF.Standings:Detail(name)
    local now, split = d.now, d.split[1]
    local myHonor = math.max(now.honor, (AF.Honor.Current()))   -- our own count may be ahead of the snapshot
    for _, category in ipairs(CATEGORY_ORDER) do
        local row = self.rows[category]
        local cap = AF.Config:Get(category .. "Max")
        local value = split[category]
        row.value:SetText(value)
        row.cap:SetText("/ " .. cap)
        row.bar:SetValue(cap > 0 and value / cap or 0)
        local full = value >= cap and cap > 0
        if category == "raid" then
            row.detail:SetText(now.total > 0 and ("%d of %d guild kills"):format(now.here, now.total) or "No guild kills yet")
        elseif category == "bank" then
            local rate = AF.Config:Get("goldPerPoint")
            local left = math.max(0, cap * rate - now.gold)
            row.detail:SetText(full and "Full this week" or (Gold(left) .. " more fills it"))
        elseif category == "honor" then
            local target = AF.Config:Get("honorTarget")
            row.detail:SetText(full and "Full this week"
                or ("%s of %s honor"):format(BreakUpLargeNumbers(myHonor), BreakUpLargeNumbers(target)))
        else
            local perRun = AF.Config:Get("dungeonPerRun")
            local runsLeft = perRun > 0 and math.ceil(math.max(0, cap - value) / perRun) or 0
            row.detail:SetText(full and "Full this week"
                or ("%d run%s  ·  %d more fill%s it"):format(now.runs, now.runs == 1 and "" or "s", runsLeft, runsLeft == 1 and "s" or ""))
        end
    end

    for i = 1, 4 do
        local cells, s = self.table[i], d.split[i]
        cells[1]:SetText(i == 1 and "This week" or WEEK_LABELS[i])
        cells[2]:SetText(s.raid)
        cells[3]:SetText(s.bank)
        cells[4]:SetText(s.honor)
        cells[5]:SetText(s.dungeon)
        cells[6]:SetText(member.weeks[i])
        cells[6]:SetTextColor(unpack(C.bright))
    end

    local notes = {}
    local deposits = 0
    for _, report in ipairs(AF.db.pendingDeposits or {}) do
        if report.n == name then deposits = deposits + 1 end
    end
    if deposits > 0 then table.insert(notes, ("%d guild bank report(s) are waiting for an officer to come online."):format(deposits)) end
    if myHonor > now.honor then
        table.insert(notes, ("Your client has counted %s honor; officers have %s so far. It's sent every few minutes."):format(
            BreakUpLargeNumbers(myHonor), BreakUpLargeNumbers(now.honor)))
    end
    if not AF.Ledger:CanRecord() then
        table.insert(notes, "Your numbers update when an officer is online. See the Rules tab for how each part is scored.")
    end
    self.note:SetText(table.concat(notes, "\n"))
end

-------------------------------------------------------------------------------
--  Rules tab: how effort is scored, with the guild's current numbers
-------------------------------------------------------------------------------
function Rules:Build(panel)
    self.panel = panel
    self.sections = {}
    local y = -14
    -- Each part of the rules on its own card.
    local function Section(key, height)
        local card = Theme.Card(panel, 448, height + 36)
        card:SetPoint("TOPLEFT", 16, y)
        local title = Theme.Text(card, 12, C.bright, nil, true)
        title:SetPoint("TOPLEFT", 12, -10)
        local body = Theme.Text(card, 11, C.text)
        body:SetPoint("TOPLEFT", 12, -28)
        body:SetWidth(424)
        body:SetWordWrap(true)
        body:SetJustifyV("TOP")
        self.sections[key] = { title = title, body = body }
        y = y - height - 36 - 8
    end
    Section("effort", 30)
    Section("raid", 30)
    Section("bank", 44)
    Section("honor", 30)
    Section("dungeon", 30)
    Section("loot", 30)
    self.footer = Theme.Text(panel, 11, C.dim)
    self.footer:SetPoint("BOTTOMLEFT", 16, 14)
end

function Rules:Refresh()
    if not self.panel then return end
    local a, r = AccentHex(), "|r"
    local function N(v) return a .. v .. r end
    local cfg = function(key) return AF.Config:Get(key) end
    local weekMax = AF.Standings.WeekMax()
    local wanted = 0
    for _ in pairs(cfg("wanted")) do wanted = wanted + 1 end
    local s = self.sections

    s.effort.title:SetText("How effort works")
    s.effort.body:SetText(("Each raid week you can score up to %s points. Your effort is the sum of the last 4 weeks, so at most %s. At the weekly reset the oldest week drops off."):format(
        N(weekMax), N(weekMax * 4)))

    s.raid.title:SetText(("Raids: up to %s"):format(N(cfg("raidMax"))))
    s.raid.body:SetText(("Your share of the guild's boss kills this week. A kill is a guild kill when at least %s of the raid are guild members. Players an officer puts on the bench count as present."):format(
        N(cfg("guildKillShare") .. "%")))

    s.bank.title:SetText(("Guild bank: up to %s"):format(N(cfg("bankMax"))))
    local goals = 0
    for _ in pairs(cfg("goals")) do goals = goals + 1 end
    s.bank.body:SetText(("%s point per %s deposited. Items on the wanted list count at their listed value (%s items, %s with a goal; see the Bank tab). Withdrawals count against it. Your own client reports your deposits when you close the bank."):format(
        N(1), N(cfg("goldPerPoint") .. "g"), N(wanted), N(goals)))

    s.honor.title:SetText(("Honor: up to %s"):format(N(cfg("honorMax"))))
    s.honor.body:SetText(("Scales with your honor this week; %s honor gives the full score. Your own client counts the honor you earn while the addon is running."):format(
        N(BreakUpLargeNumbers(cfg("honorTarget")))))

    s.dungeon.title:SetText(("Dungeons: up to %s"):format(N(cfg("dungeonMax"))))
    s.dungeon.body:SetText(("%s points for each dungeon you finish (its last boss) with at least %s guild members in the group, you included. Your own client reports the run. Alts count with your main."):format(
        N(("%g"):format(cfg("dungeonPerRun"))), N(cfg("dungeonGuildMin"))))

    s.loot.title:SetText("Loot")
    s.loot.body:SetText("Effort is information for the officers. They decide who gets each item; the loot window sorts by response, then effort, only as a guide.")

    self.footer:SetText(("Rules v%d, set by the officers in Options."):format(cfg("version")))
end

-------------------------------------------------------------------------------
--  Loot tab: who won what (officers; from the ledger, up to 8 weeks)
-------------------------------------------------------------------------------
local RESPONSE_ROLE = { ["Main spec"] = "ms", ["Off spec"] = "os", ["Pass"] = "pass" }
local RESPONSE_SHORT = { ["Main spec"] = "Main", ["Off spec"] = "Off", ["Pass"] = "Pass" }
local historyMode, historyWeeks = "items", 4
local playerSort, playerSortDesc = "items", true

local function ItemName(link)
    return (link and link:match("%[(.-)%]")) or ""
end

local function ItemCell(row)
    local f = CreateFrame("Frame", nil, row)
    f:SetSize(196, 20)
    f.icon = Theme.ItemIcon(f, 18)
    f.icon:SetPoint("LEFT")
    f.text = Theme.Text(f, 12)
    f.text:SetPoint("LEFT", f.icon, "RIGHT", 6, 0)
    f.text:SetWidth(170)
    return f
end

function LootTab:Build(panel)
    self.panel = panel
    self.search = Theme.EditBox(panel, 170)
    self.search:SetPoint("TOPLEFT", 14, -10)
    self.hint = Theme.Text(self.search, 11, C.dim)
    self.hint:SetPoint("LEFT", 8, 0)
    self.hint:SetText("Filter by player or item")
    self.search:SetScript("OnTextChanged", function(box)
        self.hint:SetShown(box:GetText() == "")
        self:Refresh()
    end)

    self.itemsButton = Theme.Button(panel, "Items", 64, 22)
    self.itemsButton:SetPoint("LEFT", self.search, "RIGHT", 10, 0)
    self.itemsButton:SetScript("OnClick", function() historyMode = "items"; self:Refresh() end)
    self.playersButton = Theme.Button(panel, "Players", 64, 22)
    self.playersButton:SetPoint("LEFT", self.itemsButton, "RIGHT", 4, 0)
    self.playersButton:SetScript("OnClick", function() historyMode = "players"; self:Refresh() end)
    self.range = Theme.Check(panel, "8 weeks", historyWeeks == 8, function(on)
        historyWeeks = on and 8 or 4
        self:Refresh()
    end)
    self.range:SetPoint("LEFT", self.playersButton, "RIGHT", 12, 0)

    self.items = Theme.List(panel, {
        left = 14, top = -42, rows = 16, rowHeight = 23,
        emptyText = "No items won in this period.",
        columns = {
            { key = "when", label = "When", width = 70 },
            { key = "player", label = "Player", width = 120 },
            { key = "item", label = "Item", width = 196, widget = ItemCell },
            { key = "response", label = "Response", width = 60, widget = function(row) return Theme.Pill(row) end },
        },
        render = function(row, e)
            row.cells.when:SetText(date("%m-%d", e.t))
            row.cells.when:SetTextColor(unpack(C.dim))
            row.cells.player:SetText(AF:ShortName(e.n))
            row.cells.player:SetTextColor(ClassColor(e.classFile or ClassOf(e.n, AF.Standings:All()[e.n])))
            row.cells.item.icon:SetItem(e.l)
            row.cells.item.text:SetText(e.l)
            local role = RESPONSE_ROLE[e.r]
            if role then row.cells.response:Set(RESPONSE_SHORT[e.r], role) else row.cells.response:Set(nil) end
        end,
        onRowEnter = function(row, e)
            GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
            GameTooltip:AddLine(e.l)
            GameTooltip:AddDoubleLine("Won by", AF:ShortName(e.n), 0.8, 0.8, 0.8, 1, 1, 1)
            GameTooltip:AddDoubleLine("When", date("%Y-%m-%d %H:%M", e.t), 0.8, 0.8, 0.8, 1, 1, 1)
            GameTooltip:AddDoubleLine("Response", e.r or "-", 0.8, 0.8, 0.8, 1, 1, 1)
            GameTooltip:AddDoubleLine("Awarded by", AF:ShortName(e.by), 0.8, 0.8, 0.8, 1, 1, 1)
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine(e.test and "Test data: gone after /reload" or "Click to remove (a wrong award)", 0.55, 0.55, 0.57)
            GameTooltip:Show()
        end,
        onRowClick = function(e)
            if e.test then return AF:Print("That's test data from /af test; it's gone after /reload.") end
            StaticPopup_Show("ADVENTFOREVER_VOID", UI.DescribeEvent(e), nil, { id = e.id })
        end,
    })

    self.players = Theme.List(panel, {
        left = 14, top = -42, rows = 16, rowHeight = 23,
        emptyText = "No items won in this period.",
        columns = {
            { key = "name", label = "Player", width = 140 },
            { key = "items", label = "Items", width = 50, justify = "RIGHT" },
            { key = "main", label = "Main", width = 50, justify = "RIGHT" },
            { key = "off", label = "Off", width = 50, justify = "RIGHT" },
            { key = "last", label = "Latest", width = 156, widget = function(row)
                local f = ItemCell(row)
                f:SetWidth(150)
                f.text:SetWidth(126)
                return f
            end },
        },
        onHeader = function(key)
            if key == "last" then key = "t" end
            if playerSort == key then playerSortDesc = not playerSortDesc else playerSort, playerSortDesc = key, key ~= "name" end
            self:Refresh()
        end,
        render = function(row, p)
            row.cells.name:SetText(AF:ShortName(p.name))
            row.cells.name:SetTextColor(ClassColor(p.classFile or ClassOf(p.name, AF.Standings:All()[p.name])))
            row.cells.items:SetText(p.items)
            row.cells.main:SetText(p.main)
            row.cells.off:SetText(p.off)
            row.cells.last.icon:SetItem(p.lastLink)
            row.cells.last.text:SetText(p.lastLink)
        end,
        onRowEnter = function(row, p)
            GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
            GameTooltip:AddLine(AF:ShortName(p.name), ClassColor(p.classFile or ClassOf(p.name, AF.Standings:All()[p.name])))
            for _, e in ipairs(p.wins) do
                GameTooltip:AddDoubleLine(e.l, date("%m-%d", e.t) .. "  " .. (RESPONSE_SHORT[e.r] or "-"), 1, 1, 1, 0.6, 0.6, 0.6)
            end
            GameTooltip:Show()
        end,
    })

    self.info = Theme.Text(panel, 11, C.dim)
    self.info:SetPoint("BOTTOMLEFT", 16, 14)
end

function LootTab:Refresh()
    if not self.panel then return end
    local items = historyMode == "items"
    -- Both lists sit in the same spot; show the active one.
    for _, list in ipairs({ self.items, self.players }) do
        local show = list == (items and self.items or self.players)
        list.body:SetShown(show)
        for _, h in pairs(list.headers) do h:SetShown(show) end
    end
    self.itemsButton.label:SetTextColor(unpack(items and C.bright or C.dim))
    self.playersButton.label:SetTextColor(unpack(items and C.dim or C.bright))

    if not AF.Ledger:CanRecord() and not AF.Loot:HasTestWins() then
        self.items:SetData({})
        self.players:SetData({})
        self.info:SetText("Only officers keep the loot history.")
        return
    end

    local filter = self.search:GetText():lower()
    local wins = {}
    for _, e in ipairs(AF.Loot:RecentWins(historyWeeks)) do
        if filter == "" or AF:ShortName(e.n):lower():find(filter, 1, true)
            or ItemName(e.l):lower():find(filter, 1, true) then
            table.insert(wins, e)
        end
    end

    if items then
        self.items:SetData(wins)
    else
        local byName, list = {}, {}
        for _, e in ipairs(wins) do        -- newest first, so the first one seen is the latest
            local p = byName[e.n]
            if not p then
                p = { name = e.n, items = 0, main = 0, off = 0, t = e.t, lastLink = e.l, wins = {}, classFile = e.classFile }
                byName[e.n] = p
                table.insert(list, p)
            end
            p.items = p.items + 1
            if e.r == "Main spec" then p.main = p.main + 1 elseif e.r == "Off spec" then p.off = p.off + 1 end
            table.insert(p.wins, e)
        end
        table.sort(list, function(a, b)
            local x, y = a[playerSort], b[playerSort]
            if playerSort == "name" then x, y = AF:ShortName(a.name), AF:ShortName(b.name) end
            if x == y then return a.name < b.name end
            if playerSortDesc then return x > y end
            return x < y
        end)
        self.players:SetData(list)
        self.players:MarkSorted(playerSort == "t" and "last" or playerSort)
    end
    self.info:SetText(("%d items won in the last %d weeks%s%s"):format(#wins, historyWeeks,
        filter ~= "" and " (filtered)" or "", AF.Loot:HasTestWins() and "  ·  includes test data until /reload" or ""))
end

-------------------------------------------------------------------------------
--  Recruit tab: guildless players who run the addon (ranks that can invite)
-------------------------------------------------------------------------------
local function Ago(t)
    local s = GetServerTime() - t
    if s < 3600 then return math.max(1, math.floor(s / 60)) .. "m ago" end
    if s < 86400 then return math.floor(s / 3600) .. "h ago" end
    return math.floor(s / 86400) .. "d ago"
end

function RecruitTab:Build(panel)
    self.panel = panel
    self.info = Theme.Text(panel, 11, C.dim)
    self.info:SetPoint("TOPLEFT", 16, -14)
    self.info:SetWidth(448)
    self.info:SetWordWrap(true)
    self.list = Theme.List(panel, {
        left = 14, top = -44, rows = 16, rowHeight = 24,
        emptyText = "Nobody yet. Guildless players with the addon show up here.",
        columns = {
            { key = "name", label = "Player", width = 170 },
            { key = "lvl", label = "Level", width = 50, justify = "RIGHT" },
            { key = "seen", label = "Seen", width = 84, justify = "RIGHT" },
            { key = "invite", label = "", width = 96, justify = "RIGHT", widget = function(row)
                local b = Theme.Button(row, "Invite", 80, 20)
                b:SetScript("OnClick", function() if row.data then AF.Recruit:Invite(row.data.name) end end)
                return b
            end },
            { key = "forget", label = "", width = 46, justify = "RIGHT", widget = function(row)
                local b = Theme.Button(row, "x", 20, 18)
                b:SetScript("OnClick", function() if row.data then AF.Recruit:Forget(row.data.name) end end)
                return b
            end },
        },
        render = function(row, r)
            row.cells.name:SetText(AF:ShortName(r.name))
            row.cells.name:SetTextColor(ClassColor(r.c))
            row.cells.lvl:SetText(r.lvl > 0 and r.lvl or "?")
            row.cells.seen:SetText(r.online and "online" or Ago(r.seen))
            if r.online then
                row.cells.seen:SetTextColor(unpack(Theme.ROLE.ms[1]))
            else
                row.cells.seen:SetTextColor(unpack(C.dim))
            end
            row.cells.invite:SetShown(AF.Recruit:CanInvite())
        end,
        onRowEnter = function(row, r)
            GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
            GameTooltip:AddLine(AF:ShortName(r.name), ClassColor(r.c))
            GameTooltip:AddLine(r.src == "group" and "Found in your group" or "Found on the realm channel", 0.8, 0.8, 0.8)
            GameTooltip:AddLine("Last seen " .. date("%Y-%m-%d %H:%M", r.seen), 0.8, 0.8, 0.8)
            GameTooltip:Show()
        end,
    })
end

function RecruitTab:Refresh()
    if not self.panel then return end
    if not AF.Recruit:CanInvite() then
        self.info:SetText("Only guild ranks that can invite see recruits.")
        self.list:SetData({})
        return
    end
    local entries = AF.Recruit:Entries()
    local online = 0
    for _, r in ipairs(entries) do
        if r.online then online = online + 1 end
    end
    self.info:SetText(("Guildless players running AdventForever: %d, %d online now. Players are kept for 14 days and leave the list once they're in the guild."):format(
        #entries, online))
    self.list:SetData(entries)
end

-------------------------------------------------------------------------------
--  Log tab
-------------------------------------------------------------------------------
function Log:Build(panel)
    self.panel = panel
    self.info = Theme.Text(panel, 11, C.dim)
    self.info:SetPoint("TOPLEFT", 14, -14)
    self.list = Theme.List(panel, {
        left = 14, top = -36, rows = 17, rowHeight = 22,
        emptyText = "No events yet.",
        columns = {
            { key = "when", label = "When", width = 82 },
            { key = "player", label = "Player", width = 110 },
            { key = "what", label = "What", width = 170 },
            { key = "by", label = "By", width = 90 },
        },
        render = function(row, e)
            local removed = AF.Ledger:IsVoided(e.id)
            row.cells.when:SetText(date("%m-%d %H:%M", e.t))
            row.cells.when:SetTextColor(unpack(C.dim))
            local who = e.n
            if e.k == "kill" then who = "Raid"
            elseif e.k == "run" then who = "Group"
            elseif e.k == "void" then
                local target = AF.Ledger:Get(e.ref)
                who = target and (target.n or "Raid") or "?"
            end
            row.cells.player:SetText(AF:ShortName(who))
            row.cells.player:SetTextColor(ClassColor(ClassOf(who, AF.Standings:All()[who])))
            local what = UI.DescribeEvent(e)
            if removed then what = "|cff6b6d72" .. what:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "") .. " (removed)|r" end
            row.cells.what:SetText(what)
            row.cells.by:SetText(AF:ShortName(e.by))
            row.cells.by:SetTextColor(unpack(C.dim))
        end,
        onRowEnter = function(row, e)
            GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
            GameTooltip:AddLine(date("%Y-%m-%d %H:%M", e.t), 1, 1, 1)
            if e.k == "won" or (e.k == "dep" and e.l) then GameTooltip:AddLine(e.l) end
            if e.k == "dep" then
                GameTooltip:AddLine(e.src == "self" and "Reported by the player's own client"
                    or "Read from the guild bank log (time rounded to the hour)", 0.8, 0.8, 0.8, true)
            elseif e.k == "kill" then
                local names = {}
                for _, name in ipairs(e.p) do table.insert(names, AF:ShortName(name)) end
                GameTooltip:AddLine(("%d guild members of %d in the raid:"):format(#e.p, e.size), 0.8, 0.8, 0.8)
                GameTooltip:AddLine(table.concat(names, ", "), 1, 1, 1, true)
            elseif e.k == "run" then
                local names = {}
                for _, name in ipairs(e.p) do table.insert(names, AF:ShortName(name)) end
                GameTooltip:AddLine(("Finished at %s with:"):format(e.en), 0.8, 0.8, 0.8)
                GameTooltip:AddLine(table.concat(names, ", "), 1, 1, 1, true)
                GameTooltip:AddLine("Reports of the same run count once.", 0.55, 0.55, 0.57)
            end
            if e.r then GameTooltip:AddLine("Reason: " .. e.r, 0.8, 0.8, 0.8, true) end
            GameTooltip:AddLine("Recorded by " .. AF:ShortName(e.by), 0.55, 0.55, 0.57)
            if AF.Ledger:IsVoided(e.id) then
                GameTooltip:AddLine("Removed: it no longer counts.", 1, 0.5, 0.5)
            elseif e.k ~= "void" then
                GameTooltip:AddLine("Click to remove", 0.55, 0.55, 0.57)
            end
            GameTooltip:Show()
        end,
        onRowClick = function(e)
            if e.k == "void" or AF.Ledger:IsVoided(e.id) then return end
            StaticPopup_Show("ADVENTFOREVER_VOID", UI.DescribeEvent(e), nil, { id = e.id })
        end,
    })
end

-- One line for an event, as the Log tab shows it.
function UI.DescribeEvent(e)
    if e.k == "cat" then
        return ("%s correction %+d"):format(AF.Standings.CATEGORY_TEXT[e.c], e.v)
    elseif e.k == "dep" then
        return ("Bank %s |cff8b8d92(%s)|r"):format(AF.Bank.Describe(e), e.src)
    elseif e.k == "kill" then
        return ("Kill: %s |cff8b8d92(%d/%d guild)|r"):format(e.en, #e.p, e.size)
    elseif e.k == "honor" then
        return ("Honor %s this week |cff8b8d92(self)|r"):format(BreakUpLargeNumbers(e.h))
    elseif e.k == "run" then
        return ("Dungeon: %s |cff8b8d92(%d guild)|r"):format(e.mn or "?", #e.p)
    elseif e.k == "link" then
        local what = e.m == e.n and "Main" or ("Alt of " .. AF:ShortName(e.m))
        return ("%s |cff8b8d92(%s)|r"):format(what, e.src == "self" and "self" or "officer")
    elseif e.k == "bench" then
        local kill = AF.Ledger:Get(e.ref)
        return "Bench credit: " .. (kill and kill.en or "a kill")
    elseif e.k == "void" then
        local target = AF.Ledger:Get(e.ref)
        return "Removed: " .. (target and UI.DescribeEvent(target) or "an event")
    end
    return "won " .. e.l
end

function Log:Refresh()
    if not self.panel then return end
    if not AF.Ledger:CanRecord() then
        self.info:SetText("Only officers keep the ledger.")
        self.list:SetData({})
        return
    end
    local events = AF.Ledger:Recent(500)
    self.info:SetText(("Latest %d of %d events, newest first"):format(#events, AF.Ledger:Count()))
    self.list:SetData(events)
end

-------------------------------------------------------------------------------
--  Bank tab: the wanted list
-------------------------------------------------------------------------------
local function ItemIDFrom(text)
    text = (text or ""):match("^%s*(.-)%s*$")
    local fromLink = text:find("|Hitem:", 1, true) and C_Item.GetItemInfoInstant(text)
    return fromLink or tonumber(text)
end

function BankTab:Build(panel)
    self.panel = panel
    local heading = Theme.Text(panel, 12, C.bright)
    heading:SetPoint("TOPLEFT", 16, -16)
    heading:SetText("Guild bank")
    self.rule = Theme.Text(panel, 11, C.dim)
    self.rule:SetPoint("TOPLEFT", 16, -36)
    self.rule:SetWidth(448)
    self.rule:SetWordWrap(true)

    -- Adding an item (officers): shift-click it into the box, or type its item ID.
    self.itemBox = Theme.EditBox(panel, 190)
    self.itemBox:SetPoint("TOPLEFT", 16, -76)
    self.itemHint = Theme.Text(self.itemBox, 11, C.dim)
    self.itemHint:SetPoint("LEFT", 8, 0)
    self.itemHint:SetText("Shift-click an item, or its ID")
    self.itemBox:SetScript("OnTextChanged", function(box) self.itemHint:SetShown(box:GetText() == "") end)
    self.valueBox = Theme.EditBox(panel, 54)
    self.valueBox:SetPoint("LEFT", self.itemBox, "RIGHT", 8, 0)
    self.valueBox:SetNumeric(true)
    local each = Theme.Text(panel, 11, C.dim)
    each:SetPoint("LEFT", self.valueBox, "RIGHT", 5, 0)
    each:SetText("g each")
    -- Optional goal: empty keeps the current one, 0 removes it.
    self.goalBox = Theme.EditBox(panel, 58)
    self.goalBox:SetPoint("LEFT", each, "RIGHT", 8, 0)
    self.goalBox:SetNumeric(true)
    self.goalHint = Theme.Text(self.goalBox, 11, C.dim)
    self.goalHint:SetPoint("LEFT", 8, 0)
    self.goalHint:SetText("goal")
    self.goalBox:SetScript("OnTextChanged", function(box) self.goalHint:SetShown(box:GetText() == "") end)
    self.add = Theme.Button(panel, "Add", 54)
    self.add:SetPoint("TOPRIGHT", -16, -76)
    self.add:SetScript("OnClick", function()
        local goalText = self.goalBox:GetText()
        local ok, err = AF.Config:SetWanted(ItemIDFrom(self.itemBox:GetText()), tonumber(self.valueBox:GetText()),
            goalText ~= "" and tonumber(goalText) or nil)
        if not ok then return AF:Print(err) end
        for _, box in ipairs({ self.itemBox, self.valueBox, self.goalBox }) do
            box:SetText("")
            box:ClearFocus()
        end
    end)
    self.editors = { self.itemBox, self.valueBox, each, self.goalBox, self.add }

    self.list = Theme.List(panel, {
        left = 14, top = -112, rows = 12, rowHeight = 24,
        emptyText = "No wanted items yet. Only items on this list count.",
        columns = {
            { key = "item", label = "Item", width = 222, widget = function(row)
                local f = CreateFrame("Frame", nil, row)
                f:SetSize(214, 20)
                f.icon = Theme.ItemIcon(f, 18)
                f.icon:SetPoint("LEFT")
                f.text = Theme.Text(f, 12)
                f.text:SetPoint("LEFT", f.icon, "RIGHT", 6, 0)
                f.text:SetWidth(186)
                return f
            end },
            { key = "value", label = "Each", width = 56, justify = "RIGHT" },
            { key = "goal", label = "Goal", width = 140, widget = function(row)
                local f = CreateFrame("Frame", nil, row)
                f:SetSize(132, 18)
                f.bar = Theme.Bar(f, 60, 6)
                f.bar:SetPoint("LEFT", 6, 0)
                f.text = Theme.Text(f, 11)
                f.text:SetPoint("LEFT", f.bar, "RIGHT", 6, 0)
                f.text:SetWidth(64)
                return f
            end },
            { key = "remove", label = "", width = 34, justify = "RIGHT", widget = function(row)
                local b = Theme.Button(row, "x", 20, 18)
                b:SetScript("OnClick", function()
                    local ok, err = AF.Config:SetWanted(row.data.id, nil)
                    if not ok then AF:Print(err) end
                end)
                return b
            end },
        },
        render = function(row, d)
            local link = select(2, C_Item.GetItemInfo(d.id))
            row.cells.item.icon:SetItem(link or ("item:" .. d.id))
            row.cells.item.text:SetText(link or ("item " .. d.id))
            row.cells.value:SetText(d.value .. "g")
            row.cells.remove:SetShown(AF.Config:CanEdit())
            local goal = row.cells.goal
            if d.target then
                goal.bar:Show()
                goal.bar:SetValue(d.done / d.target)
                if d.done >= d.target then
                    goal.text:SetText("done")
                    goal.text:SetTextColor(Theme.Accent())
                else
                    goal.text:SetText(("%s / %s"):format(BreakUpLargeNumbers(d.done), BreakUpLargeNumbers(d.target)))
                    goal.text:SetTextColor(unpack(C.text))
                end
            else
                goal.bar:Hide()
                goal.text:SetText("-")
                goal.text:SetTextColor(unpack(C.dim))
            end
        end,
        onRowEnter = function(row, d)
            GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
            GameTooltip:AddLine(select(2, C_Item.GetItemInfo(d.id)) or ("item " .. d.id))
            GameTooltip:AddLine(("Counts as %dg each toward the bank score."):format(d.value), 0.8, 0.8, 0.8)
            if d.target then
                local goal = AF.Config:Get("goals")[d.id]
                GameTooltip:AddLine(("Goal: %s, %s deposited since %s."):format(BreakUpLargeNumbers(d.target),
                    BreakUpLargeNumbers(d.done), date("%Y-%m-%d", goal.since)), 1, 1, 1, true)
                if d.done < d.target then
                    GameTooltip:AddLine(("%s still needed."):format(BreakUpLargeNumbers(d.target - d.done)), 1, 0.82, 0)
                end
            end
            GameTooltip:Show()
        end,
    })

    self.pending = Theme.Text(panel, 11, C.dim)
    self.pending:SetPoint("BOTTOMLEFT", 16, 14)
end

function BankTab:Refresh()
    if not self.panel then return end
    self.rule:SetText(("Gold and wanted items deposited count toward the bank score: 1 point per %d gold, at most %d points a week. Withdrawals count against it. Your own client reports your deposits when you close the bank; officers' clients also read the bank log."):format(
        AF.Config:Get("goldPerPoint"), AF.Config:Get("bankMax")))
    local canEdit = AF.Config:CanEdit()
    for _, region in ipairs(self.editors) do region:SetShown(canEdit) end
    self.itemHint:SetShown(canEdit and self.itemBox:GetText() == "")

    -- Unfinished goals first (most needed on top), then the rest by name.
    local data = {}
    for id, value in pairs(AF.Config:Get("wanted")) do
        local done, target = AF.Standings:GoalProgress(id)
        table.insert(data, { id = id, value = value, name = C_Item.GetItemInfo(id) or ("item " .. id),
            done = done, target = target, open = target and done < target })
    end
    table.sort(data, function(a, b)
        if (a.open or false) ~= (b.open or false) then return a.open end
        if a.open and b.open and (a.target - a.done) ~= (b.target - b.done) then
            return (a.target - a.done) > (b.target - b.done)
        end
        return a.name < b.name
    end)
    self.list:SetData(data)

    local waiting = 0
    for _, d in ipairs(AF.db.pendingDeposits or {}) do
        if d.n == AF.playerName then waiting = waiting + 1 end
    end
    self.pending:SetText(waiting > 0
        and ("%d of your deposit reports are waiting for an officer to come online."):format(waiting) or "")
end

-- Shift-clicking an item while the item box has focus puts the link there.
if type(ChatEdit_InsertLink) == "function" then
    hooksecurefunc("ChatEdit_InsertLink", function(link)
        local box = BankTab.itemBox
        if box and box:IsVisible() and box:HasFocus() and type(link) == "string" then box:SetText(link) end
    end)
end

-------------------------------------------------------------------------------
--  Options tab
-------------------------------------------------------------------------------
function Options:Build(panel)
    self.panel = panel
    -- The rules, on one card.
    local rulesCard = Theme.Card(panel, 448, 36 + #AF.Config.FIELDS * 28 + 56)
    rulesCard:SetPoint("TOPLEFT", 16, -14)
    Theme.Label(rulesCard, "Effort rules"):SetPoint("TOPLEFT", 12, -12)

    self.rows = {}
    for i, field in ipairs(AF.Config.FIELDS) do
        local y = -32 - (i - 1) * 28
        local label = Theme.Text(rulesCard, 12)
        label:SetPoint("TOPLEFT", 12, y - 4)
        label:SetText(field.label .. (field.gmOnly and "  |cff8b8d92(GM)|r" or ""))
        local box = Theme.EditBox(rulesCard, 64)
        box:SetPoint("TOPRIGHT", -12, y)
        if not field.decimals then box:SetNumeric(true) end
        table.insert(self.rows, { field = field, box = box })
    end
    local below = -32 - #AF.Config.FIELDS * 28
    local note = Theme.Text(rulesCard, 11, C.dim)
    note:SetPoint("TOPLEFT", 12, below - 4)
    note:SetText("The four caps add up to the weekly maximum (at most 200).")

    self.save = Theme.Button(rulesCard, "Save and send", 120)
    self.save:SetPoint("TOPRIGHT", -12, below - 24)
    self.save:SetScript("OnClick", function()
        local values = {}
        for _, row in ipairs(self.rows) do values[row.field.key] = tonumber(row.box:GetText()) end
        local ok, err = AF.Config:Save(values)
        if not ok then AF:Print(err) end
        self:Refresh()
    end)
    self.status = Theme.Text(rulesCard, 11, C.dim)
    self.status:SetPoint("RIGHT", self.save, "LEFT", -12, 0)
    self.status:SetJustifyH("RIGHT")

    -- The ledger backup, on its own card under the rules.
    local backupCard = Theme.Card(panel, 448, 96)
    backupCard:SetPoint("TOPLEFT", rulesCard, "BOTTOMLEFT", 0, -8)
    Theme.Label(backupCard, "Ledger backup"):SetPoint("TOPLEFT", 12, -12)
    local backupNote = Theme.Text(backupCard, 11, C.dim)
    backupNote:SetPoint("TOPLEFT", 12, -30)
    backupNote:SetWidth(424)
    backupNote:SetWordWrap(true)
    backupNote:SetText("The ledger only lives in officers' saved data. Export it now and then and keep the text somewhere safe.")
    self.export = Theme.Button(backupCard, "Export", 90)
    self.export:SetPoint("BOTTOMLEFT", 12, 12)
    self.export:SetScript("OnClick", function() SlashCmdList.ADVENTFOREVER("export") end)
    self.import = Theme.Button(panel, "Import", 90)
    self.import:SetPoint("LEFT", self.export, "RIGHT", 8, 0)
    self.import:SetScript("OnClick", function() SlashCmdList.ADVENTFOREVER("import") end)
end

function Options:Refresh()
    if not self.panel then return end
    local canEdit = AF.Config:CanEdit()
    for _, row in ipairs(self.rows) do
        row.box:SetText(tostring(AF.Config:Get(row.field.key)))
        local editable = canEdit and (not row.field.gmOnly or AF:IsGM())
        row.box:SetEnabled(editable)
        row.box:SetTextColor(editable and 1 or 0.5, editable and 1 or 0.5, editable and 1 or 0.5)
    end
    self.save:SetShown(canEdit)
    self.export:SetShown(AF.Ledger:CanRecord())
    self.import:SetShown(AF.Ledger:CanRecord())
    self.status:SetText(("Rules v%d%s"):format(AF.Config:Get("version"), canEdit and "" or "  ·  officers edit these"))
end

-------------------------------------------------------------------------------
--  Loot window (loot authority)
-------------------------------------------------------------------------------
local loot
local selectedSid
local ITEM_BUTTONS = 9

local function RefreshLoot()
    if not loot or not loot:IsShown() then return end
    local order, sessions = AF.Loot:Sessions()
    if selectedSid and not sessions[selectedSid] then selectedSid = nil end
    selectedSid = selectedSid or order[#order]

    -- Newest items at the top.
    for i, b in ipairs(loot.items) do
        local session = sessions[order[#order - i + 1]]
        b.session = session
        if session then
            b:SetItem(session.link)
            b.icon:SetDesaturated(session.awarded ~= nil)
            b.icon:SetAlpha(session.awarded and 0.5 or 1)
            if session.sid == selectedSid then b:SetBackdropBorderColor(Theme.Accent()) end
        else
            b:SetItem(nil)
        end
    end

    local session = sessions[selectedSid]
    loot.header:SetShown(session ~= nil)
    if not session then
        loot.list:SetData({})
        return
    end
    loot.header.icon:SetItem(session.link)
    loot.header.link:SetText(session.link)
    if session.awarded then
        local trade = ""
        if session.byTrade then
            if session.delivered then
                trade = "  ·  |cff4fe0a6delivered|r"
            elseif session.holder then
                trade = "  ·  waiting for " .. AF:ShortName(session.holder) .. " to trade it"
            else
                trade = "  ·  holder unknown (nobody with the addon has it)"
            end
        end
        loot.header.info:SetText("Awarded to " .. AF:ShortName(session.awarded) .. trade)
    else
        local answered, total = 0, #AF:GroupMembers()
        for _ in pairs(session.responses) do answered = answered + 1 end
        local voted = 0
        for _ in pairs(session.votes or {}) do voted = voted + 1 end
        local council = session.test and 3 or #AF.Loot:Council(session.authority)
        local who = session.authority ~= AF.playerName
            and ("  ·  %s hands it out"):format(AF:ShortName(session.authority)) or ""
        loot.header.info:SetText(("%d of %d answered  ·  council: %d, %d voted%s"):format(
            answered, total, council, voted, who))
    end
    loot.list:SetData(AF.Loot:Candidates(session.sid))
end

local function EquippedWidget(row)
    local f = CreateFrame("Frame", nil, row)
    f:SetSize(104, 18)
    f.a = Theme.ItemIcon(f, 16)
    f.a:SetPoint("LEFT")
    f.b = Theme.ItemIcon(f, 16)
    f.b:SetPoint("LEFT", f.a, "RIGHT", 3, 0)
    f.text = Theme.Text(f, 11)
    -- links: what they wear in that slot; answered: whether they responded at all.
    function f:Set(links, itemLink, answered)
        self.a:SetItem(links[1])
        self.b:SetItem(links[2])
        self.text:ClearAllPoints()
        self.text:SetPoint("LEFT", links[2] and self.b or (links[1] and self.a) or self, links[1] and "RIGHT" or "LEFT", 5, 0)
        if answered then
            self.text:SetText(UI.DiffText(AF.Loot.IlvlDiff(itemLink, links)))
        else
            self.text:SetText("|cff8b8d92-|r")
        end
    end
    return f
end

local function CreateLoot()
    loot = Theme.Window("AdventForeverLoot", "Loot", 680, 440)

    loot.items = {}
    for i = 1, ITEM_BUTTONS do
        local b = Theme.ItemIcon(loot, 34)
        b:SetPoint("TOPLEFT", 12, -34 - (i - 1) * 40)
        b:SetScript("OnClick", function(self)
            if self.session then selectedSid = self.session.sid; RefreshLoot() end
        end)
        if b.SetPropagateMouseClicks then b:SetPropagateMouseClicks(false) end
        loot.items[i] = b
    end
    local split = Theme.Line(loot)
    split:SetPoint("TOPLEFT", 56, -25)
    split:SetPoint("BOTTOMLEFT", 56, 1)
    split:SetWidth(1)

    local header = CreateFrame("Frame", nil, loot)
    header:SetPoint("TOPLEFT", 68, -34)
    header:SetSize(596, 36)
    header.icon = Theme.ItemIcon(header, 36)
    header.icon:SetPoint("LEFT")
    header.link = Theme.Text(header, 13)
    header.link:SetPoint("TOPLEFT", header.icon, "TOPRIGHT", 10, -3)
    header.info = Theme.Text(header, 11, C.dim)
    header.info:SetPoint("BOTTOMLEFT", header.icon, "BOTTOMRIGHT", 10, 3)
    loot.header = header

    loot.list = Theme.List(loot, {
        left = 68, top = -82, rows = 13, rowHeight = 24,
        emptyText = "No loot yet. Open a corpse as master looter, or /af item <shift-click>.",
        columns = {
            { key = "name", label = "Name", width = 122 },
            { key = "response", label = "Response", width = 64, widget = function(row) return Theme.Pill(row) end },
            { key = "votes", label = "Votes", width = 52, widget = function(row)
                local b = Theme.Button(row, "0", 40, 18)
                b:SetScript("OnClick", function()
                    if row.data then AF.Loot:Vote(selectedSid, row.data.name) end
                end)
                return b
            end },
            { key = "effort", label = "Effort", width = 44, justify = "RIGHT" },
            { key = "weeks", label = "Weeks", width = 52, widget = function(row) return Theme.WeekBars(row, 12) end },
            { key = "won", label = "Won", width = 34, justify = "CENTER" },
            { key = "equipped", label = "Equipped", width = 108, widget = EquippedWidget },
            { key = "note", label = "Note", width = 120 },
        },
        render = function(row, c)
            local isAlt = c.member and AF.Standings:MainOf(c.name) ~= c.name
            row.cells.name:SetText(AF:ShortName(c.name) .. (isAlt and "  |cff8b8d92alt|r" or ""))
            row.cells.name:SetTextColor(ClassColor(ClassOf(c.name, c.member)))
            if c.response then
                row.cells.response:Set(SHORT_RESPONSE[c.response], ROLE_KEY[c.response])
            else
                row.cells.response:Set(nil)
            end
            if c.member then
                row.cells.effort:SetText(c.member.effort)
                row.cells.effort:SetTextColor(unpack(C.text))
                row.cells.weeks:SetWeeks(c.member.weeks, WeekMax())
                row.cells.weeks:Show()
            else
                row.cells.effort:SetText("guest")
                row.cells.effort:SetTextColor(unpack(C.dim))
                row.cells.weeks:Hide()
            end
            row.cells.won:SetText(#c.won > 0 and #c.won or "")
            row.cells.won:SetTextColor(unpack(Theme.ROLE.os[1]))
            local session = select(2, AF.Loot:Sessions())[selectedSid]
            row.cells.equipped:Set(c.equipped, session and session.link, c.response ~= nil)
            row.cells.note:SetText(c.note or "")
            row.cells.note:SetTextColor(unpack(C.dim))

            -- Votes: the count on a button; our own vote gets the accent border.
            local vote = row.cells.votes
            local mine = false
            for _, voter in ipairs(c.voters) do
                if voter == AF.playerName then mine = true end
            end
            vote.label:SetText(#c.voters)
            vote.label:SetTextColor(unpack(#c.voters > 0 and C.bright or C.dim))
            if mine then
                vote:SetBackdropBorderColor(Theme.Accent())
            else
                vote:SetBackdropBorderColor(unpack(C.buttonBorder))
            end
            local canVote = session and not session.awarded and AF.Loot.CanVote(session)
            vote:SetEnabled(canVote and true or false)
            vote:SetAlpha((canVote or #c.voters > 0) and 1 or 0.4)
        end,
        onRowEnter = function(row, c)
            EffortTooltip(row, c.name, c.member)
            if c.note then
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine("Note: " .. c.note, 1, 0.9, 0.6, true)
            end
            if #c.won > 0 then
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine("Won this raid week", 1, 1, 1)
                for _, link in ipairs(c.won) do GameTooltip:AddLine(link) end
            end
            if AF.Ledger:CanRecord() then
                local recent = 0
                for _, e in ipairs(AF.Loot:RecentWins(4)) do
                    if AF.Standings:MainOf(e.n) == AF.Standings:MainOf(c.name) then recent = recent + 1 end
                end
                GameTooltip:AddLine(("Won in the last 4 weeks: %d"):format(recent), 0.8, 0.8, 0.8)
            end
            if not c.member then GameTooltip:AddLine("Not in the guild", 0.55, 0.55, 0.57) end
            if #c.voters > 0 then
                local names = {}
                for _, voter in ipairs(c.voters) do table.insert(names, AF:ShortName(voter)) end
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine("Votes: " .. table.concat(names, ", "), 1, 1, 1, true)
            end
            local session = select(2, AF.Loot:Sessions())[selectedSid]
            GameTooltip:AddLine(" ")
            if session and session.authority == AF.playerName then
                GameTooltip:AddLine("Click to award. Vote with the Votes button.", 0.55, 0.55, 0.57)
            else
                GameTooltip:AddLine("Click to vote for them.", 0.55, 0.55, 0.57)
            end
            GameTooltip:Show()
        end,
        onRowClick = function(c)
            local session = select(2, AF.Loot:Sessions())[selectedSid]
            if not session then return end
            if session.awarded then return AF:Printf("Already awarded to %s.", AF:ShortName(session.awarded)) end
            if session.authority ~= AF.playerName then return AF.Loot:Vote(session.sid, c.name) end
            StaticPopup_Show("ADVENTFOREVER_AWARD", session.link, AF:ShortName(c.name), { sid = session.sid, name = c.name })
        end,
    })

    local hint = Theme.Text(loot, 11, C.dim)
    hint:SetPoint("BOTTOMLEFT", 70, 14)
    hint:SetText("Sorted by response, then effort. Officers vote; the order and votes are a guide.")
    local clear = Theme.Button(loot, "Clear awarded", 110)
    clear:SetPoint("BOTTOMRIGHT", -12, 10)
    clear:SetScript("OnClick", function() AF.Loot:ClearAwarded() end)

    loot:SetScript("OnShow", RefreshLoot)
end

function UI:ShowLootWindow(sid)
    if not loot then CreateLoot() end
    if sid then selectedSid = sid end
    loot:Show()
    RefreshLoot()
end

function UI:ToggleLootWindow()
    if loot and loot:IsShown() then loot:Hide() else self:ShowLootWindow() end
end

-------------------------------------------------------------------------------
--  Loot popup (every raider)
-------------------------------------------------------------------------------
local popup

local function CreatePopup()
    popup = Theme.Window("AdventForeverPopup", "Loot", 340, 184, 180)
    popup:SetFrameStrata("DIALOG")

    popup.timer = Theme.Bar(popup, 338, 3)
    popup.timer:SetPoint("TOPLEFT", 1, -25)

    popup.icon = Theme.ItemIcon(popup, 40)
    popup.icon:SetPoint("TOPLEFT", 12, -38)
    popup.link = Theme.Text(popup, 13)
    popup.link:SetPoint("TOPLEFT", popup.icon, "TOPRIGHT", 10, -1)
    popup.link:SetPoint("RIGHT", -12, 0)
    popup.slot = Theme.Text(popup, 11, C.dim)
    popup.slot:SetPoint("TOPLEFT", popup.link, "BOTTOMLEFT", 0, -5)
    popup.eqA = Theme.ItemIcon(popup, 16)
    popup.eqA:SetPoint("LEFT", popup.slot, "RIGHT", 5, 0)
    popup.eqB = Theme.ItemIcon(popup, 16)
    popup.eqB:SetPoint("LEFT", popup.eqA, "RIGHT", 3, 0)
    popup.diff = Theme.Text(popup, 11)
    popup.info = Theme.Text(popup, 11, C.dim)
    popup.info:SetPoint("TOPLEFT", popup.slot, "BOTTOMLEFT", 0, -6)

    popup.note = Theme.EditBox(popup, 316)
    popup.note:SetPoint("TOPLEFT", 12, -100)
    popup.note:SetMaxLetters(60)
    popup.noteHint = Theme.Text(popup.note, 11, C.dim)
    popup.noteHint:SetPoint("LEFT", 8, 0)
    popup.noteHint:SetText("Note (optional): BiS, small upgrade...")
    popup.note:SetScript("OnTextChanged", function(box) popup.noteHint:SetShown(box:GetText() == "") end)

    local buttons = { { AF.Loot.MS, "Main spec", "ms" }, { AF.Loot.OS, "Off spec", "os" }, { AF.Loot.PASS, "Pass", "pass" } }
    for i, def in ipairs(buttons) do
        local b = Theme.Button(popup, def[2], 100, 24, def[3])
        b:SetPoint("BOTTOMLEFT", 12 + (i - 1) * 106, 12)
        b:SetScript("OnClick", function()
            if not popup.entry then return end
            popup.note:ClearFocus()
            AF.Loot:Respond(popup.entry, def[1], popup.note:GetText())
        end)
    end

    local elapsed = 0
    popup:SetScript("OnUpdate", function(_, dt)
        elapsed = elapsed + dt
        if elapsed < 0.1 then return end
        elapsed = 0
        local entry = popup.entry
        if not entry or entry.expires < GetTime() then return UI:ShowPopup() end
        popup.timer:SetValue((entry.expires - GetTime()) / entry.duration)
        popup:UpdateInfo()
    end)

    function popup:UpdateInfo()
        local me = AF.Standings:Get(AF.playerName)
        local parts = {}
        if me then table.insert(parts, "Your effort " .. me.effort) end
        local waiting = #AF.Loot:Incoming()
        if waiting > 1 then table.insert(parts, "1 of " .. waiting) end
        table.insert(parts, math.ceil(self.entry.expires - GetTime()) .. "s")
        self.info:SetText(table.concat(parts, "  ·  "))
    end
end

function UI:ShowPopup()
    AF.Loot:DropExpired()
    local entry = AF.Loot:Incoming()[1]
    if not popup then CreatePopup() end
    popup.entry = entry
    if not entry then return popup:Hide() end
    entry.duration = entry.duration or math.max(1, entry.expires - GetTime())
    if popup.shownEntry ~= entry then      -- a new item: a fresh note
        popup.shownEntry = entry
        popup.note:SetText("")
    end

    popup.icon:SetItem(entry.link)
    popup.link:SetText(entry.link)
    local equipLoc = select(4, C_Item.GetItemInfoInstant(entry.link))
    local equipped = AF.Loot.EquippedFor(entry.link)
    if equipLoc == "" then
        popup.slot:SetText("No equip slot")
    elseif #equipped > 0 then
        popup.slot:SetText((_G[equipLoc] or "Slot") .. "  ·  you wear")
    else
        popup.slot:SetText((_G[equipLoc] or "Slot") .. "  ·  nothing equipped")
    end
    popup.eqA:SetItem(equipped[1])
    popup.eqB:SetItem(equipped[2])
    popup.diff:ClearAllPoints()
    popup.diff:SetPoint("LEFT", equipped[2] and popup.eqB or (equipped[1] and popup.eqA) or popup.slot, "RIGHT", 6, 0)
    popup.diff:SetText(UI.DiffText(AF.Loot.IlvlDiff(entry.link, equipped)))
    popup:UpdateInfo()
    popup:Show()
end

-------------------------------------------------------------------------------
--  Text window (ledger export / import)
-------------------------------------------------------------------------------
local textWindow

local function CreateTextWindow()
    textWindow = Theme.Window("AdventForeverText", "", 520, 340)
    textWindow:SetFrameStrata("DIALOG")
    textWindow.hint = Theme.Text(textWindow, 11, C.dim)
    textWindow.hint:SetPoint("TOPLEFT", 14, -34)
    textWindow.hint:SetPoint("RIGHT", -14, 0)

    local scroll, box = Theme.TextArea(textWindow)
    scroll:SetPoint("TOPLEFT", 20, -58)
    scroll:SetPoint("BOTTOMRIGHT", -36, 50)
    box:SetScript("OnEscapePressed", function() textWindow:Hide() end)
    textWindow.box = box

    textWindow.action = Theme.Button(textWindow, "Import", 100)
    textWindow.action:SetPoint("BOTTOMRIGHT", -12, 12)
    textWindow.action:SetScript("OnClick", function()
        if textWindow.onAction then textWindow.onAction(box:GetText()) end
        textWindow:Hide()
    end)
end

-- Shows text to copy, or (with onAction) an empty box to paste into.
function UI:ShowTextWindow(title, hint, text, onAction)
    if not textWindow then CreateTextWindow() end
    textWindow.title:SetText(title)
    textWindow.hint:SetText(hint)
    textWindow.onAction = onAction
    textWindow.action:SetShown(onAction ~= nil)
    textWindow.box:SetText(text)
    textWindow:Show()
    textWindow.box:SetFocus()
    textWindow.box:HighlightText()
end

-------------------------------------------------------------------------------
--  Award dialog
-------------------------------------------------------------------------------
StaticPopupDialogs.ADVENTFOREVER_VOID = {
    text = "Remove this event?\n\n%s\n\nIt stops counting everywhere. The removal itself is logged.",
    button1 = REMOVE or "Remove",
    button2 = CANCEL,
    OnAccept = function(_, data)
        local target = AF.Ledger:Get(data.id)
        if target then AF.Ledger:Void(target, "removed in the log") end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

StaticPopupDialogs.ADVENTFOREVER_AWARD = {
    text = "Award %s to %s?",
    button1 = ACCEPT,
    button2 = CANCEL,
    OnAccept = function(_, data)
        local result, err = AF.Loot:Award(data.sid, data.name)
        if not result then AF:Print(err) end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-------------------------------------------------------------------------------
--  Refresh on changes
-------------------------------------------------------------------------------
local function RefreshAll()
    if Visible(Effort) then Effort:Refresh() end
    if Visible(Me) then Me:Refresh() end
    if Visible(BankTab) then BankTab:Refresh() end
    if Visible(Log) then Log:Refresh() end
    if Visible(LootTab) then LootTab:Refresh() end
    RefreshLoot()
end

AF:On("STANDINGS_UPDATED", function()
    RefreshNav()
    RefreshAll()
end)
AF:On("LEDGER_UPDATED", RefreshAll)
AF:On("LOOT_UPDATED", function()
    RefreshLoot()
    if Visible(LootTab) then LootTab:Refresh() end
end)
AF:On("CONFIG_UPDATED", function()
    RefreshAll()
    if Visible(Options) then Options:Refresh() end
    if Visible(BankTab) then BankTab:Refresh() end
    if Visible(Rules) then Rules:Refresh() end
end)

-- Item names arrive from the server after first use; redraw the wanted list then.
local itemTimer
AF:RegisterEvent("GET_ITEM_INFO_RECEIVED", function()
    if not Visible(BankTab) or itemTimer then return end
    itemTimer = C_Timer.NewTimer(0.3, function()
        itemTimer = nil
        if Visible(BankTab) then BankTab:Refresh() end
    end)
end)

AF:On("RECRUITS_UPDATED", function()
    if Visible(RecruitTab) then RecruitTab:Refresh() end
end)

-------------------------------------------------------------------------------
--  Trades window: items you owe someone, and items coming to you
-------------------------------------------------------------------------------
local trades

local function TimeLeft(seconds)
    if not seconds then return "?" end
    if seconds <= 0 then return "0m" end
    local h, m = math.floor(seconds / 3600), math.floor(seconds % 3600 / 60)
    return h > 0 and ("%dh %02dm"):format(h, m) or ("%dm"):format(m)
end

local function RefreshTrades()
    if not trades or not trades:IsShown() then return end
    local rows = AF.Trade:Rows()
    trades.list:SetData(rows)
    trades.status:SetText(#rows == 0 and "" or "Opening a trade with the winner puts the item in for you.")
end

local function CreateTrades()
    trades = Theme.Window("AdventForeverTrades", "Trades", 420, 230, -160)
    trades.list = Theme.List(trades, {
        left = 12, top = -32, rows = 6, rowHeight = 26,
        emptyText = "No trades waiting.",
        columns = {
            { key = "item", label = "Item", width = 170, widget = function(row)
                local f = CreateFrame("Frame", nil, row)
                f:SetSize(164, 22)
                f.icon = Theme.ItemIcon(f, 20)
                f.icon:SetPoint("LEFT")
                f.text = Theme.Text(f, 12)
                f.text:SetPoint("LEFT", f.icon, "RIGHT", 6, 0)
                f.text:SetWidth(138)
                return f
            end },
            { key = "who", label = "", width = 110 },
            { key = "left", label = "Time left", width = 60, justify = "RIGHT" },
            { key = "trade", label = "", width = 56, justify = "RIGHT", widget = function(row)
                local b = Theme.Button(row, "Trade", 50, 20)
                b:SetScript("OnClick", function()
                    if row.data then AF.Trade:Open(row.data.entry, row.data.kind) end
                end)
                return b
            end },
        },
        render = function(row, r)
            local e = r.entry
            row.cells.item.icon:SetItem(e.l)
            row.cells.item.text:SetText(e.l)
            local other = r.kind == "owe" and e.to or e.from
            if r.kind == "owe" then
                row.cells.who:SetText("to " .. AF:ShortName(other))
            else
                row.cells.who:SetText(other and ("from " .. AF:ShortName(other)) or "from ?")
            end
            if e.done then
                row.cells.left:SetText("|cff4fe0a6done|r")
            elseif e.expired then
                row.cells.left:SetText("|cffff5555expired|r")
            else
                local near = other and AF.Trade.InRange(other)
                row.cells.left:SetText((near and "|cff4fe0a6in range|r  " or "") .. TimeLeft(r.left))
            end
            row.cells.trade:SetShown(not e.done and not e.expired and other ~= nil)
        end,
        onRowEnter = function(row, r)
            GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
            GameTooltip:AddLine(r.entry.l)
            GameTooltip:AddLine(r.kind == "owe" and "You have this item; trade it to the winner."
                or "Awarded to you; the holder trades it to you.", 0.8, 0.8, 0.8, true)
            if not r.left then
                GameTooltip:AddLine("Time left unknown (your loot line wasn't readable).", 0.6, 0.6, 0.62, true)
            end
            GameTooltip:Show()
        end,
    })
    trades.status = Theme.Text(trades, 11, C.dim)
    trades.status:SetPoint("BOTTOMLEFT", 14, 10)
    local elapsed = 0
    trades:SetScript("OnUpdate", function(_, dt)    -- time left and range change by the second
        elapsed = elapsed + dt
        if elapsed < 1 then return end
        elapsed = 0
        RefreshTrades()
    end)
    trades:SetScript("OnShow", RefreshTrades)
end

function UI:ShowTrades()
    if not trades then CreateTrades() end
    trades:Show()
    RefreshTrades()
end

function UI:ToggleTrades()
    if trades and trades:IsShown() then trades:Hide() else self:ShowTrades() end
end

AF:On("TRADES_UPDATED", RefreshTrades)

-------------------------------------------------------------------------------
--  Login nudge: a short summary card about a minute after logging in
-------------------------------------------------------------------------------
local NUDGE_DELAY = 55      -- seconds after login: the ledger sync / a snapshot has landed by then
local NUDGE_SHOWN = 15      -- seconds before it fades (unless hovered)
local nudge

function UI.NudgeEnabled()
    local prefs = AF.db and AF.db.prefs
    return not prefs or prefs.nudge ~= false
end

-- The lines for the card, or nil if there's nothing to say yet.
local function NudgeLines()
    local name = AF.playerName
    local member = name and AF.Standings:Get(name)
    if not member then return nil end
    if not AF.Ledger:CanRecord() and not AF.Standings:SnapshotInfo() then return nil end   -- no numbers yet
    local a = AccentHex()
    local lines = {}
    table.insert(lines, ("Last week: %s%d|r  ·  This week so far: %s%d|r  ·  Effort: %s%d|r"):format(
        a, member.weeks[2], a, member.weeks[1], a, member.effort))

    local d = AF.Standings:Detail(name)
    local split, now = d.split[1], d.now
    if now.total > 0 then
        table.insert(lines, ("Raids: at %d of %d guild kills this week"):format(now.here, now.total))
    end
    local bankLeft = AF.Config:Get("bankMax") - split.bank
    if bankLeft > 0 then
        table.insert(lines, ("Bank: %d points open (about %s)"):format(bankLeft,
            Gold(bankLeft * AF.Config:Get("goldPerPoint"))))
    end
    local honorLeft = AF.Config:Get("honorMax") - split.honor
    if honorLeft > 0 then
        local myHonor = math.max(now.honor, (AF.Honor.Current()))
        local toGo = math.max(0, AF.Config:Get("honorTarget") - myHonor)
        table.insert(lines, ("Honor: %d points open (%s honor to go)"):format(honorLeft, BreakUpLargeNumbers(toGo)))
    end
    local dungeonLeft = AF.Config:Get("dungeonMax") - split.dungeon
    local perRun = AF.Config:Get("dungeonPerRun")
    if dungeonLeft > 0 and perRun > 0 then
        local runsLeft = math.ceil(dungeonLeft / perRun)
        table.insert(lines, ("Dungeons: %d points open (%d run%s with %d+ guildies)"):format(dungeonLeft, runsLeft,
            runsLeft == 1 and "" or "s", AF.Config:Get("dungeonGuildMin")))
    end

    -- The guild's most-needed wanted item.
    local best, bestLeft
    for itemID in pairs(AF.Config:Get("goals")) do
        local done, target = AF.Standings:GoalProgress(itemID)
        if target and done < target and (not bestLeft or target - done > bestLeft) then
            best, bestLeft = itemID, target - done
        end
    end
    if best then
        local link = select(2, C_Item.GetItemInfo(best)) or ("item " .. best)
        table.insert(lines, ("Guild needs: %s x %s"):format(BreakUpLargeNumbers(bestLeft), link))
    end

    local trades = AF.Trade:Count()
    if trades > 0 then
        table.insert(lines, ("|cffffd055%d item%s to trade: /af trades|r"):format(trades, trades == 1 and "" or "s"))
    end
    return lines
end

local function CreateNudge()
    nudge = CreateFrame("Button", "AdventForeverNudge", UIParent, "BackdropTemplate")
    nudge:SetSize(380, 40)
    nudge:SetPoint("TOP", UIParent, "TOP", 0, -120)
    nudge:SetFrameStrata("HIGH")
    Theme.Backdrop(nudge, C.bg)
    local stripe = nudge:CreateTexture(nil, "ARTWORK")
    stripe:SetPoint("TOPLEFT", 1, -1)
    stripe:SetPoint("BOTTOMLEFT", 1, 1)
    stripe:SetWidth(3)
    Theme.Accented(stripe)
    nudge.title = Theme.Text(nudge, 12, C.bright)
    nudge.title:SetPoint("TOPLEFT", 14, -10)
    nudge.title:SetText("AdventForever")
    nudge.body = Theme.Text(nudge, 12)
    nudge.body:SetPoint("TOPLEFT", 14, -30)
    nudge.body:SetWidth(352)
    nudge.body:SetWordWrap(true)
    nudge.body:SetJustifyV("TOP")
    local close = CreateFrame("Button", nil, nudge)
    close:SetSize(20, 20)
    close:SetPoint("TOPRIGHT", -4, -4)
    close.glyph = Theme.Text(close, 13, C.dim)
    close.glyph:SetPoint("CENTER")
    close.glyph:SetText("x")
    close:SetScript("OnClick", function() nudge:Hide() end)
    nudge:SetScript("OnClick", function()
        nudge:Hide()
        UI:ShowMe()
    end)
    nudge:SetScript("OnEnter", function()
        nudge.hovered = true
        nudge:SetAlpha(1)
    end)
    nudge:SetScript("OnLeave", function() nudge.hovered = false end)
    nudge:SetScript("OnUpdate", function(self, dt)
        if self.hovered then self.age = 0 return end
        self.age = (self.age or 0) + dt
        if self.age > NUDGE_SHOWN then
            local alpha = 1 - (self.age - NUDGE_SHOWN) / 2
            if alpha <= 0 then return self:Hide() end
            self:SetAlpha(alpha)
        end
    end)
    nudge:Hide()
end

-- Shows the card now (also /af nudge). Returns false if there's nothing to show.
function UI:ShowNudge()
    local lines = NudgeLines()
    if not lines then return false end
    if not nudge then CreateNudge() end
    nudge.body:SetText(table.concat(lines, "\n"))
    nudge:SetHeight(44 + nudge.body:GetStringHeight())
    nudge.age, nudge.hovered = 0, false
    nudge:SetAlpha(1)
    nudge:Show()
    return true
end

function UI:Enable()
    C_Timer.After(NUDGE_DELAY, function()
        if UI.NudgeEnabled() and IsInGuild() then UI:ShowNudge() end
    end)
end
