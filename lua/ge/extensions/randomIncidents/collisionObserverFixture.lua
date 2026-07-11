-- Synthetic collision observer fixture. Run manually with:
-- extensions.load('randomIncidents/collisionObserverFixture')
local observer = require('lua/ge/extensions/randomIncidents/collisionObserver')
local M = {}
local function v(x,y,z) return {x=x,y=y,z=z} end
local function actors() return {{actor='Car A',objectId=1,role='lead',ambient=false},{actor='Car B',objectId=2,role='chaser',ambient=false}} end
local function telemetry(a, b) return {latestByActor={['Car A']={objectId=1,position=a.position,velocity=a.velocity,forward=a.forward},['Car B']={objectId=2,position=b.position,velocity=b.velocity,forward=b.forward}}} end
local function start(id, state, getTelemetry)
  observer.clear()
  observer.startSession({sessionId=id,scenarioId='fixture',actors=actors(),sourceAdapter=function() return {{objectIdA=1,objectIdB=2},{objectIdA=2,objectIdB=1}},true end,liveStateReader=function(actor) return state[actor.objectId] end})
  observer.update(.1, getTelemetry and function() return getTelemetry() end)
  return observer.getReport()
end
function M.run()
  local state={[1]={exists=true,position=v(0,0,0),velocity=v(10,0,0),forward=v(1,0,0)},[2]={exists=true,position=v(10,0,0),velocity=v(0,0,0),forward=v(1,0,0)}}
  local r=start('live_fixture',state,function() return telemetry(state[1],state[2]) end); local e=r.events[1]
  assert(e.firstStateSourceA=='live_vehicle' and e.firstStateSourceB=='live_vehicle' and e.firstRelativeSpeedMps==10 and e.firstClosingSpeedMps==10,'live kinematics must be used at first contact')
  state[1].position=v(1,0,0);state[1].velocity=v(4,0,0);observer.update(.1,function()return telemetry(state[1],state[2])end);e=observer.getReport().events[1]
  assert(e.firstSpeedAMps==10 and e.latestSpeedAMps==4 and e.maxRelativeSpeedMps==10,'first state is immutable while latest and maxima update')

  local fallbackA={exists=false}; local liveB={exists=true,position=v(5,0,0),velocity=v(0,0,0)}; local fallbackTelemetryA={position=v(0,0,0),velocity=v(5,0,0)}
  r=start('fallback_fixture',{[1]=fallbackA,[2]=liveB},function()return telemetry(fallbackTelemetryA,liveB)end);e=r.events[1]
  assert(e.firstStateSourceA=='runtime_telemetry' and e.firstStateSourceB=='live_vehicle' and e.firstRelativeSpeedMps==5 and r.telemetryFallbackCount>0,'per-actor telemetry fallback must preserve pair kinematics')

  r=start('partial_fixture',{[1]={exists=true,position=v(0,0,0)},[2]=liveB},function()return telemetry(fallbackTelemetryA,liveB)end);e=r.events[1]
  assert(e.firstStateSourceA=='partial' and r.partialStateCount>0,'live position plus telemetry velocity is partial')

  r=start('all_fallback_fixture',{[1]={exists=false},[2]={exists=false}},function()return telemetry(fallbackTelemetryA,liveB)end)
  assert(r.events[1].firstStateSourceA=='runtime_telemetry' and r.events[1].firstStateSourceB=='runtime_telemetry' and r.telemetryFallbackCount==2,'both unavailable actors use telemetry fallback')

  r=start('invalid_fixture',{[1]={exists=true,position=v(0,0,0),velocity=v(0/0,0,0)},[2]=liveB},function()return telemetry(fallbackTelemetryA,liveB)end)
  assert(r.invalidFieldCount>0 and r.events[1].firstStateSourceA=='partial','invalid live velocity is sanitized and falls back')

  local function closing(aVelocity, bVelocity)
    local a={exists=true,position=v(0,0,0),velocity=v(aVelocity,0,0)}; local b={exists=true,position=v(10,0,0),velocity=v(bVelocity,0,0)}
    return start('closing_'..aVelocity..'_'..bVelocity,{[1]=a,[2]=b},function()return telemetry(a,b)end).events[1].firstClosingSpeedMps
  end
  assert(closing(5,0)>0 and closing(-5,0)==0 and closing(5,5)==0,'closing speed sign convention is correct')

  local before=observer.getReport();before.events[1].actorA='mutated';assert(observer.getReport().events[1].actorA=='Car A','reports are deep copies')
  observer.stopSession('fixture_stop');assert(observer.getReport().events[1].endedAtSceneTime,'stop finalizes active episode')
  observer.clear();return true
end
return M
