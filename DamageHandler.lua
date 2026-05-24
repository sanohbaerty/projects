local damageHandler = {}
local ReplicatedStorage = game.ReplicatedStorage
local Modules = ReplicatedStorage.Modules
local Shared = Modules.Shared
local GameConfig = require(Shared.GameConfig)
local StateRegistry = require(Shared.StateRegistry)
local CombatSignals = require(Shared.CombatSignals)
local AnimationController = require(Shared.AnimationController)

local Server = Modules.Server
local StatusEffectHandler = require(Server.StatusEffectHandler)

local Remotes = ReplicatedStorage.Remotes

local ATTR_SHIELDABSORB = "ShieldAbsorb"
local ATTR_SHIELDBAR = "ShieldBar"

type entity = {character: Model, humanoid: Humanoid}

local function applyAbsorb(entity: entity, damage: number)
	local victim = entity.character
	if not victim then return end
	
	local victimHumanoid = entity.humanoid
	if not victimHumanoid then return end
	
	local absorb = victim:GetAttribute(ATTR_SHIELDABSORB)
	if not absorb then return end
	
	local remaining = absorb - damage
	if remaining <= 0 then
		-- not enough absorb to cover the damage
		victim:SetAttribute("ShieldAbsorb", nil)
		return math.abs(remaining)
	else
		-- absorbed all the damage
		victim:SetAttribute("ShieldAbsorb", remaining)
		return 0
	end
end

local function playGuardBreak(entity: entity, duration: number)
	local victim = entity.character
	if not victim then return end
	
	local victimHumanoid = entity.humanoid
	if not victimHumanoid then return end
	
	local victimPlayer = game.Players:GetPlayerFromCharacter(victim)
	if victimPlayer then
		Remotes.BlockBroken:FireClient(victimPlayer, duration)
	else
		AnimationController:StopAll(nil, victim)
		AnimationController:Play("BlockBroken", nil, nil, victim)
		task.delay(duration, function()
			AnimationController:Stop("BlockBroken", nil, victim)
		end)
	end
end

local function playHitReaction(entity: entity, move: string)
	local victim = entity.character
	if not victim then return end
	
	local victimHumanoid = entity.humanoid
	if not victimHumanoid then return end
	
	local victimPlayer = game.Players:GetPlayerFromCharacter(victim)
	if victimPlayer then
		Remotes.HitReaction:FireClient(victimPlayer, move)
	else
		local customName = move .. "Hit"
		if AnimationController:HasTrack(customName .. "1", victim) then
			AnimationController:Play(customName, nil, nil, victim)
		else
			AnimationController:Play("HitReaction", nil, nil, victim)
		end
	end
end


local function applyShieldBlock(entity: entity, victimState, damage: number)
	local victim = entity.character
	if not victim then return end

	local victimHumanoid = entity.humanoid
	if not victimHumanoid then return end

	local shield = victim:GetAttribute(ATTR_SHIELDBAR) or GameConfig.ShieldBar
	local newShield = shield - damage

	if newShield <= 0 then
		victim:SetAttribute(ATTR_SHIELDBAR, GameConfig.ShieldBar) 
		victimState:Transition("GuardBroken", {
			onEnter = {GuardBrokenDuration = GameConfig.GuardBrokenDuration}
		})
		playGuardBreak(entity, GameConfig.GuardBrokenDuration)
		return damage
	else
		victim:SetAttribute(ATTR_SHIELDBAR, newShield)
		return 0
	end
end

local function resolveBlockedDamage(entity: entity, victimState, damage: number): number
	local victim = entity.character
	if not victim then return end
	
	if GameConfig.BlockType == "Shield" then
		return applyShieldBlock(entity, victimState, damage)
	elseif GameConfig.BlockType == "Partial" then
		return damage * (GameConfig.PartialBlockPercent / 100)
	end
	
	return damage
end

function damageHandler.Damage(entity: entity, move: string, combo: number)
	local victim = entity.character
	if not victim then return end
	
	local Humanoid = entity.humanoid
	if not Humanoid then return end
	
	if not victim:IsAncestorOf(Humanoid) then return end

	local victimState = StateRegistry:Get(victim) :: StateRegistry.State
	if not victimState then return end
	if victimState:IsState("Dead") then return end
	if victimState.Invincible then return end
	
	local moveData = GameConfig.Moves[move] :: GameConfig.Move
	local damage = moveData.Damage[combo]
	
	local absorbDamage = applyAbsorb(entity, damage)
	damage = absorbDamage and (absorbDamage == 0 and 0 or absorbDamage) or damage

	if victimState:IsState("Blocking") then
		damage = resolveBlockedDamage(entity, victimState, damage)
		CombatSignals.DamageBlocked:Fire(victim, move, damage)
		
		Humanoid.Health -= damage
		CombatSignals.DamageDealt:Fire(victim, nil, move, combo, damage)
		return damage
	end
	
	victimState:Transition("Stunned", {
		onEnter = {
			Overrides = {
				Duration = moveData.StunTime[combo] or GameConfig.StatusEffects["Stun"].Duration
			} :: GameConfig.StatusEffect
		}
	})
	
	Humanoid.Health -= damage
	CombatSignals.DamageDealt:Fire(victim, nil, move, combo, damage)
	
	playHitReaction(entity, move)

	return damage
end

return damageHandler
