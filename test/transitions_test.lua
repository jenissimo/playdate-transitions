local A = require("assert")

-- The point of rule 1: with NO playdate global at all the module must still
-- load, and its whole pure half -- names, plan lookup, frame math -- must still
-- work. Everything that would touch the SDK has to be an inert no-op instead of
-- a nil index. So the require happens with playdate deliberately removed.
local saved_playdate = rawget(_G, "playdate")
_G.playdate = nil
package.loaded["transitions"] = nil
_G.Transitions = nil
local T = require("transitions")

A.truthy(T ~= nil, "transitions loads under host lua with no playdate global")
A.eq(T.active, false, "nothing is transitioning at import")

-- ---- names / descriptions / implementations must agree ---------------------
-- Three lists that are edited by hand in three places; the only thing keeping
-- them in step is this loop.
A.eq(#T.names, 23, "23 effects ship (21 original + Paw Walk + Blink)")

local seen = {}
for _, n in ipairs(T.names) do
    A.falsy(seen[n], "effect name '" .. tostring(n) .. "' appears once")
    seen[n] = true
    A.truthy(type(T.descriptions[n]) == "string" and #T.descriptions[n] > 0,
        "'" .. n .. "' has a description")
    A.truthy(T.hasEffect(n), "'" .. n .. "' has an implementation")
end
for n in pairs(T.descriptions) do
    A.truthy(seen[n], "described effect '" .. n .. "' is also listed in names")
end

-- The two effects merged in from the shipping game are present under the names
-- the README will advertise.
A.truthy(seen["Paw Walk"], "Paw Walk survived the merge")
A.truthy(seen["Blink"], "Blink survived the merge")

-- ---- name canonicalisation -------------------------------------------------
-- Plan tables are written by hand, so the lookup forgives case and spacing;
-- "paw" is kept as an alias because the downstream game already spells it that way.
A.eq(T.canonical("Paw Walk"), "Paw Walk", "exact names resolve")
A.eq(T.canonical("paw walk"), "Paw Walk", "case is forgiven")
A.eq(T.canonical("pawwalk"), "Paw Walk", "spacing is forgiven")
A.eq(T.canonical("paw"), "Paw Walk", "'paw' is an alias for Paw Walk")
A.eq(T.canonical("blink"), "Blink", "'blink' resolves")
A.eq(T.canonical("Clock Wipe"), "Clock Wipe", "multi-word names resolve")
A.eq(T.canonical("Nonsense"), nil, "an unknown name resolves to nil")
A.eq(T.canonical(nil), nil, "a nil name resolves to nil, not an error")
A.eq(T.canonical(42), nil, "a non-string name resolves to nil, not an error")
A.falsy(T.hasEffect("Nonsense"), "hasEffect is false for an unknown name")

-- ---- direction -------------------------------------------------------------
-- Every effect branches on `d == "fwd"` / `d ~= "back"`, so exactly one value
-- may mean backwards and everything else must mean forwards.
A.eq(T.normalizeDir("fwd"), "fwd", "fwd stays fwd")
A.eq(T.normalizeDir("back"), "back", "back stays back")
A.eq(T.normalizeDir(nil), "fwd", "no direction means forwards")
A.eq(T.normalizeDir("backwards"), "fwd", "only exactly 'back' is backwards")

-- ---- frame / progress math -------------------------------------------------
-- The wipe must reach t == 1 on its LAST drawn frame. With frame/frames it
-- never does, and the final couple of frames render an unfinished picture that
-- the driver then snaps away.
A.eq(T.progress(0, 24), 0, "the first frame is t = 0")
A.eq(T.progress(23, 24), 1, "the last frame of 24 is exactly t = 1")
A.near(T.progress(12, 24), 12 / 23, 1e-9, "the middle interpolates linearly")
A.eq(T.progress(99, 24), 1, "overrunning clamps to 1 instead of overshooting")
A.eq(T.progress(-5, 24), 0, "a negative frame clamps to 0")
A.eq(T.progress(0, 1), 0, "a one-frame transition starts at 0")
A.eq(T.progress(1, 1), 1, "a one-frame transition does not divide by zero")
A.eq(T.progress(0, 0), 0, "a zero-frame transition does not divide by zero")
A.eq(T.progress(23), 1, "frames defaults to the documented 24")
-- Monotonic across a whole run, which is what stops an effect from stuttering.
local prev_t = -1
for f = 0, 15 do
    local t = T.progress(f, 16)
    A.truthy(t >= prev_t, "progress never goes backwards (frame " .. f .. ")")
    prev_t = t
end
A.eq(prev_t, 1, "a 16-frame run finishes at exactly 1")

-- ---- the scene-hop plan ----------------------------------------------------
-- The library ships the mechanism with no policy: an unconfigured consumer gets
-- silence, never a surprise wipe.
A.eq(next(T.PLAN), nil, "no plan is registered by default")
A.eq(T.forHop("menu>rules"), nil, "with no plan every hop is bare")

local plan = {
    ["menu>rules"]  = { "paw", "fwd", 16 },
    ["rules>menu"]  = { "paw", "back", 16 },
    ["menu>run"]    = { "blink", "fwd", 20 },
    ["title>menu"]  = { "Slide" },              -- direction and frames optional
}
local bare = {
    ["run>loading"] = "the loading scene spends its whole frame budget stepping "
                   .. "a coroutine generator; a transition's extra offscreen "
                   .. "render plus two blits overruns the frame and trips the "
                   .. "watchdog",
    ["loading>game"] = "the destination already plays its own entry animation",
}
T.setPlan(plan, bare)

local e, d, n = T.forHop("menu>rules")
A.eq(e, "Paw Walk", "a plan entry resolves its alias to the canonical name")
A.eq(d, "fwd", "a plan entry keeps its direction")
A.eq(n, 16, "a plan entry keeps its frame count")

local e2, d2, n2 = T.forHop("title>menu")
A.eq(e2, "Slide", "an entry may give just an effect")
A.eq(d2, "fwd", "a missing direction defaults to forwards")
A.eq(n2, 24, "a missing frame count defaults to 24")

-- Total function: unknown, bare and malformed hops are all silence, so a call
-- site can name its hop without guarding.
A.eq(T.forHop("nonsense>hop"), nil, "an unknown hop is silent")
A.eq(T.forHop(""), nil, "an empty hop is silent")
A.eq(T.forHop("run>loading"), nil, "a bare hop is silent")
A.eq(T.forHop("loading>game"), nil, "the second bare hop is silent too")
A.eq(T.for_hop("menu>run"), "Blink", "the for_hop spelling still works")

-- The bare list is prose, and it is meant to be read.
A.truthy(#T.bareReason("run>loading") > 20, "a bare hop keeps its stated reason")
A.eq(T.bareReason("menu>rules"), nil, "a planned hop has no bare reason")

-- ---- setPlan rejects the mistakes that would otherwise ship silently -------
-- A typo'd effect name is the dangerous one: without this check the scene
-- change simply does nothing, months later, on hardware.
A.falsy(pcall(T.setPlan, { ["a>b"] = { "Pow Walk", "fwd", 12 } }),
    "an effect name that does not exist is refused")
A.falsy(pcall(T.setPlan, { ["a-b"] = { "Slide", "fwd", 12 } }),
    "a key that is not 'from>to' is refused")
A.falsy(pcall(T.setPlan, { ["a>b"] = "Slide" }),
    "an entry that is not a table is refused")
A.falsy(pcall(T.setPlan, { ["a>b"] = { "Slide", "fwd", 0 } }),
    "a zero-frame transition is refused")
-- ...and the invariant that gives the bare list its teeth: a hop cannot be
-- planned and deliberately-bare at the same time.
A.falsy(pcall(T.setPlan, { ["a>b"] = { "Slide" } }, { ["a>b"] = "stays bare" }),
    "a hop in both the plan and the bare list is a contradiction")
-- A refused setPlan must not have half-applied itself.
A.eq(T.forHop("menu>rules"), "Paw Walk", "a rejected plan leaves the old one intact")

A.truthy(pcall(T.setPlan), "setPlan with no arguments clears the plan")
A.eq(next(T.PLAN), nil, "...and the plan really is empty afterwards")

-- ---- headless safety -------------------------------------------------------
-- Every device entry point has to be callable with no SDK present, because the
-- host test suite is where the rest of the game's logic is exercised and it
-- must not have to stub graphics to do it.
A.eq(T.load(), nil, "headless load is a no-op")
A.eq(T.start("Slide", "fwd", 24), nil, "headless start is a no-op")
A.eq(T.play("menu>rules"), nil, "headless play is a no-op")
A.eq(T.active, false, "nothing goes active without a device")
A.falsy(T._ready, "no buffers are ever allocated without a device")
local ran = false
T.draw(function() ran = true end)
A.truthy(ran, "draw still calls the scene function when inert")
ran = false
T.wrap(function() ran = true end)
A.truthy(ran, "the wrap spelling still calls the scene function")

-- ---- image path ------------------------------------------------------------
-- The paw artwork is looked up by path at first use, so a consumer who vendored
-- this repo elsewhere must be able to repoint it. Trailing slash is optional.
A.eq(T.setImagePath("juice/images"), "juice/images/", "a missing trailing slash is added")
A.eq(T.setImagePath("art/"), "art/", "an explicit trailing slash is kept")
A.eq(T.setImagePath(nil), "images/", "nil restores the shipped default")

-- ---- frame accessors -------------------------------------------------------
A.eq(T.getFrames(), 24, "the default duration is the documented 24 frames")
T.setFrames(12)
A.eq(T.getFrames(), 12, "setFrames takes")
T.setFrames(24)

-- ---- device section: frozen incoming capture -------------------------------
-- FREEZES_INCOMING is the driver's whole cost model: the destination scene's
-- draw runs into the offscreen buffer exactly once, on the frame the wipe
-- starts, and every later frame of the wipe only composites that still
-- bitmap -- rerunning the destination scene for every frame would steal frame
-- budget for no visible benefit. A fake graphics table stands in for the SDK
-- the same way the parity test above does; every method Transitions.draw
-- touches while active has to exist, even as a no-op.
package.loaded["transitions"] = nil
_G.Transitions = nil
local image = {
    draw = function() end,
    drawScaled = function() end,
    getSize = function() return 16, 16 end,
    rotatedImage = function(self) return self end,
}
local fake_gfx = {
    kColorBlack = 0,
    kColorWhite = 1,
    kDrawModeCopy = 0,
    kDrawModeFillWhite = 1,
    image = { new = function() return image end },
    getDisplayImage = function() return image end,
    pushContext = function() end,
    popContext = function() end,
    clear = function() end,
    setColor = function() end,
    fillRect = function() end,
    setStencilImage = function() end,
    clearStencil = function() end,
    setImageDrawMode = function() end,
}
_G.playdate = { graphics = fake_gfx }
local DeviceT = require("transitions")
A.eq(DeviceT.FREEZES_INCOMING, true, "the driver declares it freezes the incoming snapshot")

local draws = 0
DeviceT.start("blink", "fwd", 4)
for _ = 1, 4 do
    DeviceT.draw(function() draws = draws + 1 end)
end
A.eq(draws, 1, "the wrapped scene draw runs exactly once across a whole transition")
DeviceT.draw(function() draws = draws + 1 end)
A.eq(draws, 2, "the scene draw resumes on the frame after the transition completes")
A.eq(DeviceT.active, false, "the transition has released its snapshot by then")

-- ---- device section: split update()/draw() contract ------------------------
-- Transitions.draw/wrap(updateFn, drawFn) is the contract that fixes
-- FREEZES_INCOMING's other half: a destination scene that reads input and
-- ticks timers inside updateFn must not go dead for the whole wipe just
-- because its draw is (rightly) only captured once.
A.eq(Transitions.SPLITS_UPDATE_FROM_DRAW, true,
    "the driver declares updateFn runs every frame of a split-form wipe")

local updates, splitDraws = 0, 0
DeviceT.start("blink", "fwd", 4)
for _ = 1, 4 do
    DeviceT.draw(function() updates = updates + 1 end, function() splitDraws = splitDraws + 1 end)
end
A.eq(updates, 4, "updateFn runs on every single frame of a 4-frame transition")
A.eq(splitDraws, 1, "drawFn is still captured exactly once across the whole transition")
DeviceT.draw(function() updates = updates + 1 end, function() splitDraws = splitDraws + 1 end)
A.eq(updates, 5, "updateFn keeps running on the frame the transition completes on")
A.eq(splitDraws, 2, "drawFn resumes normally once the transition is over")
A.eq(DeviceT.active, false, "the transition has released its snapshot by then")

-- Outside any transition, both halves run every frame -- same as an ordinary
-- combined call would have.
local idleUpdates, idleDraws = 0, 0
for _ = 1, 3 do
    DeviceT.draw(function() idleUpdates = idleUpdates + 1 end, function() idleDraws = idleDraws + 1 end)
end
A.eq(idleUpdates, 3, "outside a transition updateFn runs every frame")
A.eq(idleDraws, 3, "outside a transition drawFn runs every frame too")

-- Legacy callers are unaffected: passing only one function is still the
-- byte-for-byte original freeze-everything behaviour, not the split one.
local legacyCalls = 0
DeviceT.start("blink", "fwd", 4)
for _ = 1, 4 do
    DeviceT.draw(function() legacyCalls = legacyCalls + 1 end)
end
A.eq(legacyCalls, 1, "a single combined function is still called exactly once across a transition")
DeviceT.draw(function() legacyCalls = legacyCalls + 1 end)
A.eq(legacyCalls, 2, "...and resumes normally once the transition ends")

-- Headless safety extends to the split form too: no SDK, no crash, and both
-- halves still run since there is nothing to freeze without a device.
package.loaded["transitions"] = nil
_G.Transitions = nil
_G.playdate = nil
local HeadlessT = require("transitions")
local ranUpdate, ranDraw = false, false
HeadlessT.draw(function() ranUpdate = true end, function() ranDraw = true end)
A.truthy(ranUpdate, "headless split draw calls updateFn when inert")
A.truthy(ranDraw, "headless split draw calls drawFn when inert")

package.loaded["transitions"] = nil
_G.Transitions = nil

_G.playdate = saved_playdate
return true
