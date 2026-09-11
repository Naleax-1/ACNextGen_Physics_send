---@diagnostic disable: undefined-global

--============================================================
-- worker_output.lua
-- ACNextGen Phase 3-A
-- Worker Output Verification
--
-- Responsibility:
--   Verify the complete transport chain:
--
--     Physics Hub
--       -> Bridge Input
--       -> CSP Physics Worker
--       -> Worker Output
--       -> Observer
--
-- This module NEVER:
--   * changes AC physics
--   * calculates new physics
--   * injects force
--   * replaces Physics Hub calculations
--
-- It only validates and republishes upstream results.
--============================================================

local M = {}

M.params = {
    staleTimeout = 0.75,
    expectedWheelCount = 4,
}

local state = {
    schema = "ACNextGen.WorkerOutput.v2",
    valid = false,

    tick = 0,
    source = "physics_worker",
    values = nil,

    error_count = 0,

    worker_alive = false,
    worker_input_valid = false,
    worker_output_valid = false,
    stale = true,

    current_tick = 0,
    last_valid_tick = 0,
    last_worker_tick = 0,
    last_update_time = 0.0,

    transfer_count = 0,
    status = "INIT",
    failure = "",

    input_sequence = 0,
    output_sequence = 0,

    input_force = { x = 0.0, y = 0.0, z = 0.0 },
    output_force = { x = 0.0, y = 0.0, z = 0.0 },

    checks = {
        vehicle_valid = false,
        wheels_valid = false,
        state_valid = false,
        numeric_valid = false,
        tick_valid = false,
        output_present = false,
        output_numeric = false,
        sequence_valid = false,
        injection_safe = true,
    },

    injection = {
        enabled = false,
        applied = 0,
        blocked = true,
    },
}

M.state = state

local function finite(v)
    local n = tonumber(v)
    return n ~= nil
        and n == n
        and n ~= math.huge
        and n ~= -math.huge
end

local function bool(v)
    return v == true or v == 1
end

local function countWheels(car)
    if not car then return 0 end

    local wheels = car.wheels
    if not wheels then return 0 end

    local count = 0

    for i = 0, 3 do
        local ok, wheel = pcall(function()
            return wheels[i] or wheels[i + 1]
        end)

        if ok and wheel ~= nil then
            count = count + 1
        end
    end

    return count
end

local function validateVehicle(runtime)
    local vehicle =
        runtime
        and runtime.state
        and runtime.state.vehicle

    if not vehicle or vehicle.valid ~= true then
        return false
    end

    return finite(vehicle.speedKmh)
       and finite(vehicle.rpm)
       and finite(vehicle.gear)
       and finite(vehicle.steer)
       and finite(vehicle.brake)
       and finite(vehicle.gas)
end

local function validateWheels(car, runtime)
    local runtimeOK =
        runtime
        and runtime.state
        and runtime.state.vehicle
        and runtime.state.vehicle.wheelsValid == true

    return runtimeOK
       and countWheels(car) == M.params.expectedWheelCount
end

local function validateState(runtime)
    if not runtime then return false end
    if not finite(runtime.frame) then return false end
    if not finite(runtime.time) then return false end
    if not finite(runtime.state and runtime.state.dt) then return false end
    return true
end

local function scanNumeric(value, depth)
    depth = depth or 0

    if depth > 6 then
        return true
    end

    local t = type(value)

    if t == "number" then
        return finite(value)
    end

    if t == "nil"
    or t == "boolean"
    or t == "string" then
        return true
    end

    if t ~= "table" then
        return false
    end

    for _, child in pairs(value) do
        if not scanNumeric(child, depth + 1) then
            return false
        end
    end

    return true
end

local function getHub(runtime)
    if not runtime then return nil end

    if runtime.moduleStates
    and runtime.moduleStates.physics then
        return runtime.moduleStates.physics
    end

    if runtime.physicsHub then
        return runtime.physicsHub
    end

    return nil
end

local function getBridge(runtime)
    if not runtime then return nil end

    if runtime.physicsBridge then
        return runtime.physicsBridge
    end

    if runtime.moduleStates
    and runtime.moduleStates.physics_bridge then
        return runtime.moduleStates.physics_bridge
    end

    return nil
end

local function resetFailure(message)
    state.error_count =
        (state.error_count or 0) + 1

    state.failure =
        tostring(message or "verification failure")
end

local function publish()
    if not ac or not ac.store then
        return
    end

    local function put(key, value)
        pcall(ac.store, key, value)
    end

    put("ngp_worker_schema", state.schema)
    put("ngp_worker_valid", state.valid and 1 or 0)
    put("ngp_worker_tick", state.tick)
    put("ngp_worker_source", state.source)
    put("ngp_worker_error_count", state.error_count)

    put("ngp_worker_alive", state.worker_alive and 1 or 0)
    put("ngp_worker_input_valid", state.worker_input_valid and 1 or 0)
    put("ngp_worker_output_valid", state.worker_output_valid and 1 or 0)
    put("ngp_worker_stale", state.stale and 1 or 0)

    put("ngp_worker_current_tick", state.current_tick)
    put("ngp_worker_last_valid_tick", state.last_valid_tick)
    put("ngp_worker_last_tick", state.last_worker_tick)

    put("ngp_worker_transfer_count", state.transfer_count)

    put("ngp_worker_input_sequence", state.input_sequence)
    put("ngp_worker_output_sequence", state.output_sequence)

    put("ngp_worker_input_force_x", state.input_force.x)
    put("ngp_worker_input_force_y", state.input_force.y)
    put("ngp_worker_input_force_z", state.input_force.z)

    put("ngp_worker_output_force_x", state.output_force.x)
    put("ngp_worker_output_force_y", state.output_force.y)
    put("ngp_worker_output_force_z", state.output_force.z)

    put("ngp_worker_status", state.status)
    put("ngp_worker_failure", state.failure)

    put("ngp_worker_vehicle_valid", state.checks.vehicle_valid and 1 or 0)
    put("ngp_worker_wheels_valid", state.checks.wheels_valid and 1 or 0)
    put("ngp_worker_state_valid", state.checks.state_valid and 1 or 0)
    put("ngp_worker_numeric_valid", state.checks.numeric_valid and 1 or 0)
    put("ngp_worker_tick_valid", state.checks.tick_valid and 1 or 0)
    put("ngp_worker_output_present", state.checks.output_present and 1 or 0)
    put("ngp_worker_output_numeric", state.checks.output_numeric and 1 or 0)
    put("ngp_worker_sequence_valid", state.checks.sequence_valid and 1 or 0)
    put("ngp_worker_injection_safe", state.checks.injection_safe and 1 or 0)

    -- Hard Phase 3-A injection gate.
    put("ngp_worker_injection_enabled", 0)
    put("ngp_worker_injection_applied", 0)
    put("ngp_worker_injection_blocked", 1)
end

function M.init()
    state.valid = false
    state.status = "PHASE_3A_READY"

    state.injection.enabled = false
    state.injection.applied = 0
    state.injection.blocked = true

    publish()
end

function M.update(dt, car, runtime)
    -- error_count represents the current verification frame, not a permanent
    -- historical counter. A startup WAIT must not poison a later PASS.
    state.error_count = 0
    state.failure = ""

    local hub = getHub(runtime)
    local bridge = getBridge(runtime)

    local elapsed =
        runtime and tonumber(runtime.time) or 0.0

    if not finite(elapsed) then
        elapsed = 0.0
    end

    state.current_tick =
        math.floor(
            tonumber(bridge and bridge.workerTicks) or 0
        )

    state.worker_alive =
        bridge ~= nil
        and bridge.workerAlive == true

    state.worker_input_valid =
        bridge ~= nil
        and bridge.workerInputValid == true

    state.worker_output_valid =
        bridge ~= nil
        and bridge.workerOutputValid == true

    state.transfer_count =
        math.floor(
            tonumber(bridge and bridge.transferCount) or 0
        )

    state.input_sequence =
        math.floor(
            tonumber(bridge and bridge.inputSequence) or 0
        )

    state.output_sequence =
        math.floor(
            tonumber(bridge and bridge.workerOutputSequence) or 0
        )

    local body =
        hub
        and hub.output
        and hub.output.body

    state.checks.vehicle_valid =
        validateVehicle(runtime)

    state.checks.wheels_valid =
        validateWheels(car, runtime)

    state.checks.state_valid =
        validateState(runtime)

    state.checks.output_present =
        hub ~= nil
        and hub.output ~= nil
        and hub.output.schema == "ACNextGen.PhysicsHub.v1"
        and hub.output.valid == true

    state.checks.output_numeric =
        state.checks.output_present
        and scanNumeric(hub.output)
        or false

    state.checks.numeric_valid =
        state.checks.vehicle_valid
        and state.checks.state_valid
        and state.checks.output_numeric

    state.checks.sequence_valid =
        state.worker_input_valid
        and state.worker_output_valid
        and state.input_sequence > 0
        and state.output_sequence == state.input_sequence

    local previousTick = state.last_worker_tick
    local tickAdvanced =
        state.current_tick > previousTick

    state.checks.tick_valid =
        state.current_tick > 0
        and (tickAdvanced or state.tick == 0)

    if state.current_tick > 0 then
        state.last_worker_tick =
            state.current_tick
    end

    -- A worker tick is considered fresh as soon as it is observed.
    if state.worker_alive and state.current_tick > 0 then
        state.stale = false
        state.last_update_time = elapsed
    else
        state.stale =
            elapsed - state.last_update_time
            > M.params.staleTimeout
    end

    if not state.worker_alive then
        state.stale = true
    end

    -- Read-only Worker Output mirror.
    if bridge and bridge.workerOutput then
        state.output_force.x =
            tonumber(bridge.workerOutput.x) or 0.0

        state.output_force.y =
            tonumber(bridge.workerOutput.y) or 0.0

        state.output_force.z =
            tonumber(bridge.workerOutput.z) or 0.0
    else
        state.output_force.x = 0.0
        state.output_force.y = 0.0
        state.output_force.z = 0.0
    end

    if bridge and bridge.bodyForce then
        state.input_force.x =
            tonumber(bridge.bodyForce.x) or 0.0

        state.input_force.y =
            tonumber(bridge.bodyForce.y) or 0.0

        state.input_force.z =
            tonumber(bridge.bodyForce.z) or 0.0
    else
        state.input_force.x = 0.0
        state.input_force.y = 0.0
        state.input_force.z = 0.0
    end

    state.checks.injection_safe =
        bridge ~= nil
        and bridge.injectionEnabled ~= true
        and (bridge.appliedCount or 0) == 0

    local outputValid =
        state.worker_alive
        and state.worker_input_valid
        and state.worker_output_valid
        and state.checks.vehicle_valid
        and state.checks.wheels_valid
        and state.checks.state_valid
        and state.checks.numeric_valid
        and state.checks.output_present
        and state.checks.output_numeric
        and state.checks.tick_valid
        and state.checks.sequence_valid
        and not state.stale
        and state.checks.injection_safe

    if outputValid then
        state.tick = state.current_tick
        state.last_valid_tick = state.current_tick
        state.values = hub.output
        state.valid = true
        state.status = "PHASE_3A_PASS"
        state.failure = ""
    else
        state.valid = false

        if not state.checks.injection_safe then
            state.status = "PHASE_3A_INJECTION_GUARD"
            resetFailure("injection guard violated")
        elseif not state.worker_alive then
            state.status = "PHASE_3A_WORKER_WAIT"
            resetFailure("worker not alive")
        elseif not state.checks.vehicle_valid then
            state.status = "PHASE_3A_INPUT_INVALID"
            resetFailure("vehicle state invalid")
        elseif not state.checks.wheels_valid then
            state.status = "PHASE_3A_INPUT_INVALID"
            resetFailure("wheel state invalid")
        elseif not state.checks.output_present then
            state.status = "PHASE_3A_OUTPUT_WAIT"
            resetFailure("physics hub output missing")
        elseif not state.worker_input_valid then
            state.status = "PHASE_3A_INPUT_WAIT"
            resetFailure("worker input invalid")
        elseif not state.worker_output_valid then
            state.status = "PHASE_3A_OUTPUT_WAIT"
            resetFailure("worker output invalid")
        elseif not state.checks.sequence_valid then
            state.status = "PHASE_3A_SEQUENCE_WAIT"
            resetFailure("worker input/output sequence mismatch")
        elseif state.stale then
            state.status = "PHASE_3A_STALE"
            resetFailure("worker heartbeat stale")
        else
            state.status = "PHASE_3A_VERIFYING"
        end
    end

    -- Absolute Phase 3-A safety state.
    state.injection.enabled = false
    state.injection.applied = 0
    state.injection.blocked = true

    publish()
end

function M.getState()
    return state
end

return M
