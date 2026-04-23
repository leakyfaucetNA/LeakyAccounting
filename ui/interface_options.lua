local _, ns = ...

-- ESC → Options → AddOns integration.
--
-- Groups every "Leaky *" addon under a shared top-level category named
-- "Leaky Addons", with each addon appearing as a subcategory. The parent
-- is cached on a global (`_G.LeakyAddonsSettingsCategory`) so any other
-- Leaky addon that loads before or after this one can reuse it instead
-- of duplicating the group.
--
-- Registration uses the modern retail Settings API:
--   Settings.RegisterVerticalLayoutCategory  (parent — empty display)
--   Settings.RegisterAddOnCategory           (puts it in the AddOns tab)
--   Settings.RegisterCanvasLayoutSubcategory (this addon's panel)

local GROUP_NAME = "Leaky Addons"
local SUB_NAME   = "Accounting"

-- -------------------------------------------------- --
--  Panel content                                     --
-- -------------------------------------------------- --

local function buildPanel()
    local frame = CreateFrame("Frame")
    frame:Hide()
    frame:SetScript("OnShow", function(self)
        if self._built then return end
        self._built = true

        local T = ns.theme

        local title = ns.MakeLabel(self, "Leaky Accounting", 16, T.C_ACCENT)
        title:SetPoint("TOPLEFT", 16, -16)

        local hint = ns.MakeLabel(self,
            "Open the main window with /la or /lacc, or the button below.",
            12, T.C_DIM)
        hint:SetPoint("TOPLEFT", 16, -40)

        local openBtn = CreateFrame("Button", nil, self, "UIPanelButtonTemplate")
        openBtn:SetSize(200, 26)
        openBtn:SetPoint("TOPLEFT", 16, -64)
        openBtn:SetText("Open Leaky Accounting")
        openBtn:SetScript("OnClick", function()
            if ns.ShowUI then ns.ShowUI() end
        end)
    end)
    return frame
end

-- -------------------------------------------------- --
--  Registration                                      --
-- -------------------------------------------------- --

local function register()
    if not Settings or not Settings.RegisterCanvasLayoutSubcategory then
        return  -- Midnight / modern retail only
    end

    -- Share the parent across every Leaky addon. First one in creates it;
    -- later ones reuse via the global.
    local parent = _G.LeakyAddonsSettingsCategory
    if not parent then
        parent = Settings.RegisterVerticalLayoutCategory(GROUP_NAME)
        Settings.RegisterAddOnCategory(parent)
        _G.LeakyAddonsSettingsCategory = parent
    end

    Settings.RegisterCanvasLayoutSubcategory(parent, buildPanel(), SUB_NAME)
end

-- Delay registration until PLAYER_LOGIN so all addon globals (and ns.theme
-- from ui.lua) are ready to be consumed by the panel on first show.
local boot = CreateFrame("Frame")
boot:RegisterEvent("PLAYER_LOGIN")
boot:SetScript("OnEvent", function(self)
    self:UnregisterAllEvents()
    register()
end)
