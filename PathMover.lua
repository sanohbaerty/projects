-- Connected Discord-GitHub
-- this module owns the pathfinding part of my npc movement system
-- movementcontroller sends one move request in and this handles path creation waypoint travel jumping failure checks and cleanup
-- directmover still owns the actual humanoid moveto call so this file can stay focused on paths instead of mixing every movement job together
-- defaultagent gives every npc a working base setup while npc definitions and one off requests can override only what they need
-- the request table also carries callbacks and a token check so an old path cant keep controlling an npc after a newer decision replaces it

-- btw the comments have no indent cuz i didnt write them on github i wrote them somewhere else and that kinda messed up the comments

local ServerScriptService = game:GetService("ServerScriptService")
local PathfindingService = game:GetService("PathfindingService")
local RunService = game:GetService("RunService")
local ServerModules = ServerScriptService.Server
local AIModules = ServerModules.AdvancedNPCAI
local MovementModules = AIModules.Movement
local DirectMover = require(MovementModules.DirectMover)
local DefaultAgent = require(script.DefaultAgent)
local PathMover = {}
-- these numbers control when a waypoint counts as reached and when the npc is considered stuck
-- the first waypoint gets a wider skip distance because pathfinding usually places it almost on top of the npc
-- jump cooldown and same waypoint checks stop one bad jump node from making the humanoid spam its jump state
-- stuck checks use real movement over time instead of trusting movetofinished by itself
local WAYPOINT_REACHED_DISTANCE = 2.5
local FIRST_WAYPOINT_SKIP_DISTANCE = 3
local SAME_WAYPOINT_DISTANCE = 1.25
local MIN_JUMP_INTERVAL = 0.85
local STUCK_CHECK_RATE = 0.5
local STUCK_TIMEOUT = 2.5
local STUCK_MIN_PROGRESS = 0.75
-- destination projection starts above the requested point and casts far enough down to catch uneven terrain
-- noncollidable hits get skipped and added to the ignore list so decoration cant steal the ground result
-- the skip distance moves the next ray origin past the surface that was just rejected
-- the loop cap makes sure a pile of ignored parts can never turn this into an endless cast
local GROUND_PROJECT_UP = 14
local GROUND_PROJECT_DOWN = 80
local GROUND_PROJECT_SKIP_DISTANCE = 0.08
local MAX_GROUND_RAYCAST_SKIPS = 8
-- grounded checks use short rays around the whole character footprint instead of checking floormaterial once
-- this catches ledges where the root is hanging past an edge but part of the rig still has valid ground
-- normal y rejects walls and steep side faces so touching them doesnt count as standing on them
local GROUNDED_RAY_START_HEIGHT = 0.35
local GROUNDED_RAY_DISTANCE = 0.9
local GROUNDED_MIN_NORMAL_Y = 0.55
-- if the exact destination has no valid path these radiuses build nearby fallback targets
-- every candidate is projected onto ground first and duplicates are removed before pathfinding gets called
-- the raw destination stays first so fallback positions only change the goal when they have to
local FALLBACK_RADIUS_STEPS = {4, 8, 12}
local CANDIDATE_DUPLICATE_DISTANCE = 1.25
local SHOW_PATH_DEBUG = false
local PATH_DEBUG_LIFETIME = 8
local PATH_DEBUG_FOLDER_NAME = "NPCPathDebug"
-- movement settings come from a few layers on purpose
-- request agent params have top priority then the npc agent setup then path settings then the shared default agent
-- this lets one chase request change a value without copying the entire npc definition
-- canjump is also forced off when the main movement definition says the npc should never jump
local function getMovementDefinition(moveData)
	local definition = moveData.Definition
	return definition and definition.Movement or {}
end
local function resolveAgentValue(agentParams, agentDefinition, pathDefinition, valueName, fallback)
-- this check asks whether the request table has this setting directly
-- nil means missing while false and zero still count as real values so they must be returned
	if agentParams[valueName] ~= nil then
		return agentParams[valueName]
	end
-- if the request had nothing the npc agent definition gets the next chance
-- returning here stops the rest of the priority chain as soon as this layer has a value
	if agentDefinition[valueName] ~= nil then
		return agentDefinition[valueName]
	end
-- pathdefinition is checked after agentdefinition to support path specific overrides
-- it uses the same nil rule so a false setting never gets mistaken for no setting
	if pathDefinition[valueName] ~= nil then
		return pathDefinition[valueName]
	end
-- defaultagent supplies the normal shared value when this npc did not customize it
-- fallback is only reached when every table above left the value completely unset
	if DefaultAgent[valueName] ~= nil then
		return DefaultAgent[valueName]
	end
	return fallback
end
local function getAgentParams(moveData)
-- agentparams is the one off table attached to this exact move request
-- using an empty table makes every field lookup safe when the caller passed nothing
	local agentParams = moveData.AgentParams or {}
	local movementDefinition = getMovementDefinition(moveData)
	local agentDefinition = movementDefinition.Agent or {}
	local pathDefinition = movementDefinition.Pathfinding or {}
-- agentcanjump stores the resolved boolean before the main movement switch is applied
-- the final true is the raw fallback used only when every config layer had nil
	local agentCanJump = resolveAgentValue(agentParams, agentDefinition, pathDefinition, "AgentCanJump", true)
-- canjump false is the master rule and it is allowed to override a lower agentcanjump true
-- changing the local means the table returned below matches what the npc is really allowed to do
	if movementDefinition.CanJump == false then
		agentCanJump = false
	end
-- this return table has the exact keys roblox createpath expects
-- every field runs through the same priority function but asks for its own name and fallback
	return {
		AgentRadius = resolveAgentValue(agentParams, agentDefinition, pathDefinition, "AgentRadius", 2),
		AgentHeight = resolveAgentValue(agentParams, agentDefinition, pathDefinition, "AgentHeight", 5),
		AgentCanJump = agentCanJump,
		AgentCanClimb = resolveAgentValue(agentParams, agentDefinition, pathDefinition, "AgentCanClimb", false),
		WaypointSpacing = resolveAgentValue(agentParams, agentDefinition, pathDefinition, "WaypointSpacing", 4),
		Costs = resolveAgentValue(agentParams, agentDefinition, pathDefinition, "Costs", {}),
	}
end
-- finish is the one exit point back to movementcontroller
-- cancellation is asked through a callback because this module doesnt own the controllers movement token
-- that keeps pathmover reusable without reaching inside another object to read its private state
local function finish(moveData, result)
	if not moveData.OnFinished then return end
	moveData.OnFinished(result)
end
local function isCancelled(moveData)
-- shouldcancel is a callback into movementcontroller and it may not exist for path only checks
-- double equals true means only a real true result cancels instead of any random truthy value
	if not moveData.ShouldCancel then return false end
	return moveData.ShouldCancel() == true
end
-- debug logs include the requester and token so two npc systems cant make their movement messages look identical
-- logging is fully gated by the request which keeps live servers quiet unless i am tracking one movement problem
local function debugPath(moveData, ...)
	if not moveData.DebugMovement then return end
	print(
		"[AdvancedNPCAI PathMover]",
		"Requester:", moveData.Requester or "Unknown",
		"Token:", tostring(moveData.Token or "None"),
		...
	)
end
-- raycast params always exclude the npc and any caller supplied targets
-- water is ignored because this movement setup treats solid walkable geometry as ground
-- a fresh params object is used when the ignored list changes during multi hit projection
local function getRaycastParams(ignoreInstances)
-- raycastparamsnew creates the roblox filter object used by workspace raycast
-- this local gets returned after all filter behavior is set on it
	local raycastParams = RaycastParams.new()
-- filterdescendantsinstances is the list of models and parts the ray should pass through
-- descendants are included so ignoring one npc model also ignores every limb and accessory inside it
	raycastParams.FilterDescendantsInstances = ignoreInstances or {}
-- exclude tells the ray to skip that list instead of only hitting that list
-- ignorewater also stops terrain water cells from being treated like solid walking ground
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.IgnoreWater = true
	return raycastParams
end
-- terrain is always a usable cast result since it does not have the basepart collision properties
-- normal parts only count when they can collide so effects invisible blockers and path decorations get ignored
-- keeping this rule in one function makes projection and grounded checks agree on what ground means
local function isGroundResult(raycastResult)
	if not raycastResult then return false end
	if raycastResult.Instance == workspace.Terrain then return true end
	if not raycastResult.Instance:IsA("BasePart") then return false end
	return raycastResult.Instance.CanCollide
end
-- every cast that needs extra ignores gets its own table
-- if i reused the callers table then one rejected decoration could stay ignored by a completely different path request
-- copying keeps those temporary skips local to the projection thats doing them
local function copyIgnoreInstances(ignoreInstances)
	local copied = {}
-- this for loop reads the ignore array one entry at a time
-- i is the current array index and instance is the roblox object stored at that index
	for i, instance in ignoreInstances or {} do
-- tableinsert appends the same object reference to copied without cloning the actual instance
-- the new table can now change without changing the callers original ignore table
		table.insert(copied, instance)
	end
	return copied
end
-- this takes any requested point and finds the walkable surface under it
-- each rejected hit is added to a copied ignore table so the callers original table never gets mutated
-- returning the original point when nothing solid is found lets pathfinding make the final decision instead of inventing a height
-- direction is rebuilt after every skip so the ray always ends at the same lower target
local function projectToGround(position, ignoreInstances)
-- typeof checks for the roblox vector3 datatype before any position math happens
-- anything else returns nil so subtracting or reading magnitude can never crash on bad input
	if typeof(position) ~= "Vector3" then return nil end
-- ignored is a private copy because rejected ray hits will be added during this search
-- keeping those additions private stops one projection from changing later path requests
	local ignored = copyIgnoreInstances(ignoreInstances)
-- origin is the requested position moved fourteen studs upward only on the y axis
-- starting above catches raised terrain and avoids beginning the ray inside the floor
	local origin = position + Vector3.new(0, GROUND_PROJECT_UP, 0)
-- target is the requested position moved eighty studs down and marks the bottom of the search
-- origin and target stay as world positions while direction below becomes the vector between them
	local target = position - Vector3.new(0, GROUND_PROJECT_DOWN, 0)
-- raycast needs a direction vector instead of an ending position
-- target minus origin gives both the downward heading and the full distance to cast
	local direction = target - origin
-- this numeric for loop can repeat no more than max ground raycast skips times
-- i begins at one and increases by one after each rejected hit until the cap is reached
	for i = 1, MAX_GROUND_RAYCAST_SKIPS do
-- directionmagnitude is the remaining ray length measured in studs
-- at zero point zero five or less there is no meaningful distance left so the original point is returned
		if direction.Magnitude <= 0.05 then return position end
-- result stores the first raycast hit or nil when the ray reaches its end without touching anything
-- the call uses the current origin remaining direction and a filter containing every rejected object
		local result = workspace:Raycast(origin, direction, getRaycastParams(ignored))
-- nil means there is no surface left in the vertical search
-- returning position leaves the original goal intact and lets pathfinding decide whether it can use it
		if not result then return position end
-- isgroundresult checks whether the hit was terrain or a collidable basepart
-- passing this check means resultposition is a real floor point and can be returned
		if isGroundResult(result) then
			return result.Position
		end
-- a non ground hit gets added to ignored so the next ray can pass through it
-- this is how stacked effects and noncollidable decoration are skipped one layer at a time
		table.insert(ignored, result.Instance)
-- directionunit keeps the ray heading but makes its length exactly one stud
-- multiplying by the tiny skip distance moves origin just beyond the surface that was rejected
		origin = result.Position + direction.Unit * GROUND_PROJECT_SKIP_DISTANCE
-- the bottom target never moved so subtracting the new origin rebuilds a shorter remaining direction
-- the next loop pass continues from that spot instead of restarting the full ray
		direction = target - origin
	end
	return position
end
-- all fallback math is flattened onto xz because choosing a side around the goal should not tilt with height
-- the right vector is built perpendicular to forward so the candidate pattern stays aligned with the npc approach direction
-- a tiny offset uses a stable world forward vector to avoid normalizing a near zero vector
local function getFlatDirection(fromPosition, toPosition)
-- offset is the complete x y z difference between fromposition and toposition
-- subtracting positions produces a direction vector pointing toward the target
	local offset = toPosition - fromPosition
-- flatoffset copies x and z from that vector but forces y to zero
-- this makes horizontal path planning ignore slopes height and vertical separation
	local flatOffset = Vector3.new(offset.X, 0, offset.Z)
-- magnitude is now horizontal distance because flatoffset has no y component
-- zero point zero five means both flat positions are almost identical and unit would have no safe direction
	if flatOffset.Magnitude <= 0.05 then
-- negative world z is used as a stable fallback direction for that almost zero case
-- returning early prevents the unit calculation below from dividing by a near zero length
		return Vector3.new(0, 0, -1)
	end
-- unit divides flatoffset by its own magnitude and leaves a vector with length one
-- later radius multiplication can now control distance without changing direction
	return flatOffset.Unit
end
local function getRightVector(forward)
-- swapping forward z into x and negating forward x into z rotates it ninety degrees
-- this creates a ground flat right vector without needing cframe rotation
	return Vector3.new(forward.Z, 0, -forward.X)
end
-- candidate deduping saves path computations when ground projection makes two different offsets land on the same spot
-- the distance check is cheaper than asking pathfindingservice to solve another identical route
local function isDuplicateCandidate(candidates, position)
-- this loop compares the new grounded point against every point already in candidates
-- candidate holds one vector3 while i tells which array slot it came from
	for i, candidate in candidates do
-- subtracting positions creates their gap vector and magnitude turns it into stud distance
-- a gap inside the threshold returns true immediately because another path call would be a duplicate
		if (candidate - position).Magnitude <= CANDIDATE_DUPLICATE_DISTANCE then
			return true
		end
	end
	return false
end
-- every fallback point passes this gate before it is allowed into the candidate list
-- projection handles the y position and duplicate checking handles points that collapsed together after touching ground
-- pathfinding only receives positions that survived both checks
local function addCandidate(candidates, position, ignoreInstances)
-- groundedposition holds the candidate after projecttoground corrected its y value
-- this local keeps the raw requested position separate from the floor position actually being tested
	local groundedPosition = projectToGround(position, ignoreInstances)
	if not groundedPosition then return end
-- this condition stops duplicate projected points before they reach the candidate array
-- two different offsets can land on the same floor point around tight corners so this saves a path compute
	if isDuplicateCandidate(candidates, groundedPosition) then return end
	table.insert(candidates, groundedPosition)
end
-- candidates are ordered exact goal behind goal right left then in front for every radius
-- that ordering keeps the behavior predictable and gives close alternatives a chance before wider ones
-- every point goes through the same grounding and duplicate rules so fallback quality stays consistent
local function buildCandidatePositions(root, finishPosition, ignoreInstances)
-- candidates starts as an empty ordered array
-- only addcandidate can append to it so every entry has already passed grounding and duplicate checks
	local candidates = {}
	addCandidate(candidates, finishPosition, ignoreInstances)
	if not root then return candidates end
-- forward is the flat unit direction from the npc root to the requested finish
-- right is calculated from forward so side fallbacks rotate with the npcs approach angle
	local forward = getFlatDirection(root.Position, finishPosition)
	local right = getRightVector(forward)
-- this loop reads the radius array in order so four studs is tested before eight and twelve
-- i is the array index and radius is the actual stud value used by the four offsets
	for i, radius in FALLBACK_RADIUS_STEPS do
-- subtracting forward times radius tests a point before the goal from the npcs approach side
-- the next three calls test right left and beyond the goal using the same radius
		addCandidate(candidates, finishPosition - forward * radius, ignoreInstances)
		addCandidate(candidates, finishPosition + right * radius, ignoreInstances)
		addCandidate(candidates, finishPosition - right * radius, ignoreInstances)
		addCandidate(candidates, finishPosition + forward * radius, ignoreInstances)
	end
	return candidates
end
-- one path object is created per candidate because a path keeps its own status waypoints and blocked signal
-- computeasync can throw when navigation data is unavailable so pcall turns that into a normal failed candidate
-- both the error text and path status are returned for debugging while successful callers only need the path
local function computePathToPosition(moveData, targetPosition)
	local root = moveData.Root
	if not root then return nil end
	if not targetPosition then return nil end
-- createpath makes a fresh roblox path object using the resolved agent settings
-- a fresh object matters because status waypoints and blocked events belong to one compute
	local path = PathfindingService:CreatePath(getAgentParams(moveData))
-- pcall runs computeasync in protected mode because the engine call is allowed to throw
-- success becomes a boolean and errormessage receives the thrown value when success is false
	local success, errorMessage = pcall(function()
-- computeasync solves from the roots live world position to this candidate position
-- it yields until navigation calculation finishes and then updates pathstatus and waypoints
		path:ComputeAsync(root.Position, targetPosition)
	end)
	if not success then
		return nil, tostring(errorMessage), nil
	end
-- compute can finish without throwing but still return nopath or another failed status
-- only pathstatussuccess is accepted because failed path objects do not contain a route we should follow
	if path.Status ~= Enum.PathStatus.Success then
		return nil, tostring(path.Status), path.Status
	end
	return path, nil, path.Status
end
-- this tries candidates in priority order and accepts the first route that pathfindingservice can actually solve
-- the exact destination is always attempted before nearby ground points
-- only the last failure is warned because printing every rejected fallback for every npc would flood the output
-- returning nil gives the movement controller one clean failure result to react to
local function computeBestPath(moveData)
	local root = moveData.Root
	local finishPosition = moveData.Position
	if not root then return nil end
	if not finishPosition then return nil end
	if typeof(finishPosition) ~= "Vector3" then return nil end
-- candidates contains the exact goal first followed by grounded nearby fallbacks
-- keeping the table ordered lets this function choose by priority without another sorting pass
	local candidates = buildCandidatePositions(root, finishPosition, moveData.IgnoreInstances)
	local lastError = nil
	local lastStatus = nil
-- this loop tries one candidate per pass and stops as soon as a usable path is returned
-- i tracks priority order and candidateposition is the vector3 for this attempt
	for i, candidatePosition in candidates do
-- path is either the successful path object or nil
-- errormessage and status hold the exact reason this one candidate failed
		local path, errorMessage, status = computePathToPosition(moveData, candidatePosition)
-- a non nil path proves this candidate succeeded
-- returning inside the loop prevents wider fallback paths from wasting more navigation work
		if path then
			return path, candidatePosition
		end
		lastError = errorMessage
		lastStatus = status
	end
	warn(
		"[PathMover] Path failed.",
		"Status:",
		tostring(lastStatus),
		"Error:",
		tostring(lastError),
		"RawPosition:",
		tostring(finishPosition)
	)
	return nil
end
-- nine short ground rays cover the center sides and corners of the rig footprint
-- getboundingbox finds the real bottom of different sized npc models instead of assuming every rig has the same hip height
-- each hit must be solid terrain or a collidable part and its surface normal must point upward enough
-- one valid ray is enough because an npc standing partly on a ledge is still grounded
local function hasGroundBelowHumanoid(humanoid)
	if not humanoid then return false end
	local root = humanoid.RootPart
	if not root then return false end
	local character = humanoid.Parent
	if not character then return false end
-- getboundingbox returns the model center cframe and its full world aligned size vector
-- those values work for different rig sizes instead of assuming every npc has the same height
	local boundingCFrame, boundingSize = character:GetBoundingBox()
-- half the model height is subtracted from center y to find the bottom of the character
-- that bottom becomes the base height for all of the short grounded rays
	local characterBottomY = boundingCFrame.Position.Y - (boundingSize.Y * 0.5)
	local originY = characterBottomY + GROUNDED_RAY_START_HEIGHT
-- root width and depth are multiplied by zero point four five to place casts near each edge
-- mathmax keeps very thin rigs from putting every offset too close to the center
	local edgeX = math.max(root.Size.X * 0.45, 0.75)
	local edgeZ = math.max(root.Size.Z * 0.45, 0.75)
-- offsets contains center four side points and four corners for nine total ground samples
-- every vector has zero y because originy is calculated separately from the model bottom
	local offsets = {
		Vector3.new(0, 0, 0),
		Vector3.new(edgeX, 0, 0),
		Vector3.new(-edgeX, 0, 0),
		Vector3.new(0, 0, edgeZ),
		Vector3.new(0, 0, -edgeZ),
		Vector3.new(edgeX, 0, edgeZ),
		Vector3.new(edgeX, 0, -edgeZ),
		Vector3.new(-edgeX, 0, edgeZ),
		Vector3.new(-edgeX, 0, -edgeZ),
	}
	local raycastParams = getRaycastParams({character})
-- this loop runs once for every footprint offset and can return true on the first valid floor
-- i is the offset index and offset stores how far this ray moves from root center
	for i, offset in offsets do
-- origin combines root x and z with the calculated bottom y
-- adding offset x and z moves the ray to its assigned side or corner without changing height
		local origin = Vector3.new(
			root.Position.X + offset.X,
			originY,
			root.Position.Z + offset.Z
		)
-- result stores the first object hit by a short straight downward ray
-- the same character exclusion is reused so limbs and accessories cannot count as floor
		local result = workspace:Raycast(
			origin,
			Vector3.new(0, -GROUNDED_RAY_DISTANCE, 0),
			raycastParams
		)
-- resultnormal points away from the hit surface with a length of one
-- y above the threshold means it faces upward enough to support the npc instead of being a wall
		if isGroundResult(result) and result.Normal.Y >= GROUNDED_MIN_NORMAL_Y then return true end
	end
	return false
end
-- physical ground and humanoid state are checked together
-- ground alone is not enough because a jumping or falling humanoid can still be close enough for a ray to hit
-- this stops new path jumps from firing during an existing airborne state
local function isHumanoidGrounded(humanoid)
	if not hasGroundBelowHumanoid(humanoid) then return false end
-- getstate returns the current humanoid state enum at this exact moment
-- storing it once makes all three airborne comparisons use one consistent state reading
	local state = humanoid:GetState()
-- jumping freefall and fallingdown all reject the grounded result even when a ray is close to floor
-- this prevents another jump command from firing while the humanoid is already airborne
	if state == Enum.HumanoidStateType.Jumping then return false end
	if state == Enum.HumanoidStateType.Freefall then return false end
	if state == Enum.HumanoidStateType.FallingDown then return false end
	return true
end
-- this is the shorter jump permission check for places that only need a yes or no result
-- it checks definition settings humanoid support and real ground without touching the jump cooldown state
-- the detailed waypoint check below adds the cooldown duplicate node check and readable block reason
local function canUseJump(moveData, humanoid)
	local movementDefinition = getMovementDefinition(moveData)
	if movementDefinition.CanJump == false then return false end
	local agentParams = getAgentParams(moveData)
	if agentParams.AgentCanJump == false then return false end
	if not humanoid:GetStateEnabled(Enum.HumanoidStateType.Jumping) then return false end
	if not isHumanoidGrounded(humanoid) then return false end
	return true
end
-- jump validation returns a specific reason for every rejected request
-- the waypoint must request a jump and both the npc definition and path agent must allow it
-- humanoid state support ground contact cooldown and duplicate waypoint checks all have to pass
-- movementcontroller gets the final say through shouldjumpwaypoint so higher level behavior can block a jump too
-- keeping the reason makes path debug show exactly which guard stopped the jump
local function getJumpBlockReason(moveData, humanoid, waypoint, jumpState)
-- waypointaction must equal jump before any jump permission matters
-- a normal waypoint returns its reason immediately and skips every more expensive check below
	if waypoint.Action ~= Enum.PathWaypointAction.Jump then
		return "NotJumpWaypoint"
	end
	local movementDefinition = getMovementDefinition(moveData)
	if movementDefinition.CanJump == false then
		return "Movement.CanJump is false"
	end
-- agentparams is resolved again so this decision matches the settings used to create the path
-- path generation and humanoid execution both need to agree that jumping is allowed
	local agentParams = getAgentParams(moveData)
	if agentParams.AgentCanJump == false then
		return "AgentCanJump is false"
	end
	if not humanoid:GetStateEnabled(Enum.HumanoidStateType.Jumping) then
		return "Humanoid jumping state disabled"
	end
	if not hasGroundBelowHumanoid(humanoid) then
		return "Humanoid not grounded"
	end
-- state is stored once because the next conditions compare it with several humanoid enums
-- each matching airborne state returns its own reason for debug output
	local state = humanoid:GetState()
	if state == Enum.HumanoidStateType.Jumping then
		return "Already jumping"
	end
	if state == Enum.HumanoidStateType.Freefall then
		return "In freefall"
	end
	if state == Enum.HumanoidStateType.FallingDown then
		return "Falling down"
	end
-- osclock is a steadily increasing runtime value in seconds
-- subtracting two osclock readings gives elapsed time without depending on calendar time
	local currentTime = os.clock()
-- current time minus last jump time is the number of seconds since the last accepted jump
-- anything below min jump interval is still on cooldown and returns before changing jump memory
	if currentTime - jumpState.LastJumpTime < MIN_JUMP_INTERVAL then
		return "Jump cooldown"
	end
-- lastjumpposition must exist before vector subtraction is attempted
-- distance inside same waypoint threshold means this path has already triggered that jump node
	if jumpState.LastJumpPosition and (waypoint.Position - jumpState.LastJumpPosition).Magnitude <= SAME_WAYPOINT_DISTANCE then
		return "Same jump waypoint"
	end
-- shouldjumpwaypoint is an optional callback owned by movementcontroller
-- it lets higher level npc state reject a jump even after the physical checks passed
	if moveData.ShouldJumpWaypoint then
		local allowed, reason = moveData.ShouldJumpWaypoint(waypoint.Position)
		if not allowed then
			return reason or "ShouldJumpWaypoint blocked"
		end
	end
	return nil
end
-- this wrapper turns the detailed block reason into the final allowed result
-- jump memory only updates after every check passes so a rejected request cannot consume the cooldown
-- returning the reason with the boolean keeps the visual marker and console output honest
local function shouldJumpWaypoint(moveData, humanoid, waypoint, jumpState)
-- blockreason receives a string from the first failed check or nil when all checks passed
-- keeping the exact string is what makes rejected jump debug markers useful
	local blockReason = getJumpBlockReason(moveData, humanoid, waypoint, jumpState)
	if blockReason then
		return false, blockReason
	end
-- jump time and position only update after every guard passed
-- writing them before the humanoid command blocks another callback from approving the same jump immediately
	jumpState.LastJumpTime = os.clock()
	jumpState.LastJumpPosition = waypoint.Position
	return true, "Jump allowed"
end
-- waypoint distance is measured from the live root position because movetofinished can be late near tight nodes
-- the first useful waypoint scan skips points the npc has already reached
-- jump nodes are never skipped here because their action still matters even when their position is close
local function isWaypointReached(root, waypoint, distance)
	if not root then return false end
	if not waypoint then return false end
-- waypoint position minus root position creates the gap vector
-- magnitude converts that vector into straight line distance and compares it with the reached radius
	return (waypoint.Position - root.Position).Magnitude <= distance
end
local function findFirstUsefulWaypoint(root, waypoints)
-- this loop walks the waypoint array in path order because nodes cannot be safely reordered
-- index is the current array position and waypoint is the pathwaypoint stored there
	for index, waypoint in waypoints do
-- jump nodes return their index immediately even if the npc is already close
-- skipping one would remove its jump action and could make the npc walk into the obstacle
		if waypoint.Action == Enum.PathWaypointAction.Jump then return index end
-- continue ends only this loop pass and starts the next waypoint index
-- the wider first node distance handles pathfinding placing its start almost under the npc
		if index == 1 and isWaypointReached(root, waypoint, FIRST_WAYPOINT_SKIP_DISTANCE) then continue end
		if isWaypointReached(root, waypoint, WAYPOINT_REACHED_DISTANCE) then continue end
		return index
	end
	return nil
end
-- all visual path parts live in one workspace folder so they stay separate from gameplay objects
-- old debug data for the same npc is destroyed before a new route is drawn
-- these instances only exist when studio path debug is enabled
local function getPathDebugFolder()
	local folder = workspace:FindFirstChild(PATH_DEBUG_FOLDER_NAME)
	if not folder then
-- instancenew creates the debug folder before it has a parent
-- its name is set first and parenting it to workspace makes it visible in the datamodel
		folder = Instance.new("Folder")
		folder.Name = PATH_DEBUG_FOLDER_NAME
		folder.Parent = workspace
	end
	return folder
end
-- one npc only needs one visible current path
-- deleting its older folder before drawing the next route keeps repaths readable instead of stacking lines everywhere
local function clearOldPathDebug(debugName)
	local folder = getPathDebugFolder()
	local oldDebug = folder:FindFirstChild(debugName)
	if oldDebug then
		oldDebug:Destroy()
	end
end
-- waypoint balls are anchored nonphysical markers
-- collision touch and query are disabled so debugging cannot change npc navigation hitboxes or raycasts
-- neon color separates normal and jump nodes without needing extra world parts
local function createDebugBall(position, color, parent)
	local part = Instance.new("Part")
	part.Name = "Waypoint"
	part.Shape = Enum.PartType.Ball
	part.Size = Vector3.new(0.45, 0.45, 0.45)
	part.Position = position + Vector3.new(0, 0.5, 0)
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.Material = Enum.Material.Neon
	part.Color = color
	part.Parent = parent
	return part
end
-- billboard labels make waypoint index and action readable from any camera angle
-- alwaystontop keeps the path information visible through the npc and level geometry
-- the label is parented to its marker so one destroy cleans up both objects
local function createDebugLabel(part, text)
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "DebugLabel"
	billboard.Size = UDim2.fromOffset(180, 45)
	billboard.StudsOffset = Vector3.new(0, 1.25, 0)
	billboard.AlwaysOnTop = true
	billboard.Adornee = part
	billboard.Parent = part
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(0.5, 0.5)
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.TextStrokeTransparency = 0
	label.TextScaled = true
	label.Font = Enum.Font.GothamBold
	label.Parent = billboard
end
-- debug lines are real thin parts sized to the exact distance between two waypoints
-- the midpoint places each line between the points and cframelookat aims its long z axis at the next node
-- tiny segments are skipped because they have no useful direction and can create unstable orientation
-- these parts also have every physical interaction disabled
local function createDebugLine(fromPosition, toPosition, parent)
-- distance is the length of the vector between both waypoint positions
-- that value becomes the z size because the parts long axis connects the points
	local distance = (toPosition - fromPosition).Magnitude
	if distance <= 0.05 then
		return
	end
	local part = Instance.new("Part")
	part.Name = "PathLine"
	part.Size = Vector3.new(0.15, 0.15, distance)
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.Material = Enum.Material.Neon
	part.Color = Color3.fromRGB(0, 170, 255)
-- cframelookat places the part at the midpoint and rotates its front toward the next waypoint
-- using midpoint plus exact distance makes both ends meet the marker positions
	part.CFrame = CFrame.lookAt((fromPosition + toPosition) / 2, toPosition)
	part.Parent = parent
end
-- the complete path visual only runs in studio and behind the module debug switch
-- green marks normal movement orange marks jumps and blue lines show the route order
-- each path gets a timed cleanup so repeated testing doesnt leave old markers in workspace
-- movedata keeps the folder reference so current waypoint markers can join the correct path
local function visualizePath(moveData, waypoints)
-- showpathdebug returns before any instance work when the feature is disabled
-- runserviceisstudio is the second lock that stops debug geometry from entering live servers
	if not SHOW_PATH_DEBUG then return end
	if not RunService:IsStudio() then return end
	if not moveData.Root then return end
	if not waypoints then return end
	local npcName = moveData.Root.Parent and moveData.Root.Parent.Name or "NPC"
	local debugName = npcName .. "_Path"
	clearOldPathDebug(debugName)
	local debugFolder = Instance.new("Folder")
	debugFolder.Name = debugName
	debugFolder.Parent = getPathDebugFolder()
	moveData.DebugPathFolder = debugFolder
-- this loop creates one ball and optional connecting line for every path waypoint
-- i gives route order and waypoint contains position plus normal or jump action
	for i, waypoint in waypoints do
		local color = Color3.fromRGB(0, 255, 120)
		local labelText = tostring(i) .. " NORMAL"
-- jump nodes replace the normal green color and text before their ball is created
-- normal nodes keep the defaults assigned at the start of this loop pass
		if waypoint.Action == Enum.PathWaypointAction.Jump then
			color = Color3.fromRGB(255, 170, 0)
			labelText = tostring(i) .. " JUMP"
		end
		local ball = createDebugBall(waypoint.Position, color, debugFolder)
		createDebugLabel(ball, labelText)
-- waypoints index minus one asks for the previous route node
-- the first index has no previous value so its connecting line branch is skipped
		if waypoints[i - 1] then
			createDebugLine(
				waypoints[i - 1].Position + Vector3.new(0, 0.5, 0),
				waypoint.Position + Vector3.new(0, 0.5, 0),
				debugFolder
			)
		end
	end
-- route debug has a hard lifetime even when the npc never completes its move
-- this cleanup still runs after failures cancellations and stopped studio tests as long as the datamodel is alive
	task.delay(PATH_DEBUG_LIFETIME, function()
		if debugFolder then
			debugFolder:Destroy()
		end
	end)
end
-- current waypoint markers are temporary and larger than the base path nodes
-- their color and text show whether a jump was accepted rejected or not needed
-- they use the same debug folder so a cancelled or replaced path can be understood as one group
local function markCurrentWaypoint(moveData, index, waypoint, color, text)
	if not SHOW_PATH_DEBUG then return end
	if not RunService:IsStudio() then return end
	if not moveData.DebugPathFolder then return end
	if not waypoint then return end
	local marker = Instance.new("Part")
	marker.Name = "CurrentWaypoint_" .. tostring(index)
	marker.Shape = Enum.PartType.Ball
	marker.Size = Vector3.new(0.8, 0.8, 0.8)
	marker.Position = waypoint.Position + Vector3.new(0, 1.3, 0)
	marker.Anchored = true
	marker.CanCollide = false
	marker.CanTouch = false
	marker.CanQuery = false
	marker.Material = Enum.Material.Neon
	marker.Color = color
	marker.Parent = moveData.DebugPathFolder
	createDebugLabel(marker, text)
-- current node markers disappear faster than the full path since they only explain one movement decision
-- the parent folder cleanup is still allowed to destroy them first without causing a problem
	task.delay(1.25, function()
		if marker then
			marker:Destroy()
		end
	end)
end
-- computepath exposes the solver for systems that only need to test whether a route exists
-- move below uses the same solver but also owns waypoint execution and failure handling
function PathMover:ComputePath(moveData)
	local path = computeBestPath(moveData)
	return path
end
-- move validates the request before creating any events or paths
-- failed input reports one failed result instead of letting a missing humanoid root or target break later callbacks
-- once the path starts pathfinished becomes the lock that prevents two asynchronous exits from finishing it twice
-- blocked progress and active moveto connections are tracked separately because each one can end the route
-- all of them still feed the same finishpath cleanup
function PathMover:Move(moveData)
	if isCancelled(moveData) then return end
-- these luau type casts describe the objects movedata should contain without changing them at runtime
-- humanoid root and position stay the exact references and vector supplied by the caller
	local humanoid = moveData.Humanoid :: Humanoid
	local root = moveData.Root :: BasePart
	local position = moveData.Position :: Vector3
	if not humanoid then
		finish(moveData, "Failed")
		return
	end
	if not root then
		finish(moveData, "Failed")
		return
	end
	if not position then
		finish(moveData, "Failed")
		return
	end
	debugPath(moveData, "ComputePath", "Target:", tostring(position), "HumanoidState:", humanoid:GetState().Name)
	local path = computeBestPath(moveData)
	if not path then
		debugPath(moveData, "PathResult", "Failed")
		finish(moveData, "Failed")
		return
	end
-- pathfinished is shared by every event and callback created for this move
-- the first final result flips it and later queued callbacks are blocked from finishing twice
	local pathFinished = false
	local blockedConnection
	local progressConnection
	local activeMoveConnection
	local currentWaypointIndex = 0
-- connections are removed from both roblox and movementcontrollers tracking table
-- disconnecting first stops callbacks immediately while removeconnection prevents dead entries from building up
-- this matters when an npc repaths often during combat
-- removeconnection accepts one rbxscriptsignalconnection from this path run
-- it disconnects roblox first then asks the parent controller to forget the same reference
	local function removeConnection(connection)
		if not connection then return end
		connection:Disconnect()
		if moveData.RemoveConnection then
			moveData.RemoveConnection(connection)
		end
	end
-- finishpath has a one time lock so blocked stuck cancelled and reached callbacks cannot send duplicate results
-- every owned connection is disconnected before the parent controller is notified
-- the active moveto reference is cleared after disconnect so a later callback cant treat it as current
	local function finishPath(result)
-- this guard is the one time lock for reached failed blocked and stuck results
-- returning here stops duplicate cleanup when two callbacks arrive in the same frame
		if pathFinished then return end
		pathFinished = true
		removeConnection(blockedConnection)
		removeConnection(progressConnection)
		removeConnection(activeMoveConnection)
		activeMoveConnection = nil
		finish(moveData, result)
	end
-- waypoints are pulled once after the successful compute
-- an empty path means failure while a path whose useful nodes are already reached finishes successfully
-- startindex avoids commanding the humanoid to walk backward to a starting node under its feet
	local waypoints = path:GetWaypoints()
	visualizePath(moveData, waypoints)
	if not waypoints then
		finishPath("Failed")
		return
	end
	if #waypoints <= 0 then
		debugPath(moveData, "PathResult", "Failed", "Reason:", "No waypoints")
		finishPath("Failed")
		return
	end
	debugPath(moveData, "PathResult", "Success", "Waypoints:", #waypoints)
	local startIndex = findFirstUsefulWaypoint(root, waypoints)
	if not startIndex then
		finishPath("Reached")
		return
	end
	currentWaypointIndex = startIndex
-- path blocked reports which waypoint became obstructed
-- blocks behind the npc are ignored because they cannot affect the remaining route
-- any block at or ahead of the current node ends this attempt so the controller can request a fresh path
-- pathblocked supplies the waypoint index where navigation became obstructed
-- indices lower than current waypoint are behind the npc and do not affect the route still ahead
	blockedConnection = path.Blocked:Connect(function(blockedWaypointIndex)
		if pathFinished then return end
		if isCancelled(moveData) then return end
		if blockedWaypointIndex < currentWaypointIndex then return end
		debugPath(moveData, "PathBlocked", "Index:", blockedWaypointIndex)
		finishPath("Failed")
	end)
-- heartbeat samples progress at a fixed rate instead of doing distance work every frame
-- moving far enough resets both the sample position and timeout clock
-- failing to make minimum progress for the timeout marks the route failed even if movetofinished never responds
-- dt accumulation makes the check stable across different server frame rates
-- the callback only observes the root and exits through finishpath so cleanup stays centralized
-- lastprogressposition stores the root location used for the next movement comparison
-- lastprogresstime stores when enough real movement was most recently measured
	local lastProgressPosition = root.Position
	local lastProgressTime = os.clock()
-- progressaccumulator starts at zero and collects heartbeat delta time
-- this lets distance checks run twice a second instead of doing the same work every frame
	local progressAccumulator = 0
-- heartbeat calls this function each server frame and dt is seconds since its previous call
-- the callback first checks finish and cancellation because stale paths should do no more work
	progressConnection = RunService.Heartbeat:Connect(function(dt)
		if pathFinished then return end
		if isCancelled(moveData) then return end
-- adding dt tracks real elapsed time even when server frame rate changes
-- the early return below skips distance work until the half second sample window is full
		progressAccumulator += dt
		if progressAccumulator < STUCK_CHECK_RATE then return end
		progressAccumulator = 0
-- root position minus the old sample creates the movement vector
-- magnitude measures studs traveled and enough movement resets both stuck tracking values
		if (root.Position - lastProgressPosition).Magnitude >= STUCK_MIN_PROGRESS then
			lastProgressPosition = root.Position
			lastProgressTime = os.clock()
			return
		end
-- current osclock minus last progress time is how long the npc has failed to advance
-- staying under stuck timeout returns and gives the active moveto more time
		if os.clock() - lastProgressTime < STUCK_TIMEOUT then return end
		debugPath(moveData, "PathStuck", "Waypoint:", currentWaypointIndex)
		finishPath("Failed")
	end)
	if moveData.AddConnection then
-- movementcontroller also tracks these so cancelling the npc from outside this module can stop both checks right away
-- pathmover still owns their normal cleanup which is why both addconnection and removeconnection callbacks exist
		moveData.AddConnection(blockedConnection)
		moveData.AddConnection(progressConnection)
	end
-- jump state belongs to this one path run
-- last time prevents rapid repeat jumps and last position stops the same jump node being triggered twice
-- a new path gets clean jump memory so an old route cannot block a valid new jump
-- jumpstate belongs to this path run and is captured by every waypoint callback
-- its two fields track cooldown time and duplicate position without touching another npc
	local jumpState = {
		LastJumpTime = 0,
		LastJumpPosition = nil,
	}
	local moveToWaypoint
-- movetowaypoint advances one node at a time through asynchronous movetofinished callbacks
-- it checks cancellation before every command so a replaced token cannot issue another humanoid movement
-- nearby normal nodes are skipped in a loop but jump nodes stay in the sequence
-- currentwaypointindex is updated before events use it so blocked checks always compare against the live node
-- movetowaypoint is assigned after its local declaration so its callback can call itself later
-- index is the waypoint array slot this pass is responsible for
	moveToWaypoint = function(index: number)
		if pathFinished then return end
		if isCancelled(moveData) then return end
		currentWaypointIndex = index
-- this while loop advances only when a waypoint exists is not jump and is already reached
-- all three conditions must be true and index increases once per pass
		while waypoints[index]
			and waypoints[index].Action ~= Enum.PathWaypointAction.Jump
			and isWaypointReached(root, waypoints[index], WAYPOINT_REACHED_DISTANCE) do
-- adding one changes the lookup to the next sequential path node
-- the loop then checks all three conditions again before it can skip another node
			index += 1
		end
		currentWaypointIndex = index
-- waypoint stores the node found after nearby normal points were skipped
-- the type cast tells luau it has position and action fields but does not change the object
		local waypoint = waypoints[index] :: PathWaypoint
-- nil means index moved past the end of the waypoint array
-- that is a successful completed route so finishpath receives reached
		if not waypoint then
			debugPath(moveData, "PathFinished", "Reached")
			finishPath("Reached")
			return
		end
-- waypoint action decides whether the normal move or guarded jump branch runs
-- jump permission is calculated before humanoid movement so the action and debug marker describe the same decision
-- the humanoid jump request is repeated with taskdefer because roblox state timing can consume the first request during a transition
-- this inline and expression chooses jump only when the action enum matches
-- every other action uses normal so debug text always has a readable value
		local actionName = waypoint.Action == Enum.PathWaypointAction.Jump and "Jump" or "Normal"
		debugPath(moveData, "Waypoint", "Index:", index, "Action:", actionName, "Position:", tostring(waypoint.Position))
-- shouldjump is the final boolean and jumpreason explains exactly which validation decided it
-- both values come from one call so the command log and marker cannot disagree
		local shouldJump, jumpReason = shouldJumpWaypoint(moveData, humanoid, waypoint, jumpState)
		if waypoint.Action == Enum.PathWaypointAction.Jump then
			if shouldJump then
				debugPath(moveData, "Jump", "Index:", index, "Allowed:", true, "Reason:", tostring(jumpReason))
				markCurrentWaypoint(
					moveData,
					index,
					waypoint,
					Color3.fromRGB(0, 255, 255),
					"CURRENT " .. tostring(index) .. "\nJUMPING"
				)
-- humanoidjump true requests robloxs normal jump behavior
-- changestate immediately asks the humanoid state machine to enter jumping
				humanoid.Jump = true
				humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
-- taskdefer schedules a second jump request after the current call stack completes
-- this covers engine timing where the first request is consumed during a state transition
				task.defer(function()
					if humanoid and humanoid.Parent then
						humanoid.Jump = true
						humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
					end
				end)
			else
				debugPath(moveData, "Jump", "Index:", index, "Allowed:", false, "Reason:", tostring(jumpReason))
				markCurrentWaypoint(
					moveData,
					index,
					waypoint,
					Color3.fromRGB(255, 0, 0),
					"CURRENT " .. tostring(index) .. "\nNO JUMP\n" .. tostring(jumpReason)
				)
			end
		else
			markCurrentWaypoint(
				moveData,
				index,
				waypoint,
				Color3.fromRGB(255, 255, 255),
				"CURRENT " .. tostring(index) .. "\nNORMAL"
			)
		end
-- directmover handles travel to this single waypoint and returns its movetofinished connection
-- the callback removes the completed connection before moving on so the table only contains live work
-- a failed node ends the whole path while a reached node schedules the next index
-- the recursive call is callback based so it does not grow a synchronous call stack across the route
-- if directmover cannot create a connection the route fails immediately instead of waiting forever
-- directmover receives a table containing the humanoid root target position and completion callback
-- it owns one moveto while pathmover keeps ownership of the whole waypoint sequence
		activeMoveConnection = DirectMover:Move({
			Humanoid = humanoid,
			Root = root,
			Position = waypoint.Position,
-- onfinished receives true when the waypoint was reached and false when that one moveto failed
-- this callback is asynchronous so cancellation gets checked again before advancing
			OnFinished = function(reached)
-- completedconnection copies the live connection before active move is cleared
-- that exact reference can now be disconnected and removed from tracking safely
				local completedConnection = activeMoveConnection
				activeMoveConnection = nil
				removeConnection(completedConnection)
				if isCancelled(moveData) then return end
				debugPath(moveData, "WaypointFinished", "Index:", index, "Reached:", reached)
-- an unreached waypoint fails the whole route because skipping it may walk through blocked geometry
-- a reached waypoint falls through and calls the same function with index plus one
				if not reached then
					finishPath("Failed")
					return
				end
				moveToWaypoint(index + 1)
			end,
		})
-- no returned connection means directmover did not start a moveto
-- failing now avoids waiting forever for a completion callback that cannot exist
		if not activeMoveConnection then
			finishPath("Failed")
			return
		end
		if moveData.AddConnection then
			moveData.AddConnection(activeMoveConnection)
		end
	end
-- nothing moves until every guard event and callback above is ready
-- starting at the chosen useful index begins the chain and every later node continues from its completion callback
-- this first call begins the callback chain at the first useful waypoint
-- later calls only happen from successful directmover completion callbacks
	moveToWaypoint(startIndex)
end
-- the returned table exposes path solving and path movement without starting any work when the module is required
return PathMover
