-- Connected Discord-Github
-- when in game, press 1-9 to cycle between items and 0 to go to the next item

-- Players is used to validate owners and resolve characters back to players
local Players = game:GetService("Players")
-- shared templates are read from ReplicatedStorage
local ReplicatedStorage = game:GetService("ReplicatedStorage")
-- Heartbeat supplies elapsed frame time for the shared update loop
local RunService = game:GetService("RunService")
-- the combat modules stay in the server service folder
local ServerScriptService = game:GetService("ServerScriptService")

-- use one shared path for the combat dependencies
local Services = ServerScriptService.FPS.Services

-- reuse the combat visibility check for targets behind cover
local CombatQueryService = require(Services.CombatQueryService)
-- resolve hit parts through the same humanoid lookup used by weapons
local DamageService = require(Services.DamageService)
-- explosion falloff and damage stay owned by the explosion service
local ExplosionService = require(Services.ExplosionService)

-- only named templates in this folder can become placed mines
local deployables = ReplicatedStorage.Assets.Deployables
-- one ordered list holds the live records for all owners
local activeDeployables = {}
-- this prevents a second startup call from connecting another loop
local initialized = false
local elapsed = 0 -- frame time accumulates here between proximity scans

-- callers receive this table rather than the private record list
local DeployableService = {
	Revision = 0, -- throws capture this value to detect a later clear
}

-- index identifies the record in the ordered active list
local function removeDeployable(index)
	-- keep the record reference while the array may change
	local record = activeDeployables[index]
	if not record then -- an already removed record needs no further cleanup
		return
	end

	-- a record can be cleaned up even if its visual is missing
	if record.Part then
		-- remove the world object as well as its tracked record
		record.Part:Destroy()
	end

	-- later array entries shift left, callers must account for this
	table.remove(activeDeployables, index)
end

--[[
	placement is checked before an older mine is replaced
	a rejected throw should not remove something the player already placed
]]
-- the colon call receives the service as self, placement inputs follow it
function DeployableService:Spawn(player, position, deployableData, surfaceHit)
	-- short circuit before IsA when the caller is not a Roblox instance
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return
	end
	-- a player who already left cannot create another mine
	if player.Parent ~= Players then
		return
	end

	-- capture this life so later respawns do not inherit its mines
	local character = player.Character
	-- the owner may be between characters during a respawn
	if not character then
		return
	end

	-- look up the life controller without waiting on a missing character part
	local humanoid = character:FindFirstChildWhichIsA("Humanoid")
	-- only a living character can place or detonate a mine
	if not humanoid or humanoid.Health <= 0 then
		return
	end

	-- validate the Roblox vector type before reading its coordinates
	if typeof(position) ~= "Vector3" then
		return
	end
	-- reject NaN or infinity before doing placement math
	if not math.isfinite(position.X) then
		return
	end
	-- the height must be finite too, a valid X does not guarantee this
	if not math.isfinite(position.Y) then
		return
	end
	-- validate the final coordinate before constructing a CFrame
	if not math.isfinite(position.Z) then
		return
	end

	-- field lookups below require a configuration table
	if type(deployableData) ~= "table" then
		return
	end

	-- a missing mode uses proximity, the next guard checks the result
	local triggerMode = deployableData.TriggerMode or "Proximity"
	-- unknown modes would have no matching trigger behavior
	if triggerMode ~= "Proximity" and triggerMode ~= "Remote" then
		return
	end

	-- the visual is a template name, not a supplied instance
	local visual = deployableData.Visual
	-- seconds after placement before the mine may activate
	local armTime = deployableData.ArmTime
	-- seconds after placement before the record expires
	local lifetime = deployableData.Lifetime
	-- this controls proximity detection, separate from blast radius
	local triggerRadius = deployableData.TriggerRadius
	-- the placing owner is checked against this active count limit
	local maxActive = deployableData.MaxActive
	-- the explosion service receives this nested configuration
	local explosion = deployableData.Explosion

	-- template lookup needs a nonempty name
	if type(visual) ~= "string" or visual == "" then
		return
	end

	-- check the type before calling numeric validation
	if type(armTime) ~= "number" then
		return
	end
	-- zero allows immediate arming, negative delays are invalid
	if not math.isfinite(armTime) or armTime < 0 then
		return
	end

	-- a deadline cannot be formed from a nonnumeric lifetime
	if type(lifetime) ~= "number" then
		return
	end
	-- leave time after arming and cap the lifetime at five minutes
	if not math.isfinite(lifetime) or lifetime <= armTime or lifetime > 300 then
		return
	end

	-- radius validation must run on a number
	if type(triggerRadius) ~= "number" then
		return
	end
	-- bound the detection region to avoid excessively large overlap scans
	if not math.isfinite(triggerRadius) or triggerRadius <= 0 or triggerRadius > 100 then
		return
	end

	-- the count comparison needs a numeric limit
	if type(maxActive) ~= "number" then
		return
	end
	-- an infinite limit would defeat the active count bound
	if not math.isfinite(maxActive) then
		return
	end
	-- the remainder check rejects fractional counts, at most twenty are allowed
	if maxActive <= 0 or maxActive > 20 or maxActive % 1 ~= 0 then
		return
	end

	-- validate the nested settings before reading their fields
	if type(explosion) ~= "table" then
		return
	end

	-- blast range is validated independently of detection range
	local radius = explosion.Radius
	-- the center damage is the upper end of the falloff
	local damage = explosion.Damage
	-- this is the configured lower end of the blast falloff
	local minimumDamage = explosion.MinimumDamage

	-- reject a nonnumeric blast range before comparisons
	if type(radius) ~= "number" then
		return
	end
	-- NaN can escape ordinary range comparisons
	if not math.isfinite(radius) then
		return
	end
	-- preserve the supported blast range used by this service
	if radius < 0.01 or radius > 10000 then
		return
	end

	-- damage must support the explosion arithmetic
	if type(damage) ~= "number" then
		return
	end
	-- an invalid numeric value must not reach the damage service
	if not math.isfinite(damage) then
		return
	end
	-- bound the configured damage to the supported range
	if damage < 0.01 or damage > 100000 then
		return
	end

	-- the falloff floor must also be numeric
	if type(minimumDamage) ~= "number" then
		return
	end
	-- validate the floor separately from center damage
	if not math.isfinite(minimumDamage) then
		return
	end
	-- zero edge damage is allowed, negative damage is not
	if minimumDamage < 0 or minimumDamage > 100000 then
		return
	end
	-- the falloff floor cannot exceed the center damage
	if minimumDamage > damage then
		return
	end

	-- a missing template is rejected instead of yielding for an asset
	local template = deployables:FindFirstChild(visual)
	-- the placement code uses BasePart size and transform properties
	if not template or not template:IsA("BasePart") then
		return
	end

	-- use a position with default rotation when no surface hit is supplied
	local placement = CFrame.new(position)
	-- keep the support reference for later movement and removal checks
	local surface

	-- surface alignment is optional for callers supplying a direct position
	if surfaceHit ~= nil then
		-- surface fields must come from a real Roblox cast result
		if typeof(surfaceHit) ~= "RaycastResult" then
			return
		end
		-- save the exact object that the placement cast hit
		surface = surfaceHit.Instance
		-- support that already left the world cannot hold the mine
		if not surface or not surface:IsDescendantOf(workspace) then
			return
		end
		-- the normal Y cutoff rejects steep slopes and walls, water is rejected
		-- too
		if surfaceHit.Material == Enum.Material.Water or surfaceHit.Normal.Y < 0.7 then
			return
		end
		if
			-- terrain is supported without BasePart properties
			surface ~= workspace.Terrain
			-- other surfaces must be solid parts that will stay in place
			and (not surface:IsA("BasePart") or not surface.Anchored or not surface.CanCollide)
		then
			return
		end

		-- start at the hit object to catch nested character geometry
		local ancestor = surface
		-- walk upward until the world boundary or the end of the hierarchy
		while ancestor and ancestor ~= workspace do
			-- a humanoid in this chain means the support belongs to a character
			if ancestor:FindFirstChildWhichIsA("Humanoid") then
				return
			end
			-- advance one level so the search cannot stay on the same object
			ancestor = ancestor.Parent
		end

		-- the outward surface normal becomes the mine up direction
		local normal = surfaceHit.Normal
		-- half the height plus a small gap places the bottom above the surface
		position = surfaceHit.Position + normal * (template.Size.Y * 0.5 + 0.05)

		-- cross gives a perpendicular right axis, Unit normalizes its length
		local right = Vector3.zAxis:Cross(normal).Unit
		-- build the transform from position, right and up, the third axis is
		-- derived
		placement = CFrame.fromMatrix(position, right, normal)
	end

	-- count only this owner before deciding whether to replace an older mine
	local activeCount = 0
	-- array length bounds the scan of existing records
	for index = 1, #activeDeployables do
		-- keep the record reference while the array may change
		local record = activeDeployables[index]
		-- other owners must not consume this player placement allowance
		if record.Player == player then
			activeCount += 1 -- count one record belonging to the placing player
		end
	end

	-- clearance applies to every placed mine regardless of owner
	for _, record in activeDeployables do
		-- half the sum of the larger horizontal sizes gives a spacing threshold
		local clearance = (
			math.max(template.Size.X, template.Size.Z)
			+ math.max(record.Part.Size.X, record.Part.Size.Z)
		) * 0.5

		-- Magnitude measures center distance, reject placements inside the
		-- spacing
		if record.Part.Parent and (record.Part.Position - position).Magnitude < clearance then
			return
		end
	end

	-- each placement needs its own part rather than moving the template
	local part = template:Clone()
	-- apply both the computed position and surface orientation
	part.CFrame = placement
	-- placement is fixed, the support check removes it if the floor changes
	part.Anchored = true

	-- players should not physically collide with the mine visual
	part.CanCollide = false
	-- the service uses explicit queries instead of touch events
	part.CanTouch = false
	-- other spatial queries should not target the mine visual
	part.CanQuery = false
	-- orange identifies the delay before the mine is armed
	part.Color = Color3.fromRGB(255, 170, 0)
	-- replicate ownership without exposing the private server record
	part:SetAttribute("OwnerUserId", player.UserId)
	-- the initial replicated state matches the arming delay
	part:SetAttribute("Armed", false)
	-- parent after setup so the configured part enters the world
	part.Parent = workspace

	-- support-specific checks only apply when placement provided a hit
	if surface then
		-- use a dedicated filter for the initial placement overlap
		local params = OverlapParams.new()
		-- the listed instances will be ignored by this query
		params.FilterType = Enum.RaycastFilterType.Exclude

		-- exclude the owner rig and the new mine from obstruction checks
		params.FilterDescendantsInstances = { character, part }
		-- test physical obstructions rather than noncolliding decoration
		params.RespectCanCollide = true
		-- query the placed shape, any returned solid part means overlap
		if #workspace:GetPartsInPart(part, params) > 0 then
			part:Destroy() -- discard the rejected clone before returning
			return
		end
	end

	-- make room only after the new placement has passed validation
	while activeCount >= maxActive do
		-- records are appended in order, the first owned record is the oldest
		for index, record in activeDeployables do
			-- skip mines belonging to another owner
			if record.Player ~= player then
				continue
			end
			-- remove both the part and its entry from the active list
			removeDeployable(index)
			-- keep the count aligned with the owned record just removed
			activeCount -= 1
			break
		end
	end

	-- all deadlines use this same monotonic clock within the server
	local now = os.clock()
	-- append the record so later replacement follows placement order
	table.insert(activeDeployables, {
		Player = player, -- keep the owner for leaving checks and team filtering
		-- retain this life rather than reading a replacement character later
		Character = character,
		-- use the original attacker for damage and life checks
		Humanoid = humanoid,
		Part = part, -- store the world object for position queries and cleanup
		Surface = surface, -- retain the support object for the next update

		-- save a part transform when available, terrain has no CFrame
		SurfaceCFrame = surface and surface ~= workspace.Terrain and surface.CFrame or nil,

		-- store the arming deadline rather than starting another task
		ArmAt = now + armTime,
		-- expiry is measured from placement, not from arming
		ExpireAt = now + lifetime,
		-- the update loop uses this to separate remote and proximity charges
		TriggerMode = triggerMode,
		-- save the validated range for later target checks
		TriggerRadius = triggerRadius,

		-- a shallow copy preserves these numeric settings if the config is
		-- edited
		Explosion = table.clone(explosion),
		-- track the one-time transition separately from replicated attributes
		Armed = false,
	})

	-- return the created instance so the caller can inspect the placement
	return part
end

--[[
	remote detonation only uses charges from the current character
	charges left by a previous life cannot be detonated after respawning
]]
-- the owner is supplied by the server weapon behavior
function DeployableService:Detonate(player)
	-- reject invalid callers and players no longer in this server
	if typeof(player) ~= "Instance" or not player:IsA("Player") or player.Parent ~= Players then
		return
	end

	-- capture this life so later respawns do not inherit its mines
	local character = player.Character
	-- short circuit when a respawn has temporarily removed the character
	local humanoid = character and character:FindFirstChildWhichIsA("Humanoid")
	-- only a living character can place or detonate a mine
	if not humanoid or humanoid.Health <= 0 then
		return
	end

	-- all deadlines use this same monotonic clock within the server
	local now = os.clock()

	-- walk backward so table removal cannot skip unvisited records
	for index = #activeDeployables, 1, -1 do
		-- keep the record reference while the array may change
		local record = activeDeployables[index]
		if
			-- remote detonation must belong to the requesting owner
			record.Player ~= player
			-- a respawn does not inherit a previous life remote charges
			or record.Character ~= character
			-- proximity mines cannot be detonated through this path
			or record.TriggerMode ~= "Remote"
		then
			continue
		end
		-- the charge must still exist and be inside its armed lifetime
		if not record.Part.Parent or now < record.ArmAt or now >= record.ExpireAt then
			continue
		end

		-- capture the blast origin before destroying the part
		local position = record.Part.Position

		-- remove both the part and its entry from the active list
		removeDeployable(index)
		-- the shared service applies damage using the captured blast settings
		ExplosionService:Explode(humanoid, position, record.Explosion)
	end
end

--[[
	the revision also invalidates projectile throws that are still in flight
	clearing placed parts alone would let those throws place mines afterward
]]
-- round cleanup calls this to invalidate and remove existing placements
function DeployableService:Clear()
	-- in-flight throws compare their saved revision before placing
	self.Revision += 1
	-- walk backward so table removal cannot skip unvisited records
	for index = #activeDeployables, 1, -1 do
		-- remove both the part and its entry from the active list
		removeDeployable(index)
	end
end

-- this private pass handles cleanup before checking possible triggers
local function updateDeployables()
	-- all deadlines use this same monotonic clock within the server
	local now = os.clock()

	-- walk backward so table removal cannot skip unvisited records
	for index = #activeDeployables, 1, -1 do
		-- keep the record reference while the array may change
		local record = activeDeployables[index]

		-- a removed world object must not leave a searchable record
		if not record.Part or not record.Part.Parent then
			-- remove both the part and its entry from the active list
			removeDeployable(index)
			continue
		end
		-- clean up mines whose owner has left the server
		if record.Player.Parent ~= Players then
			-- remove both the part and its entry from the active list
			removeDeployable(index)
			continue
		end

		-- a different character instance means a different life
		if record.Player.Character ~= record.Character then
			-- remove both the part and its entry from the active list
			removeDeployable(index)
			continue
		end
		-- dead or removed humanoids cannot keep active mines
		if not record.Humanoid or not record.Humanoid.Parent or record.Humanoid.Health <= 0 then
			-- remove both the part and its entry from the active list
			removeDeployable(index)
			continue
		end

		-- skip support tracking for direct placements without a surface hit
		if record.Surface then
			if
				-- support removed from the world invalidates the placement
				not record.Surface:IsDescendantOf(workspace)
				-- only part supports have a saved transform to compare
				or record.SurfaceCFrame
					and (
						-- an unanchored floor is no longer stable support
						not record.Surface.Anchored
						-- a floor that stopped colliding should not hold the
						-- mine
						or not record.Surface.CanCollide
						-- detect a moved or rotated support against its
						-- original transform
						or record.Surface.CFrame ~= record.SurfaceCFrame
					)
			then
				-- remove both the part and its entry from the active list
				removeDeployable(index)
				continue
			end

			-- use a separate filter for checking the original support
			local supportParams = RaycastParams.new()
			-- only the listed support may satisfy the ground check
			supportParams.FilterType = Enum.RaycastFilterType.Include
			-- nearby geometry must not hide the loss of the original support
			supportParams.FilterDescendantsInstances = { record.Surface }

			-- cast below the mine to confirm its support still exists there
			local support = workspace:Raycast(
				record.Part.Position,
				-record.Part.CFrame.UpVector * (record.Part.Size.Y * 0.5 + 0.15),
				supportParams
			)
			-- a missing hit means the mine would be left floating
			if not support then
				-- remove both the part and its entry from the active list
				removeDeployable(index)
				continue
			end
		end

		-- remove expired mines before arming or scanning for targets
		if now >= record.ExpireAt then
			-- remove both the part and its entry from the active list
			removeDeployable(index)
			continue
		end
		-- unarmed mines still receive cleanup but skip target detection
		if now < record.ArmAt then
			continue
		end

		-- run the visual transition once rather than on every scan
		if not record.Armed then
			-- the server record remembers that the transition happened
			record.Armed = true
			-- replicate the armed state to observers
			record.Part:SetAttribute("Armed", true)
			-- red shows that the charge is ready
			record.Part.Color = Color3.fromRGB(255, 0, 0)
		end

		-- remote charges need cleanup but no proximity scan
		if record.TriggerMode == "Remote" then
			continue
		end

		-- configure the broad target search for this mine
		local overlapParameters = OverlapParams.new()
		-- the owner character is excluded from the candidate parts
		overlapParameters.FilterType = Enum.RaycastFilterType.Exclude
		-- excluding the model also excludes its limbs and accessories
		overlapParameters.FilterDescendantsInstances = { record.Character }

		-- collect bounding-box candidates before the more precise target checks
		local parts = workspace:GetPartBoundsInRadius(
			record.Part.Position,
			record.TriggerRadius,
			overlapParameters
		)
		-- deduplicate limbs per scan without suppressing later scans
		local checkedHumanoids = {}

		-- inspect candidates until one valid target triggers the mine
		for partIndex = 1, #parts do
			-- a candidate may be a limb, accessory or unrelated world geometry
			local hitPart = parts[partIndex]
			-- the shared resolver finds a valid humanoid from the hit hierarchy
			local targetHumanoid = DamageService:ResolveHumanoid(hitPart)

			-- world geometry is not a damageable target
			if not targetHumanoid then
				continue
			end
			-- dead targets must not consume a proximity mine
			if targetHumanoid.Health <= 0 then
				continue
			end

			-- skip another limb from a humanoid already checked this pass
			if checkedHumanoids[targetHumanoid] then
				continue
			end
			-- mark before further checks so rejected targets are also
			-- deduplicated
			checkedHumanoids[targetHumanoid] = true

			-- keep an explicit self check in addition to the overlap exclusion
			if targetHumanoid == record.Humanoid then
				continue
			end

			-- the model is needed for player lookup and root fallback
			local targetCharacter = targetHumanoid.Parent
			-- reject a removed or unexpectedly parented humanoid
			if not targetCharacter or not targetCharacter:IsA("Model") then
				continue
			end

			-- prefer the root associated with the humanoid
			local targetRoot = targetHumanoid.RootPart
				-- fall back to the conventional root name if needed
				or targetCharacter:FindFirstChild("HumanoidRootPart")
			-- distance checks require an actual positioned part
			if not targetRoot or not targetRoot:IsA("BasePart") then
				continue
			end

			-- NPC characters return nil and do not use player team checks
			local targetPlayer = Players:GetPlayerFromCharacter(targetCharacter)
			-- apply player ownership and team rules only to player characters
			if targetPlayer then
				-- the owner must not trigger their own mine
				if targetPlayer == record.Player then
					continue
				end

				-- compare teams only when both players participate in teams
				if not record.Player.Neutral and not targetPlayer.Neutral then
					-- a teammate is not an eligible proximity trigger
					if record.Player.Team == targetPlayer.Team then
						continue
					end
				end
			end

			-- root distance tightens the broad bounds query to the trigger
			-- radius
			local distance = (targetRoot.Position - record.Part.Position).Magnitude
			-- a large limb inside the query does not qualify a distant root
			if distance > record.TriggerRadius then
				continue
			end

			-- reject targets behind cover through the shared visibility service
			if not CombatQueryService:HasLineOfSight(
				record.Character,
				record.Part.Position,
				targetHumanoid
			) then
				continue
			end

			-- keep the position after the mine part is destroyed
			local explosionPosition = record.Part.Position
			-- remove both the part and its entry from the active list
			removeDeployable(index)
			-- resolve the blast with the original owner humanoid after removing
			-- the mine
			ExplosionService:Explode(record.Humanoid, explosionPosition, record.Explosion)

			break
		end
	end
end

-- startup explicitly connects updates rather than running on require
function DeployableService.onReady()
	-- a repeated startup call must not create another heartbeat listener
	if initialized then
		return
	end
	-- set the guard before connecting the shared update callback
	initialized = true

	-- deltaTime is frame duration in seconds, it drives the scan accumulator
	RunService.Heartbeat:Connect(function(deltaTime)
		-- accumulate elapsed time instead of assuming a fixed frame rate
		elapsed += deltaTime

		if elapsed < 0.1 then -- wait at least a tenth of a second between scans
			return
		end
		-- reset after a scan interval, long frames do not queue catch-up scans
		elapsed = 0
		-- process all live records through one shared update pass
		updateDeployables()
	end)
end

-- export the public methods while keeping active records private
return DeployableService
