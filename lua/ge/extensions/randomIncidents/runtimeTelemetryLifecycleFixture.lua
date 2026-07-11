-- Lifecycle-focused synthetic fixture. Run manually with:
-- extensions.load('randomIncidents/runtimeTelemetryLifecycleFixture')
local telemetry = require('lua/ge/extensions/randomIncidents/runtimeTelemetry')

local M = {}
function M.run()
  local object = {position={x=0,y=0,z=0}, velocity={x=1,y=0,z=0}}
  function object:getPosition() return self.position end
  function object:getVelocity() return self.velocity end
  function object:getDirectionVector() return {x=1,y=0,z=0} end
  telemetry.clear()
  telemetry.startSession({sessionId='lifecycle_old', scenarioId='fixture', seed=123, actors={{label='Car A', objectId=1, role='lead'}}, objectProvider=function() return object end})
  telemetry.update(30.5)
  local active = telemetry.getReport()
  assert(active.status == 'ACTIVE' and active.stoppedAtSceneTime == nil and active.sampleCount > 0, 'nominal timeline completion must not stop telemetry')
  telemetry.stopSession('REPEATED')
  local old = telemetry.getReport()
  telemetry.startSession({sessionId='lifecycle_new', scenarioId='fixture', seed=123, actors={{label='Car A', objectId=2, role='lead'}}, objectProvider=function() return object end})
  local fresh = telemetry.getReport()
  assert(old.sessionId ~= fresh.sessionId and fresh.status == 'ACTIVE' and fresh.sampleCount == 0, 'repeat lifecycle must create a fresh active session')
  telemetry.clear()
  return true
end
return M
