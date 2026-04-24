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

-- Styled Slider used for both horizontal and vertical scrollbars so every
-- panel that needs scrolling shares the same dark-track / blue-thumb look.
local SCROLLBAR_W = 12
local function MakeScrollbar(parent, orientation)
    local s = CreateFrame("Slider", nil, parent, "BackdropTemplate")
    s:SetOrientation(orientation)
    if orientation == "HORIZONTAL" then
        s:SetHeight(SCROLLBAR_W)
    else
        s:SetWidth(SCROLLBAR_W)
    end
    SetBD(s, C_ELEM, C_BDR)
    local thumb = s:CreateTexture(nil, "OVERLAY")
    thumb:SetTexture(TEX)
    if orientation == "HORIZONTAL" then
        thumb:SetSize(40, SCROLLBAR_W - 4)
    else
        thumb:SetSize(SCROLLBAR_W - 4, 40)
    end
    thumb:SetVertexColor(unpack(C_ACCENT))
    s:SetThumbTexture(thumb)
    s:SetMinMaxValues(0, 0)
    s:SetValueStep(1)
    s:SetObeyStepOnDrag(false)
    s:SetValue(0)
    s:Hide()
    return s
end

ns.MakePanel     = MakePanel
ns.MakeLabel     = MakeLabel
ns.MakeButton    = MakeButton
ns.MakeScrollbar = MakeScrollbar
ns.SetBD         = SetBD
ns.SCROLLBAR_W   = SCROLLBAR_W

-- -------------------------------------------------- --
--  Main frame                                        --
-- -------------------------------------------------- --

local frame
local activeTab = "chart"
local scope     = "char"  -- "char" | "account"
local chartContent, itemizedContent, charactersContent
local chartBtn, itemizedBtn, charactersBtn
local scopeCharBtn, scopeAccountBtn, scopeLbl

local function refresh()
    chartContent:SetShown(activeTab == "chart")
    itemizedContent:SetShown(activeTab == "itemized")
    charactersContent:SetShown(activeTab == "characters")
    setTabState(chartBtn,      activeTab == "chart")
    setTabState(itemizedBtn,   activeTab == "itemized")
    setTabState(charactersBtn, activeTab == "characters")
    setTabState(scopeCharBtn,    scope == "char")
    setTabState(scopeAccountBtn, scope == "account")

    -- Scope toggle only applies to tabs that can render per-char vs account.
    local showScope = (activeTab == "chart") or (activeTab == "itemized")
    scopeLbl:SetShown(showScope)
    scopeCharBtn:SetShown(showScope)
    scopeAccountBtn:SetShown(showScope)

    if activeTab == "chart" and ns.RenderChart then
        ns.RenderChart(chartContent, scope)
    elseif activeTab == "itemized" and ns.RenderItemized then
        ns.RenderItemized(itemizedContent, scope)
    elseif activeTab == "characters" and ns.RenderCharacters then
        ns.RenderCharacters(charactersContent)
    end
end

-- Re-render if we're open when data changes.
function ns.OnDataChanged()
    if frame and frame:IsShown() then refresh() end
end

local function build()
    if frame then return frame end

    frame = CreateFrame("Frame", "LeakyAccountingFrame", UIParent, "BackdropTemplate")

    -- Restore the last persisted window size (per profile) if one exists.
    local saved = ns.addon.db and ns.addon.db.profile
    local w = (saved and saved.frameWidth)  or 760
    local h = (saved and saved.frameHeight) or 520
    frame:SetSize(w, h)
    frame:SetPoint("CENTER")
    SetBD(frame, C_BG, C_BDR)
    frame:SetFrameStrata("HIGH")
    frame:SetMovable(true)
    frame:SetResizable(true)
    frame:SetResizeBounds(520, 320)
    frame:EnableMouse(true)
    frame:SetClampedToScreen(true)
    frame:Hide()

    -- Closing on Escape: the standard WoW pattern is to add the frame's
    -- global name to UISpecialFrames. The UI then hides the first visible
    -- entry in that list before opening the game menu.
    tinsert(UISpecialFrames, "LeakyAccountingFrame")

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

    -- UI scale slider in the title bar, left of the close button. The
    -- percent readout to the left is click-to-edit; applies immediately
    -- on commit. The slider only applies scale when the mouse is
    -- released, otherwise continuous SetScale during drag flashes the
    -- frame on every tick.
    local scaleSlider = MakeScrollbar(title, "HORIZONTAL")
    scaleSlider:SetSize(100, 12)
    scaleSlider:SetPoint("RIGHT", close, "LEFT", -10, 0)
    scaleSlider:Show()
    scaleSlider:SetMinMaxValues(0.5, 2.0)
    scaleSlider:SetValueStep(0.05)
    scaleSlider:SetObeyStepOnDrag(false)
    do
        local thumb = scaleSlider:GetThumbTexture()
        if thumb then thumb:SetSize(16, 8) end
    end

    -- Click-to-edit percent readout: Button with a FontString by default,
    -- swaps to an EditBox holder on click for manual entry.
    local scaleBtn = CreateFrame("Button", nil, title)
    scaleBtn:SetSize(42, 16)
    scaleBtn:SetPoint("RIGHT", scaleSlider, "LEFT", -6, 0)
    local scaleLbl = scaleBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    scaleLbl:SetAllPoints(scaleBtn)
    scaleLbl:SetJustifyH("RIGHT")
    scaleLbl:SetTextColor(unpack(C_DIM))
    scaleBtn:SetScript("OnEnter", function() scaleLbl:SetTextColor(unpack(C_ACCENT)) end)
    scaleBtn:SetScript("OnLeave", function() scaleLbl:SetTextColor(unpack(C_DIM))    end)

    local scaleEditHolder = CreateFrame("Frame", nil, title, "BackdropTemplate")
    SetBD(scaleEditHolder, C_ELEM, C_BDR)
    scaleEditHolder:SetSize(48, 18)
    scaleEditHolder:SetPoint("RIGHT", scaleSlider, "LEFT", -6, 0)
    scaleEditHolder:Hide()
    local scaleEdit = CreateFrame("EditBox", nil, scaleEditHolder)
    scaleEdit:SetPoint("TOPLEFT", 4, -2)
    scaleEdit:SetPoint("BOTTOMRIGHT", -4, 2)
    scaleEdit:SetAutoFocus(false)
    scaleEdit:SetFontObject("GameFontNormalSmall")
    scaleEdit:SetTextColor(unpack(C_TEXT))
    scaleEdit:SetNumeric(true)
    scaleEdit:SetMaxLetters(4)

    -- Re-entry guard: applyScale calls SetValue on the slider which
    -- itself fires OnValueChanged; without the guard we'd recurse.
    local applying = false
    local function applyScale(val)
        if applying then return end
        applying = true
        if val < 0.5 then val = 0.5 elseif val > 2.0 then val = 2.0 end
        frame:SetScale(val)
        scaleSlider:SetValue(val)
        scaleLbl:SetText(string.format("%d%%", math.floor(val * 100 + 0.5)))
        if ns.addon.db and ns.addon.db.profile then
            ns.addon.db.profile.frameScale = val
        end
        applying = false
    end

    local savedScale = (ns.addon.db and ns.addon.db.profile and ns.addon.db.profile.frameScale) or 1.0
    applyScale(savedScale)

    -- Slider: update the readout every tick so the user sees the target
    -- value live, but defer the actual SetScale via a debounce. While
    -- the user drags (continuous OnValueChanged) we keep rescheduling,
    -- so SetScale only fires once — 100ms after the last change. Using
    -- a debounce instead of OnMouseDown/Up because Slider frames don't
    -- reliably surface those events (native thumb drag consumes them).
    local pendingTimer
    scaleSlider:SetScript("OnValueChanged", function(_, value)
        scaleLbl:SetText(string.format("%d%%", math.floor(value * 100 + 0.5)))
        if applying then return end
        if pendingTimer then pendingTimer:Cancel() end
        pendingTimer = C_Timer.NewTimer(0.1, function()
            pendingTimer = nil
            applyScale(value)
        end)
    end)

    -- Click-to-edit flow
    local function closeEdit()
        scaleEditHolder:Hide()
        scaleBtn:Show()
    end
    local function commitEdit(self)
        local n = tonumber(self:GetText() or "")
        if n then applyScale(n / 100) end
        self:ClearFocus()
        closeEdit()
    end
    scaleEdit:SetScript("OnEnterPressed",   commitEdit)
    scaleEdit:SetScript("OnEditFocusLost",  commitEdit)
    scaleEdit:SetScript("OnEscapePressed",  function(self) self:ClearFocus(); closeEdit() end)

    scaleBtn:SetScript("OnClick", function()
        scaleBtn:Hide()
        scaleEditHolder:Show()
        scaleEdit:SetText(tostring(math.floor(frame:GetScale() * 100 + 0.5)))
        scaleEdit:SetFocus()
        scaleEdit:HighlightText()
    end)

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

    charactersBtn = MakeButton(tabBar, "Characters", 90, 22)
    charactersBtn:SetPoint("LEFT", itemizedBtn, "RIGHT", 6, 0)
    charactersBtn:SetScript("OnClick", function() activeTab = "characters" refresh() end)

    -- Scope toggle (right side)
    scopeLbl = MakeLabel(tabBar, "Scope:", 12, C_DIM)
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

    charactersContent = MakePanel(frame, C_PANEL, C_BDR)
    charactersContent:SetPoint("TOPLEFT",     PAD, -(TITLE_H + TAB_H + PAD))
    charactersContent:SetPoint("BOTTOMRIGHT", -PAD, PAD)

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

    -- Re-render active tab when the frame is resized, and persist the
    -- new dimensions so they survive /reload and new sessions.
    frame:SetScript("OnSizeChanged", function(self)
        refresh()
        if ns.addon.db and ns.addon.db.profile then
            ns.addon.db.profile.frameWidth  = math.floor(self:GetWidth()  + 0.5)
            ns.addon.db.profile.frameHeight = math.floor(self:GetHeight() + 0.5)
        end
    end)
    frame:SetScript("OnShow", refresh)

    -- When the frame hides, belt-and-suspenders-Hide the tab content panels
    -- so any scroll / slider descendants follow (a few Slider children in
    -- retail don't reliably cascade-hide via parent visibility alone).
    -- Also hide GameTooltip so hover state doesn't leave it floating.
    frame:SetScript("OnHide", function()
        GameTooltip:Hide()
        if chartContent      then chartContent:Hide()      end
        if itemizedContent   then itemizedContent:Hide()   end
        if charactersContent then charactersContent:Hide() end
    end)

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
