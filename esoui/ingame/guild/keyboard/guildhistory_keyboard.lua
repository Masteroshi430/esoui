ZO_GUILD_HISTORY_KEYBOARD_CATEGORY_TREE_WIDTH = 270

local GUILD_EVENT_DATA = 1
local LOAD_CONTROL_TRIGGER_TIME_S = .5

local GuildHistoryManager = ZO_SortFilterList:Subclass()

function GuildHistoryManager:Initialize(control)
    ZO_SortFilterList.Initialize(self, control)

    self:SetAlternateRowBackgrounds(true)
    self:SetAutomaticallyColorRows(false)

    self.loading = control:GetNamedChild("Loading")
    self.masterList = {}

    self.scene = ZO_Scene:New("guildHistory", SCENE_MANAGER)
    self.scene:RegisterCallback("StateChange", function(oldState, state)
        if state == SCENE_SHOWING then
            self.refreshGroup:TryClean()
            self:RequestInitialEvents()
            self:AddKeybinds()
        elseif state == SCENE_HIDDEN then
            self:RemoveKeybinds()
        end
    end)
    GUILD_HISTORY_SCENE = self.scene

    ZO_ScrollList_AddDataType(self.list, GUILD_EVENT_DATA, "ZO_GuildHistoryRow", 60, function(control, data) self:SetupGuildEvent(control, data) end)

    self.updateFunction = function(control, timeS)
        --delay showing the request loading icon by LOAD_CONTROL_TRIGGER_TIME_S
        if DoesGuildHistoryCategoryHaveOutstandingRequest(self.guildId, self.selectedCategory) then
            if not self.nextLoadControlTrigger then
                self.nextLoadControlTrigger = timeS + LOAD_CONTROL_TRIGGER_TIME_S
            elseif timeS > self.nextLoadControlTrigger then
                self.loading:Show()
            end
        else
            self.nextLoadControlTrigger = nil
            self.loading:Hide()
        end
    end

    control:SetHandler("OnUpdate", self.updateFunction)
    --this update interval has nothing to do with the update handler above
    self:SetUpdateInterval(60)

    self.refreshGroup = ZO_OrderedRefreshGroup:New(ZO_ORDERED_REFRESH_GROUP_AUTO_CLEAN_IMMEDIATELY)
    self.refreshGroup:AddDirtyState("EventListData", function()
        self:RefreshData()
    end)
    self.refreshGroup:AddDirtyState("EventListFilters", function()
        self:RefreshFilters()
    end)
    self.refreshGroup:SetActive(function()
        return self:IsShowing()
    end)

    self:InitializeKeybindDescriptors()
    self:CreateCategoryTree()
    
    control:RegisterForEvent(EVENT_GUILD_HISTORY_CATEGORY_UPDATED, function(_, guildId, category) self:OnGuildHistoryCategoryUpdated(guildId, category) end)
    control:RegisterForEvent(EVENT_GUILD_HISTORY_REFRESHED, function() 
        self.selectedSubcategory = nil
        self.refreshGroup:MarkDirty("EventListData")
        self:RequestInitialEvents()
    end)
    control:RegisterForEvent(EVENT_SCREEN_RESIZED, function()
        --The template used is based on the size of the text which changes slightly relative to the size of the row when the screen resizes. This handles the text being right at the wrap point and either
        --unwrapping or wrapping at the new size.
        self.refreshGroup:MarkDirty("EventListData")
    end)
end

function GuildHistoryManager:InitializeKeybindDescriptors()
    self:SetKeybindStripDescriptor(
    {
        alignment = KEYBIND_STRIP_ALIGN_RIGHT,

        -- Show More
        {
            name = GetString(SI_GUILD_HISTORY_SHOW_MORE),
            keybind = "UI_SHORTCUT_PRIMARY",

            visible = function()
                return self.selectedCategory ~= nil and self.selectedSubcategory == nil and DoesGuildHistoryCategoryHaveMoreEvents(self.guildId, self.selectedCategory)
            end,
        
            callback = function()
                self:RequestMoreEvents()
            end,
        },
    })
end

function GuildHistoryManager:CreateCategoryTree()
    local TREE_WIDTH = ZO_GUILD_HISTORY_KEYBOARD_CATEGORY_TREE_WIDTH - ZO_SCROLL_BAR_WIDTH
    self.categoryTree = ZO_Tree:New(self.control:GetNamedChild("Categories"), 60, -10, TREE_WIDTH)

    --Category Header

    local TEXT_LABEL_MAX_WIDTH = TREE_WIDTH - ZO_TREE_ENTRY_ICON_HEADER_TEXT_OFFSET_X
    local function CategoryHeaderSetup(node, control, categoryId, open)
        control.text:SetDimensionConstraints(0, 0, TEXT_LABEL_MAX_WIDTH, 0)
        control.text:SetModifyTextType(MODIFY_TEXT_TYPE_UPPERCASE)
        control.text:SetText(GetString("SI_GUILDHISTORYCATEGORY", categoryId))

        local categoryData = GUILD_HISTORY_CATEGORIES[categoryId]
        control.icon:SetTexture(open and categoryData.down or categoryData.up)
        control.iconHighlight:SetTexture(categoryData.over)

        ZO_IconHeader_Setup(control, open)

        if open then
            self.categoryTree:SelectFirstChild(node)
        end
    end

    local NO_SELECTION_FUNCTION = nil
    local NO_EQUALITY_FUNCTION = nil
    local DEFAULT_CHILD_INDENT = nil
    local childSpacing = 0
    self.categoryTree:AddTemplate("ZO_IconHeader", CategoryHeaderSetup, NO_SELECTION_FUNCTION, NO_EQUALITY_FUNCTION, DEFAULT_CHILD_INDENT, childSpacing)

    --Subcategory Entry

    local function SubcategoryEntrySetup(node, control, data, open)
        control:SetSelected(false)
        control:SetText(data.name)
    end

    local function SubcategoryEntrySelected(control, data, selected, reselectingDuringRebuild)
        control:SetSelected(selected)
        if selected then
            local oldSelectedCategory = self.selectedCategory
            self.selectedCategory = data.categoryId
            self.selectedSubcategory = data.subcategoryId

            self:SetEmptyText(ZO_GuildHistory_GetNoEntriesText(self.selectedCategory, self.selectedSubcategory, self.guildId))

            --if it's the same category we can just mess with the filter instead of rebuilding the whole list
            if oldSelectedCategory == self.selectedCategory then
                self.refreshGroup:MarkDirty("EventListFilters")
            else
                self:RequestInitialEvents()
                self.refreshGroup:MarkDirty("EventListData")
            end
            ZO_ScrollList_ResetToTop(self.list)
            self:UpdateKeybinds()
        end
    end

    self.categoryTree:AddTemplate("ZO_GuildHistorySubcategoryEntry", SubcategoryEntrySetup, SubcategoryEntrySelected)

    --Build Tree

    for i = 1, GetNumGuildHistoryCategories() do
        local categoryData = GUILD_HISTORY_CATEGORIES[i]
        if categoryData then
            local categoryNode = self.categoryTree:AddNode("ZO_IconHeader", i)
           --All
            self.categoryTree:AddNode("ZO_GuildHistorySubcategoryEntry", {categoryId = i, name = GetString(SI_GUILD_HISTORY_SUBCATEGORY_ALL)}, categoryNode)

            if categoryData.subcategories then
                for subcategoryId, _ in pairs(categoryData.subcategories) do
                    self.categoryTree:AddNode("ZO_GuildHistorySubcategoryEntry", {categoryId = i, subcategoryId = subcategoryId, name = GetString(categoryData.subcategoryEnumName, subcategoryId)}, categoryNode)
                end
            end
        end
    end

    self.categoryTree:SetExclusive(true)
    self.categoryTree:SetOpenAnimation("ZO_TreeOpenAnimation")
    self.categoryTree:Commit()
end

function GuildHistoryManager:SetGuildId(guildId)
    self.guildId = guildId
    self:RequestInitialEvents()
    self.refreshGroup:MarkDirty("EventListData")
    self:UpdateKeybinds()
end

function GuildHistoryManager:SetupGuildEvent(control, data)
    ZO_SortFilterList.SetupRowBG(self, control, data)

    local description = self:FormatEvent(data.eventType, data.param1, data.param2, data.param3, data.param4, data.param5, data.param6)
    local formattedTime = ZO_FormatDurationAgo(data.secsSinceEvent + GetGameTimeSeconds() - self.lastEventDataUpdateS)

    control.descriptionLabel:SetText(description)
    control.timeLabel:SetText(formattedTime)
end

function GuildHistoryManager:IsShowing()
    return self.scene:IsShowing()
end

function GuildHistoryManager:FormatEvent(eventType, ...)
    local format = GUILD_EVENT_EVENT_FORMAT[eventType]
    if format then
        return format(eventType, ...)
    end
end

do
    local function ShouldShowEventType(eventType)
        return GUILD_EVENT_EVENT_FORMAT[eventType] ~= nil
    end

    function GuildHistoryManager:BuildMasterList()
        if self.guildId and self.selectedCategory then
            ZO_ClearNumericallyIndexedTable(self.masterList)
            self.lastEventDataUpdateS = GetFrameTimeSeconds()
            for i = 1, GetNumGuildEvents(self.guildId, self.selectedCategory) do
                local eventType, secsSinceEvent, param1, param2, param3, param4, param5, param6, eventId = GetGuildEventInfo(self.guildId, self.selectedCategory, i)
                if ShouldShowEventType(eventType) then
                    local event = 
                    {
                        eventId = eventId,
                        eventType = eventType,
                        param1 = param1,
                        param2 = param2,
                        param3 = param3,
                        param4 = param4,
                        param5 = param5,
                        param6 = param6,
                        secsSinceEvent = secsSinceEvent,
                        subcategoryId = ComputeGuildHistoryEventSubcategory(eventType, self.selectedCategory),
                    }
                    table.insert(self.masterList, event)
                end
            end
        end
    end
end

function GuildHistoryManager:FilterScrollList()
    local scrollData = ZO_ScrollList_GetDataList(self.list)
    ZO_ClearNumericallyIndexedTable(scrollData)

    for i, data in ipairs(self.masterList) do
        if self.selectedSubcategory == nil or self.selectedSubcategory == data.subcategoryId then
            table.insert(scrollData, ZO_ScrollList_CreateDataEntry(GUILD_EVENT_DATA, data))
        end
    end
end

do
    local function SortFunc(listEntry1, listEntry2)
        return listEntry1.data.eventId > listEntry2.data.eventId 
    end

    function GuildHistoryManager:SortScrollList()
        local scrollData = ZO_ScrollList_GetDataList(self.list)
        if #scrollData > 1 then
            table.sort(scrollData, SortFunc)
        end
    end
end

function GuildHistoryManager:RequestInitialEvents()
    if self.guildId and self.selectedCategory then
        if not HasGuildHistoryCategoryEverBeenRequested(self.guildId, self.selectedCategory) then
            self:RequestMoreEvents()
        end
    end
end

function GuildHistoryManager:RequestMoreEvents()
    if self.guildId and self.selectedCategory then
        if self:IsShowing() then
            RequestMoreGuildHistoryCategoryEvents(self.guildId, self.selectedCategory)
        end
    end
end

--Events

function GuildHistoryManager:OnGuildHistoryCategoryUpdated(guildId, category)
    if self.guildId == guildId and self.selectedCategory == category then
        self:UpdateKeybinds()
        self.refreshGroup:MarkDirty("EventListData")
    end
end

--Global XML

function ZO_GuildHistory_OnInitialized(self)
    GUILD_HISTORY = GuildHistoryManager:New(self)
end