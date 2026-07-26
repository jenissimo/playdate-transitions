package.path = package.path .. ";./?.lua;./test/?.lua"
local A = require("assert")
local J = require("jukebox")

-- Rule 1: loads and stays inert with no SDK present.
A.falsy(rawget(_G, "playdate"), "host lua has no playdate global")
A.falsy(J._ready, "not ready without the SDK")
A.eq(J.load({ tracks = { menu = "sound/menu" } }), nil, "load() no-ops off-device")
A.falsy(J.play("menu"), "play() no-ops off-device")
A.eq(J.current(), nil, "nothing is playing")
J.switch("menu", "level")   -- must not throw
J.duck(); J.restore(); J.pause(); J.resume(); J.stop()

-- ---------------------------------------------------------------- volumes
-- The generalisation over the game this came from: tracks are named by the
-- project, not by the library. Anything unnamed falls back rather than
-- silencing itself, because a missing entry is a config slip and a silent
-- game is a much worse symptom than a slightly wrong level.
J.VOL = { menu = 0.45, level = 0.55 }
A.eq(J.nominal("menu"), 0.45, "named track uses its own volume")
A.eq(J.nominal("level"), 0.55, "and so does the other one")
A.eq(J.nominal("nope"), J.DEFAULT_VOL, "an unknown track falls back to the default")

J._current = "level"
A.eq(J.nominal(), 0.55, "nominal() with no argument reads the current track")
J._current = nil
A.eq(J.nominal(), J.DEFAULT_VOL, "and falls back when nothing is playing")

-- The pause duck is a MULTIPLIER of nominal, not an absolute level: a quiet
-- track must duck to a quiet duck, otherwise pausing during the quiet theme
-- makes the music louder.
J.VOL = { quiet = 0.20, loud = 0.80 }
A.truthy(J.nominal("quiet") * J.DUCK_PAUSE < J.nominal("loud") * J.DUCK_PAUSE,
    "ducking preserves the relative loudness of tracks")
A.near(J.nominal("loud") * J.DUCK_PAUSE, 0.20, 1e-9, "0.8 ducks to 0.2 at the default ratio")
