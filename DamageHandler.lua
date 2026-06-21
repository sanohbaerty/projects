local damageHandler = {}
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Modules = ReplicatedStorage.Modules
local Shared = Modules.Shared
local GameConfig = require(Shared.GameConfig)
local StateRegistry = require(Shared.StateRegistry)
local CombatSignals = require(Shared.CombatSignals)
local AnimationController = require(Shared.AnimationController)

local ServerScriptService = game.ServerScriptService
local Server = ServerScriptService.Server
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
	
	StateRegistry:UpdateMovement(victim)
	victimHumanoid.JumpPower = 0
	
	local victimPlayer = game.Players:GetPlayerFromCharacter(victim)
	if victimPlayer then
		Remotes.BlockBroken:FireClient(victimPlayer, duration)
	else
		AnimationController:StopAll(nil, victim)
		AnimationController:Play("BlockBroken", nil, nil, victim)
	end
	
	task.delay(duration, function()
		StateRegistry:UpdateMovement(victim)
		victimHumanoid.JumpPower = victim:GetAttribute("DefaultJumpPower") or 50
		
		if victimPlayer then return end
		AnimationController:Stop("BlockBroken", nil, victim)
	end)
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
		victim:SetAttribute(ATTR_SHIELDBAR, 0)

		victimState:Transition("GuardBroken", {
			onEnter = {Duration = GameConfig.GuardBrokenDuration}
		})
		
		playGuardBreak(entity, GameConfig.GuardBrokenDuration)
		
		Remotes.VFX:FireAllClients(entity, "GuardBreak", nil, nil, true)
		
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

local function lerpNumber(a, b, t)
	return a + (b - a) * t
end

local function applyLaunch(victimEntity: entity, attackerEntity: entity, moveData: GameConfig.Move)
	local launch = moveData.Launch
	if not launch then return false end

	local victimRoot = victimEntity.character:FindFirstChild("HumanoidRootPart")
	local attackerRoot = attackerEntity.character:FindFirstChild("HumanoidRootPart")

	local didLaunch = false
	
	if launch.Target and victimRoot then
		local currentVelocity = victimRoot.AssemblyLinearVelocity
		local launchVelocity = launch.Target

		victimRoot.AssemblyLinearVelocity = Vector3.new(
			lerpNumber(currentVelocity.X, launchVelocity.X, 0.75),
			math.max(currentVelocity.Y, launchVelocity.Y * 0.45),
			lerpNumber(currentVelocity.Z, launchVelocity.Z, 0.75)
		)

		task.delay(0.08, function()
			if not victimRoot or not victimRoot.Parent then return end

			local current = victimRoot.AssemblyLinearVelocity
			victimRoot.AssemblyLinearVelocity = Vector3.new(
				current.X,
				math.max(current.Y, launchVelocity.Y * 0.75),
				current.Z
			)
		end)
		
		didLaunch = true
	end
	
	if launch.Self and attackerRoot then
		attackerRoot:SetNetworkOwner(nil)

		local currentVelocity = attackerRoot.AssemblyLinearVelocity
		local launchVelocity = launch.Self

		attackerRoot.AssemblyLinearVelocity = Vector3.new(
			lerpNumber(currentVelocity.X, launchVelocity.X, 0.75),
			math.max(currentVelocity.Y, launchVelocity.Y * 0.45),
			lerpNumber(currentVelocity.Z, launchVelocity.Z, 0.75)
		)

		task.delay(0.08, function()
			if not attackerRoot or not attackerRoot.Parent then return end

			local current = attackerRoot.AssemblyLinearVelocity
			attackerRoot.AssemblyLinearVelocity = Vector3.new(
				current.X,
				math.max(current.Y, launchVelocity.Y * 0.75),
				current.Z
			)
		end)
	end

	return didLaunch
end
type AirborneOptions = {
	FollowCharacter: Model?,
	FrontAlign: boolean?,
}

local function getAirborneFrontAlignSpeed(duration: number)
	local frontCfg = GameConfig.AirborneFrontAlign

	local minTime = frontCfg.MinAirTime
	local maxTime = frontCfg.MaxAirTime
	local minSpeed = frontCfg.MinLerpSpeed
	local maxSpeed = frontCfg.MaxLerpSpeed

	local t = 0
	if maxTime > minTime then
		t = math.clamp((duration - minTime) / (maxTime - minTime), 0, 1)
	end

	-- short airtime -> closer to maxSpeed
	return lerpNumber(maxSpeed, minSpeed, t)
end

local function getFrontAlignCFrame(victimRoot: BasePart)
	local frontCfg = GameConfig.AirborneFrontAlign

	local victimPos = victimRoot.Position
	local forward = victimRoot.CFrame.LookVector

	local targetPos = victimPos + forward * frontCfg.Distance + Vector3.new(0, frontCfg.HeightOffset, 0)
	local lookAtPos = victimPos + Vector3.new(0, frontCfg.HeightOffset, 0)

	return CFrame.new(targetPos, lookAtPos)
end

local function keepAirborne(character: Model, duration: number, airborneOptions: AirborneOptions?)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")

	if not humanoid or not root then return end

	humanoid:SetStateEnabled(Enum.HumanoidStateType.Freefall, false)

	if character:GetAttribute("Airborne") then
		character:SetAttribute("AirborneUntil", os.clock() + duration)
		return
	end

	character:SetAttribute("AirborneUntil", os.clock() + duration)
	character:SetAttribute("Airborne", true)
	root:SetNetworkOwner(nil)

	local att = Instance.new("Attachment")
	att.Name = "AirborneAttachment"
	att.Parent = root

	local lv = Instance.new("LinearVelocity")
	lv.Name = "AirborneHold"
	lv.Attachment0 = att
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.MaxForce = 0
	lv.VectorVelocity = Vector3.new(0, 4, 0)
	lv.Parent = root

	local frontAlignConn
	if GameConfig.AirborneFrontAlign and GameConfig.AirborneFrontAlign.Enabled and airborneOptions and airborneOptions.FrontAlign and airborneOptions.FollowCharacter then
		local alignSpeed = getAirborneFrontAlignSpeed(duration)

		frontAlignConn = RunService.Heartbeat:Connect(function(dt)
			if not root.Parent then
				if frontAlignConn then
					frontAlignConn:Disconnect()
					frontAlignConn = nil
				end
				return
			end

			local airborneUntil = character:GetAttribute("AirborneUntil")
			if not airborneUntil or os.clock() >= airborneUntil then
				if frontAlignConn then
					frontAlignConn:Disconnect()
					frontAlignConn = nil
				end
				return
			end

			local followRoot = airborneOptions.FollowCharacter:FindFirstChild("HumanoidRootPart")
			if not followRoot or not followRoot:IsA("BasePart") then
				return
			end

			local targetCFrame = getFrontAlignCFrame(followRoot)
			local alpha = math.clamp(alignSpeed * dt, 0, 1)
			root.CFrame = root.CFrame:Lerp(targetCFrame, alpha)
		end)
	end

	local start = os.clock()
	while os.clock() - start < 0.6 do
		if not root.Parent then break end
		if root.AssemblyLinearVelocity.Y <= 8 then break end
		task.wait()
	end

	local holdStart = os.clock()
	local rampTime = 0.18
	local maxForce = root.AssemblyMass * workspace.Gravity * 1.8

	while os.clock() - holdStart < rampTime do
		local alpha = (os.clock() - holdStart) / rampTime
		lv.MaxForce = maxForce * alpha
		lv.VectorVelocity = Vector3.new(0, 2 * (1 - alpha), 0)
		task.wait()
	end

	if GameConfig.FallDownSlowly then
		lv.MaxForce = maxForce
		lv.VectorVelocity = Vector3.new(0, -GameConfig.FallDownRate, 0)
	else
		lv.MaxForce = maxForce
		lv.VectorVelocity = Vector3.zero
	end

	task.spawn(function()
		while root.Parent do
			local airborneUntil = character:GetAttribute("AirborneUntil")
			if not airborneUntil or os.clock() >= airborneUntil then
				break
			end
			task.wait(0.05)
		end

		if frontAlignConn then
			frontAlignConn:Disconnect()
			frontAlignConn = nil
		end

		local exitCfg = GameConfig.AirborneEndBehavior

		if exitCfg.ExitDelay then
			task.wait(exitCfg.ExitDelay)
		end

		if exitCfg.Mode == "FreezeThenDrop" then
			local startFreeze = os.clock()

			while os.clock() - startFreeze < exitCfg.FreezeTime do
				if not root.Parent then break end
				root.AssemblyLinearVelocity = Vector3.zero
				task.wait()
			end

		elseif exitCfg.Mode == "SmoothDrop" then
			local startDrop = os.clock()
			local dropTime = exitCfg.DropTime

			while os.clock() - startDrop < dropTime do
				if not root.Parent then break end

				local alpha = (os.clock() - startDrop) / dropTime
				lv.VectorVelocity = Vector3.new(0, exitCfg.DropVelocity * alpha, 0)
				lv.MaxForce = root.AssemblyMass * workspace.Gravity * 2

				task.wait()
			end
		end

		if lv then lv:Destroy() end
		if att then att:Destroy() end

		humanoid:SetStateEnabled(Enum.HumanoidStateType.Freefall, true)

		character:SetAttribute("Airborne", nil)
		character:SetAttribute("AirborneUntil", nil)

		local player = game.Players:GetPlayerFromCharacter(character)
		if player and root and root.Parent then
			root:SetNetworkOwner(player)
		end
	end)
end

local function handleAirborne(victimEntity: entity, attackerEntity: entity, moveData: GameConfig.Move)
	local didLaunch = applyLaunch(victimEntity, attackerEntity, moveData)

	if didLaunch and moveData.TargetAirborneDuration then
		task.spawn(function()
			keepAirborne(victimEntity.character, moveData.TargetAirborneDuration)
		end)
	end

	if moveData.SelfAirborneDuration then
		task.spawn(function()
			keepAirborne(attackerEntity.character, moveData.SelfAirborneDuration, {
				FollowCharacter = victimEntity.character,
				FrontAlign = true,
			})
		end)
	end

	return didLaunch
end

function damageHandler.Damage(entity: entity, move: string, combo: number, attackingEntity: entity)
	local victim = entity.character
	if not victim then return end
	
	local Humanoid = entity.humanoid
	if not Humanoid then return end
	
	if not attackingEntity.humanoid then return end
	if attackingEntity.humanoid.Health <= 0 then return end

	if not victim:IsAncestorOf(Humanoid) then return end

	local victimState = StateRegistry:Get(victim) :: StateRegistry.State
	if not victimState then return end
	if victimState:IsState("Dead") then return end
	if victimState.Invincible then return end

	local moveData = GameConfig.Moves[move] :: GameConfig.Move
	local damage = moveData.Damage[combo]
		
	local absorbDamage = applyAbsorb(entity, damage)
	damage = absorbDamage and (absorbDamage == 0 and 0 or absorbDamage) or damage
	
	local moveLaunchData = moveData.Launch

	if victimState:IsState("Blocking") then
		damage = resolveBlockedDamage(entity, victimState, damage)
		CombatSignals.DamageBlocked:Fire(victim, move, damage)
		
		local shouldOverride = true -- for understanding / organization
		local purelyOverride = true -- for understanding / organization (purelyOverride is for like JUST overriding previous effects, not for PLAYING any effects)
		Remotes.VFX:FireAllClients(entity, "BlockClash", move, combo, shouldOverride)
		Remotes.VFX:FireAllClients(attackingEntity, "BlockClash", move, combo, shouldOverride, purelyOverride)
		
		Humanoid.Health -= damage
		CombatSignals.DamageDealt:Fire(victim, nil, move, combo, damage)
		
		if moveLaunchData and moveLaunchData.OnBlock then
			local didLaunch = handleAirborne(entity, attackingEntity, moveData)
			
			victimState:Transition("Stunned", {
				onEnter = {
					Overrides = {
						Duration = (moveData.StunTime[combo] or GameConfig.StatusEffects["Stun"].Duration) + moveData.TargetAirborneDuration
					} :: GameConfig.StatusEffect
				}
			})
			
			playHitReaction(entity, move)
		end
		
		return damage
	end
	
	victimState:Transition("Stunned", {
		onEnter = {
			Overrides = {
				Duration = moveData.StunTime[combo] or GameConfig.StatusEffects["Stun"].Duration
			} :: GameConfig.StatusEffect
		}
	})
	
	local didLaunch = handleAirborne(entity, attackingEntity, moveData)
	
	Humanoid.Health -= damage
	CombatSignals.DamageDealt:Fire(victim, nil, move, combo, damage)
	
	local effectName = combo == #moveData.Damage and "HitSparkFinisher" or "HitSpark"
	local VFXData = GameConfig.VFX[effectName]:: GameConfig.VFX
	
	if VFXData.Trigger == "OnHit" then
		Remotes.VFX:FireAllClients(entity, effectName, move, combo)
	end
	
	playHitReaction(entity, move)

	return damage
end

return damageHandler
