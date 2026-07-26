-- Host tests for backgrounds.lua.
--
-- The headline case is the first one: this file runs under a stock `lua` with
-- no `playdate` global anywhere, so simply getting to line two proves the
-- module keeps CONVENTIONS rule 1. Everything after that leans on the pure
-- simulation being reachable without the SDK (rule 3).

local A = require("assert")

-- ---------------------------------------------------------------- rule 1 ---

A.eq(rawget(_G, "playdate"), nil, "host lua really has no playdate global")

local B = require("backgrounds")

A.truthy(B, "require('backgrounds') returns the module")
A.eq(B, rawget(_G, "Backgrounds"), "module is also published as a global")
A.eq(type(B.update), "function", "update is exported")
A.eq(type(B.draw), "function", "draw is exported")

-- load() must report "not ready" rather than crash when there is no SDK, and
-- every draw path must then be a silent no-op.
A.eq(B.load(), false, "load reports no SDK on the host")
A.eq(B._ready, false, "_ready is false without the SDK")
for i = 1, B.count do
    A.eq(B.draw(i), false, "draw(" .. i .. ") no-ops without the SDK")
end
A.eq(B.draw(0), false, "draw(0) is refused")
A.eq(B.draw(B.count + 1), false, "draw past the end is refused")

local W, H = B.SCREEN_W, B.SCREEN_H
A.eq(W, 400, "screen width")
A.eq(H, 240, "screen height")

-- --------------------------------------------------- names vs. implementations

A.eq(#B.names, B.count, "names list length matches count")

local implemented = 0
while B.state(implemented + 1) do implemented = implemented + 1 end
A.eq(implemented, B.count, "count matches the number of implementations")
A.eq(B.state(B.count + 1), nil, "no state past the last background")
A.eq(B.state(0), nil, "no state at index 0")

local seen = {}
local namesOk = true
for i = 1, B.count do
    local n = B.names[i]
    if type(n) ~= "string" or n == "" or seen[n] then namesOk = false end
    seen[n] = true
    A.eq(B.getName(i), n, "getName(" .. i .. ") agrees with the name list")
    A.eq(B.indexOf(n), i, "indexOf round-trips " .. tostring(n))
end
A.truthy(namesOk, "every name is a non-empty unique string")
A.eq(B.getName(B.count + 1), nil, "getName is nil past the end")
A.eq(B.indexOf("Nope"), nil, "indexOf is nil for an unknown name")

-- The nine the README advertises must still be there after the refactor.
for _, n in ipairs({"Starfield", "Waves", "Radar", "Rain", "Squares",
                    "Spirograph", "Lava Lamp", "Dither Hills", "Bubbles Rise"}) do
    A.truthy(B.indexOf(n), "README background still present: " .. n)
end

-- ------------------------------------------------------------- invariants ---

-- Every cyclic quantity must sit inside [0, period) and must be advancing by a
-- rate smaller than that period -- that is what makes the single-subtract wrap
-- in advance() correct and the animation safe on a 32-bit float forever.
local function accsOk(st)
    for i = 1, st.np do
        local p, r, per = st.p[i], st.rate[i], st.per[i]
        if type(per) ~= "number" or per <= 0 then return false, "bad period" end
        if type(r) ~= "number" or r <= 0 or r >= per then return false, "bad rate" end
        if p < 0 or p >= per then return false, "accumulator escaped its period" end
    end
    return true, "ok"
end

local function boundsOk(st, margin)
    local items = st.items
    for k = 1, #items do
        local it = items[k]
        if type(it.x) == "number" and (it.x < -margin or it.x > W + margin) then return false end
        if type(it.y) == "number" and (it.y < -margin or it.y > H + margin) then return false end
    end
    -- Lightning keeps its vertices as flat {x,y,x,y,...} lists, not item tables.
    if st.bolts then
        for b = 1, #st.bolts do
            local bolt = st.bolts[b]
            for k = 1, #bolt, 2 do
                if bolt[k] < -margin or bolt[k] > W + margin then return false end
                if bolt[k + 1] < -margin or bolt[k + 1] > H + margin then return false end
            end
        end
    end
    return true
end

-- A cheap order-sensitive fingerprint of the whole simulation.
local function signature(st)
    local acc = 0
    for i = 1, st.np do acc = acc + st.p[i] * i end
    local items = st.items
    for i = 1, #items do
        local it = items[i]
        if type(it.x) == "number" then acc = acc + it.x * (i + 1) end
        if type(it.y) == "number" then acc = acc + it.y * (i + 2) end
        if type(it.r) == "number" then acc = acc + it.r * (i + 3) end
    end
    if st.grid then
        for i = 1, #st.grid do acc = acc + st.grid[i] * i end
    end
    if st.bolts then
        for b = 1, #st.bolts do
            local bolt = st.bolts[b]
            for k = 1, #bolt do acc = acc + bolt[k] * k * b end
        end
    end
    return acc
end

local SEED <const> = 424242
local STEPS <const> = 400

local function run(i, seed, steps)
    local st = B.reset(i, seed)
    local ok = true
    local why = "ok"
    local margin = B.margin(i)
    for n = 1, steps do
        B.update(i)
        -- Sample rather than assert every frame: one bad frame poisons the
        -- accumulated fingerprint anyway, and this keeps the check count sane.
        if n % 40 == 0 then
            local a, msg = accsOk(st)
            if not a then ok, why = false, msg end
            if not boundsOk(st, margin) then ok, why = false, "left the screen" end
        end
    end
    return st, ok, why
end

local firstPass = {}
for i = 1, B.count do
    local st, ok, why = run(i, SEED, STEPS)
    A.truthy(ok, B.names[i] .. " stays bounded and in-period (" .. why .. ")")
    A.truthy(st.np > 0 or #st.items > 0, B.names[i] .. " actually has state")
    firstPass[i] = signature(st)
end

-- Same seed, same frames, same state: the whole point of dropping math.random.
for i = 1, B.count do
    local st = run(i, SEED, STEPS)
    A.eq(signature(st), firstPass[i], B.names[i] .. " replays identically from a seed")
end

-- The randomised backgrounds must actually depend on the seed, or "deterministic
-- from a seed" would be true for the boring reason.
for _, n in ipairs({"Starfield", "Rain", "Matrix Rain", "Confetti", "Life", "Lightning"}) do
    local i = B.indexOf(n)
    local st = run(i, SEED + 1, STEPS)
    A.truthy(signature(st) ~= firstPass[i], n .. " differs on a different seed")
end

-- ------------------------------------------------------------------ looping --

-- The reason accumulators exist. 30000 frames is about 17 minutes at 30fps --
-- a plausible "left it on the menu" session. Every phase must still be inside
-- its period and every particle still on screen, exactly as at frame one. A
-- module that had kept `tick * rate` would pass this and still die later; what
-- this pins is that nothing here can grow at all.
local LONG <const> = 30000
for i = 1, B.count do
    if B.names[i] ~= "Life" then   -- a 1500-cell CA every 6th frame; not worth 30k frames here
        local st = B.reset(i, SEED)
        local ok, why = true, "ok"
        for n = 1, LONG do
            B.update(i)
            if n % 2500 == 0 then
                local a, msg = accsOk(st)
                if not a then ok, why = false, msg end
                if not boundsOk(st, B.margin(i)) then ok, why = false, "left the screen" end
            end
        end
        A.truthy(ok, B.names[i] .. " still loops cleanly after " .. LONG .. " frames (" .. why .. ")")
    end
end

-- Phase-only backgrounds must genuinely move, otherwise the wrap test above
-- would pass on a frozen animation.
for _, n in ipairs({"Waves", "Radar", "Squares", "Spirograph", "Plasma", "Fire",
                    "Moire", "Terrain", "Dither Hills", "Lava Lamp"}) do
    local i = B.indexOf(n)
    local st = B.reset(i, SEED)
    local before = signature(st)
    B.update(i)
    A.truthy(signature(st) ~= before, n .. " advances when updated")
end

-- ------------------------------------------------------------ dither tiles --

-- CONVENTIONS rule 6: an all-zero tile renders solid black, not transparent.
-- Every level any background can ask for must light at least one pixel of the
-- equivalent 8x8 Bayer tile, and so must a level a future edit gets wrong.
for _, lvl in ipairs(B.DITHER_LEVELS) do
    local s = B.safeDither(lvl)
    A.truthy(s > 0 and s <= 1, "dither level " .. lvl .. " clamps into (0,1]")
    A.truthy(B.ditherPixels(lvl) >= 1, "dither level " .. lvl .. " is not an all-zero tile")
end
A.truthy(B.ditherPixels(0) >= 1, "a zero level still lights a pixel")
A.truthy(B.ditherPixels(-3) >= 1, "a negative level still lights a pixel")
A.truthy(B.ditherPixels(nil) >= 1, "a nil level still lights a pixel")
A.eq(B.ditherPixels(1), 64, "a full level fills the tile")
A.eq(B.ditherPixels(9), 64, "an over-range level saturates rather than wrapping")
A.eq(B.safeDither(0.5), 0.5, "an in-range level passes through untouched")

-- --------------------------------------------------------------- lifecycle --

-- update() with no argument follows the last background drawn, so the README's
-- update()/draw(i) pair works without the consumer tracking an index.
B.draw(3)
A.eq(B.current, 3, "draw records the current background")
local radar = B.state(3)
local before = signature(radar)
B.update()
A.truthy(signature(radar) ~= before, "bare update() advances the current background")

-- A brand-new index must not have been simulated by the calls above -- that is
-- the "one background must not pay for the other sixteen" rule.
B.load({seed = 99})
A.eq(B._states[1], nil, "load with a seed drops the built states")
A.eq(B._seed, 99, "load stores the seed")
B.state(5)
A.eq(B._states[6], nil, "asking for one background builds only that one")

-- Out-of-range calls stay quiet instead of indexing a nil spec.
B.update(0)
B.update(B.count + 1)
B.update(nil)
A.eq(B.reset(B.count + 1), nil, "reset past the end returns nil")
A.truthy(B.reset(1, 7), "reset with a seed returns the fresh state")

return true
