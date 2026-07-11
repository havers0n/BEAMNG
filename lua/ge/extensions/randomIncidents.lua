print("RANDOM INCIDENTS LUA FILE LOADED v2.3.4 - RUNTIME TELEMETRY FILE EXPORT")
-- Random Incident Generator - Phase 1: Spot Harvester
-- Harvests candidate incident locations from the loaded level navgraph.

local M = {}

local logTag = 'randomIncidents'
local diagnostics = require('lua/ge/extensions/randomIncidents/diagnostics')
local runtimeTelemetry = require('lua/ge/extensions/randomIncidents/runtimeTelemetry')
local telemetryExport = require('lua/ge/extensions/randomIncidents/telemetryExport')
local runtimeTelemetryAutoExport = true
local runtimeTelemetryExportCount = 0
local function log(level, tag, message)
  local normalized = ({D='DEBUG', I='INFO', W='WARN', E='ERROR'})[level] or tostring(level):upper()
  local text = tostring(message or '')
  local category = 'lifecycle'
  if text:match('[Tt]rigger') then category = 'trigger'
  elseif text:match('[Ff]ollow') then category = 'following'
  elseif text:match('[Aa]mbient') then category = 'ambient'
  elseif text:match('[Cc]ontroller') then category = 'ai'
  elseif text:match('[Ss]pawn') or text:match('[Ss]pawned') then category = 'spawn'
  elseif text:match('[Ee]xport') then category = 'export'
  elseif text:match('[Gg]enerat') then category = 'scenario' end
  local eventType = text:lower():gsub('[^%w]+', '_'):gsub('^_+', ''):sub(1, 80)
  if text:match('Following speed sync') then eventType = 'following_speed_sync' end
  local actor = text:match('([%w%s]+) target=') or text:match('for ([%w%s]+)')
  local fields = actor and {actor = actor} or nil
  if eventType == 'following_speed_sync' then
    actor = text:match('Following speed sync (.-) target=') or actor
    fields = {actor = actor, target = text:match('target=([^%s]+)'), speed = tonumber(text:match('speed=([%+%-]?[%d%.]+)'))}
  end
  diagnostics.log(normalized, category, eventType, text, fields)
end
local function getVehicleObjectId(vehicle)
  local id = nil
  if vehicle and vehicle.getID then pcall(function() id = vehicle:getID() end) end
  return id
end
local function getCurrentMapName()
  local missionFilename = nil
  if type(getMissionFilename) == 'function' then pcall(function() missionFilename = getMissionFilename() end) end
  local levelName = nil
  if core_levels and core_levels.getLevelName and missionFilename then
    pcall(function() levelName = core_levels.getLevelName(missionFilename) end)
  end
  if type(levelName) ~= 'string' or levelName == '' then
    levelName = type(missionFilename) == 'string' and (missionFilename:match('^/*levels/([^/]+)/') or missionFilename:match('^[\\/]levels[\\/]([^\\/]+)[\\/]')) or nil
  end
  return type(levelName) == 'string' and levelName ~= '' and levelName or 'unknown'
end
local savedSpotsPath = '/settings/randomIncidents_spots.json'
local spots = {}
local generatedVehicles = {}
local generatedScene = nil

local function startRuntimeTelemetryForGeneratedScene()
  if not generatedScene then return nil end
  local actors = {}
  for _, entry in ipairs(generatedVehicles) do
    table.insert(actors, {
      label = entry.label,
      objectId = getVehicleObjectId(entry.vehicle),
      role = entry.role,
      ambient = entry.isAmbient == true,
    })
  end
  return runtimeTelemetry.startSession({
    sessionId = diagnostics.getCurrentSessionId(),
    scenarioId = generatedScene.scenarioId,
    seed = generatedScene.seed,
    actors = actors,
    diagnostics = diagnostics,
    controllerStateProvider = function(label)
      for _, entry in ipairs(generatedVehicles) do
        if entry.label == label then return entry.controller and entry.controller.state or nil end
      end
      return nil
    end,
  })
end

-- Freeze before exporting.  The exporter receives only a report snapshot and
-- never reaches into the live sampler, so clear/repeat cannot mix sessions.
local function finalizeRuntimeTelemetry(reason, automatic)
  local report = runtimeTelemetry.getReport()
  if not report or report.status ~= 'ACTIVE' then return nil end
  runtimeTelemetry.stopSession(reason)
  report = runtimeTelemetry.getReport()
  if not automatic or not runtimeTelemetryAutoExport or not report or report.actorCount == 0 or report.sampleCount == 0 then return nil end
  diagnostics.log('INFO', 'telemetry', 'telemetry_export_started', 'Runtime telemetry auto-export started', {sessionId=report.sessionId, reason=reason})
  local result = telemetryExport.export(report, {exportCount=runtimeTelemetryExportCount})
  if result.ok then
    runtimeTelemetryExportCount = result.exportCount
    diagnostics.log('INFO', 'telemetry', 'telemetry_export_completed', 'Runtime telemetry export completed', {sessionId=result.sessionId, sampleCount=result.sampleCount})
    diagnostics.log('INFO', 'telemetry', 'telemetry_auto_export_completed', 'Runtime telemetry auto-export completed', {sessionId=result.sessionId})
    log('I', logTag, string.format('Runtime telemetry exported: %s actors=%d samples=%d', result.jsonlPath, result.actorCount, result.sampleCount))
  else
    diagnostics.log('WARN', 'telemetry', 'telemetry_export_failed', 'Runtime telemetry export failed: ' .. tostring(result.message), {sessionId=report.sessionId, code=result.code})
    diagnostics.log('WARN', 'telemetry', 'telemetry_auto_export_failed', 'Runtime telemetry auto-export failed', {sessionId=report.sessionId, code=result.code})
  end
  return result
end

-- Rear-end scene tuning. Speeds are always metres per second.
local leadSpeedMps = 10
local chaseSpeedMps = 36
local distanceBehind = 15
local leadOffset = 15
local targetDistance = 160

local generatedVehicleModels = {
  'etk800',
  'covet',
}

-- Scenario Engine v2, Commit 7.
-- Scripted actors now use progressive speed reduction and staged braking around
-- a moving slow-traffic hazard. Ambient traffic remains ordinary BeamNG AI.
local VEHICLE_STATE = {
  CRUISE = 'CRUISE',
  COASTING = 'COASTING',
  DECELERATING = 'DECELERATING',
  BRAKING = 'BRAKING',
  EMERGENCY_BRAKING = 'EMERGENCY_BRAKING',
  FOLLOWING = 'FOLLOWING',
  STOPPED = 'STOPPED',
}

local vehicleControllerDefaults = {
  stopSpeedMps = 0.65,
  reverseToleranceMps = 0.35,
  holdRefreshInterval = 0.50,
  reverseCorrectionMaxMps = 2.00,
  reverseLogInterval = 0.50,
  followingSyncInterval = 1.25,
  followingSpeedDelta = 0.40,
}

local triggerEngine = require('lua/ge/extensions/randomIncidents/triggerEngine')
local ambientTrafficManager = require('lua/ge/extensions/randomIncidents/ambientTraffic')
local scenarioRegistry = require('lua/ge/extensions/randomIncidents/scenarioRegistry')
local DEFAULT_SCENARIO_ID = 'sudden_obstacle_pileup'
local LEAD_TRIGGER_ID = 'lead_reacts_to_hazard'
local TARGET_TRIGGER_ID = 'target_reacts_to_lead'
local LEAD_FALLBACK_TRIGGER_ID = 'lead_distance_fallback'
local TARGET_FALLBACK_TRIGGER_ID = 'target_distance_fallback'
local LEAD_COAST_TRIGGER_GROUP = 'lead_coast'
local LEAD_DECELERATE_TRIGGER_GROUP = 'lead_decelerate'
local LEAD_TRIGGER_GROUP = 'lead_brake'
local TARGET_TRIGGER_GROUP = 'target_brake'
local TARGET_EMERGENCY_TRIGGER_GROUP = 'target_emergency'
local activeScenarioDefinition = assert(scenarioRegistry.get(DEFAULT_SCENARIO_ID))
local ambientTrafficCountOverride = nil
local oppositeCarriagewayOverride = nil
local lastOppositeCarriagewayDiagnostics = nil

local function getScenarioDefinitionForScene(scene)
  if scene and scene.scenarioDefinition then return scene.scenarioDefinition end
  return activeScenarioDefinition
end

local function isScenarioEngineScene(scene)
  return scene ~= nil and scene.scenarioId ~= nil and scene.timeline ~= nil
end

local function getScenarioBindings(scene)
  local definition = getScenarioDefinitionForScene(scene) or {}
  local bindings = definition.bindings or {}
  return {
    lead = bindings.lead or 'Car A',
    target = bindings.target or 'Car B',
    hazard = bindings.hazard or 'Car F',
  }
end

local function findScenarioTrigger(definition, triggerId)
  for _, trigger in ipairs((definition and definition.triggers) or {}) do
    if trigger.id == triggerId then return trigger end
  end
  return nil
end

local function getScenarioTriggerThreshold(definition, triggerId, fallback)
  local trigger = findScenarioTrigger(definition, triggerId)
  return tonumber(trigger and trigger.threshold) or tonumber(fallback) or 0
end

local function getScenarioTriggerActionAmount(definition, triggerId, fallback)
  local trigger = findScenarioTrigger(definition, triggerId)
  return tonumber(trigger and trigger.action and trigger.action.amount) or tonumber(fallback) or 0
end

local function findScenarioTriggerByGroupMetric(definition, groupId, metric)
  for _, trigger in ipairs((definition and definition.triggers) or {}) do
    if trigger.group == groupId and (trigger.metric or trigger.type) == metric then return trigger end
  end
  return nil
end

local function getScenarioDistanceFallback(definition, groupId, fallback)
  local trigger = findScenarioTriggerByGroupMetric(definition, groupId, 'distance')
  return tonumber(trigger and trigger.threshold) or tonumber(fallback) or 0
end

local function getScenarioTtcThreshold(definition, groupId, fallback)
  local trigger = findScenarioTriggerByGroupMetric(definition, groupId, 'ttc')
  return tonumber(trigger and trigger.threshold) or tonumber(fallback) or 0
end

local function clamp(value, minimum, maximum)
  return math.max(minimum, math.min(maximum, value))
end

local function edgeKey(a, b)
  a = tostring(a)
  b = tostring(b)
  if a < b then return a .. '\0' .. b end
  return b .. '\0' .. a
end

local function copyPosition(pos)
  return {x = pos.x, y = pos.y, z = pos.z}
end

local function copyVector(vector)
  return {x = vector.x, y = vector.y, z = vector.z}
end

local function midpoint(a, b)
  return (a + b) * 0.5
end

local function getConnectedNodeIds(graph, nodeId, ignoredNodeId)
  local result = {}
  for connectedId in pairs(graph[nodeId] or {}) do
    if connectedId ~= ignoredNodeId then
      table.insert(result, connectedId)
    end
  end
  return result
end

local function getTurnAngleDegrees(mapNodes, graph, nodeId, otherNodeId)
  local node = mapNodes[nodeId]
  local other = mapNodes[otherNodeId]
  if not node or not other then return 0 end

  local connected = getConnectedNodeIds(graph, nodeId, otherNodeId)
  if #connected ~= 1 then return 0 end

  local adjacent = mapNodes[connected[1]]
  if not adjacent then return 0 end

  local edgeDirection = (other.pos - node.pos):normalized()
  local adjacentDirection = (adjacent.pos - node.pos):normalized()
  local straightAngle = math.deg(math.acos(clamp(edgeDirection:dot(adjacentDirection), -1, 1)))

  -- A straight road has two outward vectors pointing in opposite directions.
  return math.abs(180 - straightAngle)
end

local function addSpot(spot)
  spot.index = #spots + 1
  table.insert(spots, spot)
end

local function addIntersectionSpot(mapNodes, nodeId, degree)
  local node = mapNodes[nodeId]
  if not node then return end

  addSpot({
    type = 'intersection',
    score = 90 + degree * 8 + (node.radius or 0) * 2,
    pos = copyPosition(node.pos),
    nodeId = nodeId,
    degree = degree,
    radius = node.radius or 0,
  })
end

local function addRoadSpot(mapNodes, graph, nodeAId, nodeBId, degreeA, degreeB)
  local nodeA = mapNodes[nodeAId]
  local nodeB = mapNodes[nodeBId]
  if not nodeA or not nodeB then return end

  local position = midpoint(nodeA.pos, nodeB.pos)
  local length = nodeA.pos:distance(nodeB.pos)
  local turnA = getTurnAngleDegrees(mapNodes, graph, nodeAId, nodeBId)
  local turnB = getTurnAngleDegrees(mapNodes, graph, nodeBId, nodeAId)
  local turnAngle = math.max(turnA, turnB)
  local averageRadius = ((nodeA.radius or 0) + (nodeB.radius or 0)) * 0.5
  local direction = (nodeB.pos - nodeA.pos):normalized()

  if turnAngle >= 8 then
    addSpot({
      type = 'curve',
      score = 45 + math.min(turnAngle, 90) + math.min(length, 80) * 0.25 + averageRadius,
      pos = copyPosition(position),
      nodeA = nodeAId,
      nodeB = nodeBId,
      length = length,
      turnAngle = turnAngle,
      radius = averageRadius,
      dir = copyVector(direction),
    })
  else
    local offset = math.min(30, length * 0.35)
    addSpot({
      type = 'straight',
      score = 25 + math.min(length, 120) * 0.4 + averageRadius,
      pos = copyPosition(position),
      nodeA = nodeAId,
      nodeB = nodeBId,
      length = length,
      turnAngle = turnAngle,
      radius = averageRadius,
      dir = copyVector(direction),
      startPos = copyPosition(position - direction * offset),
      endPos = copyPosition(position + direction * offset),
    })
  end
end

function M.clearSpots()
  spots = {}
  log('I', logTag, 'Cleared harvested spots')
end

function M.harvestSpots()
  local mapData = map.getMap()
  local graphpath = map.getGraphpath()
  local mapNodes = mapData and mapData.nodes
  local graph = graphpath and graphpath.graph

  if not mapNodes or not graph or not next(mapNodes) then
    log('W', logTag, 'Cannot harvest spots: navgraph data is unavailable or empty')
    return 0
  end

  M.clearSpots()

  local visitedEdges = {}
  local visitedIntersections = {}
  local edgeCount = 0

  for nodeAId, connections in pairs(graph) do
    if mapNodes[nodeAId] then
      local degreeA = map.getNodeLinkCount(nodeAId)
      for nodeBId in pairs(connections) do
        if mapNodes[nodeBId] then
          local key = edgeKey(nodeAId, nodeBId)
          if not visitedEdges[key] then
            visitedEdges[key] = true
            edgeCount = edgeCount + 1

            local degreeB = map.getNodeLinkCount(nodeBId)
            if degreeA > 2 and not visitedIntersections[nodeAId] then
              visitedIntersections[nodeAId] = true
              addIntersectionSpot(mapNodes, nodeAId, degreeA)
            end
            if degreeB > 2 and not visitedIntersections[nodeBId] then
              visitedIntersections[nodeBId] = true
              addIntersectionSpot(mapNodes, nodeBId, degreeB)
            end

            addRoadSpot(mapNodes, graph, nodeAId, nodeBId, degreeA, degreeB)
          end
        end
      end
    end
  end

  table.sort(spots, function(a, b) return a.score > b.score end)
  for index, spot in ipairs(spots) do
    spot.index = index
  end

  log('I', logTag, string.format('Harvested %d spots from %d unique navgraph edges', #spots, edgeCount))
  return #spots
end

function M.printSpots(limit)
  limit = math.max(0, math.floor(tonumber(limit) or 20))
  local count = math.min(limit, #spots)
  log('I', logTag, string.format('Printing %d of %d harvested spots', count, #spots))

  for index = 1, count do
    local spot = spots[index]
    log('I', logTag, string.format(
      '#%d %s score=%.2f pos=(%.2f, %.2f, %.2f) nodes=%s,%s degree=%s turn=%.1f',
      index, spot.type, spot.score, spot.pos.x, spot.pos.y, spot.pos.z,
      tostring(spot.nodeA or spot.nodeId), tostring(spot.nodeB or ''),
      tostring(spot.degree or ''), spot.turnAngle or 0
    ))
  end

  return count
end

function M.countSpotsByType()
  local counts = {
    straight = 0,
    curve = 0,
    intersection = 0,
  }

  for _, spot in ipairs(spots) do
    counts[spot.type] = (counts[spot.type] or 0) + 1
  end

  log('I', logTag, string.format(
    'Spot counts: straight=%d curve=%d intersection=%d total=%d',
    counts.straight, counts.curve, counts.intersection, #spots
  ))
  return counts
end

function M.printSpotsByType(typeName, limit)
  typeName = tostring(typeName or '')
  limit = math.max(0, math.floor(tonumber(limit) or 20))

  local printed = 0
  local matching = 0
  for _, spot in ipairs(spots) do
    if spot.type == typeName then
      matching = matching + 1
      if printed < limit then
        printed = printed + 1
        log('I', logTag, string.format(
          '#%d %s score=%.2f pos=(%.2f, %.2f, %.2f) nodes=%s,%s degree=%s turn=%.1f',
          spot.index, spot.type, spot.score, spot.pos.x, spot.pos.y, spot.pos.z,
          tostring(spot.nodeA or spot.nodeId), tostring(spot.nodeB or ''),
          tostring(spot.degree or ''), spot.turnAngle or 0
        ))
      end
    end
  end

  log('I', logTag, string.format(
    'Printed %d of %d %s spots', printed, matching, typeName
  ))
  return printed
end

function M.getTopSpotByType(typeName)
  typeName = tostring(typeName or '')
  local topSpot = nil

  for _, spot in ipairs(spots) do
    if spot.type == typeName and (not topSpot or spot.score > topSpot.score) then
      topSpot = spot
    end
  end

  return topSpot
end

function M.saveSpots()
  local data = {spots = spots}
  local success = jsonWriteFile(savedSpotsPath, data, true)
  if success then
    log('I', logTag, string.format('Saved %d spots to %s', #spots, savedSpotsPath))
  else
    log('E', logTag, string.format('Failed to save spots to %s', savedSpotsPath))
  end
  return success
end

function M.debugSpot(index)
  index = math.floor(tonumber(index) or 0)
  local spot = spots[index]
  if not spot then
    log('W', logTag, string.format('No harvested spot at index %d', index))
    return nil
  end

  local n1, n2, distance = map.findClosestRoad(vec3(spot.pos.x, spot.pos.y, spot.pos.z))
  log('I', logTag, string.format(
    'Spot #%d: type=%s score=%.2f pos=(%.2f, %.2f, %.2f) closestRoad=%s,%s distance=%.2f',
    index, spot.type, spot.score, spot.pos.x, spot.pos.y, spot.pos.z,
    tostring(n1), tostring(n2), distance or -1
  ))
  return spot
end

-- Phase 2: rear-end scene generation.
-- Vehicle-side AI calls are queued because the AI extension runs in vehicle Lua,
-- while this extension runs in the game-engine Lua context.
local function vehicleLabel(vehicle, fallback)
  if vehicle and vehicle.getID then
    local ok, id = pcall(function() return vehicle:getID() end)
    if ok and id then return tostring(id) end
  end
  return fallback
end

local function findGeneratedVehicleEntry(label)
  for _, entry in ipairs(generatedVehicles) do
    if entry.label == label then return entry end
  end
  return nil
end

local function logInvalidDrivePathOnce(actorLabel, reason, nodeCount, context)
  local sceneTime = generatedScene and generatedScene.timeline and generatedScene.timeline.elapsed or 0
  local warningKeys = generatedScene and generatedScene.pathWarningKeys
  if not warningKeys then
    if generatedScene then
      generatedScene.pathWarningKeys = {}
      warningKeys = generatedScene.pathWarningKeys
    else
      warningKeys = {}
    end
  end
  local key = table.concat({tostring(actorLabel), tostring(reason), tostring(context)}, '|')
  if warningKeys[key] then return end
  warningKeys[key] = true
  log('W', logTag, string.format(
    'Skipping driveUsingPath for %s: %s, got %d nodes sceneTime=%.3f context=%s',
    tostring(actorLabel), tostring(reason), tonumber(nodeCount) or 0, tonumber(sceneTime) or 0, tostring(context)
  ))
end

local function validateDrivePath(path, actorLabel, context)
  if type(path) ~= 'table' then
    logInvalidDrivePathOnce(actorLabel, 'path must be a table', 0, context)
    return nil, false, 0
  end

  -- Build a fresh list. The caller's route is never modified while empty or
  -- nil waypoint IDs are discarded.
  local validNodes = {}
  for _, nodeId in ipairs(path) do
    if nodeId ~= nil then
      local normalized = tostring(nodeId)
      if normalized:match('%S') then
        table.insert(validNodes, normalized)
      end
    end
  end

  if #validNodes < 2 then
    logInvalidDrivePathOnce(actorLabel, 'path requires at least 2 nodes', #validNodes, context)
    return validNodes, false, #validNodes
  end
  return validNodes, true, #validNodes
end

local function queueVehicleAI(vehicle, speed, label, targetPath, driveInLane)
  if not vehicle or not vehicle.queueLuaCommand then
    log('W', logTag, string.format('%s has no queueLuaCommand; AI was not configured', label))
    return false
  end

  -- 'set' is intentional: 'limit' and the default traffic mode allow legal
  -- road speed to win over the requested scene speed. Scripted actors keep
  -- collision avoidance disabled; ambient traffic uses a separate AI path below.
  local laneMode = driveInLane and 'on' or 'off'
  local pathNodes, pathValid = validateDrivePath(targetPath, label, 'queueVehicleAI')
  local quotedPathNodes = {}
  for _, nodeId in ipairs(pathNodes or {}) do
    table.insert(quotedPathNodes, string.format('%q', nodeId))
  end
  local pathLiteral = '{' .. table.concat(quotedPathNodes, ', ') .. '}'
  local pathCommand = ''
  if pathValid then
    pathCommand = string.format(
      "; if ai.driveUsingPath then ai.driveUsingPath{wpTargetList = %s, noOfLaps = 0, driveInLane = '%%s', avoidCars = 'off', aggression = 1, routeSpeed = %%.2f, routeSpeedMode = 'set'} end",
      pathLiteral
    )
  end
  local command = string.format(
    "if input then input.event('throttle', 0, 1); input.event('brake', 0, 1); input.event('parkingbrake', 0, 1); input.event('clutch', 0, 1) end; ai.setMode('traffic'); ai.setAggression(1); ai.setSpeedMode('set'); ai.setSpeed(%.2f); ai.driveInLane('%s'); if ai.setAvoidCars then ai.setAvoidCars(false) end%s",
    speed, laneMode, string.format(pathCommand, laneMode, speed)
  )

  local ok, errorMessage = pcall(function() vehicle:queueLuaCommand(command) end)
  if ok then
    log('I', logTag, string.format('Queued AI for %s: %s', label, command))
  else
    log('E', logTag, string.format('Failed to configure %s AI: %s', label, tostring(errorMessage)))
  end
  if generatedScene then
    generatedScene.queuedAICommands = generatedScene.queuedAICommands or {}
    generatedScene.queuedAICommands[label] = command
  end
  local objectId = getVehicleObjectId(vehicle)
  diagnostics.recordCommand(label, objectId, 'queueVehicleAI', command)
  return ok, pathValid, #((pathNodes or {}))
end

local function queueFollowingSpeedSync(entry, targetSpeed)
  if not entry or not entry.vehicle or not entry.vehicle.queueLuaCommand then
    return false
  end
  local speed = math.max(0, tonumber(targetSpeed) or 0)
  local command = string.format("ai.setSpeedMode('set'); ai.setSpeed(%.2f)", speed)
  local ok, errorMessage = pcall(function() entry.vehicle:queueLuaCommand(command) end)
  if not ok then
    log('E', logTag, string.format('Failed following speed sync for %s: %s', tostring(entry.label), tostring(errorMessage)))
    return false
  end
  if generatedScene then
    generatedScene.queuedAICommands = generatedScene.queuedAICommands or {}
    generatedScene.queuedAICommands[entry.label .. ' followingSpeedSync'] = command
  end
  local objectId = getVehicleObjectId(entry.vehicle)
  diagnostics.recordCommand(entry.label, objectId, 'following_speed_sync', command)
  return true
end

local function queueAmbientVehicleAI(entry, targetPath)
  local vehicle = entry and entry.vehicle
  if not vehicle or not vehicle.queueLuaCommand then
    log('W', logTag, string.format('%s has no queueLuaCommand; ambient AI was not configured', tostring(entry and entry.label)))
    return false
  end

  local pathNodes, pathValid = validateDrivePath(targetPath, entry and entry.label or 'ambient', 'queueAmbientVehicleAI')
  local quotedPathNodes = {}
  for _, nodeId in ipairs(pathNodes or {}) do
    table.insert(quotedPathNodes, string.format('%q', nodeId))
  end
  local pathLiteral = '{' .. table.concat(quotedPathNodes, ', ') .. '}'
  local aiConfig = entry.ai or {}
  local speed = tonumber(entry.speedMps) or 14
  local aggression = clamp(tonumber(aiConfig.aggression) or 0.35, 0, 1)
  local laneMode = aiConfig.driveInLane == false and 'off' or 'on'
  local avoidCars = aiConfig.avoidCars ~= false
  local avoidMode = avoidCars and 'on' or 'off'
  local pathCommand = ''
  if pathValid then
    pathCommand = string.format(
      "; if ai.driveUsingPath then ai.driveUsingPath{wpTargetList = %s, noOfLaps = 0, driveInLane = '%%s', avoidCars = '%%s', aggression = %%.2f, routeSpeed = %%.2f, routeSpeedMode = 'set'} end",
      pathLiteral
    )
  end
  local command = string.format(
    "if input then input.event('throttle', 0, 1); input.event('brake', 0, 1); input.event('parkingbrake', 0, 1); input.event('clutch', 0, 1) end; ai.setMode('traffic'); ai.setAggression(%.2f); ai.setSpeedMode('set'); ai.setSpeed(%.2f); ai.driveInLane('%s'); if ai.setAvoidCars then ai.setAvoidCars(%s) end%s",
    aggression, speed, laneMode, tostring(avoidCars), string.format(pathCommand, laneMode, avoidMode, aggression, speed)
  )
  local ok, errorMessage = pcall(function() vehicle:queueLuaCommand(command) end)
  if ok then
    log('I', logTag, string.format(
      'Queued ambient AI for %s lane=%s speed=%.2f avoidCars=%s aggression=%.2f',
      tostring(entry.label), tostring(entry.laneChoice or 'n/a'), speed, tostring(avoidCars), aggression
    ))
  else
    log('E', logTag, string.format('Failed to configure ambient AI for %s: %s', tostring(entry.label), tostring(errorMessage)))
  end
  if generatedScene then
    generatedScene.queuedAICommands = generatedScene.queuedAICommands or {}
    generatedScene.queuedAICommands[entry.label] = command
  end
  local objectId = getVehicleObjectId(vehicle)
  diagnostics.recordCommand(entry.label, objectId, 'queueAmbientVehicleAI', command)
  return ok
end

local function queueVehicleBrake(vehicle, label, brakeAmount, commandName)
  if not vehicle or not vehicle.queueLuaCommand then
    log('W', logTag, string.format('%s has no queueLuaCommand; brake command was not applied', label))
    return false
  end

  brakeAmount = clamp(tonumber(brakeAmount) or 1, 0, 1)
  commandName = tostring(commandName or 'brake')

  -- Disable AI so it cannot overwrite direct input. Car A receives a full
  -- emergency stop, while Car B deliberately keeps rolling under partial brake.
  local command = string.format(
    "if ai then ai.setMode('disabled') end; if input then input.event('throttle', 0, 1); input.event('parkingbrake', 0, 1); input.event('brake', %.3f, 1) end",
    brakeAmount
  )
  local ok, errorMessage = pcall(function() vehicle:queueLuaCommand(command) end)
  if ok then
    log('I', logTag, string.format('%s queued for %s amount=%.2f: %s', commandName, label, brakeAmount, command))
  else
    log('E', logTag, string.format('Failed to apply %s to %s: %s', commandName, label, tostring(errorMessage)))
  end

  if generatedScene then
    generatedScene.queuedAICommands = generatedScene.queuedAICommands or {}
    generatedScene.queuedAICommands[label .. ' ' .. commandName] = command
  end
  local objectId = getVehicleObjectId(vehicle)
  diagnostics.recordCommand(label, objectId, commandName, command)
  return ok
end

local function queueVehicleEmergencyBrake(vehicle, label)
  return queueVehicleBrake(vehicle, label, 1, 'emergencyBrake')
end

local function queueVehicleSteering(vehicle, label, steeringAmount, commandName, disableAI)
  if not vehicle or not vehicle.queueLuaCommand then
    log('W', logTag, string.format('%s has no queueLuaCommand; steering command was not applied', label))
    return false
  end

  steeringAmount = clamp(tonumber(steeringAmount) or 0, -1, 1)
  commandName = tostring(commandName or 'swerve')
  local aiPrefix = disableAI == false and '' or "if ai then ai.setMode('disabled') end; "
  local command = string.format(
    "%sif input then input.event('steering', %.3f, 1) end",
    aiPrefix, steeringAmount
  )
  local ok, errorMessage = pcall(function() vehicle:queueLuaCommand(command) end)
  if ok then
    log('I', logTag, string.format('%s queued for %s amount=%.2f', commandName, label, steeringAmount))
  else
    log('E', logTag, string.format('Failed to apply %s to %s: %s', commandName, label, tostring(errorMessage)))
  end

  if generatedScene then
    generatedScene.queuedAICommands = generatedScene.queuedAICommands or {}
    generatedScene.queuedAICommands[label .. ' ' .. commandName] = command
  end
  local objectId = getVehicleObjectId(vehicle)
  diagnostics.recordCommand(label, objectId, commandName, command)
  return ok
end

local function queueVehicleStoppedHold(vehicle, label, reason)
  if not vehicle or not vehicle.queueLuaCommand then
    log('W', logTag, string.format('%s has no queueLuaCommand; stopped hold was not applied', label))
    return false
  end

  local command = "if ai then ai.setMode('disabled') end; if controller and controller.mainController and controller.mainController.shiftToGearIndex then pcall(function() controller.mainController.shiftToGearIndex(0) end) end; if input then input.event('throttle', 0, 1); input.event('clutch', 1, 1); input.event('brake', 1, 1); input.event('parkingbrake', 1, 1) end"
  local ok, errorMessage = pcall(function() vehicle:queueLuaCommand(command) end)
  if ok then
    if reason ~= 'hold_refresh' then
      log('I', logTag, string.format('Stopped hold queued for %s reason=%s', label, tostring(reason or 'state')))
    end
  else
    log('E', logTag, string.format('Failed to hold %s stopped: %s', label, tostring(errorMessage)))
  end
  if generatedScene then
    generatedScene.queuedAICommands = generatedScene.queuedAICommands or {}
    generatedScene.queuedAICommands[label .. ' stoppedHold'] = command
  end
  local objectId = getVehicleObjectId(vehicle)
  diagnostics.recordCommand(label, objectId, 'stopped_hold', command)
  return ok
end

local function ensureVehicleController(entry, initialState)
  if not entry then return nil end
  entry.controller = entry.controller or {}
  local controller = entry.controller
  controller.state = controller.state or initialState or VEHICLE_STATE.CRUISE
  controller.previousState = controller.previousState
  controller.brakeAmount = controller.brakeAmount or 0
  controller.stopSpeedMps = controller.stopSpeedMps or vehicleControllerDefaults.stopSpeedMps
  controller.reverseToleranceMps = controller.reverseToleranceMps or vehicleControllerDefaults.reverseToleranceMps
  controller.holdRefreshInterval = controller.holdRefreshInterval or vehicleControllerDefaults.holdRefreshInterval
  controller.holdRefreshElapsed = controller.holdRefreshElapsed or 0
  controller.reverseCorrectionMaxMps = controller.reverseCorrectionMaxMps or vehicleControllerDefaults.reverseCorrectionMaxMps
  controller.reverseLogInterval = controller.reverseLogInterval or vehicleControllerDefaults.reverseLogInterval
  controller.reverseLogElapsed = controller.reverseLogElapsed or controller.reverseLogInterval
  controller.reverseGuardCount = controller.reverseGuardCount or 0
  controller.reverseCorrectionCount = controller.reverseCorrectionCount or 0
  controller.autoStop = controller.autoStop ~= false
  controller.followingSyncInterval = controller.followingSyncInterval or vehicleControllerDefaults.followingSyncInterval
  controller.followingSpeedDelta = controller.followingSpeedDelta or vehicleControllerDefaults.followingSpeedDelta
  controller.followRefreshElapsed = controller.followRefreshElapsed or 0
  controller.initialized = controller.initialized == true
  controller.lastFollowingSyncTime = controller.lastFollowingSyncTime
  controller.lastFollowingCommandedSpeed = controller.lastFollowingCommandedSpeed
  controller.followingRouteInitialized = controller.followingRouteInitialized == true
  controller.followingTargetId = controller.followingTargetId
  controller.followingTargetMissingWarning = controller.followingTargetMissingWarning == true
  return controller
end

local function getVehicleVelocity(entry)
  if not entry or not entry.vehicle or not entry.vehicle.getVelocity then return nil end
  local ok, velocity = pcall(function() return entry.vehicle:getVelocity() end)
  if not ok or not velocity then return nil end
  return vec3(velocity)
end

local function getVehicleLongitudinalSpeed(entry, direction)
  local velocity = getVehicleVelocity(entry)
  if not velocity or not direction then return nil end
  return velocity:dot(direction)
end

local function cancelLowSpeedReverseCreep(entry, direction, longitudinalSpeed)
  if not entry or not entry.vehicle or not direction or not longitudinalSpeed then return false end
  local controller = ensureVehicleController(entry)
  if longitudinalSpeed >= -controller.reverseToleranceMps then return false end
  if math.abs(longitudinalSpeed) > controller.reverseCorrectionMaxMps then
    return false
  end
  if not entry.vehicle.setVelocity then
    return false
  end

  local velocity = getVehicleVelocity(entry)
  if not velocity then return false end

  -- Remove only the backwards component along the road. Lateral and vertical
  -- velocity are preserved, and higher-speed collision motion is never clamped.
  local correctedVelocity = velocity - direction * longitudinalSpeed
  local ok, errorMessage = pcall(function()
    entry.vehicle:setVelocity(correctedVelocity)
  end)
  if ok then
    controller.reverseCorrectionCount = controller.reverseCorrectionCount + 1
    return true
  end

  log('E', logTag, string.format(
    'Failed to cancel low-speed reverse creep for %s: %s',
    tostring(entry.label), tostring(errorMessage)
  ))
  return false
end

local function setVehicleControllerState(entry, newState, options)
  if not entry then return false end
  options = options or {}
  local controller = ensureVehicleController(entry, newState)
  local oldState = controller.state
  local applied = false

  if oldState == newState and controller.initialized then
    return false
  end

  if newState == VEHICLE_STATE.CRUISE or newState == VEHICLE_STATE.COASTING or newState == VEHICLE_STATE.DECELERATING or newState == VEHICLE_STATE.FOLLOWING then
    local speed = tonumber(options.speedMps) or tonumber(entry.speedMps) or 0
    local laneAware = generatedScene and generatedScene.roadRules and generatedScene.roadRules.driveInLane
    local pathValid, pathCount
    applied, pathValid, pathCount = queueVehicleAI(entry.vehicle, speed, entry.label, generatedScene and generatedScene.targetPath, laneAware)
    if applied then
      entry.speedMps = speed
      controller.targetSpeedMps = speed
      controller.brakeAmount = 0
      controller.holdRefreshElapsed = 0
      controller.autoStop = true
      controller.followTargetLabel = newState == VEHICLE_STATE.FOLLOWING and options.followTarget or nil
      controller.followSpeedOffsetMps = newState == VEHICLE_STATE.FOLLOWING and (tonumber(options.speedOffsetMps) or 0) or 0
      controller.followRefreshElapsed = 0
      controller.followingRouteInitialized = newState == VEHICLE_STATE.FOLLOWING and pathValid == true or false
      controller.followingTargetId = newState == VEHICLE_STATE.FOLLOWING and options.followTarget or nil
      controller.lastFollowingSyncTime = newState == VEHICLE_STATE.FOLLOWING and (generatedScene and generatedScene.timeline and generatedScene.timeline.elapsed or 0) or nil
      controller.lastFollowingCommandedSpeed = newState == VEHICLE_STATE.FOLLOWING and speed or nil
      controller.followingTargetMissingWarning = false
      if newState == VEHICLE_STATE.FOLLOWING and pathValid == true then
        log('I', logTag, string.format(
          'Following route initialized for %s nodes=%d', tostring(entry.label), tonumber(pathCount) or 0
        ))
      end
    end
  elseif newState == VEHICLE_STATE.BRAKING or newState == VEHICLE_STATE.EMERGENCY_BRAKING then
    local brakeAmount = clamp(tonumber(options.brakeAmount) or 1, 0, 1)
    applied = queueVehicleBrake(entry.vehicle, entry.label, brakeAmount, options.commandName or 'controllerBrake')
    if applied then
      controller.brakeAmount = brakeAmount
      controller.holdRefreshElapsed = 0
      controller.autoStop = options.autoStop ~= false
      controller.followTargetLabel = nil
    end
  elseif newState == VEHICLE_STATE.STOPPED then
    applied = queueVehicleStoppedHold(entry.vehicle, entry.label, options.reason)
    if applied then
      controller.brakeAmount = 1
      controller.holdRefreshElapsed = 0
      controller.autoStop = true
      controller.followTargetLabel = nil
    end
  else
    log('E', logTag, string.format('Unknown controller state for %s: %s', tostring(entry.label), tostring(newState)))
    return false
  end

  if applied then
    controller.initialized = true
    controller.previousState = oldState
    controller.state = newState
    controller.stateChangedAt = generatedScene and generatedScene.timeline and generatedScene.timeline.elapsed or 0
    log('I', logTag, string.format(
      'Vehicle controller transition %s: %s -> %s',
      tostring(entry.label), tostring(oldState), tostring(newState)
    ))
  end
  return applied
end

local function updateVehicleControllers(delta, direction)
  for _, entry in ipairs(generatedVehicles) do
    if not entry.isAmbient then
    local controller = ensureVehicleController(entry, entry.role == 'stopped_hazard' and VEHICLE_STATE.STOPPED or VEHICLE_STATE.CRUISE)
    local longitudinalSpeed = getVehicleLongitudinalSpeed(entry, direction)
    controller.lastLongitudinalSpeed = longitudinalSpeed
    controller.reverseLogElapsed = controller.reverseLogElapsed + delta

    if (controller.state == VEHICLE_STATE.BRAKING or controller.state == VEHICLE_STATE.EMERGENCY_BRAKING) and longitudinalSpeed then
      if longitudinalSpeed < -controller.reverseToleranceMps then
        setVehicleControllerState(entry, VEHICLE_STATE.STOPPED, {reason = 'reverse_guard'})
        local corrected = cancelLowSpeedReverseCreep(entry, direction, longitudinalSpeed)
        if controller.reverseLogElapsed >= controller.reverseLogInterval then
          controller.reverseGuardCount = controller.reverseGuardCount + 1
          log('W', logTag, string.format(
            'Reverse guard transitioned %s to STOPPED speed=%.3f corrected=%s count=%d',
            entry.label, longitudinalSpeed, tostring(corrected), controller.reverseGuardCount
          ))
          controller.reverseLogElapsed = 0
        end
      elseif math.abs(longitudinalSpeed) <= controller.stopSpeedMps and controller.autoStop ~= false then
        setVehicleControllerState(entry, VEHICLE_STATE.STOPPED, {reason = 'braking_complete'})
      end
    elseif controller.state == VEHICLE_STATE.FOLLOWING then
      controller.followRefreshElapsed = controller.followRefreshElapsed + delta
      if controller.followTargetLabel and controller.followRefreshElapsed >= controller.followingSyncInterval then
        local targetEntry = findGeneratedVehicleEntry(controller.followTargetLabel)
        local targetSpeed = targetEntry and getVehicleLongitudinalSpeed(targetEntry, direction) or nil
        if targetSpeed and targetSpeed >= 0 then
          local desiredSpeed = math.max(0, targetSpeed + (controller.followSpeedOffsetMps or 0))
          local sceneTime = generatedScene and generatedScene.timeline and generatedScene.timeline.elapsed or 0
          local elapsedSinceSync = sceneTime - (controller.lastFollowingSyncTime or -math.huge)
          local speedDelta = math.abs(desiredSpeed - (controller.lastFollowingCommandedSpeed or desiredSpeed))
          local shouldSync = controller.lastFollowingCommandedSpeed == nil or
            elapsedSinceSync >= controller.followingSyncInterval or
            (speedDelta >= controller.followingSpeedDelta and elapsedSinceSync >= controller.followingSyncInterval)
          if shouldSync and queueFollowingSpeedSync(entry, desiredSpeed) then
            controller.lastFollowingSyncTime = sceneTime
            controller.lastFollowingCommandedSpeed = desiredSpeed
            controller.targetSpeedMps = desiredSpeed
            entry.speedMps = desiredSpeed
            log('D', logTag, string.format(
              'Following speed sync %s target=%s speed=%.2f',
              tostring(entry.label), tostring(controller.followTargetLabel), desiredSpeed
            ))
          end
        elseif not controller.followingTargetMissingWarning then
          controller.followingTargetMissingWarning = true
          log('W', logTag, string.format(
            'Following target unavailable for %s target=%s; preserving current route and speed sceneTime=%.3f',
            tostring(entry.label), tostring(controller.followTargetLabel),
            tonumber(generatedScene and generatedScene.timeline and generatedScene.timeline.elapsed or 0) or 0
          ))
        end
        controller.followRefreshElapsed = 0
      end
    elseif controller.state == VEHICLE_STATE.STOPPED then
      controller.holdRefreshElapsed = controller.holdRefreshElapsed + delta
      local reverseDetected = longitudinalSpeed and longitudinalSpeed < -controller.reverseToleranceMps
      local corrected = false

      if reverseDetected then
        corrected = cancelLowSpeedReverseCreep(entry, direction, longitudinalSpeed)
        if controller.reverseLogElapsed >= controller.reverseLogInterval then
          controller.reverseGuardCount = controller.reverseGuardCount + 1
          log('W', logTag, string.format(
            'Reverse guard for %s speed=%.3f corrected=%s corrections=%d count=%d',
            entry.label, longitudinalSpeed, tostring(corrected),
            controller.reverseCorrectionCount, controller.reverseGuardCount
          ))
          controller.reverseLogElapsed = 0
        end
      end

      -- Reassert the hold on a fixed cadence only. The previous implementation
      -- queued the same command every simulation frame while reversing, which
      -- flooded the vehicle command queue without cancelling physical velocity.
      if controller.holdRefreshElapsed >= controller.holdRefreshInterval then
        queueVehicleStoppedHold(entry.vehicle, entry.label, reverseDetected and 'reverse_guard_refresh' or 'hold_refresh')
        controller.holdRefreshElapsed = 0
      end
    end
    end
  end
end

local function findForwardNextNode(currentNode, previousNode)
  local mapData = map.getMap()
  local mapNodes = mapData and mapData.nodes
  local graphpath = map.getGraphpath()
  local graph = graphpath and graphpath.graph
  local current = mapNodes and mapNodes[currentNode]
  local previous = mapNodes and mapNodes[previousNode]
  if not current or not previous or not graph or not graph[currentNode] then return nil end

  local incoming = (current.pos - previous.pos):normalized()
  local bestNode = nil
  local bestAngle = math.huge
  for candidateNode in pairs(graph[currentNode]) do
    if candidateNode ~= previousNode and mapNodes[candidateNode] then
      local outgoing = (mapNodes[candidateNode].pos - current.pos):normalized()
      local angle = math.deg(math.acos(clamp(incoming:dot(outgoing), -1, 1)))
      if angle < bestAngle then
        bestAngle = angle
        bestNode = candidateNode
      end
    end
  end
  if bestNode then
    log('I', logTag, string.format('Forward neighbor for %s after %s is %s turnAngle=%.2f', tostring(currentNode), tostring(previousNode), tostring(bestNode), bestAngle))
  else
    log('I', logTag, string.format('No forward neighbor found for %s after %s', tostring(currentNode), tostring(previousNode)))
  end
  return bestNode
end


local function getRoadRulesSafe()
  local roadRules = nil
  if map and map.getRoadRules then
    local ok, value = pcall(function() return map.getRoadRules() end)
    if ok then roadRules = value end
  end

  -- BeamNG defaults rightHandDrive to false. In BeamNG terminology this flag
  -- refers to right-hand-drive vehicles, so false corresponds to right-side
  -- traffic and true corresponds to left-side traffic.
  return roadRules or {rightHandDrive = false, turnOnRed = false}
end

local function getRoadLink(mapNodes, nodeAId, nodeBId)
  local nodeA = mapNodes and mapNodes[nodeAId]
  local nodeB = mapNodes and mapNodes[nodeBId]
  if nodeA and nodeA.links and nodeA.links[nodeBId] then return nodeA.links[nodeBId] end
  if nodeB and nodeB.links and nodeB.links[nodeAId] then return nodeB.links[nodeAId] end
  return nil
end

local function estimateLaneGeometry(nodeA, nodeB, link)
  local radiusA = tonumber(nodeA and nodeA.radius) or 2.25
  local radiusB = tonumber(nodeB and nodeB.radius) or radiusA
  local radius = (radiusA + radiusB) * 0.5
  local roadWidth = radius * 2
  local nominalLaneWidth = roadWidth >= 6.1 and 3.05 or 2.4
  local laneCount = math.max(1, math.floor(roadWidth / nominalLaneWidth))
  local oneWay = link and link.oneWay == true or false

  -- BeamNG traffic uses an even estimated lane count on two-way roads.
  if not oneWay and laneCount % 2 ~= 0 then
    laneCount = math.max(1, laneCount - 1)
  end

  return {
    radius = radius,
    roadWidth = roadWidth,
    nominalLaneWidth = nominalLaneWidth,
    laneCount = laneCount,
    laneCellWidth = roadWidth / laneCount,
    oneWay = oneWay,
  }
end

local function chooseRoadDirection(spot, link, directionOverride)
  local override = tonumber(directionOverride)
  local requestedOverride = (override == 1 or override == -1) and override or nil

  if link and link.oneWay then
    -- inNode identifies the legal direction on a one-way link. A conflicting
    -- manual override is ignored rather than allowing a scenario against traffic.
    local legalDirection = link.inNode == spot.nodeA and 1 or -1
    if requestedOverride and requestedOverride ~= legalDirection then
      log('W', logTag, string.format(
        'Illegal travelDirectionOverride=%d ignored on one-way road; legalDirection=%d inNode=%s',
        requestedOverride, legalDirection, tostring(link.inNode)
      ))
      return legalDirection, 'oneWay.guard.overrideRejected', true, requestedOverride
    end
    return legalDirection, 'oneWay.inNode', false, requestedOverride
  end

  if requestedOverride then
    return requestedOverride, 'twoWay.manualOverride', false, requestedOverride
  end

  return 1, 'twoWay.default.nodeA_to_nodeB', false, nil
end

local function buildDirectionalTargetPath(spot, roadDir)
  local mapData = map.getMap()
  local mapNodes = mapData and mapData.nodes
  local firstNode = roadDir == 1 and spot.nodeB or spot.nodeA
  local previousNode = roadDir == 1 and spot.nodeA or spot.nodeB
  local targetPath = {firstNode}
  local visited = {[tostring(previousNode)] = true, [tostring(firstNode)] = true}
  local currentNode = firstNode
  local totalDistance = 0
  local maximumNodes = 12
  local desiredPathDistance = 800

  while #targetPath < maximumNodes and totalDistance < desiredPathDistance do
    local nextNode = findForwardNextNode(currentNode, previousNode)
    if not nextNode or visited[tostring(nextNode)] then break end

    if mapNodes and mapNodes[currentNode] and mapNodes[nextNode] then
      totalDistance = totalDistance + mapNodes[currentNode].pos:distance(mapNodes[nextNode].pos)
    end
    table.insert(targetPath, nextNode)
    visited[tostring(nextNode)] = true
    previousNode = currentNode
    currentNode = nextNode
  end

  log('I', logTag, string.format(
    'Directional target path built: roadDir=%d nodes=%d forwardDistance=%.2f',
    roadDir, #targetPath, totalDistance
  ))
  return targetPath
end

local function snapPositionToSurface(position)
  if not be or not be.getSurfaceHeightBelow then return position end
  local ok, surfaceHeight = pcall(function()
    return be:getSurfaceHeightBelow(position + vec3(0, 0, 3))
  end)
  if ok and surfaceHeight and surfaceHeight >= -1e6 then
    position.z = surfaceHeight
  end
  return position
end

local function buildRoadRulePlan(spot, directionOverride, includePath)
  if not spot or spot.type ~= 'straight' then return nil end

  local mapData = map.getMap()
  local mapNodes = mapData and mapData.nodes
  local nodeA = mapNodes and mapNodes[spot.nodeA]
  local nodeB = mapNodes and mapNodes[spot.nodeB]
  if not nodeA or not nodeB then return nil end

  local link = getRoadLink(mapNodes, spot.nodeA, spot.nodeB)
  local lane = estimateLaneGeometry(nodeA, nodeB, link)
  local roadRules = getRoadRulesSafe()
  local roadDir, directionSource, overrideRejected, requestedDirectionOverride = chooseRoadDirection(spot, link, directionOverride)
  local baseDir = (nodeB.pos - nodeA.pos):normalized()
  local travelDir = baseDir * roadDir
  local roadRight = vec3(baseDir.y, -baseDir.x, 0):normalized()
  local travelRight = vec3(travelDir.y, -travelDir.x, 0):normalized()

  -- In BeamNG road rules, rightHandDrive=false means normal right-side traffic.
  local legalSide = roadRules.rightHandDrive and -1 or 1
  local laneChoice = 1
  if lane.laneCount > 1 then
    if activeScenarioDefinition.lanePreference == 'outer' then
      laneChoice = roadDir == 1 and lane.laneCount or 1
    else
      laneChoice = roadDir == 1 and (math.floor(lane.laneCount * 0.5) + 1) or math.floor(lane.laneCount * 0.5)
      laneChoice = clamp(laneChoice, 1, lane.laneCount)
    end
  end

  local laneOffset = (laneChoice - (lane.laneCount * 0.5 + 0.5)) * lane.laneCellWidth * legalSide
  local base = vec3(spot.pos.x, spot.pos.y, spot.pos.z)
  local laneCenter = snapPositionToSurface(base + roadRight * laneOffset)
  local targetPath = includePath and buildDirectionalTargetPath(spot, roadDir) or nil
  local drivability = tonumber(link and link.drivability) or 1
  local roadType = link and link.type or 'unknown'
  local valid = roadType ~= 'private' and drivability >= activeScenarioDefinition.minimumDrivability

  return {
    valid = valid,
    spot = spot,
    nodeA = spot.nodeA,
    nodeB = spot.nodeB,
    link = link,
    roadRules = roadRules,
    trafficSide = roadRules.rightHandDrive and 'left' or 'right',
    legalSide = legalSide,
    directionSource = directionSource,
    overrideRejected = overrideRejected,
    requestedDirectionOverride = requestedDirectionOverride,
    roadDir = roadDir,
    baseDir = baseDir,
    travelDir = travelDir,
    roadRight = roadRight,
    travelRight = travelRight,
    laneCenter = laneCenter,
    laneOffset = laneOffset,
    laneChoice = laneChoice,
    laneCount = lane.laneCount,
    laneCellWidth = lane.laneCellWidth,
    nominalLaneWidth = lane.nominalLaneWidth,
    radius = lane.radius,
    roadWidth = lane.roadWidth,
    oneWay = lane.oneWay,
    drivability = drivability,
    roadType = roadType,
    targetPath = targetPath,
  }
end

local function resolveMapNodeId(mapNodes, requestedId)
  if requestedId == nil or not mapNodes then return nil end
  if mapNodes[requestedId] then return requestedId end
  local requestedText = tostring(requestedId)
  for nodeId in pairs(mapNodes) do
    if tostring(nodeId) == requestedText then return nodeId end
  end
  return nil
end

local function makeNavgraphEdgeSpot(mapNodes, nodeAId, nodeBId)
  local nodeA = mapNodes and mapNodes[nodeAId]
  local nodeB = mapNodes and mapNodes[nodeBId]
  if not nodeA or not nodeB then return nil end
  local length = nodeA.pos:distance(nodeB.pos)
  if length <= 0.5 then return nil end
  local direction = (nodeB.pos - nodeA.pos):normalized()
  local position = midpoint(nodeA.pos, nodeB.pos)
  local offset = math.min(30, length * 0.35)
  return {
    type = 'straight',
    index = 'edge:' .. tostring(nodeAId) .. '<->' .. tostring(nodeBId),
    source = 'navgraph_edge',
    pos = copyPosition(position),
    nodeA = nodeAId,
    nodeB = nodeBId,
    length = length,
    turnAngle = 0,
    radius = ((tonumber(nodeA.radius) or 0) + (tonumber(nodeB.radius) or 0)) * 0.5,
    dir = copyVector(direction),
    startPos = copyPosition(position - direction * offset),
    endPos = copyPosition(position + direction * offset),
  }
end

local function getPlanTravelEndpoints(plan)
  if not plan then return nil, nil end
  if tonumber(plan.roadDir) == -1 then return plan.nodeB, plan.nodeA end
  return plan.nodeA, plan.nodeB
end

local function getNavgraphNeighborIds(mapNodes, nodeId)
  local result = {}
  local seen = {}
  local node = mapNodes and mapNodes[nodeId]
  for neighborId in pairs((node and node.links) or {}) do
    local key = tostring(neighborId)
    if not seen[key] then
      seen[key] = true
      table.insert(result, neighborId)
    end
  end
  local graphpath = map and map.getGraphpath and map.getGraphpath() or nil
  local graph = graphpath and graphpath.graph
  for neighborId in pairs((graph and graph[nodeId]) or {}) do
    local key = tostring(neighborId)
    if not seen[key] then
      seen[key] = true
      table.insert(result, neighborId)
    end
  end
  return result
end

local function findLegalOneWayContinuation(mapNodes, currentNode, adjacentNode, expectedTravelDir, primaryTravelDir, config, seekPredecessor)
  local continuationDotThreshold = clamp(tonumber(config.continuationDotThreshold) or 0.72, 0.3, 0.999)
  local maintainOppositeDotThreshold = clamp(tonumber(config.maintainOppositeDotThreshold) or 0.60, 0.1, 0.999)
  local minimumDrivability = tonumber(config.minimumDrivability) or tonumber(activeScenarioDefinition.minimumDrivability) or 0.25
  local best = nil
  local bestScore = math.huge

  for _, neighborId in ipairs(getNavgraphNeighborIds(mapNodes, currentNode)) do
    if neighborId ~= adjacentNode and mapNodes[neighborId] then
      local edgeSpot = makeNavgraphEdgeSpot(mapNodes, currentNode, neighborId)
      local edgePlan = edgeSpot and buildRoadRulePlan(edgeSpot, nil, false) or nil
      if edgePlan and edgePlan.valid and edgePlan.oneWay and (tonumber(edgePlan.drivability) or 0) >= minimumDrivability then
        local legalFrom, legalTo = getPlanTravelEndpoints(edgePlan)
        local directionMatches = seekPredecessor and legalTo == currentNode or (not seekPredecessor and legalFrom == currentNode)
        if directionMatches then
          local continuationDot = edgePlan.travelDir:dot(expectedTravelDir)
          local oppositeDot = edgePlan.travelDir:dot(primaryTravelDir)
          if continuationDot >= continuationDotThreshold and oppositeDot <= -maintainOppositeDotThreshold then
            local score = (1 - continuationDot) * 100 + (1 + oppositeDot) * 20
            if score < bestScore then
              bestScore = score
              best = {
                nodeId = seekPredecessor and legalFrom or legalTo,
                plan = edgePlan,
                continuationDot = continuationDot,
                oppositeDot = oppositeDot,
              }
            end
          end
        end
      end
    end
  end
  return best
end

local function walkOneWayCorridor(mapNodes, seedFrom, seedTo, expectedTravelDir, primaryTravelDir, config, seekPredecessor, maximumDistance)
  local nodes = {}
  local totalDistance = 0
  local maximumNodes = math.max(2, math.floor(tonumber(config.maximumCorridorNodesPerSide) or 18))
  local currentNode = seekPredecessor and seedFrom or seedTo
  local adjacentNode = seekPredecessor and seedTo or seedFrom

  while #nodes < maximumNodes and totalDistance < maximumDistance do
    local continuation = findLegalOneWayContinuation(
      mapNodes, currentNode, adjacentNode, expectedTravelDir, primaryTravelDir, config, seekPredecessor
    )
    if not continuation or not continuation.nodeId then break end
    local nextNode = continuation.nodeId
    local current = mapNodes[currentNode]
    local nextValue = mapNodes[nextNode]
    if not current or not nextValue then break end
    totalDistance = totalDistance + current.pos:distance(nextValue.pos)
    table.insert(nodes, nextNode)
    adjacentNode = currentNode
    currentNode = nextNode
  end

  return nodes, totalDistance, currentNode, adjacentNode
end

local function buildTargetPathBeyondCorridor(mapNodes, forwardEndNode, previousNode, expectedTravelDir, primaryTravelDir, config)
  local targetPath = {forwardEndNode}
  local totalDistance = 0
  local maximumNodes = math.max(4, math.floor(tonumber(config.maximumTargetPathNodes) or 14))
  local desiredDistance = math.max(160, tonumber(config.targetPathDistance) or 700)
  local currentNode = forwardEndNode
  local adjacentNode = previousNode

  while #targetPath < maximumNodes and totalDistance < desiredDistance do
    local continuation = findLegalOneWayContinuation(
      mapNodes, currentNode, adjacentNode, expectedTravelDir, primaryTravelDir, config, false
    )
    if not continuation or not continuation.nodeId then break end
    local nextNode = continuation.nodeId
    totalDistance = totalDistance + mapNodes[currentNode].pos:distance(mapNodes[nextNode].pos)
    table.insert(targetPath, nextNode)
    adjacentNode = currentNode
    currentNode = nextNode
  end
  return targetPath, totalDistance
end

local function buildOppositeCorridorPlan(edgeSpot, primaryPlan, oppositeConfig, discovery)
  local mapData = map.getMap()
  local mapNodes = mapData and mapData.nodes
  if not mapNodes or not edgeSpot then return nil, 'missing_map_or_edge' end

  local edgePlan = buildRoadRulePlan(edgeSpot, nil, false)
  if not edgePlan or not edgePlan.valid then return nil, 'edge_plan_invalid' end
  if not edgePlan.oneWay then return nil, 'edge_not_one_way' end

  local seedFrom, seedTo = getPlanTravelEndpoints(edgePlan)
  if not seedFrom or not seedTo then return nil, 'missing_legal_endpoints' end
  local seedLength = mapNodes[seedFrom].pos:distance(mapNodes[seedTo].pos)
  local halfSpan = math.max(90, tonumber(oppositeConfig.spawnHalfSpan) or 150)
  local backwardNodes, backwardDistance, backwardEnd = walkOneWayCorridor(
    mapNodes, seedFrom, seedTo, edgePlan.travelDir, primaryPlan.travelDir, oppositeConfig, true, halfSpan
  )
  local forwardNodes, forwardDistance, forwardEnd, forwardPrevious = walkOneWayCorridor(
    mapNodes, seedFrom, seedTo, edgePlan.travelDir, primaryPlan.travelDir, oppositeConfig, false, halfSpan
  )

  backwardEnd = backwardEnd or seedFrom
  forwardEnd = forwardEnd or seedTo
  local backwardPos = mapNodes[backwardEnd] and mapNodes[backwardEnd].pos
  local forwardPos = mapNodes[forwardEnd] and mapNodes[forwardEnd].pos
  if not backwardPos or not forwardPos then return nil, 'corridor_endpoint_missing' end

  local chainDistance = backwardDistance + seedLength + forwardDistance
  local directSpan = backwardPos:distance(forwardPos)
  local minimumStraightLength = math.max(80, tonumber(oppositeConfig.minimumStraightLength) or 180)
  if chainDistance < minimumStraightLength then return nil, 'corridor_path_too_short' end
  if directSpan < minimumStraightLength * 0.70 then return nil, 'corridor_direct_span_too_short' end

  local corridorDir = (forwardPos - backwardPos):normalized()
  local corridorAlignment = corridorDir:dot(edgePlan.travelDir)
  local corridorDotThreshold = clamp(tonumber(oppositeConfig.corridorDotThreshold) or 0.82, 0.5, 0.999)
  if corridorAlignment < corridorDotThreshold then return nil, 'corridor_not_straight_enough' end

  local pathPrevious = forwardPrevious or seedFrom
  local targetPath, targetPathDistance = buildTargetPathBeyondCorridor(
    mapNodes, forwardEnd, pathPrevious, corridorDir, primaryPlan.travelDir, oppositeConfig
  )
  if #targetPath < 2 then return nil, 'opposite_target_path_too_short' end

  local center = midpoint(backwardPos, forwardPos)
  local syntheticSpot = {
    type = 'straight',
    index = edgeSpot.index,
    source = 'navgraph_edge_corridor',
    pos = copyPosition(center),
    nodeA = edgeSpot.nodeA,
    nodeB = edgeSpot.nodeB,
    length = directSpan,
    pathLength = chainDistance,
    turnAngle = 0,
    radius = edgeSpot.radius,
    dir = copyVector(corridorDir),
    startPos = copyPosition(backwardPos),
    endPos = copyPosition(forwardPos),
  }

  edgePlan.spot = syntheticSpot
  edgePlan.travelDir = corridorDir
  edgePlan.baseDir = corridorDir * edgePlan.roadDir
  edgePlan.roadRight = vec3(edgePlan.baseDir.y, -edgePlan.baseDir.x, 0):normalized()
  edgePlan.travelRight = vec3(corridorDir.y, -corridorDir.x, 0):normalized()
  edgePlan.laneCenter = snapPositionToSurface(center + edgePlan.roadRight * edgePlan.laneOffset)
  edgePlan.targetPath = targetPath
  edgePlan.oppositeDiscovery = discovery or {}
  edgePlan.oppositeDiscovery.mode = edgePlan.oppositeDiscovery.mode or 'nearby_navgraph_edge_corridor'
  edgePlan.oppositeDiscovery.seedEdgeLength = seedLength
  edgePlan.oppositeDiscovery.chainDistance = chainDistance
  edgePlan.oppositeDiscovery.directSpan = directSpan
  edgePlan.oppositeDiscovery.corridorAlignment = corridorAlignment
  edgePlan.oppositeDiscovery.backwardNodes = #backwardNodes
  edgePlan.oppositeDiscovery.forwardNodes = #forwardNodes
  edgePlan.oppositeDiscovery.targetPathNodes = #targetPath
  edgePlan.oppositeDiscovery.targetPathDistance = targetPathDistance
  return edgePlan, nil
end

local function appendDiagnosticReason(item, reason)
  item.reasons = item.reasons or {}
  table.insert(item.reasons, reason)
end

local function diagnosticReasonText(item)
  if not item or not item.reasons or #item.reasons == 0 then return 'accepted' end
  return table.concat(item.reasons, ',')
end

local function logOppositeCandidateDiagnostics(diagnostics)
  if not diagnostics then return end
  local candidates = diagnostics.candidates or {}
  local limit = math.min(5, #candidates)
  for index = 1, limit do
    local item = candidates[index]
    log(item.accepted and 'I' or 'D', logTag, string.format(
      'Opposite candidate rank=%d nodes=%s<->%s accepted=%s reason=%s score=%.2f edgeLength=%.2f lateral=%.2f longitudinal=%.2f vertical=%.2f directionDot=%.3f drivability=%.2f oneWay=%s',
      index, tostring(item.nodeA), tostring(item.nodeB), tostring(item.accepted), diagnosticReasonText(item),
      tonumber(item.score) or math.huge, tonumber(item.edgeLength) or 0, tonumber(item.lateralSeparation) or 0,
      tonumber(item.longitudinalOffset) or 0, tonumber(item.verticalDifference) or 0,
      tonumber(item.directionDot) or 0, tonumber(item.drivability) or 0, tostring(item.oneWay)
    ))
  end
end

local function buildManualOppositeOverridePlan(primaryPlan, oppositeConfig, mapNodes)
  if not oppositeCarriagewayOverride then return nil, nil end
  local nodeAId = resolveMapNodeId(mapNodes, oppositeCarriagewayOverride.nodeA)
  local nodeBId = resolveMapNodeId(mapNodes, oppositeCarriagewayOverride.nodeB)
  if not nodeAId or not nodeBId then return nil, 'manual_override_nodes_not_found' end
  local edgeSpot = makeNavgraphEdgeSpot(mapNodes, nodeAId, nodeBId)
  if not edgeSpot or not getRoadLink(mapNodes, nodeAId, nodeBId) then return nil, 'manual_override_edge_not_found' end
  local basePlan = buildRoadRulePlan(edgeSpot, nil, false)
  if not basePlan or not basePlan.valid or not basePlan.oneWay then return nil, 'manual_override_edge_invalid' end
  local directionDot = basePlan.travelDir:dot(primaryPlan.travelDir)
  local discovery = {
    mode = 'manual_navgraph_edge_override',
    directionDot = directionDot,
    score = 0,
    manualOverride = true,
  }
  local plan, reason = buildOppositeCorridorPlan(edgeSpot, primaryPlan, oppositeConfig, discovery)
  if not plan then return nil, 'manual_override_' .. tostring(reason) end
  log('I', logTag, string.format(
    'Manual opposite carriageway override selected nodes=%s<->%s dirDot=%.3f span=%.2f targetPathNodes=%d',
    tostring(nodeAId), tostring(nodeBId), directionDot, tonumber(plan.spot.length) or 0, #(plan.targetPath or {})
  ))
  return plan, nil
end

local function findOppositeCarriagewayPlan(primaryPlan, ambientConfig)
  local oppositeConfig = ambientConfig and ambientConfig.oppositeFlow or {}
  if oppositeConfig.enabled == false then return nil, 'disabled' end
  if not primaryPlan then return nil, 'missing_primary_plan' end

  -- On an undivided two-way road, the opposite flow lives on the same navgraph
  -- edge. Build a second legal road plan with the reversed travel direction.
  if not primaryPlan.oneWay then
    local reversePlan = buildRoadRulePlan(primaryPlan.spot, -primaryPlan.roadDir, true)
    if reversePlan and reversePlan.valid then
      reversePlan.oppositeDiscovery = {
        mode = 'same_two_way_segment',
        lateralSeparation = 0,
        longitudinalOffset = 0,
        verticalDifference = 0,
        directionDot = reversePlan.travelDir:dot(primaryPlan.travelDir),
        score = 0,
      }
      log('I', logTag, string.format(
        'Opposite flow uses same two-way segment spot=%s roadDir=%d lane=%d/%d',
        tostring(reversePlan.spot.index), reversePlan.roadDir, reversePlan.laneChoice, reversePlan.laneCount
      ))
      lastOppositeCarriagewayDiagnostics = {mode = 'same_two_way_segment', candidates = {}}
      return reversePlan, nil
    end
    return nil, 'two_way_reverse_plan_invalid'
  end

  local mapData = map.getMap()
  local mapNodes = mapData and mapData.nodes
  if not mapNodes then return nil, 'missing_navgraph_nodes' end

  if oppositeCarriagewayOverride then
    local overridePlan, overrideReason = buildManualOppositeOverridePlan(primaryPlan, oppositeConfig, mapNodes)
    lastOppositeCarriagewayDiagnostics = {
      mode = 'manual_override',
      override = scenarioRegistry.copy(oppositeCarriagewayOverride),
      reason = overrideReason,
      candidates = {},
    }
    if overridePlan then return overridePlan, nil end
    log('W', logTag, string.format('Manual opposite carriageway override failed: %s', tostring(overrideReason)))
    return nil, overrideReason
  end

  local minimumLateralSeparation = math.max(2, tonumber(oppositeConfig.minimumLateralSeparation) or 5)
  local maximumLateralSeparation = math.max(minimumLateralSeparation, tonumber(oppositeConfig.maximumLateralSeparation) or 45)
  local maximumLongitudinalOffset = math.max(10, tonumber(oppositeConfig.maximumLongitudinalOffset) or 160)
  local maximumVerticalDifference = math.max(1, tonumber(oppositeConfig.maximumVerticalDifference) or 8)
  local parallelDotThreshold = clamp(tonumber(oppositeConfig.parallelDotThreshold) or 0.82, 0.5, 0.999)
  local minimumEdgeLength = math.max(2, tonumber(oppositeConfig.minimumEdgeLength) or 6)
  local minimumDrivability = tonumber(oppositeConfig.minimumDrivability) or tonumber(activeScenarioDefinition.minimumDrivability) or 0.25
  local maximumCorridorCandidates = math.max(5, math.floor(tonumber(oppositeConfig.maximumCorridorCandidates) or 24))

  local primaryPos = vec3(primaryPlan.spot.pos.x, primaryPlan.spot.pos.y, primaryPlan.spot.pos.z)
  local diagnostics = {}
  local accepted = {}
  local visitedEdges = {}

  for nodeAId, nodeA in pairs(mapNodes) do
    for nodeBId in pairs((nodeA and nodeA.links) or {}) do
      local key = edgeKey(nodeAId, nodeBId)
      if not visitedEdges[key] then
        visitedEdges[key] = true
        local item = {nodeA = nodeAId, nodeB = nodeBId, accepted = false, reasons = {}}
        local edgeSpot = makeNavgraphEdgeSpot(mapNodes, nodeAId, nodeBId)
        local candidatePos = edgeSpot and vec3(edgeSpot.pos.x, edgeSpot.pos.y, edgeSpot.pos.z) or primaryPos
        local delta = candidatePos - primaryPos
        item.edgeLength = edgeSpot and edgeSpot.length or 0
        item.lateralSeparation = math.abs(delta:dot(primaryPlan.travelRight))
        item.longitudinalOffset = math.abs(delta:dot(primaryPlan.travelDir))
        item.verticalDifference = math.abs(candidatePos.z - primaryPos.z)

        if key == edgeKey(primaryPlan.nodeA, primaryPlan.nodeB) then appendDiagnosticReason(item, 'primary_edge') end
        if not edgeSpot then appendDiagnosticReason(item, 'invalid_edge_geometry') end
        if item.edgeLength < minimumEdgeLength then appendDiagnosticReason(item, 'edge_too_short') end

        local candidatePlan = edgeSpot and buildRoadRulePlan(edgeSpot, nil, false) or nil
        item.oneWay = candidatePlan and candidatePlan.oneWay or false
        item.drivability = candidatePlan and tonumber(candidatePlan.drivability) or 0
        item.roadType = candidatePlan and candidatePlan.roadType or 'unknown'
        item.directionDot = candidatePlan and candidatePlan.travelDir:dot(primaryPlan.travelDir) or 1

        if not candidatePlan then appendDiagnosticReason(item, 'invalid_road_plan') end
        if candidatePlan and not candidatePlan.valid then appendDiagnosticReason(item, 'road_plan_rejected') end
        if candidatePlan and not candidatePlan.oneWay then appendDiagnosticReason(item, 'not_one_way') end
        if candidatePlan and item.drivability < minimumDrivability then appendDiagnosticReason(item, 'low_drivability') end
        if candidatePlan and candidatePlan.roadType == 'private' then appendDiagnosticReason(item, 'private_road') end
        if item.lateralSeparation < minimumLateralSeparation then appendDiagnosticReason(item, 'lateral_too_close') end
        if item.lateralSeparation > maximumLateralSeparation then appendDiagnosticReason(item, 'lateral_too_far') end
        if item.longitudinalOffset > maximumLongitudinalOffset then appendDiagnosticReason(item, 'longitudinal_too_far') end
        if item.verticalDifference > maximumVerticalDifference then appendDiagnosticReason(item, 'vertical_too_far') end
        if candidatePlan and item.directionDot > -parallelDotThreshold then appendDiagnosticReason(item, 'not_parallel_opposite') end

        local desiredLateral = (minimumLateralSeparation + maximumLateralSeparation) * 0.5
        local alignmentPenalty = math.max(0, 1 + item.directionDot) * 100
        local proximityPenalty = math.abs(item.lateralSeparation - desiredLateral) + item.longitudinalOffset * 0.18 + item.verticalDifference * 6
        item.score = proximityPenalty + alignmentPenalty
        item.edgeSpot = edgeSpot
        item.candidatePlan = candidatePlan
        item.accepted = #item.reasons == 0
        table.insert(diagnostics, item)
        if item.accepted then table.insert(accepted, item) end
      end
    end
  end

  table.sort(diagnostics, function(a, b) return (a.score or math.huge) < (b.score or math.huge) end)
  table.sort(accepted, function(a, b) return (a.score or math.huge) < (b.score or math.huge) end)

  local bestPlan = nil
  local bestItem = nil
  for index = 1, math.min(#accepted, maximumCorridorCandidates) do
    local item = accepted[index]
    local discovery = {
      mode = 'nearby_navgraph_edge_corridor',
      lateralSeparation = item.lateralSeparation,
      longitudinalOffset = item.longitudinalOffset,
      verticalDifference = item.verticalDifference,
      directionDot = item.directionDot,
      score = item.score,
      seedNodeA = item.nodeA,
      seedNodeB = item.nodeB,
    }
    local plan, reason = buildOppositeCorridorPlan(item.edgeSpot, primaryPlan, oppositeConfig, discovery)
    if plan then
      bestPlan = plan
      bestItem = item
      break
    end
    appendDiagnosticReason(item, 'corridor_' .. tostring(reason))
    item.accepted = false
  end

  table.sort(diagnostics, function(a, b)
    if a.accepted ~= b.accepted then return a.accepted end
    return (a.score or math.huge) < (b.score or math.huge)
  end)
  lastOppositeCarriagewayDiagnostics = {
    mode = 'nearby_navgraph_edges',
    scannedEdges = #diagnostics,
    acceptedEdges = #accepted,
    selectedNodeA = bestItem and bestItem.nodeA or nil,
    selectedNodeB = bestItem and bestItem.nodeB or nil,
    candidates = diagnostics,
  }
  logOppositeCandidateDiagnostics(lastOppositeCarriagewayDiagnostics)

  if not bestPlan then return nil, 'no_parallel_opposite_navgraph_edge_corridor' end
  log('I', logTag, string.format(
    'Opposite carriageway selected from navgraph edge nodes=%s<->%s lateral=%.2f longitudinal=%.2f vertical=%.2f dirDot=%.3f span=%.2f chain=%.2f targetPathNodes=%d score=%.2f',
    tostring(bestPlan.oppositeDiscovery.seedNodeA), tostring(bestPlan.oppositeDiscovery.seedNodeB),
    bestPlan.oppositeDiscovery.lateralSeparation, bestPlan.oppositeDiscovery.longitudinalOffset,
    bestPlan.oppositeDiscovery.verticalDifference, bestPlan.oppositeDiscovery.directionDot,
    tonumber(bestPlan.oppositeDiscovery.directSpan) or 0, tonumber(bestPlan.oppositeDiscovery.chainDistance) or 0,
    #(bestPlan.targetPath or {}), bestPlan.oppositeDiscovery.score
  ))
  return bestPlan, nil
end

local function isLaneAwareSpotUsable(spot)
  local plan = buildRoadRulePlan(spot, nil, false)
  return plan and plan.valid and plan.laneCount >= 1
end

local function selectLaneAwareStraightSpot(seed, minimumLength)
  local candidates = {}
  for _, spot in ipairs(spots) do
    if spot.type == 'straight' and
       (not minimumLength or (spot.length or 0) >= minimumLength) and
       isLaneAwareSpotUsable(spot) then
      table.insert(candidates, spot)
    end
  end

  if #candidates == 0 then
    log('W', logTag, 'No lane-aware straight spots passed road-rule validation')
    return nil
  end

  if seed == nil then return candidates[1] end
  local numericSeed = math.floor(tonumber(seed) or 0)
  local candidateCount = math.min(#candidates, 10)
  local value = (math.abs(numericSeed) * 1103515245 + 12345) % 2147483648
  local index = (value % candidateCount) + 1
  log('I', logTag, string.format(
    'Seed=%s selected lane-aware straight rank=%d/%d candidates=%d',
    tostring(seed), index, candidateCount, #candidates
  ))
  return candidates[index]
end

local function selectScenarioStraightSpot(seed)
  for _, minimumLength in ipairs(activeScenarioDefinition.preferredStraightLengths) do
    local spot = selectLaneAwareStraightSpot(seed, minimumLength)
    if spot then
      log('I', logTag, string.format(
        'Scenario road selected with minimumLength=%.2f actualLength=%.2f spot=%s',
        minimumLength, tonumber(spot.length) or 0, tostring(spot.index)
      ))
      return spot, minimumLength
    end
  end
  return nil, nil
end

local function buildScenarioVehicleSpecs(spot)
  if not spot or not spot.length then return nil end

  local convoy = activeScenarioDefinition.convoy
  local totalBackSpan = 0
  for index = 2, #convoy do
    totalBackSpan = totalBackSpan + (tonumber(convoy[index].gapBehind) or 0)
  end

  local edgeMargin = 12
  local usableSpan = math.max(0, spot.length - edgeMargin * 2)
  local leadSpeed = convoy[1].speedMps
  local hazardSpeed = tonumber(activeScenarioDefinition.hazard and activeScenarioDefinition.hazard.speedMps) or 0
  local closingSpeed = math.max(0.1, leadSpeed - hazardSpeed)
  local leadBrakeDistance = getScenarioDistanceFallback(
    activeScenarioDefinition, LEAD_TRIGGER_GROUP, activeScenarioDefinition.leadBrakeDistance
  )
  local spacingTriggerId = activeScenarioDefinition.initialSpacingTriggerId or LEAD_TRIGGER_ID
  local spacingTrigger = findScenarioTrigger(activeScenarioDefinition, spacingTriggerId)
  local spacingMetric = spacingTrigger and (spacingTrigger.metric or spacingTrigger.type) or 'ttc'
  local spacingThreshold = tonumber(spacingTrigger and spacingTrigger.threshold) or 0
  local primaryReactionGap
  if spacingMetric == 'ttc' and spacingThreshold > 0 then
    primaryReactionGap = closingSpeed * spacingThreshold
  elseif spacingMetric == 'distance' and spacingThreshold > 0 then
    primaryReactionGap = spacingThreshold
  else
    local leadTtcThreshold = getScenarioTtcThreshold(activeScenarioDefinition, LEAD_TRIGGER_GROUP, 0)
    primaryReactionGap = leadTtcThreshold > 0 and closingSpeed * leadTtcThreshold or leadBrakeDistance
  end
  local desiredHazardGap = primaryReactionGap + closingSpeed * activeScenarioDefinition.desiredNormalDriveTime
  local hazardGap = math.min(desiredHazardGap, usableSpan - totalBackSpan)
  local minimumHazardGap = math.max(leadBrakeDistance, primaryReactionGap) + 70
  if hazardGap < minimumHazardGap then
    log('W', logTag, string.format(
      'Straight spot is too short for Timeline v2: length=%.2f usableSpan=%.2f rearSpan=%.2f hazardGap=%.2f minimum=%.2f',
      spot.length, usableSpan, totalBackSpan, hazardGap, minimumHazardGap
    ))
    return nil
  end

  local totalScenarioSpan = totalBackSpan + hazardGap
  local leadOffset = -totalScenarioSpan * 0.5 + totalBackSpan
  local expectedTriggerTime = (hazardGap - primaryReactionGap) / closingSpeed
  local specs = {}
  local currentOffset = leadOffset

  for index, baseSpec in ipairs(convoy) do
    if index > 1 then
      currentOffset = currentOffset - (tonumber(baseSpec.gapBehind) or 0)
    end
    table.insert(specs, {
      label = baseSpec.label,
      role = baseSpec.role,
      model = baseSpec.model,
      offset = currentOffset,
      lateralOffset = baseSpec.lateralOffset,
      speedMps = baseSpec.speedMps,
    })
  end

  table.insert(specs, {
    label = activeScenarioDefinition.hazard.label,
    role = activeScenarioDefinition.hazard.role,
    model = activeScenarioDefinition.hazard.model,
    offset = leadOffset + hazardGap,
    lateralOffset = activeScenarioDefinition.hazard.lateralOffset,
    speedMps = hazardSpeed,
  })

  return specs, {
    totalBackSpan = totalBackSpan,
    hazardGap = hazardGap,
    totalScenarioSpan = totalScenarioSpan,
    leadOffset = leadOffset,
    hazardSpeedMps = hazardSpeed,
    expectedLeadTriggerTime = expectedTriggerTime,
  }
end

function M.debugRoadRules(spotIndex, directionOverride)
  local index = math.floor(tonumber(spotIndex) or 0)
  if index <= 0 and generatedScene and generatedScene.spotIndex then
    index = generatedScene.spotIndex
  end
  if index <= 0 then
    local top = M.getTopSpotByType('straight')
    index = top and top.index or 0
  end

  local spot = spots[index]
  if not spot then
    log('W', logTag, string.format('debugRoadRules: no harvested spot at index %d', index))
    return nil
  end

  local plan = buildRoadRulePlan(spot, directionOverride, true)
  if not plan then
    log('E', logTag, string.format('debugRoadRules: could not build a road plan for spot #%d', index))
    return nil
  end

  local link = plan.link or {}
  log('I', logTag, string.format(
    'RoadRules #%d valid=%s type=%s nodes=%s<->%s length=%.2f radius=%.2f roadWidth=%.2f drivability=%.2f',
    index, tostring(plan.valid), tostring(plan.roadType), tostring(plan.nodeA), tostring(plan.nodeB),
    tonumber(spot.length) or 0, plan.radius, plan.roadWidth, plan.drivability
  ))
  log('I', logTag, string.format(
    'Traffic rules: rightHandDrive=%s trafficSide=%s oneWay=%s inNode=%s lanes=%s speedLimit=%s',
    tostring(plan.roadRules.rightHandDrive), plan.trafficSide, tostring(plan.oneWay),
    tostring(link.inNode or 'n/a'), tostring(link.lanes or 'n/a'), tostring(link.speedLimit or 'n/a')
  ))
  log('I', logTag, string.format(
    'Lane plan: directionSource=%s requestedOverride=%s overrideRejected=%s roadDir=%d laneChoice=%d/%d laneWidth=%.2f laneOffsetFromCenter=%.2f driveInLane=%s',
    plan.directionSource, tostring(plan.requestedDirectionOverride or 'none'), tostring(plan.overrideRejected), plan.roadDir, plan.laneChoice, plan.laneCount,
    plan.laneCellWidth, plan.laneOffset, tostring(activeScenarioDefinition.driveInLane)
  ))
  log('I', logTag, string.format(
    'Vectors: baseDir=(%.3f, %.3f, %.3f) travelDir=(%.3f, %.3f, %.3f) travelRight=(%.3f, %.3f, %.3f)',
    plan.baseDir.x, plan.baseDir.y, plan.baseDir.z,
    plan.travelDir.x, plan.travelDir.y, plan.travelDir.z,
    plan.travelRight.x, plan.travelRight.y, plan.travelRight.z
  ))
  log('I', logTag, string.format(
    'Lane center=(%.2f, %.2f, %.2f) targetPath={%s}',
    plan.laneCenter.x, plan.laneCenter.y, plan.laneCenter.z,
    plan.targetPath and table.concat(plan.targetPath, ', ') or ''
  ))
  return plan
end

local function spawnVehicle(model, position, rotation, label)
  if not core_vehicles or not core_vehicles.spawnNewVehicle then
    log('E', logTag, 'Cannot spawn ' .. label .. ': core_vehicles.spawnNewVehicle is unavailable')
    return nil
  end

  local ok, vehicle = pcall(function()
    return core_vehicles.spawnNewVehicle(model, {
      pos = position,
      rot = rotation,
      autoEnterVehicle = false,
    })
  end)
  if not ok or not vehicle then
    log('E', logTag, string.format('Failed to spawn %s (%s): %s', label, model, tostring(vehicle)))
    return nil
  end

  log('I', logTag, string.format('Spawned %s model=%s id=%s', label, model, vehicleLabel(vehicle, '?')))
  return vehicle
end

local function buildAmbientModelCandidates(primaryModel, ambientConfig)
  local candidates = {}
  local seen = {}
  local function add(model)
    if type(model) == 'string' and model ~= '' and not seen[model] then
      seen[model] = true
      table.insert(candidates, model)
    end
  end
  add(primaryModel)
  for _, model in ipairs((ambientConfig and ambientConfig.models) or {}) do add(model) end
  for _, model in ipairs((ambientConfig and ambientConfig.fallbackModels) or {}) do add(model) end
  -- Scripted actor models are already known to work in the active scenario.
  for _, actor in ipairs((activeScenarioDefinition and activeScenarioDefinition.convoy) or {}) do add(actor.model) end
  if activeScenarioDefinition and activeScenarioDefinition.hazard then add(activeScenarioDefinition.hazard.model) end
  return candidates
end

local function spawnAmbientVehicleWithFallback(spec, position, rotation, ambientConfig)
  local candidates = buildAmbientModelCandidates(spec.model, ambientConfig)
  for candidateIndex, model in ipairs(candidates) do
    local vehicle = spawnVehicle(model, position, rotation, spec.label)
    if vehicle then
      local fallbackUsed = model ~= spec.model
      if fallbackUsed then
        log('W', logTag, string.format(
          'Ambient model fallback for %s: requested=%s selected=%s attempt=%d/%d',
          tostring(spec.label), tostring(spec.model), tostring(model), candidateIndex, #candidates
        ))
      end
      return vehicle, model, fallbackUsed
    end
  end
  return nil, nil, false
end

function M.clearGeneratedVehicles()
  finalizeRuntimeTelemetry('CLEARED', true)
  log('I', logTag, string.format('Clearing %d generated vehicles', #generatedVehicles))
  for index, entry in ipairs(generatedVehicles) do
    local vehicle = entry.vehicle or entry
    local id = nil
    if vehicle and vehicle.getID then
      pcall(function() id = vehicle:getID() end)
    end
    local removed = false
    if id and be and be.deleteObject then
      local ok = pcall(function() be:deleteObject(id) end)
      removed = ok
    elseif vehicle and vehicle.delete then
      local ok = pcall(function() vehicle:delete() end)
      removed = ok
    end
    log('I', logTag, string.format('Clear vehicle #%d id=%s result=%s', index, tostring(id or '?'), tostring(removed)))
  end
  generatedVehicles = {}
  generatedScene = nil
  return true
end

local function selectStraightSpot(seed, minimumLength)
  local straightSpots = {}
  for _, spot in ipairs(spots) do
    if spot.type == 'straight' and (not minimumLength or (spot.length or 0) >= minimumLength) then
      table.insert(straightSpots, spot)
    end
  end

  if #straightSpots == 0 and minimumLength then
    log('W', logTag, string.format(
      'No straight spots meet minimum length %.2f; falling back to any straight spot',
      minimumLength
    ))
    for _, spot in ipairs(spots) do
      if spot.type == 'straight' then table.insert(straightSpots, spot) end
    end
  end

  if #straightSpots == 0 then return nil end

  if seed == nil then
    log('I', logTag, string.format(
      'No seed supplied; selected top straight spot%s',
      minimumLength and string.format(' with requested minimum length %.2f', minimumLength) or ''
    ))
    return straightSpots[1]
  end

  -- Keep seeded choices biased toward the best ten spots while remaining repeatable.
  local numericSeed = math.floor(tonumber(seed) or 0)
  local candidateCount = math.min(#straightSpots, 10)
  local value = (math.abs(numericSeed) * 1103515245 + 12345) % 2147483648
  local index = (value % candidateCount) + 1
  log('I', logTag, string.format(
    'Seed=%s selected high-score straight rank=%d/%d minimumLength=%s',
    tostring(seed), index, candidateCount, tostring(minimumLength or 'none')
  ))
  return straightSpots[index]
end

function M.generateRearEnd(seed)
  log('I', logTag, 'Generating rear-end scene')
  M.clearGeneratedVehicles()

  local spot = selectStraightSpot(seed)
  if not spot then
    log('W', logTag, 'Cannot generate rear-end scene: no harvested straight spots')
    return nil
  end

  local mapData = map.getMap()
  local mapNodes = mapData and mapData.nodes
  local nodeA = mapNodes and mapNodes[spot.nodeA]
  local nodeB = mapNodes and mapNodes[spot.nodeB]
  if not nodeA or not nodeB then
    log('E', logTag, string.format('Cannot generate rear-end scene: nodes %s,%s are unavailable', tostring(spot.nodeA), tostring(spot.nodeB)))
    return nil
  end

  local dir = (nodeB.pos - nodeA.pos):normalized()
  local nextNodeAfterB = findForwardNextNode(spot.nodeB, spot.nodeA)
  local targetPath = {spot.nodeB}
  if nextNodeAfterB then table.insert(targetPath, nextNodeAfterB) end
  local base = vec3(spot.pos.x, spot.pos.y, spot.pos.z)
  local posA = base + dir * leadOffset
  local posB = posA - dir * distanceBehind
  local rotation = quatFromDir(dir, vec3(0, 0, 1))
  log('I', logTag, string.format('Selected straight #%d score=%.2f nodes=%s->%s dir=(%.3f, %.3f, %.3f)', spot.index, spot.score, tostring(spot.nodeA), tostring(spot.nodeB), dir.x, dir.y, dir.z))
  log('I', logTag, string.format('Rear-end targetPath={%s}', table.concat(targetPath, ', ')))
  log('I', logTag, string.format('Computed positions: Car A ahead=(%.2f, %.2f, %.2f), Car B behind=(%.2f, %.2f, %.2f)', posA.x, posA.y, posA.z, posB.x, posB.y, posB.z))
  log('I', logTag, string.format('Node distances: Car A to nodeA=%.2f nodeB=%.2f; Car B to nodeA=%.2f nodeB=%.2f', posA:distance(nodeA.pos), posA:distance(nodeB.pos), posB:distance(nodeA.pos), posB:distance(nodeB.pos)))

  local carA = spawnVehicle(generatedVehicleModels[1], posA, rotation, 'Car A')
  local carB = spawnVehicle(generatedVehicleModels[2], posB, rotation, 'Car B')
  if not carA or not carB then
    log('W', logTag, 'Rear-end scene was only partially spawned; clearing partial result')
    if carA then table.insert(generatedVehicles, carA) end
    if carB then table.insert(generatedVehicles, carB) end
    M.clearGeneratedVehicles()
    return nil
  end

  generatedVehicles = {
    {vehicle = carA, initialPosition = copyPosition(posA), initialRotation = rotation, model = generatedVehicleModels[1], label = 'Car A', role = 'lead', speedMps = leadSpeedMps},
    {vehicle = carB, initialPosition = copyPosition(posB), initialRotation = rotation, model = generatedVehicleModels[2], label = 'Car B', role = 'chaser', speedMps = chaseSpeedMps},
  }
  generatedScene = {
    seed = seed,
    spotIndex = spot.index,
    nodeA = spot.nodeA,
    nodeB = spot.nodeB,
    posA = copyPosition(posA),
    posB = copyPosition(posB),
    rotation = rotation,
    vehicleModels = {generatedVehicleModels[1], generatedVehicleModels[2]},
    vehicles = {
      {label = 'Car A', role = 'lead', model = generatedVehicleModels[1], position = copyPosition(posA), initialRotation = rotation, speedMps = leadSpeedMps},
      {label = 'Car B', role = 'chaser', model = generatedVehicleModels[2], position = copyPosition(posB), initialRotation = rotation, speedMps = chaseSpeedMps},
    },
    preset = 'reliable_rear_end_v0_1',
    phase = 'stable',
    dir = copyVector(dir),
    distanceBehind = distanceBehind,
    leadSpeedMps = leadSpeedMps,
    chaseSpeedMps = chaseSpeedMps,
    targetDistance = targetDistance,
    targetPath = targetPath,
    carAToNodeA = posA:distance(nodeA.pos),
    carAToNodeB = posA:distance(nodeB.pos),
    carBToNodeA = posB:distance(nodeA.pos),
    carBToNodeB = posB:distance(nodeB.pos),
    queuedAICommands = {},
  }
  queueVehicleAI(carA, leadSpeedMps, 'Car A', targetPath)
  queueVehicleAI(carB, chaseSpeedMps, 'Car B', targetPath)
  log('I', logTag, 'Rear-end scene generated successfully; call start() to begin AI movement')
  return {spot = spot, carA = carA, carB = carB}
end

local function generateScenarioFromActiveDefinition(seed, travelDirectionOverride)
  diagnostics.setStatus('GENERATING')
  log('I', logTag, string.format(
    'Generating road scenario preset=%s phase=%s seed=%s directionOverride=%s',
    activeScenarioDefinition.name, activeScenarioDefinition.phase, tostring(seed), tostring(travelDirectionOverride)
  ))
  M.clearGeneratedVehicles()

  local spot, selectedMinimumLength = selectScenarioStraightSpot(seed)
  if not spot then
    log('W', logTag, 'Cannot generate Scenario Timeline v2: no sufficiently long lane-aware straight spot')
    return nil
  end

  local roadPlan = buildRoadRulePlan(spot, travelDirectionOverride, true)
  if not roadPlan or not roadPlan.valid then
    log('E', logTag, string.format(
      'Cannot generate Scenario Timeline v2: road-rule plan is invalid for spot=%s',
      tostring(spot.index)
    ))
    return nil
  end

  local scenarioSpecs, geometry = buildScenarioVehicleSpecs(spot)
  if not scenarioSpecs then
    log('E', logTag, 'Cannot generate Scenario Timeline v2: selected road is too short for six-vehicle geometry')
    return nil
  end

  local ambientConfig = scenarioRegistry.copy(activeScenarioDefinition.ambientTraffic or {})
  if ambientTrafficCountOverride ~= nil then ambientConfig.count = ambientTrafficCountOverride end

  local totalAmbientCount = math.max(0, math.floor(tonumber(ambientConfig.count) or 0))
  local oppositePlan, oppositePlanReason = findOppositeCarriagewayPlan(roadPlan, ambientConfig)
  local configuredOppositeCount = math.max(0, math.floor(tonumber(ambientConfig.oppositeFlow and ambientConfig.oppositeFlow.count) or math.floor(totalAmbientCount * 0.5)))
  local desiredOppositeCount = math.min(totalAmbientCount, configuredOppositeCount)
  local oppositeCount = oppositePlan and desiredOppositeCount or 0
  local sameDirectionCount = totalAmbientCount - oppositeCount

  local sameConfig = scenarioRegistry.copy(ambientConfig)
  sameConfig.count = sameDirectionCount
  local sameSpecs, sameSummary, sameError = ambientTrafficManager.build(sameConfig, roadPlan, seed)
  if not sameSpecs then
    log('E', logTag, string.format('Cannot generate same-direction ambient traffic: %s', tostring(sameError)))
    return nil
  end

  local ambientSpecs = {}
  for index, ambientSpec in ipairs(sameSpecs) do
    ambientSpec.label = string.format('Ambient S%02d', index)
    ambientSpec.flowDirection = 'same'
    ambientSpec.roadPlan = roadPlan
    ambientSpec.targetPath = roadPlan.targetPath
    table.insert(ambientSpecs, ambientSpec)
  end

  local oppositeSpecs = {}
  local oppositeSummary = {requestedCount = oppositeCount, generatedCount = 0, skippedCount = oppositeCount, reason = oppositePlanReason}
  if oppositePlan and oppositeCount > 0 then
    local oppositeConfig = scenarioRegistry.copy(ambientConfig)
    oppositeConfig.count = oppositeCount
    oppositeConfig.excludeScenarioLane = false
    oppositeConfig.fallbackToScenarioLane = true
    oppositeSpecs, oppositeSummary, sameError = ambientTrafficManager.build(oppositeConfig, oppositePlan, (tonumber(seed) or 0) + 91009)
    if not oppositeSpecs then
      log('W', logTag, string.format('Opposite-flow ambient generation failed: %s; keeping same-direction scene', tostring(sameError)))
      oppositeSpecs = {}
      oppositeSummary = {requestedCount = oppositeCount, generatedCount = 0, skippedCount = oppositeCount, reason = tostring(sameError)}
    end
    for index, ambientSpec in ipairs(oppositeSpecs) do
      ambientSpec.label = string.format('Ambient O%02d', index)
      ambientSpec.flowDirection = 'opposite'
      ambientSpec.roadPlan = oppositePlan
      ambientSpec.targetPath = oppositePlan.targetPath
      table.insert(ambientSpecs, ambientSpec)
    end
  end

  for _, ambientSpec in ipairs(ambientSpecs) do table.insert(scenarioSpecs, ambientSpec) end
  local ambientSummary = {
    enabled = ambientConfig.enabled ~= false,
    requestedCount = totalAmbientCount,
    generatedCount = #ambientSpecs,
    skippedCount = totalAmbientCount - #ambientSpecs,
    spawnedCount = 0,
    spawnSkippedCount = 0,
    modelFallbackCount = 0,
    scenarioLane = roadPlan.laneChoice,
    eligibleLanes = sameSummary.eligibleLanes or {},
    reason = sameSummary.reason,
    sameDirectionRequested = sameDirectionCount,
    sameDirectionGenerated = #sameSpecs,
    oppositeDirectionRequested = desiredOppositeCount,
    oppositeDirectionGenerated = #oppositeSpecs,
    oppositeReason = oppositeSummary.reason or oppositePlanReason,
    oppositeSpotIndex = oppositePlan and oppositePlan.spot and oppositePlan.spot.index or nil,
    oppositeMode = oppositePlan and oppositePlan.oppositeDiscovery and oppositePlan.oppositeDiscovery.mode or nil,
    oppositeSeedNodeA = oppositePlan and oppositePlan.oppositeDiscovery and oppositePlan.oppositeDiscovery.seedNodeA or nil,
    oppositeSeedNodeB = oppositePlan and oppositePlan.oppositeDiscovery and oppositePlan.oppositeDiscovery.seedNodeB or nil,
    oppositeDiagnostics = lastOppositeCarriagewayDiagnostics,
    sameDirectionSpawned = 0,
    oppositeDirectionSpawned = 0,
  }
  if ambientSummary.reason then
    log('W', logTag, string.format(
      'Same-direction ambient result reason=%s requested=%d generated=%d',
      tostring(ambientSummary.reason), sameDirectionCount, #sameSpecs
    ))
  end
  if oppositePlanReason or oppositeSummary.reason then
    log('W', logTag, string.format(
      'Opposite-flow ambient result reason=%s requested=%d generated=%d',
      tostring(oppositeSummary.reason or oppositePlanReason), desiredOppositeCount, #oppositeSpecs
    ))
  end

  local travelDir = roadPlan.travelDir
  local travelRight = roadPlan.travelRight
  local laneCenter = roadPlan.laneCenter
  local rotation = quatFromDir(travelDir, vec3(0, 0, 1))
  local targetPath = roadPlan.targetPath or {}
  local spawnedEntries = {}
  local storedVehicleSpecs = {}

  for _, spec in ipairs(scenarioSpecs) do
    local specPlan = spec.roadPlan or roadPlan
    local specSpot = specPlan.spot or spot
    local specTravelDir = specPlan.travelDir or travelDir
    local specTravelRight = specPlan.travelRight or travelRight
    local specRotation = quatFromDir(specTravelDir, vec3(0, 0, 1))
    local specTargetPath = spec.targetPath or specPlan.targetPath or targetPath
    local vehicleJitter = spec.lateralOffset or 0
    local specLaneOffset = tonumber(spec.laneOffset) or specPlan.laneOffset
    local specLaneCenter = vec3(specSpot.pos.x, specSpot.pos.y, specSpot.pos.z) + specPlan.roadRight * specLaneOffset
    local position = specLaneCenter + specTravelDir * spec.offset + specTravelRight * vehicleJitter
    position = snapPositionToSurface(position)
    local vehicle = nil
    local spawnedModel = spec.model
    local ambientFallbackUsed = false
    if spec.isAmbient then
      vehicle, spawnedModel, ambientFallbackUsed = spawnAmbientVehicleWithFallback(spec, position, specRotation, ambientConfig)
    else
      vehicle = spawnVehicle(spec.model, position, specRotation, spec.label)
    end

    if not vehicle then
      if spec.isAmbient then
        ambientSummary.spawnSkippedCount = (tonumber(ambientSummary.spawnSkippedCount) or 0) + 1
        ambientSummary.skippedCount = (tonumber(ambientSummary.skippedCount) or 0) + 1
        log('W', logTag, string.format(
          'Skipping optional ambient vehicle %s after all model candidates failed; scripted scene remains active',
          tostring(spec.label)
        ))
      else
        log('E', logTag, string.format(
          'Scenario Timeline v2 critical actor spawn failed at %s; clearing %d partial vehicles',
          spec.label, #spawnedEntries
        ))
        generatedVehicles = spawnedEntries
        M.clearGeneratedVehicles()
        return nil
      end
    end

    if not vehicle then
      -- Optional ambient traffic must never invalidate the scripted scenario.
    else

    local controllerData = nil
    if not spec.isAmbient then
      controllerData = {
        state = spec.role == 'stopped_hazard' and VEHICLE_STATE.STOPPED or VEHICLE_STATE.CRUISE,
        brakeAmount = 0,
      }
    end

    local entry = {
      vehicle = vehicle,
      initialPosition = copyPosition(position),
      initialRotation = specRotation,
      model = spawnedModel,
      requestedModel = spec.model,
      ambientFallbackUsed = ambientFallbackUsed,
      label = spec.label,
      role = spec.role,
      speedMps = spec.speedMps,
      lateralOffset = vehicleJitter,
      laneOffset = specLaneOffset,
      laneChoice = spec.laneChoice or specPlan.laneChoice,
      isAmbient = spec.isAmbient == true,
      flowDirection = spec.flowDirection or 'scenario',
      targetPath = specTargetPath,
      ai = spec.ai,
      controller = controllerData,
    }
    table.insert(spawnedEntries, entry)
    table.insert(storedVehicleSpecs, {
      label = spec.label,
      role = spec.role,
      model = spawnedModel,
      requestedModel = spec.model,
      ambientFallbackUsed = ambientFallbackUsed,
      position = copyPosition(position),
      initialRotation = specRotation,
      speedMps = spec.speedMps,
      lateralOffset = vehicleJitter,
      laneOffset = specLaneOffset,
      laneChoice = spec.laneChoice or specPlan.laneChoice,
      longitudinalOffset = spec.offset,
      isAmbient = spec.isAmbient == true,
      flowDirection = spec.flowDirection or 'scenario',
      targetPath = specTargetPath,
      ai = spec.ai,
      controllerState = spec.role == 'stopped_hazard' and VEHICLE_STATE.STOPPED or VEHICLE_STATE.CRUISE,
    })

    log('I', logTag, string.format(
      '%s role=%s ambient=%s longitudinalOffset=%.2f lane=%d/%d laneCenterOffset=%.2f jitter=%.2f position=(%.2f, %.2f, %.2f) speedMps=%.2f',
      spec.label, spec.role, tostring(spec.isAmbient == true), spec.offset, spec.laneChoice or specPlan.laneChoice, specPlan.laneCount, specLaneOffset, vehicleJitter,
      position.x, position.y, position.z, spec.speedMps
    ))
      if spec.isAmbient then
        ambientSummary.spawnedCount = (tonumber(ambientSummary.spawnedCount) or 0) + 1
        if spec.flowDirection == 'opposite' then
          ambientSummary.oppositeDirectionSpawned = (tonumber(ambientSummary.oppositeDirectionSpawned) or 0) + 1
        else
          ambientSummary.sameDirectionSpawned = (tonumber(ambientSummary.sameDirectionSpawned) or 0) + 1
        end
        if ambientFallbackUsed then
          ambientSummary.modelFallbackCount = (tonumber(ambientSummary.modelFallbackCount) or 0) + 1
        end
      end
    end
  end

  ambientSummary.spawnedCount = tonumber(ambientSummary.spawnedCount) or 0
  ambientSummary.spawnSkippedCount = tonumber(ambientSummary.spawnSkippedCount) or 0
  ambientSummary.modelFallbackCount = tonumber(ambientSummary.modelFallbackCount) or 0

  local triggerRuntime, triggerError = triggerEngine.create(activeScenarioDefinition.triggers or {})
  if not triggerRuntime then
    log('E', logTag, string.format('Cannot generate scenario trigger runtime: %s', tostring(triggerError)))
    generatedVehicles = spawnedEntries
    M.clearGeneratedVehicles()
    return nil
  end

  local leadBrakeDistance = getScenarioDistanceFallback(
    activeScenarioDefinition, LEAD_TRIGGER_GROUP, activeScenarioDefinition.leadBrakeDistance
  )
  local targetBrakeDistance = getScenarioDistanceFallback(
    activeScenarioDefinition, TARGET_TRIGGER_GROUP, activeScenarioDefinition.targetBrakeDistance
  )
  local targetBrakeAmount = getScenarioTriggerActionAmount(
    activeScenarioDefinition, TARGET_TRIGGER_ID, activeScenarioDefinition.targetBrakeAmount
  )

  generatedVehicles = spawnedEntries
  generatedScene = {
    scenarioId = activeScenarioDefinition.id,
    mapName = getCurrentMapName(),
    scenarioVersion = activeScenarioDefinition.version,
    scenarioDefinition = scenarioRegistry.copy(activeScenarioDefinition),
    preset = activeScenarioDefinition.name,
    phase = activeScenarioDefinition.phase,
    seed = seed,
    spotIndex = spot.index,
    selectedMinimumLength = selectedMinimumLength,
    nodeA = spot.nodeA,
    nodeB = spot.nodeB,
    spotLength = spot.length,
    rotation = rotation,
    dir = copyVector(travelDir),
    baseDir = copyVector(roadPlan.baseDir),
    right = copyVector(travelRight),
    targetPath = targetPath,
    vehicles = storedVehicleSpecs,
    scenarioGeometry = geometry,
    ambientTraffic = ambientSummary,
    triggerRuntime = triggerRuntime,
    roadRules = {
      rightHandDrive = roadPlan.roadRules.rightHandDrive == true,
      trafficSide = roadPlan.trafficSide,
      oneWay = roadPlan.oneWay,
      inNode = roadPlan.link and roadPlan.link.inNode or nil,
      roadType = roadPlan.roadType,
      drivability = roadPlan.drivability,
      directionSource = roadPlan.directionSource,
      requestedDirectionOverride = roadPlan.requestedDirectionOverride,
      overrideRejected = roadPlan.overrideRejected,
      roadDir = roadPlan.roadDir,
      lanePreference = activeScenarioDefinition.lanePreference,
      laneChoice = roadPlan.laneChoice,
      laneCount = roadPlan.laneCount,
      laneWidth = roadPlan.laneCellWidth,
      roadWidth = roadPlan.roadWidth,
      laneOffset = roadPlan.laneOffset,
      laneCenter = copyPosition(roadPlan.laneCenter),
      driveInLane = activeScenarioDefinition.driveInLane,
    },
    timeline = {
      mode = 'trigger_engine',
      scenarioDuration = activeScenarioDefinition.scenarioDuration,
      maximumScenarioTime = activeScenarioDefinition.maximumScenarioTime,
      desiredNormalDriveTime = activeScenarioDefinition.desiredNormalDriveTime,
      leadBrakeDistance = leadBrakeDistance,
      targetBrakeDistance = targetBrakeDistance,
      targetBrakeAmount = targetBrakeAmount,
      expectedLeadTriggerTime = geometry.expectedLeadTriggerTime,
      initialLeadHazardGap = geometry.hazardGap,
      hazardSpeedMps = geometry.hazardSpeedMps,
      elapsed = 0,
      started = false,
      phase = 'ready',
      leadBrakeTriggered = false,
      targetBrakeTriggered = false,
      completed = false,
      timeoutWarningLogged = false,
      transientActions = {},
    },
    queuedAICommands = {},
  }
  for _, entry in ipairs(generatedVehicles) do diagnostics.registerActor(entry) end
  startRuntimeTelemetryForGeneratedScene()

  log('I', logTag, string.format(
    'Scenario definition %s v%s generated: actors=%d ambient=%d vehicles=%d spot=%s length=%.2f trafficSide=%s oneWay=%s roadDir=%d lane=%d/%d initialHazardGap=%.2f hazardSpeed=%.2f expectedLeadTrigger=%.2fs targetPathNodes=%d; call start()',
    tostring(activeScenarioDefinition.id), tostring(activeScenarioDefinition.version),
    #generatedVehicles - (ambientSummary.spawnedCount or 0), ambientSummary.spawnedCount or 0, #generatedVehicles, tostring(spot.index), tonumber(spot.length) or 0,
    roadPlan.trafficSide, tostring(roadPlan.oneWay), roadPlan.roadDir,
    roadPlan.laneChoice, roadPlan.laneCount, geometry.hazardGap,
    geometry.hazardSpeedMps, geometry.expectedLeadTriggerTime, #targetPath
  ))
  return {spot = spot, vehicles = generatedVehicles, roadRules = generatedScene.roadRules, timeline = generatedScene.timeline}
end

function M.listScenarioDefinitions()
  local definitions = scenarioRegistry.list()
  for _, definition in ipairs(definitions) do
    log('I', logTag, string.format(
      'Scenario definition id=%s version=%s name=%s actors=%d ambient=%d totalVehicles=%d triggers=%d duration=%.2f',
      tostring(definition.id), tostring(definition.version), tostring(definition.name),
      tonumber(definition.actorCount) or 0, tonumber(definition.ambientCount) or 0, tonumber(definition.totalVehicleCount) or 0,
      tonumber(definition.triggerCount) or 0, tonumber(definition.scenarioDuration) or 0
    ))
  end
  return definitions
end

function M.printScenarioDefinition(scenarioId)
  local definition, errorMessage = scenarioRegistry.get(scenarioId or DEFAULT_SCENARIO_ID)
  if not definition then
    log('E', logTag, string.format('Unknown scenario definition %s: %s', tostring(scenarioId), tostring(errorMessage)))
    return nil
  end

  log('I', logTag, string.format(
    'Scenario %s v%s preset=%s phase=%s duration=%.2f maxTime=%.2f normalDrive=%.2f actors=%d',
    tostring(definition.id), tostring(definition.version), tostring(definition.name),
    tostring(definition.phase), tonumber(definition.scenarioDuration) or 0,
    tonumber(definition.maximumScenarioTime) or 0, tonumber(definition.desiredNormalDriveTime) or 0,
    #(definition.convoy or {}) + (definition.hazard and 1 or 0)
  ))
  for index, actor in ipairs(definition.convoy or {}) do
    log('I', logTag, string.format(
      'Actor #%d label=%s role=%s model=%s speedMps=%.2f gapBehind=%.2f lateralOffset=%.2f',
      index, tostring(actor.label), tostring(actor.role), tostring(actor.model),
      tonumber(actor.speedMps) or 0, tonumber(actor.gapBehind) or 0, tonumber(actor.lateralOffset) or 0
    ))
  end
  local ambient = definition.ambientTraffic or {}
  log('I', logTag, string.format(
    'Ambient definition enabled=%s count=%d excludeScenarioLane=%s speedRange=%.2f..%.2f models={%s}',
    tostring(ambient.enabled ~= false), tonumber(ambient.count) or 0, tostring(ambient.excludeScenarioLane ~= false),
    tonumber(ambient.speedRange and ambient.speedRange[1]) or 0, tonumber(ambient.speedRange and ambient.speedRange[2]) or 0,
    table.concat(ambient.models or {}, ', ')
  ))
  if definition.hazard then
    local hazard = definition.hazard
    log('I', logTag, string.format(
      'Hazard label=%s role=%s model=%s speedMps=%.2f lateralOffset=%.2f',
      tostring(hazard.label), tostring(hazard.role), tostring(hazard.model),
      tonumber(hazard.speedMps) or 0, tonumber(hazard.lateralOffset) or 0
    ))
  end
  for index, trigger in ipairs(definition.triggers or {}) do
    local action = trigger.action or {}
    log('I', logTag, string.format(
      'Trigger #%d id=%s group=%s subject=%s target=%s metric=%s operator=%s threshold=%.3f delay=%.3f once=%s action=%s amount=%s requires=%s requiresGroup=%s',
      index, tostring(trigger.id), tostring(trigger.group or 'none'), tostring(trigger.subject), tostring(trigger.target),
      tostring(trigger.metric or trigger.type), tostring(trigger.operator or '<='),
      tonumber(trigger.threshold) or 0, tonumber(trigger.delaySeconds) or 0, tostring(trigger.once ~= false), tostring(action.type),
      tostring(action.amount or 'n/a'), type(trigger.requires) == 'table' and table.concat(trigger.requires, ',') or tostring(trigger.requires or ''),
      type(trigger.requiresGroups) == 'table' and table.concat(trigger.requiresGroups, ',') or tostring(trigger.requiresGroup or trigger.requiresGroups or '')
    ))
  end
  return definition
end

function M.generateScenario(scenarioId, seed, travelDirectionOverride)
  finalizeRuntimeTelemetry('NEW_GENERATE', true)
  diagnostics.beginSession({scenarioId = scenarioId or DEFAULT_SCENARIO_ID, seed = seed, mapName = getCurrentMapName(), scenarioVersion = activeScenarioDefinition and activeScenarioDefinition.version, phase = activeScenarioDefinition and activeScenarioDefinition.phase})
  local definition, errorMessage = scenarioRegistry.get(scenarioId or DEFAULT_SCENARIO_ID)
  if not definition then
    log('E', logTag, string.format('Cannot generate unknown scenario %s: %s', tostring(scenarioId), tostring(errorMessage)))
    diagnostics.setStatus('FAILED')
    return nil
  end

  activeScenarioDefinition = definition
  diagnostics.updateMetadata({scenarioId = definition.id, scenarioVersion = definition.version, phase = definition.phase})
  local result = generateScenarioFromActiveDefinition(seed, travelDirectionOverride)
  if result then diagnostics.setStatus('GENERATED') else diagnostics.setStatus('FAILED') end
  return result
end

function M.generateShortsPileup(seed, travelDirectionOverride)
  return M.generateScenario(DEFAULT_SCENARIO_ID, seed, travelDirectionOverride)
end

local function getVehicleWorldPosition(entry)
  if not entry or not entry.vehicle or not entry.vehicle.getPosition then return nil end
  local ok, position = pcall(function() return entry.vehicle:getPosition() end)
  if not ok or not position then return nil end
  return vec3(position)
end

local function measureScenarioTrigger(trigger, direction)
  local subjectEntry = findGeneratedVehicleEntry(trigger.subject)
  local targetEntry = findGeneratedVehicleEntry(trigger.target)
  if not subjectEntry then return nil, 'subject actor unavailable: '..tostring(trigger.subject) end
  if not targetEntry then return nil, 'target actor unavailable: '..tostring(trigger.target) end

  local subjectPosition = getVehicleWorldPosition(subjectEntry)
  local targetPosition = getVehicleWorldPosition(targetEntry)
  if not subjectPosition or not targetPosition then return nil, 'actor positions unavailable' end

  local displacement = targetPosition - subjectPosition
  local euclideanDistance = displacement:length()
  local longitudinalDistance = direction and displacement:dot(direction) or euclideanDistance
  local distance = trigger.distanceMode == 'euclidean' and euclideanDistance or longitudinalDistance

  local subjectVelocity = getVehicleVelocity(subjectEntry)
  local targetVelocity = getVehicleVelocity(targetEntry)
  local subjectSpeed = subjectVelocity and direction and subjectVelocity:dot(direction) or 0
  local targetSpeed = targetVelocity and direction and targetVelocity:dot(direction) or 0
  local relativeSpeed = subjectSpeed - targetSpeed
  local ttc = math.huge
  if distance and distance > 0 and relativeSpeed > 0.001 then
    ttc = distance / relativeSpeed
  end

  return {
    distance = distance,
    longitudinalDistance = longitudinalDistance,
    euclideanDistance = euclideanDistance,
    subjectSpeed = subjectSpeed,
    targetSpeed = targetSpeed,
    relativeSpeed = relativeSpeed,
    ttc = ttc,
  }
end

local function cancelTransientBrakeRelease(label, reason)
  if not generatedScene or not generatedScene.timeline or not generatedScene.timeline.transientActions then return false end
  local key = tostring(label)..':brake'
  if generatedScene.timeline.transientActions[key] then
    generatedScene.timeline.transientActions[key] = nil
    log('I', logTag, string.format(
      'Cancelled pending brake release for %s reason=%s', tostring(label), tostring(reason or 'superseded')
    ))
    return true
  end
  return false
end

local function executeScenarioTriggerAction(action, trigger, metrics)
  action = action or {}
  local actorLabel = action.actor or trigger.subject
  local entry = findGeneratedVehicleEntry(actorLabel)
  if not entry then return false, 'action actor unavailable: '..tostring(actorLabel) end

  if action.type == 'set_speed' then
    cancelTransientBrakeRelease(entry.label, 'set_speed')
    local requestedState = tostring(action.controllerState or 'DECELERATING')
    local controllerState = VEHICLE_STATE[requestedState] or VEHICLE_STATE.DECELERATING
    if controllerState == VEHICLE_STATE.STOPPED or controllerState == VEHICLE_STATE.BRAKING or controllerState == VEHICLE_STATE.EMERGENCY_BRAKING then
      controllerState = VEHICLE_STATE.DECELERATING
    end
    return setVehicleControllerState(entry, controllerState, {
      speedMps = tonumber(action.speedMps) or entry.speedMps,
    })
  elseif action.type == 'brake' then
    cancelTransientBrakeRelease(entry.label, 'stronger_brake')
    local controllerState = action.mode == 'emergency' and VEHICLE_STATE.EMERGENCY_BRAKING or VEHICLE_STATE.BRAKING
    return setVehicleControllerState(entry, controllerState, {
      brakeAmount = clamp(tonumber(action.amount) or 1, 0, 1),
      commandName = action.commandName or ('triggerBrake_'..tostring(trigger.id)),
      autoStop = action.autoStop ~= false,
    })
  elseif action.type == 'brake_pulse' then
    local duration = math.max(0.05, tonumber(action.duration) or 0.5)
    local controllerState = action.mode == 'emergency' and VEHICLE_STATE.EMERGENCY_BRAKING or VEHICLE_STATE.BRAKING
    local applied = setVehicleControllerState(entry, controllerState, {
      brakeAmount = clamp(tonumber(action.amount) or 1, 0, 1),
      commandName = action.commandName or ('triggerBrakePulse_'..tostring(trigger.id)),
      autoStop = false,
    })
    if applied and generatedScene and generatedScene.timeline then
      generatedScene.timeline.transientActions = generatedScene.timeline.transientActions or {}
      generatedScene.timeline.transientActions[entry.label..':brake'] = {
        label = entry.label,
        type = 'brake',
        releaseAt = (generatedScene.timeline.elapsed or 0) + duration,
        releaseState = action.releaseState or 'CRUISE',
        releaseSpeedMps = tonumber(action.releaseSpeedMps),
        followTarget = action.followTarget,
        speedOffsetMps = tonumber(action.speedOffsetMps) or 0,
      }
      log('I', logTag, string.format(
        'Brake pulse scheduled for %s duration=%.2fs releaseState=%s releaseSpeed=%s followTarget=%s',
        tostring(entry.label), duration, tostring(action.releaseState or 'CRUISE'),
        action.releaseSpeedMps and string.format('%.2f', tonumber(action.releaseSpeedMps)) or 'current',
        tostring(action.followTarget or 'none')
      ))
    end
    return applied
  elseif action.type == 'stop' then
    cancelTransientBrakeRelease(entry.label, 'stop')
    return setVehicleControllerState(entry, VEHICLE_STATE.STOPPED, {
      reason = action.reason or ('trigger_'..tostring(trigger.id)),
    })
  elseif action.type == 'resume' then
    cancelTransientBrakeRelease(entry.label, 'resume')
    return setVehicleControllerState(entry, VEHICLE_STATE.CRUISE, {
      speedMps = tonumber(action.speedMps) or entry.speedMps,
    })
  elseif action.type == 'swerve' then
    local applied = queueVehicleSteering(
      entry.vehicle, entry.label, tonumber(action.amount) or 0,
      action.commandName or ('triggerSwerve_'..tostring(trigger.id)),
      action.disableAI
    )
    if applied and tonumber(action.duration) and tonumber(action.duration) > 0 and generatedScene and generatedScene.timeline then
      generatedScene.timeline.transientActions = generatedScene.timeline.transientActions or {}
      generatedScene.timeline.transientActions[entry.label..':steering'] = {
        label = entry.label,
        type = 'steering',
        releaseAt = (generatedScene.timeline.elapsed or 0) + tonumber(action.duration),
      }
    end
    return applied
  end

  return false, 'unsupported action type '..tostring(action.type)
end

local function updateTransientActions()
  if not generatedScene or not generatedScene.timeline then return end
  local timeline = generatedScene.timeline
  local actions = timeline.transientActions or {}
  for key, pending in pairs(actions) do
    if timeline.elapsed >= (pending.releaseAt or math.huge) then
      local entry = findGeneratedVehicleEntry(pending.label)
      if entry and pending.type == 'steering' then
        queueVehicleSteering(entry.vehicle, entry.label, 0, 'triggerSwerveRelease', false)
      elseif entry and pending.type == 'brake' then
        local requestedState = tostring(pending.releaseState or 'CRUISE')
        local releaseState = VEHICLE_STATE[requestedState] or VEHICLE_STATE.CRUISE
        if releaseState == VEHICLE_STATE.STOPPED or releaseState == VEHICLE_STATE.BRAKING or releaseState == VEHICLE_STATE.EMERGENCY_BRAKING then
          releaseState = VEHICLE_STATE.CRUISE
        end
        local releaseSpeed = tonumber(pending.releaseSpeedMps) or tonumber(entry.speedMps) or 0
        if releaseState == VEHICLE_STATE.FOLLOWING and pending.followTarget then
          local targetEntry = findGeneratedVehicleEntry(pending.followTarget)
          local direction = generatedScene.dir and vec3(generatedScene.dir.x, generatedScene.dir.y, generatedScene.dir.z) or nil
          local targetSpeed = targetEntry and getVehicleLongitudinalSpeed(targetEntry, direction) or nil
          if targetSpeed and targetSpeed >= 0 then
            releaseSpeed = math.max(0, targetSpeed + (tonumber(pending.speedOffsetMps) or 0))
          end
        end
        setVehicleControllerState(entry, releaseState, {
          speedMps = releaseSpeed,
          followTarget = pending.followTarget,
          speedOffsetMps = pending.speedOffsetMps,
        })
        log('I', logTag, string.format(
          'Brake pulse released for %s state=%s speed=%.2f followTarget=%s',
          tostring(entry.label), tostring(releaseState), releaseSpeed, tostring(pending.followTarget or 'none')
        ))
      end
      actions[key] = nil
    end
  end
end

local function buildTriggerContext(direction)
  local timeline = generatedScene and generatedScene.timeline or {}
  return {
    elapsed = timeline.elapsed or 0,
    measure = function(trigger)
      return measureScenarioTrigger(trigger, direction)
    end,
    executeAction = function(action, trigger, metrics)
      return executeScenarioTriggerAction(action, trigger, metrics)
    end,
    onScheduled = function(trigger, state, metrics)
      log('I', logTag, string.format(
        'Trigger reaction scheduled id=%s group=%s metric=%s value=%s matchedAt=%.3f executeAt=%.3f delay=%.3f distance=%s relativeSpeed=%s ttc=%s',
        tostring(trigger.id), tostring(trigger.group or 'none'), tostring(trigger.metric or trigger.type),
        state.lastValue == math.huge and 'inf' or string.format('%.3f', tonumber(state.lastValue) or 0),
        tonumber(state.matchedAt) or 0, tonumber(state.executeAt) or 0, tonumber(trigger.delaySeconds) or 0,
        metrics.distance and string.format('%.3f', metrics.distance) or 'n/a',
        metrics.relativeSpeed and string.format('%.3f', metrics.relativeSpeed) or 'n/a',
        metrics.ttc == math.huge and 'inf' or (metrics.ttc and string.format('%.3f', metrics.ttc) or 'n/a')
      ))
    end,
  }
end

local function applyTriggerEventToTimeline(event)
  if not event or not generatedScene or not generatedScene.timeline then return end
  local timeline = generatedScene.timeline
  diagnostics.recordTrigger()
  if event.phase then timeline.phase = event.phase end
  if event.legacyFlag then timeline[event.legacyFlag] = true end
  if event.legacyTimestamp then timeline[event.legacyTimestamp] = event.firedAt end

  log('I', logTag, string.format(
    'Trigger fired id=%s group=%s source=%s subject=%s target=%s metric=%s value=%s threshold=%.3f action=%s matchedAt=%.3f sceneTime=%.3f reactionDelay=%.3f',
    tostring(event.id), tostring(event.group or 'none'), tostring(event.source), tostring(event.subject), tostring(event.target),
    tostring(event.metric), event.value == math.huge and 'inf' or string.format('%.3f', tonumber(event.value) or 0),
    tonumber(event.threshold) or 0, tostring(event.action and event.action.type), tonumber(event.matchedAt) or tonumber(event.firedAt) or 0,
    tonumber(event.firedAt) or 0, tonumber(event.reactionDelay) or 0
  ))

  if event.group == LEAD_COAST_TRIGGER_GROUP then
    log('I', logTag, string.format(
      'Car A began coasting at sceneTime=%.3f targetSpeed=%.2f via=%s',
      tonumber(event.firedAt) or 0, tonumber(event.action and event.action.speedMps) or 0, tostring(event.id)
    ))
  elseif event.group == LEAD_DECELERATE_TRIGGER_GROUP then
    log('I', logTag, string.format(
      'Car A began progressive deceleration at sceneTime=%.3f targetSpeed=%.2f via=%s',
      tonumber(event.firedAt) or 0, tonumber(event.action and event.action.speedMps) or 0, tostring(event.id)
    ))
  elseif event.group == LEAD_TRIGGER_GROUP then
    log('I', logTag, string.format(
      'Car A final braking stage triggered at sceneTime=%.3f amount=%.2f via=%s',
      tonumber(event.firedAt) or 0, tonumber(event.action and event.action.amount) or 0, tostring(event.id)
    ))
  elseif event.group == TARGET_TRIGGER_GROUP then
    log('I', logTag, string.format(
      'Car B delayed light braking triggered at sceneTime=%.3f amount=%.2f',
      tonumber(event.firedAt) or 0, tonumber(event.action and event.action.amount) or 0
    ))
  elseif event.group == TARGET_EMERGENCY_TRIGGER_GROUP then
    log('I', logTag, string.format(
      'Car B emergency braking stage triggered at sceneTime=%.3f amount=%.2f',
      tonumber(event.firedAt) or 0, tonumber(event.action and event.action.amount) or 0
    ))
  end
end

local function fireScenarioTrigger(triggerId, source)
  if not isScenarioEngineScene(generatedScene) then
    log('W', logTag, 'Cannot fire trigger: active scene is not a Scenario Engine scene')
    return false
  end

  local runtime = generatedScene.triggerRuntime
  local state = triggerEngine.getState(runtime, triggerId)
  local effectiveState, effectiveDefinition = triggerEngine.getEffectiveState(runtime, triggerId)
  if effectiveState and effectiveState.fired then
    log('I', logTag, string.format(
      'Trigger %s group was already resolved by %s', tostring(triggerId),
      tostring(effectiveDefinition and effectiveDefinition.id or triggerId)
    ))
    return true
  end
  if state and state.pending then
    log('I', logTag, string.format('Trigger %s already has a pending delayed action', tostring(triggerId)))
    return true
  end

  local direction = generatedScene.dir and vec3(generatedScene.dir.x, generatedScene.dir.y, generatedScene.dir.z) or nil
  local context = buildTriggerContext(direction)
  local definition = triggerEngine.getDefinition(runtime, triggerId)
  local metrics = definition and context.measure(definition) or nil
  local event, errorMessage = triggerEngine.fire(runtime, triggerId, context, metrics, source or 'manual')
  if not event then
    log('E', logTag, string.format('Failed to fire trigger %s: %s', tostring(triggerId), tostring(errorMessage)))
    return false
  end
  applyTriggerEventToTimeline(event)
  return true
end

function M.start()
  diagnostics.setStatus('RUNNING')
  log('I', logTag, string.format('Starting generated vehicle AI movement for %d vehicles', #generatedVehicles))
  local ambientStarted = 0
  for _, entry in ipairs(generatedVehicles) do
    local speed = entry.speedMps
    if not speed then
      speed = entry.label == 'Car A' and leadSpeedMps or chaseSpeedMps
    end
    if entry.isAmbient then
      if queueAmbientVehicleAI(entry, entry.targetPath or (generatedScene and generatedScene.targetPath or nil)) then
        ambientStarted = ambientStarted + 1
      end
    else
      ensureVehicleController(entry, entry.role == 'stopped_hazard' and VEHICLE_STATE.STOPPED or VEHICLE_STATE.CRUISE)
      if entry.role == 'stopped_hazard' then
        setVehicleControllerState(entry, VEHICLE_STATE.STOPPED, {reason = 'initial_hazard'})
      else
        setVehicleControllerState(entry, VEHICLE_STATE.CRUISE, {speedMps = speed})
      end
    end
  end
  if ambientStarted > 0 then
    log('I', logTag, string.format('Ambient traffic started: %d vehicles', ambientStarted))
  end

  if isScenarioEngineScene(generatedScene) then
    generatedScene.timeline = generatedScene.timeline or {}
    local definition = getScenarioDefinitionForScene(generatedScene)
    local timeline = generatedScene.timeline
    local runtime, triggerError
    if generatedScene.triggerRuntime then
      runtime, triggerError = triggerEngine.reset(generatedScene.triggerRuntime)
    else
      runtime, triggerError = triggerEngine.create(definition.triggers or {})
    end
    if not runtime then
      log('E', logTag, string.format('Cannot arm trigger engine: %s', tostring(triggerError)))
      return false
    end
    generatedScene.triggerRuntime = runtime

    timeline.mode = 'trigger_engine'
    timeline.scenarioDuration = timeline.scenarioDuration or definition.scenarioDuration
    timeline.maximumScenarioTime = timeline.maximumScenarioTime or definition.maximumScenarioTime
    timeline.leadBrakeDistance = getScenarioDistanceFallback(definition, LEAD_TRIGGER_GROUP, definition.leadBrakeDistance)
    timeline.targetBrakeDistance = getScenarioDistanceFallback(definition, TARGET_TRIGGER_GROUP, definition.targetBrakeDistance)
    timeline.leadTtcThreshold = getScenarioTtcThreshold(definition, LEAD_TRIGGER_GROUP, 0)
    timeline.targetTtcThreshold = getScenarioTtcThreshold(definition, TARGET_TRIGGER_GROUP, 0)
    timeline.targetBrakeAmount = getScenarioTriggerActionAmount(definition, TARGET_TRIGGER_ID, definition.targetBrakeAmount)
    timeline.elapsed = 0
    timeline.started = true
    timeline.phase = 'normal_drive'
    timeline.leadBrakeTriggered = false
    timeline.targetBrakeTriggered = false
    timeline.brakeTriggeredAt = nil
    timeline.targetBrakeTriggeredAt = nil
    timeline.leadHazardGap = timeline.initialLeadHazardGap
    timeline.targetLeadGap = nil
    timeline.completed = false
    timeline.completedAt = nil
    timeline.timeoutWarningLogged = false
    timeline.transientActions = {}
    log('I', logTag, string.format(
      'Trigger Engine armed: triggers=%d leadCoastTTC=%.2fs leadDecelTTC=%.2fs leadFinalTTC=%.2fs targetTTC=%.2fs targetDelay=%.2fs leadFallback=%.2fm targetFallback=%.2fm expectedFirstReaction=%.2fs duration=%.2fs',
      #(definition.triggers or {}),
      tonumber(definition.reactionModel and definition.reactionModel.leadCoastTtcSeconds) or 0,
      tonumber(definition.reactionModel and definition.reactionModel.leadDecelerateTtcSeconds) or 0,
      timeline.leadTtcThreshold, timeline.targetTtcThreshold,
      tonumber(definition.reactionModel and definition.reactionModel.targetReactionDelaySeconds) or 0,
      timeline.leadBrakeDistance, timeline.targetBrakeDistance,
      tonumber(timeline.expectedLeadTriggerTime) or -1, timeline.scenarioDuration
    ))
  end

  return #generatedVehicles > 0
end

function M.fireTrigger(triggerId)
  return fireScenarioTrigger(tostring(triggerId or ''), 'manual')
end

function M.triggerLeadBrake()
  return fireScenarioTrigger(LEAD_TRIGGER_ID, 'manual_alias')
end

function M.triggerTargetBrake()
  return fireScenarioTrigger(TARGET_TRIGGER_ID, 'manual_alias')
end

function M.stopVehicle(label, brakeAmount)
  local entry = findGeneratedVehicleEntry(tostring(label or ''))
  if not entry then
    log('W', logTag, string.format('stopVehicle: no generated vehicle named %s', tostring(label)))
    return false
  end
  return setVehicleControllerState(entry, VEHICLE_STATE.BRAKING, {
    brakeAmount = clamp(tonumber(brakeAmount) or 1, 0, 1),
    commandName = 'manualStop',
  })
end

function M.resumeVehicle(label, speedMps)
  local entry = findGeneratedVehicleEntry(tostring(label or ''))
  if not entry then
    log('W', logTag, string.format('resumeVehicle: no generated vehicle named %s', tostring(label)))
    return false
  end
  return setVehicleControllerState(entry, VEHICLE_STATE.CRUISE, {
    speedMps = tonumber(speedMps) or entry.speedMps,
  })
end

function M.getVehicleControllerState(label)
  local entry = findGeneratedVehicleEntry(tostring(label or ''))
  if not entry then return nil end
  if entry.isAmbient then
    log('I', logTag, string.format('Controller %s is ambient and unmanaged by Vehicle Controller', entry.label))
    return {state = 'AMBIENT_AI', unmanaged = true}
  end
  local controller = ensureVehicleController(entry)
  log('I', logTag, string.format(
    'Controller %s state=%s previous=%s speed=%.3f brake=%.2f reverseGuards=%d reverseCorrections=%d',
    entry.label, tostring(controller.state), tostring(controller.previousState or 'none'),
    tonumber(controller.lastLongitudinalSpeed) or 0, tonumber(controller.brakeAmount) or 0,
    tonumber(controller.reverseGuardCount) or 0, tonumber(controller.reverseCorrectionCount) or 0
  ))
  return controller
end

function M.printVehicleControllerStates()
  local result = {}
  for _, entry in ipairs(generatedVehicles) do
    if entry.isAmbient then
      result[entry.label] = {state = 'AMBIENT_AI', unmanaged = true}
      log('I', logTag, string.format(
        'Controller %s role=%s state=AMBIENT_AI lane=%s speedMps=%.2f',
        entry.label, tostring(entry.role), tostring(entry.laneChoice or 'n/a'), tonumber(entry.speedMps) or 0
      ))
    else
      local controller = ensureVehicleController(entry)
      result[entry.label] = controller
      log('I', logTag, string.format(
        'Controller %s role=%s state=%s longitudinalSpeed=%.3f brake=%.2f reverseGuards=%d reverseCorrections=%d',
        entry.label, tostring(entry.role), tostring(controller.state),
        tonumber(controller.lastLongitudinalSpeed) or 0, tonumber(controller.brakeAmount) or 0,
        tonumber(controller.reverseGuardCount) or 0, tonumber(controller.reverseCorrectionCount) or 0
      ))
    end
  end
  return result
end

function M.setOppositeCarriagewayOverride(nodeAId, nodeBId)
  if nodeAId == nil or nodeBId == nil or tostring(nodeAId) == '' or tostring(nodeBId) == '' then
    oppositeCarriagewayOverride = nil
    log('I', logTag, 'Opposite carriageway override cleared')
    return nil
  end
  oppositeCarriagewayOverride = {nodeA = nodeAId, nodeB = nodeBId}
  log('I', logTag, string.format(
    'Opposite carriageway override set to navgraph edge %s<->%s for future generations',
    tostring(nodeAId), tostring(nodeBId)
  ))
  return scenarioRegistry.copy(oppositeCarriagewayOverride)
end

function M.clearOppositeCarriagewayOverride()
  oppositeCarriagewayOverride = nil
  log('I', logTag, 'Opposite carriageway override cleared')
  return true
end

function M.getOppositeCarriagewayOverride()
  if not oppositeCarriagewayOverride then
    log('I', logTag, 'No opposite carriageway override is configured')
    return nil
  end
  log('I', logTag, string.format(
    'Opposite carriageway override nodes=%s<->%s',
    tostring(oppositeCarriagewayOverride.nodeA), tostring(oppositeCarriagewayOverride.nodeB)
  ))
  return scenarioRegistry.copy(oppositeCarriagewayOverride)
end

function M.printOppositeCarriagewayDiagnostics()
  local diagnostics = lastOppositeCarriagewayDiagnostics
  if not diagnostics then
    log('W', logTag, 'No opposite carriageway diagnostics are available; generate a scenario first')
    return nil
  end
  log('I', logTag, string.format(
    'Opposite discovery diagnostics mode=%s scannedEdges=%s acceptedEdges=%s selected=%s<->%s reason=%s',
    tostring(diagnostics.mode or 'unknown'), tostring(diagnostics.scannedEdges or 'n/a'),
    tostring(diagnostics.acceptedEdges or 'n/a'), tostring(diagnostics.selectedNodeA or 'n/a'),
    tostring(diagnostics.selectedNodeB or 'n/a'), tostring(diagnostics.reason or 'none')
  ))
  logOppositeCandidateDiagnostics(diagnostics)
  return diagnostics
end

function M.setAmbientTrafficCount(count)
  count = tonumber(count)
  if count == nil then
    ambientTrafficCountOverride = nil
    log('I', logTag, 'Ambient traffic count override cleared')
    return nil
  end
  count = math.floor(count)
  if count < 0 or count > 32 then
    log('W', logTag, 'Ambient traffic count must be between 0 and 32')
    return false
  end
  ambientTrafficCountOverride = count
  log('I', logTag, string.format('Ambient traffic count override set to %d for future generations', count))
  return count
end

function M.printAmbientTraffic()
  if not generatedScene then
    log('W', logTag, 'No generated scene is available')
    return nil
  end
  local summary = generatedScene.ambientTraffic or {}
  local eligibleLaneLabels = {}
  for _, lane in ipairs(summary.eligibleLanes or {}) do table.insert(eligibleLaneLabels, tostring(lane)) end
  log('I', logTag, string.format(
    'Ambient traffic summary: enabled=%s requested=%d planned=%d spawned=%d skipped=%d spawnSkipped=%d modelFallbacks=%d same=%d/%d planned spawned=%d opposite=%d/%d planned spawned=%d oppositeMode=%s oppositeSpot=%s oppositeReason=%s scenarioLane=%s eligibleLanes={%s} reason=%s',
    tostring(summary.enabled), tonumber(summary.requestedCount) or 0, tonumber(summary.generatedCount) or 0,
    tonumber(summary.spawnedCount) or 0, tonumber(summary.skippedCount) or 0,
    tonumber(summary.spawnSkippedCount) or 0, tonumber(summary.modelFallbackCount) or 0,
    tonumber(summary.sameDirectionGenerated) or 0, tonumber(summary.sameDirectionRequested) or 0, tonumber(summary.sameDirectionSpawned) or 0,
    tonumber(summary.oppositeDirectionGenerated) or 0, tonumber(summary.oppositeDirectionRequested) or 0, tonumber(summary.oppositeDirectionSpawned) or 0,
    tostring(summary.oppositeMode or 'none'), tostring(summary.oppositeSpotIndex or 'n/a'), tostring(summary.oppositeReason or 'none'),
    tostring(summary.scenarioLane or 'n/a'), table.concat(eligibleLaneLabels, ', '), tostring(summary.reason or 'none')
  ))
  local result = {}
  for _, entry in ipairs(generatedVehicles) do
    if entry.isAmbient then
      local item = {
        label = entry.label,
        model = entry.model,
        laneChoice = entry.laneChoice,
        speedMps = entry.speedMps,
        initialPosition = entry.initialPosition,
        flowDirection = entry.flowDirection,
      }
      table.insert(result, item)
      log('I', logTag, string.format(
        '%s flow=%s model=%s lane=%s speedMps=%.2f initialPos=(%.2f, %.2f, %.2f)',
        entry.label, tostring(entry.flowDirection or 'same'), tostring(entry.model), tostring(entry.laneChoice or 'n/a'), tonumber(entry.speedMps) or 0,
        entry.initialPosition.x, entry.initialPosition.y, entry.initialPosition.z
      ))
    end
  end
  return {summary = summary, vehicles = result}
end

function M.getTriggerGroupState(groupId)
  if not generatedScene or not generatedScene.triggerRuntime then return nil end
  local groupState = triggerEngine.getGroupState(generatedScene.triggerRuntime, groupId)
  if not groupState then
    log('W', logTag, string.format('Unknown trigger group %s', tostring(groupId)))
    return nil
  end
  log('I', logTag, string.format(
    'Trigger group id=%s status=%s triggerId=%s matchedAt=%s firedAt=%s',
    tostring(groupId), tostring(groupState.status), tostring(groupState.triggerId or 'none'),
    tostring(groupState.matchedAt or 'n/a'), tostring(groupState.firedAt or 'n/a')
  ))
  return groupState
end

function M.getTriggerState(triggerId)
  if not generatedScene or not generatedScene.triggerRuntime then return nil end
  local state = triggerEngine.getState(generatedScene.triggerRuntime, triggerId)
  if not state then
    log('W', logTag, string.format('Unknown trigger state %s', tostring(triggerId)))
    return nil
  end
  local metrics = state.lastMetrics or {}
  log('I', logTag, string.format(
    'Trigger state id=%s fired=%s pending=%s matchedAt=%s executeAt=%s firedAt=%s fireCount=%d blockedBy=%s metricAvailable=%s unavailableSince=%s value=%s distance=%s relativeSpeed=%s ttc=%s error=%s',
    tostring(triggerId), tostring(state.fired), tostring(state.pending), tostring(state.matchedAt or 'n/a'),
    tostring(state.executeAt or 'n/a'), tostring(state.firedAt or 'n/a'), tonumber(state.fireCount) or 0,
    tostring(state.blockedBy or 'none'), tostring(state.metricAvailable), tostring(state.unavailableSince or 'n/a'), tostring(state.lastValue or 'n/a'),
    tostring(metrics.distance or 'n/a'), tostring(metrics.relativeSpeed or 'n/a'),
    metrics.ttc == math.huge and 'inf' or tostring(metrics.ttc or 'n/a'), tostring(state.lastError or '')
  ))
  return state
end

function M.printTriggerStates()
  if not generatedScene or not generatedScene.triggerRuntime then
    log('W', logTag, 'No trigger runtime is available')
    return nil
  end
  local states = triggerEngine.listStates(generatedScene.triggerRuntime)
  for _, item in ipairs(states) do
    local definition = item.definition or {}
    local state = item.state or {}
    local metrics = state.lastMetrics or {}
    log('I', logTag, string.format(
      'Trigger %s group=%s metric=%s threshold=%.3f delay=%.3f fallbackFor=%s fallbackWait=%.3f fired=%s pending=%s matchedAt=%s executeAt=%s firedAt=%s fireCount=%d blockedBy=%s metricAvailable=%s unavailableSince=%s distance=%s relativeSpeed=%s ttc=%s action=%s',
      tostring(definition.id), tostring(definition.group or 'none'), tostring(definition.metric or definition.type), tonumber(definition.threshold) or 0,
      tonumber(definition.delaySeconds) or 0, tostring(definition.fallbackFor or 'none'), tonumber(definition.fallbackUnavailableSeconds) or 0,
      tostring(state.fired), tostring(state.pending), tostring(state.matchedAt or 'n/a'),
      tostring(state.executeAt or 'n/a'), tostring(state.firedAt or 'n/a'), tonumber(state.fireCount) or 0, tostring(state.blockedBy or 'none'),
      tostring(state.metricAvailable), tostring(state.unavailableSince or 'n/a'),
      metrics.distance and string.format('%.3f', metrics.distance) or 'n/a',
      metrics.relativeSpeed and string.format('%.3f', metrics.relativeSpeed) or 'n/a',
      metrics.ttc == math.huge and 'inf' or (metrics.ttc and string.format('%.3f', metrics.ttc) or 'n/a'),
      tostring(definition.action and definition.action.type or 'n/a')
    ))
  end
  return states
end

function M.printTriggerEvents()
  if not generatedScene or not generatedScene.triggerRuntime then
    log('W', logTag, 'No trigger runtime is available')
    return nil
  end
  local events = triggerEngine.getEvents(generatedScene.triggerRuntime)
  if #events == 0 then
    log('I', logTag, 'Trigger event log is empty')
  end
  for _, event in ipairs(events) do
    log('I', logTag, string.format(
      'Trigger event #%d id=%s group=%s matchedAt=%.3f firedAt=%.3f delay=%.3f source=%s metric=%s value=%s threshold=%.3f action=%s',
      tonumber(event.sequence) or 0, tostring(event.id), tostring(event.group or 'none'),
      tonumber(event.matchedAt) or tonumber(event.firedAt) or 0, tonumber(event.firedAt) or 0, tonumber(event.reactionDelay) or 0,
      tostring(event.source), tostring(event.metric), event.value == math.huge and 'inf' or tostring(event.value),
      tonumber(event.threshold) or 0, tostring(event.action and event.action.type or 'n/a')
    ))
  end
  return events
end

function M.onUpdate(dtReal, dtSim, dtRaw)
  if not isScenarioEngineScene(generatedScene) then return end
  local definition = getScenarioDefinitionForScene(generatedScene)
  local timeline = generatedScene.timeline
  if not timeline or not timeline.started then return end

  local delta = tonumber(dtSim) or tonumber(dtReal) or tonumber(dtRaw) or 0
  if delta <= 0 then return end
  timeline.elapsed = (timeline.elapsed or 0) + delta
  diagnostics.setSceneTime(timeline.elapsed)
  runtimeTelemetry.update(delta)

  local direction = generatedScene.dir and vec3(generatedScene.dir.x, generatedScene.dir.y, generatedScene.dir.z) or nil
  updateVehicleControllers(delta, direction)

  local context = buildTriggerContext(direction)
  local firedEvents, triggerError = triggerEngine.update(generatedScene.triggerRuntime, context)
  if triggerError then
    log('E', logTag, string.format('Trigger Engine update failed: %s', tostring(triggerError)))
  end
  for _, event in ipairs(firedEvents or {}) do
    applyTriggerEventToTimeline(event)
  end
  updateTransientActions()

  local leadState = triggerEngine.getEffectiveState(generatedScene.triggerRuntime, LEAD_TRIGGER_ID)
  local targetState = triggerEngine.getEffectiveState(generatedScene.triggerRuntime, TARGET_TRIGGER_ID)
  local leadMetrics = leadState and leadState.lastMetrics or {}
  local targetMetrics = targetState and targetState.lastMetrics or {}
  local leadHazardGap = leadMetrics.distance
  local targetLeadGap = targetMetrics.distance
  timeline.leadHazardGap = leadHazardGap
  timeline.targetLeadGap = targetLeadGap

  if not timeline.completed and timeline.elapsed >= (timeline.scenarioDuration or definition.scenarioDuration) then
    timeline.completed = true
    timeline.completedAt = timeline.elapsed
    timeline.phase = 'complete'
    diagnostics.setStatus('COMPLETED')
    log('I', logTag, string.format(
      'Telemetry nominal timeline completed at %.2fs; telemetry remains ACTIVE; leadBrake=%s targetBrake=%s leadHazardGap=%s targetLeadGap=%s triggerEvents=%d',
      timeline.elapsed, tostring(timeline.leadBrakeTriggered), tostring(timeline.targetBrakeTriggered),
      leadHazardGap and string.format('%.2f', leadHazardGap) or 'n/a',
      targetLeadGap and string.format('%.2f', targetLeadGap) or 'n/a',
      #(generatedScene.triggerRuntime.events or {})
    ))
  end

  if not (leadState and leadState.fired) and not timeline.timeoutWarningLogged and
      timeline.elapsed >= (timeline.maximumScenarioTime or definition.maximumScenarioTime) then
    timeline.timeoutWarningLogged = true
    log('W', logTag, string.format(
      'Scenario Timeline v2 timeout: lead trigger never fired; elapsed=%.2f gap=%s',
      timeline.elapsed, leadHazardGap and string.format('%.2f', leadHazardGap) or 'n/a'
    ))
  end
end

function M.reset()
  diagnostics.setStatus('RESET')
  log('I', logTag, 'Resetting generated vehicles to initial positions')
  for _, entry in ipairs(generatedVehicles) do
    local vehicle = entry.vehicle
    local position = vec3(entry.initialPosition.x, entry.initialPosition.y, entry.initialPosition.z)
    local ok = false
    if vehicle and vehicle.setPositionRotation then
      ok = pcall(function() vehicle:setPositionRotation(position, entry.initialRotation) end)
    else
      if vehicle and vehicle.setPosition then pcall(function() vehicle:setPosition(position) end) end
      if vehicle and vehicle.setRotation then pcall(function() vehicle:setRotation(entry.initialRotation) end) end
      ok = vehicle ~= nil
    end
    if entry.isAmbient then
      log('I', logTag, string.format('Reset %s result=%s controllerState=AMBIENT_AI', entry.label, tostring(ok)))
    else
      local controller = ensureVehicleController(entry, entry.role == 'stopped_hazard' and VEHICLE_STATE.STOPPED or VEHICLE_STATE.CRUISE)
      controller.state = entry.role == 'stopped_hazard' and VEHICLE_STATE.STOPPED or VEHICLE_STATE.CRUISE
      controller.previousState = nil
      controller.initialized = false
      controller.brakeAmount = 0
      controller.holdRefreshElapsed = 0
      controller.reverseGuardCount = 0
      controller.autoStop = true
      controller.followTargetLabel = nil
      controller.followRefreshElapsed = 0
      controller.lastFollowingSyncTime = nil
      controller.lastFollowingCommandedSpeed = nil
      controller.followingRouteInitialized = false
      controller.followingTargetId = nil
      controller.followingTargetMissingWarning = false
      log('I', logTag, string.format('Reset %s result=%s controllerState=%s', entry.label, tostring(ok), controller.state))
    end
  end
  return #generatedVehicles > 0
end

function M.repeatScene()
  log('I', logTag, 'Repeat mode: respawn same scene')
  if not generatedScene or #generatedVehicles == 0 then
    log('W', logTag, 'Cannot repeat scene: no generated scene is available')
    return false
  end

  local scene = generatedScene
  finalizeRuntimeTelemetry('REPEATED', true)
  local parentSessionId = diagnostics.getCurrentSessionId()
  diagnostics.beginSession({scenarioId = scene.scenarioId, seed = scene.seed, mapName = scene.mapName or getCurrentMapName(), scenarioVersion = scene.scenarioVersion, phase = scene.phase}, parentSessionId, true)
  local oldVehicleIds = {}
  for _, entry in ipairs(generatedVehicles) do
    local id = '?'
    if entry.vehicle and entry.vehicle.getID then
      pcall(function() id = entry.vehicle:getID() end)
    end
    table.insert(oldVehicleIds, string.format('%s=%s', entry.label, tostring(id)))
  end
  log('I', logTag, string.format('Old vehicle IDs cleared: %s', table.concat(oldVehicleIds, ', ')))

  local storedVehicleSpecs = scene.vehicles
  if not storedVehicleSpecs or #storedVehicleSpecs == 0 then
    -- Compatibility fallback for scenes generated by older v0.1 files.
    local modelA = scene.vehicleModels and scene.vehicleModels[1] or generatedVehicleModels[1]
    local modelB = scene.vehicleModels and scene.vehicleModels[2] or generatedVehicleModels[2]
    storedVehicleSpecs = {
      {label = 'Car A', role = 'lead', model = modelA, position = scene.posA, initialRotation = scene.rotation, speedMps = scene.leadSpeedMps or leadSpeedMps},
      {label = 'Car B', role = 'chaser', model = modelB, position = scene.posB, initialRotation = scene.rotation, speedMps = scene.chaseSpeedMps or chaseSpeedMps},
    }
  end

  log('I', logTag, 'Repeat step 1/3: clearing old generated vehicles')
  M.clearGeneratedVehicles()

  log('I', logTag, string.format(
    'Same scene reused: preset=%s phase=%s spot=%s seed=%s nodes=%s->%s targetPath={%s}',
    tostring(scene.preset or 'legacy'), tostring(scene.phase or 'legacy'),
    tostring(scene.spotIndex), tostring(scene.seed), tostring(scene.nodeA), tostring(scene.nodeB),
    scene.targetPath and table.concat(scene.targetPath, ', ') or ''
  ))
  log('I', logTag, string.format(
    'Repeat step 2/3: respawning %d vehicles at stored positions and rotations',
    #storedVehicleSpecs
  ))

  local respawnedEntries = {}
  local newVehicleIds = {}
  for _, spec in ipairs(storedVehicleSpecs) do
    local storedPosition = spec.position or spec.initialPosition
    if not storedPosition then
      log('E', logTag, string.format('Repeat respawn failed: %s has no stored position', tostring(spec.label)))
      generatedVehicles = respawnedEntries
      M.clearGeneratedVehicles()
      return false
    end

    local rotation = spec.initialRotation or scene.rotation
    local position = vec3(storedPosition.x, storedPosition.y, storedPosition.z)
    local vehicle = spawnVehicle(spec.model, position, rotation, spec.label)
    if not vehicle then
      if spec.isAmbient then
        log('W', logTag, string.format(
          'Repeat skipped optional ambient vehicle %s model=%s; scripted actors remain valid',
          tostring(spec.label), tostring(spec.model)
        ))
      else
        log('E', logTag, string.format(
          'Repeat respawn failed at critical actor %s; clearing %d partial vehicles',
          tostring(spec.label), #respawnedEntries
        ))
        generatedVehicles = respawnedEntries
        M.clearGeneratedVehicles()
        return false
      end
    end

    if vehicle then

    local controllerData = nil
    if not spec.isAmbient then
      controllerData = {
        state = spec.controllerState or (spec.role == 'stopped_hazard' and VEHICLE_STATE.STOPPED or VEHICLE_STATE.CRUISE),
        brakeAmount = 0,
      }
    end

    table.insert(respawnedEntries, {
      vehicle = vehicle,
      initialPosition = copyPosition(position),
      initialRotation = rotation,
      model = spec.model,
      label = spec.label,
      role = spec.role,
      speedMps = spec.speedMps,
      lateralOffset = spec.lateralOffset,
      laneOffset = spec.laneOffset,
      laneChoice = spec.laneChoice,
      isAmbient = spec.isAmbient == true,
      flowDirection = spec.flowDirection or 'scenario',
      targetPath = spec.targetPath or scene.targetPath,
      ai = spec.ai,
      controller = controllerData,
    })
    table.insert(newVehicleIds, string.format('%s=%s', spec.label, vehicleLabel(vehicle, '?')))
    end
  end

  generatedVehicles = respawnedEntries
  generatedScene = scene
  generatedScene.queuedAICommands = {}
  for _, entry in ipairs(generatedVehicles) do diagnostics.registerActor(entry) end
  startRuntimeTelemetryForGeneratedScene()
  log('I', logTag, string.format('New vehicle IDs spawned: %s', table.concat(newVehicleIds, ', ')))

  log('I', logTag, 'Repeat step 3/3: reapplying AI and starting the same scene')
  local started = M.start()
  log('I', logTag, string.format(
    'AI reapplied; same scene repeat complete; vehicles=%d started=%s',
    #generatedVehicles, tostring(started)
  ))
  return started
end

function M.printGeneratedSceneDebug()
  if not generatedScene then
    log('W', logTag, 'No generated scene debug data is available')
    return nil
  end

  local scene = generatedScene
  log('I', logTag, string.format(
    'Generated scene: scenarioId=%s scenarioVersion=%s preset=%s phase=%s seed=%s spot=%s nodes=%s->%s vehicles=%d targetPath={%s}',
    tostring(scene.scenarioId or 'legacy'), tostring(scene.scenarioVersion or 'n/a'),
    tostring(scene.preset or 'legacy'), tostring(scene.phase or 'legacy'),
    tostring(scene.seed), tostring(scene.spotIndex), tostring(scene.nodeA), tostring(scene.nodeB),
    scene.vehicles and #scene.vehicles or #generatedVehicles,
    scene.targetPath and table.concat(scene.targetPath, ', ') or ''
  ))

  if scene.dir then
    log('I', logTag, string.format(
      'Generated scene direction=(%.3f, %.3f, %.3f) spotLength=%s',
      scene.dir.x, scene.dir.y, scene.dir.z, tostring(scene.spotLength or 'n/a')
    ))
  end

  if scene.roadRules then
    local rules = scene.roadRules
    local laneCenter = rules.laneCenter or {x = 0, y = 0, z = 0}
    log('I', logTag, string.format(
      'Road rules: trafficSide=%s rightHandDrive=%s oneWay=%s roadDir=%s directionSource=%s lane=%s/%s laneWidth=%.2f roadWidth=%.2f laneOffset=%.2f laneCenter=(%.2f, %.2f, %.2f) driveInLane=%s',
      tostring(rules.trafficSide), tostring(rules.rightHandDrive), tostring(rules.oneWay),
      tostring(rules.roadDir), tostring(rules.directionSource), tostring(rules.laneChoice), tostring(rules.laneCount),
      tonumber(rules.laneWidth) or 0, tonumber(rules.roadWidth) or 0, tonumber(rules.laneOffset) or 0,
      tonumber(laneCenter.x) or 0, tonumber(laneCenter.y) or 0, tonumber(laneCenter.z) or 0,
      tostring(rules.driveInLane)
    ))
  end

  if scene.vehicles then
    for index, spec in ipairs(scene.vehicles) do
      local position = spec.position or spec.initialPosition
      log('I', logTag, string.format(
        'Vehicle #%d %s role=%s model=%s position=(%.2f, %.2f, %.2f) speedMps=%.2f lateralOffset=%.2f queuedAI=%s',
        index, tostring(spec.label), tostring(spec.role or 'n/a'), tostring(spec.model),
        position and position.x or 0, position and position.y or 0, position and position.z or 0,
        tonumber(spec.speedMps) or 0, tonumber(spec.lateralOffset) or 0,
        tostring(scene.queuedAICommands and scene.queuedAICommands[spec.label] or '<none>')
      ))
    end
  end

  if scene.timeline then
    local timeline = scene.timeline
    log('I', logTag, string.format(
      'Timeline: mode=%s phase=%s started=%s elapsed=%.3f duration=%.2f expectedLeadTrigger=%.2f leadHazardGap=%s leadTTC=%.2f leadFallbackDistance=%.2f leadBrakeTriggered=%s leadBrakeAt=%s targetLeadGap=%s targetTTC=%.2f targetFallbackDistance=%.2f targetBrakeAmount=%.2f targetBrakeTriggered=%s targetBrakeAt=%s completed=%s',
      tostring(timeline.mode or 'legacy'), tostring(timeline.phase or 'n/a'), tostring(timeline.started),
      tonumber(timeline.elapsed) or 0, tonumber(timeline.scenarioDuration) or 0,
      tonumber(timeline.expectedLeadTriggerTime) or 0,
      timeline.leadHazardGap and string.format('%.2f', timeline.leadHazardGap) or 'n/a',
      tonumber(timeline.leadTtcThreshold) or 0, tonumber(timeline.leadBrakeDistance) or 0, tostring(timeline.leadBrakeTriggered),
      tostring(timeline.brakeTriggeredAt or 'n/a'),
      timeline.targetLeadGap and string.format('%.2f', timeline.targetLeadGap) or 'n/a',
      tonumber(timeline.targetTtcThreshold) or 0, tonumber(timeline.targetBrakeDistance) or 0, tonumber(timeline.targetBrakeAmount) or 0,
      tostring(timeline.targetBrakeTriggered), tostring(timeline.targetBrakeTriggeredAt or 'n/a'),
      tostring(timeline.completed)
    ))
  end

  if scene.posA and scene.posB then
    log('I', logTag, string.format(
      'Legacy rear-end details: posA=(%.2f, %.2f, %.2f) posB=(%.2f, %.2f, %.2f) distanceBehind=%.2f leadSpeedMps=%.2f chaseSpeedMps=%.2f',
      scene.posA.x, scene.posA.y, scene.posA.z,
      scene.posB.x, scene.posB.y, scene.posB.z,
      scene.distanceBehind or 0, scene.leadSpeedMps or 0, scene.chaseSpeedMps or 0
    ))
  end
  return scene
end

-- Stable preset alias for the currently validated rear-end behavior.
function M.generateReliableRearEnd(seed)
  log('I', logTag, string.format('Generating reliable rear-end preset with seed=%s', tostring(seed)))
  return M.generateRearEnd(seed)
end

function M.printSceneSummary()
  if not generatedScene then
    log('W', logTag, 'No generated scene is available for summary')
    return nil
  end

  local scene = generatedScene
  log('I', logTag, string.format(
    'Scene summary: scenarioId=%s scenarioVersion=%s preset=%s phase=%s seed=%s spot=%s nodes=%s->%s targetPath={%s} vehicles=%d',
    tostring(scene.scenarioId or 'legacy'), tostring(scene.scenarioVersion or 'n/a'),
    tostring(scene.preset or 'legacy'), tostring(scene.phase or 'legacy'),
    tostring(scene.seed), tostring(scene.spotIndex), tostring(scene.nodeA), tostring(scene.nodeB),
    scene.targetPath and table.concat(scene.targetPath, ', ') or '',
    scene.vehicles and #scene.vehicles or #generatedVehicles
  ))

  if scene.roadRules then
    local rules = scene.roadRules
    log('I', logTag, string.format(
      'Road summary: trafficSide=%s oneWay=%s roadDir=%s lane=%s/%s laneOffset=%.2f driveInLane=%s',
      tostring(rules.trafficSide), tostring(rules.oneWay), tostring(rules.roadDir),
      tostring(rules.laneChoice), tostring(rules.laneCount), tonumber(rules.laneOffset) or 0,
      tostring(rules.driveInLane)
    ))
  end
  if scene.vehicles then
    for _, spec in ipairs(scene.vehicles) do
      local position = spec.position or spec.initialPosition
      log('I', logTag, string.format(
        '%s role=%s ambient=%s model=%s lane=%s pos=(%.2f, %.2f, %.2f) speedMps=%.2f lateralOffset=%.2f',
        tostring(spec.label), tostring(spec.role or 'n/a'), tostring(spec.isAmbient == true), tostring(spec.model), tostring(spec.laneChoice or 'n/a'),
        position and position.x or 0, position and position.y or 0, position and position.z or 0,
        tonumber(spec.speedMps) or 0, tonumber(spec.lateralOffset) or 0
      ))
    end
  end
  if scene.timeline then
    local timeline = scene.timeline
    log('I', logTag, string.format(
      'Timeline summary: mode=%s phase=%s started=%s elapsed=%.3f duration=%.2f expectedLeadTrigger=%.2f initialHazardGap=%.2f currentHazardGap=%s leadTTC=%.2f leadFallbackDistance=%.2f leadBrakeTriggered=%s currentTargetGap=%s targetTTC=%.2f targetFallbackDistance=%.2f targetBrakeTriggered=%s completed=%s',
      tostring(timeline.mode or 'legacy'), tostring(timeline.phase or 'n/a'), tostring(timeline.started),
      tonumber(timeline.elapsed) or 0, tonumber(timeline.scenarioDuration) or 0,
      tonumber(timeline.expectedLeadTriggerTime) or 0, tonumber(timeline.initialLeadHazardGap) or 0,
      timeline.leadHazardGap and string.format('%.2f', timeline.leadHazardGap) or 'n/a',
      tonumber(timeline.leadTtcThreshold) or 0, tonumber(timeline.leadBrakeDistance) or 0, tostring(timeline.leadBrakeTriggered),
      timeline.targetLeadGap and string.format('%.2f', timeline.targetLeadGap) or 'n/a',
      tonumber(timeline.targetTtcThreshold) or 0, tonumber(timeline.targetBrakeDistance) or 0, tostring(timeline.targetBrakeTriggered),
      tostring(timeline.completed)
    ))
  end
  return scene
end

function M.setConsoleLogLevel(level) return diagnostics.setConsoleLogLevel(level) end
function M.getConsoleLogLevel() return diagnostics.getConsoleLogLevel() end
function M.setDiagnosticCaptureLevel(level) return diagnostics.setDiagnosticCaptureLevel(level) end
function M.getDiagnosticCaptureLevel() return diagnostics.getDiagnosticCaptureLevel() end
function M.exportLastSessionLog()
  local result = diagnostics.exportLastSession()
  if result.ok then log('I', logTag, 'Diagnostic session exported: ' .. tostring(result.txtPath)) else log('E', logTag, 'Diagnostic session export failed: ' .. tostring(result.message)) end
  return result
end
function M.testDiagnosticExportPath() return diagnostics.testDiagnosticExportPath() end
function M.exportCurrentSessionLog() return diagnostics.exportLastSession() end
function M.getLastSessionReport() return diagnostics.getLastSessionReport() end
function M.printLastSessionSummary() return diagnostics.printSummary() end
function M.clearDiagnosticHistory() diagnostics.clearHistory(); return true end
function M.getRuntimeTelemetryReport() return runtimeTelemetry.getReport() end
function M.clearRuntimeTelemetry()
  finalizeRuntimeTelemetry('CLEARED', true)
  return runtimeTelemetry.clear()
end
function M.stopRuntimeTelemetry(reason)
  return finalizeRuntimeTelemetry(reason or 'STOPPED', true) or {ok=true, stopped=false}
end
function M.exportRuntimeTelemetry()
  local report = runtimeTelemetry.getReport()
  if not report then return {ok=false, code='NO_REPORT', failedStep='get_report', message='No runtime telemetry report is available'} end
  diagnostics.log('INFO', 'telemetry', 'telemetry_export_started', 'Runtime telemetry export started', {sessionId=report.sessionId})
  local result = telemetryExport.export(report, {exportCount=runtimeTelemetryExportCount})
  if result.ok then
    runtimeTelemetryExportCount = result.exportCount
    diagnostics.log('INFO', 'telemetry', 'telemetry_export_completed', 'Runtime telemetry export completed', {sessionId=result.sessionId, sampleCount=result.sampleCount})
    log('I', logTag, string.format('Runtime telemetry exported: %s actors=%d samples=%d', result.jsonlPath, result.actorCount, result.sampleCount))
  else
    diagnostics.log('WARN', 'telemetry', 'telemetry_export_failed', 'Runtime telemetry export failed: ' .. tostring(result.message), {sessionId=report.sessionId, code=result.code})
  end
  return result
end
function M.getLastRuntimeTelemetryExport() return telemetryExport.getLastResult() end
function M.setRuntimeTelemetryAutoExport(enabled) runtimeTelemetryAutoExport = enabled == true; return runtimeTelemetryAutoExport end
function M.getRuntimeTelemetryAutoExport() return runtimeTelemetryAutoExport end
function M.printRuntimeTelemetrySummary()
  local summary = runtimeTelemetry.getSummary()
  if not summary then
    log('W', logTag, 'No runtime telemetry report is available')
    return nil
  end
  log('I', logTag, string.format(
    'Runtime telemetry session=%s scenario=%s seed=%s actors=%d samples=%d dropped=%d',
    tostring(summary.sessionId), tostring(summary.scenarioId), tostring(summary.seed),
    summary.actorCount, summary.sampleCount, summary.droppedSampleCount
  ))
  for _, actor in ipairs(summary.actorSummaries or {}) do
    log('I', logTag, string.format(
      'Telemetry actor=%s samples=%d speed[min=%.2f max=%.2f final=%.2f] maxDecel=%s distance=%.2f missing=%d',
      tostring(actor.actor), actor.sampleCount or 0, actor.minSpeedMps or 0, actor.maxSpeedMps or 0,
      actor.finalSpeedMps or 0, actor.maxDecelerationMps2 and string.format('%.2f', actor.maxDecelerationMps2) or 'n/a',
      actor.approximateDistanceMeters or 0, actor.missingSampleCount or 0
    ))
  end
  return summary
end
function M.onExtensionUnloaded()
  finalizeRuntimeTelemetry('UNLOADED', true)
  if #generatedVehicles > 0 then M.clearGeneratedVehicles() end
  diagnostics.setStatus('UNLOADED')
  diagnostics.finish('UNLOADED')
end
M.onUnload = M.onExtensionUnloaded

-- Keep the public spot-query API explicitly exported before returning the module.
M.countSpotsByType = M.countSpotsByType
M.printSpotsByType = M.printSpotsByType
M.getTopSpotByType = M.getTopSpotByType
M.VEHICLE_STATE = VEHICLE_STATE
M.DEFAULT_SCENARIO_ID = DEFAULT_SCENARIO_ID

return M
