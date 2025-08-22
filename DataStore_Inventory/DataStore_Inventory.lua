--[[	*** DataStore_Inventory ***
Written by : Thaoky, EU-Marécages de Zangar
July 13th, 2009
--]]
if not DataStore then return end

local addonName, addon = ...
local thisCharacter
local setInfo
local collectedSets
local appearancesCounters


local DataStore = DataStore
local TableInsert, TableConcat, strfind, format, strsplit, pairs, type, tonumber, select, time = table.insert, table.concat, string.find, format, strsplit, pairs, type, tonumber, select, time
local GetAverageItemLevel, GetInventoryItemLink, GetItemInfo, GetItemInfoInstant, UnitClass = GetAverageItemLevel, GetInventoryItemLink, GetItemInfo, GetItemInfoInstant, UnitClass
local C_TransmogCollection, C_TransmogSets = C_TransmogCollection, C_TransmogSets

local isRetail = (WOW_PROJECT_ID == WOW_PROJECT_MAINLINE)
local isMists = LE_EXPANSION_LEVEL_CURRENT == LE_EXPANSION_LEVEL_MISTS_OF_PANDARIA
local L = AddonFactory:GetLocale(addonName)
local bit64 = LibStub("LibBit64")


-- *** Utility functions ***
local NUM_EQUIPMENT_SLOTS = 30			-- 30 slots when counting the new profession tools added in 10.0

local function IsEnchanted(link)
	if not link then return end
	
	if not strfind(link, "item:%d+:0:0:0:0:0:0:%d+:%d+:0:0") then	-- 7th is the UniqueID, 8th LinkLevel which are irrelevant
		-- enchants/jewels store values instead of zeroes in the link, if this string can't be found, there's at least one enchant/jewel
		return true
	end
end


-- *** Scanning functions ***
local handleItemInfo

local function ScanAverageItemLevel()
	local char = thisCharacter
	char.lastUpdate = time()
	char.overallAIL = 0

	-- GetAverageItemLevel only exists in retail
	if type(GetAverageItemLevel) == "function" then

		local overallAiL, AiL = GetAverageItemLevel()
		if overallAiL and AiL and overallAiL > 0 and AiL > 0 then
			char.overallAIL = overallAiL
			char.averageItemLvl = AiL
		end
		return
	end
	
	-- if we get here, GetAverageItemLevel does not exist, we must calculate manually.
	local totalItemLevel = 0
	local itemCount = 0
	
	-- Only the 18 first slots are relevant when scanning the AiL (19 = tabard, followed by profession tools)
	for i = 1, 18 do
		local link = GetInventoryItemLink("player", i)
		
		if link then
			local itemName = GetItemInfo(link)
			
			if not itemName then
				--print("Waiting for equipment slot "..i) --debug
				handleItemInfo = true
				-- addon:RegisterEvent("GET_ITEM_INFO_RECEIVED", OnGetItemInfoReceived)
				return -- wait for GET_ITEM_INFO_RECEIVED (will be triggered by non-cached itemInfo request)
			end

			if i ~= 4 then		-- InventorySlotId 4 = shirt
				itemCount = itemCount + 1
				totalItemLevel = totalItemLevel + tonumber(((select(4, GetItemInfo(link))) or 0))
			end
		end
	end
	
	-- Found by qwarlocknew on 6/04/2021
	-- On an alt with no gear, the "if link" in the loop could always be nil, and thus the itemCount could be zero
	-- leading to a division by zero, so intercept this case
	--print(format("total: %d, count: %d, ail: %d",totalItemLevel, itemCount, totalItemLevel / itemCount)) --DAC
	char.averageItemLvl = totalItemLevel / math.max(itemCount, 1) -- math.max fixes divide by zero (bug credit: qwarlocknew)
end

local function ScanInventorySlot(slot)
	local inventory = thisCharacter.Inventory
	local link = GetInventoryItemLink("player", slot)

	local currentContent = inventory[slot]
	
	if link then 
		if IsEnchanted(link) then		-- if there's an enchant, save the full link
			inventory[slot] = link
		else 									-- .. otherwise, only save the id
			inventory[slot] = tonumber(link:match("item:(%d+)"))
		end
	else
		inventory[slot] = nil
	end
	
	if currentContent ~= inventory[slot] then		-- the content of this slot has actually changed since last scan
		AddonFactory:Broadcast("DATASTORE_INVENTORY_SLOT_UPDATED", slot)
	end
end

local function ScanInventory()
	local numGreen = 0
	local numBlue = 0
	local numPurple = 0
	local numHeirloom = 0
	local lowestILevel = 0
	local highestILevel = 0

	-- info at : https://wowpedia.fandom.com/wiki/InventorySlotId
	for slot = 1, NUM_EQUIPMENT_SLOTS do
		ScanInventorySlot(slot)
		
		if isRetail and slot ~= 4 and slot < 19 then
			-- https://wowpedia.fandom.com/wiki/ItemLocationMixin
			local itemLoc = ItemLocation:CreateFromEquipmentSlot(slot)

			if itemLoc:IsValid() then
				local quality = C_Item.GetItemQuality(itemLoc)
				
				if quality == 2 then
					numGreen = numGreen + 1
				elseif quality == 3 then
					numBlue = numBlue + 1
				elseif quality == 4 then
					numPurple = numPurple + 1
				elseif quality == 7 then
					numHeirloom = numHeirloom + 1
				end
				
				local level = C_Item.GetCurrentItemLevel(itemLoc)
				-- print("slot: " .. slot .. " level: " .. level)

				if level > highestILevel then
					highestILevel = level
				end
				
				if lowestILevel == 0 or level < lowestILevel then
					lowestILevel = level
				end
			end
		end
	end
	
	-- print("numGreen: " .. numGreen)
	-- print("numBlue: " .. numBlue)
	-- print("numPurple: " .. numPurple)
	-- print("lowestILevel: " .. lowestILevel)
	-- print("highestILevel: " .. highestILevel)
	
	thisCharacter.EquipmentInfo = numGreen				-- bits 0-4, 5 bits = number of green pieces
				+ bit64:LeftShift(numBlue, 5)				-- bits 5-9, 5 bits = number of blue pieces
				+ bit64:LeftShift(numPurple, 10)			-- bits 10-14, 5 bits = number of purple pieces
				+ bit64:LeftShift(numHeirloom, 15)		-- bits 15-19, 5 bits = number of heirloom pieces
				+ bit64:LeftShift(lowestILevel, 20)		-- bits 20-31, 12 bits = lowest iLevel
				+ bit64:LeftShift(highestILevel, 32)	-- bits 32+, 12 bits = highest iLevel
	thisCharacter.lastUpdate = time()
end

local function ScanTransmogCollection()
	local _, englishClass = UnitClass("player")
	
	appearancesCounters[englishClass] = appearancesCounters[englishClass] or {}
	local classCounters = appearancesCounters[englishClass]
	
	-- browse all categories
	for i = 1, DataStore:GetHashSize(Enum.TransmogCollectionType) - 1 do
		local name = C_TransmogCollection.GetCategoryInfo(i)
		if name then
			local collected = C_TransmogCollection.GetCategoryCollectedCount(i)
			local total = C_TransmogCollection.GetCategoryTotal(i)

			-- ex: [1] = "76/345" but in an integer
			classCounters[i] = total					-- bits 0-11, 12 bits = total appearances
				+ bit64:LeftShift(collected, 12)		-- bits 12-23, 12 bits = number of collected appearances
		end
	end
end

local classMasks = {
	[1] = "WARRIOR",
	[2] = "PALADIN",
	[4] = "HUNTER",
	[8] = "ROGUE",
	[16] = "PRIEST",
	[32] = "DEATHKNIGHT",
	[64] = "SHAMAN",
	[128] = "MAGE",
	[256] = "WARLOCK",
	[512] = "MONK",
	[1024] = "DRUID",
	[2048] = "DEMONHUNTER",
	[4096] = "EVOKER"
}

local classArmorMask = {
	["WARRIOR"] = 35, -- Warrior (1) + Paladin (2) + DeathKnight (32)
	["PALADIN"] = 35, -- Warrior (1) + Paladin (2) + DeathKnight (32)
	["DEATHKNIGHT"] = 35, -- Warrior (1) + Paladin (2) + DeathKnight (32)
	["PRIEST"] = 400, -- Priest (16) + Mage (128) + Warlock (256)
	["MAGE"] = 400, -- Priest (16) + Mage (128) + Warlock (256)
	["WARLOCK"] = 400, -- Priest (16) + Mage (128) + Warlock (256)
	["ROGUE"] = 3592, -- Rogue (8) + Monk (512) + Druid (1024) + DemonHunter (2048)
	["MONK"] = 3592, -- Rogue (8) + Monk (512) + Druid (1024) + DemonHunter (2048)
	["DRUID"] = 3592, -- Rogue (8) + Monk (512) + Druid (1024) + DemonHunter (2048)
	["DEMONHUNTER"] = 3592, -- Rogue (8) + Monk (512) + Druid (1024) + DemonHunter (2048)
	["HUNTER"] = 4164, -- Hunter (4) + Shaman (64) + Evoker (4096)
	["SHAMAN"] = 4164, -- Hunter (4) + Shaman (64) + Evoker (4096)
	["EVOKER"] = 4164, -- Hunter (4) + Shaman (64) + Evoker (4096)
}

local function ScanTransmogSets()
	local sets = C_TransmogSets.GetAllSets()
	if not sets then return end

	local englishClass = select(2, UnitClass("player"))
	
	for _, set in pairs(sets) do
		local class = classMasks[set.classMask]
		
		if classArmorMask[englishClass] == set.classMask then class = englishClass end

		--[[ 01/12/2024: Do not change this.
				It would be very tempting to read all classes at once, but even though it is possible, 
				the data can be wrong for classes other than the current one.
				Even worse, it can be wrong when comparing two characters of the same class.
				Something is very wrong on Blizzard's side.
				Case 1: 
				- I farm the Icecrown citadel sets for paladin, I complete the 3 versions fully with a paladin.
				- Then I log in with another alt, the completion of the paladin set is incorrect, even a few days later, so it's not just a matter of refreshing some cache.
				
				Case 2:
				- Same story for the warrior set. I complete it on one warrior.
				- Then a few days later I want to check the warrior set from another warrior, and same thing, it appears incomplete.
				
				Why make things easy when you can make them complicated ..
		--]]
		if class == englishClass then
			local setID = set.setID

			-- coming from Blizzard_Wardrobe.lua:
			-- WardrobeSetsDataProviderMixin:GetSetSourceData
			-- WardrobeSetsDataProviderMixin:GetSortedSetSources
			local appearances = C_TransmogSets.GetSetPrimaryAppearances(setID)
			local numTotal = 0
			local numCollected = 0
			local iconID = 0

			-- Avoid reading the iconID multiple times, because the call is memory intensive, so take the known saved iconID if we have one already.
			if setInfo[setID] then
				iconID = bit64:RightShift(setInfo[setID], 8)		-- bits 8+, iconID for this set
			end

			for _, appearance in pairs(appearances) do
				numTotal = numTotal + 1
				if appearance.collected then
					numCollected = numCollected + 1

					-- ex: [setID] = true, list of collected sets
					collectedSets[setID] = collectedSets[setID] or {}
					collectedSets[setID][appearance.appearanceID] = true
				end
				
				-- if we previously knew the iconID for this set, don't read it again
				if iconID == 0 then
				
					-- This call is causing a lot of memory consumption, do not do it too often
					local info = C_TransmogCollection.GetSourceInfo(appearance.appearanceID)
					
					-- Note that there is a direct way to get this item id with C_TransmogCollection.GetSourceItemID(itemModifiedAppearanceID)
					-- but it's still necessary to identify the head piece of gear, so we cannot skip the previous call.
					
					-- 2 = head slot, couldn't find the constant for that :(
					if info and info.invType == 2 then	
						iconID = info.itemID
						-- print("appear ID : " .. appearance.appearanceID .. " itemID : " ..info.itemID)
					end
				end
			end

			if numTotal == numCollected then
				collectedSets[set.setID] = nil	-- if set is complete, kill the table, the counters will tell it
			end
		
			setInfo[setID] = numTotal						-- bits 0-3, 4 bits = number of pieces in the set
				+ bit64:LeftShift(numCollected, 4)		-- bits 4-7, 4 bits = number of collected pieces
				+ bit64:LeftShift(iconID, 8)				-- bits 8+, iconID for this set
		end
	end
end


-- *** Event Handlers ***
local function OnPlayerAlive()
	ScanInventory()
	ScanAverageItemLevel()
	
	if isRetail then
		ScanTransmogSets()

		-- Scan again after 5 seconds, no less, to ensure that item info has been properly updated.
		C_Timer.After(5, ScanInventory)
	end
end

local function OnPlayerEquipmentChanged(event, slot)
	-- ScanInventorySlot(slot)
	ScanInventory()
	ScanAverageItemLevel()
	thisCharacter.lastUpdate = time()
end

local function OnPlayerAilReady()
	ScanAverageItemLevel()
end

local function OnTransmogCollectionLoaded()
	ScanTransmogCollection()
	ScanTransmogSets()
end

local function OnTransmogCollectionUpdated(event, collectionIndex, modID, itemAppearanceID, reason)
	ScanTransmogCollection()
	ScanTransmogSets()
end

local function OnGetItemInfoReceived(event, itemID, success)
	-- ignore calls unless otherwise specified
	if handleItemInfo then
		ScanAverageItemLevel()
		handleItemInfo = nil
	end
end

-- ** Mixins **
local function _GetInventory(character)
	return character.Inventory
end

local function _GetInventoryItem(character, slotID)
	return character.Inventory[slotID]
end

local function _GetInventoryItemCount(character, searchedID)
	local count = 0
	for _, item in pairs(character.Inventory) do
		if type(item) == "number" then		-- saved as a number ? this is the itemID
			if (item == searchedID) then
				count = count + 1
			end
		elseif tonumber(item:match("item:(%d+)")) == searchedID then		-- otherwise it's the item link
			count = count + 1
		end
	end
	return count
end
	
local function _GetAverageItemLevel(character)
	return character.averageItemLvl, character.overallAIL
end

local function _IterateInventory(character, callback)
	for _, item in pairs(character.Inventory) do
		callback(item)
	end
end

local function _GetNumUncommonEquipment(character)
	return character.EquipmentInfo
		and bit64:GetBits(character.EquipmentInfo, 0, 5)	-- bits 0-4, 5 bits = number of green pieces
		or 0
end

local function _GetNumRareEquipment(character)
	return character.EquipmentInfo
		and bit64:GetBits(character.EquipmentInfo, 5, 5)	-- bits 5-9, 5 bits = number of blue pieces
		or 0
end

local function _GetNumEpicEquipment(character)
	return character.EquipmentInfo
		and bit64:GetBits(character.EquipmentInfo, 10, 5)	-- bits 10-14, 5 bits = number of purple pieces
		or 0
end

local function _GetNumHeirloomEquipment(character)
	return character.EquipmentInfo
		and bit64:GetBits(character.EquipmentInfo, 15, 5)	-- bits 15-19, 5 bits = number of heirloom pieces
		or 0
end

local function _GetLowestItemLevel(character)
	return character.EquipmentInfo
		and bit64:GetBits(character.EquipmentInfo, 20, 12)	-- bits 20-31, 12 bits = lowest iLevel
		or 0
end

local function _GetHighestItemLevel(character)
	return character.EquipmentInfo
		and bit64:GetBits(character.EquipmentInfo, 32, 12)	-- bits 32+, 12 bits = highest iLevel
		or 0
end

local function _GetSetIcon(setID)
	
	-- *** now loaded through a scan, should not be necessary anymore. ***
	-- no cached item id ? look for one
	-- if not setInfo[setID] then 
		-- coming from Blizzard_Wardrobe.lua:
		-- WardrobeSetsDataProviderMixin:GetSetSourceData
		-- WardrobeSetsDataProviderMixin:GetSortedSetSources
		-- local appearances = C_TransmogSets.GetSetPrimaryAppearances(setID)
		
		-- for _, appearance in pairs(appearances) do
			-- local info = C_TransmogCollection.GetSourceInfo(appearance.appearanceID)
			
			-- 2 = head slot, couldn't find the constant for that :(
			-- if info and info.invType == 2 then	
				-- iconIDs[setID] = info.itemID
				-- break	-- we found the item we were looking for, leave the loop
			-- end
		-- end
	-- end

	if setInfo[setID] then
		local iconID = bit64:RightShift(setInfo[setID], 8)		-- bits 8+, iconID for this set
	
		-- return the icon
		return select(5, GetItemInfoInstant(iconID))
	end
	
	return QUESTION_MARK_ICON
end

local function _GetCollectedSetInfo(setID)
	-- numCollected, numTotal
	return bit64:GetBits(setInfo[setID], 4, 4), bit64:GetBits(setInfo[setID], 0, 4)
end

local function _IsSetCollected(setID)
	local numCollected, numTotal = _GetCollectedSetInfo(setID)
	return (numCollected == numTotal) and numTotal ~= 0
end

local function _IsSetItemCollected(setID, sourceID)
	local set = collectedSets[setID]
	return set and set[sourceID]
end


AddonFactory:OnAddonLoaded(addonName, function()
	DataStore:RegisterModule({
		addon = addon,
		addonName = addonName,
		rawTables = {
			"DataStore_Inventory_SetInfo",
			"DataStore_Inventory_CollectedSets",
			"DataStore_Inventory_AppearancesCounters",
			"DataStore_Inventory_Options"
		},
		characterTables = {
			["DataStore_Inventory_Characters"] = {
				GetInventory = _GetInventory,
				GetInventoryItem = _GetInventoryItem,
				GetInventoryItemCount = _GetInventoryItemCount,
				GetAverageItemLevel = _GetAverageItemLevel,
				IterateInventory = _IterateInventory,
				GetNumUncommonEquipment = isRetail and _GetNumUncommonEquipment,
				GetNumRareEquipment = isRetail and _GetNumRareEquipment,
				GetNumEpicEquipment = isRetail and _GetNumEpicEquipment,
				GetNumHeirloomEquipment = isRetail and _GetNumHeirloomEquipment,
				GetLowestItemLevel = isRetail and _GetLowestItemLevel,
				GetHighestItemLevel = isRetail and _GetHighestItemLevel,
			},
		},

	})
	
	thisCharacter = DataStore:GetCharacterDB("DataStore_Inventory_Characters", true)
	thisCharacter.Inventory = thisCharacter.Inventory or {}
	
	setInfo = DataStore_Inventory_SetInfo
	collectedSets = DataStore_Inventory_CollectedSets
	appearancesCounters = DataStore_Inventory_AppearancesCounters
	
	-- Stop here for non-retail
	if not isRetail then return end

	DataStore:RegisterMethod(addon, "GetSetIcon", _GetSetIcon)
	DataStore:RegisterMethod(addon, "IsSetCollected", _IsSetCollected)
	DataStore:RegisterMethod(addon, "IsSetItemCollected", _IsSetItemCollected)
	DataStore:RegisterMethod(addon, "GetCollectedSetInfo", _GetCollectedSetInfo)
end)

AddonFactory:OnPlayerLogin(function()
	addon:ListenTo("PLAYER_ALIVE", OnPlayerAlive)
	addon:ListenTo("PLAYER_EQUIPMENT_CHANGED", OnPlayerEquipmentChanged)
	
	if isRetail or isMists then
		addon:ListenTo("PLAYER_AVG_ITEM_LEVEL_UPDATE", OnPlayerAilReady)
		-- addon:ListenTo("TRANSMOG_COLLECTION_LOADED", OnTransmogCollectionLoaded)
		addon:ListenTo("TRANSMOG_COLLECTION_UPDATED", OnTransmogCollectionUpdated)
	else
		addon:ListenTo("GET_ITEM_INFO_RECEIVED", OnGetItemInfoReceived)
		addon:SetupOptions()
	end
end)


local PT = LibStub("LibPeriodicTable-3.1")
local BB = LibStub("LibBabble-Boss-3.0"):GetUnstrictLookupTable()

local DataSources = {
	"InstanceLoot",
	"InstanceLootHeroic",
	"InstanceLootLFR",
	"CurrencyItems",
}

-- stays out of public methods for now
function addon:GetSource(searchedID)
	local info, source
	for _, v in pairs(DataSources) do
		info, source = PT:ItemInSet(searchedID, v)
		if source then
			local _, instance, boss = strsplit(".", source)		-- ex: "InstanceLoot.Gnomeregan.Techbot"
			
			-- 21/07/2014: removed the "Heroic" information from the source info, as it is now shown on the item anyway
			-- This removed the Babble-Zone dependancy
			
			-- instance = BZ[instance] or instance
			-- if v == "InstanceLootHeroic" then
				-- instance = format("%s (%s)", instance, L["Heroic"])
								
			if v == "CurrencyItems" then
				-- for currency items, there will be no "boss" value, let's return the quantity instead
				boss = info.."x"
			end
			
			if boss == "Trash Mobs" then 
				boss = L["Trash Mobs"]
			else
				boss = BB[boss] or boss
			end
			
			return instance, boss
		end
	end
end
