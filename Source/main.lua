import "CoreLibs/graphics"
import "transitions"
import "backgrounds"

local gfx <const> = playdate.graphics
local snd <const> = playdate.sound
local W <const> = 400
local H <const> = 240
local sin <const> = math.sin
local cos <const> = math.cos
local floor <const> = math.floor
local max <const> = math.max
local min <const> = math.min

playdate.display.setRefreshRate(30)

local fontBold = gfx.font.new("fonts/Roobert-10-Bold")
local fontTitle = gfx.font.new("fonts/Roobert-11-Medium")
assert(fontBold)
assert(fontTitle)
local synthWhoosh = snd.synth.new(snd.kWaveNoise)
synthWhoosh:setADSR(0.02, 0.25, 0.1, 0.3)
synthWhoosh:setVolume(0.2)
local synthSweep = snd.synth.new(snd.kWaveSawtooth)
synthSweep:setADSR(0.01, 0.12, 0.05, 0.15)
synthSweep:setVolume(0.1)
local synthTick = snd.synth.new(snd.kWaveSquare)
synthTick:setADSR(0.001, 0.03, 0, 0.01)
synthTick:setVolume(0.15)

local function sfxTick() synthTick:playNote(900, 1, 0.03) end
local function sfxWhoosh() synthWhoosh:playNote(120, 1, 0.4); synthSweep:playNote(280, 0.8, 0.25) end
local tick = 0
local scene = "menu"
local sel = 1
local selPunch = 0
local scrollOff = 0
local holdTimer = 0
local transSpeed = 24
local demoBgIdx = 1
local autoPlay = false
local autoPause = 0

local TRANS = Transitions.names
local PX, PY, PW, PH = 55, 14, 290, 199
local LIST_Y = PY + 36
local ITEM_H = 14
local MAX_VIS = 11
local function drawOutlined(text, x, y)
    gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
    for dx = -1, 1 do
        for dy = -1, 1 do
            if dx ~= 0 or dy ~= 0 then
                gfx.drawText(text, x + dx, y + dy)
            end
        end
    end
    gfx.setImageDrawMode(gfx.kDrawModeCopy)
    gfx.drawText(text, x, y)
end
local function drawMenuBg()
    gfx.clear(gfx.kColorWhite)
    gfx.setColor(gfx.kColorBlack)
    local sp = 22
    for x = 0, W, sp do
        for y = 0, H, sp do
            local v = sin(x * 0.016 + tick * 0.045) + cos(y * 0.02 + tick * 0.035)
            local r = floor(1.5 + v * 2)
            if r > 0 then gfx.fillCircleAtPoint(x, y, r) end
        end
    end
end

local function drawMenu()
    drawMenuBg()

    gfx.setColor(gfx.kColorWhite)
    gfx.fillRect(PX, PY, PW, PH)
    gfx.setColor(gfx.kColorBlack)
    gfx.setLineWidth(2)
    gfx.drawRect(PX, PY, PW, PH)
    gfx.drawRect(PX + 3, PY + 3, PW - 6, PH - 6)
    gfx.setLineWidth(1)

    gfx.setFont(fontTitle)
    local title = "TRANSITIONS"
    local tw, _ = gfx.getTextSize(title)
    gfx.drawText(title, PX + (PW - tw) / 2, PY + 8)
    gfx.drawLine(PX + 12, PY + 28, PX + PW - 12, PY + 28)

    gfx.setClipRect(PX + 4, LIST_Y - 2, PW - 8, MAX_VIS * ITEM_H + 4)
    gfx.setFont(fontBold)
    selPunch = selPunch * 0.82
    if sel <= scrollOff then scrollOff = sel - 1 end
    if sel > scrollOff + MAX_VIS then scrollOff = sel - MAX_VIS end

    for idx = 1, MAX_VIS do
        local i = idx + scrollOff
        if i > #TRANS then break end
        local name = TRANS[i]
        local iy = LIST_Y + (idx - 1) * ITEM_H
        if i == sel then
            local extra = floor(selPunch * 6)
            gfx.setColor(gfx.kColorBlack)
            gfx.fillRect(PX + 6 - extra, iy - 1, PW - 12 + extra * 2, ITEM_H)
            gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
            local arrow = floor(sin(tick * 0.15) * 2)
            gfx.drawText(">", PX + 12 + arrow, iy)
            gfx.drawText(name, PX + 26, iy)
            gfx.setImageDrawMode(gfx.kDrawModeCopy)
        else
            gfx.drawText("  " .. name, PX + 12, iy)
        end
    end
    gfx.clearClipRect()

    gfx.setColor(gfx.kColorBlack)
    local mx = floor(PX + PW / 2)
    if scrollOff > 0 then
        local ay = LIST_Y - 3
        gfx.fillRect(mx - 1, ay - 3, 2, 1)
        gfx.fillRect(mx - 2, ay - 2, 4, 1)
        gfx.fillRect(mx - 3, ay - 1, 6, 1)
        gfx.fillRect(mx - 4, ay, 8, 1)
    end
    if scrollOff + MAX_VIS < #TRANS then
        local by = LIST_Y + MAX_VIS * ITEM_H
        gfx.fillRect(mx - 4, by, 8, 1)
        gfx.fillRect(mx - 3, by + 1, 6, 1)
        gfx.fillRect(mx - 2, by + 2, 4, 1)
        gfx.fillRect(mx - 1, by + 3, 2, 1)
    end

    gfx.setFont(fontBold)
    drawOutlined(Transitions.descriptions[TRANS[sel]] or "", PX + 8, PY + PH + 5)
    local spd = "Speed:" .. tostring(floor(transSpeed))
    local sw2, _ = gfx.getTextSize(spd)
    drawOutlined(spd, PX + PW - sw2 - 8, PY + PH + 5)
end
local function drawDemo()
    Backgrounds.draw(demoBgIdx)
    gfx.setColor(gfx.kColorBlack)

    local cw, ch = 210, 54
    local cx = (W - cw) / 2
    local cy = (H - ch) / 2 - 10
    gfx.setColor(gfx.kColorWhite)
    gfx.fillRoundRect(cx, cy, cw, ch, 4)
    gfx.setColor(gfx.kColorBlack)
    gfx.setLineWidth(2)
    gfx.drawRoundRect(cx, cy, cw, ch, 4)
    gfx.setLineWidth(1)

    gfx.setFont(fontTitle)
    local name = TRANS[sel]
    local nw, _ = gfx.getTextSize(name)
    gfx.drawText(name, cx + (cw - nw) / 2, cy + 8)

    gfx.setFont(fontBold)
    local bgn = "BG: " .. Backgrounds.getName(demoBgIdx)
    local bw2, _ = gfx.getTextSize(bgn)
    gfx.drawText(bgn, cx + (cw - bw2) / 2, cy + 32)

    gfx.setFont(fontBold)
    drawOutlined("[A] Next  [B] Back  D-pad: BG", 12, H - 15)
end
local function drawScene()
    if scene == "menu" then drawMenu() else drawDemo() end
end
local function moveSelection(dir)
    sel += dir
    if sel < 1 then sel = #TRANS end
    if sel > #TRANS then sel = 1 end
    selPunch = 1
    sfxTick()
end

local function handleInput()
    if scene == "menu" then
        local moved = false
        if playdate.buttonJustPressed(playdate.kButtonUp) then moveSelection(-1); moved = true end
        if playdate.buttonJustPressed(playdate.kButtonDown) then moveSelection(1); moved = true end

        if not moved then
            if playdate.buttonIsPressed(playdate.kButtonUp) or playdate.buttonIsPressed(playdate.kButtonDown) then
                holdTimer += 1
                if holdTimer > 14 and holdTimer % 3 == 0 then
                    local dir = playdate.buttonIsPressed(playdate.kButtonUp) and -1 or 1
                    moveSelection(dir)
                end
            else
                holdTimer = 0
            end
        else
            holdTimer = 0
        end

        if playdate.buttonJustPressed(playdate.kButtonA) then
            demoBgIdx = (demoBgIdx % Backgrounds.count) + 1
            sfxWhoosh()
            Transitions.start(TRANS[sel], "fwd", floor(transSpeed))
            scene = "demo"
        end
    else
        if playdate.buttonJustPressed(playdate.kButtonB) then
            sfxWhoosh()
            Transitions.start(TRANS[sel], "back", floor(transSpeed))
            scene = "menu"
        end
        if playdate.buttonJustPressed(playdate.kButtonA) then
            demoBgIdx = (demoBgIdx % Backgrounds.count) + 1
            sfxWhoosh()
            Transitions.start(TRANS[sel], "fwd", floor(transSpeed))
        end
        if playdate.buttonJustPressed(playdate.kButtonLeft) then
            demoBgIdx = ((demoBgIdx - 2) % Backgrounds.count) + 1
        end
        if playdate.buttonJustPressed(playdate.kButtonRight) then
            demoBgIdx = (demoBgIdx % Backgrounds.count) + 1
        end
    end
end
local function autoStep()
    if Transitions.active then return end
    if autoPause > 0 then
        autoPause -= 1
        return
    end
    if scene == "menu" then
        demoBgIdx = (demoBgIdx % Backgrounds.count) + 1
        Transitions.start(TRANS[sel], "fwd", 20)
        scene = "demo"
        autoPause = 25
    else
        Transitions.start(TRANS[sel], "back", 20)
        scene = "menu"
        sel += 1
        if sel > #TRANS then
            sel = 1
            autoPlay = false
        end
        selPunch = 1
        autoPause = 15
    end
end

function playdate.update()
    tick += 1
    Backgrounds.update()

    local cc = playdate.getCrankChange()
    if math.abs(cc) > 1 then
        transSpeed = max(8, min(60, transSpeed + cc * 0.12))
    end

    if autoPlay then
        autoStep()
    elseif not Transitions.active then
        handleInput()
    end

    Transitions.draw(drawScene)

    playdate.drawFPS(2, 2)
end

local sysMenu = playdate.getSystemMenu()
sysMenu:addMenuItem("Reset Speed", function() transSpeed = 24 end)
sysMenu:addMenuItem("Auto Showcase", function()
    autoPlay = true
    autoPause = 10
    scene = "menu"
end)
