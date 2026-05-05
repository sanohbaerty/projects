local Players = game.Players

local ReplicatedStorage = game.ReplicatedStorage
local Modules = ReplicatedStorage.Modules
local Shared = Modules.Shared
local GameConfig = require(Shared.GameConfig)
local Signals = require(Shared.Signals)
local PlayerSignals = require(Shared.PlayerSignals)
local StatusEffectHandler = {}

-- Each effect is a table with up to four fields

-- Stack : "Ignore" | "Refresh" | "Stack"
-- Ignore = second application / effect does nothing if one is already active
-- Refresh = cancels current instance (if running) and restarts fresh
-- Stack = each application is a separate independent instance so 2x burn, 2x poison, etc
--
-- onApply(character, effect, StateMachine)
-- Runs once immediately when the effect starts
-- State should be set here like zero walkspeed, set attribute, etc
--
-- onTick(character, effect, StateMachine) [optional]
-- If defined, runs every effect.TickRate seconds for effect.Duration.
-- Deal damage here, for anything repeating.
--
-- onRemove(character, effect, StateMachine)
-- Function that runs once when the effect ends, either naturally or cancelled.
-- You can undo whatever onApply did. Restore walkspeed, clear attributes, etc.
--
-- subEffects : {effectName, ...} [optional]
-- Other effects to automatically apply alongside this one.
-- Those sub-effects are tracked separately and cancelled separately.

local Registry = {}
local characterStateConnections = {}

local function recalculateWalkSpeed(character: Model)
	local humanoid = character:FindFirstChildOfClass("Humanoid"):: Humanoid
	if not humanoid then return end
	
	local data = Registry[character]
	if not data then return end
	
	local base = character:GetAttribute("DefaultWalkSpeed") or 16
	
	local StateMachine = data.StateMachine
	if StateMachine and StateMachine:IsState("Stunned") then
		humanoid.WalkSpeed = 0
		return
	end
	
	local slowMulti = 1
	for i, v in data.modifiers.slows do
		slowMulti *= (1 - v)
	end

	local boostMulti = 1
	for i, v in data.modifiers.boosts do
		boostMulti *= (1 + v)
	end
	
	slowMulti = math.max(0, slowMulti)
	humanoid.WalkSpeed = base * slowMulti * boostMulti
end

StatusEffectHandler.Definitions = {
	Stun = {
		Stack = "Refresh",
		
		onApply = function(character, effect, StateMachine)
			local humanoid = character:FindFirstChildOfClass("Humanoid"):: Humanoid
			if not humanoid then return end
			
			humanoid.WalkSpeed = 0
			humanoid.JumpPower = 0
		end,
		
		onRemove = function(character, effect, StateMachine)
			local humanoid = character:FindFirstChildOfClass("Humanoid"):: Humanoid
			if not humanoid then return end
			
			recalculateWalkSpeed(character)
			humanoid.JumpPower = character:GetAttribute("DefaultJumpPower") or 50
			
			if not StateMachine or not StateMachine:IsState("Stunned") then return end
			
			StateMachine:Transition("Idle")
		end,
	},
	
	Slow = {
		Stack = "Stack",

		onApply = function(character, effect, StateMachine)
			local hum = character:FindFirstChildOfClass("Humanoid")
			if not hum then return end
			
			local mods = Registry[character].modifiers
			mods.slows[effect.Id] = effect.Value or 0.3

			recalculateWalkSpeed(character)
		end,

		onRemove = function(character, effect, StateMachine)
			local hum = character:FindFirstChildOfClass("Humanoid")
			if not hum then return end
			
			local mods = Registry[character].modifiers
			mods.slows[effect.Id] = nil

			recalculateWalkSpeed(character)
		end,
	},

	SpeedBoost = {
		Stack = "Stack",

		onApply = function(character, effect, StateMachine)
			local hum = character:FindFirstChildOfClass("Humanoid")
			if not hum then return end
			
			local mods = Registry[character].modifiers
			mods.boosts[effect.Id] = effect.Value or 0.25

			recalculateWalkSpeed(character)
		end,

		onRemove = function(character, effect, StateMachine)
			local hum = character:FindFirstChildOfClass("Humanoid")
			if not hum then return end
			
			local mods = Registry[character].modifiers
			mods.boosts[effect.Id] = nil

			recalculateWalkSpeed(character)
		end,
	},

	Burn = {
		-- you can burn 2x, 3x, inf x
		Stack = "Stack",

		onApply = function(character, effect, StateMachine)
			local Stacks = (character:GetAttribute("BurnStacks") or 0) + 1
			character:SetAttribute("BurnStacks", Stacks)
		end,

		onTick = function(character, effect, StateMachine)
			local hum = character:FindFirstChildOfClass("Humanoid")
			if hum and hum.Health > 0 then
				hum:TakeDamage(effect.DamagePerTick or 2)
			end
		end,

		onRemove = function(character, effect, StateMachine)
			local Stacks = character:GetAttribute("BurnStacks") or 1
			character:SetAttribute("BurnStacks", math.max(0, Stacks - 1))
		end,
	},

	Poison = {
		Stack = "Ignore",

		onTick = function(character, effect, StateMachine)
			local hum = character:FindFirstChildOfClass("Humanoid")
			if hum and hum.Health > 0 then
				hum:TakeDamage(effect.DamagePerTick or 3)
			end
		end,
	},

	Shield = {
		Stack = "Refresh",

		onApply = function(character, effect, StateMachine)
			character:SetAttribute("ShieldAbsorb", effect.Value or 20)
		end,

		onRemove = function(character, effect, StateMachine)
			character:SetAttribute("ShieldAbsorb", nil)
		end,
	},

	Invulnerable = {
		Stack = "Refresh",

		onApply = function(character, effect, StateMachine)
			if StateMachine then 
				StateMachine.Invincible = true 
			end
		end,

		onRemove = function(character, effect, StateMachine)
			if StateMachine then 
				StateMachine.Invincible = false 
			end
		end,
	},

	-- EXAMPLES: 
	-- GuardBreak applies Stun AND Slow without duplicating functions
	-- Each sub-effect is tracked separately, cancels separately, expires separately
	GuardBreak = {
		Stack = "Refresh",
		subEffects = {"Stun", "Slow"},
		-- No onApply/onTick/onRemove needed bc the sub-effects handle everything
	},
}

local function runEffect(character: Model, effectName: string, definition, effect, StateMachine, key)
	if definition.subEffects then
		for i, subEffectname in definition.subEffects do
			StatusEffectHandler.apply(subEffectname, character, StateMachine)
		end
	end
	
	if definition.onApply then
		definition.onApply(character, effect, StateMachine)
	end
	
	if definition.onTick then
		local tickRate = effect.TickRate or 0.5
		local elapsed = 0
		
		while elapsed < effect.Duration do
			task.wait(tickRate)
			elapsed += tickRate

			local slot = Registry[character] and Registry[character].effects[key]
			if not slot or slot.cancelled then break end

			definition.onTick(character, effect, StateMachine)
		end
	else
		task.wait(effect.Duration)
	end
	
	local slot = Registry[character] and Registry[character].effects[key]
	local cancelled = slot and slot.cancelled
	
	if not cancelled and definition.onRemove then
		definition.onRemove(character, effect, StateMachine)
	end
	
	if not Registry[character] then return end
	Registry[character].effects[key] = nil
end

function StatusEffectHandler.apply(effectName: string, character: Model, StateMachine, overrides: {[string]: any}?)
	Registry[character] = Registry[character] or {
		effects = {},
		modifiers = {
			slows = {},
			boosts = {}
		},
		StateMachine = StateMachine
	}
	
	if not characterStateConnections[character] then
		characterStateConnections[character] = StateMachine.StateChanged:Connect(function()
			recalculateWalkSpeed(character)
		end)
	end
	
	local baseDefinition = StatusEffectHandler.Definitions[effectName]
	assert(baseDefinition, "[StatusEffectHandler] Effect '" .. effectName .. "' not found in Definitions.")
	
	local baseConfig = nil

	if not baseDefinition.subEffects or baseDefinition.onApply or baseDefinition.onTick then
		baseConfig = GameConfig.StatusEffects[effectName]
		assert(baseConfig, "[StatusEffectHandler] Effect '" .. effectName .. "' not found in GameConfig.")
	end

	local effect = baseConfig and table.clone(baseConfig) or {}
	
	local effect = table.clone(baseConfig)
	if overrides then
		for i, v in overrides do
			effect[i] = v
		end
	end
	
	local StackMode = baseDefinition.Stack or "Refresh"
	
	if StackMode == "Ignore" then
		for effectKey, slot in Registry[character].effects do
			if effectKey:match("^" .. effectName .. "_") then return end 
		end
	elseif StackMode == "Refresh" then
		StatusEffectHandler.remove(effectName, character)
	end

	local id = tostring(os.clock())
	local key = effectName .. "_" .. id
	effect.Id = id

	Registry[character].effects[key] = {
		cancelled = false,
		effect = effect,
		definition = baseDefinition
	}
	
	task.spawn(runEffect, character, effectName, baseDefinition, effect, StateMachine, key)
end

function StatusEffectHandler.remove(effectName: string, character: Model)
	if not Registry[character] then return end

	local definition = StatusEffectHandler.Definitions[effectName]
	local toRemove = {}

	for effectKey in Registry[character].effects do
		if effectKey:match("^" .. effectName .. "_") then
			table.insert(toRemove, effectKey)
		end
	end

	for i, effectKey in toRemove do
		local slot = Registry[character].effects[effectKey]
		if not slot then continue end

		slot.cancelled = true

		if definition and definition.onRemove then
			definition.onRemove(character, slot.effect, Registry[character].StateMachine)
		end

		Registry[character].effects[effectKey] = nil
	end
end

function StatusEffectHandler.removeAll(character: Model)
	if not Registry[character] then return end

	local StateMachine = Registry[character].StateMachine

	for effectKey, slot in Registry[character].effects do
		slot.cancelled = true
		local effectName = effectKey:match("^(.+)_%d+%.?%d*$")
		if not effectName then continue end

		local definition = StatusEffectHandler.Definitions[effectName]
		if definition and definition.onRemove and slot.effect then
			definition.onRemove(character, slot.effect, StateMachine)
		end
	end

	Registry[character].effects = {}
	Registry[character] = nil
end

function StatusEffectHandler.isActive(effectName: string, character: Model): boolean
	if not Registry[character] then return false end
	for effectKey, v in Registry[character].effects do
		if effectKey:match("^" .. effectName .. "_") then return true end
	end
	return false
end

Players.PlayerAdded:Connect(function(player: Player)
	player.CharacterRemoving:Connect(function(character)
		if characterStateConnections[character] then
			characterStateConnections[character] = nil
		end
	end)
end)

return StatusEffectHandler
