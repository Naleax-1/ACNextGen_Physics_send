---@diagnostic disable: undefined-global

--============================================================
-- ACNextGen
-- Phase 3-A : Worker Output Verification Observer
--
-- Responsibility:
--   Observe and verify the runtime/worker transport path.
--
-- IMPORTANT:
--   This module DOES NOT perform physics calculation.
--   This module DOES NOT modify physics output.
--   This module DOES NOT inject force.
--
-- Verification path:
--
--   Engine / Physics Output
--          |
--          v
--   Physics Bridge Input
--          |
--          v
--       Worker
--          |
--          v
--   Physics Bridge Output
--          |
--          v
--       Observer
--
-- Phase 3-A verification fields:
--
--   Worker Alive
--   Tick
--   Input
--   Output
--   Transfer Count
--   Errors
--   Stale
--   Injection
--   Applied
--
--============================================================

local M = {}

--============================================================
-- Configuration
--============================================================

local CONFIG = {
    -- UI/log update interval.
    uiInterval = 0.10,

    -- Heartbeat timeout.
    --
    -- If no worker tick is observed for this amount of time,
    -- the worker is considered stale.
    staleTimeout = 0.75,

    -- Diagnostic log interval.
    logInterval = 1.00,

    -- Maximum number of error messages retained.
    maxErrors = 8,
}

--============================================================
-- Internal state
--============================================================

local state = {
    initialized = false,

    -- Observer clock.
    time = 0.0,

    -- UI/log timers.
    uiTimer = 0.0,
    logTimer = 0.0,

    --========================================================
    -- Worker
    --========================================================

    workerAlive = false,

    workerTick = 0,
    previousWorkerTick = 0,

    lastWorkerTickTime = 0.0,

    --========================================================
    -- Input
    --========================================================

    inputValid = false,

    inputAvailable = false,

    inputForceX = 0.0,
    inputForceY = 0.0,
    inputForceZ = 0.0,

    inputSequence = 0,

    --========================================================
    -- Output
    --========================================================

    outputValid = false,

    outputAvailable = false,

    outputForceX = 0.0,
    outputForceY = 0.0,
    outputForceZ = 0.0,

    outputSequence = 0,

    --========================================================
    -- Transport
    --========================================================

    transferCount = 0,

    previousTransferCount = 0,

    transferDelta = 0,

    --========================================================
    -- Applied
    --========================================================

    appliedCount = 0,

    previousAppliedCount = 0,

    appliedDelta = 0,

    --========================================================
    -- Injection
    --========================================================

    injectionEnabled = false,

    --========================================================
    -- Error
    --========================================================

    errorCount = 0,

    errors = {},

    lastError = "",

    --========================================================
    -- Stale
    --========================================================

    stale = true,

    staleReason = "NO WORKER HEARTBEAT",

    staleTime = 0.0,

    --========================================================
    -- Status
    --========================================================

    status = "INIT",

    bridgeStatus = "UNKNOWN",

    bridgeMode = "UNKNOWN",

    workerError = "",

    apiAvailable = false,

    apiAllowed = false,

    --========================================================
    -- Verification
    --========================================================

    verification = {
        worker = false,
        tick = false,
        input = false,
        output = false,
        transfer = false,
        errors = true,
        stale = false,
        injection = false,
        applied = false,

        overall = false,
    },
}

--============================================================
-- Utility
--============================================================

local function num(value, fallback)
    local n = tonumber(value)

    if n == nil
        or n ~= n
        or n == math.huge
        or n == -math.huge then

        return fallback or 0.0
    end

    return n
end

local function bool(value)
    return value == true
end

local function safeField(object, key, fallback)
    if not object then
        return fallback
    end

    local ok, value = pcall(function()
        return object[key]
    end)

    if not ok or value == nil then
        return fallback
    end

    return value
end

local function now()
    if os and os.clock then
        local ok, value = pcall(os.clock)

        if ok and value then
            return value
        end
    end

    return state.time
end

local function addError(message)
    message = tostring(message or "UNKNOWN ERROR")

    state.errorCount = state.errorCount + 1
    state.lastError = message

    table.insert(state.errors, {
        time = state.time,
        message = message,
    })

    while #state.errors > CONFIG.maxErrors do
        table.remove(state.errors, 1)
    end
end

local function clearErrors()
    state.errorCount = 0
    state.lastError = ""
    state.errors = {}
end

--============================================================
-- Bridge acquisition
--============================================================

local function getBridge(runtime)
    if not runtime then
        return nil
    end

    -- Preferred path.
    if runtime.physicsBridge then
        return runtime.physicsBridge
    end

    -- Runtime module state.
    if runtime.moduleStates then
        if runtime.moduleStates.physics_bridge then
            return runtime.moduleStates.physics_bridge
        end

        if runtime.moduleStates.physicsBridge then
            return runtime.moduleStates.physicsBridge
        end
    end

    -- Compatibility path.
    if runtime.state then
        if runtime.state.physicsBridge then
            return runtime.state.physicsBridge
        end
    end

    return nil
end

--============================================================
-- Physics output acquisition
--============================================================

local function getWorkerOutput(runtime)
    if not runtime then
        return nil
    end

    if runtime.workerOutput then
        return runtime.workerOutput
    end

    if runtime.moduleStates
    and runtime.moduleStates.worker_output then
        return runtime.moduleStates.worker_output
    end

    return nil
end

local function getPhysicsOutput(runtime)
    if not runtime then
        return nil
    end

    -- Canonical runtime pointer.
    if runtime.physicsOutput then
        return runtime.physicsOutput
    end

    -- Physics hub.
    if runtime.physicsHub then
        return runtime.physicsHub
    end

    -- Runtime state compatibility.
    if runtime.state then

        if runtime.state.physicsOutput then
            return runtime.state.physicsOutput
        end

        if runtime.state.physicsHub then
            return runtime.state.physicsHub
        end
    end

    -- Module state compatibility.
    if runtime.moduleStates then

        if runtime.moduleStates.physics then
            return runtime.moduleStates.physics
        end
    end

    return nil
end

--============================================================
-- Read body force
--============================================================

local function readBodyForce(source)
    if not source then
        return false, 0.0, 0.0, 0.0
    end

    local body = safeField(source, "body", nil)

    if not body then
        return false, 0.0, 0.0, 0.0
    end

    local available = safeField(body, "available", false)

    if available ~= true then
        return false, 0.0, 0.0, 0.0
    end

    local x = num(safeField(body, "forceX", 0.0), 0.0)
    local y = num(safeField(body, "forceY", 0.0), 0.0)
    local z = num(safeField(body, "forceZ", 0.0), 0.0)

    return true, x, y, z
end

--============================================================
-- Read bridge state
--============================================================

local function readBridge(runtime)
    local bridge = getBridge(runtime)

    if not bridge then

        state.bridgeStatus = "WAIT"
        state.bridgeMode = "NO BRIDGE"

        state.workerAlive = false
        state.injectionEnabled = false

        state.stale = true
        state.staleReason = "BRIDGE UNAVAILABLE"

        return nil
    end

    state.bridgeStatus =
        tostring(safeField(bridge, "status", "UNKNOWN"))

    state.bridgeMode =
        tostring(safeField(bridge, "mode", "UNKNOWN"))

    --========================================================
    -- Worker
    --========================================================

    state.workerAlive =
        bool(safeField(bridge, "workerAlive", false))

    state.workerTick =
        math.floor(
            num(
                safeField(bridge, "workerTicks", 0),
                0
            )
        )

    state.workerError =
        tostring(
            safeField(
                bridge,
                "workerError",
                ""
            )
        )

    state.apiAvailable =
        bool(
            safeField(
                bridge,
                "apiAvailable",
                false
            )
        )

    state.apiAllowed =
        bool(
            safeField(
                bridge,
                "apiAllowed",
                false
            )
        )

    --========================================================
    -- Transfer
    --========================================================

    state.transferCount =
        math.floor(
            num(
                safeField(
                    bridge,
                    "transferCount",
                    0
                ),
                0
            )
        )

    state.appliedCount =
        math.floor(
            num(
                safeField(
                    bridge,
                    "appliedCount",
                    0
                ),
                0
            )
        )

    --========================================================
    -- Injection
    --========================================================

    state.injectionEnabled =
        bool(
            safeField(
                bridge,
                "injectionEnabled",
                false
            )
        )

    -- Phase 3-A Worker Output contract.
    local workerOutput = getWorkerOutput(runtime)

    if workerOutput then
        state.inputValid =
            bool(safeField(workerOutput, "worker_input_valid", false))

        state.outputValid =
            bool(safeField(workerOutput, "worker_output_valid", false))

        state.inputSequence =
            math.floor(num(
                safeField(workerOutput, "input_sequence", 0), 0))

        state.outputSequence =
            math.floor(num(
                safeField(workerOutput, "output_sequence", 0), 0))

        state.errorCount =
            math.max(0, math.floor(num(
                safeField(workerOutput, "error_count", 0), 0)))

        state.stale =
            bool(safeField(workerOutput, "stale", true))

        state.status =
            tostring(safeField(
                workerOutput, "status", state.status))

        local inputForce = safeField(workerOutput, "input_force", nil)
        if inputForce then
            state.inputForceX = num(safeField(inputForce, "x", 0.0), 0.0)
            state.inputForceY = num(safeField(inputForce, "y", 0.0), 0.0)
            state.inputForceZ = num(safeField(inputForce, "z", 0.0), 0.0)
        end

        local outputForce = safeField(workerOutput, "output_force", nil)
        if outputForce then
            state.outputForceX = num(safeField(outputForce, "x", 0.0), 0.0)
            state.outputForceY = num(safeField(outputForce, "y", 0.0), 0.0)
            state.outputForceZ = num(safeField(outputForce, "z", 0.0), 0.0)
            state.outputAvailable = workerOutput.available == true
        end
    end

    return bridge
end

--============================================================
-- Read input
--============================================================

local function readInput(runtime)
    local workerOutput = getWorkerOutput(runtime)

    if workerOutput then
        local valid =
            safeField(workerOutput, "worker_input_valid", false) == true

        local inputForce =
            safeField(workerOutput, "input_force", nil)

        state.inputValid = valid
        state.inputAvailable = workerOutput.input_available == true

        if inputForce then
            state.inputForceX =
                num(safeField(inputForce, "x", 0.0), 0.0)
            state.inputForceY =
                num(safeField(inputForce, "y", 0.0), 0.0)
            state.inputForceZ =
                num(safeField(inputForce, "z", 0.0), 0.0)
        end

        return
    end

    local physicsOutput = getPhysicsOutput(runtime)
    state.inputAvailable = physicsOutput ~= nil
    state.inputValid = false
end

--============================================================
-- Read output
--============================================================

local function readOutput(runtime, bridge)
    local workerOutput = getWorkerOutput(runtime)

    if workerOutput then
        state.outputValid =
            safeField(workerOutput, "worker_output_valid", false) == true

        state.outputAvailable = workerOutput.available == true

        local outputForce =
            safeField(workerOutput, "output_force", nil)

        if outputForce then
            state.outputForceX =
                num(safeField(outputForce, "x", 0.0), 0.0)
            state.outputForceY =
                num(safeField(outputForce, "y", 0.0), 0.0)
            state.outputForceZ =
                num(safeField(outputForce, "z", 0.0), 0.0)
        end

        return
    end

    state.outputValid = false
    state.outputAvailable = false
end

--============================================================
-- Calculate deltas
--============================================================

local function updateCounters()
    state.transferDelta =
        state.transferCount -
        state.previousTransferCount

    state.appliedDelta =
        state.appliedCount -
        state.previousAppliedCount

    if state.transferDelta < 0 then
        state.transferDelta = 0
    end

    if state.appliedDelta < 0 then
        state.appliedDelta = 0
    end

    state.previousTransferCount =
        state.transferCount

    state.previousAppliedCount =
        state.appliedCount
end

--============================================================
-- Worker heartbeat / stale detection
--============================================================

-- Read the validator's verdict; the Observer never independently grants PASS.
local function verify(runtime)
    local output = getWorkerOutput(runtime)
    local v = state.verification
    local checks = output and output.checks or {}
    v.worker = output ~= nil and output.worker_alive == true
    v.tick = output ~= nil and output.tick_fresh == true
    v.input = output ~= nil and output.worker_input_valid == true
    v.output = output ~= nil and output.worker_output_valid == true
    v.transfer = output ~= nil and output.transfer_delta > 0
    v.errors = output ~= nil and output.error_count == 0
    v.stale = output ~= nil and output.stale == false
    v.injection = checks.injection_safe == true
    v.applied = output ~= nil and output.injection.applied == 0
    v.overall = output ~= nil and output.valid == true and output.transport_pass == true
    state.status = output and output.status or "PHASE_3A_OUTPUT_WAIT"
    state.errorCount = output and output.error_count or 0
    state.lastError = output and output.failure or ""
    state.stale = not output or output.stale
    state.staleTime = output and output.stale_time or 0
    state.staleReason = state.stale and "RESULT OR HEARTBEAT NOT FRESH" or ""
    state.bodyAvailable = output ~= nil and output.body_available == true
    state.wheelOutput = output and output.values and output.values.wheel or nil
    state.pendingSequence = output and output.pending_sequence or 0
end

--============================================================
-- Initialization
--============================================================

function M.init()
    state.initialized = true
    state.time = 0.0
    state.uiTimer = 0.0
    state.logTimer = 0.0

    state.status = "PHASE_3A_INIT"

    clearErrors()

    if ac and ac.log then
        pcall(
            ac.log,
            "[ACNextGen] Phase 3-A Observer loaded"
        )
    end
end

--============================================================
-- Update
--============================================================

function M.update(dt, car, runtime)

    dt = num(dt, 0.0)

    state.time =
        state.time + dt

    --========================================================
    -- Bridge
    --========================================================

    local bridge =
        readBridge(runtime)

    --========================================================
    -- Input
    --========================================================

    readInput(runtime)

    --========================================================
    -- Output
    --========================================================

    readOutput(
        runtime,
        bridge
    )

    --========================================================
    -- Counters
    --========================================================

    updateCounters()

    --========================================================
    -- Heartbeat
    --========================================================

    -- Freshness comes from WorkerOutput, not this throttled UI clock.

    --========================================================
    -- Errors
    --========================================================

    -- Errors are retained by the validator, not reset or recounted here.

    --========================================================
    -- Verification
    --========================================================

    verify(runtime)

    --========================================================
    -- Diagnostic logging
    --========================================================

    state.logTimer =
        state.logTimer + dt

    if state.logTimer >= CONFIG.logInterval then

        state.logTimer = 0.0

        if ac and ac.log then

            local message = string.format(
                "[ACNextGen Phase3-A] " ..
                "Worker=%s Tick=%d " ..
                "Input=%s Output=%s " ..
                "Transfers=%d Applied=%d " ..
                "Errors=%d Stale=%s Injection=%s " ..
                "Status=%s",

                state.workerAlive
                    and "ALIVE"
                    or "DEAD",

                state.workerTick,

                state.inputAvailable
                    and "OK"
                    or "WAIT",

                state.outputAvailable
                    and "OK"
                    or "WAIT",

                state.transferCount,

                state.appliedCount,

                state.errorCount,

                state.stale
                    and "YES"
                    or "NO",

                state.injectionEnabled
                    and "ON"
                    or "OFF",

                state.status
            )

            pcall(
                ac.log,
                message
            )
        end
    end
end

--============================================================
-- UI helpers
--============================================================

local function yesNo(value)
    return value and "YES" or "NO"
end

local function passWait(value)
    return value and "PASS" or "WAIT"
end

local function drawVerificationRow(
    label,
    value
)

    ui.text(
        string.format(
            " %-18s %s",
            label,
            passWait(value)
        )
    )
end

--============================================================
-- UI
--============================================================

function M.drawUI(runtime, modules)

    if not ui then
        return
    end

    local v =
        state.verification

    ui.text(
        "=== ACNextGen / PHASE 3-A ==="
    )

    ui.text(
        "Worker Output Verification"
    )

    ui.separator()

    --========================================================
    -- Overall
    --========================================================

    ui.text(
        "PHASE 3-A STATUS : " ..
        tostring(state.status)
    )

    ui.text(
        "Overall          : " ..
        passWait(v.overall) .. " (transport only; AC behavior unverified)"
    )

    ui.separator()

    --========================================================
    -- Worker
    --========================================================

    ui.text(
        "Worker"
    )

    ui.text(
        " Worker Alive     : " ..
        yesNo(state.workerAlive)
    )

    ui.text(
        " Tick             : " ..
        tostring(state.workerTick)
    )

    ui.text(
        " Tick Fresh       : " ..
        yesNo(v.tick)
    )

    ui.text(
        " Stale Time       : " ..
        string.format(
            "%.3f s",
            num(state.staleTime, 0.0)
        )
    )

    ui.text(
        " Stale            : " ..
        yesNo(state.stale)
    )

    if state.staleReason ~= "" then
        ui.text(
            " Stale Reason     : " ..
            tostring(state.staleReason)
        )
    end

    ui.separator()

    --========================================================
    -- Input
    --========================================================

    ui.text(
        "Input"
    )

    ui.text(
        " Input Available  : " ..
        yesNo(state.inputAvailable)
    )

    ui.text(
        " Input Valid      : " ..
        yesNo(state.inputValid)
    )

    ui.text(
        string.format(
            state.bodyAvailable and " Input Body Force : %.3f / %.3f / %.3f" or " Input Body Force : N/A (no producer)",
            state.inputForceX,
            state.inputForceY,
            state.inputForceZ
        )
    )

    ui.text(
        " Input Sequence   : " ..
        tostring(state.inputSequence)
    )

    ui.separator()

    --========================================================
    -- Output
    --========================================================

    ui.text(
        "Output"
    )

    ui.text(
        " Output Available : " ..
        yesNo(state.outputAvailable)
    )

    ui.text(
        " Output Valid     : " ..
        yesNo(state.outputValid)
    )

    ui.text(
        string.format(
            state.bodyAvailable and " Output Body Force: %.3f / %.3f / %.3f" or " Output Body Force: N/A (no producer)",
            state.outputForceX,
            state.outputForceY,
            state.outputForceZ
        )
    )

    ui.text(
        " Output Sequence  : " ..
        tostring(state.outputSequence)
    )

    ui.separator()

    ui.text(" Input/Output sequence above: last acknowledged pair")
    ui.text(" Pending Sequence : " .. tostring(state.pendingSequence or 0))
    ui.text(" Worker wheel results (unchanged producer channels)")
    for i, name in ipairs({"FL", "FR", "RL", "RR"}) do
        local w = state.wheelOutput and state.wheelOutput[i - 1]
        ui.text(w and string.format(" %s lateral %.3f / longitudinal %.3f", name,
            w.lateralForce, w.longitudinalForce) or (" " .. name .. " : N/A"))
    end
    ui.separator()

    --========================================================
    -- Transfer
    --========================================================

    ui.text(
        "Transfer"
    )

    ui.text(
        " Transfer Count   : " ..
        tostring(state.transferCount)
    )

    ui.text(
        " Transfer Delta   : " ..
        tostring(state.transferDelta)
    )

    ui.separator()

    --========================================================
    -- Errors
    --========================================================

    ui.text(
        "Errors"
    )

    ui.text(
        " Error Count      : " ..
        tostring(state.errorCount)
    )

    ui.text(
        " Error State      : " ..
        (
            state.errorCount == 0
            and "CLEAR"
            or "ERROR"
        )
    )

    if state.lastError ~= "" then

        ui.text(
            " Last Error       : " ..
            tostring(state.lastError)
        )
    end

    ui.separator()

    --========================================================
    -- Injection
    --========================================================

    ui.text(
        "Injection"
    )

    ui.text(
        " Injection        : " ..
        (
            state.injectionEnabled
            and "ENABLED"
            or "DISABLED"
        )
    )

    ui.text(
        " Applied          : " ..
        tostring(state.appliedCount)
    )

    ui.text(
        " Applied Delta    : " ..
        tostring(state.appliedDelta)
    )

    ui.separator()

    --========================================================
    -- Bridge
    --========================================================

    ui.text(
        "Physics Bridge"
    )

    ui.text(
        " Status           : " ..
        tostring(state.bridgeStatus)
    )

    ui.text(
        " Mode             : " ..
        tostring(state.bridgeMode)
    )

    ui.text(
        " API Available    : " ..
        yesNo(state.apiAvailable)
    )

    ui.text(
        " API Allowed      : " ..
        yesNo(state.apiAllowed)
    )

    ui.separator()

    --========================================================
    -- Verification matrix
    --========================================================

    ui.text(
        "Verification Matrix"
    )

    drawVerificationRow(
        "Worker Alive",
        v.worker
    )

    drawVerificationRow(
        "Tick",
        v.tick
    )

    drawVerificationRow(
        "Input",
        v.input
    )

    drawVerificationRow(
        "Output",
        v.output
    )

    drawVerificationRow(
        "Transfer Count",
        v.transfer
    )

    drawVerificationRow(
        "Errors",
        v.errors
    )

    drawVerificationRow(
        "Stale",
        v.stale
    )

    drawVerificationRow(
        "Injection",
        v.injection
    )

    drawVerificationRow(
        "Applied",
        v.applied
    )

    ui.separator()

    ui.text(
        "PHASE 3-A RESULT : " ..
        passWait(v.overall) .. " (transport only; AC behavior unverified)"
    )

    --========================================================
    -- Compatibility / module information
    --========================================================

    if modules then

        ui.separator()

        ui.text(
            "Module Health"
        )

        for i = 1, #modules do

            local entry =
                modules[i]

            ui.text(
                string.format(
                    " %-20s %s",
                    tostring(
                        entry.name
                    ),
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
-- Public state accessor
--============================================================

function M.getState()
    return state
end

--============================================================
-- Public verification accessor
--============================================================

function M.getVerification()
    return state.verification
end

--============================================================
-- Public status accessor
--============================================================

function M.getStatus()
    return state.status
end

--============================================================
-- Public reset
--============================================================

function M.reset()

    state.workerAlive = false

    state.workerTick = 0
    state.previousWorkerTick = 0

    state.lastWorkerTickTime =
        state.time

    state.inputValid = false
    state.inputAvailable = false

    state.outputValid = false
    state.outputAvailable = false

    state.inputSequence = 0
    state.outputSequence = 0

    state.transferCount = 0
    state.previousTransferCount = 0
    state.transferDelta = 0

    state.appliedCount = 0
    state.previousAppliedCount = 0
    state.appliedDelta = 0

    state.injectionEnabled = false

    state.stale = true
    state.staleReason = "RESET"

    state.staleTime = 0.0

    state.status =
        "PHASE_3A_RESET"

    clearErrors()

    state.verification.worker = false
    state.verification.tick = false
    state.verification.input = false
    state.verification.output = false
    state.verification.transfer = false
    state.verification.errors = true
    state.verification.stale = false
    state.verification.injection = false
    state.verification.applied = false
    state.verification.overall = false
end

--============================================================
-- End
--============================================================

return M