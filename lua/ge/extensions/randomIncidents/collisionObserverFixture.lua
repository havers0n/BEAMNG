-- Synthetic collision observer fixture. Run manually with:
-- extensions.load('randomIncidents/collisionObserverFixture')
local observer = require('lua/ge/extensions/randomIncidents/collisionObserver')
local M = {}
local function v(x,y,z) return {x=x,y=y,z=z} end
local function actors() return {{actor='Car A',objectId=1,role='lead',ambient=false},{actor='Car B',objectId=2,role='chaser',ambient=false}} end
local function object(state)
  local o={state=state}
  -- These mocks deliberately reject detached calls: the production reader must
  -- use the BeamNG-compatible colon closure pattern.
  function o:getPosition() assert(self==o,'detached getPosition'); if self.state.positionError then error('position failure') end; return self.state.position end
  function o:getVelocity() assert(self==o,'detached getVelocity'); if self.state.velocityError then error('velocity failure') end; return self.state.velocity end
  function o:getDirectionVector() assert(self==o,'detached getDirectionVector'); if self.state.forwardError then error('forward failure') end; return self.state.forward end
  return o
end
local function report(id,a,b,objectB)
  return {sessionId=id,latestByActor={['Car A']={objectId=1,position=a.position,velocity=a.velocity,forward=a.forward},['Car B']={objectId=objectB and 99 or 2,position=b.position,velocity=b.velocity,forward=b.forward}}}
end
local function run(id, objects, telemetry, diagnostics)
  observer.clear()
  observer.startSession({sessionId=id,scenarioId='fixture',actors=actors(),objectProvider=function(objectId)return objects[objectId]end,diagnostics=diagnostics,sourceAdapter=function()return {{objectIdA=1,objectIdB=2}},true end})
  observer.update(.1,function()return telemetry end)
  return observer.getReport()
end
function M.run()
  local a={position=v(0,0,0),velocity=v(10,0,0),forward=v(1,0,0)};local b={position=v(10,0,0),velocity=v(0,0,0),forward=v(1,0,0)}
  local r=run('live',{[1]=object(a),[2]=object(b)},report('live',a,b));local e=r.events[1]
  assert(e.firstStateSourceA=='live_vehicle' and e.firstStateSourceB=='live_vehicle' and e.firstClosingSpeedMps==10,'bound live reads must produce current kinematics')
  assert(r.liveStateReadFailureCount==0 and r.telemetryFallbackCount==0 and r.livePositionReadCount==2 and r.liveVelocityReadCount==2,'complete reads are not failures')

  local forwardFail={position=a.position,velocity=a.velocity,forwardError=true};r=run('forward',{[1]=object(forwardFail),[2]=object(b)},report('forward',a,b))
  assert(r.events[1].firstStateSourceA=='live_vehicle' and r.liveForwardReadFailureCount==1 and r.liveStateReadFailureCount==0,'forward is optional')

  local positionFail={position=a.position,velocity=a.velocity,positionError=true};r=run('partial',{[1]=object(positionFail),[2]=object(b)},report('partial',a,b))
  assert(r.events[1].firstStateSourceA=='partial' and r.telemetryFallbackCount==1 and r.events[1].firstRelativeSpeedMps==10,'position fallback is partial and preserves kinematics')

  r=run('missing',{[2]=object(b)},report('missing',a,b));assert(r.liveObjectNotFoundCount==1 and r.events[1].firstStateSourceA=='runtime_telemetry','missing object uses matching telemetry')

  local nan={position=a.position,velocity=v(0/0,0,0)};r=run('nan',{[1]=object(nan),[2]=object(b)},report('nan',a,b));assert(r.invalidFieldCount>0 and r.liveVelocityReadFailureCount==1 and r.events[1].firstStateSourceA=='partial','NaN is sanitized and falls back')

  r=run('stale',{[2]=object(b)},report('other_session',a,b));assert(r.events[1].firstStateSourceA=='partial' and r.lastLiveReadFailureStage=='telemetry_fallback_missing','stale-session telemetry is rejected')

  local calls=0;local diagnostics={log=function(_,_,eventType)if eventType=='collision_live_state_read_failed'then calls=calls+1 end end};r=run('coalesced',{},report('coalesced',a,b),diagnostics);observer.update(.1,function()return report('coalesced',a,b)end);assert(calls==1,'failure logging is coalesced by stage')
  local copy=observer.getReport();copy.lastLiveReadFailureStage='mutated';assert(observer.getReport().lastLiveReadFailureStage~='mutated','report diagnostics are deep copied')
  observer.clear();return true
end
return M
