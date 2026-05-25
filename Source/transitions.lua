Transitions = {}

local gfx <const> = playdate.graphics
local W <const> = 400
local H <const> = 240
local sin <const> = math.sin
local cos <const> = math.cos
local floor <const> = math.floor
local ceil <const> = math.ceil
local max <const> = math.max
local min <const> = math.min
local pi <const> = math.pi
local rad <const> = math.rad
local unpack <const> = table.unpack

Transitions.active = false

local _buf = gfx.image.new(W, H)
local _st = gfx.image.new(W, H, gfx.kColorBlack)
local _prev = nil
local _name, _dir, _frame, _frames

-- easing
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

local function stencilDraw(prev, cur, drawFn)
    gfx.pushContext(_st)
    gfx.clear(gfx.kColorBlack)
    gfx.setColor(gfx.kColorWhite)
    drawFn()
    gfx.popContext()
    prev:draw(0, 0)
    gfx.setStencilImage(_st)
    cur:draw(0, 0)
    gfx.clearStencil()
end

-- effects
local fx = {}

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
                local lt = max(0, min(1, (t - dl * 0.4) / 0.6))
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
                waveDl = waveDl + sin(r * 1.2) * 0.06
                waveDl = max(0, min(1, waveDl))
                local lt = max(0, min(1, (t - waveDl * 0.65) / 0.35))
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
                local lt = max(0, min(1, (t - dl * 0.7) / 0.3))
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

local bSeeds = {
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
            local lt = max(0, min(1, (t - dl) / max(0.01, 1 - dl)))
            lt = easeOut(lt)
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
            local lt = max(0, min(1, (t - dl) / max(0.01, 1 - dl)))
            lt = easeIO(lt)
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
        local lt = max(0, min(1, (t - dl) / max(0.01, 1 - dl)))
        lt = easeOut(lt)
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
        local dir = d == "fwd" and 1 or -1
        for angle = 0, curA, 0.13 do
            local r = angle * rPerRad
            gfx.fillCircleAtPoint(floor(cx + cos(angle * dir) * r), floor(cy + sin(angle * dir) * r), 56)
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

-- public API
Transitions.names = {
    "Slide", "Fade", "Dissolve", "Circle", "Diamonds",
    "Diamond Wave", "Triangles", "Bubbles", "Blinds", "Clock Wipe",
    "Wave Wipe", "Interleave", "Dither Bands", "Spiral", "Wind",
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
}

function Transitions.start(name, dir, frames)
    _prev = gfx.getDisplayImage()
    Transitions.active = true
    _name = name
    _dir = dir or "fwd"
    _frame = 0
    _frames = frames or 24
end

function Transitions.draw(drawFn)
    if Transitions.active and _frame >= _frames then
        Transitions.active = false
        _prev = nil
    end

    if not Transitions.active then
        drawFn()
        return
    end

    gfx.pushContext(_buf)
    drawFn()
    gfx.popContext()

    gfx.setColor(gfx.kColorBlack)

    local t = min(1.0, _frame / max(1, _frames - 1))
    fx[_name](t, _prev, _buf, _dir)

    _frame += 1
end

function Transitions.setFrames(n)
    _frames = n
end

function Transitions.getFrames()
    return _frames or 24
end
