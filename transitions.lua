-- playdate-juice: transitions
--
-- Scene-change wipes for Playdate. 23 effects, all direction-aware, all driven
-- by the same two calls: start one when you swap scenes, wrap your per-frame
-- draw. The wipe composites a snapshot of the OUTGOING screen over the incoming
-- scene, which keeps the consumer's scene code completely unaware of it.
--
-- Two things about this module are not obvious and are the reason it looks the
-- way it does:
--
-- 1. NOTHING HERE TOUCHES THE SDK AT LOAD TIME. The two full-screen buffers are
--    allocated on the first Transitions.start (or an explicit Transitions.load),
--    and the paw artwork is only read the first time the paw effect actually
--    runs. A consumer who imports this file and never transitions pays nothing,
--    and `require("transitions")` under host lua -- with no `playdate` global at
--    all -- succeeds, which is what makes the pure half testable.
--
-- 2. A TRANSITION IS EXPENSIVE, SO SOME SCENE HOPS MUST STAY BARE. Every frame
--    of a transition costs a full offscreen render of the incoming scene plus
--    two full-screen blits. A scene that already spends its frame budget on real
--    work -- a coroutine level generator is the case this was learned on --
--    cannot also carry that; overrunning the frame there trips the watchdog and
--    reboots the console. Bare hops also matter for taste: a wipe on a hop that
--    repeats every 60 seconds of play stops reading as punctuation and starts
--    reading as lag, and a hop whose destination already plays its own entry
--    animation does not want a second one in front of it.
--
--    That is what setPlan(plan, bare) is for. The plan maps "from>to" to an
--    effect; the bare table records, in prose, WHY a hop deliberately has none.
--    setPlan enforces that no hop appears in both, so "we decided this stays
--    bare" survives as a checked invariant instead of a comment somebody edits
--    past. The policy itself -- which of YOUR scenes get which effect -- stays
--    in your game; this module only ships the mechanism.
--
-- One effect, Paw Walk, needs artwork: images/paw_print.png and
-- images/paw_plate.png, which ship next to this file. Copy the `images` folder
-- along with transitions.lua, or -- if it lands somewhere else in your source
-- tree -- call Transitions.setImagePath("your/folder/") once at boot. Either
-- file being absent costs you the stamps, not the transition: the walk still
-- wipes, just unstamped, and no other effect reads a file at all.
--
-- Ported and merged from github.com/jenissimo/playdate-transitions (MIT); the
-- Paw Walk and Blink effects come from Nyandoku, which shipped this driver.
Transitions = Transitions or {}

local pd <const> = rawget(_G, "playdate")
local gfx <const> = pd and pd.graphics

local W <const> = 400
local H <const> = 240
local sin <const> = math.sin
local cos <const> = math.cos
local sqrt <const> = math.sqrt
local floor <const> = math.floor
local ceil <const> = math.ceil
local max <const> = math.max
local min <const> = math.min
local pi <const> = math.pi
local rad <const> = math.rad
local unpack <const> = table.unpack

-- ============================================================== pure section
-- Everything down to "device section" is plain Lua: no SDK, no allocation. This
-- is the half the host tests cover.

Transitions.active = false
Transitions._ready = false      -- true once the buffers exist; see load()

Transitions.names = {
    "Slide", "Fade", "Dissolve", "Circle", "Diamonds",
    "Diamond Wave", "Triangles", "Bubbles", "Blinds", "Clock Wipe",
    "Wave Wipe", "Interleave", "Dither Bands", "Spiral", "Wind",
    "Melt", "Shatter", "Scanline", "Pixel Shift", "Hexagons", "Diagonal",
    "Paw Walk", "Blink",
}

Transitions.descriptions = {
    ["Slide"] = "Horizontal push slide",
    ["Fade"] = "Dither fade through black",
    ["Dissolve"] = "Bayer crossfade",
    ["Circle"] = "Circular iris reveal",
    ["Diamonds"] = "Diagonal diamond cascade",
    ["Diamond Wave"] = "Column wave with bounce",
    ["Triangles"] = "Triangle mosaic with pop",
    ["Bubbles"] = "Rising / falling bubbles",
    ["Blinds"] = "Horizontal blinds",
    ["Clock Wipe"] = "Radial clock sweep",
    ["Wave Wipe"] = "Flowing sine wave",
    ["Interleave"] = "Alternating band zip",
    ["Dither Bands"] = "Cascading dither bands",
    ["Spiral"] = "Archimedean spiral",
    ["Wind"] = "Turbulent pixel erosion",
    ["Melt"] = "Dripping melt with gravity",
    ["Shatter"] = "Falling broken pieces",
    ["Scanline"] = "CRT beam sweep",
    ["Pixel Shift"] = "VHS tracking glitch",
    ["Hexagons"] = "Honeycomb cell reveal",
    ["Diagonal"] = "Diagonal split / merge",
    ["Paw Walk"] = "Cat paws walk the page across",
    ["Blink"] = "Eyelids close and open",
}

-- Effect names are display strings with spaces and capitals, which is a poor
-- thing to have to type in a plan table. Every lookup goes through canonical(),
-- so "Paw Walk", "paw walk", "pawwalk" and "paw" all name the same effect.
local ALIASES <const> = { paw = "Paw Walk" }

-- Declared here, far above the effects that fill it, so that hasEffect() below
-- closes over the real table: a `local` is only in scope from its declaration
-- onward, and a second `local fx` further down would leave this one empty and
-- every name looking unimplemented.
local fx = {}

local canon_by_key = {}
for _, n in ipairs(Transitions.names) do
    canon_by_key[n:lower():gsub("%s+", "")] = n
end
for k, n in pairs(ALIASES) do canon_by_key[k] = n end

-- Returns the canonical effect name, or nil if nothing by that name exists.
function Transitions.canonical(name)
    if type(name) ~= "string" then return nil end
    return canon_by_key[name:lower():gsub("%s+", "")]
end

-- True only if the name resolves AND something down there draws it.
function Transitions.hasEffect(n)
    local c = Transitions.canonical(n)
    return c ~= nil and fx[c] ~= nil
end

-- Anything that is not exactly "back" walks forward. Kept as one function so
-- every effect agrees on what a direction is, including the ones a consumer adds.
function Transitions.normalizeDir(dir)
    return dir == "back" and "back" or "fwd"
end

-- Frame -> 0..1. The last frame must land exactly on 1, hence frames-1: with a
-- plain frame/frames the wipe never finishes and the final state is only ever
-- reached by the driver giving up. frames <= 1 is a single-frame cut.
function Transitions.progress(frame, frames)
    frames = frames or 24
    if frame < 0 then frame = 0 end
    local span = frames - 1
    if span < 1 then span = 1 end
    local t = frame / span
    return t > 1 and 1 or t
end

-- ---- scene-hop plan --------------------------------------------------------
-- Empty by default: the library has no opinion about your scenes. Call setPlan
-- once at boot with your own tables.

Transitions.PLAN = {}
Transitions.BARE = {}

-- plan: { ["from>to"] = { effect, dir, frames }, ... }
-- bare: { ["from>to"] = "why this hop deliberately has no transition", ... }
--
-- Both are validated here rather than at the call site, because a typo'd effect
-- name would otherwise surface as a scene change that silently does nothing --
-- months later, on hardware. A hop listed in both tables is a contradiction and
-- is refused outright: the bare list only means something if it is honoured.
function Transitions.setPlan(plan, bare)
    plan = plan or {}
    bare = bare or {}
    local resolved = {}
    for hop, e in pairs(plan) do
        if type(hop) ~= "string" or not hop:find(">", 1, true) then
            error("transitions: plan key '" .. tostring(hop) .. "' is not 'from>to'", 2)
        end
        if type(e) ~= "table" then
            error("transitions: plan entry '" .. hop .. "' is not { effect, dir, frames }", 2)
        end
        local effect = Transitions.canonical(e[1])
        if not effect or not Transitions.hasEffect(effect) then
            error("transitions: plan entry '" .. hop .. "' names no such effect: "
                .. tostring(e[1]), 2)
        end
        local frames = e[3] or 24
        if type(frames) ~= "number" or frames < 1 then
            error("transitions: plan entry '" .. hop .. "' has a bad frame count", 2)
        end
        if bare[hop] then
            error("transitions: hop '" .. hop .. "' is in both the plan and the "
                .. "bare list -- decide which", 2)
        end
        resolved[hop] = { effect, Transitions.normalizeDir(e[2]), frames }
    end
    Transitions.PLAN = resolved
    Transitions.BARE = bare
    return Transitions.PLAN
end

-- Returns effect, dir, frames -- or nil when the hop is bare or unknown. Total
-- by design: a call site can always name its hop without guarding first.
function Transitions.forHop(hop)
    local e = Transitions.PLAN[hop]
    if not e then return nil end
    return e[1], e[2], e[3]
end

-- The prose reason a hop is bare, for tests and for the next reader.
function Transitions.bareReason(hop)
    return Transitions.BARE[hop]
end

-- ---- easing ----------------------------------------------------------------

local function easeIn(t) return t * t * t end
local function easeOut(t) return 1 - (1 - t) ^ 3 end
local function easeIO(t)
    if t < 0.5 then return 4 * t * t * t
    else return 1 - (-2 * t + 2) ^ 3 / 2 end
end
local function easeBack(t)
    local c1, c3 = 2.2, 3.2
    return 1 + c3 * (t - 1) ^ 3 + c1 * (t - 1) ^ 2
end
local function clamp01(v) return v < 0 and 0 or (v > 1 and 1 or v) end

-- ============================================================ device section
-- From here down every function assumes it is being called from inside
-- Transitions.draw, which only runs when `gfx` exists and the buffers are up.

local buf, stencil, prev
local name, dir, frame, frames

-- Where the paw artwork lives, WITHOUT the .png -- that is how the Playdate
-- image loader wants it, and it is also what lets pdc's .pdi swap in. A
-- consumer who vendored this repo somewhere else (or renamed the folder) calls
-- setImagePath("juice/images/") once before the first paw transition.
local image_path = "images/"

-- nil = not looked for yet, false = looked and unavailable, true = loaded.
local paw_state = nil
local paw_ink, paw_plate            -- pointing right (the "fwd" walk)
local paw_ink_b, paw_plate_b        -- ...and the 180-degree trail for "back"
local ink_w, ink_h, plate_w, plate_h = 0, 0, 0, 0

function Transitions.setImagePath(prefix)
    prefix = prefix or "images/"
    if prefix ~= "" and prefix:sub(-1) ~= "/" then prefix = prefix .. "/" end
    if prefix ~= image_path then
        image_path = prefix
        paw_state = nil                 -- look again, at the new location
        paw_ink, paw_plate, paw_ink_b, paw_plate_b = nil, nil, nil, nil
    end
    return image_path
end

-- Allocates the two full-screen buffers. Idempotent, and called for you by
-- start(); call it yourself at boot only if you would rather pay the two
-- allocations then than on the first scene change. `opts.imagePath` is a
-- convenience for setImagePath.
function Transitions.load(opts)
    if opts and opts.imagePath then Transitions.setImagePath(opts.imagePath) end
    if not gfx then return end
    buf = buf or gfx.image.new(W, H)
    stencil = stencil or gfx.image.new(W, H, gfx.kColorBlack)
    Transitions._ready = true
end

-- The paw stamps, read on first use and never again. A missing file must
-- DEGRADE, not crash: gfx.image.new returns nil for a bad path, but it is
-- wrapped anyway because a consumer's asset folder is outside this module's
-- control and a failed decode must not take a scene change down with it. With
-- no artwork the paw effect still runs -- as a plain vertical wipe, unstamped.
local function load_paw_assets()
    if paw_state ~= nil then return paw_state end
    paw_state = false
    if not gfx then return false end

    local ok, ink = pcall(gfx.image.new, image_path .. "paw_print")
    if not ok or not ink then
        print("transitions: no " .. image_path .. "paw_print -- Paw Walk runs unstamped")
        return false
    end
    paw_ink = ink
    ink_w, ink_h = ink:getSize()
    -- 180 is the one rotation that does not resize the image, and for a shape
    -- symmetric about its walk axis it is exactly a mirror.
    paw_ink_b = ink:rotatedImage(180)

    local ok2, plate = pcall(gfx.image.new, image_path .. "paw_plate")
    if ok2 and plate then
        paw_plate = plate
        plate_w, plate_h = plate:getSize()
        paw_plate_b = plate:rotatedImage(180)
    end
    paw_state = true
    return true
end

-- Draws `cur` over `prev` wherever mask_fn paints white.
local function stencilDraw(p, c, mask_fn)
    gfx.pushContext(stencil)
    gfx.clear(gfx.kColorBlack)
    gfx.setColor(gfx.kColorWhite)
    mask_fn()
    gfx.popContext()
    p:draw(0, 0)
    gfx.setStencilImage(stencil)
    c:draw(0, 0)
    gfx.clearStencil()
end

-- ---- effects ---------------------------------------------------------------
-- Signature is always (t, prevImage, curImage, dir) with t in 0..1.
-- (`fx` itself is declared up in the pure section -- see the note there.)

fx["Slide"] = function(t, p, c, d)
    t = easeIO(t)
    local o = floor(t * W)
    if d == "fwd" then p:draw(-o, 0); c:draw(W - o, 0)
    else p:draw(o, 0); c:draw(-W + o, 0) end
end

fx["Fade"] = function(t, p, c, d)
    gfx.clear(gfx.kColorBlack)
    if t < 0.5 then
        p:drawFaded(0, 0, 1 - easeIn(t * 2), gfx.image.kDitherTypeBayer8x8)
    else
        c:drawFaded(0, 0, easeOut((t - 0.5) * 2), gfx.image.kDitherTypeBayer8x8)
    end
end

fx["Dissolve"] = function(t, p, c, d)
    t = easeIO(t)
    local dither = d == "fwd" and gfx.image.kDitherTypeBayer4x4 or gfx.image.kDitherTypeBayer8x8
    c:draw(0, 0)
    p:drawFaded(0, 0, 1 - t, dither)
end

fx["Circle"] = function(t, p, c, d)
    t = easeOut(t)
    stencilDraw(p, c, function()
        if d == "fwd" then
            gfx.fillCircleAtPoint(W / 2, H / 2, floor(t * 290))
        else
            gfx.fillRect(0, 0, W, H)
            gfx.setColor(gfx.kColorBlack)
            gfx.fillCircleAtPoint(W / 2, H / 2, floor((1 - t) * 290))
            gfx.setColor(gfx.kColorWhite)
        end
    end)
end

fx["Diamonds"] = function(t, p, c, d)
    t = easeOut(t)
    local nc, nr = 8, 5
    local cw, ch = W / nc, H / nr
    local halfD = (cw + ch) / 2 * 1.1
    stencilDraw(p, c, function()
        for r = 0, nr - 1 do
            for col = 0, nc - 1 do
                local dl = d == "fwd"
                    and (r + col) / (nr + nc - 2)
                    or ((nr - 1 - r) + (nc - 1 - col)) / (nr + nc - 2)
                local lt = clamp01((t - dl * 0.4) / 0.6)
                if lt > 0 then
                    local cx, cy = col * cw + cw / 2, r * ch + ch / 2
                    local s = lt * halfD
                    gfx.fillPolygon(cx, cy - s, cx + s, cy, cx, cy + s, cx - s, cy)
                end
            end
        end
    end)
end

fx["Diamond Wave"] = function(t, p, c, d)
    local nc, nr = 10, 6
    local cw, ch = W / nc, H / nr
    local halfD = (cw + ch) / 2 * 1.15
    stencilDraw(p, c, function()
        for r = 0, nr - 1 do
            for col = 0, nc - 1 do
                local waveDl = (d == "fwd" and col or (nc - 1 - col)) / (nc - 1)
                waveDl = clamp01(waveDl + sin(r * 1.2) * 0.06)
                local lt = clamp01((t - waveDl * 0.65) / 0.35)
                if lt > 0 then
                    local s = easeBack(lt) * (1 + sin(lt * pi) * 0.15)
                    local cx, cy = col * cw + cw / 2, r * ch + ch / 2
                    local half = s * halfD
                    gfx.fillPolygon(cx, cy - half, cx + half, cy, cx, cy + half, cx - half, cy)
                end
            end
        end
    end)
end

fx["Triangles"] = function(t, p, c, d)
    local tw, th = 58, 50
    local nC = ceil(W / tw) + 1
    local nR = ceil(H / th) + 1
    stencilDraw(p, c, function()
        for r = 0, nR - 1 do
            for col = 0, nC * 2 do
                local up = (col + r) % 2 == 0
                local bx, by = col * tw / 2, r * th
                local dl = d == "fwd"
                    and (col * 0.3 + r * 0.7) / (nC * 2 + nR)
                    or ((nC * 2 - col) * 0.3 + (nR - r) * 0.7) / (nC * 2 + nR)
                local lt = clamp01((t - dl * 0.7) / 0.3)
                if lt > 0 then
                    local s = easeOut(lt)
                    local cx, cy = bx, by + th / 2
                    local hw, hh = s * tw / 2, s * th / 2
                    if up then
                        gfx.fillPolygon(cx, cy - hh, cx - hw, cy + hh, cx + hw, cy + hh)
                    else
                        gfx.fillPolygon(cx, cy + hh, cx - hw, cy - hh, cx + hw, cy - hh)
                    end
                end
            end
        end
    end)
end

local bSeeds <const> = {
    {x=25,r=50,d=0.00,w=3.0},{x=75,r=40,d=0.04,w=2.5},
    {x=120,r=55,d=0.02,w=4.0},{x=165,r=38,d=0.08,w=2.0},
    {x=205,r=45,d=0.03,w=3.5},{x=250,r=52,d=0.01,w=2.8},
    {x=295,r=42,d=0.06,w=3.2},{x=335,r=58,d=0.04,w=2.3},
    {x=375,r=36,d=0.07,w=4.2},{x=50,r=32,d=0.10,w=2.0},
    {x=100,r=35,d=0.12,w=3.0},{x=145,r=30,d=0.14,w=2.5},
    {x=190,r=48,d=0.09,w=3.8},{x=235,r=33,d=0.13,w=2.2},
    {x=280,r=46,d=0.11,w=3.5},{x=320,r=34,d=0.15,w=2.8},
    {x=360,r=40,d=0.05,w=3.0},{x=395,r=44,d=0.16,w=2.6},
}

fx["Bubbles"] = function(t, p, c, d)
    local et = easeIO(t)
    local goUp = (d == "fwd")
    stencilDraw(p, c, function()
        if goUp then
            local waterY = H + 30 - et * (H + 60)
            if waterY < H then
                gfx.fillRect(0, max(0, floor(waterY)), W, H)
            end
            for _, b in ipairs(bSeeds) do
                local lt = max(0, (t - b.d) / (1 - b.d))
                if lt > 0 then
                    local e = easeOut(lt)
                    local br = e * b.r * 0.7
                    local bubY = waterY - e * 35 - sin(lt * b.w * pi) * 12
                    local wx = sin(lt * b.w * pi * 2) * 10
                    gfx.fillCircleAtPoint(b.x + wx, bubY, br)
                    gfx.fillCircleAtPoint(b.x + wx - 8, bubY + br * 0.5, br * 0.3)
                end
            end
        else
            local waterY = -30 + et * (H + 60)
            if waterY > 0 then
                gfx.fillRect(0, 0, W, min(H, floor(waterY)))
            end
            for _, b in ipairs(bSeeds) do
                local lt = max(0, (t - b.d) / (1 - b.d))
                if lt > 0 then
                    local e = easeOut(lt)
                    local br = e * b.r * 0.7
                    local bubY = waterY + e * 35 + sin(lt * b.w * pi) * 12
                    local wx = sin(lt * b.w * pi * 2) * 10
                    gfx.fillCircleAtPoint(b.x + wx, bubY, br)
                    gfx.fillCircleAtPoint(b.x + wx + 8, bubY - br * 0.5, br * 0.3)
                end
            end
        end
    end)
end

fx["Blinds"] = function(t, p, c, d)
    local n = 12
    local bh = H / n
    stencilDraw(p, c, function()
        for i = 0, n - 1 do
            local dl = d == "fwd" and i * 0.04 or (n - 1 - i) * 0.04
            local lt = easeOut(clamp01((t - dl) / max(0.01, 1 - dl)))
            gfx.fillRect(0, floor(i * bh), W, ceil(lt * bh))
        end
    end)
end

fx["Clock Wipe"] = function(t, p, c, d)
    t = easeIO(t)
    local sw = t * 360
    stencilDraw(p, c, function()
        if sw > 0 then
            local cx, cy, r = W / 2, H / 2, 350
            local steps = max(1, floor(sw / 8))
            local pts = {cx, cy}
            for i = 0, steps do
                local deg = -90 + (d == "fwd" and 1 or -1) * sw * i / steps
                local a = rad(deg)
                pts[#pts + 1] = cx + r * cos(a)
                pts[#pts + 1] = cy + r * sin(a)
            end
            if #pts >= 6 then gfx.fillPolygon(unpack(pts)) end
        end
    end)
end

fx["Wave Wipe"] = function(t, p, c, d)
    t = easeIO(t)
    local sweep = -100 + t * (W + 200)
    stencilDraw(p, c, function()
        for y = 0, H - 1, 3 do
            local wave = sin(y * 0.028 + t * 5) * 60 + sin(y * 0.065 + t * 8) * 30
            local wx = sweep + wave
            if d == "fwd" then
                if wx > 0 then gfx.fillRect(0, y, min(W, floor(wx)), 3) end
            else
                local startX = max(0, floor(W - wx))
                if startX < W then gfx.fillRect(startX, y, W - startX, 3) end
            end
        end
    end)
end

fx["Interleave"] = function(t, p, c, d)
    local n = 12
    local bh = ceil(H / n)
    stencilDraw(p, c, function()
        for i = 0, n - 1 do
            local dl = i * 0.025
            local lt = easeIO(clamp01((t - dl) / max(0.01, 1 - dl)))
            local y = i * bh
            local offset = floor(lt * W)
            if (i % 2 == 0) == (d == "fwd") then
                gfx.fillRect(0, y, offset, bh)
            else
                gfx.fillRect(W - offset, y, offset, bh)
            end
        end
    end)
end

fx["Dither Bands"] = function(t, p, c, d)
    p:draw(0, 0)
    local n = 8
    local bh = ceil(H / n)
    for i = 0, n - 1 do
        local dl = d == "fwd" and i * 0.06 or (n - 1 - i) * 0.06
        local lt = easeOut(clamp01((t - dl) / max(0.01, 1 - dl)))
        if lt > 0.01 then
            gfx.setClipRect(0, i * bh, W, bh)
            if lt >= 0.97 then
                c:draw(0, 0)
            else
                c:drawFaded(0, 0, lt, gfx.image.kDitherTypeBayer8x8)
            end
            gfx.clearClipRect()
        end
    end
end

fx["Spiral"] = function(t, p, c, d)
    t = easeOut(t)
    stencilDraw(p, c, function()
        local cx, cy = W / 2, H / 2
        local maxA = 3 * 2 * pi
        local curA = t * maxA
        local rPerRad = 300 / maxA
        local sgn = d == "fwd" and 1 or -1
        for angle = 0, curA, 0.13 do
            local r = angle * rPerRad
            gfx.fillCircleAtPoint(floor(cx + cos(angle * sgn) * r), floor(cy + sin(angle * sgn) * r), 56)
        end
        if t > 0.85 then gfx.fillRect(0, 0, W, H) end
    end)
end

fx["Wind"] = function(t, p, c, d)
    t = easeIO(t)
    local sweep = -40 + t * (W + 80)
    stencilDraw(p, c, function()
        for y = 0, H - 1 do
            local noise = sin(y * 0.1 + t * 9) * 22
                + sin(y * 0.23 + t * 13) * 14
                + sin(y * 0.47 + t * 6) * 8
                + sin(y * 0.71 + t * 17) * 4
            local wx = sweep + noise
            if d == "fwd" then
                if wx > 0 then gfx.fillRect(0, y, min(W, floor(wx)), 1) end
            else
                local startX = max(0, floor(W - wx))
                if startX < W then gfx.fillRect(startX, y, W - startX, 1) end
            end
        end
        for i = 0, 60 do
            local px = sweep + 15 + (i * 37 + i * i * 3) % 90
            local py = (i * 53 + 11) % H
            if d == "back" then px = W - px end
            if px > 0 and px < W then
                gfx.fillRect(floor(px), py, 1 + i % 3, 1)
            end
        end
    end)
end

fx["Melt"] = function(t, p, c, d)
    stencilDraw(p, c, function()
        for col = 0, W - 1, 2 do
            local speed = 0.6 + sin(col * 0.15 + col * col * 0.001) * 0.4
            local delay = (1 - speed) * 0.3
            local lt = max(0, (t - delay) / (1 - delay))
            if lt > 0 then
                local drop = easeIn(lt) * (H + 40)
                local drip = sin(col * 0.3 + lt * 4) * 8 * lt
                local fillH = floor(drop + drip)
                if d == "fwd" then
                    gfx.fillRect(col, 0, 2, min(H, fillH))
                else
                    gfx.fillRect(col, max(0, H - fillH), 2, H)
                end
            end
        end
    end)
end

fx["Shatter"] = function(t, p, c, d)
    stencilDraw(p, c, function()
        gfx.fillRect(0, 0, W, H)
    end)
    if t < 0.95 then
        local chunks = 18
        for i = 0, chunks - 1 do
            local cx = (i * 89 + 13) % W
            local cy = (i * 53 + 7) % H
            local cw2 = 40 + (i % 4) * 20
            local ch2 = 30 + (i % 3) * 15
            local delay = (i % 5) * 0.04
            local lt = max(0, (t - delay) / (1 - delay))
            if lt > 0 then
                local gravity = lt * lt * 300
                local rot = (i % 2 == 0 and 1 or -1) * lt * 30
                local dx = (d == "fwd" and 1 or -1) * rot
                local dy = gravity
                local sx = cx - cw2 / 2 + dx
                local sy = cy - ch2 / 2 + dy
                gfx.setClipRect(floor(sx), floor(sy), cw2, ch2)
                p:draw(floor(dx), floor(dy))
                gfx.clearClipRect()
            end
        end
    end
end

fx["Scanline"] = function(t, p, c, d)
    local scanY = floor(t * (H + 16)) - 8
    local actualY = d == "fwd" and scanY or (H - scanY)
    stencilDraw(p, c, function()
        if d == "fwd" then
            if actualY > 0 then gfx.fillRect(0, 0, W, min(H, actualY)) end
        else
            if actualY < H then gfx.fillRect(0, max(0, actualY), W, H) end
        end
    end)
    gfx.setColor(gfx.kColorWhite)
    local beamY = max(0, min(H - 3, actualY))
    gfx.fillRect(0, beamY, W, 2)
    gfx.setColor(gfx.kColorBlack)
    for x = 0, W - 1, 4 do
        local flicker = sin(x * 0.5 + t * 40) > 0.3 and 1 or 0
        gfx.fillRect(x, beamY + flicker, 2, 1)
    end
end

fx["Pixel Shift"] = function(t, p, c, d)
    local maxShift = W * 1.2
    stencilDraw(p, c, function()
        for y = 0, H - 1, 2 do
            local dir2 = (y / 2) % 2 == 0 and 1 or -1
            if d == "back" then dir2 = -dir2 end
            local rowDelay = sin(y * 0.05) * 0.1
            local lt = clamp01((t - rowDelay * 0.5) / (1 - rowDelay * 0.5))
            local shift = easeIO(lt) * maxShift * dir2
            if dir2 > 0 then
                local fillStart = max(0, floor(W - shift))
                if fillStart < W then gfx.fillRect(fillStart, y, W, 2) end
            else
                local fillEnd = min(W, floor(-shift))
                if fillEnd > 0 then gfx.fillRect(0, y, fillEnd, 2) end
            end
        end
    end)
end

fx["Hexagons"] = function(t, p, c, d)
    t = easeOut(t)
    local hexR = 28
    local hexW = hexR * 1.73
    local hexH = hexR * 2
    local cols = ceil(W / hexW) + 1
    local rows = ceil(H / (hexH * 0.75)) + 1
    stencilDraw(p, c, function()
        for row = 0, rows - 1 do
            for col = 0, cols - 1 do
                local cx = col * hexW + (row % 2) * hexW * 0.5
                local cy = row * hexH * 0.75
                local dist = sqrt((cx - W / 2) ^ 2 + (cy - H / 2) ^ 2)
                local maxDist = 250
                local dl = clamp01(d == "fwd" and dist / maxDist or (1 - dist / maxDist))
                local lt = clamp01((t - dl * 0.75) / 0.25)
                if lt > 0 then
                    local s = easeOut(lt) * hexR
                    local pts = {}
                    for k = 0, 5 do
                        local a = pi / 3 * k + pi / 6
                        pts[#pts + 1] = cx + cos(a) * s
                        pts[#pts + 1] = cy + sin(a) * s
                    end
                    gfx.fillPolygon(unpack(pts))
                end
            end
        end
    end)
end

fx["Diagonal"] = function(t, p, c, d)
    t = easeIO(t)
    local threshold = t * (W + H)
    stencilDraw(p, c, function()
        for y = 0, H - 1, 2 do
            if d == "fwd" then
                local fw = floor(threshold - y)
                if fw > 0 then gfx.fillRect(0, y, min(W, fw), 2) end
            else
                local sx = floor(W - (threshold - (H - 1 - y)))
                if sx < W then gfx.fillRect(max(0, sx), y, W - max(0, sx), 2) end
            end
        end
    end)
end

-- ---- effect: Paw Walk ------------------------------------------------------
-- A cat walks across the page and the new screen follows it in. The reveal is a
-- vertical boundary; the prints run ahead of it so the paws lead and the page
-- catches up. Prints alternate above/below the path -- that gait is the whole
-- reason this reads as an animal rather than as a grid of stamps.

local PAWS <const> = 8
local PAW_FIRST <const> = -20       -- first print, in travel space
local PAW_SPACING <const> = 64
local PAW_LEAD <const> = 250        -- a print starts appearing this far ahead
local PAW_SET <const> = 60          -- ...and is fully down by this far ahead
local PAW_LIFT <const> = 34         -- ...and lifts once the page has passed it
local PAW_GAIT <const> = 18         -- perpendicular offset, alternating each step

-- The stamp is drawn art, not procedural shapes: hand-drawn toe beans simply
-- look better than four circles on an orbit, which is what this started as.
--
-- Two images per print. `paw_plate` is the filled silhouette, laid down in
-- WHITE first, because the artwork is an outline with transparent gaps and the
-- walk crosses inverted menu rows and filled panel headers -- without the plate
-- those prints would be black ink on black.
--
-- The art is baked at the size the press overshoot peaks at, so the runtime only
-- ever scales DOWN -- upscaling a 1-bit bitmap is what makes a stamp look chewed.
local PAW_NOMINAL <const> = 1 / 1.16

local function paw_stamp(cx, cy, s, fwd)
    local sc = s * PAW_NOMINAL
    if sc <= 0.02 or not paw_ink then return end
    local plate = fwd and paw_plate or paw_plate_b
    if plate then
        gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
        plate:drawScaled(cx - plate_w * sc / 2, cy - plate_h * sc / 2, sc)
    end
    gfx.setImageDrawMode(gfx.kDrawModeCopy)
    local ink = fwd and paw_ink or paw_ink_b
    ink:drawScaled(cx - ink_w * sc / 2, cy - ink_h * sc / 2, sc)
end

fx["Paw Walk"] = function(t, p, c, d)
    load_paw_assets()                  -- first paw transition only; then cached
    local fwd = (d ~= "back")
    local e = easeIn(t) * 0.3 + easeOut(t) * 0.7     -- brisk start, soft land
    -- Travel space: u runs the way the cat walks, so "back" is the same maths
    -- mirrored at the end. The boundary lands exactly on W at t == 1, or the
    -- last frames of the transition are duplicates of a finished wipe.
    local bu = e * W

    -- 1. the page itself
    stencilDraw(p, c, function()
        if fwd then gfx.fillRect(0, 0, floor(bu), H)
        else gfx.fillRect(W - floor(bu), 0, floor(bu), H) end
    end)

    -- 2. the prints, as INK ON TOP -- emphatically not as holes in the stencil.
    -- On a light page a paw-shaped reveal is white on white and completely
    -- invisible; that was the first version's bug. Each print is a white halo
    -- under black ink so it reads over header bars and inverted rows too.
    for i = 0, PAWS - 1 do
        local pu = PAW_FIRST + i * PAW_SPACING
        local ahead = pu - bu
        local a = clamp01((PAW_LEAD - ahead) / (PAW_LEAD - PAW_SET))
        -- press and settle: a small overshoot, so each print lands rather than
        -- fades up. The lift term takes it away again as the page sweeps past,
        -- which is what leaves the final frame clean.
        local press = a < 0.62 and (a / 0.62) * 1.16
                        or 1.16 - 0.16 * ((a - 0.62) / 0.38)
        local s = min(press, clamp01((ahead + PAW_LIFT) / PAW_LIFT))
        if s > 0.02 then
            local py = H / 2 + sin(pu * 0.017) * 40
                      + ((i % 2 == 0) and -PAW_GAIT or PAW_GAIT)
            paw_stamp(fwd and pu or (W - pu), py, s, fwd)
        end
    end
    gfx.setImageDrawMode(gfx.kDrawModeCopy)
    gfx.setColor(gfx.kColorBlack)
end

-- ---- effect: Blink ---------------------------------------------------------
-- Two lids close over the old screen and open on the new one. Reads as a
-- bracket rather than a wipe, which is what you want at the start and end of a
-- run rather than between menu pages.

-- 5px columns: at 10px the stepping on the lid's diagonal was plainly visible.
-- 80 fillRects a frame is nothing next to the two full-screen blits alongside.
local LID_COLS <const> = 80
local COL_W <const> = W / LID_COLS

-- Half-height of the aperture at column centre x, for a given openness 0..1.
-- The sine term is what makes this a lens rather than a slot. Scaled so the
-- screen is exactly, only just fully covered at open == 1: an earlier version
-- reached full coverage at open 0.91 and spent the last five frames of the
-- transition redrawing an already-finished picture.
local function aperture(x, open)
    return open * (H / 2) * (1 + 0.8 * sin(pi * x / W))
end

local function lid_columns(open, paint)
    for i = 0, LID_COLS - 1 do
        local x = i * COL_W
        local half = aperture(x + COL_W / 2, open)
        paint(x, H / 2 - half, H / 2 + half)
    end
end

fx["Blink"] = function(t, p, c, d)
    -- Closing uses easeOut, NOT easeIn: a cubic ease-in left the first five
    -- frames of twenty with no visible movement at all, which reads as a hitch
    -- rather than a blink. fwd snaps shut like a real blink; back closes slowly,
    -- so backing out of somewhere feels like a decision rather than an accident.
    local closing = min(1, t * 2)
    local shut = (d ~= "back") and easeOut(closing) or easeIn(closing)
    local open = easeOut(max(0, t * 2 - 1))

    if t < 0.5 then
        p:draw(0, 0)
        gfx.setColor(gfx.kColorBlack)
        lid_columns(1 - shut, function(x, top, bot)
            if top > 0 then gfx.fillRect(x, 0, COL_W + 1, top) end
            if bot < H then gfx.fillRect(x, bot, COL_W + 1, H - bot) end
        end)
        -- a 1px white lash line, or black lids over dark art read as nothing
        gfx.setColor(gfx.kColorWhite)
        lid_columns(1 - shut, function(x, top, bot)
            if top > 0 then gfx.fillRect(x, top, COL_W + 1, 1) end
            if bot < H then gfx.fillRect(x, bot - 1, COL_W + 1, 1) end
        end)
        gfx.setColor(gfx.kColorBlack)
    else
        gfx.clear(gfx.kColorBlack)
        gfx.pushContext(stencil)
        gfx.clear(gfx.kColorBlack)
        gfx.setColor(gfx.kColorWhite)
        lid_columns(open, function(x, top, bot)
            gfx.fillRect(x, max(0, top), COL_W + 1, min(H, bot) - max(0, top))
        end)
        gfx.popContext()
        gfx.setStencilImage(stencil)
        c:draw(0, 0)
        gfx.clearStencil()
        if open < 0.98 then
            gfx.setColor(gfx.kColorWhite)
            lid_columns(open, function(x, top, bot)
                if top > 0 then gfx.fillRect(x, top, COL_W + 1, 1) end
                if bot < H then gfx.fillRect(x, bot - 1, COL_W + 1, 1) end
            end)
            gfx.setColor(gfx.kColorBlack)
        end
    end
end

-- ================================================================ the driver

-- Start a transition. Call it at the moment you swap scenes -- the snapshot is
-- taken here, so the screen must still show the OUTGOING scene.
-- An unknown effect name is a silent no-op rather than a crash mid-scene-change.
function Transitions.start(effect, direction, duration)
    if not gfx then return end
    local canon = Transitions.canonical(effect)
    if not canon or not fx[canon] then return end
    Transitions.load()                            -- idempotent; never at import
    prev = gfx.getDisplayImage()
    name = canon
    dir = Transitions.normalizeDir(direction)
    frame = 0
    frames = duration or 24
    Transitions.active = true
    -- Optional companion module from the demo app; looked up at call time so
    -- this file never depends on import order.
    local sounds = rawget(_G, "TransitionSounds")
    if sounds then sounds.play(name, dir) end
end

-- Start whatever the registered plan says this hop gets. Bare and unknown hops
-- are silent, so a call site can name its hop unconditionally.
function Transitions.play(hop)
    if Transitions.active then return end          -- never stack transitions
    local e, d, n = Transitions.forHop(hop)
    if not e then return end
    Transitions.start(e, d, n)
end

-- Wrap your per-frame scene draw. While a transition runs the incoming scene
-- still draws -- into an offscreen buffer -- so it animates in behind the wipe.
-- Gate your input handling on Transitions.active, or the outgoing scene keeps
-- reading the d-pad.
function Transitions.draw(drawFn)
    if Transitions.active and frame >= frames then
        Transitions.active = false
        prev = nil                                 -- drop the snapshot promptly
    end
    if not Transitions.active or not Transitions._ready then
        drawFn()
        return
    end

    gfx.pushContext(buf)
    drawFn()
    gfx.popContext()

    gfx.setColor(gfx.kColorBlack)
    fx[name](Transitions.progress(frame, frames), prev, buf, dir)
    frame = frame + 1
end

function Transitions.setFrames(n) frames = n end
function Transitions.getFrames() return frames or 24 end

-- Downstream spellings kept alive on purpose: Nyandoku shipped this driver as
-- for_hop/wrap and there is no reason to break its call sites over a style.
Transitions.for_hop = Transitions.forHop
Transitions.wrap = Transitions.draw

return Transitions
