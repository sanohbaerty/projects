-- Connected Discord-GitHub | Discord: .sanoh | Roblox: S4N0H

-- damageHandler is the server side part that decides what a confirmed hit actually does.
-- the hitbox and validator should already decide if the hit is real before this runs.
-- this module only handles the result of that hit, like damage, block logic, shield hp, stun, launch, airborne holding, and vfx signals.
-- i keep it server sided because clients should not be trusted to decide health, guard break, or physics that affects another player.

local damageHandler = {}

-- services used by the damage resolver
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

-- shared modules used by both server and client systems
local Modules = ReplicatedStorage.Modules
local Shared = Modules.Shared
local GameConfig = require(Shared.GameConfig)
local StateRegistry = require(Shared.StateRegistry)
local CombatSignals = require(Shared.CombatSignals)
local AnimationController = require(Shared.AnimationController)

-- no server-only module is required here right now.
-- damageHandler should stay focused on resolving a confirmed hit, not doing extra setup.

-- remotes only tell clients to show animations and vfx. damage itself stays on the server
local Remotes = ReplicatedStorage.Remotes

-- attribute keys are stored once so spelling mistakes do not silently break shields
local ATTR_SHIELDABSORB = "ShieldAbsorb"
local ATTR_SHIELDBAR = "ShieldBar"

-- the damage system passes characters around as entities so every helper gets the same shape of data
type entity = {character: Model, humanoid: Humanoid}


-- shield absorb is handled before normal block logic.
-- reason is simple: absorb acts like a temporary extra health layer from a status effect,
-- while block is an active state from the StateMachine. keeping them separate makes it easier
-- to add new defensive effects later without rewriting the main Damage function.
local function applyAbsorb(entity: entity, damage: number)
	-- gets the person being hit
	local victim = entity.character
	if not victim then return end
	
	-- gets their humanoid
	local victimHumanoid = entity.humanoid
	if not victimHumanoid then return end
	
	-- absorb is stored on the character so any status effect can add it without changing this module
	local absorb = victim:GetAttribute(ATTR_SHIELDABSORB)
	if not absorb then return end
	
	-- subtracts the damage from the absorb amount
	local remaining = absorb - damage

	if remaining <= 0 then
		-- shield absorb ran out so remove it
		victim:SetAttribute("ShieldAbsorb", nil)

		-- shield absorb broke, so only the leftover amount should hit health
		return math.abs(remaining)
	else
		-- shield absorbed all the damage
		victim:SetAttribute("ShieldAbsorb", remaining)

		-- absorb still has points left, so the actual health damage becomes 0
		return 0
	end
end


-- guard break is more than just a state change.
-- when a shield runs out, the StateMachine handles the actual GuardBroken state,
-- but this helper handles the side effects that have to happen around it:
-- movement refresh, no jumping, client feedback for players, and server animation for npcs.
local function playGuardBreak(entity: entity, duration: number)
	-- this plays when someones block breaks

	local victim = entity.character
	if not victim then return end
	
	local victimHumanoid = entity.humanoid
	if not victimHumanoid then return end
	
	-- refresh movement because GuardBroken may change walk speed or stop movement completely
	StateRegistry:UpdateMovement(victim)

	-- stop jump so a guard broken player cannot hop out of the punish window
	victimHumanoid.JumpPower = 0
	
	-- players and npcs need different feedback paths
	local victimPlayer = game.Players:GetPlayerFromCharacter(victim)

	if victimPlayer then
		-- player animations and ui should be handled on their own client
		Remotes.BlockBroken:FireClient(victimPlayer, duration)
	else
		-- npcs do not have a player client, so the server plays their animation
		AnimationController:StopAll(nil, victim)
		AnimationController:Play("BlockBroken", nil, nil, victim)
	end
	
	task.delay(duration, function()
		-- after guard break ends, restore movement using the current state rules
		StateRegistry:UpdateMovement(victim)
		victimHumanoid.JumpPower = victim:GetAttribute("DefaultJumpPower") or 50
		
		-- players already got told through the remote, so do not stop a server track that does not exist
		if victimPlayer then return end

		-- stop npc block broken animation
		AnimationController:Stop("BlockBroken", nil, victim)
	end)
end


-- hit reactions are split between players and npcs.
-- players get a remote because their client owns their animation controller,
-- but npcs can safely play the animation from the server.
-- this keeps player combat responsive without letting the client control real damage.
local function playHitReaction(entity: entity, move: string)
	-- this makes the victim show a hit reaction without letting the client decide damage

	local victim = entity.character
	if not victim then return end
	
	local victimHumanoid = entity.humanoid
	if not victimHumanoid then return end
	
	local victimPlayer = game.Players:GetPlayerFromCharacter(victim)

	if victimPlayer then
		-- players get the animation request locally so it feels smoother
		Remotes.HitReaction:FireClient(victimPlayer, move)
	else
		-- npcs run from the server side animation controller
		local customName = move .. "Hit"

		-- custom hit reactions let certain moves feel different without changing the damage code
		if AnimationController:HasTrack(customName .. "1", victim) then
			AnimationController:Play(customName, nil, nil, victim)
		else
			-- fallback so a missing custom animation does not break the combat flow
			AnimationController:Play("HitReaction", nil, nil, victim)
		end
	end
end


-- shield block uses a shield bar instead of reducing health right away.
-- if the bar still has hp, the hit is fully blocked.
-- if the bar breaks, the victim is forced into GuardBroken and the damage goes through.
-- this is why this helper returns a number instead of directly deciding everything in Damage.
local function applyShieldBlock(entity: entity, victimState, damage: number)
	-- shield type blocking drains the shield bar before touching health

	local victim = entity.character
	if not victim then return end

	local victimHumanoid = entity.humanoid
	if not victimHumanoid then return end

	-- use the saved shield value, or reset to config value if the attribute is not there yet
	local shield = victim:GetAttribute(ATTR_SHIELDBAR) or GameConfig.ShieldBar

	-- shield loses the same amount that the hit would have dealt
	local newShield = shield - damage

	if newShield <= 0 then
		-- shield hit zero, so the victim gets punished with GuardBroken
		victim:SetAttribute(ATTR_SHIELDBAR, 0)

		-- StateMachine owns the real combat state, not this helper
		victimState:Transition("GuardBroken", {
			onEnter = {Duration = GameConfig.GuardBrokenDuration}
		})
		
		-- visual and movement side effects are handled outside the state transition
		playGuardBreak(entity, GameConfig.GuardBrokenDuration)
		
		-- everyone sees the break because it matters for combat readability
		Remotes.VFX:FireAllClients(entity, "GuardBreak", nil, nil, true)
		
		-- this version lets the hit damage through when the shield breaks
		return damage
	else
		-- shield survived, so save the new shield hp
		victim:SetAttribute(ATTR_SHIELDBAR, newShield)

		-- block fully ate the hit
		return 0
	end
end


-- this is the one place that decides how blocking changes damage.
-- the main Damage function should not care if the game is using Shield block or Partial block.
-- GameConfig decides the block type, then this function returns the final damage that should hit health.
local function resolveBlockedDamage(entity: entity, victimState, damage: number): number
	-- returns the health damage after block rules are applied

	local victim = entity.character
	if not victim then return end
	
	if GameConfig.BlockType == "Shield" then
		-- Shield mode uses the shield bar system
		return applyShieldBlock(entity, victimState, damage)

	elseif GameConfig.BlockType == "Partial" then
		-- Partial mode reduces damage by a percent instead of using shield hp
		return damage * (GameConfig.PartialBlockPercent / 100)
	end
	
	-- fallback keeps the function safe if config is changed wrong
	return damage
end


-- tiny helper for smoothing numbers.
-- i use this during launch so velocity changes do not snap instantly from one value to another.
local function lerpNumber(a, b, t)
	-- smooths a number between a and b
	return a + (b - a) * t
end


-- launch only runs for moves that have Launch data in GameConfig.
-- this lets a normal punch, heavy hit, uppercut, or air combo all use the same damage code
-- while the config decides which moves actually push players into the air.
local function applyLaunch(victimEntity: entity, attackerEntity: entity, moveData: GameConfig.Move)
	-- reads moveData.Launch and applies physics to the victim and maybe the attacker

	local launch = moveData.Launch
	if not launch then return false end

	local victimRoot = victimEntity.character:FindFirstChild("HumanoidRootPart")
	local attackerRoot = attackerEntity.character:FindFirstChild("HumanoidRootPart")

	local didLaunch = false
	
	if launch.Target and victimRoot then
		-- victim launch is the knockup or knockback part of the move

		local currentVelocity = victimRoot.AssemblyLinearVelocity
		local launchVelocity = launch.Target

		victimRoot.AssemblyLinearVelocity = Vector3.new(
			lerpNumber(currentVelocity.X, launchVelocity.X, 0.75),
			math.max(currentVelocity.Y, launchVelocity.Y * 0.45),
			lerpNumber(currentVelocity.Z, launchVelocity.Z, 0.75)
		)

		task.delay(0.08, function()
			if not victimRoot or not victimRoot.Parent then return end

			-- second push helps the launch feel consistent after Roblox physics updates
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
		-- self launch is used for air combo starters where the attacker follows the victim

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

			-- same delayed boost so attacker launch matches victim launch timing
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


-- front align speed changes based on how long the air combo lasts.
-- short air time needs the attacker to move into place faster,
-- longer air time can move slower so it looks less jerky.
local function getAirborneFrontAlignSpeed(duration: number)
	-- turns air duration into a lerp speed for front align

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


-- this builds the CFrame where the attacker should float during an air combo.
-- it uses the victim root look vector so the attacker stays in front of the victim,
-- not just at some random world position.
local function getFrontAlignCFrame(victimRoot: BasePart)
	-- builds a position in front of the victim and makes the attacker face back toward them

	local frontCfg = GameConfig.AirborneFrontAlign

	local victimPos = victimRoot.Position
	local forward = victimRoot.CFrame.LookVector

	local targetPos = victimPos + forward * frontCfg.Distance + Vector3.new(0, frontCfg.HeightOffset, 0)
	local lookAtPos = victimPos + Vector3.new(0, frontCfg.HeightOffset, 0)

	return CFrame.new(targetPos, lookAtPos)
end


-- keeps a character suspended after a launch.
-- this is the part that stops air combos from instantly falling apart because of Roblox gravity.
-- LinearVelocity does the holding, attributes store the timer, and optional front align keeps
-- the attacker positioned in front of the victim for follow up hits.
local function keepAirborne(character: Model, duration: number, airborneOptions: AirborneOptions?)
	-- sets up the temporary airborne state and gravity counter force

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")

	if not humanoid or not root then return end

	-- Freefall is disabled so Roblox does not force a falling animation during the combo hold
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Freefall, false)

	-- if another hit lands mid air, extend the timer instead of making duplicate force objects
	if character:GetAttribute("Airborne") then
		character:SetAttribute("AirborneUntil", os.clock() + duration)
		return
	end

	-- attributes let other systems know this character is currently being held in an air combo
	character:SetAttribute("AirborneUntil", os.clock() + duration)
	character:SetAttribute("Airborne", true)

	-- server ownership makes the air hold more consistent across players
	root:SetNetworkOwner(nil)

	-- LinearVelocity needs an attachment to know what part it is acting on
	local att = Instance.new("Attachment")
	att.Name = "AirborneAttachment"
	att.Parent = root

	-- starts at zero force, then ramps up later so the launch does not instantly cancel
	local lv = Instance.new("LinearVelocity")
	lv.Name = "AirborneHold"
	lv.Attachment0 = att
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.MaxForce = 0
	lv.VectorVelocity = Vector3.new(0, 4, 0)
	lv.Parent = root

	local frontAlignConn

	-- optional front align is only used for the attacker, not every airborne character
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

			-- CFrame lerp moves toward the air combo spot smoothly instead of teleporting
			local targetCFrame = getFrontAlignCFrame(followRoot)
			local alpha = math.clamp(alignSpeed * dt, 0, 1)
			root.CFrame = root.CFrame:Lerp(targetCFrame, alpha)
		end)
	end

	-- let the first part of the launch happen before the hold force starts fighting it
	local start = os.clock()
	while os.clock() - start < 0.6 do
		if not root.Parent then break end
		if root.AssemblyLinearVelocity.Y <= 8 then break end
		task.wait()
	end

	-- ramp force in so the character does not snap or jitter when the hold starts
	local holdStart = os.clock()
	local rampTime = 0.18
	local maxForce = root.AssemblyMass * workspace.Gravity * 1.8

	while os.clock() - holdStart < rampTime do
		local alpha = (os.clock() - holdStart) / rampTime
		lv.MaxForce = maxForce * alpha
		lv.VectorVelocity = Vector3.new(0, 2 * (1 - alpha), 0)
		task.wait()
	end

	-- after the ramp, the config decides if the character floats still or drifts downward
	if GameConfig.FallDownSlowly then
		lv.MaxForce = maxForce
		lv.VectorVelocity = Vector3.new(0, -GameConfig.FallDownRate, 0)
	else
		lv.MaxForce = maxForce
		lv.VectorVelocity = Vector3.zero
	end

	task.spawn(function()
		-- keep checking the attribute because later hits can extend the same airborne state
		while root.Parent do
			local airborneUntil = character:GetAttribute("AirborneUntil")
			if not airborneUntil or os.clock() >= airborneUntil then
				break
			end
			task.wait(0.05)
		end

		-- disconnect the heartbeat loop so it does not keep running after the combo ends
		if frontAlignConn then
			frontAlignConn:Disconnect()
			frontAlignConn = nil
		end

		local exitCfg = GameConfig.AirborneEndBehavior

		if exitCfg.ExitDelay then
			task.wait(exitCfg.ExitDelay)
		end

		-- FreezeThenDrop gives a small pause before gravity takes back over
		if exitCfg.Mode == "FreezeThenDrop" then
			local startFreeze = os.clock()

			while os.clock() - startFreeze < exitCfg.FreezeTime do
				if not root.Parent then break end
				root.AssemblyLinearVelocity = Vector3.zero
				task.wait()
			end

		-- SmoothDrop lets the force push downward instead of instantly removing the hold
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

		-- destroy temporary physics objects so old air combo forces do not stack up
		if lv then lv:Destroy() end
		if att then att:Destroy() end

		-- Freefall gets re-enabled once the custom air hold is finished
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Freefall, true)

		-- clear attributes so other systems do not think the character is still airborne
		character:SetAttribute("Airborne", nil)
		character:SetAttribute("AirborneUntil", nil)

		-- return ownership so player movement feels normal after the server controlled combo
		local player = game.Players:GetPlayerFromCharacter(character)
		if player and root and root.Parent then
			root:SetNetworkOwner(player)
		end
	end)
end


-- this wraps launch and airborne holding into one helper.
-- applyLaunch gives the actual velocity push, then keepAirborne decides how long each character stays up.
-- doing it here keeps the main Damage function readable.
local function handleAirborne(victimEntity: entity, attackerEntity: entity, moveData: GameConfig.Move)
	-- one helper handles both the physics push and the timed air hold

	local didLaunch = applyLaunch(victimEntity, attackerEntity, moveData)

	if didLaunch and moveData.TargetAirborneDuration then
		-- victim stays airborne only if the move config asks for it
		task.spawn(function()
			keepAirborne(victimEntity.character, moveData.TargetAirborneDuration)
		end)
	end

	if moveData.SelfAirborneDuration then
		-- attacker gets front align so follow up hits are easier to land
		task.spawn(function()
			keepAirborne(attackerEntity.character, moveData.SelfAirborneDuration, {
				FollowCharacter = victimEntity.character,
				FrontAlign = true,
			})
		end)
	end

	return didLaunch
end


-- this is the public method other combat code calls after a hit is confirmed.
-- it does the final server checks, reads the move config, resolves shields and block,
-- applies stun, handles launch, subtracts health, fires combat signals, and tells clients to show vfx.
-- the order matters a lot, because defense has to resolve before health damage and launch.
function damageHandler.Damage(entity: entity, move: string, combo: number, attackingEntity: entity)
	-- main damage function for a confirmed combat hit
	-- by the time this runs, the hitbox already found a valid target

	local victim = entity.character
	if not victim then return end
	
	local victimHumanoid = entity.humanoid
	if not victimHumanoid then return end
	
	-- dead attackers should not be able to finish delayed hit callbacks
	if not attackingEntity.humanoid then return end
	if attackingEntity.humanoid.Health <= 0 then return end

	-- sanity check so a random humanoid cannot be paired with the wrong character model
	if not victim:IsAncestorOf(victimHumanoid) then return end

	-- StateMachine tells us if the victim is blocking, dead, invincible, or able to be stunned
	local victimState = StateRegistry:Get(victim) :: StateRegistry.State
	if not victimState then return end

	-- invincible and dead states stop the hit before anything else happens
	if victimState:IsState("Dead") then return end
	if victimState.Invincible then return end

	-- combo index chooses which damage value to use for this hit
	local moveData = GameConfig.Moves[move] :: GameConfig.Move
	local damage = moveData.Damage[combo]
		
	-- absorb happens before blocking because it is a separate temporary protection layer
	local absorbDamage = applyAbsorb(entity, damage)
	damage = absorbDamage and (absorbDamage == 0 and 0 or absorbDamage) or damage
	
	local moveLaunchData = moveData.Launch

	-- blocking gets its own branch because it can change damage, play clash vfx,
	-- fire block signals, and sometimes still launch depending on move config.
	if victimState:IsState("Blocking") then
		-- blocking changes the damage before health gets touched
		damage = resolveBlockedDamage(entity, victimState, damage)

		-- signal lets ui, sound, or other combat systems react without being directly inside this module
		CombatSignals.DamageBlocked:Fire(victim, move, damage)
		
		-- both sides get clash feedback so the hit does not look like it disappeared
		local shouldOverride = true
		local purelyOverride = true

		Remotes.VFX:FireAllClients(entity, "BlockClash", move, combo, shouldOverride)
		Remotes.VFX:FireAllClients(attackingEntity, "BlockClash", move, combo, shouldOverride, purelyOverride)
		
		-- after block rules, only the remaining damage is removed from health
		victimHumanoid.Health -= damage

		-- even blocked hits can deal chip or guard break damage depending on config
		CombatSignals.DamageDealt:Fire(victim, nil, move, combo, damage)
		
		if moveLaunchData and moveLaunchData.OnBlock then
			-- OnBlock lets special moves still launch during a block, if the config wants that
			handleAirborne(entity, attackingEntity, moveData)
			
			-- block launch also stuns so the airborne timer and state timer stay close together
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
	
	-- normal hits stun the victim before damage feedback starts
	victimState:Transition("Stunned", {
		onEnter = {
			Overrides = {
				Duration = moveData.StunTime[combo] or GameConfig.StatusEffects["Stun"].Duration
			} :: GameConfig.StatusEffect
		}
	})
	
	-- launch happens before vfx so the hit result and movement line up
	handleAirborne(entity, attackingEntity, moveData)
	
	-- subtract health on the server after all defensive checks are done
	victimHumanoid.Health -= damage

	-- signal keeps the rest of the combat framework loosely connected to this module
	CombatSignals.DamageDealt:Fire(victim, nil, move, combo, damage)
	
	-- final combo hit gets a different spark so the combo end is readable
	local effectName = combo == #moveData.Damage and "HitSparkFinisher" or "HitSpark"
	local VFXData = GameConfig.VFX[effectName] :: GameConfig.VFX
	
	-- config controls when vfx fires so this module does not hardcode every effect rule
	if VFXData.Trigger == "OnHit" then
		Remotes.VFX:FireAllClients(entity, effectName, move, combo)
	end
	
	-- hit reaction is last because it is only visual feedback after the hit fully resolves
	playHitReaction(entity, move)

	return damage
end

return damageHandler
