# playdate-juice — module conventions

Every file in this repo is a **drop-in module**: a user copies it (or the whole
repo, as a git submodule) into their `Source/` and imports it. That constrains
how modules may be written. These rules are not style preferences — each one
exists because breaking it breaks a real consumer.

## 1. Cross-runtime module pattern (mandatory)

Every module must load both on Playdate (`import`) and under host `lua`
(`require`), because the host is where the tests run.

```lua
Foo = Foo or {}                                    -- global, survives double-import

local pd  = rawget(_G, "playdate")                 -- nil under host lua
local gfx = pd and pd.graphics
local snd = pd and pd.sound

local Dep = rawget(_G, "Dep") or require("dep")    -- deps, import-order agnostic

-- ... module body ...

return Foo                                         -- so require() works
```

**Never** write `local snd <const> = playdate.sound` at file scope — that is an
immediate nil-index crash under host `lua`, and it is why the old
`Source/sounds.lua` was untestable.

**Never** assume import order. A module may not read another module's state at
load time.

## 2. Nothing touches the SDK at load time

Allocating a synth, a sampleplayer, an image, or a sprite at file scope means
the consumer pays for it whether or not they use the module — and it runs before
their `playdate.update` exists. Every module exposes `Foo.load(spec)` (or
`Foo.new(...)`) and allocates only there. Modules gate every device call on a
`Foo._ready` flag so that under host `lua` they are silent no-ops rather than
crashes.

## 3. Pure core, thin device shell

Split each file into a **pure** section (plain numbers, math, state machines —
no SDK) and a **device** section. The pure part is what `test/` covers. If a
behaviour is worth a comment explaining why it is correct, it is worth being in
the pure part where a test can pin it.

## 4. Tests

- Host tests live in `test/<module>_test.lua` and are registered in
  `test/run.lua`.
- Run: `lua test/run.lua` — expect `N checks, 0 failures`.
- On Windows: `& "C:\Users\jenis\AppData\Local\Programs\Lua\bin\lua.exe" test/run.lua`
- A module with no host-testable surface still gets a test that at minimum
  `require`s it, proving rule 1 holds.

## 5. Playdate Lua is 32-bit

Integer literals above 2^31 silently become floats, and a bitwise op on a float
crashes on-device with "number has no integer representation". Keep constants
small and mask each step.

## 6. Screen facts

400×240, 1 bit. `setPattern` with an all-zero tile renders **solid black**, not
transparent — dither tiles must never be all-zero.

## 7. Comments explain *why*

Match the density of the existing files. An engine module documents the trap it
is avoiding (a silent SDK failure mode, a frame-budget constraint, a 32-bit
hazard), not what the line does. `docs/`-level rationale goes in the module
header.

## 8. pdc compiles everything

`pdc` compiles **every** `.lua` in the source tree, not just what `main.lua`
imports. A syntax error in an unimported file fails the consumer's build. This
is why every file here must be valid Playdate Lua even when it is only ever run
on the host.
