--[[	*** DataStore_Inventory ***
Written by : Thaoky, EU-Marécages de Zangar
July 13th, 2009
--]]
if not DataStore then return end

local addonName = "DataStore_Inventory"

_G[addonName] = LibStub("AceAddon-3.0"):NewAddon(addonName, "AceConsole-3.0", "AceEvent-3.0", "AceComm-3.0", "AceSerializer-3.0")

local addon = _G[addonName]

local commPrefix = "DS_Inv"		-- let's keep it a bit shorter than the addon name, this goes on a comm channel, a byte is a byte ffs :p
local L = LibStub("AceLocale-3.0"):GetLocale(addonName)

-- Message types
local MSG_SEND_AIL								= 1	-- Send AIL at login
local MSG_AIL_REPLY								= 2	-- reply
local MSG_EQUIPMENT_REQUEST					= 3	-- request equipment ..
local MSG_EQUIPMENT_TRANSFER					= 4	-- .. and send the data

local AddonDB_Defaults = {
	global = {
		Options = {
			AutoClearGuildInventory = false,		-- Automatically clear guild members' inventory at login
			BroadcastAiL = true,						-- Broadcast professions at login or not
			EquipmentRequestNotification = false,	-- Get a warning when someone requests my equipment
		},
		Reference = {
			AppearancesCounters = {},				-- ex: ["MAGE"] = { [1] = "76/345" ... }	= category 1 => 76/345
			CollectedSets = {},						-- ex: [setID] = true, list of collected sets
			SetNumItems = {},							-- ex: [setID] = 8, number of pieces in a set
			SetNumCollected = {},					-- ex: [setID] = 4, number of collected pieces in a set
			SetIconIDs = {},							-- ex: [setID] = itemID, itemID of the icon that represents the set
		},
		Guilds = {
			['*'] = {			-- ["Account.Realm.Name"] 
				Members = {
					['*'] = {				-- ["MemberName"] 
						lastUpdate = nil,
						averageItemLvl = 0,
						Inventory = {},		-- 19 inventory slots, a simple table containing item id's or full item string if enchanted
					}
				}
			},
		},
		Characters = {
			['*'] = {				-- ["Account.Realm.Name"] 
				lastUpdate = nil,
				averageItemLvl = 0,
				overallAIL = 0,
				Inventory = {},		-- 19 inventory slots, a simple table containing item id's or full item string if enchanted
			}
		}
	}
}

-- *** Utility functions ***
local NUM_EQUIPMENT_SLOTS = 19

local function GetOption(option)
	return addon.db.global.Options[option]
end

local function IsEnchanted(link)
	if not link then return end
	
	if not string.find(link, "item:%d+:0:0:0:0:0:0:%d+:%d+:0:0") then	-- 7th is the UniqueID, 8th LinkLevel which are irrelevant
		-- enchants/jewels store values instead of zeroes in the link, if this string can't be found, there's at least one enchant/jewel
		return true
	end
end

local function GetThisGuild()
	local key = DataStore:GetThisGuildKey()
	return key and addon.db.global.Guilds[key] 
end

local function GetMemberKey(guild, member)
	-- returns the appropriate key to address a guild member. 
	--	Either it's a known alt ==> point to the characters table
	--	Or it's a guild member ==> point to the guild table
	local main = DataStore:GetNameOfMain(member)
	if main and main == UnitName("player") then
		local key = format("%s.%s.%s", DataStore.ThisAccount, DataStore.ThisRealm, member)
		return addon.db.global.Characters[key]
	end
	return guild.Members[member]
end

local function GetAIL(alts)
	-- alts = list of alts in the same guild, same realm, same account, pipe-delimited : "alt1|alt2|alt3..."
	--	usually provided by the main datastore module, but can also be built manually
	local out = {}
	
	local character = DataStore:GetCharacter()	-- this character
	local ail = DataStore:GetAverageItemLevel(character)
	table.insert(out, format("%s:%d", UnitName("player"), ail))

	if strlen(alts) > 0 then
		for _, name in pairs( { strsplit("|", alts) }) do	-- then all his alts
			character = DataStore:GetCharacter(name)
			if character then
				ail = DataStore:GetAverageItemLevel(character)
				if ail then
					table.insert(out, format("%s:%d", name, ail))
				end
			end
		end
	end
	return table.concat(out, "|")
end

local function SaveAIL(sender, ailList)
	local thisGuild = GetThisGuild()
	if not thisGuild then return end
	
	for _, ailChar in pairs( { strsplit("|", ailList) }) do	-- "char:ail | char:ail | ..."
		local name, ail = strsplit(":", ailChar)
		if name and ail then
			thisGuild.Members[name].averageItemLvl = tonumber(ail)
		end
	end
end

local function GuildBroadcast(messageType, ...)
	local serializedData = addon:Serialize(messageType, ...)
	addon:SendCommMessage(commPrefix, serializedData, "GUILD")
end

local function GuildWhisper(player, messageType, ...)
	if DataStore:IsGuildMemberOnline(player) then
		local serializedData = addon:Serialize(messageType, ...)
		addon:SendCommMessage(commPrefix, serializedData, "WHISPER", player)
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

	-- GetAverageItemLevel only exists in retail
	if type(GetAverageItemLevel) == "function" then

		local overallAiL, AiL = GetAverageItemLevel()
		if overallAiL and AiL and overallAiL > 0 and AiL > 0 then
			local character = addon.ThisCharacter
			character.overallAIL = overallAiL
			character.averageItemLvl = AiL
		end
		return
	end
	
	-- if we get here, GetAverageItemLevel does not exist, we must calculate manually.
	local totalItemLevel = 0
	local itemCount = 0
	
	for i = 1, NUM_EQUIPMENT_SLOTS do
		local link = GetInventoryItemLink("player", i)
		if link then
		
			local itemName = GetItemInfo(link)
			if not itemName then
				--print("Waiting for equipment slot "..i) --debug
				handleItemInfo = true
				-- addon:RegisterEvent("GET_ITEM_INFO_RECEIVED", OnGetItemInfoReceived)
				return -- wait for GET_ITEM_INFO_RECEIVED (will be triggered by non-cached itemInfo request)
			end

			if (i ~= 4) and (i ~= 19) then		-- InventorySlotId 4 = shirt, 19 = tabard, skip them
				itemCount = itemCount + 1
				totalItemLevel = totalItemLevel + tonumber(((select(4, GetItemInfo(link))) or 0))
			end
		end
	end
	
	-- Found by qwarlocknew on 6/04/2021
	-- On an alt with no gear, the "if link" in the loop could always be nil, and thus the itemCount could be zero
	-- leading to a division by zero, so intercept this case
	--print(format("total: %d, count: %d, ail: %d",totalItemLevel, itemCount, totalItemLevel / itemCount)) --DAC
	addon.ThisCharacter.averageItemLvl = totalItemLevel / math.max(itemCount, 1) -- math.max fixes divide by zero (bug credit: qwarlocknew)
	addon.ThisCharacter.lastUpdate = time()	
end

local function ScanInventorySlot(slot)
	local inventory = addon.ThisCharacter.Inventory
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
		addon:SendMessage("DATASTORE_INVENTORY_SLOT_UPDATED", slot)
	end
end

local function ScanInventory()
	for slot = 1, NUM_EQUIPMENT_SLOTS do
		ScanInventorySlot(slot)
	end
	
	addon.ThisCharacter.lastUpdate = time()
end

local function ScanTransmogCollection()
	local _, englishClass = UnitClass("player")
	
	local counters = addon.db.global.Reference.AppearancesCounters
	
	counters[englishClass] = counters[englishClass] or {}
	local classCounters = counters[englishClass]
	local name
	local collected, total
	
	-- browse all categories
	for i = 1, DataStore:GetHashSize(Enum.TransmogCollectionType) - 1 do
		name = C_TransmogCollection.GetCategoryInfo(i)
		if name then
			collected = C_TransmogCollection.GetCategoryCollectedCount(i)
			total = C_TransmogCollection.GetCategoryTotal(i)

			classCounters[i] = format("%s/%s", collected, total)		-- [1] = "76/345" ...
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
	local _, englishClass = UnitClass("player")
	local collectedSets = addon.db.global.Reference.CollectedSets
	-- counters[englishClass] = counters[englishClass] or {}
	-- local classCounters = counters[englishClass]

	local sets = C_TransmogSets.GetAllSets()
	if not sets then return end

	for _, set in pairs(sets) do
		local class = classMasks[set.classMask]
		
		if classArmorMask[englishClass] == set.classMask then class = englishClass end

		if class == englishClass then
			local setID = set.setID

			local appearances = C_TransmogSets.GetSetPrimaryAppearances(set.setID)
			local numTotal = 0
			local numCollected = 0

			for _, appearance in pairs(appearances) do
				numTotal = numTotal + 1
				if appearance.collected then
					numCollected = numCollected + 1

					collectedSets[setID] = collectedSets[setID] or {}
					collectedSets[setID][appearance.appearanceID] = true
				end
			end

			if numTotal == numCollected then
				collectedSets[set.setID] = nil	-- if set is complete, kill the table, the counters will tell it
			end

			addon.db.global.Reference.SetNumItems[setID] = numTotal
			addon.db.global.Reference.SetNumCollected[setID] = (numCollected ~= 0) and numCollected or nil
		end
	end
end


-- *** Event Handlers ***
local function OnPlayerAlive()
	ScanInventory()
	ScanAverageItemLevel()
	
	if WOW_PROJECT_ID == WOW_PROJECT_MAINLINE then
		ScanTransmogSets()
	end
end

local function OnPlayerEquipmentChanged(event, slot)
	ScanInventorySlot(slot)
	ScanAverageItemLevel()
	addon.ThisCharacter.lastUpdate = time()
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
				addon:SendMessage("DATASTORE_PLAYER_EQUIPMENT_RECEIVED", player, member)
				return
			end
		end
	end
	
	if main == player then	-- if player requests the equipment of one of own alts, process the request locally, using the network works fine, but let's save the traffic.
		-- trigger the same event, _GetGuildMemberInventoryItem will take care of picking the data in the right place
		addon:SendMessage("DATASTORE_PLAYER_EQUIPMENT_RECEIVED", player, member)
		return
	end
	
	-- prevent spamming remote players with too many requests
	sentRequests = sentRequests or {}
	
	if sentRequests[main] and ((time() - sentRequests[main]) < 5) then		-- if there's a known timestamp , and it was sent less than 5 seconds ago .. exit
		return
	end
	
	sentRequests[main] = time()		-- timestamp of the last request sent to this player
	GuildWhisper(main, MSG_EQUIPMENT_REQUEST, member)
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
	local iconIDs = addon.db.global.Reference.SetIconIDs

	-- no cached item id ? look for one
	if not iconIDs[setID] then 
		-- coming from Blizzard_Wardrobe.lua:
		-- WardrobeSetsDataProviderMixin:GetSetSourceData
		-- WardrobeSetsDataProviderMixin:GetSortedSetSources
		local apppearances = C_TransmogSets.GetSetPrimaryAppearances(setID)
		
		for _, appearance in pairs(apppearances) do
			local info = C_TransmogCollection.GetSourceInfo(appearance.appearanceID)
			
			-- 2 = head slot, couldn't find the constant for that :(
			if info and info.invType == 2 then	
				iconIDs[setID] = info.itemID
				break	-- we found the item we were looking for, leave the loop
			end
		end
	end

	if iconIDs[setID] then
		local _, _, _, _, icon = GetItemInfoInstant(iconIDs[setID])
		return icon
	end
	return QUESTION_MARK_ICON
end

local function _IsSetCollected(setID)
	local ref = addon.db.global.Reference

	-- should not be nil, but default to -1 to fail comparison below
	local numTotal = ref.SetNumItems[setID] or -1

	-- may be nil (= 0 collected)
	local numCollected = ref.SetNumCollected[setID] or 0

	return (numCollected == numTotal)
end

local function _IsSetItemCollected(setID, sourceID)
	local set = addon.db.global.Reference.CollectedSets[setID]
	return (set and set[sourceID])
end

local function _GetCollectedSetInfo(setID)
	local ref = addon.db.global.Reference

	local numTotal = ref.SetNumItems[setID] or 0
	local numCollected = ref.SetNumCollected[setID] or 0

	return numCollected, numTotal
end


local PublicMethods = {
	GetInventory = _GetInventory,
	GetInventoryItem = _GetInventoryItem,
	GetInventoryItemCount = _GetInventoryItemCount,
	GetAverageItemLevel = _GetAverageItemLevel,
	RequestGuildMemberEquipment = _RequestGuildMemberEquipment,
	GetGuildMemberInventoryItem = _GetGuildMemberInventoryItem,
	GetGuildMemberAverageItemLevel = _GetGuildMemberAverageItemLevel,
}

if WOW_PROJECT_ID == WOW_PROJECT_MAINLINE then
	PublicMethods.IterateInventory = _IterateInventory
	PublicMethods.GetSetIcon = _GetSetIcon
	PublicMethods.IsSetCollected = _IsSetCollected
	PublicMethods.IsSetItemCollected = _IsSetItemCollected
	PublicMethods.GetCollectedSetInfo = _GetCollectedSetInfo
end


-- *** Guild Comm ***
local function OnGuildAltsReceived(self, sender, alts)
	if sender == UnitName("player") and GetOption("BroadcastAiL") then				-- if I receive my own list of alts in the same guild, same realm, same account..
		GuildBroadcast(MSG_SEND_AIL, GetAIL(alts))	-- ..then broacast AIL
	end
end

local GuildCommCallbacks = {
	[MSG_SEND_AIL] = function(sender, ail)
			local player = UnitName("player")
			if sender ~= player then						-- don't send back to self
				local alts = DataStore:GetGuildMemberAlts(player)			-- get my own alts
				if alts and GetOption("BroadcastAiL") then
					GuildWhisper(sender, MSG_AIL_REPLY, GetAIL(alts))		-- .. and send them back
				end
			end
			SaveAIL(sender, ail)
		end,
	[MSG_AIL_REPLY] = function(sender, ail)
			SaveAIL(sender, ail)
		end,
	[MSG_EQUIPMENT_REQUEST] = function(sender, character)
			if GetOption("EquipmentRequestNotification") then
				addon:Print(format(L["%s is inspecting %s"], sender, character))
			end
	
			local key = DataStore:GetCharacter(character)	-- this realm, this account
			if key then
				GuildWhisper(sender, MSG_EQUIPMENT_TRANSFER, character, DataStore:GetInventory(key))
			end
		end,
	[MSG_EQUIPMENT_TRANSFER] = function(sender, character, equipment)
			local thisGuild = GetThisGuild()
			if thisGuild then
				thisGuild.Members[character].Inventory = equipment
				thisGuild.Members[character].lastUpdate = time()
				addon:SendMessage("DATASTORE_PLAYER_EQUIPMENT_RECEIVED", sender, character)
			end
		end,
}

function addon:OnInitialize()
	addon.db = LibStub("AceDB-3.0"):New(addonName .. "DB", AddonDB_Defaults)

	DataStore:RegisterModule(addonName, addon, PublicMethods)
	DataStore:SetGuildCommCallbacks(commPrefix, GuildCommCallbacks)
	
	DataStore:SetCharacterBasedMethod("GetInventory")
	DataStore:SetCharacterBasedMethod("GetInventoryItem")
	DataStore:SetCharacterBasedMethod("GetInventoryItemCount")
	DataStore:SetCharacterBasedMethod("GetAverageItemLevel")
	
	if WOW_PROJECT_ID == WOW_PROJECT_MAINLINE then
		DataStore:SetCharacterBasedMethod("IterateInventory")
	end
	
	DataStore:SetGuildBasedMethod("GetGuildMemberInventoryItem")
	DataStore:SetGuildBasedMethod("GetGuildMemberAverageItemLevel")
	
	addon:RegisterMessage("DATASTORE_GUILD_ALTS_RECEIVED", OnGuildAltsReceived)
	addon:RegisterComm(commPrefix, DataStore:GetGuildCommHandler())
end

function addon:OnEnable()
	addon:RegisterEvent("PLAYER_ALIVE", OnPlayerAlive)
	addon:RegisterEvent("PLAYER_EQUIPMENT_CHANGED", OnPlayerEquipmentChanged)
	
	if WOW_PROJECT_ID == WOW_PROJECT_MAINLINE then
		-- addon:RegisterEvent("PLAYER_AVG_ITEM_LEVEL_READY", OnPlayerAilReady)
		-- addon:RegisterEvent("TRANSMOG_COLLECTION_LOADED", OnTransmogCollectionLoaded)
		addon:RegisterEvent("TRANSMOG_COLLECTION_UPDATED", OnTransmogCollectionUpdated)
	else
		addon:RegisterEvent("GET_ITEM_INFO_RECEIVED", OnGetItemInfoReceived)
	end
	
	addon:SetupOptions()
	
	if GetOption("AutoClearGuildInventory") then
		ClearGuildInventories()
	end
end

function addon:OnDisable()
	addon:UnregisterEvent("PLAYER_ALIVE")
	addon:UnregisterEvent("PLAYER_EQUIPMENT_CHANGED")
end


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
