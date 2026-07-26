-- Host tests for shake.lua. Everything here runs against the pure core; the
-- device shell is only checked for "no-ops instead of crashing".
local A = require("assert")
local Shake = require("shake")

-- ---------------------------------------------------------------------------
-- module contract (CONVENTIONS rule 1: loads under host lua, sets the global)
-- ---------------------------------------------------------------------------

A.truthy(Shake, "shake: require returns the module")
A.eq(rawget(_G, "Shake"), Shake, "shake: global and return value are the same table")
A.falsy(Shake.load(), "shake: load() reports not-ready under host lua")

-- ---------------------------------------------------------------------------
-- 32-bit hash: integer, non-negative, never wider than the mask
-- ---------------------------------------------------------------------------

local MASK = Shake.MASK
A.eq(MASK, 0x7fffffff, "shake: mask is 31 bits")

local hashOk, noiseOk = true, true
local sawZero, sawNonZero = false, false
for _, n in ipairs({0, 1, 2, 3, 7, 255, 4096, 65535, 123456, 16777216,
                    1073741823, 2147483646, MASK}) do
    local h = Shake.hash32(n)
    if math.type(h) ~= "integer" then hashOk = false end
    if h < 0 or h > MASK then hashOk = false end
    if h == 0 then sawZero = true else sawNonZero = true end
end
A.truthy(hashOk, "shake: hash32 stays an integer inside [0, MASK]")
A.truthy(sawNonZero, "shake: hash32 produces non-zero output")
A.falsy(sawZero, "shake: hash32 does not collapse to zero on these inputs")

-- A bitwise op on the result must not blow up: that is the on-device failure
-- mode this whole discipline exists to prevent.
A.eq(math.type(Shake.hash32(999) & MASK), "integer", "shake: hash32 output is bit-op safe")

-- Value noise must stay inside [-1, 1] — the magnitude bound below is derived
-- from it, so if this slips the offsets silently exceed `amplitude`.
local nmin, nmax = 1e9, -1e9
for ch = 1, 6 do
    for k = 0, 400 do
        local v = Shake.noise(ch, k * 0.37)
        if type(v) ~= "number" then noiseOk = false end
        if v < nmin then nmin = v end
        if v > nmax then nmax = v end
    end
end
A.truthy(noiseOk, "shake: noise returns numbers")
A.truthy(nmin >= -1.0, "shake: noise floor is -1")
A.truthy(nmax <= 1.0, "shake: noise ceiling is +1")
A.truthy(nmax - nmin > 1.0, "shake: noise actually uses its range")

-- Noise is a function of (channel, t) only — no hidden state.
A.eq(Shake.noise(3, 12.25), Shake.noise(3, 12.25), "shake: noise is pure")

-- ---------------------------------------------------------------------------
-- zero trauma is exactly zero offset
-- ---------------------------------------------------------------------------

local idle = Shake.new({amplitude = 9, rotation = 4, seed = 5})
A.eq(idle.trauma, 0, "shake: a new shaker has no trauma")
A.falsy(idle:isActive(), "shake: a new shaker is inactive")
for _ = 1, 20 do
    local dx, dy = idle:update()
    A.eq(dx, 0, "shake: idle dx is exactly 0")
    A.eq(dy, 0, "shake: idle dy is exactly 0")
end
A.eq(idle:rotationAngle(), 0.0, "shake: idle roll is exactly 0")

-- ---------------------------------------------------------------------------
-- trauma decays to exactly 0 and stays there (never negative)
-- ---------------------------------------------------------------------------

local decayer = Shake.new({amplitude = 6, decay = 0.1, seed = 11})
decayer:add(1.0)
A.eq(decayer.trauma, 1.0, "shake: add clamps at 1")
decayer:add(5.0)
A.eq(decayer.trauma, 1.0, "shake: piling on more trauma still clamps at 1")

local wentNegative = false
for _ = 1, 200 do
    decayer:update()
    if decayer.trauma < 0 then wentNegative = true end
end
A.falsy(wentNegative, "shake: trauma never goes negative")
A.eq(decayer.trauma, 0, "shake: trauma lands on exactly 0")
A.eq(decayer.dx, 0, "shake: dx is 0 once trauma is spent")
A.eq(decayer.dy, 0, "shake: dy is 0 once trauma is spent")
A.falsy(decayer:isActive(), "shake: a spent shaker is inactive")

-- and stays there
for _ = 1, 10 do decayer:update() end
A.eq(decayer.trauma, 0, "shake: spent trauma stays at 0")
A.eq(decayer.dx, 0, "shake: spent shaker keeps dx at 0")

-- ---------------------------------------------------------------------------
-- determinism: same seed + same trauma script -> identical offsets
-- ---------------------------------------------------------------------------

local script = {0.9, 0, 0, 0.4, 0, 0, 0, 0.7, 0, 0, 0, 0, 0.2, 0, 0, 0}

local function run(seed)
    local s = Shake.new({amplitude = 7, rotation = 3, decay = 0.05,
                         frequency = 0.4, power = 2, seed = seed})
    local out = {}
    for frame = 1, 120 do
        local add = script[((frame - 1) % #script) + 1]
        if add > 0 then s:add(add) end
        local dx, dy = s:update()
        out[#out + 1] = dx
        out[#out + 1] = dy
        out[#out + 1] = s:rotationAngle()
    end
    return out
end

local a1, a2, b1 = run(1234), run(1234), run(4321)
local sameSeedMatches, differentSeedDiffers = true, false
for i = 1, #a1 do
    if a1[i] ~= a2[i] then sameSeedMatches = false end
    if a1[i] ~= b1[i] then differentSeedDiffers = true end
end
A.truthy(sameSeedMatches, "shake: same seed replays identically")
A.truthy(differentSeedDiffers, "shake: a different seed shakes differently")

-- ---------------------------------------------------------------------------
-- integer output and magnitude bound
-- ---------------------------------------------------------------------------

local AMP = 8
local bounded = Shake.new({amplitude = AMP, rotation = 5, decay = 0.03,
                           frequency = 0.6, seed = 77})
local allInt, withinBound, maxSeen, rollMax = true, true, 0, 0
for frame = 1, 600 do
    -- Keep it pinned at full trauma for part of the run so the bound is
    -- exercised at maximum magnitude, then let it decay out.
    if frame < 400 then bounded:add(1.0) end
    local dx, dy = bounded:update()
    if math.type(dx) ~= "integer" or math.type(dy) ~= "integer" then allInt = false end
    if math.abs(dx) > AMP or math.abs(dy) > AMP then withinBound = false end
    maxSeen = math.max(maxSeen, math.abs(dx), math.abs(dy))
    rollMax = math.max(rollMax, math.abs(bounded:rotationAngle()))
end
A.truthy(allInt, "shake: offsets are integers")
A.truthy(withinBound, "shake: |offset| never exceeds amplitude")
A.truthy(maxSeen >= AMP - 2, "shake: the shake actually reaches near its amplitude")
A.truthy(rollMax <= 5.0, "shake: |roll| never exceeds the configured rotation")

-- rotation defaults to off, and stays off
local noRoll = Shake.new({amplitude = 6, seed = 3})
noRoll:add(1.0)
local rolled = false
for _ = 1, 60 do
    noRoll:update()
    if noRoll:rotationAngle() ~= 0 then rolled = true end
end
A.falsy(rolled, "shake: rotation is opt-in and stays exactly 0 when unset")

-- ---------------------------------------------------------------------------
-- independent shakers
-- ---------------------------------------------------------------------------

local screen = Shake.new("quake")
local widget = Shake.new("rattle")
widget:add(1.0)
local screenStayedStill = true
for _ = 1, 20 do
    screen:update()
    widget:update()
    if screen.dx ~= 0 or screen.dy ~= 0 then screenStayedStill = false end
end
A.truthy(screenStayedStill, "shake: one shaker's trauma does not leak into another")
A.truthy(widget:isActive(), "shake: the shaken instance is still going")
A.eq(screen.amplitude, Shake.PRESETS.quake.amplitude, "shake: preset by name is applied")

-- a preset table is a template, not shared state
Shake.new("hit").amplitude = 999
A.eq(Shake.PRESETS.hit.amplitude, 6, "shake: instances do not write back into presets")

-- stop() cuts everything dead
local stopper = Shake.new({amplitude = 6, rotation = 2, seed = 9})
stopper:add(1.0)
stopper:update()
stopper:stop()
A.eq(stopper.trauma, 0, "shake: stop clears trauma")
A.eq(stopper.dx, 0, "shake: stop re-centres dx")
A.eq(stopper.dy, 0, "shake: stop re-centres dy")
A.eq(stopper:rotationAngle(), 0.0, "shake: stop re-centres roll")

-- setTrauma clamps both ends
local clamp = Shake.new({seed = 2})
A.eq(clamp:setTrauma(-3), 0, "shake: setTrauma clamps below at 0")
A.eq(clamp:setTrauma(9), 1.0, "shake: setTrauma clamps above at 1")

-- dt scaling: two half-frames decay the same as one whole frame
local whole = Shake.new({decay = 0.1, seed = 1})
local halves = Shake.new({decay = 0.1, seed = 1})
whole:setTrauma(1.0)
halves:setTrauma(1.0)
whole:update(1.0)
halves:update(0.5)
halves:update(0.5)
A.near(whole.trauma, halves.trauma, 1e-9, "shake: decay scales with dt")

-- Shake.main() hands back one shared instance
A.eq(Shake.main(), Shake.main(), "shake: main() is a singleton")

-- ---------------------------------------------------------------------------
-- device shell no-ops under host lua
-- ---------------------------------------------------------------------------

local dx, dy = Shake.apply(widget)
A.eq(dx, 0, "shake: apply is a silent no-op without the SDK")
A.eq(dy, 0, "shake: apply returns a zero offset without the SDK")
Shake.pop()
A.truthy(true, "shake: pop survives an empty stack without the SDK")
