-- shake.lua — trauma-based screen shake.
--
-- Why trauma rather than "pick a random offset for N frames": a raw decaying
-- random shake reads as noise. The trauma model (Squirrel Eiserloh, GDC 2016)
-- keeps a single 0..1 energy value that events *add* to and that decays
-- linearly, and drives the offset by trauma^2 or ^3. The exponent is the whole
-- trick — it makes a shake bloom hard on impact and then taper off long before
-- the trauma counter reaches zero, which is what "impact" feels like.
--
-- The core is pure math: no SDK call anywhere above the "device shell" section,
-- so a consumer can pin an exact shake in a host test. `Shake.apply` /
-- `Shake.pop` are the only functions that touch playdate.graphics and they
-- no-op under host lua.
--
-- Offsets are integers. This is a 1-bit 400x240 panel; a sub-pixel draw offset
-- cannot show up on screen, it only costs a redraw.

Shake = Shake or {}

local pd  = rawget(_G, "playdate")
local gfx = pd and pd.graphics

local floor <const> = math.floor
local min <const>   = math.min
local max <const>   = math.max

-- ---------------------------------------------------------------------------
-- pure: 32-bit-safe hash + value noise
-- ---------------------------------------------------------------------------

-- Playdate Lua carries 32-bit integers. Two consequences, both load-bearing:
--   * a numeric *literal* above 2^31-1 does not fit lua_Integer and is silently
--     lexed as a float, and a bitwise op on a float dies on-device with
--     "number has no integer representation". So no constant here exceeds MASK.
--   * arithmetic wraps at a different width than on the 64-bit host. Masking to
--     31 bits after *every* step hides that: `&`, `~` and both shifts only ever
--     depend on the low bits that survive the mask, so host and device agree
--     bit for bit. That is what makes a shake reproducible in a test.
local MASK <const> = 0x7fffffff
Shake.MASK = MASK

-- xorshift-flavoured integer hash. Shifts and xors only, deliberately: a
-- multiply would still be correct under the mask but is the easiest place for
-- someone to later paste in a 64-bit-sized constant and break the device.
local function hash32(n)
    local x = ((n << 1) | 1) & MASK   -- odd-ify so hash32(0) is not a fixed point
    x = (x ~ (x << 13)) & MASK
    x = (x ~ (x >> 17)) & MASK
    x = (x ~ (x << 5)) & MASK
    x = (x ~ (x >> 11)) & MASK
    return x
end
Shake.hash32 = hash32

-- hash32 folded into [-1, 1].
local SCALE <const> = 1.0 / 1073741823.0   -- (MASK >> 1), written as a float on purpose
local function hash_signed(n)
    return (hash32(n) & 0x3fffffff) * SCALE * 2.0 - 1.0
end

-- Value noise: hash the two integer neighbours of t and smoothstep between
-- them. Smooth matters — sampling the hash directly gives a per-frame white
-- noise that looks like a broken cable rather than a camera being knocked.
-- Result is in [-1, 1] because it is a convex blend of two values in [-1, 1];
-- the magnitude bound of the whole module rests on that.
local function noise(channel, t)
    local i = floor(t)
    local f = t - i
    local base = ((channel & 0xffff) << 15) & MASK
    local a = hash_signed((base + (i & 0x7fff)) & MASK)
    local b = hash_signed((base + ((i + 1) & 0x7fff)) & MASK)
    local u = f * f * (3.0 - 2.0 * f)
    return a + (b - a) * u
end
Shake.noise = noise

-- Round away from zero, so |round(v)| <= |v| rounded up symmetrically and the
-- documented magnitude bound holds on the negative side too (plain
-- floor(v + 0.5) turns -4.0 into -4 but -4.5 into -5).
local function iround(v)
    if v >= 0 then return floor(v + 0.5) end
    return -floor(-v + 0.5)
end

-- ---------------------------------------------------------------------------
-- pure: shakers
-- ---------------------------------------------------------------------------

-- Presets are read-only templates; `new` copies out of them, so two shakers
-- built from one preset never share state. That is the whole point of having
-- instances: a UI element can rattle while the screen stays still.
Shake.PRESETS = {
    -- name        amp  roll  decay  freq  power
    bump   = { amplitude = 3,  rotation = 0.0, decay = 0.10, frequency = 0.55, power = 2 },
    hit    = { amplitude = 6,  rotation = 1.5, decay = 0.06, frequency = 0.45, power = 2 },
    quake  = { amplitude = 10, rotation = 3.0, decay = 0.02, frequency = 0.22, power = 3 },
    rattle = { amplitude = 2,  rotation = 0.0, decay = 0.04, frequency = 0.90, power = 2 },
}

local Shaker = {}
Shaker.__index = Shaker

-- opts: preset name, or a table of
--   amplitude  max |offset| in pixels at trauma 1        (default 6)
--              keep it a whole number: the offset is rounded, so the promised
--              bound |dx| <= amplitude only holds exactly for integers
--   rotation   max |roll| in degrees at trauma 1         (default 0)
--   decay      trauma removed per frame                  (default 0.06)
--   frequency  noise steps per frame; higher = twitchier (default 0.45)
--   power      2 = punchy, 3 = very tapered              (default 2)
--   seed       any integer; two seeds never rattle alike (default 1)
function Shake.new(opts)
    if type(opts) == "string" then opts = Shake.PRESETS[opts] end
    opts = opts or Shake.PRESETS.hit

    local s = setmetatable({}, Shaker)
    s.amplitude = opts.amplitude or 6
    s.rotation  = opts.rotation or 0
    s.decay     = opts.decay or 0.06
    s.frequency = opts.frequency or 0.45
    s.power     = opts.power or 2
    -- Three noise channels are drawn from seed, seed+1, seed+2, so the seed is
    -- clipped well short of the channel width to keep those from wrapping into
    -- another shaker's channel.
    s.seed      = (opts.seed or 1) & 0x3fff
    s.trauma    = 0
    s.time      = 0
    s.dx        = 0
    s.dy        = 0
    s.roll      = 0.0
    return s
end

-- Add trauma. Clamped at 1 so a burst of ten simultaneous hits shakes exactly
-- as hard as one big one instead of launching the camera off-screen.
function Shaker:add(amount)
    self.trauma = min(1.0, max(0.0, self.trauma + (amount or 0.5)))
    return self.trauma
end

function Shaker:setTrauma(v)
    self.trauma = min(1.0, max(0.0, v or 0))
    return self.trauma
end

-- Cut the shake dead and re-centre. Offsets go to exactly 0, not "nearly 0" —
-- a resting camera parked at (1, 0) is a bug the consumer will chase for hours.
function Shaker:stop()
    self.trauma = 0
    self.dx, self.dy, self.roll = 0, 0, 0.0
end

function Shaker:isActive()
    return self.trauma > 0
end

-- One frame. `dt` is in frames (1.0 default) for consumers running a fixed
-- 30 fps loop; pass 30/refreshRate if you run at 50.
function Shaker:update(dt)
    dt = dt or 1.0

    -- Linear decay, floored at 0. Trauma must never go negative: trauma^2 of a
    -- negative is positive and the shake would come back from the dead.
    local tr = self.trauma - self.decay * dt
    if tr < 0 then tr = 0 end
    self.trauma = tr

    if tr <= 0 then
        self.dx, self.dy, self.roll = 0, 0, 0.0
        return 0, 0
    end

    self.time = self.time + self.frequency * dt

    local mag = tr ^ self.power
    local t = self.time
    self.dx   = iround(self.amplitude * mag * noise(self.seed, t))
    self.dy   = iround(self.amplitude * mag * noise(self.seed + 1, t))
    self.roll = self.rotation * mag * noise(self.seed + 2, t)
    return self.dx, self.dy
end

function Shaker:offset()
    return self.dx, self.dy
end

-- Degrees, and a float — rotation is not a draw offset, the consumer has to
-- feed it to image:drawRotated() or a sprite. setDrawOffset cannot rotate.
function Shaker:rotationAngle()
    return self.roll
end

-- Lazily-created shared shaker, for the common "one screen, one shake" case.
-- A plain table, so this still allocates nothing on the SDK side (rule 2).
local _main
function Shake.main(opts)
    if not _main then _main = Shake.new(opts) end
    return _main
end

-- ---------------------------------------------------------------------------
-- device shell
-- ---------------------------------------------------------------------------

Shake._ready = false

function Shake.load()
    Shake._ready = gfx ~= nil
    return Shake._ready
end

-- Fixed-depth save stack, allocated once. apply/pop run every frame; growing a
-- table there would hand the GC work in the exact frame the game is already
-- spending on an explosion.
local _sx, _sy, _sp = {0, 0, 0, 0, 0, 0, 0, 0}, {0, 0, 0, 0, 0, 0, 0, 0}, 0

-- setDrawOffset is absolute, not relative, so the previous offset is saved and
-- the shake is added on top of it. Nesting (a shaking UI panel inside a shaking
-- world) therefore composes.
function Shake.apply(shaker)
    if not Shake._ready then return 0, 0 end
    local dx, dy = shaker.dx, shaker.dy
    local ox, oy = gfx.getDrawOffset()
    if _sp < 8 then
        _sp = _sp + 1
        _sx[_sp], _sy[_sp] = ox, oy
    end
    gfx.setDrawOffset(ox + dx, oy + dy)
    return dx, dy
end

function Shake.pop()
    if not Shake._ready or _sp == 0 then return end
    gfx.setDrawOffset(_sx[_sp], _sy[_sp])
    _sp = _sp - 1
end

return Shake
