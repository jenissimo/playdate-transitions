--[[
backgrounds.lua -- procedural looping backgrounds for Playdate (playdate-juice).

Full-screen 1-bit backdrops, each one a *pure simulation* plus a thin renderer.
Three constraints shaped this file:

  * A consumer showing one background must not pay for the other sixteen. Every
    background's state (80 stars, a 50x30 Life grid, 60 rain drops) is built on
    first use, never at load time -- CONVENTIONS rule 2.

  * These loop forever. A phase written as `tick * 0.04` grows without bound,
    and Playdate Lua numbers are 32-bit floats: after a few million frames the
    per-frame increment drops below one ulp and the animation stutters, then
    freezes outright. So every cyclic quantity is an accumulator wrapped to its
    own *exact* period -- a multiple of 2*pi for a sine, the ring spacing for
    the radar sweep, the fall height for a rain drop. Wrapping on an exact
    period is mathematically invisible and keeps precision constant for an
    infinite session. The multiples matter: a background that feeds `ph` to
    both sin(ph) and sin(ph*1.7) must wrap at 10*TAU, because only then is the
    jump in *both* terms a whole number of cycles.

  * Randomness comes from a seeded generator, not math.random, so a background
    rebuilds bit-identically and the host tests can assert on it.

API (unchanged from the demo-era module):
    Backgrounds.update([index])   advance one frame of simulation
    Backgrounds.draw(index)       render it (silent no-op with no SDK)
    Backgrounds.names / .count / .getName(i) / .indexOf(name)
    Backgrounds.load{seed=, preload=}   optional; draw() calls it for you
    Backgrounds.reset(index[, seed])    rebuild one background's state
]]

Backgrounds = Backgrounds or {}

local pd = rawget(_G, "playdate")
local gfx = pd and pd.graphics

local W <const> = 400
local H <const> = 240
local TAU <const> = math.pi * 2
local sin <const> = math.sin
local cos <const> = math.cos
local floor <const> = math.floor
local ceil <const> = math.ceil
local pi <const> = math.pi
local unpack <const> = table.unpack

-- ===========================================================================
-- pure: seeded RNG
-- ===========================================================================

-- Park-Miller minimal standard driven through Schrage's trick. The trick is not
-- decoration: it keeps every intermediate under 2^31 so the sequence is
-- identical on the console's 32-bit integers and on the 64-bit host, and no
-- literal here ever becomes a float (CONVENTIONS rule 5).
local function nextSeed(s)
    local hi = s // 127773
    local lo = s % 127773
    s = 16807 * lo - 2836 * hi
    if s <= 0 then s = s + 2147483647 end
    return s
end

local function newRng(seed)
    local s = floor(seed) % 2147483647
    if s <= 0 then s = s + 2147483646 end
    local r = {}
    function r.float()
        s = nextSeed(s)
        return (s - 1) / 2147483646
    end
    function r.range(a, b)          -- inclusive integers
        return a + floor(r.float() * (b - a + 1))
    end
    return r
end

-- ===========================================================================
-- pure: dither safety
-- ===========================================================================

-- An 8x8 Bayer tile holds 64 pixels, so a level below 1/64 rounds down to a
-- tile with nothing set. An all-zero tile handed to setPattern renders SOLID
-- BLACK rather than transparent (CONVENTIONS rule 6), and through
-- setDitherPattern the shape simply vanishes -- both are silent failures with
-- no error to trace. Every dither call in this file goes through safeDither so
-- neither can happen, whatever a future edit computes.
local DITHER_FLOOR <const> = 1 / 64

local function safeDither(level)
    if not level or level < DITHER_FLOOR then return DITHER_FLOOR end
    if level > 1 then return 1 end
    return level
end

Backgrounds.DITHER_FLOOR = DITHER_FLOOR
Backgrounds.safeDither = safeDither

-- Lit pixels in the equivalent 8x8 tile. Exported because "never all-zero" is
-- an invariant worth asserting rather than trusting.
function Backgrounds.ditherPixels(level)
    return floor(safeDither(level) * 64 + 0.5)
end

-- Every level any background can request. Kept next to the code that uses them
-- so the test can walk the whole set.
Backgrounds.DITHER_LEVELS = {
    0.2, 0.25, 0.35, 0.4, 0.45, 0.5, 0.6, 0.7, 0.75, 0.8, 1.0,
}

-- ===========================================================================
-- pure: accumulator plumbing
-- ===========================================================================

-- Register a cyclic quantity: starting value, per-frame rate, exact period.
-- Everything that would otherwise be "tick * k" lives here, which is what makes
-- the loop-forever property a single generic test instead of seventeen.
local function addAcc(st, v0, rate, period)
    local i = st.np + 1
    st.np = i
    st.p[i] = v0 % period
    st.rate[i] = rate
    st.per[i] = period
    return i
end

local function advance(st)
    local p, rate, per = st.p, st.rate, st.per
    for i = 1, st.np do
        local v = p[i] + rate[i]
        -- One subtract suffices because every rate is smaller than its period.
        -- Staying inside [0, period) is the whole point: the accumulator never
        -- grows, so its float resolution never degrades.
        if v >= per[i] then v = v - per[i] end
        p[i] = v
    end
end

-- ===========================================================================
-- device helpers (only reached when the SDK is present)
-- ===========================================================================

local function dither(level, big)
    gfx.setDitherPattern(safeDither(level),
        big and gfx.image.kDitherTypeBayer8x8 or gfx.image.kDitherTypeBayer4x4)
end

-- ===========================================================================
-- backgrounds
--
-- Each spec is { name, margin, init(st, rng), step(st), render(st) }.
--   init   builds state; called once, lazily, on first use.
--   step   pure simulation; runs with or without the SDK.
--   render draws; never mutates state.
--   margin how far outside 400x240 an item is allowed to sit (spawn gutters and
--          deliberately oversized meshes), asserted by the bounds test.
-- ===========================================================================

local specs = {}

-- 1 -----------------------------------------------------------------------
specs[1] = {
    name = "Starfield", margin = 4,
    init = function(st, rng)
        for i = 1, 80 do
            st.items[i] = {
                x = rng.range(0, W), y = rng.range(0, H),
                spd = 0.8 + rng.float() * 3,
                sz = rng.range(1, 4) == 1 and 2 or 1,
            }
        end
    end,
    step = function(st)
        local rng = st.rng
        local items = st.items
        for i = 1, #items do
            local s = items[i]
            s.x = s.x - s.spd
            -- Recycling at the edge *is* the loop: x is bounded by construction,
            -- so no accumulator is needed here.
            if s.x < -2 then s.x = W + 2; s.y = rng.range(0, H) end
        end
    end,
    render = function(st)
        gfx.clear(gfx.kColorBlack)
        gfx.setColor(gfx.kColorWhite)
        local items = st.items
        for i = 1, #items do
            local s = items[i]
            gfx.fillRect(floor(s.x), floor(s.y), s.sz, s.sz)
        end
    end,
}

-- 2 -----------------------------------------------------------------------
specs[2] = {
    name = "Waves", margin = 0,
    init = function(st) addAcc(st, 0, 0.04, TAU) end,
    render = function(st)
        gfx.clear(gfx.kColorWhite)
        gfx.setColor(gfx.kColorBlack)
        local t = st.p[1]
        for w = 0, 5 do
            local amp = 18 + w * 8
            local freq = 0.014 + w * 0.004
            local ph = t + w * 1.5
            local yb = 30 + w * 34
            local py = yb + sin(ph) * amp
            for x = 1, W do
                local y = yb + sin(x * freq + ph) * amp
                gfx.drawLine(x - 1, py, x, y)
                py = y
            end
        end
    end,
}

-- 3 -----------------------------------------------------------------------
local RADAR_R <const> = 160

specs[3] = {
    name = "Radar", margin = 0,
    init = function(st)
        addAcc(st, 0, 1.0, RADAR_R + 30)  -- ring travel; period is the ring spacing
        addAcc(st, 0, 2.5, 360)           -- sweep angle, degrees
    end,
    render = function(st)
        gfx.clear(gfx.kColorBlack)
        gfx.setColor(gfx.kColorWhite)
        local cx, cy = W / 2, H / 2
        local ring = st.p[1]
        for i = 0, 6 do
            local r = (i * 30 + ring) % (RADAR_R + 30)
            if r > 0 and r < RADAR_R then gfx.drawCircleAtPoint(cx, cy, floor(r)) end
        end
        local a = math.rad(st.p[2])
        gfx.setLineWidth(2)
        gfx.drawLine(cx, cy, cx + cos(a) * RADAR_R, cy + sin(a) * RADAR_R)
        gfx.setLineWidth(1)
        gfx.fillCircleAtPoint(cx, cy, 3)
    end,
}

-- 4 -----------------------------------------------------------------------
specs[4] = {
    name = "Rain", margin = 32,
    init = function(st, rng)
        st.wind = addAcc(st, 0, 0.015, TAU)
        for i = 1, 60 do
            local spd = 1.5 + rng.float() * 3
            local it = {
                x = rng.range(0, W + 60) % W,
                spd = spd,
                len = 12 + rng.float() * 16,
                y = 0,
            }
            -- Fall phase wraps at H+40: the drop reappears above the screen
            -- instead of its y climbing forever.
            it.pi = addAcc(st, rng.range(0, H + 40), spd * 1.6, H + 40)
            st.items[i] = it
        end
    end,
    step = function(st)
        local p = st.p
        local items = st.items
        for i = 1, #items do
            local it = items[i]
            it.y = p[it.pi] - 15
        end
    end,
    render = function(st)
        gfx.clear(gfx.kColorWhite)
        gfx.setColor(gfx.kColorBlack)
        gfx.drawLine(0, H - 2, W, H - 2)
        local wind = sin(st.p[st.wind]) * 1.5
        local items = st.items
        for i = 1, #items do
            local d = items[i]
            local x, y = d.x, d.y
            if d.spd > 3.5 then
                gfx.setLineWidth(2)
                gfx.drawLine(x + wind, y, x + wind * 0.5, y + d.len * 0.7)
                gfx.setLineWidth(1)
            elseif d.spd > 2.5 then
                gfx.drawLine(x + wind, y, x + wind * 0.5, y + d.len * 0.9)
            else
                gfx.drawLine(x + wind, y, x + wind * 0.3, y + d.len * 0.5)
            end
            if y + d.len > H - 6 and y < H - 2 then
                gfx.fillRect(floor(x) - 1, H - 4, 1, 1)
                gfx.fillRect(floor(x) + 1, H - 5, 1, 1)
                gfx.fillRect(floor(x), H - 3, 1, 1)
            end
        end
    end,
}

-- 5 -----------------------------------------------------------------------
specs[5] = {
    name = "Squares", margin = 0,
    init = function(st)
        addAcc(st, 0, 0.04, TAU)  -- rotation
        addAcc(st, 0, 0.06, TAU)  -- breathing size
        -- One scratch polygon reused by all 54 cells; the original allocated a
        -- fresh table per cell per frame, which is 1600 tables a second of GC.
        st.pts = {0, 0, 0, 0, 0, 0, 0, 0}
    end,
    render = function(st)
        gfx.clear(gfx.kColorWhite)
        gfx.setColor(gfx.kColorBlack)
        local gs = 50
        local rot, breathe = st.p[1], st.p[2]
        local pts = st.pts
        for r = 0, ceil(H / gs) do
            for c = 0, ceil(W / gs) do
                local cx, cy = c * gs + gs / 2, r * gs + gs / 2
                local ang = rot + (c + r) * 0.6
                local sz = 13 + sin(breathe + c * 0.4 + r * 0.8) * 6
                local ca, sa = cos(ang), sin(ang)
                for k = 0, 3 do
                    local a = k * pi / 2
                    local px, py = sz * cos(a), sz * sin(a)
                    pts[k * 2 + 1] = cx + px * ca - py * sa
                    pts[k * 2 + 2] = cy + px * sa + py * ca
                end
                gfx.drawPolygon(unpack(pts))
            end
        end
    end,
}

-- 6 -----------------------------------------------------------------------
specs[6] = {
    name = "Spirograph", margin = 0,
    init = function(st)
        addAcc(st, 0, 0.008, TAU)  -- outer radius wobble
        addAcc(st, 0, 0.012, TAU)  -- pen offset wobble
    end,
    render = function(st)
        gfx.clear(gfx.kColorWhite)
        gfx.setColor(gfx.kColorBlack)
        local ccx, ccy = W / 2, H / 2
        local R = 75 + sin(st.p[1]) * 10
        local r = 32
        local dd = 52 + sin(st.p[2]) * 8
        local px, py
        for i = 0, 500 do
            local a = i / 500 * pi * 12
            local x = floor(ccx + (R - r) * cos(a) + dd * cos((R - r) / r * a))
            local y = floor(ccy + (R - r) * sin(a) - dd * sin((R - r) / r * a))
            if px then gfx.drawLine(px, py, x, y) end
            px, py = x, y
        end
    end,
}

-- 7 -----------------------------------------------------------------------
-- Shared read-only shape constants. The original rebuilt this list inside
-- draw(), i.e. five tables every frame for no reason.
local LAVA <const> = {
    {ox = 0.6,  oy = 0.4,  rx = 100, ry = 55, spd = 0.012, base = 65},
    {ox = 0.3,  oy = 0.6,  rx = 90,  ry = 50, spd = 0.015, base = 58},
    {ox = 0.7,  oy = 0.55, rx = 110, ry = 45, spd = 0.010, base = 60},
    {ox = 0.45, oy = 0.35, rx = 80,  ry = 60, spd = 0.018, base = 52},
    {ox = 0.55, oy = 0.7,  rx = 95,  ry = 40, spd = 0.013, base = 55},
}

specs[7] = {
    name = "Lava Lamp", margin = 0,
    init = function(st)
        for i = 1, #LAVA do
            local b = LAVA[i]
            local it = {b = b, x = 0, y = 0, r = b.base}
            -- ph feeds sin(ph), cos(ph*0.7) and sin(ph*1.3): 10*TAU is the
            -- smallest wrap that is a whole number of cycles for all three
            -- (7 and 13 turns respectively), so the wrap cannot be seen.
            it.pi = addAcc(st, i * 1.7, b.spd, TAU * 10)
            st.items[i] = it
        end
    end,
    step = function(st)
        local p = st.p
        for i = 1, #st.items do
            local it = st.items[i]
            local b, ph = it.b, p[it.pi]
            it.x = floor(W * b.ox + sin(ph) * b.rx)
            it.y = floor(H * b.oy + cos(ph * 0.7) * b.ry)
            it.r = b.base + floor(sin(ph * 1.3) * 10)
        end
    end,
    render = function(st)
        gfx.clear(gfx.kColorWhite)
        for i = 1, #st.items do
            local it = st.items[i]
            local x, y, r = it.x, it.y, it.r
            dither(0.35, true)
            gfx.fillCircleAtPoint(x, y, r)
            dither(0.7, false)
            gfx.fillCircleAtPoint(x, y, floor(r * 0.6))
            gfx.setColor(gfx.kColorBlack)
            gfx.fillCircleAtPoint(x, y, floor(r * 0.25))
        end
        gfx.setColor(gfx.kColorBlack)
    end,
}

-- 8 -----------------------------------------------------------------------
local HILLS <const> = {
    {yBase = 60,  amp = 35, freq = 0.012, spd = 0.02, dither = 0.2},
    {yBase = 100, amp = 30, freq = 0.018, spd = 0.03, dither = 0.45},
    {yBase = 140, amp = 25, freq = 0.022, spd = 0.04, dither = 0.7},
    {yBase = 175, amp = 20, freq = 0.028, spd = 0.05, dither = 1.0},
}

specs[8] = {
    name = "Dither Hills", margin = 0,
    init = function(st)
        for i = 1, #HILLS do
            -- ph is used as both ph and ph*1.7, so 10*TAU (10 and 17 turns).
            addAcc(st, 0, HILLS[i].spd, TAU * 10)
        end
    end,
    render = function(st)
        gfx.clear(gfx.kColorWhite)
        for i = 1, #HILLS do
            local l = HILLS[i]
            local ph = st.p[i]
            -- A fully opaque layer draws as solid black; asking the dither for
            -- 1.0 would give the same picture more slowly.
            if l.dither >= 0.95 then
                gfx.setColor(gfx.kColorBlack)
            else
                dither(l.dither, true)
            end
            for x = 0, W - 1, 3 do
                local y = l.yBase + sin(x * l.freq + ph) * l.amp
                        + sin(x * l.freq * 2.5 + ph * 1.7) * l.amp * 0.25
                gfx.fillRect(x, floor(y), 3, H - floor(y))
            end
        end
        gfx.setColor(gfx.kColorBlack)
    end,
}

-- 9 -----------------------------------------------------------------------
specs[9] = {
    name = "Bubbles Rise", margin = 48,
    init = function(st)
        st.wob = addAcc(st, 0, 0.03, TAU)
        for i = 0, 24 do
            local spd = 0.6 + (i % 5) * 0.3
            local r = 8 + (i % 4) * 5
            local it = {k = i, r = r, baseX = (i * 67 + 19) % W, x = 0, y = 0}
            -- Rise phase wraps at H + 4r, one full trip from below the bottom
            -- edge to above the top one.
            it.pi = addAcc(st, i * 41, spd, H + r * 4)
            st.items[i + 1] = it
        end
    end,
    step = function(st)
        local p = st.p
        local wob = p[st.wob]
        for n = 1, #st.items do
            local it = st.items[n]
            it.y = H - (p[it.pi] - it.r * 2)
            it.x = it.baseX + sin(wob + it.k * 1.1) * 12
        end
    end,
    render = function(st)
        gfx.clear(gfx.kColorBlack)
        for n = 1, #st.items do
            local it = st.items[n]
            local x, y, r = it.x, it.y, it.r
            local norm = y / H
            if norm < 0.25 then
                gfx.setColor(gfx.kColorWhite)
            elseif norm < 0.5 then
                dither(0.8, true)
            elseif norm < 0.75 then
                dither(0.5, false)
            else
                dither(0.25, true)
            end
            gfx.fillCircleAtPoint(floor(x), floor(y), r)
        end
        gfx.setColor(gfx.kColorBlack)
    end,
}

-- 10 ----------------------------------------------------------------------
specs[10] = {
    name = "Plasma", margin = 0,
    init = function(st)
        addAcc(st, 0, 0.03, TAU * 5)  -- used as t1 and t1*0.8 -> 5 and 4 turns
        addAcc(st, 0, 0.025, TAU)
    end,
    render = function(st)
        gfx.clear(gfx.kColorWhite)
        local s = 10
        local t1, t2 = st.p[1], st.p[2]
        for x = 0, W - 1, s do
            local sx = sin(x * 0.02 + t1)
            for y = 0, H - 1, s do
                local v = sx + sin(y * 0.025 + t2) + sin((x + y) * 0.015 + t1 * 0.8)
                local n = (v + 3) / 6
                if n < 0.35 then
                    dither(0.8, true)
                    gfx.fillRect(x, y, s, s)
                elseif n < 0.5 then
                    dither(0.5, false)
                    gfx.fillRect(x, y, s, s)
                elseif n < 0.65 then
                    dither(0.25, true)
                    gfx.fillRect(x, y, s, s)
                end
            end
        end
    end,
}

-- 11 ----------------------------------------------------------------------
local MATRIX_CHARS <const> = "0123456789:.<>|=+*ABCDEF"
local MATRIX_N <const> = #MATRIX_CHARS

specs[11] = {
    name = "Matrix Rain", margin = 16,
    init = function(st, rng)
        -- The glyph cycle is an accumulator too: floor() of a value kept inside
        -- [0, MATRIX_N) is exactly floor(tick*rate) % MATRIX_N, and it cannot
        -- drift out of float range on a long session.
        st.fast = addAcc(st, 0, 0.3, MATRIX_N)
        st.slow = addAcc(st, 0, 0.05, MATRIX_N)
        for i = 1, 28 do
            local x = (i - 1) * 15 + rng.range(0, 6)
            local spd = 1.2 + rng.float() * 2.5
            local len = 5 + rng.range(1, 10)
            local it = {x = x, len = len, ci = i, head = 0}
            it.pi = addAcc(st, rng.range(0, 300), spd, H + len * 10)
            st.items[i] = it
        end
    end,
    step = function(st)
        local p = st.p
        for i = 1, #st.items do
            local it = st.items[i]
            it.head = p[it.pi]
        end
    end,
    render = function(st)
        gfx.clear(gfx.kColorBlack)
        gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
        local fast, slow = floor(st.p[st.fast]), floor(st.p[st.slow])
        for i = 1, #st.items do
            local c = st.items[i]
            local ci, head = c.ci, c.head
            for j = 0, c.len - 1 do
                local y = floor(head - j * 10)
                if y >= 0 and y < H then
                    local skip = j > c.len * 0.7 and (ci + j) % 3 == 0
                    if not skip then
                        local idx = ((ci * 7 + j * 13 + (j < 2 and fast or slow)) % MATRIX_N) + 1
                        gfx.drawText(MATRIX_CHARS:sub(idx, idx), c.x, y)
                    end
                end
            end
        end
        gfx.setImageDrawMode(gfx.kDrawModeCopy)
        gfx.setColor(gfx.kColorBlack)
    end,
}

-- 12 ----------------------------------------------------------------------
specs[12] = {
    name = "Fire", margin = 0,
    init = function(st)
        -- t, t*1.7, t*0.6 and t*2.3 all land on whole cycles at 10*TAU.
        addAcc(st, 0, 0.08, TAU * 10)
    end,
    render = function(st)
        gfx.clear(gfx.kColorBlack)
        local t = st.p[1]
        local step = 4
        for x = 0, W - 1, step do
            local h = 50 + sin(x * 0.05 + t) * 25 + sin(x * 0.12 + t * 1.7) * 15
                    + sin(x * 0.03 + t * 0.6) * 20 + sin(x * 0.23 + t * 2.3) * 8
            dither(0.75, true)
            gfx.fillRect(x, H - floor(h), step, floor(h))
            dither(0.4, false)
            gfx.fillRect(x, H - floor(h * 0.65), step, floor(h * 0.65))
            gfx.setColor(gfx.kColorWhite)
            gfx.fillRect(x, H - floor(h * 0.3), step, floor(h * 0.3))
        end
        gfx.setColor(gfx.kColorBlack)
    end,
}

-- 13 ----------------------------------------------------------------------
specs[13] = {
    name = "Moire", margin = 0,
    init = function(st)
        addAcc(st, 0, 0.02, TAU)
        addAcc(st, 0, 0.015, TAU)
        addAcc(st, 0, 0.025, TAU)
        addAcc(st, 0, 0.018, TAU)
    end,
    render = function(st)
        gfx.clear(gfx.kColorWhite)
        gfx.setColor(gfx.kColorBlack)
        local p = st.p
        local cx1 = W / 2 + sin(p[1]) * 60
        local cy1 = H / 2 + cos(p[2]) * 40
        local cx2 = W / 2 + sin(p[3] + 2) * 60
        local cy2 = H / 2 + cos(p[4] + 1) * 40
        for r = 10, 260, 10 do
            gfx.drawCircleAtPoint(floor(cx1), floor(cy1), r)
            gfx.drawCircleAtPoint(floor(cx2), floor(cy2), r)
        end
    end,
}

-- 14 ----------------------------------------------------------------------
local STRIKE_PERIOD <const> = 46

-- Midpoint displacement into a flat {x1,y1,x2,y2,...} list. Flat on purpose:
-- depth 5 is 33 vertices per bolt and up to 3 bolts every 46 frames, and the
-- console does not need 99 short-lived tables for that.
local function boltInto(out, x1, y1, x2, y2, d, rng)
    if d == 0 then
        out[#out + 1] = x2
        out[#out + 1] = y2
        return
    end
    local mx = (x1 + x2) / 2 + (rng.float() - 0.5) * (y2 - y1) * 0.4
    local my = (y1 + y2) / 2
    boltInto(out, x1, y1, mx, my, d - 1, rng)
    boltInto(out, mx, my, x2, y2, d - 1, rng)
end

local function strike(st, rng)
    local bolts = {}
    for i = 1, 2 + floor(rng.float() * 2) do
        local sx = 80 + rng.range(0, W - 160)
        local out = {sx, 0}
        boltInto(out, sx, 0, sx + (rng.float() - 0.5) * 100, H, 5, rng)
        bolts[i] = out
    end
    st.bolts = bolts
end

specs[14] = {
    name = "Lightning", margin = 96,
    init = function(st, rng)
        -- Age in frames. It wraps to exactly 0 (integer rate, integer period)
        -- and that instant is the next strike -- no free-running timer to
        -- compare against.
        addAcc(st, 0, 1, STRIKE_PERIOD)
        strike(st, rng)
    end,
    step = function(st)
        if st.p[1] == 0 then strike(st, st.rng) end
    end,
    render = function(st)
        gfx.clear(gfx.kColorBlack)
        local age = st.p[1]
        local bolts = st.bolts
        local first = bolts[1]
        if age < 6 and first then
            dither(0.6, true)
            for i = 4, #first, 2 do
                local px, py = first[i - 3], first[i - 2]
                local qx, qy = first[i - 1], first[i]
                gfx.drawLine(floor(px) - 3, floor(py), floor(qx) - 3, floor(qy))
                gfx.drawLine(floor(px) + 3, floor(py), floor(qx) + 3, floor(qy))
            end
        end
        gfx.setColor(gfx.kColorWhite)
        gfx.setLineWidth(age < 4 and 3 or (age < 12 and 2 or 1))
        for bi = 1, #bolts do
            local bolt = bolts[bi]
            if age < 20 + bi * 8 then
                for i = 4, #bolt, 2 do
                    gfx.drawLine(floor(bolt[i - 3]), floor(bolt[i - 2]),
                                 floor(bolt[i - 1]), floor(bolt[i]))
                end
            end
        end
        gfx.setLineWidth(1)
        gfx.setColor(gfx.kColorBlack)
    end,
}

-- 15 ----------------------------------------------------------------------
-- Margin 96, not the 24 the steady state needs: the particles are seeded with
-- an upward kick of up to 5 px/frame against 0.15 gravity, so the opening burst
-- arcs ~83px above the top edge before the first landing. After that every
-- recycle re-enters from just above y=0 and the field stays in [-20, H].
specs[15] = {
    name = "Confetti", margin = 96,
    init = function(st, rng)
        for i = 1, 40 do
            st.items[i] = {
                x = rng.range(0, W), y = rng.range(0, H),
                vx = rng.float() * 4 - 2, vy = -2 - rng.float() * 3,
                sz = 2 + rng.range(0, 3), sh = rng.range(1, 3),
            }
        end
    end,
    step = function(st)
        local rng = st.rng
        local items = st.items
        for i = 1, #items do
            local p = items[i]
            p.vy = p.vy + 0.15
            p.x = p.x + p.vx
            p.y = p.y + p.vy
            -- Bounce, then respawn once the bounce has died: velocity can never
            -- run away, which is what keeps this one looping rather than
            -- integrating gravity forever.
            if p.y > H - 4 then
                p.y = H - 4
                p.vy = -p.vy * 0.5
                if math.abs(p.vy) < 0.5 then
                    p.x = rng.range(0, W)
                    p.y = -rng.range(0, 20)
                    p.vy = 0
                    p.vx = rng.float() * 4 - 2
                end
            end
            if p.x < -10 or p.x > W + 10 then
                p.x = rng.range(0, W)
                p.y = -rng.range(0, 20)
                p.vy = 0
                p.vx = rng.float() * 4 - 2
            end
        end
    end,
    render = function(st)
        gfx.clear(gfx.kColorWhite)
        gfx.setColor(gfx.kColorBlack)
        local items = st.items
        for i = 1, #items do
            local p = items[i]
            local x, y = floor(p.x), floor(p.y)
            if p.sh == 1 then
                gfx.fillRect(x, y, p.sz, p.sz)
            elseif p.sh == 2 then
                gfx.fillCircleAtPoint(x, y, floor(p.sz / 2) + 1)
            else
                gfx.fillRect(x, y, p.sz + 2, 2)
            end
        end
    end,
}

-- 16 ----------------------------------------------------------------------
local LIFE_W <const> = 50
local LIFE_H <const> = 30
local LIFE_SZ <const> = 8
local LIFE_N <const> = LIFE_W * LIFE_H

specs[16] = {
    name = "Life", margin = 0,
    init = function(st, rng)
        addAcc(st, 0, 1, 6)  -- generation every 6th frame; wrap to 0 is the tick
        local a, b = {}, {}
        for i = 1, LIFE_N do
            a[i] = rng.float() < 0.35 and 1 or 0
            b[i] = 0
        end
        st.grid, st.grid2 = a, b
    end,
    step = function(st)
        if st.p[1] ~= 0 then return end
        local cur, nxt = st.grid, st.grid2
        for y = 0, LIFE_H - 1 do
            for x = 0, LIFE_W - 1 do
                local n = 0
                for dy = -1, 1 do
                    for dx = -1, 1 do
                        if dx ~= 0 or dy ~= 0 then
                            n = n + cur[((y + dy) % LIFE_H) * LIFE_W + (x + dx) % LIFE_W + 1]
                        end
                    end
                end
                local idx = y * LIFE_W + x + 1
                nxt[idx] = (cur[idx] == 1 and (n == 2 or n == 3) or n == 3) and 1 or 0
            end
        end
        st.grid, st.grid2 = nxt, cur
        -- A few random births keep the field from settling into still lifes and
        -- looking frozen -- this background has to survive being left on.
        for _ = 1, 3 do st.grid[st.rng.range(1, LIFE_N)] = 1 end
    end,
    render = function(st)
        gfx.clear(gfx.kColorWhite)
        gfx.setColor(gfx.kColorBlack)
        local grid = st.grid
        for y = 0, LIFE_H - 1 do
            local row = y * LIFE_W
            for x = 0, LIFE_W - 1 do
                if grid[row + x + 1] == 1 then
                    gfx.fillRect(x * LIFE_SZ, y * LIFE_SZ, LIFE_SZ - 1, LIFE_SZ - 1)
                end
            end
        end
    end,
}

-- 17 ----------------------------------------------------------------------
specs[17] = {
    name = "Terrain", margin = 0,
    init = function(st)
        addAcc(st, 0, 0.06, TAU * 10)  -- used as scroll and scroll*1.3
    end,
    render = function(st)
        gfx.clear(gfx.kColorBlack)
        gfx.setColor(gfx.kColorWhite)
        local scroll = st.p[1]
        for r = 0, 15 do
            local depth = r / 15
            local scale = 0.65 + depth * 0.35
            local baseY = 40 + r * 13
            local prevX, prevY
            for c = 0, 30 do
                local xn = (c / 30 - 0.5) * W * 1.5 * scale + W / 2
                local h = (sin(c * 0.16 + r * 0.5 + scroll) * 20
                         + sin(c * 0.32 + scroll * 1.3) * 10) * (0.3 + depth * 0.7)
                local yn = baseY - h
                if prevX then gfx.drawLine(floor(prevX), floor(prevY), floor(xn), floor(yn)) end
                prevX, prevY = xn, yn
            end
        end
    end,
}

-- ===========================================================================
-- public surface
-- ===========================================================================

Backgrounds.count = #specs
Backgrounds.names = {}
for i = 1, #specs do Backgrounds.names[i] = specs[i].name end

Backgrounds.SCREEN_W = W
Backgrounds.SCREEN_H = H

-- Kept on the module so a double import (or a require after an import) reuses
-- the live simulations instead of silently restarting them.
Backgrounds._states = Backgrounds._states or {}
Backgrounds._seed = Backgrounds._seed or 20240526

local function newState(sp, seed)
    local st = {
        p = {}, rate = {}, per = {}, np = 0,
        items = {},
        rng = newRng(seed),
    }
    if sp.init then sp.init(st, st.rng) end
    return st
end

function Backgrounds.getName(index)
    local sp = specs[index]
    return sp and sp.name
end

function Backgrounds.indexOf(name)
    for i = 1, #specs do
        if specs[i].name == name then return i end
    end
    return nil
end

function Backgrounds.margin(index)
    local sp = specs[index]
    return sp and (sp.margin or 0)
end

-- Optional. draw() calls this itself, so a consumer following the README never
-- has to. Options: seed (base seed for every background), preload (list of
-- indices to build now rather than on first draw, if a first-frame hitch during
-- a transition would be visible).
function Backgrounds.load(opts)
    opts = opts or {}
    if opts.seed then
        Backgrounds._seed = floor(opts.seed)
        Backgrounds._states = {}
    end
    Backgrounds._loaded = true
    -- Under host lua there is no SDK: simulation still runs, drawing no-ops.
    Backgrounds._ready = gfx ~= nil
    if opts.preload then
        for _, i in ipairs(opts.preload) do Backgrounds.state(i) end
    end
    return Backgrounds._ready
end

-- Build (or fetch) one background's state. Nothing exists until it is asked
-- for, so showing Starfield never allocates the 1500-cell Life grid.
function Backgrounds.state(index)
    local sp = specs[index]
    if not sp then return nil end
    local st = Backgrounds._states[index]
    if not st then
        -- 7919 keeps the per-background seeds far apart, so two backgrounds
        -- built from the same base seed do not start on correlated sequences.
        st = newState(sp, Backgrounds._seed + index * 7919)
        Backgrounds._states[index] = st
    end
    return st
end

-- Rebuild deterministically. Same seed in, same background out.
function Backgrounds.reset(index, seed)
    local sp = specs[index]
    if not sp then return nil end
    local st = newState(sp, seed or (Backgrounds._seed + index * 7919))
    Backgrounds._states[index] = st
    return st
end

-- Advance one frame. With no argument this steps whichever background was last
-- drawn: stepping all seventeen would make a consumer who has cycled through
-- the list pay for sixteen simulations they cannot see (Life alone is 13500
-- neighbour reads a generation).
function Backgrounds.update(index)
    index = index or Backgrounds.current
    local sp = specs[index]
    if not sp then return end
    local st = Backgrounds.state(index)
    advance(st)
    if sp.step then sp.step(st) end
end

function Backgrounds.draw(index)
    local sp = specs[index]
    if not sp then return false end
    if not Backgrounds._loaded then Backgrounds.load() end
    Backgrounds.current = index
    local st = Backgrounds.state(index)
    if not Backgrounds._ready then return false end
    sp.render(st)
    -- Hand the context back in a known state; several renderers leave a dither
    -- pattern or a white pen behind and the caller draws its UI next.
    gfx.setColor(gfx.kColorBlack)
    return true
end

return Backgrounds
