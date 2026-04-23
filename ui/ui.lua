local _, ns = ...

-- Main frame for LeakyAccounting. Layout mirrors LECDM: dark charcoal panels
-- with a blue accent, single title bar, and a tab bar below it. Content
-- panel is owned by the active tab module (chart.lua / itemized.lua).

-- -------------------------------------------------- --
--  Theme (same palette as LECDM settings)            --
-- -------------------------------------------------- --

local TEX      = "Interface\\Buttons\\WHITE8x8"
local C_BG     = {0.08, 0.08, 0.08, 0.95}
local C_PANEL  = {0.12, 0.12, 0.12, 1}
local C_ELEM   = {0.18, 0.18, 0.18, 1}
local C_BDR    = {0.25, 0.25, 0.25, 1}
local C_ACCENT = {0.45, 0.45, 0.95, 1}
local C_HOVER  = {0.22, 0.22, 0.22, 1}
local C_TEXT   = {0.90, 0.90, 0.90, 1}
local C_DIM    = {0.60, 0.60, 0.60, 1}
local C_GOOD   = {0.35, 0.80, 0.35, 1}
local C_BAD    = {0.85, 0.35, 0.35, 1}

local TITLE_H = 28
local TAB_H   = 32
local PAD     = 8

ns.theme = {
    TEX = TEX,
    C_BG = C_BG, C_PANEL = C_PANEL, C_ELEM = C_ELEM, C_BDR = C_BDR,
    C_ACCENT = C_ACCENT, C_HOVER = C_HOVER, C_TEXT = C_TEXT, C_DIM = C_DIM,
    C_GOOD = C_GOOD, C_BAD = C_BAD,
    TITLE_H = TITLE_H, TAB_H = TAB_H, PAD = PAD,
}

-- -------------------------------------------------- --
--  Primitive helpers                                 --
-- -------------------------------------------------- --

local function SetBD(f, bg, bdr)
    f:SetBackdrop({
        bgFile   = TEX,
        edgeFile = TEX,
        edgeSize = 1,
        insets   = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    f:SetBackdropColor(unpack(bg))
    f:SetBackdropBorderColor(unpack(bdr or C_BDR))
end

local function MakePanel(parent, bg, bdr)
    local f = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    SetBD(f, bg or C_PANEL, bdr or C_BDR)
    return f
end

local function MakeLabel(parent, text, size, color)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    if size then
        local font = fs:GetFont()
        fs:SetFont(font, size, "")
    end
    fs:SetText(text or "")
    fs:SetTextColor(unpack(color or C_TEXT))
    return fs
end

local function MakeButton(parent, text, w, h)
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    SetBD(b, C_ELEM, C_BDR)
    b:SetSize(w or 70, h or 22)
    local fs = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetPoint("CENTER")
    fs:SetText(text or "")
    fs:SetTextColor(unpack(C_TEXT))
    b.text = fs
    b:SetScript("OnEnter", function(s) s:SetBackdropColor(unpack(C_HOVER)) end)
    b:SetScript("OnLeave", function(s) s:SetBackdropColor(unpack(C_ELEM)) end)
    return b
end

local function setTabState(btn, active)
    if active then
        btn:SetBackdropColor(unpack(C_ACCENT))
        btn:SetScript("OnEnter", function(s) s:SetBackdropColor(0.55, 0.55, 1.0, 1) end)
        btn:SetScript("OnLeave", function(s) s:SetBackdropColor(unpack(C_ACCENT)) end)
        btn.text:SetTextColor(1, 1, 1, 1)
    else
        btn:SetBackdropColor(unpack(C_ELEM))
        btn:SetScript("OnEnter", function(s) s:SetBackdropColor(unpack(C_HOVER)) end)
        btn:SetScript("OnLeave", function(s) s:SetBackdropColor(unpack(C_ELEM)) end)
        btn.text:SetTextColor(unpack(C_TEXT))
    end
end

ns.MakePanel  = MakePanel
ns.MakeLabel  = MakeLabel
ns.MakeButton = MakeButton
ns.SetBD      = SetBD

-- -------------------------------------------------- --
--  Main frame                                        --
-- -------------------------------------------------- --

local frame
local activeTab = "chart"
local scope     = "char"  -- "char" | "account"
local chartContent, itemizedContent
local chartBtn, itemizedBtn
local scopeCharBtn, scopeAccountBtn

local function refresh()
    chartContent:SetShown(activeTab == "chart")
    itemizedContent:SetShown(activeTab == "itemized")
    setTabState(chartBtn,    activeTab == "chart")
    setTabState(itemizedBtn, activeTab == "itemized")
    setTabState(scopeCharBtn,    scope == "char")
    setTabState(scopeAccountBtn, scope == "account")

    if activeTab == "chart" and ns.RenderChart then
        ns.RenderChart(chartContent, scope)
    elseif activeTab == "itemized" and ns.RenderItemized then
        ns.RenderItemized(itemizedContent, scope)
    end
end

-- Re-render if we're open when data changes.
function ns.OnDataChanged()
    if frame and frame:IsShown() then refresh() end
end

local function build()
    if frame then return frame end

    frame = CreateFrame("Frame", "LeakyAccountingFrame", UIParent, "BackdropTemplate")
    frame:SetSize(760, 520)
    frame:SetPoint("CENTER")
    SetBD(frame, C_BG, C_BDR)
    frame:SetFrameStrata("HIGH")
    frame:SetMovable(true)
    frame:SetResizable(true)
    frame:SetResizeBounds(520, 320)
    frame:EnableMouse(true)
    frame:SetClampedToScreen(true)
    frame:Hide()

    -- Title bar
    local title = MakePanel(frame, C_PANEL, C_BDR)
    title:SetPoint("TOPLEFT", 0, 0)
    title:SetPoint("TOPRIGHT", 0, 0)
    title:SetHeight(TITLE_H)
    title:EnableMouse(true)
    title:RegisterForDrag("LeftButton")
    title:SetScript("OnDragStart", function() frame:StartMoving() end)
    title:SetScript("OnDragStop",  function() frame:StopMovingOrSizing() end)

    local titleText = MakeLabel(title, "Leaky Accounting", 14, C_ACCENT)
    titleText:SetPoint("LEFT", 10, 0)

    local close = MakeButton(title, "X", 24, 20)
    close:SetPoint("RIGHT", -4, 0)
    close:SetScript("OnClick", function() frame:Hide() end)

    -- Tab bar
    local tabBar = MakePanel(frame, C_PANEL, C_BDR)
    tabBar:SetPoint("TOPLEFT", 0, -TITLE_H)
    tabBar:SetPoint("TOPRIGHT", 0, -TITLE_H)
    tabBar:SetHeight(TAB_H)

    chartBtn    = MakeButton(tabBar, "Chart",    80, 22)
    chartBtn:SetPoint("LEFT", PAD, 0)
    chartBtn:SetScript("OnClick", function() activeTab = "chart" refresh() end)

    itemizedBtn = MakeButton(tabBar, "Itemized", 80, 22)
    itemizedBtn:SetPoint("LEFT", chartBtn, "RIGHT", 6, 0)
    itemizedBtn:SetScript("OnClick", function() activeTab = "itemized" refresh() end)

    -- Scope toggle (right side)
    local scopeLbl = MakeLabel(tabBar, "Scope:", 12, C_DIM)
    scopeAccountBtn = MakeButton(tabBar, "Account", 80, 22)
    scopeAccountBtn:SetPoint("RIGHT", -PAD, 0)
    scopeAccountBtn:SetScript("OnClick", function() scope = "account" refresh() end)

    scopeCharBtn = MakeButton(tabBar, "Character", 80, 22)
    scopeCharBtn:SetPoint("RIGHT", scopeAccountBtn, "LEFT", -4, 0)
    scopeCharBtn:SetScript("OnClick", function() scope = "char" refresh() end)

    scopeLbl:SetPoint("RIGHT", scopeCharBtn, "LEFT", -8, 0)

    -- Content panels (one per tab; toggled visible)
    chartContent = MakePanel(frame, C_PANEL, C_BDR)
    chartContent:SetPoint("TOPLEFT",     PAD, -(TITLE_H + TAB_H + PAD))
    chartContent:SetPoint("BOTTOMRIGHT", -PAD, PAD)

    itemizedContent = MakePanel(frame, C_PANEL, C_BDR)
    itemizedContent:SetPoint("TOPLEFT",     PAD, -(TITLE_H + TAB_H + PAD))
    itemizedContent:SetPoint("BOTTOMRIGHT", -PAD, PAD)

    -- Bottom-right resize grip
    local grip = CreateFrame("Button", nil, frame)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", -2, 2)
    grip:SetFrameLevel(frame:GetFrameLevel() + 10)
    grip:EnableMouse(true)
    local gripTex = grip:CreateTexture(nil, "OVERLAY")
    gripTex:SetTexture(TEX)
    gripTex:SetAllPoints(grip)
    gripTex:SetVertexColor(unpack(C_BDR))
    grip:SetScript("OnEnter", function() gripTex:SetVertexColor(unpack(C_ACCENT)) end)
    grip:SetScript("OnLeave", function() gripTex:SetVertexColor(unpack(C_BDR))    end)
    grip:SetScript("OnMouseDown", function(_, button)
        if button == "LeftButton" then frame:StartSizing("BOTTOMRIGHT") end
    end)
    grip:SetScript("OnMouseUp", function() frame:StopMovingOrSizing() end)

    -- Re-render active tab when the frame is resized
    frame:SetScript("OnSizeChanged", function() refresh() end)
    frame:SetScript("OnShow", refresh)
    return frame
end

-- -------------------------------------------------- --
--  Public API                                        --
-- -------------------------------------------------- --

function ns.ToggleUI()
    local f = build()
    if f:IsShown() then f:Hide() else f:Show() end
end

function ns.ShowUI()
    build():Show()
end
