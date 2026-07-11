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
local function liveState(s, actor, telemetry)
  local o = objectFor(s, actor.objectId)
  if o then
    local pos, vel = nil, nil
    if o.getPosition then local ok, v = pcall(function() return o:getPosition() end); if ok then pos=vector(v,s) end end
    if o.getVelocity then local ok, v = pcall(function() return o:getVelocity() end); if ok then vel=vector(v,s) end end
    if pos or vel then return pos, vel, 'live_vehicle' end
  end
  local latest = telemetry and telemetry.latestByActor and telemetry.latestByActor[actor.actor]
  if latest then return vector(latest.position, s), vector(latest.velocity, s), 'runtime_telemetry' end
  return nil, nil, 'partial'
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
  local pa, va, sourceA = liveState(s,a,telemetry); local pb, vb, sourceB = liveState(s,b,telemetry)
  local relative, closing = nil, nil
  if va and vb then relative=length({x=va.x-vb.x,y=va.y-vb.y,z=va.z-vb.z}) end
  if pa and pb and va and vb then
    local normal={x=pb.x-pa.x,y=pb.y-pa.y,z=pb.z-pa.z}; local d=length(normal)
    if d and d > 0 then closing=math.max(0, ((va.x-vb.x)*normal.x+(va.y-vb.y)*normal.y+(va.z-vb.z)*normal.z)/d) end
  end
  local stateSource = sourceA == 'live_vehicle' and sourceB == 'live_vehicle' and 'live_vehicle' or ((sourceA == 'runtime_telemetry' or sourceB == 'runtime_telemetry') and 'runtime_telemetry' or 'partial')
  if not e then
    s.nextEventId=s.nextEventId+1
    e={eventId='collision_'..s.sessionId..'_'..s.nextEventId, sessionId=s.sessionId, state='ACTIVE', pairKey=pairKey,
      actorA=a.actor,actorB=b.actor,objectIdA=a.objectId,objectIdB=b.objectId,roleA=a.role,roleB=b.role,ambientA=a.ambient,ambientB=b.ambient,
      startedAtSceneTime=now,lastObservedAtSceneTime=now,endedAtSceneTime=nil,durationSeconds=0,observationCount=0,sources={objectCollisions=true,crashDetection=false},
      firstPositionA=pa,firstPositionB=pb,latestPositionA=pa,latestPositionB=pb,firstSpeedAMps=length(va),firstSpeedBMps=length(vb),latestSpeedAMps=length(va),latestSpeedBMps=length(vb),
      firstRelativeSpeedMps=relative,maxRelativeSpeedMps=relative,firstClosingSpeedMps=closing,maxClosingSpeedMps=closing,stateSource=stateSource,
      controllerStateA=s.controllerStateProvider and s.controllerStateProvider(a.actor,a.objectId) or nil,controllerStateB=s.controllerStateProvider and s.controllerStateProvider(b.actor,b.objectId) or nil}
    addEvent(s,e); s.byPair[pairKey]=e
    emit(s,'INFO','collision_started','Collision episode started',{eventId=e.eventId,pairKey=pairKey,actorA=a.actor,actorB=b.actor})
  else
    e.lastObservedAtSceneTime=now; e.latestPositionA=pa or e.latestPositionA; e.latestPositionB=pb or e.latestPositionB; e.latestSpeedAMps=length(va) or e.latestSpeedAMps; e.latestSpeedBMps=length(vb) or e.latestSpeedBMps; e.stateSource=stateSource
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
    collisionEventCount=#events,activeCollisionCount=active,endedCollisionCount=ended,rawObservationCount=s.rawObservationCount,duplicateObservationCount=s.duplicateObservationCount,ignoredUnknownObjectCount=s.ignoredUnknownObjectCount,unpairedCrashSignalCount=s.unpairedCrashSignalCount,droppedCollisionEventCount=s.droppedCollisionEventCount,invalidFieldCount=s.invalidFieldCount,sourceStatus=copy(s.sourceStatus),events=events}
end
function M.startSession(config)
  if current then M.stopSession('replaced') end; config=type(config)=='table' and config or {}
  local actors, byId={},{}; for _,x in ipairs(config.actors or {}) do local id=tonumber(x.objectId); if id and not byId[id] then local a={actor=tostring(x.actor or x.label or ''),objectId=id,role=tostring(x.role or ''),ambient=x.ambient==true}; actors[#actors+1]=a;byId[id]=a end end
  current={sessionId=tostring(config.sessionId or ''),scenarioId=config.scenarioId,seed=config.seed,status='ACTIVE',startedAtSceneTime=0,stoppedAtSceneTime=nil,sceneTime=0,pollInterval=finite(config.pollInterval) and config.pollInterval>0 and config.pollInterval or DEFAULT_POLL_INTERVAL,frameLevel=config.frameLevel==true,accumulator=0,actors=actors,actorsByObjectId=byId,events={},byPair={},nextEventId=0,rawObservationCount=0,duplicateObservationCount=0,ignoredUnknownObjectCount=0,unpairedCrashSignalCount=0,droppedCollisionEventCount=0,invalidFieldCount=0,diagnostics=config.diagnostics,objectProvider=config.objectProvider,controllerStateProvider=config.controllerStateProvider,sourceAdapter=config.sourceAdapter,sourceStatus={objectCollisionsAvailable=nil,crashDetectionAvailable=false,primarySource='objectCollisions'}}
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
