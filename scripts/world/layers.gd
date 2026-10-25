class_name Layers
extends Object

# Every collision layer in the game, in one table.
#
# They used to be declared separately in player.gd, playground.gd, dummy.gd and
# rock.gd. Each file was right about itself and the set did not add up: a player
# and a dummy each left the other out of its mask, so they walked through one
# another, and no file read wrong on its own. One table means a mask can be
# written next to the thing it is masking against.
#
# A body is solid to another when EITHER side has the other's layer in its mask;
# Godot only needs the pair in one direction. SOLID_* below is the full set for
# each moving body, written both ways on purpose so the table can be read
# straight down.

const WORLD := 1        # floors, ground, anything you stand on
const WALL := 2         # blocks movement and sight, cannot be climbed
const CLIMBABLE := 4    # the climb walls and the time boundary's cut face
const PLAYER := 8
const THROWABLE := 16   # rocks
const DUMMY := 32
const PICKUP := 64      # weapon rack areas
const NAV_BRIDGE := 128 # seen by the navigation bake and nothing else

const TERRAIN := WORLD | WALL | CLIMBABLE

# What each moving body collides with. Everything that can be walked into is
# listed here, so a new body is added in one place rather than in two.
const SOLID_PLAYER := TERRAIN | PLAYER | THROWABLE | DUMMY
const SOLID_DUMMY := TERRAIN | PLAYER | THROWABLE | DUMMY
const SOLID_ROCK := TERRAIN | PLAYER | THROWABLE | DUMMY
