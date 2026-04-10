local addonName, ConsumableHelper = ...

-------------------------------------------------------------------------------
-- Config defaults (persisted in ConsumableHelperDB via SavedVariables)
-------------------------------------------------------------------------------
local defaults = {
    debugEnabled = false,
}

local function DebugPrint(msg)
    if ConsumableHelperDB and ConsumableHelperDB.debugEnabled then
        print("|cff00ccff[ConsumableHelper]|r " .. msg)
    end
end

-------------------------------------------------------------------------------
-- Constants
-------------------------------------------------------------------------------
local FRAME_WIDTH    = 340
local FRAME_HEIGHT   = 480
local ROW_HEIGHT     = 34
local HEADER_HEIGHT  = 24
local CONTENT_WIDTH  = FRAME_WIDTH - 34  -- room for scrollbar + padding

-------------------------------------------------------------------------------
-- State
-------------------------------------------------------------------------------
local mainFrame
local scrollFrame
local contentFrame
local titleText
local specText
local currentSpecID
local currentClassFile
local activeTab = "consumables"  -- "consumables", "enchants", or "utility"
local tabButtons = {}
local itemCacheWarmed = false
local testSpecID = nil
local testClassName = nil

-------------------------------------------------------------------------------
-- Class / Spec Detection
-------------------------------------------------------------------------------
local function DetectClassAndSpec()
    if testSpecID and testClassName then
        local _, specName = GetSpecializationInfoForSpecID(testSpecID)
        specName = specName or "Test Spec"
        currentClassFile = testClassName:upper()
        currentSpecID = testSpecID
        DebugPrint("Showing consumables for: " .. tostring(currentClassFile) .. ", spec: " .. tostring(specName) .. " (ID: " .. tostring(testSpecID) .. ")")
        return currentClassFile, testSpecID, specName
    end
    local _, classFile = UnitClass("player")
    local specIndex = GetSpecialization()
    local specID, specName
    if specIndex then
        specID, specName = GetSpecializationInfo(specIndex)
    end
    currentClassFile = classFile
    currentSpecID = specID
    DebugPrint("Detected class: " .. tostring(classFile) .. ", spec: " .. tostring(specName) .. " (ID: " .. tostring(specID) .. ")")
    return classFile, specID, specName
end

-------------------------------------------------------------------------------
-- Data Filtering
-------------------------------------------------------------------------------
local function ItemMatchesPlayer(itemData, classFile, specID)
    -- Check class restriction
    if itemData.classes then
        local classMatch = false
        for _, c in ipairs(itemData.classes) do
            if c == classFile then classMatch = true; break end
        end
        if not classMatch then return false end
    end
    -- Check spec restriction
    if itemData.specs then
        local specMatch = false
        for _, s in ipairs(itemData.specs) do
            if s == specID then specMatch = true; break end
        end
        if not specMatch then return false end
    end
    return true
end

local function GetFilteredData(sourceData, classFile, specID)
    local filtered = {}
    for _, categoryData in ipairs(sourceData) do
        local matchedItems = {}
        for _, itemData in ipairs(categoryData.items) do
            if ItemMatchesPlayer(itemData, classFile, specID) then
                matchedItems[#matchedItems + 1] = itemData
            end
        end
        if #matchedItems > 0 then
            filtered[#filtered + 1] = {
                category = categoryData.category,
                items    = matchedItems,
            }
        end
    end
    DebugPrint("Filtered data: " .. #filtered .. " categories for " .. tostring(classFile) .. "/" .. tostring(specID))
    return filtered
end

-------------------------------------------------------------------------------
-- Item Cache Warming
-- Pre-request all item data so names/icons are available instantly
-------------------------------------------------------------------------------
local function WarmItemCache()
    if itemCacheWarmed then return end
    itemCacheWarmed = true
    local count = 0
    local function cacheItems(dataTable)
        if not dataTable then return end
        for _, categoryData in ipairs(dataTable) do
            for _, itemData in ipairs(categoryData.items) do
                if itemData.itemId then
                    C_Item.RequestLoadItemDataByID(itemData.itemId)
                    count = count + 1
                end
                -- Also warm quality variant IDs
                if itemData.qualities then
                    for _, qId in ipairs(itemData.qualities) do
                        if qId ~= itemData.itemId then
                            C_Item.RequestLoadItemDataByID(qId)
                            count = count + 1
                        end
                    end
                end
            end
        end
    end
    cacheItems(ConsumableHelper.ConsumableData)
    cacheItems(ConsumableHelper.EnchantData)
    cacheItems(ConsumableHelper.UtilityData)
    DebugPrint("Warming item cache: requested " .. count .. " items")
end

-------------------------------------------------------------------------------
-- Auction House Search
-------------------------------------------------------------------------------
local function SearchAuctionHouseByName(itemName)
    DebugPrint("SearchAuctionHouseByName called for: " .. tostring(itemName))
    if not AuctionHouseFrame or not AuctionHouseFrame:IsShown() then
        DebugPrint("AuctionHouseFrame not available or not shown, aborting search")
        return
    end

    local searchQuery = {
        searchString = itemName,
        sorts = { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } },
        minLevel = 0,
        maxLevel = 0,
        filters = {},
        itemClassFilters = {},
    }
    C_AuctionHouse.SendBrowseQuery(searchQuery)
end

-------------------------------------------------------------------------------
-- UI Components
-------------------------------------------------------------------------------

-- Category header bar (e.g. "Flasks", "Potions")
local function CreateCategoryHeader(parent, text, yOffset)
    local header = CreateFrame("Frame", nil, parent)
    header:SetSize(CONTENT_WIDTH, HEADER_HEIGHT)
    header:SetPoint("TOPLEFT", 0, -yOffset)

    local bg = header:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.20, 0.15, 0.05, 0.6)

    local label = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("LEFT", 8, 0)
    label:SetText("|cffffd100" .. text .. "|r")

    return HEADER_HEIGHT
end

-- Single item row: [icon] [name]
-- pendingItems tracks rows awaiting async item data (keyed by itemId)
local pendingItems = {}
local pendingEventFrame

local function EnsurePendingEventFrame()
    if pendingEventFrame then return end
    pendingEventFrame = CreateFrame("Frame")
    pendingEventFrame:RegisterEvent("ITEM_DATA_LOAD_RESULT")
    pendingEventFrame:SetScript("OnEvent", function(_, _, loadedId)
        local entries = pendingItems[loadedId]
        if not entries then return end
        local tex = C_Item.GetItemIconByID(loadedId)
        local name = C_Item.GetItemNameByID(loadedId)
        for _, entry in ipairs(entries) do
            if tex then entry.icon:SetTexture(tex) end
            if name then
                entry.nameText:SetText(name)
                entry.displayName = name
            end
        end
        pendingItems[loadedId] = nil
    end)
end

local function CreateItemRow(parent, itemData, yOffset, rowIndex)
    local row = CreateFrame("Button", nil, parent)
    row:SetSize(CONTENT_WIDTH, ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 0, -yOffset)
    row:EnableMouse(true)
    row:RegisterForClicks("LeftButtonUp")

    -- Alternating background
    if rowIndex % 2 == 0 then
        local bg = row:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(1, 1, 1, 0.03)
    end

    -- Hover highlight (manual show/hide)
    local hlTex = row:CreateTexture(nil, "OVERLAY")
    hlTex:SetAllPoints()
    hlTex:SetColorTexture(1, 1, 1, 0.06)
    hlTex:Hide()

    -- Icon
    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(26, 26)
    icon:SetPoint("LEFT", 6, 0)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    -- Item name (leave room for counts on the right)
    local hasQualities = itemData.qualities and #itemData.qualities >= 2
    local nameText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    nameText:SetPoint("LEFT", icon, "RIGHT", 6, 0)
    nameText:SetPoint("RIGHT", row, "RIGHT", hasQualities and -96 or -36, 0)
    nameText:SetJustifyH("LEFT")
    nameText:SetWordWrap(false)

    -- Bag count display
    local updateCount
    if hasQualities then
        -- Per-quality-tier display: [★]N  [★★]N  [★★★]N
        local tierFrames = {}
        local tierCount = #itemData.qualities
        local tierWidth = 28
        for qi = tierCount, 1, -1 do
            local offsetFromRight = (tierCount - qi) * tierWidth + 4
            local qIcon = row:CreateTexture(nil, "ARTWORK")
            qIcon:SetSize(12, 12)
            qIcon:SetPoint("RIGHT", row, "RIGHT", -offsetFromRight - 12, 0)
            qIcon:SetAtlas("Professions-Icon-Quality-12-Tier" .. qi, false)

            local qText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            qText:SetPoint("LEFT", qIcon, "RIGHT", 1, 0)
            qText:SetJustifyH("LEFT")

            tierFrames[qi] = { icon = qIcon, text = qText, itemId = itemData.qualities[qi] }
        end

        updateCount = function()
            for qi = 1, tierCount do
                local tf = tierFrames[qi]
                local count = C_Item.GetItemCount(tf.itemId, false)
                if count > 0 then
                    tf.text:SetText("|cff00ff00" .. count .. "|r")
                else
                    tf.text:SetText("|cff4a4a4a0|r")
                end
            end
        end
    else
        -- Single count display
        local countText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        countText:SetPoint("RIGHT", row, "RIGHT", -6, 0)
        countText:SetJustifyH("RIGHT")

        updateCount = function()
            if itemData.itemId then
                local count = C_Item.GetItemCount(itemData.itemId, false)
                if count > 0 then
                    countText:SetText("|cff00ff00" .. count .. "|r")
                else
                    countText:SetText("|cff666666-|r")
                end
            end
        end
    end
    updateCount()

    -- Refresh count when bags change
    row:RegisterEvent("BAG_UPDATE_DELAYED")
    row:SetScript("OnEvent", function()
        updateCount()
    end)

    -- Shared entry table for async updates
    local entry = { icon = icon, nameText = nameText, displayName = itemData.name }

    if itemData.itemId then
        -- Try cached icon
        local iconId = C_Item.GetItemIconByID(itemData.itemId)
        icon:SetTexture(iconId or 134400)

        -- Try cached localised name
        local localName = C_Item.GetItemNameByID(itemData.itemId)
        if localName then
            entry.displayName = localName
        end
        nameText:SetText(entry.displayName)

        -- If either is missing, register for async update
        if not iconId or not localName then
            EnsurePendingEventFrame()
            if not pendingItems[itemData.itemId] then
                pendingItems[itemData.itemId] = {}
                C_Item.RequestLoadItemDataByID(itemData.itemId)
            end
            pendingItems[itemData.itemId][#pendingItems[itemData.itemId] + 1] = entry
        end
    elseif type(itemData.icon) == "string" then
        icon:SetTexture("Interface\\Icons\\" .. itemData.icon)
        nameText:SetText(entry.displayName)
    else
        icon:SetTexture(itemData.icon or 134400)
        nameText:SetText(entry.displayName)
    end

    -- Click row to search AH by localised name
    row:SetScript("OnClick", function()
        SearchAuctionHouseByName(entry.displayName)
    end)

    -- Row tooltip — use item ID for proper localised tooltip when possible
    row:SetScript("OnEnter", function(self)
        hlTex:Show()
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if itemData.itemId then
            GameTooltip:SetItemByID(itemData.itemId)
        else
            GameTooltip:SetText(entry.displayName, 1, 1, 1)
        end
        GameTooltip:AddLine("Click to search the Auction House", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function()
        hlTex:Hide()
        GameTooltip:Hide()
    end)

    return ROW_HEIGHT
end

-------------------------------------------------------------------------------
-- Populate / Rebuild Content
-------------------------------------------------------------------------------
local function PopulateContent()
    -- Wipe existing children and pending async lookups
    wipe(pendingItems)
    if contentFrame then
        local children = { contentFrame:GetChildren() }
        for _, child in ipairs(children) do child:Hide(); child:SetParent(nil) end
    end

    local classFile, specID, specName = DetectClassAndSpec()

    -- Pick data source based on active tab
    local sourceData, tabLabel, skipFilter
    if activeTab == "enchants" then
        sourceData = ConsumableHelper.EnchantData
        tabLabel   = "Enchants"
    elseif activeTab == "utility" then
        sourceData = ConsumableHelper.UtilityData
        tabLabel   = "Utility"
        skipFilter = true
    else
        sourceData = ConsumableHelper.ConsumableData
        tabLabel   = "Consumables"
    end

    local filteredData = skipFilter and sourceData or GetFilteredData(sourceData, classFile, specID)

    -- Update title with tab label
    if titleText then
        titleText:SetText("|cff00ccffConsumableHelper|r")
    end
    -- Update spec line with class-coloured spec name
    if specText then
        local label = (specName or "Unknown") .. " " .. tabLabel
        local classColor = RAID_CLASS_COLORS[classFile]
        if classColor then
            specText:SetTextColor(classColor.r, classColor.g, classColor.b)
            specText:SetText(label)
        else
            specText:SetTextColor(1, 1, 1)
            specText:SetText(label)
        end
    end

    -- Build rows
    local yOffset  = 2
    local rowIndex = 0

    for _, categoryData in ipairs(filteredData) do
        local hHeight = CreateCategoryHeader(contentFrame, categoryData.category, yOffset)
        yOffset = yOffset + hHeight + 2

        for _, itemData in ipairs(categoryData.items) do
            rowIndex = rowIndex + 1
            local rHeight = CreateItemRow(contentFrame, itemData, yOffset, rowIndex)
            yOffset = yOffset + rHeight + 1
        end

        yOffset = yOffset + 4  -- gap between categories
    end

    contentFrame:SetHeight(yOffset + 8)
    if scrollFrame then scrollFrame:SetVerticalScroll(0) end
    DebugPrint("Populated " .. rowIndex .. " items for " .. tostring(specName))
end

-------------------------------------------------------------------------------
-- Main Frame
-------------------------------------------------------------------------------
local function CreateMainFrame()
    DebugPrint("CreateMainFrame called")
    if mainFrame then
        DebugPrint("MainFrame already exists, rebuilding content")
        PopulateContent()
        return mainFrame
    end
    DebugPrint("Building new MainFrame")

    mainFrame = CreateFrame("Frame", "ConsumableHelperFrame", UIParent, "BackdropTemplate")
    mainFrame:SetSize(FRAME_WIDTH, FRAME_HEIGHT)
    mainFrame:SetFrameStrata("HIGH")
    mainFrame:SetClampedToScreen(true)

    -- Draggable
    mainFrame:SetMovable(true)
    mainFrame:EnableMouse(true)
    mainFrame:RegisterForDrag("LeftButton")
    mainFrame:SetScript("OnDragStart", mainFrame.StartMoving)
    mainFrame:SetScript("OnDragStop", mainFrame.StopMovingOrSizing)

    -- Backdrop
    mainFrame:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    mainFrame:SetBackdropColor(0.08, 0.08, 0.08, 0.93)
    mainFrame:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)

    -- Addon icon orb (top-left corner)
    local orbSize = 36
    local orbFrame = CreateFrame("Frame", nil, mainFrame)
    orbFrame:SetSize(orbSize, orbSize)
    orbFrame:SetPoint("TOPLEFT", 6, -5)
    orbFrame:SetFrameLevel(mainFrame:GetFrameLevel() + 2)

    local orbIcon = orbFrame:CreateTexture(nil, "ARTWORK")
    orbIcon:SetAllPoints()
    orbIcon:SetTexture("Interface\\AddOns\\ConsumableHelper\\Art\\Icons\\ConsumableHelperIcon")
    orbIcon:SetMask("Interface\\CHARACTERFRAME\\TempPortraitAlphaMask")

    local orbBorder = orbFrame:CreateTexture(nil, "OVERLAY")
    orbBorder:SetSize(orbSize + 4, orbSize + 4)
    orbBorder:SetPoint("CENTER")
    orbBorder:SetTexture("Interface\\MINIMAP\\MiniMap-TrackingBorder")
    orbBorder:SetPoint("CENTER", 6, -6)

    -- Title
    titleText = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    titleText:SetPoint("TOPLEFT", 46, -8)
    titleText:SetText("|cff00ccffConsumableHelper|r")

    -- Spec + tab line (class-coloured, below title)
    specText = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    specText:SetPoint("TOPLEFT", titleText, "BOTTOMLEFT", 0, -2)
    specText:SetText("")

    -- Close button
    local closeBtn = CreateFrame("Button", nil, mainFrame, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -2, -2)

    -- Divider under title
    local divider = mainFrame:CreateTexture(nil, "ARTWORK")
    divider:SetHeight(1)
    divider:SetPoint("TOPLEFT", 8, -44)
    divider:SetPoint("TOPRIGHT", -8, -44)
    divider:SetColorTexture(0.4, 0.4, 0.4, 0.6)

    -- Tab buttons
    local TAB_HEIGHT = 22
    local tabs = {
        { key = "consumables", label = "Consumables" },
        { key = "enchants",    label = "Enchants" },
        { key = "utility",     label = "Utility" },
    }
    local tabXOffset = 8
    for _, tabInfo in ipairs(tabs) do
        local tab = CreateFrame("Button", nil, mainFrame)
        tab:SetHeight(TAB_HEIGHT)
        tab:SetPoint("TOPLEFT", tabXOffset, -47)

        local tabText = tab:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        tabText:SetPoint("CENTER")
        tabText:SetText(tabInfo.label)
        -- Size button to text width + padding
        tab:SetWidth(tabText:GetStringWidth() + 20)

        local tabBg = tab:CreateTexture(nil, "BACKGROUND")
        tabBg:SetAllPoints()

        tab.key    = tabInfo.key
        tab.bgTex  = tabBg
        tab.fStr   = tabText

        tab:SetScript("OnClick", function()
            activeTab = tabInfo.key
            -- Update tab visuals
            for _, t in pairs(tabButtons) do
                if t.key == activeTab then
                    t.bgTex:SetColorTexture(0.2, 0.6, 0.8, 0.35)
                    t.fStr:SetTextColor(1, 1, 1)
                else
                    t.bgTex:SetColorTexture(0.15, 0.15, 0.15, 0.5)
                    t.fStr:SetTextColor(0.6, 0.6, 0.6)
                end
            end
            PopulateContent()
        end)

        tabButtons[tabInfo.key] = tab
        tabXOffset = tabXOffset + tab:GetWidth() + 4
    end

    -- Set initial tab visuals
    for _, t in pairs(tabButtons) do
        if t.key == activeTab then
            t.bgTex:SetColorTexture(0.2, 0.6, 0.8, 0.35)
            t.fStr:SetTextColor(1, 1, 1)
        else
            t.bgTex:SetColorTexture(0.15, 0.15, 0.15, 0.5)
            t.fStr:SetTextColor(0.6, 0.6, 0.6)
        end
    end

    -- Divider under tabs
    local tabDivider = mainFrame:CreateTexture(nil, "ARTWORK")
    tabDivider:SetHeight(1)
    tabDivider:SetPoint("TOPLEFT", 8, -(47 + TAB_HEIGHT + 2))
    tabDivider:SetPoint("TOPRIGHT", -8, -(47 + TAB_HEIGHT + 2))
    tabDivider:SetColorTexture(0.4, 0.4, 0.4, 0.6)

    -- Scroll frame (below tabs)
    scrollFrame = CreateFrame("ScrollFrame", "ConsumableHelperScrollFrame", mainFrame,
                              "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 6, -(47 + TAB_HEIGHT + 4))
    scrollFrame:SetPoint("BOTTOMRIGHT", -28, 8)

    -- Content frame inside the scroll view
    contentFrame = CreateFrame("Frame", nil, scrollFrame)
    contentFrame:SetWidth(CONTENT_WIDTH)
    contentFrame:SetHeight(1)
    scrollFrame:SetScrollChild(contentFrame)

    -- Fill with spec-filtered data
    PopulateContent()

    mainFrame:Hide()
    return mainFrame
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------
-------------------------------------------------------------------------------
-- Options Panel (Interface → AddOns → ConsumableHelper)
-------------------------------------------------------------------------------
local function CreateOptionsPanel()
    local panel = CreateFrame("Frame")
    panel.name = "ConsumableHelper"

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("|cff00ccffConsumableHelper|r Options")

    local subtitle = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    subtitle:SetText("Auction House consumable helper")

    -- Debug checkbox
    local debugCheck = CreateFrame("CheckButton", "ConsumableHelperDebugCheck", panel, "InterfaceOptionsCheckButtonTemplate")
    debugCheck:SetPoint("TOPLEFT", subtitle, "BOTTOMLEFT", 0, -16)
    debugCheck.Text:SetText("Enable debug logging")
    debugCheck:SetChecked(ConsumableHelperDB.debugEnabled)
    debugCheck:SetScript("OnClick", function(self)
        ConsumableHelperDB.debugEnabled = self:GetChecked()
        if ConsumableHelperDB.debugEnabled then
            print("|cff00ccff[ConsumableHelper]|r Debug logging |cff00ff00enabled|r")
        else
            print("|cff00ccff[ConsumableHelper]|r Debug logging |cffff0000disabled|r")
        end
    end)

    local category = Settings.RegisterCanvasLayoutCategory(panel, "ConsumableHelper")
    Settings.RegisterAddOnCategory(category)
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("AUCTION_HOUSE_SHOW")
eventFrame:RegisterEvent("AUCTION_HOUSE_CLOSED")
eventFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")

eventFrame:SetScript("OnEvent", function(_, event, arg1)
    DebugPrint("Event fired: " .. event)

    if event == "ADDON_LOADED" and arg1 == addonName then
        -- Initialize saved variables with defaults
        if not ConsumableHelperDB then ConsumableHelperDB = {} end
        for k, v in pairs(defaults) do
            if ConsumableHelperDB[k] == nil then ConsumableHelperDB[k] = v end
        end
        CreateOptionsPanel()
        DebugPrint("Addon loaded, config initialised")
        return
    end

    if event == "PLAYER_LOGIN" then
        WarmItemCache()
        return
    end

    if event == "AUCTION_HOUSE_SHOW" then
        DebugPrint("Auction House opened — creating/showing ConsumableHelper frame")
        local frame = CreateMainFrame()
        if AuctionHouseFrame then
            DebugPrint("Anchoring to AuctionHouseFrame")
            frame:ClearAllPoints()
            frame:SetPoint("TOPLEFT", AuctionHouseFrame, "TOPRIGHT", 4, 0)
        else
            DebugPrint("WARNING: AuctionHouseFrame is nil, cannot anchor")
        end
        frame:Show()
        DebugPrint("Frame shown")

    elseif event == "AUCTION_HOUSE_CLOSED" then
        DebugPrint("Auction House closed — hiding ConsumableHelper frame")
        if mainFrame then
            mainFrame:Hide()
        end

    elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
        -- arg1 is the unit; only care about "player"
        if arg1 == "player" then
            DebugPrint("Spec changed — refreshing consumable list")
            if mainFrame and mainFrame:IsShown() then
                PopulateContent()
            end
        end
    end
end)

-------------------------------------------------------------------------------
-- Slash Commands
-------------------------------------------------------------------------------
-- /consumablehelper or /ch — toggle window outside the AH
SLASH_CONSUMABLEHELPER1 = "/consumablehelper"
SLASH_CONSUMABLEHELPER2 = "/ch"
SlashCmdList["CONSUMABLEHELPER"] = function(msg)
    local cmd, arg1, arg2 = strsplit(" ", (msg or ""):lower():trim())
    if cmd == "debug" then
        ConsumableHelperDB.debugEnabled = not ConsumableHelperDB.debugEnabled
        if ConsumableHelperDB.debugEnabled then
            print("|cff00ccff[ConsumableHelper]|r Debug logging |cff00ff00enabled|r")
        else
            print("|cff00ccff[ConsumableHelper]|r Debug logging |cffff0000disabled|r")
        end
    elseif cmd == "show" and arg1 and arg2 then
        local className = arg1:lower()
        local specName = arg2:lower()
        -- Map class and spec names to spec IDs
        local classSpecs = ConsumableHelper.ClassSpecs
        local matches = {}
        for spec, id in pairs(classSpecs[className]) do
            if spec:sub(1, #specName) == specName then
                table.insert(matches, {spec = spec, id = id})
            end
        end
        if #matches == 1 then
            local specID = matches[1].id
            local fullSpecName = matches[1].spec
            testClassName = className
            testSpecID = specID
            print("|cff00ccff[ConsumableHelper]|r Showing consumables for: " .. className:gsub("^%l", string.upper) .. " " .. fullSpecName:gsub("^%l", string.upper) .. " (ID: " .. specID .. ")")
            if mainFrame and mainFrame:IsShown() then
                PopulateContent()
            end
        elseif #matches > 1 then
            local matchSpecs = {}
            for _, m in ipairs(matches) do
                table.insert(matchSpecs, m.spec)
            end
            print("|cff00ccff[ConsumableHelper]|r Ambiguous spec '" .. specName .. "' matches: " .. table.concat(matchSpecs, ", "))
        else
            print("|cff00ccff[ConsumableHelper]|r No matching spec found for '" .. specName .. "' in class '" .. className .. "'")
        end
    elseif cmd == "reset" then
        testSpecID = nil
        testClassName = nil
        print("|cff00ccff[ConsumableHelper]|r Reset shown spec to current player specialization")
        if mainFrame and mainFrame:IsShown() then
            PopulateContent()
        end
    elseif cmd == "" then
        local frame = CreateMainFrame()
        if frame:IsShown() then
            frame:Hide()
        else
            frame:ClearAllPoints()
            frame:SetPoint("CENTER")
            frame:Show()
        end
    else
        print("|cff00ccff[ConsumableHelper]|r commands:")
        print("  /ch — toggle the ConsumableHelper window")
        print("  /ch debug — toggle debug logging")
        print("  /ch show <class> <spec> — show consumables for a specific spec (e.g., /ch show paladin ret)")
        print("  /ch reset — reset shown spec to current player specialization")
    end
end
