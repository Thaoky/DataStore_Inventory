--[[ 
This file keeps track of the guild communication when exchanging player inventories
--]]

local addonName, addon = ...
local guilds
local options

local DataStore = DataStore
local TableInsert, TableConcat, format, strsplit, pairs, type, tonumber, time = table.insert, table.concat, format, strsplit, pairs, type, tonumber, time
local UnitName = UnitName

local commPrefix = "DS_Inv"
local L = DataStore:GetLocale(addonName)

-- Message types
local MSG_SEND_AIL								= 1	-- Send AIL at login
local MSG_AIL_REPLY								= 2	-- reply
local MSG_EQUIPMENT_REQUEST					= 3	-- request equipment ..
local MSG_EQUIPMENT_TRANSFER					= 4	-- .. and send the data

-- *** Utility functions ***
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
			thisGuild.Members[name] = thisGuild.Members[name] or {}
			thisGuild.Members[name].averageItemLvl = tonumber(ail)
		end
	end
end

local function ClearGuildInventories()
	local thisGuild = GetThisGuild()
	if thisGuild and thisGuild.Members then
		wipe(thisGuild.Members)
	end
end


-- ** Mixins **
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
	DataStore:RegisterTables({
		addon = addon,
		guildTables = {
			["DataStore_Inventory_Guilds"] = {
				GetGuildMemberInventoryItem = _GetGuildMemberInventoryItem,
				GetGuildMemberAverageItemLevel = _GetGuildMemberAverageItemLevel,
			},
		},
	})
	
	guilds = DataStore_Inventory_Guilds
	
	local guildID = DataStore:GetCharacterGuildID(DataStore.ThisCharKey)
	if guildID then
		guilds[guildID] = guilds[guildID] or {}				-- Create the guild
	end

	DataStore:SetGuildCommCallbacks(commPrefix, commCallbacks)
	DataStore:ListenTo("DATASTORE_GUILD_ALTS_RECEIVED", OnGuildAltsReceived)
	DataStore:OnGuildComm(commPrefix, DataStore:GetGuildCommHandler())
	
	DataStore:RegisterMethod(addon, "RequestGuildMemberEquipment", _RequestGuildMemberEquipment)
end)

DataStore:OnPlayerLogin(function()
	options = DataStore:SetDefaults("DataStore_Inventory_Options", {
		BroadcastAiL = true,							-- Broadcast professions at login or not
		AutoClearGuildInventory = false,			-- Automatically clear guild members' inventory at login
		EquipmentRequestNotification = false,	-- Get a warning when someone requests my equipment
	})

	if options.AutoClearGuildInventory then
		ClearGuildInventories()
	end
end)
