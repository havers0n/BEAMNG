local M = {}

local LEVELS = {DEBUG = 10, INFO = 20, WARN = 30, ERROR = 40}
local LEVEL_NAMES = {[10] = 'DEBUG', [20] = 'INFO', [30] = 'WARN', [40] = 'ERROR'}
local MAX_EVENTS = 4000
local MAX_COMMAND = 16384
local COALESCE_WINDOW = 8
local sequence = 0
local current = nil
local lastSession = nil
local consoleLevel = LEVELS.INFO
local captureLevel = LEVELS.DEBUG
local nativeLog = _G.log

local function nowString()
  local t = os.date('*t')
  return string.format('%04d%02d%02d_%02d%02d%02d', t.year, t.month, t.day, t.hour, t.min, t.sec)
end

local function normalizeLevel(level)
  if type(level) ~= 'string' then return nil end
  local name = string.upper(level)
  return LEVELS[name] and name or nil
end

local function copy(value, depth, seen)
  if depth > 4 then return '<max-depth>' end
  local kind = type(value)
  if kind == 'nil' or kind == 'string' or kind == 'number' or kind == 'boolean' then
    if kind == 'number' and (value ~= value or value == math.huge or value == -math.huge) then return tostring(value) end
    return value
  end
  if kind ~= 'table' then return '<' .. kind .. '>' end
  seen = seen or {}
  if seen[value] then return '<cycle>' end
  seen[value] = true
  local result = {}
  for key, item in pairs(value) do
    local safeKey = type(key) == 'string' and key or tostring(key)
    result[safeKey] = copy(item, depth + 1, seen)
  end
  seen[value] = nil
  return result
end

local function countLevel(session, level)
  session.counters = session.counters or {}
  local key = LEVEL_NAMES[level] .. 'Count'
  session.counters[key] = (session.counters[key] or 0) + 1
end

local function eventKey(category, eventType, fields)
  return tostring(category) .. ':' .. tostring(eventType) .. ':' .. tostring(fields and (fields.actor or fields.label) or '')
end

local function removeOldestDebug(session)
  for index, event in ipairs(session.events) do
    if event.level == 'DEBUG' then table.remove(session.events, index); return true end
  end
  return false
end

local function addEvent(session, event)
  if #session.events >= MAX_EVENTS and not removeOldestDebug(session) then
    if event.level == 'DEBUG' then
      session.counters.droppedEvents = (session.counters.droppedEvents or 0) + 1
      return
    end
    table.remove(session.events, 1)
    session.counters.droppedEvents = (session.counters.droppedEvents or 0) + 1
  end
  table.insert(session.events, event)
end

local function archive(status)
  if not current then return end
  if status then current.status = status end
  lastSession = copy(current, 0)
  current = nil
end

function M.beginSession(meta, parentSessionId, isRepeat)
  if current then
    local previousStatus = current.status
    if previousStatus == 'GENERATED' or previousStatus == 'RUNNING' then previousStatus = 'COMPLETED' end
    archive(previousStatus)
  end
  sequence = sequence + 1
  local seed = meta and meta.seed
  local seedPart = seed ~= nil and ('_seed' .. tostring(seed):gsub('[^%w%-]', '_')) or ''
  local sessionId = nowString() .. seedPart .. string.format('_%03d', sequence)
  current = {
    sessionId = sessionId, parentSessionId = parentSessionId, createdAt = os.date('!%Y-%m-%dT%H:%M:%SZ'),
    mapName = meta and meta.mapName or nil, seed = seed, scenarioId = meta and meta.scenarioId or nil,
    scenarioVersion = meta and meta.scenarioVersion or nil, phase = meta and meta.phase or nil,
    modVersion = '2.3.3', status = isRepeat and 'REPEATED' or 'CREATED', sceneTime = 0,
    events = {}, counters = {DEBUGCount = 0, INFOCount = 0, WARNCount = 0, ERRORCount = 0, droppedEvents = 0, triggerCount = 0},
    actors = {}, lastVehicleCommands = {}, export = {}, _coalesced = {}
  }
  M.log(isRepeat and 'INFO' or 'INFO', 'lifecycle', 'session_created', isRepeat and 'Diagnostic repeat session created' or 'Diagnostic session created', {sessionId = sessionId, parentSessionId = parentSessionId})
  return current
end

function M.setStatus(status)
  if not current then return false end
  local allowed = {CREATED=true, GENERATING=true, GENERATED=true, RUNNING=true, COMPLETED=true, FAILED=true, RESET=true, REPEATED=true, UNLOADED=true}
  if not allowed[status] then return false end
  current.status = status
  return true
end

function M.setSceneTime(value)
  if current then current.sceneTime = tonumber(value) or current.sceneTime or 0 end
end
function M.updateMetadata(meta)
  if not current or type(meta) ~= 'table' then return false end
  for key, value in pairs(meta) do if current[key] ~= nil or key == 'mapName' or key == 'scenarioVersion' or key == 'phase' then current[key] = copy(value, 0) end end
  return true
end

function M.log(level, category, eventType, message, fields)
  local normalized = normalizeLevel(level) or 'INFO'
  local numeric = LEVELS[normalized]
  local safeFields = copy(fields or {}, 0)
  if current and numeric >= captureLevel then
    local key = eventKey(category, eventType, safeFields)
    local coalesce = normalized == 'DEBUG' and (eventType == 'following_speed_sync' or eventType == 'following_speed_sync_detail')
    if coalesce then
      local previous = current._coalesced[key]
      if previous and (current.sceneTime - (previous.lastTime or 0)) <= COALESCE_WINDOW then
        previous.lastTime = current.sceneTime; previous.count = previous.count + 1
        previous.lastValue = safeFields.value or safeFields.speed or previous.lastValue
        previous.minValue = math.min(previous.minValue or previous.lastValue or 0, tonumber(safeFields.value or safeFields.speed) or previous.minValue or 0)
        previous.maxValue = math.max(previous.maxValue or previous.lastValue or 0, tonumber(safeFields.value or safeFields.speed) or previous.maxValue or 0)
      else
        local record = {recordType='coalescedDebug', level='DEBUG', category=category, eventType=eventType, actor=safeFields.actor, firstTime=current.sceneTime, lastTime=current.sceneTime, count=1, firstValue=safeFields.value or safeFields.speed, lastValue=safeFields.value or safeFields.speed, minValue=tonumber(safeFields.value or safeFields.speed), maxValue=tonumber(safeFields.value or safeFields.speed)}
        current._coalesced[key] = record
        addEvent(current, record)
      end
    else
      addEvent(current, {recordType='event', level=normalized, category=tostring(category or 'general'), eventType=tostring(eventType or 'message'), message=tostring(message or ''), sceneTime=current.sceneTime, fields=safeFields})
    end
    countLevel(current, numeric)
  end
  if numeric >= consoleLevel and nativeLog then pcall(nativeLog, normalized:sub(1, 1), 'randomIncidents', tostring(message or '')) end
end

function M.setConsoleLogLevel(level)
  local name = normalizeLevel(level)
  if not name then return false, 'Invalid log level; expected DEBUG, INFO, WARN, or ERROR' end
  consoleLevel = LEVELS[name]; return name
end
function M.getConsoleLogLevel() return LEVEL_NAMES[consoleLevel] end
function M.setDiagnosticCaptureLevel(level)
  local name = normalizeLevel(level)
  if not name then return false, 'Invalid log level; expected DEBUG, INFO, WARN, or ERROR' end
  captureLevel = LEVELS[name]; return name
end
function M.getDiagnosticCaptureLevel() return LEVEL_NAMES[captureLevel] end

function M.registerActor(actor)
  if not current or not actor then return false end
  local objectId = nil
  if actor.vehicle and actor.vehicle.getID then pcall(function() objectId = actor.vehicle:getID() end) end
  table.insert(current.actors, {label=tostring(actor.label), role=tostring(actor.role or ''), objectId=tonumber(objectId), model=tostring(actor.model or ''), ambient=actor.isAmbient == true, initialSpeed=tonumber(actor.speedMps) or 0, lane=tonumber(actor.laneChoice), spawnPosition=copy(actor.initialPosition or {}, 0)})
  return true
end

function M.recordCommand(actor, objectId, context, command)
  if not current then return end
  local text = tostring(command or '')
  if #text > MAX_COMMAND then text = text:sub(1, MAX_COMMAND) .. '\n<command truncated>' end
  current.lastVehicleCommands[tostring(actor or '?')] = {actor=tostring(actor or '?'), objectId=tonumber(objectId), sceneTime=current.sceneTime, context=tostring(context or ''), command=text}
end

function M.recordTrigger() if current then current.counters.triggerCount = (current.counters.triggerCount or 0) + 1 end end
function M.finish(status) if current then archive(status or current.status) end end

local function getSession() return current or lastSession end
function M.getLastSessionReport()
  local session = getSession(); if not session then return nil end
  local result = copy(session, 0); result._coalesced = nil; return result
end

local function normalizeFsPath(path)
  path = tostring(path or ''):gsub('\\', '/')
  path = path:gsub('/+', '/')
  if path:match('^%a:/$') then return path end
  return path:gsub('/+$', '')
end

local function joinFsPath(base, ...)
  local result = normalizeFsPath(base)
  for _, segment in ipairs({...}) do
    local cleanSegment = tostring(segment or ''):gsub('^/+', ''):gsub('/+$', '')
    if cleanSegment ~= '' then result = result .. '/' .. cleanSegment end
  end
  return normalizeFsPath(result)
end

local function isWithinUserPath(path, base)
  local lowerPath, lowerBase = string.lower(normalizeFsPath(path)), string.lower(normalizeFsPath(base))
  return lowerPath == lowerBase or lowerPath:sub(1, #lowerBase + 1) == lowerBase .. '/'
end

local function pathError(code, normalizedPath, baseUserPath, failedStep, message)
  return {ok=false, code=code, normalizedPath=normalizedPath, baseUserPath=baseUserPath, failedStep=failedStep, message=message}
end

local function pathProbe(message, fields)
  M.log('DEBUG', 'export', 'export_path_probe', message, fields)
end

local function ensureDirectory(path, baseUserPath, failedStep)
  local info = {path=path, existsBefore=false, createResult='not_called', existsAfter=false}
  local existsBefore = false
  local existsOk, existsResult = pcall(function() return FS:directoryExists(path) end)
  if existsOk then existsBefore = existsResult == true end
  info.existsBefore = existsBefore
  pathProbe(string.format('Export path step=%s path=%s directoryExistsBefore=%s', failedStep, path, tostring(existsBefore)), {path=path, directoryExistsBefore=existsBefore, step=failedStep})
  if existsBefore then info.existsAfter = true; return true, nil, info end

  local createOk, createResult = pcall(function() return FS:directoryCreate(path, true) end)
  info.createResult = createResult
  local existsAfterOk, existsAfterResult = pcall(function() return FS:directoryExists(path) end)
  local existsAfter = existsAfterOk and existsAfterResult == true
  info.existsAfter = existsAfter
  pathProbe(string.format('Export path step=%s path=%s directoryCreateResult=%s directoryExistsAfter=%s', failedStep, path, tostring(createResult), tostring(existsAfter)), {path=path, directoryCreateResult=createResult, directoryExistsAfter=existsAfter, step=failedStep})
  if existsAfter then return true, nil, info end
  local reason = createOk and ('directoryCreate result=' .. tostring(createResult)) or ('directoryCreate exception=' .. tostring(createResult))
  return false, pathError('DIRECTORY_CREATE_FAILED', path, baseUserPath, failedStep, 'Unable to create diagnostic directory: ' .. reason), info
end

local function buildExportPaths(sessionId, report)
  local rawBase = nil
  local baseOk, baseResult = pcall(function() return FS and FS:getUserPath() end)
  if baseOk then rawBase = baseResult end
  local baseUserPath = normalizeFsPath(rawBase)
  local parentPath = baseUserPath ~= '' and joinFsPath(baseUserPath, 'random_incident_generator') .. '/' or ''
  local exportDirectory = parentPath ~= '' and joinFsPath(parentPath, 'logs') .. '/' or ''
  report = report or {}
  report.rawUserPath = rawBase
  report.normalizedUserPath = baseUserPath
  report.parentPath = parentPath
  report.logsPath = exportDirectory
  pathProbe(string.format('Export path rawUserPath=%s normalizedUserPath=%s exportDirectory=%s', tostring(rawBase), baseUserPath, exportDirectory), {rawUserPath=rawBase, normalizedUserPath=baseUserPath, exportDirectory=exportDirectory})
  if not baseOk or baseUserPath == '' then return nil, pathError('USER_PATH_UNAVAILABLE', exportDirectory, baseUserPath, 'resolve_user_path', 'BeamNG user path is unavailable') end
  if not isWithinUserPath(parentPath, baseUserPath) or not isWithinUserPath(exportDirectory, baseUserPath) then return nil, pathError('PATH_OUTSIDE_USER_PATH', exportDirectory, baseUserPath, 'validate_path', 'Diagnostic export path is outside BeamNG user path') end
  if not FS or not FS.directoryExists or not FS.directoryCreate then return nil, pathError('FS_API_UNAVAILABLE', exportDirectory, baseUserPath, 'validate_fs_api', 'BeamNG filesystem API is unavailable') end

  local parentOk, parentError, parentInfo = ensureDirectory(parentPath, baseUserPath, 'create_parent')
  report.parentExistsBefore = parentInfo and parentInfo.existsBefore or false
  report.parentCreateResult = parentInfo and parentInfo.createResult or 'not_called'
  report.parentExistsAfter = parentInfo and parentInfo.existsAfter or false
  if not parentOk then return nil, parentError end
  local exportOk, exportError, logsInfo = ensureDirectory(exportDirectory, baseUserPath, 'create_export_directory')
  report.logsExistsBefore = logsInfo and logsInfo.existsBefore or false
  report.logsCreateResult = logsInfo and logsInfo.createResult or 'not_called'
  report.logsExistsAfter = logsInfo and logsInfo.existsAfter or false
  if not exportOk then return nil, exportError end
  local safeSessionId = tostring(sessionId or ''):gsub('[^%w%-_]', '_')
  return exportDirectory .. 'randomIncidents_' .. safeSessionId .. '.txt', exportDirectory .. 'randomIncidents_' .. safeSessionId .. '.jsonl'
end

function M.testDiagnosticExportPath()
  local report = {}
  local txtPath, errorResult = buildExportPaths('path_self_check', report)
  if not txtPath then
    report.ok = false
    report.code = errorResult and errorResult.code or 'PATH_UNAVAILABLE'
    report.normalizedPath = errorResult and errorResult.normalizedPath or report.logsPath
    report.baseUserPath = errorResult and errorResult.baseUserPath or report.normalizedUserPath
    report.failedStep = errorResult and errorResult.failedStep or 'unknown'
    report.message = errorResult and errorResult.message or 'Unable to prepare diagnostic export path'
    return report
  end
  report.ok = true
  return report
end

local function textReport(session)
  local c = session.counters or {}
  local out = {'Random Incident Generator Diagnostic Session', '============================================', '1. Header', 'sessionId: ' .. tostring(session.sessionId), 'status: ' .. tostring(session.status), 'createdAt: ' .. tostring(session.createdAt), 'modVersion: ' .. tostring(session.modVersion), '', '2. Scenario', 'scenarioId: ' .. tostring(session.scenarioId), 'scenarioVersion: ' .. tostring(session.scenarioVersion), 'phase: ' .. tostring(session.phase), 'seed: ' .. tostring(session.seed), '', '3. Environment', 'map: ' .. tostring(session.mapName), 'sceneTime: ' .. tostring(session.sceneTime), '', '4. Actors'}
  for _, actor in ipairs(session.actors or {}) do table.insert(out, string.format('%s role=%s objectId=%s model=%s ambient=%s speed=%.2f lane=%s position=%s', actor.label, actor.role, tostring(actor.objectId), actor.model, tostring(actor.ambient), actor.initialSpeed, tostring(actor.lane), jsonEncode(actor.spawnPosition))) end
  table.insert(out, ''); table.insert(out, '5. Important Timeline');
  for _, event in ipairs(session.events or {}) do if event.level ~= 'DEBUG' then table.insert(out, string.format('[%s] t=%.3f %s/%s: %s %s', event.level, event.sceneTime or 0, event.category, event.eventType, event.message or '', jsonEncode(event.fields or {}))) end end
  for _, section in ipairs({'6. Trigger Events', '7. Controller Transitions', '8. Warnings and Errors', '9. Last Vehicle Lua Commands', '10. Coalesced Debug Summary', '11. Counters', '12. Export Metadata'}) do table.insert(out, ''); table.insert(out, section) end
  for _, event in ipairs(session.events or {}) do if event.recordType == 'coalescedDebug' then table.insert(out, string.format('%s/%s actor=%s count=%d first=%.3f last=%.3f firstValue=%s lastValue=%s min=%s max=%s', event.category, event.eventType, tostring(event.actor), event.count, event.firstTime or 0, event.lastTime or 0, tostring(event.firstValue), tostring(event.lastValue), tostring(event.minValue), tostring(event.maxValue))) end end
  for actor, command in pairs(session.lastVehicleCommands or {}) do table.insert(out, string.format('%s objectId=%s context=%s sceneTime=%.3f\n%s', actor, tostring(command.objectId), command.context, command.sceneTime or 0, command.command)) end
  table.insert(out, string.format('events=%d DEBUG=%d INFO=%d WARN=%d ERROR=%d droppedEvents=%d triggerCount=%d', #session.events, c.DEBUGCount or 0, c.INFOCount or 0, c.WARNCount or 0, c.ERRORCount or 0, c.droppedEvents or 0, c.triggerCount or 0))
  return table.concat(out, '\n') .. '\n'
end

function M.exportLastSession()
  local session = lastSession or current
  if not session then return {ok=false, code='NO_SESSION', message='No diagnostic session is available'} end
  local txtPath, jsonlPath = buildExportPaths(session.sessionId)
  if not txtPath then return jsonlPath end
  local txtTemp, jsonlTemp = txtPath .. '.tmp', jsonlPath .. '.tmp'
  local txt = io.open(txtTemp, 'w'); if not txt then return {ok=false, code='TXT_OPEN_FAILED', message='Unable to open TXT export'} end
  txt:write(textReport(session)); txt:close()
  local jsonl = io.open(jsonlTemp, 'w'); if not jsonl then if FS and FS.removeFile then FS:removeFile(txtTemp) end; return {ok=false, code='JSONL_OPEN_FAILED', message='Unable to open JSONL export'} end
  local safe = copy(session, 0); safe.events = nil; safe._coalesced = nil; safe.recordType = 'session'
  jsonl:write(jsonEncode(safe) .. '\n')
  for _, event in ipairs(session.events or {}) do local eventRecord = copy(event, 0); eventRecord.recordType = 'event'; jsonl:write(jsonEncode(eventRecord) .. '\n') end
  jsonl:write(jsonEncode({recordType='summary', sessionId=session.sessionId, counters=copy(session.counters or {}, 0), eventCount=#(session.events or {})}) .. '\n'); jsonl:close()
  if not FS or not FS.renameFile or FS:renameFile(txtTemp, txtPath) ~= 0 then
    if FS and FS.removeFile then FS:removeFile(txtTemp); FS:removeFile(jsonlTemp) end
    return {ok=false, code='TXT_COMMIT_FAILED', message='Unable to commit TXT export'}
  end
  if FS:renameFile(jsonlTemp, jsonlPath) ~= 0 then
    if FS and FS.removeFile then FS:removeFile(jsonlTemp); FS:removeFile(txtPath) end
    return {ok=false, code='JSONL_COMMIT_FAILED', message='Unable to commit JSONL export'}
  end
  session.export = {txtPath=txtPath, jsonlPath=jsonlPath, exportedAt=os.date('!%Y-%m-%dT%H:%M:%SZ')}
  return {ok=true, sessionId=session.sessionId, txtPath=txtPath, jsonlPath=jsonlPath, eventCount=#(session.events or {}), warningCount=session.counters.WARNCount or 0, errorCount=session.counters.ERRORCount or 0}
end

function M.printSummary()
  local session = getSession(); if not session then if nativeLog then pcall(nativeLog, 'W', 'randomIncidents', 'No diagnostic session is available') end; return nil end
  local c = session.counters or {}
  local lines = {'Diagnostic session summary', 'sessionId=' .. tostring(session.sessionId), 'scenario=' .. tostring(session.scenarioId), 'seed=' .. tostring(session.seed), 'map=' .. tostring(session.mapName), 'status=' .. tostring(session.status), string.format('duration=%.3f actorCount=%d triggerCount=%d', session.sceneTime or 0, #(session.actors or {}), c.triggerCount or 0), string.format('warnings=%d errors=%d droppedEvents=%d', c.WARNCount or 0, c.ERRORCount or 0, c.droppedEvents or 0)}
  if session.export and session.export.txtPath then table.insert(lines, 'export=' .. session.export.txtPath) end
  local n = 0; for index = #(session.events or {}), 1, -1 do local e=session.events[index]; if e.level == 'WARN' or e.level == 'ERROR' then table.insert(lines, '['..e.level..'] '..tostring(e.message)); n=n+1; if n >= 5 then break end end end
  for _, line in ipairs(lines) do if nativeLog then pcall(nativeLog, 'I', 'randomIncidents', line) end end
  return copy(session, 0)
end

function M.clearHistory() current=nil; lastSession=nil end
function M.getCurrentSessionId() return current and current.sessionId or nil end
function M.getLastSessionId() return lastSession and lastSession.sessionId or nil end

return M
