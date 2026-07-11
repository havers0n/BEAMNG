-- Synthetic collision observer fixture. Run manually with:
-- extensions.load('randomIncidents/collisionObserverFixture')
local observer = require('lua/ge/extensions/randomIncidents/collisionObserver')
local M = {}
local function v(x,y,z) return {x=x,y=y,z=z} end
local function actors() return {{actor='Car A',objectId=1,role='lead',ambient=false},{actor='Car B',objectId=2,role='chaser',ambient=false}} end
local function start(id, feed)
  local objects={[1]={position=v(0,0,0),velocity=v(10,0,0)},[2]={position=v(5,0,0),velocity=v(2,0,0)}}
  for _,o in pairs(objects) do function o:getPosition() return self.position end; function o:getVelocity() return self.velocity end end
  observer.clear(); observer.startSession({sessionId=id,scenarioId='fixture',actors=actors(),objectProvider=function(objectId)return objects[objectId]end,sourceAdapter=function() return feed(),true end})
  return objects
end
function M.run()
  local contacts={{{objectIdA=1,objectIdB=2},{objectIdA=2,objectIdB=1}}}; local tick=0
  start('collision_fixture',function() tick=tick+1;return contacts[tick] or {} end)
  observer.update(.1); local r=observer.getReport();assert(r.collisionEventCount==1 and r.duplicateObservationCount==1 and r.events[1].pairKey=='1:2','dual-sided contact must dedupe')
  observer.update(.1);assert(observer.getReport().events[1].observationCount==1,'no contact must not increment')
  observer.update(.2);assert(observer.getReport().activeCollisionCount==1,'gap below grace remains active')
  observer.update(.2);r=observer.getReport();assert(r.endedCollisionCount==1,'gap above grace ends episode')
  for _=1,6 do observer.update(.1) end; contacts[tick+1]={{objectIdA=2,objectIdB=1}}; observer.update(.1);r=observer.getReport();assert(r.collisionEventCount==2 and r.events[2].actorA=='Car A','recontact beyond merge is new canonical event')
  local before=observer.getReport();before.events[1].actorA='mutated';assert(observer.getReport().events[1].actorA=='Car A','reports are deep copies')
  observer.stopSession('fixture_stop');assert(observer.getReport().activeCollisionCount==0 and observer.getReport().events[2].endedAtSceneTime,'stop finalizes active')
  local unknownTick=0;start('unknown_fixture',function() unknownTick=unknownTick+1;return {{objectIdA=1,objectIdB=99},{objectIdA=1,objectIdB=1}} end);observer.update(.1);r=observer.getReport();assert(r.collisionEventCount==0 and r.ignoredUnknownObjectCount==2,'unknown and self are ignored')
  local bad=start('invalid_fixture',function() return {{objectIdA=1,objectIdB=2}} end);bad[1].position={x=0,y=0};observer.update(.1);r=observer.getReport();assert(r.collisionEventCount==1 and r.invalidFieldCount>0 and r.events[1].firstPositionA==nil,'invalid vectors remain sanitized')
  local hit=false;start('overflow_fixture',function() return hit and {{objectIdA=1,objectIdB=2}} or {},true end)
  for _=1,257 do hit=true;observer.update(.1);hit=false;observer.update(.9) end
  r=observer.getReport();assert(r.collisionEventCount==256 and r.droppedCollisionEventCount==1,'event buffer drops oldest ended event')
  observer.startSession({sessionId='new_fixture',actors=actors(),sourceAdapter=function()return {},true end});assert(observer.getReport().collisionEventCount==0,'new session is isolated')
  observer.clear();return true
end
return M
