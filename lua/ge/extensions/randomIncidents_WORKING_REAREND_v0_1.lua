Exit code: 0
Wall time: 0.4 seconds
Output:
print("RANDOM INCIDENTS LUA FILE LOADED v1.1")
-- Random Incident Generator - Phase 1: Spot Harvester
-- Harvests candidate incident locations from the loaded level navgraph.

local M = {}

local logTag = 'randomIncidents'
local savedSpotsPath = '/settings/randomIncidents_spots.json'
local spots = {}
local generatedVehicles = {}
local generatedScene = nil

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

local function queueVehicleAI(vehicle, speed, label, targetPath)
  if not vehicle or not vehicle.queueLuaCommand then
    log('W', logTag, string.format('%s has no queueLuaCommand; AI was not configured', label))
    return false
  end

  -- 'set' is intentional: 'limit' and the default traffic mode allow legal
  -- road speed to win over the requested scene speed.
  local pathLiteral = '{}'
  if targetPath and #targetPath > 0 then
    local pathNodes = {}
    for _, nodeId in ipairs(targetPath) do
      table.insert(pathNodes, string.format('%q', tostring(nodeId)))
    end
    pathLiteral = '{' .. table.concat(pathNodes, ', ') .. '}'
  end
  local command = string.format(
    "ai.setMode('traffic'); ai.setAggression(1); ai.setSpeedMode('set'); ai.setSpeed(%.2f); ai.driveInLane('off'); if ai.setAvoidCars then ai.setAvoidCars(false) end; if ai.driveUsingPath then ai.driveUsingPath{wpTargetList = %s, noOfLaps = 0, driveInLane = 'off', avoidCars = 'off', aggression = 1, routeSpeed = %.2f, routeSpeedMode = 'set'} end",
    speed, pathLiteral, speed
  )

  local ok, errorMessage = pcall(function() vehicle:queueLuaCommand(command) end)
  if ok then
    log('I', logTag, string.format('Queued AI for %s: %s', label, command))
  else
    log('E', logTag, string.format('Failed to configure %s AI: %s', label, tostring(errorMessage)))
  end
  if generatedScene then
    generatedScene.queuedAICommands[label] = command
  end
  return ok
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

function M.clearGeneratedVehicles()
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

local function selectStraightSpot(seed)
  local straightSpots = {}
  for _, spot in ipairs(spots) do
    if spot.type == 'straight' then table.insert(straightSpots, spot) end
  end
  if #straightSpots == 0 then return nil end

  if seed == nil then
    log('I', logTag, 'No seed supplied; selected top straight spot')
    return straightSpots[1]
  end

  -- Keep seeded choices biased toward the best ten spots while remaining repeatable.
  local numericSeed = math.floor(tonumber(seed) or 0)
  local candidateCount = math.min(#straightSpots, 10)
  local value = (math.abs(numericSeed) * 1103515245 + 12345) % 2147483648
  local index = (value % candidateCount) + 1
  log('I', logTag, string.format('Seed=%s selected high-score straight rank=%d/%d', tostring(seed), index, candidateCount))
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
    {vehicle = carA, initialPosition = copyPosition(posA), initialRotation = rotation, label = 'Car A'},
    {vehicle = carB, initialPosition = copyPosition(posB), initialRotation = rotation, label = 'Car B'},
  }
  generatedScene = {
    spotIndex = spot.index,
    nodeA = spot.nodeA,
    nodeB = spot.nodeB,
    posA = copyPosition(posA),
    posB = copyPosition(posB),
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

function M.start()
  log('I', logTag, 'Starting generated vehicle AI movement')
  for _, entry in ipairs(generatedVehicles) do
    queueVehicleAI(entry.vehicle, entry.label == 'Car A' and leadSpeedMps or chaseSpeedMps, entry.label, generatedScene and generatedScene.targetPath)
  end
  return #generatedVehicles > 0
end

function M.reset()
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
    log('I', logTag, string.format('Reset %s result=%s', entry.label, tostring(ok)))
  end
  return #generatedVehicles > 0
end

function M.printGeneratedSceneDebug()
  if not generatedScene then
    log('W', logTag, 'No generated rear-end scene debug data is available')
    return nil
  end

  local scene = generatedScene
  log('I', logTag, string.format(
    'Generated scene: spot=%s posA=(%.2f, %.2f, %.2f) posB=(%.2f, %.2f, %.2f) dir=(%.3f, %.3f, %.3f) distanceBehind=%.2f leadSpeedMps=%.2f chaseSpeedMps=%.2f targetDistance=%.2f',
    tostring(scene.spotIndex), scene.posA.x, scene.posA.y, scene.posA.z,
    scene.posB.x, scene.posB.y, scene.posB.z,
    scene.dir.x, scene.dir.y, scene.dir.z,
    scene.distanceBehind, scene.leadSpeedMps, scene.chaseSpeedMps, scene.targetDistance
  ))
  log('I', logTag, string.format('Generated scene nodes: nodeA=%s nodeB=%s targetPath={%s}', tostring(scene.nodeA), tostring(scene.nodeB), scene.targetPath and table.concat(scene.targetPath, ', ') or ''))
  log('I', logTag, string.format('Generated scene node distances: Car A to nodeA=%.2f nodeB=%.2f; Car B to nodeA=%.2f nodeB=%.2f', scene.carAToNodeA, scene.carAToNodeB, scene.carBToNodeA, scene.carBToNodeB))
  for _, label in ipairs({'Car A', 'Car B'}) do
    log('I', logTag, string.format('Queued AI commands for %s: %s', label, tostring(scene.queuedAICommands[label] or '<none>')))
  end
  return scene
end

-- Keep the public spot-query API explicitly exported before returning the module.
M.countSpotsByType = M.countSpotsByType
M.printSpotsByType = M.printSpotsByType
M.getTopSpotByType = M.getTopSpotByType

return M


