-- Offline LuaJIT regression tests. All AC/CSP objects below are TEST DOUBLES.
-- Run from the repository root: luajit Phase3-A/test_transport.lua
-- These tests cannot prove CSP scheduling/ABI or vehicle behavior in AC.
local root = 'Phase3-A/'
local tests, failed = 0, 0
local function test(name, fn)
    tests = tests + 1
    local ok, err = pcall(fn)
    if not ok then failed = failed + 1 end
    print((ok and 'OK   ' or 'FAIL ') .. name .. (ok and '' or (': ' .. tostring(err))))
end
local function equal(a, b, message)
    assert(a == b, (message or 'mismatch') .. ': ' .. tostring(a) .. ' != ' .. tostring(b))
end
local producers = {'tire_state', 'load_transfer', 'mass_balance', 'suspension',
    'drivetrain', 'diff_lsd', 'tire_force', 'yaw_moment_budget'}
local function fixture()
    local f = {shared = nil, layout = nil, workers = {}, stores = {}, calls = 0}
    f.car = {speedKmh=52.4, rpm=4800, steer=0.18, gear=3, brake=0, gas=0.72,
        clutch=1, handbrake=0, mass=1200, wheels={}, localAngularVelocity={x=0,y=0.1,z=0},
        localVelocity={x=1,y=0,z=14}, velocity={x=1,y=0,z=14}, accG={x=0.1,y=0,z=0.2}}
    for i=0,3 do f.car.wheels[i] = {load=3000+i*100, angularSpeed=45+i,
        slipRatio=0.02, slipAngle=0.03, suspensionTravel=0.1, radius=0.33,
        tyreRadius=0.33, tyreWidth=0.22, isInContact=true} end
    f.env = setmetatable({}, {__index=_G})
    f.env._G = f.env
    local ac = {
        StructItem = { key=function(k) return k end, int32=function() return 'int' end,
            double=function() return 'double' end, float=function() return 'float' end },
        store=function(k,v) f.stores[k]=v end, load=function(k) return f.stores[k] end,
        log=function() end, getCar=function() return f.car end,
    }
    ac.connect = function(layout)
        if f.layout then
            for k,v in pairs(layout) do equal(v, f.layout[k], 'app/worker ABI ' .. k) end
            for k,v in pairs(f.layout) do equal(v, layout[k], 'worker/app ABI ' .. k) end
        else
            f.layout = layout
            local data = {}
            for k in pairs(layout) do if type(k)=='string' then data[k]=0 end end
            f.shared = setmetatable({}, {
                __index=function(_,k) assert(layout[k], 'unknown read ' .. k); return data[k] end,
                __newindex=function(_,k,v)
                    assert(layout[k], 'unknown write ' .. k)
                    assert(type(v)=='number', 'non-numeric bus field ' .. k)
                    data[k]=v
                    if f.onWrite then f.onWrite(k,v) end
                end })
        end
        return f.shared
    end
    f.env.ac = ac
    f.env.physics = {
        allowed=function() return true end,
        addForce=function() f.calls=f.calls+1; error('Injection forbidden') end,
        startPhysicsWorker=function(source,generation,callback)
            local w = { stopped=false, callback=callback }
            local env = setmetatable({ script={}, worker={ input=generation,
                terminate=function() w.stopped=true end } }, {__index=f.env})
            setfenv(assert(loadstring(source)),env)()
            w.update=env.script.update
            f.workers[#f.workers+1]=w
        end,
    }
    function f:load(path) return setfenv(assert(loadfile(root .. path)),self.env)() end
    f.hub=f:load('modules/physics.lua')
    f.bridge=f:load('modules/physics_bridge.lua')
    f.output=f:load('modules/worker_output.lua')
    f.observer=f:load('modules/observer.lua')
    f.hub.init(); f.bridge.init(); f.output.init(); f.observer.init()
    f.runtime = {frame=0,time=0,totalErrorCount=0,lastError='',moduleStates={},
        moduleWheelStates={tire_force={},tire_state={}},moduleUpdatedAt={},moduleErrors={},
        state={dt=1/60,vehicle={valid=true,wheelsValid=true}}}
    for _,k in ipairs({'speedKmh','rpm','steer','gear','brake','gas'}) do
        f.runtime.state.vehicle[k]=f.car[k]
    end
    for _,name in ipairs(producers) do f.runtime.moduleStates[name]={} end
    for i=0,3 do
        f.runtime.moduleWheelStates.tire_force[i]={lateral=123.5+i*71,longitudinal=-45.25-i*29}
        f.runtime.moduleWheelStates.tire_state[i]={load=3000+i*100,omega=45+i,
            filteredSlipRatio=0.02+i*0.01,filteredSlipAngle=-0.03-i*0.01}
    end
    function f:worker(n)
        for _=1,n or 1 do
            local w=self.workers[#self.workers]
            assert(w and not w.stopped, 'no running worker')
            w.update(1/333)
        end
    end
    function f:app()
        self.bridge.update(1/60,self.car,self.runtime)
        self.runtime.physicsBridge=self.bridge.state
        self.output.update(1/60,self.car,self.runtime)
        self.runtime.workerOutput=self.output.state
        self.observer.update(0.05,self.car,self.runtime)
    end
    function f:step(dt)
        self.runtime.time=self.runtime.time+(dt or 1/60)
        self.runtime.frame=self.runtime.frame+1
        for _,name in ipairs(producers) do self.runtime.moduleUpdatedAt[name]=self.runtime.time end
        self.hub.update(dt or 1/60,self.car,self.runtime)
        self.runtime.physicsOutput=self.hub.state.output
        self.runtime.moduleStates.physics=self.hub.state
        self:app()
    end
    function f:ready()
        self:step(); self:worker(5); self:step()
        assert(self.output.state.valid, self.output.state.status .. ': ' .. self.output.state.failure)
    end
    return f
end

test('startup wait is not an error or a PASS',function()
    local f=fixture(); f:step()
    equal(f.output.state.valid,false); equal(f.output.state.error_count,0)
    equal(f.bridge.state.transferCount,0)
end)
test('asynchronous previous-input response is paired before next publish',function()
    local f=fixture(); f:ready()
    equal(f.output.state.input_sequence,1); equal(f.output.state.output_sequence,1)
    equal(f.output.state.pending_sequence,2); equal(f.output.state.transfer_count,1)
    assert(f.observer.state.verification.overall)
end)
test('returned wheel channels preserve all four independently',function()
    local f=fixture(); f:ready()
    for i=0,3 do
        local w=f.output.state.values.wheel[i]
        equal(w.lateralForce,123.5+i*71); equal(w.longitudinalForce,-45.25-i*29)
        equal(w.load,3000+i*100); equal(w.omega,45+i)
    end
    equal(f.output.state.values.vehicle.rpm,4800)
end)
test('unavailable body is not fabricated as an available zero',function()
    local f=fixture(); f:ready()
    equal(f.output.state.body_available,false)
    equal(f.output.state.values.wheel[0].verticalAvailable,false)
    local lines={}; f.env.ui={text=function(s) lines[#lines+1]=s end,separator=function() end}
    f.observer.drawUI(f.runtime,{})
    assert(table.concat(lines,'\n'):find('N/A %(no producer%)'))
end)
test('output is a worker snapshot, not a mutable Hub reference',function()
    local f=fixture(); f:ready(); local out=f.output.state.values
    f.hub.state.output.wheel[0].lateralForce=99999
    equal(out.wheel[0].lateralForce,123.5)
    assert(out ~= f.hub.state.output)
end)
test('slow worker never has its outstanding input overwritten',function()
    local f=fixture(); f:step()
    for i=1,10 do f:step() end
    equal(f.shared.inputSequence,1); equal(f.bridge.state.submittedCount,1)
    f:worker(); f:step(); assert(f.output.state.valid)
    equal(f.output.state.output_sequence,1); equal(f.output.state.pending_sequence,12)
end)
test('repeated worker ticks do not fabricate new transfers',function()
    local f=fixture(); f:ready(); f:worker(100); f:app()
    local n=f.bridge.state.transferCount
    for _=1,5 do f:worker(); f:app() end
    equal(f.bridge.state.transferCount,n)
end)
test('short gap without a new tick is fresh, not instantly invalid',function()
    local f=fixture(); f:ready(); f.runtime.time=f.runtime.time+0.01; f:app()
    assert(f.output.state.valid)
end)
test('tick activity cannot refresh a frozen output timestamp',function()
    local f=fixture(); f:ready(); f:worker(); f:app()
    f.runtime.time=f.runtime.time+0.8; f:worker(10); f:app()
    assert(f.bridge.state.workerAlive); assert(f.output.state.stale)
    assert(not f.output.state.valid and f.output.state.error_count>0)
end)
test('heartbeat loss blocks output and retains error after recovery',function()
    local f=fixture(); f:ready(); f.runtime.time=f.runtime.time+0.8; f:app()
    assert(not f.output.state.valid); local errors=f.output.state.error_count
    assert(errors>0); f:worker(); f:step()
    assert(f.output.state.error_count>=errors and not f.output.state.valid)
end)
test('future output sequence is rejected',function()
    local f=fixture(); f:step(); f:worker(); f.shared.outputSequence=2; f:app()
    assert(f.output.state.error_count>0 and not f.output.state.valid)
end)
test('old output sequence is rejected, not relabelled',function()
    local f=fixture(); f.runtime.frame=10; f:step(); f:worker()
    f.shared.outputSequence=3; f:app()
    equal(f.bridge.state.transferCount,0); assert(f.output.state.error_count>0)
end)
test('matching sequence with modified payload is rejected',function()
    local f=fixture(); f:step(); f:worker(); f.shared.output_lateralForce0=999; f:app()
    equal(f.bridge.state.transferCount,0); assert(f.output.state.error_count>0)
end)
for _,value in ipairs({0/0,math.huge,-math.huge,'12'}) do
    test('invalid producer numeric is not defaulted to valid zero: '..tostring(value),function()
        local f=fixture(); f.runtime.moduleWheelStates.tire_force[0].lateral=value; f:step()
        equal(f.hub.state.output.valid,false); equal(f.bridge.state.submittedCount,0)
        equal(f.output.state.valid,false)
    end)
end
test('missing producer field blocks publishing',function()
    local f=fixture(); f.runtime.moduleWheelStates.tire_force[0].lateral=nil; f:step()
    equal(f.hub.state.output.valid,false); equal(f.bridge.state.submittedCount,0)
end)
test('missing FL cannot alias FR',function()
    local f=fixture(); f.runtime.moduleWheelStates.tire_force[0]=nil; f:step()
    equal(f.hub.state.output.valid,false); equal(f.bridge.state.submittedCount,0)
end)
test('three-wheel car does not count FL twice',function()
    local f=fixture(); f:ready(); f.car.wheels[0]=nil; f:app()
    equal(f.output.state.checks.wheels_valid,false); equal(f.output.state.valid,false)
end)
test('zero wheel force is a legitimate producer result',function()
    local f=fixture()
    for i=0,3 do local w=f.runtime.moduleWheelStates.tire_force[i]; w.lateral=0; w.longitudinal=0 end
    f:ready(); equal(f.output.state.values.wheel[0].lateralForce,0)
end)
test('missing physics API never grants PASS',function()
    local f=fixture(); f.env.physics.startPhysicsWorker=nil; f:step()
    equal(f.output.state.valid,false); equal(#f.workers,0)
end)
test('worker callback error remains visible',function()
    local f=fixture(); f:ready(); f.workers[1].callback('injected test worker error'); f:app()
    assert(not f.output.state.valid and f.output.state.error_count>0)
    assert(f.output.state.failure:find('injected test worker error'))
end)
test('unexpected Applied is observed, not hidden by a hardcoded zero',function()
    local f=fixture(); f:ready(); f.shared.appliedCount=1; f:app()
    equal(f.output.state.injection.applied,1); equal(f.observer.state.appliedCount,1)
    assert(not f.output.state.valid and not f.observer.state.verification.overall)
end)
test('changing injection parameter cannot call physical API',function()
    local f=fixture(); f.bridge.params.injectionEnabled=true; f:ready()
    equal(f.shared.enabled,0); equal(f.calls,0); equal(f.output.state.injection.enabled,false)
end)
test('retained runtime errors block transport PASS',function()
    local f=fixture(); f:ready(); f.runtime.totalErrorCount=1; f.runtime.lastError='producer test error'; f:app()
    equal(f.output.state.valid,false); assert(f.output.state.failure:find('producer test error'))
end)
test('Observer cannot overrule a failed validator',function()
    local f=fixture(); f:ready(); f.output.state.valid=false; f.output.state.status='TEST_BLOCKED'
    f.observer.update(0.2,f.car,f.runtime)
    equal(f.observer.state.verification.overall,false); equal(f.observer.state.status,'TEST_BLOCKED')
end)
test('source freshness is tied to module update times',function()
    local f=fixture(); f:step(); f.runtime.time=1
    f.hub.update(1/60,f.car,f.runtime)
    equal(f.hub.state.output.valid,false)
end)
test('worker runs during app payload publication without reading a torn packet',function()
    local f=fixture(); f:step(); f:worker(); f:app()
    f.onWrite=function(key)
        if key:find('^input_') then f:worker() end
    end
    f:worker(); f:step(); f:worker(); f:step()
    assert(f.output.state.valid); equal(f.output.state.error_count,0)
end)
test('worker startup exception remains diagnostic',function()
    local f=fixture(); f.env.physics.startPhysicsWorker=function() error('test start failed') end
    f:step(); assert(f.output.state.error_count>0); equal(f.output.state.valid,false)
end)

print(string.format('\n%d tests, %d failures (offline mocks, NOT AC validation)',tests,failed))
assert(failed==0, 'offline regression failures: '..failed)
