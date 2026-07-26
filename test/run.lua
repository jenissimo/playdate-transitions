-- Host test entry point:  lua test/run.lua   (from the repo root)
-- Expect "N checks, 0 failures".
--
-- Modules live at the repo root so that a consumer can submodule this repo
-- straight into their Source/ and `import "juice/sfxkit"`; the path below is
-- what lets the same files load under host lua via require().
package.path = package.path .. ";./?.lua;./test/?.lua"

require("sfxkit_test")
require("jukebox_test")
require("transitions_test")
require("tween_test")
require("shake_test")
require("particles_test")
require("backgrounds_test")

require("assert").done()
