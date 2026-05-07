-- TITLE NAME IS COMBOTRACKER MEANT TO BE StatusEffectsHandler SORRY I SUBMIT THE WRONG NAME BUT HERES THE STATUSEFFECTHANDLER CODE:
-- THIS IS NOT A COMBOTRACKER BUT A STATUSEFFECTHANDLER SORRY FOR THE CONFUSION

-- Discord: .sanoh | Roblox: S4N0H

--[[
	StatusEffectHandler

	Built around a main registry that contains characters and shows their effects and speed modifiers. Each effect is defined in one place.
	You can easily add new effects without touching the main logic
	Just need to add an entry into Definitions and Gameconfig, and you are doone!
	(a lil coding knowledge needed cuz u need to add an onRemove and onApply)
--]]

--[[

	HOW TO GIVE YOURSELF AN EFFECT (ADMIN COMMANDS) TO TEST IT OUT WHEN YOU JOIN THE GAME

	-- put username, not "me" or "others" or "all"

	-- /effect <name> <effectname> to give effects
	-- example: /effect john Burn

	-- /remove <name> <effectname> -- to remove an effect
	-- example: /remove john Burn

	-- /removeall <name>
	-- example: /removeall john

	EFFECT LIST:

	Stun        = {Duration = 5 },
	Slow        = {Duration = 5, Value = 0.5},
	SpeedBoost  = {Duration = 5, Value = 0.5},
	Burn        = {Duration = 5, TickRate = 0.5, DamagePerTick = 2},
	Poison      = {Duration = 5, TickRate = 1, DamagePerTick = 3},
	Shield      = {Duration = 5, Value = 50 },
	Invulnerable= {Duration = 5 },
	GuardBreak = {},

	-- IMPORTANT!!!!!
	-- effect name is case sensitive. you may NOT do "stun" but must do "Stun" instead.
]]

local Players = game:GetService("Players")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Modules = ReplicatedStorage.Modules
local Shared = Modules.Shared
local GameConfig = require(Shared.GameConfig)
local Signals = require(Shared.Signals)
local PlayerSignals = require(Shared.PlayerSignals)

local StatusEffectHandler = {}

--[[
	Registry stores all active effects
	Key is character model, each entry has:
	- effects: a map of "NameOfEffect_timestamp" and it will give {cancelled, effect, definition}
	- modifiers: slow or boost tables used by recalculateWalkSpeed
	- statemachine - reference to external statemachine module so combat state can be read like Stunned, Invincible
--]]
local Registry = {}

-- Tracks StateChanged signal connections per character so we can disconnect on removal
-- Without this, old connections would pile up across respawns and cause memory leaks
local characterStateConnections = {}

--[[
	recalculateWalkSpeed:

	Gets the characters final walkspeed each time its called
	This avoids bugs slows or boosts could conflict

	Formula of speed is baseSpeed (16 usually) * total slow factors (50% + 25% could be 75% which is 1.75 in numbers) * total speed factors (same calculation as slow)
	each boost as a decimal increase (e.g. 0.25 = 25% faster) so multiplying them together means effects compound naturally rather than stacking linearly

	If the StateMachine is in a Stunned state, we hard-lock WalkSpeed to 0 and
	skip the formula entirely since stun always wins over other modifiers.
--]]

local function recalculateWalkSpeed(character: Model)
	local humanoid = character:FindFirstChildOfClass("Humanoid") :: Humanoid
	if not humanoid then return end

	local data = Registry[character]
	if not data then return end

	local base = character:GetAttribute("DefaultWalkSpeed") or 16

	-- Stun takes priority over all speed modifiers
	local StateMachine = data.StateMachine
	if StateMachine and StateMachine:IsState("Stunned") then
		humanoid.WalkSpeed = 0
		return
	end

	-- Compound all active slows into one multiplier (e.g. two 30% slows = 0.7 * 0.7 = 49% speed)
	local slowMulti = 1
	for _, v in data.modifiers.slows do
		slowMulti *= (1 - v)
	end

	-- Compound all active boosts (e.g. two 25% boosts = 1.25 * 1.25 = 56.25% extra)
	local boostMulti = 1
	for _, v in data.modifiers.boosts do
		boostMulti *= (1 + v)
	end

	-- Clamp slowMulti so we can't go negative from extreme slows
	slowMulti = math.max(0, slowMulti)
	humanoid.WalkSpeed = base * slowMulti * boostMulti
end

--[[
	Effect Definitions

	Each entry describes one status effect. The system only requires `Stack`, but
	you can also define any of these lifecycle hooks:

	  Stack: "Ignore" | "Refresh" | "Stack"
	    Controls what happens when the same effect is applied twice.
	    Ignore  = second application does nothing if one is already running.
	    Refresh = cancels the current instance and starts fresh (e.g. re-stunning).
	    Stack   = each application is its own independent instance (e.g. multi-burn).

	  onApply(character, effect, StateMachine)
	    Runs once when the effect first starts. Good for setting attributes or
	    zeroing out the humanoid state.

	  onTick(character, effect, StateMachine)  [optional]
	    If present, fires every effect.TickRate seconds for the effect's Duration.
	    Used for repeating damage (burn, poison) or HoT ticks.

	  onRemove(character, effect, StateMachine)
	    Runs once when the effect ends (naturally or cancelled). Should undo
	    whatever onApply set up.

	  subEffects: { effectName, ... }  [optional]
	    Applies additional effects automatically. Each sub-effect is tracked and
	    cancelled independently, so GuardBreak's Slow can expire separately from
	    GuardBreak's Stun.
--]]

StatusEffectHandler.Definitions = {

	Stun = {
		Stack = "Refresh", -- re-stunning resets the duration and removes old effect making a new one instead of stacking

		onApply = function(character, effect, StateMachine)
			local humanoid = character:FindFirstChildOfClass("Humanoid") :: Humanoid
			if not humanoid then return end

			-- zero out jump and walk so they are truly stunned
			humanoid.WalkSpeed = 0
			humanoid.JumpPower = 0
		end,

		onRemove = function(character, effect, StateMachine)
			local humanoid = character:FindFirstChildOfClass("Humanoid") :: Humanoid
			if not humanoid then return end

			-- calculate walkspeed instead of making it 16 incase other effects are speeding up or slowing the player
			recalculateWalkSpeed(character)
			humanoid.JumpPower = character:GetAttribute("DefaultJumpPower") or 50

			-- only transition out of Stunned if the StateMachine is actually in that state
			-- checking first prevents double-transitioning or overwriting a different active state
			if not StateMachine or not StateMachine:IsState("Stunned") then return end
			StateMachine:Transition("Idle")
		end,
	},

	Slow = {
		Stack = "Stack", -- multiple slows add up (e.g. ice + web both apply and they use a generalized "Slow" effect)

		onApply = function(character, effect, StateMachine)
			local hum = character:FindFirstChildOfClass("Humanoid")
			if not hum then return end

			-- store the slow under its unique effect Id so we can remove exactly this instance without affecting other active slows
			local mods = Registry[character].modifiers
			mods.slows[effect.Id] = effect.Value or 0.3
			recalculateWalkSpeed(character)
		end,

		onRemove = function(character, effect, StateMachine)
			local hum = character:FindFirstChildOfClass("Humanoid")
			if not hum then return end

			-- make only this effect nil
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
		Stack = "Stack", -- getting hit twice will be 2x the effect

		onApply = function(character, effect, StateMachine)
			-- track a visible stack count so UI/VFX can show burn
			local stacks = (character:GetAttribute("BurnStacks") or 0) + 1
			character:SetAttribute("BurnStacks", stacks)
		end,

		onTick = function(character, effect, StateMachine)
			local hum = character:FindFirstChildOfClass("Humanoid")
			-- make sure humanoid exists
			if hum and hum.Health > 0 then
				hum.Health -= effect.DamagePerTick or 2
			end
		end,

		onRemove = function(character, effect, StateMachine)
			-- remove only this burn effect
			local stacks = character:GetAttribute("BurnStacks") or 1
			character:SetAttribute("BurnStacks", math.max(0, stacks - 1))
		end,
	},

	Poison = {
		Stack = "Ignore", -- only 1 poison instance, reapplying will not go through

		onTick = function(character, effect, StateMachine)
			local hum = character:FindFirstChildOfClass("Humanoid")
			if hum and hum.Health > 0 then
				hum.Health -= effect.DamagePerTick or 3
			end
		end,
		-- no onApply/onRemove needed bc poison only does damage, no persistent state changes
	},

	Shield = {
		Stack = "Refresh", -- Reapplying resets the absorption value to full

		onApply = function(character, effect, StateMachine)
			-- Other systems (damage handlers) read ShieldAbsorb to intercept incoming damage
			character:SetAttribute("ShieldAbsorb", effect.Value or 20)
		end,

		onRemove = function(character, effect, StateMachine)
			character:SetAttribute("ShieldAbsorb", nil)
		end,
	},

	Invulnerable = {
		Stack = "Refresh",

		onApply = function(character, effect, StateMachine)
			-- the StateMachine gives an invincible value that damage scripts check before applying any health reduction
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

	--[[
		GuardBreak is a composite effect it leaves it up to the sub effects to do the work
		like a combination of sub effects, this avoids duplicating Stun/Slow logic. here, each sub-effect is applied
		independently, meaning they can have different durations and expire separately.
		we don't need onApply/onTick/onRemove because the sub-effects own all the state and the onApply/onTick/onRemove are in the sub-effects
	--]]
	GuardBreak = {
		Stack = "Refresh",
		subEffects = {"Stun", "Slow"},
	},
}

--[[
	runEffect
	
	the core function that runs the effect, it's spawned via task.spawn
	so it runs concurrently without blocking the main thread blah blah blah you know how it goes

	Flow
	  1. apply any subEffects (e.g. GuardBreak triggers Stun + Slow)
	  2. call onApply if defined
	  3. if onTick is defined, loop every TickRate seconds until Duration elapses
	     or the slot is cancelled (e.g. with remove/removeAll)
	  4. if onTick is NOT defined, just wait the full Duration
	  5. call onRemove only if the effect wasn't externally cancelled
	     (if cancelled, remove() already called onRemove directly)
--]]
local function runEffect(character: Model, effectName: string, definition, effect, StateMachine, key)
	if definition.subEffects then
		for _, subEffectName in definition.subEffects do
			StatusEffectHandler.apply(subEffectName, character, StateMachine)
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

			-- re-check the slot each tick bc the effect may have been cancelled mid-loop
			local slot = Registry[character] and Registry[character].effects[key]
			if not slot or slot.cancelled then break end

			definition.onTick(character, effect, StateMachine)
		end
	else
		-- effects without a tick loop still respect Duration before cleanup
		task.wait(effect.Duration)
	end

	-- only call onRemove naturally if the effect wasn't already cancelled by remove()
	-- if cancelled = true, remove() already handled cleanup to avoid double-calling onRemove
	local slot = Registry[character] and Registry[character].effects[key]
	local cancelled = slot and slot.cancelled

	if not cancelled and definition.onRemove then
		definition.onRemove(character, effect, StateMachine)
	end

	if not Registry[character] then return end
	Registry[character].effects[key] = nil
end

--[[
	StatusEffectHandler.apply
	
	entry point for applying any effect to a character
	
	It:
	  1. initialises the Registry entry for this character if it doesn't exist yet
	  2. connects a StateChanged listener so speed recalculates when combat state changes
	     (e.g. entering/leaving Stunned)
	  3. resolves the definition and GameConfig data, merging in any per-call overrides
	  4. handles the stacking mode before spawning the effect coroutine
--]]
function StatusEffectHandler.apply(effectName: string, character: Model, StateMachine, overrides: {[string]: any}?)
	-- lazily initialise this character's data block the first time an effect is applied
	Registry[character] = Registry[character] or {
		effects = {},
		modifiers = { slows = {}, boosts = {} },
		StateMachine = StateMachine
	}

	-- listen for StateMachine state changes so stun/unstun properly updates speed
	if not characterStateConnections[character] then
		characterStateConnections[character] = StateMachine.StateChanged:Connect(function()
			recalculateWalkSpeed(character)
		end)
	end

	local baseDefinition = StatusEffectHandler.Definitions[effectName]
	assert(baseDefinition, "[StatusEffectHandler] Effect '" .. effectName .. "' not found in Definitions.")

	-- pure composite effects (subEffects only, no tick/apply logic) don't need a GameConfig entry
	local baseConfig = nil
	if not baseDefinition.subEffects or baseDefinition.onApply or baseDefinition.onTick then
		baseConfig = GameConfig.StatusEffects[effectName]
		assert(baseConfig, "[StatusEffectHandler] Effect '" .. effectName .. "' not found in GameConfig.")
	end

	-- clone config so overrides don't mutate the shared GameConfig table
	local effect = baseConfig and table.clone(baseConfig) or {}
	if overrides then
		for k, v in overrides do
			effect[k] = v
		end
	end

	local stackMode = baseDefinition.Stack or "Refresh"

	if stackMode == "Ignore" then
		-- if any instance of this effect is already running, bail out immediately
		for effectKey in Registry[character].effects do
			if effectKey:match("^" .. effectName .. "_") then return end
		end
	elseif stackMode == "Refresh" then
		-- cancel and clean up any existing instance before starting fresh
		StatusEffectHandler.remove(effectName, character)
	end
	-- stack mode: fall through and add a new independent instance

	-- use os.clock() for the unique key, sub-millisecond precision prevents collisions
	-- even when two effects of the same type are applied in the same frame
	local id = tostring(os.clock())
	local key = effectName .. "_" .. id
	effect.Id = id

	Registry[character].effects[key] = {
		cancelled = false,
		effect = effect,
		definition = baseDefinition
	}

	-- spawn so the tick loop doesn't block the calling code
	task.spawn(runEffect, character, effectName, baseDefinition, effect, StateMachine, key)
end

--[[
	StatusEffectHandler.remove
	
	Cancels all active instances of a named effect on a character.
	Sets cancelled = true on each slot (so the running coroutine exits its tick loop),
	calls onRemove immediately, then clears the slot from the Registry.
	
	This is also used internally by Refresh stacking to reset an effect cleanly.
--]]
function StatusEffectHandler.remove(effectName: string, character: Model)
	if not Registry[character] then return end

	local definition = StatusEffectHandler.Definitions[effectName]
	local toRemove = {}

	-- Collect matching keys first to avoid modifying the table while iterating
	for effectKey in Registry[character].effects do
		if effectKey:match("^" .. effectName .. "_") then
			table.insert(toRemove, effectKey)
		end
	end

	for _, effectKey in toRemove do
		local slot = Registry[character].effects[effectKey]
		if not slot then continue end

		slot.cancelled = true -- Signals the coroutine's tick loop to stop

		if definition and definition.onRemove then
			definition.onRemove(character, slot.effect, Registry[character].StateMachine)
		end

		Registry[character].effects[effectKey] = nil
	end
end

--[[
	StatusEffectHandler.removeAll
	
	Strips every active effect from a character, this is used on death or respawn.
	Iterates all slots, cancels each, calls onRemove, then wipes the Registry entry
	entirely so there's no leftover state.
--]]
function StatusEffectHandler.removeAll(character: Model)
	if not Registry[character] then return end

	local StateMachine = Registry[character].StateMachine

	for effectKey, slot in Registry[character].effects do
		slot.cancelled = true

		-- Extract the effect name from the key pattern "EffectName_timestamp"
		local effectName = effectKey:match("^(.+)_%d+%.?%d*$")
		if not effectName then continue end

		local definition = StatusEffectHandler.Definitions[effectName]
		if definition and definition.onRemove and slot.effect then
			definition.onRemove(character, slot.effect, StateMachine)
		end
	end

	Registry[character].effects = {}
	Registry[character] = nil -- Full cleanup so the character has no lingering Registry data
end

--[[
	StatusEffectHandler.isActive
	
	Returns true if at least one instance of the named effect is currently running.
	Useful for conditional logic (e.g. "don't apply Poison if already poisoned" in
	ability scripts that don't go through the Ignore stack mode themselves).
--]]
function StatusEffectHandler.isActive(effectName: string, character: Model): boolean
	if not Registry[character] then return false end
	for effectKey in Registry[character].effects do
		if effectKey:match("^" .. effectName .. "_") then return true end
	end
	return false
end

-- Clean up the StateChanged connection when a character is removed (e.g. on death/respawn).
-- Without this the connection would reference a stale character and leak memory.
Players.PlayerAdded:Connect(function(player: Player)
	player.CharacterRemoving:Connect(function(character)
		if not characterStateConnections[character] then return end
		characterStateConnections[character]:Disconnect()
		characterStateConnections[character] = nil
	end)
end)

return StatusEffectHandler
