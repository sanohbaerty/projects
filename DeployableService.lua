-- Connected Discord-Github
--[[
	keeps placed mines tied to the character that created them
	one heartbeat handles arming cleanup and proximity checks
	when in game press 1-9 to cycle between items and 0 for the next item
]]

-- used to check owners and find players from their characters
local Players = game:GetService("Players")
-- the mine templates are stored here so the game can share the assets
local ReplicatedStorage = game:GetService("ReplicatedStorage")
-- heartbeat gives the shared update loop its frame time
local RunService = game:GetService("RunService")
-- the combat modules run on the server so clients do not control damage
local ServerScriptService = game:GetService("ServerScriptService")
-- used for world placement and the overlap and raycast checks
local Workspace = game:GetService("Workspace")

-- keep the shared dependency path in one place
local services = ServerScriptService.FPS.Services
-- reuse the weapon visibility checks so cover also blocks mine triggers
local CombatQueryService = require(services.CombatQueryService)
-- reuse the humanoid resolver for limbs and accessory parts
local DamageService = require(services.DamageService)
-- blast damage and falloff stay in the existing explosion service
local ExplosionService = require(services.ExplosionService)

-- scan at most ten times a second instead of querying every frame
local SCAN_INTERVAL = 0.1
-- five minutes is the longest a placed mine can remain active
local MAX_LIFETIME = 300
-- cap proximity range so one mine cannot scan too much of the map
local MAX_TRIGGER_RADIUS = 100
local MAX_ACTIVE = 20 -- limit how many mines one player can keep active
-- keep the blast range inside the supported config bounds
local MAX_BLAST_RADIUS = 10000
-- reject damage values outside the supported config bounds
local MAX_DAMAGE = 100000
-- the upward component rejects walls and slopes that are too steep
local MIN_SURFACE_NORMAL_Y = 0.7
-- leave a small gap so the mine does not intersect its support
local PLACEMENT_GAP = 0.05
-- cast a little past the bottom of the mine to find its support
local SUPPORT_REACH = 0.15
-- orange shows that the arming delay has not finished
local ARMING_COLOR = Color3.fromRGB(255, 170, 0)
-- red shows that the mine can now trigger
local ARMED_COLOR = Color3.fromRGB(255, 0, 0)

-- only templates from this folder can become placed mines
local deployables = ReplicatedStorage.Assets.Deployables
-- records stay in placement order so the oldest can be replaced first
local activeDeployables = {}
-- remember startup so repeated calls cannot connect extra loops
local initialized = false
local elapsed = 0 -- accumulate frame time until another proximity scan is due

-- share the numeric checks so every config field rejects bad numbers
local function isNumberInRange(value, minimum, maximum)
	-- check the type first so math and comparisons only receive numbers
	return type(value) == "number"
		-- nan and infinity cannot be used for distances or deadlines
		and math.isfinite(value)
		and value >= minimum -- include the lower bound in the accepted range
		and value <= maximum -- include the upper bound in the accepted range
end

-- validate every coordinate before creating a placement transform
local function isFinitePosition(position)
	-- typeof identifies the roblox vector before its fields are read
	return typeof(position) == "Vector3"
		and math.isfinite(position.X) -- reject an invalid horizontal coordinate
		-- a valid x does not guarantee a valid height
		and math.isfinite(position.Y)
		-- check the remaining coordinate before allowing placement
		and math.isfinite(position.Z)
end

-- share the owner checks between placement and remote detonation
local function getLivingCharacter(player)
	-- short circuit before calling an instance method on an invalid value
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return
	end

	-- a player who left the server cannot place or detonate mines
	if player.Parent ~= Players then
		return
	end

	-- capture the current life rather than looking up a later respawn
	local character = player.Character
	-- respawning can leave the player without a character for a moment
	if not character then
		return
	end

	-- find the life controller without waiting for a missing child
	local humanoid = character:FindFirstChildWhichIsA("Humanoid")
	-- only living characters can use the service
	if not humanoid or humanoid.Health <= 0 then
		return
	end

	-- return both so callers use the same character and life controller
	return character, humanoid
end

-- check the blast settings before passing them to the damage code
local function isExplosionValid(explosion)
	-- the nested settings must support field lookups
	if type(explosion) ~= "table" then
		return false
	end

	-- blast range must be positive and inside the supported limit
	if not isNumberInRange(explosion.Radius, 0.01, MAX_BLAST_RADIUS) then
		return false
	end

	-- center damage must be a finite positive number
	if not isNumberInRange(explosion.Damage, 0.01, MAX_DAMAGE) then
		return false
	end

	-- allow zero edge damage but never more than the center damage
	return isNumberInRange(explosion.MinimumDamage, 0, explosion.Damage)
end

-- reject bad config before creating a part or replacing an older mine
local function isDeployableDataValid(data)
	-- stop before reading fields from a value that is not a config table
	if type(data) ~= "table" then
		return false
	end

	-- an omitted trigger mode uses proximity detection
	local triggerMode = data.TriggerMode or "Proximity"
	-- other mode names have no matching trigger behavior
	if triggerMode ~= "Proximity" and triggerMode ~= "Remote" then
		return false
	end

	-- the visual must name a template instead of supplying an instance
	if type(data.Visual) ~= "string" or data.Visual == "" then
		return false
	end

	-- zero arms immediately and a negative delay is not allowed
	if not isNumberInRange(data.ArmTime, 0, MAX_LIFETIME) then
		return false
	end

	-- a finite lifetime keeps the expiry deadline valid
	if not isNumberInRange(data.Lifetime, 0, MAX_LIFETIME) then
		return false
	end

	-- the mine needs some usable time after it finishes arming
	if data.Lifetime <= data.ArmTime then
		return false
	end

	-- bound the detection range independently of the explosion radius
	if not isNumberInRange(data.TriggerRadius, 0, MAX_TRIGGER_RADIUS) then
		return false
	end

	-- the shared range check includes zero but detection needs real range
	if data.TriggerRadius == 0 then
		return false
	end

	-- the owner limit must allow at least one mine and stay under the cap
	if not isNumberInRange(data.MaxActive, 1, MAX_ACTIVE) then
		return false
	end

	-- a remainder means the count is fractional rather than a whole mine
	if data.MaxActive % 1 ~= 0 then
		return false
	end

	-- only accept the config if its nested blast settings pass too
	return isExplosionValid(data.Explosion)
end

-- detect character geometry even when the hit part is inside an accessory
local function belongsToCharacter(instance)
	-- start at the hit object before checking its parents
	local ancestor = instance
	-- stop at the world boundary or when the parent chain ends
	while ancestor and ancestor ~= Workspace do
		-- a humanoid in this chain marks the support as character geometry
		if ancestor:FindFirstChildWhichIsA("Humanoid") then
			-- tell placement to reject this character as a support
			return true
		end

		-- move up one level so nested character parts are checked too
		ancestor = ancestor.Parent
	end

	-- no humanoid was found anywhere in the parent chain
	return false
end

-- only accept stable ground that can hold a stationary mine
local function isSurfaceValid(surfaceHit)
	-- the normal and hit object must come from a roblox cast result
	if typeof(surfaceHit) ~= "RaycastResult" then
		return false
	end

	-- keep the exact support found by the placement cast
	local surface = surfaceHit.Instance
	-- support outside the world can no longer hold the mine
	if not surface or not surface:IsDescendantOf(Workspace) then
		return false
	end

	-- water is not solid support even when its surface points upward
	if surfaceHit.Material == Enum.Material.Water then
		return false
	end

	-- the upward normal component rejects walls and steep slopes
	if surfaceHit.Normal.Y < MIN_SURFACE_NORMAL_Y then
		return false
	end

	-- terrain is supported without reading properties meant for parts
	if surface == Workspace.Terrain then
		-- solid terrain passed the material and slope checks
		return true
	end

	-- other supports must be solid anchored parts
	if not surface:IsA("BasePart") or not surface.Anchored or not surface.CanCollide then
		return false
	end

	-- even an anchored character part should not become a mine support
	return not belongsToCharacter(surface)
end

-- build the mine transform and return its optional support together
local function getPlacement(position, template, surfaceHit)
	-- direct placements use the supplied position without a ground cast
	if not surfaceHit then
		-- use the default rotation when there is no surface to align with
		return CFrame.new(position)
	end

	-- stop before calculating a transform from unsuitable ground
	if not isSurfaceValid(surfaceHit) then
		return
	end

	-- the outward normal becomes the local up direction of the mine
	local normal = surfaceHit.Normal
	-- half the height places the bottom above the hit point
	local offset = template.Size.Y * 0.5 + PLACEMENT_GAP
	-- offset along the slope normal instead of straight up in world space
	local placementPosition = surfaceHit.Position + normal * offset
	-- cross gives a unit right axis, the slope limit prevents a zero vector
	local right = Vector3.zAxis:Cross(normal).Unit
	-- use right and up as the local axes and keep the support for cleanup
	return CFrame.fromMatrix(placementPosition, right, normal), surfaceHit.Instance
end

-- keep new mines separated from existing mines belonging to any owner
local function hasClearance(template, position)
	-- use the larger horizontal size as the new mine spacing width
	local width = math.max(template.Size.X, template.Size.Z)
	-- check the ordered list regardless of who owns each mine
	for _, record in ipairs(activeDeployables) do
		-- read the existing visual for its current position and size
		local part = record.part
		-- a removed visual should not block placement while awaiting cleanup
		if not part.Parent then
			continue
		end

		-- account for the size of the existing mine too
		local otherWidth = math.max(part.Size.X, part.Size.Z)
		-- half of each width gives the minimum center spacing
		local clearance = (width + otherWidth) * 0.5
		-- magnitude measures how far apart the two centers are
		if (part.Position - position).Magnitude < clearance then
			-- reject this placement as soon as one mine is too close
			return false
		end
	end

	-- the new position cleared every existing mine
	return true
end

-- configure a separate visual before putting it into the world
local function createPart(template, placement, player)
	-- clone so placing a mine never moves or changes the shared template
	local part = template:Clone()
	-- apply both the calculated position and surface rotation
	part.CFrame = placement
	-- the mine stays fixed and support changes are handled during cleanup
	part.Anchored = true
	part.CanCollide = false -- players should not be blocked by the mine visual
	-- detection uses spatial queries so touch events are unnecessary
	part.CanTouch = false
	-- keep the visual out of normal raycasts and overlap queries
	part.CanQuery = false
	-- start with the unarmed color until the update loop arms it
	part.Color = ARMING_COLOR
	-- replicate ownership without sharing the private server record
	part:SetAttribute("OwnerUserId", player.UserId)
	-- replicate the initial state for anything observing the mine
	part:SetAttribute("Armed", false)
	-- parent last so the configured visual enters the world
	part.Parent = Workspace
	-- give placement the clone so it can check and track it
	return part
end

-- check the placed shape against solid objects before accepting it
local function isObstructed(part, character)
	-- this filter is only used for the initial obstruction check
	local parameters = OverlapParams.new()
	-- listed objects should be ignored rather than treated as blockers
	parameters.FilterType = Enum.RaycastFilterType.Exclude
	-- ignore the owner rig and the new visual during the overlap query
	parameters.FilterDescendantsInstances = { character, part }
	-- use collision state so noncolliding decoration does not block placement
	parameters.RespectCanCollide = true
	-- any returned solid overlap means the placed shape is obstructed
	return #Workspace:GetPartsInPart(part, parameters) > 0
end

-- remove the tracked entry and its visual through the same cleanup path
local function removeDeployable(index)
	-- keep the record before removing its slot from the array
	local record = activeDeployables[index]
	-- an entry that is already missing needs no more cleanup
	if not record then
		return
	end

	-- stop tracking first because destroying the part can notify listeners
	table.remove(activeDeployables, index)
	-- remove the world visual as well as the server record
	record.part:Destroy()
end

-- replace only the oldest owned mines after the new placement passes
local function makeRoom(player, maxActive)
	-- save array positions without changing the list during this scan
	local ownedIndices = {}
	-- placement order makes the first owned entries the oldest ones
	for index, record in ipairs(activeDeployables) do
		-- other owners do not count toward this players allowance
		if record.player == player then
			-- remember this owned entry for removal if the limit requires it
			table.insert(ownedIndices, index)
		end
	end

	-- include the incoming mine when working out how much room is needed
	local removeCount = #ownedIndices - maxActive + 1
	-- remove the selected oldest entries backwards so indices stay valid
	for ownedIndex = removeCount, 1, -1 do
		-- clean up the visual and record at the saved array position
		removeDeployable(ownedIndices[ownedIndex])
	end
end

-- store deadlines and reusable query filters with the placed mine
local function trackDeployable(record, data)
	-- use the same elapsed clock as arming and expiry checks
	local now = os.clock()
	-- save the arming deadline instead of starting a separate delayed task
	record.armAt = now + data.ArmTime
	-- lifetime starts at placement rather than after arming
	record.expireAt = now + data.Lifetime
	-- remember whether updates or a remote request should trigger the mine
	record.triggerMode = data.TriggerMode or "Proximity"
	-- save the validated detection range for later scans
	record.triggerRadius = data.TriggerRadius
	-- copy the settings so later config edits do not change this blast
	record.explosion = table.clone(data.Explosion)
	record.armed = false -- track the visual transition so it only runs once

	-- create one target filter to reuse across this mines scans
	local overlapParameters = OverlapParams.new()
	-- targets come from everything except the listed instances
	overlapParameters.FilterType = Enum.RaycastFilterType.Exclude
	-- exclude the owner rig together with its limbs and accessories
	overlapParameters.FilterDescendantsInstances = { record.character }
	-- keep the filter on the record instead of allocating it each scan
	record.overlapParameters = overlapParameters

	-- direct placements do not need a support filter
	if record.surface then
		-- use a separate filter for the original ground support
		local supportParameters = RaycastParams.new()
		-- only listed support can satisfy this raycast
		supportParameters.FilterType = Enum.RaycastFilterType.Include
		-- nearby objects must not hide the loss of the original support
		supportParameters.FilterDescendantsInstances = { record.surface }
		-- reuse this filter for later ground checks
		record.supportParameters = supportParameters
	end

	-- only part supports have a transform to capture
	if record.surface and record.surface:IsA("BasePart") then
		-- keep the original transform so movement or rotation can be detected
		record.surfaceCFrame = record.surface.CFrame
	end

	-- append last so replacement keeps following placement order
	table.insert(activeDeployables, record)
end

-- remove surface placements that would otherwise be left floating
local function hasSupport(record)
	-- check the same object that supported the initial placement
	local surface = record.surface
	-- direct placements do not opt into ground tracking
	if not surface then
		-- no tracked support means there is no ground check to fail
		return true
	end

	-- a support removed from the world no longer holds the mine
	if not surface:IsDescendantOf(Workspace) then
		return false
	end

	-- a saved transform means this is a part that must not have moved
	if record.surfaceCFrame and surface.CFrame ~= record.surfaceCFrame then
		return false
	end

	-- part supports must remain fixed and solid after placement
	if record.surfaceCFrame and (not surface.Anchored or not surface.CanCollide) then
		return false
	end

	-- use the mine transform to cast toward the ground beneath it
	local part = record.part
	-- cast down its local up axis past the bottom and placement gap
	local direction = -part.CFrame.UpVector * (part.Size.Y * 0.5 + SUPPORT_REACH)
	-- the filtered ray also detects terrain removed below the mine
	local support = Workspace:Raycast(part.Position, direction, record.supportParameters)
	-- convert the optional cast result into a support check result
	return if support then true else false
end

-- centralize cleanup checks before any arming or target detection
local function isRecordValid(record, now)
	-- missing visuals and expired mines should leave the active list
	if not record.part.Parent or now >= record.expireAt then
		return false
	end

	-- leaving or respawning must not carry mines into another life
	if record.player.Parent ~= Players or record.player.Character ~= record.character then
		return false
	end

	-- a dead or removed life controller cannot keep active mines
	if not record.humanoid.Parent or record.humanoid.Health <= 0 then
		return false
	end

	-- only keep the record if its optional ground support still works
	return hasSupport(record)
end

-- apply the armed state once after the deadline has passed
local function armDeployable(record)
	-- skip repeated attribute writes and color changes on later scans
	if record.armed then
		return
	end

	-- remember locally that the arming transition has happened
	record.armed = true
	-- replicate the transition for clients observing the visual
	record.part:SetAttribute("Armed", true)
	record.part.Color = ARMED_COLOR -- red matches the mines new armed state
end

-- keep ownership and team rules out of the target scan loop
local function isFriendlyPlayer(owner, target)
	-- npcs have no player and do not participate in these team checks
	if not target then
		-- let the remaining target checks decide whether this npc can trigger
		return false
	end

	-- the owner must never trigger their own proximity mine
	if target == owner then
		-- treat the owner as friendly regardless of team state
		return true
	end

	-- matching teams only count when both players are nonneutral
	return not owner.Neutral and not target.Neutral and owner.Team == target.Team
end

-- narrow a resolved humanoid down to a living visible enemy in range
local function canTrigger(record, humanoid)
	-- ignore the original owner and dead targets before further checks
	if humanoid == record.humanoid or humanoid.Health <= 0 then
		return false
	end

	-- the model is needed for player lookup and root fallback
	local character = humanoid.Parent
	-- a removed or incorrectly parented humanoid is not a valid target
	if not character or not character:IsA("Model") then
		return false
	end

	-- prefer the assigned root and fall back to the usual root name
	local root = humanoid.RootPart or character:FindFirstChild("HumanoidRootPart")
	-- distance checks need a part with a real world position
	if not root or not root:IsA("BasePart") then
		return false
	end

	-- resolve player characters while leaving npcs without a player
	local player = Players:GetPlayerFromCharacter(character)
	-- reject teammates and the owner before checking distance or cover
	if isFriendlyPlayer(record.player, player) then
		return false
	end

	-- use the mine center for both range and visibility checks
	local position = record.part.Position
	-- a limb can overlap the query while its root is still out of range
	if (root.Position - position).Magnitude > record.triggerRadius then
		return false
	end

	-- use the shared combat check so enemies behind cover do not trigger
	return CombatQueryService:HasLineOfSight(record.character, position, humanoid)
end

-- find one eligible target without checking every limb more than once
local function hasTriggerTarget(record)
	-- collect nearby bounding boxes before doing precise humanoid checks
	local parts = Workspace:GetPartBoundsInRadius(
		record.part.Position, -- center the query on the placed mine
		record.triggerRadius, -- use detection range rather than explosion range
		-- reuse the filter that excludes the owner character
		record.overlapParameters
	)
	-- start fresh each scan so rejected targets can qualify later
	local checkedHumanoids = {}
	-- each result may be a limb an accessory or unrelated map geometry
	for _, part in ipairs(parts) do
		-- let the shared resolver follow the hit hierarchy to its humanoid
		local humanoid = DamageService:ResolveHumanoid(part)
		-- skip world geometry and another limb from an already checked target
		if not humanoid or checkedHumanoids[humanoid] then
			continue
		end

		-- mark before testing so rejected targets are also checked only once
		checkedHumanoids[humanoid] = true
		-- run the health team distance and visibility checks for this target
		if canTrigger(record, humanoid) then
			-- one qualifying humanoid is enough to trigger the mine
			return true
		end
	end

	-- none of the candidates passed all the trigger checks
	return false
end

-- share the remove then explode sequence between both trigger modes
local function explodeDeployable(index)
	-- keep the attacker and settings before removing the list entry
	local record = activeDeployables[index]
	-- capture the blast origin before destroying the visual
	local position = record.part.Position
	-- remove first so damage callbacks cannot trigger this charge again
	removeDeployable(index)
	-- apply the blast using the original attacker and saved settings
	ExplosionService:Explode(record.humanoid, position, record.explosion)
end

-- one shared pass handles cleanup before arming and proximity triggers
local function updateDeployables()
	-- all records in this pass use the same time for deadline checks
	local now = os.clock()
	-- walk backwards so removing an entry does not skip the next record
	for index = #activeDeployables, 1, -1 do
		-- keep the current entry while its state is checked
		local record = activeDeployables[index]
		-- invalid records should be removed even if they are not armed yet
		if not isRecordValid(record, now) then
			-- clean up both the visual and the tracked entry
			removeDeployable(index)
			continue
		end

		-- leave unarmed mines tracked but skip their trigger checks
		if now < record.armAt then
			continue
		end

		-- update the visual once when the arming deadline has passed
		armDeployable(record)
		-- remote charges get cleanup but wait for an explicit detonation call
		if record.triggerMode == "Remote" then
			continue
		end

		-- only proximity mines reach the nearby target scan
		if hasTriggerTarget(record) then
			-- remove the triggered mine and hand damage to the explosion
			-- service
			explodeDeployable(index)
		end
	end
end

-- turn variable frame times into a shared scan interval
local function onHeartbeat(deltaTime)
	-- add the actual frame duration instead of assuming a fixed frame rate
	elapsed += deltaTime
	-- wait until enough time has accumulated for the next scan
	if elapsed < SCAN_INTERVAL then
		return
	end

	elapsed = 0 -- reset so a long frame does not queue several catch-up scans
	updateDeployables() -- process all owners through the same update pass
end

-- keep the public names because the existing weapon code calls them
local DeployableService = {
	-- throws save this number so a later clear can invalidate them
	Revision = 0,
}

-- validate the whole placement before replacing any existing mines
function DeployableService:Spawn(player, position, deployableData, surfaceHit)
	-- capture the living owner so this mine stays tied to the same life
	local character, humanoid = getLivingCharacter(player)
	-- stop if the player cannot currently place a mine
	if not character then
		return
	end

	-- reject invalid math inputs and settings before reading the template
	if not isFinitePosition(position) or not isDeployableDataValid(deployableData) then
		return
	end

	-- look up the named asset without waiting for a missing template
	local template = deployables:FindFirstChild(deployableData.Visual)
	-- placement uses part size and transforms so models are not accepted
	if not template or not template:IsA("BasePart") then
		return
	end

	-- compute the final transform and retain any supporting surface
	local placement, surface = getPlacement(position, template, surfaceHit)
	-- reject bad ground or spacing before creating a world visual
	if not placement or not hasClearance(template, placement.Position) then
		return
	end

	-- create the configured clone for the final shape overlap check
	local part = createPart(template, placement, player)
	-- surface placements also need to fit without intersecting solids
	if surface and isObstructed(part, character) then
		-- discard the rejected clone without removing any existing mine
		part:Destroy()
		return
	end

	-- only replace older mines now that the new placement has passed
	makeRoom(player, deployableData.MaxActive)
	-- store ownership and placement together before adding timing data
	trackDeployable({
		-- keep the owner for disconnect checks and team filtering
		player = player,
		-- remember this life so a respawn does not inherit the mine
		character = character,
		-- retain the original attacker for life checks and blast attribution
		humanoid = humanoid,
		-- keep the world visual for queries state changes and cleanup
		part = part,
		-- remember optional ground support for later stability checks
		surface = surface,
	}, deployableData)
	-- let the caller inspect the accepted placement
	return part
end

-- remote detonation only uses armed charges from the current life
function DeployableService:Detonate(player)
	-- apply the same living owner checks used by placement
	local character = getLivingCharacter(player)
	-- dead or disconnected players cannot request a blast
	if not character then
		return
	end

	local now = os.clock() -- use one timestamp for all charges in this request
	-- walk backwards because successful detonations remove array entries
	for index = #activeDeployables, 1, -1 do
		-- inspect the next tracked charge without changing the list yet
		local record = activeDeployables[index]
		-- skip other owners and charges from a previous life
		if record.player ~= player or record.character ~= character then
			continue
		end

		-- proximity mines cannot be triggered through this request
		if record.triggerMode ~= "Remote" then
			continue
		end

		-- only existing charges inside their armed lifetime can detonate
		if not record.part.Parent or now < record.armAt or now >= record.expireAt then
			continue
		end

		-- remove and explode each eligible charge through the shared helper
		explodeDeployable(index)
	end
end

-- round cleanup removes placed mines and invalidates throws in flight
function DeployableService:Clear()
	-- in-flight throws compare their saved revision before placing a mine
	self.Revision += 1
	-- remove backwards so the shifting array does not skip entries
	for index = #activeDeployables, 1, -1 do
		-- destroy each visual and remove its tracked record
		removeDeployable(index)
	end
end

-- start updates explicitly instead of running a loop when required
function DeployableService.onReady()
	-- repeated startup calls must not add another heartbeat connection
	if initialized then
		return
	end

	initialized = true -- set the guard before attaching the callback
	-- heartbeat passes frame duration to the shared scan accumulator
	RunService.Heartbeat:Connect(onHeartbeat)
end

-- export the service while the active records stay private
return DeployableService
