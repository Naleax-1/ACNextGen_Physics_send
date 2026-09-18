---@diagnostic disable: undefined-global
-- Phase 3-A contract validator. Consumes ONLY worker-returned snapshots.
-- No force calculations, no application API, and no Observer-owned verdict.
local M = { params = { staleTimeout = 0.75, expectedWheelCount = 4 } }
local state = {
    schema = 'ACNextGen.WorkerOutput.v3', source = 'physics_worker',
    available = false, valid = false, transport_pass = false, values = nil, tick = 0, timestamp = nil,
    error_count = 0, failure = '', status = 'INIT',
    worker_alive = false, worker_input_valid = false, worker_output_valid = false,
    current_tick = 0, last_worker_tick = 0, last_valid_tick = 0,
    last_update_time = 0, stale = true, stale_time = 0, tick_fresh = false,
    input_available = false, input_sequence = 0, output_sequence = 0,
    pending_sequence = 0, transfer_count = 0, transfer_delta = 0,
    input_force = { x = 0, y = 0, z = 0 }, output_force = { x = 0, y = 0, z = 0 },
    body_available = false, checks = {},
    injection = { enabled = false, applied = 0, blocked = true },
}
M.state = state
local ownErrors, lastFault = 0, ''
local function finite(v)
    return type(v) == 'number' and v == v and v ~= math.huge and v ~= -math.huge
end
local function fault(message)
    if message ~= lastFault then ownErrors = ownErrors + 1 end
    lastFault, state.failure = message, message
end
local function validWheels(car)
    if not car then return false end
    -- CSP wheels are zero-based. Do not count wheel 1 twice if FL is absent.
    for i = 0, 3 do
        local ok, w = pcall(function() return car.wheels[i] end)
        if not ok or w == nil then return false end
    end
    return true
end
local function validVehicle(runtime)
    local v = runtime and runtime.state and runtime.state.vehicle
    if not v or v.valid ~= true or v.wheelsValid ~= true then return false end
    for _, k in ipairs({'speedKmh', 'rpm', 'steer', 'gear', 'brake', 'gas'}) do
        if not finite(v[k]) then return false end
    end
    return true
end
local function validPayload(out)
    if type(out) ~= 'table' or out.schema ~= state.schema or out.available ~= true then return false end
    if not finite(out.sequence) or out.sequence <= 0 or out.sequence % 1 ~= 0
        or not finite(out.tick) or out.tick <= 0 or out.tick % 1 ~= 0
        or not finite(out.timestamp) then return false end
    if type(out.body) ~= 'table' or type(out.body.available) ~= 'boolean'
        or type(out.vehicle) ~= 'table' or type(out.wheel) ~= 'table' then return false end
    if out.body.available then
        for _, k in ipairs({'forceX', 'forceY', 'forceZ'}) do
            if not finite(out.body[k]) then return false end
        end
    end
    for _, k in ipairs({'speedKmh', 'rpm', 'steer', 'gear', 'brake', 'gas'}) do
        if not out.vehicle or not finite(out.vehicle[k]) then return false end
    end
    for i = 0, 3 do
        local w = out.wheel and out.wheel[i]
        if type(w) ~= 'table' or w.available ~= true then return false end
        for _, k in ipairs({'lateralForce', 'longitudinalForce', 'load', 'slipRatio', 'slipAngle', 'omega'}) do
            if not finite(w[k]) then return false end
        end
    end
    return true
end
local function publish()
    if not ac or not ac.store then return end
    for _, key in ipairs({'schema', 'valid', 'tick', 'source', 'error_count', 'worker_alive',
            'worker_input_valid', 'worker_output_valid', 'stale', 'stale_time',
            'current_tick', 'last_valid_tick', 'last_worker_tick', 'transfer_count',
            'transfer_delta', 'input_sequence', 'output_sequence', 'pending_sequence',
            'status', 'failure', 'available', 'body_available', 'transport_pass'}) do
        local value = state[key]
        if type(value) == 'boolean' then value = value and 1 or 0 end
        pcall(ac.store, 'ngp_worker_' .. key, value)
    end
    for k, v in pairs(state.checks) do pcall(ac.store, 'ngp_worker_' .. k, v and 1 or 0) end
    for _, kind in ipairs({'input_force', 'output_force'}) do
        for _, axis in ipairs({'x', 'y', 'z'}) do
            pcall(ac.store, 'ngp_worker_' .. kind .. '_' .. axis, state[kind][axis])
        end
    end
    pcall(ac.store, 'ngp_worker_injection_enabled', state.injection.enabled and 1 or 0)
    pcall(ac.store, 'ngp_worker_injection_applied', state.injection.applied)
    pcall(ac.store, 'ngp_worker_injection_blocked', 1)
end
function M.init() state.status = 'PHASE_3A_READY'; publish() end
function M.update(dt, car, runtime)
    local b = runtime and (runtime.physicsBridge or (runtime.moduleStates or {}).physics_bridge)
    local out = b and b.workerOutput
    if type(out) ~= 'table' then out = nil end
    local now = runtime and runtime.time
    local c = state.checks
    c.state_valid = finite(now) and finite(runtime.frame)
        and runtime.state ~= nil and finite(runtime.state.dt)
    if not c.state_valid then now = 0 end
    c.vehicle_valid = validVehicle(runtime)
    c.wheels_valid = validWheels(car)
    state.worker_alive = b ~= nil and b.workerAlive == true
    state.current_tick = b and b.workerTicks or 0
    if state.current_tick > state.last_worker_tick then state.last_update_time = now end
    state.last_worker_tick = state.current_tick
    state.tick_fresh = state.worker_alive and state.current_tick > 0
        and now >= state.last_update_time and now - state.last_update_time <= M.params.staleTimeout
    c.tick_valid = state.tick_fresh
    state.available = out ~= nil and out.available == true
    state.timestamp = state.available and out.timestamp or nil
    state.stale_time = finite(state.timestamp) and now - state.timestamp or 0
    state.stale = not state.available or not finite(state.timestamp)
        or state.stale_time < 0 or state.stale_time > M.params.staleTimeout or not state.tick_fresh
    state.input_available = b ~= nil and b.inputAvailable == true
    state.worker_input_valid = b ~= nil and b.workerInputValid == true
    state.input_sequence = b and b.inputSequence or 0
    state.output_sequence = out and out.sequence or 0
    state.pending_sequence = b and b.pendingSequence or 0
    local count = b and b.transferCount or 0
    state.transfer_delta = math.max(0, count - state.transfer_count)
    state.transfer_count = count
    c.output_present = state.available
    c.output_numeric = validPayload(out)
    c.numeric_valid = c.state_valid and c.vehicle_valid and c.output_numeric
    c.sequence_valid = state.available and state.input_sequence > 0
        and state.input_sequence == state.output_sequence
        and b.workerOutputSequence == state.output_sequence
    state.injection.enabled = b ~= nil and b.injectionEnabled == true
    state.injection.applied = b and b.appliedCount or 0
    c.injection_safe = b ~= nil and not state.injection.enabled and state.injection.applied == 0
    state.body_available = state.available and type(out.body) == 'table' and out.body.available == true
    state.input_force = b and b.bodyForce or {x=0, y=0, z=0}
    state.output_force = { x = out and out.forceX or 0, y = out and out.forceY or 0, z = out and out.forceZ or 0 }
    -- Startup WAIT is not an error. Real faults persist until app reload.
    local problem
    if b and not c.injection_safe then problem = 'injection guard violated'
    elseif not c.state_valid then problem = 'runtime state invalid'
    elseif state.available and not c.output_numeric then problem = 'worker payload invalid'
    elseif state.available and not c.sequence_valid then problem = 'worker sequence mismatch'
    elseif state.available and state.stale then problem = 'worker result/heartbeat stale'
    end
    if problem then fault(problem) else lastFault = '' end
    state.error_count = ownErrors + (b and b.errorCount or 0) + (runtime and runtime.totalErrorCount or 0)
    if b and b.workerError ~= '' then state.failure = b.workerError end
    if runtime and (runtime.totalErrorCount or 0) > 0 then state.failure = runtime.lastError or 'runtime error' end
    state.worker_output_valid = state.available and out.valid == true
        and b.workerOutputValid == true and c.numeric_valid and c.sequence_valid
        and not state.stale and c.injection_safe and c.wheels_valid and state.error_count == 0
    state.valid = state.worker_output_valid and state.worker_input_valid
        and c.wheels_valid and state.error_count == 0 and state.transfer_count > 0
    state.values = state.valid and out or nil
    state.transport_pass = state.valid and state.transfer_delta > 0
    state.tick = state.available and out.tick or 0
    if state.valid then
        state.last_valid_tick = state.tick
        -- Transport scope only: not full Phase 3-A, AC application or behavior.
        state.status = state.transport_pass and 'PHASE_3A_TRANSPORT_PASS' or 'PHASE_3A_TRANSPORT_FRESH'
    elseif state.error_count > 0 then state.status = 'PHASE_3A_ERROR'
    elseif not c.vehicle_valid or not c.wheels_valid then state.status = 'PHASE_3A_INPUT_INVALID'
    elseif not state.worker_alive then state.status = 'PHASE_3A_WORKER_WAIT'
    elseif state.stale and state.available then state.status = 'PHASE_3A_STALE'
    else state.status = 'PHASE_3A_OUTPUT_WAIT' end
    publish()
end
function M.getState() return state end
return M
