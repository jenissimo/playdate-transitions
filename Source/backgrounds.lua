Backgrounds = {}

local gfx <const> = playdate.graphics
local W <const> = 400
local H <const> = 240
local sin <const> = math.sin
local cos <const> = math.cos
local floor <const> = math.floor
local ceil <const> = math.ceil
local pi <const> = math.pi
local unpack <const> = table.unpack

local tick = 0

local stars = {}
for i = 1, 80 do
    stars[i] = {x = math.random(0, W), y = math.random(0, H), spd = 0.8 + math.random() * 3, sz = math.random(1, 4) == 1 and 2 or 1}
end

local rainDrops = {}
for i = 1, 60 do
    rainDrops[i] = {x = math.random(0, W + 60), y = math.random(0, H + 40), spd = 1.5 + math.random() * 3, len = 12 + math.random() * 16}
end

local bg = {}

bg[1] = {
    name = "Starfield",
    draw = function()
        gfx.clear(gfx.kColorBlack)
        gfx.setColor(gfx.kColorWhite)
        for _, s in ipairs(stars) do
            s.x -= s.spd
            if s.x < -2 then s.x = W + 2; s.y = math.random(0, H) end
            gfx.fillRect(floor(s.x), floor(s.y), s.sz, s.sz)
        end
    end
}

bg[2] = {
    name = "Waves",
    draw = function()
        gfx.clear(gfx.kColorWhite)
        gfx.setColor(gfx.kColorBlack)
        for w = 0, 5 do
            local amp = 18 + w * 8
            local freq = 0.014 + w * 0.004
            local ph = tick * 0.04 + w * 1.5
            local yb = 30 + w * 34
            local py = yb + sin(ph) * amp
            for x = 1, W do
                local y = yb + sin(x * freq + ph) * amp
                gfx.drawLine(x - 1, py, x, y)
                py = y
            end
        end
    end
}

bg[3] = {
    name = "Radar",
    draw = function()
        gfx.clear(gfx.kColorBlack)
        gfx.setColor(gfx.kColorWhite)
        local cx, cy, mR = W / 2, H / 2, 160
        for i = 0, 6 do
            local r = ((i * 30 + tick * 1.0) % (mR + 30))
            if r > 0 and r < mR then gfx.drawCircleAtPoint(cx, cy, floor(r)) end
        end
        local a = math.rad(tick * 2.5)
        gfx.setLineWidth(2)
        gfx.drawLine(cx, cy, cx + cos(a) * mR, cy + sin(a) * mR)
        gfx.setLineWidth(1)
        gfx.fillCircleAtPoint(cx, cy, 3)
    end
}

bg[4] = {
    name = "Rain",
    draw = function()
        gfx.clear(gfx.kColorWhite)
        gfx.setColor(gfx.kColorBlack)
        gfx.drawLine(0, H - 2, W, H - 2)
        for _, d in ipairs(rainDrops) do
            local x = d.x % W
            local y = (d.y + tick * d.spd * 1.6) % (H + 40) - 15
            local wind = sin(tick * 0.015) * 1.5
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
    end
}

bg[5] = {
    name = "Squares",
    draw = function()
        gfx.clear(gfx.kColorWhite)
        gfx.setColor(gfx.kColorBlack)
        local gs = 50
        for r = 0, ceil(H / gs) do
            for c = 0, ceil(W / gs) do
                local cx, cy = c * gs + gs / 2, r * gs + gs / 2
                local ang = tick * 0.04 + (c + r) * 0.6
                local sz = 13 + sin(tick * 0.06 + c * 0.4 + r * 0.8) * 6
                local ca, sa = cos(ang), sin(ang)
                local pts = {}
                for k = 0, 3 do
                    local a = k * pi / 2
                    local px, py = sz * cos(a), sz * sin(a)
                    pts[#pts + 1] = cx + px * ca - py * sa
                    pts[#pts + 1] = cy + px * sa + py * ca
                end
                gfx.drawPolygon(unpack(pts))
            end
        end
    end
}

bg[6] = {
    name = "Spirograph",
    draw = function()
        gfx.clear(gfx.kColorWhite)
        gfx.setColor(gfx.kColorBlack)
        local ccx, ccy = W / 2, H / 2
        local R = 75 + sin(tick * 0.008) * 10
        local r = 32
        local dd = 52 + sin(tick * 0.012) * 8
        local px, py
        for i = 0, 500 do
            local a = i / 500 * pi * 12
            local x = floor(ccx + (R - r) * cos(a) + dd * cos((R - r) / r * a))
            local y = floor(ccy + (R - r) * sin(a) - dd * sin((R - r) / r * a))
            if px then gfx.drawLine(px, py, x, y) end
            px, py = x, y
        end
    end
}

bg[7] = {
    name = "Lava Lamp",
    draw = function()
        gfx.clear(gfx.kColorWhite)
        local blobs = {
            {ox=0.6,oy=0.4,rx=100,ry=55,spd=0.012,base=65},
            {ox=0.3,oy=0.6,rx=90,ry=50,spd=0.015,base=58},
            {ox=0.7,oy=0.55,rx=110,ry=45,spd=0.010,base=60},
            {ox=0.45,oy=0.35,rx=80,ry=60,spd=0.018,base=52},
            {ox=0.55,oy=0.7,rx=95,ry=40,spd=0.013,base=55},
        }
        for i, b in ipairs(blobs) do
            local ph = tick * b.spd + i * 1.7
            local x = floor(W * b.ox + sin(ph) * b.rx)
            local y = floor(H * b.oy + cos(ph * 0.7) * b.ry)
            local r = b.base + floor(sin(ph * 1.3) * 10)
            gfx.setDitherPattern(0.35, gfx.image.kDitherTypeBayer8x8)
            gfx.fillCircleAtPoint(x, y, r)
            gfx.setDitherPattern(0.7, gfx.image.kDitherTypeBayer4x4)
            gfx.fillCircleAtPoint(x, y, floor(r * 0.6))
            gfx.setColor(gfx.kColorBlack)
            gfx.fillCircleAtPoint(x, y, floor(r * 0.25))
        end
        gfx.setColor(gfx.kColorBlack)
    end
}

bg[8] = {
    name = "Dither Hills",
    draw = function()
        gfx.clear(gfx.kColorWhite)
        local layers = {
            {yBase=60,amp=35,freq=0.012,spd=0.02,dither=0.2},
            {yBase=100,amp=30,freq=0.018,spd=0.03,dither=0.45},
            {yBase=140,amp=25,freq=0.022,spd=0.04,dither=0.7},
            {yBase=175,amp=20,freq=0.028,spd=0.05,dither=1.0},
        }
        for _, l in ipairs(layers) do
            local ph = tick * l.spd
            if l.dither >= 0.95 then
                gfx.setColor(gfx.kColorBlack)
            else
                gfx.setDitherPattern(l.dither, gfx.image.kDitherTypeBayer8x8)
            end
            for x = 0, W - 1, 3 do
                local y = l.yBase + sin(x * l.freq + ph) * l.amp + sin(x * l.freq * 2.5 + ph * 1.7) * l.amp * 0.25
                gfx.fillRect(x, floor(y), 3, H - floor(y))
            end
        end
        gfx.setColor(gfx.kColorBlack)
    end
}

bg[9] = {
    name = "Bubbles Rise",
    draw = function()
        gfx.clear(gfx.kColorBlack)
        for i = 0, 24 do
            local spd = 0.6 + (i % 5) * 0.3
            local r = 8 + (i % 4) * 5
            local wobble = sin(tick * 0.03 + i * 1.1) * 12
            local y = H - ((i * 41 + tick * spd) % (H + r * 4) - r * 2)
            local baseX = (i * 67 + 19) % W
            local x = baseX + wobble
            local norm = y / H
            if norm < 0.25 then
                gfx.setColor(gfx.kColorWhite)
                gfx.fillCircleAtPoint(floor(x), floor(y), r)
            elseif norm < 0.5 then
                gfx.setDitherPattern(0.8, gfx.image.kDitherTypeBayer8x8)
                gfx.fillCircleAtPoint(floor(x), floor(y), r)
            elseif norm < 0.75 then
                gfx.setDitherPattern(0.5, gfx.image.kDitherTypeBayer4x4)
                gfx.fillCircleAtPoint(floor(x), floor(y), r)
            else
                gfx.setDitherPattern(0.25, gfx.image.kDitherTypeBayer8x8)
                gfx.fillCircleAtPoint(floor(x), floor(y), r)
            end
        end
        gfx.setColor(gfx.kColorBlack)
    end
}

Backgrounds.count = #bg

Backgrounds.names = {}
for i, b in ipairs(bg) do
    Backgrounds.names[i] = b.name
end

function Backgrounds.update()
    tick += 1
end

function Backgrounds.draw(index)
    bg[index].draw()
    gfx.setColor(gfx.kColorBlack)
end

function Backgrounds.getName(index)
    return bg[index].name
end
