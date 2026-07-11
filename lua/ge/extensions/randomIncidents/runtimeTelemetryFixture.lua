-- Unit-style synthetic fixture. Run manually with:
-- extensions.load('randomIncidents/runtimeTelemetryFixture')
local telemetry = require('lua/ge/extensions/randomIncidents/runtimeTelemetry')

local function vector(x, y, z) return {x=x, y=y, z=z} end
local objects = {
  [1] = {position=vector(0, 0, 0), velocity=vector(10, 0, 0)},
  [2] = {position=vector(0, 10, 0), velocity=vector(4, 0, 0)},
}
for _, object in pairs(objects) do
  function object:getPosition() return self.position end
  function object:getVelocity() return self.velocity end
  function object:getDirectionVector() return vector(1, 0, 0) end
end
local function updatePositions()
  for _, object in pairs(objects) do
    object.position = vector(object.position.x + object.velocity.x * 0.5, object.position.y, object.position.z)
  end
end
local function run()
  telemetry.clear()
  telemetry.startSession({sessionId='fixture-one', scenarioId='fixture', seed=17, sampleInterval=0.5,
    actors={{label='alpha', objectId=1, role='lead', ambient=false}, {label='bravo', objectId=2, role='ambient', ambient=true}},
    objectProvider=function(id) return objects[id] end})
  telemetry.update(0.5)
  updatePositions(); objects[1].velocity = vector(6, 0, 0); telemetry.update(0.5)
  updatePositions(); objects[2] = nil; telemetry.update(0.5)
  objects[2] = {position=vector(100, 10, 0), velocity=vector(3, 0, 0)}
  objects[2].getPosition = function(self) return self.position end
  objects[2].getVelocity = function(self) return self.velocity end
  objects[2].getDirectionVector = function(self) return vector(1, 0, 0) end
  telemetry.update(0.5)
  local first = telemetry.getReport()
  assert(first.sampleCount == 8 and #first.samples == 8, 'two actors must produce chronological samples')
  assert(type(first.samples[1]) == 'table' and type(first.samples[1].sceneTime) == 'number', 'samples retain numeric array keys')
  assert(first.actorSummaries[1].maxDecelerationMps2 == -8, 'max deceleration must use scalar speed delta')
  assert(first.actorSummaries[2].missingSampleCount == 1, 'temporary absence must be counted')
  assert(first.actorSummaries[2].approximateDistanceMeters == 2, 'distance must not bridge unavailable samples')
  first.samples[1].actor = 'mutated'
  assert(telemetry.getReport().samples[1].actor == 'alpha', 'reports must be deep copies')
  telemetry.stopSession('fixture_complete')

  telemetry.startSession({sessionId='fixture-overflow', scenarioId='fixture', actors={{label='alpha', objectId=1, role='lead', ambient=false}}, sampleInterval=0.5, objectProvider=function(id) return objects[id] end})
  for _ = 1, 3001 do telemetry.update(0.5) end
  local overflow = telemetry.getReport()
  assert(#overflow.samples == 3000 and overflow.droppedSampleCount == 1, 'buffer must remain bounded and count drops')
  for index = 2, #overflow.samples do assert(overflow.samples[index - 1].sceneTime <= overflow.samples[index].sceneTime, 'samples must be chronological') end
  telemetry.startSession({sessionId='fixture-reset', scenarioId='fixture-reset', actors={{label='bravo', objectId=2, role='ambient', ambient=true}}, objectProvider=function(id) return objects[id] end})
  local reset = telemetry.getReport()
  assert(reset.sessionId == 'fixture-reset' and reset.sampleCount == 0 and reset.droppedSampleCount == 0, 'new session must not retain old samples')
  telemetry.clear()
  return true
end

local M = {}
function M.run() return run() end
return M
