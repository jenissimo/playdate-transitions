-- sfxkit -- a procedural sound-effects engine for Playdate.
--
-- Extracted from a shipping game (Nyandoku), where the sound layer was ~700
-- lines of hand-written emitters. About a third of that was engine and worth
-- keeping; the rest was that game's recipes. This file is the engine.
--
-- What it gives you over calling playdate.sound directly:
--
--   * a voice pool allocated once, so nothing allocates a synth mid-game;
--   * a TIME-BASED allocator, so two sounds never silently eat each other;
--   * a per-frame emit budget with priorities, so a frame that fires six
--     events does not overflow the audio channel;
--   * recipes as data, so a sound is a table you can diff, test and tweak
--     rather than a function you have to read;
--   * correct glide/LFO math (see SfxKit.glide -- the SDK's units are not what
--     you expect and the failure is silent).
--
-- The whole module is a no-op under host `lua`, so a project's recipe table
-- stays testable without the SDK. See CONVENTIONS.md rule 1.
SfxKit = SfxKit or {}

local pd  = rawget(_G, "playdate")
local snd = pd and pd.sound

-- ============================================================== pure section
-- Everything above the "device layer" banner runs under host lua and is
-- covered by test/sfxkit_test.lua.

-- Returns rate, center, depth for a pitch glide; play the note at f_lo.
--
-- Two traps live in these three numbers, and both fail SILENTLY -- playNote
-- never errors and never returns false for either:
--
--  1. A frequency modulator is scaled in OCTAVES, not Hz. The C reference for
--     setFrequencyModulator is explicit: "the signal is scaled so that a value
--     of 1 doubles the synth pitch (i.e. an octave up) and -1 halves it". So
--     the span is log2(f_hi/f_lo). Passing a Hz difference here asks for a
--     sweep of tens of octaves -- past Nyquist within a millisecond, i.e. a
--     click or silence rather than a glide.
--  2. A sawtooth traverses its full +1..-1 range over ONE period, so
--     rate = 1/T. At 1/(2T) every glide stops half its span short.
--
-- center == depth means the signal spans 0..span (SawtoothUp, rising from
-- f_lo) or span..0 (SawtoothDown, falling to f_lo) -- which is why the same
-- pair works for both directions and the note is always played at f_lo.
function SfxKit.glide(f_hi, f_lo, seconds)
    local half = math.log(f_hi / f_lo, 2) / 2
    return 1 / seconds, half, half
end

-- Semitone ratio. Handy for building sample-rate tables against a recorded
-- pitch: MEOW = { SfxKit.semitone(-4), SfxKit.semitone(-2), ... }
function SfxKit.semitone(n)
    return 2 ^ (n / 12)
end

-- Detune by +/- `cents`, with the random draw injected so a test is
-- deterministic. Repeated one-shots at a bit-identical pitch read as a tape
-- loop; a few cents of scatter is what stops that.
function SfxKit.detune(hz, r01, cents)
    local span = (cents or 8) / 1200
    return hz * (2 ^ (span * (r01 * 2 - 1)))
end

-- ------------------------------------------------------------- allocator
-- The reason this module exists in a library rather than in a game.
--
-- A Playdate synth buffers exactly ONE note event. Play a second note on a
-- synth that is still ringing and the first is not mixed with it -- it is
-- deleted. Hand-assigning voices ("use LEAD[4..5] here, because the confirm
-- sound took LEAD[1..3] in this same frame") is how a game normally copes, and
-- it does not survive being moved to another project: the assignments encode
-- one specific scene graph, and they only cover collisions inside a single
-- frame. A note scheduled 0.9 s ahead is still cut off by an emit three frames
-- later.
--
-- So: reserve by AUDIO TIME, not by frame. A voice is free when the sound it
-- is holding has finished. The allocator is pure -- the clock is a parameter --
-- which is what makes it host-testable.

local Alloc = {}
Alloc.__index = Alloc

function SfxKit.newAllocator(counts)
    local a = setmetatable({ groups = {} }, Alloc)
    for name, n in pairs(counts or {}) do
        local busy, stamp = {}, {}
        for i = 1, n do busy[i], stamp[i] = -1e9, -1 end
        a.groups[name] = { n = n, busy = busy, stamp = stamp }
    end
    return a
end

-- Returns a voice index, or nil when the group has nothing to give.
--
-- A voice is available only if BOTH hold:
--
--   1. its note has finished in audio time (busy <= t0). This is the
--      cross-frame constraint: a note scheduled 0.9 s ahead must not be cut
--      off by an emit three frames later.
--   2. it was not already handed out THIS FRAME (stamp ~= frame). This is the
--      same-batch constraint, and it is not the same thing as (1): a synth
--      holds exactly ONE pending note event, so scheduling a second note on it
--      before the first has begun *deletes* the first -- even when the two do
--      not overlap in time at all. Two notes 0.14 s apart in the same frame
--      are both still pending when the second is scheduled.
--
-- Dropping (1) gives you a silently truncated pad. Dropping (2) gives you a
-- chord that loses a note whenever two recipes land together, which is the
-- exact bug that hand-assigned voice tables exist to prevent.
--
-- `steal` (used by priority-1 recipes) takes the voice that frees up soonest
-- rather than returning nil -- but it still respects (2), because clobbering a
-- note scheduled moments ago in this same batch is never an improvement over
-- staying silent.
function Alloc:claim(group, t0, t1, steal, frame)
    local g = self.groups[group]
    if not g then return nil end
    local best, best_free = nil, nil
    for i = 1, g.n do
        if g.stamp[i] ~= frame then
            local free_at = g.busy[i]
            if free_at <= t0 then
                -- Among free voices take the one idle longest: it maximises
                -- the gap before this voice is a candidate again, which keeps
                -- a fast arpeggio off the same synth twice running.
                if not best_free or free_at < best_free then best, best_free = i, free_at end
            end
        end
    end
    if not best and steal then
        for i = 1, g.n do
            if g.stamp[i] ~= frame and (not best_free or g.busy[i] < best_free) then
                best, best_free = i, g.busy[i]
            end
        end
    end
    if not best then return nil end
    g.busy[best], g.stamp[best] = t1, frame
    return best
end

-- Only for tests and for a hard reset (scene teardown): forget every
-- reservation. Never call this per frame -- the reservations ARE the state.
function Alloc:reset()
    for _, g in pairs(self.groups) do
        for i = 1, g.n do g.busy[i], g.stamp[i] = -1e9, -1 end
    end
end

-- ------------------------------------------------------------- recipes
-- A recipe is data:
--
--   { prio = 2, debounce = 6, notes = {
--       { group = "lead", hz = 392.00, vol = 0.30, len = 0.07, at = 0.000,
--         adsr = { 0, 0.050, 0, 0.040 }, pw = 0.25 },
--       { group = "glide_up", from = 130.81, to = 261.63, vol = 0.28,
--         len = 0.35, at = 0.000, adsr = { 0, 0, 1, 0.10 } },
--       { sample = "meow", rate = 1.0, vol = 0.85 },
--   } }
--
-- prio 1 is exempt from the frame budget and may steal a voice; 2 and 3 spend
-- the budget and are dropped when it is gone.
--
-- A recipe may also be a function(...) -> recipe, for the sounds that depend on
-- game state (a chime that climbs with a streak, a hit that changes when it is
-- the last life). Keep those functions pure and returning plain tables: that is
-- what lets a project unit-test its own sound design.

-- How long a voice is really occupied: the scheduled note plus its release
-- tail. Getting this wrong in the cheap direction (ignoring release) is what
-- makes a pad get chopped by the next emit.
function SfxKit.note_span(note)
    local at  = note.at or 0
    local len = note.len or 0
    local rel = note.adsr and note.adsr[4] or 0
    return at, at + len + rel
end

-- Which budgets a recipe will charge: one for its synth notes, one for its
-- samples, regardless of how many of each it has. Pure, so the accounting can
-- be asserted on the host -- the device path around it cannot be.
function SfxKit.wants(recipe)
    local synth, sample = false, false
    for _, n in ipairs(recipe.notes or {}) do
        if n.sample then sample = true else synth = true end
    end
    return synth, sample
end

-- Structural validation, exposed so a project can assert its whole recipe table
-- in a host test instead of discovering a typo as silence on the device.
-- Returns true, or false plus a message.
function SfxKit.validate(recipe, groups, samples)
    if type(recipe) ~= "table" then return false, "recipe is not a table" end
    if type(recipe.notes) ~= "table" or #recipe.notes == 0 then
        return false, "recipe has no notes"
    end
    local prio = recipe.prio or 2
    if prio ~= 1 and prio ~= 2 and prio ~= 3 then
        return false, "prio must be 1, 2 or 3"
    end
    for i, n in ipairs(recipe.notes) do
        local where = "note " .. i .. ": "
        if n.sample then
            if samples and not samples[n.sample] then
                return false, where .. "unknown sample '" .. tostring(n.sample) .. "'"
            end
        elseif n.group then
            if groups and not groups[n.group] then
                return false, where .. "unknown group '" .. tostring(n.group) .. "'"
            end
            local gliding = n.from ~= nil or n.to ~= nil
            if gliding and not (n.from and n.to) then
                return false, where .. "a glide needs both from and to"
            end
            if not gliding and not n.hz then
                return false, where .. "needs hz (or from/to for a glide)"
            end
            -- playNote(0, ...) silently becomes noteOff(), so a zero here is
            -- not a low note, it is a cancelled one.
            if n.hz == 0 then return false, where .. "hz must not be 0" end
        else
            return false, where .. "needs either group or sample"
        end
        if n.adsr and #n.adsr ~= 4 then return false, where .. "adsr must be 4 values" end
    end
    return true
end

-- ============================================================ device layer

SfxKit._ready = false
SfxKit._frame = 0

-- setParameter index for pulse width. Confirmed 1-based: the docs enumerate the
-- wavetable parameters as "1: x position ... 2: x position 0-1 scaled", and the
-- SDK's own wavetable.lua does setParameterMod(2, lfo) with the comment "param
-- 2 changes the table position using [0,1] scaling" -- which only lines up
-- 1-based. (Single File Examples/synth.lua calls setParameter(0, n); that one
-- is buggy -- index 0 is a no-op.) Square has exactly one parameter and it is
-- the pulse width.
local PW <const> = 1

-- Friendly names for the SDK's waveform constants, verified against the
-- installed SDK rather than remembered. The three PO* waves are the Pocket
-- Operator oscillators; they take a second parameter, so a group using one
-- wants `pw` in its notes to mean that parameter instead of pulse width.
local WAVES = {
    square    = "kWaveSquare",
    triangle  = "kWaveTriangle",
    sine      = "kWaveSine",
    sawtooth  = "kWaveSawtooth",
    noise     = "kWaveNoise",
    po_phase  = "kWavePOPhase",
    po_digital = "kWavePODigital",
    po_vosim  = "kWavePOVosim",
}

local LFO_SHAPES = {
    sawtoothUp    = "kLFOSawtoothUp",
    sawtoothDown  = "kLFOSawtoothDown",
    triangle      = "kLFOTriangle",
    square        = "kLFOSquare",
    sine          = "kLFOSine",
    sampleAndHold = "kLFOSampleAndHold",
}

local buses    = {}    -- name -> channel
local groups   = {}    -- name -> { voices = {synth}, lfo = lfo|nil, wave = str }
local samples  = {}    -- name -> { players = {sampleplayer}, slot = n }
local recipes  = {}
local alloc                              -- SfxKit.newAllocator over the groups
local budget_synth, budget_sample = 0, 0
local budget_max_synth, budget_max_sample = 2, 1
local debounce_until = {}

-- Injectable so tests can drive the allocator without the SDK.
local clock = function() return snd and snd.getCurrentTime() or 0 end
function SfxKit.setClock(fn) clock = fn end
function SfxKit.now() return clock() end

local function claim_budget(prio, sample)
    if not SfxKit._ready then return false end
    if prio == 1 then return true end
    if sample then
        if budget_sample <= 0 then return false end
        budget_sample = budget_sample - 1
    else
        if budget_synth <= 0 then return false end
        budget_synth = budget_synth - 1
    end
    return true
end

--- Allocate every voice, bus and sample player. Call once, at boot, before the
--- first playdate.update. Nothing in this module allocates afterwards.
---
--- spec = {
---   buses   = { sfx = { volume = 0.85, crush = { amount, undersampling, mix } } },
---   groups  = { lead = { wave = "square", count = 6, bus = "sfx" },
---               glide_up = { wave = "square", count = 1, bus = "sfx",
---                            lfo = "sawtoothUp" } },
---   samples = { meow = { path = "sound/meow_1", copies = 2, bus = "voice" } },
---   budget  = { synth = 2, sample = 1 },
--- }
function SfxKit.load(spec)
    if not snd then return end
    spec = spec or {}
    local ok = true

    for name, b in pairs(spec.buses or {}) do
        local ch = snd.channel.new()
        ch:setVolume(b.volume or 1.0)
        -- An effect belongs to a CHANNEL, not to a note. Adding it here once is
        -- deliberate: shaping a single sound with it would change every sound
        -- on the bus, immediately and globally. That is also why a project that
        -- wants two crush amounts needs two buses.
        if b.crush then
            local c = snd.bitcrusher.new()
            c:setAmount(b.crush.amount or 0.2)
            c:setUndersampling(b.crush.undersampling or 0.2)
            c:setMix(b.crush.mix or 0.3)
            ch:addEffect(c)
            b._effect = c
        end
        buses[name] = ch
    end

    local counts = {}
    for name, g in pairs(spec.groups or {}) do
        local wave = snd[WAVES[g.wave or "square"]]
        local ch   = buses[g.bus] or nil
        local voices = {}
        for i = 1, (g.count or 1) do
            local s = snd.synth.new(wave)
            if ch then ch:addSource(s) end
            voices[i] = s
        end
        local lfo
        if g.lfo then
            -- One modulator shared by the group's voices. Attached once and
            -- NEVER cleared with nil -- the SDK's own sndtest.lua warns that
            -- can error. Only setRate/setCenter/setDepth are ever called.
            lfo = snd.lfo.new(snd[LFO_SHAPES[g.lfo]])
            lfo:setRetrigger(true)
            for i = 1, #voices do voices[i]:setFrequencyMod(lfo) end
        end
        groups[name] = { voices = voices, lfo = lfo }
        counts[name] = #voices
    end
    alloc = SfxKit.newAllocator(counts)

    for name, s in pairs(spec.samples or {}) do
        local base, err = snd.sampleplayer.new(s.path)
        if not base then
            -- Fail loudly in development, silently for a player: a renamed
            -- asset must not brick somebody's console.
            print("sfxkit: missing sample " .. tostring(s.path) .. " (" .. tostring(err) .. ")")
            ok = false
        else
            local ch = buses[s.bus]
            local players = { base }
            -- copy() shares the sample DATA, so a second player costs no
            -- meaningful RAM and lets two overlapping one-shots both sound
            -- instead of cutting each other off.
            for i = 2, (s.copies or 1) do players[i] = base:copy() end
            for _, p in ipairs(players) do if ch then ch:addSource(p) end end
            samples[name] = { players = players, slot = 0 }
        end
    end

    local b = spec.budget or {}
    budget_max_synth  = b.synth or 2
    budget_max_sample = b.sample or 1
    -- Seed the budget here rather than waiting for the first frame(): a game
    -- normally emits a boot sound before its first playdate.update runs, and
    -- without this that very first sound is dropped.
    budget_synth, budget_sample = budget_max_synth, budget_max_sample

    SfxKit._ready = ok
    SfxKit.buses, SfxKit.groups, SfxKit.samples = buses, groups, samples
    return ok
end

--- MUST be the first statement of playdate.update. Several independent input
--- branches can each want a sound in one frame; this is what stops all of them
--- sounding at once and overflowing the channel.
function SfxKit.frame()
    SfxKit._frame = SfxKit._frame + 1
    budget_synth, budget_sample = budget_max_synth, budget_max_sample
end

--- Register a recipe (a table, or a function(...) returning one).
function SfxKit.define(name, recipe)
    recipes[name] = recipe
end

--- Register a whole table of them at once.
function SfxKit.defineAll(tbl)
    for name, r in pairs(tbl) do recipes[name] = r end
end

function SfxKit.recipe(name)
    return recipes[name]
end

--- Validate every registered recipe against the loaded groups/samples. Meant
--- for a host test: a project calls this after defineAll and gets a typo'd
--- group name as a test failure instead of as silence on the device.
--- Returns true, or false plus the offending name and message.
function SfxKit.validateAll(groupNames, sampleNames)
    for name, r in pairs(recipes) do
        if type(r) == "table" then
            local ok, err = SfxKit.validate(r, groupNames, sampleNames)
            if not ok then return false, name, err end
        end
    end
    return true
end

local function play_note(n, t, prio)
    local at, ends = SfxKit.note_span(n)
    local idx = alloc:claim(n.group, t + at, t + ends, prio == 1, SfxKit._frame)
    if not idx then return false end
    local g = groups[n.group]
    local v = g.voices[idx]
    if n.pw then v:setParameter(PW, n.pw) end
    local a = n.adsr
    -- The pool is shared, so the previous emit left ITS envelope on this synth.
    -- Every note sets the ADSR it wants; there is no "default" to fall back on.
    if a then v:setADSR(a[1], a[2], a[3], a[4]) end
    if n.from and n.to then
        local hi, lo = math.max(n.from, n.to), math.min(n.from, n.to)
        local rate, center, depth = SfxKit.glide(hi, lo, n.len or 0.3)
        g.lfo:setRate(rate)
        g.lfo:setCenter(center)
        g.lfo:setDepth(depth)
        -- Always played at the LOW end: the modulator supplies the direction.
        v:playNote(lo, n.vol or 0.25, n.len, t + at)
    else
        -- A noise voice still needs a nonzero pitch it will ignore, because
        -- playNote(0, ...) silently becomes noteOff().
        v:playNote(n.hz, n.vol or 0.25, n.len, t + at)
    end
    return true
end

local function play_sample(n)
    local s = samples[n.sample]
    if not s then return false end
    s.slot = (s.slot % #s.players) + 1
    local p = s.players[s.slot]
    if n.rate then p:setRate(n.rate) end
    p:setVolume(n.vol or 1.0)
    -- play(), never playAt(): a sampleplayer queues exactly ONE scheduled event
    -- and a second playAt silently overwrites it. Only use playAt when the
    -- recipe genuinely needs the sample offset inside a longer gesture.
    if n.at and n.at > 0 then
        p:playAt(SfxKit.now() + n.at, n.vol or 1.0, n.vol or 1.0, n.rate or 1.0)
    else
        p:play(1)
    end
    return true
end

--- Fire a registered recipe. Extra arguments are passed to a function recipe.
--- Returns true if anything actually sounded.
function SfxKit.emit(name, ...)
    if not SfxKit._ready then return false end
    local r = recipes[name]
    if not r then return false end
    if type(r) == "function" then r = r(...) end
    if type(r) ~= "table" then return false end

    -- Mash guard. The only defence against a player leaning on a button that
    -- produces a rejection sound: silence on the second press IS the feedback.
    --
    -- `debounce_key` lets several recipes share one cooldown. That is not a
    -- nicety: a game usually has more than one way to be told "no" (A on a
    -- closed cell, B on the same cell), and per-recipe timers let a player
    -- alternate buttons and defeat the guard entirely.
    if r.debounce then
        local key = r.debounce_key or name
        local until_frame = debounce_until[key] or 0
        if SfxKit._frame < until_frame then return false end
        debounce_until[key] = SfxKit._frame + r.debounce
    end

    local prio = r.prio or 2

    -- The budget is spent per EMIT, not per note. A recipe is one *sound* -- a
    -- three-note arpeggio is still one sound -- so charging each note would
    -- make any chord unplayable at a realistic budget, and would truncate
    -- gestures halfway through in a way that sounds like a bug rather than
    -- like restraint. The synth and sample budgets are charged independently
    -- so a recipe that layers a one-shot over a chord can still get its
    -- one-shot when the synth budget is gone.
    local wants_synth, wants_sample = SfxKit.wants(r)
    local may_synth  = wants_synth  and claim_budget(prio, false)
    local may_sample = wants_sample and claim_budget(prio, true)
    if not may_synth and not may_sample then return false end

    local t = SfxKit.now()
    local sounded = false
    for _, n in ipairs(r.notes) do
        if n.sample then
            if may_sample then sounded = play_sample(n) or sounded end
        elseif may_synth then
            sounded = play_note(n, t, prio) or sounded
        end
    end
    return sounded
end

--- Escape hatch: the raw voice pool, for the one sound a project needs to
--- build imperatively. Prefer a recipe.
function SfxKit.voice(group, i)
    local g = groups[group]
    return g and g.voices[i or 1]
end

function SfxKit.allocator()
    return alloc
end

return SfxKit
