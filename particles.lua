-- particles.lua — pooled 1-bit particle system.
--
-- Two hard constraints shaped every decision here.
--
-- 1. The heap. A 168 MHz Cortex-M7 with a small heap running a 30-50 fps loop
--    cannot afford a table per particle per emit: the allocation is cheap, the
--    collection is not, and it lands as a stutter in the exact frame the game
--    just blew something up. So the pool is allocated once in `Particles.new`
--    and never grows. Emitting reinitialises a slot; dying swaps a slot to the
--    back. Nothing in `emit`, `update` or `draw` creates a table.
--
-- 2. One bit. There is no alpha, so "fading out" has to be a dither ramp, a
--    shrink, or both. `FADE` walks a particle down four Bayer levels over its
--    life; `SHRINK` scales it toward a single pixel. Both are computed in the
--    pure step so a test can pin them.
--
-- The simulation is pure math (no SDK call above the device shell), which is
-- what makes `emit -> N frames -> pool free again` testable on the host.
--
-- Overflow policy: **emits past capacity are dropped**, counted in
-- `sys.dropped`, never allocated. Recycling the oldest live particle would
-- need an O(n) scan or a second ordering structure on every emit, and the
-- failure mode of dropping (a slightly thinner spray) is far kinder than the
-- failure mode of scanning (a frame spike precisely when the screen is busy).
-- Watch `sys.dropped` and size the pool up.

Particles = Particles or {}

local pd  = rawget(_G, "playdate")
local gfx = pd and pd.graphics

local floor <const> = math.floor
local cos <const>   = math.cos
local sin <const>   = math.sin
local rad <const>   = math.rad

-- ---------------------------------------------------------------------------
-- pure: deterministic RNG
-- ---------------------------------------------------------------------------

-- Same 32-bit discipline as shake.lua. Every constant is below 2^31 (a larger
-- literal is silently lexed as a *float* on-device, and the bitwise op below
-- then dies with "number has no integer representation"), and the state is
-- masked after each step. The multiply overflows 32 bits on-device, which is
-- fine and deliberate: integer multiplication wraps, and the low 31 bits the
-- mask keeps are identical to the ones the 64-bit host computes. That is what
-- makes a spray reproducible in a test.
local MASK <const> = 0x7fffffff
local LCG_A <const> = 1103515245
local LCG_C <const> = 12345
local RSCALE <const> = 1.0 / 16777216.0   -- 1/2^24, float literal on purpose

Particles.MASK = MASK

-- ---------------------------------------------------------------------------
-- pure: particle styles
-- ---------------------------------------------------------------------------

local SOLID  <const> = 1   -- constant size, constant ink
local FADE   <const> = 2   -- constant size, dithers out over its life
local SHRINK <const> = 3   -- solid ink, shrinks toward one pixel

Particles.SOLID, Particles.FADE, Particles.SHRINK = SOLID, FADE, SHRINK

-- Number of ink levels. Four is the useful maximum on this panel: past that
-- the Bayer steps are indistinguishable at particle sizes and each extra level
-- costs another sweep of the array in draw().
local LEVELS <const> = 4

-- Level 1..3 are dither coverages, level 4 is solid. Larger = more ink, which
-- is the convention backgrounds.lua already uses in this repo. Never 0: rule 6
-- — an all-zero pattern renders solid black, i.e. the opposite of invisible.
local INK <const> = {0.25, 0.5, 0.75}

-- ---------------------------------------------------------------------------
-- pure: presets
-- ---------------------------------------------------------------------------

-- Velocities are pixels/frame and lifetimes are frames, matching the rest of
-- this repo (transitions.lua counts frames, not seconds). Angles: degrees,
-- 0 = right, growing clockwise because screen y grows downward — so 270 is up.
Particles.PRESETS = {
    -- A tight ring of hard dots. Reads as an impact; no gravity, so it stays
    -- where it was fired and dies in place.
    burst = { n = 14, speed = {1.2, 2.6}, life = {8, 14}, size = {2, 2},
              style = SOLID, grav = 0, drag = 0.12, spread = 360 },

    -- Slow, big, drifts up a touch, dithers away. The one preset that actually
    -- looks like smoke in 1 bit — a solid puff just looks like a blob.
    puff  = { n = 10, speed = {0.25, 0.9}, life = {18, 30}, size = {3, 5},
              style = FADE, grav = -0.02, drag = 0.06, spread = 360 },

    -- Fast, gravity-bound, shrinking to a pixel. Aimed up by default; pass a
    -- direction to emit() to fire it off a surface.
    spark = { n = 18, speed = {1.5, 4.0}, life = {12, 22}, size = {3, 3},
              style = SHRINK, grav = 0.14, drag = 0.02, spread = 70, dir = 270 },
}

-- ---------------------------------------------------------------------------
-- pure: the system
-- ---------------------------------------------------------------------------

local System = {}
System.__index = System

-- capacity: hard ceiling on live particles. opts:
--   seed   integer, any value; identical seeds replay identically  (default 1)
--   rand   function() -> [0,1); injected generator, overrides seed (default nil)
--   color  "black" (default) or "white". Note that setDitherPattern lays down
--          *black* ink, so a white system should stick to SOLID/SHRINK styles;
--          FADE on white would flip to black halfway through.
function Particles.new(capacity, opts)
    capacity = capacity or 128
    opts = opts or {}

    local s = setmetatable({}, System)
    s.capacity = capacity
    s.count = 0
    s.dropped = 0
    s.white = opts.color == "white"
    s._rand = opts.rand
    s:setSeed(opts.seed or 1)

    -- The one and only allocation. Every field a particle will ever hold is
    -- created here, because adding a field later (p.foo = 1 on a live particle)
    -- rehashes the table and is exactly the per-frame allocation this pool
    -- exists to avoid.
    local pool = {}
    for i = 1, capacity do
        pool[i] = {
            x = 0, y = 0, vx = 0, vy = 0,
            ix = 0, iy = 0,
            age = 0, life = 1,
            size = 1, dsize = 1,
            grav = 0, drag = 0,
            style = SOLID, level = LEVELS,
        }
    end
    s.pool = pool
    return s
end

function System:setSeed(n)
    local v = (n or 1) & MASK
    if v == 0 then v = 1 end
    self._rs = v
    return self
end

function System:random()
    if self._rand then return self._rand() end
    local v = (self._rs * LCG_A + LCG_C) & MASK
    self._rs = v
    -- The low bits of an LCG are famously non-random (bit 0 alternates), so
    -- the value is taken from the top: bits 7..30.
    return ((v >> 7) & 0xffffff) * RSCALE
end

local function pick(s, range, fallback)
    if not range then return fallback end
    local lo, hi = range[1], range[2]
    if hi == lo then return lo end
    return lo + (hi - lo) * s:random()
end

-- Fire particles. `spec` is a preset name or a preset-shaped table; `n` and
-- `dir` (degrees) override the spec. Returns how many were actually emitted —
-- compare it against `n` to notice a pool that is too small.
function System:emit(x, y, spec, n, dir)
    if type(spec) == "string" then spec = Particles.PRESETS[spec] end
    spec = spec or Particles.PRESETS.burst
    n = n or spec.n or 8

    local capacity = self.capacity
    local pool = self.pool
    local spread = spec.spread or 360
    local baseDir = dir or spec.dir or 0
    local style = spec.style or SOLID
    local grav = spec.grav or 0
    local drag = spec.drag or 0

    local made = 0
    for _ = 1, n do
        if self.count >= capacity then
            -- Documented policy: drop, do not grow, do not scan for a victim.
            self.dropped = self.dropped + (n - made)
            break
        end
        self.count = self.count + 1
        local p = pool[self.count]

        local a = rad(baseDir - spread * 0.5 + spread * self:random())
        local sp = pick(self, spec.speed, 1)
        local size = floor(pick(self, spec.size, 2) + 0.5)
        if size < 1 then size = 1 end

        p.x, p.y = x, y
        p.ix, p.iy = floor(x), floor(y)
        p.vx = cos(a) * sp
        p.vy = sin(a) * sp
        p.age = 0
        p.life = pick(self, spec.life, 12)
        p.size, p.dsize = size, size
        p.grav, p.drag = grav, drag
        p.style = style
        p.level = LEVELS
        made = made + 1
    end
    return made
end

-- Advance one frame (`dt` in frames; pass 30/refreshRate if you run at 50).
-- Returns the live count.
function System:update(dt)
    dt = dt or 1.0
    local pool = self.pool
    local n = self.count
    local i = 1

    while i <= n do
        local p = pool[i]
        p.age = p.age + dt

        if p.age >= p.life then
            -- Swap-remove by exchanging *references*, so the dead particle
            -- stays in the pool array (just past the live window) and is the
            -- next slot emit() hands out. No garbage, no shifting.
            pool[i] = pool[n]
            pool[n] = p
            n = n - 1
        else
            p.vy = p.vy + p.grav * dt

            -- Linear damping rather than drag^dt: a pow() per particle per
            -- frame is real money at 300 particles, and over a 10-30 frame
            -- lifetime the two are visually identical.
            local d = 1.0 - p.drag * dt
            if d < 0 then d = 0 end
            p.vx = p.vx * d
            p.vy = p.vy * d

            p.x = p.x + p.vx * dt
            p.y = p.y + p.vy * dt
            p.ix = floor(p.x)
            p.iy = floor(p.y)

            local rem = 1.0 - p.age / p.life
            if p.style == FADE then
                local lv = floor(rem * LEVELS) + 1
                if lv > LEVELS then lv = LEVELS end
                p.level = lv
            elseif p.style == SHRINK then
                local sz = floor(p.size * rem + 0.5)
                p.dsize = sz < 1 and 1 or sz
            end

            i = i + 1
        end
    end

    self.count = n
    return n
end

-- Kill everything. The pool is untouched — the slots are simply outside the
-- live window again.
function System:clear()
    self.count = 0
    return self
end

function System:free()
    return self.capacity - self.count
end

function System:isEmpty()
    return self.count == 0
end

-- Iterate live particles, pure. Handy for tests and for consumers who want to
-- draw particles themselves (as sprites, into an image, whatever).
function System:each(fn)
    local pool = self.pool
    for i = 1, self.count do
        fn(pool[i], i)
    end
end

-- ---------------------------------------------------------------------------
-- device shell
-- ---------------------------------------------------------------------------

Particles._ready = false

function Particles.load()
    Particles._ready = gfx ~= nil
    return Particles._ready
end

-- One pass per ink level, walking the packed array LEVELS times, instead of
-- one setDitherPattern per particle. The pattern is graphics *state*: setting
-- it is the expensive half, and re-setting it 300 times a frame costs far more
-- than four extra sweeps of an array of integers.
--
-- fillRect, not fillCircleAtPoint: a circle at these radii is 1-4 pixels that
-- nobody can tell from a square on a 1-bit panel, and the circle rasteriser is
-- several times the cost. Everything is pre-floored in update(), so this loop
-- does no arithmetic at all.
function System:draw()
    if not Particles._ready then return end
    local n = self.count
    if n == 0 then return end

    local pool = self.pool
    local solid = self.white and gfx.kColorWhite or gfx.kColorBlack

    for lv = LEVELS, 1, -1 do
        local armed = false
        for i = 1, n do
            local p = pool[i]
            if p.level == lv then
                if not armed then
                    if lv == LEVELS then
                        gfx.setColor(solid)
                    else
                        gfx.setDitherPattern(INK[lv], gfx.image.kDitherTypeBayer8x8)
                    end
                    armed = true
                end
                gfx.fillRect(p.ix, p.iy, p.dsize, p.dsize)
            end
        end
    end

    -- Leave the graphics state where the rest of this repo expects it.
    gfx.setColor(gfx.kColorBlack)
end

return Particles
