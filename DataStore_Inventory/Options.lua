if not DataStore then return end

local addonName = "DataStore_Inventory"
local addon = _G[addonName]
local L = LibStub("AceLocale-3.0"):GetLocale(addonName)

function addon:SetupOptions()
	local f = DataStore.Frames.InventoryOptions
	
	DataStore:AddOptionCategory(f, addonName, "DataStore")

	-- restore saved options to gui
	f.AutoClearGuildInventory:SetChecked(DataStore:GetOption(addonName, "AutoClearGuildInventory"))
	f.BroadcastAiL:SetChecked(DataStore:GetOption(addonName, "BroadcastAiL"))
	f.EquipmentRequestNotification:SetChecked(DataStore:GetOption(addonName, "EquipmentRequestNotification"))
end
