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

local normalizeCapturedEvent

function M.log(level, category, eventType, message, fields)
  local normalized = normalizeLevel(level) or 'INFO'
  local numeric = LEVELS[normalized]
  local safeFields = copy(fields or {}, 0)
  eventType, safeFields = normalizeCapturedEvent(category, eventType, message, safeFields, current and current.sceneTime or 0)
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
function M.getSessionSnapshot(session)
  if type(session) ~= 'table' then return nil end
  local snapshot = copy(session, 0)
  snapshot.events = copy(session.events or {}, 0)
  snapshot.actors = copy(session.actors or {}, 0)
  snapshot.lastVehicleCommands = copy(session.lastVehicleCommands or {}, 0)
  snapshot.counters = copy(session.counters or {}, 0)
  snapshot._coalesced = copy(session._coalesced or {}, 0)
  snapshot.export = copy(session.export or {}, 0)
  return snapshot
end
function M.getLastSessionReport()
  local session = getSession(); if not session then return nil end
  local result = M.getSessionSnapshot(session); result._coalesced = nil; return result
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

local function isValidPhysicalPath(path, base)
  path = normalizeFsPath(path)
  return path ~= '' and path ~= normalizeFsPath(base) and not path:find('..', 1, true) and path:match('^%a:/') ~= nil and isWithinUserPath(path, base)
end

local function pathError(code, normalizedPath, baseUserPath, failedStep, message, virtualPath, physicalPath, createResult, existsAfter)
  return {ok=false, code=code, normalizedPath=normalizedPath, baseUserPath=baseUserPath, failedStep=failedStep, virtualPath=virtualPath, physicalPath=physicalPath, createResult=createResult, existsAfter=existsAfter, message=message}
end

local function pathProbe(message, fields)
  M.log('DEBUG', 'export', 'export_path_probe', message, fields)
end

local function ensureDirectory(virtualPath, physicalPath, baseUserPath, failedStep)
  local info = {virtualPath=virtualPath, physicalPath=physicalPath, existsBefore=false, createResult='not_called', existsAfter=false}
  local existsBefore = false
  local existsOk, existsResult = pcall(function() return FS:directoryExists(virtualPath) end)
  if existsOk then existsBefore = existsResult == true end
  info.existsBefore = existsBefore
  pathProbe(string.format('Export path step=%s virtual=%s physical=%s directoryExistsBefore=%s', failedStep, virtualPath, physicalPath, tostring(existsBefore)), {virtualPath=virtualPath, physicalPath=physicalPath, directoryExistsBefore=existsBefore, step=failedStep})
  if existsBefore then info.existsAfter = true; return true, nil, info end

  local createOk, createResult = pcall(function() return FS:directoryCreate(virtualPath, true) end)
  info.createResult = createResult
  local existsAfterOk, existsAfterResult = pcall(function() return FS:directoryExists(virtualPath) end)
  local existsAfter = existsAfterOk and existsAfterResult == true
  info.existsAfter = existsAfter
  pathProbe(string.format('Export path step=%s virtual=%s physical=%s directoryCreateResult=%s directoryExistsAfter=%s', failedStep, virtualPath, physicalPath, tostring(createResult), tostring(existsAfter)), {virtualPath=virtualPath, physicalPath=physicalPath, directoryCreateResult=createResult, directoryExistsAfter=existsAfter, step=failedStep})
  if existsAfter then return true, nil, info end
  local reason = createOk and ('directoryCreate result=' .. tostring(createResult)) or ('directoryCreate exception=' .. tostring(createResult))
  return false, pathError('DIRECTORY_CREATE_FAILED', physicalPath, baseUserPath, failedStep, 'Unable to create diagnostic directory: ' .. reason, virtualPath, physicalPath, createResult, existsAfter), info
end

local function buildExportPaths(sessionId, report)
  local rawBase = nil
  local baseOk, baseResult = pcall(function() return FS and FS:getUserPath() end)
  if baseOk then rawBase = baseResult end
  local baseUserPath = normalizeFsPath(rawBase)
  local virtualParentPath = 'random_incident_generator/'
  local virtualLogsPath = 'random_incident_generator/logs/'
  local physicalParentPath = nil
  local physicalLogsPath = nil
  report = report or {}
  report.rawUserPath = rawBase
  report.normalizedUserPath = baseUserPath
  report.virtualParentPath = virtualParentPath
  report.virtualLogsPath = virtualLogsPath
  report.writeBackend = 'sandboxed_io_open'
  report.writePathType = 'virtual'
  pathProbe(string.format('Export path rawUserPath=%s normalizedUserPath=%s virtualParent=%s virtualLogs=%s', tostring(rawBase), baseUserPath, virtualParentPath, virtualLogsPath), {rawUserPath=rawBase, normalizedUserPath=baseUserPath, virtualParentPath=virtualParentPath, virtualLogsPath=virtualLogsPath})
  if not baseOk or baseUserPath == '' then return nil, pathError('USER_PATH_UNAVAILABLE', baseUserPath, baseUserPath, 'resolve_user_path', 'BeamNG user path is unavailable', virtualParentPath, nil) end
  if not FS or not FS.expandFilename or not FS.directoryExists or not FS.directoryCreate or not FS.fileExists or not FS.removeFile then return nil, pathError('FS_API_UNAVAILABLE', baseUserPath, baseUserPath, 'validate_fs_api', 'BeamNG filesystem API is unavailable', virtualParentPath, nil) end

  local physicalParentOk, physicalParentResult = pcall(function() return FS:expandFilename(virtualParentPath) end)
  local physicalLogsOk, physicalLogsResult = pcall(function() return FS:expandFilename(virtualLogsPath) end)
  local expandedParentPath = physicalParentOk and normalizeFsPath(physicalParentResult) or ''
  local expandedLogsPath = physicalLogsOk and normalizeFsPath(physicalLogsResult) or ''
  report.expandedParentPath = expandedParentPath
  report.expandedLogsPath = expandedLogsPath
  report.expansionChangedParent = expandedParentPath ~= normalizeFsPath(virtualParentPath)
  report.expansionChangedLogs = expandedLogsPath ~= normalizeFsPath(virtualLogsPath)
  local physicalPathSource = 'expandFilename'
  if isValidPhysicalPath(expandedParentPath, baseUserPath) and isValidPhysicalPath(expandedLogsPath, baseUserPath) then
    physicalParentPath = expandedParentPath
    physicalLogsPath = expandedLogsPath
  else
    physicalPathSource = 'safe_user_path_join'
    physicalParentPath = joinFsPath(baseUserPath, 'random_incident_generator')
    physicalLogsPath = joinFsPath(baseUserPath, 'random_incident_generator', 'logs')
  end
  report.physicalPathSource = physicalPathSource
  if not isValidPhysicalPath(physicalParentPath, baseUserPath) or not isValidPhysicalPath(physicalLogsPath, baseUserPath) then
    local errorResult = pathError('VFS_EXPANSION_FAILED', physicalLogsPath or baseUserPath, baseUserPath, 'resolve_physical_path', 'Unable to resolve a physical diagnostic path inside BeamNG user path', virtualLogsPath, physicalLogsPath)
    errorResult.expandedPath = expandedLogsPath
    errorResult.fallbackAttempted = true
    return nil, errorResult
  end
  physicalParentPath = physicalParentPath .. '/'
  physicalLogsPath = physicalLogsPath .. '/'
  report.physicalParentPath = physicalParentPath
  report.physicalLogsPath = physicalLogsPath
  if not isWithinUserPath(physicalParentPath, baseUserPath) or not isWithinUserPath(physicalLogsPath, baseUserPath) then
    return nil, pathError('PATH_OUTSIDE_USER_PATH', physicalLogsPath, baseUserPath, 'validate_physical_path', 'Diagnostic export path is outside BeamNG user path', virtualLogsPath, physicalLogsPath)
  end

  local parentOk, parentError, parentInfo = ensureDirectory(virtualParentPath, physicalParentPath, baseUserPath, 'create_parent')
  report.virtualParentExistsBefore = parentInfo and parentInfo.existsBefore or false
  report.virtualParentCreateResult = parentInfo and parentInfo.createResult or 'not_called'
  report.virtualParentExistsAfter = parentInfo and parentInfo.existsAfter or false
  if not parentOk then return nil, parentError end
  local exportOk, exportError, logsInfo = ensureDirectory(virtualLogsPath, physicalLogsPath, baseUserPath, 'create_export_directory')
  report.virtualLogsExistsBefore = logsInfo and logsInfo.existsBefore or false
  report.virtualLogsCreateResult = logsInfo and logsInfo.createResult or 'not_called'
  report.virtualLogsExistsAfter = logsInfo and logsInfo.existsAfter or false
  if not exportOk then return nil, exportError end
  local probeVirtualPath = virtualLogsPath .. 'randomIncidents_export_probe.tmp'
  local probePhysicalPath = physicalLogsPath .. 'randomIncidents_export_probe.tmp'
  local virtualProbePath = '/' .. probeVirtualPath
  report.probeFilePath = probePhysicalPath
  report.virtualProbePath = virtualProbePath
  report.physicalProbeDisplayPath = probePhysicalPath
  report.writeBackend = 'sandboxed_io_open'
  report.writePathType = 'virtual'
  local probeFile = io.open(virtualProbePath, 'w')
  report.probeOpenOk = probeFile ~= nil
  report.probeWriteOk = false
  report.probeCloseOk = false
  if probeFile then
    local writeOk = pcall(function() probeFile:write('Random Incident Generator export probe\n') end)
    local closeOk = pcall(function() probeFile:close() end)
    report.probeWriteOk = writeOk and closeOk
    report.probeCloseOk = closeOk
  end
  local probeExistsWriteOk, probeExistsWriteResult = pcall(function() return FS:fileExists(virtualProbePath) end)
  report.probeExistsAfterWrite = probeExistsWriteOk and probeExistsWriteResult == true
  local cleanupCallOk, cleanupResult = pcall(function() return FS:removeFile(virtualProbePath) end)
  local probeExistsAfterCleanup = false
  local probeExistsCleanupOk, probeExistsCleanupResult = pcall(function() return FS:fileExists(virtualProbePath) end)
  if probeExistsCleanupOk then probeExistsAfterCleanup = probeExistsCleanupResult == true end
  report.probeCleanupOk = cleanupCallOk and not probeExistsAfterCleanup and (cleanupResult == 0 or cleanupResult == true)
  if not report.probeOpenOk then return nil, pathError('PROBE_OPEN_FAILED', physicalLogsPath, baseUserPath, 'probe_open', 'Unable to open diagnostic probe file through BeamNG VFS', virtualProbePath, probePhysicalPath, nil, false) end
  if not report.probeWriteOk then return nil, pathError('PROBE_WRITE_FAILED', physicalLogsPath, baseUserPath, 'probe_write', 'Unable to write diagnostic probe file through BeamNG VFS', virtualProbePath, probePhysicalPath, nil, false) end
  if not report.probeCloseOk then return nil, pathError('PROBE_CLOSE_FAILED', physicalLogsPath, baseUserPath, 'probe_close', 'Unable to close diagnostic probe file', virtualProbePath, probePhysicalPath, nil, false) end
  if not report.probeCleanupOk then return nil, pathError('PROBE_CLEANUP_FAILED', physicalLogsPath, baseUserPath, 'probe_cleanup', 'Unable to remove diagnostic probe file through BeamNG VFS', virtualProbePath, probePhysicalPath, cleanupResult, probeExistsAfterCleanup) end
  local safeSessionId = tostring(sessionId or ''):gsub('[^%w%-_]', '_')
  local virtualTxtPath = '/' .. virtualLogsPath .. 'randomIncidents_' .. safeSessionId .. '.txt'
  local virtualJsonlPath = '/' .. virtualLogsPath .. 'randomIncidents_' .. safeSessionId .. '.jsonl'
  local physicalTxtPath = physicalLogsPath .. 'randomIncidents_' .. safeSessionId .. '.txt'
  local physicalJsonlPath = physicalLogsPath .. 'randomIncidents_' .. safeSessionId .. '.jsonl'
  return physicalTxtPath, physicalJsonlPath, virtualTxtPath, virtualJsonlPath
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
    report.virtualPath = errorResult and errorResult.virtualPath or report.virtualLogsPath
    report.physicalPath = errorResult and errorResult.physicalPath or report.physicalLogsPath
    report.createResult = errorResult and errorResult.createResult or nil
    report.existsAfter = errorResult and errorResult.existsAfter or false
    report.expandedPath = errorResult and errorResult.expandedPath or report.expandedLogsPath
    report.fallbackAttempted = errorResult and errorResult.fallbackAttempted or false
    report.message = errorResult and errorResult.message or 'Unable to prepare diagnostic export path'
    return report
  end
  report.ok = true
  return report
end

normalizeCapturedEvent = function(category, eventType, message, fields, sceneTime)
  local normalizedEventType = tostring(eventType or 'message')
  fields = fields or {}
  if category == 'trigger' then
    if tostring(message):match('Trigger reaction scheduled') then normalizedEventType = 'trigger_reaction_scheduled'
    elseif tostring(message):match('Trigger fired') then normalizedEventType = 'trigger_fired'
    elseif tostring(message):match('[Tt]rigger [^:]+ cancelled') then normalizedEventType = 'trigger_cancelled' end
    if normalizedEventType == 'trigger_fired' or normalizedEventType == 'trigger_reaction_scheduled' then
      fields.triggerId = fields.triggerId or tostring(message):match('id=([^%s]+)')
      fields.group = fields.group or tostring(message):match('group=([^%s]+)')
      fields.subject = fields.subject or tostring(message):match('subject=([^%s]+)')
      fields.target = fields.target or tostring(message):match('target=([^%s]+)')
      fields.metric = fields.metric or tostring(message):match('metric=([^%s]+)')
      fields.value = fields.value or tonumber(tostring(message):match('value=([^%s]+)'))
      fields.threshold = fields.threshold or tonumber(tostring(message):match('threshold=([^%s]+)'))
      fields.sceneTime = fields.sceneTime or sceneTime
    end
  elseif category == 'ai' and tostring(message):match('Vehicle controller transition') then
    normalizedEventType = 'controller_transition'
    local actor, oldState, newState = tostring(message):match('Vehicle controller transition ([^:]+): ([^%s]+) %-%> ([^%s]+)')
    fields.actor = fields.actor or actor
    fields.oldState = fields.oldState or oldState
    fields.newState = fields.newState or newState
    fields.sceneTime = fields.sceneTime or sceneTime
  end
  return normalizedEventType, fields
end

local function removeVirtualFile(path)
  if not FS or not FS.removeFile then return false end
  local ok, result = pcall(function() return FS:removeFile(path) end)
  return ok and (result == 0 or result == true)
end

local function exportFailure(code, failedStep, virtualPath, physicalDisplayPath, message)
  return {ok=false, code=code, failedStep=failedStep, writeBackend='sandboxed_io_open', writePathType='virtual', virtualPath=virtualPath, physicalDisplayPath=physicalDisplayPath, message=message}
end

local function appendSection(lines, title, sectionLines)
  table.insert(lines, title)
  if sectionLines and #sectionLines > 0 then
    for _, line in ipairs(sectionLines) do table.insert(lines, line) end
  else
    table.insert(lines, '(none)')
  end
  table.insert(lines, '')
end

local function isImportantTimelineEvent(event)
  if not event or event.recordType ~= 'event' then return false end
  if event.level == 'WARN' or event.level == 'ERROR' then return true end
  if event.level ~= 'INFO' then return false end
  local message = tostring(event.message or '')
  local eventType = tostring(event.eventType or '')
  if message:match('Forward neighbor') or message:match('Opposite candidate') or message:match('Queued AI') then return false end
  if message:match('position=') and event.category == 'lifecycle' then return false end
  if event.category == 'trigger' and (eventType == 'trigger_fired' or eventType == 'trigger_reaction_scheduled' or eventType == 'trigger_cancelled' or eventType == 'trigger_engine_armed') then return true end
  if event.category == 'ai' and eventType == 'controller_transition' then return event.fields and event.fields.oldState ~= event.fields.newState end
  if event.category == 'following' and (message:match('Following route initialized') or message:match('target temporarily unavailable')) then return true end
  if message:match('Diagnostic session created') or message:match('Generating road scenario') or message:match('generated successfully') or message:match('Scenario definition .* generated') then return true end
  if message:match('Selected straight') or message:match('opposite carriageway selected') or message:match('Ambient traffic started') or message:match('spawned') or message:match('Scenario Timeline') or message:match('Diagnostic session exported') then return true end
  if message:match('brake') or message:match('Brake') or message:match('scheduled') or message:match('released') then return true end
  return false
end

local function textReport(session, exportMetadata)
  local c = session.counters or {}
  local out = {'Random Incident Generator Diagnostic Session', '============================================', '1. Header', 'sessionId: ' .. tostring(session.sessionId), 'status: ' .. tostring(session.status), 'createdAt: ' .. tostring(session.createdAt), 'modVersion: ' .. tostring(session.modVersion), '', '2. Scenario', 'scenarioId: ' .. tostring(session.scenarioId), 'scenarioVersion: ' .. tostring(session.scenarioVersion), 'phase: ' .. tostring(session.phase), 'seed: ' .. tostring(session.seed), '', '3. Environment', 'map: ' .. tostring(session.mapName), 'sceneTime: ' .. tostring(session.sceneTime), '', '4. Actors'}
  for _, actor in ipairs(session.actors or {}) do table.insert(out, string.format('%s role=%s objectId=%s model=%s ambient=%s speed=%.2f lane=%s position=%s', actor.label, actor.role, tostring(actor.objectId), actor.model, tostring(actor.ambient), actor.initialSpeed, tostring(actor.lane), jsonEncode(actor.spawnPosition))) end

  local timelineLines, triggerLines, transitionLines, warningLines, commandLines, coalescedLines = {}, {}, {}, {}, {}, {}
  for _, event in ipairs(session.events or {}) do
    local line = string.format('[%s] t=%.3f %s/%s: %s %s', event.level, event.sceneTime or 0, event.category, event.eventType, event.message or '', jsonEncode(event.fields or {}))
    if isImportantTimelineEvent(event) then table.insert(timelineLines, line) end
    if event.recordType == 'event' and event.category == 'trigger' and (event.eventType == 'trigger_fired' or event.eventType == 'trigger_reaction_scheduled' or event.eventType == 'trigger_cancelled') then table.insert(triggerLines, line) end
    if event.recordType == 'event' and event.category == 'ai' and event.eventType == 'controller_transition' and event.fields and event.fields.oldState ~= event.fields.newState then table.insert(transitionLines, line) end
    if event.recordType == 'event' and (event.level == 'WARN' or event.level == 'ERROR') then table.insert(warningLines, line) end
    if event.recordType == 'coalescedDebug' then table.insert(coalescedLines, string.format('%s/%s actor=%s count=%d firstTime=%.3f lastTime=%.3f firstValue=%s lastValue=%s minValue=%s maxValue=%s', event.category, event.eventType, tostring(event.actor), event.count, event.firstTime or 0, event.lastTime or 0, tostring(event.firstValue), tostring(event.lastValue), tostring(event.minValue), tostring(event.maxValue))) end
  end
  for actor, command in pairs(session.lastVehicleCommands or {}) do table.insert(commandLines, string.format('actor=%s objectId=%s context=%s sceneTime=%.3f\ncommand=%s', actor, tostring(command.objectId), command.context, command.sceneTime or 0, command.command)) end

  table.insert(out, ''); appendSection(out, '5. Important Timeline', timelineLines)
  appendSection(out, '6. Trigger Events', triggerLines)
  appendSection(out, '7. Controller Transitions', transitionLines)
  appendSection(out, '8. Warnings and Errors', warningLines)
  appendSection(out, '9. Last Vehicle Lua Commands', commandLines)
  appendSection(out, '10. Coalesced Debug Summary', coalescedLines)
  local counterLines = {
    string.format('exportedEventRecords=%d', #(session.events or {})),
    string.format('capturedDebugObservations=%d', c.DEBUGCount or 0),
    string.format('capturedInfoObservations=%d', c.INFOCount or 0),
    string.format('capturedWarnObservations=%d', c.WARNCount or 0),
    string.format('capturedErrorObservations=%d', c.ERRORCount or 0),
    string.format('droppedEvents=%d', c.droppedEvents or 0),
    string.format('triggerCount=%d', c.triggerCount or 0),
  }
  appendSection(out, '11. Counters', counterLines)
  local exportLines = {}
  if exportMetadata then
    table.insert(exportLines, 'exportedAt=' .. tostring(exportMetadata.exportedAt))
    table.insert(exportLines, 'txtPath=' .. tostring(exportMetadata.txtPath))
    table.insert(exportLines, 'jsonlPath=' .. tostring(exportMetadata.jsonlPath))
    table.insert(exportLines, 'writeBackend=' .. tostring(exportMetadata.writeBackend))
    table.insert(exportLines, 'sessionId=' .. tostring(exportMetadata.sessionId))
    table.insert(exportLines, 'formatVersion=' .. tostring(exportMetadata.formatVersion))
    table.insert(exportLines, 'exportCount=' .. tostring(exportMetadata.exportCount or 1))
  end
  appendSection(out, '12. Export Metadata', exportLines)
  return table.concat(out, '\n') .. '\n'
end

function M.exportLastSession()
  local liveSession = lastSession or current
  if not liveSession then return {ok=false, code='NO_SESSION', message='No diagnostic session is available'} end
  local snapshot = M.getSessionSnapshot(liveSession)
  local txtPath, jsonlPath, virtualTxtPath, virtualJsonlPath = buildExportPaths(snapshot.sessionId)
  if not txtPath then return jsonlPath end
  local virtualTxtTemp, virtualJsonlTemp = virtualTxtPath .. '.tmp', virtualJsonlPath .. '.tmp'
  local exportMetadata = {exportedAt=os.date('!%Y-%m-%dT%H:%M:%SZ'), txtPath=txtPath, jsonlPath=jsonlPath, writeBackend='sandboxed_io_open', sessionId=snapshot.sessionId, formatVersion='1', exportCount=((liveSession.export and liveSession.export.exportCount) or 0) + 1}
  local txt = io.open(virtualTxtTemp, 'w')
  if not txt then return exportFailure('TXT_OPEN_FAILED', 'txt_open', virtualTxtTemp, txtPath, 'Unable to open TXT export through BeamNG VFS') end
  local txtWriteOk = pcall(function() txt:write(textReport(snapshot, exportMetadata)) end)
  local txtCloseOk = pcall(function() txt:close() end)
  if not txtWriteOk then removeVirtualFile(virtualTxtTemp); return exportFailure('TXT_WRITE_FAILED', 'txt_write', virtualTxtTemp, txtPath, 'Unable to write TXT export through BeamNG VFS') end
  if not txtCloseOk then removeVirtualFile(virtualTxtTemp); return exportFailure('TXT_CLOSE_FAILED', 'txt_close', virtualTxtTemp, txtPath, 'Unable to close TXT export') end
  local txtExistsOk, txtExists = pcall(function() return FS:fileExists(virtualTxtTemp) end)
  if not txtExistsOk or txtExists ~= true then removeVirtualFile(virtualTxtTemp); return exportFailure('TXT_VERIFY_FAILED', 'txt_verify_temp', virtualTxtTemp, txtPath, 'TXT temporary file was not visible through BeamNG VFS') end

  local jsonl = io.open(virtualJsonlTemp, 'w')
  if not jsonl then removeVirtualFile(virtualTxtTemp); return exportFailure('JSONL_OPEN_FAILED', 'jsonl_open', virtualJsonlTemp, jsonlPath, 'Unable to open JSONL export through BeamNG VFS') end
  local safe = copy(snapshot, 0); safe.events = nil; safe._coalesced = nil; safe.recordType = 'session'
  local jsonlWriteOk = pcall(function()
    jsonl:write(jsonEncode(safe) .. '\n')
    for _, event in ipairs(snapshot.events or {}) do local eventRecord = copy(event, 0); eventRecord.recordType = 'event'; jsonl:write(jsonEncode(eventRecord) .. '\n') end
    jsonl:write(jsonEncode({recordType='summary', sessionId=snapshot.sessionId, counters=copy(snapshot.counters or {}, 0), eventCount=#(snapshot.events or {})}) .. '\n')
  end)
  local jsonlCloseOk = pcall(function() jsonl:close() end)
  if not jsonlWriteOk then removeVirtualFile(virtualTxtTemp); removeVirtualFile(virtualJsonlTemp); return exportFailure('JSONL_WRITE_FAILED', 'jsonl_write', virtualJsonlTemp, jsonlPath, 'Unable to write JSONL export through BeamNG VFS') end
  if not jsonlCloseOk then removeVirtualFile(virtualTxtTemp); removeVirtualFile(virtualJsonlTemp); return exportFailure('JSONL_CLOSE_FAILED', 'jsonl_close', virtualJsonlTemp, jsonlPath, 'Unable to close JSONL export') end
  local jsonlExistsOk, jsonlExists = pcall(function() return FS:fileExists(virtualJsonlTemp) end)
  if not jsonlExistsOk or jsonlExists ~= true then removeVirtualFile(virtualTxtTemp); removeVirtualFile(virtualJsonlTemp); return exportFailure('JSONL_VERIFY_FAILED', 'jsonl_verify_temp', virtualJsonlTemp, jsonlPath, 'JSONL temporary file was not visible through BeamNG VFS') end

  local txtRenameOk, txtRenameResult = false, nil
  if FS and FS.renameFile then txtRenameOk, txtRenameResult = pcall(function() return FS:renameFile(virtualTxtTemp, virtualTxtPath) end) end
  if not txtRenameOk or txtRenameResult ~= 0 then
    removeVirtualFile(virtualTxtTemp); removeVirtualFile(virtualJsonlTemp)
    return exportFailure('TXT_COMMIT_FAILED', 'txt_rename', virtualTxtTemp, txtPath, 'Unable to commit TXT export')
  end
  local txtFinalOk, txtFinalExists = pcall(function() return FS:fileExists(virtualTxtPath) end)
  if not txtFinalOk or txtFinalExists ~= true then
    removeVirtualFile(virtualJsonlTemp)
    return exportFailure('TXT_VERIFY_FAILED', 'txt_verify_final', virtualTxtPath, txtPath, 'TXT final file was not visible through BeamNG VFS')
  end
  local jsonlRenameOk, jsonlRenameResult = pcall(function() return FS:renameFile(virtualJsonlTemp, virtualJsonlPath) end)
  if not jsonlRenameOk or jsonlRenameResult ~= 0 then
    removeVirtualFile(virtualJsonlTemp)
    return exportFailure('JSONL_COMMIT_FAILED', 'jsonl_rename', virtualJsonlTemp, jsonlPath, 'Unable to commit JSONL export')
  end
  local jsonlFinalOk, jsonlFinalExists = pcall(function() return FS:fileExists(virtualJsonlPath) end)
  if not jsonlFinalOk or jsonlFinalExists ~= true then return exportFailure('JSONL_VERIFY_FAILED', 'jsonl_verify_final', virtualJsonlPath, jsonlPath, 'JSONL final file was not visible through BeamNG VFS') end
  liveSession.export = copy(exportMetadata, 0)
  return {ok=true, sessionId=snapshot.sessionId, txtPath=txtPath, jsonlPath=jsonlPath, eventCount=#(snapshot.events or {}), warningCount=snapshot.counters.WARNCount or 0, errorCount=snapshot.counters.ERRORCount or 0}
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
