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
