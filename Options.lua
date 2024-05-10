if not DataStore then return end

local addonName, addon = ...

function addon:SetupOptions()
	local f = DataStore.Frames.InventoryOptions
	
	DataStore:AddOptionCategory(f, addonName, "DataStore")

	-- restore saved options to gui
	local options = DataStore_Inventory_Options
	
	f.AutoClearGuildInventory:SetChecked(options.AutoClearGuildInventory)
	f.BroadcastAiL:SetChecked(options.BroadcastAiL)
	f.EquipmentRequestNotification:SetChecked(options.EquipmentRequestNotification)
end
