-- Host tests for tween.lua.
--
-- The module is pure Lua with no device section, so this file covers all of it.
-- The two things worth being pedantic about, because both produce bugs that only
-- show as a pixel out of place and never as a crash:
--   1. endpoint exactness -- an easing that returns 0.9999999999999999 at t=1
--      parks a sprite one unit short forever;
--   2. frame accounting -- a sequence that loses a fractional frame per member
--      drifts out of sync with the sound cue it was supposed to hit.

local A = require("assert")
local Tween = require("tween")

--------------------------------------------------------------------------------
-- Easing: endpoints
--------------------------------------------------------------------------------

-- The classic off-by-one lives in outBounce and inElastic, but asserting on the
-- whole set is the only version of this test that stays true after someone adds
-- a curve.
A.truthy(#Tween.easeNames >= 30, "ease set is populated")
for _, name in ipairs(Tween.easeNames) do
    local f = Tween.ease[name]
    A.eq(f(0), 0, name .. "(0) is exactly 0")
    A.eq(f(1), 1, name .. "(1) is exactly 1")
    -- Domain clamp: out-of-range t saturates rather than extrapolating.
    A.eq(f(-0.5), 0, name .. "(-0.5) clamps to 0")
    A.eq(f(1.5), 1, name .. "(1.5) clamps to 1")
end

-- Endpoint exactness is not free: these are the values the raw Penner formulas
-- produce, and each is the reason the clamp wrapper exists.
A.truthy(1 - math.cos(math.pi / 2) ~= 1, "raw inSine really does miss 1")
A.truthy(2.70158 - 1.70158 ~= 1, "raw inBack really does miss 1")

-- Midpoint sanity: symmetric inOut curves cross at exactly 0.5.
for _, name in ipairs({ "linear", "inOutQuad", "inOutCubic", "inOutQuart",
                        "inOutQuint", "inOutSine", "inOutCirc", "inOutBounce" }) do
    A.near(Tween.ease[name](0.5), 0.5, 1e-12, name .. " crosses 0.5 at t=0.5")
end

-- Known values, so a rewritten formula cannot silently change shape.
A.near(Tween.ease.inQuad(0.5), 0.25, 1e-12, "inQuad(0.5)")
A.near(Tween.ease.outQuad(0.5), 0.75, 1e-12, "outQuad(0.5)")
A.near(Tween.ease.inCubic(0.5), 0.125, 1e-12, "inCubic(0.5)")
A.near(Tween.ease.outSine(0.5), math.sin(math.pi / 4), 1e-12, "outSine(0.5)")

--------------------------------------------------------------------------------
-- Easing: monotonicity and overshoot
--------------------------------------------------------------------------------

local monotone = {
    "linear", "inQuad", "outQuad", "inOutQuad", "inCubic", "outCubic",
    "inOutCubic", "inQuart", "outQuart", "inOutQuart", "inQuint", "outQuint",
    "inOutQuint", "inSine", "outSine", "inOutSine", "inExpo", "outExpo",
    "inOutExpo", "inCirc", "outCirc", "inOutCirc",
}
for _, name in ipairs(monotone) do
    local f = Tween.ease[name]
    local prev = f(0)
    local ok = true
    local inRange = true
    for i = 1, 200 do
        local v = f(i / 200)
        if v < prev - 1e-12 then ok = false end
        if v < -1e-12 or v > 1 + 1e-12 then inRange = false end
        prev = v
    end
    A.truthy(ok, name .. " is non-decreasing")
    A.truthy(inRange, name .. " stays within 0..1")
end

-- The overshoot families must actually overshoot, or they have been flattened
-- into their non-overshooting cousins by a bad edit.
local function extremes(name)
    local f = Tween.ease[name]
    local lo, hi = 0, 1
    for i = 0, 200 do
        local v = f(i / 200)
        if v < lo then lo = v end
        if v > hi then hi = v end
    end
    return lo, hi
end
local lo = select(1, extremes("inBack"))
A.truthy(lo < -0.05, "inBack undershoots below 0")
local _, hi = extremes("outBack")
A.truthy(hi > 1.05, "outBack overshoots above 1")
local elo, ehi = extremes("inOutElastic")
A.truthy(elo < 0 and ehi > 1, "inOutElastic swings both ways")

-- outBounce's four-segment piecewise must never leave 0..1 and must be made of
-- rising arcs -- a wrong breakpoint shows up as a value above 1.
local bLo, bHi = extremes("outBounce")
A.truthy(bLo >= -1e-12 and bHi <= 1 + 1e-12, "outBounce stays within 0..1")

-- in/out mirror identity: outX(t) == 1 - inX(1-t) for the pure families.
for _, pair in ipairs({ { "inQuad", "outQuad" }, { "inCubic", "outCubic" },
                        { "inQuint", "outQuint" }, { "inSine", "outSine" },
                        { "inCirc", "outCirc" }, { "inBounce", "outBounce" } }) do
    local fin, fout = Tween.ease[pair[1]], Tween.ease[pair[2]]
    local ok = true
    for i = 1, 19 do
        local t = i / 20
        if math.abs(fout(t) - (1 - fin(1 - t))) > 1e-9 then ok = false end
    end
    A.truthy(ok, pair[2] .. " mirrors " .. pair[1])
end

--------------------------------------------------------------------------------
-- Interpolation helpers
--------------------------------------------------------------------------------

A.eq(Tween.lerp(10, 200, 0), 10, "lerp at 0")
A.eq(Tween.lerp(10, 200, 1), 200, "lerp at 1 is exact")
A.near(Tween.lerp(10, 200, 0.5), 105, 1e-12, "lerp midpoint")
-- The specific value that motivated the (1-t)*a + t*b form.
A.eq(Tween.lerp(0.1, 200, 1), 200, "lerp lands exactly on an awkward target")

-- Half-life damping: after exactly halfLife frames, half the distance is gone,
-- and splitting the step must not change the answer.
A.near(Tween.damp(0, 100, 10, 10), 50, 1e-12, "damp halves over one half-life")
local a1 = Tween.damp(0, 100, 10, 0.5)
local a2 = Tween.damp(a1, 100, 10, 0.5)
A.near(a2, Tween.damp(0, 100, 10, 1), 1e-12, "damp is step-size independent")

--------------------------------------------------------------------------------
-- Spring
--------------------------------------------------------------------------------

local sp = Tween.newSpring(0, 8)
local prev = -1
local overshot = false
local monotoneRise = true
for _ = 1, 200 do
    local v = sp:update(100, 1)
    if v > 100 + 1e-9 then overshot = true end
    if v < prev - 1e-9 then monotoneRise = false end
    prev = v
end
A.falsy(overshot, "critically damped spring never overshoots")
A.truthy(monotoneRise, "spring approach is monotone")
A.near(sp.value, 100, 1e-3, "spring converges on the target")

-- Retargeting mid-flight is the thing easing cannot do. The value must BEND, not
-- snap: momentum carries it a little further past the reversal point before the
-- velocity flips, which is exactly the behaviour an easing curve cannot produce.
local sp2 = Tween.newSpring(0, 8)
for _ = 1, 5 do sp2:update(100, 1) end
local mid, midV = sp2.value, sp2.velocity
A.truthy(mid > 0 and mid < 100, "spring is mid-flight")
A.truthy(midV > 0, "spring is still moving toward the old target")
sp2:update(-100, 1)
A.truthy(sp2.velocity < 0, "one step after retargeting, velocity has flipped")
A.truthy(math.abs(sp2.value - mid) < math.abs(midV) * 2,
    "spring position stays continuous across a retarget")
for _ = 1, 200 do sp2:update(-100, 1) end
-- near(), not eq(): a spring converges asymptotically and is the one thing in
-- this module that does NOT land exactly, because there is no last frame to
-- snap on. Tweens have a known end; springs do not.
A.near(sp2.value, -100, 1e-9, "spring settles on the retargeted value")

sp2:reset(7)
A.eq(sp2.value, 7, "spring reset sets value")
A.eq(sp2.velocity, 0, "spring reset clears velocity")

-- A spring already at rest on its target must stay put exactly.
local sp3 = Tween.newSpring(50, 8)
sp3:update(50, 1)
A.eq(sp3.value, 50, "settled spring does not jitter")

--------------------------------------------------------------------------------
-- Tweener: basic stepping
--------------------------------------------------------------------------------

Tween.reset()

local obj = { x = 0, y = 0 }
local tw = Tween.to(obj, 20, { x = 100 })
A.eq(Tween.count(), 1, "tween registers as a root")

Tween.update()
A.near(obj.x, 5, 1e-12, "linear tween after 1 of 20 frames")
for _ = 1, 9 do Tween.update() end
A.near(obj.x, 50, 1e-12, "linear tween at the halfway frame")
A.falsy(tw.done, "still running at frame 10")

for _ = 1, 10 do Tween.update() end
A.truthy(tw.done, "done on frame 20, not 21")
-- The headline guarantee: exact equality, not near().
A.eq(obj.x, 100, "completed tween lands exactly on the target")
A.eq(Tween.count(), 0, "finished tween leaves the root list")

-- Every easing must land exactly, not just linear -- this is the pairing of the
-- endpoint test above with the value-write path.
Tween.reset()
for _, name in ipairs(Tween.easeNames) do
    local o = { v = 3 }
    Tween.to(o, 7, { v = 200 }, name)
    for _ = 1, 7 do Tween.update() end
    A.eq(o.v, 200, "tween with " .. name .. " lands exactly on 200")
end

-- Multiple fields at once, and a start value that is not zero.
Tween.reset()
local multi = { x = 10, y = -20, z = 5 }
Tween.to(multi, 4, { x = 20, y = 20 })
for _ = 1, 4 do Tween.update() end
A.eq(multi.x, 20, "multi-field x")
A.eq(multi.y, 20, "multi-field y")
A.eq(multi.z, 5, "untouched field is left alone")

-- Fractional dt has to add up to the same place.
Tween.reset()
local frac = { x = 0 }
Tween.to(frac, 10, { x = 100 })
for _ = 1, 20 do Tween.update(0.5) end
A.eq(frac.x, 100, "half-frame steps still land exactly")

-- Tween.value needs no host table.
Tween.reset()
local vt = Tween.value(0, 40, 4)
Tween.update()
A.near(vt.value, 10, 1e-12, "Tween.value exposes .value")
for _ = 1, 3 do Tween.update() end
A.eq(vt.value, 40, "Tween.value lands exactly")

-- Single-field form.
Tween.reset()
local sf = { a = 1 }
Tween.field(sf, 2, "a", 9)
Tween.update(); Tween.update()
A.eq(sf.a, 9, "Tween.field lands exactly")

-- Rounding.
Tween.reset()
local rn = { x = 0 }
Tween.to(rn, 3, { x = 10 }):snap()
Tween.update()
A.eq(rn.x, math.floor(rn.x), "snap writes integers mid-flight")
Tween.update(); Tween.update()
A.eq(rn.x, 10, "snap still lands on the target")

--------------------------------------------------------------------------------
-- Tweener: callbacks
--------------------------------------------------------------------------------

Tween.reset()
local calls = 0
local updates = 0
local cb = { x = 0 }
Tween.to(cb, 3, { x = 1 })
    :onComplete(function() calls = calls + 1 end)
    :onUpdate(function() updates = updates + 1 end)
A.eq(calls, 0, "onComplete has not fired before the first update")
for _ = 1, 3 do Tween.update() end
A.eq(calls, 1, "onComplete fired once")
A.eq(updates, 3, "onUpdate fired once per frame including the last")
-- Keep pumping; a finished tween must be gone, not re-firing.
for _ = 1, 10 do Tween.update() end
A.eq(calls, 1, "onComplete still fired exactly once after more updates")
A.eq(updates, 3, "onUpdate stops once the tween is done")

-- A callback that starts another tween must not steal a frame from it.
Tween.reset()
local later = { x = 0 }
Tween.to({ q = 0 }, 1, { q = 1 }):onComplete(function()
    Tween.to(later, 2, { x = 10 })
end)
Tween.update()
A.eq(later.x, 0, "a tween born in a callback does not step on that same frame")
Tween.update()
A.near(later.x, 5, 1e-12, "it steps normally on the next frame")

--------------------------------------------------------------------------------
-- Tweener: cancel, pause, finish, restart
--------------------------------------------------------------------------------

Tween.reset()
local cancelled = 0
local cx = { x = 0 }
local ct = Tween.to(cx, 10, { x = 100 }):keep()
    :onComplete(function() cancelled = cancelled + 1 end)
for _ = 1, 5 do Tween.update() end
local atCancel = cx.x
A.near(atCancel, 50, 1e-12, "halfway before cancel")
ct:cancel()
for _ = 1, 20 do Tween.update() end
A.eq(cx.x, atCancel, "cancel freezes the value where it stood")
A.eq(cancelled, 0, "cancel does not fire onComplete")
A.truthy(ct.done, "cancelled tween reports done")
A.truthy(ct.cancelled, "cancelled tween reports cancelled")
A.eq(Tween.count(), 0, "cancelled tween leaves the root list")
-- Cancelling twice, or after completion, is a no-op rather than an error.
ct:cancel()
A.eq(cancelled, 0, "second cancel is a no-op")

Tween.reset()
local px = { x = 0 }
local pt = Tween.to(px, 10, { x = 100 })
Tween.update(); Tween.update()
pt:pause()
for _ = 1, 5 do Tween.update() end
A.near(px.x, 20, 1e-12, "paused tween does not advance")
pt:resume()
Tween.update()
A.near(px.x, 30, 1e-12, "resumed tween picks up where it left off")

Tween.reset()
local fired = 0
local fx = { x = 0 }
local ft = Tween.to(fx, 100, { x = 50 }):keep()
    :onComplete(function() fired = fired + 1 end)
Tween.update()
ft:finish()
A.eq(fx.x, 50, "finish writes the exact target")
A.eq(fired, 1, "finish fires onComplete once")
for _ = 1, 5 do Tween.update() end
A.eq(fired, 1, "finish does not double-fire on the next update")

Tween.reset()
local rfired = 0
local rx = { x = 0 }
local rt = Tween.to(rx, 4, { x = 40 }):keep()
    :onComplete(function() rfired = rfired + 1 end)
for _ = 1, 4 do Tween.update() end
A.eq(rx.x, 40, "first pass lands")
A.eq(rfired, 1, "first completion")
rt:restart()
A.eq(Tween.count(), 1, "restart re-roots the tween")
Tween.update()
-- Restart replays the recorded from -> to, so the object jumps back to the
-- start of the curve rather than sitting on the target doing nothing.
A.near(rx.x, 10, 1e-12, "restart replays from the recorded start value")
for _ = 1, 3 do Tween.update() end
A.eq(rx.x, 40, "restart lands exactly again")
A.eq(rfired, 2, "restart re-arms onComplete")

--------------------------------------------------------------------------------
-- Sequences
--------------------------------------------------------------------------------

Tween.reset()
local order = {}
local so = { x = 0 }
local seq = Tween.sequence(
    Tween.to(so, 5, { x = 10 }):onComplete(function() order[#order + 1] = "a" end),
    Tween.to(so, 5, { x = 30 }):onComplete(function() order[#order + 1] = "b" end),
    Tween.call(function() order[#order + 1] = "c" end)
):keep()
A.eq(Tween.count(), 4, "children are still listed until the first sweep")
Tween.update()
A.eq(Tween.count(), 1, "the first update sweeps adopted children out of the root list")
A.near(so.x, 2, 1e-12, "sequence drives its first member")

for _ = 1, 4 do Tween.update() end
A.eq(so.x, 10, "first member lands exactly")
A.eq(#order, 1, "only the first callback has fired")
A.eq(order[1], "a", "first member completed first")

for _ = 1, 5 do Tween.update() end
A.eq(so.x, 30, "second member lands exactly")
A.eq(#order, 3, "second member and the trailing call both fired")
A.eq(order[2], "b", "sequence order is preserved")
A.eq(order[3], "c", "Tween.call runs at its place in the sequence")
A.truthy(seq.done, "sequence completes with its last member")
-- 5 + 5 frames, finished on update 10. Not 11, not 9.
A.eq(Tween.count(), 0, "finished sequence leaves the root list")

-- The second member must start from where the first one left the object, not
-- from a value snapshotted at construction time.
Tween.reset()
local lazy = { x = 0 }
Tween.sequence(
    Tween.to(lazy, 2, { x = 100 }),
    Tween.to(lazy, 2, { x = 200 })
)
for _ = 1, 2 do Tween.update() end
A.eq(lazy.x, 100, "first leg lands")
Tween.update()
A.near(lazy.x, 150, 1e-12, "second leg starts from 100, not from 0")
Tween.update()
A.eq(lazy.x, 200, "second leg lands exactly")

-- Leftover carry: a 3-frame dt through 1-frame members must not lose time.
Tween.reset()
local carry = { x = 0 }
local carrySeq = Tween.sequence(
    Tween.to(carry, 1, { x = 1 }),
    Tween.to(carry, 1, { x = 2 }),
    Tween.to(carry, 1, { x = 3 })
):keep()
Tween.update(3)
A.truthy(carrySeq.done, "a single dt=3 update drains a 3x1-frame sequence")
A.eq(carry.x, 3, "and lands on the final target")

-- Exact total frame count over uneven members.
Tween.reset()
local total = { x = 0 }
local ts = Tween.sequence(
    Tween.to(total, 3, { x = 1 }),
    Tween.to(total, 7, { x = 2 }),
    Tween.delay(2)
):keep()
for i = 1, 11 do
    Tween.update()
    A.falsy(ts.done, "sequence still running at frame " .. i)
end
Tween.update()
A.truthy(ts.done, "12-frame sequence finishes on frame 12")

-- Cancelling a sequence stops its children too.
Tween.reset()
local cseq = { x = 0 }
local cancelSeq = Tween.sequence(
    Tween.to(cseq, 4, { x = 10 }),
    Tween.to(cseq, 4, { x = 20 })
):keep()
Tween.update(); Tween.update()
local frozen = cseq.x
cancelSeq:cancel()
for _ = 1, 20 do Tween.update() end
A.eq(cseq.x, frozen, "cancelled sequence stops writing")
A.truthy(cancelSeq.items[1].done, "child is cancelled with the parent")
A.truthy(cancelSeq.items[1].cancelled, "child reports cancelled")

--------------------------------------------------------------------------------
-- Parallel groups
--------------------------------------------------------------------------------

Tween.reset()
local pobj = { x = 0, y = 0 }
local groupDone = 0
local par = Tween.parallel(
    Tween.to(pobj, 4, { x = 100 }),
    Tween.to(pobj, 8, { y = 200 })
):keep():onComplete(function() groupDone = groupDone + 1 end)

for _ = 1, 4 do Tween.update() end
A.eq(pobj.x, 100, "short member of the group lands on time")
A.near(pobj.y, 100, 1e-12, "long member is halfway")
A.falsy(par.done, "group is not done until its slowest member is")

for _ = 1, 4 do Tween.update() end
A.eq(pobj.y, 200, "long member lands exactly")
A.truthy(par.done, "group completes with its slowest member")
A.eq(groupDone, 1, "group onComplete fired once")

-- Nesting: a group inside a sequence, driven only by the root.
Tween.reset()
local nest = { x = 0, y = 0 }
local nestSeq = Tween.sequence(
    Tween.parallel(
        Tween.to(nest, 2, { x = 10 }),
        Tween.to(nest, 2, { y = 20 })
    ),
    Tween.to(nest, 2, { x = 50 })
):keep()
-- 2 leaf tweens + the parallel + the trailing tween + the sequence.
A.eq(Tween.count(), 5, "everything is rooted until the first sweep")
for _ = 1, 4 do Tween.update() end
A.truthy(nestSeq.done, "nested sequence finishes in 4 frames")
A.eq(nest.x, 50, "nested x lands exactly")
A.eq(nest.y, 20, "nested y lands exactly")

-- Tween.chain is the sequence constructor under its other name.
A.eq(Tween.chain, Tween.sequence, "Tween.chain aliases Tween.sequence")

--------------------------------------------------------------------------------
-- Pooling
--------------------------------------------------------------------------------

Tween.reset()
A.eq(Tween.poolSize(), 0, "pool starts empty")
local po = { x = 0 }
Tween.to(po, 1, { x = 1 })
Tween.update()
A.truthy(Tween.poolSize() >= 1, "a finished fire-and-forget tween is recycled")

-- The recycled table is what the next tween gets: this is the property that
-- makes the steady state allocation-free, so pin it.
local before = Tween.poolSize()
Tween.to(po, 1, { x = 2 })
A.eq(Tween.poolSize(), before - 1, "the next tween comes out of the pool")
Tween.update()
A.eq(po.x, 2, "a recycled tween still works correctly")

-- keep() opts out, which is what makes holding a handle safe.
Tween.reset()
local kept = Tween.to({ x = 0 }, 1, { x = 1 }):keep()
Tween.update()
A.eq(Tween.poolSize(), 0, "keep() keeps the tween out of the pool")
A.truthy(kept.done, "kept tween still reports done")
kept:cancel()
A.eq(kept.cancelled, false, "cancel after completion is a no-op")

-- Recycling must not leave the previous target pinned.
Tween.reset()
local doomed = { x = 0 }
local dt2 = Tween.to(doomed, 1, { x = 1 })
Tween.update()
A.eq(dt2.obj, nil, "recycled tween drops its object reference")

-- A sequence releases its children when it completes.
Tween.reset()
Tween.sequence(
    Tween.to({ x = 0 }, 1, { x = 1 }),
    Tween.to({ x = 0 }, 1, { x = 1 })
)
Tween.update(); Tween.update()
A.truthy(Tween.poolSize() >= 3, "sequence and both children return to the pool")

--------------------------------------------------------------------------------
-- Reentrancy
--------------------------------------------------------------------------------

-- A completion callback tearing everything down is a real pattern ("run over,
-- drop the scene"), and it empties the list the driver is walking.
Tween.reset()
Tween.to({ x = 0 }, 1, { x = 1 }):onComplete(function() Tween.reset() end)
Tween.to({ x = 0 }, 5, { x = 1 })
Tween.to({ x = 0 }, 5, { x = 1 })
Tween.update()
A.eq(Tween.count(), 0, "reset from a completion callback empties the list")
Tween.update()
A.eq(Tween.count(), 0, "and the count does not go negative afterwards")
local after = { x = 0 }
Tween.to(after, 2, { x = 10 })
A.eq(Tween.count(), 1, "the driver still works after a reentrant reset")
Tween.update(); Tween.update()
A.eq(after.x, 10, "and still lands exactly")

-- A callback cancelling a sibling mid-sweep must not skip or double-step it.
Tween.reset()
local victim = { x = 0 }
local vt = Tween.to(victim, 10, { x = 100 }):keep()
Tween.to({ q = 0 }, 1, { q = 1 }):onComplete(function() vt:cancel() end)
Tween.update()
local frozenAt = victim.x
for _ = 1, 10 do Tween.update() end
A.eq(victim.x, frozenAt, "a tween cancelled from a sibling's callback stops")
A.truthy(vt.cancelled, "and reports cancelled")

--------------------------------------------------------------------------------
-- Misc API surface
--------------------------------------------------------------------------------

Tween.reset()
local so1 = Tween.to({ x = 0 }, 100, { x = 1 }):keep()
local so2 = Tween.to({ x = 0 }, 100, { x = 1 }):keep()
A.eq(Tween.count(), 2, "two roots")
Tween.stopAll()
Tween.update()
A.eq(Tween.count(), 0, "stopAll clears the root list")
A.truthy(so1.cancelled and so2.cancelled, "stopAll cancels rather than completes")

-- String easing names resolve, and a bad one is a loud error rather than a
-- silent fallback to linear.
Tween.reset()
local es = { x = 0 }
Tween.to(es, 2, { x = 10 }, "outQuad")
Tween.update(); Tween.update()
A.eq(es.x, 10, "string easing name resolves")
A.falsy(pcall(Tween.to, { x = 0 }, 2, { x = 1 }, "notAnEasing"), "unknown easing errors")

-- A non-numeric field is caught at the first step, not silently arithmetic'd.
Tween.reset()
Tween.to({ x = "nope" }, 2, { x = 1 })
A.falsy(pcall(Tween.update), "tweening a non-number field errors")

-- fromPenner adapts the SDK's four-arg signature and inherits the clamp, which
-- is what fixes the SDK's inExpo landing on 0.999.
local penner = function(t, b, c, d) return c * 2 ^ (10 * (t / d - 1)) + b - c * 0.001 end
A.near(penner(1, 0, 1, 1), 0.999, 1e-12, "the raw SDK inExpo really does stop short")
local adapted = Tween.fromPenner(penner)
A.eq(adapted(1), 1, "fromPenner lands exactly on 1")
A.eq(adapted(0), 0, "fromPenner starts exactly on 0")

-- Tween.penner returns nil under host lua, where there is no SDK; it must not
-- crash, which is the cross-runtime rule in miniature.
A.eq(Tween.penner("inQuad"), nil, "Tween.penner is nil without the SDK")

Tween.reset()
A.eq(Tween.count(), 0, "reset leaves no roots")
A.eq(Tween.poolSize(), 0, "reset empties the pool")

return true
