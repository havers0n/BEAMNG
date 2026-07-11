-- Ambient traffic population manager for Scenario Engine v2.
-- Produces deterministic, lane-aware vehicle specifications. It does not spawn
-- vehicles or call BeamNG APIs; the host extension owns those responsibilities.
local M = {}

local function clamp(value, minimum, maximum)
  return math.max(minimum, math.min(maximum, value))
end

local function copyArray(value)
  local result = {}
  for _, item in ipairs(value or {}) do table.insert(result, item) end
  return result
end

local function createRng(seed)
  local state = (math.abs(math.floor(tonumber(seed) or 0)) + 104729) % 2147483647
  if state == 0 then state = 1 end
  return function()
    state = (state * 48271) % 2147483647
    return state / 2147483647
  end
end

local function randomRange(nextRandom, minimum, maximum)
  return minimum + (maximum - minimum) * nextRandom()
end

local function shuffled(values, nextRandom)
  local result = copyArray(values)
  for index = #result, 2, -1 do
    local other = math.floor(nextRandom() * index) + 1
    result[index], result[other] = result[other], result[index]
  end
  return result
end

function M.validate(config)
  if config == nil then return true end
  if type(config) ~= 'table' then return false, 'ambientTraffic must be a table' end
  if config.enabled == false then return true end

  local count = tonumber(config.count or 0)
  if count == nil or count < 0 or count > 32 or count ~= math.floor(count) then
    return false, 'ambientTraffic.count must be an integer from 0 to 32'
  end

  if type(config.models) ~= 'table' or #config.models == 0 then
    return false, 'ambientTraffic.models must contain at least one vehicle model'
  end
  for index, model in ipairs(config.models) do
    if type(model) ~= 'string' or model == '' then
      return false, 'ambientTraffic.models['..index..'] must be a non-empty string'
    end
  end

  local speedRange = config.speedRange
  if type(speedRange) ~= 'table' or tonumber(speedRange[1]) == nil or tonumber(speedRange[2]) == nil then
    return false, 'ambientTraffic.speedRange must be {minimum, maximum}'
  end
  if tonumber(speedRange[1]) < 0 or tonumber(speedRange[2]) < tonumber(speedRange[1]) then
    return false, 'ambientTraffic.speedRange is invalid'
  end

  for _, field in ipairs({'edgeMargin', 'longitudinalJitter', 'lateralJitter', 'minimumSpacing', 'aggression'}) do
    if config[field] ~= nil and tonumber(config[field]) == nil then
      return false, 'ambientTraffic.'..field..' must be numeric'
    end
  end
  return true
end

local function legalLaneChoices(roadPlan)
  local laneCount = math.max(1, math.floor(tonumber(roadPlan.laneCount) or 1))
  local choices = {}
  if roadPlan.oneWay then
    for lane = 1, laneCount do table.insert(choices, lane) end
  elseif laneCount <= 1 then
    table.insert(choices, 1)
  elseif tonumber(roadPlan.roadDir) == -1 then
    for lane = 1, math.max(1, math.floor(laneCount * 0.5)) do table.insert(choices, lane) end
  else
    for lane = math.max(1, math.floor(laneCount * 0.5) + 1), laneCount do table.insert(choices, lane) end
  end
  return choices
end

local function getLaneOffset(roadPlan, laneChoice)
  local laneCount = math.max(1, math.floor(tonumber(roadPlan.laneCount) or 1))
  local laneWidth = tonumber(roadPlan.laneCellWidth) or tonumber(roadPlan.nominalLaneWidth) or 3.05
  local legalSide = tonumber(roadPlan.legalSide) or 1
  return (laneChoice - (laneCount * 0.5 + 0.5)) * laneWidth * legalSide
end

function M.build(config, roadPlan, seed)
  config = config or {}
  local valid, errorMessage = M.validate(config)
  if not valid then return nil, nil, errorMessage end

  local requestedCount = math.floor(tonumber(config.count) or 0)
  local summary = {
    enabled = config.enabled ~= false,
    requestedCount = requestedCount,
    generatedCount = 0,
    skippedCount = 0,
    eligibleLanes = {},
    scenarioLane = roadPlan and roadPlan.laneChoice or nil,
    reason = nil,
  }
  if not summary.enabled or requestedCount == 0 then
    summary.reason = summary.enabled and 'count_zero' or 'disabled'
    return {}, summary
  end
  if type(roadPlan) ~= 'table' or type(roadPlan.spot) ~= 'table' then
    return nil, nil, 'ambient traffic requires a valid road plan with spot data'
  end

  local choices = legalLaneChoices(roadPlan)
  if config.excludeScenarioLane ~= false then
    local filtered = {}
    for _, lane in ipairs(choices) do
      if lane ~= roadPlan.laneChoice then table.insert(filtered, lane) end
    end
    choices = filtered
  end
  if #choices == 0 and config.fallbackToScenarioLane == true then
    choices = {roadPlan.laneChoice}
    summary.reason = 'scenario_lane_fallback'
  end
  if #choices == 0 then
    summary.reason = 'no_eligible_adjacent_lane'
    summary.skippedCount = requestedCount
    return {}, summary
  end

  local nextRandom = createRng((tonumber(seed) or 0) + 600013)
  choices = shuffled(choices, nextRandom)
  summary.eligibleLanes = copyArray(choices)

  local spotLength = tonumber(roadPlan.spot.length) or 0
  local edgeMargin = math.max(8, tonumber(config.edgeMargin) or 22)
  local minimumOffset = -math.max(0, spotLength * 0.5 - edgeMargin)
  local maximumOffset = math.max(0, spotLength * 0.5 - edgeMargin)
  if maximumOffset - minimumOffset < 40 then
    summary.reason = 'road_segment_too_short'
    summary.skippedCount = requestedCount
    return {}, summary
  end

  local minimumSpacing = math.max(8, tonumber(config.minimumSpacing) or 28)
  local longitudinalSpan = maximumOffset - minimumOffset
  local capacityPerLane = math.max(1, math.floor(longitudinalSpan / minimumSpacing))
  local actualCount = math.min(requestedCount, capacityPerLane * #choices)

  local laneAssignments = {}
  for index = 1, actualCount do
    laneAssignments[index] = choices[((index - 1) % #choices) + 1]
  end

  local speedMin = tonumber(config.speedRange[1])
  local speedMax = tonumber(config.speedRange[2])
  local longitudinalJitter = math.max(0, tonumber(config.longitudinalJitter) or 8)
  local lateralJitter = math.max(0, tonumber(config.lateralJitter) or 0.12)
  local models = config.models
  local specs = {}

  for index = 1, actualCount do
    local laneChoice = laneAssignments[index]
    local fraction = (index - 0.5) / actualCount
    local baseOffset = minimumOffset + (maximumOffset - minimumOffset) * fraction
    local offset = clamp(
      baseOffset + randomRange(nextRandom, -longitudinalJitter, longitudinalJitter),
      minimumOffset,
      maximumOffset
    )
    local modelIndex = math.floor(nextRandom() * #models) + 1
    local model = models[modelIndex]
    local speedMps = randomRange(nextRandom, speedMin, speedMax)
    local jitter = randomRange(nextRandom, -lateralJitter, lateralJitter)

    table.insert(specs, {
      label = string.format('Ambient %02d', index),
      role = 'ambient_traffic',
      model = model,
      offset = offset,
      lateralOffset = jitter,
      speedMps = speedMps,
      laneChoice = laneChoice,
      laneOffset = getLaneOffset(roadPlan, laneChoice),
      isAmbient = true,
      ai = {
        aggression = clamp(tonumber(config.aggression) or 0.35, 0, 1),
        avoidCars = true,
        driveInLane = config.driveInLane ~= false,
      },
    })
  end

  table.sort(specs, function(a, b)
    if a.laneChoice == b.laneChoice then return a.offset < b.offset end
    return a.laneChoice < b.laneChoice
  end)

  summary.generatedCount = #specs
  summary.skippedCount = requestedCount - #specs
  summary.minimumSpacing = minimumSpacing
  summary.capacityPerLane = capacityPerLane
  summary.minimumOffset = minimumOffset
  summary.maximumOffset = maximumOffset
  summary.speedRange = {speedMin, speedMax}
  return specs, summary
end

return M
