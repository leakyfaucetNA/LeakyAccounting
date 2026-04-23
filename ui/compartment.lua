local _, ns = ...

-- AddOn compartment button handlers.
--
-- Left click  → toggle the main UI.
-- Right click → context menu with Open / Reset Character / Reset All /
--               Reset Last X Days. The three resets route through
--               StaticPopup dialogs for confirmation (Reset Last X Days
--               uses a two-step flow: enter the day count, then confirm).
--
-- Blizzard's AddonCompartmentMixin calls this function via the global
-- name registered in the TOC:
--     ## AddonCompartmentFunc: LeakyAccounting_OnCompartmentClick
-- It receives (addonName, buttonName) where buttonName is "LeftButton"
-- or "RightButton".

-- -------------------------------------------------- --
--  Static popups                                     --
-- -------------------------------------------------- --

StaticPopupDialogs["LEAKYACCOUNTING_RESET_CHAR"] = {
    text         = "Reset all tracked data for this character (%s)?\n\nThis cannot be undone.",
    button1      = YES,
    button2      = NO,
    OnAccept     = function() ns.ResetCurrentCharacter() end,
    timeout      = 0,
    whileDead    = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

StaticPopupDialogs["LEAKYACCOUNTING_RESET_ALL"] = {
    text         = "Reset ALL tracked data for EVERY character on this account?\n\nThis cannot be undone.",
    button1      = YES,
    button2      = NO,
    OnAccept     = function() ns.ResetAllCharacters() end,
    timeout      = 0,
    whileDead    = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- Two-step flow for "Reset Last X Days":
--  1. LEAKYACCOUNTING_RESET_DAYS_INPUT   — user types a day count
--  2. LEAKYACCOUNTING_RESET_DAYS_CONFIRM — user confirms the wipe
StaticPopupDialogs["LEAKYACCOUNTING_RESET_DAYS_INPUT"] = {
    text         = "Reset the last how many days of data?",
    button1      = OKAY,
    button2      = CANCEL,
    hasEditBox   = 1,
    maxLetters   = 5,
    OnShow       = function(self)
        self.editBox:SetNumeric(true)
        self.editBox:SetText("7")
        self.editBox:HighlightText()
        self.editBox:SetFocus()
    end,
    OnAccept     = function(self)
        local n = tonumber(self.editBox:GetText() or "")
        if not n or n < 1 then return end
        if n > 3650 then n = 3650 end
        local popup = StaticPopup_Show("LEAKYACCOUNTING_RESET_DAYS_CONFIRM", n)
        if popup then popup.data = n end
    end,
    EditBoxOnEnterPressed = function(self)
        local parent = self:GetParent()
        local n = tonumber(parent.editBox:GetText() or "")
        if not n or n < 1 then parent:Hide(); return end
        if n > 3650 then n = 3650 end
        parent:Hide()
        local popup = StaticPopup_Show("LEAKYACCOUNTING_RESET_DAYS_CONFIRM", n)
        if popup then popup.data = n end
    end,
    EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
    timeout      = 0,
    whileDead    = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

StaticPopupDialogs["LEAKYACCOUNTING_RESET_DAYS_CONFIRM"] = {
    text         = "Remove all tracked data from the last %d day(s) across every character?\n\nThis cannot be undone.",
    button1      = YES,
    button2      = NO,
    OnAccept     = function(self)
        local n = self.data
        if type(n) == "number" and n > 0 then ns.ResetLastDays(n) end
    end,
    timeout      = 0,
    whileDead    = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- -------------------------------------------------- --
--  Click handler (global — referenced by TOC)        --
-- -------------------------------------------------- --

function LeakyAccounting_OnCompartmentClick(_, button)
    if button == "LeftButton" then
        if ns.ToggleUI then ns.ToggleUI() end
        return
    end

    if button ~= "RightButton" then return end
    if not MenuUtil or not MenuUtil.CreateContextMenu then
        ns.lpmsg("Right-click menu requires modern retail MenuUtil API.")
        return
    end

    MenuUtil.CreateContextMenu(nil, function(_, rootDescription)
        rootDescription:CreateTitle("Leaky Accounting")
        rootDescription:CreateButton("Open", function()
            if ns.ShowUI then ns.ShowUI() end
        end)
        rootDescription:CreateDivider()
        rootDescription:CreateButton("Reset Character", function()
            StaticPopup_Show("LEAKYACCOUNTING_RESET_CHAR", ns.GetCharKey())
        end)
        rootDescription:CreateButton("Reset All", function()
            StaticPopup_Show("LEAKYACCOUNTING_RESET_ALL")
        end)
        rootDescription:CreateButton("Reset Last X Days...", function()
            StaticPopup_Show("LEAKYACCOUNTING_RESET_DAYS_INPUT")
        end)
    end)
end
