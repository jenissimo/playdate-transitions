-- tween.lua -- normalized easing curves + a frame-stepped tweener.
--
-- WHY THIS EXISTS WHEN THE SDK ALREADY TWEENS
--
-- `playdate.easingFunctions` (CoreLibs/easing) is the same Penner set, in
-- Penner's four-argument form f(elapsed, begin, change, duration). `Tween.ease`
-- is the normalized one-argument form f(t in 0..1) -> 0..1. Reach for the SDK's
-- when you are feeding `playdate.timer` or `playdate.graphics.animator`, which
-- expect that signature. Reach for these when you want a curve you can compose,
-- store in a data table, hand to a shader-ish loop, or assert on in a host test:
-- CoreLibs/easing assigns into the `playdate` global at load, so it cannot even
-- be require()d under host lua. `Tween.penner(name)` bridges the SDK table into
-- this one on device.
--
-- Normalizing also fixes endpoint bugs the SDK inherits from Penner, which
-- matter because an easing endpoint is what a sprite's resting position is:
--   * inExpo(d, b, c, d) returns b + 0.999*c -- off by a tenth of a percent of
--     the whole travel, so `inExpo` never actually arrives.
--   * inSine and outBack land ~1e-16 off their endpoints (cos(pi/2) is not 0).
-- Every `Tween.ease` entry returns exactly 0 for t <= 0 and exactly 1 for
-- t >= 1; test/tween_test.lua pins all of them, so a future edit cannot
-- reintroduce the drift.
--
-- `playdate.timer` / `playdate.frameTimer` will interpolate one value each, but
-- both push themselves into a module-private registry driven by the runtime, so
-- neither is reachable from a host test, and `playdate.timer` is wall-clock
-- driven -- a busy frame changes the numbers, which is the opposite of what a
-- test wants. Neither offers sequencing, parallel groups, or reuse: you
-- hand-roll the chain out of `timerEndedCallback`, and every `.new()` is a fresh
-- table plus a registry entry removed with `table.remove`.
--
-- WHAT THIS ADDS
--   * Frame-count stepping. `Tween.update()` advances exactly one frame, or dt
--     frames. Twenty updates of a 20-frame tween is 20 frames, on a 50 fps
--     Simulator and on a device dropping to 22 fps alike, and in a test.
--   * Sequences and parallel groups that nest, with exact leftover carry -- a
--     sequence of three 10-frame tweens finishes on update 30, not 30-ish.
--   * A pool. `Tween.update` allocates nothing: no closures, no varargs, no
--     table.remove, numeric-for only. Finished tweens are recycled.
--   * Critically damped springs and half-life damping, which the SDK lacks
--     entirely and which are what you actually want for a camera or a cursor
--     chasing a moving target (an easing curve needs a fixed destination).
--
-- Everything here is pure Lua. There is no device section and no `_ready` flag
-- (rule 2 is vacuous for this module) -- it behaves identically under host lua
-- and on hardware, which is the whole point.

Tween = Tween or {}

local sin <const> = math.sin
local cos <const> = math.cos
local sqrt <const> = math.sqrt
local floor <const> = math.floor
local pi <const> = math.pi

--------------------------------------------------------------------------------
-- Easing
--------------------------------------------------------------------------------

-- Penner's magic numbers, named once. c1 is the classic 10% overshoot.
local c1 <const> = 1.70158
local c2 <const> = c1 * 1.525
local c3 <const> = c1 + 1
local c4 <const> = (2 * pi) / 3
local c5 <const> = (2 * pi) / 4.5
local n1 <const> = 7.5625
local d1 <const> = 2.75

-- Raw curves: no endpoint guards, because every one of them is wrapped below and
-- the wrapper short-circuits t <= 0 and t >= 1. That is not just tidiness -- it
-- means `inExpo` never evaluates 2^-10 at t=0, and no curve can drift off its
-- endpoint no matter how the formula is later rewritten.
local raw = {}

function raw.linear(t) return t end

function raw.inQuad(t) return t * t end
function raw.outQuad(t) local u = 1 - t; return 1 - u * u end
function raw.inOutQuad(t)
    if t < 0.5 then return 2 * t * t end
    local u = -2 * t + 2
    return 1 - u * u / 2
end

function raw.inCubic(t) return t * t * t end
function raw.outCubic(t) local u = 1 - t; return 1 - u * u * u end
function raw.inOutCubic(t)
    if t < 0.5 then return 4 * t * t * t end
    local u = -2 * t + 2
    return 1 - u * u * u / 2
end

function raw.inQuart(t) local s = t * t; return s * s end
function raw.outQuart(t) local u = 1 - t; u = u * u; return 1 - u * u end
function raw.inOutQuart(t)
    if t < 0.5 then local s = t * t; return 8 * s * s end
    local u = -2 * t + 2
    u = u * u
    return 1 - u * u / 2
end

function raw.inQuint(t) local s = t * t; return s * s * t end
function raw.outQuint(t) local u = 1 - t; local s = u * u; return 1 - s * s * u end
function raw.inOutQuint(t)
    if t < 0.5 then local s = t * t; return 16 * s * s * t end
    local u = -2 * t + 2
    local s = u * u
    return 1 - s * s * u / 2
end

function raw.inSine(t) return 1 - cos((t * pi) / 2) end
function raw.outSine(t) return sin((t * pi) / 2) end
function raw.inOutSine(t) return -(cos(pi * t) - 1) / 2 end

function raw.inExpo(t) return 2 ^ (10 * t - 10) end
function raw.outExpo(t) return 1 - 2 ^ (-10 * t) end
function raw.inOutExpo(t)
    if t < 0.5 then return 2 ^ (20 * t - 10) / 2 end
    return (2 - 2 ^ (-20 * t + 10)) / 2
end

function raw.inCirc(t) return 1 - sqrt(1 - t * t) end
function raw.outCirc(t) local u = t - 1; return sqrt(1 - u * u) end
function raw.inOutCirc(t)
    if t < 0.5 then
        local u = 2 * t
        return (1 - sqrt(1 - u * u)) / 2
    end
    local u = -2 * t + 2
    return (sqrt(1 - u * u) + 1) / 2
end

function raw.inBack(t) return c3 * t * t * t - c1 * t * t end
function raw.outBack(t)
    local u = t - 1
    return 1 + c3 * u * u * u + c1 * u * u
end
function raw.inOutBack(t)
    if t < 0.5 then
        local u = 2 * t
        return (u * u * ((c2 + 1) * u - c2)) / 2
    end
    local u = 2 * t - 2
    return (u * u * ((c2 + 1) * u + c2) + 2) / 2
end

function raw.inElastic(t) return -(2 ^ (10 * t - 10)) * sin((t * 10 - 10.75) * c4) end
function raw.outElastic(t) return 2 ^ (-10 * t) * sin((t * 10 - 0.75) * c4) + 1 end
function raw.inOutElastic(t)
    if t < 0.5 then
        return -(2 ^ (20 * t - 10) * sin((20 * t - 11.125) * c5)) / 2
    end
    return (2 ^ (-20 * t + 10) * sin((20 * t - 11.125) * c5)) / 2 + 1
end

function raw.outBounce(t)
    if t < 1 / d1 then
        return n1 * t * t
    elseif t < 2 / d1 then
        t = t - 1.5 / d1
        return n1 * t * t + 0.75
    elseif t < 2.5 / d1 then
        t = t - 2.25 / d1
        return n1 * t * t + 0.9375
    end
    t = t - 2.625 / d1
    return n1 * t * t + 0.984375
end
function raw.inBounce(t) return 1 - raw.outBounce(1 - t) end
function raw.inOutBounce(t)
    if t < 0.5 then return (1 - raw.outBounce(1 - 2 * t)) / 2 end
    return (1 + raw.outBounce(2 * t - 1)) / 2
end

-- One wrapper per curve, built once at load. The extra call is a few dozen
-- nanoseconds against one evaluation per tween per frame, and it buys the
-- endpoint contract for the whole set at once instead of one chance per curve to
-- forget a guard. It also clamps the domain, so feeding a curve a t outside 0..1 (a
-- sequence carrying leftover, a hand-computed ratio) saturates instead of
-- extrapolating an overshoot curve into nonsense.
local function clamped(f)
    return function(t)
        if t <= 0 then return 0 end
        if t >= 1 then return 1 end
        return f(t)
    end
end

Tween.ease = {}
for name, f in pairs(raw) do
    Tween.ease[name] = clamped(f)
end

-- Sorted, so demos and tests iterate in a fixed order. `pairs` over Tween.ease
-- is not reproducible between runs and a test that walks the set must be.
Tween.easeNames = {}
for name in pairs(Tween.ease) do
    Tween.easeNames[#Tween.easeNames + 1] = name
end
table.sort(Tween.easeNames)

-- Adapt a Penner four-arg easing to the normalized form. Allocates a closure, so
-- call it at setup and keep the result, never per frame.
function Tween.fromPenner(f)
    return clamped(function(t) return f(t, 0, 1, 1) end)
end

-- Same, by name, from the SDK's table if it is present. rawget so this file
-- still loads under host lua, where it simply returns nil.
function Tween.penner(name)
    local pd = rawget(_G, "playdate")
    local set = pd and pd.easingFunctions
    local f = set and set[name]
    return f and Tween.fromPenner(f) or nil
end

local function resolveEase(e)
    if e == nil then return Tween.ease.linear end
    if type(e) == "string" then
        local f = Tween.ease[e]
        if not f then error("tween: unknown easing '" .. e .. "'", 3) end
        return f
    end
    return e
end

--------------------------------------------------------------------------------
-- Stateless interpolation helpers
--------------------------------------------------------------------------------

function Tween.lerp(a, b, t)
    -- (1-t)*a + t*b rather than a + (b-a)*t: the second form can land a ulp off
    -- b at t=1, and "a ulp off" is a sprite parked at 199.9997.
    return (1 - t) * a + t * b
end

-- Exponential smoothing with a half-life expressed in frames. Unlike the usual
-- `cur += (tgt - cur) * 0.2`, this is stepsize-independent: two updates of
-- dt=0.5 land exactly where one update of dt=1 does, so it behaves the same when
-- the device drops frames.
function Tween.damp(current, target, halfLife, dt)
    if halfLife <= 0 then return target end
    return target + (current - target) * 0.5 ^ ((dt or 1) / halfLife)
end

--------------------------------------------------------------------------------
-- Critically damped spring
--------------------------------------------------------------------------------

-- What easing cannot do: chase a target that keeps moving. An easing curve is
-- parameterized on a fixed destination, so retargeting mid-flight either snaps
-- or restarts. A spring carries velocity, so it just bends. Standard
-- critically-damped solution (Game Programming Gems 4 / Unity SmoothDamp) --
-- critically damped means it never overshoots, which is what you want for a
-- camera or a menu cursor and not what `outElastic` gives you.
--
-- smoothTime and dt are both in FRAMES, consistent with the rest of the module.
--
-- Note the one place a spring differs from a tween here: it converges
-- asymptotically and never lands exactly on the target, because there is no
-- final frame to snap on. If you need an exact resting value, tween; if you need
-- to follow something, spring.
local Spring = {}
Spring.__index = Spring

function Tween.newSpring(value, smoothTime, maxSpeed)
    return setmetatable({
        value = value or 0,
        velocity = 0,
        smoothTime = smoothTime or 10,
        maxSpeed = maxSpeed or math.huge,
    }, Spring)
end

function Spring:reset(value)
    self.value = value or 0
    self.velocity = 0
    return self
end

function Spring:update(target, dt)
    dt = dt or 1
    local smoothTime = self.smoothTime
    if smoothTime < 1e-4 then smoothTime = 1e-4 end

    local omega = 2 / smoothTime
    local x = omega * dt
    -- Pade approximation of exp(-x); cheaper than math.exp and monotone over the
    -- range we care about.
    local expf = 1 / (1 + x + 0.48 * x * x + 0.235 * x * x * x)

    local change = self.value - target
    local maxChange = self.maxSpeed * smoothTime
    if change > maxChange then change = maxChange
    elseif change < -maxChange then change = -maxChange end

    local goal = self.value - change
    local temp = (self.velocity + omega * change) * dt
    self.velocity = (self.velocity - omega * temp) * expf
    local out = goal + (change + temp) * expf

    -- Guard the one case the analytic solution gets wrong: a large dt can step
    -- past the target. Snap instead, or the spring visibly ticks backwards on a
    -- dropped frame.
    if (target - self.value > 0) == (out > target) then
        out = target
        self.velocity = (out - goal) / dt
    end

    self.value = out
    return out
end

--------------------------------------------------------------------------------
-- Tweener
--------------------------------------------------------------------------------

local Node = {}
Node.__index = Node

local _active = {}   -- root nodes, dense 1.._n
local _n = 0
local _pool = {}     -- recycled node tables, dense 1.._poolN
local _poolN = 0
local _tick = 0      -- update counter, used to defer newborn nodes one frame

-- Pooling contract, stated once because it is the one sharp edge here:
-- a node that finishes or is cancelled goes back into the pool and its table is
-- handed to the next `Tween.to`. That is safe for the overwhelmingly common
-- fire-and-forget use, and it is why `Tween.update` allocates nothing in steady
-- state. If you intend to hold a handle PAST completion, call `tw:keep()`;
-- otherwise a stale handle's `:cancel()` will cancel whichever tween now owns
-- the table. `tw.done` tells you which state you are in.
local function alloc()
    if _poolN > 0 then
        local t = _pool[_poolN]
        _pool[_poolN] = nil
        _poolN = _poolN - 1
        t._pooled = false
        return t
    end
    -- The four arrays are allocated once per node ever created and then reused
    -- forever; that is the whole point of keeping them out of the reset path.
    return setmetatable({ keys = {}, from = {}, to = {}, items = {} }, Node)
end

local function release(node)
    if node._pooled then return end
    node._pooled = true
    -- Drop every outward reference or the pool pins sprites and child nodes
    -- alive, which turns a memory optimisation into a leak.
    node.obj = nil
    node.oncomplete = nil
    node.onupdate = nil
    local items = node.items
    for i = 1, node.itemN do items[i] = nil end
    node.itemN = 0
    node.n = 0
    _poolN = _poolN + 1
    _pool[_poolN] = node
end

Tween.release = release

local function root(node)
    node._inRoot = true
    node._bornAt = _tick
    _n = _n + 1
    _active[_n] = node
    return node
end

-- Steps. Each returns leftover dt (>= 0) if the node finished during this step,
-- or nil if it is still running. The leftover is what makes a sequence land on
-- an exact frame count instead of accumulating a rounding error per member.
local STEP = {}

local function applyEnd(self)
    local keys, to, obj, rnd = self.keys, self.to, self.obj, self.round
    for i = 1, self.n do
        local v = to[i]
        if rnd then v = floor(v + 0.5) end
        -- Written verbatim, not through the easing: this is the line that
        -- guarantees a finished tween is AT 200 and not at 199.99999999999997.
        obj[keys[i]] = v
    end
    self.progress = 1
    self.eased = 1
end

STEP.tween = function(self, dt)
    if not self.started then
        self.started = true
        local keys, from, obj = self.keys, self.from, self.obj
        -- `from` is read here, not at construction, so a tween sitting second in
        -- a sequence starts from wherever the first one actually left the
        -- object -- the alternative silently snaps.
        for i = 1, self.n do
            local v = obj[keys[i]]
            if type(v) ~= "number" then
                error("tween: field '" .. tostring(keys[i]) .. "' is not a number", 2)
            end
            from[i] = v
        end
    end

    local frames = self.frames
    local f = self.frame + dt
    self.frame = f

    if f >= frames then
        applyEnd(self)
        if self.onupdate then self.onupdate(self) end
        return f - frames
    end

    local p = f / frames
    local e = self.easefn(p)
    local keys, from, to, obj, rnd = self.keys, self.from, self.to, self.obj, self.round
    for i = 1, self.n do
        local a = from[i]
        local v = a + (to[i] - a) * e
        if rnd then v = floor(v + 0.5) end
        obj[keys[i]] = v
    end
    self.progress = p
    self.eased = e
    if self.onupdate then self.onupdate(self) end
    return nil
end

STEP.seq = function(self, dt)
    local items, itemN = self.items, self.itemN
    while true do
        local child = items[self.index]
        if not child then return dt end
        local left = child:_step(dt)
        if left == nil then
            self.progress = (self.index - 1) / itemN
            return nil
        end
        child:_complete()
        self.index = self.index + 1
        dt = left
    end
end

STEP.par = function(self, dt)
    local items, itemN = self.items, self.itemN
    local allDone = true
    local minLeft = nil
    for i = 1, itemN do
        local child = items[i]
        if not child.done then
            local left = child:_step(dt)
            if left == nil then
                allDone = false
            else
                child:_complete()
                if minLeft == nil or left < minLeft then minLeft = left end
            end
        end
    end
    if not allDone then return nil end
    -- The group ends when its LAST member does, so the leftover is the smallest
    -- of the members' leftovers, not the largest.
    return minLeft or dt
end

function Node:_step(dt)
    return self.step(self, dt)
end

function Node:_complete()
    if self.done then return end
    self.done = true
    self._inRoot = false
    if self.itemN > 0 then
        local items = self.items
        for i = 1, self.itemN do
            local c = items[i]
            if not c.done then c:_complete() end
        end
    end
    -- `_fired` rather than nil-ing the callback, so that a `restart()` (possibly
    -- from inside the callback itself) can legitimately arm it again, while a
    -- plain completion can only ever fire once.
    if self.oncomplete and not self._fired then
        self._fired = true
        self.oncomplete(self)
    end
end

local function initNode(node, kind, frames, easefn)
    node.kind = kind
    node.step = STEP[kind]
    node.frames = frames or 0
    node.frame = 0
    node.easefn = easefn or Tween.ease.linear
    node.n = 0
    node.itemN = 0
    node.index = 1
    node.progress = 0
    node.eased = 0
    node.done = false
    node.cancelled = false
    node.paused = false
    node.started = false
    node.round = false
    node._fired = false
    node._recycle = true
    node._inRoot = false
    node._adopted = false
    node.obj = nil
    node.oncomplete = nil
    node.onupdate = nil
    node.value = 0
    return node
end

--------------------------------------------------------------------------------
-- Constructors
--------------------------------------------------------------------------------

-- Tween.to(obj, frames, {x = 200, y = 40}, "outBack")
function Tween.to(obj, frames, fields, ease)
    local t = initNode(alloc(), "tween", frames, resolveEase(ease))
    t.obj = obj
    local keys, to = t.keys, t.to
    local i = 0
    for k, v in pairs(fields) do
        i = i + 1
        keys[i] = k
        to[i] = v
    end
    t.n = i
    return root(t)
end

-- Single-field form. Same thing without the table literal at the call site,
-- which matters if you are firing tweens from inside a loop.
function Tween.field(obj, frames, key, toValue, ease)
    local t = initNode(alloc(), "tween", frames, resolveEase(ease))
    t.obj = obj
    t.keys[1] = key
    t.to[1] = toValue
    t.n = 1
    return root(t)
end

-- A bare number, for when there is no object to write into. Read `tw.value`.
function Tween.value(from, to, frames, ease)
    local t = initNode(alloc(), "tween", frames, resolveEase(ease))
    t.value = from
    t.obj = t              -- the node is its own target; tw.value is the field
    t.keys[1] = "value"
    t.to[1] = to
    t.n = 1
    return root(t)
end

function Tween.delay(frames)
    return root(initNode(alloc(), "tween", frames, Tween.ease.linear))
end

-- Zero-frame node that fires its callback on completion. Exists to be dropped
-- into a sequence, where it is the "and now do this" step.
function Tween.call(fn)
    local t = initNode(alloc(), "tween", 0, Tween.ease.linear)
    t.oncomplete = fn
    return root(t)
end

local function adopt(node, i, child)
    -- Taking a child out of the root list is a flag, not a table.remove: the
    -- root loop sweeps un-rooted nodes on its next pass, so nothing mutates
    -- _active while it is being walked.
    child._inRoot = false
    child._adopted = true
    node.items[i] = child
end

local function group(kind, ...)
    local t = initNode(alloc(), kind, 0, Tween.ease.linear)
    local count = select("#", ...)
    for i = 1, count do
        adopt(t, i, (select(i, ...)))
    end
    t.itemN = count
    return root(t)
end

function Tween.sequence(...) return group("seq", ...) end
function Tween.parallel(...) return group("par", ...) end
Tween.chain = Tween.sequence

--------------------------------------------------------------------------------
-- Handle methods
--------------------------------------------------------------------------------

function Node:onComplete(fn) self.oncomplete = fn; self._fired = false; return self end
function Node:onUpdate(fn) self.onupdate = fn; return self end

-- Round every written value to an integer. On a 1-bit 400x240 screen a sprite at
-- x=142.7 is drawn at 142 anyway, and rounding here keeps the value the game
-- logic reads in agreement with the pixel the player sees.
function Node:snap(on)
    self.round = (on ~= false)
    return self
end

-- Opt out of pooling. Required if you keep the handle past completion.
function Node:keep()
    self._recycle = false
    return self
end

function Node:pause() self.paused = true; return self end
function Node:resume() self.paused = false; return self end

-- Stop where it stands: no final value written, no completion callback. This is
-- deliberately not `finish()` -- cancelling an entrance animation should leave
-- the sprite mid-slide so the caller can take over, not teleport it.
function Node:cancel()
    if self.done then return self end
    self.done = true
    self.cancelled = true
    self._inRoot = false
    for i = 1, self.itemN do
        local c = self.items[i]
        if not c.done then c:cancel() end
    end
    return self
end

-- Jump to the end: writes the target values and fires the callback.
function Node:finish()
    if self.done then return self end
    -- A huge dt rather than a special case, so completion goes down exactly the
    -- same path as a natural finish and cannot drift from it.
    self:_step(self.frames * 2 + 1e9)
    self:_complete()
    return self
end

function Node:restart()
    self.frame = 0
    self.index = 1
    self.done = false
    self.cancelled = false
    self._fired = false
    self.progress = 0
    self.eased = 0
    -- `started` stays true if it ever ran, so a restart replays the recorded
    -- from -> to. Re-reading the object here would make replaying a finished
    -- tween a no-op, since the object is already sitting on the target.
    for i = 1, self.itemN do self.items[i]:restart() end
    -- Only a root re-enters the driver. An adopted child is stepped by its
    -- parent, and rooting it here would run it twice per frame.
    if not self._inRoot and not self._adopted then
        if self._pooled then
            error("tween: restart() on a recycled tween -- call keep() if you hold the handle", 2)
        end
        root(self)
    end
    return self
end

--------------------------------------------------------------------------------
-- Driver
--------------------------------------------------------------------------------

-- Call once per playdate.update. dt is in frames and defaults to 1; pass a real
-- delta only if you are deliberately decoupling from the frame rate.
--
-- Allocation-free by construction: numeric for, swap-remove instead of
-- table.remove, no closures, no varargs, no string building. Anything added here
-- has to keep that true.
function Tween.update(dt)
    dt = dt or 1
    _tick = _tick + 1
    local a = _active
    local i = 1
    while i <= _n do
        local node = a[i]
        local drop = not node._inRoot
        if not drop and not node.paused and node._bornAt ~= _tick then
            -- A tween created during this same update (typically by a completion
            -- callback) waits for the next one. Otherwise a chain built in a
            -- callback would jump a frame ahead of one built anywhere else,
            -- which is exactly the sort of thing that only shows up on device.
            local left = node:_step(dt)
            if left ~= nil then
                node:_complete()
                drop = true
            end
        end
        if drop then
            -- Guarded because a completion callback is allowed to tear the whole
            -- thing down (Tween.reset() on "run over"), which empties the list
            -- underneath us. Without this the swap writes past the end and _n
            -- goes negative.
            if _n >= i then
                a[i] = a[_n]
                a[_n] = nil
                _n = _n - 1
            end
            if node._recycle and (node.done or node.cancelled) then
                for k = 1, node.itemN do
                    local c = node.items[k]
                    if c._recycle then release(c) end
                end
                release(node)
            end
        else
            i = i + 1
        end
    end
end

function Tween.count() return _n end
function Tween.poolSize() return _poolN end

function Tween.stopAll()
    for i = 1, _n do _active[i]:cancel() end
end

-- Drop everything without running callbacks and empty the pool. For tests and
-- for a hard reset between scenes.
function Tween.reset()
    for i = 1, _n do
        _active[i]._inRoot = false
        _active[i] = nil
    end
    _n = 0
    for i = 1, _poolN do _pool[i] = nil end
    _poolN = 0
    _tick = 0
end

return Tween
