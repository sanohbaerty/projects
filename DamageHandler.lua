-- Connected Discord-GitHub | Discord: .sanoh | Roblox: S4N0H

-- damageHandler is the last server step after the hitbox confirms somebody got hit
-- the hitbox finds the target and the validator checks if the hit should count
-- this module takes that confirmed hit and connects it to states damage shields launch physics animations signals and vfx
-- all real combat results stay server sided so a client cannot decide health guard breaks stun or another players physics

local damageHandler = {}

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Modules = ReplicatedStorage.Modules
local Shared = Modules.Shared

local GameConfig = require(Shared.GameConfig)
local StateRegistry = require(Shared.StateRegistry)
local CombatSignals = require(Shared.CombatSignals)
local AnimationController = require(Shared.AnimationController)

-- remotes only send visual results to clients
-- damage states and physics are already decided on the server before any of these fire
local Remotes = ReplicatedStorage.Remotes

-- keeping attribute names here makes every shield read and write use the exact same key
local ATTR_SHIELD_ABSORB = "ShieldAbsorb"
local ATTR_SHIELD_BAR = "ShieldBar"
local ATTR_AIRBORNE = "Airborne"
local ATTR_AIRBORNE_UNTIL = "AirborneUntil"
local ATTR_DEFAULT_JUMP_POWER = "DefaultJumpPower"

type entity = {
	character: Model,
	humanoid: Humanoid,
}

type AirborneOptions = {
	FollowCharacter: Model?,
	FrontAlign: boolean?,
}

-- every public hit comes in as an entity table
-- this checks the character and humanoid still match so delayed hit callbacks cannot damage the wrong model
local function isValidEntity(targetEntity: entity?): boolean
	if not targetEntity then return false end

	local character = targetEntity.character
	local humanoid = targetEntity.humanoid

	if not character or not character:IsA("Model") then return false end
	if not humanoid or not humanoid:IsA("Humanoid") then return false end
	if not character:IsAncestorOf(humanoid) then return false end

	return true
end

-- physics helpers need a real basepart and not just anything named HumanoidRootPart
-- returning nil here is needed because some characters can disappear during delayed combat work
local function getRoot(character: Model): BasePart?
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then return nil end

	return root
end

-- absorb is a status shield that sits before the normal blocking system
-- it returns the damage that should continue into block logic and health instead of changing health by itself
local function applyAbsorb(targetEntity: entity, damage: number): number
	local victim = targetEntity.character
	local absorb = victim:GetAttribute(ATTR_SHIELD_ABSORB)

	-- no absorb means the original damage keeps moving through the resolver
	if type(absorb) ~= "number" or absorb <= 0 then return damage end

	local remainingAbsorb = absorb - damage

	-- the absorb survived so it saves the new amount and fully eats this hit
	if remainingAbsorb > 0 then
		victim:SetAttribute(ATTR_SHIELD_ABSORB, remainingAbsorb)
		return 0
	end

	-- clearing the attribute tells every status system that the absorb is finished
	-- only the part of the hit that went past zero is allowed to continue
	victim:SetAttribute(ATTR_SHIELD_ABSORB, nil)
	return math.abs(remainingAbsorb)
end

-- players handle their guard break feedback locally while npcs have no client to do it for them
-- both paths still come from the same server state so the animation never decides if the break happened
local function playGuardBreak(targetEntity: entity, duration: number)
	local victim = targetEntity.character
	local victimHumanoid = targetEntity.humanoid
	local victimPlayer = Players:GetPlayerFromCharacter(victim)

	-- GuardBroken changes movement rules inside StateRegistry so movement gets refreshed right away
	StateRegistry:UpdateMovement(victim)
	victimHumanoid.JumpPower = 0

	if victimPlayer then
		Remotes.BlockBroken:FireClient(victimPlayer, duration)
	else
		AnimationController:StopAll(nil, victim)
		AnimationController:Play("BlockBroken", nil, nil, victim)
	end

	task.delay(duration, function()
		-- the character might be gone by the time the state timer finishes
		if not victim.Parent or not victimHumanoid.Parent then return end

		-- movement is read again instead of saving old speed since another state could have changed during the break
		StateRegistry:UpdateMovement(victim)
		victimHumanoid.JumpPower = victim:GetAttribute(ATTR_DEFAULT_JUMP_POWER) or 50

		-- player feedback already ends on its own client so only npc tracks need a server stop
		if victimPlayer then return end
		AnimationController:Stop("BlockBroken", nil, victim)
	end)
end

-- hit reactions use two paths because player animation controllers run locally and npc ones run on the server
-- this only sends the visual reaction after the server has already resolved the hit
local function playHitReaction(targetEntity: entity, move: string)
	local victim = targetEntity.character
	local victimPlayer = Players:GetPlayerFromCharacter(victim)

	if victimPlayer then
		Remotes.HitReaction:FireClient(victimPlayer, move)
		return
	end

	-- move specific tracks let one attack have its own reaction without adding special cases to Damage
	local customReaction = move .. "Hit"
	if AnimationController:HasTrack(customReaction .. "1", victim) then
		AnimationController:Play(customReaction, nil, nil, victim)
		return
	end

	-- missing custom tracks fall back to the shared reaction so combat still keeps going
	AnimationController:Play("HitReaction", nil, nil, victim)
end

-- shield block drains a separate shield bar before health
-- breaking the bar connects into StateRegistry then this helper sends the movement animation and vfx side effects
local function applyShieldBlock(targetEntity: entity, victimState, damage: number): number
	local victim = targetEntity.character
	local shield = victim:GetAttribute(ATTR_SHIELD_BAR)

	if type(shield) ~= "number" then
		shield = GameConfig.ShieldBar
	end

	local remainingShield = shield - damage

	-- a shield that survives owns the whole hit so health damage becomes zero
	if remainingShield > 0 then
		victim:SetAttribute(ATTR_SHIELD_BAR, remainingShield)
		return 0
	end

	victim:SetAttribute(ATTR_SHIELD_BAR, 0)

	-- StateRegistry owns the actual GuardBroken state and its timer
	-- playGuardBreak handles everything around that state without putting visuals inside the state machine
	victimState:Transition("GuardBroken", {
		onEnter = {
			Duration = GameConfig.GuardBrokenDuration,
		},
	})

	playGuardBreak(targetEntity, GameConfig.GuardBrokenDuration)
	Remotes.VFX:FireAllClients(targetEntity, "GuardBreak", nil, nil, true)

	-- this combat setup lets the original hit go through when the shield breaks
	return damage
end

-- Damage does not need separate branches for every block system
-- GameConfig picks the block rule here and this gives Damage one final number to subtract from health
local function resolveBlockedDamage(targetEntity: entity, victimState, damage: number): number
	if GameConfig.BlockType == "Shield" then
		return applyShieldBlock(targetEntity, victimState, damage)
	end

	if GameConfig.BlockType == "Partial" then
		return damage * (GameConfig.PartialBlockPercent / 100)
	end

	-- unknown block settings keep the original damage instead of silently deleting the hit
	return damage
end

-- launch velocity blends with current movement so the hit keeps some direction instead of snapping to a full replacement
local function lerpNumber(startValue: number, endValue: number, alpha: number): number
	return startValue + (endValue - startValue) * alpha
end

-- the first push keeps current horizontal movement while pulling it toward the move config
-- the delayed y boost happens after roblox gets one physics step so the launch does not get swallowed by the current velocity
local function applyLaunchVelocity(root: BasePart, launchVelocity: Vector3)
	local currentVelocity = root.AssemblyLinearVelocity

	root.AssemblyLinearVelocity = Vector3.new(
		lerpNumber(currentVelocity.X, launchVelocity.X, 0.75),
		math.max(currentVelocity.Y, launchVelocity.Y * 0.45),
		lerpNumber(currentVelocity.Z, launchVelocity.Z, 0.75)
	)

	task.delay(0.08, function()
		if not root.Parent then return end

		local updatedVelocity = root.AssemblyLinearVelocity
		root.AssemblyLinearVelocity = Vector3.new(
			updatedVelocity.X,
			math.max(updatedVelocity.Y, launchVelocity.Y * 0.75),
			updatedVelocity.Z
		)
	end)
end

-- Launch data can push the victim the attacker or both
-- the bool only tracks victim launch because target airborne holding should not start from a self launch by itself
local function applyLaunch(victimEntity: entity, attackerEntity: entity, moveData: GameConfig.Move): boolean
	local launch = moveData.Launch
	if not launch then return false end

	local victimRoot = getRoot(victimEntity.character)
	local attackerRoot = getRoot(attackerEntity.character)
	local didLaunchVictim = false

	if launch.Target and victimRoot then
		applyLaunchVelocity(victimRoot, launch.Target)
		didLaunchVictim = true
	end

	if not launch.Self or not attackerRoot then return didLaunchVictim end

	-- server ownership keeps self launch and later front align from fighting the attackers client physics
	attackerRoot:SetNetworkOwner(nil)
	applyLaunchVelocity(attackerRoot, launch.Self)

	return didLaunchVictim
end

-- shorter air combos need faster front align or the attacker reaches the spot after the combo is already over
-- longer air combos use a slower speed so the correction does not look like a teleport
local function getAirborneFrontAlignSpeed(duration: number): number
	local frontConfig = GameConfig.AirborneFrontAlign
	local minTime = frontConfig.MinAirTime
	local maxTime = frontConfig.MaxAirTime

	if maxTime <= minTime then return frontConfig.MaxLerpSpeed end

	local timeAlpha = math.clamp((duration - minTime) / (maxTime - minTime), 0, 1)
	return lerpNumber(frontConfig.MaxLerpSpeed, frontConfig.MinLerpSpeed, timeAlpha)
end

-- the victim lookvector decides what front means so the target position moves with their facing direction
-- CFrame.new points the attacker back at the victim which keeps both characters lined up for follow up attacks
local function getFrontAlignCFrame(victimRoot: BasePart): CFrame
	local frontConfig = GameConfig.AirborneFrontAlign
	local heightOffset = Vector3.new(0, frontConfig.HeightOffset, 0)
	local victimPosition = victimRoot.Position
	local targetPosition = victimPosition + victimRoot.CFrame.LookVector * frontConfig.Distance + heightOffset
	local lookAtPosition = victimPosition + heightOffset

	return CFrame.new(targetPosition, lookAtPosition)
end

-- front align only exists for the attacker side of an air combo
-- this check keeps normal victim airborne holding from creating a heartbeat connection it does not need
local function canUseFrontAlign(options: AirborneOptions?): boolean
	local frontConfig = GameConfig.AirborneFrontAlign

	if not frontConfig or not frontConfig.Enabled then return false end
	if not options or not options.FrontAlign then return false end
	if not options.FollowCharacter then return false end

	return true
end

-- this heartbeat connection follows the victims current root instead of saving one old cframe
-- it disconnects itself when the hold ends so no combat loop is left running after the combo
local function startFrontAlign(
	character: Model,
	root: BasePart,
	duration: number,
	options: AirborneOptions?
): RBXScriptConnection?
	if not canUseFrontAlign(options) then return nil end

	local activeOptions = options :: AirborneOptions
	local followCharacter = activeOptions.FollowCharacter :: Model
	local alignSpeed = getAirborneFrontAlignSpeed(duration)
	local connection: RBXScriptConnection

	connection = RunService.Heartbeat:Connect(function(deltaTime)
		if not root.Parent then
			connection:Disconnect()
			return
		end

		local airborneUntil = character:GetAttribute(ATTR_AIRBORNE_UNTIL)
		if type(airborneUntil) ~= "number" or os.clock() >= airborneUntil then
			connection:Disconnect()
			return
		end

		local followRoot = getRoot(followCharacter)
		if not followRoot then return end

		local targetCFrame = getFrontAlignCFrame(followRoot)
		local alpha = math.clamp(alignSpeed * deltaTime, 0, 1)
		root.CFrame = root.CFrame:Lerp(targetCFrame, alpha)
	end)

	return connection
end

-- LinearVelocity needs its own attachment so the temporary force can be removed without touching other character physics
-- force starts at zero because keepAirborne ramps it after the launch gets time to move upward
local function createAirborneForce(root: BasePart): (Attachment, LinearVelocity)
	local attachment = Instance.new("Attachment")
	attachment.Name = "AirborneAttachment"
	attachment.Parent = root

	local linearVelocity = Instance.new("LinearVelocity")
	linearVelocity.Name = "AirborneHold"
	linearVelocity.Attachment0 = attachment
	linearVelocity.RelativeTo = Enum.ActuatorRelativeTo.World
	linearVelocity.MaxForce = 0
	linearVelocity.VectorVelocity = Vector3.new(0, 4, 0)
	linearVelocity.Parent = root

	return attachment, linearVelocity
end

-- the launch gets a small window before the hold force starts countering gravity
-- the loop also ends early once upward speed is already low enough to begin the hold
local function waitForLaunchPeak(root: BasePart)
	local endTime = os.clock() + 0.6

	while root.Parent and os.clock() < endTime and root.AssemblyLinearVelocity.Y > 8 do
		task.wait()
	end
end

-- max force ramps from zero to the amount needed to fight gravity
-- this stops the launch from snapping when LinearVelocity takes control
local function rampAirborneForce(root: BasePart, linearVelocity: LinearVelocity): number
	local rampTime = 0.18
	local startTime = os.clock()
	local maxForce = root.AssemblyMass * workspace.Gravity * 1.8

	while root.Parent and os.clock() - startTime < rampTime do
		local alpha = (os.clock() - startTime) / rampTime
		linearVelocity.MaxForce = maxForce * alpha
		linearVelocity.VectorVelocity = Vector3.new(0, 2 * (1 - alpha), 0)
		task.wait()
	end

	return maxForce
end

-- after the ramp the config decides between a still hold and a controlled downward drift
-- both use the same gravity counter force so they stay consistent across character mass
local function setAirborneHold(linearVelocity: LinearVelocity, maxForce: number)
	local holdVelocity = Vector3.zero

	if GameConfig.FallDownSlowly then
		holdVelocity = Vector3.new(0, -GameConfig.FallDownRate, 0)
	end

	linearVelocity.MaxForce = maxForce
	linearVelocity.VectorVelocity = holdVelocity
end

-- later air hits only update AirborneUntil so this loop reads the attribute again every pass
-- the same force objects stay alive while the timer extends which stops duplicate constraints from stacking
local function waitForAirborneEnd(character: Model, root: BasePart)
	local airborneUntil = character:GetAttribute(ATTR_AIRBORNE_UNTIL)

	while root.Parent and type(airborneUntil) == "number" and os.clock() < airborneUntil do
		task.wait(0.05)
		airborneUntil = character:GetAttribute(ATTR_AIRBORNE_UNTIL)
	end
end

-- FreezeThenDrop removes any leftover launch movement for a short pause before normal gravity comes back
local function runFreezeThenDrop(root: BasePart, exitConfig)
	local endTime = os.clock() + exitConfig.FreezeTime

	while root.Parent and os.clock() < endTime do
		root.AssemblyLinearVelocity = Vector3.zero
		task.wait()
	end
end

-- SmoothDrop keeps LinearVelocity active while its downward speed increases over the configured time
-- cleanup removes the force right after this so roblox gravity takes over from the final downward motion
local function runSmoothDrop(root: BasePart, linearVelocity: LinearVelocity, exitConfig)
	local startTime = os.clock()
	local dropTime = exitConfig.DropTime

	while root.Parent and os.clock() - startTime < dropTime do
		local alpha = (os.clock() - startTime) / dropTime
		linearVelocity.VectorVelocity = Vector3.new(0, exitConfig.DropVelocity * alpha, 0)
		linearVelocity.MaxForce = root.AssemblyMass * workspace.Gravity * 2
		task.wait()
	end
end

-- exit behavior is separated from cleanup so adding another drop style does not make keepAirborne turn into one giant nested function
local function runAirborneExit(root: BasePart, linearVelocity: LinearVelocity)
	local exitConfig = GameConfig.AirborneEndBehavior

	if exitConfig.ExitDelay and exitConfig.ExitDelay > 0 then
		task.wait(exitConfig.ExitDelay)
	end

	if not root.Parent then return end

	if exitConfig.Mode == "FreezeThenDrop" then
		runFreezeThenDrop(root, exitConfig)
		return
	end

	if exitConfig.Mode == "SmoothDrop" then
		runSmoothDrop(root, linearVelocity, exitConfig)
	end
end

-- cleanup disconnects and destroys only the objects this airborne hold created
-- attributes are cleared last so other combat systems know the custom hold is fully finished
local function cleanupAirborne(
	character: Model,
	humanoid: Humanoid,
	root: BasePart,
	attachment: Attachment,
	linearVelocity: LinearVelocity,
	frontAlignConnection: RBXScriptConnection?
)
	if frontAlignConnection and frontAlignConnection.Connected then
		frontAlignConnection:Disconnect()
	end

	if linearVelocity.Parent then
		linearVelocity:Destroy()
	end

	if attachment.Parent then
		attachment:Destroy()
	end

	if humanoid.Parent then
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Freefall, true)
	end

	character:SetAttribute(ATTR_AIRBORNE, nil)
	character:SetAttribute(ATTR_AIRBORNE_UNTIL, nil)

	if not root.Parent then return end

	-- player ownership comes back after the server controlled hold so normal movement does not feel delayed
	local player = Players:GetPlayerFromCharacter(character)
	if not player then return end

	root:SetNetworkOwner(player)
end

-- keepAirborne connects launch physics to a timed gravity hold
-- repeated hits extend the timer while the first call keeps ownership force objects and heartbeat cleanup in one place
local function keepAirborne(character: Model, duration: number, options: AirborneOptions?)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = getRoot(character)

	if not humanoid or not root then return end

	-- Freefall stays disabled on every refresh so roblox does not take control of an active air combo
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Freefall, false)

	-- extending the attribute reuses the current hold instead of creating another LinearVelocity on the same root
	if character:GetAttribute(ATTR_AIRBORNE) then
		character:SetAttribute(ATTR_AIRBORNE_UNTIL, os.clock() + duration)
		return
	end

	character:SetAttribute(ATTR_AIRBORNE, true)
	character:SetAttribute(ATTR_AIRBORNE_UNTIL, os.clock() + duration)
	root:SetNetworkOwner(nil)

	local attachment, linearVelocity = createAirborneForce(root)
	local frontAlignConnection = startFrontAlign(character, root, duration, options)

	waitForLaunchPeak(root)

	if not root.Parent then
		cleanupAirborne(character, humanoid, root, attachment, linearVelocity, frontAlignConnection)
		return
	end

	local maxForce = rampAirborneForce(root, linearVelocity)

	if not root.Parent then
		cleanupAirborne(character, humanoid, root, attachment, linearVelocity, frontAlignConnection)
		return
	end

	setAirborneHold(linearVelocity, maxForce)

	task.spawn(function()
		waitForAirborneEnd(character, root)
		runAirborneExit(root, linearVelocity)
		cleanupAirborne(character, humanoid, root, attachment, linearVelocity, frontAlignConnection)
	end)
end

-- handleAirborne is the bridge between move config and the physics helpers
-- applyLaunch creates the push then each configured duration starts the correct hold for the victim or attacker
local function handleAirborne(victimEntity: entity, attackerEntity: entity, moveData: GameConfig.Move): boolean
	local didLaunchVictim = applyLaunch(victimEntity, attackerEntity, moveData)
	local victimDuration = moveData.TargetAirborneDuration
	local attackerDuration = moveData.SelfAirborneDuration

	if didLaunchVictim and victimDuration then
		task.spawn(function()
			keepAirborne(victimEntity.character, victimDuration)
		end)
	end

	if attackerDuration then
		task.spawn(function()
			keepAirborne(attackerEntity.character, attackerDuration, {
				FollowCharacter = victimEntity.character,
				FrontAlign = true,
			})
		end)
	end

	return didLaunchVictim
end

-- move stun can change per combo hit and falls back to the shared stun status when the move has no override
local function getStunDuration(moveData: GameConfig.Move, combo: number): number
	return moveData.StunTime[combo] or GameConfig.StatusEffects.Stun.Duration
end

-- StateRegistry owns all state transitions so Damage only sends the duration data the Stunned state needs
local function applyStun(victimState, duration: number)
	victimState:Transition("Stunned", {
		onEnter = {
			Overrides = {
				Duration = duration,
			} :: GameConfig.StatusEffect,
		},
	})
end

-- blocked hits still fire DamageDealt because chip damage shield breaks ui and sounds need the final amount
-- OnBlock launch is handled after shield math so the state and physics use the same resolved hit
local function resolveBlockedHit(
	victimEntity: entity,
	attackerEntity: entity,
	victimState,
	move: string,
	combo: number,
	moveData: GameConfig.Move,
	damage: number
): number
	local victim = victimEntity.character
	local victimHumanoid = victimEntity.humanoid
	local resolvedDamage = resolveBlockedDamage(victimEntity, victimState, damage)

	CombatSignals.DamageBlocked:Fire(victim, move, resolvedDamage)

	-- both characters get clash vfx so attacker and victim feedback stay synced from the same server hit
	Remotes.VFX:FireAllClients(victimEntity, "BlockClash", move, combo, true)
	Remotes.VFX:FireAllClients(attackerEntity, "BlockClash", move, combo, true, true)

	victimHumanoid.Health -= resolvedDamage
	CombatSignals.DamageDealt:Fire(victim, nil, move, combo, resolvedDamage)

	local launch = moveData.Launch
	if not launch or not launch.OnBlock then return resolvedDamage end

	handleAirborne(victimEntity, attackerEntity, moveData)

	-- blocked launch adds target air time onto stun so the victim does not leave Stunned while still being held
	local airborneDuration = moveData.TargetAirborneDuration or 0
	applyStun(victimState, getStunDuration(moveData, combo) + airborneDuration)
	playHitReaction(victimEntity, move)

	return resolvedDamage
end

-- normal hits apply state and physics before health feedback so every connected system sees the finished result in the same order
local function resolveNormalHit(
	victimEntity: entity,
	attackerEntity: entity,
	victimState,
	move: string,
	combo: number,
	moveData: GameConfig.Move,
	damage: number
): number
	local victim = victimEntity.character
	local victimHumanoid = victimEntity.humanoid

	applyStun(victimState, getStunDuration(moveData, combo))
	handleAirborne(victimEntity, attackerEntity, moveData)

	victimHumanoid.Health -= damage
	CombatSignals.DamageDealt:Fire(victim, nil, move, combo, damage)

	-- combo finishers use a different effect name but both still follow the trigger rule stored in GameConfig
	local effectName = combo == #moveData.Damage and "HitSparkFinisher" or "HitSpark"
	local effectData = GameConfig.VFX[effectName] :: GameConfig.VFX

	if effectData.Trigger == "OnHit" then
		Remotes.VFX:FireAllClients(victimEntity, effectName, move, combo)
	end

	playHitReaction(victimEntity, move)
	return damage
end

-- this is the only public damage entry
-- HitboxHandler and the validator call this after confirming contact then this runs defense state physics health signals and visuals in that order
function damageHandler.Damage(victimEntity: entity, move: string, combo: number, attackerEntity: entity)
	if not isValidEntity(victimEntity) then return end
	if not isValidEntity(attackerEntity) then return end
	if attackerEntity.humanoid.Health <= 0 then return end

	local victim = victimEntity.character
	local victimState = StateRegistry:Get(victim) :: StateRegistry.State
	if not victimState then return end

	-- dead and invincible states stop before absorb block stun health signals or vfx can run
	if victimState:IsState("Dead") then return end
	if victimState.Invincible then return end

	local moveData = GameConfig.Moves[move] :: GameConfig.Move
	if not moveData then return end

	local damage = moveData.Damage[combo]
	if type(damage) ~= "number" then return end

	-- absorb is always first because it is a status health layer and blocking only sees whatever damage gets past it
	damage = applyAbsorb(victimEntity, damage)

	if victimState:IsState("Blocking") then
		return resolveBlockedHit(victimEntity, attackerEntity, victimState, move, combo, moveData, damage)
	end

	return resolveNormalHit(victimEntity, attackerEntity, victimState, move, combo, moveData, damage)
end

return damageHandler
