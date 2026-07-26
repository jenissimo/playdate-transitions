TransitionSounds = {}
TransitionSounds.enabled = true

local snd <const> = playdate.sound

local n1 = snd.synth.new(snd.kWaveNoise)
local n2 = snd.synth.new(snd.kWaveNoise)
local sq = snd.synth.new(snd.kWaveSquare)
local si = snd.synth.new(snd.kWaveSine)
local tr = snd.synth.new(snd.kWaveTriangle)

local fx = {}

fx["Slide"] = function(d)
    n1:setADSR(0.02, 0.2, 0.08, 0.25)
    n1:setVolume(0.18)
    n1:playNote(d == "fwd" and 350 or 250, 1, 0.38)
    n2:setADSR(0.01, 0.12, 0.04, 0.18)
    n2:setVolume(0.08)
    n2:playNote(d == "fwd" and 700 or 500, 0.7, 0.28)
    tr:setADSR(0.03, 0.15, 0.03, 0.2)
    tr:setVolume(0.025)
    tr:playNote(d == "fwd" and 500 or 380, 0.35, 0.3)
end

fx["Fade"] = function(d)
    n1:setADSR(0.15, 0.3, 0.15, 0.4)
    n1:setVolume(0.12)
    n1:playNote(d == "fwd" and 280 or 340, 0.7, 0.6)
    si:setADSR(0.15, 0.25, 0.1, 0.35)
    si:setVolume(0.025)
    si:playNote(d == "fwd" and 440 or 520, 0.3, 0.55)
end

fx["Dissolve"] = function(d)
    n1:setADSR(0.06, 0.25, 0.12, 0.3)
    n1:setVolume(0.13)
    n1:playNote(d == "fwd" and 400 or 300, 0.65, 0.5)
    n2:setADSR(0.08, 0.2, 0.08, 0.25)
    n2:setVolume(0.06)
    n2:playNote(d == "fwd" and 800 or 600, 0.4, 0.4)
end

fx["Circle"] = function(d)
    n1:setADSR(0.01, 0.15, 0.2, 0.3)
    n1:setVolume(0.15)
    n1:playNote(d == "fwd" and 450 or 320, 0.85, 0.4)
    n2:setADSR(0.02, 0.1, 0.1, 0.2)
    n2:setVolume(0.06)
    n2:playNote(d == "fwd" and 900 or 640, 0.5, 0.35)
    si:setADSR(0.02, 0.1, 0.12, 0.25)
    si:setVolume(0.025)
    si:playNote(d == "fwd" and 600 or 800, 0.3, 0.35)
end

fx["Diamonds"] = function(d)
    n1:setADSR(0.008, 0.1, 0.04, 0.15)
    n1:setVolume(0.14)
    n1:playNote(d == "fwd" and 600 or 450, 0.8, 0.22)
    n2:setADSR(0.003, 0.06, 0.02, 0.1)
    n2:setVolume(0.08)
    n2:playNote(d == "fwd" and 1200 or 900, 0.6, 0.15)
    tr:setADSR(0.005, 0.08, 0.02, 0.12)
    tr:setVolume(0.025)
    tr:playNote(d == "fwd" and 1100 or 850, 0.35, 0.2)
end

fx["Diamond Wave"] = function(d)
    n1:setADSR(0.01, 0.18, 0.08, 0.22)
    n1:setVolume(0.14)
    n1:playNote(d == "fwd" and 500 or 380, 0.75, 0.38)
    n2:setADSR(0.015, 0.12, 0.05, 0.18)
    n2:setVolume(0.06)
    n2:playNote(d == "fwd" and 1000 or 750, 0.5, 0.3)
    tr:setADSR(0.02, 0.1, 0.04, 0.15)
    tr:setVolume(0.02)
    tr:playNote(d == "fwd" and 880 or 660, 0.3, 0.28)
end

fx["Triangles"] = function(d)
    n1:setADSR(0.003, 0.06, 0.01, 0.08)
    n1:setVolume(0.16)
    n1:playNote(d == "fwd" and 550 or 420, 0.9, 0.12)
    n2:setADSR(0.001, 0.03, 0, 0.05)
    n2:setVolume(0.1)
    n2:playNote(d == "fwd" and 1100 or 850, 0.7, 0.06)
    tr:setADSR(0.003, 0.04, 0.01, 0.06)
    tr:setVolume(0.02)
    tr:playNote(d == "fwd" and 950 or 750, 0.3, 0.1)
end

fx["Bubbles"] = function(d)
    n1:setADSR(0.02, 0.15, 0.12, 0.2)
    n1:setVolume(0.14)
    n1:playNote(d == "fwd" and 420 or 300, 0.7, 0.4)
    n2:setADSR(0.01, 0.08, 0.06, 0.15)
    n2:setVolume(0.07)
    n2:playNote(d == "fwd" and 850 or 600, 0.5, 0.3)
    si:setADSR(0.01, 0.06, 0.08, 0.15)
    si:setVolume(0.025)
    si:playNote(d == "fwd" and 800 or 550, 0.3, 0.3)
end

fx["Blinds"] = function(d)
    n1:setADSR(0.005, 0.07, 0.02, 0.1)
    n1:setVolume(0.16)
    n1:playNote(d == "fwd" and 480 or 360, 0.85, 0.15)
    n2:setADSR(0.002, 0.04, 0.01, 0.06)
    n2:setVolume(0.09)
    n2:playNote(d == "fwd" and 950 or 720, 0.6, 0.08)
end

fx["Clock Wipe"] = function(d)
    n1:setADSR(0.015, 0.2, 0.15, 0.2)
    n1:setVolume(0.13)
    n1:playNote(d == "fwd" and 380 or 280, 0.7, 0.5)
    n2:setADSR(0.02, 0.15, 0.08, 0.15)
    n2:setVolume(0.05)
    n2:playNote(d == "fwd" and 750 or 560, 0.45, 0.4)
    tr:setADSR(0.01, 0.1, 0.06, 0.12)
    tr:setVolume(0.02)
    tr:playNote(d == "fwd" and 520 or 420, 0.25, 0.4)
end

fx["Wave Wipe"] = function(d)
    n1:setADSR(0.03, 0.22, 0.12, 0.25)
    n1:setVolume(0.16)
    n1:playNote(d == "fwd" and 320 or 230, 0.85, 0.5)
    n2:setADSR(0.04, 0.18, 0.08, 0.2)
    n2:setVolume(0.07)
    n2:playNote(d == "fwd" and 640 or 460, 0.5, 0.4)
    tr:setADSR(0.05, 0.15, 0.06, 0.2)
    tr:setVolume(0.02)
    tr:playNote(d == "fwd" and 480 or 360, 0.25, 0.38)
end

fx["Interleave"] = function(d)
    n1:setADSR(0.005, 0.08, 0.04, 0.12)
    n1:setVolume(0.15)
    n1:playNote(d == "fwd" and 520 or 400, 0.8, 0.2)
    n2:setADSR(0.002, 0.04, 0.02, 0.08)
    n2:setVolume(0.08)
    n2:playNote(d == "fwd" and 1050 or 800, 0.55, 0.12)
end

fx["Dither Bands"] = function(d)
    n1:setADSR(0.01, 0.15, 0.1, 0.2)
    n1:setVolume(0.14)
    n1:playNote(d == "fwd" and 430 or 330, 0.75, 0.35)
    n2:setADSR(0.005, 0.08, 0.04, 0.12)
    n2:setVolume(0.07)
    n2:playNote(d == "fwd" and 860 or 660, 0.5, 0.2)
    sq:setADSR(0.002, 0.03, 0.01, 0.05)
    sq:setVolume(0.02)
    sq:playNote(d == "fwd" and 700 or 560, 0.3, 0.08)
end

fx["Spiral"] = function(d)
    n1:setADSR(0.02, 0.22, 0.12, 0.25)
    n1:setVolume(0.15)
    n1:playNote(d == "fwd" and 440 or 330, 0.75, 0.5)
    n2:setADSR(0.015, 0.15, 0.06, 0.2)
    n2:setVolume(0.06)
    n2:playNote(d == "fwd" and 880 or 660, 0.45, 0.4)
    tr:setADSR(0.025, 0.12, 0.05, 0.18)
    tr:setVolume(0.02)
    tr:playNote(d == "fwd" and 650 or 480, 0.3, 0.45)
end

fx["Wind"] = function(d)
    n1:setADSR(0.04, 0.25, 0.15, 0.3)
    n1:setVolume(0.2)
    n1:playNote(d == "fwd" and 350 or 250, 1, 0.5)
    n2:setADSR(0.02, 0.15, 0.08, 0.2)
    n2:setVolume(0.08)
    n2:playNote(d == "fwd" and 700 or 500, 0.6, 0.4)
end

fx["Melt"] = function(d)
    n1:setADSR(0.01, 0.25, 0.12, 0.3)
    n1:setVolume(0.14)
    n1:playNote(d == "fwd" and 300 or 480, 0.75, 0.5)
    n2:setADSR(0.03, 0.18, 0.08, 0.22)
    n2:setVolume(0.06)
    n2:playNote(d == "fwd" and 600 or 960, 0.45, 0.4)
    si:setADSR(0.02, 0.15, 0.06, 0.25)
    si:setVolume(0.02)
    si:playNote(d == "fwd" and 450 or 700, 0.25, 0.45)
end

fx["Shatter"] = function(d)
    n1:setADSR(0.003, 0.1, 0.04, 0.2)
    n1:setVolume(0.22)
    n1:playNote(d == "fwd" and 500 or 380, 1, 0.22)
    n2:setADSR(0.001, 0.04, 0.02, 0.1)
    n2:setVolume(0.12)
    n2:playNote(d == "fwd" and 1200 or 900, 0.8, 0.1)
    sq:setADSR(0.001, 0.01, 0, 0.03)
    sq:setVolume(0.03)
    sq:playNote(d == "fwd" and 1400 or 1100, 0.4, 0.03)
end

fx["Scanline"] = function(d)
    n1:setADSR(0.008, 0.18, 0.1, 0.15)
    n1:setVolume(0.12)
    n1:playNote(d == "fwd" and 800 or 600, 0.65, 0.35)
    n2:setADSR(0.005, 0.1, 0.06, 0.1)
    n2:setVolume(0.06)
    n2:playNote(d == "fwd" and 1600 or 1200, 0.4, 0.25)
    sq:setADSR(0.006, 0.12, 0.05, 0.08)
    sq:setVolume(0.015)
    sq:playNote(d == "fwd" and 1800 or 1400, 0.25, 0.2)
end

fx["Pixel Shift"] = function(d)
    n1:setADSR(0.002, 0.07, 0.03, 0.12)
    n1:setVolume(0.16)
    n1:playNote(d == "fwd" and 450 or 340, 0.8, 0.2)
    n2:setADSR(0.001, 0.04, 0.015, 0.08)
    n2:setVolume(0.09)
    n2:playNote(d == "fwd" and 900 or 680, 0.6, 0.1)
end

fx["Hexagons"] = function(d)
    n1:setADSR(0.005, 0.09, 0.03, 0.12)
    n1:setVolume(0.14)
    n1:playNote(d == "fwd" and 530 or 400, 0.8, 0.18)
    n2:setADSR(0.008, 0.06, 0.02, 0.1)
    n2:setVolume(0.07)
    n2:playNote(d == "fwd" and 1060 or 800, 0.5, 0.15)
    tr:setADSR(0.005, 0.06, 0.02, 0.08)
    tr:setVolume(0.02)
    tr:playNote(d == "fwd" and 820 or 650, 0.3, 0.15)
end

fx["Diagonal"] = function(d)
    n1:setADSR(0.01, 0.12, 0.05, 0.18)
    n1:setVolume(0.16)
    n1:playNote(d == "fwd" and 400 or 290, 0.85, 0.28)
    n2:setADSR(0.005, 0.07, 0.03, 0.12)
    n2:setVolume(0.08)
    n2:playNote(d == "fwd" and 800 or 580, 0.55, 0.2)
    tr:setADSR(0.01, 0.06, 0.02, 0.1)
    tr:setVolume(0.02)
    tr:playNote(d == "fwd" and 600 or 440, 0.3, 0.22)
end

function TransitionSounds.play(name, dir)
    if TransitionSounds.enabled and fx[name] then
        fx[name](dir or "fwd")
    end
end
