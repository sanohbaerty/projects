local PlayerData = {}

local Players = game.Players
local ReplicatedStorage = game.ReplicatedStorage

local RunService = game:GetService("RunService")

local Modules = ReplicatedStorage.Modules
local ServerModules = Modules.Server
local SharedModules = Modules.Shared

local Signals = require(SharedModules.Signals)
local PlayerSignals = require(SharedModules.PlayerSignals)
local ProfileStore = require(ServerModules.ProfileStore)
local DataTemplate = require(script.DataTemplate)
local DataManager = require(script.DataManager)

local function GetStoreName()
	return RunService:IsStudio() and "Test" or "Live"
end

local PlayerStore = ProfileStore.New(GetStoreName(), DataTemplate)

local DataErrorKickMSG = "Data Error: Please Rejoin."

local function Initialize(player: Player, profile: typeof(PlayerStore:StartSessionAsync()))
	local leaderstats = Instance.new("Folder")
	leaderstats.Name = "leaderstats"
	leaderstats.Parent = player
	
	local Level = Instance.new("IntValue")
	Level.Name = "Level"
	Level.Parent = leaderstats
	Level.Value = DataManager.Profiles[player].Data.Level
	
	local Exp = Instance.new("IntValue")
	Exp.Name = "Exp"
	Exp.Parent = leaderstats
	Exp.Value = DataManager.Profiles[player].Data.Exp
end

PlayerData.onReady = function()
	PlayerSignals.PlayerAdded:Connect(function(player)
		local profile = PlayerStore:StartSessionAsync("Player_" .. player.UserId, {
			Cancel = function()
				return player.Parent ~= Players
			end,
		})

		if not profile then
			player:Kick(DataErrorKickMSG)
			return 
		end

		profile:AddUserId(player.UserId)
		profile:Reconcile()

		profile.OnSessionEnd:Connect(function()
			DataManager.Profiles[player] = nil
			player:Kick(DataErrorKickMSG)
		end)

		if player.Parent == Players then
			DataManager.Profiles[player] = profile
			Initialize(player, profile)
		else
			profile:EndSession()
		end
	end)

	PlayerSignals.PlayerRemoving:Connect(function(player)
		local profile = DataManager.Profiles[player]:: typeof(PlayerStore:StartSessionAsync())
		if not profile then return end

		profile:EndSession()
		DataManager.Profiles[player] = nil
	end)
end

PlayerData.Modify = function(player: Player, value: string, overwrite: number | string | {})
	DataManager:Modify(player, value, overwrite)
end

PlayerData.OverWrite = function(player: Player, overwrite: {})
	DataManager.Profiles[player].Data = overwrite
end

PlayerData.Get = function(player: Player)
	local profile = DataManager.Profiles[player]
	if not profile then return end
	
	return profile.Data
end

return PlayerData
