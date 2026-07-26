-- Host tests for particles.lua. The simulation is pure, so everything except
-- draw() is exercised here; draw() is only checked for "no-ops, does not crash".
local A = require("assert")
local Particles = require("particles")

-- ---------------------------------------------------------------------------
-- module contract (CONVENTIONS rule 1)
-- ---------------------------------------------------------------------------

A.truthy(Particles, "particles: require returns the module")
A.eq(rawget(_G, "Particles"), Particles, "particles: global and return value are the same table")
A.falsy(Particles.load(), "particles: load() reports not-ready under host lua")

-- ---------------------------------------------------------------------------
-- deterministic RNG
-- ---------------------------------------------------------------------------

local r1 = Particles.new(4, {seed = 99})
local r2 = Particles.new(4, {seed = 99})
local r3 = Particles.new(4, {seed = 100})
local rngMatches, rngDiffers, inRange = true, false, true
for _ = 1, 500 do
    local a, b, c = r1:random(), r2:random(), r3:random()
    if a ~= b then rngMatches = false end
    if a ~= c then rngDiffers = true end
    if a < 0 or a >= 1 then inRange = false end
end
A.truthy(rngMatches, "particles: same seed gives the same stream")
A.truthy(rngDiffers, "particles: a different seed gives a different stream")
A.truthy(inRange, "particles: random() stays in [0, 1)")

-- injectable generator wins over the seed
local fixed = Particles.new(4, {seed = 1, rand = function() return 0.25 end})
A.eq(fixed:random(), 0.25, "particles: an injected rand overrides the internal one")

-- ---------------------------------------------------------------------------
-- pool: capacity is a hard ceiling, overflow is dropped (documented policy)
-- ---------------------------------------------------------------------------

local CAP = 10
local sys = Particles.new(CAP, {seed = 7})
A.eq(sys.capacity, CAP, "particles: capacity is what was asked for")
A.eq(sys.count, 0, "particles: a new system is empty")
A.eq(sys:free(), CAP, "particles: a new system is fully free")
A.truthy(sys:isEmpty(), "particles: a new system reports empty")

-- Remember the pool tables so we can prove nothing new is ever created.
local original = {}
for i = 1, CAP do original[sys.pool[i]] = true end
A.eq(#sys.pool, CAP, "particles: the pool is exactly `capacity` slots")

local made = sys:emit(100, 100, "burst", 50)
A.eq(made, CAP, "particles: emit returns how many actually fit")
A.eq(sys.count, CAP, "particles: the pool never exceeds capacity")
A.eq(sys.dropped, 40, "particles: the overflow is counted as dropped")
A.eq(sys:free(), 0, "particles: a full pool has no free slots")

-- emitting into a full pool is a no-op, not an error and not an allocation
local more = sys:emit(0, 0, "burst", 5)
A.eq(more, 0, "particles: emitting into a full pool emits nothing")
A.eq(sys.count, CAP, "particles: a full pool stays at capacity")
A.eq(sys.dropped, 45, "particles: the second overflow is counted too")
A.eq(#sys.pool, CAP, "particles: overflow did not grow the pool")

local stillOriginal = true
for i = 1, CAP do
    if not original[sys.pool[i]] then stillOriginal = false end
end
A.truthy(stillOriginal, "particles: every slot is still one of the preallocated tables")

-- ---------------------------------------------------------------------------
-- a particle dies exactly at its lifetime
-- ---------------------------------------------------------------------------

local timed = Particles.new(4, {seed = 3})
local SPEC = {n = 1, speed = {0, 0}, life = {10, 10}, size = {2, 2},
              style = Particles.SOLID, grav = 0, drag = 0, spread = 0}
A.eq(timed:emit(50, 50, SPEC, 1), 1, "particles: one particle emitted")
for frame = 1, 9 do
    timed:update()
    A.eq(timed.count, 1, "particles: alive at frame " .. frame .. " of a 10-frame life")
end
timed:update()
A.eq(timed.count, 0, "particles: dead exactly on the frame its lifetime elapses")
A.eq(timed:free(), 4, "particles: the slot came back")

-- ---------------------------------------------------------------------------
-- a full emit -> expire cycle returns the pool to fully free
-- ---------------------------------------------------------------------------

local cycle = Particles.new(64, {seed = 21})
local poolIds = {}
for i = 1, 64 do poolIds[cycle.pool[i]] = true end

for round = 1, 5 do
    cycle:emit(200, 120, "burst", 20)
    cycle:emit(120, 60, "puff", 10)
    cycle:emit(300, 200, "spark", 15)
    A.truthy(cycle.count <= cycle.capacity, "particles: round " .. round .. " respects capacity")
    for _ = 1, 200 do cycle:update() end
    A.eq(cycle.count, 0, "particles: round " .. round .. " fully expires")
    A.eq(cycle:free(), 64, "particles: round " .. round .. " returns the pool fully free")
end
A.truthy(cycle:isEmpty(), "particles: the system is empty after a full cycle")
A.eq(#cycle.pool, 64, "particles: the pool is still exactly 64 slots")
local recycled = true
for i = 1, 64 do
    if not poolIds[cycle.pool[i]] then recycled = false end
end
A.truthy(recycled, "particles: slots were recycled, not reallocated")

-- ---------------------------------------------------------------------------
-- no allocation growth across many emit/update frames
-- ---------------------------------------------------------------------------
-- Collecting at both ends makes this a test of *retained* growth, which is the
-- property that matters: a pool that quietly grows is the GC stall this module
-- exists to avoid.
local churn = Particles.new(128, {seed = 5})
collectgarbage("collect")
local kbBefore = collectgarbage("count")
for frame = 1, 2000 do
    if frame % 7 == 0 then churn:emit(100, 100, "spark", 6) end
    churn:update()
end
collectgarbage("collect")
local kbAfter = collectgarbage("count")
A.truthy(kbAfter - kbBefore < 8, "particles: 2000 frames of churn retain no measurable heap")
A.truthy(churn.count <= 128, "particles: churn never overran the pool")

-- ---------------------------------------------------------------------------
-- simulation determinism
-- ---------------------------------------------------------------------------

local function simulate(seed)
    local s = Particles.new(48, {seed = seed})
    local out = {}
    for frame = 1, 90 do
        if frame % 10 == 1 then s:emit(200, 120, "spark", 8, 270) end
        s:update()
        s:each(function(p)
            out[#out + 1] = p.x
            out[#out + 1] = p.y
            out[#out + 1] = p.dsize
            out[#out + 1] = p.level
        end)
    end
    return out
end

local d1, d2, d3 = simulate(555), simulate(555), simulate(556)
A.eq(#d1, #d2, "particles: the same seed produces the same number of samples")
local simMatches, simDiffers = true, false
for i = 1, #d1 do
    if d1[i] ~= d2[i] then simMatches = false end
    if d3[i] ~= nil and d1[i] ~= d3[i] then simDiffers = true end
end
A.truthy(simMatches, "particles: the same seed replays the same simulation")
A.truthy(simDiffers, "particles: a different seed produces a different simulation")
A.truthy(#d1 > 0, "particles: the simulation actually produced particles")

-- ---------------------------------------------------------------------------
-- physics and 1-bit fade behaviour
-- ---------------------------------------------------------------------------

local phys = Particles.new(8, {seed = 4})
local FALL = {n = 1, speed = {0, 0}, life = {60, 60}, size = {4, 4},
              style = Particles.SHRINK, grav = 0.5, drag = 0, spread = 0}
phys:emit(10, 10, FALL, 1)
local p = phys.pool[1]
phys:update()
A.near(p.vy, 0.5, 1e-9, "particles: gravity accumulates into vy")
A.near(p.y, 10.5, 1e-9, "particles: velocity integrates into y")
phys:update()
A.near(p.vy, 1.0, 1e-9, "particles: gravity keeps accumulating")
A.eq(math.type(p.ix), "integer", "particles: the draw x is pre-floored to an integer")
A.eq(math.type(p.iy), "integer", "particles: the draw y is pre-floored to an integer")

-- drag bleeds speed off
local dragged = Particles.new(4, {seed = 4})
local GLIDE = {n = 1, speed = {4, 4}, life = {60, 60}, size = {2, 2},
               style = Particles.SOLID, grav = 0, drag = 0.5, spread = 0, dir = 0}
dragged:emit(0, 0, GLIDE, 1)
local g = dragged.pool[1]
A.near(g.vx, 4.0, 1e-9, "particles: emitted at the requested speed along dir 0")
dragged:update()
A.near(g.vx, 2.0, 1e-9, "particles: drag halves the velocity")
dragged:update()
A.near(g.vx, 1.0, 1e-9, "particles: drag compounds")

-- SHRINK never reaches zero size (a zero-size fillRect draws nothing at all,
-- so the particle would vanish a few frames before it actually dies)
local shrinkOk, shrinkMax, shrankSome = true, 0, false
phys:clear()
phys:emit(10, 10, FALL, 1)
local sp = phys.pool[1]
for _ = 1, 59 do
    phys:update()
    if sp.dsize < 1 then shrinkOk = false end
    if sp.dsize > shrinkMax then shrinkMax = sp.dsize end
    if sp.dsize < 4 then shrankSome = true end
end
A.truthy(shrinkOk, "particles: a shrinking particle never drops below 1px")
A.eq(shrinkMax, 4, "particles: a shrinking particle never exceeds its emitted size")
A.truthy(shrankSome, "particles: a shrinking particle does shrink")

-- FADE walks the ink levels down and stays inside 1..4
local fader = Particles.new(4, {seed = 6})
local SMOKE = {n = 1, speed = {0, 0}, life = {40, 40}, size = {3, 3},
               style = Particles.FADE, grav = 0, drag = 0, spread = 0}
fader:emit(20, 20, SMOKE, 1)
local f = fader.pool[1]
A.eq(f.level, 4, "particles: a fresh FADE particle starts at full ink")
local levelOk, lastLevel, wentDown = true, 4, false
for _ = 1, 39 do
    fader:update()
    if f.level < 1 or f.level > 4 then levelOk = false end
    if f.level > lastLevel then levelOk = false end   -- must be monotone
    if f.level < lastLevel then wentDown = true end
    lastLevel = f.level
end
A.truthy(levelOk, "particles: FADE ink level stays in 1..4 and never brightens")
A.truthy(wentDown, "particles: FADE ink level actually falls")
A.eq(lastLevel, 1, "particles: FADE ends on the faintest level")

-- ---------------------------------------------------------------------------
-- clear(), presets, and the device shell
-- ---------------------------------------------------------------------------

local c = Particles.new(16, {seed = 8})
c:emit(0, 0, "burst", 10)
A.eq(c.count, 10, "particles: emitted 10")
c:clear()
A.eq(c.count, 0, "particles: clear kills everything")
A.eq(c:free(), 16, "particles: clear frees the whole pool")
A.eq(#c.pool, 16, "particles: clear does not touch the pool itself")

for _, name in ipairs({"burst", "puff", "spark"}) do
    A.truthy(Particles.PRESETS[name], "particles: preset '" .. name .. "' exists")
end

-- an unknown preset name falls back rather than erroring mid-frame
local fb = Particles.new(8, {seed = 2})
A.eq(fb:emit(0, 0, "no-such-preset", 3), 3, "particles: an unknown preset name falls back")

-- draw() must be a silent no-op without the SDK
c:emit(10, 10, "puff", 4)
c:update()
c:draw()
A.truthy(true, "particles: draw is a silent no-op without the SDK")
