---@diagnostic disable: undefined-global
-- Phase 3-A: single-flight result transport, never a physical application.
-- The app owns input fields; the worker owns output fields. Sequence is the
-- commit marker, written LAST. Neither side overwrites an unconsumed packet.
local M = { params = { probeEnabled = true, injectionEnabled = false,
    heartbeatTimeout = 0.75 } }
local state = {
    schema = "ACNextGen.PhysicsBridge.v3", status = "INIT", mode = "UNRESOLVED",
    workerRequested = false, workerAlive = false, workerTicks = 0,
    workerGeneration = 0, workerError = "", errorCount = 0,
    apiAvailable = false, apiAllowed = false, injectionEnabled = false,
    appliedCount = 0, transferCount = 0, submittedCount = 0,
    inputSequence = 0, pendingSequence = 0, workerOutputSequence = 0,
    workerInputValid = false, workerOutputValid = false,
    lastWorkerTickTime = 0, lastOutputTime = nil, staleTime = 0,
    bodyForce = { x = 0, y = 0, z = 0 },
    workerOutput = { available = false, valid = false, x = 0, y = 0, z = 0 },
}
M.state = state
local bus, pending, completedInput
local lastSubmitted = 0
local stopped = false
local previousTime = nil
local observedWorkerErrors = 0

-- One layout definition is used in BOTH Lua contexts, avoiding ABI drift.
-- Force channels retain their owner's semantics; no body sum is fabricated.
local SHARED = [[
local fields = { 'timestamp', 'speedKmh', 'rpm', 'steer', 'gear', 'brake', 'gas',
    'bodyAvailable', 'forceX', 'forceY', 'forceZ' }
for i = 0, 3 do
    for _, name in ipairs({'lateralForce', 'longitudinalForce', 'load',
            'slipRatio', 'slipAngle', 'omega'}) do
        fields[#fields + 1] = name .. i
    end
end
local layout = { ac.StructItem.key('ACNextGen.PhysicsBridge.Phase3A.v3'),
    generation = ac.StructItem.int32(), enabled = ac.StructItem.int32(),
    inputSequence = ac.StructItem.int32(), inputValid = ac.StructItem.int32(),
    outputSequence = ac.StructItem.int32(), outputValid = ac.StructItem.int32(),
    outputTick = ac.StructItem.int32(), workerTicks = ac.StructItem.int32(),
    appliedCount = ac.StructItem.int32(), workerErrors = ac.StructItem.int32() }
for _, name in ipairs(fields) do
    layout['input_' .. name] = ac.StructItem.double()
    layout['output_' .. name] = ac.StructItem.double()
end
local function finite(v)
    return type(v) == 'number' and v == v and v ~= math.huge and v ~= -math.huge
end
]]
local WORKER_SOURCE = SHARED .. [[
local bridge = ac.connect(layout)
local generation = worker.input
function script.update(dt)
    if bridge.generation ~= generation then worker.terminate(); return end
    bridge.workerTicks = bridge.workerTicks + 1
    local seq = bridge.inputSequence
    -- A completed output is immutable until the app publishes another input.
    if seq <= 0 or seq == bridge.outputSequence then return end
    local packet = {}
    local valid = bridge.inputValid == 1
    for _, name in ipairs(fields) do
        packet[name] = bridge['input_' .. name]
        valid = valid and finite(packet[name])
    end
    if bridge.inputSequence ~= seq or bridge.generation ~= generation then return end
    bridge.outputValid = 0
    for _, name in ipairs(fields) do bridge['output_' .. name] = packet[name] end
    bridge.outputTick = bridge.workerTicks
    bridge.outputValid = valid and 1 or 0
    if not valid then bridge.workerErrors = bridge.workerErrors + 1 end
    bridge.outputSequence = seq -- commit only after payload and metadata
end
]]

local function finite(v)
    return type(v) == 'number' and v == v and v ~= math.huge and v ~= -math.huge
end
local function fault(message)
    if state.workerError ~= tostring(message) then state.errorCount = state.errorCount + 1 end
    state.workerError = tostring(message)
    state.workerOutputValid = false
    state.workerOutput.valid = false
end
local function detectAPI()
    state.apiAvailable = physics ~= nil and type(physics.startPhysicsWorker) == 'function'
    local ok, allowed = false, false
    if physics and type(physics.allowed) == 'function' then ok, allowed = pcall(physics.allowed) end
    state.apiAllowed = ok and allowed == true
    state.mode = state.apiAvailable and 'PHYSICS_WORKER' or 'NO_PHYSICS_WORKER_API'
end
local function createBus()
    if bus then return true end
    if not ac or not ac.connect or not ac.StructItem then return false end
    local ok, result = pcall(function()
        return assert(loadstring(SHARED .. '\nreturn ac.connect(layout)'))()
    end)
    if not ok or not result then
        stopped = true
        fault('connect: ' .. tostring(result or 'no shared bus returned'))
        return false
    end
    bus = result
    -- Persist generation in the shared connection across app reloads. Old
    -- workers observe the change and terminate rather than writing this run.
    state.workerGeneration = (bus.generation % 2147483646) + 1
    bus.generation = state.workerGeneration
    bus.enabled = 0
    bus.inputSequence, bus.inputValid = 0, 0
    bus.outputSequence, bus.outputValid = 0, 0
    bus.outputTick, bus.workerTicks = 0, 0
    bus.appliedCount, bus.workerErrors = 0, 0
    return true
end
local function startWorker()
    if state.workerRequested or stopped or not state.apiAvailable
        or not M.params.probeEnabled then return end
    if not createBus() then state.status = 'SHARED_BUS_UNAVAILABLE'; return end
    state.workerRequested = true
    local generation = state.workerGeneration
    local ok, err = pcall(physics.startPhysicsWorker, WORKER_SOURCE, generation, function(error)
        if generation ~= state.workerGeneration then return end
        stopped = true
        state.workerAlive = false
        fault(error or 'worker stopped')
        state.status = 'WORKER_STOPPED'
    end)
    if not ok then stopped = true; fault('start: ' .. tostring(err)) end
end

local wheelFields = { 'lateralForce', 'longitudinalForce', 'load', 'slipRatio', 'slipAngle', 'omega' }
local vehicleFields = { 'speedKmh', 'rpm', 'steer', 'gear', 'brake', 'gas' }
local function makePacket(output, now)
    if type(output) ~= 'table' or output.schema ~= 'ACNextGen.PhysicsHub.v1'
        or output.available ~= true or output.valid ~= true then return nil, 'hub unavailable/invalid' end
    local seq = output.sequence
    if not finite(seq) or seq <= 0 or seq % 1 ~= 0 or seq >= 2147483647 then
        return nil, 'invalid source sequence'
    end
    if not finite(output.timestamp) or output.timestamp > now
        or now - output.timestamp > M.params.heartbeatTimeout then return nil, 'stale/future source timestamp' end
    if type(output.vehicle) ~= 'table' or type(output.wheel) ~= 'table'
        or type(output.body) ~= 'table' or type(output.body.available) ~= 'boolean' then
        return nil, 'invalid source contract shape'
    end
    local p = { sequence = seq, timestamp = output.timestamp }
    for _, name in ipairs(vehicleFields) do p[name] = output.vehicle[name] end
    local body = output.body
    p.bodyAvailable = body.available and 1 or 0
    -- Unavailable is explicit metadata, NOT a generated zero-force result.
    for _, name in ipairs({'forceX', 'forceY', 'forceZ'}) do
        if p.bodyAvailable == 1 then p[name] = body[name] else p[name] = 0 end
    end
    for i = 0, 3 do
        local w = output.wheel and output.wheel[i]
        if type(w) ~= 'table' or w.available ~= true then return nil, 'wheel unavailable: ' .. i end
        for _, name in ipairs(wheelFields) do p[name .. i] = w[name] end
    end
    for _, name in ipairs(vehicleFields) do
        if not finite(p[name]) then return nil, 'invalid vehicle: ' .. name end
    end
    for _, name in ipairs({'forceX', 'forceY', 'forceZ'}) do
        if not finite(p[name]) then return nil, 'invalid body: ' .. name end
    end
    for i = 0, 3 do
        for _, name in ipairs(wheelFields) do
            if not finite(p[name .. i]) then return nil, 'invalid wheel: ' .. name .. i end
        end
    end
    return p
end
local function publish(packet)
    -- Only called with no outstanding input, or after its output was consumed.
    bus.inputSequence = 0
    bus.inputValid = 0
    for name, value in pairs(packet) do
        if name ~= 'sequence' then bus['input_' .. name] = value end
    end
    bus.inputValid = 1
    bus.inputSequence = packet.sequence
    pending = packet
    lastSubmitted = packet.sequence
    state.pendingSequence = packet.sequence
    state.submittedCount = state.submittedCount + 1
end
local function unpackOutput(packet, tick)
    local out = { schema = 'ACNextGen.WorkerOutput.v3', available = true, valid = true,
        sequence = packet.sequence, tick = tick, timestamp = packet.timestamp,
        source = 'physics_worker', vehicle = {}, wheel = {},
        body = { available = packet.bodyAvailable == 1,
            forceX = packet.forceX, forceY = packet.forceY, forceZ = packet.forceZ },
        forceX = packet.forceX, forceY = packet.forceY, forceZ = packet.forceZ,
        x = packet.forceX, y = packet.forceY, z = packet.forceZ }
    for _, name in ipairs(vehicleFields) do out.vehicle[name] = packet[name] end
    for i = 0, 3 do
        out.wheel[i] = { available = true, verticalAvailable = false, torqueAvailable = false }
        for _, name in ipairs(wheelFields) do out.wheel[i][name] = packet[name .. i] end
    end
    return out
end
local function receive(now)
    if not pending then return end
    local seq = bus.outputSequence
    if seq == state.workerOutputSequence or seq == 0 then return end
    if seq ~= pending.sequence then
        fault('output sequence mismatch: expected ' .. pending.sequence .. ', got ' .. seq)
        return
    end
    local packet = { sequence = seq }
    local valid = bus.outputValid == 1
    for name, expected in pairs(pending) do
        if name ~= 'sequence' then
            local value = bus['output_' .. name]
            packet[name] = value
            valid = valid and finite(value) and value == expected
        end
    end
    local tick = bus.outputTick
    if bus.outputSequence ~= seq then return end
    if not valid or tick <= 0 or tick > bus.workerTicks then
        fault('worker output invalid or payload mismatch'); return
    end
    if packet.timestamp > now or now - packet.timestamp > M.params.heartbeatTimeout then
        fault('worker output stale/future'); return
    end
    completedInput = pending
    state.inputSequence = pending.sequence -- the input paired with THIS output
    state.workerOutputSequence = seq
    state.workerOutput = unpackOutput(packet, tick) -- never the live Hub table
    state.lastOutputTime = packet.timestamp -- age of data, not age of observation
    state.bodyForce = { x = pending.forceX, y = pending.forceY, z = pending.forceZ }
    state.transferCount = state.transferCount + 1 -- acknowledged transfers only
    pending = nil
    state.pendingSequence = 0
end

function M.init()
    detectAPI()
    state.status = 'READY'
end
function M.update(dt, car, runtime)
    local now = runtime and runtime.time
    state.injectionEnabled = false -- no physical API exists in this module
    detectAPI()
    startWorker()
    if not bus then state.status = 'SHARED_BUS_UNAVAILABLE'; return end
    bus.enabled = 0
    state.appliedCount = bus.appliedCount -- observe, never hide an unexpected write
    if not finite(now) then fault('runtime clock invalid'); return end
    if previousTime and now < previousTime then fault('runtime clock regressed') end
    previousTime = now
    if bus.generation ~= state.workerGeneration then
        stopped = true
        fault('shared generation changed; reload required')
    end
    if bus.workerTicks < state.workerTicks then fault('worker tick regressed') end
    if bus.workerErrors > observedWorkerErrors then
        observedWorkerErrors = bus.workerErrors
        fault('worker rejected input: ' .. observedWorkerErrors)
    end
    if pending and now - pending.timestamp > M.params.heartbeatTimeout and state.errorCount == 0 then
        fault('worker response timeout: sequence ' .. pending.sequence)
    end
    if bus.workerTicks > state.workerTicks then state.lastWorkerTickTime = now end
    state.workerTicks = bus.workerTicks
    state.workerAlive = not stopped and bus.workerTicks > 0
        and now >= state.lastWorkerTickTime
        and now - state.lastWorkerTickTime <= M.params.heartbeatTimeout
    local output = runtime and runtime.physicsOutput
    local packet, reason = makePacket(output, now)
    state.sourceValid = packet ~= nil
    state.inputFailure = reason or ''
    if packet and packet.sequence < lastSubmitted then fault('source sequence regressed'); packet = nil end
    -- CONSUME BEFORE PUBLISH. Worker and app clocks need not advance together.
    if state.errorCount == 0 then receive(now) end
    if packet and not pending and packet.sequence > lastSubmitted and state.errorCount == 0 then publish(packet) end
    state.staleTime = state.lastOutputTime and now - state.lastOutputTime or 0
    state.outputStale = state.lastOutputTime == nil or state.staleTime < 0
        or state.staleTime > M.params.heartbeatTimeout
    state.workerInputValid = completedInput ~= nil and packet ~= nil
    state.workerOutputValid = state.workerOutput.available and state.workerInputValid
        and M.params.probeEnabled and state.workerAlive and not state.outputStale and state.errorCount == 0
        and bus.workerErrors == 0 and state.appliedCount == 0
    state.workerOutput.valid = state.workerOutputValid
    state.inputAvailable = completedInput ~= nil or pending ~= nil
    state.status = state.workerOutputValid and 'PHYSICS_WORKER_OUTPUT_VALID'
        or (state.errorCount > 0 and 'PHYSICS_WORKER_ERROR' or 'PHYSICS_WORKER_WAITING_OUTPUT')
end
function M.getState() return state end
return M
