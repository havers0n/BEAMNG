-- Generic trigger runtime for Scenario Engine v2.
-- This module does not know about BeamNG vehicles or controller commands.
-- The host extension supplies metric measurement and action execution callbacks.
local M = {}

local supportedMetrics = {
  distance = true,
  relative_speed = true,
  ttc = true,
}

local supportedOperators = {
  ['<'] = true,
  ['<='] = true,
  ['>'] = true,
  ['>='] = true,
  ['=='] = true,
  ['~='] = true,
}

local supportedActions = {
  brake = true,
  brake_pulse = true,
  stop = true,
  swerve = true,
  resume = true,
  set_speed = true,
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

local function normalizeStringList(value)
  if value == nil then return {} end
  if type(value) == 'string' then return {value} end
  if type(value) ~= 'table' then return nil end
  local result = {}
  for _, item in ipairs(value) do
    if type(item) ~= 'string' or item == '' then return nil end
    table.insert(result, item)
  end
  return result
end

local function normalizeRequires(value)
  return normalizeStringList(value)
end

local function normalizeRequiresGroups(value)
  return normalizeStringList(value)
end

local function getTriggerGroup(trigger)
  if type(trigger.group) == 'string' and trigger.group ~= '' then return trigger.group end
  return nil
end

function M.validate(definitions)
  if type(definitions) ~= 'table' then return false, 'triggers must be a table' end
  if #definitions == 0 then return false, 'at least one trigger is required' end

  local ids = {}
  local groups = {}
  for index, trigger in ipairs(definitions) do
    if type(trigger) ~= 'table' then return false, 'trigger #'..index..' must be a table' end
    if type(trigger.id) ~= 'string' or trigger.id == '' then return false, 'trigger #'..index..' needs an id' end
    if ids[trigger.id] then return false, 'duplicate trigger id: '..trigger.id end
    ids[trigger.id] = true

    local metric = trigger.metric or trigger.type
    if not supportedMetrics[metric] then
      return false, trigger.id..' has unsupported metric '..tostring(metric)
    end
    local operator = trigger.operator or '<='
    if not supportedOperators[operator] then
      return false, trigger.id..' has unsupported operator '..tostring(operator)
    end
    if tonumber(trigger.threshold) == nil then return false, trigger.id..' needs a numeric threshold' end
    if type(trigger.subject) ~= 'string' or trigger.subject == '' then return false, trigger.id..' needs a subject' end
    if type(trigger.target) ~= 'string' or trigger.target == '' then return false, trigger.id..' needs a target' end

    local delaySeconds = tonumber(trigger.delaySeconds or 0)
    if delaySeconds == nil or delaySeconds < 0 then
      return false, trigger.id..' delaySeconds must be a non-negative number'
    end
    if trigger.minRelativeSpeed ~= nil and tonumber(trigger.minRelativeSpeed) == nil then
      return false, trigger.id..' minRelativeSpeed must be numeric'
    end
    if trigger.fallbackUnavailableSeconds ~= nil then
      local fallbackWait = tonumber(trigger.fallbackUnavailableSeconds)
      if fallbackWait == nil or fallbackWait < 0 then
        return false, trigger.id..' fallbackUnavailableSeconds must be a non-negative number'
      end
    end

    local group = getTriggerGroup(trigger)
    if trigger.group ~= nil and not group then
      return false, trigger.id..' group must be a non-empty string'
    end
    if group then groups[group] = true end

    local action = trigger.action
    if type(action) ~= 'table' then return false, trigger.id..' needs an action' end
    if not supportedActions[action.type] then
      return false, trigger.id..' has unsupported action '..tostring(action.type)
    end
    if (action.type == 'brake' or action.type == 'brake_pulse') and action.amount ~= nil and tonumber(action.amount) == nil then
      return false, trigger.id..' brake action amount must be numeric'
    end
    if action.type == 'brake_pulse' then
      local duration = tonumber(action.duration)
      if duration == nil or duration <= 0 then
        return false, trigger.id..' brake_pulse action duration must be a positive number'
      end
    end
    if action.type == 'set_speed' and tonumber(action.speedMps) == nil then
      return false, trigger.id..' set_speed action speedMps must be numeric'
    end
    if action.type == 'swerve' and action.amount ~= nil and tonumber(action.amount) == nil then
      return false, trigger.id..' swerve action amount must be numeric'
    end

    local requires = normalizeRequires(trigger.requires)
    if not requires then return false, trigger.id..' requires must be a string or list of strings' end
    local requiresGroups = normalizeRequiresGroups(trigger.requiresGroup or trigger.requiresGroups)
    if not requiresGroups then
      return false, trigger.id..' requiresGroup/requiresGroups must be a string or list of strings'
    end
  end

  for _, trigger in ipairs(definitions) do
    local requires = normalizeRequires(trigger.requires) or {}
    for _, requiredId in ipairs(requires) do
      if not ids[requiredId] then return false, trigger.id..' requires unknown trigger '..requiredId end
      if requiredId == trigger.id then return false, trigger.id..' cannot require itself' end
    end

    local requiresGroups = normalizeRequiresGroups(trigger.requiresGroup or trigger.requiresGroups) or {}
    for _, requiredGroup in ipairs(requiresGroups) do
      if not groups[requiredGroup] then
        return false, trigger.id..' requires unknown trigger group '..requiredGroup
      end
      if requiredGroup == getTriggerGroup(trigger) then
        return false, trigger.id..' cannot require its own trigger group '..requiredGroup
      end
    end

    if trigger.fallbackFor ~= nil then
      if type(trigger.fallbackFor) ~= 'string' or trigger.fallbackFor == '' then
        return false, trigger.id..' fallbackFor must be a non-empty trigger id'
      end
      if not ids[trigger.fallbackFor] then
        return false, trigger.id..' fallbackFor references unknown trigger '..trigger.fallbackFor
      end
      if trigger.fallbackFor == trigger.id then
        return false, trigger.id..' cannot fallback to itself'
      end
    end
  end

  return true
end

local function createState(trigger)
  return {
    id = trigger.id,
    fired = false,
    firedAt = nil,
    fireCount = 0,
    pending = false,
    matchedAt = nil,
    executeAt = nil,
    pendingMetrics = nil,
    pendingSource = nil,
    blockedBy = nil,
    lastMetrics = nil,
    lastValue = nil,
    lastActionResult = nil,
    lastError = nil,
    metricAvailable = nil,
    unavailableSince = nil,
  }
end

function M.create(definitions)
  local valid, errorMessage = M.validate(definitions)
  if not valid then return nil, errorMessage end

  local copiedDefinitions = deepCopy(definitions)
  local runtime = {
    definitions = copiedDefinitions,
    definitionsById = {},
    states = {},
    groups = {},
    events = {},
    sequence = 0,
  }

  for _, trigger in ipairs(copiedDefinitions) do
    runtime.definitionsById[trigger.id] = trigger
    runtime.states[trigger.id] = createState(trigger)
    local group = getTriggerGroup(trigger)
    if group and not runtime.groups[group] then
      runtime.groups[group] = {
        id = group,
        status = 'idle',
        triggerId = nil,
        matchedAt = nil,
        firedAt = nil,
      }
    end
  end
  return runtime
end

function M.reset(runtime)
  if type(runtime) ~= 'table' or type(runtime.definitions) ~= 'table' then
    return nil, 'invalid trigger runtime'
  end
  local fresh, errorMessage = M.create(runtime.definitions)
  if not fresh then return nil, errorMessage end
  runtime.definitionsById = fresh.definitionsById
  runtime.states = fresh.states
  runtime.groups = fresh.groups
  runtime.events = {}
  runtime.sequence = 0
  return runtime
end

local function compare(value, operator, threshold)
  if value == nil then return false end
  if operator == '<' then return value < threshold end
  if operator == '<=' then return value <= threshold end
  if operator == '>' then return value > threshold end
  if operator == '>=' then return value >= threshold end
  if operator == '==' then return value == threshold end
  if operator == '~=' then return value ~= threshold end
  return false
end

local function dependenciesSatisfied(runtime, trigger)
  local requires = normalizeRequires(trigger.requires) or {}
  for _, requiredId in ipairs(requires) do
    local requiredState = runtime.states[requiredId]
    if not requiredState or not requiredState.fired then return false end
  end

  local requiresGroups = normalizeRequiresGroups(trigger.requiresGroup or trigger.requiresGroups) or {}
  for _, requiredGroup in ipairs(requiresGroups) do
    local groupState = runtime.groups[requiredGroup]
    if not groupState or groupState.status ~= 'fired' then return false end
  end
  return true
end

local function groupAvailable(runtime, trigger)
  local group = getTriggerGroup(trigger)
  if not group then return true end
  local groupState = runtime.groups[group]
  if not groupState then return true end
  if groupState.status == 'idle' then return true end
  return groupState.triggerId == trigger.id
end

local function reserveGroup(runtime, trigger, status, elapsed)
  local group = getTriggerGroup(trigger)
  if not group then return true end
  local groupState = runtime.groups[group]
  if not groupState then
    groupState = {id = group, status = 'idle'}
    runtime.groups[group] = groupState
  end
  if groupState.status ~= 'idle' and groupState.triggerId ~= trigger.id then
    return false, groupState.triggerId
  end
  groupState.status = status or 'pending'
  groupState.triggerId = trigger.id
  groupState.matchedAt = groupState.matchedAt or elapsed
  return true
end

local function releaseGroup(runtime, trigger)
  local group = getTriggerGroup(trigger)
  if not group then return end
  local groupState = runtime.groups[group]
  if groupState and groupState.triggerId == trigger.id and groupState.status ~= 'fired' then
    groupState.status = 'idle'
    groupState.triggerId = nil
    groupState.matchedAt = nil
    groupState.firedAt = nil
  end
end

local function getMetricValue(trigger, metrics)
  local metric = trigger.metric or trigger.type
  if metric == 'distance' then return metrics and metrics.distance end
  if metric == 'relative_speed' then return metrics and metrics.relativeSpeed end
  if metric == 'ttc' then return metrics and metrics.ttc end
  return nil
end

local function metricRequirementsSatisfied(trigger, metrics)
  if not metrics then return false end
  local positiveDistanceRequired = trigger.requirePositiveDistance ~= false
  if positiveDistanceRequired and metrics.distance ~= nil and metrics.distance <= 0 then return false end
  if trigger.minRelativeSpeed ~= nil then
    if metrics.relativeSpeed == nil or metrics.relativeSpeed < tonumber(trigger.minRelativeSpeed) then return false end
  end
  return true
end

local function metricValueIsAvailable(trigger, metrics)
  if not metrics then return false end
  local value = getMetricValue(trigger, metrics)
  if type(value) ~= 'number' or value ~= value or value == math.huge or value == -math.huge then
    return false
  end
  return metricRequirementsSatisfied(trigger, metrics)
end

local function updateMetricAvailability(state, trigger, metrics, elapsed)
  local available = metricValueIsAvailable(trigger, metrics)
  state.metricAvailable = available
  if available then
    state.unavailableSince = nil
  elseif state.unavailableSince == nil then
    state.unavailableSince = elapsed
  end
end

local function fallbackRequirementsSatisfied(runtime, trigger, elapsed)
  if trigger.fallbackFor == nil then return true end
  local primaryState = runtime.states and runtime.states[trigger.fallbackFor]
  if not primaryState then return false, trigger.fallbackFor end
  if primaryState.fired or primaryState.pending then return false, trigger.fallbackFor end
  if primaryState.metricAvailable ~= false then return false, trigger.fallbackFor end
  local waitSeconds = math.max(0, tonumber(trigger.fallbackUnavailableSeconds) or 0)
  local unavailableSince = primaryState.unavailableSince
  if unavailableSince == nil or elapsed - unavailableSince < waitSeconds then
    return false, trigger.fallbackFor
  end
  return true
end

local function canEvaluate(runtime, trigger, elapsed)
  local state = runtime.states[trigger.id]
  if not state then return false end
  if trigger.enabled == false then return false end
  if state.pending then return false end
  if trigger.once ~= false and state.fired then return false end
  if trigger.minElapsed ~= nil and elapsed < tonumber(trigger.minElapsed) then return false end
  if trigger.maxElapsed ~= nil and elapsed > tonumber(trigger.maxElapsed) then return false end
  if not groupAvailable(runtime, trigger) then
    local groupState = runtime.groups[getTriggerGroup(trigger)]
    state.blockedBy = groupState and groupState.triggerId or nil
    return false
  end
  local fallbackReady, fallbackHolder = fallbackRequirementsSatisfied(runtime, trigger, elapsed)
  if not fallbackReady then
    state.blockedBy = 'fallback:'..tostring(fallbackHolder)
    return false
  end
  state.blockedBy = nil
  return dependenciesSatisfied(runtime, trigger)
end

local function buildEvent(runtime, trigger, state, metrics, elapsed, source)
  runtime.sequence = runtime.sequence + 1
  local matchedAt = state.matchedAt or elapsed
  return {
    sequence = runtime.sequence,
    id = trigger.id,
    group = getTriggerGroup(trigger),
    matchedAt = matchedAt,
    firedAt = elapsed,
    reactionDelay = math.max(0, elapsed - matchedAt),
    configuredDelay = tonumber(trigger.delaySeconds) or 0,
    source = source or 'condition',
    subject = trigger.subject,
    target = trigger.target,
    metric = trigger.metric or trigger.type,
    operator = trigger.operator or '<=',
    threshold = tonumber(trigger.threshold),
    value = getMetricValue(trigger, metrics),
    metrics = deepCopy(metrics or {}),
    action = deepCopy(trigger.action),
    phase = trigger.phase,
    legacyFlag = trigger.legacyFlag,
    legacyTimestamp = trigger.legacyTimestamp,
    fireCount = state.fireCount + 1,
  }
end

local function executeAndRecord(runtime, trigger, context, metrics, source)
  local state = runtime.states[trigger.id]
  local elapsed = tonumber(context.elapsed) or 0
  local reserved, holder = reserveGroup(runtime, trigger, 'pending', state.matchedAt or elapsed)
  if not reserved then
    state.blockedBy = holder
    return nil, 'trigger group already claimed by '..tostring(holder)
  end

  local event = buildEvent(runtime, trigger, state, metrics, elapsed, source)
  local ok, errorMessage = context.executeAction(event.action, trigger, metrics or {}, event)
  state.lastMetrics = deepCopy(metrics or {})
  state.lastValue = event.value
  state.lastActionResult = ok == true
  state.lastError = errorMessage

  if not ok then
    state.pending = false
    state.pendingMetrics = nil
    state.pendingSource = nil
    state.executeAt = nil
    releaseGroup(runtime, trigger)
    return nil, errorMessage or 'action execution failed'
  end

  state.fired = true
  state.firedAt = elapsed
  state.fireCount = state.fireCount + 1
  state.pending = false
  state.executeAt = nil
  state.pendingMetrics = nil
  state.pendingSource = nil
  event.fireCount = state.fireCount
  table.insert(runtime.events, event)

  local group = getTriggerGroup(trigger)
  if group then
    local groupState = runtime.groups[group]
    groupState.status = 'fired'
    groupState.triggerId = trigger.id
    groupState.firedAt = elapsed
  end
  return event
end

local function scheduleTrigger(runtime, trigger, state, metrics, elapsed, source, context)
  local reserved, holder = reserveGroup(runtime, trigger, 'pending', elapsed)
  if not reserved then
    state.blockedBy = holder
    return false, 'trigger group already claimed by '..tostring(holder)
  end

  local delaySeconds = math.max(0, tonumber(trigger.delaySeconds) or 0)
  state.pending = true
  state.matchedAt = elapsed
  state.executeAt = elapsed + delaySeconds
  state.pendingMetrics = deepCopy(metrics or {})
  state.pendingSource = source or 'condition'
  state.lastMetrics = deepCopy(metrics or {})
  state.lastValue = getMetricValue(trigger, metrics)
  state.lastError = nil
  if context and type(context.onScheduled) == 'function' then
    context.onScheduled(trigger, deepCopy(state), deepCopy(metrics or {}))
  end
  return true
end

local function processPending(runtime, trigger, state, context, firedEvents)
  if not state.pending then return end
  local elapsed = tonumber(context.elapsed) or 0
  if elapsed < (state.executeAt or math.huge) then return end

  local metrics = state.pendingMetrics or state.lastMetrics or {}
  local source = state.pendingSource == 'condition' and 'delayed_condition' or (state.pendingSource or 'delayed')
  local event, actionError = executeAndRecord(runtime, trigger, context, metrics, source)
  if event then
    table.insert(firedEvents, event)
  else
    state.lastError = actionError
  end
end

function M.update(runtime, context)
  if type(runtime) ~= 'table' then return {}, 'invalid trigger runtime' end
  if type(context) ~= 'table' or type(context.measure) ~= 'function' or type(context.executeAction) ~= 'function' then
    return {}, 'invalid trigger context'
  end

  local elapsed = tonumber(context.elapsed) or 0
  local firedEvents = {}

  -- Delayed driver reactions execute before new conditions are considered.
  for _, trigger in ipairs(runtime.definitions or {}) do
    local state = runtime.states[trigger.id]
    processPending(runtime, trigger, state, context, firedEvents)
  end

  for _, trigger in ipairs(runtime.definitions or {}) do
    local state = runtime.states[trigger.id]
    local metrics, measureError = context.measure(trigger)
    if metrics then
      state.lastMetrics = deepCopy(metrics)
      state.lastValue = getMetricValue(trigger, metrics)
      updateMetricAvailability(state, trigger, metrics, elapsed)

      if canEvaluate(runtime, trigger, elapsed) and metricRequirementsSatisfied(trigger, metrics) then
        local metricValue = getMetricValue(trigger, metrics)
        if compare(metricValue, trigger.operator or '<=', tonumber(trigger.threshold)) then
          local delaySeconds = math.max(0, tonumber(trigger.delaySeconds) or 0)
          if delaySeconds > 0 then
            local scheduled, scheduleError = scheduleTrigger(runtime, trigger, state, metrics, elapsed, 'condition', context)
            if not scheduled then state.lastError = scheduleError end
          else
            state.matchedAt = elapsed
            local event, actionError = executeAndRecord(runtime, trigger, context, metrics, 'condition')
            if event then
              table.insert(firedEvents, event)
            else
              state.lastError = actionError
            end
          end
        end
      end
    else
      state.metricAvailable = false
      if state.unavailableSince == nil then state.unavailableSince = elapsed end
      state.lastError = measureError or 'metric measurement failed'
    end
  end

  return firedEvents
end

function M.fire(runtime, triggerId, context, metrics, source)
  if type(runtime) ~= 'table' then return nil, 'invalid trigger runtime' end
  if type(context) ~= 'table' or type(context.executeAction) ~= 'function' then return nil, 'invalid trigger context' end
  local trigger = runtime.definitionsById and runtime.definitionsById[tostring(triggerId or '')]
  if not trigger then return nil, 'unknown trigger '..tostring(triggerId) end

  local state = runtime.states[trigger.id]
  if trigger.once ~= false and state and state.fired then
    return nil, 'trigger already fired'
  end
  if state and state.pending then
    return nil, 'trigger action is already pending'
  end
  if not groupAvailable(runtime, trigger) then
    local groupState = runtime.groups[getTriggerGroup(trigger)]
    return nil, 'trigger group already resolved by '..tostring(groupState and groupState.triggerId)
  end

  if not metrics and type(context.measure) == 'function' then
    metrics = context.measure(trigger)
  end
  state.matchedAt = tonumber(context.elapsed) or 0
  return executeAndRecord(runtime, trigger, context, metrics or {}, source or 'manual')
end

function M.getDefinition(runtime, triggerId)
  if not runtime or not runtime.definitionsById then return nil end
  return runtime.definitionsById[tostring(triggerId or '')]
end

function M.getState(runtime, triggerId)
  if not runtime or not runtime.states then return nil end
  return runtime.states[tostring(triggerId or '')]
end

function M.getGroupState(runtime, groupId)
  if not runtime or not runtime.groups then return nil end
  return deepCopy(runtime.groups[tostring(groupId or '')])
end

function M.getEffectiveState(runtime, triggerId)
  local definition = M.getDefinition(runtime, triggerId)
  local state = M.getState(runtime, triggerId)
  if not definition or not state then return state, definition end
  local group = getTriggerGroup(definition)
  local groupState = group and runtime.groups and runtime.groups[group] or nil
  if groupState and groupState.triggerId and runtime.states[groupState.triggerId] then
    return runtime.states[groupState.triggerId], runtime.definitionsById[groupState.triggerId]
  end
  return state, definition
end

function M.listStates(runtime)
  local result = {}
  if not runtime then return result end
  for _, trigger in ipairs(runtime.definitions or {}) do
    table.insert(result, {
      definition = deepCopy(trigger),
      state = deepCopy(runtime.states and runtime.states[trigger.id] or nil),
      group = deepCopy(getTriggerGroup(trigger) and runtime.groups[getTriggerGroup(trigger)] or nil),
    })
  end
  return result
end

function M.getEvents(runtime)
  return deepCopy(runtime and runtime.events or {})
end

function M.copy(value)
  return deepCopy(value)
end

return M
