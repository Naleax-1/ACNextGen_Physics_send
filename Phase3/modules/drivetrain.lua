---@diagnostic disable: undefined-global

--============================================================
-- ACNextGen Observer
-- Phase 3-A / Worker Output Verification
--
-- ROLE:
--   Diagnostic / Verification UI ONLY
--
-- NEVER:
--   - calculate physics
--   - modify physics values
--   - inject physics
--   - repair worker output
--
-- DATA FLOW:
--
--   Runtime State
--        ↓
--   Physics Hub
--        ↓
--   Physics Worker
--        ↓
--   Worker Output
--        ↓
--   Observer
--
-- Injection is intentionally outside this path.
--============================================================

local M = {}

local logTimer = 0.0

local WHEEL_NAMES = {
    [0] = "FL",
    [1] = "FR",
    [2] = "RL",
    [3] = "RR",
}

--============================================================
-- Safe helpers
--============================================================

local function num(v, fallback)
    local n = tonumber(v)

    if n == nil
    or n ~= n
    or n == math.huge
    or n == -math.huge then
        return fallback or 0.0
    end

    return n
end

local function text(v, fallback)
    if v == nil then
        return fallback or ""
    end

    return tostring(v)
end

local function field(obj, key, fallback)
    if not obj then
        return fallback
    end

    local ok, value = pcall(function()
        return obj[key]
    end)

    if not ok or value == nil then
        return fallback
    end

    return value
end

local function loadNum(key, fallback)
    if not ac or not ac.load then
        return fallback or 0.0
    end

    local ok, value = pcall(ac.load, key)

    if not ok or value == nil then
        return fallback or 0.0
    end

    return num(value, fallback)
end

local function loadText(key, fallback)
    if not ac or not ac.load then
        return fallback or ""
    end

    local ok, value = pcall(ac.load, key)

    if not ok or value == nil then
        return fallback or ""
    end

    return tostring(value)
end

local function passFail(value)
    return value and "PASS" or "FAIL"
end

local function yesNo(value)
    return value and "YES" or "NO"
end

local function validInvalid(value)
    return value and "VALID" or "INVALID"
end

--============================================================
-- Wheel helper
--============================================================

local function wheel(car, i)
    local wheels = field(car, "wheels", nil)

    if not wheels then
        return nil
    end

    local ok, value = pcall(function()
        return wheels[i] or wheels[i + 1]
    end)

    if not ok then
        return nil
    end

    return value
end

--============================================================
-- Init
--============================================================

function M.init()

    if ac and ac.log then
        ac.log(
            "[ACNextGen] Phase 3-A Observer loaded"
        )
    end

end

--============================================================
-- Update
--
-- Observer does NOT calculate physics.
-- It only keeps diagnostic timing/logging.
--============================================================

function M.update(dt, car, runtime)

    logTimer = logTimer + num(dt, 0.0)

    if logTimer < 1.0 then
        return
    end

    logTimer = 0.0

    if not ac or not ac.log then
        return
    end

    if not car then
        ac.log(
            "[ACNextGen Phase3-A] vehicle unavailable"
        )

        return
    end

    local vehicle =
        runtime
        and runtime.state
        and runtime.state.vehicle
        or nil

    local worker =
        runtime
        and runtime.workerOutput
        or nil

    ac.log(
        string.format(
            "[ACNextGen Phase3-A] speed=%.1f rpm=%.0f worker=%s tick=%d output=%s",
            num(field(vehicle, "speedKmh", 0.0), 0.0),
            num(field(vehicle, "rpm", 0.0), 0.0),
            worker and
                (worker.worker_alive and "ALIVE" or "DEAD")
                or "WAIT",
            math.floor(
                num(
                    worker and worker.tick or 0,
                    0
                )
            ),
            worker and
                (worker.valid and "VALID" or "INVALID")
                or "WAIT"
        )
    )

end

--============================================================
-- Runtime Section
--============================================================

local function drawRuntime(runtime)

    ui.text("Runtime")

    ui.text(
        "  ACNextGen      : "
        .. (
            runtime.initialized
            and "READY"
            or "INIT"
        )
    )

    ui.text(
        "  Vehicle        : "
        .. (
            runtime.carOK
            and "OK"
            or "NO CAR"
        )
    )

    ui.text(
        "  Wheels         : "
        .. (
            runtime.wheelsOK
            and "OK"
            or "NO WHEELS"
        )
    )

    ui.text(
        "  Modules        : "
        .. tostring(runtime.loadedCount or 0)
    )

    ui.text(
        "  Active Errors  : "
        .. tostring(runtime.activeErrorCount or 0)
    )

    ui.text(
        "  State Bus      : "
        .. (
            runtime.state
            and "ON"
            or "OFF"
        )
    )

end

--============================================================
-- Vehicle State
--============================================================

local function drawVehicle(runtime, car)

    local vehicle =
        runtime
        and runtime.state
        and runtime.state.vehicle
        or nil

    ui.separator()

    if vehicle and vehicle.valid then

        ui.text(
            "Vehicle State / Runtime State Bus"
        )

        ui.text(
            string.format(
                "  Speed          : %.1f km/h",
                num(vehicle.speedKmh, 0.0)
            )
        )

        ui.text(
            string.format(
                "  RPM            : %.0f",
                num(vehicle.rpm, 0.0)
            )
        )

        ui.text(
            string.format(
                "  Gear           : %d",
                math.floor(
                    num(vehicle.gear, 0)
                )
            )
        )

        ui.text(
            string.format(
                "  Steer          : %.3f",
                num(vehicle.steer, 0.0)
            )
        )

        ui.text(
            string.format(
                "  Gas            : %.3f",
                num(vehicle.gas, 0.0)
            )
        )

        ui.text(
            string.format(
                "  Brake          : %.3f",
                num(vehicle.brake, 0.0)
            )
        )

        ui.text(
            string.format(
                "  State Valid    : %s",
                yesNo(vehicle.valid)
            )
        )

        ui.separator()

        ui.text("Four Wheel Check")

        for i = 0, 3 do

            ui.text(
                string.format(
                    "  %s : %s",
                    WHEEL_NAMES[i],
                    wheel(car, i)
                    and "OK"
                    or "MISSING"
                )
            )

        end

    else

        ui.text("Vehicle State")
        ui.text("  Vehicle not found")

    end

end

--============================================================
-- Module Health
--============================================================

local function drawModuleHealth(modules)

    ui.separator()

    ui.text("Module Health")

    if not modules then
        ui.text("  Modules unavailable")
        return
    end

    for i = 1, #modules do

        local entry = modules[i]

        if entry then

            ui.text(
                string.format(
                    "  %-20s %s",
                    tostring(entry.name),
                    tostring(
                        entry.lastStatus
                        or "UNKNOWN"
                    )
                )
            )

        end

    end

end

--============================================================
-- Physics Hub
--============================================================

local function drawPhysicsHub(runtime)

    ui.separator()

    ui.text(
        "Physics Hub / Phase 2"
    )

    ui.text(
        "  Schema          : "
        .. loadText(
            "ngp_hub_schema",
            "ACNextGen.PhysicsHub.v1"
        )
    )

    ui.text(
        "  Valid           : "
        .. (
            loadNum(
                "ngp_hub_valid",
                0
            ) == 1
            and "PASS"
            or "WAIT"
        )
    )

    ui.text(
        "  Source          : "
        .. loadText(
            "ngp_hub_source",
            "unknown"
        )
    )

    ui.text(
        "  Direct Modules  : "
        .. tostring(
            loadNum(
                "ngp_hub_direct_module_count",
                0
            )
        )
        .. " / 8 expected"
    )

end

--============================================================
-- Worker Output Verification
--============================================================

local function drawWorkerOutput(runtime)

    ui.separator()

    ui.text(
        "Worker Output Verification / Phase 3-A"
    )

    local worker =
        runtime
        and runtime.workerOutput
        or nil

    if not worker then

        ui.text(
            "  Status          : WAIT"
        )

        ui.text(
            "  Worker Output   : NOT AVAILABLE"
        )

        ui.text(
            "  PHASE 3-A       : WAIT"
        )

        return

    end

    ----------------------------------------------------------
    -- Worker Alive
    ----------------------------------------------------------

    ui.text(
        "  Worker Alive    : "
        .. (
            worker.worker_alive
            and "YES"
            or "NO"
        )
    )

    ----------------------------------------------------------
    -- Tick
    ----------------------------------------------------------

    ui.text(
        "  Tick            : "
        .. tostring(
            math.floor(
                num(
                    worker.tick,
                    0
                )
            )
        )
    )

    ----------------------------------------------------------
    -- Input
    ----------------------------------------------------------

    ui.text(
        "  Input           : "
        .. (
            worker.worker_input_valid
            and "VALID"
            or "INVALID"
        )
    )

    ----------------------------------------------------------
    -- Output
    ----------------------------------------------------------

    ui.text(
        "  Output          : "
        .. (
            worker.worker_output_valid
            and "VALID"
            or "INVALID"
        )
    )

    ----------------------------------------------------------
    -- Transfer
    ----------------------------------------------------------

    ui.text(
        "  Transfer Count  : "
        .. tostring(
            math.floor(
                num(
                    worker.transfer_count,
                    0
                )
            )
        )
    )

    ----------------------------------------------------------
    -- Errors
    ----------------------------------------------------------

    ui.text(
        "  Errors          : "
        .. tostring(
            math.floor(
                num(
                    worker.error_count,
                    0
                )
            )
        )
    )

    ----------------------------------------------------------
    -- Stale
    ----------------------------------------------------------

    ui.text(
        "  Stale           : "
        .. (
            worker.stale
            and "YES"
            or "NO"
        )
    )

    ----------------------------------------------------------
    -- Status
    ----------------------------------------------------------

    ui.text(
        "  Status          : "
        .. tostring(
            worker.status
            or "WAIT"
        )
    )

    ----------------------------------------------------------
    -- Source
    ----------------------------------------------------------

    ui.text(
        "  Source          : "
        .. tostring(
            worker.source
            or "physics_worker"
        )
    )

    ----------------------------------------------------------
    -- Failure
    ----------------------------------------------------------

    if worker.failure
    and worker.failure ~= "" then

        ui.text(
            "  Failure         : "
            .. tostring(
                worker.failure
            )
        )

    end

    ----------------------------------------------------------
    -- Injection
    --
    -- HARD SAFETY RULE:
    -- Observer only reports this state.
    -- It never enables injection.
    ----------------------------------------------------------

    ui.text(
        "  Injection       : DISABLED"
    )

    ui.text(
        "  Applied         : 0"
    )

    ----------------------------------------------------------
    -- Phase 3-A Gate
    ----------------------------------------------------------

    local gatePass =
        worker.worker_alive == true
        and worker.worker_input_valid == true
        and worker.worker_output_valid == true
        and worker.stale ~= true
        and num(worker.error_count, 0) == 0
        and worker.injection_enabled ~= true
        and num(worker.applied_count, 0) == 0

    ui.separator()

    ui.text(
        "PHASE 3-A        : "
        .. (
            gatePass
            and "PASS"
            or (
                worker.status == "STALLED"
                and "FAIL / STALLED"
                or "WAIT"
            )
        )
    )

end

--============================================================
-- Physics Bridge
--============================================================

local function drawPhysicsBridge(runtime)

    ui.separator()

    ui.text(
        "Physics Bridge / Phase 3"
    )

    local bridge =
        runtime.physicsBridge
        or (
            runtime.moduleStates
            and runtime.moduleStates.physics_bridge
        )

    if not bridge then

        ui.text(
            "  Bridge state    : WAIT"
        )

        return

    end

    ui.text(
        "  Status          : "
        .. tostring(
            bridge.status
            or "UNKNOWN"
        )
    )

    ui.text(
        "  Mode            : "
        .. tostring(
            bridge.mode
            or "UNKNOWN"
        )
    )

    ui.text(
        "  Worker API      : "
        .. (
            bridge.apiAvailable
            and "AVAILABLE"
            or "MISSING"
        )
    )

    ui.text(
        "  Worker Alive    : "
        .. (
            bridge.workerAlive
            and "YES"
            or "NO"
        )
    )

    ui.text(
        "  Worker Ticks    : "
        .. tostring(
            bridge.workerTicks
            or 0
        )
    )

    ui.text(
        "  Input Valid     : "
        .. (
            bridge.workerInputValid
            and "YES"
            or "NO"
        )
    )

    ui.text(
        "  Output Valid    : "
        .. (
            bridge.workerOutputValid
            and "YES"
            or "NO"
        )
    )

    ui.text(
        "  Injection       : DISABLED"
    )

    ui.text(
        "  Transfers       : "
        .. tostring(
            bridge.transferCount
            or 0
        )
    )

    ui.text(
        "  Applied         : 0"
    )

    if bridge.workerError
    and bridge.workerError ~= "" then

        ui.text(
            "  Error           : "
            .. tostring(
                bridge.workerError
            )
        )

    end

end

--============================================================
-- Phase 1 Gate
--============================================================

local function drawLegacyGate()

    ui.separator()

    ui.text(
        "Phase 1 Gate / Compatibility"
    )

    ui.text(
        "  Loaded Modules   : "
        .. (
            loadNum(
                "ngp_phase1_loaded_13",
                0
            ) == 1
            and "PASS"
            or "WAIT"
        )
    )

    ui.text(
        "  Vehicle Acquired : "
        .. (
            loadNum(
                "ngp_phase1_car_ok",
                0
            ) == 1
            and "PASS"
            or "WAIT"
        )
    )

    ui.text(
        "  Wheels Available : "
        .. (
            loadNum(
                "ngp_phase1_wheels_ok",
                0
            ) == 1
            and "PASS"
            or "WAIT"
        )
    )

    ui.text(
        "  No Active Errors : "
        .. (
            loadNum(
                "ngp_phase1_no_active_errors",
                0
            ) == 1
            and "PASS"
            or "WAIT"
        )
    )

end

--============================================================
-- Main UI
--============================================================

function M.drawUI(runtime, modules)

    ui.text(
        "=== ACNextGen V1.1 / PHASE 3 ==="
    )

    ui.text(
        "Physical Integration Foundation"
    )

    ui.separator()

    drawRuntime(runtime)

    drawVehicle(
        runtime,
        ac and ac.getCar
        and ac.getCar(0)
        or nil
    )

    drawModuleHealth(modules)

    drawPhysicsHub(runtime)

    --========================================================
    -- THIS IS THE NEW PHASE 3-A SECTION
    --========================================================

    drawWorkerOutput(runtime)

    drawPhysicsBridge(runtime)

    drawLegacyGate()

end

return M

exportState()

return M
