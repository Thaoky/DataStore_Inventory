--[[	*** DataStore_Inventory ***
Written by : Thaoky, EU-Marécages de Zangar
July 13th, 2009
--]]
if not DataStore then return end

local addonName, addon = ...
local thisCharacter
local guilds
local setInfo
local collectedSets
local appearancesCounters
local options

local DataStore = DataStore
local TableInsert, TableConcat, strfind, format, strsplit, pairs, type, tonumber, select, time = table.insert, table.concat, string.find, format, strsplit, pairs, type, tonumber, select, time
local GetAverageItemLevel, GetInventoryItemLink, GetItemInfo, GetItemInfoInstant, UnitClass, UnitName = GetAverageItemLevel, GetInventoryItemLink, GetItemInfo, GetItemInfoInstant, UnitClass, UnitName
local C_TransmogCollection, C_TransmogSets = C_TransmogCollection, C_TransmogSets

local commPrefix = "DS_Inv"
local isRetail = (WOW_PROJECT_ID == WOW_PROJECT_MAINLINE)

local L = DataStore:GetLocale(addonName)
local bit64 = LibStub("LibBit64")

-- Message types
local MSG_SEND_AIL								= 1	-- Send AIL at login
local MSG_AIL_REPLY								= 2	-- reply
local MSG_EQUIPMENT_REQUEST					= 3	-- request equipment ..
local MSG_EQUIPMENT_TRANSFER					= 4	-- .. and send the data

-- *** Utility functions ***
local NUM_EQUIPMENT_SLOTS = 30			-- 30 slots when counting the new profession tools added in 10.0

local function IsEnchanted(link)
	if not link then return end
	
	if not strfind(link, "item:%d+:0:0:0:0:0:0:%d+:%d+:0:0") then	-- 7th is the UniqueID, 8th LinkLevel which are irrelevant
		-- enchants/jewels store values instead of zeroes in the link, if this string can't be found, there's at least one enchant/jewel
		return true
	end
end

local function GetThisGuild()
	local guildID = DataStore:GetCharacterGuildID(DataStore.ThisCharKey)
	return guildID and guilds[guildID] 
end

local function GetMemberKey(guild, member)
	-- returns the appropriate key to address a guild member. 
	--	Either it's a known alt ==> point to the characters table
	--	Or it's a guild member ==> point to the guild table
	local main = DataStore:GetNameOfMain(member)
	
	if main and main == UnitName("player") then
		local key = format("%s.%s.%s", DataStore.ThisAccount, DataStore.ThisRealm, member)
		local id = DataStore:GetCharacterID(key)
		
		return DataStore_Inventory_Characters[id]
	end
	
	return guild.Members[member]
end

local function GetAIL(alts)
	-- alts = list of alts in the same guild, same realm, same account, pipe-delimited : "alt1|alt2|alt3..."
	--	usually provided by the main datastore module, but can also be built manually
	local out = {}
	
	local character = DataStore:GetCharacter()	-- this character
	local ail = DataStore:GetAverageItemLevel(character)
	TableInsert(out, format("%s:%d", UnitName("player"), ail))

	if strlen(alts) > 0 then
		for _, name in pairs( { strsplit("|", alts) }) do	-- then all his alts
			character = DataStore:GetCharacter(name)
			
			if character then
				ail = DataStore:GetAverageItemLevel(character)
				
				if ail then
					TableInsert(out, format("%s:%d", name, ail))
				end
			end
		end
	end

	return TableConcat(out, "|")
end

local function SaveAIL(sender, ailList)
	local thisGuild = GetThisGuild()
	if not thisGuild then return end
	
	thisGuild.Members = thisGuild.Members or {}
	
	for _, ailChar in pairs( { strsplit("|", ailList) }) do	-- "char:ail | char:ail | ..."
		local name, ail = strsplit(":", ailChar)
		
		if name and ail then
			thisGuild.Members[name].averageItemLvl = tonumber(ail)
		end
	end
end

local function ClearGuildInventories()
	local thisGuild = GetThisGuild()
	if thisGuild then
		wipe(thisGuild.Members)
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
		DataStore:Broadcast("DATASTORE_INVENTORY_SLOT_UPDATED", slot)
	end
end

local function ScanInventory()
	-- info at : https://wowpedia.fandom.com/wiki/InventorySlotId
	for slot = 1, NUM_EQUIPMENT_SLOTS do
		ScanInventorySlot(slot)
	end
	
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

		if class == englishClass then
			local setID = set.setID

			-- coming from Blizzard_Wardrobe.lua:
			-- WardrobeSetsDataProviderMixin:GetSetSourceData
			-- WardrobeSetsDataProviderMixin:GetSortedSetSources
			local appearances = C_TransmogSets.GetSetPrimaryAppearances(setID)
			local numTotal = 0
			local numCollected = 0
			local iconID = 0

			for _, appearance in pairs(appearances) do
				numTotal = numTotal + 1
				if appearance.collected then
					numCollected = numCollected + 1

					-- ex: [setID] = true, list of collected sets
					collectedSets[setID] = collectedSets[setID] or {}
					collectedSets[setID][appearance.appearanceID] = true
				end
				
				local info = C_TransmogCollection.GetSourceInfo(appearance.appearanceID)
				
				-- 2 = head slot, couldn't find the constant for that :(
				if info and info.invType == 2 then	
					iconID = info.itemID
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
	end
end

local function OnPlayerEquipmentChanged(event, slot)
	ScanInventorySlot(slot)
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

local function OnTransmogCollectionUpdated()
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

local sentRequests		-- recently sent requests

local function _RequestGuildMemberEquipment(member)
	-- requests the equipment of a given character (alt or main)
	local player = UnitName("player")
	local main = DataStore:GetNameOfMain(member)
	
	if not main then 		-- player is offline, check if his equipment is in the DB
		local thisGuild = GetThisGuild()
		
		if thisGuild and thisGuild.Members[member] then		-- player found
			if thisGuild.Members[member].Inventory then		-- equipment found
				DataStore:Broadcast("DATASTORE_PLAYER_EQUIPMENT_RECEIVED", player, member)
				return
			end
		end
	end
	
	if main == player then	-- if player requests the equipment of one of own alts, process the request locally, using the network works fine, but let's save the traffic.
		-- trigger the same event, _GetGuildMemberInventoryItem will take care of picking the data in the right place
		DataStore:Broadcast("DATASTORE_PLAYER_EQUIPMENT_RECEIVED", player, member)
		return
	end
	
	-- prevent spamming remote players with too many requests
	sentRequests = sentRequests or {}
	
	if sentRequests[main] and ((time() - sentRequests[main]) < 5) then		-- if there's a known timestamp , and it was sent less than 5 seconds ago .. exit
		return
	end
	
	sentRequests[main] = time()		-- timestamp of the last request sent to this player
	DataStore:GuildWhisper(commPrefix, main, MSG_EQUIPMENT_REQUEST, member)
end

local function _GetGuildMemberInventoryItem(guild, member, slotID)
	local character = GetMemberKey(guild, member)
	
	if character then
		return character.Inventory[slotID]
	end
end

local function _GetGuildMemberAverageItemLevel(guild, member)
	local character = GetMemberKey(guild, member)

	if character then
		return character.averageItemLvl
	end
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



-- *** Guild Comm ***
local function OnGuildAltsReceived(self, sender, alts)
	if sender == UnitName("player") and options.BroadcastAiL then				-- if I receive my own list of alts in the same guild, same realm, same account..
		DataStore:GuildBroadcast(commPrefix, MSG_SEND_AIL, GetAIL(alts))	-- ..then broacast AIL
	end
end

local commCallbacks = {
	[MSG_SEND_AIL] = function(sender, ail)
			local player = UnitName("player")
			if sender ~= player then						-- don't send back to self
				local alts = DataStore:GetGuildMemberAlts(player)			-- get my own alts
				if alts and options.BroadcastAiL then
					DataStore:GuildWhisper(commPrefix, sender, MSG_AIL_REPLY, GetAIL(alts))		-- .. and send them back
				end
			end
			SaveAIL(sender, ail)
		end,
	[MSG_AIL_REPLY] = function(sender, ail)
			SaveAIL(sender, ail)
		end,
	[MSG_EQUIPMENT_REQUEST] = function(sender, character)
			if options.EquipmentRequestNotification then
				addon:Print(format(L["%s is inspecting %s"], sender, character))
			end
	
			local key = DataStore:GetCharacter(character)	-- this realm, this account
			if key then
				DataStore:GuildWhisper(commPrefix, sender, MSG_EQUIPMENT_TRANSFER, character, DataStore:GetInventory(key))
			end
		end,
	[MSG_EQUIPMENT_TRANSFER] = function(sender, character, equipment)
			local thisGuild = GetThisGuild()
			if thisGuild then
				thisGuild.Members[character].Inventory = equipment
				thisGuild.Members[character].lastUpdate = time()
				DataStore:Broadcast("DATASTORE_PLAYER_EQUIPMENT_RECEIVED", sender, character)
			end
		end,
}

DataStore:OnAddonLoaded(addonName, function()
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
				IterateInventory = isRetail and _IterateInventory,
			},
		},
		guildTables = {
			["DataStore_Inventory_Guilds"] = {
				GetGuildMemberInventoryItem = _GetGuildMemberInventoryItem,
				GetGuildMemberAverageItemLevel = _GetGuildMemberAverageItemLevel,
			},
		},
	})
	
	thisCharacter = DataStore:GetCharacterDB("DataStore_Inventory_Characters", true)
	thisCharacter.Inventory = thisCharacter.Inventory or {}
	
	guilds = DataStore_Inventory_Guilds
	setInfo = DataStore_Inventory_SetInfo
	collectedSets = DataStore_Inventory_CollectedSets
	appearancesCounters = DataStore_Inventory_AppearancesCounters
	

	DataStore:SetGuildCommCallbacks(commPrefix, commCallbacks)
	DataStore:ListenTo("DATASTORE_GUILD_ALTS_RECEIVED", OnGuildAltsReceived)
	DataStore:OnGuildComm(commPrefix, DataStore:GetGuildCommHandler())
	
	DataStore:RegisterMethod(addon, "RequestGuildMemberEquipment", _RequestGuildMemberEquipment)
	
	-- Stop here for non-retail
	if not isRetail then return end

	DataStore:RegisterMethod(addon, "GetSetIcon", _GetSetIcon)
	DataStore:RegisterMethod(addon, "IsSetCollected", _IsSetCollected)
	DataStore:RegisterMethod(addon, "IsSetItemCollected", _IsSetItemCollected)
	DataStore:RegisterMethod(addon, "GetCollectedSetInfo", _GetCollectedSetInfo)
end)

DataStore:OnPlayerLogin(function()
	options = DataStore_Inventory_Options
	
	options.AutoClearGuildInventory = options.AutoClearGuildInventory or false					-- Automatically clear guild members' inventory at login
	options.BroadcastAiL = options.BroadcastAiL or true												-- Broadcast professions at login or not
	options.EquipmentRequestNotification = options.EquipmentRequestNotification or false	-- Get a warning when someone requests my equipment
	
	addon:ListenTo("PLAYER_ALIVE", OnPlayerAlive)
	addon:ListenTo("PLAYER_EQUIPMENT_CHANGED", OnPlayerEquipmentChanged)
	
	if isRetail then
		-- addon:ListenTo("PLAYER_AVG_ITEM_LEVEL_READY", OnPlayerAilReady)
		-- addon:ListenTo("TRANSMOG_COLLECTION_LOADED", OnTransmogCollectionLoaded)
		addon:ListenTo("TRANSMOG_COLLECTION_UPDATED", OnTransmogCollectionUpdated)
	else
		addon:ListenTo("GET_ITEM_INFO_RECEIVED", OnGetItemInfoReceived)
		addon:SetupOptions()
	end
	
	if options.AutoClearGuildInventory then
		ClearGuildInventories()
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
