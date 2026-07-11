local ZombieBrain = {}

local ServerScriptService = game:GetService("ServerScriptService")
local CollectionService = game:GetService("CollectionService")

local Server = ServerScriptService.Server
local Types = require(Server.Types)
local CombatTactics = require(Server.AdvancedNPCAI.Brain.CombatTactics)
local SimpleCombat = require(Server.AdvancedNPCAI.Combat.SimpleCombat)

local RNG = Random.new()

local MODES = {
	IDLE = "Idle",
	WANDERING = "Wandering",
	RETURNING_HOME = "ReturningHome",

	CHASING = "Chasing",
	FIRST_SIGHT_INTERCEPTING = "FirstSightIntercepting",
	ATTACKING = "Attacking",
	EVADING = "Evading",

	RETURNING_TO_SEARCH = "ReturningToSearch",
	SEARCHING = "Searching",

	FLEEING = "Fleeing",
}

local DEFAULT_CONFIG = {
	AttackRange = 4,

	SearchMinConfidence = 0.12,
	SearchTime = 8,
	SearchArrivalDistance = 4,
	SearchPointRadius = 10,
	SearchRebuildDistance = 12,

	RepathRate = 0.25,
	MinimumActivePathAge = 0.1,
	AllowAirborneRepath = false,
	DebugMovement = false,
	MinRepathDistance = 2,

	VisibleLeadTime = 0.15,
	LostLeadTime = 0.8,
	MaxPredictionTime = 1.5,
	MaxPredictionDistance = 25,

	FirstSightInterceptEnabled = false,
	FirstSightMinTargetSpeed = 4,
	FirstSightMinLeadTime = 0.2,
	FirstSightMaxLeadTime = 1.2,
	FirstSightMaxLeadDistance = 18,
	FirstSightArrivalDistance = 3,
	FirstSightMaxTime = 1.75,
	FirstSightFrontDot = 0.25,
	FirstSightTurnTolerance = 0.55,
	FirstSightMaxGroundHeight = 12,

	WanderEnabled = true,
	WanderRadius = 35,
	WanderMinPause = 1.5,
	WanderMaxPause = 4,
	WanderArrivalDistance = 5,
	ReturnHomeEnabled = true,
	ReturnHomeDistance = 85,
	HomeArrivalDistance = 6,

	LowHealthFleeEnabled = true,
	LowHealthFleePercent = 0.28,
	LowHealthRecoverPercent = 0.45,

	FleeDistance = 35,
	FleeSideStep = 5,
	FleeArrivalDistance = 8,
	FleeRepathRate = 1.25,
	FleeMaxDistanceFromHome = 120,

	TargetCommitTime = 2,
	TargetSwitchDistanceAdvantage = 12,
	TargetSwitchConfidenceAdvantage = 0.35,
	RetaliationEnabled = true,
	RetaliationMemoryTime = 3.5,
	RetaliationBreaksCommit = true,

	TacticalMovementEnabled = false,
	DodgeEnabled = true,
	DodgeChance = 0.3,
	DodgeCooldown = 2.4,
	DodgeTriggerDistance = 6.5,
	DodgeBackstepDistance = 5,
	DodgeSideDistance = 3.5,
	DodgeSideChance = 0.55,
	DodgeCommitTime = 0.65,
	DodgeArrivalDistance = 1.75,
	DodgeMaxHeightChange = 3.5,
	DodgeReactionLockTime = 0.8,
	DodgeOnlyWhenTargetAttacking = true,

	GuardFearEnabled = false,
	GuardTag = "Guard",
	GuardAttribute = "NPCType",
	GuardAttributeValue = "Guard",
	GuardFaction = "Guard",
	GuardWeakHealthPercent = 0.35,
	GuardDetectDistance = 70,
}

local function getConfig(controller)
	local definition = controller.Definition or {}
	local brainConfig = definition.BrainConfig or {}
	local perception = definition.Perception or {}
	local memoryConfig = perception.Memory or {}

	return {
		AttackRange = brainConfig.AttackRange or DEFAULT_CONFIG.AttackRange,

		SearchMinConfidence = brainConfig.SearchMinConfidence or DEFAULT_CONFIG.SearchMinConfidence,
		SearchTime = brainConfig.SearchTime or memoryConfig.SearchTime or DEFAULT_CONFIG.SearchTime,
		SearchArrivalDistance = brainConfig.SearchArrivalDistance or DEFAULT_CONFIG.SearchArrivalDistance,
		SearchPointRadius = brainConfig.SearchPointRadius or DEFAULT_CONFIG.SearchPointRadius,
		SearchRebuildDistance = brainConfig.SearchRebuildDistance or DEFAULT_CONFIG.SearchRebuildDistance,

		RepathRate = brainConfig.RepathRate or DEFAULT_CONFIG.RepathRate,
		MinimumActivePathAge = brainConfig.MinimumActivePathAge or DEFAULT_CONFIG.MinimumActivePathAge,
		AllowAirborneRepath = if brainConfig.AllowAirborneRepath ~= nil then brainConfig.AllowAirborneRepath else DEFAULT_CONFIG.AllowAirborneRepath,
		DebugMovement = brainConfig.DebugMovement == true,
		MinRepathDistance = brainConfig.MinRepathDistance or DEFAULT_CONFIG.MinRepathDistance,

		VisibleLeadTime = brainConfig.VisibleLeadTime or DEFAULT_CONFIG.VisibleLeadTime,
		LostLeadTime = brainConfig.LostLeadTime or DEFAULT_CONFIG.LostLeadTime,
		MaxPredictionTime = brainConfig.MaxPredictionTime or DEFAULT_CONFIG.MaxPredictionTime,
		MaxPredictionDistance = brainConfig.MaxPredictionDistance or DEFAULT_CONFIG.MaxPredictionDistance,

		FirstSightInterceptEnabled = brainConfig.FirstSightInterceptEnabled == true,
		FirstSightMinTargetSpeed = brainConfig.FirstSightMinTargetSpeed or DEFAULT_CONFIG.FirstSightMinTargetSpeed,
		FirstSightMinLeadTime = brainConfig.FirstSightMinLeadTime or DEFAULT_CONFIG.FirstSightMinLeadTime,
		FirstSightMaxLeadTime = brainConfig.FirstSightMaxLeadTime or DEFAULT_CONFIG.FirstSightMaxLeadTime,
		FirstSightMaxLeadDistance = brainConfig.FirstSightMaxLeadDistance or DEFAULT_CONFIG.FirstSightMaxLeadDistance,
		FirstSightArrivalDistance = brainConfig.FirstSightArrivalDistance or DEFAULT_CONFIG.FirstSightArrivalDistance,
		FirstSightMaxTime = brainConfig.FirstSightMaxTime or DEFAULT_CONFIG.FirstSightMaxTime,
		FirstSightFrontDot = brainConfig.FirstSightFrontDot or DEFAULT_CONFIG.FirstSightFrontDot,
		FirstSightTurnTolerance = brainConfig.FirstSightTurnTolerance or DEFAULT_CONFIG.FirstSightTurnTolerance,
		FirstSightMaxGroundHeight = brainConfig.FirstSightMaxGroundHeight or DEFAULT_CONFIG.FirstSightMaxGroundHeight,

		WanderEnabled = if brainConfig.WanderEnabled ~= nil then brainConfig.WanderEnabled else DEFAULT_CONFIG.WanderEnabled,
		WanderRadius = brainConfig.WanderRadius or DEFAULT_CONFIG.WanderRadius,
		WanderMinPause = brainConfig.WanderMinPause or DEFAULT_CONFIG.WanderMinPause,
		WanderMaxPause = brainConfig.WanderMaxPause or DEFAULT_CONFIG.WanderMaxPause,
		WanderArrivalDistance = brainConfig.WanderArrivalDistance or DEFAULT_CONFIG.WanderArrivalDistance,
		ReturnHomeEnabled = if brainConfig.ReturnHomeEnabled ~= nil then brainConfig.ReturnHomeEnabled else DEFAULT_CONFIG.ReturnHomeEnabled,
		ReturnHomeDistance = brainConfig.ReturnHomeDistance or DEFAULT_CONFIG.ReturnHomeDistance,
		HomeArrivalDistance = brainConfig.HomeArrivalDistance or DEFAULT_CONFIG.HomeArrivalDistance,

		LowHealthFleeEnabled = if brainConfig.LowHealthFleeEnabled ~= nil then brainConfig.LowHealthFleeEnabled else DEFAULT_CONFIG.LowHealthFleeEnabled,
		LowHealthFleePercent = brainConfig.LowHealthFleePercent or DEFAULT_CONFIG.LowHealthFleePercent,
		LowHealthRecoverPercent = brainConfig.LowHealthRecoverPercent or DEFAULT_CONFIG.LowHealthRecoverPercent,

		FleeDistance = brainConfig.FleeDistance or DEFAULT_CONFIG.FleeDistance,
		FleeSideStep = brainConfig.FleeSideStep or DEFAULT_CONFIG.FleeSideStep,
		FleeArrivalDistance = brainConfig.FleeArrivalDistance or DEFAULT_CONFIG.FleeArrivalDistance,
		FleeRepathRate = brainConfig.FleeRepathRate or DEFAULT_CONFIG.FleeRepathRate,
		FleeMaxDistanceFromHome = brainConfig.FleeMaxDistanceFromHome or DEFAULT_CONFIG.FleeMaxDistanceFromHome,

		TargetCommitTime = brainConfig.TargetCommitTime or DEFAULT_CONFIG.TargetCommitTime,
		TargetSwitchDistanceAdvantage = brainConfig.TargetSwitchDistanceAdvantage or DEFAULT_CONFIG.TargetSwitchDistanceAdvantage,
		TargetSwitchConfidenceAdvantage = brainConfig.TargetSwitchConfidenceAdvantage or DEFAULT_CONFIG.TargetSwitchConfidenceAdvantage,
		RetaliationEnabled = if brainConfig.RetaliationEnabled ~= nil then brainConfig.RetaliationEnabled else DEFAULT_CONFIG.RetaliationEnabled,
		RetaliationMemoryTime = brainConfig.RetaliationMemoryTime or DEFAULT_CONFIG.RetaliationMemoryTime,
		RetaliationBreaksCommit = if brainConfig.RetaliationBreaksCommit ~= nil then brainConfig.RetaliationBreaksCommit else DEFAULT_CONFIG.RetaliationBreaksCommit,

		TacticalMovementEnabled = brainConfig.TacticalMovementEnabled == true,
		DodgeEnabled = if brainConfig.DodgeEnabled ~= nil then brainConfig.DodgeEnabled else DEFAULT_CONFIG.DodgeEnabled,
		DodgeChance = brainConfig.DodgeChance or DEFAULT_CONFIG.DodgeChance,
		DodgeCooldown = brainConfig.DodgeCooldown or DEFAULT_CONFIG.DodgeCooldown,
		DodgeTriggerDistance = brainConfig.DodgeTriggerDistance or DEFAULT_CONFIG.DodgeTriggerDistance,
		DodgeBackstepDistance = brainConfig.DodgeBackstepDistance or DEFAULT_CONFIG.DodgeBackstepDistance,
		DodgeSideDistance = brainConfig.DodgeSideDistance or DEFAULT_CONFIG.DodgeSideDistance,
		DodgeSideChance = brainConfig.DodgeSideChance or DEFAULT_CONFIG.DodgeSideChance,
		DodgeCommitTime = brainConfig.DodgeCommitTime or DEFAULT_CONFIG.DodgeCommitTime,
		DodgeArrivalDistance = brainConfig.DodgeArrivalDistance or DEFAULT_CONFIG.DodgeArrivalDistance,
		DodgeMaxHeightChange = brainConfig.DodgeMaxHeightChange or DEFAULT_CONFIG.DodgeMaxHeightChange,
		DodgeReactionLockTime = brainConfig.DodgeReactionLockTime or DEFAULT_CONFIG.DodgeReactionLockTime,
		DodgeOnlyWhenTargetAttacking = if brainConfig.DodgeOnlyWhenTargetAttacking ~= nil then brainConfig.DodgeOnlyWhenTargetAttacking else DEFAULT_CONFIG.DodgeOnlyWhenTargetAttacking,

		GuardFearEnabled = if brainConfig.GuardFearEnabled ~= nil then brainConfig.GuardFearEnabled else DEFAULT_CONFIG.GuardFearEnabled,
		GuardTag = brainConfig.GuardTag or DEFAULT_CONFIG.GuardTag,
		GuardAttribute = brainConfig.GuardAttribute or DEFAULT_CONFIG.GuardAttribute,
		GuardAttributeValue = brainConfig.GuardAttributeValue or DEFAULT_CONFIG.GuardAttributeValue,
		GuardFaction = brainConfig.GuardFaction or DEFAULT_CONFIG.GuardFaction,
		GuardWeakHealthPercent = brainConfig.GuardWeakHealthPercent or DEFAULT_CONFIG.GuardWeakHealthPercent,
		GuardDetectDistance = brainConfig.GuardDetectDistance or DEFAULT_CONFIG.GuardDetectDistance,
	}
end

local function setMode(blackboard, mode)
	if blackboard.Mode == mode then return false end

	blackboard.Mode = mode
	blackboard.ModeStartedTime = os.clock()

	return true
end

local function debugPrint(config, ...)
	if not config.DebugMovement then return end

	print("[ZombieBrain]", ...)
end

local function getDistance(controller, position)
	if not controller.Root then return math.huge end
	if not position then return math.huge end

	return (position - controller.Root.Position).Magnitude
end

local function getFlatVelocity(memory)
	local velocity = memory.LastKnownVelocity or Vector3.zero
	return Vector3.new(velocity.X, 0, velocity.Z)
end

local function getFlatVector(vector)
	if not vector then return Vector3.zero end

	return Vector3.new(vector.X, 0, vector.Z)
end

local function clampVector(vector, maxMagnitude)
	if vector.Magnitude <= maxMagnitude then return vector end
	if vector.Magnitude <= 0 then return Vector3.zero end

	return vector.Unit * maxMagnitude
end

local function getSafeUnit(vector, fallback)
	if vector.Magnitude > 0.01 then return vector.Unit end

	return fallback
end

local function getRandomFlatDirection()
	local x = RNG:NextNumber(-1, 1)
	local z = RNG:NextNumber(-1, 1)
	local direction = Vector3.new(x, 0, z)

	return getSafeUnit(direction, Vector3.new(0, 0, -1))
end

local function getHumanoidHealthPercent(humanoid)
	if not humanoid then return 1 end
	if humanoid.MaxHealth <= 0 then return 1 end

	return math.clamp(humanoid.Health / humanoid.MaxHealth, 0, 1)
end

local function getControllerHealthPercent(controller)
	return getHumanoidHealthPercent(controller.Humanoid)
end

local function getMemoryHealthPercent(memory)
	if not memory then return 1 end

	return getHumanoidHealthPercent(memory.Humanoid)
end

local function getMemoryPosition(memory)
	if not memory then return end
	if memory.Root then return memory.Root.Position end
	if memory.LastKnownPosition then return memory.LastKnownPosition end
	if memory.LastSeenPosition then return memory.LastSeenPosition end

	return
end

local function isMemoryUsable(memory)
	if not memory then return false end
	if not memory.Character then return false end
	if not memory.Character.Parent then return false end
	if not memory.Humanoid then return false end
	if memory.Humanoid.Health <= 0 then return false end
	if not memory.Confidence then return false end
	if memory.Confidence <= 0 then return false end

	return true
end

local function getPredictionTime(memory, config)
	if memory.CurrentlyVisible then return config.VisibleLeadTime end

	local timeSinceSeen = os.clock() - (memory.LastSeenTime or os.clock())
	local confidence = math.clamp(memory.Confidence or 0, 0, 1)
	local predictionTime = config.LostLeadTime + (timeSinceSeen * 0.25)

	predictionTime = math.min(predictionTime, config.MaxPredictionTime)
	predictionTime *= math.max(confidence, 0.25)

	return predictionTime
end

local function getPredictedPosition(memory, config)
	if memory.CurrentlyVisible and memory.Root then
		local velocity = Vector3.new(memory.Root.AssemblyLinearVelocity.X, 0, memory.Root.AssemblyLinearVelocity.Z)
		local offset = clampVector(velocity * config.VisibleLeadTime, config.MaxPredictionDistance)

		return memory.Root.Position + offset
	end

	local basePosition = memory.LastKnownPosition or memory.LastSeenPosition
	if not basePosition then return end

	local velocity = getFlatVelocity(memory)
	local predictionTime = getPredictionTime(memory, config)
	local offset = clampVector(velocity * predictionTime, config.MaxPredictionDistance)

	return basePosition + offset
end

local function shouldSwitchTarget(controller, blackboard, config, currentTarget, nextTarget)
	if not isMemoryUsable(nextTarget) then return false end
	if not isMemoryUsable(currentTarget) then return true end
	if currentTarget == nextTarget then return false end

	local committedTime = blackboard.TargetCommittedTime or 0
	if os.clock() - committedTime < config.TargetCommitTime then return false end

	local currentPosition = getMemoryPosition(currentTarget)
	local nextPosition = getMemoryPosition(nextTarget)
	local currentDistance = getDistance(controller, currentPosition)
	local nextDistance = getDistance(controller, nextPosition)
	local distanceAdvantage = currentDistance - nextDistance
	local confidenceAdvantage = (nextTarget.Confidence or 0) - (currentTarget.Confidence or 0)

	if distanceAdvantage >= config.TargetSwitchDistanceAdvantage then return true end
	if confidenceAdvantage >= config.TargetSwitchConfidenceAdvantage then return true end

	return false
end

local function commitTarget(blackboard, memory)
	if blackboard.CurrentTarget == memory then return end

	blackboard.FirstSight = nil
	blackboard.FirstSightTargetKey = nil
	blackboard.CurrentTarget = memory
	blackboard.TargetCommittedTime = os.clock()
	blackboard.LastMovePosition = nil
	blackboard.MovementMode = nil
	blackboard.SearchStartedTime = nil
	blackboard.SearchPoints = nil
	blackboard.SearchIndex = nil
	blackboard.SearchCenter = nil
end

local function getRecentAttackerMemory(controller, currentTarget, config)
	if not config.RetaliationEnabled then return nil, false end
	if not controller.Perception then return nil, false end
	if not controller.Perception.GetAllMemories then return nil, false end

	local recentHits = SimpleCombat:GetRecentAttackers(controller.Model, config.RetaliationMemoryTime)
	local hitByCharacter = {}
	local latestHitTime = -math.huge
	local latestAttackerCharacter = nil

	for i, recentHit in recentHits do
		local attackerCharacter = recentHit.AttackerCharacter
		if not attackerCharacter then continue end

		hitByCharacter[attackerCharacter] = recentHit

		if recentHit.LastDamageTime > latestHitTime then
			latestHitTime = recentHit.LastDamageTime
			latestAttackerCharacter = attackerCharacter
		end
	end

	if not latestAttackerCharacter then return nil, false end

	local memories = controller.Perception:GetAllMemories()
	local recentAttackerMemory = nil

	for targetKey, memory in memories do
		if memory.Character ~= latestAttackerCharacter then continue end
		if not isMemoryUsable(memory) then break end

		recentAttackerMemory = memory
		break
	end

	local currentTargetWasRecent = currentTarget and hitByCharacter[currentTarget.Character] ~= nil

	return recentAttackerMemory, currentTargetWasRecent
end

local function getTargetMemory(controller, blackboard, config)
	local currentTarget = blackboard.CurrentTarget

	if not controller.Perception then return currentTarget end

	local recentAttacker, currentTargetWasRecent = getRecentAttackerMemory(controller, currentTarget, config)
	if recentAttacker and recentAttacker ~= currentTarget then
		if (config.RetaliationBreaksCommit and not currentTargetWasRecent) or shouldSwitchTarget(controller, blackboard, config, currentTarget, recentAttacker) then
			commitTarget(blackboard, recentAttacker)
			return recentAttacker
		end
	end

	local bestTarget = controller.Perception:GetBestTarget()
	if shouldSwitchTarget(controller, blackboard, config, currentTarget, bestTarget) then
		commitTarget(blackboard, bestTarget)
		return bestTarget
	end

	if isMemoryUsable(currentTarget) then return currentTarget end

	return bestTarget
end

local function addMemoriesFromTable(memoryList, memories)
	if typeof(memories) ~= "table" then return end

	for i, memory in memories do
		if isMemoryUsable(memory) then
			table.insert(memoryList, memory)
		end
	end
end

local function getKnownMemories(controller)
	local memoryList = {}

	if not controller.Perception then return memoryList end

	local perception = controller.Perception

	if perception.GetVisibleMemories then
		local visibleMemories = perception:GetVisibleMemories()
		addMemoriesFromTable(memoryList, visibleMemories)
	end

	if #memoryList > 0 then return memoryList end

	if perception.GetMemories then
		local memories = perception:GetMemories()
		addMemoriesFromTable(memoryList, memories)
	end

	if #memoryList > 0 then return memoryList end

	if perception.Memories then
		addMemoriesFromTable(memoryList, perception.Memories)
	end

	if #memoryList > 0 then return memoryList end

	if perception.TargetMemory and perception.TargetMemory.Memories then
		addMemoriesFromTable(memoryList, perception.TargetMemory.Memories)
	end

	return memoryList
end

local function hasCollectionTag(instance, tagName)
	if not instance then return false end
	if not tagName then return false end
	if tagName == "" then return false end

	return CollectionService:HasTag(instance, tagName)
end

local function hasMatchingAttribute(instance, attributeName, attributeValue)
	if not instance then return false end
	if not attributeName then return false end
	if attributeName == "" then return false end

	return instance:GetAttribute(attributeName) == attributeValue
end

local function isGuardMemory(memory, config)
	if not memory then return false end

	local character = memory.Character
	local humanoid = memory.Humanoid
	local root = memory.Root

	if memory.IsGuard == true then return true end
	if memory.Role == "Guard" then return true end
	if memory.Faction == config.GuardFaction then return true end

	if hasCollectionTag(character, config.GuardTag) then return true end
	if hasCollectionTag(humanoid, config.GuardTag) then return true end
	if hasCollectionTag(root, config.GuardTag) then return true end

	if hasMatchingAttribute(character, config.GuardAttribute, config.GuardAttributeValue) then return true end
	if hasMatchingAttribute(humanoid, config.GuardAttribute, config.GuardAttributeValue) then return true end
	if hasMatchingAttribute(root, config.GuardAttribute, config.GuardAttributeValue) then return true end

	if character and character:GetAttribute("Faction") == config.GuardFaction then return true end
	if character and character:GetAttribute("IsGuard") == true then return true end

	return false
end

local function isGuardWeak(memory, config)
	return getMemoryHealthPercent(memory) <= config.GuardWeakHealthPercent
end

local function getBestGuardThreat(controller, config)
	local bestThreat = nil
	local bestDistance = math.huge
	local memories = getKnownMemories(controller)

	for i, memory in memories do
		if memory.CurrentlyVisible and isGuardMemory(memory, config) and not isGuardWeak(memory, config) then
			local position = getMemoryPosition(memory)
			local distance = getDistance(controller, position)

			if distance <= config.GuardDetectDistance and distance < bestDistance then
				bestThreat = memory
				bestDistance = distance
			end
		end
	end

	return bestThreat
end

local function shouldLowHealthFlee(controller, blackboard, config)
	if not config.LowHealthFleeEnabled then return false end

	local healthPercent = getControllerHealthPercent(controller)

	if blackboard.Mode == MODES.FLEEING then
		return healthPercent <= config.LowHealthRecoverPercent
	end

	return healthPercent <= config.LowHealthFleePercent
end

local function shouldRepath(blackboard, config, position, movementMode, force)
	if force then return true end
	if movementMode and blackboard.MovementMode ~= movementMode then return true end

	local currentTime = os.clock()
	local lastRepathTime = blackboard.LastRepathTime or 0

	if currentTime - lastRepathTime < config.RepathRate then return false end

	local lastMovePosition = blackboard.LastMovePosition
	if not lastMovePosition then return true end

	return (position - lastMovePosition).Magnitude >= config.MinRepathDistance
end

local function shouldUsePathfinding(controller, memory, position)
	local movementConfig = controller.Definition.Movement or {}

	if not movementConfig.UsePathfinding then return false end
	if not controller.Movement.PathfindTo then return false end

	if memory and memory.CurrentlyVisible then
		if movementConfig.UsePathfindingWhenVisible == true then return true end

		local pathfindDistance = movementConfig.PathfindDistance
		if pathfindDistance and getDistance(controller, position) >= pathfindDistance then return true end
		if controller.Movement.IsDirectMoveRecentlyBlocked and controller.Movement:IsDirectMoveRecentlyBlocked(position) then return true end
		if controller.Movement.HasClearDirectPath and not controller.Movement:HasClearDirectPath(position, memory.Character) then return true end

		return false
	end

	return movementConfig.UsePathfindingWhenHidden ~= false
end

local function moveTo(controller: Types.Controller, blackboard: {}, config, memory: Types.Memory?, position, force)
	if not controller.Movement then return end
	if not position then return end

	local usePathfinding = shouldUsePathfinding(controller, memory, position)
	local movementMode = usePathfinding and "Path" or "Direct"

	if not shouldRepath(blackboard, config, position, movementMode, force) then return end

	blackboard.LastRepathTime = os.clock()
	blackboard.LastMovePosition = position
	blackboard.MovementMode = movementMode

	local moveOptions = {
		Requester = "Brain",
		MinimumActivePathAge = config.MinimumActivePathAge,
		AllowAirborneRepath = config.AllowAirborneRepath,
		DebugMovement = config.DebugMovement,
	}

	if usePathfinding then
		controller.Movement:PathfindTo(position, moveOptions)
		return
	end

	controller.Movement:MoveTo(position, moveOptions)
end

local function stopMovement(controller)
	if not controller.Movement then return end
	if not controller.Movement.Stop then return end

	controller.Movement:Stop()
end

local function resetMovementRequestData(blackboard)
	blackboard.LastMovePosition = nil
	blackboard.MovementMode = nil
end

local function clearSearchPoints(blackboard)
	blackboard.SearchPoints = nil
	blackboard.SearchIndex = nil
	blackboard.SearchCenter = nil
end

local function clearSearchData(blackboard)
	blackboard.SearchStartedTime = nil
	clearSearchPoints(blackboard)
end

local function clearWanderData(blackboard)
	blackboard.WanderGoal = nil
	blackboard.NextWanderTime = nil
end

local function clearFleeData(blackboard)
	blackboard.FleeGoal = nil
	blackboard.LastFleeGoalTime = nil
	blackboard.FleeThreat = nil
end

local function clearTargetData(blackboard)
	blackboard.CurrentTarget = nil
	blackboard.TargetCommittedTime = nil
	blackboard.LastKnownPosition = nil
	blackboard.WantsAttack = false
	blackboard.AttackTarget = nil
	blackboard.SearchPrepareStartedTime = nil
	blackboard.ResearchQueued = nil
	blackboard.FirstSight = nil
	blackboard.FirstSightTargetKey = nil

	resetMovementRequestData(blackboard)
	clearSearchData(blackboard)
	clearFleeData(blackboard)
end

local function getFirstSightTargetKey(memory)
	if not memory then return end
	if memory.TargetKey ~= nil then return memory.TargetKey end

	return memory.Character
end

local function getRootGroundOffset(controller)
	local root = controller.Root
	if not root then return 3 end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = {controller.Model}
	params.RespectCanCollide = true

	local result = workspace:Raycast(root.Position + Vector3.new(0, 2, 0), Vector3.new(0, -10, 0), params)
	if not result then return 3 end

	return math.clamp(root.Position.Y - result.Position.Y, 1.5, 6)
end

local function groundFirstSightPosition(controller, memory, position, config)
	local params = RaycastParams.new()
	local ignored = {controller.Model}

	if memory.Character then
		table.insert(ignored, memory.Character)
	end

	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignored
	params.RespectCanCollide = true

	local rayHeight = config.FirstSightMaxGroundHeight
	local origin = position + Vector3.new(0, rayHeight, 0)
	local result = workspace:Raycast(origin, Vector3.new(0, -(rayHeight * 2 + 8), 0), params)

	if not result then return end
	if math.abs(result.Position.Y - position.Y) > rayHeight then return end

	return Vector3.new(position.X, result.Position.Y + getRootGroundOffset(controller), position.Z)
end

local function clearFirstSight(controller, blackboard, reason)
	local firstSight = blackboard.FirstSight
	if not firstSight then return end

	firstSight.Active = false
	firstSight.FinishedTime = os.clock()
	firstSight.FinishReason = reason

	if controller and controller.Model then
		controller.Model:SetAttribute("FirstSightIntercept", false)
		controller.Model:SetAttribute("FirstSightInterceptReason", reason)
	end
end

local function tryStartFirstSightIntercept(controller, blackboard, memory, config)
	if not config.FirstSightInterceptEnabled then return false end
	if not memory.CurrentlyVisible then return false end
	if not memory.Root then return false end
	if not controller.Root then return false end
	if not controller.Movement.PathfindTo then return false end

	local targetKey = getFirstSightTargetKey(memory)
	if targetKey == nil then return false end
	if blackboard.FirstSightTargetKey == targetKey then return false end

	blackboard.FirstSightTargetKey = targetKey

	local targetPosition = memory.Root.Position
	local targetVelocity = getFlatVector(memory.Root.AssemblyLinearVelocity)
	local targetSpeed = targetVelocity.Magnitude
	local firstSight = {
		TargetKey = targetKey,
		SeenTime = os.clock(),
		StartPosition = targetPosition,
		StartVelocity = targetVelocity,
		Active = false,
	}

	blackboard.FirstSight = firstSight

	if targetSpeed < config.FirstSightMinTargetSpeed then
		firstSight.FinishReason = "TargetTooSlow"
		return false
	end

	local travelDirection = targetVelocity.Unit
	local targetToNPC = getFlatVector(controller.Root.Position - targetPosition)
	local targetToNPCDirection = getSafeUnit(targetToNPC, -travelDirection)
	local frontDot = travelDirection:Dot(targetToNPCDirection)
	local travelTime = targetToNPC.Magnitude / math.max(controller.Humanoid.WalkSpeed, 1)
	local leadTime = math.clamp(travelTime, config.FirstSightMinLeadTime, config.FirstSightMaxLeadTime)
	local leadDistance = math.clamp(targetSpeed * leadTime, config.FirstSightMinTargetSpeed, config.FirstSightMaxLeadDistance)

	if frontDot >= config.FirstSightFrontDot then
		local currentForwardDistance = math.max(targetToNPC:Dot(travelDirection), 0)
		leadDistance = math.max(leadDistance, math.min(currentForwardDistance + config.FirstSightArrivalDistance, config.FirstSightMaxLeadDistance))
	end

	local interceptPosition = targetPosition + travelDirection * leadDistance
	interceptPosition = groundFirstSightPosition(controller, memory, interceptPosition, config)

	if not interceptPosition then
		firstSight.FinishReason = "NoGround"
		return false
	end

	firstSight.StartDirection = travelDirection
	firstSight.InterceptPosition = interceptPosition
	firstSight.WasInFront = frontDot >= config.FirstSightFrontDot
	firstSight.Active = true

	setMode(blackboard, MODES.FIRST_SIGHT_INTERCEPTING)

	blackboard.CurrentTarget = memory
	blackboard.LastKnownPosition = targetPosition
	blackboard.WantsAttack = false
	blackboard.AttackTarget = nil

	clearSearchData(blackboard)
	clearWanderData(blackboard)
	clearFleeData(blackboard)
	resetMovementRequestData(blackboard)

	blackboard.LastRepathTime = os.clock()
	blackboard.LastMovePosition = interceptPosition
	blackboard.MovementMode = "Path"

	controller.Model:SetAttribute("FirstSightIntercept", true)
	controller.Model:SetAttribute("FirstSightInterceptPosition", interceptPosition)
	controller.Model:SetAttribute("FirstSightInterceptReason", nil)

	controller.Movement:PathfindTo(interceptPosition, {
		Requester = "FirstSightIntercept",
		Force = true,
		MinimumActivePathAge = config.MinimumActivePathAge,
		AllowAirborneRepath = false,
		DebugMovement = config.DebugMovement,
		TargetPosition = interceptPosition,
	})

	debugPrint(config, "First sight intercept", memory.Character, interceptPosition, "InFront:", firstSight.WasInFront)

	return true
end

local function updateFirstSightIntercept(controller, blackboard, memory, config)
	local firstSight = blackboard.FirstSight
	if not firstSight or not firstSight.Active then return false end

	if getFirstSightTargetKey(memory) ~= firstSight.TargetKey then
		clearFirstSight(controller, blackboard, "TargetChanged")
		return false
	end

	if not memory.CurrentlyVisible or not memory.Root then
		clearFirstSight(controller, blackboard, "TargetLost")
		return false
	end

	if os.clock() - firstSight.SeenTime >= config.FirstSightMaxTime then
		clearFirstSight(controller, blackboard, "Expired")
		return false
	end

	if getDistance(controller, firstSight.InterceptPosition) <= config.FirstSightArrivalDistance then
		clearFirstSight(controller, blackboard, "Reached")
		return false
	end

	local movement = controller.Movement
	if not movement.IsMoving or movement.CurrentRequester ~= "FirstSightIntercept" then
		clearFirstSight(controller, blackboard, "PathEnded")
		return false
	end

	local targetVelocity = getFlatVector(memory.Root.AssemblyLinearVelocity)
	if targetVelocity.Magnitude < config.FirstSightMinTargetSpeed then
		clearFirstSight(controller, blackboard, "TargetSlowed")
		return false
	end

	if firstSight.StartDirection:Dot(targetVelocity.Unit) < config.FirstSightTurnTolerance then
		clearFirstSight(controller, blackboard, "TargetTurned")
		return false
	end

	setMode(blackboard, MODES.FIRST_SIGHT_INTERCEPTING)
	blackboard.CurrentTarget = memory
	blackboard.LastKnownPosition = memory.Root.Position
	blackboard.WantsAttack = false
	blackboard.AttackTarget = nil

	return true
end

local function setHomePosition(controller, blackboard)
	if blackboard.HomePosition then return end
	if not controller.Root then return end

	blackboard.HomePosition = controller.Root.Position
end

local function getHomePosition(controller, blackboard)
	setHomePosition(controller, blackboard)

	return blackboard.HomePosition
end

local function scheduleNextWander(blackboard, config)
	blackboard.NextWanderTime = os.clock() + RNG:NextNumber(config.WanderMinPause, config.WanderMaxPause)
end

local function getRandomPointAround(position, radius)
	local direction = getRandomFlatDirection()
	local distance = RNG:NextNumber(radius * 0.35, radius)

	return position + direction * distance
end

local function getWanderGoal(controller, blackboard, config)
	local homePosition = getHomePosition(controller, blackboard)
	if not homePosition then return end

	return getRandomPointAround(homePosition, config.WanderRadius)
end

local function returnHome(controller, blackboard, config)
	local homePosition = getHomePosition(controller, blackboard)

	if not homePosition then
		setMode(blackboard, MODES.IDLE)
		stopMovement(controller)
		return
	end

	local changed = setMode(blackboard, MODES.RETURNING_HOME)

	blackboard.CurrentTarget = nil
	blackboard.WantsAttack = false
	blackboard.AttackTarget = nil

	if changed then
		clearWanderData(blackboard)
		clearSearchData(blackboard)
		resetMovementRequestData(blackboard)
	end

	if getDistance(controller, homePosition) <= config.HomeArrivalDistance then
		setMode(blackboard, MODES.IDLE)
		stopMovement(controller)
		scheduleNextWander(blackboard, config)
		return
	end

	moveTo(controller, blackboard, config, nil, homePosition, changed)
end

local function wander(controller, blackboard, config)
	if not config.WanderEnabled then
		local changed = setMode(blackboard, MODES.IDLE)

		clearTargetData(blackboard)

		if changed then stopMovement(controller) end
		return
	end

	local homePosition = getHomePosition(controller, blackboard)

	if config.ReturnHomeEnabled and homePosition and getDistance(controller, homePosition) >= config.ReturnHomeDistance then
		returnHome(controller, blackboard, config)
		return
	end

	local currentTime = os.clock()

	if not blackboard.NextWanderTime then
		scheduleNextWander(blackboard, config)
	end

	if blackboard.WanderGoal and getDistance(controller, blackboard.WanderGoal) <= config.WanderArrivalDistance then
		blackboard.WanderGoal = nil
		scheduleNextWander(blackboard, config)
		setMode(blackboard, MODES.IDLE)
		stopMovement(controller)
		return
	end

	if not blackboard.WanderGoal and currentTime < blackboard.NextWanderTime then
		local changed = setMode(blackboard, MODES.IDLE)

		if changed then stopMovement(controller) end
		return
	end

	if not blackboard.WanderGoal then
		blackboard.WanderGoal = getWanderGoal(controller, blackboard, config)
		resetMovementRequestData(blackboard)
	end

	if not blackboard.WanderGoal then
		setMode(blackboard, MODES.IDLE)
		stopMovement(controller)
		return
	end

	local changed = setMode(blackboard, MODES.WANDERING)

	clearTargetData(blackboard)
	blackboard.WanderGoal = blackboard.WanderGoal

	moveTo(controller, blackboard, config, nil, blackboard.WanderGoal, changed)
end

local function getSearchCenter(memory, config)
	local lastSeenPosition = memory.LastSeenPosition
	local lastKnownPosition = memory.LastKnownPosition
	local predictedPosition = getPredictedPosition(memory, config)

	if lastSeenPosition then return lastSeenPosition end
	if lastKnownPosition then return lastKnownPosition end

	return predictedPosition
end

local function buildSearchPoints(center, memory, config)
	local velocity = getFlatVelocity(memory)
	local forward = getSafeUnit(velocity, Vector3.new(0, 0, -1))
	local right = getSafeUnit(Vector3.new(forward.Z, 0, -forward.X), Vector3.new(1, 0, 0))
	local radius = config.SearchPointRadius
	local predictedPosition = getPredictedPosition(memory, config)
	local forwardRight = getSafeUnit(forward + right, forward)
	local forwardLeft = getSafeUnit(forward - right, forward)
	local backRight = getSafeUnit(-forward + right, -forward)
	local backLeft = getSafeUnit(-forward - right, -forward)

	local points = {
		center,
		center + forward * radius,
		center + right * radius,
		center - right * radius,
		center - forward * radius,
		center + forwardRight * radius,
		center + forwardLeft * radius,
		center + backRight * radius,
		center + backLeft * radius,
	}

	if predictedPosition and (predictedPosition - center).Magnitude >= 2 then
		table.insert(points, 2, predictedPosition)
	end

	return points
end

local function shouldRebuildSearchPoints(blackboard, center, config)
	if not blackboard.SearchPoints then return true end
	if not blackboard.SearchCenter then return true end

	return (center - blackboard.SearchCenter).Magnitude >= config.SearchRebuildDistance
end

local function getSearchGoal(controller, blackboard, memory, config, center)
	if shouldRebuildSearchPoints(blackboard, center, config) then
		blackboard.SearchPoints = buildSearchPoints(center, memory, config)
		blackboard.SearchIndex = 1
		blackboard.SearchCenter = center
		resetMovementRequestData(blackboard)
	end

	local searchIndex = blackboard.SearchIndex or 1
	local goal = blackboard.SearchPoints[searchIndex] or center

	if getDistance(controller, goal) > config.SearchArrivalDistance then return goal end

	searchIndex += 1

	if searchIndex > #blackboard.SearchPoints then
		searchIndex = 1
	end

	blackboard.SearchIndex = searchIndex

	return blackboard.SearchPoints[searchIndex] or center
end

local function idle(controller, blackboard, config)
	wander(controller, blackboard, config)
end

local function evade(controller, blackboard, memory, config)
	if not CombatTactics:Update(controller, blackboard, memory, config) then return false end

	setMode(blackboard, MODES.EVADING)

	blackboard.CurrentTarget = memory
	blackboard.LastKnownPosition = memory.LastKnownPosition
	blackboard.WantsAttack = false
	blackboard.AttackTarget = nil

	clearSearchData(blackboard)
	clearWanderData(blackboard)
	clearFleeData(blackboard)

	return true
end

local function attack(controller, blackboard, memory, config)
	setMode(blackboard, MODES.ATTACKING)

	blackboard.CurrentTarget = memory
	blackboard.AttackTarget = memory
	blackboard.WantsAttack = true
	blackboard.LastKnownPosition = memory.LastKnownPosition

	clearSearchData(blackboard)
	clearWanderData(blackboard)
	clearFleeData(blackboard)

	debugPrint(config, "Attacking", memory.Character)
	stopMovement(controller)
	SimpleCombat:TryMeleeAttack(controller, memory)
end

local function chase(controller, blackboard, memory, config, position)
	local changed = setMode(blackboard, MODES.CHASING)

	blackboard.CurrentTarget = memory
	blackboard.LastKnownPosition = position
	blackboard.WantsAttack = false
	blackboard.AttackTarget = nil

	clearSearchData(blackboard)
	clearWanderData(blackboard)
	clearFleeData(blackboard)

	moveTo(controller, blackboard, config, memory, position, changed)
end

local function beginLostSearch(controller, blackboard, memory, config, center)
	local changed = setMode(blackboard, MODES.RETURNING_TO_SEARCH)

	blackboard.CurrentTarget = memory
	blackboard.LastKnownPosition = center
	blackboard.WantsAttack = false
	blackboard.AttackTarget = nil
	blackboard.SearchStartedTime = os.clock()

	clearSearchPoints(blackboard)
	clearWanderData(blackboard)
	clearFleeData(blackboard)
	resetMovementRequestData(blackboard)

	debugPrint(config, "Lost target, returning to search area")

	moveTo(controller, blackboard, config, memory, center, changed)
end

local function returnToSearchArea(controller, blackboard, memory, config, center)
	local searchStartedTime = blackboard.SearchStartedTime or os.clock()
	local searchAge = os.clock() - searchStartedTime

	blackboard.CurrentTarget = memory
	blackboard.LastKnownPosition = center
	blackboard.WantsAttack = false
	blackboard.AttackTarget = nil

	if searchAge >= config.SearchTime then
		idle(controller, blackboard, config)
		return
	end

	if getDistance(controller, center) > config.SearchArrivalDistance then
		moveTo(controller, blackboard, config, memory, center, false)
		return
	end

	setMode(blackboard, MODES.SEARCHING)
	clearSearchPoints(blackboard)
	resetMovementRequestData(blackboard)
end

local function searchAroundArea(controller, blackboard, memory, config, center)
	local searchStartedTime = blackboard.SearchStartedTime or os.clock()
	local searchAge = os.clock() - searchStartedTime

	blackboard.CurrentTarget = memory
	blackboard.LastKnownPosition = center
	blackboard.WantsAttack = false
	blackboard.AttackTarget = nil

	if searchAge >= config.SearchTime then
		debugPrint(config, "Search failed, going passive")
		idle(controller, blackboard, config)
		return
	end

	local goal = getSearchGoal(controller, blackboard, memory, config, center)

	moveTo(controller, blackboard, config, memory, goal, false)
end

local function lostSearch(controller, blackboard, memory, config)
	local center = getSearchCenter(memory, config)

	if not center then
		idle(controller, blackboard, config)
		return
	end

	if blackboard.Mode ~= MODES.RETURNING_TO_SEARCH and blackboard.Mode ~= MODES.SEARCHING then
		beginLostSearch(controller, blackboard, memory, config, center)
		return
	end

	if blackboard.Mode == MODES.RETURNING_TO_SEARCH then
		returnToSearchArea(controller, blackboard, memory, config, center)
		return
	end

	searchAroundArea(controller, blackboard, memory, config, center)
end

local function getFleeGoal(controller, blackboard, config, threatMemory)
	local root = controller.Root
	if not root then return end

	local threatPosition = getMemoryPosition(threatMemory)
	local homePosition = getHomePosition(controller, blackboard)
	local currentPosition = root.Position

	local awayDirection = Vector3.new(0, 0, -1)

	if threatPosition then
		awayDirection = getFlatVector(currentPosition - threatPosition)
		awayDirection = getSafeUnit(awayDirection, getRandomFlatDirection())
	else
		awayDirection = getRandomFlatDirection()
	end

	local sideDirection = Vector3.new(awayDirection.Z, 0, -awayDirection.X)
	local sideAmount = RNG:NextNumber(-config.FleeSideStep, config.FleeSideStep)
	local fleeGoal = currentPosition + awayDirection * config.FleeDistance + sideDirection * sideAmount

	if homePosition and (fleeGoal - homePosition).Magnitude > config.FleeMaxDistanceFromHome then
		local homeDirection = getFlatVector(homePosition - currentPosition)
		homeDirection = getSafeUnit(homeDirection, awayDirection)
		fleeGoal = currentPosition + getSafeUnit(awayDirection + homeDirection, awayDirection) * config.FleeDistance
	end

	return fleeGoal
end

local function shouldRefreshFleeGoal(controller, blackboard, config)
	if not blackboard.FleeGoal then return true end
	if getDistance(controller, blackboard.FleeGoal) <= config.FleeArrivalDistance then return true end

	local lastFleeGoalTime = blackboard.LastFleeGoalTime or 0

	return os.clock() - lastFleeGoalTime >= config.FleeRepathRate
end

local function flee(controller, blackboard, config, threatMemory, reason)
	local changed = setMode(blackboard, MODES.FLEEING)

	blackboard.CurrentTarget = threatMemory
	blackboard.WantsAttack = false
	blackboard.AttackTarget = nil
	blackboard.FleeThreat = threatMemory

	clearSearchData(blackboard)
	clearWanderData(blackboard)

	if changed then
		resetMovementRequestData(blackboard)
		debugPrint(config, "Fleeing:", reason)
	end

	if shouldRefreshFleeGoal(controller, blackboard, config) then
		blackboard.FleeGoal = getFleeGoal(controller, blackboard, config, threatMemory)
		blackboard.LastFleeGoalTime = os.clock()
	end

	if not blackboard.FleeGoal then
		idle(controller, blackboard, config)
		return
	end

	moveTo(controller, blackboard, config, threatMemory, blackboard.FleeGoal, changed)
end

function ZombieBrain:Start(controller, blackboard)
	if not blackboard then return end

	blackboard.Mode = MODES.IDLE
	blackboard.ModeStartedTime = os.clock()

	blackboard.LastRepathTime = 0
	blackboard.LastMovePosition = nil
	blackboard.MovementMode = nil

	blackboard.CurrentTarget = nil
	blackboard.TargetCommittedTime = nil
	blackboard.LastKnownPosition = nil
	blackboard.WantsAttack = false
	blackboard.AttackTarget = nil

	blackboard.SearchStartedTime = nil
	blackboard.SearchPoints = nil
	blackboard.SearchIndex = nil
	blackboard.SearchCenter = nil

	blackboard.WanderGoal = nil
	blackboard.NextWanderTime = nil

	blackboard.FleeGoal = nil
	blackboard.LastFleeGoalTime = nil
	blackboard.FleeThreat = nil

	blackboard.HomePosition = nil
	blackboard.SearchPrepareStartedTime = nil
	blackboard.ResearchQueued = nil

	blackboard.TacticalGoal = nil
	blackboard.TacticalUntil = nil
	blackboard.TacticalTarget = nil
	blackboard.TacticalKind = nil
	blackboard.TacticalArrivalDistance = nil
	blackboard.LastDodgeTime = nil
	blackboard.LastDodgeConsideredTarget = nil
	blackboard.LastDodgeConsideredTime = nil

	blackboard.FirstSight = nil
	blackboard.FirstSightTargetKey = nil

	if controller.Model then
		controller.Model:SetAttribute("FirstSightIntercept", false)
		controller.Model:SetAttribute("FirstSightInterceptReason", nil)
	end

	setHomePosition(controller, blackboard)
end

function ZombieBrain:Update(controller, blackboard, dt)
	if not controller then return end
	if not blackboard then return end
	if not controller.Perception then return end
	if not controller.Movement then return end

	setHomePosition(controller, blackboard)

	local config = getConfig(controller)
	local memory = getTargetMemory(controller, blackboard, config):: Types.Memory
	local guardThreat = nil

	if config.GuardFearEnabled then
		guardThreat = getBestGuardThreat(controller, config)
	end

	if shouldLowHealthFlee(controller, blackboard, config) then
		CombatTactics:Clear(controller, blackboard)

		local fleeThreat = guardThreat or memory

		if isMemoryUsable(fleeThreat) then
			flee(controller, blackboard, config, fleeThreat, "LowHealth")
			return
		end

		returnHome(controller, blackboard, config)
		return
	end

	if guardThreat then
		CombatTactics:Clear(controller, blackboard)
		flee(controller, blackboard, config, guardThreat, "GuardThreat")
		return
	end

	if not isMemoryUsable(memory) then
		CombatTactics:Clear(controller, blackboard)
		idle(controller, blackboard, config)
		return
	end

	local position = getPredictedPosition(memory, config)

	if not position then
		CombatTactics:Clear(controller, blackboard)
		idle(controller, blackboard, config)
		return
	end

	if memory.CurrentlyVisible and evade(controller, blackboard, memory, config) then return end

	if memory.CurrentlyVisible and SimpleCombat:CanAttemptMeleeAttack(controller, memory) then
		clearFirstSight(controller, blackboard, "AttackRange")
		attack(controller, blackboard, memory, config)
		return
	end

	if updateFirstSightIntercept(controller, blackboard, memory, config) then return end
	if tryStartFirstSightIntercept(controller, blackboard, memory, config) then return end

	if memory.CurrentlyVisible then
		chase(controller, blackboard, memory, config, position)
		return
	end

	CombatTactics:Clear(controller, blackboard)
	lostSearch(controller, blackboard, memory, config)
end

function ZombieBrain:Stop(controller, blackboard)
	if blackboard then
		blackboard.Mode = MODES.IDLE
		clearTargetData(blackboard)
		clearWanderData(blackboard)
	end

	if not controller then return end

	CombatTactics:Clear(controller, blackboard)

	if controller.Model then
		controller.Model:SetAttribute("FirstSightIntercept", false)
	end

	stopMovement(controller)
end

return ZombieBrain
