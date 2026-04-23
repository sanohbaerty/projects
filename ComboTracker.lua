local ReplicatedStorage = game.ReplicatedStorage
local Modules = ReplicatedStorage.Modules
local GameConfig = require(Modules.Shared.GameConfig)
local PlayerSignals = require(Modules.Shared.PlayerSignals)

local ComboTracker = {}

local DefaultComboTable = {
	CurrentCombo = 1,
	Combo = 0,
	Time = os.clock()
}

function ComboTracker:Advance(player: Player, move: string)
	local data = ComboTracker[player] or table.clone(DefaultComboTable)

	local moveData = GameConfig.Moves[move]:: GameConfig.Move
	local max = #moveData.Damage

	local nextCombo = data.Combo % max + 1

	data.CurrentCombo = nextCombo
	data.Combo += 1
	data.Time = os.clock()
	
	ComboTracker[player] = data
	return nextCombo
end

function ComboTracker:Reset(player: Player)
	local data = ComboTracker[player] or table.clone(DefaultComboTable)
	data.Time = os.clock()
	data.Combo = 0
	data.CurrentCombo = 1
	
	ComboTracker[player] = data
end

function ComboTracker.getStep(player, move)
	return (ComboTracker[player] or DefaultComboTable).CurrentCombo
end

function ComboTracker.getLastHitTime(player)
	return (ComboTracker[player] or DefaultComboTable).Time
end

function ComboTracker:StartResetTimer(player, move)
	local moveData = GameConfig.Moves[move]:: GameConfig.Move
	local resetTime = moveData.ComboResetTime
	
	local hitTime = ComboTracker[player].Time
	
	task.delay(resetTime, function()
		if ComboTracker[player] and ComboTracker[player].Time == hitTime then
			ComboTracker:Reset(player)
		end
	end)
end

PlayerSignals.PlayerRemoving:Connect(function(player)
	ComboTracker[player] = nil
end)

return ComboTracker
