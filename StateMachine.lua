-- fairly new to state machines so may have some errors/inconsistencies

local StateMachine = {}
StateMachine.__index = StateMachine

local ReplicatedStorage = game.ReplicatedStorage
local Modules = ReplicatedStorage.Modules
local Shared = Modules.Shared
local Signals = require(Shared.Signals)

StateMachine.States = {
	IDLE = "Idle",
	ATTACKING = "Attacking",
	CASTING = "Casting",
	DODGING = "Dodging",
	BLOCKING = "Blocking",
	STUNNED = "Stunned",
	GUARDBROKEN = "GuardBroken",
	DEAD = "Dead"
}

local S = StateMachine.States
local Transitions = {
	[S.IDLE] = {S.ATTACKING, S.CASTING, S.DODGING, S.BLOCKING, S.STUNNED, S.DEAD},
	[S.ATTACKING] = {S.IDLE, S.CASTING, S.DODGING, S.BLOCKING, S.STUNNED, S.DEAD},
	[S.CASTING] = {S.IDLE, S.DODGING, S.BLOCKING, S.STUNNED, S.DEAD},
	[S.DODGING] = {S.IDLE, S.DEAD},
	[S.BLOCKING] = {S.IDLE, S.ATTACKING, S.CASTING, S.DODGING, S.GUARDBROKEN, S.DEAD},
	[S.GUARDBROKEN] = {S.IDLE, S.DEAD},
	[S.STUNNED] = {S.IDLE, S.DEAD},
	[S.DEAD] = {}
}

local StateHandlers = {
	[S.IDLE] = require(script.Idle),
	[S.ATTACKING] = require(script.Attacking),
	[S.CASTING] = require(script.Casting),
	[S.DODGING] = require(script.Dodging),
	[S.BLOCKING] = require(script.Blocking),
	[S.GUARDBROKEN] = require(script.GuardBroken),
	[S.STUNNED] = require(script.Stunned),
	[S.DEAD] = require(script.Dead)
}

function StateMachine.new(Character: Model)
	local self = setmetatable({}, StateMachine)
	
	self.Character = Character
	self.CurrentState = StateMachine.States.IDLE
	self.StateChanged = Signals.new()
	self.Invincible = false
	
	return self
end

function StateMachine:CanTransition(toState)
	local allowed = Transitions[self.CurrentState]
	if not allowed then return false end
	
	return table.find(allowed, toState)
end

function StateMachine:Transition(toState: string, args: {onEnter: {}, onExit: {}})
	if not self:CanTransition(toState) then
		warn(string.format(
			"[StateMachine] Blocked: %s tried to move from %s to %s",
			self.Character.Name,
			self.CurrentState,
			toState
			))
		return false
	end
	
	local prevState = self.CurrentState
	local exitHandler = StateHandlers[prevState]
	local enterHandler = StateHandlers[toState]
	
	if exitHandler and exitHandler.onExit then
		exitHandler.onExit(self, toState, args and args.onExit)
	end
	
	self.CurrentState = toState
	self.StateChanged:Fire(toState, prevState)
	
	if enterHandler and enterHandler.onEnter then
		enterHandler.onEnter(self, prevState, args and args.onEnter)
	end
	
	return true
end

function StateMachine:GetState()
	return self.CurrentState
end

function StateMachine:IsState(state)
	return self.CurrentState == state
end

function StateMachine:Reset()
	self.Invincible = false
	self:Transition(S.IDLE)
	self.CurrentState = S.IDLE
end

function StateMachine:Cleanup()
	self.StateChanged:DisconnectAll()
	self.StateChanged = nil
	self.Character = nil
	self.CurrentState = nil
	self.Invincible = nil
end

return StateMachine
