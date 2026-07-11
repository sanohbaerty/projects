local GuardBrain = {}

local ServerScriptService = game:GetService("ServerScriptService")
local CollectionService = game:GetService("CollectionService")

local Server = ServerScriptService.Server
local NPCRegistry = require(Server.AdvancedNPCAI.Main.NPCRegistry)
local CombatTactics = require(Server.AdvancedNPCAI.Brain.CombatTactics)
local SimpleCombat = require(Server.AdvancedNPCAI.Combat.SimpleCombat)

local RNG = Random.new()

local MODES = {
	IDLE = "Idle",
	OBSERVING = "Observing",
	HOLDING = "Holding",
	PATROLLING = "Patrolling",
	RETURNING_TO_POST = "ReturningToPost",

	PURSUING = "Pursuing",
	ATTACKING = "Attacking",
	EVADING = "Evading",

	RETURNING_TO_INVESTIGATE = "ReturningToInvestigate",
	INVESTIGATING = "Investigating",

	CAUTION = "Caution",
}

local DEFAULT_CONFIG = {
	AttackRange = 4,

	SearchMinConfidence = 0.15,
	SearchTime = 7,
	SearchArrivalDistance = 4,
	SearchPointRadius = 9,
	SearchRebuildDistance = 12,

	RepathRate = 0.3,
	MinimumActivePathAge = 0.1,
	AllowAirborneRepath = false,
	DebugMovement = false,
	MinRepathDistance = 2,

	VisibleLeadTime = 0.12,
	LostLeadTime = 0.7,
	MaxPredictionTime = 1.4,
	MaxPredictionDistance = 24,

	PostReturnEnabled = true,
	ReturnPostDistance = 55,
	PostArrivalDistance = 5,

	PatrolRoute = nil,
	PatrolRoutePrefix = "GuardRoute_",
	ObserveMinTime = 0.8,
	ObserveMaxTime = 1.6,

	ZombieTargetEnabled = true,
	TargetFactions = {"Zombie"},
	ZombieTag = "Zombie",
	ZombieAttribute = "NPCType",
	ZombieAttributeValue = "Zombie",
	ZombieFaction = "Zombie",
	ZombieDetectDistance = 80,

	TargetCommitTime = 2.25,
	TargetSwitchScoreAdvantage = 1.15,
	CurrentTargetScoreBonus = 1.25,
	VisibleTargetScore = 3,
	ConfidenceTargetScore = 2.5,
	DistanceTargetScore = 2,
	AttackingTargetScore = 1.5,
	WeakTargetScore = 1,
	RetaliationEnabled = true,
	RetaliationMemoryTime = 4,
	RetaliationScoreBonus = 8,
	RetaliationDamageScore = 3,
	RetaliationBreaksCommit = true,
	RetaliationResponseTolerance = 1.5,
	RetaliationSwitchCooldown = 3,

	LowHealthCautionEnabled = true,
	LowHealthCautionPercent = 0.35,
	LowHealthRecoverPercent = 0.55,
	CautionReturnToPost = true,
	CautionRequiresThreat = true,
	CautionSafetyFactor = 1.15,
	CautionFallbackTargetDamage = 14,
	CautionFallbackTargetCooldown = 1.2,
	CautionNearbyThreatRadius = 16,
	CautionExtraThreatPressure = 0.55,

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
	
	RoutePick = "Random", -- "Closest", "Furthest", "Random"
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

		PostReturnEnabled = if brainConfig.PostReturnEnabled ~= nil then brainConfig.PostReturnEnabled else DEFAULT_CONFIG.PostReturnEnabled,
		ReturnPostDistance = brainConfig.ReturnPostDistance or DEFAULT_CONFIG.ReturnPostDistance,
		PostArrivalDistance = brainConfig.PostArrivalDistance or DEFAULT_CONFIG.PostArrivalDistance,

		PatrolRoute = brainConfig.PatrolRoute or DEFAULT_CONFIG.PatrolRoute,
		PatrolRoutePrefix = brainConfig.PatrolRoutePrefix or DEFAULT_CONFIG.PatrolRoutePrefix,
		ObserveMinTime = brainConfig.ObserveMinTime or DEFAULT_CONFIG.ObserveMinTime,
		ObserveMaxTime = brainConfig.ObserveMaxTime or DEFAULT_CONFIG.ObserveMaxTime,

		ZombieTargetEnabled = if brainConfig.ZombieTargetEnabled ~= nil then brainConfig.ZombieTargetEnabled else DEFAULT_CONFIG.ZombieTargetEnabled,
		TargetFactions = brainConfig.TargetFactions or DEFAULT_CONFIG.TargetFactions,
		ZombieTag = brainConfig.ZombieTag or DEFAULT_CONFIG.ZombieTag,
		ZombieAttribute = brainConfig.ZombieAttribute or DEFAULT_CONFIG.ZombieAttribute,
		ZombieAttributeValue = brainConfig.ZombieAttributeValue or DEFAULT_CONFIG.ZombieAttributeValue,
		ZombieFaction = brainConfig.ZombieFaction or DEFAULT_CONFIG.ZombieFaction,
		ZombieDetectDistance = brainConfig.ZombieDetectDistance or DEFAULT_CONFIG.ZombieDetectDistance,

		TargetCommitTime = brainConfig.TargetCommitTime or DEFAULT_CONFIG.TargetCommitTime,
		TargetSwitchScoreAdvantage = brainConfig.TargetSwitchScoreAdvantage or DEFAULT_CONFIG.TargetSwitchScoreAdvantage,
		CurrentTargetScoreBonus = brainConfig.CurrentTargetScoreBonus or DEFAULT_CONFIG.CurrentTargetScoreBonus,
		VisibleTargetScore = brainConfig.VisibleTargetScore or DEFAULT_CONFIG.VisibleTargetScore,
		ConfidenceTargetScore = brainConfig.ConfidenceTargetScore or DEFAULT_CONFIG.ConfidenceTargetScore,
		DistanceTargetScore = brainConfig.DistanceTargetScore or DEFAULT_CONFIG.DistanceTargetScore,
		AttackingTargetScore = brainConfig.AttackingTargetScore or DEFAULT_CONFIG.AttackingTargetScore,
		WeakTargetScore = brainConfig.WeakTargetScore or DEFAULT_CONFIG.WeakTargetScore,
		RetaliationEnabled = if brainConfig.RetaliationEnabled ~= nil then brainConfig.RetaliationEnabled else DEFAULT_CONFIG.RetaliationEnabled,
		RetaliationMemoryTime = brainConfig.RetaliationMemoryTime or DEFAULT_CONFIG.RetaliationMemoryTime,
		RetaliationScoreBonus = brainConfig.RetaliationScoreBonus or DEFAULT_CONFIG.RetaliationScoreBonus,
		RetaliationDamageScore = brainConfig.RetaliationDamageScore or DEFAULT_CONFIG.RetaliationDamageScore,
		RetaliationBreaksCommit = if brainConfig.RetaliationBreaksCommit ~= nil then brainConfig.RetaliationBreaksCommit else DEFAULT_CONFIG.RetaliationBreaksCommit,
		RetaliationResponseTolerance = brainConfig.RetaliationResponseTolerance or DEFAULT_CONFIG.RetaliationResponseTolerance,
		RetaliationSwitchCooldown = brainConfig.RetaliationSwitchCooldown or DEFAULT_CONFIG.RetaliationSwitchCooldown,

		LowHealthCautionEnabled = if brainConfig.LowHealthCautionEnabled ~= nil then brainConfig.LowHealthCautionEnabled else DEFAULT_CONFIG.LowHealthCautionEnabled,
		LowHealthCautionPercent = brainConfig.LowHealthCautionPercent or DEFAULT_CONFIG.LowHealthCautionPercent,
		LowHealthRecoverPercent = brainConfig.LowHealthRecoverPercent or DEFAULT_CONFIG.LowHealthRecoverPercent,
		CautionReturnToPost = if brainConfig.CautionReturnToPost ~= nil then brainConfig.CautionReturnToPost else DEFAULT_CONFIG.CautionReturnToPost,
		CautionRequiresThreat = if brainConfig.CautionRequiresThreat ~= nil then brainConfig.CautionRequiresThreat else DEFAULT_CONFIG.CautionRequiresThreat,
		CautionSafetyFactor = brainConfig.CautionSafetyFactor or DEFAULT_CONFIG.CautionSafetyFactor,
		CautionFallbackTargetDamage = brainConfig.CautionFallbackTargetDamage or DEFAULT_CONFIG.CautionFallbackTargetDamage,
		CautionFallbackTargetCooldown = brainConfig.CautionFallbackTargetCooldown or DEFAULT_CONFIG.CautionFallbackTargetCooldown,
		CautionNearbyThreatRadius = brainConfig.CautionNearbyThreatRadius or DEFAULT_CONFIG.CautionNearbyThreatRadius,
		CautionExtraThreatPressure = brainConfig.CautionExtraThreatPressure or DEFAULT_CONFIG.CautionExtraThreatPressure,

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
		
		RoutePick = brainConfig.RoutePick or DEFAULT_CONFIG.RoutePick,
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

	print("[GuardBrain]", ...)
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

local function isMemoryUsable(memory)
	if not memory then return false end
	if not memory.Character then return false end
	if not memory.Character.Parent then return false end
	if not memory.Humanoid then return false end
	if memory.Humanoid.Health <= 0 then return false end
	if not memory.Root then return false end
	if not memory.Root.Parent then return false end
	if not memory.Confidence then return false end
	if memory.Confidence <= 0 then return false end

	return true
end

local function getHumanoidHealthPercent(humanoid)
	if not humanoid then return 1 end
	if humanoid.MaxHealth <= 0 then return 1 end

	return math.clamp(humanoid.Health / humanoid.MaxHealth, 0, 1)
end

local function getControllerHealthPercent(controller)
	return getHumanoidHealthPercent(controller.Humanoid)
end

local function getPredictionTime(memory, config)
	if memory.CurrentlyVisible then return config.VisibleLeadTime end

	local timeSinceSeen = os.clock() - (memory.LastSeenTime or os.clock())
	local confidence = math.clamp(memory.Confidence or 0, 0, 1)
	local predictionTime = config.LostLeadTime + (timeSinceSeen * 0.2)

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

local function getMemoryPosition(memory)
	if not memory then return end
	if memory.Root then return memory.Root.Position end
	if memory.LastKnownPosition then return memory.LastKnownPosition end
	if memory.LastSeenPosition then return memory.LastSeenPosition end

	return
end

local function addMemoriesFromTable(memoryList, memories)
	if typeof(memories) ~= "table" then return end

	for targetKey, memory in memories do
		if isMemoryUsable(memory) then
			table.insert(memoryList, memory)
		end
	end
end

local function getKnownMemories(controller)
	local memoryList = {}

	if not controller.Perception then return memoryList end

	local perception = controller.Perception

	if perception.GetAllMemories then
		local memories = perception:GetAllMemories()
		addMemoriesFromTable(memoryList, memories)
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

local function listContains(list, value)
	if not list then return false end
	if value == nil then return false end

	for i, listValue in list do
		if listValue == value then return true end
	end

	return false
end

local function getMemoryFaction(memory)
	if not memory then return end
	if memory.Faction then return memory.Faction end
	if memory.Character then return memory.Character:GetAttribute("Faction") end

	return
end

local function isZombieMemory(memory, config)
	if not memory then return false end
	if listContains(config.TargetFactions, getMemoryFaction(memory)) then return true end

	local character = memory.Character
	local humanoid = memory.Humanoid
	local root = memory.Root

	if memory.IsZombie == true then return true end
	if memory.Role == "Zombie" then return true end
	if memory.Faction == config.ZombieFaction then return true end

	if hasCollectionTag(character, config.ZombieTag) then return true end
	if hasCollectionTag(humanoid, config.ZombieTag) then return true end
	if hasCollectionTag(root, config.ZombieTag) then return true end

	if hasMatchingAttribute(character, config.ZombieAttribute, config.ZombieAttributeValue) then return true end
	if hasMatchingAttribute(humanoid, config.ZombieAttribute, config.ZombieAttributeValue) then return true end
	if hasMatchingAttribute(root, config.ZombieAttribute, config.ZombieAttributeValue) then return true end

	if character and character:GetAttribute("Faction") == config.ZombieFaction then return true end
	if character and character:GetAttribute("IsZombie") == true then return true end

	return false
end

local function getImminentAttackMemory(controller, config)
	if not config.TacticalMovementEnabled then return end

	local bestMemory = nil
	local bestDistance = math.huge
	local memories = getKnownMemories(controller)

	for i, memory in memories do
		if not memory.CurrentlyVisible then continue end
		if not isZombieMemory(memory, config) then continue end
		if not SimpleCombat:IsAttackWindingUp(memory.Character) then continue end

		local position = getMemoryPosition(memory)
		local distance = getDistance(controller, position)

		if distance > config.DodgeTriggerDistance then continue end
		if distance >= bestDistance then continue end

		bestMemory = memory
		bestDistance = distance
	end

	return bestMemory
end

local function isMemoryReachable(controller, memory, position)
	if not controller.Movement then return false end
	if not position then return false end

	local movementConfig = controller.Definition.Movement or {}
	local canPathfind = movementConfig.UsePathfinding and controller.Movement.PathfindTo

	if canPathfind then
		if controller.Movement.IsPathMoveRecentlyBlocked and controller.Movement:IsPathMoveRecentlyBlocked(position) then
			return false
		end

		return true
	end

	if controller.Movement.IsDirectMoveRecentlyBlocked and controller.Movement:IsDirectMoveRecentlyBlocked(position) then
		return false
	end

	if controller.Movement.HasClearDirectPath then
		return controller.Movement:HasClearDirectPath(position, memory.Character)
	end

	return true
end

local function getMemoryHealthPercent(memory)
	if not memory then return 1 end

	return getHumanoidHealthPercent(memory.Humanoid)
end

local function getTargetRecord(memory)
	if not memory then return end
	if not memory.Character then return end

	return NPCRegistry:GetFromModel(memory.Character)
end

local function getRecentHitMap(controller, config)
	local recentHitMap = {}

	if not config.RetaliationEnabled then return recentHitMap end

	local recentHits = SimpleCombat:GetRecentAttackers(controller.Model, config.RetaliationMemoryTime)

	for i, recentHit in recentHits do
		if not recentHit.AttackerCharacter then continue end

		recentHitMap[recentHit.AttackerCharacter] = recentHit
	end

	return recentHitMap
end

local function getTargetScore(controller, blackboard, memory, config, recentHitMap)
	if not isMemoryUsable(memory) then return -math.huge, false end
	if not isZombieMemory(memory, config) then return -math.huge, false end

	local position = getMemoryPosition(memory)
	local distance = getDistance(controller, position)
	if distance > config.ZombieDetectDistance then return -math.huge, false end

	local normalizedDistance = 1 - math.clamp(distance / math.max(config.ZombieDetectDistance, 1), 0, 1)
	local score = 0

	if memory.CurrentlyVisible then
		score += config.VisibleTargetScore
	end

	score += math.clamp(memory.Confidence or 0, 0, 1) * config.ConfidenceTargetScore
	score += normalizedDistance * config.DistanceTargetScore
	score += (1 - getMemoryHealthPercent(memory)) * config.WeakTargetScore

	if blackboard.CurrentTarget == memory then
		score += config.CurrentTargetScoreBonus
	end

	if SimpleCombat:IsAttackWindingUp(memory.Character) then
		score += config.AttackingTargetScore
	end

	local recentHit = recentHitMap and recentHitMap[memory.Character]
	local recentAttacker = recentHit ~= nil

	if recentAttacker then
		local hitAge = os.clock() - recentHit.LastDamageTime
		local recency = 1 - math.clamp(hitAge / math.max(config.RetaliationMemoryTime, 0.01), 0, 1)
		local maximumHealth = controller.Humanoid and controller.Humanoid.MaxHealth or 100
		local damagePressure = math.clamp(recentHit.TotalDamage / math.max(maximumHealth * 0.25, 1), 0, 1)

		score += config.RetaliationScoreBonus * (0.7 + recency * 0.3)
		score += damagePressure * config.RetaliationDamageScore
	end

	return score, recentAttacker
end

local function commitTarget(blackboard, memory)
	if blackboard.CurrentTarget == memory then return end

	blackboard.CurrentTarget = memory
	blackboard.TargetCommittedTime = os.clock()
	blackboard.LastMovePosition = nil
	blackboard.MovementMode = nil
	blackboard.SearchStartedTime = nil
	blackboard.SearchPoints = nil
	blackboard.SearchIndex = nil
	blackboard.SearchCenter = nil
end

local function getBestTargetMemory(controller, blackboard, config)
	local bestMemory = nil
	local bestScore = -math.huge
	local recentHitMap = getRecentHitMap(controller, config)
	local memories = getKnownMemories(controller)

	for i, memory in memories do
		local score = getTargetScore(controller, blackboard, memory, config, recentHitMap)

		if score > bestScore then
			bestMemory = memory
			bestScore = score
		end
	end

	return bestMemory, bestScore, recentHitMap
end

local function getLatestRecentAttackerMemory(controller, config, recentHitMap)
	local latestMemory = nil
	local latestHitTime = -math.huge
	local memories = getKnownMemories(controller)

	for i, memory in memories do
		if not isZombieMemory(memory, config) then continue end

		local recentHit = recentHitMap[memory.Character]
		if not recentHit then continue end
		if recentHit.LastDamageTime <= latestHitTime then continue end

		latestMemory = memory
		latestHitTime = recentHit.LastDamageTime
	end

	return latestMemory
end

local function getTargetMemory(controller, blackboard, config)
	local currentTarget = blackboard.CurrentTarget

	if not controller.Perception then return currentTarget end

	if not config.ZombieTargetEnabled then
		local bestTarget = controller.Perception:GetBestTarget()

		if isMemoryUsable(bestTarget) then
			commitTarget(blackboard, bestTarget)
		end

		return bestTarget
	end

	local bestTarget, bestScore, recentHitMap = getBestTargetMemory(controller, blackboard, config)

	if not isMemoryUsable(currentTarget) or not isZombieMemory(currentTarget, config) then
		commitTarget(blackboard, bestTarget)
		return bestTarget
	end

	local currentScore = getTargetScore(controller, blackboard, currentTarget, config, recentHitMap)
	local currentTime = os.clock()
	local latestAttacker = getLatestRecentAttackerMemory(controller, config, recentHitMap)
	local lastRetaliationSwitchTime = blackboard.LastRetaliationSwitchTime or 0
	local retaliationSwitchReady = currentTime - lastRetaliationSwitchTime >= config.RetaliationSwitchCooldown

	if latestAttacker and latestAttacker ~= currentTarget and retaliationSwitchReady and config.RetaliationBreaksCommit then
		local latestHit = recentHitMap[latestAttacker.Character]
		local currentHit = recentHitMap[currentTarget.Character]
		local latestAttackerIsNewer = latestHit and (
			not currentHit or latestHit.LastDamageTime > currentHit.LastDamageTime
		)
		local latestScore = getTargetScore(controller, blackboard, latestAttacker, config, recentHitMap)

		if latestAttackerIsNewer and latestScore + config.RetaliationResponseTolerance >= currentScore then
			blackboard.LastRetaliationSwitchTime = currentTime
			commitTarget(blackboard, latestAttacker)
			return latestAttacker
		end
	end

	if not bestTarget or bestTarget == currentTarget then return currentTarget end

	local committedTime = blackboard.TargetCommittedTime or 0
	local commitmentActive = currentTime - committedTime < config.TargetCommitTime

	if commitmentActive then return currentTarget end
	if bestScore < currentScore + config.TargetSwitchScoreAdvantage then return currentTarget end

	commitTarget(blackboard, bestTarget)
	return bestTarget
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

local function moveTo(controller: any, blackboard: {}, config, memory, position, force)
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

local function clearTargetData(blackboard)
	blackboard.CurrentTarget = nil
	blackboard.TargetCommittedTime = nil
	blackboard.LastKnownPosition = nil
	blackboard.WantsAttack = false
	blackboard.AttackTarget = nil

	resetMovementRequestData(blackboard)
	clearSearchData(blackboard)
end

local function setPostPosition(controller, blackboard)
	if blackboard.PostPosition then return end
	if not controller.Root then return end

	blackboard.PostPosition = controller.Root.Position
end

local function getPostPosition(controller, blackboard)
	setPostPosition(controller, blackboard)

	return blackboard.PostPosition
end

local function getRouteFromSpawnData(controller)
	local spawnData = controller.SpawnData
	if not spawnData then return end

	if typeof(spawnData.RouteFolder) == "Instance" then return spawnData.RouteFolder end
	if typeof(spawnData.Route) == "Instance" then return spawnData.Route end

	return
end

local function getRouteFromConfig(config)
	if typeof(config.PatrolRoute) == "Instance" then return config.PatrolRoute end
	if typeof(config.PatrolRoute) ~= "string" then return end

	local advancedNPC = workspace:FindFirstChild("AdvancedNPC")
	if not advancedNPC then return end

	local routes = advancedNPC:FindFirstChild("Routes")
	if not routes then return end

	return routes:FindFirstChild(config.PatrolRoute)
end

local function isGuardRoute(routeFolder, config)
	if not routeFolder then return false end
	if not routeFolder:IsA("Folder") then return false end
	if routeFolder:GetAttribute("RouteOwner") == "Guard" then return true end

	local prefix = config.PatrolRoutePrefix
	if not prefix or prefix == "" then return false end

	return string.sub(routeFolder.Name, 1, #prefix) == prefix
end

local function getPatrolRoute(controller, config)
	local spawnRoute = getRouteFromSpawnData(controller)
	if isGuardRoute(spawnRoute, config) then return spawnRoute end

	local configRoute = getRouteFromConfig(config)
	if isGuardRoute(configRoute, config) then return configRoute end

	return
end

local function getRoutesFolder()
	local advancedNPC = workspace:FindFirstChild("AdvancedNPC")
	if not advancedNPC then return end

	return advancedNPC:FindFirstChild("Routes")
end

local function getRouteStartPoint(routeFolder, controller, config)
	local root = controller.Root
	if not root then return 1 end

	local selectedPoint = 1
	local selectedDistance = if config.RoutePick == "Furthest" then 0 else math.huge

	for i, waypoint in routeFolder:GetChildren() do
		if not waypoint:IsA("BasePart") then continue end

		local pointNumber = tonumber(waypoint.Name)
		if not pointNumber then continue end

		local distance = (root.Position - waypoint.Position).Magnitude

		if config.RoutePick == "Furthest" then
			if distance > selectedDistance then
				selectedDistance = distance
				selectedPoint = pointNumber
			end
		elseif distance < selectedDistance then
			selectedDistance = distance
			selectedPoint = pointNumber
		end
	end

	return selectedPoint
end

local function choosePatrolRoute(controller, blackboard, config)
	local routeFolder = getPatrolRoute(controller, config)
	if routeFolder then
		return routeFolder, getRouteStartPoint(routeFolder, controller, config)
	end

	if blackboard.ActiveRoute and blackboard.ActiveRoute.Parent then
		return blackboard.ActiveRoute, blackboard.ActiveRoutePoint or 1
	end

	local routesFolder = getRoutesFolder()
	if not routesFolder then return nil, 1 end

	local routes = {}
	for i, child in routesFolder:GetChildren() do
		if isGuardRoute(child, config) then
			table.insert(routes, child)
		end
	end

	if #routes <= 0 then return nil, 1 end

	if config.RoutePick == "Random" then
		local route = routes[RNG:NextInteger(1, #routes)]
		return route, 1
	end

	local selectedRoute = nil
	local selectedPoint = 1
	local selectedDistance = if config.RoutePick == "Furthest" then 0 else math.huge
	local root = controller.Root

	if not root then
		return routes[1], 1
	end

	for i, route in routes do
		for waypointIndex, waypoint in route:GetChildren() do
			if not waypoint:IsA("BasePart") then continue end

			local pointNumber = tonumber(waypoint.Name)
			if not pointNumber then continue end

			local distance = (root.Position - waypoint.Position).Magnitude

			if config.RoutePick == "Furthest" then
				if distance > selectedDistance then
					selectedDistance = distance
					selectedRoute = route
					selectedPoint = pointNumber
				end
			elseif distance < selectedDistance then
				selectedDistance = distance
				selectedRoute = route
				selectedPoint = pointNumber
			end
		end
	end

	if selectedRoute then
		return selectedRoute, selectedPoint
	end

	return routes[1], 1
end

local function isRouteActive(controller, routeFolder)
	local movement = controller.Movement
	if not movement then return false end
	if not movement.IsMoving then return false end
	if movement.CurrentMode ~= "Route" then return false end

	return movement.CurrentRoute == routeFolder
end

local function getCombatStats(definition, fallbackDamage, fallbackCooldown)
	local combat = definition and definition.Combat or {}
	local damage = combat.Damage or fallbackDamage
	local cooldown = combat.Cooldown or fallbackCooldown

	return math.max(damage, 1), math.max(cooldown, 0.05)
end

local function getTargetCombatStats(controller, memory, config)
	local targetRecord = getTargetRecord(memory)
	local targetDefinition = targetRecord and targetRecord.Definition
	local damage, cooldown = getCombatStats(
		targetDefinition,
		config.CautionFallbackTargetDamage,
		config.CautionFallbackTargetCooldown
	)

	local recentHit = SimpleCombat:GetRecentHit(controller and controller.Model, config.RetaliationMemoryTime)
	if recentHit and recentHit.AttackerCharacter == memory.Character and recentHit.Damage then
		damage = math.max(recentHit.Damage, 1)
	end

	return damage, cooldown
end

local function getNearbyThreatCount(controller, config)
	local threatCount = 0
	local memories = getKnownMemories(controller)

	for i, memory in memories do
		if not memory.CurrentlyVisible then continue end
		if not isZombieMemory(memory, config) then continue end

		local position = getMemoryPosition(memory)
		if getDistance(controller, position) > config.CautionNearbyThreatRadius then continue end

		threatCount += 1
	end

	return threatCount
end

local function getTimeToDefeat(health, damage, cooldown)
	local hits = math.max(math.ceil(health / math.max(damage, 1)), 1)
	return hits * math.max(cooldown, 0.05)
end

local function canFinishTargetFirst(controller, memory, config)
	if not isMemoryUsable(memory) then return false end
	if not controller.Humanoid then return false end

	local ownDamage, ownCooldown = getCombatStats(
		controller.Definition,
		config.CautionFallbackTargetDamage,
		config.CautionFallbackTargetCooldown
	)
	local targetDamage, targetCooldown = getTargetCombatStats(controller, memory, config)
	local timeToDefeatTarget = getTimeToDefeat(memory.Humanoid.Health, ownDamage, ownCooldown)
	local timeUntilDefeated = getTimeToDefeat(controller.Humanoid.Health, targetDamage, targetCooldown)
	local nearbyThreats = math.max(getNearbyThreatCount(controller, config), 1)
	local pressure = 1 + math.max(nearbyThreats - 1, 0) * config.CautionExtraThreatPressure

	timeUntilDefeated /= pressure

	return timeToDefeatTarget * config.CautionSafetyFactor <= timeUntilDefeated
end

local function shouldLowHealthCaution(controller, blackboard, config, memory)
	if not config.LowHealthCautionEnabled then return false end

	local healthPercent = getControllerHealthPercent(controller)
	local cautionPercent = config.LowHealthCautionPercent

	if blackboard.Mode == MODES.CAUTION then
		cautionPercent = config.LowHealthRecoverPercent
	end

	if healthPercent > cautionPercent then return false end
	if not isMemoryUsable(memory) then return not config.CautionRequiresThreat end
	if canFinishTargetFirst(controller, memory, config) then return false end

	return true
end

local function enterCaution(controller, blackboard, config, memory)
	local changed = setMode(blackboard, MODES.CAUTION)
	local postPosition = getPostPosition(controller, blackboard)

	blackboard.ActiveRoute = nil
	blackboard.CurrentTarget = memory
	blackboard.WantsAttack = false
	blackboard.AttackTarget = nil

	CombatTactics:Clear(controller, blackboard)

	if changed then
		clearSearchData(blackboard)
		resetMovementRequestData(blackboard)
		debugPrint(config, "Caution, outmatched at low health")
	end

	if config.CautionReturnToPost and postPosition and getDistance(controller, postPosition) > config.PostArrivalDistance then
		moveTo(controller, blackboard, config, memory, postPosition, changed)
		return
	end

	stopMovement(controller)
end

local function holdPost(controller, blackboard, config)
	local changed = setMode(blackboard, MODES.HOLDING)

	clearTargetData(blackboard)
	blackboard.ActiveRoute = nil

	if changed then
		debugPrint(config, "Holding post")
		stopMovement(controller)
	end
end

local function returnToPost(controller, blackboard, config)
	local postPosition = getPostPosition(controller, blackboard)

	if not postPosition then
		holdPost(controller, blackboard, config)
		return
	end

	local changed = setMode(blackboard, MODES.RETURNING_TO_POST)

	blackboard.ActiveRoute = nil
	blackboard.CurrentTarget = nil
	blackboard.WantsAttack = false
	blackboard.AttackTarget = nil

	if changed then
		clearSearchData(blackboard)
		resetMovementRequestData(blackboard)
		debugPrint(config, "Returning to post")
	end

	if getDistance(controller, postPosition) <= config.PostArrivalDistance then
		holdPost(controller, blackboard, config)
		return
	end

	moveTo(controller, blackboard, config, nil, postPosition, changed)
end

local function scheduleObservation(blackboard, config)
	local minimumTime = math.min(config.ObserveMinTime, config.ObserveMaxTime)
	local maximumTime = math.max(config.ObserveMinTime, config.ObserveMaxTime)

	blackboard.ObserveUntil = os.clock() + RNG:NextNumber(minimumTime, maximumTime)
end

local function observe(controller, blackboard, config)
	if not blackboard.ObserveUntil then return false end

	if os.clock() >= blackboard.ObserveUntil then
		blackboard.ObserveUntil = nil
		return false
	end

	local changed = setMode(blackboard, MODES.OBSERVING)
	blackboard.ActiveRoute = nil
	clearTargetData(blackboard)

	if changed then
		debugPrint(config, "Observing surroundings")
		stopMovement(controller)
	end

	return true
end

local function patrol(controller, blackboard, config)
	if blackboard.Mode ~= MODES.PATROLLING and blackboard.Mode ~= MODES.OBSERVING and not blackboard.ObserveUntil then
		scheduleObservation(blackboard, config)
	end

	if observe(controller, blackboard, config) then return end
	if controller.Movement.IsMoving then return end
	local routeFolder, pointToMove = choosePatrolRoute(controller, blackboard, config)

	clearTargetData(blackboard)

	if not routeFolder then
		local postPosition = getPostPosition(controller, blackboard)

		if config.PostReturnEnabled and postPosition and getDistance(controller, postPosition) >= config.ReturnPostDistance then
			returnToPost(controller, blackboard, config)
			return
		end

		holdPost(controller, blackboard, config)
		return
	end

	local changed = setMode(blackboard, MODES.PATROLLING)

	if not changed and blackboard.ActiveRoute == routeFolder and isRouteActive(controller, routeFolder) then return end
	
	blackboard.ActiveRoute = routeFolder
	blackboard.ActiveRoutePoint = pointToMove or 1
	blackboard.LastRepathTime = os.clock()

	debugPrint(config, "Patrolling", routeFolder:GetFullName())

	controller.Movement:FollowRoute(routeFolder, {
		Loop = controller.Definition.Movement.LoopRoutes == true,
		Requester = "Brain",
		DebugMovement = config.DebugMovement,
		Point = blackboard.ActiveRoutePoint,
	})
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
	local randomDirection = getRandomFlatDirection()

	local points = {
		center,
		center + forward * radius,
		center + right * radius,
		center - right * radius,
		center - forward * radius,
		center + forwardRight * radius,
		center + forwardLeft * radius,
		center + randomDirection * radius,
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

local function evade(controller, blackboard, memory, config)
	if not CombatTactics:Update(controller, blackboard, memory, config) then return false end

	setMode(blackboard, MODES.EVADING)

	blackboard.ActiveRoute = nil
	blackboard.LastTacticalThreat = memory.Character
	blackboard.WantsAttack = false
	blackboard.AttackTarget = nil

	clearSearchData(blackboard)

	return true
end

local function attack(controller, blackboard, memory, config)
	setMode(blackboard, MODES.ATTACKING)

	blackboard.ActiveRoute = nil
	blackboard.CurrentTarget = memory
	blackboard.AttackTarget = memory
	blackboard.WantsAttack = true
	blackboard.LastKnownPosition = memory.LastKnownPosition

	clearSearchData(blackboard)
	debugPrint(config, "Attacking", memory.Character)
	stopMovement(controller)
	SimpleCombat:TryMeleeAttack(controller, memory)
end

local function pursue(controller, blackboard, memory, config, position)
	local changed = setMode(blackboard, MODES.PURSUING)

	blackboard.ActiveRoute = nil
	blackboard.CurrentTarget = memory
	blackboard.LastKnownPosition = position
	blackboard.WantsAttack = false
	blackboard.AttackTarget = nil

	if changed then
		clearSearchData(blackboard)
		resetMovementRequestData(blackboard)
		debugPrint(config, "Pursuing", memory.Character)
	end

	moveTo(controller, blackboard, config, memory, position, changed)
end

local function beginInvestigation(controller, blackboard, memory, config, center)
	local changed = setMode(blackboard, MODES.RETURNING_TO_INVESTIGATE)

	blackboard.ActiveRoute = nil
	blackboard.CurrentTarget = memory
	blackboard.LastKnownPosition = center
	blackboard.WantsAttack = false
	blackboard.AttackTarget = nil
	blackboard.SearchStartedTime = os.clock()

	clearSearchPoints(blackboard)
	resetMovementRequestData(blackboard)

	debugPrint(config, "Lost target, returning to investigation area")

	moveTo(controller, blackboard, config, memory, center, changed)
end

local function returnToInvestigationArea(controller, blackboard, memory, config, center)
	local searchStartedTime = blackboard.SearchStartedTime or os.clock()
	local searchAge = os.clock() - searchStartedTime

	blackboard.CurrentTarget = memory
	blackboard.LastKnownPosition = center
	blackboard.WantsAttack = false
	blackboard.AttackTarget = nil

	if searchAge >= config.SearchTime then
		patrol(controller, blackboard, config)
		return
	end

	if getDistance(controller, center) > config.SearchArrivalDistance then
		moveTo(controller, blackboard, config, memory, center, false)
		return
	end

	setMode(blackboard, MODES.INVESTIGATING)
	clearSearchPoints(blackboard)
	resetMovementRequestData(blackboard)
end

local function investigateArea(controller, blackboard, memory, config, center)
	local searchStartedTime = blackboard.SearchStartedTime or os.clock()
	local searchAge = os.clock() - searchStartedTime

	blackboard.CurrentTarget = memory
	blackboard.LastKnownPosition = center
	blackboard.WantsAttack = false
	blackboard.AttackTarget = nil

	if searchAge >= config.SearchTime then
		debugPrint(config, "Investigation finished, resuming duty")
		patrol(controller, blackboard, config)
		return
	end

	local goal = getSearchGoal(controller, blackboard, memory, config, center)
	moveTo(controller, blackboard, config, memory, goal, false)
end

local function investigate(controller, blackboard, memory, config)
	local center = getSearchCenter(memory, config)

	if not center then
		patrol(controller, blackboard, config)
		return
	end

	if blackboard.Mode ~= MODES.RETURNING_TO_INVESTIGATE and blackboard.Mode ~= MODES.INVESTIGATING then
		beginInvestigation(controller, blackboard, memory, config, center)
		return
	end

	if blackboard.Mode == MODES.RETURNING_TO_INVESTIGATE then
		returnToInvestigationArea(controller, blackboard, memory, config, center)
		return
	end

	investigateArea(controller, blackboard, memory, config, center)
end

function GuardBrain:Start(controller, blackboard)
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

	blackboard.ActiveRoute = nil
	blackboard.ActiveRoutePoint = nil
	blackboard.PostPosition = nil
	blackboard.ObserveUntil = nil

	blackboard.TacticalGoal = nil
	blackboard.TacticalUntil = nil
	blackboard.TacticalTarget = nil
	blackboard.TacticalKind = nil
	blackboard.TacticalArrivalDistance = nil
	blackboard.LastDodgeTime = nil
	blackboard.LastDodgeConsideredTarget = nil
	blackboard.LastDodgeConsideredTime = nil
	blackboard.LastRetaliationSwitchTime = nil

	setPostPosition(controller, blackboard)
	scheduleObservation(blackboard, getConfig(controller))
end

function GuardBrain:Update(controller, blackboard, dt)
	if not controller then return end
	if not blackboard then return end
	if not controller.Perception then return end
	if not controller.Movement then return end

	setPostPosition(controller, blackboard)

	local config = getConfig(controller)
	local memory = getTargetMemory(controller, blackboard, config)

	if shouldLowHealthCaution(controller, blackboard, config, memory) then
		enterCaution(controller, blackboard, config, memory)
		return
	end

	if not isMemoryUsable(memory) then
		CombatTactics:Clear(controller, blackboard)
		patrol(controller, blackboard, config)
		return
	end

	blackboard.ObserveUntil = nil

	local position = getPredictedPosition(memory, config)

	if not position then
		CombatTactics:Clear(controller, blackboard)
		patrol(controller, blackboard, config)
		return
	end

	local distance = getDistance(controller, position)

	if config.ZombieTargetEnabled and distance > config.ZombieDetectDistance then
		CombatTactics:Clear(controller, blackboard)
		patrol(controller, blackboard, config)
		return
	end

	if not isMemoryReachable(controller, memory, position) then
		CombatTactics:Clear(controller, blackboard)
		patrol(controller, blackboard, config)
		return
	end

	local tacticalMemory = getImminentAttackMemory(controller, config) or memory
	if tacticalMemory.CurrentlyVisible and evade(controller, blackboard, tacticalMemory, config) then return end

	if memory.CurrentlyVisible and SimpleCombat:CanAttemptMeleeAttack(controller, memory) then
		attack(controller, blackboard, memory, config)
		return
	end

	if memory.CurrentlyVisible then
		pursue(controller, blackboard, memory, config, position)
		return
	end

	CombatTactics:Clear(controller, blackboard)

	if memory.Confidence < config.SearchMinConfidence then
		patrol(controller, blackboard, config)
		return
	end

	investigate(controller, blackboard, memory, config)
end

function GuardBrain:Stop(controller, blackboard)
	if blackboard then
		blackboard.Mode = MODES.IDLE
		blackboard.ActiveRoute = nil
		clearTargetData(blackboard)
	end

	if not controller then return end

	CombatTactics:Clear(controller, blackboard)
	stopMovement(controller)
end

return GuardBrain
