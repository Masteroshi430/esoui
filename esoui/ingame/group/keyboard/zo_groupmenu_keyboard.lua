ZO_GROUP_MENU_KEYBOARD_TREE_WIDTH = 300
-- 75 is the inset from the multiIcon plus the icon and spacing from ZO_IconHeader
local scrollBarOffset = 16
ZO_GROUP_MENU_KEYBOARD_TREE_LABEL_WIDTH = ZO_GROUP_MENU_KEYBOARD_TREE_WIDTH - 75 - scrollBarOffset
ZO_GROUP_MENU_KEYBOARD_TREE_SUBCATEGORY_INDENT = 75
ZO_GROUP_MENU_KEYBOARD_TREE_SUBCATEGORY_LABEL_WIDTH = ZO_GROUP_MENU_KEYBOARD_TREE_WIDTH - ZO_GROUP_MENU_KEYBOARD_TREE_SUBCATEGORY_INDENT - scrollBarOffset

local GroupMenu_Keyboard = ZO_InitializingObject:Subclass()

function GroupMenu_Keyboard:Initialize(control)
    self.control = control
    self.headerControl = self.control:GetNamedChild("Header")
    self.categoriesControl = self.control:GetNamedChild("Categories")

    local function OnStateChange(oldState, newState)
        if newState == SCENE_SHOWING  then
            KEYBIND_STRIP:AddKeybindButton(self.keybindStripDescriptor)

            if self.currentCategoryFragment then
                SCENE_MANAGER:AddFragment(self.currentCategoryFragment)
            end

            PREFERRED_ROLES:RefreshRoles()

            if self.categoryFragmentToShow then
                self:SetCurrentCategory(self.categoryFragmentToShow)
                self.categoryFragmentToShow = nil
            end

            self.categoriesRefreshGroup:TryClean()
        elseif newState == SCENE_HIDING then
            KEYBIND_STRIP:RemoveKeybindButton(self.keybindStripDescriptor)
        end
    end

    KEYBOARD_GROUP_MENU_SCENE = ZO_Scene:New("groupMenuKeyboard", SCENE_MANAGER)
    KEYBOARD_GROUP_MENU_SCENE:RegisterCallback("StateChange", OnStateChange)

    self:InitializeCategories()
    self:InitializeKeybindDescriptors()

    local function RefreshCategories()
        self.categoriesRefreshGroup:MarkDirty("List")
    end

    ZO_ACTIVITY_FINDER_ROOT_MANAGER:RegisterCallback("OnUpdateGroupStatus", function(...) self:OnUpdateGroupStatus(...) end)
    ZO_ACTIVITY_FINDER_ROOT_MANAGER:RegisterCallback("OnLevelUpdate", RefreshCategories)

    ZO_COLLECTIBLE_DATA_MANAGER:RegisterCallback("OnCollectionUpdated", RefreshCategories)

    self.control:RegisterForEvent(EVENT_PLAYER_ACTIVATED, RefreshCategories)
    self.control:RegisterForEvent(EVENT_QUEST_COMPLETE, RefreshCategories)
end

function GroupMenu_Keyboard:InitializeCategories()
    self.navigationTree = ZO_Tree:New(self.categoriesControl:GetNamedChild("ScrollChild"), 60, -10, ZO_GROUP_MENU_KEYBOARD_TREE_WIDTH)
    self.categoryFragmentToNodeLookup = {}
    self.nodeList = {}

    -- Categories refresh group
    local categoriesRefreshGroup = ZO_OrderedRefreshGroup:New(ZO_ORDERED_REFRESH_GROUP_AUTO_CLEAN_PER_FRAME)
    categoriesRefreshGroup:AddDirtyState("List", function()
        self:RefreshCategories()
    end)

    categoriesRefreshGroup:SetActive(function()
        return self:IsCategoriesRefreshGroupActive()
    end)

    categoriesRefreshGroup:MarkDirty("List")
    self.categoriesRefreshGroup = categoriesRefreshGroup

    local function RefreshNode(control, categoryData, open, enabled)
        if control.icon then
            local iconTexture = open and categoryData.pressedIcon or categoryData.normalIcon
            iconTexture = not enabled and categoryData.disabledIcon or iconTexture
            control.icon:SetTexture(iconTexture)
            control.iconHighlight:SetTexture(categoryData.mouseoverIcon)

            ZO_IconHeader_Setup(control, open, enabled)
        end
    end

    local function SetupNode(node, control, categoryData, open)
        control.text:SetText(categoryData.name)
        control.text:SetModifyTextType(MODIFY_TEXT_TYPE_UPPERCASE)

        local disabled = false
        if categoryData then
            disabled = categoryData.activityFinderObject and (categoryData.activityFinderObject:GetLevelLockInfo() or categoryData.activityFinderObject:GetNumLocations() == 0) or false
            disabled = disabled or (categoryData.isZoneStories and ZONE_STORIES_MANAGER:GetZoneData(ZONE_STORIES_MANAGER.GetDefaultZoneSelection()) == nil) or false
        end

        local selected = node.selected or open
        RefreshNode(control, categoryData, selected, not disabled)
    end

    local function SetupParentNode(node, control, categoryData, open, userRequested)
        SetupNode(node, control, categoryData, open)

        if open and userRequested then
            self.navigationTree:SelectFirstChild(node)
        end
    end

    local function SetupChildNode(node, control, categoryData, open)
        control:SetSelected(false)
        control:SetText(categoryData.name)
    end

    local function OnNodeSelected(control, categoryData, selected, reselectingDuringRebuild)
        control:SetSelected(selected)

        if selected then
            if categoryData.activityFinderObject then
                ZO_ACTIVITY_FINDER_ROOT_MANAGER:ClearSelections()
            end

            if KEYBOARD_GROUP_MENU_SCENE:IsShowing() then
                if self.currentCategoryFragment then
                    SCENE_MANAGER:RemoveFragment(self.currentCategoryFragment)
                end

                -- Order matters:
                if categoryData.onTreeEntrySelected then
                    categoryData.onTreeEntrySelected(categoryData)
                end
                SCENE_MANAGER:AddFragment(categoryData.categoryFragment)
            end

            self.currentCategoryFragment = categoryData.categoryFragment
        end

        RefreshNode(control, categoryData, selected, control.enabled)
    end

    local CHILD_SPACING = 0
    local NO_SELECTION_FUNCTION = nil
    local NO_EQUALITY_FUNCTION = nil
    self.navigationTree:AddTemplate("ZO_GroupMenuKeyboard_StatusIconHeader", SetupParentNode, NO_SELECTION_FUNCTION, NO_EQUALITY_FUNCTION, ZO_GROUP_MENU_KEYBOARD_TREE_SUBCATEGORY_INDENT, CHILD_SPACING)
    self.navigationTree:AddTemplate("ZO_GroupMenuKeyboard_StatusIconChildlessHeader", SetupNode, OnNodeSelected)
    self.navigationTree:AddTemplate("ZO_GroupMenuKeyboard_Subcategory", SetupChildNode, OnNodeSelected)
    self.navigationTree:SetExclusive(true)
    self.navigationTree:SetOpenAnimation("ZO_TreeOpenAnimation")
end

function GroupMenu_Keyboard:InitializeKeybindDescriptors()
    self.keybindStripDescriptor =
    {
        -- Invite to Group
        alignment = KEYBIND_STRIP_ALIGN_CENTER,

        name = GetString(SI_GROUP_WINDOW_INVITE_PLAYER),
        keybind = "UI_SHORTCUT_PRIMARY",
        
        callback = function()
            ZO_Dialogs_ShowDialog("GROUP_INVITE")
        end,

        visible = function()
            local playerIsGrouped, playerIsLeader, groupSize = ZO_ACTIVITY_FINDER_ROOT_MANAGER:GetGroupStatus()
            return IsGroupModificationAvailable() and (not playerIsGrouped or (playerIsLeader and groupSize < MAX_GROUP_SIZE_THRESHOLD))
        end
    }
end

function GroupMenu_Keyboard:OnUpdateGroupStatus()
    if KEYBOARD_GROUP_MENU_SCENE:IsShowing() then
        KEYBIND_STRIP:UpdateKeybindButton(self.keybindStripDescriptor)
    end
end

function GroupMenu_Keyboard:SetCategoryOnShow(categoryFragment)
    self.categoryFragmentToShow = categoryFragment
end

function GroupMenu_Keyboard:SetCurrentCategory(categoryFragment)
    if KEYBOARD_GROUP_MENU_SCENE:IsShowing() then
        local node = self.categoryFragmentToNodeLookup[categoryFragment]
        self.navigationTree:SelectNode(node)
    end
end

function GroupMenu_Keyboard:ShowCategory(categoryFragment)
    if KEYBOARD_GROUP_MENU_SCENE:IsShowing() then
        self:SetCurrentCategory(categoryFragment)
    else
        self:SetCategoryOnShow(categoryFragment)
        MAIN_MENU_KEYBOARD:RefreshCategoryBar()
        MAIN_MENU_KEYBOARD:ShowScene("groupMenuKeyboard")
    end
end

function GroupMenu_Keyboard:IsCategoriesRefreshGroupActive()
    return KEYBOARD_GROUP_MENU_SCENE:IsShowing()
end

do
    local LOCK_TEXTURE = zo_iconFormat("EsoUI/Art/Miscellaneous/locked_disabled.dds", "100%", "100%")
    local CHAMPION_ICON = zo_iconFormat(ZO_GetChampionPointsIcon(), "100%", "100%")

    function GroupMenu_Keyboard:OnActivityCategoryMouseEnter(control, data)
        ZO_IconHeader_OnMouseEnter(control)
        if not control.enabled then
            local isLevelLocked, lowestLevelLimit, lowestRankLimit = data.activityFinderObject:GetLevelLockInfo()
            local lockedText
            if isLevelLocked then
                if lowestLevelLimit then
                    lockedText = zo_strformat(SI_ACTIVITY_FINDER_TOOLTIP_LEVEL_LOCK, LOCK_TEXTURE, lowestLevelLimit)
                elseif lowestRankLimit then
                    lockedText = zo_strformat(SI_ACTIVITY_FINDER_TOOLTIP_CHAMPION_LOCK, LOCK_TEXTURE, CHAMPION_ICON, lowestRankLimit)
                end
            else
                local numLocations = data.activityFinderObject:GetNumLocations()
                if numLocations == 0 then
                    lockedText = zo_strformat(SI_ACTIVITY_FINDER_TOOLTIP_NO_ACTIVITIES_LOCK, LOCK_TEXTURE)
                end
            end

            if lockedText then
                InitializeTooltip(InformationTooltip, control, RIGHT, -10)
                SetTooltipText(InformationTooltip, lockedText)
            end
        end
    end

    function GroupMenu_Keyboard:OnZoneStoriesCategoryMouseEnter(control, data)
        ZO_IconHeader_OnMouseEnter(control)
        if not control.enabled then
            local isLocked = ZONE_STORIES_MANAGER:GetZoneData(ZONE_STORIES_MANAGER.GetDefaultZoneSelection()) == nil
            if isLocked then
                local lockedText = zo_strformat(SI_ZONE_STORY_TOOLTIP_UNAVAILABLE_IN_ZONE, LOCK_TEXTURE)
                InitializeTooltip(InformationTooltip, control, RIGHT, -10)
                SetTooltipText(InformationTooltip, lockedText)
            end
        end
    end
end

do
    local function PrioritySort(item1, item2)
        local priority1, priority2 = item1.priority, item2.priority
        if priority1 == priority2 then
            return item1.name < item2.name
        elseif priority1 and priority2 then
            return priority1 < priority2
        else
            return priority1 ~= nil
        end
    end

    function GroupMenu_Keyboard:AddCategoryTreeNode(nodeData, parentNode)
        local nodeTemplate
        if parentNode then
            nodeTemplate = "ZO_GroupMenuKeyboard_Subcategory"
        elseif nodeData.children or (nodeData.getChildrenFunction and #(nodeData.getChildrenFunction()) > 0) then
            nodeTemplate = "ZO_GroupMenuKeyboard_StatusIconHeader"
        else
            nodeTemplate = "ZO_GroupMenuKeyboard_StatusIconChildlessHeader"
        end

        local node = self.navigationTree:AddNode(nodeTemplate, nodeData, parentNode)
        if nodeData.categoryFragment then
            local existingFragmentNode = self.categoryFragmentToNodeLookup[nodeData.categoryFragment]
            if not existingFragmentNode or existingFragmentNode:GetData().priority > nodeData.priority then
                self.categoryFragmentToNodeLookup[nodeData.categoryFragment] = node
            end
        end
        if nodeData.getChildrenFunction then
            node.getChildrenFunction = nodeData.getChildrenFunction
        end

        if nodeData.activityFinderObject then
            node.control.OnMouseEnter = function(control) self:OnActivityCategoryMouseEnter(control, nodeData) end
        elseif nodeData.isZoneStories then
            node.control.OnMouseEnter = function(control) self:OnZoneStoriesCategoryMouseEnter(control, nodeData) end
        end

        return node
    end

    function GroupMenu_Keyboard:AddCategoryTreeNodes(nodeDataList, parentNode)
        table.sort(nodeDataList, PrioritySort)

        for index, nodeData in ipairs(nodeDataList) do
            local node = self:AddCategoryTreeNode(nodeData, parentNode)

            local children = nodeData.children
            if nodeData.getChildrenFunction then
                children = nodeData.getChildrenFunction()
            end

            if children then
                self:AddCategoryTreeNodes(children, node)
            end
        end
    end

    function GroupMenu_Keyboard:AddCategory(data)
        self.navigationTree:Reset()
        ZO_ClearTable(self.categoryFragmentToNodeLookup)

        table.insert(self.nodeList, data)
        self:AddCategoryTreeNodes(self.nodeList)

        self.navigationTree:Commit()
    end
end

function GroupMenu_Keyboard:RebuildCategories()
    local selectedParentData = nil
    local selectedNode = self.navigationTree:GetSelectedNode()
    if selectedNode then
        local parentNode = selectedNode:GetParent()
        if parentNode then
            selectedParentData = parentNode:GetData()
        end
    end

    self.navigationTree:Reset()
    ZO_ClearTable(self.categoryFragmentToNodeLookup)

    self:AddCategoryTreeNodes(self.nodeList)

    --Order matters: Do this after the category nodes have been added
    local nodeToSelect
    if selectedParentData then
        local parentNode = self.navigationTree:GetTreeNodeByData(selectedParentData)
        if parentNode then
            nodeToSelect = parentNode:GetChild(1)
        end
    end

    self.navigationTree:Commit(nodeToSelect)
end

function GroupMenu_Keyboard:HideTree()
    self.categoriesControl:SetHidden(true)
end

function GroupMenu_Keyboard:ShowTree()
    self.categoriesControl:SetHidden(false)
end

function GroupMenu_Keyboard:RefreshCategories()
    self.navigationTree:RefreshVisible()
    self.navigationTree:Commit()
end

function ZO_GroupMenuKeyboard_OnInitialized(control)
    GROUP_MENU_KEYBOARD = GroupMenu_Keyboard:New(control)
end