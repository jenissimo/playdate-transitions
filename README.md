# playdate-transitions

Drop-in scene transition library for [Playdate](https://play.date/). 21 effects, all direction-aware. Includes a demo app with procedural backgrounds.

## Transitions

21 effects, all direction-aware (forward/backward):

| Effect | |
|---|---|
| Slide | Horizontal push |
| Fade | Dither fade through black |
| Dissolve | Bayer crossfade |
| Circle | Iris open / close |
| Diamonds | Diagonal diamond cascade |
| Diamond Wave | Column-by-column wave |
| Triangles | Triangle mosaic |
| Bubbles | Rising / falling fill with bubble edge |
| Blinds | Horizontal blinds |
| Clock Wipe | Radial sweep |
| Wave Wipe | Multi-sine wave boundary |
| Interleave | Alternating bands from opposite sides |
| Dither Bands | Cascading dithered crossfade |
| Spiral | Archimedean spiral |
| Wind | Turbulent pixel erosion |
| Melt | Dripping melt with gravity |
| Shatter | Falling broken pieces |
| Scanline | CRT beam sweep |
| Pixel Shift | VHS tracking glitch |
| Hexagons | Honeycomb cell reveal |
| Diagonal | Diagonal split / merge |

## Usage

Copy `transitions.lua` into your `Source/` folder.

```lua
import "transitions"

function changeScene()
    Transitions.start("Slide", "fwd", 24) -- name, direction, frames
    currentScene = newScene
end

function playdate.update()
    if not Transitions.active then handleInput() end
    Transitions.draw(function() currentScene:draw() end)
end
```

## API

```
Transitions.start(name, dir, frames)  -- start a transition ("fwd" / "back")
Transitions.draw(drawFn)              -- wrap your draw call
Transitions.active                    -- true while transitioning
Transitions.names                     -- ordered name list
Transitions.descriptions              -- name → description table
```

## Backgrounds (optional)

`backgrounds.lua` provides 9 procedural looping backgrounds: Starfield, Waves, Radar, Rain, Squares, Spirograph, Lava Lamp, Dither Hills, Bubbles Rise.

```lua
import "backgrounds"

function playdate.update()
    Backgrounds.update()
    Backgrounds.draw(1)
end
```

## Demo

`main.lua` is a standalone demo. D-pad to navigate, A/B to trigger transitions, crank to adjust speed.

```
pdc Source Transitions.pdx
```

## License

MIT
