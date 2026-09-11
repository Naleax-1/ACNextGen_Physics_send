---@diagnostic disable: undefined-global

--============================================================
-- physics_bridge.lua
-- ACNextGen V1.1 Phase 3
-- Physics Output -> CSP Physics Worker Transport
--
-- Phase 3-A policy:
--   * No physics injection.
--   * Worker is a transport/probe endpoint only.
--   * Physics Hub output is copied into a shared transport buffer.
--   * Worker validates that buffer and mirrors it back as Worker Output.
--   * Observer/Worker Output can therefore verify the complete path.
--
-- Transport path:
--   Physics Hub -> Bridge Input -> CSP Worker -> Worker Output
--
-- IMPORTANT:
--   The worker NEVER calls physics.addForce() in Phase 3-A.
--============================================================

local M = {}

M.params = {
    probeEnabled = true,
    injectionEnabled = false,       -- HARD LOCK: must remain false in Phase 3-A.
    heartbeatTimeout = 0.75,
    publishInterval = 0.10,
}

local state = {
    schema = "ACNextGen.PhysicsBridge.v2",
    status = "INIT",
    mode = "UNRESOLVED",

    workerRequested = false,
    workerAlive = false,
    workerTicks = 0,
    workerGeneration = 0,
    workerError = "",

    apiAvailable = false,
    apiAllowed = false,

    workerInputValid = false,
    workerOutputValid = false,
    workerOutputSequence = 0,

    injectionEnabled = false,
    appliedCount = 0,

    lastWorkerTickTime = 0.0,
    lastPublishedTime = 0.0,
    transferCount = 0,

    inputSequence = 0,
    bodyForce = { x = 0.0, y = 0.0, z = 0.0 },

    workerOutput = {
        x = 0.0,
        y = 0.0,
        z = 0.0,
        available = false,
    },
}

M.state = state

local bridgeData = nil
local lastGenerationSeed = 0

local WORKER_SOURCE = [[
---@diagnostic disable: undefined-global

local bridge = ac.connect({
    key = ac.StructItem.key('ACNextGen.PhysicsBridge'),
    generation = ac.StructItem.int32(),
    enabled = ac.StructItem.int32(),

    forceX = ac.StructItem.float(),
    forceY = ac.StructItem.float(),
    forceZ = ac.StructItem.float(),

    inputSequence = ac.StructItem.int32(),
    workerTicks = ac.StructItem.int32(),
    lastDt = ac.StructItem.float(),

    inputValid = ac.StructItem.int32(),
    outputValid = ac.StructItem.int32(),
    outputSequence = ac.StructItem.int32(),
    outputForceX = ac.StructItem.float(),
    outputForceY = ac.StructItem.float(),
    outputForceZ = ac.StructItem.float(),

    appliedCount = ac.StructItem.int32(),
    workerStatus = ac.StructItem.int32(),
})

local startGeneration = worker.input

local function finite(v)
    return v ~= nil and v == v
        and v ~= math.huge
        and v ~= -math.huge
end

function script.update(dt)
    if bridge.generation ~= startGeneration then
        worker.terminate()
        return
    end

    bridge.workerTicks = bridge.workerTicks + 1
    bridge.lastDt = dt
    bridge.workerStatus = 1

    local inputOK =
        bridge.inputValid == 1
        and finite(bridge.forceX)
        and finite(bridge.forceY)
        and finite(bridge.forceZ)

    bridge.inputValid = inputOK and 1 or 0
    bridge.outputValid = 0

    if inputOK then
        -- Phase 3-A worker output is a transport mirror.
        -- It is NOT a physics injection and does not call physics.addForce().
        bridge.outputForceX = bridge.forceX
        bridge.outputForceY = bridge.forceY
        bridge.outputForceZ = bridge.forceZ
        bridge.outputSequence = bridge.inputSequence
        bridge.outputValid = 1
    else
        bridge.outputForceX = 0
        bridge.outputForceY = 0
        bridge.outputForceZ = 0
        bridge.outputSequence = bridge.inputSequence
    end

    -- Injection is intentionally impossible in this worker.
    bridge.appliedCount = 0
end
]]

local function num(v, fallback)
    local n = tonumber(v)
    if n == nil or n ~= n or n == math.huge or n == -math.huge then
        return fallback or 0.0
    end
    return n
end

local function finite(v)
    local n = tonumber(v)
    return n ~= nil and n == n and n ~= math.huge and n ~= -math.huge
end

local function nowClock()
    if os and os.clock then
        local ok, value = pcall(os.clock)
        if ok and value then return value end
    end
    return 0.0
end

local function log(msg)
    if ac and ac.log then
        pcall(ac.log, "[ACNextGen Bridge] " .. tostring(msg))
    end
end

local function newGeneration()
    lastGenerationSeed = (lastGenerationSeed + 1) % 2147483647
    if lastGenerationSeed == 0 then lastGenerationSeed = 1 end
    return lastGenerationSeed
end

local function createSharedBus()
    if bridgeData or not ac or not ac.connect or not ac.StructItem then
        return bridgeData ~= nil
    end

    local ok, data = pcall(function()
        return ac.connect({
            key = ac.StructItem.key('ACNextGen.PhysicsBridge'),
            generation = ac.StructItem.int32(),
            enabled = ac.StructItem.int32(),

            forceX = ac.StructItem.float(),
            forceY = ac.StructItem.float(),
            forceZ = ac.StructItem.float(),

            inputSequence = ac.StructItem.int32(),
            workerTicks = ac.StructItem.int32(),
            lastDt = ac.StructItem.float(),

            inputValid = ac.StructItem.int32(),
            outputValid = ac.StructItem.int32(),
            outputSequence = ac.StructItem.int32(),
            outputForceX = ac.StructItem.float(),
            outputForceY = ac.StructItem.float(),
            outputForceZ = ac.StructItem.float(),

            appliedCount = ac.StructItem.int32(),
            workerStatus = ac.StructItem.int32(),
        })
    end)

    if not ok or not data then
        state.workerError = tostring(data or "ac.connect() failed")
        return false
    end

    bridgeData = data
    bridgeData.generation = 0
    bridgeData.enabled = 0

    bridgeData.forceX = 0.0
    bridgeData.forceY = 0.0
    bridgeData.forceZ = 0.0

    bridgeData.inputSequence = 0
    bridgeData.workerTicks = 0
    bridgeData.lastDt = 0.0

    bridgeData.inputValid = 0
    bridgeData.outputValid = 0
    bridgeData.outputSequence = 0
    bridgeData.outputForceX = 0.0
    bridgeData.outputForceY = 0.0
    bridgeData.outputForceZ = 0.0

    bridgeData.appliedCount = 0
    bridgeData.workerStatus = 0

    return true
end

local function detectAPI()
    state.apiAvailable =
        physics ~= nil
        and type(physics.startPhysicsWorker) == "function"

    if physics and type(physics.allowed) == "function" then
        local ok, allowed = pcall(physics.allowed)
        state.apiAllowed = ok and allowed == true
    else
        state.apiAllowed = false
    end

    if state.apiAvailable then
        state.mode = "PHYSICS_WORKER_CANDIDATE"
    else
        state.mode = "NO_PHYSICS_WORKER_API"
    end
end

local function startWorker()
    if state.workerRequested
    or not state.apiAvailable
    or not M.params.probeEnabled then
        return
    end

    if not createSharedBus() then
        state.status = "SHARED_BUS_ERROR"
        return
    end

    local generation = newGeneration()

    state.workerGeneration = generation
    bridgeData.generation = generation
    bridgeData.enabled = 0
    bridgeData.workerStatus = 0
    bridgeData.workerTicks = 0
    bridgeData.appliedCount = 0

    local ok, result = pcall(function()
        return physics.startPhysicsWorker(
            WORKER_SOURCE,
            generation,
            function(err)
                if err then
                    state.workerError = tostring(err)
                    state.workerAlive = false
                    state.status = "WORKER_STOPPED_ERROR"
                    log("worker stopped: " .. tostring(err))
                else
                    state.workerAlive = false
                    state.status = "WORKER_STOPPED"
                end
            end
        )
    end)

    if not ok then
        state.workerRequested = false
        state.workerError = tostring(result)
        state.status = "WORKER_START_ERROR"
        return
    end

    state.workerRequested = true
    state.status = "WORKER_STARTING"
end

local function readWorkerHeartbeat(elapsed)
    if not bridgeData then return end

    local ticks = num(bridgeData.workerTicks, 0)

    if ticks ~= state.workerTicks then
        state.workerTicks = ticks
        state.lastWorkerTickTime = elapsed
        state.workerAlive = ticks > 0

        if state.workerAlive then
            state.status = "PHYSICS_WORKER_ALIVE"
            state.mode = "PHYSICS_WORKER"
        end
    elseif state.workerAlive
    and elapsed - state.lastWorkerTickTime > M.params.heartbeatTimeout then
        state.workerAlive = false
        state.status = "WORKER_HEARTBEAT_LOST"
    end

    state.appliedCount = 0
end

local function publishShared(output)
    if not bridgeData then return end

    -- Phase 3-A hard gate: never enable injection.
    bridgeData.enabled = 0

    local valid =
        output ~= nil
        and output.schema == "ACNextGen.PhysicsHub.v1"
        and output.valid == true
        and output.body ~= nil
        and finite(output.body.forceX)
        and finite(output.body.forceY)
        and finite(output.body.forceZ)

    state.inputSequence = state.inputSequence + 1

    bridgeData.inputSequence = state.inputSequence
    bridgeData.inputValid = valid and 1 or 0

    if valid then
        bridgeData.forceX = num(output.body.forceX, 0.0)
        bridgeData.forceY = num(output.body.forceY, 0.0)
        bridgeData.forceZ = num(output.body.forceZ, 0.0)

        state.bodyForce.x = bridgeData.forceX
        state.bodyForce.y = bridgeData.forceY
        state.bodyForce.z = bridgeData.forceZ
    else
        bridgeData.forceX = 0.0
        bridgeData.forceY = 0.0
        bridgeData.forceZ = 0.0

        state.bodyForce.x = 0.0
        state.bodyForce.y = 0.0
        state.bodyForce.z = 0.0
    end

    state.injectionEnabled = false
    state.transferCount = state.transferCount + 1
end

local function readWorkerOutput()
    if not bridgeData then
        state.workerInputValid = false
        state.workerOutputValid = false
        state.workerOutput.available = false
        return
    end

    state.workerInputValid =
        bridgeData.inputValid == 1

    state.workerOutputValid =
        bridgeData.outputValid == 1
        and bridgeData.outputSequence == bridgeData.inputSequence
        and finite(bridgeData.outputForceX)
        and finite(bridgeData.outputForceY)
        and finite(bridgeData.outputForceZ)

    state.workerOutputSequence =
        num(bridgeData.outputSequence, 0)

    state.workerOutput.x =
        num(bridgeData.outputForceX, 0.0)

    state.workerOutput.y =
        num(bridgeData.outputForceY, 0.0)

    state.workerOutput.z =
        num(bridgeData.outputForceZ, 0.0)

    state.workerOutput.available =
        state.workerOutputValid

    -- Never expose a non-zero applied count in Phase 3-A.
    state.appliedCount = 0
end

function M.init()
    detectAPI()
    createSharedBus()

    if not state.apiAvailable then
        state.status = "CSP_WORKER_UNAVAILABLE"
        return
    end

    state.status = "READY"
end

function M.update(dt, car, runtime)
    local elapsed =
        runtime and num(runtime.time, 0.0)
        or nowClock()

    detectAPI()

    if M.params.probeEnabled
    and not state.workerRequested
    and not state.workerAlive then
        startWorker()
    end

    local output = nil

    if runtime then
        output = runtime.physicsOutput
        if not output and runtime.moduleStates
        and runtime.moduleStates.physics then
            output = runtime.moduleStates.physics.output
        end
    end

    publishShared(output)
    readWorkerHeartbeat(elapsed)
    readWorkerOutput()

    state.lastPublishedTime = elapsed

    if state.workerAlive
    and state.workerInputValid
    and state.workerOutputValid then
        state.status = "PHYSICS_WORKER_OUTPUT_VALID"
    elseif state.workerAlive then
        state.status = "PHYSICS_WORKER_WAITING_OUTPUT"
    elseif state.status == "READY"
    or state.status == "WORKER_HEARTBEAT_LOST" then
        state.status = "PHYSICS_WORKER_WAITING"
    end
end

function M.getState()
    return state
end

return M
