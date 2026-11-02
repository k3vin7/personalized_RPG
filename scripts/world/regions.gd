class_name Regions
extends RefCounted

# The playground's three region pieces, side by side along x, and the one
# place their origins are written. Everything a region holds is built at
# `origin + local`, and every check that stands somewhere inside a region
# adds the same origin -- so a region moves by changing one line here, and
# nothing in another file has to be re-measured by hand (CLAUDE.md note 8).
#
#   west: the obstacle course   -- gaps, step ladder, climb ring, smooth wall,
#                                  occluders, high platform, the 3 m ledge
#   middle: the hub             -- spawn marks, rocks, the race stands and
#                                  the weapon rack
#   east: the arena             -- the scarecrows, plain and per race
#
# Each is the same 40 x 20 slab (x -20..20, z -2..18 around its origin). The
# west bridge joins the hub to the course along the north half of the seam;
# the east bridge runs along the south half, which leaves the hub's +x edge at
# z > 6 a true cliff: nothing below it until the kill plane, which the
# respawn check, the void check and the cliff throw all stand on.

const HUB := Vector3.ZERO
const OBSTACLE := Vector3(-44.0, 0.0, 0.0)
const ARENA := Vector3(54.0, 0.0, 0.0)

const PLAZA_CENTRE := Vector3(0.0, -0.5, 8.0)
const PLAZA_SIZE := Vector3(40.0, 1.0, 20.0)

# x -24..-20, z 10..18.
const WEST_BRIDGE_CENTRE := Vector3(-22.0, -0.5, 14.0)
const WEST_BRIDGE_SIZE := Vector3(4.0, 1.0, 8.0)
# x 20..34, z -2..6. Fourteen metres, because the cliff throw from x = 17 at
# z = 11 lands past x = 29 and has to find nothing there.
const EAST_BRIDGE_CENTRE := Vector3(27.0, -0.5, 2.0)
const EAST_BRIDGE_SIZE := Vector3(14.0, 1.0, 8.0)
