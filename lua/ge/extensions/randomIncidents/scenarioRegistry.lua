local M = {}

local triggerEngine = require('lua/ge/extensions/randomIncidents/triggerEngine')
local ambientTrafficManager = require('lua/ge/extensions/randomIncidents/ambientTraffic')

local definitions = {
  sudden_obstacle_pileup = require('lua/ge/extensions/randomIncidents/scenarios/suddenObstaclePileup'),
}

local function deepCopy(value, seen)
  if type(value) ~= 'table' then return value end
  seen = seen or {}
  if seen[value] then return seen[value] end
  local result = {}
  seen[value] = result
  for key, item in pairs(value) do
    result[deepCopy(key, seen)] = deepCopy(item, seen)
  end
  return result
end

local function validate(definition)
  if type(definition) ~= 'table' then return false, 'definition must be a table' end
  if type(definition.id) ~= 'string' or definition.id == '' then return false, 'id is required' end
  if type(definition.name) ~= 'string' or definition.name == '' then return false, 'name is required' end
  if type(definition.convoy) ~= 'table' or #definition.convoy == 0 then return false, 'convoy actors are required' end
  if type(definition.hazard) ~= 'table' then return false, 'hazard actor is required' end

  local labels = {}
  for _, actor in ipairs(definition.convoy) do
    if type(actor.label) ~= 'string' or actor.label == '' then return false, 'every convoy actor needs a label' end
    if labels[actor.label] then return false, 'duplicate actor label: '..actor.label end
    labels[actor.label] = true
    if type(actor.model) ~= 'string' or actor.model == '' then return false, actor.label..' needs a model' end
    if tonumber(actor.speedMps) == nil then return false, actor.label..' needs speedMps' end
  end

  if type(definition.hazard.label) ~= 'string' or definition.hazard.label == '' then return false, 'hazard needs a label' end
  if labels[definition.hazard.label] then return false, 'duplicate actor label: '..definition.hazard.label end
  labels[definition.hazard.label] = true

  local bindings = definition.bindings or {}
  for _, key in ipairs({'lead', 'target', 'hazard'}) do
    local label = bindings[key]
    if type(label) ~= 'string' or label == '' then return false, 'binding '..key..' is required' end
    if not labels[label] then return false, 'binding '..key..' references unknown actor '..label end
    if key == 'hazard' and label ~= definition.hazard.label then
      return false, 'hazard binding must reference hazard actor'
    end
  end

  local ambientValid, ambientError = ambientTrafficManager.validate(definition.ambientTraffic)
  if not ambientValid then return false, 'invalid ambient traffic: '..tostring(ambientError) end

  local triggerValid, triggerError = triggerEngine.validate(definition.triggers)
  if not triggerValid then return false, 'invalid triggers: '..tostring(triggerError) end
  for _, trigger in ipairs(definition.triggers or {}) do
    if not labels[trigger.subject] then return false, trigger.id..' references unknown subject '..tostring(trigger.subject) end
    if not labels[trigger.target] then return false, trigger.id..' references unknown target '..tostring(trigger.target) end
    local actionActor = trigger.action and trigger.action.actor or trigger.subject
    if not labels[actionActor] then return false, trigger.id..' action references unknown actor '..tostring(actionActor) end
  end

  return true
end

for id, definition in pairs(definitions) do
  local valid, errorMessage = validate(definition)
  if not valid then error('Invalid scenario definition '..tostring(id)..': '..tostring(errorMessage)) end
end

function M.get(id)
  id = tostring(id or '')
  local definition = definitions[id]
  if not definition then return nil, 'not registered' end
  return deepCopy(definition)
end

function M.list()
  local result = {}
  for _, definition in pairs(definitions) do
    table.insert(result, {
      id = definition.id,
      version = definition.version,
      name = definition.name,
      description = definition.description,
      actorCount = #(definition.convoy or {}) + (definition.hazard and 1 or 0),
      ambientCount = tonumber(definition.ambientTraffic and definition.ambientTraffic.count) or 0,
      totalVehicleCount = #(definition.convoy or {}) + (definition.hazard and 1 or 0) + (tonumber(definition.ambientTraffic and definition.ambientTraffic.count) or 0),
      triggerCount = #(definition.triggers or {}),
      scenarioDuration = definition.scenarioDuration,
    })
  end
  table.sort(result, function(a, b) return tostring(a.id) < tostring(b.id) end)
  return result
end

function M.copy(value)
  return deepCopy(value)
end

function M.validate(definition)
  return validate(definition)
end

return M
