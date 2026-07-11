-- Runtime telemetry file export.  This module only consumes immutable reports.
local M = {}

local FORMAT_VERSION = 2
local VIRTUAL_DIRECTORY = '/random_incident_generator/telemetry/'
local lastResult = nil

local function finite(v) return type(v) == 'number' and v == v and v ~= math.huge and v ~= -math.huge end
local function scalar(v) return type(v) == 'string' or type(v) == 'boolean' or finite(v) end
local function copy(v, seen)
  local t = type(v)
  if t == 'nil' or t == 'string' or t == 'boolean' then return v end
  if t == 'number' then return finite(v) and v or nil end
  if t ~= 'table' then return nil end
  seen = seen or {}; if seen[v] then return nil end; seen[v] = true
  local r = {}; for k, item in pairs(v) do if type(k) == 'string' or type(k) == 'number' then r[k] = copy(item, seen) end end
  seen[v] = nil; return r
end
local function safeSessionId(id)
  return type(id) == 'string' and id ~= '' and not id:find('..', 1, true) and not id:find('[\\/]') and not id:find('^%a:') and not id:find('[%c]') and id:match('^[%w_-]+$') ~= nil
end
local function json(value)
  if jsonEncode then return jsonEncode(value) end
  local t = type(value)
  if value == nil then return 'null' end
  if t == 'boolean' then return value and 'true' or 'false' end
  if t == 'number' then return finite(value) and string.format('%.17g', value) or 'null' end
  if t == 'string' then return '"' .. value:gsub('[%z\1-\31\\"]', function(c) local b = string.byte(c); if c == '\\' then return '\\\\' elseif c == '"' then return '\\"' end return string.format('\\u%04x', b) end) .. '"' end
  local array, n = true, 0; for k in pairs(value) do if type(k) ~= 'number' or k < 1 or k % 1 ~= 0 then array = false; break end if k > n then n = k end end
  local out = {}; if array then for i = 1, n do out[i] = json(value[i]) end; return '[' .. table.concat(out, ',') .. ']' end
  for k, v in pairs(value) do table.insert(out, json(tostring(k)) .. ':' .. json(v)) end; table.sort(out); return '{' .. table.concat(out, ',') .. '}'
end
local function failure(code, step, message, sessionId)
  local r = {ok=false, code=code, failedStep=step, message=message, sessionId=sessionId}; lastResult = r; return r
end
local function buildSnapshot(report)
  if type(report) ~= 'table' then return nil, failure('NO_REPORT', 'validate_report', 'No runtime telemetry report is available') end
  if not safeSessionId(report.sessionId) then return nil, failure('UNSAFE_SESSION_ID', 'validate_session_id', 'Telemetry sessionId is unsafe for a filename', report.sessionId) end
  if #(report.actors or {}) == 0 or #(report.samples or {}) == 0 then return nil, failure('EMPTY_REPORT', 'validate_report', 'Telemetry report has no actors or samples', report.sessionId) end
  local actors, samples, summaries, collisions = {}, {}, {}, {}
  for i, a in ipairs(report.actors or {}) do actors[i] = {actor=tostring(a.label or a.actor or ''), objectId=finite(a.objectId) and a.objectId or nil, role=tostring(a.role or ''), ambient=a.ambient == true} end
  for i, s in ipairs(report.samples or {}) do samples[i] = {sceneTime=finite(s.sceneTime) and s.sceneTime or nil, actor=tostring(s.actor or ''), objectId=finite(s.objectId) and s.objectId or nil, role=tostring(s.role or ''), ambient=s.ambient == true, exists=s.exists == true, position=copy(s.position), velocity=copy(s.velocity), speedMps=finite(s.speedMps) and s.speedMps or nil, accelerationMps2=finite(s.accelerationMps2) and s.accelerationMps2 or nil, forward=copy(s.forward), controllerState=(type(s.controllerState) == 'string' or type(s.controllerState) == 'number' or type(s.controllerState) == 'boolean') and s.controllerState or nil} end
  for i, a in ipairs(report.actorSummaries or {}) do summaries[i] = {actor=tostring(a.actor or ''), objectId=finite(a.objectId) and a.objectId or nil, sampleCount=tonumber(a.sampleCount) or 0, missingSampleCount=tonumber(a.missingSampleCount) or 0, firstSceneTime=finite(a.firstSceneTime) and a.firstSceneTime or nil, lastSceneTime=finite(a.lastSceneTime) and a.lastSceneTime or nil, initialSpeedMps=finite(a.initialSpeedMps) and a.initialSpeedMps or nil, finalSpeedMps=finite(a.finalSpeedMps) and a.finalSpeedMps or nil, minSpeedMps=finite(a.minSpeedMps) and a.minSpeedMps or nil, maxSpeedMps=finite(a.maxSpeedMps) and a.maxSpeedMps or nil, maxAccelerationMps2=finite(a.maxAccelerationMps2) and a.maxAccelerationMps2 or nil, maxDecelerationMps2=finite(a.maxDecelerationMps2) and a.maxDecelerationMps2 or nil, approximateDistanceMeters=finite(a.approximateDistanceMeters) and a.approximateDistanceMeters or 0} end
  for i, e in ipairs(report.collisionEvents or {}) do
    collisions[i] = {formatVersion=FORMAT_VERSION,eventId=tostring(e.eventId or ''),sessionId=report.sessionId,state=tostring(e.state or ''),pairKey=tostring(e.pairKey or ''),actorA=tostring(e.actorA or ''),actorB=tostring(e.actorB or ''),objectIdA=finite(e.objectIdA) and e.objectIdA or nil,objectIdB=finite(e.objectIdB) and e.objectIdB or nil,roleA=tostring(e.roleA or ''),roleB=tostring(e.roleB or ''),ambientA=e.ambientA==true,ambientB=e.ambientB==true,startedAtSceneTime=finite(e.startedAtSceneTime) and e.startedAtSceneTime or nil,lastObservedAtSceneTime=finite(e.lastObservedAtSceneTime) and e.lastObservedAtSceneTime or nil,endedAtSceneTime=finite(e.endedAtSceneTime) and e.endedAtSceneTime or nil,durationSeconds=finite(e.durationSeconds) and e.durationSeconds or nil,observationCount=tonumber(e.observationCount) or 0,sources=copy(e.sources) or {objectCollisions=false,crashDetection=false},firstPositionA=copy(e.firstPositionA),firstPositionB=copy(e.firstPositionB),latestPositionA=copy(e.latestPositionA),latestPositionB=copy(e.latestPositionB),firstSpeedAMps=finite(e.firstSpeedAMps) and e.firstSpeedAMps or nil,firstSpeedBMps=finite(e.firstSpeedBMps) and e.firstSpeedBMps or nil,latestSpeedAMps=finite(e.latestSpeedAMps) and e.latestSpeedAMps or nil,latestSpeedBMps=finite(e.latestSpeedBMps) and e.latestSpeedBMps or nil,firstRelativeSpeedMps=finite(e.firstRelativeSpeedMps) and e.firstRelativeSpeedMps or nil,maxRelativeSpeedMps=finite(e.maxRelativeSpeedMps) and e.maxRelativeSpeedMps or nil,firstClosingSpeedMps=finite(e.firstClosingSpeedMps) and e.firstClosingSpeedMps or nil,maxClosingSpeedMps=finite(e.maxClosingSpeedMps) and e.maxClosingSpeedMps or nil,stateSource=tostring(e.stateSource or 'partial'),firstStateSourceA=tostring(e.firstStateSourceA or 'partial'),firstStateSourceB=tostring(e.firstStateSourceB or 'partial'),latestStateSourceA=tostring(e.latestStateSourceA or 'partial'),latestStateSourceB=tostring(e.latestStateSourceB or 'partial'),controllerStateA=scalar(e.controllerStateA) and e.controllerStateA or nil,controllerStateB=scalar(e.controllerStateB) and e.controllerStateB or nil}
  end
  return {sessionId=report.sessionId, scenarioId=report.scenarioId, seed=report.seed, status=report.status, startedAtSceneTime=report.startedAtSceneTime, stoppedAtSceneTime=report.stoppedAtSceneTime, sampleInterval=report.sampleInterval, actorCount=#actors, sampleCount=#samples, collisionEventCount=#collisions, droppedSampleCount=tonumber(report.droppedSampleCount) or 0, invalidFieldCount=tonumber(report.invalidFieldCount) or 0, actors=actors, samples=samples, collisionEvents=collisions, actorSummaries=summaries}
end
local function number(v) return finite(v) and string.format('%.3f', v) or 'n/a' end
function M.render(report, metadata)
  local snapshot, err = buildSnapshot(report); if not snapshot then return nil, err end
  metadata = metadata or {}; local exportedAt = metadata.exportedAt or os.date('!%Y-%m-%dT%H:%M:%SZ'); local exportCount = tonumber(metadata.exportCount) or 1
  local lines = {json({recordType='session', formatVersion=FORMAT_VERSION, sessionId=snapshot.sessionId, scenarioId=snapshot.scenarioId, seed=snapshot.seed, status=snapshot.status, startedAtSceneTime=snapshot.startedAtSceneTime, stoppedAtSceneTime=snapshot.stoppedAtSceneTime, sampleInterval=snapshot.sampleInterval, actorCount=snapshot.actorCount, actors=snapshot.actors})}
  for _, s in ipairs(snapshot.samples) do s.recordType='sample'; s.sessionId=snapshot.sessionId; table.insert(lines, json(s)) end
  for _, e in ipairs(snapshot.collisionEvents) do e.recordType='collision_event'; table.insert(lines, json(e)) end
  for _, s in ipairs(snapshot.actorSummaries) do s.recordType='actor_summary'; s.sessionId=snapshot.sessionId; table.insert(lines, json(s)) end
  table.insert(lines, json({recordType='summary', formatVersion=FORMAT_VERSION, sessionId=snapshot.sessionId, actorCount=snapshot.actorCount, sampleCount=snapshot.sampleCount, collisionEventCount=snapshot.collisionEventCount, droppedSampleCount=snapshot.droppedSampleCount, invalidFieldCount=snapshot.invalidFieldCount, exportedAt=exportedAt, exportCount=exportCount}))
  local duration = (finite(snapshot.stoppedAtSceneTime) and finite(snapshot.startedAtSceneTime)) and snapshot.stoppedAtSceneTime - snapshot.startedAtSceneTime or 'active'
  local txt = {'Runtime Telemetry Summary', '=========================', '', '1. Session', 'sessionId: ' .. snapshot.sessionId, 'scenarioId: ' .. tostring(snapshot.scenarioId), 'seed: ' .. tostring(snapshot.seed), 'status: ' .. tostring(snapshot.status), 'startedAtSceneTime: ' .. number(snapshot.startedAtSceneTime), 'stoppedAtSceneTime: ' .. number(snapshot.stoppedAtSceneTime), 'duration: ' .. (type(duration) == 'number' and number(duration) or duration), 'sampleInterval: ' .. number(snapshot.sampleInterval), '', '2. Totals', 'actorCount: ' .. snapshot.actorCount, 'sampleCount: ' .. snapshot.sampleCount, 'droppedSampleCount: ' .. snapshot.droppedSampleCount, 'invalidFieldCount: ' .. snapshot.invalidFieldCount, '', '3. Actor Summaries'}
  for _, a in ipairs(snapshot.actorSummaries) do table.insert(txt, tostring(a.actor)); table.insert(txt, '  objectId: ' .. tostring(a.objectId)); table.insert(txt, '  role: ' .. tostring((snapshot.actors[_] or {}).role)); table.insert(txt, '  samples: ' .. a.sampleCount); table.insert(txt, '  missing: ' .. a.missingSampleCount); table.insert(txt, '  initial speed: ' .. number(a.initialSpeedMps)); table.insert(txt, '  final speed: ' .. number(a.finalSpeedMps)); table.insert(txt, '  min speed: ' .. number(a.minSpeedMps)); table.insert(txt, '  max speed: ' .. number(a.maxSpeedMps)); table.insert(txt, '  max acceleration: ' .. number(a.maxAccelerationMps2)); table.insert(txt, '  max deceleration: ' .. number(a.maxDecelerationMps2)); table.insert(txt, '  approximate distance: ' .. number(a.approximateDistanceMeters)) end
  table.insert(txt, ''); table.insert(txt, '4. Collision Events')
  if #snapshot.collisionEvents == 0 then table.insert(txt, '(none)') end
  for i, e in ipairs(snapshot.collisionEvents) do table.insert(txt, 'Collision ' .. i); table.insert(txt, '  eventId: ' .. e.eventId); table.insert(txt, '  actors: ' .. e.actorA .. ' / ' .. e.actorB); table.insert(txt, '  object IDs: ' .. tostring(e.objectIdA) .. ' / ' .. tostring(e.objectIdB)); table.insert(txt, '  state: ' .. e.state); table.insert(txt, '  start: ' .. number(e.startedAtSceneTime)); table.insert(txt, '  end: ' .. number(e.endedAtSceneTime)); table.insert(txt, '  duration: ' .. number(e.durationSeconds)); table.insert(txt, '  observations: ' .. e.observationCount); table.insert(txt, '  max relative speed: ' .. number(e.maxRelativeSpeedMps)); table.insert(txt, '  max closing speed: ' .. number(e.maxClosingSpeedMps)); table.insert(txt, '  first state source: A=' .. e.firstStateSourceA .. ' B=' .. e.firstStateSourceB); table.insert(txt, '  latest state source: A=' .. e.latestStateSourceA .. ' B=' .. e.latestStateSourceB); table.insert(txt, '  sources: objectCollisions=' .. tostring(e.sources.objectCollisions) .. ' crashDetection=' .. tostring(e.sources.crashDetection)) end
  table.insert(txt, ''); table.insert(txt, '5. Export Metadata'); table.insert(txt, 'exportedAt: ' .. exportedAt); table.insert(txt, 'jsonlPath: ' .. tostring(metadata.jsonlPath or '')); table.insert(txt, 'txtPath: ' .. tostring(metadata.txtPath or '')); table.insert(txt, 'writeBackend: sandboxed_io_open'); table.insert(txt, 'formatVersion: ' .. FORMAT_VERSION); table.insert(txt, 'exportCount: ' .. exportCount)
  return {snapshot=snapshot, jsonl=table.concat(lines, '\n') .. '\n', txt=table.concat(txt, '\n') .. '\n', exportedAt=exportedAt, exportCount=exportCount}
end
local function remove(path) if FS and FS.removeFile then pcall(function() FS:removeFile(path) end) end end
local function writeAtomic(temp, final, content, physical, prefix)
  local f = io.open(temp, 'w'); if not f then return failure(prefix .. '_OPEN_FAILED', prefix:lower() .. '_open', 'Unable to open export temporary file') end
  local ok = pcall(function() f:write(content) end); local closed = pcall(function() f:close() end)
  if not ok or not closed then remove(temp); return failure(prefix .. (ok and '_CLOSE_FAILED' or '_WRITE_FAILED'), prefix:lower() .. (ok and '_close' or '_write'), 'Unable to write export temporary file') end
  local existsOk, exists = pcall(function() return FS:fileExists(temp) end); if not existsOk or exists ~= true then remove(temp); return failure(prefix .. '_VERIFY_FAILED', prefix:lower() .. '_verify_temp', 'Temporary export file was not visible through VFS') end
  local renameOk, renameResult = pcall(function() return FS:renameFile(temp, final) end); if not renameOk or (renameResult ~= 0 and renameResult ~= true) then remove(temp); return failure(prefix .. '_COMMIT_FAILED', prefix:lower() .. '_rename', 'Unable to atomically commit export file') end
  local finalOk, finalExists = pcall(function() return FS:fileExists(final) end); if not finalOk or finalExists ~= true then return failure(prefix .. '_VERIFY_FAILED', prefix:lower() .. '_verify_final', 'Final export file was not visible through VFS') end
  return true
end
function M.export(report, options)
  options = options or {}; if not FS or not FS.directoryCreate or not FS.directoryExists or not FS.fileExists or not FS.renameFile or not FS.removeFile or not FS.getUserPath then return failure('FS_API_UNAVAILABLE', 'validate_fs_api', 'BeamNG filesystem API is unavailable') end
  local sessionId = report and report.sessionId; if not safeSessionId(sessionId) then return failure('UNSAFE_SESSION_ID', 'validate_session_id', 'Telemetry sessionId is unsafe for a filename', sessionId) end
  local userOk, userPath = pcall(function() return FS:getUserPath() end); if not userOk or type(userPath) ~= 'string' or userPath == '' then return failure('USER_PATH_UNAVAILABLE', 'resolve_user_path', 'BeamNG user path is unavailable', sessionId) end
  local dirOk = pcall(function() return FS:directoryCreate(VIRTUAL_DIRECTORY, true) end); local existsOk, exists = pcall(function() return FS:directoryExists(VIRTUAL_DIRECTORY) end); if not dirOk or not existsOk or exists ~= true then return failure('DIRECTORY_CREATE_FAILED', 'create_directory', 'Unable to create telemetry directory', sessionId) end
  local displayDir = userPath:gsub('\\', '/') .. (userPath:sub(-1) == '/' and '' or '/') .. 'random_incident_generator/telemetry/'
  local jsonName, txtName = 'telemetry_' .. sessionId .. '.jsonl', 'telemetry_' .. sessionId .. '_summary.txt'; local count = (tonumber(options.exportCount) or 0) + 1
  local rendered, err = M.render(report, {exportedAt=options.exportedAt, exportCount=count, jsonlPath=displayDir .. jsonName, txtPath=displayDir .. txtName}); if not rendered then return err end
  local jsonVirtual, txtVirtual = VIRTUAL_DIRECTORY .. jsonName, VIRTUAL_DIRECTORY .. txtName
  local jsonOk = writeAtomic(jsonVirtual .. '.tmp', jsonVirtual, rendered.jsonl, displayDir .. jsonName, 'JSONL'); if not jsonOk then lastResult.sessionId = sessionId; return lastResult end
  local txtOk = writeAtomic(txtVirtual .. '.tmp', txtVirtual, rendered.txt, displayDir .. txtName, 'TXT'); if not txtOk then lastResult.sessionId = sessionId; return lastResult end
  lastResult = {ok=true, sessionId=sessionId, scenarioId=rendered.snapshot.scenarioId, seed=rendered.snapshot.seed, actorCount=rendered.snapshot.actorCount, sampleCount=rendered.snapshot.sampleCount, collisionEventCount=rendered.snapshot.collisionEventCount, droppedSampleCount=rendered.snapshot.droppedSampleCount, invalidFieldCount=rendered.snapshot.invalidFieldCount, jsonlPath=displayDir .. jsonName, txtPath=displayDir .. txtName, jsonlVirtualPath=jsonVirtual, txtVirtualPath=txtVirtual, writeBackend='sandboxed_io_open', exportCount=count, exportedAt=rendered.exportedAt}
  return copy(lastResult)
end
function M.getLastResult() return copy(lastResult) end
function M.clearLastResult() lastResult = nil end
return M
