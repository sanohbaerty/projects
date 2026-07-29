local ServerScriptService = game:GetService("ServerScriptService")
local PathfindingService = game:GetService("PathfindingService")
local RunService = game:GetService("RunService")

local ServerModules = ServerScriptService.Server
local AIModules = ServerModules.AdvancedNPCAI
local MovementModules = AIModules.Movement

local DirectMover = require(MovementModules.DirectMover)
local DefaultAgent = require(script.DefaultAgent)

local PathMover = {}

local WAYPOINT_REACHED_DISTANCE = 2.5
local FIRST_WAYPOINT_SKIP_DISTANCE = 3
local SAME_WAYPOINT_DISTANCE = 1.25
local MIN_JUMP_INTERVAL = 0.85
local STUCK_CHECK_RATE = 0.5
local STUCK_TIMEOUT = 2.5
local STUCK_MIN_PROGRESS = 0.75

local GROUND_PROJECT_UP = 14
local GROUND_PROJECT_DOWN = 80
local GROUND_PROJECT_SKIP_DISTANCE = 0.08
local MAX_GROUND_RAYCAST_SKIPS = 8

local GROUNDED_RAY_START_HEIGHT = 0.35
local GROUNDED_RAY_DISTANCE = 0.9
local GROUNDED_MIN_NORMAL_Y = 0.55

local FALLBACK_RADIUS_STEPS = {4, 8, 12}
local CANDIDATE_DUPLICATE_DISTANCE = 1.25

local SHOW_PATH_DEBUG = false
local PATH_DEBUG_LIFETIME = 8
local PATH_DEBUG_FOLDER_NAME = "NPCPathDebug"

local function getMovementDefinition(moveData)
	local definition = moveData.Definition
	return definition and definition.Movement or {}
end

local function resolveAgentValue(agentParams, agentDefinition, pathDefinition, valueName, fallback)
	if agentParams[valueName] ~= nil then
		return agentParams[valueName]
	end

	if agentDefinition[valueName] ~= nil then
		return agentDefinition[valueName]
	end

	if pathDefinition[valueName] ~= nil then
		return pathDefinition[valueName]
	end

	if DefaultAgent[valueName] ~= nil then
		return DefaultAgent[valueName]
	end

	return fallback
end

local function getAgentParams(moveData)
	local agentParams = moveData.AgentParams or {}
	local movementDefinition = getMovementDefinition(moveData)
	local agentDefinition = movementDefinition.Agent or {}
	local pathDefinition = movementDefinition.Pathfinding or {}

	local agentCanJump = resolveAgentValue(agentParams, agentDefinition, pathDefinition, "AgentCanJump", true)

	if movementDefinition.CanJump == false then
		agentCanJump = false
	end

	return {
		AgentRadius = resolveAgentValue(agentParams, agentDefinition, pathDefinition, "AgentRadius", 2),
		AgentHeight = resolveAgentValue(agentParams, agentDefinition, pathDefinition, "AgentHeight", 5),
		AgentCanJump = agentCanJump,
		AgentCanClimb = resolveAgentValue(agentParams, agentDefinition, pathDefinition, "AgentCanClimb", false),
		WaypointSpacing = resolveAgentValue(agentParams, agentDefinition, pathDefinition, "WaypointSpacing", 4),
		Costs = resolveAgentValue(agentParams, agentDefinition, pathDefinition, "Costs", {}),
	}
end

local function finish(moveData, result)
	if not moveData.OnFinished then return end
	moveData.OnFinished(result)
end

local function isCancelled(moveData)
	if not moveData.ShouldCancel then return false end
	return moveData.ShouldCancel() == true
end

local function debugPath(moveData, ...)
	if not moveData.DebugMovement then return end

	print(
		"[AdvancedNPCAI PathMover]",
		"Requester:", moveData.Requester or "Unknown",
		"Token:", tostring(moveData.Token or "None"),
		...
	)
end

local function getRaycastParams(ignoreInstances)
	local raycastParams = RaycastParams.new()
	raycastParams.FilterDescendantsInstances = ignoreInstances or {}
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.IgnoreWater = true

	return raycastParams
end

local function isGroundResult(raycastResult)
	if not raycastResult then return false end
	if raycastResult.Instance == workspace.Terrain then return true end
	if not raycastResult.Instance:IsA("BasePart") then return false end

	return raycastResult.Instance.CanCollide
end

local function copyIgnoreInstances(ignoreInstances)
	local copied = {}

	for i, instance in ignoreInstances or {} do
		table.insert(copied, instance)
	end

	return copied
end

local function projectToGround(position, ignoreInstances)
	if typeof(position) ~= "Vector3" then return nil end

	local ignored = copyIgnoreInstances(ignoreInstances)
	local origin = position + Vector3.new(0, GROUND_PROJECT_UP, 0)
	local target = position - Vector3.new(0, GROUND_PROJECT_DOWN, 0)
	local direction = target - origin

	for i = 1, MAX_GROUND_RAYCAST_SKIPS do
		if direction.Magnitude <= 0.05 then return position end

		local result = workspace:Raycast(origin, direction, getRaycastParams(ignored))
		if not result then return position end

		if isGroundResult(result) then
			return result.Position
		end

		table.insert(ignored, result.Instance)

		origin = result.Position + direction.Unit * GROUND_PROJECT_SKIP_DISTANCE
		direction = target - origin
	end

	return position
end

local function getFlatDirection(fromPosition, toPosition)
	local offset = toPosition - fromPosition
	local flatOffset = Vector3.new(offset.X, 0, offset.Z)

	if flatOffset.Magnitude <= 0.05 then
		return Vector3.new(0, 0, -1)
	end

	return flatOffset.Unit
end

local function getRightVector(forward)
	return Vector3.new(forward.Z, 0, -forward.X)
end

local function isDuplicateCandidate(candidates, position)
	for i, candidate in candidates do
		if (candidate - position).Magnitude <= CANDIDATE_DUPLICATE_DISTANCE then
			return true
		end
	end

	return false
end

local function addCandidate(candidates, position, ignoreInstances)
	local groundedPosition = projectToGround(position, ignoreInstances)
	if not groundedPosition then return end
	if isDuplicateCandidate(candidates, groundedPosition) then return end

	table.insert(candidates, groundedPosition)
end

local function buildCandidatePositions(root, finishPosition, ignoreInstances)
	local candidates = {}

	addCandidate(candidates, finishPosition, ignoreInstances)

	if not root then return candidates end

	local forward = getFlatDirection(root.Position, finishPosition)
	local right = getRightVector(forward)

	for i, radius in FALLBACK_RADIUS_STEPS do
		addCandidate(candidates, finishPosition - forward * radius, ignoreInstances)
		addCandidate(candidates, finishPosition + right * radius, ignoreInstances)
		addCandidate(candidates, finishPosition - right * radius, ignoreInstances)
		addCandidate(candidates, finishPosition + forward * radius, ignoreInstances)
	end

	return candidates
end

local function computePathToPosition(moveData, targetPosition)
	local root = moveData.Root
	if not root then return nil end
	if not targetPosition then return nil end

	local path = PathfindingService:CreatePath(getAgentParams(moveData))

	local success, errorMessage = pcall(function()
		path:ComputeAsync(root.Position, targetPosition)
	end)

	if not success then
		return nil, tostring(errorMessage), nil
	end

	if path.Status ~= Enum.PathStatus.Success then
		return nil, tostring(path.Status), path.Status
	end

	return path, nil, path.Status
end

local function computeBestPath(moveData)
	local root = moveData.Root
	local finishPosition = moveData.Position

	if not root then return nil end
	if not finishPosition then return nil end
	if typeof(finishPosition) ~= "Vector3" then return nil end

	local candidates = buildCandidatePositions(root, finishPosition, moveData.IgnoreInstances)
	local lastError = nil
	local lastStatus = nil

	for i, candidatePosition in candidates do
		local path, errorMessage, status = computePathToPosition(moveData, candidatePosition)

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

local function hasGroundBelowHumanoid(humanoid)
	if not humanoid then return false end

	local root = humanoid.RootPart
	if not root then return false end

	local character = humanoid.Parent
	if not character then return false end

	local boundingCFrame, boundingSize = character:GetBoundingBox()
	local characterBottomY = boundingCFrame.Position.Y - (boundingSize.Y * 0.5)

	local originY = characterBottomY + GROUNDED_RAY_START_HEIGHT
	
	local edgeX = math.max(root.Size.X * 0.45, 0.75)
	local edgeZ = math.max(root.Size.Z * 0.45, 0.75)

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

	for i, offset in offsets do
		local origin = Vector3.new(
			root.Position.X + offset.X,
			originY,
			root.Position.Z + offset.Z
		)

		local result = workspace:Raycast(
			origin,
			Vector3.new(0, -GROUNDED_RAY_DISTANCE, 0),
			raycastParams
		)

		if isGroundResult(result) and result.Normal.Y >= GROUNDED_MIN_NORMAL_Y then return true end
	end

	return false
end

local function isHumanoidGrounded(humanoid)
	if not hasGroundBelowHumanoid(humanoid) then return false end

	local state = humanoid:GetState()
	if state == Enum.HumanoidStateType.Jumping then return false end
	if state == Enum.HumanoidStateType.Freefall then return false end
	if state == Enum.HumanoidStateType.FallingDown then return false end

	return true
end

local function canUseJump(moveData, humanoid)
	local movementDefinition = getMovementDefinition(moveData)
	if movementDefinition.CanJump == false then return false end

	local agentParams = getAgentParams(moveData)
	if agentParams.AgentCanJump == false then return false end
	if not humanoid:GetStateEnabled(Enum.HumanoidStateType.Jumping) then return false end
	if not isHumanoidGrounded(humanoid) then return false end

	return true
end

local function getJumpBlockReason(moveData, humanoid, waypoint, jumpState)
	if waypoint.Action ~= Enum.PathWaypointAction.Jump then
		return "NotJumpWaypoint"
	end

	local movementDefinition = getMovementDefinition(moveData)

	if movementDefinition.CanJump == false then
		return "Movement.CanJump is false"
	end

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

	local currentTime = os.clock()

	if currentTime - jumpState.LastJumpTime < MIN_JUMP_INTERVAL then
		return "Jump cooldown"
	end

	if jumpState.LastJumpPosition and (waypoint.Position - jumpState.LastJumpPosition).Magnitude <= SAME_WAYPOINT_DISTANCE then
		return "Same jump waypoint"
	end

	if moveData.ShouldJumpWaypoint then
		local allowed, reason = moveData.ShouldJumpWaypoint(waypoint.Position)

		if not allowed then
			return reason or "ShouldJumpWaypoint blocked"
		end
	end

	return nil
end

local function shouldJumpWaypoint(moveData, humanoid, waypoint, jumpState)
	local blockReason = getJumpBlockReason(moveData, humanoid, waypoint, jumpState)

	if blockReason then
		return false, blockReason
	end

	jumpState.LastJumpTime = os.clock()
	jumpState.LastJumpPosition = waypoint.Position

	return true, "Jump allowed"
end

local function isWaypointReached(root, waypoint, distance)
	if not root then return false end
	if not waypoint then return false end

	return (waypoint.Position - root.Position).Magnitude <= distance
end

local function findFirstUsefulWaypoint(root, waypoints)
	for index, waypoint in waypoints do
		if waypoint.Action == Enum.PathWaypointAction.Jump then return index end
		if index == 1 and isWaypointReached(root, waypoint, FIRST_WAYPOINT_SKIP_DISTANCE) then continue end
		if isWaypointReached(root, waypoint, WAYPOINT_REACHED_DISTANCE) then continue end

		return index
	end

	return nil
end

local function getPathDebugFolder()
	local folder = workspace:FindFirstChild(PATH_DEBUG_FOLDER_NAME)

	if not folder then
		folder = Instance.new("Folder")
		folder.Name = PATH_DEBUG_FOLDER_NAME
		folder.Parent = workspace
	end

	return folder
end

local function clearOldPathDebug(debugName)
	local folder = getPathDebugFolder()
	local oldDebug = folder:FindFirstChild(debugName)

	if oldDebug then
		oldDebug:Destroy()
	end
end

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

local function createDebugLine(fromPosition, toPosition, parent)
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
	part.CFrame = CFrame.lookAt((fromPosition + toPosition) / 2, toPosition)
	part.Parent = parent
end

local function visualizePath(moveData, waypoints)
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

	for i, waypoint in waypoints do
		local color = Color3.fromRGB(0, 255, 120)
		local labelText = tostring(i) .. " NORMAL"

		if waypoint.Action == Enum.PathWaypointAction.Jump then
			color = Color3.fromRGB(255, 170, 0)
			labelText = tostring(i) .. " JUMP"
		end

		local ball = createDebugBall(waypoint.Position, color, debugFolder)
		createDebugLabel(ball, labelText)

		if waypoints[i - 1] then
			createDebugLine(
				waypoints[i - 1].Position + Vector3.new(0, 0.5, 0),
				waypoint.Position + Vector3.new(0, 0.5, 0),
				debugFolder
			)
		end
	end

	task.delay(PATH_DEBUG_LIFETIME, function()
		if debugFolder then
			debugFolder:Destroy()
		end
	end)
end

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

	task.delay(1.25, function()
		if marker then
			marker:Destroy()
		end
	end)
end

function PathMover:ComputePath(moveData)
	local path = computeBestPath(moveData)
	return path
end

function PathMover:Move(moveData)
	if isCancelled(moveData) then return end

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

	local pathFinished = false
	local blockedConnection
	local progressConnection
	local activeMoveConnection
	local currentWaypointIndex = 0

	local function removeConnection(connection)
		if not connection then return end
		connection:Disconnect()

		if moveData.RemoveConnection then
			moveData.RemoveConnection(connection)
		end
	end

	local function finishPath(result)
		if pathFinished then return end
		pathFinished = true

		removeConnection(blockedConnection)
		removeConnection(progressConnection)
		removeConnection(activeMoveConnection)
		activeMoveConnection = nil
		finish(moveData, result)
	end

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

	blockedConnection = path.Blocked:Connect(function(blockedWaypointIndex)
		if pathFinished then return end
		if isCancelled(moveData) then return end
		if blockedWaypointIndex < currentWaypointIndex then return end

		debugPath(moveData, "PathBlocked", "Index:", blockedWaypointIndex)
		finishPath("Failed")
	end)

	local lastProgressPosition = root.Position
	local lastProgressTime = os.clock()
	local progressAccumulator = 0

	progressConnection = RunService.Heartbeat:Connect(function(dt)
		if pathFinished then return end
		if isCancelled(moveData) then return end

		progressAccumulator += dt
		if progressAccumulator < STUCK_CHECK_RATE then return end
		progressAccumulator = 0

		if (root.Position - lastProgressPosition).Magnitude >= STUCK_MIN_PROGRESS then
			lastProgressPosition = root.Position
			lastProgressTime = os.clock()
			return
		end

		if os.clock() - lastProgressTime < STUCK_TIMEOUT then return end

		debugPath(moveData, "PathStuck", "Waypoint:", currentWaypointIndex)
		finishPath("Failed")
	end)

	if moveData.AddConnection then
		moveData.AddConnection(blockedConnection)
		moveData.AddConnection(progressConnection)
	end

	local jumpState = {
		LastJumpTime = 0,
		LastJumpPosition = nil,
	}

	local moveToWaypoint

	moveToWaypoint = function(index: number)
		if pathFinished then return end
		if isCancelled(moveData) then return end

		currentWaypointIndex = index

		while waypoints[index]
			and waypoints[index].Action ~= Enum.PathWaypointAction.Jump
			and isWaypointReached(root, waypoints[index], WAYPOINT_REACHED_DISTANCE) do

			index += 1
		end

		currentWaypointIndex = index

		local waypoint = waypoints[index] :: PathWaypoint

		if not waypoint then
			debugPath(moveData, "PathFinished", "Reached")
			finishPath("Reached")
			return
		end

		local actionName = waypoint.Action == Enum.PathWaypointAction.Jump and "Jump" or "Normal"
		debugPath(moveData, "Waypoint", "Index:", index, "Action:", actionName, "Position:", tostring(waypoint.Position))

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

				humanoid.Jump = true
				humanoid:ChangeState(Enum.HumanoidStateType.Jumping)

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

		activeMoveConnection = DirectMover:Move({
			Humanoid = humanoid,
			Root = root,
			Position = waypoint.Position,

			OnFinished = function(reached)
				local completedConnection = activeMoveConnection
				activeMoveConnection = nil
				removeConnection(completedConnection)

				if isCancelled(moveData) then return end

				debugPath(moveData, "WaypointFinished", "Index:", index, "Reached:", reached)

				if not reached then
					finishPath("Failed")
					return
				end

				moveToWaypoint(index + 1)
			end,
		})

		if not activeMoveConnection then
			finishPath("Failed")
			return
		end

		if moveData.AddConnection then
			moveData.AddConnection(activeMoveConnection)
		end
	end

	moveToWaypoint(startIndex)
end

return PathMover
