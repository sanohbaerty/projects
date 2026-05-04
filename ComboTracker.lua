local ReplicatedStorage = game.ReplicatedStorage
local Modules = ReplicatedStorage.Modules
local GameConfig = require(Modules.Shared.GameConfig)
local PlayerSignals = require(Modules.Shared.PlayerSignals)
local Signals = require(Modules.Shared.Signals)

local ComboTracker = {}

if game.RunService:IsClient() then
	ComboTracker.ComboChanged = Signals.new()
	ComboTracker.ComboEnded = Signals.new()
end

local function getDefaultMoveData()
	return {
		Combo = 0,
		CurrentCombo = 1,
		Time = os.clock(),
		ResetToken = 0
	}
end

local function getMoveData(character)
	if not ComboTracker[character] then
		ComboTracker[character] = getDefaultMoveData()
	end
	return ComboTracker[character]
end
function ComboTracker:Advance(character: Model, move: string)
	local data = getMoveData(character)

	local moveData = GameConfig.Moves[move]
	local max = #moveData.Damage

	local nextCombo = data.Combo % max + 1

	data.CurrentCombo = nextCombo
	data.Combo += 1
	data.Time = os.clock()
	data.ResetToken += 1

	if self.ComboChanged then
		self.ComboChanged:Fire(character, move, nextCombo)
	end

	return nextCombo
end

function ComboTracker:Reset(character: Model)
	local data = getMoveData(character)

	data.Combo = 0
	data.CurrentCombo = 1
	data.Time = os.clock()

	if self.ComboEnded then
		self.ComboEnded:Fire(character)
	end
end

function ComboTracker.getStep(character, move)
	if ComboTracker[character] then
		return ComboTracker[character].CurrentCombo
	end
	return 1
end

function ComboTracker.getLastHitTime(character, move)
	if ComboTracker[character] then
		return ComboTracker[character].Time
	end
	return os.clock()
end

function ComboTracker:StartResetTimer(character: Model)
	local data = getMoveData(character)
	local token = data.ResetToken

	task.delay(1.2, function()
		local current = getMoveData(character)

		if current.ResetToken == token then
			self:Reset(character)
		end
	end)
end

ComboTracker.onReady = function()
	if game.RunService:IsServer() then
		PlayerSignals.PlayerAdded:Connect(function(player)
			player.CharacterAdded:Connect(function(character)
				ComboTracker[character] = nil
			end)
		end)
	else
		game.Players.LocalPlayer.CharacterAdded:Connect(function()
			ComboTracker[game.Players.LocalPlayer.Character] = nil
		end)
	end
end

return ComboTracker
