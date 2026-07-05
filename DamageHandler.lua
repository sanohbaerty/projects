-- Connected Discord-GitHub

-- this module is for handling damage on the server
-- it checks blocking, shield, stun, launch, vfx, hit reactions, all that

local damageHandler = {}

-- getting the services we need
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

-- getting shared modules
local Modules = ReplicatedStorage.Modules
local Shared = Modules.Shared
local GameConfig = require(Shared.GameConfig)
local StateRegistry = require(Shared.StateRegistry)
local CombatSignals = require(Shared.CombatSignals)
local AnimationController = require(Shared.AnimationController)

-- getting server modules
local ServerScriptService = game.ServerScriptService
local Server = ServerScriptService.Server
local StatusEffectHandler = require(Server.StatusEffectHandler)

-- remotes for telling the client to play stuff
local Remotes = ReplicatedStorage.Remotes

-- attribute names so i dont keep typing strings everywhere
local ATTR_SHIELDABSORB = "ShieldAbsorb"
local ATTR_SHIELDBAR = "ShieldBar"

-- an entity is basically just a character and its humanoid
type entity = {character: Model, humanoid: Humanoid}


local function applyAbsorb(entity: entity, damage: number)
	-- gets the person being hit
	local victim = entity.character
	if not victim then return end
	
	-- gets their humanoid
	local victimHumanoid = entity.humanoid
	if not victimHumanoid then return end
	
	-- checks if they have shield absorb
	local absorb = victim:GetAttribute(ATTR_SHIELDABSORB)
	if not absorb then return end
	
	-- subtracts the damage from the absorb amount
	local remaining = absorb - damage

	if remaining <= 0 then
		-- shield absorb ran out so remove it
		victim:SetAttribute("ShieldAbsorb", nil)

		-- returns the leftover damage
		return math.abs(remaining)
	else
		-- shield absorbed all the damage
		victim:SetAttribute("ShieldAbsorb", remaining)

		-- no damage goes through
		return 0
	end
end


local function playGuardBreak(entity: entity, duration: number)
	-- this plays when someones block breaks

	local victim = entity.character
	if not victim then return end
	
	local victimHumanoid = entity.humanoid
	if not victimHumanoid then return end
	
	-- update their movement so the guardbroken state can slow them or stop them
	StateRegistry:UpdateMovement(victim)

	-- stops them from jumping while guard broken
	victimHumanoid.JumpPower = 0
	
	-- checks if this victim is a real player
	local victimPlayer = game.Players:GetPlayerFromCharacter(victim)

	if victimPlayer then
		-- if its a player then tell their client their block broke
		Remotes.BlockBroken:FireClient(victimPlayer, duration)
	else
		-- if its an npc then play the animation on the server
		AnimationController:StopAll(nil, victim)
		AnimationController:Play("BlockBroken", nil, nil, victim)
	end
	
	task.delay(duration, function()
		-- after the duration is done, give movement and jump back
		StateRegistry:UpdateMovement(victim)
		victimHumanoid.JumpPower = victim:GetAttribute("DefaultJumpPower") or 50
		
		-- player handles their own animation
		if victimPlayer then return end

		-- stop npc block broken animation
		AnimationController:Stop("BlockBroken", nil, victim)
	end)
end


local function playHitReaction(entity: entity, move: string)
	-- this makes the victim play a hit reaction

	local victim = entity.character
	if not victim then return end
	
	local victimHumanoid = entity.humanoid
	if not victimHumanoid then return end
	
	local victimPlayer = game.Players:GetPlayerFromCharacter(victim)

	if victimPlayer then
		-- players get told through a remote
		Remotes.HitReaction:FireClient(victimPlayer, move)
	else
		-- npcs play animation from the server
		local customName = move .. "Hit"

		-- tries to use a custom hit animation for that move
		if AnimationController:HasTrack(customName .. "1", victim) then
			AnimationController:Play(customName, nil, nil, victim)
		else
			-- if theres no custom one then use the normal hit reaction
			AnimationController:Play("HitReaction", nil, nil, victim)
		end
	end
end


local function applyShieldBlock(entity: entity, victimState, damage: number)
	-- this is for shield type blocking

	local victim = entity.character
	if not victim then return end

	local victimHumanoid = entity.humanoid
	if not victimHumanoid then return end

	-- gets current shield bar
	local shield = victim:GetAttribute(ATTR_SHIELDBAR) or GameConfig.ShieldBar

	-- subtracts the hit damage from shield
	local newShield = shield - damage

	if newShield <= 0 then
		-- shield broke
		victim:SetAttribute(ATTR_SHIELDBAR, 0)

		-- puts victim into guard broken state
		victimState:Transition("GuardBroken", {
			onEnter = {Duration = GameConfig.GuardBrokenDuration}
		})
		
		-- plays guard break stuff
		playGuardBreak(entity, GameConfig.GuardBrokenDuration)
		
		-- shows guard break vfx to everyone
		Remotes.VFX:FireAllClients(entity, "GuardBreak", nil, nil, true)
		
		-- damage goes through because shield broke
		return damage
	else
		-- shield still has health left
		victim:SetAttribute(ATTR_SHIELDBAR, newShield)

		-- no health damage
		return 0
	end
end


local function resolveBlockedDamage(entity: entity, victimState, damage: number): number
	-- decides what happens when someone blocks

	local victim = entity.character
	if not victim then return end
	
	if GameConfig.BlockType == "Shield" then
		-- shield blocking uses shield hp
		return applyShieldBlock(entity, victimState, damage)

	elseif GameConfig.BlockType == "Partial" then
		-- partial block only lets some damage through
		return damage * (GameConfig.PartialBlockPercent / 100)
	end
	
	-- if no special block type then just use the damage
	return damage
end


local function lerpNumber(a, b, t)
	-- smooths a number between a and b
	return a + (b - a) * t
end


local function applyLaunch(victimEntity: entity, attackerEntity: entity, moveData: GameConfig.Move)
	-- handles moves that launch someone in the air

	local launch = moveData.Launch
	if not launch then return false end

	local victimRoot = victimEntity.character:FindFirstChild("HumanoidRootPart")
	local attackerRoot = attackerEntity.character:FindFirstChild("HumanoidRootPart")

	local didLaunch = false
	
	if launch.Target and victimRoot then
		-- launches the victim

		local currentVelocity = victimRoot.AssemblyLinearVelocity
		local launchVelocity = launch.Target

		victimRoot.AssemblyLinearVelocity = Vector3.new(
			lerpNumber(currentVelocity.X, launchVelocity.X, 0.75),
			math.max(currentVelocity.Y, launchVelocity.Y * 0.45),
			lerpNumber(currentVelocity.Z, launchVelocity.Z, 0.75)
		)

		task.delay(0.08, function()
			if not victimRoot or not victimRoot.Parent then return end

			-- gives a little extra upwards push after a tiny delay
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
		-- launches the attacker too if the move has self launch

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

			-- same second boost thing but for attacker
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
	-- decides how fast the attacker should move into place during air combos

	local frontCfg = GameConfig.AirborneFrontAlign

	local minTime = frontCfg.MinAirTime
	local maxTime = frontCfg.MaxAirTime
	local minSpeed = frontCfg.MinLerpSpeed
	local maxSpeed = frontCfg.MaxLerpSpeed

	local t = 0
	if maxTime > minTime then
		t = math.clamp((duration - minTime) / (maxTime - minTime), 0, 1)
	end

	-- shorter airtime means faster align
	return lerpNumber(maxSpeed, minSpeed, t)
end


local function getFrontAlignCFrame(victimRoot: BasePart)
	-- gets the position in front of the victim

	local frontCfg = GameConfig.AirborneFrontAlign

	local victimPos = victimRoot.Position
	local forward = victimRoot.CFrame.LookVector

	local targetPos = victimPos + forward * frontCfg.Distance + Vector3.new(0, frontCfg.HeightOffset, 0)
	local lookAtPos = victimPos + Vector3.new(0, frontCfg.HeightOffset, 0)

	return CFrame.new(targetPos, lookAtPos)
end


local function keepAirborne(character: Model, duration: number, airborneOptions: AirborneOptions?)
	-- keeps a character in the air for a bit

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")

	if not humanoid or not root then return end

	-- stops roblox freefall from taking over
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Freefall, false)

	-- if theyre already airborne just extend the time
	if character:GetAttribute("Airborne") then
		character:SetAttribute("AirborneUntil", os.clock() + duration)
		return
	end

	-- marks them as airborne
	character:SetAttribute("AirborneUntil", os.clock() + duration)
	character:SetAttribute("Airborne", true)

	-- server controls the root while airborne
	root:SetNetworkOwner(nil)

	-- attachment for linear velocity
	local att = Instance.new("Attachment")
	att.Name = "AirborneAttachment"
	att.Parent = root

	-- linear velocity holds them in the air
	local lv = Instance.new("LinearVelocity")
	lv.Name = "AirborneHold"
	lv.Attachment0 = att
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.MaxForce = 0
	lv.VectorVelocity = Vector3.new(0, 4, 0)
	lv.Parent = root

	local frontAlignConn

	-- this keeps attacker in front of victim during air combos
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

			-- moves the character to the front align spot
			local targetCFrame = getFrontAlignCFrame(followRoot)
			local alpha = math.clamp(alignSpeed * dt, 0, 1)
			root.CFrame = root.CFrame:Lerp(targetCFrame, alpha)
		end)
	end

	-- waits until the launch slows down a little
	local start = os.clock()
	while os.clock() - start < 0.6 do
		if not root.Parent then break end
		if root.AssemblyLinearVelocity.Y <= 8 then break end
		task.wait()
	end

	-- slowly turns on the force so it doesnt snap weird
	local holdStart = os.clock()
	local rampTime = 0.18
	local maxForce = root.AssemblyMass * workspace.Gravity * 1.8

	while os.clock() - holdStart < rampTime do
		local alpha = (os.clock() - holdStart) / rampTime
		lv.MaxForce = maxForce * alpha
		lv.VectorVelocity = Vector3.new(0, 2 * (1 - alpha), 0)
		task.wait()
	end

	-- either slowly falls or just stays still depending on config
	if GameConfig.FallDownSlowly then
		lv.MaxForce = maxForce
		lv.VectorVelocity = Vector3.new(0, -GameConfig.FallDownRate, 0)
	else
		lv.MaxForce = maxForce
		lv.VectorVelocity = Vector3.zero
	end

	task.spawn(function()
		-- waits until airborne time is over
		while root.Parent do
			local airborneUntil = character:GetAttribute("AirborneUntil")
			if not airborneUntil or os.clock() >= airborneUntil then
				break
			end
			task.wait(0.05)
		end

		-- stops front align
		if frontAlignConn then
			frontAlignConn:Disconnect()
			frontAlignConn = nil
		end

		local exitCfg = GameConfig.AirborneEndBehavior

		if exitCfg.ExitDelay then
			task.wait(exitCfg.ExitDelay)
		end

		-- freezes then drops if config says that
		if exitCfg.Mode == "FreezeThenDrop" then
			local startFreeze = os.clock()

			while os.clock() - startFreeze < exitCfg.FreezeTime do
				if not root.Parent then break end
				root.AssemblyLinearVelocity = Vector3.zero
				task.wait()
			end

		-- smoothly drops them if config says that
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

		-- clean up the force objects
		if lv then lv:Destroy() end
		if att then att:Destroy() end

		-- gives roblox freefall back
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Freefall, true)

		-- remove airborne attributes
		character:SetAttribute("Airborne", nil)
		character:SetAttribute("AirborneUntil", nil)

		-- gives network ownership back to the player
		local player = game.Players:GetPlayerFromCharacter(character)
		if player and root and root.Parent then
			root:SetNetworkOwner(player)
		end
	end)
end


local function handleAirborne(victimEntity: entity, attackerEntity: entity, moveData: GameConfig.Move)
	-- handles all launch and airborne stuff for a move

	local didLaunch = applyLaunch(victimEntity, attackerEntity, moveData)

	if didLaunch and moveData.TargetAirborneDuration then
		-- keeps victim in air
		task.spawn(function()
			keepAirborne(victimEntity.character, moveData.TargetAirborneDuration)
		end)
	end

	if moveData.SelfAirborneDuration then
		-- keeps attacker in air and makes them stay in front of victim
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
	-- main damage function
	-- this runs when a hit actually lands

	local victim = entity.character
	if not victim then return end
	
	local Humanoid = entity.humanoid
	if not Humanoid then return end
	
	-- attacker has to have humanoid and be alive
	if not attackingEntity.humanoid then return end
	if attackingEntity.humanoid.Health <= 0 then return end

	-- make sure humanoid actually belongs to the victim
	if not victim:IsAncestorOf(Humanoid) then return end

	-- get victim state
	local victimState = StateRegistry:Get(victim) :: StateRegistry.State
	if not victimState then return end

	-- dont damage dead or invincible people
	if victimState:IsState("Dead") then return end
	if victimState.Invincible then return end

	-- get move data and damage for this combo hit
	local moveData = GameConfig.Moves[move] :: GameConfig.Move
	local damage = moveData.Damage[combo]
		
	-- check if shield absorb blocks any damage first
	local absorbDamage = applyAbsorb(entity, damage)
	damage = absorbDamage and (absorbDamage == 0 and 0 or absorbDamage) or damage
	
	local moveLaunchData = moveData.Launch

	if victimState:IsState("Blocking") then
		-- victim is blocking so handle block damage instead
		damage = resolveBlockedDamage(entity, victimState, damage)

		-- tells other scripts damage was blocked
		CombatSignals.DamageBlocked:Fire(victim, move, damage)
		
		-- block clash vfx for victim and attacker
		local shouldOverride = true
		local purelyOverride = true

		Remotes.VFX:FireAllClients(entity, "BlockClash", move, combo, shouldOverride)
		Remotes.VFX:FireAllClients(attackingEntity, "BlockClash", move, combo, shouldOverride, purelyOverride)
		
		-- subtract whatever damage got through
		Humanoid.Health -= damage

		-- tells other scripts damage got dealt
		CombatSignals.DamageDealt:Fire(victim, nil, move, combo, damage)
		
		if moveLaunchData and moveLaunchData.OnBlock then
			-- some moves can still launch even if blocked
			local didLaunch = handleAirborne(entity, attackingEntity, moveData)
			
			-- stun the victim after block launch
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
	
	-- if they are not blocking then stun them normally
	victimState:Transition("Stunned", {
		onEnter = {
			Overrides = {
				Duration = moveData.StunTime[combo] or GameConfig.StatusEffects["Stun"].Duration
			} :: GameConfig.StatusEffect
		}
	})
	
	-- launch and airborne stuff
	local didLaunch = handleAirborne(entity, attackingEntity, moveData)
	
	-- actually deal the damage
	Humanoid.Health -= damage

	-- tells other scripts damage happened
	CombatSignals.DamageDealt:Fire(victim, nil, move, combo, damage)
	
	-- decides if it should use normal hit spark or finisher hit spark
	local effectName = combo == #moveData.Damage and "HitSparkFinisher" or "HitSpark"
	local VFXData = GameConfig.VFX[effectName] :: GameConfig.VFX
	
	-- plays vfx if this effect is meant to happen on hit
	if VFXData.Trigger == "OnHit" then
		Remotes.VFX:FireAllClients(entity, effectName, move, combo)
	end
	
	-- play hit animation
	playHitReaction(entity, move)

	return damage
end

return damageHandler
