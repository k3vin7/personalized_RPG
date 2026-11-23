class_name SyncRules
extends Object

# How a body shown on another machine follows the state it is sent. One table,
# because these used to be copied into player.gd, rock.gd and dummy.gd and
# each copy was right about itself: a change to one left the other two behind
# with nothing in any single file to say so (the hazard-8 pattern).

# A gap bigger than this between where a body is shown and where it is said to
# be is a teleport: snap, do not slide. Sliding drags the capsule through
# whatever stands in between at teleport speed and shoves it away.
const TELEPORT_STEP := 2.0
# How long a snapped body has no collision, so the arrival shoves nobody.
const TELEPORT_BLIND := 0.2
# The ease toward the sent position for ordinary gaps, as a rate per second:
# a short lerp hides the space between state packets without letting them
# drift. The yaw eases a little faster.
const LERP_RATE := 18.0
const YAW_LERP_RATE := 20.0
# How often the server sends a body it places (a rock, a scarecrow, a carried
# person) to every peer.
const STATE_INTERVAL := 0.05
# 2026-11-22: a raised guard slows the walk (SkillDef guard_move_mult). The
# server holds the body to it only once the guard has been up this long:
# positions sent before the raise can arrive after it. And never below this
# floor (m/s): a body held still still jitters on the wire.
const GUARD_SPEED_GRACE := 0.3
const GUARD_SPEED_FLOOR := 0.5


# The fraction of the remaining gap to close this step.
static func ease(delta: float) -> float:
	return 1.0 - exp(-LERP_RATE * delta)


static func ease_yaw(delta: float) -> float:
	return 1.0 - exp(-YAW_LERP_RATE * delta)
