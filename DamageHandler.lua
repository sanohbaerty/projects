-- Connected Discord-GitHub | Discord: .sanoh | Roblox: S4N0H

-- this module is the last server step after the hitbox and hit validator already finished their jobs
-- the hitbox only figures out what character was touched and the validator decides if that contact is allowed to count
-- after both of those pass they call damageHandler.Damage with the victim the move name the combo number and the attacker
-- this script does not search for targets and it does not accept a damage number from the client
-- it reads the damage and all launch data from GameConfig on the server so the client cannot raise damage or invent a move
-- the order inside this module matters because every part of the result depends on what happened before it
-- absorb gets checked first because it is an extra health layer before blocking
-- blocking resolves the amount that is actually allowed to reach health
-- stun and airborne physics are started from the confirmed move data
-- health is changed on the server then signals and remotes tell the rest of the game what result already happened
-- remotes in here are feedback only they do not give a client control over health states shields guard breaks or physics
-- keeping all of this in one final resolver also means every attack follows the same rules instead of each move handling damage differently

-- this table is what gets returned at the bottom
-- only Damage is public everything else stays local so other scripts cannot skip parts of the damage order
local damageHandler = {}

-- Players is used to tell the difference between a real player character and an npc character
-- ReplicatedStorage holds the shared configs modules and remotes used by both sides of the combat system
-- RunService gives the heartbeat connection used while an attacker follows a victim during an air combo
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

-- these paths keep the requires in one shared location instead of searching the game every time a hit happens
local Modules = ReplicatedStorage.Modules
local Shared = Modules.Shared

-- GameConfig owns move damage stun launch shield and vfx settings
-- StateRegistry owns states like Blocking GuardBroken Stunned and Dead plus the movement rules tied to them
-- CombatSignals lets other server systems react to a finished hit without putting their code inside this module
-- AnimationController plays server controlled npc animations while player animation feedback is sent through remotes
local GameConfig = require(Shared.GameConfig)
local StateRegistry = require(Shared.StateRegistry)
local CombatSignals = require(Shared.CombatSignals)
local AnimationController = require(Shared.AnimationController)

-- these remotes only tell clients what visual result the server already decided
-- BlockBroken tells the victim player to run their local guard break feedback for the server supplied duration
-- HitReaction tells a player character which move reaction should be shown
-- VFX tells every client which hit guard break or clash effect should be drawn
-- none of these remotes are used to ask a client how much damage happened or whether a state should change
-- by the time one of them fires the server has already done the shield math state change health change or physics setup
local Remotes = ReplicatedStorage.Remotes

-- these constants are the exact attribute keys shared by all helpers in this module
-- putting the names here stops one function from reading a slightly different spelling than another function writes
-- ShieldAbsorb stores the amount left in the temporary absorb layer
-- ShieldBar stores the normal blocking shield amount
-- Airborne marks that one custom airborne controller is already active on the character
-- AirborneUntil stores the clock time that controller is allowed to keep running until
-- DefaultJumpPower is used after guard break so jump power goes back to the characters own saved value instead of one hardcoded value
local ATTR_SHIELD_ABSORB = "ShieldAbsorb"
local ATTR_SHIELD_BAR = "ShieldBar"
local ATTR_AIRBORNE = "Airborne"
local ATTR_AIRBORNE_UNTIL = "AirborneUntil"
local ATTR_DEFAULT_JUMP_POWER = "DefaultJumpPower"

-- every combat target is passed around as one entity table
-- keeping the model and humanoid together means helpers do not need to search for the humanoid again during the same hit
-- isValidEntity still checks that both objects exist and that the humanoid really belongs to that model
-- this matters when delayed hitbox callbacks run after a character died respawned or got removed
type entity = {
	character: Model,
	humanoid: Humanoid,
}

-- these options are only needed by the airborne controller
-- FollowCharacter is the character whose current root position should be followed during front align
-- FrontAlign has to be true before a heartbeat connection is made
-- both fields are optional because victim airborne holding does not need to follow anybody
type AirborneOptions = {
	FollowCharacter: Model?,
	FrontAlign: boolean?,
}

-- this validates the entity table before any state health animation or physics work starts
-- targetEntity can be nil because a delayed hit callback may finish after its target was removed
-- character has to still be a Model because all attributes states roots and animations are read from that model
-- humanoid has to still be a Humanoid because health and humanoid states are changed later in the resolver
-- IsAncestorOf is important because an old humanoid reference could still exist while no longer belonging to this character
-- returning false on any failed check makes Damage stop without partially applying a hit
-- returning true means the model and humanoid pair is still safe to use for this exact call
local function isValidEntity(targetEntity: entity?): boolean
	if not targetEntity then return false end

	local character = targetEntity.character
	local humanoid = targetEntity.humanoid

	if not character or not character:IsA("Model") then return false end
	if not humanoid or not humanoid:IsA("Humanoid") then return false end
	if not character:IsAncestorOf(humanoid) then return false end

	return true
end

-- every launch and airborne helper needs the characters real HumanoidRootPart
-- FindFirstChild by itself can return any instance with that name so the BasePart check is still required
-- the return type is optional because combat work can be delayed and the root may already be destroyed when the helper runs
-- callers check for nil instead of assuming the character stayed alive for the whole task
-- keeping this check in one helper makes every physics path use the same root rules
local function getRoot(character: Model): BasePart?
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then return nil end

	return root
end

-- absorb is a temporary damage layer placed before normal blocking and before health
-- this helper never edits humanoid health itself
-- it only reads ShieldAbsorb subtracts the incoming damage and returns the amount that still needs to be resolved
-- returning a number instead of doing the whole hit here lets the main Damage function keep one clear order
-- a full absorb returns zero so block logic and health receive no damage from this hit
-- an absorb that breaks returns only the overflow so the part covered by the absorb cannot be counted twice
-- an invalid missing or empty attribute acts like no absorb and returns the original damage unchanged
local function applyAbsorb(targetEntity: entity, damage: number): number
	local victim = targetEntity.character
	local absorb = victim:GetAttribute(ATTR_SHIELD_ABSORB)

	-- attributes can be nil or another type so the number check prevents bad status data from entering the math
	-- zero and negative values also mean there is nothing left to absorb
	-- in all of those cases the exact incoming damage keeps moving to the blocking check
	if type(absorb) ~= "number" or absorb <= 0 then return damage end

	local remainingAbsorb = absorb - damage

	-- remainingAbsorb above zero means the shield had more points than this hit dealt
	-- the new amount is saved back on the same character for the next hit
	-- zero is returned because none of this hit is allowed to reach block math or health
	if remainingAbsorb > 0 then
		victim:SetAttribute(ATTR_SHIELD_ABSORB, remainingAbsorb)
		return 0
	end

	-- reaching this point means the hit used all absorb points and may have gone past zero
	-- nil removes the attribute completely so other status code can tell the absorb is no longer active
	-- remainingAbsorb is zero or negative because the subtraction already happened
	-- math.abs turns that negative overflow into the positive damage amount that was not covered
	-- when it landed exactly on zero the return is zero and no damage continues
	victim:SetAttribute(ATTR_SHIELD_ABSORB, nil)
	return math.abs(remainingAbsorb)
end

-- this runs the extra movement animation and client feedback after StateRegistry entered GuardBroken
-- it does not decide whether the shield broke because applyShieldBlock already did that math on the server
-- player characters use their own client feedback so their local animation and ui can react without the server trying to own those tracks
-- npc characters have no personal client so their BlockBroken animation is stopped and played through AnimationController on the server
-- jump power is forced to zero during the break so the victim cannot jump while the state says their guard is broken
-- after the duration the helper checks that the original character and humanoid still exist before restoring anything
-- movement gets recalculated from StateRegistry at the end instead of restoring one old WalkSpeed that could now be wrong
-- this keeps another state applied during the guard break from being overwritten by stale movement values
local function playGuardBreak(targetEntity: entity, duration: number)
	local victim = targetEntity.character
	local victimHumanoid = targetEntity.humanoid
	local victimPlayer = Players:GetPlayerFromCharacter(victim)

	-- the state transition happened right before this helper was called
	-- UpdateMovement makes the current state restrictions take effect immediately on this character
	-- jump power is handled directly here because the guard break feedback needs jumping fully disabled for the same duration
	StateRegistry:UpdateMovement(victim)
	victimHumanoid.JumpPower = 0

	if victimPlayer then
		Remotes.BlockBroken:FireClient(victimPlayer, duration)
	else
		AnimationController:StopAll(nil, victim)
		AnimationController:Play("BlockBroken", nil, nil, victim)
	end

	task.delay(duration, function()
		-- task.delay keeps this callback alive even if the victim died reset or was removed during the break
		-- checking both parents stops the callback from writing movement or jump values onto destroyed instances
		if not victim.Parent or not victimHumanoid.Parent then return end

		-- the old speed is not cached because another state may have started while GuardBroken was active
		-- UpdateMovement asks StateRegistry for the correct movement rules that exist right now
		-- jump power uses the characters saved default and only falls back to 50 when that attribute was never set
		StateRegistry:UpdateMovement(victim)
		victimHumanoid.JumpPower = victim:GetAttribute(ATTR_DEFAULT_JUMP_POWER) or 50

		-- the player remote is responsible for ending its own local feedback using the same duration
		-- returning here avoids the server trying to stop a player animation track it never started
		-- npc animation was started above by AnimationController so that exact track is stopped here
		if victimPlayer then return end
		AnimationController:Stop("BlockBroken", nil, victim)
	end)
end

-- this chooses where the hit reaction animation needs to be played
-- a player character owns its normal animation controller locally so the server sends the move name to only that player
-- an npc has no owning client animation path so AnimationController handles the track on the server
-- this helper never changes health stun or physics it only displays a reaction after the hit result already exists
-- npc reactions first look for a move specific animation so different attacks can have different body reactions
-- when that track is missing the shared HitReaction track is used so one missing custom animation does not stop combat
local function playHitReaction(targetEntity: entity, move: string)
	local victim = targetEntity.character
	local victimPlayer = Players:GetPlayerFromCharacter(victim)

	if victimPlayer then
		Remotes.HitReaction:FireClient(victimPlayer, move)
		return
	end

	-- the move name is combined with Hit so a move called Uppercut looks for UppercutHit
	-- HasTrack checks the first numbered track because AnimationController stores reaction variants with a number on the end
	-- when the custom set exists AnimationController can choose and play from that set without Damage knowing its animation details
	local customReaction = move .. "Hit"
	if AnimationController:HasTrack(customReaction .. "1", victim) then
		AnimationController:Play(customReaction, nil, nil, victim)
		return
	end

	-- not every move needs its own animation set
	-- this fallback guarantees the npc still reacts even when no move specific track was added
	AnimationController:Play("HitReaction", nil, nil, victim)
end

-- this handles the Shield block mode from GameConfig
-- the shield bar is separate from humanoid health and only exists while the victim is blocking
-- the stored ShieldBar attribute is used when it is a number
-- when the attribute was never created the configured full shield amount is used as the starting value
-- damage is subtracted once and the result decides whether the shield survived or broke
-- a surviving shield stores its remaining points and returns zero health damage
-- a broken shield is set to zero enters GuardBroken sends feedback and returns the original hit damage
-- returning the original damage on break is intentional for this combat setup because the breaking hit is allowed to pass through
-- StateRegistry owns the actual state while this helper only connects that result to animation movement and vfx
local function applyShieldBlock(targetEntity: entity, victimState, damage: number): number
	local victim = targetEntity.character
	local shield = victim:GetAttribute(ATTR_SHIELD_BAR)

	if type(shield) ~= "number" then
		shield = GameConfig.ShieldBar
	end

	local remainingShield = shield - damage

	-- remainingShield above zero means the block had enough points to cover the complete hit
	-- the remaining amount is saved for the next blocked attack
	-- zero is returned so resolveBlockedHit subtracts nothing from humanoid health
	if remainingShield > 0 then
		victim:SetAttribute(ATTR_SHIELD_BAR, remainingShield)
		return 0
	end

	victim:SetAttribute(ATTR_SHIELD_BAR, 0)

	-- setting the attribute to zero makes the empty shield visible to ui and any other shield reader
	-- Transition is the real gameplay state change and receives the configured break duration through onEnter data
	-- the state registry can now apply its normal rules without needing to know about remotes animations or vfx
	-- playGuardBreak handles jump movement and player or npc feedback after the state is already official
	victimState:Transition("GuardBroken", {
		onEnter = {
			Duration = GameConfig.GuardBrokenDuration,
		},
	})

	playGuardBreak(targetEntity, GameConfig.GuardBrokenDuration)
	Remotes.VFX:FireAllClients(targetEntity, "GuardBreak", nil, nil, true)

	-- damage is returned unchanged instead of returning only shield overflow
	-- that means the attack that reaches zero shield also deals its full configured damage to health
	-- this is a rule of this shield system and keeping it here makes that choice easy to find
	return damage
end

-- this is the single block math router used by resolveBlockedHit
-- Damage only needs to know that the victim is Blocking it does not need the details of every block mode
-- Shield sends the hit through the shield bar and guard break rules
-- Partial multiplies the hit by the configured percent so only that portion reaches health
-- any other value returns the original damage because silently turning an unknown setting into zero damage would hide a config mistake
-- every branch returns the final blocked damage amount and the caller uses that same number for health signals and ui
local function resolveBlockedDamage(targetEntity: entity, victimState, damage: number): number
	if GameConfig.BlockType == "Shield" then
		return applyShieldBlock(targetEntity, victimState, damage)
	end

	if GameConfig.BlockType == "Partial" then
		return damage * (GameConfig.PartialBlockPercent / 100)
	end

	-- this fallback keeps the attack working when BlockType is misspelled or a new mode was not connected yet
	-- full damage is safer here than making every blocking character accidentally invincible
	return damage
end

-- this is the basic number interpolation used by launch velocity and front align speed
-- alpha zero returns the starting value and alpha one returns the ending value
-- values between them move part of the distance toward the ending value
-- using one helper keeps the math identical anywhere this script needs a smooth blend
local function lerpNumber(startValue: number, endValue: number, alpha: number): number
	return startValue + (endValue - startValue) * alpha
end

-- this applies one configured launch vector to a root without completely deleting the velocity it already had
-- current AssemblyLinearVelocity is read first so a running or falling character keeps part of that motion
-- x and z are blended 75 percent toward the configured launch instead of being hard replaced
-- y uses math.max so a strong existing upward velocity is never made weaker by the first part of the launch
-- only 45 percent of configured y is used on the immediate write because the second write finishes the vertical push
-- the 0.08 delay gives roblox a physics step before the stronger y value is applied
-- without that second step a launch can lose height when current character physics and the new velocity are resolved in the same frame
-- the delayed callback checks root.Parent because the character could be removed during those 0.08 seconds
-- x and z from the updated velocity are kept during the second write so physics changes from the first step are not erased
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

-- this reads the optional Launch table from one move and applies each side of it that is actually configured
-- Launch.Target is the velocity for the victim and Launch.Self is the velocity for the attacker
-- either side can exist by itself or both can exist on the same move
-- roots are resolved separately because one character can disappear while the other still exists
-- didLaunchVictim only becomes true when Target data existed and the victims root was valid
-- handleAirborne uses that bool so it does not start a victim hold when only the attacker launched themself
-- attacker network ownership is moved to the server before self launch because front align may also control that root right after this
-- the function returns victim launch status after both possible launches have been checked
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

	-- player roots are normally simulated by that players client for smoother movement
	-- during this self launch the server is about to control velocity and possibly CFrame every heartbeat
	-- setting ownership to nil makes the server the physics owner so two machines are not correcting the same root at once
	attackerRoot:SetNetworkOwner(nil)
	applyLaunchVelocity(attackerRoot, launch.Self)

	return didLaunchVictim
end

-- this converts airborne duration into the lerp speed used by attacker front align
-- MinAirTime and MaxAirTime define the duration range expected by the config
-- a short duration produces a value near MaxLerpSpeed because the attacker has less time to reach the victim
-- a long duration produces a value near MinLerpSpeed because the correction can happen more slowly
-- timeAlpha is clamped so durations outside the configured range cannot create speeds past either limit
-- the speed values are reversed in lerpNumber on purpose short time starts at max speed and long time ends at min speed
-- when the config range is invalid or zero sized MaxLerpSpeed is returned so no divide by zero happens
local function getAirborneFrontAlignSpeed(duration: number): number
	local frontConfig = GameConfig.AirborneFrontAlign
	local minTime = frontConfig.MinAirTime
	local maxTime = frontConfig.MaxAirTime

	if maxTime <= minTime then return frontConfig.MaxLerpSpeed end

	local timeAlpha = math.clamp((duration - minTime) / (maxTime - minTime), 0, 1)
	return lerpNumber(frontConfig.MaxLerpSpeed, frontConfig.MinLerpSpeed, timeAlpha)
end

-- this calculates the exact CFrame where the attacker should move during front align
-- the victims current Position is the center of the calculation so the target updates when the victim moves
-- the victims LookVector decides which direction counts as in front of them
-- Distance pushes the target position forward from the victim along that look direction
-- HeightOffset raises or lowers both the target and look point without changing their facing relationship
-- targetPosition is where the attacker root should be
-- lookAtPosition is where that root should face
-- CFrame.new with both positions returns one CFrame that places the attacker in front and turns them back toward the victim
local function getFrontAlignCFrame(victimRoot: BasePart): CFrame
	local frontConfig = GameConfig.AirborneFrontAlign
	local heightOffset = Vector3.new(0, frontConfig.HeightOffset, 0)
	local victimPosition = victimRoot.Position
	local targetPosition = victimPosition + victimRoot.CFrame.LookVector * frontConfig.Distance + heightOffset
	local lookAtPosition = victimPosition + heightOffset

	return CFrame.new(targetPosition, lookAtPosition)
end

-- this collects every condition required before startFrontAlign creates a heartbeat connection
-- the whole feature must exist in GameConfig and Enabled has to be true
-- options must be supplied because normal victim airborne calls do not pass any
-- FrontAlign must be true so a caller has to directly request this behavior
-- FollowCharacter must exist because there is nothing to follow without a victim model
-- returning false early avoids making a connection that would only wake up every frame and do nothing
local function canUseFrontAlign(options: AirborneOptions?): boolean
	local frontConfig = GameConfig.AirborneFrontAlign

	if not frontConfig or not frontConfig.Enabled then return false end
	if not options or not options.FrontAlign then return false end
	if not options.FollowCharacter then return false end

	return true
end

-- this starts the per physics step correction that keeps an airborne attacker in front of the victim
-- canUseFrontAlign is checked before any option cast or connection is made
-- the follow character is saved but its root is looked up again every heartbeat because roots can be replaced or removed
-- alignSpeed is calculated once from the requested air duration because that duration does not change for this connection
-- deltaTime is multiplied into the speed so the lerp behaves similarly across different server frame rates
-- the connection stops itself if the controlled root is destroyed
-- it also reads AirborneUntil every heartbeat and stops when the attribute is missing invalid or expired
-- if the victim root is temporarily missing that frame is skipped without destroying the attackers whole airborne hold
-- each valid frame gets a fresh target CFrame from the victims current position and facing
-- CFrame:Lerp moves and turns the attacker part of the way toward that target instead of teleporting there
-- returning the connection lets cleanupAirborne disconnect it from one central cleanup path too
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

-- this creates the two temporary instances used to hold a character in the air
-- LinearVelocity needs an Attachment0 so a new attachment is parented directly to the root
-- both objects get clear names so they can be seen while debugging the character in studio
-- RelativeTo World means the y velocity stays world vertical even while the character rotates
-- MaxForce starts at zero so creating the constraint does not instantly cancel the launch that was just applied
-- VectorVelocity starts slightly upward but it has no effect until rampAirborneForce raises MaxForce
-- both instances are returned because cleanupAirborne must destroy exactly the objects created for this hold
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

-- this waits for the strongest part of the upward launch before the gravity hold starts taking control
-- endTime puts a hard 0.6 second limit on the wait so a huge launch can never stall the rest of the airborne setup forever
-- the loop only continues while the root still exists
-- it also only continues while vertical speed is above 8 because that means the character is still rising fast
-- once y speed falls low enough the hold can begin without cutting off most of the launch arc
-- task.wait yields between checks so this does not block the server thread
local function waitForLaunchPeak(root: BasePart)
	local endTime = os.clock() + 0.6

	while root.Parent and os.clock() < endTime and root.AssemblyLinearVelocity.Y > 8 do
		task.wait()
	end
end

-- this slowly gives LinearVelocity enough force to take over from normal gravity
-- rampTime is the amount of time used to move from no force to full holding force
-- maxForce is based on AssemblyMass times workspace gravity so heavier characters receive the force needed for their own mass
-- the extra 1.8 multiplier gives enough room for the constraint to control the root instead of barely matching gravity
-- alpha moves from zero toward one during the ramp
-- MaxForce follows alpha so the constraint does not switch from zero to full strength in one frame
-- VectorVelocity starts near two studs upward and fades toward zero during the same ramp
-- this softens the handoff between the attack launch and the stationary air hold
-- the final maxForce is returned so setAirborneHold can reuse the exact calculated value
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

-- this sets the normal velocity used after the force ramp is complete
-- Vector3.zero gives a mostly stationary hold because LinearVelocity fights movement in every world axis
-- when FallDownSlowly is enabled the y value becomes negative FallDownRate so the victim drifts down during the combo
-- only the desired velocity changes the mass based maxForce stays the one calculated for this root
-- keeping the choice in GameConfig lets the same physics code support a frozen air combo or a slow falling one
local function setAirborneHold(linearVelocity: LinearVelocity, maxForce: number)
	local holdVelocity = Vector3.zero

	if GameConfig.FallDownSlowly then
		holdVelocity = Vector3.new(0, -GameConfig.FallDownRate, 0)
	end

	linearVelocity.MaxForce = maxForce
	linearVelocity.VectorVelocity = holdVelocity
end

-- this waits until the active airborne timer is actually finished
-- AirborneUntil is read before the loop then read again after every wait
-- that repeated read is required because another combo hit can extend the attribute while this same hold is running
-- the existing attachment LinearVelocity and cleanup task stay in use during an extension
-- no second constraint gets created and no second cleanup races the first one
-- the loop also ends when the root is removed or when the attribute stops being a number
-- checking every 0.05 seconds is frequent enough for the timer while avoiding a full heartbeat connection just for waiting
local function waitForAirborneEnd(character: Model, root: BasePart)
	local airborneUntil = character:GetAttribute(ATTR_AIRBORNE_UNTIL)

	while root.Parent and type(airborneUntil) == "number" and os.clock() < airborneUntil do
		task.wait(0.05)
		airborneUntil = character:GetAttribute(ATTR_AIRBORNE_UNTIL)
	end
end

-- this is one possible airborne exit mode from GameConfig
-- for FreezeTime the root velocity is forced to zero every loop
-- repeating the write matters because gravity or another small physics response can add velocity again between frames
-- when the time ends cleanup removes LinearVelocity and normal roblox gravity is allowed to pull the character down
-- the root parent check stops the loop immediately if the character was removed during the freeze
local function runFreezeThenDrop(root: BasePart, exitConfig)
	local endTime = os.clock() + exitConfig.FreezeTime

	while root.Parent and os.clock() < endTime do
		root.AssemblyLinearVelocity = Vector3.zero
		task.wait()
	end
end

-- this is the second airborne exit mode
-- it keeps the same LinearVelocity alive and changes its target y speed over DropTime
-- alpha starts near zero and reaches one as the exit finishes
-- DropVelocity is multiplied by alpha so the downward speed starts soft and becomes the full configured value
-- MaxForce is recalculated from the current root mass with extra force so the requested descent is actually followed
-- after this function returns cleanup destroys the constraint and roblox gravity continues from the downward movement already created
-- the root check prevents writes after the character has been removed
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

-- this reads the configured airborne ending behavior and sends it to the matching helper
-- ExitDelay leaves the normal hold active for a little longer before an exit style starts
-- after that delay the root is checked again because the character could have disappeared while this task was waiting
-- FreezeThenDrop runs its own timed freeze then returns so no other mode can also run
-- SmoothDrop runs its controlled descent when selected
-- an unknown mode simply does no special exit and cleanup will remove the hold normally
-- keeping mode selection here leaves keepAirborne focused on the full lifecycle instead of filling it with mode specific loops
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

-- this is the single cleanup path for a finished interrupted or invalid airborne hold
-- front align is disconnected first so it cannot keep moving the root while force objects are being removed
-- Connected is checked before Disconnect so an already self disconnected connection is safe to pass here
-- LinearVelocity and its attachment are only destroyed when they still have a parent
-- Freefall is enabled again when the humanoid still exists so normal roblox humanoid behavior can resume
-- Airborne and AirborneUntil are cleared after the custom controller objects are gone
-- this order means other combat code does not see Airborne as false while the old force is still active
-- network ownership is only restored when the root still exists and the character belongs to a player
-- npc roots stay server owned because there is no player to restore ownership to
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

	-- self launch and front align temporarily moved physics ownership to the server
	-- after every custom force and connection is gone the player can simulate their own root again
	-- this restores normal movement response instead of leaving the character server owned after the combo
	local player = Players:GetPlayerFromCharacter(character)
	if not player then return end

	root:SetNetworkOwner(player)
end

-- this owns the complete airborne hold lifecycle for one character
-- it finds the humanoid and root again because this function can run inside a spawned task after the original hit returned
-- Freefall is disabled so the humanoid does not switch into its normal falling behavior while custom force controls the root
-- when Airborne is already true this call only moves AirborneUntil forward and returns
-- that refresh path is how later combo hits extend one hold without stacking attachments LinearVelocity objects or cleanup tasks
-- the first call marks the character airborne stores the ending clock time and gives network ownership to the server
-- it creates the temporary force and optionally starts attacker front align
-- it lets the launch rise then ramps into the actual hold
-- root existence is checked after both waiting stages because the character can disappear while either one yields
-- every early failure uses cleanupAirborne so attributes force objects humanoid state and ownership are not left half changed
-- after the hold is active a spawned task waits for the final possibly extended timer runs the selected exit and performs cleanup
-- spawning the wait task lets the damage resolver finish immediately instead of blocking until the whole air combo ends
local function keepAirborne(character: Model, duration: number, options: AirborneOptions?)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = getRoot(character)

	if not humanoid or not root then return end

	-- this runs before the existing hold check on purpose
	-- even a refresh makes sure Freefall is still disabled in case another system tried to enable it during the combo
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Freefall, false)

	-- Airborne true means the first call already owns the force connection and cleanup task
	-- only the ending time is replaced with now plus the new duration
	-- waitForAirborneEnd will read the new value on its next pass and keep the same hold alive longer
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

-- this connects one moves launch data to the longer airborne hold system
-- applyLaunch runs first because the initial velocity has to exist before keepAirborne waits for its peak
-- TargetAirborneDuration belongs to the victim and only starts when the victim was actually launched
-- SelfAirborneDuration belongs to the attacker and can start even when the move has no victim launch
-- each hold starts in its own task because waitForLaunchPeak and the force ramp both yield
-- the victim call has no options because a launched victim only needs the gravity hold
-- the attacker call follows the victim and requests FrontAlign so air combo spacing stays usable
-- didLaunchVictim is returned to the caller because blocked hit rules may care whether target launch really happened
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

-- this chooses the stun duration for one exact combo index
-- StunTime can contain a different value for each hit in the move
-- when that combo slot is nil the normal shared Stun status duration from GameConfig is used
-- keeping the fallback here means blocked and normal hit paths always resolve stun the same way
local function getStunDuration(moveData: GameConfig.Move, combo: number): number
	return moveData.StunTime[combo] or GameConfig.StatusEffects.Stun.Duration
end

-- this sends the victim into the Stunned state through StateRegistry
-- the damage module does not directly set movement speed action locks or state timers
-- those rules stay inside the Stunned state and this function only supplies the duration override for this hit
-- the GameConfig.StatusEffect cast matches the structure expected by the state onEnter data
-- using one helper keeps normal hits and launch on block hits from building different transition tables
local function applyStun(victimState, duration: number)
	victimState:Transition("Stunned", {
		onEnter = {
			Overrides = {
				Duration = duration,
			} :: GameConfig.StatusEffect,
		},
	})
end

-- this resolves a hit after Damage confirmed the victim is currently Blocking
-- resolveBlockedDamage runs first and returns the exact number allowed through the selected block system
-- DamageBlocked fires even when that number is zero so block ui sounds and other server systems still know contact happened
-- clash vfx is sent for both sides from the same confirmed server hit so attacker and victim see matching feedback
-- resolvedDamage is the only amount subtracted from health and the same amount is sent through DamageDealt
-- this keeps health ui combat logs and effects from disagreeing about shield or partial block math
-- most blocked moves stop after that result and do not stun launch or play a normal hit reaction
-- a move with Launch.OnBlock continues into handleAirborne after all block math already finished
-- target airborne duration is added to stun so the victim cannot leave Stunned while the custom air hold is still controlling them
-- the final resolved amount is returned to the original Damage caller
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

	-- the first call attaches the clash result to the victim side
	-- the second call sends the attacker side version using the final true argument expected by the vfx remote
	-- both are fired here so they use the same move combo and server timing
	Remotes.VFX:FireAllClients(victimEntity, "BlockClash", move, combo, true)
	Remotes.VFX:FireAllClients(attackerEntity, "BlockClash", move, combo, true, true)

	victimHumanoid.Health -= resolvedDamage
	CombatSignals.DamageDealt:Fire(victim, nil, move, combo, resolvedDamage)

	local launch = moveData.Launch
	if not launch or not launch.OnBlock then return resolvedDamage end

	handleAirborne(victimEntity, attackerEntity, moveData)

	-- TargetAirborneDuration can be nil so zero is used when the move only launches the attacker
	-- adding the air time to normal combo stun keeps state restrictions active through the complete victim hold
	-- the hit reaction is played here because Launch.OnBlock makes this block act like a real launched impact
	local airborneDuration = moveData.TargetAirborneDuration or 0
	applyStun(victimState, getStunDuration(moveData, combo) + airborneDuration)
	playHitReaction(victimEntity, move)

	return resolvedDamage
end

-- this is the normal non blocking hit path
-- stun is applied first so the victims state already matches the hit before other server listeners react
-- airborne launch starts next because its setup comes from the same confirmed move and combo
-- health is then reduced by the final damage that already passed absorb in Damage
-- DamageDealt fires after the health write and receives that exact same number
-- the combo index decides between the normal hit spark and finisher hit spark
-- the effect still checks its Trigger config before any remote is fired
-- hit reaction plays last because it is visual feedback for a gameplay result that is already complete
-- the damage amount is returned so the public entry can pass the final result back to its caller
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

	-- the last damage entry in the moves Damage array marks the finisher combo hit
	-- every earlier combo index uses HitSpark and the last one uses HitSparkFinisher
	-- effectData is read from config so this module does not hardcode whether that effect should trigger on hit
	local effectName = combo == #moveData.Damage and "HitSparkFinisher" or "HitSpark"
	local effectData = GameConfig.VFX[effectName] :: GameConfig.VFX

	if effectData.Trigger == "OnHit" then
		Remotes.VFX:FireAllClients(victimEntity, effectName, move, combo)
	end

	playHitReaction(victimEntity, move)
	return damage
end

-- this is the only function outside this module is supposed to call
-- HitboxHandler already found contact and the server validator already approved that contact before reaching here
-- victimEntity is the character receiving the hit and attackerEntity is the character that used the move
-- move is only a config key and combo is the index used for that moves damage and stun arrays
-- both entities are validated again because they may have changed between contact validation and this final callback
-- a dead attacker cannot finish a delayed hit so their humanoid health is checked before any victim work
-- the victims state object is required because blocking dead invincible stun and guard break rules all depend on StateRegistry
-- Dead and Invincible stop before absorb is spent or any feedback is fired
-- moveData is read by name from the server GameConfig so a client never supplies its own move table
-- the combo damage must be a number or the call ends without applying a partial broken result
-- absorb is resolved before the blocking branch because it is the outer damage layer in this system
-- after absorb the victim state decides between the blocked resolver and the normal resolver
-- both paths return the amount they actually applied while every gameplay decision stays server sided
function damageHandler.Damage(victimEntity: entity, move: string, combo: number, attackerEntity: entity)
	if not isValidEntity(victimEntity) then return end
	if not isValidEntity(attackerEntity) then return end
	if attackerEntity.humanoid.Health <= 0 then return end

	local victim = victimEntity.character
	local victimState = StateRegistry:Get(victim) :: StateRegistry.State
	if not victimState then return end

	-- these checks happen before move lookup and before ShieldAbsorb is changed
	-- a rejected hit therefore cannot consume shields trigger reactions or send fake combat feedback
	-- Dead uses the registry state while Invincible is a direct state property shared by temporary invulnerability states
	if victimState:IsState("Dead") then return end
	if victimState.Invincible then return end

	local moveData = GameConfig.Moves[move] :: GameConfig.Move
	if not moveData then return end

	local damage = moveData.Damage[combo]
	if type(damage) ~= "number" then return end

	-- applyAbsorb returns a new damage number and that value replaces the original config damage
	-- if absorb covered the whole hit the next path receives zero
	-- if absorb broke the next path only receives overflow
	-- this prevents blocking and absorb from both reducing the same full damage amount
	damage = applyAbsorb(victimEntity, damage)

	if victimState:IsState("Blocking") then
		return resolveBlockedHit(victimEntity, attackerEntity, victimState, move, combo, moveData, damage)
	end

	return resolveNormalHit(victimEntity, attackerEntity, victimState, move, combo, moveData, damage)
end

return damageHandler
