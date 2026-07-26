-- jukebox -- streamed music with crossfades, ducking and a pause guard.
--
-- Small on purpose: a fileplayer already does the hard part. What a game
-- actually keeps re-deriving is the bookkeeping around it -- "don't restart the
-- track that is already playing", "don't let two crossfades race", "un-duck
-- when the system menu closes" -- and every one of those, done wrong, reads as
-- a music-logic bug rather than an audio glitch.
--
-- Deliberately independent of sfxkit: no import-order coupling, no shared
-- state. Where a moment needs both (a win jingle ducking the bed) the SCENE
-- calls both, because the scene is the only thing that knows the moment.
Jukebox = Jukebox or {}

local pd  = rawget(_G, "playdate")
local snd = pd and pd.sound

-- ============================================================== pure section

-- Per-track nominal volume. A streamed bed and a one-shot rarely want the same
-- gain, and baking the difference into the asset is worse: it makes the master
-- unusable anywhere else. Set this from the project.
Jukebox.VOL = {}
Jukebox.DEFAULT_VOL = 0.5

-- Multiplier applied to whatever is nominal, not an absolute level -- so a
-- quiet track ducks to a quiet duck.
Jukebox.DUCK_PAUSE = 0.25

Jukebox._ready   = false
Jukebox._current = nil
Jukebox._pending = false
Jukebox._want    = nil

local players = {}

function Jukebox.nominal(name)
    return Jukebox.VOL[name or Jukebox._current] or Jukebox.DEFAULT_VOL
end

function Jukebox.current()
    return Jukebox._current
end

-- ============================================================ device layer

--- spec = { tracks = { menu = "sound/main_menu", level = "sound/level" },
---          volumes = { menu = 0.45, level = 0.55 },
---          buffer = 1.0 }
function Jukebox.load(spec)
    if not snd then return end
    spec = spec or {}
    -- A 1.0 s buffer, not the 0.25 s default. A heavy frame -- a procedural
    -- generator, a big scene build -- can starve the stream, and the default
    -- failure mode is a stutter followed by a restart from the top of the
    -- track, which looks like a bug in your music logic rather than an
    -- underrun.
    local size = spec.buffer or 1.0
    local ok = true
    for name, path in pairs(spec.tracks or {}) do
        local p = snd.fileplayer.new(size)
        -- load() only *instructs* the player -- "the file isn't loaded until
        -- play() or setBufferSize() is called" -- and documents no return
        -- value. So a bad path cannot be detected here; play() is where it
        -- surfaces.
        if p then p:load(path) else ok = false end
        players[name] = p
    end
    for name, v in pairs(spec.volumes or {}) do Jukebox.VOL[name] = v end
    Jukebox._ready = ok and next(players) ~= nil
    Jukebox.players = players
    return Jukebox._ready
end

--- Start a track, or do nothing if it is already the one playing.
--- That guard is the point: most call sites are "return to the menu", and three
--- of four of them are returns to a menu whose music never stopped. A restart
--- there is the single most noticeable bug in a music layer.
function Jukebox.play(name)
    if not Jukebox._ready then return false end
    local p = players[name]
    if not p then return false end
    -- The _pending check matters on the abort path: a caller may ask for a
    -- crossfade and then, in the SAME frame, ask to play the destination
    -- directly. The switch is still fading so the track is not playing yet --
    -- without this the track starts here AND the fade callback starts it again.
    if Jukebox._current == name and (Jukebox._pending or p:isPlaying()) then return true end
    Jukebox._pending = false
    local v = Jukebox.nominal(name)
    p:setVolume(v, v)
    -- First moment the file is actually touched, so the only place a bad path
    -- can be caught.
    if not p:play(0) then          -- repeatCount 0 = loop forever
        print("jukebox: could not play " .. tostring(name))
        return false
    end
    Jukebox._current = name
    return true
end

function Jukebox.stop()
    if not Jukebox._ready then return end
    local p = players[Jukebox._current]
    if p then p:stop() end
    Jukebox._current, Jukebox._pending, Jukebox._want = nil, false, nil
end

--- Crossfade. Every fade goes through fileplayer:setVolume's own fade argument,
--- which runs on the audio thread for free. Never hand-roll a ramp in
--- playdate.update -- these land on the busiest scene-switch frames there are.
function Jukebox.switch(from, to, out_s, in_s)
    if not Jukebox._ready then return end
    local a, b = players[from], players[to]
    if not a or not b then return end
    -- _want, not a captured local: a second switch while the first is still
    -- fading (start a level, then back out of it inside 0.35 s) must not leave
    -- two crossfades racing. The in-flight fade reads _want when it lands, so
    -- rapid switches collapse to the last one asked for.
    Jukebox._want = to
    if Jukebox._pending then return end
    if Jukebox._current ~= from then
        Jukebox.play(to)
        return
    end
    Jukebox._current = to
    Jukebox._pending = true
    a:setVolume(0, 0, out_s or 0.5, function(p)
        -- stop() inside the callback, because the docs are explicit that a
        -- fileplayer must not be playing when load() is called.
        p:stop()
        Jukebox._pending = false
        local want   = Jukebox._want
        local target = players[want]
        if not target then return end
        Jukebox._current = want
        target:setVolume(0, 0)
        if target:play(0) then
            local v = Jukebox.nominal(want)
            target:setVolume(v, v, in_s or 0.5)
        end
    end)
end

--- Duck to an absolute level (a jingle needs room).
function Jukebox.duck(level, seconds)
    if not Jukebox._ready then return end
    local p = players[Jukebox._current]
    if not p then return end
    local v = level or (Jukebox.nominal() * 0.4)
    p:setVolume(v, v, seconds or 0.15)
end

function Jukebox.restore(seconds)
    if not Jukebox._ready then return end
    local p = players[Jukebox._current]
    if not p then return end
    local v = Jukebox.nominal()
    p:setVolume(v, v, seconds or 1.20)
end

--- Wire these to playdate.gameWillPause / gameWillResume.
function Jukebox.pause()
    Jukebox.duck(Jukebox.nominal() * Jukebox.DUCK_PAUSE, 0.12)
end

--- Not optional. Without a resume hook the music stays ducked for the rest of
--- the session after the first pause -- and anything a game puts in the system
--- menu guarantees players will open it.
function Jukebox.resume()
    Jukebox.restore(0.25)
end

return Jukebox
