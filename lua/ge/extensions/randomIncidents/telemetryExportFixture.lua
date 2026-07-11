-- Synthetic export fixture. Run manually with:
-- extensions.load('randomIncidents/telemetryExportFixture')
local exporter = require('lua/ge/extensions/randomIncidents/telemetryExport')

local function vector(x, y, z) return {x=x, y=y, z=z} end
local function parseJsonLines(text)
  local records = {}
  for line in text:gmatch('[^\n]+') do
    assert(line:match('^%b{}$'), 'each JSONL line must be an object')
    assert(not line:match('nan') and not line:match('inf') and not line:match('table: 0x'), 'JSONL cannot contain unsafe values')
    table.insert(records, line)
  end
  return records
end
local function report()
  local actors = {{label='Car A', objectId=11, role='lead', ambient=false}, {label='Car B', objectId=12, role='ambient', ambient=true}}
  local samples = {}
  for tick = 1, 3 do
    for index, actor in ipairs(actors) do
      local acceleration = -1
      if tick == 1 and index == 1 then acceleration = nil end
      table.insert(samples, {sceneTime=tick * 0.5, actor=actor.label, objectId=actor.objectId, role=actor.role, ambient=actor.ambient, exists=true, position=vector(tick, index, 0), velocity=vector(10 - index, 0, 0), speedMps=10-index, accelerationMps2=acceleration, forward=vector(1, 0, 0), controllerState='CRUISE'})
    end
  end
  return {sessionId='fixture_export_001', scenarioId='fixture', seed=123, status='ACTIVE', startedAtSceneTime=0, stoppedAtSceneTime=nil, sampleInterval=0.5, actorCount=2, sampleCount=6, droppedSampleCount=0, invalidFieldCount=0, actors=actors, samples=samples, collisionEvents={{formatVersion=2,eventId='collision_fixture_1',state='ENDED',pairKey='11:12',actorA='Car A',actorB='Car B',objectIdA=11,objectIdB=12,roleA='lead',roleB='ambient',ambientA=false,ambientB=true,startedAtSceneTime=.5,lastObservedAtSceneTime=.6,endedAtSceneTime=.9,durationSeconds=.4,observationCount=2,sources={objectCollisions=true,crashDetection=false},firstPositionA=vector(1,1,0),firstPositionB=vector(1,2,0),latestPositionA=vector(2,1,0),latestPositionB=vector(2,2,0),firstSpeedAMps=9,firstSpeedBMps=8,latestSpeedAMps=8,latestSpeedBMps=7,firstRelativeSpeedMps=1,maxRelativeSpeedMps=2,firstClosingSpeedMps=1,maxClosingSpeedMps=2,stateSource='live_vehicle',firstStateSourceA='live_vehicle',firstStateSourceB='live_vehicle',latestStateSourceA='live_vehicle',latestStateSourceB='partial'}}, actorSummaries={{actor='Car A', objectId=11, sampleCount=3, missingSampleCount=0, firstSceneTime=.5, lastSceneTime=1.5, initialSpeedMps=9, finalSpeedMps=9, minSpeedMps=9, maxSpeedMps=9, maxAccelerationMps2=0, maxDecelerationMps2=-1, approximateDistanceMeters=2}, {actor='Car B', objectId=12, sampleCount=3, missingSampleCount=0, firstSceneTime=.5, lastSceneTime=1.5, initialSpeedMps=8, finalSpeedMps=8, minSpeedMps=8, maxSpeedMps=8, maxAccelerationMps2=0, maxDecelerationMps2=-1, approximateDistanceMeters=2}}}
end
local M = {}
function M.run()
  local source = report()
  local first = assert(exporter.render(source, {exportedAt='2026-07-11T00:00:00Z', exportCount=1}))
  local records = parseJsonLines(first.jsonl)
  assert(type(jsonDecode) == 'function', 'BeamNG JSON decoder is required for this fixture')
  for _, line in ipairs(records) do
    local ok, decoded = pcall(jsonDecode, line)
    assert(ok and type(decoded) == 'table', 'each JSONL line must parse through BeamNG JSON decoder')
  end
  assert(#records == 11, 'record count must be 1 + 6 samples + 1 collision + 2 summaries + 1 summary')
  assert(records[1]:match('"recordType":"session"'), 'session must be first')
  assert(records[2]:match('"recordType":"sample"') and records[7]:match('"recordType":"sample"'), 'six samples must follow')
  assert(records[8]:match('"recordType":"collision_event"'), 'collision records follow samples')
  assert(records[8]:match('"formatVersion":2'), 'every collision record must be versioned')
  assert(records[9]:match('"recordType":"actor_summary"') and records[10]:match('"recordType":"actor_summary"'), 'actor summaries follow collisions')
  assert(records[11]:match('"recordType":"summary"') and records[11]:match('"formatVersion":2'), 'v2 summary must be last')
  assert(first.txt:find('Car A', 1, true) and first.txt:find('Car B', 1, true), 'TXT must include both actors')
  assert(not first.txt:find('controllerState', 1, true), 'TXT must not include raw samples')
  assert(first.txt:find('4. Collision Events', 1, true) and first.txt:find('collision_fixture_1', 1, true), 'TXT must include collision events')
  assert(first.txt:find('first state source: A=live_vehicle B=live_vehicle', 1, true) and first.txt:find('latest state source: A=live_vehicle B=partial', 1, true), 'TXT must include state sources')
  local second = assert(exporter.render(source, {exportedAt='2026-07-11T00:00:01Z', exportCount=2}))
  assert(source.samples[1].accelerationMps2 == nil and source.samples[1].actor == 'Car A', 'render must not mutate report')
  local comparableFirst = first.jsonl:gsub('2026%-07%-11T00:00:00Z', ''):gsub('"exportCount":1', '"exportCount":#')
  local comparableSecond = second.jsonl:gsub('2026%-07%-11T00:00:01Z', ''):gsub('"exportCount":2', '"exportCount":#')
  assert(comparableFirst == comparableSecond, 'repeat rendering differs only by export metadata')
  local unsafe = report(); unsafe.sessionId='../unsafe'; local _, unsafeErr = exporter.render(unsafe); assert(unsafeErr and unsafeErr.code == 'UNSAFE_SESSION_ID', 'unsafe session id must fail')
  local empty = report(); empty.samples = {}; local _, emptyErr = exporter.render(empty); assert(emptyErr and emptyErr.code == 'EMPTY_REPORT', 'empty report must fail')
  return true
end
return M
