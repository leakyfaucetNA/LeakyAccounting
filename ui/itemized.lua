local _, ns = ...

-- Itemized transaction table with:
--   * search box (filters across name, source, other, char, date)
--   * click-to-sort headers (first click desc, second asc)
--   * drag-to-resize column widths
--
-- Session state (sort key/dir, column widths, search text) lives in a
-- module-local table — it persists while the player is logged in, across
-- show/hide of the UI and across scope toggles, but is wiped on /reload
-- because module-locals reset then.

local T
local ROW_H     = 20
local COL_PAD   = 6
local MIN_COL_W = 30
local HEADER_H  = 22
local GRIP_W    = 4
local SEARCH_H  = 24
local HSCROLL_H = 12
local TOTALS_H  = 28
local WINDOW_H  = 24

-- -------------------------------------------------- --
--  Session state                                     --
-- -------------------------------------------------- --

-- Friendly Source labels the user sees in the Source column. Each maps to
-- one or more raw `source` values in the DB via ns.FormatSource — the
-- filter matches on the friendly label so "Trade" catches trade /
-- trade-pay / trade-receive in one click.
local FILTER_CATEGORIES = { "Vendor", "Auction", "Trade", "Repair", "Mail" }

-- Buy/Sell filter categories — match against `t.kind` (lowercased) via a
-- mapping. Stored under state.filterKinds with the friendly label as key
-- so it shares the same shape as filterSources.
local KIND_CATEGORIES = { "Buy", "Sell" }

-- Default filter state = every category enabled (nothing filtered out).
-- Unchecking a category narrows the list. Emptying all categories hides
-- everything — consistent "checkbox = allowed" semantics.
local function defaultFilterSources()
    local t = {}
    for _, c in ipairs(FILTER_CATEGORIES) do t[c] = true end
    return t
end
local function defaultFilterKinds()
    local t = {}
    for _, c in ipairs(KIND_CATEGORIES) do t[c] = true end
    return t
end

local session = {
    char    = { sortKey = "date", sortDir = "desc", widths = {}, search = "", windowDays = 7,
                filterSources = defaultFilterSources(), filterKinds = defaultFilterKinds() },
    account = { sortKey = "date", sortDir = "desc", widths = {}, search = "", windowDays = 7,
                filterSources = defaultFilterSources(), filterKinds = defaultFilterKinds() },
}

-- Debounce render calls that come from fast-firing input events (search
-- keystrokes, window-days typing). One shared timer collapses a burst of
-- keystrokes into a single RenderItemized call.
local pendingRender
local function scheduleRender(parent, scope)
    if pendingRender then pendingRender:Cancel() end
    pendingRender = C_Timer.NewTimer(0.15, function()
        pendingRender = nil
        ns.RenderItemized(parent, scope)
    end)
end

-- -------------------------------------------------- --
--  Item-info resolver                                --
-- -------------------------------------------------- --

-- Resolves a transaction's item-link (colored hyperlink) lazily:
--   * itemLink present → use it (already colored via |c escapes)
--   * itemName only    → C_Item.GetItemInfo(name) returns the link once the
--     client caches the item. Returns (link, quality) or (nil, nil) if not
--     yet cached. On cache miss, GET_ITEM_INFO_RECEIVED fires later and we
--     re-render the whole view.
local function resolveItemLink(txn)
    if txn.itemLink then return txn.itemLink end
    if txn.itemName and txn.itemName ~= "" then
        local _, link = C_Item.GetItemInfo(txn.itemName)
        return link
    end
end

-- Returns an inline atlas markup for the crafted-quality tier (1–5), or nil.
-- Uses C_TradeSkillUI.GetItemCraftedQualityInfo().iconChat; same pattern the
-- Blizzard auction-house UI uses to show tier stars on items.
local function craftedQualityMarkup(link)
    if not link then return nil end
    if not C_TradeSkillUI or not C_TradeSkillUI.GetItemCraftedQualityInfo then return nil end
    local info = C_TradeSkillUI.GetItemCraftedQualityInfo(link)
    if not info or not info.iconChat then return nil end
    return CreateAtlasMarkup(info.iconChat, 17, 15, 1, 0)
end

-- Resolve async item-info events and trigger a UI refresh if the frame is
-- showing. Debounced to one refresh per 0.25s so a flurry of events on
-- login doesn't hammer the renderer.
do
    local pending = false
    local f = CreateFrame("Frame")
    f:RegisterEvent("GET_ITEM_INFO_RECEIVED")
    f:SetScript("OnEvent", function()
        if pending then return end
        pending = true
        C_Timer.After(0.25, function()
            pending = false
            if ns.OnDataChanged then ns.OnDataChanged() end
        end)
    end)
end

-- -------------------------------------------------- --
--  Column definitions                                --
-- -------------------------------------------------- --

local function stripLink(link)
    -- "|cffffffff|Hitem:…|hFoo|h|r" → "Foo"
    local plain = link:gsub("|c%x%x%x%x%x%x%x%x", "")
    plain = plain:gsub("|H.-|h(.-)|h", "%1")
    plain = plain:gsub("|r", "")
    return plain
end

local function itemSortVal(t)
    if t.itemName then return t.itemName:lower() end
    if t.itemLink then return stripLink(t.itemLink):lower() end
    return ""
end

local function buildColumns(scope)
    local cols = {}
    local function add(def) cols[#cols + 1] = def end

    add {
        key = "date", label = "Date", w = 100,
        render  = function(t) return date("%m/%d %H:%M", t.t), T.C_DIM end,
        sortVal = function(t) return t.t end,
    }
    if scope == "account" then
        add {
            key = "char", label = "Char", w = 80,
            render  = function(t) return t._char or "", T.C_TEXT end,
            sortVal = function(t) return (t._char or ""):lower() end,
        }
    end
    add {
        key = "kind", label = "Kind", w = 44,
        render = function(t)
            if t.kind == "sell" then return "Sell", T.C_GOOD end
            return "Buy", T.C_BAD
        end,
        sortVal = function(t) return t.kind or "" end,
    }
    add {
        key = "source", label = "Source", w = 96,
        render  = function(t) return ns.FormatSource(t.source), T.C_DIM end,
        sortVal = function(t) return ns.FormatSource(t.source):lower() end,
    }
    add {
        key = "item", label = "Item", w = 220,
        render  = function(t)
            local link    = resolveItemLink(t)
            local display = link or t.itemName or "?"
            local tier    = craftedQualityMarkup(link)
            if tier then display = display .. " " .. tier end
            return display, nil
        end,
        sortVal = itemSortVal,
    }
    add {
        key = "qty", label = "Qty", w = 40, justify = "CENTER",
        render  = function(t) return tostring(t.qty or 1), T.C_TEXT end,
        sortVal = function(t) return t.qty or 1 end,
    }
    add {
        key = "unit", label = "Unit", w = 90, justify = "RIGHT",
        render  = function(t) return ns.FormatMoney(t.unitPrice or 0), nil end,
        sortVal = function(t) return t.unitPrice or 0 end,
    }
    add {
        key = "total", label = "Total", w = 100, justify = "RIGHT",
        render  = function(t) return ns.FormatMoney((t.unitPrice or 0) * (t.qty or 1)), nil end,
        sortVal = function(t) return (t.unitPrice or 0) * (t.qty or 1) end,
    }
    if scope == "char" then
        add {
            key = "other", label = "Other", w = 100,
            -- Show Other for direct trades (trade window, COD item,
            -- trade-gold in/out) and for guild-funded repairs. Vendors,
            -- auction, plain mail gold, and self-paid repairs have no
            -- meaningful counterparty so we leave the cell blank there.
            -- "Guild Repair" is rendered from a fixed string; the
            -- actual value isn't stored on guild-repair money entries.
            render = function(t)
                local src = t.source or ""
                if src == "guild-repair" then return "Guild Repair", T.C_DIM end
                if src == "trade" or src:match("^trade%-") then
                    return t.otherPlayer or "", T.C_DIM
                end
                return "", T.C_DIM
            end,
            sortVal = function(t)
                local src = t.source or ""
                if src == "guild-repair" then return "guild repair" end
                if src == "trade" or src:match("^trade%-") then
                    return (t.otherPlayer or ""):lower()
                end
                return ""
            end,
        }
    end
    return cols
end

-- -------------------------------------------------- --
--  Filter / sort                                     --
-- -------------------------------------------------- --

local function filterTxns(txns, query, windowDays, filterSources, filterKinds)
    local q       = (query and query ~= "") and query:lower() or nil
    local cutoff  = (windowDays and windowDays > 0) and (time() - windowDays * 86400) or nil

    -- Determine whether each filter set is actually narrowing the list.
    -- If every category in a set is checked, we can skip its per-row check.
    local useSrc = false
    if filterSources then
        for _, cat in ipairs(FILTER_CATEGORIES) do
            if not filterSources[cat] then useSrc = true; break end
        end
    end
    local useKind = false
    if filterKinds then
        for _, cat in ipairs(KIND_CATEGORIES) do
            if not filterKinds[cat] then useKind = true; break end
        end
    end
    if not q and not cutoff and not useSrc and not useKind then return txns end

    local out = {}
    for _, t in ipairs(txns) do
        local pass = true
        if cutoff and t.t and t.t < cutoff then pass = false end
        if pass and useSrc then
            if not filterSources[ns.FormatSource(t.source)] then pass = false end
        end
        if pass and useKind then
            local label = (t.kind == "sell") and "Sell" or (t.kind == "buy") and "Buy" or nil
            if not label or not filterKinds[label] then pass = false end
        end
        if pass and q then
            local hay = table.concat({
                t.itemName or "",
                t.itemLink and stripLink(t.itemLink) or "",
                t.otherPlayer or "",
                t.source or "",
                ns.FormatSource(t.source),
                t.kind or "",
                t._char or "",
                date("%m/%d", t.t),
                date("%Y-%m-%d %H:%M", t.t),
            }, " "):lower()
            if not hay:find(q, 1, true) then pass = false end
        end
        if pass then out[#out + 1] = t end
    end
    return out
end

local function sortTxns(txns, cols, sortKey, sortDir)
    local col
    for _, c in ipairs(cols) do
        if c.key == sortKey then col = c; break end
    end
    if not col then col = cols[1] end
    local sv = col.sortVal
    local desc = (sortDir == "desc")
    table.sort(txns, function(a, b)
        local av, bv = sv(a), sv(b)
        if av == bv then
            -- Stable secondary sort on time desc
            return a.t > b.t
        end
        if desc then return av > bv else return av < bv end
    end)
end

-- -------------------------------------------------- --
--  Layout application (widths / positions)           --
-- -------------------------------------------------- --

local function widthFor(state, col)
    return state.widths[col.key] or col.w
end

local function layoutHeaderAndRows(layout)
    local x = COL_PAD
    for _, col in ipairs(layout.cols) do
        local w = widthFor(layout.state, col)
        local cell = layout.headerCells[col.key]
        cell:ClearAllPoints()
        cell:SetPoint("LEFT", layout.header, "LEFT", x, 0)
        cell:SetSize(w, HEADER_H)
        cell.text:SetWidth(w - 12)  -- leave room for sort arrow
        local grip = layout.grips[col.key]
        grip:ClearAllPoints()
        grip:SetPoint("LEFT", layout.header, "LEFT", x + w - math.floor(GRIP_W / 2), 0)
        grip:SetSize(GRIP_W, HEADER_H)
        x = x + w + COL_PAD
    end

    -- Total column width; header & content share this width so the rows
    -- line up with the header as they scroll horizontally.
    local visibleW = layout.scroll:GetWidth()
    if visibleW <= 0 then visibleW = 1 end
    local contentW = math.max(x, visibleW)
    layout.header:SetWidth(contentW)
    layout.content:SetWidth(contentW)

    -- Horizontal scrollbar range
    local maxScroll = math.max(0, contentW - visibleW)
    layout.hscroll:SetMinMaxValues(0, maxScroll)
    if maxScroll <= 0 then
        layout.hscroll:SetValue(0)
        layout.hscroll:Hide()
        layout.scroll:SetHorizontalScroll(0)
        layout.headerScroll:SetHorizontalScroll(0)
    else
        layout.hscroll:Show()
        local cur = layout.hscroll:GetValue()
        if cur > maxScroll then layout.hscroll:SetValue(maxScroll) end
    end

    -- Vertical scrollbar range (content height set by RenderItemized)
    local visibleH = layout.scroll:GetHeight()
    local contentH = layout.content:GetHeight()
    local maxV = math.max(0, contentH - visibleH)
    layout.vscroll:SetMinMaxValues(0, maxV)
    if maxV <= 0 then
        layout.vscroll:SetValue(0)
        layout.vscroll:Hide()
        layout.scroll:SetVerticalScroll(0)
    else
        layout.vscroll:Show()
        local curV = layout.vscroll:GetValue()
        if curV > maxV then layout.vscroll:SetValue(maxV) end
    end

    for _, row in ipairs(layout.rows) do
        if row:IsShown() then
            local rx = COL_PAD
            for _, col in ipairs(layout.cols) do
                local w = widthFor(layout.state, col)
                local fs = row.fs[col.key]
                if fs then
                    fs:ClearAllPoints()
                    fs:SetPoint("LEFT", row, "LEFT", rx, 0)
                    fs:SetWidth(w)
                    fs:SetJustifyH(col.justify or "LEFT")
                end
                -- Tooltip / shift-click hitbox sits over the item cell.
                if col.key == "item" and row.itemHitbox then
                    row.itemHitbox:ClearAllPoints()
                    row.itemHitbox:SetPoint("LEFT", row, "LEFT", rx, 0)
                    row.itemHitbox:SetSize(w, ROW_H)
                end
                rx = rx + w + COL_PAD
            end
        end
    end
end

local function updateHeaderArrows(layout)
    for _, col in ipairs(layout.cols) do
        local cell = layout.headerCells[col.key]
        if col.key == layout.state.sortKey then
            cell.arrow:SetText(layout.state.sortDir == "desc" and "v" or "^")
            cell.arrow:Show()
        else
            cell.arrow:Hide()
        end
    end
end

-- -------------------------------------------------- --
--  Header / grip / search builders                   --
-- -------------------------------------------------- --

local function makeHeaderCell(parent, col, onClick)
    T = ns.theme
    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    btn:SetHeight(HEADER_H)
    btn:RegisterForClicks("LeftButtonUp")

    local text = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    text:SetPoint("LEFT", 0, 0)
    text:SetJustifyH(col.justify or "LEFT")
    text:SetText(col.label)
    text:SetTextColor(unpack(T.C_ACCENT))
    btn.text = text

    local arrow = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    arrow:SetPoint("RIGHT", -2, 0)
    arrow:SetTextColor(unpack(T.C_ACCENT))
    arrow:Hide()
    btn.arrow = arrow

    btn:SetScript("OnEnter", function() text:SetTextColor(1, 1, 1, 1) end)
    btn:SetScript("OnLeave", function() text:SetTextColor(unpack(T.C_ACCENT)) end)
    btn:SetScript("OnClick", function() onClick(col) end)
    return btn
end

local function makeResizeGrip(parent, onDrag)
    T = ns.theme
    local grip = CreateFrame("Frame", nil, parent)
    grip:EnableMouse(true)
    grip:SetFrameLevel(parent:GetFrameLevel() + 5)

    -- Subtle visible tick so users discover the handle
    local tex = grip:CreateTexture(nil, "OVERLAY")
    tex:SetTexture(T.TEX)
    tex:SetAllPoints(grip)
    tex:SetVertexColor(0.35, 0.35, 0.55, 0)
    grip.tex = tex

    grip:SetScript("OnEnter", function(s)
        s.tex:SetVertexColor(0.45, 0.45, 0.95, 0.6)
        SetCursor("Interface\\Cursor\\UI-Cursor-SizeRight")
    end)
    grip:SetScript("OnLeave", function(s)
        if not s.dragging then s.tex:SetVertexColor(0.35, 0.35, 0.55, 0) end
        SetCursor(nil)
    end)

    grip:SetScript("OnMouseDown", function(s, button)
        if button ~= "LeftButton" then return end
        s.dragging = true
        s.startCursorX = (GetCursorPosition())
        s.startWidth   = onDrag("begin")
    end)
    grip:SetScript("OnMouseUp", function(s)
        if s.dragging then
            s.dragging = false
            onDrag("end")
            s.tex:SetVertexColor(0.35, 0.35, 0.55, 0)
        end
    end)
    grip:SetScript("OnUpdate", function(s)
        if not s.dragging then return end
        local cursorX = (GetCursorPosition())
        local scale = s:GetEffectiveScale()
        local deltaPx = (cursorX - s.startCursorX) / scale
        onDrag("update", s.startWidth + deltaPx)
    end)

    return grip
end

local function makeSearchBox(parent, onChanged)
    T = ns.theme
    local holder = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    ns.SetBD(holder, T.C_ELEM, T.C_BDR)
    holder:SetHeight(SEARCH_H)

    local lbl = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lbl:SetText("Search:")
    lbl:SetTextColor(unpack(T.C_DIM))

    local eb = CreateFrame("EditBox", nil, holder)
    eb:SetPoint("TOPLEFT", 6, -3)
    eb:SetPoint("BOTTOMRIGHT", -6, 3)
    eb:SetAutoFocus(false)
    eb:SetFontObject("GameFontNormalSmall")
    eb:SetTextColor(unpack(T.C_TEXT))
    eb:SetScript("OnEscapePressed", eb.ClearFocus)
    eb:SetScript("OnEnterPressed",  eb.ClearFocus)
    eb:SetScript("OnTextChanged", function(s, userInput)
        if userInput then onChanged(s:GetText()) end
    end)

    holder.editBox = eb
    holder.label   = lbl
    return holder
end

-- -------------------------------------------------- --
--  Row pool                                          --
-- -------------------------------------------------- --

local function itemHitboxEnter(self)
    local link = self._itemLink
    if not link and self._itemName then
        _, link = C_Item.GetItemInfo(self._itemName)
    end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    if link then
        GameTooltip:SetHyperlink(link)
    elseif self._itemName then
        GameTooltip:SetText(self._itemName, 1, 1, 1)
    end
    GameTooltip:Show()
end

local function itemHitboxLeave()
    GameTooltip:Hide()
end

-- -------------------------------------------------- --
--  Delete popups                                     --
-- -------------------------------------------------- --

StaticPopupDialogs["LEAKYACCOUNTING_DELETE_ENTRY"] = {
    text         = "Delete this entry?\n\n%s",
    button1      = YES,
    button2      = NO,
    OnAccept     = function(self)
        local src = self.data
        if src and ns.DeleteRecord then ns.DeleteRecord(src) end
    end,
    timeout      = 0,
    whileDead    = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

StaticPopupDialogs["LEAKYACCOUNTING_DELETE_ALL_ITEM"] = {
    text         = "Delete ALL entries for %s across every character?\n\nThis cannot be undone.",
    button1      = YES,
    button2      = NO,
    OnAccept     = function(self)
        local src = self.data
        if src and ns.DeleteAllMatchingItem then
            local n = ns.DeleteAllMatchingItem(src)
            ns.lpmsg("Deleted " .. n .. " matching entries.")
        end
    end,
    timeout      = 0,
    whileDead    = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- Strip color / hyperlink markup so the popup title fits the standard
-- popup font (which ignores |c / |H anyway when embedded via format).
local function plainItemName(src)
    if not src then return "item" end
    if src.itemName then return src.itemName end
    if src.itemLink then return stripLink(src.itemLink) end
    return "item"
end

-- Styled context menu. `items` is an array of descriptors:
--   { kind = "title",  text = "Foo" }
--   { kind = "button", text = "Delete", onClick = function() ... end }
-- Pooled singleton — the menu Frame, its catcher, and a reusable row
-- pool are created once and reshown on subsequent calls. This matters
-- because WoW can't actually free Frame objects, so creating a new
-- menu per right-click accumulates orphaned frames indefinitely.
local styledMenu, styledMenuCatcher, styledMenuTitle
local styledMenuRowPool = {}

local STYLED_MENU_PAD    = 6
local STYLED_MENU_TITLE  = 22
local STYLED_MENU_ROW_H  = 22
local STYLED_MENU_WIDTH  = 170

local function ensureStyledMenu()
    if styledMenu then return end

    styledMenu = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    ns.SetBD(styledMenu, T.C_BG, T.C_BDR)
    styledMenu:SetFrameStrata("DIALOG")
    styledMenu:SetWidth(STYLED_MENU_WIDTH)
    styledMenu:EnableMouse(true)
    styledMenu:Hide()

    styledMenuTitle = ns.MakeLabel(styledMenu, "", 12, T.C_ACCENT)
    styledMenuTitle:SetWordWrap(true)
    styledMenuTitle:SetJustifyH("LEFT")
    styledMenuTitle:Hide()

    styledMenuCatcher = CreateFrame("Frame", nil, UIParent)
    styledMenuCatcher:SetAllPoints(UIParent)
    styledMenuCatcher:SetFrameStrata("DIALOG")
    styledMenuCatcher:SetFrameLevel(styledMenu:GetFrameLevel() - 1)
    styledMenuCatcher:EnableMouse(true)
    styledMenuCatcher:Hide()
    styledMenuCatcher:SetScript("OnMouseDown", function() styledMenu:Hide() end)

    styledMenu:SetScript("OnShow", function() styledMenuCatcher:Show() end)
    styledMenu:SetScript("OnHide", function() styledMenuCatcher:Hide() end)
end

local function getStyledMenuRow(index)
    local row = styledMenuRowPool[index]
    if row then return row end

    row = CreateFrame("Button", nil, styledMenu, "BackdropTemplate")
    row:SetHeight(STYLED_MENU_ROW_H - 2)
    ns.SetBD(row, T.C_PANEL, T.C_BDR)
    row.label = ns.MakeLabel(row, "", 12, T.C_TEXT)
    row.label:SetPoint("LEFT", 8, 0)
    row:SetScript("OnEnter", function(s) s:SetBackdropColor(unpack(T.C_HOVER)) end)
    row:SetScript("OnLeave", function(s) s:SetBackdropColor(unpack(T.C_PANEL)) end)
    row:SetScript("OnClick", function(s)
        styledMenu:Hide()
        if s._onClick then s._onClick() end
    end)
    styledMenuRowPool[index] = row
    return row
end

local function showStyledMenu(items)
    ensureStyledMenu()

    -- Hide all pooled rows first; only the ones we re-populate will Show().
    for _, row in ipairs(styledMenuRowPool) do row:Hide() end
    styledMenuTitle:Hide()

    local y = -STYLED_MENU_PAD
    local buttonIdx = 0
    for _, item in ipairs(items) do
        if item.kind == "title" then
            styledMenuTitle:SetText(item.text)
            styledMenuTitle:ClearAllPoints()
            styledMenuTitle:SetPoint("TOPLEFT",  STYLED_MENU_PAD + 4, y)
            styledMenuTitle:SetPoint("TOPRIGHT", -STYLED_MENU_PAD - 4, y)
            styledMenuTitle:Show()
            local textH = math.max(STYLED_MENU_TITLE, (styledMenuTitle:GetStringHeight() or 0) + 6)
            y = y - textH
        elseif item.kind == "button" then
            buttonIdx = buttonIdx + 1
            local row = getStyledMenuRow(buttonIdx)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT",  STYLED_MENU_PAD, y)
            row:SetPoint("TOPRIGHT", -STYLED_MENU_PAD, y)
            row.label:SetText(item.text)
            row._onClick = item.onClick
            row:Show()
            y = y - STYLED_MENU_ROW_H
        end
    end

    styledMenu:SetHeight(-y + STYLED_MENU_PAD)

    -- Position the top-left at the cursor, clamped to the screen so a
    -- click near the right/bottom edge doesn't send the menu off-screen.
    local mx, my  = GetCursorPosition()
    local scale   = UIParent:GetEffectiveScale()
    mx = mx / scale; my = my / scale
    local w, h    = styledMenu:GetSize()
    local screenW = UIParent:GetWidth()
    if mx + w > screenW then mx = screenW - w end
    if my - h < 0       then my = h end
    styledMenu:ClearAllPoints()
    styledMenu:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", mx, my)

    styledMenu:Show()
    styledMenu:Raise()
end

local function openRowContextMenu(self)
    local src = self._src
    if not src then return end
    local label = plainItemName(src)

    local items = {
        { kind = "title",  text = label },
        { kind = "button", text = "Delete", onClick = function()
            local popup = StaticPopup_Show("LEAKYACCOUNTING_DELETE_ENTRY", label)
            if popup then popup.data = src end
        end },
    }
    -- "Delete (All)" is item-scoped only — hide for Gold / money rows.
    local isItem = (src.itemID ~= nil) or (src.itemName and src.itemName ~= "Gold")
    if isItem then
        items[#items + 1] = { kind = "button", text = "Delete (All)", onClick = function()
            local popup = StaticPopup_Show("LEAKYACCOUNTING_DELETE_ALL_ITEM", label)
            if popup then popup.data = src end
        end }
    end

    showStyledMenu(items)
end

local function itemHitboxClick(self, button)
    if button == "RightButton" then
        openRowContextMenu(self)
        return
    end
    if IsModifiedClick("CHATLINK") then
        local link = self._itemLink
        if not link and self._itemName then
            _, link = C_Item.GetItemInfo(self._itemName)
        end
        if link then HandleModifiedItemClick(link) end
    end
end

local function getRow(layout, idx)
    local r = layout.rows[idx]
    if r then r:Show(); return r end

    local row = CreateFrame("Frame", nil, layout.content, "BackdropTemplate")
    row:SetHeight(ROW_H)

    if idx % 2 == 0 then
        row:SetBackdrop({ bgFile = T.TEX })
        row:SetBackdropColor(1, 1, 1, 0.025)
    end

    row.fs = {}
    for _, col in ipairs(layout.cols) do
        local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetWordWrap(false)
        row.fs[col.key] = fs
    end

    -- Invisible hitbox over the item cell for tooltip + shift-click linking.
    -- Sized and positioned later in layoutHeaderAndRows.
    local hitbox = CreateFrame("Button", nil, row)
    hitbox:EnableMouse(true)
    hitbox:RegisterForClicks("AnyUp")
    hitbox:SetScript("OnEnter", itemHitboxEnter)
    hitbox:SetScript("OnLeave", itemHitboxLeave)
    hitbox:SetScript("OnClick", itemHitboxClick)
    row.itemHitbox = hitbox

    layout.rows[idx] = row
    return row
end

local function fillRow(row, cols, txn)
    for _, col in ipairs(cols) do
        local fs = row.fs[col.key]
        if fs then
            local text, color = col.render(txn)
            fs:SetText(text or "")
            if color then fs:SetTextColor(unpack(color)) else fs:SetTextColor(1, 1, 1, 1) end
        end
    end
    if row.itemHitbox then
        row.itemHitbox._itemLink = txn.itemLink
        row.itemHitbox._itemName = txn.itemName
        row.itemHitbox._src      = txn._src
    end
end

-- -------------------------------------------------- --
--  Layout lifecycle                                  --
-- -------------------------------------------------- --

local function destroyLayout(layout)
    if layout.headerScroll then layout.headerScroll:Hide(); layout.headerScroll:SetParent(nil) end
    if layout.scroll       then layout.scroll:Hide();       layout.scroll:SetParent(nil)       end
    if layout.hscroll      then layout.hscroll:Hide();      layout.hscroll:SetParent(nil)      end
    if layout.vscroll      then layout.vscroll:Hide();      layout.vscroll:SetParent(nil)      end
    if layout.totalsStrip  then layout.totalsStrip:Hide(); layout.totalsStrip:SetParent(nil)   end
    if layout.windowRow    then layout.windowRow:Hide();    layout.windowRow:SetParent(nil)    end
    if layout.search       then layout.search:Hide();       layout.search:SetParent(nil)       end
    if layout.searchLbl    then layout.searchLbl:Hide()                                         end
    if layout.filterBtn      then layout.filterBtn:Hide();      layout.filterBtn:SetParent(nil)      end
    if layout.filterDropdown then layout.filterDropdown:Hide(); layout.filterDropdown:SetParent(nil) end
    if layout.filterCatcher  then layout.filterCatcher:Hide();  layout.filterCatcher:SetParent(nil)  end
end

local function ensureLayout(parent, scope)
    T = ns.theme
    if parent._layout and parent._layout.scope == scope then
        return parent._layout
    end
    if parent._layout then destroyLayout(parent._layout) end

    local state = session[scope]
    local cols  = buildColumns(scope)

    local layout = {
        scope        = scope,
        cols         = cols,
        state        = state,
        headerCells  = {},
        grips        = {},
        rows         = {},
    }
    parent._layout = layout

    -- Filter button (top-right). Click toggles a styled dropdown panel.
    local filterBtn = ns.MakeButton(parent, "Filter", 100, SEARCH_H - 2)
    filterBtn:SetPoint("TOPRIGHT", -T.PAD, -T.PAD - 1)
    layout.filterBtn = filterBtn

    -- Dropdown panel: dark backdrop + blue accent thumb, matching the
    -- rest of the UI. A full-screen mouse "catcher" sits just beneath the
    -- panel so clicking anywhere outside closes it.
    local PAD_D   = 6
    local ROW_H_D = 22
    local TITLE_D = 22
    local SEP_H   = 8
    local DROP_W  = 170

    local totalDropH = PAD_D
                     + TITLE_D + #FILTER_CATEGORIES * ROW_H_D
                     + SEP_H
                     + TITLE_D + #KIND_CATEGORIES   * ROW_H_D
                     + PAD_D

    local dropdown = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    ns.SetBD(dropdown, T.C_BG, T.C_BDR)
    dropdown:SetFrameStrata("DIALOG")
    dropdown:SetSize(DROP_W, totalDropH)
    dropdown:SetPoint("TOPRIGHT", filterBtn, "BOTTOMRIGHT", 0, -2)
    dropdown:Hide()
    layout.filterDropdown = dropdown

    local rowRefreshers = {}  -- collected per-section so dropdown._refresh syncs all

    -- Builds one section: a header label, then a checkbox row per
    -- category. `stateMap` is the table that holds the section's
    -- on/off bits (state.filterSources or state.filterKinds).
    local function buildSection(headerText, categories, stateMap, startY)
        local header = ns.MakeLabel(dropdown, headerText, 12, T.C_ACCENT)
        header:SetPoint("TOPLEFT", PAD_D + 4, startY)
        local y = startY - TITLE_D

        for _, cat in ipairs(categories) do
            local row = CreateFrame("Button", nil, dropdown, "BackdropTemplate")
            row:SetHeight(ROW_H_D - 2)
            row:SetPoint("TOPLEFT",  PAD_D, y)
            row:SetPoint("TOPRIGHT", -PAD_D, y)
            ns.SetBD(row, T.C_PANEL, T.C_BDR)

            local box = CreateFrame("Frame", nil, row, "BackdropTemplate")
            box:SetSize(12, 12)
            box:SetPoint("LEFT", 6, 0)
            ns.SetBD(box, T.C_ELEM, T.C_BDR)
            local fill = box:CreateTexture(nil, "OVERLAY")
            fill:SetTexture(T.TEX)
            fill:SetPoint("TOPLEFT", 2, -2)
            fill:SetPoint("BOTTOMRIGHT", -2, 2)
            fill:SetVertexColor(unpack(T.C_ACCENT))

            local lbl = ns.MakeLabel(row, cat, 12, T.C_TEXT)
            lbl:SetPoint("LEFT", box, "RIGHT", 8, 0)

            local function refreshRow() fill:SetShown(stateMap[cat] == true) end
            refreshRow()
            rowRefreshers[#rowRefreshers + 1] = refreshRow

            row:RegisterForClicks("AnyUp")
            row:SetScript("OnEnter", function(s) s:SetBackdropColor(unpack(T.C_HOVER)) end)
            row:SetScript("OnLeave", function(s) s:SetBackdropColor(unpack(T.C_PANEL)) end)
            row:SetScript("OnClick", function()
                if stateMap[cat] then
                    stateMap[cat] = nil
                else
                    stateMap[cat] = true
                end
                refreshRow()
                ns.RenderItemized(parent, scope)
            end)

            y = y - ROW_H_D
        end
        return y  -- next section starts here
    end

    local nextY = buildSection("Source", FILTER_CATEGORIES, state.filterSources, -PAD_D)

    -- Separator line between sections
    local sepY = nextY - math.floor(SEP_H / 2)
    local sep = dropdown:CreateTexture(nil, "OVERLAY")
    sep:SetTexture(T.TEX)
    sep:SetVertexColor(unpack(T.C_BDR))
    sep:SetHeight(1)
    sep:SetPoint("LEFT",  dropdown, "TOPLEFT",  PAD_D, sepY)
    sep:SetPoint("RIGHT", dropdown, "TOPRIGHT", -PAD_D, sepY)
    nextY = nextY - SEP_H

    buildSection("Kind", KIND_CATEGORIES, state.filterKinds, nextY)

    dropdown._refresh = function()
        for _, fn in ipairs(rowRefreshers) do fn() end
    end

    -- Close-on-outside is intentionally NOT implemented right now — every
    -- approach tried (full-screen catcher, GLOBAL_MOUSE_DOWN handler) has
    -- interfered with clicks reaching the child Button rows. Users close
    -- the dropdown by clicking the Filter button again, which toggles.
    -- layout.filterCatcher is kept nil so destroyLayout's guard is a no-op.

    filterBtn:SetScript("OnClick", function()
        if dropdown:IsShown() then
            dropdown:Hide()
        else
            dropdown._refresh()
            dropdown:Show()
            -- Deliberately do NOT call dropdown:Raise() — it bumps the
            -- dropdown's own level above its children's, so clicks on
            -- the row area are absorbed by the dropdown Frame instead
            -- of reaching the checkbox Buttons. The dropdown is already
            -- in DIALOG strata above the HIGH-strata parent and above
            -- the catcher, which is what we actually need.
        end
    end)

    -- Search box (left of the Filter button)
    local search = makeSearchBox(parent, function(text)
        state.search = text
        scheduleRender(parent, scope)
    end)
    search:SetPoint("TOPLEFT",  T.PAD + 52, -T.PAD)
    search:SetPoint("TOPRIGHT", filterBtn, "TOPLEFT", -8, 0)
    search.label:SetPoint("RIGHT", search, "LEFT", -4, 0)
    search.editBox:SetText(state.search or "")
    layout.search    = search
    layout.searchLbl = search.label

    -- Header scroll: clips the header horizontally so cells can't overflow.
    local headerScroll = CreateFrame("ScrollFrame", nil, parent)
    headerScroll:SetPoint("TOPLEFT",  T.PAD, -(T.PAD + SEARCH_H + 4))
    headerScroll:SetPoint("TOPRIGHT", -(T.PAD + HSCROLL_H + 2), -(T.PAD + SEARCH_H + 4))
    headerScroll:SetHeight(HEADER_H)
    layout.headerScroll = headerScroll

    local header = ns.MakePanel(headerScroll, T.C_ELEM, T.C_BDR)
    header:SetSize(1, HEADER_H)
    headerScroll:SetScrollChild(header)
    layout.header = header

    local function onHeaderClick(col)
        if state.sortKey == col.key then
            state.sortDir = (state.sortDir == "desc") and "asc" or "desc"
        else
            state.sortKey = col.key
            state.sortDir = "desc"
        end
        ns.RenderItemized(parent, scope)
    end

    for _, col in ipairs(cols) do
        layout.headerCells[col.key] = makeHeaderCell(header, col, onHeaderClick)
        layout.headerCells[col.key]:SetParent(header)

        local myCol = col
        local grip = makeResizeGrip(header, function(phase, newWidth)
            if     phase == "begin"  then return widthFor(state, myCol)
            elseif phase == "update" then
                -- OnUpdate fires every frame while dragging; skip the
                -- layout pass when the cursor hasn't moved enough to
                -- change the rounded width (was re-laying out 60+ times
                -- per second for a stationary cursor).
                local w = math.max(MIN_COL_W, math.floor(newWidth + 0.5))
                if state.widths[myCol.key] ~= w then
                    state.widths[myCol.key] = w
                    layoutHeaderAndRows(layout)
                end
            end
        end)
        layout.grips[col.key] = grip
    end

    -- Vertical scroll frame + content (no built-in scrollbar — we draw our own)
    local BOTTOM_INSET = T.PAD + TOTALS_H + 2 + WINDOW_H + 2 + HSCROLL_H + 2
    local scroll = CreateFrame("ScrollFrame", nil, parent)
    scroll:SetPoint("TOPLEFT",     T.PAD,                    -(T.PAD + SEARCH_H + 4 + HEADER_H + 2))
    scroll:SetPoint("BOTTOMRIGHT", -(T.PAD + HSCROLL_H + 2), BOTTOM_INSET)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(1, 1)
    scroll:SetScrollChild(content)
    scroll:SetScript("OnSizeChanged", function() layoutHeaderAndRows(layout) end)
    layout.scroll  = scroll
    layout.content = content

    -- Vertical scrollbar (drives the content's vertical scroll)
    local vscroll = ns.MakeScrollbar(parent, "VERTICAL")
    vscroll:SetPoint("TOPRIGHT",    -T.PAD, -(T.PAD + SEARCH_H + 4 + HEADER_H + 2))
    vscroll:SetPoint("BOTTOMRIGHT", -T.PAD, BOTTOM_INSET)
    vscroll:SetScript("OnValueChanged", function(_, value)
        scroll:SetVerticalScroll(value)
    end)
    layout.vscroll = vscroll

    -- Mouse wheel on the scroll frame drives the vertical slider.
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(_, delta)
        local _, maxV = vscroll:GetMinMaxValues()
        if maxV <= 0 then return end
        local new = vscroll:GetValue() - delta * ROW_H * 3
        if new < 0       then new = 0 end
        if new > maxV    then new = maxV end
        vscroll:SetValue(new)
    end)

    -- Horizontal scrollbar (drives both header and content)
    local hscroll = ns.MakeScrollbar(parent, "HORIZONTAL")
    hscroll:SetPoint("BOTTOMLEFT",  T.PAD,                    T.PAD + TOTALS_H + 2 + WINDOW_H + 2)
    hscroll:SetPoint("BOTTOMRIGHT", -(T.PAD + HSCROLL_H + 2), T.PAD + TOTALS_H + 2 + WINDOW_H + 2)
    hscroll:SetScript("OnValueChanged", function(_, value)
        scroll:SetHorizontalScroll(value)
        headerScroll:SetHorizontalScroll(value)
    end)
    layout.hscroll = hscroll

    -- Totals strip: Earned / Spent / Net, computed from the currently
    -- visible (filtered) rows each render.
    local totalsStrip = ns.MakePanel(parent, T.C_PANEL, T.C_BDR)
    totalsStrip:SetPoint("BOTTOMLEFT",  T.PAD, T.PAD)
    totalsStrip:SetPoint("BOTTOMRIGHT", -T.PAD, T.PAD)
    totalsStrip:SetHeight(TOTALS_H)

    local earnedLbl = ns.MakeLabel(totalsStrip, "Total Earned:", 12, T.C_DIM)
    earnedLbl:SetPoint("LEFT", 12, 0)
    local earnedVal = ns.MakeLabel(totalsStrip, "", 12, T.C_GOOD)
    earnedVal:SetPoint("LEFT", earnedLbl, "RIGHT", 6, 0)

    local spentLbl = ns.MakeLabel(totalsStrip, "Total Spent:", 12, T.C_DIM)
    spentLbl:SetPoint("LEFT", earnedVal, "RIGHT", 20, 0)
    local spentVal = ns.MakeLabel(totalsStrip, "", 12, T.C_BAD)
    spentVal:SetPoint("LEFT", spentLbl, "RIGHT", 6, 0)

    local netLbl = ns.MakeLabel(totalsStrip, "Net:", 12, T.C_DIM)
    netLbl:SetPoint("LEFT", spentVal, "RIGHT", 20, 0)
    local netVal = ns.MakeLabel(totalsStrip, "", 12, T.C_TEXT)
    netVal:SetPoint("LEFT", netLbl, "RIGHT", 6, 0)

    -- Average unit price — shown only when the filtered rows collapse to
    -- a single item (e.g. search resolves to one unique itemID). Hidden
    -- otherwise; render layer toggles visibility each paint.
    local avgBuyLbl = ns.MakeLabel(totalsStrip, "Avg Buy:", 12, T.C_DIM)
    avgBuyLbl:SetPoint("LEFT", netVal, "RIGHT", 24, 0)
    local avgBuyVal = ns.MakeLabel(totalsStrip, "", 12, T.C_BAD)
    avgBuyVal:SetPoint("LEFT", avgBuyLbl, "RIGHT", 6, 0)

    local avgSellLbl = ns.MakeLabel(totalsStrip, "Avg Sell:", 12, T.C_DIM)
    avgSellLbl:SetPoint("LEFT", avgBuyVal, "RIGHT", 20, 0)
    local avgSellVal = ns.MakeLabel(totalsStrip, "", 12, T.C_GOOD)
    avgSellVal:SetPoint("LEFT", avgSellLbl, "RIGHT", 6, 0)

    avgBuyLbl:Hide(); avgBuyVal:Hide()
    avgSellLbl:Hide(); avgSellVal:Hide()

    layout.totalsStrip = totalsStrip
    layout.totals = {
        earned = earnedVal, spent = spentVal, net = netVal,
        avgBuyLbl  = avgBuyLbl,  avgBuyVal  = avgBuyVal,
        avgSellLbl = avgSellLbl, avgSellVal = avgSellVal,
    }

    -- Window filter row: sits just above the totals strip. Independent of
    -- the Settings-tab windowDays — each scope keeps its own live filter
    -- value in the module's session table. Value of 0 disables the filter
    -- (shows all rows).
    local windowRow = ns.MakePanel(parent, T.C_PANEL, T.C_BDR)
    windowRow:SetPoint("BOTTOMLEFT",  T.PAD, T.PAD + TOTALS_H + 2)
    windowRow:SetPoint("BOTTOMRIGHT", -T.PAD, T.PAD + TOTALS_H + 2)
    windowRow:SetHeight(WINDOW_H)

    local wLbl = ns.MakeLabel(windowRow, "Window (days):", 12, T.C_DIM)
    wLbl:SetPoint("LEFT", 12, 0)

    local wHolder = CreateFrame("Frame", nil, windowRow, "BackdropTemplate")
    ns.SetBD(wHolder, T.C_ELEM, T.C_BDR)
    wHolder:SetSize(56, 18)
    wHolder:SetPoint("LEFT", wLbl, "RIGHT", 8, 0)

    local wEb = CreateFrame("EditBox", nil, wHolder)
    wEb:SetPoint("TOPLEFT", 4, -2)
    wEb:SetPoint("BOTTOMRIGHT", -4, 2)
    wEb:SetAutoFocus(false)
    wEb:SetFontObject("GameFontNormalSmall")
    wEb:SetTextColor(unpack(T.C_TEXT))
    wEb:SetNumeric(true)
    wEb:SetMaxLetters(5)
    wEb:SetScript("OnEscapePressed", wEb.ClearFocus)
    wEb:SetText(tostring(state.windowDays or 7))

    local wHint = ns.MakeLabel(windowRow, "0 = show all", 11, T.C_DIM)
    wHint:SetPoint("LEFT", wHolder, "RIGHT", 8, 0)

    local function applyWindow()
        local n = tonumber(wEb:GetText() or "")
        if not n or n < 0 then n = 0 end
        if n > 36500 then n = 36500 end
        state.windowDays = n
        scheduleRender(parent, scope)
    end
    wEb:SetScript("OnEnterPressed", function(self) applyWindow(); self:ClearFocus() end)
    wEb:SetScript("OnEditFocusLost", applyWindow)
    wEb:SetScript("OnTextChanged", function(_, userInput)
        if userInput then applyWindow() end
    end)

    layout.windowRow  = windowRow
    layout.windowEdit = wEb

    return layout
end

-- -------------------------------------------------- --
--  Render                                            --
-- -------------------------------------------------- --

function ns.RenderItemized(parent, scope)
    T = ns.theme
    local layout = ensureLayout(parent, scope)
    local state  = layout.state

    updateHeaderArrows(layout)
    layoutHeaderAndRows(layout)

    -- Filter button label: "Filter" when every category in both sections
    -- is checked; "Filter (N/Total)" when the list has been narrowed.
    if layout.filterBtn and layout.filterBtn.text then
        local checked, total = 0, #FILTER_CATEGORIES + #KIND_CATEGORIES
        for _, cat in ipairs(FILTER_CATEGORIES) do
            if state.filterSources[cat] then checked = checked + 1 end
        end
        for _, cat in ipairs(KIND_CATEGORIES) do
            if state.filterKinds[cat] then checked = checked + 1 end
        end
        if checked == total then
            layout.filterBtn.text:SetText("Filter")
        else
            layout.filterBtn.text:SetText(string.format("Filter (%d/%d)", checked, total))
        end
    end

    local txns = ns.CollectTxns(scope)
    txns = filterTxns(txns, state.search, state.windowDays, state.filterSources, state.filterKinds)
    sortTxns(txns, layout.cols, state.sortKey, state.sortDir)

    -- Totals over whatever is currently shown (i.e. post-filter). Also
    -- accumulates per-kind qty+total so we can show Avg Buy / Avg Sell
    -- when the filter resolves to one unique item.
    local earned, spent = 0, 0
    local buyTotal, buyQty, sellTotal, sellQty = 0, 0, 0, 0
    local soleKey, mixed = nil, false
    for i, t in ipairs(txns) do
        local v = (t.qty or 1) * (t.unitPrice or 0)
        -- Guild-funded repairs came out of the guild bank, not the
        -- player's wallet — we still show the row (with the Other
        -- column noting the context) but don't let it shift the
        -- player's Earned / Spent / Net numbers.
        local countable = t.source ~= "guild-repair"
        if countable then
            if     t.kind == "sell" then earned = earned + v; sellTotal = sellTotal + v; sellQty = sellQty + (t.qty or 1)
            elseif t.kind == "buy"  then spent  = spent  + v; buyTotal  = buyTotal  + v; buyQty  = buyQty  + (t.qty or 1) end
        end

        local key = t.itemID or t.itemName
        if i == 1 then
            soleKey = key
        elseif key ~= soleKey then
            mixed = true
        end
    end
    local net = earned - spent
    layout.totals.earned:SetText(ns.FormatMoney(earned))
    layout.totals.spent:SetText(ns.FormatMoney(spent))
    layout.totals.net:SetText(ns.FormatMoney(net))
    layout.totals.net:SetTextColor(unpack(net >= 0 and T.C_GOOD or T.C_BAD))

    -- Show Avg Buy / Avg Sell only when exactly one unique item is visible
    -- AND at least one row exists for the respective kind. "Gold" rows
    -- (money log) count as their own key, so mixed gold+item filtering
    -- correctly suppresses the avg.
    local isSingle = (#txns > 0) and (not mixed) and (soleKey ~= nil)
    if isSingle and buyQty > 0 then
        layout.totals.avgBuyLbl:Show()
        layout.totals.avgBuyVal:Show()
        layout.totals.avgBuyVal:SetText(ns.FormatMoney(math.floor(buyTotal / buyQty + 0.5)))
    else
        layout.totals.avgBuyLbl:Hide()
        layout.totals.avgBuyVal:Hide()
    end
    if isSingle and sellQty > 0 then
        layout.totals.avgSellLbl:Show()
        layout.totals.avgSellVal:Show()
        layout.totals.avgSellVal:SetText(ns.FormatMoney(math.floor(sellTotal / sellQty + 0.5)))
    else
        layout.totals.avgSellLbl:Hide()
        layout.totals.avgSellVal:Hide()
    end

    for _, r in ipairs(layout.rows) do r:Hide() end

    if #txns == 0 then
        if not layout.emptyFS then
            layout.emptyFS = layout.content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            layout.emptyFS:SetPoint("TOP", 0, -40)
            layout.emptyFS:SetTextColor(unpack(T.C_DIM))
        end
        layout.emptyFS:SetText((state.search and state.search ~= "")
            and ("No transactions match \"" .. state.search .. "\".")
            or  "No transactions logged yet.")
        layout.emptyFS:Show()
        layout.content:SetHeight(100)
        return
    end
    if layout.emptyFS then layout.emptyFS:Hide() end

    for i, txn in ipairs(txns) do
        local row = getRow(layout, i)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT",  layout.content, "TOPLEFT",  0, -(i - 1) * ROW_H)
        row:SetPoint("TOPRIGHT", layout.content, "TOPRIGHT", 0, -(i - 1) * ROW_H)
        fillRow(row, layout.cols, txn)
    end

    layout.content:SetHeight(#txns * ROW_H)
    layoutHeaderAndRows(layout)  -- reposition new rows' cells + update scrollbar ranges
end
