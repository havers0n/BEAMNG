-- Bounded, read-only actor telemetry. This module deliberately has no scenario
-- knowledge; callers provide the canonical actor registry for each session.
local M = {}

local DEFAULT_INTERVAL = 0.5
local MAX_SAMPLES = 3000
local MAX_SAMPLES_PER_UPDATE = 4
local current = nil
local lastReport = nil

local function finite(value)
  return type(value) == 'number' and value == value and value ~= math.huge and value ~= -math.huge
end

local function copy(value, seen)
  local kind = type(value)
  if kind == 'nil' or kind == 'string' or kind == 'boolean' then return value end
  if kind == 'number' then return finite(value) and value or nil end
  if kind ~= 'table' then return nil end
  seen = seen or {}
  if seen[value] then return nil end
  seen[value] = true
  local result = {}
  for key, item in pairs(value) do
    if (type(key) == 'string' or type(key) == 'number') and type(item) ~= 'function' and type(item) ~= 'userdata' then
      result[key] = copy(item, seen)
    end
  end
  seen[value] = nil
  return result
end

local function vector(value, session)
  if not value then return nil end
  local x, y, z = value.x, value.y, value.z
  if finite(x) and finite(y) and finite(z) then return {x=x, y=y, z=z} end
  session.invalidFieldCount = session.invalidFieldCount + 1
  return nil
end

local function distance(a, b)
  local dx, dy, dz = b.x - a.x, b.y - a.y, b.z - a.z
  local result = math.sqrt(dx * dx + dy * dy + dz * dz)
  return finite(result) and result or nil
end

local function emit(session, level, eventType, message, fields)
  if session.diagnostics and session.diagnostics.log then
    pcall(session.diagnostics.log, level, 'telemetry', eventType, message, fields)
  end
end

local function getObject(session, objectId)
  if session.objectProvider then
    local ok, object = pcall(session.objectProvider, objectId)
    return ok and object or nil
  end
  if be and be.getObjectByID then
    local ok, object = pcall(function() return be:getObjectByID(objectId) end)
    return ok and object or nil
  end
  return nil
end

local function getVector(object, method, session)
  if not object or type(object[method]) ~= 'function' then return nil end
  local ok, value = pcall(function() return object[method](object) end)
  if not ok or value == nil then return nil end
  return vector(value, session)
end

local function sanitizeActor(actor)
  actor = type(actor) == 'table' and actor or {}
  local objectId = tonumber(actor.objectId)
  if not finite(objectId) then objectId = nil end
  return {label=tostring(actor.label or ''), objectId=objectId, role=tostring(actor.role or ''), ambient=actor.ambient == true}
end

local function safeScalar(value)
  if type(value) == 'number' then return finite(value) and value or nil end
  if type(value) == 'string' or type(value) == 'boolean' or value == nil then return value end
  return tostring(value)
end

local function createSummary(actor)
  return {actor=actor.label, objectId=actor.objectId, sampleCount=0, missingSampleCount=0,
    firstSceneTime=nil, lastSceneTime=nil, initialSpeedMps=nil, finalSpeedMps=nil,
    minSpeedMps=nil, maxSpeedMps=nil, maxAccelerationMps2=nil, maxDecelerationMps2=nil,
    approximateDistanceMeters=0, _lastPosition=nil, _lastWasAvailable=false}
end

local function addSample(session, sample)
  if #session.samples >= MAX_SAMPLES then
    table.remove(session.samples, 1)
    session.droppedSampleCount = session.droppedSampleCount + 1
    if not session.bufferOverflowReported then
      session.bufferOverflowReported = true
      emit(session, 'WARN', 'telemetry_buffer_overflow', 'Runtime telemetry sample buffer reached its limit', {maxSamples=MAX_SAMPLES})
    end
  end
  table.insert(session.samples, sample)
end

local function sampleActor(session, actor, summary)
  local object = actor.objectId and getObject(session, actor.objectId) or nil
  local sample = {sceneTime=session.sceneTime, actor=actor.label, objectId=actor.objectId, role=actor.role, ambient=actor.ambient, exists=object ~= nil,
    position=nil, velocity=nil, speedMps=nil, accelerationMps2=nil, forward=nil, controllerState=nil}
  summary.sampleCount = summary.sampleCount + 1
  summary.firstSceneTime = summary.firstSceneTime or session.sceneTime
  summary.lastSceneTime = session.sceneTime
  if not object then
    summary.missingSampleCount = summary.missingSampleCount + 1
    summary._lastWasAvailable, summary._lastSpeed, summary._lastSpeedTime = false, nil, nil
    if not session.unavailable[actor.label] then
      session.unavailable[actor.label] = true
      emit(session, 'WARN', 'telemetry_actor_unavailable', 'Runtime telemetry actor is unavailable', {actor=actor.label, objectId=actor.objectId})
    end
    session.latestByActor[actor.label] = sample
    addSample(session, sample)
    return
  end
  if session.unavailable[actor.label] then
    session.unavailable[actor.label] = nil
    emit(session, 'INFO', 'telemetry_actor_restored', 'Runtime telemetry actor is available again', {actor=actor.label, objectId=actor.objectId})
  end
  sample.position = getVector(object, 'getPosition', session)
  sample.velocity = getVector(object, 'getVelocity', session)
  sample.forward = getVector(object, 'getDirectionVector', session)
  if sample.velocity then
    sample.speedMps = math.sqrt(sample.velocity.x * sample.velocity.x + sample.velocity.y * sample.velocity.y + sample.velocity.z * sample.velocity.z)
    if not finite(sample.speedMps) then sample.speedMps = nil; session.invalidFieldCount = session.invalidFieldCount + 1 end
  end
  if session.controllerStateProvider then
    local ok, state = pcall(session.controllerStateProvider, actor.label, actor.objectId)
    if ok and (type(state) == 'string' or type(state) == 'number' or type(state) == 'boolean') then sample.controllerState = state end
  end
  if summary.sampleCount > 0 and finite(summary._lastSpeed) and finite(sample.speedMps) then
    local elapsed = session.sceneTime - (summary._lastSpeedTime or session.sceneTime)
    if elapsed > 0 then
      local acceleration = (sample.speedMps - summary._lastSpeed) / elapsed
      if finite(acceleration) then sample.accelerationMps2 = acceleration else session.invalidFieldCount = session.invalidFieldCount + 1 end
    end
  end
  if finite(sample.speedMps) then
    summary.initialSpeedMps = summary.initialSpeedMps or sample.speedMps
    summary.finalSpeedMps = sample.speedMps
    summary.minSpeedMps = summary.minSpeedMps and math.min(summary.minSpeedMps, sample.speedMps) or sample.speedMps
    summary.maxSpeedMps = summary.maxSpeedMps and math.max(summary.maxSpeedMps, sample.speedMps) or sample.speedMps
    summary._lastSpeed, summary._lastSpeedTime = sample.speedMps, session.sceneTime
  end
  if finite(sample.accelerationMps2) then
    if sample.accelerationMps2 >= 0 then summary.maxAccelerationMps2 = summary.maxAccelerationMps2 and math.max(summary.maxAccelerationMps2, sample.accelerationMps2) or sample.accelerationMps2
    else summary.maxDecelerationMps2 = summary.maxDecelerationMps2 and math.min(summary.maxDecelerationMps2, sample.accelerationMps2) or sample.accelerationMps2 end
  end
  if sample.position and summary._lastPosition and summary._lastWasAvailable then
    local travelled = distance(summary._lastPosition, sample.position)
    if travelled and finite(summary.approximateDistanceMeters + travelled) then summary.approximateDistanceMeters = summary.approximateDistanceMeters + travelled
    elseif not travelled then session.invalidFieldCount = session.invalidFieldCount + 1 end
  end
  summary._lastPosition, summary._lastWasAvailable = sample.position, sample.position ~= nil
  session.latestByActor[actor.label] = sample
  addSample(session, sample)
end

local function snapshot(session)
  if not session then return nil end
  local summaries, actors, samples, latest = {}, {}, {}, {}
  for index, actor in ipairs(session.actors) do
    actors[index] = copy(actor)
    local summary = copy(session.summaries[index])
    summary._lastPosition, summary._lastWasAvailable, summary._lastSpeed, summary._lastSpeedTime = nil, nil, nil, nil
    summaries[index] = summary
    latest[actor.label] = copy(session.latestByActor[actor.label])
  end
  for index, item in ipairs(session.samples) do samples[index] = copy(item) end
  return {sessionId=session.sessionId, scenarioId=session.scenarioId, seed=session.seed, status=session.status,
    startedAtSceneTime=session.startedAtSceneTime, stoppedAtSceneTime=session.stoppedAtSceneTime, sampleInterval=session.sampleInterval,
    actorCount=#actors, sampleCount=#samples, droppedSampleCount=session.droppedSampleCount, invalidFieldCount=session.invalidFieldCount,
    actors=actors, latestByActor=latest, actorSummaries=summaries, samples=samples}
end

function M.startSession(config)
  if current then M.stopSession('replaced') end
  config = type(config) == 'table' and config or {}
  local actors = {}
  for _, actor in ipairs(config.actors or {}) do table.insert(actors, sanitizeActor(actor)) end
  current = {sessionId=tostring(config.sessionId or ''), scenarioId=safeScalar(config.scenarioId), seed=safeScalar(config.seed), status='RUNNING', startedAtSceneTime=0,
    stoppedAtSceneTime=nil, sceneTime=0, sampleInterval=finite(config.sampleInterval) and config.sampleInterval > 0 and config.sampleInterval or DEFAULT_INTERVAL,
    accumulator=0, actors=actors, samples={}, latestByActor={}, summaries={}, unavailable={}, droppedSampleCount=0, invalidFieldCount=0,
    diagnostics=config.diagnostics, objectProvider=config.objectProvider, controllerStateProvider=config.controllerStateProvider, bufferOverflowReported=false}
  for index, actor in ipairs(actors) do current.summaries[index] = createSummary(actor) end
  emit(current, 'INFO', 'telemetry_session_started', 'Runtime telemetry session started', {sessionId=current.sessionId, scenarioId=current.scenarioId, actorCount=#actors})
  return current.sessionId
end

function M.update(dtSim)
  if not current or current.status ~= 'RUNNING' then return false end
  local delta = tonumber(dtSim)
  if not finite(delta) or delta <= 0 then return false end
  current.sceneTime = current.sceneTime + delta
  if not finite(current.sceneTime) then current.invalidFieldCount = current.invalidFieldCount + 1; return false end
  current.accumulator = current.accumulator + delta
  local count = 0
  while current.accumulator >= current.sampleInterval and count < MAX_SAMPLES_PER_UPDATE do
    current.accumulator = current.accumulator - current.sampleInterval
    for index, actor in ipairs(current.actors) do sampleActor(current, actor, current.summaries[index]) end
    count = count + 1
  end
  if count == MAX_SAMPLES_PER_UPDATE and current.accumulator >= current.sampleInterval then current.accumulator = 0 end
  return count > 0
end

function M.stopSession(reason)
  if not current then return false end
  current.status = tostring(reason or 'STOPPED')
  current.stoppedAtSceneTime = current.sceneTime
  emit(current, 'INFO', 'telemetry_session_stopped', 'Runtime telemetry session stopped', {sessionId=current.sessionId, reason=current.status})
  lastReport = snapshot(current)
  current = nil
  return true
end

function M.clear() current=nil; lastReport=nil; return true end
function M.getReport() return snapshot(current) or copy(lastReport) end
function M.getSummary()
  local report = M.getReport()
  if not report then return nil end
  return {sessionId=report.sessionId, scenarioId=report.scenarioId, seed=report.seed, status=report.status, actorCount=report.actorCount, sampleCount=report.sampleCount, droppedSampleCount=report.droppedSampleCount, actorSummaries=report.actorSummaries}
end

return M
