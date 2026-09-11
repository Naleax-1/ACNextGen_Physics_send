---@diagnostic disable: undefined-global
--============================================================
-- worker_output.lua
-- ACNextGen Phase 3-A
-- Worker Output Verification
--
-- Responsibility:
--   Verify that the Physics Worker receives validated Runtime State,
--   advances its tick, and exposes a safe WorkerOutput contract.
--
-- This module NEVER:
--   * changes AC physics
--   * calculates new physics
--   * injects forces
--   * replaces PhysicsHub calculations
--
-- It only verifies and republishes results produced upstream.
--============================================================

local M = {}

M.params = {
    staleTimeout = 0.25,
    expectedWheelCount = 4,
}

local state = {
    schema = "ACNextGen.WorkerOutput.v1",
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
    checks = {
        vehicle_valid = false,
        wheels_valid = false,
        state_valid = false,
        numeric_valid = false,
        tick_valid = false,
        output_present = false,
        output_numeric = false,
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
    return n ~= nil and n == n and n ~= math.huge and n ~= -math.huge
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
    local vehicle = runtime and runtime.state and runtime.state.vehicle
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
    local runtimeOK = runtime
        and runtime.state
        and runtime.state.vehicle
        and runtime.state.vehicle.wheelsValid == true

    return runtimeOK and countWheels(car) == M.params.expectedWheelCount
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
    if depth > 5 then
        return true
    end

    local t = type(value)
    if t == "number" then
        return finite(value)
    end
    if t == "nil" or t == "boolean" or t == "string" then
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

local function outputPresent(hub)
    if not hub or not hub.output then
        return false
    end
    return hub.output.schema == "ACNextGen.PhysicsHub.v1"
end

local function copyOutput(hub)
    -- Deliberately keep the live calculation result reference.
    -- No recalculation or transformation is performed here.
    return hub and hub.output or nil
end

local function resetFailure(message)
    state.error_count = (state.error_count or 0) + 1
    state.failure = tostring(message or "verification failure")
end

local function publish()
    if not ac or not ac.store then return end

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
    put("ngp_worker_status", state.status)
    put("ngp_worker_failure", state.failure)

    put("ngp_worker_vehicle_valid", state.checks.vehicle_valid and 1 or 0)
    put("ngp_worker_wheels_valid", state.checks.wheels_valid and 1 or 0)
    put("ngp_worker_state_valid", state.checks.state_valid and 1 or 0)
    put("ngp_worker_numeric_valid", state.checks.numeric_valid and 1 or 0)
    put("ngp_worker_tick_valid", state.checks.tick_valid and 1 or 0)
    put("ngp_worker_output_present", state.checks.output_present and 1 or 0)
    put("ngp_worker_output_numeric", state.checks.output_numeric and 1 or 0)

    -- Hard Phase 3-A injection gate.
    put("ngp_worker_injection_enabled", 0)
    put("ngp_worker_injection_applied", 0)
    put("ngp_worker_injection_blocked", 1)
end

function M.init()
    state.valid = false
    state.status = "READY"
    state.injection.enabled = false
    state.injection.applied = 0
    state.injection.blocked = true
    publish()
end

function M.update(dt, car, runtime)
    local hub = runtime
        and runtime.moduleStates
        and runtime.moduleStates.physics

    local bridge = runtime
        and (runtime.physicsBridge
            or (runtime.moduleStates and runtime.moduleStates.physics_bridge))

    local elapsed = runtime and tonumber(runtime.time) or 0.0
    if not finite(elapsed) then elapsed = 0.0 end

    state.current_tick = tonumber(bridge and bridge.workerTicks) or 0
    state.worker_alive = bridge and bridge.workerAlive == true or false
    state.worker_input_valid = bridge and bridge.workerInputValid == true or false

    state.checks.vehicle_valid = validateVehicle(runtime)
    state.checks.wheels_valid = validateWheels(car, runtime)
    state.checks.state_valid = validateState(runtime)

    state.checks.output_present = outputPresent(hub)
    state.checks.output_numeric =
        state.checks.output_present
        and scanNumeric(hub.output)
        or false

    state.checks.numeric_valid =
        state.checks.vehicle_valid
        and state.checks.state_valid
        and state.checks.output_numeric

    local previousTick = state.last_worker_tick
    local tickAdvanced = state.current_tick > previousTick
    state.checks.tick_valid = state.current_tick > 0 and (tickAdvanced or state.tick == 0)

    if state.current_tick > 0 then
        state.last_worker_tick = state.current_tick
    end

    state.stale =
        (not state.worker_alive)
        or state.current_tick <= 0
        or (state.last_valid_tick > 0
            and state.current_tick == state.last_valid_tick
            and elapsed - state.last_update_time > M.params.staleTimeout)

    local inputValid =
        state.checks.vehicle_valid
        and state.checks.wheels_valid
        and state.checks.state_valid
        and state.checks.numeric_valid

    state.worker_input_valid = state.worker_input_valid and inputValid

    local outputValid =
        state.worker_alive
        and state.worker_input_valid
        and state.checks.output_present
        and state.checks.output_numeric
        and not state.stale

    state.worker_output_valid = outputValid

    if outputValid then
        state.tick = state.current_tick
        state.last_valid_tick = state.current_tick
        state.values = copyOutput(hub)
        state.valid = true
        state.status = "PASS"
        state.failure = ""
        state.last_update_time = elapsed
        state.transfer_count = state.transfer_count + 1
    else
        state.valid = false
        state.status = state.worker_alive and "INVALID" or "STALLED"

        if not state.checks.vehicle_valid then
            resetFailure("vehicle state invalid")
        elseif not state.checks.wheels_valid then
            resetFailure("wheel state invalid")
        elseif not state.checks.state_valid then
            resetFailure("runtime state invalid")
        elseif not state.worker_alive then
            resetFailure("worker not alive")
        elseif not state.worker_input_valid then
            resetFailure("worker input invalid")
        elseif not state.checks.output_present then
            resetFailure("worker output missing")
        elseif not state.checks.output_numeric then
            resetFailure("worker output contains nil/NaN/Inf")
        elseif state.stale then
            resetFailure("stale worker tick")
        end
    end

    -- Injection can never be enabled by this module.
    state.injection.enabled = false
    state.injection.applied = 0
    state.injection.blocked = true

    publish()
end

function M.getState()
    return state
end

return M
