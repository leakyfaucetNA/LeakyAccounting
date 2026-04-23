local _, ns = ...

-- Characters tab: lists every character stored in the DB with summary
-- numbers (tx count, earned/spent/net) and a Delete button per row. Use
-- case: wipe data for a renamed / transferred / deleted character so it
-- stops polluting the account-wide view.

local T
local ROW_H = 28

-- WoW class colors as {r, g, b} from the RAID_CLASS_COLORS global. Fall
-- back to neutral text if the class tag is unknown.
local function classColor(classTag)
    if classTag and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classTag] then
        local c = RAID_CLASS_COLORS[classTag]
        return { c.r, c.g, c.b, 1 }
    end
    return ns.theme.C_TEXT
end

-- Confirmation popup for destructive wipe
StaticPopupDialogs["LEAKYACCOUNTING_DELETE_CHAR"] = {
    text         = "Delete all tracked data for %s?\n\nThis cannot be undone.",
    button1      = YES,
    button2      = NO,
    OnAccept     = function(self)
        local key = self.data
        if key and ns.addon and ns.addon.db.global.characters[key] then
            ns.addon.db.global.characters[key] = nil
            ns.lpmsg("Deleted all data for " .. key)
            if ns.OnDataChanged then ns.OnDataChanged() end
        end
    end,
    timeout      = 0,
    whileDead    = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- -------------------------------------------------- --
--  Data                                              --
-- -------------------------------------------------- --

local function foldBucket(bucket)
    local income, spend = 0, 0
    local log = bucket.goldLog or {}
    for i = 2, #log do
        local d = log[i].gold - log[i - 1].gold
        if d > 0 then income = income + d
        elseif d < 0 then spend = spend - d end
    end
    return income, spend
end

local function buildRows()
    local rows = {}
    for key, bucket in ns.IterCharacters() do
        local income, spend = foldBucket(bucket)
        rows[#rows + 1] = {
            key    = key,
            name   = bucket.name  or "?",
            realm  = bucket.realm or "?",
            class  = bucket.class,
            nMoney = #(bucket.money or {}),
            gold   = (bucket.goldLog and #bucket.goldLog > 0)
                     and bucket.goldLog[#bucket.goldLog].gold or 0,
            income = income,
            spend  = spend,
            net    = income - spend,
        }
    end
    table.sort(rows, function(a, b) return a.net > b.net end)
    return rows
end

-- -------------------------------------------------- --
--  Row builder                                       --
-- -------------------------------------------------- --

local function ensureLayout(parent)
    T = ns.theme
    if parent._charsLayout then return parent._charsLayout end

    local layout = { rows = {} }
    parent._charsLayout = layout

    -- Header
    local header = ns.MakePanel(parent, T.C_ELEM, T.C_BDR)
    header:SetPoint("TOPLEFT",  T.PAD, -T.PAD)
    header:SetPoint("TOPRIGHT", -T.PAD, -T.PAD)
    header:SetHeight(22)
    layout.header = header

    local function hLabel(text, ref, off, justify, width)
        local fs = header:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        if ref == "LEFT" then
            fs:SetPoint("LEFT", header, "LEFT", off, 0)
        else
            fs:SetPoint("LEFT", ref, "RIGHT", off, 0)
        end
        fs:SetWidth(width)
        fs:SetJustifyH(justify or "LEFT")
        fs:SetText(text)
        fs:SetTextColor(unpack(T.C_ACCENT))
        return fs
    end

    layout.cols = {}
    layout.cols.name    = hLabel("Character",     "LEFT",   12,        "LEFT",   160)
    layout.cols.realm   = hLabel("Realm",         layout.cols.name,    6, "LEFT",  120)
    layout.cols.earned  = hLabel("Earned",        layout.cols.realm,   6, "RIGHT", 110)
    layout.cols.spent   = hLabel("Spent",         layout.cols.earned,  6, "RIGHT", 110)
    layout.cols.net     = hLabel("Net",           layout.cols.spent,   6, "RIGHT", 110)
    -- Delete column: anchored to the far right of the header
    layout.cols.delete  = header:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    layout.cols.delete:SetPoint("RIGHT", header, "RIGHT", -12, 0)
    layout.cols.delete:SetText("")

    -- Scroll frame
    local scroll = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT",     T.PAD,       -(T.PAD + 26))
    scroll:SetPoint("BOTTOMRIGHT", -(T.PAD + 20), T.PAD)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(1, 1)
    scroll:SetScrollChild(content)
    scroll:SetScript("OnSizeChanged", function(_, w) content:SetWidth(math.max(w, 1)) end)
    layout.scroll  = scroll
    layout.content = content

    return layout
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

    local function mkFS(justify, width, leftAnchor, off)
        local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetWordWrap(false)
        fs:SetWidth(width)
        fs:SetJustifyH(justify or "LEFT")
        if leftAnchor == "LEFT" then
            fs:SetPoint("LEFT", row, "LEFT", off, 0)
        else
            fs:SetPoint("LEFT", leftAnchor, "RIGHT", off, 0)
        end
        return fs
    end

    row.fsName   = mkFS("LEFT",   160, "LEFT",        12)
    row.fsRealm  = mkFS("LEFT",   120, row.fsName,    6)
    row.fsEarned = mkFS("RIGHT",  110, row.fsRealm,   6)
    row.fsSpent  = mkFS("RIGHT",  110, row.fsEarned,  6)
    row.fsNet    = mkFS("RIGHT",  110, row.fsSpent,   6)

    -- Delete button (anchored to right edge)
    local btn = CreateFrame("Button", nil, row, "BackdropTemplate")
    ns.SetBD(btn, { 0.65, 0.20, 0.20, 1 }, T.C_BDR)
    btn:SetSize(64, 20)
    btn:SetPoint("RIGHT", -8, 0)
    local btnText = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    btnText:SetPoint("CENTER")
    btnText:SetText("Delete")
    btnText:SetTextColor(1, 1, 1, 1)
    btn:SetScript("OnEnter", function(s) s:SetBackdropColor(0.85, 0.30, 0.30, 1) end)
    btn:SetScript("OnLeave", function(s) s:SetBackdropColor(0.65, 0.20, 0.20, 1) end)
    btn:SetScript("OnClick", function(s)
        local key = s._key
        if not key then return end
        local popup = StaticPopup_Show("LEAKYACCOUNTING_DELETE_CHAR", key)
        if popup then popup.data = key end
    end)
    row.deleteBtn = btn

    layout.rows[idx] = row
    return row
end

-- -------------------------------------------------- --
--  Render                                            --
-- -------------------------------------------------- --

function ns.RenderCharacters(parent)
    T = ns.theme
    local layout = ensureLayout(parent)
    local rows = buildRows()

    for _, r in ipairs(layout.rows) do r:Hide() end

    if #rows == 0 then
        if not layout.emptyFS then
            layout.emptyFS = layout.content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            layout.emptyFS:SetPoint("TOP", 0, -40)
            layout.emptyFS:SetTextColor(unpack(T.C_DIM))
            layout.emptyFS:SetText("No characters tracked yet.")
        end
        layout.emptyFS:Show()
        layout.content:SetHeight(80)
        return
    end
    if layout.emptyFS then layout.emptyFS:Hide() end

    for i, data in ipairs(rows) do
        local row = getRow(layout, i)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT",  layout.content, "TOPLEFT",  0, -(i - 1) * ROW_H)
        row:SetPoint("TOPRIGHT", layout.content, "TOPRIGHT", 0, -(i - 1) * ROW_H)

        row.fsName:SetText(data.name)
        row.fsName:SetTextColor(unpack(classColor(data.class)))

        row.fsRealm:SetText(data.realm)
        row.fsRealm:SetTextColor(unpack(T.C_DIM))

        row.fsEarned:SetText(ns.FormatMoney(data.income))
        row.fsSpent:SetText(ns.FormatMoney(data.spend))
        row.fsNet:SetText(ns.FormatMoney(data.net))
        row.fsNet:SetTextColor(unpack(data.net >= 0 and T.C_GOOD or T.C_BAD))

        row.deleteBtn._key = data.key
    end

    layout.content:SetHeight(#rows * ROW_H)
end
