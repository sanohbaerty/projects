-- MADE BY SANOH (.sanoh on Discord / S4N0H roblox)

local StateMachine = {}
StateMachine.__index = StateMachine

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Modules.Shared
local Signals = require(Shared.Signals)
local GameConfig = require(Shared.GameConfig)
local StatusEffectHandler = require(game.ServerScriptService.Server.StatusEffectHandler)

StateMachine.States = {
	IDLE = "Idle",
	ATTACKING = "Attacking",
	CASTING = "Casting",
	DODGING = "Dodging",
	BLOCKING = "Blocking",
	STUNNED = "Stunned",
	GUARDBROKEN = "GuardBroken",
	SPRINTING = "Sprinting",
	DEAD = "Dead",
}

local S = StateMachine.States
local Transitions = {
	[S.IDLE] = {S.ATTACKING, S.SPRINTING, S.CASTING, S.DODGING, S.BLOCKING, S.STUNNED, S.DEAD},
	[S.SPRINTING] = {S.IDLE, S.DODGING, S.ATTACKING, S.DEAD},
	[S.ATTACKING] = {S.IDLE, S.SPRINTING, S.CASTING, S.DODGING, S.BLOCKING, S.STUNNED, S.DEAD},
	[S.CASTING] = {S.IDLE, S.DODGING, S.BLOCKING, S.STUNNED, S.DEAD},
	[S.DODGING] = {S.IDLE, S.SPRINTING, S.DEAD},
	[S.BLOCKING] = {S.IDLE, S.SPRINTING, S.ATTACKING, S.CASTING, S.DODGING, S.GUARDBROKEN, S.STUNNED, S.DEAD},
	[S.GUARDBROKEN] = {S.IDLE, S.DEAD, S.GUARDBROKEN},
	[S.STUNNED] = {S.IDLE, S.DEAD, S.STUNNED},
	[S.DEAD] = {},
}

local StateHandlers = {
	[S.IDLE] = require(script.Idle),
	[S.SPRINTING] = require(script.Sprinting),
	[S.ATTACKING] = require(script.Attacking),
	[S.CASTING] = require(script.Casting),
	[S.DODGING] = require(script.Dodging),
	[S.BLOCKING] = require(script.Blocking),
	[S.GUARDBROKEN] = require(script.GuardBroken),
	[S.STUNNED] = require(script.Stunned),
	[S.DEAD] = require(script.Dead),
}

function StateMachine.new(character: Model)
	local self = setmetatable({}, StateMachine)
	self.Character = character
	self.CurrentState = S.IDLE
	self.StateChanged = Signals.new()
	self.InvulnerabilitySources = {}
	self.Invincible = false
	self.StateRevision = 0
	return self
end

function StateMachine:CanTransition(toState)
	if typeof(toState) ~= "string" or not StateHandlers[toState] then return false end

	local allowed = Transitions[self.CurrentState]
	if not allowed then return false end
	return table.find(allowed, toState) ~= nil
end

function StateMachine:Transition(toState: string, args)
	if not self:CanTransition(toState) then return false end

	local previousState = self.CurrentState
	local exitHandler = StateHandlers[previousState]
	local enterHandler = StateHandlers[toState]

	if exitHandler and exitHandler.onExit then
		exitHandler.onExit(self, toState, args and args.onExit)
	end

	self.CurrentState = toState
	self.StateRevision += 1

	if enterHandler and enterHandler.onEnter then
		enterHandler.onEnter(self, previousState, args and args.onEnter)
	end

	self:UpdateMovement()
	self.StateChanged:Fire(toState, previousState)
	return true
end

function StateMachine:SetInvincible(source: string, enabled: boolean)
	if enabled then
		self.InvulnerabilitySources[source] = true
	else
		self.InvulnerabilitySources[source] = nil
	end
	self.Invincible = next(self.InvulnerabilitySources) ~= nil
end

function StateMachine:IsInvincible()
	return self.Invincible == true
end

function StateMachine:UpdateMovement()
	local humanoid = self.Character:FindFirstChildWhichIsA("Humanoid")
	if not humanoid then return end

	local speed = self.Character:GetAttribute("DefaultWalkSpeed") or 16
	if self:IsState("Stunned") or self:IsState("GuardBroken") then
		humanoid.WalkSpeed = 0
		return
	end

	if self:IsState("Blocking") then
		speed *= GameConfig.BlockSpeedModifier
	end
	if self:IsState("Sprinting") then
		speed *= GameConfig.SprintSpeedMultiplier
	end

	local data = StatusEffectHandler.Registry[self.Character]
	if data then
		local slowMultiplier = 1
		for effectId, value in data.modifiers.slows do
			slowMultiplier *= 1 - value
		end

		local boostMultiplier = 1
		for effectId, value in data.modifiers.boosts do
			boostMultiplier *= 1 + value
		end

		speed *= math.max(0, slowMultiplier)
		speed *= boostMultiplier
	end

	humanoid.WalkSpeed = speed
end

function StateMachine:GetState()
	return self.CurrentState
end

function StateMachine:IsState(state)
	return self.CurrentState == state
end

function StateMachine:Reset()
	local previousState = self.CurrentState
	self.CurrentState = S.IDLE
	self.StateRevision += 1
	table.clear(self.InvulnerabilitySources)
	self.Invincible = false
	self.StateChanged:Fire(S.IDLE, previousState)
	self:UpdateMovement()
end

function StateMachine:Cleanup()
	self.StateChanged:DisconnectAll()
	table.clear(self.InvulnerabilitySources)
	self.StateChanged = nil
	self.Character = nil
	self.CurrentState = nil
	self.InvulnerabilitySources = nil
	self.Invincible = nil
	self.StateRevision = nil
end

return StateMachine
