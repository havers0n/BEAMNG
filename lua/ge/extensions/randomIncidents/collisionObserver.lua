-- Read-only, scenario-independent collision episode observer.  BeamNG's GE
-- object map is intentionally accessed defensively: object records can vanish
-- while a vehicle is being deleted or respawned.
local M = {}

local DEFAULT_POLL_INTERVAL, CONTACT_END_GRACE, RECONTACT_MERGE_WINDOW = 0.10, 0.35, 0.50
local MAX_EVENTS, MAX_POLLS_PER_UPDATE = 256, 4
local current, lastReport = nil, nil

local function finite(v) return type(v) == 'number' and v == v and v ~= math.huge and v ~= -math.huge end
local function scalar(v) return type(v) == 'string' or type(v) == 'boolean' or finite(v) end
local function copy(v, seen)
  local kind = type(v)
  if kind == 'nil' or kind == 'string' or kind == 'boolean' then return v end
  if kind == 'number' then return finite(v) and v or nil end
  if kind ~= 'table' then return nil end
  seen = seen or {}; if seen[v] then return nil end; seen[v] = true
  local r = {}; for k, x in pairs(v) do if type(k) == 'string' or type(k) == 'number' then r[k] = copy(x, seen) end end; seen[v] = nil
  return r
end
local function vector(v, session)
  if type(v) ~= 'table' and type(v) ~= 'userdata' then return nil end
  local ok, x, y, z = pcall(function() return v.x, v.y, v.z end)
  if not ok or not finite(x) or not finite(y) or not finite(z) then if v ~= nil then session.invalidFieldCount = session.invalidFieldCount + 1 end; return nil end
  return {x=x, y=y, z=z}
end
local function length(v) return v and math.sqrt(v.x*v.x + v.y*v.y + v.z*v.z) or nil end
local function emit(s, level, eventType, message, fields)
  if s.diagnostics and s.diagnostics.log then pcall(s.diagnostics.log, level, 'collision', eventType, message, fields) end
end
local function objectFor(s, id)
  if s.objectProvider then local ok, value = pcall(s.objectProvider, id); if ok then return value end end
  if be and be.getObjectByID then local ok, value = pcall(function() return be:getObjectByID(id) end); if ok then return value end end
  return nil
end
-- All getters are isolated so one transient BeamNG object failure never loses
-- another current field. This reader never sends commands to Vehicle Lua.
local function readLiveActorState(s, actorRecord)
  s.liveStateReadCount = s.liveStateReadCount + 1
  if s.liveStateReader then
    local ok, state = pcall(s.liveStateReader, actorRecord)
    if ok and type(state) == 'table' then
      local position, velocity, forward = vector(state.position, s), vector(state.velocity, s), vector(state.forward, s)
      if position or velocity then return {exists=state.exists ~= false,position=position,velocity=velocity,forward=forward,speedMps=length(velocity),source='live_vehicle'} end
    end
    s.liveStateReadFailureCount=s.liveStateReadFailureCount+1
    return {exists=false,source='partial'}
  end
  local vehicle = objectFor(s, actorRecord.objectId)
  if not vehicle then s.liveStateReadFailureCount=s.liveStateReadFailureCount+1; return {exists=false,source='partial'} end
  local position, velocity, forward = nil, nil, nil
  if vehicle.getPosition then local ok, value=pcall(function() return vehicle:getPosition() end); if ok then position=vector(value,s) end end
  if vehicle.getVelocity then local ok, value=pcall(function() return vehicle:getVelocity() end); if ok then velocity=vector(value,s) end end
  if vehicle.getDirectionVector then local ok, value=pcall(function() return vehicle:getDirectionVector() end); if ok then forward=vector(value,s) end end
  if not position and not velocity then s.liveStateReadFailureCount=s.liveStateReadFailureCount+1 end
  return {exists=true,position=position,velocity=velocity,forward=forward,speedMps=length(velocity),source=(position and velocity) and 'live_vehicle' or 'partial'}
end
local function resolveCollisionActorState(s, actorRecord, telemetryAccessor)
  local live = readLiveActorState(s, actorRecord)
  local latest = telemetryAccessor and telemetryAccessor.latestByActor and telemetryAccessor.latestByActor[actorRecord.actor]
  -- Do not use a stale actor record when a repeat has assigned a new object ID.
  if latest and tonumber(latest.objectId) ~= tonumber(actorRecord.objectId) then latest=nil end
  local position, velocity, forward = live.position, live.velocity, live.forward
  local usedFallback = false
  if latest then
    if not position then position=vector(latest.position,s); usedFallback=position ~= nil end
    if not velocity then velocity=vector(latest.velocity,s); usedFallback=velocity ~= nil end
    if not forward then forward=vector(latest.forward,s) end
  end
  local source
  if live.position and live.velocity then source='live_vehicle'
  elseif not live.position and not live.velocity and position and velocity then source='runtime_telemetry'
  else source='partial' end
  if usedFallback then s.telemetryFallbackCount=s.telemetryFallbackCount+1 end
  if source == 'partial' then s.partialStateCount=s.partialStateCount+1 end
  return {exists=live.exists,position=position,velocity=velocity,forward=forward,speedMps=length(velocity),source=source}
end
local function computePairKinematics(stateA, stateB)
  local velocityA, velocityB = stateA and stateA.velocity, stateB and stateB.velocity
  if not velocityA or not velocityB then return nil, nil end
  local relativeVelocity={x=velocityA.x-velocityB.x,y=velocityA.y-velocityB.y,z=velocityA.z-velocityB.z}
  local relativeSpeed=length(relativeVelocity)
  local positionA, positionB = stateA.position, stateB.position
  if not positionA or not positionB then return relativeSpeed, nil end
  local deltaPosition={x=positionB.x-positionA.x,y=positionB.y-positionA.y,z=positionB.z-positionA.z}; local distance=length(deltaPosition)
  if not distance or distance <= 1e-6 then return relativeSpeed, nil end
  return relativeSpeed, math.max(0,(relativeVelocity.x*deltaPosition.x+relativeVelocity.y*deltaPosition.y+relativeVelocity.z*deltaPosition.z)/distance)
end
local function normalizePair(s, a, b)
  a, b = tonumber(a), tonumber(b)
  if not a or not b or a == b then return nil end
  local low, high = math.min(a,b), math.max(a,b)
  local aa, bb = s.actorsByObjectId[low], s.actorsByObjectId[high]
  if not aa or not bb then return nil end
  return tostring(low)..':'..tostring(high), aa, bb
end
local function defaultPoll(s)
  local objects = map and map.objects
  if type(objects) ~= 'table' then return nil, false end
  local observations, usable = {}, false
  for id in pairs(s.actorsByObjectId) do
    local object = objects[id] or objects[tostring(id)]
    if object then
      -- Presence of an object record confirms that this map exposes the GE map
      -- object registry. objectCollisions itself is sparse and appears only on
      -- contacts in versions that provide it.
      usable = true
      local contacts = object.objectCollisions
      if type(contacts) == 'table' then
        for otherId, value in pairs(contacts) do
          -- BeamNG scenario/traffic call sites treat exactly `== 1` as a
          -- current contact. Do not infer collisions from auxiliary values.
          if value == 1 then
          local candidate = tonumber(otherId)
          if not candidate and type(value) == 'table' then candidate = tonumber(value.objectId or value.id) end
          if candidate then table.insert(observations, {objectIdA=tonumber(id), objectIdB=candidate, source='objectCollisions'}) end
          end
        end
      end
    end
  end
  return observations, usable
end
local function addEvent(s, event)
  if #s.events >= MAX_EVENTS then
    local removed = false
    for i, old in ipairs(s.events) do if old.state == 'ENDED' then table.remove(s.events, i); removed=true; break end end
    if not removed then table.remove(s.events, 1) end
    s.droppedCollisionEventCount=s.droppedCollisionEventCount+1
    if not s.overflowReported then s.overflowReported=true; emit(s, 'WARN', 'collision_buffer_overflow', 'Collision event buffer overflow', {sessionId=s.sessionId, maxEvents=MAX_EVENTS}) end
  end
  table.insert(s.events, event)
end
local function finish(s, e, at, reason)
  if e.state ~= 'ACTIVE' then return end
  e.state='ENDED'; e.endedAtSceneTime=at; e.durationSeconds=math.max(0, at-e.startedAtSceneTime)
  emit(s, 'INFO', 'collision_ended', 'Collision episode ended', {eventId=e.eventId, pairKey=e.pairKey, reason=reason, durationSeconds=e.durationSeconds, observationCount=e.observationCount})
end
local function observe(s, pairKey, a, b, now, telemetry)
  local e = s.byPair[pairKey]
  if e and e.state == 'ENDED' and now - (e.endedAtSceneTime or now) > RECONTACT_MERGE_WINDOW then e=nil; s.byPair[pairKey]=nil end
  if e and e.state == 'ENDED' then e.state='ACTIVE'; e.endedAtSceneTime=nil end
  local stateA, stateB = resolveCollisionActorState(s,a,telemetry), resolveCollisionActorState(s,b,telemetry)
  local relative, closing = computePairKinematics(stateA, stateB)
  local stateSource = stateA.source == stateB.source and stateA.source or 'mixed'
  if not e then
    s.nextEventId=s.nextEventId+1
    e={formatVersion=2,eventId='collision_'..s.sessionId..'_'..s.nextEventId, sessionId=s.sessionId, state='ACTIVE', pairKey=pairKey,
      actorA=a.actor,actorB=b.actor,objectIdA=a.objectId,objectIdB=b.objectId,roleA=a.role,roleB=b.role,ambientA=a.ambient,ambientB=b.ambient,
      startedAtSceneTime=now,lastObservedAtSceneTime=now,endedAtSceneTime=nil,durationSeconds=0,observationCount=0,sources={objectCollisions=true,crashDetection=false},
      firstPositionA=stateA.position,firstPositionB=stateB.position,latestPositionA=stateA.position,latestPositionB=stateB.position,firstSpeedAMps=stateA.speedMps,firstSpeedBMps=stateB.speedMps,latestSpeedAMps=stateA.speedMps,latestSpeedBMps=stateB.speedMps,
      firstRelativeSpeedMps=relative,maxRelativeSpeedMps=relative,firstClosingSpeedMps=closing,maxClosingSpeedMps=closing,stateSource=stateSource,
      firstStateSourceA=stateA.source,firstStateSourceB=stateB.source,latestStateSourceA=stateA.source,latestStateSourceB=stateB.source,
      controllerStateA=s.controllerStateProvider and s.controllerStateProvider(a.actor,a.objectId) or nil,controllerStateB=s.controllerStateProvider and s.controllerStateProvider(b.actor,b.objectId) or nil}
    addEvent(s,e); s.byPair[pairKey]=e
    emit(s,'INFO','collision_started','Collision episode started',{eventId=e.eventId,pairKey=pairKey,actorA=a.actor,actorB=b.actor})
  else
    e.lastObservedAtSceneTime=now; e.latestPositionA=stateA.position or e.latestPositionA; e.latestPositionB=stateB.position or e.latestPositionB; e.latestSpeedAMps=stateA.speedMps or e.latestSpeedAMps; e.latestSpeedBMps=stateB.speedMps or e.latestSpeedBMps; e.latestStateSourceA=stateA.source; e.latestStateSourceB=stateB.source
    if relative then e.maxRelativeSpeedMps=math.max(e.maxRelativeSpeedMps or relative,relative) end
    if closing then e.maxClosingSpeedMps=math.max(e.maxClosingSpeedMps or closing,closing) end
  end
  e.observationCount=e.observationCount+1; e.durationSeconds=math.max(0,now-e.startedAtSceneTime)
end
local function poll(s, telemetry)
  local raw, available
  if s.sourceAdapter then raw, available=s.sourceAdapter(s, s.sceneTime) else raw, available=defaultPoll(s) end
  if available == false then s.sourceStatus.objectCollisionsAvailable=false; if not s.sourceUnavailableReported then s.sourceUnavailableReported=true; emit(s,'WARN','collision_source_unavailable','Primary collision source is unavailable',{sessionId=s.sessionId, primarySource='objectCollisions'}) end else s.sourceStatus.objectCollisionsAvailable=true end
  local seen, telemetryResolved={}
  for _, o in ipairs(type(raw)=='table' and raw or {}) do
    s.rawObservationCount=s.rawObservationCount+1
    local key,a,b=normalizePair(s,o.objectIdA,o.objectIdB)
    if not key then s.ignoredUnknownObjectCount=s.ignoredUnknownObjectCount+1
    elseif seen[key] then s.duplicateObservationCount=s.duplicateObservationCount+1
    else
      seen[key]=true
      if not telemetryResolved and type(telemetry) == 'function' then local ok, report = pcall(telemetry); telemetry = ok and report or nil; telemetryResolved=true end
      observe(s,key,a,b,s.sceneTime,telemetry)
    end
  end
  for _, e in ipairs(s.events) do if e.state=='ACTIVE' and not seen[e.pairKey] and s.sceneTime-e.lastObservedAtSceneTime > CONTACT_END_GRACE then finish(s,e,e.lastObservedAtSceneTime+CONTACT_END_GRACE,'contact_grace_elapsed') end end
end
local function snapshot(s)
  if not s then return nil end
  local events=copy(s.events); local active,ended=0,0; for _,e in ipairs(events) do if e.state=='ACTIVE' then active=active+1 else ended=ended+1 end end
  return {sessionId=s.sessionId,scenarioId=s.scenarioId,seed=s.seed,status=s.status,startedAtSceneTime=s.startedAtSceneTime,stoppedAtSceneTime=s.stoppedAtSceneTime,pollInterval=s.pollInterval,actorCount=#s.actors,
    collisionEventCount=#events,activeCollisionCount=active,endedCollisionCount=ended,rawObservationCount=s.rawObservationCount,duplicateObservationCount=s.duplicateObservationCount,ignoredUnknownObjectCount=s.ignoredUnknownObjectCount,unpairedCrashSignalCount=s.unpairedCrashSignalCount,droppedCollisionEventCount=s.droppedCollisionEventCount,invalidFieldCount=s.invalidFieldCount,liveStateReadCount=s.liveStateReadCount,liveStateReadFailureCount=s.liveStateReadFailureCount,telemetryFallbackCount=s.telemetryFallbackCount,partialStateCount=s.partialStateCount,sourceStatus=copy(s.sourceStatus),events=events}
end
function M.startSession(config)
  if current then M.stopSession('replaced') end; config=type(config)=='table' and config or {}
  local actors, byId={},{}; for _,x in ipairs(config.actors or {}) do local id=tonumber(x.objectId); if id and not byId[id] then local a={actor=tostring(x.actor or x.label or ''),objectId=id,role=tostring(x.role or ''),ambient=x.ambient==true}; actors[#actors+1]=a;byId[id]=a end end
  current={sessionId=tostring(config.sessionId or ''),scenarioId=config.scenarioId,seed=config.seed,status='ACTIVE',startedAtSceneTime=0,stoppedAtSceneTime=nil,sceneTime=0,pollInterval=finite(config.pollInterval) and config.pollInterval>0 and config.pollInterval or DEFAULT_POLL_INTERVAL,frameLevel=config.frameLevel==true,accumulator=0,actors=actors,actorsByObjectId=byId,events={},byPair={},nextEventId=0,rawObservationCount=0,duplicateObservationCount=0,ignoredUnknownObjectCount=0,unpairedCrashSignalCount=0,droppedCollisionEventCount=0,invalidFieldCount=0,liveStateReadCount=0,liveStateReadFailureCount=0,telemetryFallbackCount=0,partialStateCount=0,diagnostics=config.diagnostics,objectProvider=config.objectProvider,liveStateReader=config.liveStateReader,controllerStateProvider=config.controllerStateProvider,sourceAdapter=config.sourceAdapter,sourceStatus={objectCollisionsAvailable=nil,crashDetectionAvailable=false,primarySource='objectCollisions'}}
  emit(current,'INFO','collision_observer_started','Collision observer started',{sessionId=current.sessionId,actorCount=#actors,pollInterval=current.pollInterval}); return current.sessionId
end
function M.update(dtSim, telemetry)
  if not current or current.status~='ACTIVE' then return false end; local dt=tonumber(dtSim); if not finite(dt) or dt<=0 then return false end
  current.sceneTime=current.sceneTime+dt; if current.frameLevel then poll(current, telemetry); return true end; current.accumulator=current.accumulator+dt; local n=0
  while current.accumulator>=current.pollInterval and n<MAX_POLLS_PER_UPDATE do current.accumulator=current.accumulator-current.pollInterval; poll(current,telemetry); n=n+1 end
  if n==MAX_POLLS_PER_UPDATE and current.accumulator>=current.pollInterval then current.accumulator=0 end; return n>0
end
function M.stopSession(reason)
  if not current then return false end; for _,e in ipairs(current.events) do finish(current,e,current.sceneTime,'session_stop') end; current.status=tostring(reason or 'STOPPED');current.stoppedAtSceneTime=current.sceneTime;emit(current,'INFO','collision_observer_stopped','Collision observer stopped',{sessionId=current.sessionId,reason=current.status});lastReport=snapshot(current);current=nil;return true
end
function M.clear() current=nil;lastReport=nil;return true end
function M.getReport() return snapshot(current) or copy(lastReport) end
function M.getEvents() local r=M.getReport();return r and r.events or {} end
function M.getSummary() local r=M.getReport();if not r then return nil end; r.events=nil;return r end
return M
