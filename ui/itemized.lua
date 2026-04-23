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

-- -------------------------------------------------- --
--  Session state                                     --
-- -------------------------------------------------- --

local session = {
    char    = { sortKey = "date", sortDir = "desc", widths = {}, search = "" },
    account = { sortKey = "date", sortDir = "desc", widths = {}, search = "" },
}

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
            render  = function(t) return t.otherPlayer or "", T.C_DIM end,
            sortVal = function(t) return (t.otherPlayer or ""):lower() end,
        }
    end
    return cols
end

-- -------------------------------------------------- --
--  Filter / sort                                     --
-- -------------------------------------------------- --

local function filterTxns(txns, query)
    if not query or query == "" then return txns end
    local q = query:lower()
    local out = {}
    for _, t in ipairs(txns) do
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
        if hay:find(q, 1, true) then out[#out + 1] = t end
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
        GameTooltip:SetText(self._itemName)
    end
    GameTooltip:Show()
end

local function itemHitboxLeave()
    GameTooltip:Hide()
end

local function itemHitboxClick(self)
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
    if layout.search       then layout.search:Hide();       layout.search:SetParent(nil)       end
    if layout.searchLbl    then layout.searchLbl:Hide()                                         end
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

    -- Search box
    local search = makeSearchBox(parent, function(text)
        state.search = text
        ns.RenderItemized(parent, scope)
    end)
    search:SetPoint("TOPLEFT",  T.PAD + 52, -T.PAD)
    search:SetPoint("TOPRIGHT", -T.PAD, -T.PAD)
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
                state.widths[myCol.key] = math.max(MIN_COL_W, newWidth)
                layoutHeaderAndRows(layout)
            end
        end)
        layout.grips[col.key] = grip
    end

    -- Vertical scroll frame + content (no built-in scrollbar — we draw our own)
    local BOTTOM_INSET = T.PAD + TOTALS_H + 2 + HSCROLL_H + 2
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
    hscroll:SetPoint("BOTTOMLEFT",  T.PAD,                    T.PAD + TOTALS_H + 2)
    hscroll:SetPoint("BOTTOMRIGHT", -(T.PAD + HSCROLL_H + 2), T.PAD + TOTALS_H + 2)
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

    layout.totalsStrip = totalsStrip
    layout.totals = { earned = earnedVal, spent = spentVal, net = netVal }

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

    local txns = ns.CollectTxns(scope)
    txns = filterTxns(txns, state.search)
    sortTxns(txns, layout.cols, state.sortKey, state.sortDir)

    -- Totals over whatever is currently shown (i.e. post-filter).
    local earned, spent = 0, 0
    for _, t in ipairs(txns) do
        local v = (t.qty or 1) * (t.unitPrice or 0)
        if     t.kind == "sell" then earned = earned + v
        elseif t.kind == "buy"  then spent  = spent  + v end
    end
    local net = earned - spent
    layout.totals.earned:SetText(ns.FormatMoney(earned))
    layout.totals.spent:SetText(ns.FormatMoney(spent))
    layout.totals.net:SetText(ns.FormatMoney(net))
    layout.totals.net:SetTextColor(unpack(net >= 0 and T.C_GOOD or T.C_BAD))

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
