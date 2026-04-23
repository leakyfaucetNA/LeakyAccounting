local _, ns = ...

-- Settings tab: simple form for addon-wide preferences. Each entry reads
-- from / writes to `ns.addon.db.profile`. On save we call
-- ns.OnDataChanged() so any tab that depends on the setting (e.g. the
-- chart's "Last N days" row) re-renders immediately.

local T

local function ensureLayout(parent)
    T = ns.theme
    if parent._settingsLayout then return parent._settingsLayout end
    local layout = {}
    parent._settingsLayout = layout

    -- Row 1: Data window days
    local rowY = -T.PAD - 6

    local label = ns.MakeLabel(parent, "Data window (days):", 13, T.C_TEXT)
    label:SetPoint("TOPLEFT", T.PAD + 8, rowY)

    -- EditBox holder so we can frame it with our dark-track look.
    local holder = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    ns.SetBD(holder, T.C_ELEM, T.C_BDR)
    holder:SetSize(64, 22)
    holder:SetPoint("LEFT", label, "RIGHT", 10, 0)

    local eb = CreateFrame("EditBox", nil, holder)
    eb:SetPoint("TOPLEFT", 6, -3)
    eb:SetPoint("BOTTOMRIGHT", -6, 3)
    eb:SetAutoFocus(false)
    eb:SetFontObject("GameFontNormal")
    eb:SetTextColor(unpack(T.C_TEXT))
    eb:SetNumeric(true)
    eb:SetMaxLetters(4)
    eb:SetScript("OnEscapePressed", eb.ClearFocus)

    local function commit()
        local n = tonumber(eb:GetText())
        if not n or n < 1 then n = 1 end
        if n > 3650 then n = 3650 end  -- ~10 years, enough for any sane window
        ns.addon.db.profile.windowDays = n
        eb:SetText(tostring(n))
        if ns.OnDataChanged then ns.OnDataChanged() end
    end
    eb:SetScript("OnEnterPressed", function(self) commit(); self:ClearFocus() end)
    eb:SetScript("OnEditFocusLost", commit)

    local hint = ns.MakeLabel(parent,
        "Chart shows profit / deficit over this many days.", 11, T.C_DIM)
    hint:SetPoint("LEFT", holder, "RIGHT", 10, 0)

    layout.windowEdit = eb

    return layout
end

function ns.RenderSettings(parent)
    T = ns.theme
    local layout = ensureLayout(parent)
    local windowDays = (ns.addon.db.profile and ns.addon.db.profile.windowDays) or 7
    layout.windowEdit:SetText(tostring(windowDays))
end
