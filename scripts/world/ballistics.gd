class_name Ballistics
extends Object

# The arc arithmetic both sides share. The jump plan (client) and the throw
# solve (server) each had their own copy of the cheapest launch to a point;
# N-5 put it here so there is one.


# The minimum-speed launch that lands `distance` metres out and `rise` metres
# up: 45 degrees tilted by half the slope to the target. Returned as
# (horizontal speed, vertical speed); the heading is the caller's.
static func cheapest_launch(distance: float, rise: float, gravity: float) -> Vector2:
	var flat := maxf(distance, 0.001)
	var span := sqrt(flat * flat + rise * rise)
	var optimum := PI * 0.25 + 0.5 * atan2(rise, flat)
	var speed := sqrt(maxf(gravity * (rise + span), 0.0))
	return Vector2(speed * cos(optimum), speed * sin(optimum))


# 2026-11-22 (the pitching machine): the launch at a given `speed` that
# lands `distance` out and `rise` up, on the low arc (the flatter of the two).
# (horizontal speed, vertical speed); Vector2.ZERO when the speed cannot
# reach that far.
static func launch_at_speed(distance: float, rise: float, speed: float, gravity: float) -> Vector2:
	var flat := maxf(distance, 0.001)
	var v2 := speed * speed
	var under := v2 * v2 - gravity * (gravity * flat * flat + 2.0 * rise * v2)
	if under < 0.0:
		return Vector2.ZERO
	var angle := atan((v2 - sqrt(under)) / (gravity * flat))
	return Vector2(speed * cos(angle), speed * sin(angle))
