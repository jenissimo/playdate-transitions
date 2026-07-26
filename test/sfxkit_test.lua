package.path = package.path .. ";./?.lua;./test/?.lua"
local A = require("assert")
local S = require("sfxkit")

-- Rule 1: the module must load with no `playdate` global at all, and every
-- device entry point must no-op rather than crash. This is the test that keeps
-- a consumer's own sound design host-testable.
A.falsy(rawget(_G, "playdate"), "host lua has no playdate global")
A.falsy(S._ready, "not ready without the SDK")
A.eq(S.load({ groups = { lead = { wave = "square", count = 2 } } }), nil, "load() no-ops off-device")
S.define("boop", { notes = { { group = "lead", hz = 440, len = 0.1 } } })
A.falsy(S.emit("boop"), "emit() no-ops off-device")
S.frame()   -- must not throw

-- ------------------------------------------------------------------- glide
-- An exact doubling over 0.35 s. depth is in OCTAVES (half the span, because
-- the modulator is centred), and rate is 1/T, not 1/(2T). Round numbers here
-- rather than note frequencies: equal-tempered C4/C3 is 261.63/130.81 =
-- 2.00008, so a musical pair cannot pin the maths to the precision that would
-- actually catch a bug.
local rate, center, depth = S.glide(200, 100, 0.35)
A.near(rate, 1 / 0.35, 1e-12, "glide rate is 1/seconds")
A.near(center, 0.5, 1e-12, "one octave -> centre 0.5")
A.eq(center, depth, "centre and depth are the same number")

-- Two octaves must give twice the depth: the span is logarithmic, so a test
-- that only ever checks one octave would pass with a linear (Hz) bug in it.
local _, c2 = S.glide(400, 100, 1.0)
A.near(c2, 1.0, 1e-12, "two octaves -> centre 1.0")

-- And the real musical pair still lands where it should, just less tightly.
local _, cm = S.glide(261.63, 130.81, 0.35)
A.near(cm, 0.5, 1e-4, "C3 -> C4 is one octave to within a rounding error")

-- A falling glide is expressed by the LFO shape, not by the numbers, so the
-- same call with the arguments the other way round is still positive.
local _, c3 = S.glide(392.00, 130.81, 0.4)
A.truthy(c3 > 0, "depth is always positive")

-- --------------------------------------------------------------- semitone
A.near(S.semitone(0), 1.0, 1e-12, "unison")
A.near(S.semitone(12), 2.0, 1e-12, "octave")
A.near(S.semitone(-12), 0.5, 1e-12, "octave down")
A.near(S.semitone(7), 1.498307, 1e-6, "fifth")

-- ----------------------------------------------------------------- detune
-- r01 = 0.5 is the centre of the window and must return the pitch untouched;
-- anything else means a "detune" that transposes.
A.near(S.detune(440, 0.5, 8), 440, 1e-9, "mid draw does not shift pitch")
A.truthy(S.detune(440, 1.0, 8) > 440, "top of the window is sharp")
A.truthy(S.detune(440, 0.0, 8) < 440, "bottom of the window is flat")
-- 8 cents is 8/1200 of an octave -- about 0.46 % at A4. If this ever comes out
-- in the percents, the scatter has become a transposition.
A.truthy(S.detune(440, 1.0, 8) - 440 < 3, "8 cents stays under 3 Hz at A4")

-- -------------------------------------------------------------- note_span
local at, ends = S.note_span({ at = 0.1, len = 0.2, adsr = { 0, 0, 0, 0.05 } })
A.near(at, 0.1, 1e-9, "span starts at `at`")
-- The release tail is the whole point: a voice reserved only for `len` gets
-- chopped by the next emit while it is still audibly ringing.
A.near(ends, 0.35, 1e-9, "span includes the release tail")
local at2, ends2 = S.note_span({ hz = 440 })
A.eq(at2, 0, "missing `at` defaults to 0")
A.eq(ends2, 0, "a note with no length occupies nothing")

-- -------------------------------------------------------------- allocator
local a = S.newAllocator({ lead = 2, tick = 1 })

A.eq(a:claim("lead", 0, 1, false, 1), 1, "first claim takes voice 1")
A.eq(a:claim("lead", 0, 1, false, 1), 2, "second claim takes the other voice")
A.eq(a:claim("lead", 0, 1, false, 1), nil, "third claim in the same window is dropped")
A.eq(a:claim("nope", 0, 1, false, 1), nil, "unknown group claims nothing")

-- Priority 1 steals rather than going silent -- but only from an EARLIER frame.
A.eq(a:claim("lead", 0, 1, true, 1), nil, "steal never clobbers a note scheduled this frame")
A.eq(a:claim("lead", 0, 1, true, 2), 1, "on a later frame it takes the voice freeing soonest")

-- Time, not frames, is what frees a voice: this is the case hand-assigned
-- voices never covered -- a note scheduled 0.9 s ahead being cut off by an
-- emit a few frames later.
A.eq(a:claim("lead", 1.5, 2.0, false, 3), 1, "voice 1 is free once its note has ended")
A.eq(a:claim("lead", 1.5, 2.0, false, 3), 2, "and so is voice 2")
A.eq(a:claim("lead", 1.4, 2.0, false, 4), nil, "still busy a hair before it ends")

-- The same-frame rule, which is NOT implied by the time rule. A synth holds one
-- pending note event, so a second note scheduled on it in the same batch
-- deletes the first -- even when the two do not overlap in time at all. Two
-- notes 0.3 s apart, both scheduled in one frame, still need two voices.
local c = S.newAllocator({ lead = 2 })
A.eq(c:claim("lead", 0.0, 0.1, false, 7), 1, "an early short note takes voice 1")
A.eq(c:claim("lead", 0.3, 0.4, false, 7), 2, "a later, non-overlapping note in the SAME frame needs its own voice")
A.eq(c:claim("lead", 0.6, 0.7, false, 7), nil, "a third one in that frame has nowhere to go")
A.eq(c:claim("lead", 0.6, 0.7, false, 8), 1, "and lands fine once the batch has moved on")

-- A single-voice group is a real allocation policy, not a special case: it is
-- how a project says "there is only one riser, and the important one wins".
A.eq(a:claim("tick", 0, 0.2, false, 5), 1, "single-voice group hands out its voice")
A.eq(a:claim("tick", 0.1, 0.3, false, 6), nil, "and refuses while it is busy")
A.eq(a:claim("tick", 0.1, 0.3, true, 6), 1, "unless the caller may steal")

a:reset()
A.eq(a:claim("lead", 0, 1, false, 9), 1, "reset forgets every reservation")

-- Determinism: the same claim sequence on a fresh allocator gives the same
-- voices. Sound design that shifts under you is untestable.
local b1, b2 = S.newAllocator({ lead = 3 }), S.newAllocator({ lead = 3 })
local seq1, seq2 = {}, {}
for i = 1, 6 do
    seq1[i] = b1:claim("lead", i * 0.1, i * 0.1 + 0.25, false, i) or -1
    seq2[i] = b2:claim("lead", i * 0.1, i * 0.1 + 0.25, false, i) or -1
end
for i = 1, 6 do A.eq(seq1[i], seq2[i], "allocation is deterministic at step " .. i) end

-- ----------------------------------------------------------------- wants
-- The budget is charged per emit, not per note: a recipe is one *sound*. A
-- three-note arpeggio charging three units would be unplayable at any sane
-- budget, and would get truncated mid-gesture.
local w_syn, w_smp = S.wants({ notes = {
    { group = "lead", hz = 261.63 }, { group = "lead", hz = 329.63 }, { group = "lead", hz = 392.00 },
} })
A.truthy(w_syn, "a chord charges the synth budget")
A.falsy(w_smp, "and not the sample budget")

w_syn, w_smp = S.wants({ notes = { { sample = "meow" } } })
A.falsy(w_syn, "a pure one-shot does not charge the synth budget")
A.truthy(w_smp, "it charges the sample budget")

-- The two budgets are independent so a layered recipe can still land its
-- one-shot on a frame where the synth budget is already gone.
w_syn, w_smp = S.wants({ notes = { { group = "lead", hz = 440 }, { sample = "meow" } } })
A.truthy(w_syn and w_smp, "a layered recipe charges both")

w_syn, w_smp = S.wants({ notes = {} })
A.falsy(w_syn or w_smp, "an empty recipe charges nothing")

-- --------------------------------------------------------------- validate
local G, SM = { lead = true, glide = true }, { meow = true }

A.truthy(S.validate({ notes = { { group = "lead", hz = 440, len = 0.1 } } }, G, SM),
    "a plain note validates")
A.truthy(S.validate({ notes = { { sample = "meow", rate = 1.0 } } }, G, SM),
    "a sample note validates")
A.truthy(S.validate({ notes = { { group = "glide", from = 130, to = 260, len = 0.3 } } }, G, SM),
    "a glide validates")

A.falsy(S.validate({ notes = {} }, G, SM), "an empty recipe is rejected")
A.falsy(S.validate({ notes = { { hz = 440 } } }, G, SM), "a note needs a group or a sample")
A.falsy(S.validate({ notes = { { group = "nope", hz = 440 } } }, G, SM), "unknown group is caught")
A.falsy(S.validate({ notes = { { sample = "nope" } } }, G, SM), "unknown sample is caught")
A.falsy(S.validate({ notes = { { group = "glide", from = 130, len = 0.3 } } }, G, SM),
    "a half-specified glide is caught")
A.falsy(S.validate({ notes = { { group = "lead" } } }, G, SM), "a note with no pitch is caught")
-- playNote(0, ...) silently becomes noteOff(), so a zero here is a cancelled
-- note rather than a low one -- exactly the kind of silent failure this
-- validator exists to turn into a test failure.
A.falsy(S.validate({ notes = { { group = "lead", hz = 0, len = 0.1 } } }, G, SM),
    "hz = 0 is caught, because it means noteOff")
A.falsy(S.validate({ notes = { { group = "lead", hz = 440, adsr = { 0, 0.1 } } } }, G, SM),
    "a short adsr is caught")
A.falsy(S.validate({ prio = 9, notes = { { group = "lead", hz = 440 } } }, G, SM),
    "an out-of-range priority is caught")

-- validateAll walks the registered table, which is how a project turns "I
-- typo'd a group name" from silence-on-device into a red test.
S.define("good", { notes = { { group = "lead", hz = 440, len = 0.1 } } })
A.truthy(S.validateAll(G, SM), "all-good recipe table validates")
S.define("bad", { notes = { { group = "typo", hz = 440, len = 0.1 } } })
local ok, which = S.validateAll(G, SM)
A.falsy(ok, "validateAll fails on a bad recipe")
A.eq(which, "bad", "and names the offender")
