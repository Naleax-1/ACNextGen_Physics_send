---@diagnostic disable: undefined-global
-- ACNextGen V1.1 Phase 1 Observer
-- Diagnostic only: no physics calculation and no physics injection.

local M = {}
local logTimer = 0.0
local WHEEL_NAMES = { [0] = "FL", [1] = "FR", [2] = "RL", [3] = "RR" }

local function num(v, fallback)
    local n = tonumber(v)
    if n == nil or n ~= n or n == math.huge or n == -math.huge then return fallback or 0.0 end
    return n
end

local function field(obj, key, fallback)
    if not obj then return fallback end
    local ok, value = pcall(function() return obj[key] end)
    if not ok or value == nil then return fallback end
    return value
end

local function loadNum(key, fallback)
    if not ac or not ac.load then return fallback or 0.0 end
    local ok, value = pcall(ac.load, key)
    if not ok or value == nil then return fallback or 0.0 end
    return num(value, fallback)
end

local function loadText(key, fallback)
    if not ac or not ac.load then return fallback or "" end
    local ok, value = pcall(ac.load, key)
    if not ok or value == nil then return fallback or "" end
    return tostring(value)
end

local function wheel(car, i)
    local wheels = field(car, "wheels", nil)
    if not wheels then return nil end
    local ok, value = pcall(function() return wheels[i] or wheels[i + 1] end)
    return ok and value or nil
end

function M.init()
    if ac and ac.log then ac.log("[ACNextGen] Phase 1 Observer loaded") end
end

function M.update(dt, car, runtime)
    logTimer = logTimer + num(dt, 0.0)
    if logTimer < 1.0 then return end
    logTimer = 0.0
    if ac and ac.log and car then
        ac.log(string.format("[ACNextGen Phase1] speed=%.1f rpm=%.0f gear=%d wheels=%s",
            num(field(car, "speedKmh", 0.0), 0.0),
            num(field(car, "rpm", 0.0), 0.0),
            math.floor(num(field(car, "gear", 0), 0)),
            field(car, "wheels", nil) and "OK" or "NO"))
    end
end

function M.drawUI(runtime, modules)
    local car = ac and ac.getCar and ac.getCar(0) or nil
    ui.text("=== ACNextGen V1.1 / PHASE 3 ===")
    ui.text("Physical Integration Foundation")
    ui.separator()

    ui.text("Runtime")
    ui.text("  ACNextGen      : " .. (runtime.initialized and "READY" or "INIT"))
    ui.text("  Vehicle        : " .. (runtime.carOK and "OK" or "NO CAR"))
    ui.text("  Wheels         : " .. (runtime.wheelsOK and "OK" or "NO WHEELS"))
    ui.text(string.format("  Modules        : %d / 13", runtime.loadedCount or 0))
    ui.text("  Active Errors  : " .. tostring(runtime.activeErrorCount or 0))
    ui.text("  State Bus      : " .. (runtime.moduleStates and "ON" or "OFF"))
    ui.text("  Module States  : " .. tostring((function()
        local count = 0
        if runtime.moduleStates then
            for _ in pairs(runtime.moduleStates) do count = count + 1 end
        end
        return count
    end)()))
    ui.separator()

    local vehicle = runtime.state and runtime.state.vehicle or nil
    if vehicle and vehicle.valid then
        ui.text("Vehicle State / Runtime State Bus")
        ui.text(string.format("  Speed          : %.1f km/h", num(vehicle.speedKmh,0)))
        ui.text(string.format("  RPM            : %.0f", num(vehicle.rpm,0)))
        ui.text(string.format("  Gear           : %d", math.floor(num(vehicle.gear,0))))
        ui.text(string.format("  Steer          : %.3f", num(vehicle.steer,0)))
        ui.text(string.format("  Gas            : %.3f", num(vehicle.gas,0)))
        ui.text(string.format("  Brake          : %.3f", num(vehicle.brake,0)))
        ui.separator()
        ui.text("Four Wheel Check")
        for i = 0, 3 do
            ui.text(string.format("  %s : %s", WHEEL_NAMES[i], wheel(car,i) and "OK" or "MISSING"))
        end
    else
        ui.text("Vehicle State")
        ui.text("  Vehicle not found")
    end

    ui.separator()
    ui.text("Module Health / Phase 2")
    for i = 1, #modules do
        local e = modules[i]
        ui.text(string.format("  %-18s %s", tostring(e.name), tostring(e.lastStatus or "UNKNOWN")))
    end

    ui.separator()
    ui.text("Physics Hub / Phase 2")
    ui.text("  Schema          : ACNextGen.PhysicsHub.v1")
    ui.text("  Hub Valid       : " .. (loadNum("ngp_hub_valid", 0) == 1 and "PASS" or "WAIT"))
    ui.text("  Source          : " .. loadText("ngp_hub_source", "unknown"))
    ui.text("  Direct Modules  : " .. tostring(loadNum("ngp_hub_direct_module_count", 0)) .. " / 8 expected")


    ui.separator()
    ui.text("Physics Bridge / Phase 3")
    local bridge = runtime.physicsBridge or (runtime.moduleStates and runtime.moduleStates.physics_bridge)
    if bridge then
        ui.text("  Status          : " .. tostring(bridge.status or "UNKNOWN"))
        ui.text("  Mode            : " .. tostring(bridge.mode or "UNKNOWN"))
        ui.text("  Worker API      : " .. (bridge.apiAvailable and "AVAILABLE" or "MISSING"))
        ui.text("  Worker Alive    : " .. (bridge.workerAlive and "YES" or "NO"))
        ui.text("  Worker Ticks    : " .. tostring(bridge.workerTicks or 0))
        ui.text("  Injection       : " .. (bridge.injectionEnabled and "ARMED" or "DISABLED"))
        ui.text("  Transfers       : " .. tostring(bridge.transferCount or 0))
        ui.text("  Applied         : " .. tostring(bridge.appliedCount or 0))
        if bridge.workerError and bridge.workerError ~= "" then
            ui.text("  Error           : " .. tostring(bridge.workerError))
        end
    else
        ui.text("  Bridge state    : WAIT")
    end

    ui.separator()
    ui.text("Phase 1 Gate (preserved)")
    ui.text("  Loaded 13 modules : " .. (loadNum("ngp_phase1_loaded_13",0) == 1 and "PASS" or "WAIT"))
    ui.text("  Vehicle acquired  : " .. (loadNum("ngp_phase1_car_ok",0) == 1 and "PASS" or "WAIT"))
    ui.text("  Wheels available  : " .. (loadNum("ngp_phase1_wheels_ok",0) == 1 and "PASS" or "WAIT"))
    ui.text("  No active errors  : " .. (loadNum("ngp_phase1_no_active_errors",0) == 1 and "PASS" or "WAIT"))
end

return M
