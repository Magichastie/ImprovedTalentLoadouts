local addonName, TalentLoadouts = ...

local talentUI = "Blizzard_ClassTalentUI"
local LibDD = LibStub:GetLibrary("LibUIDropDownMenu-4.0")
local LibSerialize = LibStub("LibSerialize")
local LibDeflate = LibStub("LibDeflate")
local internalVersion = 7
local NUM_ACTIONBAR_BUTTONS = 15 * 12
local ITL_LOADOUT_NAME = "[ITL] Temp"

local LDB = LibStub:GetLibrary("LibDataBroker-1.1")
local dataObjText = "ITL: %s, %s"
local dataObj = LDB:NewDataObject(addonName, {type = "data source", text = "ITL: Spec, Loadout"})

local dropdownFont = CreateFont("ITL_DropdownFont")
local iterateLoadouts

--- Create an iterator for a hash table.
-- @param t:table The table to create the iterator for.
-- @param order:function A sort function for the keys.
-- @return function The iterator usable in a loop.
local function spairs(t, order)
    local keys = {}
    for k in pairs(t) do
        keys[#keys + 1] = k
    end

    if order then
        table.sort(
            keys,
            function(a, b)
                return order(t, a, b)
            end
        )
    else
        table.sort(keys)
    end

    local i = 0
    return function()
        i = i + 1
        if keys[i] then
            return keys[i], t[keys[i]], keys[i + 1]
        end
    end
end

local function sortByName(t, a, b)
    if t[a] and t[b] and t[a].name and t[b].name then
        return t[a].name < t[b].name
    end
end

local defaultDB = {
    loadouts = {
        globalLoadouts = {},
        characterLoadouts = {},
    },
    actionbars = {
        macros = {
            global = {},
            char = {},
        }
    }
}

local hooks = {}
local function HookFunction(namespace, key, func)
    hooksecurefunc(namespace, key, function()
        if hooks[key] then
            func()
        end
    end)
    hooks[key] = true
end

local function UnhookFunction(key)
    hooks[key] = nil
end

local RegisterEvent, UnregisterEvent
do
    local eventFrame = CreateFrame("Frame")
    function RegisterEvent(event)
        eventFrame:RegisterEvent(event)
    end

    function UnregisterEvent(event)
        eventFrame:UnregisterEvent(event)
    end

    RegisterEvent("ADDON_LOADED")
    RegisterEvent("PLAYER_ENTERING_WORLD")
    RegisterEvent("TRAIT_CONFIG_UPDATED")
    RegisterEvent("TRAIT_CONFIG_CREATED")
    RegisterEvent("PLAYER_REGEN_ENABLED")
    RegisterEvent("PLAYER_REGEN_DISABLED")
    RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
    RegisterEvent("UPDATE_MACROS")
    RegisterEvent("ACTIVE_PLAYER_SPECIALIZATION_CHANGED")
    RegisterEvent("EQUIPMENT_SWAP_FINISHED")
    RegisterEvent("VOID_STORAGE_UPDATE")
    eventFrame:SetScript("OnEvent", function(self, event, arg1, arg2, arg3)
        if event == "ADDON_LOADED" then
            if arg1 == addonName then
                TalentLoadouts:Initialize()
            elseif arg1 == talentUI then
                self:UnregisterEvent("ADDON_LOADED")
                TalentLoadouts:InitializeTalentLoadouts()
                TalentLoadouts:UpdateSpecID()
                TalentLoadouts:InitializeDropdown()
                TalentLoadouts:InitializeButtons()
                TalentLoadouts:InitializeHooks()
            end
        elseif event == "PLAYER_ENTERING_WORLD" then
            TalentLoadouts:InitializeCharacterDB()
            TalentLoadouts:SaveCurrentLoadouts()
            TalentLoadouts:UpdateDataObj(ITLAPI:GetCurrentLoadout())
            TalentLoadouts:DeleteTempLoadouts()
            TalentLoadouts:UpdateKnownFlyouts()
        elseif event == "VOID_STORAGE_UPDATE" then
            TalentLoadouts:UpdateKnownFlyouts()
        elseif event == "PLAYER_REGEN_ENABLED" then
            RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
        elseif event == "PLAYER_REGEN_DISABLED" then
            UnregisterEvent("UNIT_SPELLCAST_SUCCEEDED")
        elseif event == "TRAIT_CONFIG_UPDATED" then
            TalentLoadouts:UpdateConfig(arg1)

            if not TalentLoadouts.blizzImported then
                TalentLoadouts.pendingLoadout = nil
            end
        elseif event == "TRAIT_CONFIG_CREATED" and TalentLoadouts.blizzImported then
            if arg1.type ~= Enum.TraitConfigType.Combat then return end
            TalentLoadouts:LoadAsBlizzardLoadout(arg1)
        elseif event == "UPDATE_MACROS" then
            TalentLoadouts:UpdateMacros()
        elseif event == "ACTIVE_PLAYER_SPECIALIZATION_CHANGED" then
            TalentLoadouts.charDB.lastCategory = nil
            TalentLoadouts:UpdateSpecID(true)
            TalentLoadouts:UpdateActionBar()
            TalentLoadouts:UpdateDropdownText()
            TalentLoadouts:UpdateSpecButtons()
            TalentLoadouts:UpdateDataObj()
            TalentLoadouts:UpdateIterator()
        elseif event == "CONFIG_COMMIT_FAILED" then
            C_Timer.After(0.1, function()
                if (TalentLoadouts.pendingLoadout and not UnitCastingInfo("player")) or TalentLoadouts.lastUpdated then
                    TalentLoadouts:OnLoadoutFail(event)
                end
            end)
        elseif event == "UNIT_SPELLCAST_SUCCEEDED" and arg1 == "player" and arg3 == Constants.TraitConsts.COMMIT_COMBAT_TRAIT_CONFIG_CHANGES_SPELL_ID then
            if TalentLoadouts.pendingLoadout then
                TalentLoadouts:OnLoadoutSuccess()
            else
                TalentLoadouts:OnUnknownLoadoutSuccess()
            end
        elseif event == "EQUIPMENT_SWAP_FINISHED" and not arg1 then
            local name = C_EquipmentSet.GetEquipmentSetInfo(arg2)
            TalentLoadouts:Print("Equipment swap failed:", name)
        end
    end)
end

local function GetPlayerName()
    local name, realm = UnitName("player"), GetNormalizedRealmName()
    return name .. "-" .. realm
end

function TalentLoadouts:Initialize()
    ImprovedTalentLoadoutsDB = ImprovedTalentLoadoutsDB or TalentLoadoutProfilesDB or defaultDB
    if not ImprovedTalentLoadoutsDB.classesInitialized then
        self:InitializeClassDBs()
        ImprovedTalentLoadoutsDB.classesInitialized = true
    end
    self:CheckForDBUpdates()
    dropdownFont:SetFont(GameFontNormal:GetFont(), ImprovedTalentLoadoutsDB.options.fontSize, "")
end

function TalentLoadouts:InitializeClassDBs()
    local classes = {"HUNTER", "WARLOCK", "PRIEST", "PALADIN", "MAGE", "ROGUE", "DRUID", "SHAMAN", "WARRIOR", "DEATHKNIGHT", "MONK", "DEMONHUNTER", "EVOKER"}
    for i, className in ipairs(classes) do
        ImprovedTalentLoadoutsDB.loadouts.globalLoadouts[className] = ImprovedTalentLoadoutsDB.loadouts.globalLoadouts[className] or {configIDs = {}, categories = {}}
    end
end

function TalentLoadouts:InitializeCharacterDB()
    local playerName = GetPlayerName()
    if not ImprovedTalentLoadoutsDB.loadouts.characterLoadouts[playerName] then
        ImprovedTalentLoadoutsDB.loadouts.characterLoadouts[playerName] = {}
    end

    if not ImprovedTalentLoadoutsDB.actionbars.macros.char[playerName] then
        ImprovedTalentLoadoutsDB.actionbars.macros.char[playerName] = {}
    end

    ImprovedTalentLoadoutsDB.actionbars.macros.global = ImprovedTalentLoadoutsDB.actionbars.macros.global or {}
    self.charDB = ImprovedTalentLoadoutsDB.loadouts.characterLoadouts[playerName]
    self.globalDB = ImprovedTalentLoadoutsDB.loadouts.globalLoadouts[UnitClassBase("player")]
    self.charMacros = ImprovedTalentLoadoutsDB.actionbars.macros.char[playerName]
    self.globalMacros = ImprovedTalentLoadoutsDB.actionbars.macros.global
    self.flyouts = {}
    self.specID = PlayerUtil.GetCurrentSpecID()
    self:CheckDBIntegrity()
    self:CheckForVersionUpdates()
    self.initialized = true
    self:UpdateMacros()
    self:UpdateIterator()
end

-- Not sure how that can happen but apparently it was a problem for someone. Maybe there is another AddOn that overwrites my db?
function TalentLoadouts:CheckDBIntegrity()
    ImprovedTalentLoadoutsDB.loadouts = ImprovedTalentLoadoutsDB.loadouts or {globalLoadouts = {}, characterLoadouts = {}}
    ImprovedTalentLoadoutsDB.loadouts.globalLoadouts = ImprovedTalentLoadoutsDB.loadouts.globalLoadouts or {}
    ImprovedTalentLoadoutsDB.loadouts.characterLoadouts = ImprovedTalentLoadoutsDB.loadouts.characterLoadouts or {}

    if not self.globalDB then
        ImprovedTalentLoadoutsDB.classesInitialized = nil
        self:Initialize()
        self.globalDB = ImprovedTalentLoadoutsDB.loadouts.globalLoadouts[UnitClassBase("player")]
    end

    if not self.charDB then
        local playerName = GetPlayerName()
        self.charDB = ImprovedTalentLoadoutsDB.loadouts.characterLoadouts[playerName]
    end
end

function TalentLoadouts:CheckForDBUpdates()
    ImprovedTalentLoadoutsDB.options = ImprovedTalentLoadoutsDB.options or {
        fontSize = ImprovedTalentLoadoutsDB.fontSize or 10,
        simc = ImprovedTalentLoadoutsDB.simc == nil and true or ImprovedTalentLoadoutsDB.simc,
        applyLoadout = ImprovedTalentLoadoutsDB.applyLoadout == nil and true or ImprovedTalentLoadoutsDB.applyLoadout,
        showSpecButtons = ImprovedTalentLoadoutsDB.showSpecButtons == nil and true or ImprovedTalentLoadoutsDB.showSpecButtons,
        specButtonType = "text",
    }

    local options = ImprovedTalentLoadoutsDB.options
    local optionKeys = {
        ["loadActionbars"] = true,
        ["clearEmptySlots"] = false,
        ["findMacroByName"] = false,
        ["loadBlizzard"] = false,
        ["showCategoryName"] = false,
        ["sortLoadoutsByName"] = false,
        ["loadActionbarsSpec"] = false,
        ["loadAsBlizzard"] = true,
        ["useAddOnLoadoutFallback"] = false,
    }

    for key, defaultValue in ipairs(optionKeys) do
        if options[key] == nil then
            options[key] = defaultValue
        end
    end
end


function TalentLoadouts:CheckForVersionUpdates()
    local currentVersion = ImprovedTalentLoadoutsDB.version

    if (currentVersion or 0) < 7 then
        ImprovedTalentLoadoutsDB.options.loadAsBlizzard = true
    end

    ImprovedTalentLoadoutsDB.version = internalVersion
end

function TalentLoadouts:UpdateSpecID(isRespec)
    if not self.loaded then
        UIParentLoadAddOn("Blizzard_ClassTalentUI")
        self.loaded = true
    end

    self.specID = PlayerUtil.GetCurrentSpecID()
    self.treeID = securecall(ClassTalentFrame.TalentsTab.GetTalentTreeID, ClassTalentFrame.TalentsTab)

    if isRespec then
        self.charDB.lastLoadout = nil
    end
end

function TalentLoadouts:UpdateActionBar()
    if not ImprovedTalentLoadoutsDB.options.loadActionbarsSpec then return end

    local currentSpecID = self.specID
    local configInfo = self.globalDB.configIDs[currentSpecID][self.charDB[currentSpecID]]
    if configInfo and configInfo.actionBars then
        -- Players are reporting that it sometimes doesn't work after changing the specialization. As I can't reproduce I will add a small delay for now, maybe that fixes it.
        C_Timer.After(0.1, function()
            self:LoadActionBar(configInfo.actionBars, configInfo.name)
        end)
    elseif not configInfo then
        self:Print("Couldn't find the last loadout of the spec. Make sure that the dropdown doesn't say \"Unknown\". This means that you've changed the tree without updating a loadout.")
    end
end

function TalentLoadouts:UpdateIterator()
    if ImprovedTalentLoadoutsDB.options.sortLoadoutsByName then
        iterateLoadouts = GenerateClosure(spairs, TalentLoadouts.globalDB.configIDs[self.specID] or {}, sortByName)
    else
        iterateLoadouts = GenerateClosure(pairs, TalentLoadouts.globalDB.configIDs[self.specID] or {})
    end
end

-- WIP, Wasn't able to reproduce the issue of empty loadout info
local function CreateEntryInfoFromString(configID, exportString, treeID, repeating)
    configID = C_Traits.GetConfigInfo(configID) and configID or C_ClassTalents.GetActiveConfigID()
    local treeID = securecall(ClassTalentFrame.TalentsTab.GetTalentTreeID, ClassTalentFrame.TalentsTab)
    local importStream = ExportUtil.MakeImportDataStream(exportString)
    local _ = securecallfunction(ClassTalentFrame.TalentsTab.ReadLoadoutHeader, ClassTalentFrame.TalentsTab, importStream)
    local loadoutContent = securecallfunction(ClassTalentFrame.TalentsTab.ReadLoadoutContent, ClassTalentFrame.TalentsTab, importStream, treeID)
    local success, loadoutEntryInfo = pcall(ClassTalentFrame.TalentsTab.ConvertToImportLoadoutEntryInfo, ClassTalentFrame.TalentsTab, configID, treeID, loadoutContent)
    -- TalentLoadouts:Print(success, loadoutEntryInfo and #loadoutEntryInfo)
    if success and #loadoutEntryInfo > 0 then
        return loadoutEntryInfo
    elseif not repeating then
        return CreateEntryInfoFromString(configID, exportString, treeID, true)
    else
        TalentLoadouts:Print("Wasn't able to import the loadout. Try reloading or restarting your game.")
    end
end

local function CreateExportString(configInfo, configID, specID, skipEntryInfo)
    local treeID = (configInfo and configInfo.treeIDs[1]) or securecall(ClassTalentFrame.TalentsTab.GetTalentTreeID, ClassTalentFrame.TalentsTab)
    local treeHash = treeID and C_Traits.GetTreeHash(treeID);

    if treeID and treeID == TalentLoadouts.treeID then
        local serializationVersion = C_Traits.GetLoadoutSerializationVersion()
        local dataStream = ExportUtil.MakeExportDataStream()

        ClassTalentFrame.TalentsTab:WriteLoadoutHeader(dataStream, serializationVersion, specID, treeHash)
        ClassTalentFrame.TalentsTab:WriteLoadoutContent(dataStream , configID, treeID)

        local exportString = dataStream:GetExportString()

        local loadoutEntryInfo
        if not skipEntryInfo then
            loadoutEntryInfo = CreateEntryInfoFromString(configID, exportString, treeID)
        end

        return exportString, loadoutEntryInfo, treeHash
    end
end

function TalentLoadouts:InitializeTalentLoadouts()
    if not self.globalDB or not self.charDB then
        self:CheckDBIntegrity()
    end

    local specConfigIDs = self.globalDB.configIDs
    local currentSpecID = self.specID
    if specConfigIDs[currentSpecID] then
        for configID, configInfo in pairs(specConfigIDs[currentSpecID]) do
            if C_Traits.GetConfigInfo(configID) and (not configInfo.exportString or not configInfo.entryInfo or not configInfo.treeHash) then
                configInfo.exportString, configInfo.entryInfo, configInfo.treeHash = CreateExportString(configInfo, configID, currentSpecID)
            end
        end
    else
        self:UpdateSpecID()
        self:SaveCurrentLoadouts()
    end

    self.loaded = true
end

function TalentLoadouts:InitializeTalentLoadout(newConfigID)
    local specConfigIDs = self.globalDB.configIDs
    local currentSpecID = self.specID
    if not specConfigIDs[currentSpecID] then
        self:UpdateSpecID()
        currentSpecID = self.specID
        specConfigIDs[currentSpecID] = {}
    end

    local configID = C_Traits.GetConfigInfo(newConfigID) and newConfigID or C_ClassTalents.GetActiveConfigID()
    local configInfo = specConfigIDs[currentSpecID][newConfigID]
    if configInfo and (not configInfo.exportString or not configInfo.entryInfo or not configInfo.treeHash) then
        configInfo.exportString, configInfo.entryInfo, configInfo.treeHash = CreateExportString(configInfo, configID, currentSpecID)
    end
end

function TalentLoadouts:UpdateConfig(configID)
    if not self.loaded then
        UIParentLoadAddOn("Blizzard_ClassTalentUI")
        self.loaded = true
        self:UpdateConfig(configID)
        return
    end

    local currentSpecID = self.specID
    local configInfo = self.globalDB.configIDs[currentSpecID][configID]
    if configInfo then
        local newConfigInfo = C_Traits.GetConfigInfo(configID)
        configInfo.exportString, configInfo.entryInfo = CreateExportString(configInfo, configID, currentSpecID)
        configInfo.name = newConfigInfo and newConfigInfo.name or configInfo.name
    else
        self:SaveLoadout(configID, currentSpecID)
    end
end

function TalentLoadouts:SaveLoadout(configID, currentSpecID)
    local specLoadouts = self.globalDB.configIDs[currentSpecID]
    local configInfo = C_Traits.GetConfigInfo(configID)
    if configInfo.type == 1 and configInfo.name ~= ITL_LOADOUT_NAME then
        configInfo.default = configID == C_ClassTalents.GetActiveConfigID() or nil
        specLoadouts[configID] = configInfo
        self:InitializeTalentLoadout(configID)
    end
end

-- Delete duplicate Temp Loadouts
function TalentLoadouts:DeleteTempLoadouts()
    if InCombatLockdown() then return end

    local specID = self.specID
    local configIDs = C_ClassTalents.GetConfigIDsBySpecID(specID)

    local counter = 0
    for _, configID in ipairs(configIDs) do
        local configInfo = C_Traits.GetConfigInfo(configID)
        if configInfo.name == ITL_LOADOUT_NAME then
            if counter > 1 then
                C_ClassTalents.DeleteConfig(configID)
            else
                self.charDB.tempLoadout = configID
            end

            counter = counter + 1
        end
    end

    if ClassTalentFrame and ClassTalentFrame:IsShown() then
        C_ClassTalents.UpdateLastSelectedSavedConfigID(specID, nil)
        securecall(ClassTalentFrame.TalentsTab.RefreshLoadoutOptions, ClassTalentFrame.TalentsTab)
        securecall(ClassTalentFrame.TalentsTab.LoadoutDropDown.ClearSelection, ClassTalentFrame.TalentsTab.LoadoutDropDown)
    end

    self.pendingDeletion = nil
end


function TalentLoadouts:GetExportStringForTree(skipEntryInfo)
    return CreateExportString(nil, C_ClassTalents.GetActiveConfigID(), self.specID, skipEntryInfo)
end

function TalentLoadouts:SaveCurrentLoadouts()
    if not self.globalDB or not self.charDB then
        self:CheckDBIntegrity()
    end

    for specIndex=1, GetNumSpecializations() do
        local specID = GetSpecializationInfo(specIndex)
        self.globalDB.configIDs[specID] = self.globalDB.configIDs[specID] or {}

        local specLoadouts = self.globalDB.configIDs[specID]
        local configIDs = C_ClassTalents.GetConfigIDsBySpecID(specID)

        for _, configID in ipairs(configIDs) do
            if not specLoadouts[configID] then
                local configInfo = C_Traits.GetConfigInfo(configID)
                if not (configInfo.name == ITL_LOADOUT_NAME) then
                    specLoadouts[configID] = configInfo
                end
            end
        end
    end

    local currentSpecID = self.specID
    local activeConfigID = C_ClassTalents.GetActiveConfigID()
    if activeConfigID then
        self.globalDB.configIDs[currentSpecID][activeConfigID] = self.globalDB.configIDs[currentSpecID][activeConfigID] or C_Traits.GetConfigInfo(activeConfigID)
        self.globalDB.configIDs[currentSpecID][activeConfigID].default = true
    end
end

function TalentLoadouts:UpdateDataObj(configInfo)
    local _, name = GetSpecializationInfoByID(TalentLoadouts.specID)
    dataObj.text = dataObjText:format(name, configInfo and configInfo.name or "Unknown")
end

function TalentLoadouts:LoadGearAndLayout(configInfo)
    if not InCombatLockdown() then
        if configInfo.gearset then
            -- Without delay it may fail.
            C_Timer.After(0, function() EquipmentManager_EquipSet(configInfo.gearset) end)
        end

        if configInfo.layout then
            C_EditMode.SetActiveLayout(configInfo.layout)
        end
    else
        self:Print("Can't change gear or layouts in combat")
    end
end

local function ResetTree(treeID, treeType)
    local activeConfigID = C_ClassTalents.GetActiveConfigID()

    if C_Traits.ConfigHasStagedChanges(activeConfigID) then
        C_Traits.RollbackConfig(activeConfigID)
    end

    if not treeType or treeType == 1 then
        C_Traits.ResetTree(activeConfigID, treeID)
    else
        local currencyInfo = C_Traits.GetTreeCurrencyInfo(activeConfigID, treeID, false)
        if treeType == 2 then
            C_Traits.ResetTreeByCurrency(activeConfigID, treeID, currencyInfo[1].traitCurrencyID)
        elseif treeType == 3 then
            C_Traits.ResetTreeByCurrency(activeConfigID, treeID, currencyInfo[2].traitCurrencyID)
        end
    end
end

local function CommitLoadout()
    local configInfo = TalentLoadouts.pendingLoadout
    if configInfo then
        local activeConfigID = C_ClassTalents.GetActiveConfigID()

        local entryInfo = configInfo.entryInfo
        table.sort(entryInfo, function(a, b)
            local nodeA = C_Traits.GetNodeInfo(activeConfigID, a.nodeID)
            local nodeB = C_Traits.GetNodeInfo(activeConfigID, b.nodeID)

            return nodeA.posY < nodeB.posY or (nodeA.posY == nodeB.posY and nodeA.posX < nodeB.posX)
        end)

        for i=1, #entryInfo do
            local entry = entryInfo[i]
            local nodeInfo = C_Traits.GetNodeInfo(activeConfigID, entry.nodeID)
            if nodeInfo.isAvailable and nodeInfo.isVisible then
                if nodeInfo.type == Enum.TraitNodeType.Selection then
                    C_Traits.SetSelection(activeConfigID, entry.nodeID, entry.selectionEntryID)
                end

                if C_Traits.CanPurchaseRank(activeConfigID, entry.nodeID, entry.selectionEntryID) then
                    for rank=1, entry.ranksPurchased do
                        C_Traits.PurchaseRank(activeConfigID, entry.nodeID)
                    end
                end
            end
        end

        if ImprovedTalentLoadoutsDB.options.applyLoadout then
            local canChange, _, changeError = C_ClassTalents.CanChangeTalents()
            if not canChange then 
                if changeError == ERR_TALENT_FAILED_UNSPENT_TALENT_POINTS then
                    configInfo.error = true
                end
        
                TalentLoadouts:OnLoadoutFail()
                TalentLoadouts:Print("|cffff0000Can't load Loadout.|r", changeError)
                return
            end

            if pcall(C_Traits.GetConfigInfo, TalentLoadouts.charDB.tempLoadout) then
                --securecallfunction(ClassTalentFrame.TalentsTab.UpdateTreeCurrencyInfo, ClassTalentFrame.TalentsTab)
                RunNextFrame(GenerateClosure(C_ClassTalents.CommitConfig, TalentLoadouts.charDB.tempLoadout))
                RunNextFrame(GenerateClosure(C_ClassTalents.UpdateLastSelectedSavedConfigID, TalentLoadouts.specID, TalentLoadouts.charDB.tempLoadout))
            else
                --securecallfunction(ClassTalentFrame.TalentsTab.UpdateTreeCurrencyInfo, ClassTalentFrame.TalentsTab)
                RunNextFrame(GenerateClosure(C_ClassTalents.CommitConfig, activeConfigID))
            end

            RegisterEvent("CONFIG_COMMIT_FAILED")
        else
            HookFunction(C_Traits, "RollbackConfig", TalentLoadouts.OnLoadoutFail)
        end

        if not C_Traits.ConfigHasStagedChanges(activeConfigID) and TalentLoadouts.pendingLoadout then
            TalentLoadouts:OnLoadoutSuccess()
        end
    end
end

function TalentLoadouts:LoadAsBlizzardLoadout(newConfigInfo)
    if newConfigInfo.name == ITL_LOADOUT_NAME then
        if not self.charDB.tempLoadout or self.charDB.tempLoadout ~= newConfigInfo.ID then
            self.charDB.tempLoadout = newConfigInfo.ID
            C_ClassTalents.SetUsesSharedActionBars(newConfigInfo.ID, true)
        end

        ResetTree(newConfigInfo.treeIDs[1], newConfigInfo.type)
        RunNextFrame(CommitLoadout)
    end
end

local function LoadBlizzardLoadout(configID, currentSpecID, configInfo, categoryInfo)
    C_ClassTalents.LoadConfig(configID, true)
    C_ClassTalents.UpdateLastSelectedSavedConfigID(currentSpecID, nil)
    TalentLoadouts.pendingLoadout = configInfo
    TalentLoadouts.pendingCategory = categoryInfo
    TalentLoadouts.lastUpdated = nil
    TalentLoadouts.lastUpdatedCategory = nil
    TalentLoadouts:UpdateDropdownText()
    TalentLoadouts:UpdateDataObj(configInfo)
    TalentLoadouts:LoadGearAndLayout(configInfo)
end

local function LoadLoadout(self, configInfo, categoryInfo, forceBlizzardDisable)
    if not configInfo then return end

    local currentSpecID = TalentLoadouts.specID
    local configID = configInfo.ID

    if ImprovedTalentLoadoutsDB.options.loadBlizzard and C_Traits.GetConfigInfo(configID) then
        LoadBlizzardLoadout(configID, currentSpecID, configInfo, categoryInfo)
        return
    end

    if not forceBlizzardDisable and ImprovedTalentLoadoutsDB.options.loadAsBlizzard then
        local tempLoadoutInfo = TalentLoadouts.charDB.tempLoadout and C_Traits.GetConfigInfo(TalentLoadouts.charDB.tempLoadout)
        local canCreate = C_ClassTalents.CanCreateNewConfig()
        if (tempLoadoutInfo or canCreate) and TalentLoadouts.charDB.lastLoadout ~= configInfo.ID then
            TalentLoadouts.pendingLoadout = configInfo
            TalentLoadouts.pendingCategory = categoryInfo
            TalentLoadouts.lastUpdated = nil
            TalentLoadouts.lastUpdatedCategory = nil
        
            TalentLoadouts:UpdateDropdownText()
            TalentLoadouts:UpdateDataObj()

            TalentLoadouts.blizzImported = true

            if not TalentLoadouts.charDB.tempLoadout or not tempLoadoutInfo then
                C_ClassTalents.RequestNewConfig(ITL_LOADOUT_NAME)
            elseif tempLoadoutInfo then
                C_ClassTalents.UpdateLastSelectedSavedConfigID(currentSpecID, TalentLoadouts.charDB.tempLoadout)
                ResetTree(configInfo.treeIDs[1], configInfo.type)
                RunNextFrame(CommitLoadout)
            end
        elseif not tempLoadoutInfo or not canCreate then
            if not ImprovedTalentLoadoutsDB.options.useBlizzardFallback then
                TalentLoadouts:Print("|cFFFF0000Can't load the loadouts as a Blizzard one because you have 10 Blizzard loadouts|r. |cFFFFFF00Delete one of them or disable \"Options -> Loadouts -> Load As Blizzard Loadout\"|r. You can also enable the \"Fall back to AddOn Loadout \" option to fall back to the old way of loading loadouts if the AddOn can't create/find the " .. ITL_LOADOUT_NAME .. " loadout.")
            else
                LoadLoadout(self, configInfo, categoryInfo, true)
            end
        end
    elseif configInfo.entryInfo then
        TalentLoadouts.pendingLoadout = configInfo
        TalentLoadouts.pendingCategory = categoryInfo
        TalentLoadouts.lastUpdated = nil
        TalentLoadouts.lastUpdatedCategory = nil

        ResetTree(configInfo.treeIDs[1], configInfo.type)
        RunNextFrame(CommitLoadout)
    
        TalentLoadouts:UpdateDropdownText()
        TalentLoadouts:UpdateDataObj()
    elseif C_Traits.GetConfigInfo(configID) then
        LoadBlizzardLoadout(configID, currentSpecID, configInfo, categoryInfo)
    end

    configInfo.error = nil
    LibDD:CloseDropDownMenus()
end

function TalentLoadouts:OnLoadoutSuccess()
    local configInfo = TalentLoadouts.pendingLoadout
    local categoryInfo = TalentLoadouts.pendingCategory

    TalentLoadouts:LoadGearAndLayout(configInfo)

    TalentLoadouts.charDB.lastLoadout = configInfo.ID
    TalentLoadouts.charDB[self.specID] = configInfo.ID
    TalentLoadouts.charDB.lastCategory = categoryInfo
    TalentLoadouts.pendingLoadout = nil
    TalentLoadouts.pendingCategory = nil

    TalentLoadouts:UpdateDropdownText()
    TalentLoadouts:UpdateDataObj(configInfo)

    UnhookFunction("RollbackConfig")
    UnregisterEvent("CONFIG_COMMIT_FAILED")

    if TalentLoadouts.blizzImported then
        TalentLoadouts.blizzImported = nil
        TalentLoadouts.pendingDeletion = true
    end

    if ImprovedTalentLoadoutsDB.options.loadActionbars and configInfo.actionBars then
        C_Timer.After(0.25, function()
            TalentLoadouts:LoadActionBar(configInfo.actionBars, configInfo.name)
        end)
    end

    C_Timer.After(0.25, function()
        TalentLoadouts:UpdateCurrentExportString()
    end)
end

function TalentLoadouts:OnUnknownLoadoutSuccess()
    local known = false
    if TalentLoadouts.lastUpdated then
        local configInfo = TalentLoadouts.lastUpdated
        local exportString = CreateExportString(configInfo, C_ClassTalents.GetActiveConfigID(), self.specID, true)
        if exportString == configInfo.exportString then
            TalentLoadouts.charDB.lastLoadout = configInfo.ID
            TalentLoadouts.charDB[self.specID] = configInfo.ID
            TalentLoadouts.charDB.lastCategory = TalentLoadouts.lastUpdatedCategory
            known = true
        end
    end

    if not known then
        TalentLoadouts.charDB.lastLoadout = nil
        TalentLoadouts.charDB[self.specID] = nil
        TalentLoadouts.charDB.lastCategory = nil

        C_ClassTalents.UpdateLastSelectedSavedConfigID(self.specID, nil)
    end

    UnregisterEvent("CONFIG_COMMIT_FAILED")

    TalentLoadouts:UpdateDropdownText()
    TalentLoadouts:UpdateDataObj()

    TalentLoadouts.pendingDeletion = true
    
end

function TalentLoadouts:OnLoadoutFail()
    TalentLoadouts.pendingLoadout = nil
    TalentLoadouts.pendingCategory = nil
    TalentLoadouts.lastUpdated = nil
    TalentLoadouts.lastUpdatedCategory = nil

    UnhookFunction("RollbackConfig")
    UnregisterEvent("CONFIG_COMMIT_FAILED")

    TalentLoadouts:UpdateDropdownText()
    TalentLoadouts:UpdateDataObj()
end

function TalentLoadouts:UpdateCurrentExportString()
    local configID = TalentLoadouts.charDB[self.specID]
    local configInfo = configID and self.globalDB.configIDs[self.specID][configID]
    if configInfo then
        local exportString, entryInfo
        if not configInfo.entryInfo then
            exportString, entryInfo = CreateExportString(nil, C_ClassTalents.GetActiveConfigID(), self.specID)
        else
            exportString = CreateExportString(nil, C_ClassTalents.GetActiveConfigID(), self.specID, true)
        end

        configInfo.exportString = exportString
        configInfo.entryInfo = configInfo.entryInfo or entryInfo
    end
end

function TalentLoadouts:LoadLoadoutByName(name)
    local configIDs = self.globalDB.configIDs[self.specID]
    for _, configInfo in pairs(configIDs) do
        if configInfo.name == name then
            LoadLoadout(nil, configInfo)
            break
        end
    end
end

local function FindFreeConfigID()
    local freeIndex = 1

    for _ in ipairs(TalentLoadouts.globalDB.configIDs[TalentLoadouts.specID]) do
        freeIndex = freeIndex + 1
    end

    return freeIndex
end

StaticPopupDialogs["TALENTLOADOUTS_CATEGORY_CREATE"] = {
    text = "Category Name",
    button1 = "Create",
    button2 = "Cancel",
    OnAccept = function(self)
       local categoryName = self.editBox:GetText()
       TalentLoadouts:CreateCategory(categoryName)
    end,
    timeout = 0,
    EditBoxOnEnterPressed = function(self)
         if ( self:GetParent().button1:IsEnabled() ) then
             self:GetParent().button1:Click();
         end
     end,
    hasEditBox = true,
    whileDead = true,
    hideOnEscape = true,
}

local function CreateCategory()
    StaticPopup_Show("TALENTLOADOUTS_CATEGORY_CREATE")
end

function TalentLoadouts:CreateCategory(categoryName)
    local key = categoryName:lower()
    local currentSpecID = self.specID
    self.globalDB.categories[currentSpecID] = self.globalDB.categories[currentSpecID] or {}

    if self.globalDB.categories[currentSpecID][key] then
        self:Print("A category with this name already exists.")
        return
    end

    self.globalDB.categories[currentSpecID][key] = {
        name = categoryName,
        key = key,
        loadouts = {},
    }
end

StaticPopupDialogs["TALENTLOADOUTS_CATEGORY_IMPORT"] = {
    text = "Category Import String",
    button1 = "Import",
    button2 = "Cancel",
    OnAccept = function(self)
       local importString = self.editBox:GetText()
       TalentLoadouts:ProcessCategoryImport(importString)
    end,
    timeout = 0,
    EditBoxOnEnterPressed = function(self)
         if ( self:GetParent().button1:IsEnabled() ) then
             self:GetParent().button1:Click();
         end
     end,
    hasEditBox = true,
    whileDead = true,
    hideOnEscape = true,
}

local function ImportCategory()
    StaticPopup_Show("TALENTLOADOUTS_CATEGORY_IMPORT")
end

function TalentLoadouts:ProcessCategoryImport(importString)
    local version, categoryString = importString:match("!PTL(%d+)!(.+)")
    local decoded = LibDeflate:DecodeForPrint(categoryString)
    if not decoded then return end
    local decompressed = LibDeflate:DecompressDeflate(decoded)
    if not decompressed then return end
    local success, data = LibSerialize:Deserialize(decompressed)
    if not success then return end
    
    local categories = self.globalDB.categories[self.specID]
    if not categories then
        self.globalDB.categories[self.specID] = {}
        categories = self.globalDB.categories[self.specID]
    end

    self:ImportCategory(data)
end

local function GetAvailableCategoryKey(categories, key, index)
    local newKey = string.format("%s-%d", key, index)
    if not categories[newKey] then
        return newKey
    else
        return GetAvailableCategoryKey(categories, key, index + 1)
    end
end

function TalentLoadouts:ImportCategory(data, isSubCategory, parentKey)
    local categories = self.globalDB.categories[self.specID]
    if categories[data.key] then 
        data.key = GetAvailableCategoryKey(categories, data.key, 2)
    end

    categories[data.key] = {
        key = data.key,
        name = data.name,
        loadouts = {},
        categories = {},
        isSubCategory = isSubCategory,
        parents = isSubCategory and {}
    }

    local categoryInfo = categories[data.key]
    if parentKey then
        tInsertUnique(categoryInfo.parents, parentKey)
    end

    if data.subCategories then
        for _, subCategory in ipairs(data.subCategories) do
            local key = self:ImportCategory(subCategory, true, data.key)
            tInsertUnique(categoryInfo.categories, key)
        end
    end

    for _, configInfo in ipairs(data) do
        local configID = TalentLoadouts:ImportLoadout(configInfo.exportString, configInfo.name, data.key)
        if configID then
            tinsert(categoryInfo.loadouts, configID)
        end
    end

    return data.key
end

StaticPopupDialogs["TALENTLOADOUTS_CATEGORY_EXPORT"] = {
    text = "Export Category",
    button1 = "Okay",
    timeout = 0,
    EditBoxOnEnterPressed = function(self)
         if ( self:GetParent().button1:IsEnabled() ) then
             self:GetParent().button1:Click();
         end
     end,
    hasEditBox = true,
    whileDead = true,
    hideOnEscape = true,
}

local function CreateCategoryExportTbl(categoryInfo)
    local currentSpecID = TalentLoadouts.specID
    local export = {name = categoryInfo.name, key = categoryInfo.key}
    if categoryInfo.categories and #categoryInfo.categories > 0 then
        export.subCategories = {}

        for _, categoryKey in ipairs(categoryInfo.categories) do
            local subCategoryInfo = TalentLoadouts.globalDB.categories[currentSpecID][categoryKey]
            if subCategoryInfo then
                tinsert(export.subCategories, CreateCategoryExportTbl(subCategoryInfo))
            end
        end
    end

    if categoryInfo.loadouts and #categoryInfo.loadouts > 0 then
        for _, configID in ipairs(categoryInfo.loadouts) do
            local configInfo = TalentLoadouts.globalDB.configIDs[currentSpecID][configID]
            if configInfo then
                tinsert(export, {name = configInfo.name, exportString = configInfo.exportString})
            end
        end
    end

    return export
end

local function ExportCategory(self, categoryInfo)
    if categoryInfo then
        local export = CreateCategoryExportTbl(categoryInfo)

        local serialized = LibSerialize:Serialize(export)
        local compressed = LibDeflate:CompressDeflate(serialized)
        local encode = LibDeflate:EncodeForPrint(compressed)
        local dialog = StaticPopup_Show("TALENTLOADOUTS_CATEGORY_EXPORT")
        dialog.editBox:SetText("!PTL1!" .. encode)
        dialog.editBox:HighlightText()
        dialog.editBox:SetFocus()
    end
end

StaticPopupDialogs["TALENTLOADOUTS_CATEGORY_RENAME"] = {
    text = "New Category Name for '%s'",
    button1 = "Rename",
    button2 = "Cancel",
    OnAccept = function(self, categoryInfo)
       local newCategoryName = self.editBox:GetText()
       TalentLoadouts:RenameCategory(categoryInfo, newCategoryName)
    end,
    timeout = 0,
    EditBoxOnEnterPressed = function(self)
         if ( self:GetParent().button1:IsEnabled() ) then
             self:GetParent().button1:Click();
         end
     end,
    hasEditBox = true,
    whileDead = true,
    hideOnEscape = true,
}

local function RenameCategory(self, categoryInfo)
    local dialog = StaticPopup_Show("TALENTLOADOUTS_CATEGORY_RENAME", categoryInfo.name)
    dialog.editBox:SetText(categoryInfo.name)
    dialog.data = categoryInfo
end

function TalentLoadouts:RenameCategory(categoryInfo, newCategoryName)
    if categoryInfo and #newCategoryName > 0 then
        categoryInfo.name = newCategoryName
    end
end

local function RemoveCategoryFromCategory(self, parentCategory, categoryInfo, isDeletion)
    if not isDeletion then
        tDeleteItem(parentCategory.categories, categoryInfo.key)
    end

    if categoryInfo.parents then
        tDeleteItem(categoryInfo.parents, parentCategory.key)
    end

    if not categoryInfo.parents or #categoryInfo.parents == 0 then
        categoryInfo.isSubCategory = nil
    end
    LibDD:CloseDropDownMenus()
end

StaticPopupDialogs["TALENTLOADOUTS_CATEGORY_DELETE"] = {
    text = "Are you sure you want to delete the category%s?",
    button1 = "Delete",
    button2 = "Cancel",
    OnAccept = function(self, categoryInfo, withLoadouts)
        TalentLoadouts:DeleteCategory(categoryInfo, withLoadouts)
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
 }

local function DeleteCategory(self, categoryInfo, withLoadouts)
    local dialog = StaticPopup_Show("TALENTLOADOUTS_CATEGORY_DELETE", withLoadouts and " (|cffff0000including loadouts|r)" or "")
    dialog.data = categoryInfo
    dialog.data2 = withLoadouts
end

function TalentLoadouts:DeleteCategory(categoryInfo, withLoadouts)
    if categoryInfo then
        local currentSpecID = self.specID
        if withLoadouts then
            for _, configID in ipairs(categoryInfo.loadouts) do
                self.globalDB.configIDs[currentSpecID][configID] = nil
            end
        else
            for _, configID in ipairs(categoryInfo.loadouts) do
                local configInfo = self.globalDB.configIDs[currentSpecID][configID]
                if configInfo and configInfo.categories and configInfo.categories[categoryInfo.key] then
                    configInfo.categories[categoryInfo.key] = nil
                end
            end
        end

        if categoryInfo.isSubCategory then
            for _, categoryKey in ipairs(categoryInfo.parents) do
                local parentCategoryInfo = self.globalDB.categories[currentSpecID][categoryKey]
                if parentCategoryInfo then
                    tDeleteItem(parentCategoryInfo.categories, categoryInfo.key)
                end
            end
        end

        if categoryInfo.categories then
            for _, categoryKey in ipairs(categoryInfo.categories) do
                local subCategoryInfo = self.globalDB.categories[currentSpecID][categoryKey]
                if subCategoryInfo then
                    RemoveCategoryFromCategory(nil, categoryInfo, subCategoryInfo, true)
                end
            end
        end

        self.globalDB.categories[currentSpecID][categoryInfo.key] = nil
    end
end

StaticPopupDialogs["TALENTLOADOUTS_LOADOUT_SAVE"] = {
    text = "Loadout Name",
    button1 = "Save",
    button2 = "Cancel",
    OnAccept = function(self, saveType, apply)
        local loadoutName = self.editBox:GetText()
        if saveType == 1 then
            TalentLoadouts:SaveCurrentLoadout(loadoutName, nil, apply)
        elseif saveType == 2 then
            TalentLoadouts:SaveCurrentClassTree(loadoutName)
        elseif saveType == 3 then
            TalentLoadouts:SaveCurrentSpecTree(loadoutName)
        end
    end,
    timeout = 0,
    EditBoxOnEnterPressed = function(self)
         if ( self:GetParent().button1:IsEnabled() ) then
             self:GetParent().button1:Click();
         end
     end,
    hasEditBox = true,
    whileDead = true,
    hideOnEscape = true,
 }

 local function SaveCurrentLoadout(self, apply)
    local dialog = StaticPopup_Show("TALENTLOADOUTS_LOADOUT_SAVE")
    dialog.data = 1
    dialog.data2 = apply
 end

 local function SaveCurrentClassTree()
    local dialog = StaticPopup_Show("TALENTLOADOUTS_LOADOUT_SAVE")
    dialog.data = 2
 end

 local function SaveCurrentSpecTree()
    local dialog = StaticPopup_Show("TALENTLOADOUTS_LOADOUT_SAVE")
    dialog.data = 3
 end

 function TalentLoadouts:SaveCurrentLoadout(loadoutName, currencyID, apply, treeType)
    local currentSpecID = self.specID
    local activeConfigID = C_ClassTalents.GetActiveConfigID()
    local fakeConfigID = FindFreeConfigID()
    if not fakeConfigID then return end

    self.globalDB.configIDs[currentSpecID][fakeConfigID] = C_Traits.GetConfigInfo(activeConfigID)

    local configInfo = self.globalDB.configIDs[currentSpecID][fakeConfigID]
    configInfo.fake = true
    configInfo.type = treeType or 1
    configInfo.name = loadoutName
    configInfo.ID = fakeConfigID
    configInfo.currencyID = currencyID
    configInfo.categories = {}

    local isInspecting = securecall(ClassTalentFrame.TalentsTab.IsInspecting, ClassTalentFrame.TalentsTab)
    if isInspecting then
        local treeID = configInfo.treeIDs[1]
        local unit = securecall(ClassTalentFrame.GetInspectUnit, ClassTalentFrame)
        if unit then
            local exportString = C_Traits.GenerateInspectImportString(unit)
            configInfo.exportString, configInfo.entryInfo, configInfo.treeHash = exportString, CreateEntryInfoFromString(activeConfigID, exportString, treeID), C_Traits.GetTreeHash(treeID)
            return
        end
    else
        self:InitializeTalentLoadout(fakeConfigID)
    end

    if not C_Traits.ConfigHasStagedChanges(activeConfigID) then
        if currencyID then
            self.charDB.lastClassLoadout = fakeConfigID
        else
            self.charDB.lastLoadout = fakeConfigID
            self.charDB[currentSpecID] = fakeConfigID
        end

        TalentLoadouts:UpdateDropdownText()
        TalentLoadouts:UpdateDataObj(self.globalDB.configIDs[currentSpecID][fakeConfigID])
    elseif apply then
        LoadLoadout(nil, configInfo)
    end
 end

 function TalentLoadouts:SaveCurrentClassTree(loadoutName)
    loadoutName = string.format("[C] %s", loadoutName)
    self:ImportClassLoadout(self:GetExportStringForTree(), loadoutName)
 end

 function TalentLoadouts:SaveCurrentSpecTree(loadoutName)
    loadoutName = string.format("[S] %s", loadoutName)
    self:ImportSpecLoadout(self:GetExportStringForTree(), loadoutName)
 end

 local function UpdateWithCurrentTree(self, configID, categoryInfo, isButtonUpdate)
    if configID then
        local currentSpecID = TalentLoadouts.specID
        local configInfo = TalentLoadouts.globalDB.configIDs[currentSpecID][configID]
        if configInfo then
            local activeConfigID = C_ClassTalents.GetActiveConfigID()
            configInfo.exportString, configInfo.entryInfo = CreateExportString(configInfo, activeConfigID, currentSpecID)
            configInfo.error = nil

            TalentLoadouts:Print(configInfo.name, "updated")

            if isButtonUpdate then
                TalentLoadouts.lastUpdated = configInfo
                TalentLoadouts.lastUpdatedCategory = categoryInfo
            end
        end
    end
 end

 StaticPopupDialogs["TALENTLOADOUTS_LOADOUT_IMPORT_STRING_UPDATE"] = {
    text = "Loadout Import String",
    button1 = "Import",
    button2 = "Cancel",
    OnAccept = function(self, configID)
       local importString = self.editBox:GetText()
       TalentLoadouts:UpdateWithString(configID, importString)
    end,
    timeout = 0,
    EditBoxOnEnterPressed = function(self)
         if ( self:GetParent().button1:IsEnabled() ) then
             self:GetParent().button1:Click();
         end
     end,
    hasEditBox = true,
    whileDead = true,
    hideOnEscape = true,
}

 local function UpdateWithString(self, configID)
    local dialog = StaticPopup_Show("TALENTLOADOUTS_LOADOUT_IMPORT_STRING_UPDATE")
    dialog.data = configID
 end

 function TalentLoadouts:UpdateWithString(configID, importString)
    if configID then
        local currentSpecID = TalentLoadouts.specID
        local configInfo = TalentLoadouts.globalDB.configIDs[currentSpecID][configID]
        if configInfo then
            local treeID = securecallfunction(ClassTalentFrame.TalentsTab.GetTreeInfo, ClassTalentFrame.TalentsTab).ID
            local entryInfo = CreateEntryInfoFromString(configID, importString, treeID)
        
            if entryInfo then
                if configID == self.charDB.lastLoadout then
                    self.charDB.lastLoadout = nil
                    self:UpdateDropdownText()
                    self:UpdateDataObj()
                end

                configInfo.entryInfo = entryInfo
                configInfo.exportString = importString
                configInfo.error = nil
            else
                self:Print("Invalid import string.")
            end
        end
    end
 end

StaticPopupDialogs["TALENTLOADOUTS_LOADOUT_DELETE"] = {
    text = "Are you sure you want to delete the loadout?",
    button1 = "Delete",
    button2 = "Cancel",
    OnAccept = function(self, configID)
        TalentLoadouts:DeleteLoadout(configID)
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
 }

local function DeleteLoadout(self, configID)
    local dialog = StaticPopup_Show("TALENTLOADOUTS_LOADOUT_DELETE")
    dialog.data = configID
end

function TalentLoadouts:DeleteLoadout(configID)
    local currentSpecID = self.specID

    local configInfo = self.globalDB.configIDs[currentSpecID][configID]
    self.globalDB.configIDs[currentSpecID][configID] = nil

    if self.charDB.lastLoadout == configID then
        self.charDB.lastLoadout = nil
    end

    if configInfo.categories then
        for categoryKey in pairs(configInfo.categories) do
            tDeleteItem(self.globalDB.categories[currentSpecID][categoryKey].loadouts, configID)
        end
    end

    LibDD:CloseDropDownMenus()
    self:UpdateDropdownText()
    self:UpdateDataObj()
end

StaticPopupDialogs["TALENTLOADOUTS_LOADOUT_RENAME"] = {
    text = "New Loadout Name",
    button1 = "Rename",
    button2 = "Cancel",
    OnAccept = function(self, configInfo)
       local newName = self.editBox:GetText()
       TalentLoadouts:RenameLoadout(configInfo, newName)
    end,
    timeout = 0,
    EditBoxOnEnterPressed = function(self)
         if ( self:GetParent().button1:IsEnabled() ) then
             self:GetParent().button1:Click();
         end
    end,
    hasEditBox = true,
    whileDead = true,
    hideOnEscape = true,
}

local function RenameLoadout(self, configID)
    local currentSpecID = TalentLoadouts.specID
    local configInfo = TalentLoadouts.globalDB.configIDs[currentSpecID][configID]

    if configInfo then
        local dialog = StaticPopup_Show("TALENTLOADOUTS_LOADOUT_RENAME")
        dialog.editBox:SetText(configInfo.name)
        dialog.data = configInfo
    end
end

function TalentLoadouts:RenameLoadout(configInfo, newLoadoutName)
    configInfo.name = newLoadoutName

    LibDD:CloseDropDownMenus()
    self:UpdateDropdownText()
    self:UpdateDataObj(configInfo)
end

StaticPopupDialogs["TALENTLOADOUTS_LOADOUT_IMPORT_STRING"] = {
    text = "Loadout Import String",
    button1 = "Import",
    button2 = "Cancel",
    OnAccept = function(self, apply, treeType)
        local importString = self.editBox:GetText()
        local dialog = StaticPopup_Show("TALENTLOADOUTS_LOADOUT_IMPORT_NAME")
        dialog.data = {importString, treeType}
        dialog.data2 = apply
    end,
    timeout = 0,
    EditBoxOnEnterPressed = function(self)
         if ( self:GetParent().button1:IsEnabled() ) then
             self:GetParent().button1:Click();
         end
     end,
    hasEditBox = true,
    whileDead = true,
    hideOnEscape = true,
}

StaticPopupDialogs["TALENTLOADOUTS_LOADOUT_IMPORT_NAME"] = {
    text = "Loadout Import Name",
    button1 = "Import",
    button2 = "Cancel",
    OnAccept = function(self, data, apply)
        local importString, treeType = unpack(data)
        local loadoutName = self.editBox:GetText()
        local fakeConfigID
        if not treeType or treeType == 1 then
            fakeConfigID = TalentLoadouts:ImportLoadout(importString, loadoutName)
        elseif treeType == 2 then
            loadoutName = string.format("[C] %s", loadoutName)
            fakeConfigID = TalentLoadouts:ImportClassLoadout(importString, loadoutName)
        elseif treeType == 3 then
            loadoutName = string.format("[S] %s", loadoutName)
            fakeConfigID = TalentLoadouts:ImportSpecLoadout(importString, loadoutName)
        end

        if fakeConfigID and apply then
            LoadLoadout(nil, TalentLoadouts.globalDB.configIDs[TalentLoadouts.specID][fakeConfigID])
        end
    end,
    timeout = 0,
    EditBoxOnEnterPressed = function(self)
         if ( self:GetParent().button1:IsEnabled() ) then
             self:GetParent().button1:Click();
         end
     end,
    hasEditBox = true,
    whileDead = true,
    hideOnEscape = true,
}

local function ImportCustomLoadout(self, apply)
    local dialog = StaticPopup_Show("TALENTLOADOUTS_LOADOUT_IMPORT_STRING")
    dialog.data = apply
end

local function ImportCustomClassLoadout(self, apply)
    local dialog = StaticPopup_Show("TALENTLOADOUTS_LOADOUT_IMPORT_STRING")
    dialog.data = apply
    dialog.data2 = 2
end

local function ImportCustomSpecLoadout(self, apply)
    local dialog = StaticPopup_Show("TALENTLOADOUTS_LOADOUT_IMPORT_STRING")
    dialog.data = apply
    dialog.data2 = 3
end

function TalentLoadouts:ImportLoadout(importString, loadoutName, category)
    local currentSpecID = self.specID
    local fakeConfigID = FindFreeConfigID()
    if not fakeConfigID then return end

    local treeID = securecallfunction(ClassTalentFrame.TalentsTab.GetTreeInfo, ClassTalentFrame.TalentsTab).ID
    local entryInfo = CreateEntryInfoFromString(C_ClassTalents.GetActiveConfigID(), importString, treeID)

    if entryInfo then
        self.globalDB.configIDs[currentSpecID][fakeConfigID] = {
            ID = fakeConfigID,
            fake = true,
            type = 1,
            treeIDs = {treeID},
            name = loadoutName,
            exportString = importString,
            entryInfo = entryInfo,
            usesSharedActionBars = true,
            categories = category and {[category] = true} or {},
        }
    else
        self:Print("Invalid import string.")
        return
    end

    return fakeConfigID
end

function TalentLoadouts:ImportSpecLoadout(importString, loadoutName, category)
    local currentSpecID = self.specID
    local fakeConfigID = FindFreeConfigID()
    if not fakeConfigID then return end

    local treeID = securecallfunction(ClassTalentFrame.TalentsTab.GetTreeInfo, ClassTalentFrame.TalentsTab).ID
    local loadoutEntryInfo = CreateEntryInfoFromString(C_ClassTalents.GetActiveConfigID(), importString, treeID)

    if loadoutEntryInfo then
        local configID = C_ClassTalents.GetActiveConfigID()
        local specEntryInfo = {}
        for i=1, #loadoutEntryInfo do
            local nodeInfo = C_Traits.GetNodeInfo(configID, loadoutEntryInfo[i].nodeID)
            local nodeCost = C_Traits.GetNodeCost(configID, nodeInfo.ID)
            if C_Traits.GetTraitCurrencyInfo(nodeCost[1].ID) == Enum.TraitCurrencyFlag.UseSpecIcon then
                tinsert(specEntryInfo, loadoutEntryInfo[i])
            end
        end

        self.globalDB.configIDs[currentSpecID][fakeConfigID] = {
            ID = fakeConfigID,
            fake = true,
            type = 3,
            treeIDs = {treeID},
            name = loadoutName,
            exportString = importString,
            entryInfo = specEntryInfo,
            usesSharedActionBars = true,
            categories = category and {[category] = true} or {},
        }
    else
        self:Print("Invalid import string.")
        return
    end

    return fakeConfigID
end

function TalentLoadouts:ImportClassLoadout(importString, loadoutName, category)
    local currentSpecID = self.specID
    local fakeConfigID = FindFreeConfigID()
    if not fakeConfigID then return end

    local configID = C_ClassTalents.GetActiveConfigID()
    local treeID = securecallfunction(ClassTalentFrame.TalentsTab.GetTreeInfo, ClassTalentFrame.TalentsTab).ID
    local loadoutEntryInfo = CreateEntryInfoFromString(configID, importString, treeID)

    if loadoutEntryInfo then
        local classEntryInfo = {}
        for i=1, #loadoutEntryInfo do
            local nodeInfo = C_Traits.GetNodeInfo(configID, loadoutEntryInfo[i].nodeID)
            local nodeCost = C_Traits.GetNodeCost(configID, nodeInfo.ID)
            if C_Traits.GetTraitCurrencyInfo(nodeCost[1].ID) == Enum.TraitCurrencyFlag.UseClassIcon then
                tinsert(classEntryInfo, loadoutEntryInfo[i])
            end
        end

        self.globalDB.configIDs[currentSpecID][fakeConfigID] = {
            ID = fakeConfigID,
            fake = true,
            type = 2,
            treeIDs = {treeID},
            name = loadoutName,
            exportString = importString,
            entryInfo = classEntryInfo,
            usesSharedActionBars = true,
            categories = category and {[category] = true} or {},
        }
    else
        self:Print("Invalid import string.")
        return
    end

    return fakeConfigID
end

StaticPopupDialogs["TALENTLOADOUTS_LOADOUT_EXPORT"] = {
    text = "Loadout Export String",
    button1 = "Okay",
    timeout = 0,
    EditBoxOnEnterPressed = function(self)
         if ( self:GetParent().button1:IsEnabled() ) then
             self:GetParent().button1:Click();
         end
     end,
    hasEditBox = true,
    whileDead = true,
    hideOnEscape = true,
}

local function ExportLoadout(self, configID)
    local currentSpecID = TalentLoadouts.specID
    local configInfo = TalentLoadouts.globalDB.configIDs[currentSpecID][configID]
    if configInfo then
        local dialog = StaticPopup_Show("TALENTLOADOUTS_LOADOUT_EXPORT")
        dialog.editBox:SetText(configInfo.exportString)
        dialog.editBox:HighlightText()
        dialog.editBox:SetFocus()
    end
end

local function UpdateActionBars(self, configID)
    local currentSpecID = TalentLoadouts.specID
    local configInfo = TalentLoadouts.globalDB.configIDs[currentSpecID][configID]
    if configInfo then
        TalentLoadouts:UpdateActionBars(configInfo)
    end
end

local function RemoveActionBars(self, configID)
    local currentSpecID = TalentLoadouts.specID
    local configInfo = TalentLoadouts.globalDB.configIDs[currentSpecID][configID]
    if configInfo then
        configInfo.actionBars = nil
    end
end

function TalentLoadouts:UpdateActionBars(configInfo)
    self:UpdateKnownFlyouts()

    configInfo.actionBars = configInfo.actionBars or {}
    local actionBars = {}

    for actionSlot = 1, NUM_ACTIONBAR_BUTTONS do
        local actionType, id, actionSubType = GetActionInfo(actionSlot)
        if actionType then
            local key, macroType, macroName
            if actionType == "macro" then
                local name = GetActionText(actionSlot)
                --local name, _, body = GetMacroInfo(id)

                if name then
                    local macroIndex = not self.duplicates[name] and (self.globalMacros[name] or self.characterMacros[name])
                    if macroIndex then
                        macroName = name
                        macroType = macroIndex > MAX_ACCOUNT_MACROS and "characterMacros" or "globalMacros"

                        if body then
                            body = strtrim(body:gsub("\r", ""))
                            key = string.format("%s\031%s", name, body)
                        end
                    end
                end
            elseif actionType == "spell" then
                id = FindBaseSpellByID(id)
            elseif actionType == "flyout" then
                id = self.flyouts[id]
            end

            actionBars[actionSlot] = {
                type = actionType,
                id = id,
                subType = actionSubType,
                key = key,
                macroName = macroName,
                macroType = macroType
            }
        end
    end

    if next(actionBars) then
        local serialized = LibSerialize:Serialize(actionBars)
        local compressed = LibDeflate:CompressDeflate(serialized)
        configInfo.actionBars = compressed
    end
end

local function LoadActionBar(self, configID)
    local currentSpecID = TalentLoadouts.specID
    local configInfo = TalentLoadouts.globalDB.configIDs[currentSpecID][configID]
    if configInfo and configInfo.actionBars then
        TalentLoadouts:LoadActionBar(configInfo.actionBars, configInfo.name)
    end
end

function TalentLoadouts:LoadActionBar(actionBars, name)
    if not actionBars then return end

    local decompressed = LibDeflate:DecompressDeflate(actionBars)
    if not decompressed then return end
    local success, data = LibSerialize:Deserialize(decompressed)
    if not success then return end

    self:UpdateMacros()

    if not next(data) then return end

    if name then
        self:Print("Loading action bars of", name)
    end


    local printWarning = false
    for actionSlot = 1, NUM_ACTIONBAR_BUTTONS do
        local slotInfo = data[actionSlot]
        local currentType, currentID, currentSubType = GetActionInfo(actionSlot)
        if slotInfo then

            local pickedUp = false
            ClearCursor()
            if slotInfo.type == "spell" and slotInfo.id ~= currentID then
                PickupSpell(slotInfo.id)
                pickedUp = true
            elseif slotInfo.type == "macro" then
                if slotInfo.macroType and self[slotInfo.macroType] and not self.duplicates[slotInfo.macroName] then
                    local id = self[slotInfo.macroType][slotInfo.key]
                    if not id then
                        id = slotInfo.macroName and self[slotInfo.macroType][slotInfo.macroName]
                    end

                    if id and id ~= currentID then
                        PickupMacro(id)
                        pickedUp = true
                    elseif not id then
                        self:Print("Please resave your action bars. Couldn't find macro: ", slotInfo.macroName, (slotInfo.body or ""):gsub("\n", " "))
                    end
                elseif self.duplicates[slotInfo.macroName] then
                    printWarning = true
                end
            elseif slotInfo.type == "summonmount" then
                local _, spellID = C_MountJournal.GetMountInfoByID(slotInfo.id)
                PickupSpell(spellID)
                pickedUp = true
            elseif slotInfo.type == "flyout" then
                PickupSpellBookItem(slotInfo.id, BOOKTYPE_SPELL)
                pickedUp = true
            elseif slotInfo.type == "item" then
                PickupItem(slotInfo.id)
                pickedUp = true
            end

            if pickedUp then
                PlaceAction(actionSlot)
                ClearCursor()
            end
        elseif ImprovedTalentLoadoutsDB.options.clearEmptySlots and not slotInfo and currentType then
            PickupAction(actionSlot)
            ClearCursor()
        end
    end

    if printWarning then
        self:Print("|cffff0000For now the AddOn won't place macros with duplicate names until Blizzard fixes the issue with receiving the macro body.|r")
    end
end

local function AddToCategory(self, categoryInfo, value)
    if type(value) == "number" then
        local configInfo = TalentLoadouts.globalDB.configIDs[TalentLoadouts.specID][value]

        if configInfo and categoryInfo then
            configInfo.categories = configInfo.categories or {}
            configInfo.categories[categoryInfo.key] = true
            tInsertUnique(categoryInfo.loadouts, value)
            LibDD:CloseDropDownMenus()
        end
    elseif type(value) == "table" then
        local parentCategory = categoryInfo
        local subCategory = value

        subCategory.isSubCategory = true
        subCategory.parents = subCategory.parents or {}
        tInsertUnique(subCategory.parents, parentCategory.key)

        parentCategory.categories = parentCategory.categories or {}
        tInsertUnique(parentCategory.categories, subCategory.key)
        LibDD:CloseDropDownMenus()
    end
end

local function RemoveFromSpecificCategory(self, configID, categoryInfo)
    local configInfo = TalentLoadouts.globalDB.configIDs[TalentLoadouts.specID][configID]
    if configInfo then
        configInfo.categories[categoryInfo.key] = nil
        tDeleteItem(categoryInfo.loadouts, configID)
        LibDD:CloseDropDownMenus()
    end
end

StaticPopupDialogs["TALENTLOADOUTS_LOADOUT_DELETE_ALL"] = {
    text = "Do you want to delete all of your loadouts? Type \"DELETE\".",
    button1 = "Delete",
    button2 = "Cancel",
    OnShow = function(self)
        self.button1:Disable()
    end,
    OnAccept = function()
        TalentLoadouts:DeleteAllLoadouts()
    end,
    timeout = 0,
    EditBoxOnEnterPressed = function(self)
         if ( self:GetParent().button1:IsEnabled() ) then
             self:GetParent().button1:Click();
         end
    end,
    EditBoxOnTextChanged = function(self)
        if self:GetText() == "DELETE" then
            self:GetParent().button1:Enable()
            return
        end

        self:GetParent().button1:Disable()
    end,
    hasEditBox = true,
    whileDead = true,
    hideOnEscape = true,
}

function TalentLoadouts:ShowDeleteAll()
    StaticPopup_Show("TALENTLOADOUTS_LOADOUT_DELETE_ALL")
end

function TalentLoadouts:DeleteAllLoadouts()
    wipe(self.globalDB.configIDs[self.specID])
    LibDD.CloseDropDownMenus()
end

local loadoutFunctions = {
    assignGearset = {
        name = "Assign Gearset",
        notCheckable = true,
        hasArrow = true,
        menuList = "gearset",
    },
    assignLayout = {
        name = "Assign Layout",
        notCheckable = true,
        hasArrow = true,
        menuList = "layout",
    },
    updateTree = {
        name = "Update Tree",
        notCheckable = true,
        func = UpdateWithCurrentTree,
    },
    updateWithString = {
        name = "Update with String",
        notCheckable = true,
        func = UpdateWithString,
    },
    updateActionbars = {
        name = "Save Actionbars",
        notCheckable = true,
        func = UpdateActionBars,
    },
    removeActionbars = {
        name = "Remove Actionbars",
        notCheckable = true,
        func = RemoveActionBars,
        required = "actionBars"
    },
    loadActionbars = {
        name = "Load Actionbars",
        notCheckable = true,
        func = LoadActionBar,
        required = "actionBars",
    },
    delete = {
        name = "Delete",
        func = DeleteLoadout,
        notCheckable = true,
        skipFor = {default = true}
    },
    rename = {
        name = "Rename",
        func = RenameLoadout,
        notCheckable = true,
    },
    export = {
        name = "Export",
        func = ExportLoadout,
        notCheckable = true
    },
    addToCategory = {
        name = "Add to Category",
        menuList = "addToCategory",
        notCheckable = true,
        hasArrow = true,
    },
    removeFromCategory = {
        name = "Remove from this Category",
        func = RemoveFromSpecificCategory,
        notCheckable = true,
        level = 3,
    }
}

local categoryFunctions = {
    addToCategory = {
        name = "Add to Category",
        hasArrow = true,
        notCheckable = true,
        menuList = "addToCategory"
    },
    removeFromCategory = {
        name = "Remove from Category",
        hasArrow = true,
        notCheckable = true,
        menuList = "removeFromCategory",
        required = "isSubCategory",
    },
    delete = {
        name = "Delete",
        func = DeleteCategory,
        notCheckable = true,
    },
    deleteWithLoadouts = {
        name = "Delete including Loadouts",
        func = DeleteCategory,
        arg2 = true,
        notCheckable = true,
    },
    rename = {
        name = "Rename",
        func = RenameCategory,
        notCheckable = true,
    },
    export = {
        name = "Export Category",
        tooltipTitle = "Export",
        tooltipText = "Export all loadouts associated with this category at once.",
        func = ExportCategory,
        notCheckable = true
    }
}

local function LoadoutDropdownInitialize(_, level, menu, ...)
    local currentSpecID = TalentLoadouts.specID
    if level == 1 then
        TalentLoadouts.globalDB.categories[currentSpecID] = TalentLoadouts.globalDB.categories[currentSpecID] or {}
        TalentLoadouts.globalDB.configIDs[currentSpecID] = TalentLoadouts.globalDB.configIDs[currentSpecID] or {}
        TalentLoadouts:UpdateIterator()

        
        for _, categoryInfo in spairs(TalentLoadouts.globalDB.categories[currentSpecID], sortByName) do
            if not categoryInfo.isSubCategory then
                LibDD:UIDropDownMenu_AddButton(
                        {
                            value = categoryInfo,
                            colorCode = "|cFF34ebe1",
                            text = categoryInfo.name,
                            hasArrow = true,
                            minWidth = 170,
                            fontObject = dropdownFont,
                            notCheckable = 1,
                            menuList = "category"
                        },
                level)
            end
        end


        for configID, configInfo in iterateLoadouts() do
            if not configInfo.default and (not configInfo.categories or not next(configInfo.categories)) then
                local color = (configInfo.error and "|cFFFF0000") or (configInfo.fake and "|cFF33ff96") or "|cFFFFD100"

                LibDD:UIDropDownMenu_AddButton(
                    {
                        arg1 = configInfo,
                        value = configID,
                        colorCode = color,
                        text = string.format("%s%s", prefix or configInfo.name, prefix and configInfo.name or ""),
                        hasArrow = true,
                        minWidth = 170,
                        fontObject = dropdownFont,
                        func = LoadLoadout,
                        checked = function()
                            return TalentLoadouts.charDB.lastLoadout and TalentLoadouts.charDB.lastLoadout == configID
                        end,
                        menuList = "loadout"
                    },
                level)
            end
        end

        LibDD:UIDropDownMenu_AddButton(
            {
                text = "Options",
                notCheckable = 1,
                hasArrow = true,
                fontObject = dropdownFont,
                minWidth = 170,
                menuList = "options"
            }
        )

        LibDD:UIDropDownMenu_AddButton(
            {
                text = "Create Loadout",
                minWidth = 170,
                fontObject = dropdownFont,
                hasArrow = true,
                notCheckable = 1,
                func = SaveCurrentLoadout,
                menuList = "createLoadout"
            },
        level)

        LibDD:UIDropDownMenu_AddButton(
            {
                text = "Import Loadout",
                minWidth = 170,
                fontObject = dropdownFont,
                hasArrow = true,
                notCheckable = 1,
                func = ImportCustomLoadout,
                menuList = "importLoadout"
            },
        level)

        LibDD:UIDropDownMenu_AddButton(
            {
                text = "Create Category",
                minWidth = 170,
                fontObject = dropdownFont,
                notCheckable = 1,
                func = CreateCategory,
            }
        )

        LibDD:UIDropDownMenu_AddButton(
            {
                text = "Import Category",
                minWidth = 170,
                fontObject = dropdownFont,
                notCheckable = 1,
                func = ImportCategory,
            }
        )

        LibDD:UIDropDownMenu_AddButton(
            {
                text = "Close",
                minWidth = 170,
                fontObject = dropdownFont,
                notCheckable = 1,
                func = LibDD.CloseDropDownMenus,
            },
        level)
    elseif menu == "createLoadout" then
        LibDD:UIDropDownMenu_AddButton(
            {
                text = "Create Loadout",
                minWidth = 170,
                fontObject = dropdownFont,
                notCheckable = 1,
                func = SaveCurrentLoadout,
            },
        level)

        LibDD:UIDropDownMenu_AddButton(
            {
                text = "Create Loadout + Apply",
                arg1 = true,
                minWidth = 170,
                fontObject = dropdownFont,
                notCheckable = 1,
                func = SaveCurrentLoadout,
            },
        level)

        LibDD:UIDropDownMenu_AddButton(
            {
                text = "Create Class Loadout",
                minWidth = 170,
                fontObject = dropdownFont,
                notCheckable = 1,
                func = SaveCurrentClassTree,
            },
        level)

        LibDD:UIDropDownMenu_AddButton(
            {
                text = "Create Spec Loadout",
                minWidth = 170,
                fontObject = dropdownFont,
                notCheckable = 1,
                func = SaveCurrentSpecTree,
            },
        level)
    elseif menu == "importLoadout" then
        LibDD:UIDropDownMenu_AddButton(
            {
                text = "Import Loadout",
                minWidth = 170,
                fontObject = dropdownFont,
                notCheckable = 1,
                func = ImportCustomLoadout,
            },
        level)

        LibDD:UIDropDownMenu_AddButton(
            {
                text = "Import Loadout + Apply",
                arg1 = true,
                minWidth = 170,
                fontObject = dropdownFont,
                notCheckable = 1,
                func = ImportCustomLoadout,
            },
        level)

        LibDD:UIDropDownMenu_AddButton(
            {
                text = "Import Class Loadout",
                minWidth = 170,
                fontObject = dropdownFont,
                notCheckable = 1,
                func = ImportCustomClassLoadout,
            },
        level)
        
        LibDD:UIDropDownMenu_AddButton(
            {
                text = "Import Spec Loadout",
                minWidth = 170,
                fontObject = dropdownFont,
                notCheckable = 1,
                func = ImportCustomSpecLoadout,
            },
        level)

    elseif menu == "options" then
        LibDD:UIDropDownMenu_AddButton(
            {
                text = "Display Category Name",
                isNotRadio = true,
                minWidth = 170,
                fontObject = dropdownFont,
                func = function()
                    ImprovedTalentLoadoutsDB.options.showCategoryName = not ImprovedTalentLoadoutsDB.options.showCategoryName
                    TalentLoadouts:UpdateDropdownText()
                end,
                checked = function()
                    return ImprovedTalentLoadoutsDB.options.showCategoryName
                end
            },
        level)

        LibDD:UIDropDownMenu_AddButton(
            {
                text = "Show Spec Buttons",
                isNotRadio = true,
                minWidth = 170,
                fontObject = dropdownFont,
                func = function()
                    ImprovedTalentLoadoutsDB.options.showSpecButtons = not ImprovedTalentLoadoutsDB.options.showSpecButtons
                    TalentLoadouts:UpdateSpecButtons()
                end,
                checked = function()
                    return ImprovedTalentLoadoutsDB.options.showSpecButtons
                end 
            },
        level)

        LibDD:UIDropDownMenu_AddButton(
            {
                text = "Sort Loadouts by Name",
                isNotRadio = true,
                minWidth = 170,
                fontObject = dropdownFont,
                func = function()
                    ImprovedTalentLoadoutsDB.options.sortLoadoutsByName = not ImprovedTalentLoadoutsDB.options.sortLoadoutsByName
                    TalentLoadouts:UpdateIterator()
                end,
                checked = function()
                    return ImprovedTalentLoadoutsDB.options.sortLoadoutsByName
                end
            },
        level)

        LibDD:UIDropDownMenu_AddButton(
            {
                text = "Loadouts",
                notCheckable = 1,
                minWidth = 170,
                fontObject = dropdownFont,
                hasArrow = true,
                menuList = "globalLoadoutOptions"
            },
        level)

        LibDD:UIDropDownMenu_AddButton(
            {
                text = "Action Bars",
                notCheckable = 1,
                minWidth = 170,
                fontObject = dropdownFont,
                hasArrow = true,
                menuList = "actionBarOptions"
            },
        level)

        LibDD:UIDropDownMenu_AddButton(
            {
                text = "Spec Button Type",
                notCheckable = 1,
                minWidth = 170,
                fontObject = dropdownFont,
                hasArrow = true,
                menuList = "specButtonType"
            },
        level)

        LibDD:UIDropDownMenu_AddButton(
            {
                text = "Font Size",
                notCheckable = 1,
                minWidth = 170,
                fontObject = dropdownFont,
                hasArrow = true,
                menuList = "fontSizeOptions"
            },
        level)

        LibDD:UIDropDownMenu_AddButton(
            {
                text = "Delete All",
                notCheckable = 1,
                minWidth = 170,
                fontObject = dropdownFont,
                func = function()
                    TalentLoadouts:ShowDeleteAll()
                end,
            },
        level)
    elseif menu == "fontSizeOptions" then
        local fontSizes = {10, 11, 12, 13, 14, 15, 16, 18, 20}
        for _, fontSize in ipairs(fontSizes) do
            LibDD:UIDropDownMenu_AddButton(
                {
                    text = fontSize,
                    fontObject = dropdownFont,
                    func = function()
                        ImprovedTalentLoadoutsDB.options.fontSize = fontSize
                        TalentLoadouts:UpdateDropdownFont()
                        LibDD.CloseDropDownMenus()
                    end,
                    checked = function()
                        return ImprovedTalentLoadoutsDB.options.fontSize == fontSize
                    end
                },
            level)
        end
    elseif menu == "actionBarOptions" then
        LibDD:UIDropDownMenu_AddButton(
            {
                text = "Load Action Bars with Loadout",
                isNotRadio = true,
                minWidth = 170,
                fontObject = dropdownFont,
                func = function()
                    ImprovedTalentLoadoutsDB.options.loadActionbars = not ImprovedTalentLoadoutsDB.options.loadActionbars
                end,
                checked = function()
                    return ImprovedTalentLoadoutsDB.options.loadActionbars
                end
            },
        level)

                LibDD:UIDropDownMenu_AddButton(
            {
                text = "Load Action Bars with Spec",
                isNotRadio = true,
                minWidth = 170,
                fontObject = dropdownFont,
                func = function()
                    ImprovedTalentLoadoutsDB.options.loadActionbarsSpec = not ImprovedTalentLoadoutsDB.options.loadActionbarsSpec
                end,
                checked = function()
                    return ImprovedTalentLoadoutsDB.options.loadActionbarsSpec
                end
            },
        level)

        LibDD:UIDropDownMenu_AddButton(
            {
                text = "Clear Slots when loading Action Bars",
                isNotRadio = true,
                minWidth = 170,
                tooltipTitle = "|cffff0000WARNING! Use this option at your own risk!|r",
                tooltipText = "This will remove an action from a slot if it was empty when you've saved the action bars. It's unclear if this affects the action bars of other specs.",
                tooltipOnButton = 1,
                fontObject = dropdownFont,
                func = function()
                    ImprovedTalentLoadoutsDB.options.clearEmptySlots = not ImprovedTalentLoadoutsDB.options.clearEmptySlots
                end,
                checked = function()
                    return ImprovedTalentLoadoutsDB.options.clearEmptySlots
                end
            },
        level)

        LibDD:UIDropDownMenu_AddButton(
            {
                text = "Find Macro By Name",
                isNotRadio = true,
                tooltipTitle = "Description:",
                tooltipText = "Lets the AddOn find saved macros based on their names (instead of name + body).",
                tooltipOnButton = 1,
                minWidth = 170,
                fontObject = dropdownFont,
                func = function()
                    ImprovedTalentLoadoutsDB.options.findMacroByName = not ImprovedTalentLoadoutsDB.options.findMacroByName
                end,
                checked = function()
                    return ImprovedTalentLoadoutsDB.options.findMacroByName
                end
            },
        level)
    elseif menu == "globalLoadoutOptions" then
        LibDD:UIDropDownMenu_AddButton(
            {
                text = "Automatically apply Loadout",
                isNotRadio = true,
                minWidth = 170,
                fontObject = dropdownFont,
                func = function()
                    ImprovedTalentLoadoutsDB.options.applyLoadout = not ImprovedTalentLoadoutsDB.options.applyLoadout
                end,
                checked = function()
                    return ImprovedTalentLoadoutsDB.options.applyLoadout
                end
            },
        level)

        LibDD:UIDropDownMenu_AddButton(
            {
                text = "Add Loadouts to /simc",
                isNotRadio = true,
                minWidth = 170,
                fontObject = dropdownFont,
                func = function()
                    ImprovedTalentLoadoutsDB.options.simc = not ImprovedTalentLoadoutsDB.options.simc
                end,
                checked = function()
                    return ImprovedTalentLoadoutsDB.options.simc
                end
            },
        level)

        LibDD:UIDropDownMenu_AddButton(
            {
                text = "Load Blizzard Loadouts (yellow)",
                isNotRadio = true,
                minWidth = 170,
                fontObject = dropdownFont,
                tooltipOnButton = 1,
                tooltipTitle = "Load Blizzard Loadouts",
                tooltipText = "Load the yellow loadouts (if they exists) with the Blizzard API functions and don't handle it as an AddOn loadout. At large this disables the action bar handling of the AddOn for the yellow loadouts.",
                func = function()
                    ImprovedTalentLoadoutsDB.options.loadBlizzard = not ImprovedTalentLoadoutsDB.options.loadBlizzard
                end,
                checked = function()
                    return ImprovedTalentLoadoutsDB.options.loadBlizzard
                end 
            },
        level)

        LibDD:UIDropDownMenu_AddButton(
            {
                text = "Load as Blizzard Loadout",
                isNotRadio = true,
                minWidth = 170,
                fontObject = dropdownFont,
                func = function()
                    ImprovedTalentLoadoutsDB.options.loadAsBlizzard = not ImprovedTalentLoadoutsDB.options.loadAsBlizzard
                end,
                checked = function()
                    return ImprovedTalentLoadoutsDB.options.loadAsBlizzard
                end
            },
        level)

        LibDD:UIDropDownMenu_AddButton(
            {
                text = "Fall back to AddOn Loadout",
                isNotRadio = true,
                minWidth = 170,
                fontObject = dropdownFont,
                func = function()
                    ImprovedTalentLoadoutsDB.options.useAddOnLoadoutFallback = not ImprovedTalentLoadoutsDB.options.useAddOnLoadoutFallback
                end,
                checked = function()
                    return ImprovedTalentLoadoutsDB.options.useAddOnLoadoutFallback
                end
            },
        level)
    elseif menu == "specButtonType" then
        local buttonTypes = {"text", "icon"}
        local buttonTypesText = {"Text", "Icons"}
        for i, buttonType in ipairs(buttonTypes) do
            LibDD:UIDropDownMenu_AddButton(
            {
                text = buttonTypesText[i],
                fontObject = dropdownFont,
                func = function()
                    ImprovedTalentLoadoutsDB.options.specButtonType = buttonType
                    TalentLoadouts:UpdateSpecButtons()
                end,
                checked = function()
                    return ImprovedTalentLoadoutsDB.options.specButtonType == buttonType
                end,
            }
            ,level)
        end
    elseif menu == "loadout" then
        local functions = {"addToCategory", "removeFromCategory", "assignGearset", "assignLayout", "updateTree", "updateWithString", "updateActionbars", "removeActionbars", "loadActionbars", "rename", "delete", "export"}
        local configID, categoryInfo = L_UIDROPDOWNMENU_MENU_VALUE
        if type(L_UIDROPDOWNMENU_MENU_VALUE) == "table" then
            configID, categoryInfo = unpack(L_UIDROPDOWNMENU_MENU_VALUE)
        end
        local configInfo = TalentLoadouts.globalDB.configIDs[currentSpecID][configID]

        for _, func in ipairs(functions) do
            local info = loadoutFunctions[func]
            if (not info.required or configInfo[info.required]) and (not info.level or level == info.level) then
                LibDD:UIDropDownMenu_AddButton(
                {
                    arg1 = configID,
                    arg2 = categoryInfo,
                    value = configID,
                    notCheckable = info.notCheckable and 1 or nil,
                    tooltipTitle = info.tooltipTitle,
                    tooltipOnButton = info.tooltipText and 1 or nil,
                    tooltipText = info.tooltipText,
                    text = info.name,
                    isNotRadio = true,
                    fontObject = dropdownFont,
                    func = info.func,
                    checked = info.checked,
                    hasArrow = info.hasArrow,
                    menuList = info.menuList,
                    minWidth = 150,
                },
                level)
            end
        end
    elseif menu == "category" then
        local categoryInfo = TalentLoadouts.globalDB.categories[currentSpecID][L_UIDROPDOWNMENU_MENU_VALUE.key]
        if categoryInfo then
            if categoryInfo.categories then
                for _, categoryKey in ipairs(categoryInfo.categories) do
                    local categoryInfo = TalentLoadouts.globalDB.categories[currentSpecID][categoryKey]
                    if categoryInfo and categoryInfo.name then
                        LibDD:UIDropDownMenu_AddButton(
                        {
                            value = categoryInfo,
                            colorCode = "|cFF34ebe1",
                            text = categoryInfo.name,
                            hasArrow = true,
                            minWidth = 170,
                            fontObject = dropdownFont,
                            notCheckable = 1,
                            menuList = "category"
                        },
                level)
                    end
                end
            end

            for _, configID in ipairs(categoryInfo.loadouts) do
                local configInfo = TalentLoadouts.globalDB.configIDs[currentSpecID][configID]
                if configInfo and not configInfo.default then
                    local color = configInfo.fake and "|cFF33ff96" or "|cFFFFD100"
                    LibDD:UIDropDownMenu_AddButton(
                        {
                            arg1 = configInfo,
                            arg2 = categoryInfo,
                            value = {configID, categoryInfo},
                            colorCode = color,
                            text = configInfo.name,
                            minWidth = 170,
                            fontObject = dropdownFont,
                            hasArrow = true,
                            func = function(...)
                                LoadLoadout(...)
                                LibDD:CloseDropDownMenus()
                            end,
                            checked = function()
                                return TalentLoadouts.charDB.lastLoadout and TalentLoadouts.charDB.lastLoadout == configID
                            end,
                            menuList = "loadout"
                        },
                    level)
                end
            end
        end

        LibDD:UIDropDownMenu_AddButton(
            {
                value = L_UIDROPDOWNMENU_MENU_VALUE,
                text = "Category Options",
                hasArrow = true,
                minWidth = 170,
                fontObject = dropdownFont,
                notCheckable = 1,
                menuList = "categoryOptions"
            },
        level)
    elseif menu == "categoryOptions" then
        local functions = {"addToCategory", "removeFromCategory", "rename", "delete", "deleteWithLoadouts", "export"}
        for _, func in ipairs(functions) do
            local info = categoryFunctions[func]
            if (not info.required or L_UIDROPDOWNMENU_MENU_VALUE[info.required]) then
                LibDD:UIDropDownMenu_AddButton(
                {
                    value = L_UIDROPDOWNMENU_MENU_VALUE,
                    arg1 = L_UIDROPDOWNMENU_MENU_VALUE,
                    arg2 = info.arg2,
                    notCheckable = info.notCheckable and 1 or nil,
                    tooltipTitle = info.tooltipTitle,
                    tooltipOnButton = info.tooltipText and 1 or nil,
                    tooltipText = info.tooltipText,
                    text = info.name,
                    isNotRadio = true,
                    fontObject = dropdownFont,
                    func = info.func,
                    checked = info.checked,
                    hasArrow = info.hasArrow,
                    menuList = info.menuList,
                    minWidth = 170,
                },
                level)
            end
        end
    elseif menu == "addToCategory" then
        local isCategory = type(L_UIDROPDOWNMENU_MENU_VALUE) == "table"

        for _, categoryInfo in spairs(TalentLoadouts.globalDB.categories[currentSpecID], 
        function(t, a, b) if t[a] and t[b] and t[a].name and t[b].name then return t[a].name < t[b].name end end) do
            if not isCategory or categoryInfo.key ~= L_UIDROPDOWNMENU_MENU_VALUE.key then
                LibDD:UIDropDownMenu_AddButton(
                        {
                            arg1 = categoryInfo,
                            arg2 = L_UIDROPDOWNMENU_MENU_VALUE,
                            colorCode = "|cFFab96b3",
                            text = categoryInfo.name,
                            minWidth = 170,
                            fontObject = dropdownFont,
                            notCheckable = 1,
                            func = AddToCategory,
                        },
                level)
            end
        end
    elseif menu == "removeFromCategory" then
        for _, categoryKey in ipairs(L_UIDROPDOWNMENU_MENU_VALUE.parents) do
            local categoryInfo = TalentLoadouts.globalDB.categories[currentSpecID][categoryKey]
            if categoryInfo then
                LibDD:UIDropDownMenu_AddButton(
                        {
                            arg1 = categoryInfo,
                            arg2 = L_UIDROPDOWNMENU_MENU_VALUE,
                            colorCode = "|cFFab96b3",
                            text = categoryInfo.name,
                            minWidth = 170,
                            fontObject = dropdownFont,
                            notCheckable = 1,
                            func = RemoveCategoryFromCategory,
                        },
                level)
            end
        end
    elseif menu == "gearset" then
        local configInfo = TalentLoadouts.globalDB.configIDs[currentSpecID][L_UIDROPDOWNMENU_MENU_VALUE]
        if configInfo then
            for _, equipmentSetID in ipairs(C_EquipmentSet.GetEquipmentSetIDs()) do
                local name, icon = C_EquipmentSet.GetEquipmentSetInfo(equipmentSetID)

                LibDD:UIDropDownMenu_AddButton(
                    {
                        arg1 = L_UIDROPDOWNMENU_MENU_VALUE,
                        text = string.format("|T%d:0|t %s", icon, name),
                        fontObject = dropdownFont,
                        minWidth = 170,
                        checked = function()
                            return configInfo.gearset and configInfo.gearset == equipmentSetID
                        end,
                        func = function()
                            if configInfo.gearset and configInfo.gearset == equipmentSetID then
                                configInfo.gearset = nil
                            else
                                configInfo.gearset = equipmentSetID
                            end
                        end
                    },
                level)
            end
        end
    elseif menu == "layout" then
        local configInfo = TalentLoadouts.globalDB.configIDs[currentSpecID][L_UIDROPDOWNMENU_MENU_VALUE]
        if configInfo then
            local layoutsInfo =  C_EditMode.GetLayouts()
            if not layoutsInfo then return end

            for index, info in ipairs(layoutsInfo.layouts) do
                local layoutIndex = index + 2

                LibDD:UIDropDownMenu_AddButton(
                    {
                        text = info.layoutName,
                        fontObject = dropdownFont,
                        minWidth = 170,
                        checked = function()
                            return configInfo.layout and configInfo.layout == layoutIndex
                        end,
                        func = function()
                            if configInfo.layout and configInfo.layout == layoutIndex then
                                configInfo.layout = nil
                            else
                                configInfo.layout = layoutIndex
                            end
                        end
                    },
                level)
            end
        end
    end
end

function TalentLoadouts:UpdateDropdownText()
    if not self.dropdown then return end

    local currentSpecID = self.specID
    local dropdownText = ""

    local color, configInfo = "FFFFFF", nil
    if self.pendingLoadout then
        color = "F5B042"
        configInfo = self.pendingLoadout
    elseif self.charDB[currentSpecID] then
        configInfo = self.globalDB.configIDs[currentSpecID][self.charDB[currentSpecID]]
    elseif self.charDB.lastLoadout then 
        configInfo = self.globalDB.configIDs[currentSpecID][self.charDB.lastLoadout]
    end
    dropdownText = string.format("|cFF%s%s|r", color, configInfo and configInfo.name or "Unknown")

    if self.charDB.lastCategory and ImprovedTalentLoadoutsDB.options.showCategoryName then
        dropdownText = string.format("|cFF34ebe1[%s]|r %s", self.charDB.lastCategory.name, dropdownText)
        LibDD:UIDropDownMenu_SetText(self.dropdown, dropdownText)
    else
        LibDD:UIDropDownMenu_SetText(self.dropdown, dropdownText)
    end
end

function TalentLoadouts:UpdateDropdownFont()
    dropdownFont:SetFont(GameFontNormal:GetFont(), ImprovedTalentLoadoutsDB.options.fontSize or 10, "")
end

function TalentLoadouts:InitializeHooks()
    hooksecurefunc(C_Traits, "RollbackConfig", function()
        if TalentLoadouts.currentLoadout then
            TalentLoadouts.pendingLoadout = nil
            TalentLoadouts.charDB.lastLoadout = TalentLoadouts.currentLoadout
            TalentLoadouts.currentLoadout = nil
            TalentLoadouts:UpdateDropdownText()
        end
    end)

    if not IsAddOnLoaded("Simulationcraft") then return end
    hooksecurefunc(SlashCmdList, "ACECONSOLE_SIMC", function()
        if not ImprovedTalentLoadoutsDB.options.simc then return end

        local customLoadouts
        for _, v in ITLAPI.EnumerateSpecLoadouts() do
           if not v.default then
              if customLoadouts then
                 customLoadouts = string.format("%s\n# Saved Loadout: %s\n# talents=%s", customLoadouts, v.name, v.exportString)
              else
                 customLoadouts = string.format("\n# Saved Loadout: %s\n# talents=%s", v.name, v.exportString)
              end
           end
        end
        
        if customLoadouts and SimcEditBox then
           local hooked = true
           local text = SimcEditBox:GetText()

           local outputHeader = "\n\n# From ImprovedTalentLoadouts\n#"
           customLoadouts = outputHeader .. customLoadouts

           SimcEditBox:SetCursorPosition(SimcEditBox:GetNumLetters())
           SimcEditBox:HighlightText(0,0)
           SimcEditBox:Insert(customLoadouts)
           SimcEditBox:HighlightText()
           SimcEditBox:SetFocus()
           SimcEditBox:HookScript("OnTextChanged", function(self) 
                 if hooked then
                    self:SetText(text .. customLoadouts)
                    self:HighlightText()
                 end
           end)
           
           SimcEditBox:HookScript("OnHide", function(self)
                 hooked = false
           end)
        end
  end)
end

function TalentLoadouts:InitializeDropdown()
    local dropdown = LibDD:Create_UIDropDownMenu("TestDropdownMenu", ClassTalentFrame.TalentsTab)
    self.dropdown = dropdown
    dropdown:SetPoint("LEFT", ClassTalentFrame.TalentsTab.SearchBox, "RIGHT", 0, -1)
    
    LibDD:UIDropDownMenu_SetAnchor(dropdown, 0, 16, "BOTTOM", dropdown.Middle, "CENTER")
    LibDD:UIDropDownMenu_Initialize(dropdown, LoadoutDropdownInitialize)
    LibDD:UIDropDownMenu_SetWidth(dropdown, 170)
    self:UpdateDropdownText()
end

local function CreateTextSpecButton(width, specIndex, _, specName)
    local specButton = CreateFrame("Button", nil, TalentLoadouts.dropdown, "UIPanelButtonNoTooltipTemplate, UIButtonTemplate")
    specButton:SetNormalAtlas("charactercreate-customize-dropdownbox")
    specButton:SetSize(width, 30)

    if #specName > ceil(width/10) then
        specButton:SetText(specName:sub(1, ceil(width/11)) .. "...")
    else
        specButton:SetText(specName)
    end
    specButton:SetPoint("LEFT", ClassTalentFrame.TalentsTab.ResetButton , "RIGHT", (specIndex-1) * (width + 1), -2)
    return specButton
end

local function CreateIconSpecButton(width, specIndex, numSpecializations, _, icon)
    width = 79.5

    local specButton = CreateFrame("Button", nil, TalentLoadouts.dropdown)
    specButton:SetNormalTexture(icon)
    specButton:SetHighlightTexture(icon)
    specButton:SetSize(39.75, 39.75)
    specButton:SetPoint("LEFT", ClassTalentFrame.TalentsTab.ResetButton , "RIGHT", (specIndex-1) * (width/2 + 1) + (width * (numSpecializations==3 and 1.25 or 1)), -2)
    return specButton
end

function TalentLoadouts:CreateSpecButtons(specButtonType)
    local createFunction = specButtonType == "text" and CreateTextSpecButton or CreateIconSpecButton
    self.specButtons[specButtonType] = {}
    local specTypeButtons = self.specButtons[specButtonType]

    local numSpecializations = GetNumSpecializations()
    local width = 318 / numSpecializations
    for specIndex=1, numSpecializations do
        local specName, _, icon = select(2, GetSpecializationInfo(specIndex))
        local specButton = createFunction(width, specIndex, numSpecializations, specName, icon)
        specButton.name = specName
        specButton.icon = icon
        specButton.width = width
        specButton.type = ImprovedTalentLoadoutsDB.options.specButtonType
        specTypeButtons[specIndex] = specButton
        specButton.specIndex = specIndex
        specButton:RegisterForClicks("LeftButtonDown")

        specButton:SetScript("OnClick", function(self)
            if self.specIndex ~= GetSpecialization() then
                SetSpecialization(specIndex)
            end
        end)
        
        specButton:SetScript("OnEnter", function()
            GameTooltip:SetOwner(specButton, "ANCHOR_TOP")
            GameTooltip:AddLine("Change your specialization to " .. specName)
            GameTooltip:Show()
        end)
        
        specButton:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)

        if specIndex == GetSpecialization() then
            specButton:GetNormalTexture():SetVertexColor(0, 1, 0)
        end
    end
end

function TalentLoadouts:InitializeButtons()
    local saveButton = CreateFrame("Button", nil, self.dropdown, "UIPanelButtonNoTooltipTemplate, UIButtonTemplate")
    self.saveButton = saveButton
    saveButton:SetSize(65, 32)
    saveButton:SetNormalAtlas("charactercreate-customize-dropdownbox")
    --saveButton:SetHighlightAtlas("charactercreate-customize-dropdownbox-open")    
    saveButton:RegisterForClicks("LeftButtonDown")
    saveButton:SetPoint("LEFT", self.dropdown, "RIGHT", -10, 2)
    saveButton:SetText("Update")
    --saveButton:Disable()
    saveButton.enabled = false

    saveButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(saveButton, "ANCHOR_TOP")
        GameTooltip:AddLine("Update the active loadout with the current tree.")
        GameTooltip:AddLine("Hold down SHIFT to update the loadout")
        GameTooltip:AddLine("Hold down CTRL to update the loadout + action bars")
        GameTooltip:Show()
    end)
    
    saveButton:SetScript("OnLeave", function(self)
        GameTooltip:Hide()
    end)

    saveButton:SetScript("OnClick", function()
        if IsShiftKeyDown() then
            UpdateWithCurrentTree(nil, TalentLoadouts.charDB.lastLoadout, TalentLoadouts.charDB.lastCategory, true)
        elseif IsControlKeyDown() then
            UpdateWithCurrentTree(nil, TalentLoadouts.charDB.lastLoadout, TalentLoadouts.charDB.lastCategory, true)
            UpdateActionBars(nil, TalentLoadouts.charDB.lastLoadout)
        end
    end)

    self.specButtons = {}
    if ImprovedTalentLoadoutsDB.options.showSpecButtons then
        self:CreateSpecButtons(ImprovedTalentLoadoutsDB.options.specButtonType)
    end
end

function TalentLoadouts:UpdateSpecButtons()
    local specButtonType = ImprovedTalentLoadoutsDB.options.specButtonType

    for _, specButtons in pairs(self.specButtons) do
        for _, specButton in ipairs(specButtons) do
            specButton:Hide()
        end
    end

    if not self.specButtons[specButtonType] then
        self:CreateSpecButtons(specButtonType)
    end

    if ImprovedTalentLoadoutsDB.options.showSpecButtons then
        for specIndex, specButton in ipairs(self.specButtons[specButtonType]) do
            specButton:Show()
            if specIndex == GetSpecialization() then
                specButton:GetNormalTexture():SetVertexColor(0, 1, 0)
            else
                specButton:GetNormalTexture():SetVertexColor(1, 1, 1)
            end
        end
    end
end

function TalentLoadouts:Print(...)
    print("|cff33ff96[TalentLoadouts]|r", ...)
end

function TalentLoadouts:UpdateMacros()
    if not self.initialized then return end

    self.globalMacros = {}
    self.characterMacros = {}
    self.duplicates = {}
    local globalMacros = self.globalMacros
    local charMacros = self.characterMacros

    for macroSlot = 1, MAX_ACCOUNT_MACROS do
        local name, _, body = GetMacroInfo(macroSlot)

        if name then
            body = strtrim(body:gsub("\r", ""))
            local key = string.format("%s\031%s", name, body)
            globalMacros[macroSlot] = {
                slot = macroSlot,
                body = body,
                name = name,
                key = key
            }

            if globalMacros[name] then
                self.duplicates[name] = true
            end

            globalMacros[key] = macroSlot
            globalMacros[name] = macroSlot
        elseif globalMacros[macroSlot] then
            globalMacros[globalMacros[macroSlot].key] = nil
            globalMacros[macroSlot] = nil
        end
    end

    for macroSlot = MAX_ACCOUNT_MACROS + 1, (MAX_ACCOUNT_MACROS + MAX_CHARACTER_MACROS) do
        local name, _, body = GetMacroInfo(macroSlot)
        if name then
        body = strtrim(body:gsub("\r", ""))
            local key = string.format("%s\031%s", name, body)
            charMacros[macroSlot] = {
                slot = macroSlot,
                body = body,
                name = name,
                key = key,
            }

            if charMacros[name] then
                self.duplicates[name] = true
            end

            charMacros[key] = macroSlot
            charMacros[name] = macroSlot
        elseif charMacros[macroSlot] then
            charMacros[charMacros[macroSlot].key] = nil
            charMacros[macroSlot] = nil
        end
    end

    --backwards compatibility
    self.charMacros = self.characterMacros
end

function TalentLoadouts:UpdateKnownFlyouts()
    self.flyouts = {}

    for i = 1, GetNumSpellTabs() do
        local offset, numSpells, _, offSpecID = select(3, GetSpellTabInfo(i));
        if offSpecID == 0 then
            for slotId = offset + 1, numSpells + offset do
                local spellType, id = GetSpellBookItemInfo(slotId, BOOKTYPE_SPELL)
                if spellType  and spellType == "FLYOUT" then
                self.flyouts[id] = slotId
                end
            end
        end
    end
end

SLASH_IMPROVEDTALENDLOADOUTS1 = '/itl'
SlashCmdList["IMPROVEDTALENDLOADOUTS"] = function(msg, editbox)
    local action, argument = strsplit(" ", msg, 2)
    if action == 'saveActionbar' then
        local currentSpecID = TalentLoadouts.specID
        local configID = TalentLoadouts.charDB[currentSpecID]
        if configID then
            UpdateActionBars(nil, configID)
        end
    elseif action == 'load' and #argument > 0 then
        TalentLoadouts:LoadLoadoutByName(argument)
    end
end
