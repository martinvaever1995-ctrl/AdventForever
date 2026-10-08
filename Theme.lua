-------------------------------------------------------------------------------
--  Theme.lua -- the flat dark look and the widgets built on it: windows, tabs,
--  buttons, checkboxes, inputs, bars, week mini bars, response pills, item
--  icons and scrolling lists.
--
--  With EllesmereUI installed (and its third-party skinning on for us), its
--  skinning API takes over the styling and supplies the accent color, so we
--  match the user's theme and follow live accent changes. Without it, the
--  built-in palette below is used.
-------------------------------------------------------------------------------
local _, AF = ...
local Theme = AF:NewModule("Theme")

local WHITE = "Interface\\Buttons\\WHITE8x8"
local DEFAULT_ACCENT = { 12 / 255, 210 / 255, 157 / 255 }

local MEDIA = "Interface\\AddOns\\AdventForever\\Media\\"
Theme.FONT = MEDIA .. "Inter-Regular.ttf"
Theme.FONT_BOLD = MEDIA .. "Inter-SemiBold.ttf"
Theme.ICONS = MEDIA .. "Icons\\"
Theme.LOGO = MEDIA .. "Logo"

-- A crisp 1px black outline round windows, cards, buttons and bars; cards a step
-- lighter than the window; thin dividers inside them a soft grey.
local C = {
    bg = { 0.063, 0.067, 0.075, 0.97 },
    sidebar = { 0.043, 0.047, 0.051, 1 },
    titleBar = { 0.043, 0.047, 0.051, 1 },
    card = { 0.09, 0.094, 0.106, 1 },
    border = { 0, 0, 0, 1 },
    line = { 0.165, 0.173, 0.188, 1 },
    track = { 0.141, 0.149, 0.165, 1 },
    input = { 0.04, 0.042, 0.047, 1 },
    button = { 0.106, 0.11, 0.122, 1 },
    buttonBorder = { 0, 0, 0, 1 },
    text = { 0.85, 0.855, 0.863 },
    bright = { 1, 1, 1 },
    dim = { 0.545, 0.553, 0.573 },
    faint = { 0.4, 0.41, 0.43 },
    stripe = { 1, 1, 1, 0.025 },
}
Theme.C = C

-- Response colors: text, background.
Theme.ROLE = {
    ms = { { 0.31, 0.88, 0.65 }, { 0.07, 0.23, 0.17, 1 } },
    os = { { 0.95, 0.76, 0.31 }, { 0.24, 0.19, 0.07, 1 } },
    pass = { { 0.545, 0.553, 0.573 }, { 0.149, 0.157, 0.173, 1 } },
}

-------------------------------------------------------------------------------
--  EllesmereUI bridge
-------------------------------------------------------------------------------
local skin              -- EllesmereUI's skin API while it skins us
local skinned = {}      -- every primitive we asked for, replayed when the API arrives
local accented = {}     -- regions painted in the accent color

function Theme.Accent()
    if skin and skin.GetAccentColor then return skin.GetAccentColor() end
    return DEFAULT_ACCENT[1], DEFAULT_ACCENT[2], DEFAULT_ACCENT[3]
end

local function Paint(a)
    local r, g, b = Theme.Accent()
    if a.kind == "texture" then a.region:SetColorTexture(r, g, b, a.alpha)
    elseif a.kind == "gradient" then
        -- The accent, a little lighter at the top and deeper at the bottom.
        a.region:SetTexture(WHITE)
        local top = CreateColor(math.min(1, r * 1.12 + 0.06), math.min(1, g * 1.12 + 0.06), math.min(1, b * 1.12 + 0.06), a.alpha)
        local bottom = CreateColor(r * 0.82, g * 0.82, b * 0.82, a.alpha)
        if a.region.SetGradient then
            a.region:SetGradient("VERTICAL", bottom, top)
        else
            a.region:SetColorTexture(r, g, b, a.alpha)
        end
    elseif a.kind == "vertex" then a.region:SetVertexColor(r, g, b, a.alpha)
    elseif a.kind == "border" then a.region:SetBackdropBorderColor(r, g, b, a.alpha)
    else a.region:SetTextColor(r, g, b, a.alpha) end
end

local function RepaintAccents()
    for _, a in ipairs(accented) do Paint(a) end
end

-- Paints a region in the accent color now and whenever the accent changes.
function Theme.Accented(region, alpha, kind)
    local a = { region = region, alpha = alpha or 1, kind = kind or "texture" }
    table.insert(accented, a)
    Paint(a)
end

local function Apply(entry)
    local fn = skin[entry.method]
    if not fn then return end
    local ok, err = pcall(fn, entry.frame, unpack(entry.args))
    if not ok then geterrorhandler()(err) end
    if entry.after then entry.after() end
end

-- Asks EllesmereUI to skin a frame (now, or once its API arrives).
-- after() runs once the skin is applied, to hide our own art it replaces.
local function Skin(method, frame, args, after)
    local entry = { method = method, frame = frame, args = args or {}, after = after }
    table.insert(skinned, entry)
    if skin then Apply(entry) end
end

if EllesmereUI and EllesmereUI.RegisterSkin then
    EllesmereUI.RegisterSkin("AdventForever", function(S)
        skin = S
        for _, entry in ipairs(skinned) do Apply(entry) end
        if S.OnLooksChanged then S.OnLooksChanged(RepaintAccents) end
        RepaintAccents()
    end)
end

-------------------------------------------------------------------------------
--  Basics
-------------------------------------------------------------------------------
function Theme.Backdrop(frame, bg, border)
    frame:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
    frame:SetBackdropColor(unpack(bg))
    frame:SetBackdropBorderColor(unpack(border or C.border))
end

-- Sets a font, falling back to the game's if ours can't load.
local function SetFont(region, path, size)
    region:SetFont(path, size, "")
    -- SetFont doesn't reliably report failure; check whether the font took.
    if not region:GetFont() then region:SetFont(STANDARD_TEXT_FONT, size, "") end
end
Theme.SetFont = SetFont

-- Text in Inter (SemiBold with bold = true). EllesmereUI users get their own font.
function Theme.Text(parent, size, color, layer, bold)
    local fs = parent:CreateFontString(nil, layer or "OVERLAY")
    SetFont(fs, bold and Theme.FONT_BOLD or Theme.FONT, size or 12)
    fs:SetTextColor(unpack(color or C.text))
    fs:SetShadowOffset(1, -1)
    fs:SetShadowColor(0, 0, 0, 0.6)
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    Skin("Font", fs)
    return fs
end

-- A small, dim, all-caps section label ("RAIDS", "THIS WEEK").
function Theme.Label(parent, text)
    local fs = Theme.Text(parent, 10, C.faint, nil, true)
    fs:SetText(text and text:upper() or "")
    return fs
end

-- A thin divider inside a card or window.
function Theme.Line(parent, layer)
    local t = parent:CreateTexture(nil, layer or "BORDER")
    t:SetColorTexture(unpack(C.line))
    return t
end

-- A card: a panel a step lighter than the window, with a black outline.
function Theme.Card(parent, width, height)
    local f = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    if width then f:SetSize(width, height) end
    Theme.Backdrop(f, C.card)
    f:SetFrameLevel(math.max(0, parent:GetFrameLevel()))
    Skin("Panel", f)
    return f
end

function Theme.QualityColor(link)
    local quality = link and C_Item.GetItemQualityByID and C_Item.GetItemQualityByID(link)
    local c = quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
    if c then return c.r, c.g, c.b end
    local hex = link and link:match("|c%x%x(%x%x%x%x%x%x)")
    if hex then
        return tonumber(hex:sub(1, 2), 16) / 255, tonumber(hex:sub(3, 4), 16) / 255, tonumber(hex:sub(5, 6), 16) / 255
    end
    return C.line[1], C.line[2], C.line[3]
end

-------------------------------------------------------------------------------
--  Windows
-------------------------------------------------------------------------------
local function SavePosition(f)
    AF.db.ui = AF.db.ui or {}
    local point, _, relPoint, x, y = f:GetPoint()
    AF.db.ui[f:GetName()] = { point, relPoint, x, y }
end

local function RestorePosition(f, defaultY)
    local saved = AF.db.ui and AF.db.ui[f:GetName()]
    f:ClearAllPoints()
    if saved then
        f:SetPoint(saved[1], UIParent, saved[2], saved[3], saved[4])
    else
        f:SetPoint("CENTER", UIParent, "CENTER", 0, defaultY or 0)
    end
end

-- A movable window with a title bar and close button; Escape closes it and it
-- reopens where it was left.
function Theme.Window(name, title, width, height, defaultY)
    local f = CreateFrame("Frame", name, UIParent, "BackdropTemplate")
    f:SetSize(width, height)
    f:SetFrameStrata("HIGH")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    Theme.Backdrop(f, C.bg)

    local bar = CreateFrame("Frame", nil, f)
    bar:SetPoint("TOPLEFT", 1, -1)
    bar:SetPoint("TOPRIGHT", -1, -1)
    bar:SetHeight(24)
    local barBg = bar:CreateTexture(nil, "BACKGROUND")
    barBg:SetAllPoints()
    barBg:SetColorTexture(unpack(C.titleBar))
    local barLine = bar:CreateTexture(nil, "BORDER")
    barLine:SetColorTexture(unpack(C.border))
    barLine:SetPoint("BOTTOMLEFT")
    barLine:SetPoint("BOTTOMRIGHT")
    barLine:SetHeight(1)
    bar:EnableMouse(true)
    bar:RegisterForDrag("LeftButton")
    bar:SetScript("OnDragStart", function() f:StartMoving() end)
    bar:SetScript("OnDragStop", function()
        f:StopMovingOrSizing()
        SavePosition(f)
    end)
    f.bar = bar

    f.title = Theme.Text(bar, 12, C.bright, nil, true)
    f.title:SetPoint("LEFT", 10, 0)
    f.title:SetText(title)

    local close = CreateFrame("Button", nil, bar)
    close:SetSize(24, 24)
    close:SetPoint("RIGHT")
    close.glyph = Theme.Text(close, 14, C.dim)
    close.glyph:SetPoint("CENTER", 0, 1)
    close.glyph:SetText("x")
    close:SetScript("OnEnter", function() close.glyph:SetTextColor(unpack(C.bright)) end)
    close:SetScript("OnLeave", function() close.glyph:SetTextColor(unpack(C.dim)) end)
    close:SetScript("OnClick", function() f:Hide() end)
    f.close = close

    table.insert(UISpecialFrames, name)
    RestorePosition(f, defaultY)
    f:Hide()
    Skin("Shell", f, { { noTopBar = true } })
    Skin("CloseButton", close, nil, function() close.glyph:Hide() end)
    return f
end

-------------------------------------------------------------------------------
--  Controls
-------------------------------------------------------------------------------
-- Flat button. role ("ms", "os", "pass") colors the label and border.
function Theme.Button(parent, text, width, height, role)
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    b:SetSize(width or 100, height or 22)
    local textColor, border = { 0.9, 0.9, 0.9 }, C.buttonBorder
    if role then
        textColor = Theme.ROLE[role][1]
        border = { textColor[1] * 0.45, textColor[2] * 0.45, textColor[3] * 0.45, 1 }
    end
    Theme.Backdrop(b, C.button, border)
    b.label = Theme.Text(b, 12, textColor)
    b.label:SetPoint("CENTER")
    b.label:SetText(text)
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetPoint("TOPLEFT", 1, -1)
    hl:SetPoint("BOTTOMRIGHT", -1, 1)
    hl:SetColorTexture(1, 1, 1, 0.06)
    b:SetScript("OnMouseDown", function() b.label:SetPoint("CENTER", 0, -1) end)
    b:SetScript("OnMouseUp", function() b.label:SetPoint("CENTER", 0, 0) end)
    Skin("Button", b)
    return b
end

function Theme.Check(parent, label, checked, onChange)
    local c = CreateFrame("Button", nil, parent, "BackdropTemplate")
    c:SetSize(14, 14)
    Theme.Backdrop(c, C.input, C.buttonBorder)
    c.mark = c:CreateTexture(nil, "ARTWORK")
    c.mark:SetPoint("TOPLEFT", 3, -3)
    c.mark:SetPoint("BOTTOMRIGHT", -3, 3)
    Theme.Accented(c.mark)
    c.label = Theme.Text(parent, 11, C.dim)
    c.label:SetPoint("LEFT", c, "RIGHT", 6, 0)
    c.label:SetText(label)
    c:SetHitRectInsets(0, -(c.label:GetStringWidth() + 8), 0, 0)   -- the label is clickable too
    c.checked = checked and true or false
    c.mark:SetShown(c.checked)
    c:SetScript("OnClick", function()
        c.checked = not c.checked
        c.mark:SetShown(c.checked)
        onChange(c.checked)
    end)
    return c
end

function Theme.EditBox(parent, width)
    local e = CreateFrame("EditBox", nil, parent, "BackdropTemplate")
    e:SetSize(width, 22)
    Theme.Backdrop(e, C.input, C.buttonBorder)
    SetFont(e, Theme.FONT, 12)
    e:SetTextColor(1, 1, 1)
    e:SetTextInsets(6, 6, 0, 0)
    e:SetAutoFocus(false)
    e:SetScript("OnEscapePressed", e.ClearFocus)
    e:SetScript("OnEnterPressed", e.ClearFocus)
    e:SetScript("OnEditFocusGained", function() e:SetBackdropBorderColor(Theme.Accent()) end)
    e:SetScript("OnEditFocusLost", function() e:SetBackdropBorderColor(unpack(C.buttonBorder)) end)
    Skin("EditBox", e)
    return e
end

-- Tabs along the top of a window (under its title bar). onSelect(index).
function Theme.Tabs(window, labels, onSelect)
    local tabs = { buttons = {} }
    local x = 8
    for i, label in ipairs(labels) do
        local b = CreateFrame("Button", nil, window)
        b.label = Theme.Text(b, 12, C.dim)
        b.label:SetPoint("CENTER")
        b.label:SetText(label)
        b:SetSize(b.label:GetStringWidth() + 18, 26)
        b:SetPoint("TOPLEFT", window, "TOPLEFT", x, -25)
        x = x + b:GetWidth() + 2
        b.underline = b:CreateTexture(nil, "OVERLAY")
        b.underline:SetPoint("BOTTOMLEFT", 6, 0)
        b.underline:SetPoint("BOTTOMRIGHT", -6, 0)
        b.underline:SetHeight(2)
        Theme.Accented(b.underline)
        b:SetScript("OnClick", function() tabs:Select(i) end)
        b:SetScript("OnEnter", function() if tabs.selected ~= i then b.label:SetTextColor(unpack(C.text)) end end)
        b:SetScript("OnLeave", function() if tabs.selected ~= i then b.label:SetTextColor(unpack(C.dim)) end end)
        tabs.buttons[i] = b
        Skin("Tab", b)
    end
    local line = Theme.Line(window)
    line:SetPoint("TOPLEFT", 1, -51)
    line:SetPoint("TOPRIGHT", -1, -51)
    line:SetHeight(1)

    function tabs:Select(index)
        self.selected = index
        for i, b in ipairs(self.buttons) do
            local on = i == index
            b.underline:SetShown(on)
            b.label:SetTextColor(unpack(on and C.bright or C.dim))
            if skin and skin.SetTabSelection then pcall(skin.SetTabSelection, b, on) end
        end
        onSelect(index)
    end
    return tabs
end

-------------------------------------------------------------------------------
--  Sidebar navigation (the main window)
--    items = { { page = index, label, icon = file name in Media/Icons, officer = bool }, ... }
--    in the order shown; officer items sit under an "Officers" heading and only
--    show while showOfficer() is true. onSelect(page).
-------------------------------------------------------------------------------
function Theme.Sidebar(window, items, width, onSelect, showOfficer)
    local side = CreateFrame("Frame", nil, window)
    side:SetPoint("TOPLEFT", 1, -25)
    side:SetPoint("BOTTOMLEFT", 1, 1)
    side:SetWidth(width)
    local bg = side:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(unpack(C.sidebar))
    local edge = side:CreateTexture(nil, "BORDER")
    edge:SetPoint("TOPRIGHT")
    edge:SetPoint("BOTTOMRIGHT")
    edge:SetWidth(1)
    edge:SetColorTexture(unpack(C.border))

    -- The logo block.
    local logo = side:CreateTexture(nil, "ARTWORK")
    logo:SetSize(34, 34)
    logo:SetPoint("TOPLEFT", 12, -12)
    logo:SetTexture(Theme.LOGO)
    local logoEdge = side:CreateTexture(nil, "BORDER")
    logoEdge:SetPoint("TOPLEFT", logo, -1, 1)
    logoEdge:SetPoint("BOTTOMRIGHT", logo, 1, -1)
    logoEdge:SetColorTexture(unpack(C.border))
    local name = Theme.Text(side, 13, C.bright, nil, true)
    name:SetPoint("TOPLEFT", logo, "TOPRIGHT", 9, -2)
    name:SetText("Advent")
    local sub = Theme.Text(side, 11, nil, nil, true)
    sub:SetPoint("TOPLEFT", name, "BOTTOMLEFT", 0, -2)
    sub:SetText("Forever")
    Theme.Accented(sub, 1, "text")
    local divider = Theme.Line(side)
    divider:SetPoint("TOPLEFT", 10, -58)
    divider:SetPoint("TOPRIGHT", -10, -58)
    divider:SetHeight(1)

    local nav = { buttons = {}, items = items }
    nav.heading = Theme.Label(side, "Officers")
    for _, item in ipairs(items) do
        local b = CreateFrame("Button", nil, side)
        b:SetSize(width - 1, 28)
        b.bg = b:CreateTexture(nil, "BACKGROUND")
        b.bg:SetAllPoints()
        b.bg:SetColorTexture(unpack(C.card))
        b.marker = b:CreateTexture(nil, "ARTWORK")
        b.marker:SetPoint("TOPLEFT", 0, -4)
        b.marker:SetPoint("BOTTOMLEFT", 0, 4)
        b.marker:SetWidth(2)
        Theme.Accented(b.marker)
        b.icon = b:CreateTexture(nil, "ARTWORK")
        b.icon:SetSize(16, 16)
        b.icon:SetPoint("LEFT", 14, 0)
        b.icon:SetTexture(Theme.ICONS .. item.icon)
        b.label = Theme.Text(b, 12)
        b.label:SetPoint("LEFT", b.icon, "RIGHT", 9, 0)
        b.label:SetText(item.label)
        local hl = b:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.04)
        b:SetScript("OnClick", function() nav:Select(item.page) end)
        b.item = item
        nav.buttons[item.page] = b
    end

    -- Places the visible buttons from the top (officer ones under their heading).
    function nav:Layout()
        local y, headed = -68, false
        local officer = showOfficer()
        for _, item in ipairs(self.items) do
            local b = self.buttons[item.page]
            local show = not item.officer or officer
            b:SetShown(show)
            if show then
                if item.officer and not headed then
                    headed = true
                    y = y - 10
                    self.heading:ClearAllPoints()
                    self.heading:SetPoint("TOPLEFT", side, "TOPLEFT", 14, y)
                    y = y - 18
                end
                b:ClearAllPoints()
                b:SetPoint("TOPLEFT", side, "TOPLEFT", 0, y)
                y = y - 30
            end
        end
        self.heading:SetShown(headed)
    end

    function nav:Select(page)
        self.selected = page
        for p, b in pairs(self.buttons) do
            local on = p == page
            b.bg:SetShown(on)
            b.marker:SetShown(on)
            b.label:SetTextColor(unpack(on and C.bright or C.dim))
            if on then
                local r, g, bl = Theme.Accent()
                b.icon:SetVertexColor(r, g, bl)
            else
                b.icon:SetVertexColor(unpack(C.dim))
            end
        end
        onSelect(page)
    end

    nav:Layout()
    return nav
end

-------------------------------------------------------------------------------
--  Data widgets
-------------------------------------------------------------------------------
-- Horizontal bar with a black outline and a soft gradient fill; SetValue(0..1).
-- Give it a fixed width.
function Theme.Bar(parent, width, height)
    local bar = CreateFrame("Frame", nil, parent)
    bar:SetSize(width, height or 6)
    local edge = bar:CreateTexture(nil, "BACKGROUND", nil, -1)
    edge:SetPoint("TOPLEFT", -1, 1)
    edge:SetPoint("BOTTOMRIGHT", 1, -1)
    edge:SetColorTexture(unpack(C.border))
    local track = bar:CreateTexture(nil, "BACKGROUND")
    track:SetAllPoints()
    track:SetColorTexture(unpack(C.track))
    bar.fill = bar:CreateTexture(nil, "ARTWORK")
    bar.fill:SetPoint("TOPLEFT")
    bar.fill:SetPoint("BOTTOMLEFT")
    Theme.Accented(bar.fill, 1, "gradient")
    function bar:SetValue(fraction)
        fraction = math.max(0, math.min(1, fraction))
        self.fill:SetShown(fraction > 0)
        self.fill:SetWidth(math.max(1, width * fraction))
    end
    return bar
end

-- Four mini bars, oldest week on the left, this week (brightest) on the right.
-- SetWeeks(weeks newest first, max).
function Theme.WeekBars(parent, height)
    height = height or 12
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(4 * 6 + 3 * 2, height)
    f.bars = {}
    for i = 1, 4 do
        local slot = f:CreateTexture(nil, "BACKGROUND")
        slot:SetSize(6, height)
        slot:SetPoint("BOTTOMLEFT", (i - 1) * 8, 0)
        slot:SetColorTexture(unpack(C.track))
        local bar = f:CreateTexture(nil, "ARTWORK")
        bar:SetWidth(6)
        bar:SetPoint("BOTTOMLEFT", (i - 1) * 8, 0)
        Theme.Accented(bar, i == 4 and 1 or 0.55, "gradient")
        f.bars[i] = bar
    end
    function f:SetWeeks(weeks, max)
        for i = 1, 4 do
            local value = weeks[5 - i] or 0
            local h = height * math.min(1, value / math.max(1, max))
            self.bars[i]:SetShown(h >= 0.5)
            self.bars[i]:SetHeight(math.max(1, h))
        end
    end
    return f
end

-- Small colored label. Set(text, role) or Set(nil) to hide.
function Theme.Pill(parent)
    local p = CreateFrame("Frame", nil, parent)
    p:SetHeight(15)
    p.bg = p:CreateTexture(nil, "BACKGROUND")
    p.bg:SetAllPoints()
    p.text = Theme.Text(p, 10)
    p.text:SetPoint("CENTER")
    function p:Set(text, role)
        if not text then return self:Hide() end
        self.text:SetText(text)
        self.text:SetTextColor(unpack(Theme.ROLE[role][1]))
        self.bg:SetColorTexture(unpack(Theme.ROLE[role][2]))
        self:SetWidth(self.text:GetStringWidth() + 12)
        self:Show()
    end
    return p
end

-- Item icon with a quality-colored border and the item tooltip on hover.
function Theme.ItemIcon(parent, size)
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    b:SetSize(size, size)
    Theme.Backdrop(b, { 0, 0, 0, 1 })
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetPoint("TOPLEFT", 1, -1)
    b.icon:SetPoint("BOTTOMRIGHT", -1, 1)
    b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    if b.SetPropagateMouseClicks then b:SetPropagateMouseClicks(true) end
    b:SetScript("OnEnter", function(self)
        if not self.link then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetHyperlink(self.link)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    function b:SetItem(link)
        self.link = link
        if not link then return self:Hide() end
        self.icon:SetTexture(select(5, C_Item.GetItemInfoInstant(link)) or 134400)
        self:SetBackdropBorderColor(Theme.QualityColor(link))
        self:Show()
    end
    return b
end

-- A scrolling table. opts:
--   left, top, rows, rowHeight
--   columns = { { key, label, width, justify, widget = function(row) -> region } }
--   render(row, data), onHeader(key), onRowClick(data), onRowEnter(row, data), emptyText
-- Mouse wheel scrolls; a thin thumb on the right shows where you are.
function Theme.List(parent, opts)
    local rowHeight = opts.rowHeight or 22
    local list = { data = {}, offset = 0 }
    local width = 0
    for _, col in ipairs(opts.columns) do width = width + col.width end

    list.headers = {}
    local x = 0
    for _, col in ipairs(opts.columns) do
        local h = CreateFrame("Button", nil, parent)
        h:SetSize(col.width, 20)
        h:SetPoint("TOPLEFT", parent, "TOPLEFT", opts.left + x, opts.top)
        h.label = Theme.Label(h, col.label)
        h.label:SetPoint("LEFT", 4, 0)
        h.label:SetPoint("RIGHT", -4, 0)
        h.label:SetJustifyH(col.justify or "LEFT")
        if opts.onHeader then h:SetScript("OnClick", function() opts.onHeader(col.key) end) end
        list.headers[col.key] = h
        x = x + col.width
    end
    -- The list sits on a card.
    list.card = Theme.Card(parent)
    list.card:SetPoint("TOPLEFT", parent, "TOPLEFT", opts.left - 6, opts.top + 4)
    list.card:SetSize(width + 12, 22 + opts.rows * rowHeight + 10)
    local headLine = Theme.Line(parent)
    headLine:SetPoint("TOPLEFT", parent, "TOPLEFT", opts.left, opts.top - 20)
    headLine:SetSize(width, 1)

    local body = CreateFrame("Frame", nil, parent)
    body:SetPoint("TOPLEFT", parent, "TOPLEFT", opts.left, opts.top - 22)
    body:SetSize(width, opts.rows * rowHeight)
    body:EnableMouseWheel(true)
    body:SetScript("OnMouseWheel", function(_, delta)
        list.offset = list.offset - delta * 3
        list:Update()
    end)
    list.body = body

    list.thumb = body:CreateTexture(nil, "OVERLAY")
    list.thumb:SetWidth(2)
    list.thumb:SetColorTexture(1, 1, 1, 0.3)

    list.empty = Theme.Text(body, 12, C.dim)
    list.empty:SetPoint("CENTER")
    list.empty:SetText(opts.emptyText or "")

    list.rows = {}
    for r = 1, opts.rows do
        local row = CreateFrame("Button", nil, body)
        row:SetSize(width, rowHeight)
        row:SetPoint("TOPLEFT", 0, -(r - 1) * rowHeight)
        if r % 2 == 0 then
            local stripe = row:CreateTexture(nil, "BACKGROUND")
            stripe:SetAllPoints()
            stripe:SetColorTexture(unpack(C.stripe))
        end
        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        Theme.Accented(hl, 0.12)
        row.cells = {}
        local cx = 0
        for _, col in ipairs(opts.columns) do
            local cell
            if col.widget then
                cell = col.widget(row)
                cell:SetPoint(col.justify == "RIGHT" and "RIGHT" or "LEFT", row, "LEFT",
                    col.justify == "RIGHT" and (cx + col.width - 4) or (cx + 4), 0)
            else
                cell = Theme.Text(row, 12)
                cell:SetPoint("LEFT", row, "LEFT", cx + 4, 0)
                cell:SetWidth(col.width - 8)
                cell:SetJustifyH(col.justify or "LEFT")
            end
            row.cells[col.key] = cell
            cx = cx + col.width
        end
        row:SetScript("OnClick", function(self) if self.data and opts.onRowClick then opts.onRowClick(self.data) end end)
        row:SetScript("OnEnter", function(self) if self.data and opts.onRowEnter then opts.onRowEnter(self, self.data) end end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        list.rows[r] = row
    end

    function list:Update()
        local total = #self.data
        self.offset = math.max(0, math.min(self.offset, total - opts.rows))
        for r, row in ipairs(self.rows) do
            local d = self.data[r + self.offset]
            row.data = d
            if d then opts.render(row, d); row:Show() else row:Hide() end
        end
        self.empty:SetShown(total == 0)
        if total > opts.rows then
            local h = body:GetHeight()
            local thumbH = math.max(12, h * opts.rows / total)
            self.thumb:SetHeight(thumbH)
            self.thumb:SetPoint("TOPRIGHT", body, "TOPRIGHT", 0, -(h - thumbH) * self.offset / (total - opts.rows))
            self.thumb:Show()
        else
            self.thumb:Hide()
        end
    end

    function list:SetData(data)
        self.data = data
        self:Update()
    end

    -- Highlights the sorted column's header.
    function list:MarkSorted(key)
        for k, h in pairs(self.headers) do h.label:SetTextColor(unpack(k == key and C.bright or C.faint)) end
    end
    return list
end

-- A multi-line text box in a scroll frame (export / import).
function Theme.TextArea(parent)
    local scroll = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    local holder = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    Theme.Backdrop(holder, C.input, C.buttonBorder)
    holder:SetPoint("TOPLEFT", scroll, "TOPLEFT", -6, 6)
    holder:SetPoint("BOTTOMRIGHT", scroll, "BOTTOMRIGHT", 6, -6)
    holder:SetFrameLevel(math.max(0, scroll:GetFrameLevel() - 1))
    local box = CreateFrame("EditBox", nil, scroll)
    box:SetMultiLine(true)
    box:SetMaxLetters(0)
    box:SetMaxBytes(0)
    SetFont(box, Theme.FONT, 11)
    box:SetTextColor(0.9, 0.9, 0.9)
    box:SetAutoFocus(false)
    scroll:SetScrollChild(box)
    scroll:SetScript("OnSizeChanged", function(self, w) box:SetWidth(w) end)
    scroll:SetScript("OnMouseDown", function() box:SetFocus() end)
    if scroll.ScrollBar then Skin("ScrollBar", scroll.ScrollBar) end
    return scroll, box
end
