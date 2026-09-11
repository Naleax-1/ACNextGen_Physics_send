---@diagnostic disable: undefined-global

--============================================================
-- physics_bridge.lua
-- ACNextGen V1.1 Phase 3
-- Physics Output -> CSP Physics Bridge
--
-- Responsibility (one): transfer Physics Hub output toward CSP physics.
-- No tire model, LSD, suspension, load-transfer or drivetrain math lives here.
--
-- Phase 3 safety policy:
--   * Physics injection is DISABLED.
--   * A CSP physics-worker probe is started when available.
--   * The worker only reports that the physics context is alive.
--   * Non-zero force injection is intentionally reserved for later gates.
--
-- The bridge uses physics.startPhysicsWorker() because CSP documents that
-- physics workers run in the physics-thread context; the CSP CspDebug sample
-- uses the same shared ac.connect()/workerData pattern and calls physics.addForce()
-- from that worker. This bridge does not assume App Lua itself is the injection
-- context.
--============================================================

local M = {}

M.params = {
    probeEnabled = true,
    injectionEnabled = false,       -- MUST remain false until the 1 N gate.
    heartbeatTimeout = 0.75,
    publishInterval = 0.10,
}

local state = {
    schema = "ACNextGen.PhysicsBridge.v1",
    status = "INIT",
    mode = "UNRESOLVED",
    workerRequested = false,
    workerAlive = false,
    workerTicks = 0,
    workerGeneration = 0,
    workerError = "",
    apiAvailable = false,
    apiAllowed = false,
    injectionEnabled = false,
    lastWorkerTickTime = 0.0,
    lastPublishedTime = 0.0,
    transferCount = 0,
    appliedCount = 0,
    bodyForce = { x = 0.0, y = 0.0, z = 0.0 },
}

M.state = state

local bridgeData = nil
local lastPublish = 0.0
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
    workerTicks = ac.StructItem.int32(),
    lastDt = ac.StructItem.float(),
    appliedCount = ac.StructItem.int32(),
    workerStatus = ac.StructItem.int32(),
})

local startGeneration = worker.input
local zero = vec3()
local force = vec3()

function script.update(dt)
    if bridge.generation ~= startGeneration then
        worker.terminate()
        return
    end

    bridge.workerTicks = bridge.workerTicks + 1
    bridge.lastDt = dt
    bridge.workerStatus = 1

    -- Phase 3 is a transport/probe stage. Keep injection disabled even if the
    -- shared structure is accidentally populated by a future caller.
    if bridge.enabled == 1 then
        force:set(bridge.forceX, bridge.forceY, bridge.forceZ)
        physics.addForce(0, zero, false, force, false)
        bridge.appliedCount = bridge.appliedCount + 1
    end
end
]]

local function num(v, fallback)
    local n = tonumber(v)
    if n == nil or n ~= n or n == math.huge or n == -math.huge then
        return fallback or 0.0
    end
    return n
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
            workerTicks = ac.StructItem.int32(),
            lastDt = ac.StructItem.float(),
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
    bridgeData.workerTicks = 0
    bridgeData.lastDt = 0.0
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
    if state.workerRequested or not state.apiAvailable or not M.params.probeEnabled then
        return
    end

    if not createSharedBus() then
        state.status = "SHARED_BUS_ERROR"
        return
    end

    local generation = newGeneration()
    state.workerGeneration = generation
    bridgeData.generation = generation
    bridgeData.enabled = M.params.injectionEnabled and 1 or 0
    bridgeData.workerStatus = 0
    bridgeData.workerTicks = 0
    bridgeData.appliedCount = 0

    local ok, result = pcall(function()
        return physics.startPhysicsWorker(WORKER_SOURCE, generation, function(err)
            if err then
                state.workerError = tostring(err)
                state.workerAlive = false
                state.status = "WORKER_STOPPED_ERROR"
                log("worker stopped: " .. tostring(err))
            else
                state.workerAlive = false
                state.status = "WORKER_STOPPED"
            end
        end)
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

    state.appliedCount = num(bridgeData.appliedCount, state.appliedCount)
end

local function publishShared(output)
    if not bridgeData then return end

    -- Phase 3 hard gate: output is transported as zeros until the explicit
    -- injection gate is enabled in a later phase.
    local allow = M.params.injectionEnabled == true and state.workerAlive
    bridgeData.enabled = allow and 1 or 0

    if allow and output and output.body and output.body.available then
        bridgeData.forceX = num(output.body.forceX, 0.0)
        bridgeData.forceY = num(output.body.forceY, 0.0)
        bridgeData.forceZ = num(output.body.forceZ, 0.0)
    else
        bridgeData.forceX = 0.0
        bridgeData.forceY = 0.0
        bridgeData.forceZ = 0.0
    end

    state.bodyForce.x = bridgeData.forceX
    state.bodyForce.y = bridgeData.forceY
    state.bodyForce.z = bridgeData.forceZ
    state.injectionEnabled = allow
    state.transferCount = state.transferCount + 1
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
    local elapsed = 0.0
    if runtime then
        elapsed = num(runtime.time, 0.0)
    else
        elapsed = nowClock()
    end

    detectAPI()

    if M.params.probeEnabled and not state.workerRequested and not state.workerAlive then
        startWorker()
    end

    readWorkerHeartbeat(elapsed)

    local physicsEntry = runtime
        and runtime.moduleStates
        and nil
    local hub = nil

    if runtime and runtime.moduleStates and runtime.moduleStates.physics then
        hub = runtime.moduleStates.physics
    elseif runtime and runtime.physicsHub then
        hub = runtime.physicsHub
    end

    -- The Physics module itself is registered into runtime.moduleStates before
    -- this bridge executes in later integrations only if the host chooses to do
    -- so. For the current Phase 2 host, read canonical hub output from the
    -- module table stored under runtime.state when available.
    if not hub and runtime and runtime.state then
        hub = runtime.state.physicsHub
    end

    -- Also accept a direct runtime pointer supplied by the host without forcing
    -- a new dependency into Physics.lua.
    if not hub and runtime and runtime.physicsOutput then
        hub = runtime.physicsOutput
    end

    publishShared(hub)

    lastPublish = elapsed
    state.lastPublishedTime = elapsed
end

function M.getState()
    return state
end

return M
