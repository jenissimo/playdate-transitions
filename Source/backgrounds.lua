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

local matrixCols = {}
for i = 1, 28 do
    matrixCols[i] = {x = (i - 1) * 15 + math.random(0, 6), spd = 1.2 + math.random() * 2.5, len = 5 + math.random(1, 10), off = math.random(0, 300)}
end

local confetti = {}
for i = 1, 40 do
    confetti[i] = {x = math.random(0, W), y = math.random(0, H), vx = math.random() * 4 - 2, vy = -2 - math.random() * 3, sz = 2 + math.random(0, 3), sh = math.random(1, 3)}
end

local lifeW, lifeH, lifeSz = 50, 30, 8
local lifeGrid, lifeNext = {}, {}
for i = 1, lifeW * lifeH do
    lifeGrid[i] = math.random() < 0.35 and 1 or 0
    lifeNext[i] = 0
end

local function mkBolt(x1, y1, x2, y2, d)
    if d == 0 then return {{x1, y1}, {x2, y2}} end
    local mx = (x1 + x2) / 2 + (math.random() - 0.5) * (y2 - y1) * 0.4
    local my = (y1 + y2) / 2
    local a = mkBolt(x1, y1, mx, my, d - 1)
    local b = mkBolt(mx, my, x2, y2, d - 1)
    for i = 2, #b do a[#a + 1] = b[i] end
    return a
end
local lightBolts = {}
local lightTimer = -100

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

bg[10] = {
    name = "Plasma",
    draw = function()
        gfx.clear(gfx.kColorWhite)
        local s = 10
        local t1, t2 = tick * 0.03, tick * 0.025
        for x = 0, W - 1, s do
            local sx = sin(x * 0.02 + t1)
            for y = 0, H - 1, s do
                local v = sx + sin(y * 0.025 + t2) + sin((x + y) * 0.015 + t1 * 0.8)
                local n = (v + 3) / 6
                if n < 0.35 then
                    gfx.setDitherPattern(0.8, gfx.image.kDitherTypeBayer8x8)
                    gfx.fillRect(x, y, s, s)
                elseif n < 0.5 then
                    gfx.setDitherPattern(0.5, gfx.image.kDitherTypeBayer4x4)
                    gfx.fillRect(x, y, s, s)
                elseif n < 0.65 then
                    gfx.setDitherPattern(0.25, gfx.image.kDitherTypeBayer8x8)
                    gfx.fillRect(x, y, s, s)
                end
            end
        end
    end
}

local matrixChars = "0123456789:.<>|=+*ABCDEF"

bg[11] = {
    name = "Matrix Rain",
    draw = function()
        gfx.clear(gfx.kColorBlack)
        gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
        for ci, c in ipairs(matrixCols) do
            local head = (c.off + tick * c.spd) % (H + c.len * 10)
            for j = 0, c.len - 1 do
                local y = floor(head - j * 10)
                if y >= 0 and y < H then
                    local skip = j > c.len * 0.7 and (ci + j) % 3 == 0
                    if not skip then
                        local rate = j < 2 and 0.3 or 0.05
                        local idx = ((ci * 7 + j * 13 + floor(tick * rate)) % #matrixChars) + 1
                        gfx.drawText(matrixChars:sub(idx, idx), c.x, y)
                    end
                end
            end
        end
        gfx.setImageDrawMode(gfx.kDrawModeCopy)
        gfx.setColor(gfx.kColorBlack)
    end
}

bg[12] = {
    name = "Fire",
    draw = function()
        gfx.clear(gfx.kColorBlack)
        local t = tick * 0.08
        local step = 4
        for x = 0, W - 1, step do
            local h = 50 + sin(x * 0.05 + t) * 25 + sin(x * 0.12 + t * 1.7) * 15
                    + sin(x * 0.03 + t * 0.6) * 20 + sin(x * 0.23 + t * 2.3) * 8
            gfx.setDitherPattern(0.75, gfx.image.kDitherTypeBayer8x8)
            gfx.fillRect(x, H - floor(h), step, floor(h))
            gfx.setDitherPattern(0.4, gfx.image.kDitherTypeBayer4x4)
            gfx.fillRect(x, H - floor(h * 0.65), step, floor(h * 0.65))
            gfx.setColor(gfx.kColorWhite)
            gfx.fillRect(x, H - floor(h * 0.3), step, floor(h * 0.3))
        end
        gfx.setColor(gfx.kColorBlack)
    end
}

bg[13] = {
    name = "Moire",
    draw = function()
        gfx.clear(gfx.kColorWhite)
        gfx.setColor(gfx.kColorBlack)
        local cx1 = W / 2 + sin(tick * 0.02) * 60
        local cy1 = H / 2 + cos(tick * 0.015) * 40
        local cx2 = W / 2 + sin(tick * 0.025 + 2) * 60
        local cy2 = H / 2 + cos(tick * 0.018 + 1) * 40
        for r = 10, 260, 10 do
            gfx.drawCircleAtPoint(floor(cx1), floor(cy1), r)
            gfx.drawCircleAtPoint(floor(cx2), floor(cy2), r)
        end
    end
}

bg[14] = {
    name = "Lightning",
    draw = function()
        gfx.clear(gfx.kColorBlack)
        local age = tick - lightTimer
        if age > 45 then
            lightTimer = tick
            age = 0
            lightBolts = {}
            for i = 1, 2 + floor(math.random() * 2) do
                local sx = 80 + math.random(0, W - 160)
                lightBolts[i] = mkBolt(sx, 0, sx + (math.random() - 0.5) * 100, H, 5)
            end
        end
        if age < 6 and lightBolts[1] then
            gfx.setDitherPattern(0.6, gfx.image.kDitherTypeBayer8x8)
            for i = 2, #lightBolts[1] do
                local p, q = lightBolts[1][i - 1], lightBolts[1][i]
                gfx.drawLine(floor(p[1]) - 3, floor(p[2]), floor(q[1]) - 3, floor(q[2]))
                gfx.drawLine(floor(p[1]) + 3, floor(p[2]), floor(q[1]) + 3, floor(q[2]))
            end
        end
        gfx.setColor(gfx.kColorWhite)
        gfx.setLineWidth(age < 4 and 3 or (age < 12 and 2 or 1))
        for bi, bolt in ipairs(lightBolts) do
            if age < 20 + bi * 8 then
                for i = 2, #bolt do
                    gfx.drawLine(floor(bolt[i - 1][1]), floor(bolt[i - 1][2]), floor(bolt[i][1]), floor(bolt[i][2]))
                end
            end
        end
        gfx.setLineWidth(1)
    end
}

bg[15] = {
    name = "Confetti",
    draw = function()
        gfx.clear(gfx.kColorWhite)
        gfx.setColor(gfx.kColorBlack)
        for _, p in ipairs(confetti) do
            p.vy = p.vy + 0.15
            p.x = p.x + p.vx
            p.y = p.y + p.vy
            if p.y > H - 4 then
                p.y = H - 4
                p.vy = -p.vy * 0.5
                if math.abs(p.vy) < 0.5 then
                    p.x = math.random(0, W)
                    p.y = -math.random(0, 20)
                    p.vy = 0
                    p.vx = math.random() * 4 - 2
                end
            end
            if p.x < -10 or p.x > W + 10 then
                p.x = math.random(0, W)
                p.y = -math.random(0, 20)
                p.vy = 0
                p.vx = math.random() * 4 - 2
            end
            local x, y = floor(p.x), floor(p.y)
            if p.sh == 1 then
                gfx.fillRect(x, y, p.sz, p.sz)
            elseif p.sh == 2 then
                gfx.fillCircleAtPoint(x, y, floor(p.sz / 2) + 1)
            else
                gfx.fillRect(x, y, p.sz + 2, 2)
            end
        end
    end
}

bg[16] = {
    name = "Life",
    draw = function()
        gfx.clear(gfx.kColorWhite)
        gfx.setColor(gfx.kColorBlack)
        if tick % 6 == 0 then
            for y = 0, lifeH - 1 do
                for x = 0, lifeW - 1 do
                    local n = 0
                    for dy = -1, 1 do
                        for dx = -1, 1 do
                            if dx ~= 0 or dy ~= 0 then
                                n = n + lifeGrid[((y + dy) % lifeH) * lifeW + (x + dx) % lifeW + 1]
                            end
                        end
                    end
                    local idx = y * lifeW + x + 1
                    lifeNext[idx] = (lifeGrid[idx] == 1 and (n == 2 or n == 3) or n == 3) and 1 or 0
                end
            end
            lifeGrid, lifeNext = lifeNext, lifeGrid
            for i = 1, 3 do lifeGrid[math.random(1, lifeW * lifeH)] = 1 end
        end
        for y = 0, lifeH - 1 do
            for x = 0, lifeW - 1 do
                if lifeGrid[y * lifeW + x + 1] == 1 then
                    gfx.fillRect(x * lifeSz, y * lifeSz, lifeSz - 1, lifeSz - 1)
                end
            end
        end
    end
}

bg[17] = {
    name = "Terrain",
    draw = function()
        gfx.clear(gfx.kColorBlack)
        gfx.setColor(gfx.kColorWhite)
        local scroll = tick * 0.06
        for r = 0, 15 do
            local depth = r / 15
            local scale = 0.65 + depth * 0.35
            local baseY = 40 + r * 13
            local prevX, prevY
            for c = 0, 30 do
                local xn = (c / 30 - 0.5) * W * 1.5 * scale + W / 2
                local h = (sin(c * 0.16 + r * 0.5 + scroll) * 20 + sin(c * 0.32 + scroll * 1.3) * 10) * (0.3 + depth * 0.7)
                local yn = baseY - h
                if prevX then gfx.drawLine(floor(prevX), floor(prevY), floor(xn), floor(yn)) end
                prevX, prevY = xn, yn
            end
        end
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
