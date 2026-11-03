# Usage: python -I tools/tidy_blockout.py maps/blockout_Finimes.tscn maps/blockout_Finimes.tscn report.txt  (snap 0.5 m / 5 deg, close cliff_* corners, rename by role, list east-forest cuts outside floor_9/11)
"""Tidy maps/blockout_Finimes.tscn: snap transforms, close cliff corners,
rename by role, and report east-forest cut boxes that leave the east floors.
Only Y-axis rotations are expected; anything else is reported and left alone.
Idempotent: running it on its own output changes nothing."""
import math
import re
import sys

POS_STEP = 0.5
ANG_STEP = 5.0
NODE_RE = re.compile(r'^\[node name="([^"]+)" type="([^"]+)" parent="([^"]+)"(.*)\]$')
ROOT_RE = re.compile(r'^\[node name="([^"]+)" type="([^"]+)" unique_id=(\d+)\]$')
TF_RE = re.compile(r'^transform = Transform3D\((.*)\)$')
SIZE_RE = re.compile(r'^size = Vector3\((.*)\)$')


def fmt(v):
    r = round(v, 6)
    if abs(r - round(r)) < 1e-9:
        return str(int(round(r)))
    return ("%.7g" % r)


def parse_tscn(text):
    lines = text.split("\n")
    nodes = []  # dicts with name, type, parent, start, end (line idx), tf, size
    current = None
    for i, line in enumerate(lines):
        m = NODE_RE.match(line)
        r = ROOT_RE.match(line)
        if m or r:
            if current:
                current["end"] = i
            if m:
                current = {"name": m.group(1), "type": m.group(2), "parent": m.group(3), "start": i,
                           "tf": None, "size": None, "tf_line": None, "size_line": None, "op": None}
            else:
                current = {"name": r.group(1), "type": r.group(2), "parent": None, "start": i,
                           "tf": None, "size": None, "tf_line": None, "size_line": None, "op": None}
            nodes.append(current)
            continue
        if current is None:
            continue
        t = TF_RE.match(line)
        if t:
            current["tf"] = [float(x) for x in t.group(1).split(",")]
            current["tf_line"] = i
        s = SIZE_RE.match(line)
        if s:
            current["size"] = [float(x) for x in s.group(1).split(",")]
            current["size_line"] = i
        if line.startswith("operation = "):
            current["op"] = int(line.split("=")[1])
    if current:
        current["end"] = len(lines)
    return lines, nodes


def path_of(n):
    if n["parent"] is None:
        return "."
    if n["parent"] == ".":
        return n["name"]
    return n["parent"] + "/" + n["name"]


def yaw_of(tf):
    # basis.x = (xx, xy, xz); for a Y rotation by t: (cos t, 0, -sin t)
    xx, xy, xz, yx, yy, yz, zx, zy, zz = tf[:9]
    pure = abs(xy) < 1e-5 and abs(yx) < 1e-5 and abs(yz) < 1e-5 and abs(zy) < 1e-5 and abs(yy - 1) < 1e-5
    if not pure:
        return None
    return math.degrees(math.atan2(-xz, xx))


def tf_from(yaw_deg, origin):
    t = math.radians(yaw_deg)
    c, s = math.cos(t), math.sin(t)
    return [c, 0.0, -s, 0.0, 1.0, 0.0, s, 0.0, c, origin[0], origin[1], origin[2]]


def snap(v, step):
    return round(v / step) * step


def world_of(nodes_by_path, n):
    """World 2D pose (x, z, yaw) and y of node n, composing Y-rotations up the chain."""
    chain = []
    cur = n
    while cur is not None:
        chain.append(cur)
        cur = nodes_by_path.get(cur["parent"]) if cur["parent"] not in (None, ".") else (nodes_by_path.get(".") if cur["parent"] == "." else None)
        if cur is not None and cur["parent"] is None:
            chain.append(cur)
            break
    x, y, z, yaw = 0.0, 0.0, 0.0, 0.0
    for node in reversed(chain):
        tf = node["tf"]
        if tf is None:
            continue
        # The file is row-major: rows[0] = (cos t, 0, sin t), so yaw_of() (which
        # reads -xz) returns -t. The true heading is the negative.
        ly = -(yaw_of(tf) or 0.0)
        ox, oy, oz = tf[9], tf[10], tf[11]
        # local origin rotated by the accumulated yaw, then added
        t = math.radians(yaw)
        c, s = math.cos(t), math.sin(t)
        # Godot: world = R(yaw) * local; for Y rotation, x' = c*x + s*z, z' = -s*x + c*z
        wx = c * ox + s * oz
        wz = -s * ox + c * oz
        x += wx
        z += wz
        y += oy
        yaw += ly
    return x, y, z, yaw


def corners(cx, cz, yaw, sx, sz):
    t = math.radians(yaw)
    c, s = math.cos(t), math.sin(t)
    out = []
    for dx, dz in ((-sx / 2, -sz / 2), (sx / 2, -sz / 2), (sx / 2, sz / 2), (-sx / 2, sz / 2)):
        out.append((cx + c * dx + s * dz, cz - s * dx + c * dz))
    return out


def main():
    src, dst, rep = sys.argv[1], sys.argv[2], sys.argv[3]
    text = open(src, encoding="utf-8").read()
    lines, nodes = parse_tscn(text)
    report = []
    by_path = {path_of(n): n for n in nodes}

    # ---- 1. snap
    snapped = 0
    for n in nodes:
        if n["tf"] is None:
            continue
        yaw = yaw_of(n["tf"])
        if yaw is None:
            report.append("NOT_Y_ROTATION %s" % path_of(n))
            continue
        new_yaw = snap(yaw, ANG_STEP) % 360.0
        o = n["tf"][9:12]
        new_o = [snap(v, POS_STEP) for v in o]
        moved = max(abs(a - b) for a, b in zip(o, new_o))
        turned = abs((new_yaw - yaw + 180) % 360 - 180)
        if moved > 1e-6 or turned > 1e-6:
            snapped += 1
            if moved > 0.26 or turned > 2.6:
                report.append("SNAP_LARGE %s moved=%.3f turned=%.2f" % (path_of(n), moved, turned))
        n["tf"] = tf_from(new_yaw, new_o)
        n["yaw"] = new_yaw
    report.append("SNAPPED %d transforms" % snapped)

    # ---- 2. cliff corners: the edge* walls under south/CSGCombiner3D
    edges = [n for n in nodes if n["parent"] == "south/CSGCombiner3D" and re.match(r"^edge\d*$", n["name"])]
    poses = {}
    for e in edges:
        x, y, z, yaw = world_of(by_path, e)
        poses[e["name"]] = (x, z, yaw)
    # each wall: centre, direction (local +x in world), half length
    def dir_of(yaw):
        t = math.radians(yaw)
        return (math.cos(t), -math.sin(t))
    def intersect(p, d, q, e):
        # p + a d = q + b e
        den = d[0] * e[1] - d[1] * e[0]
        if abs(den) < 1e-6:
            return None
        a = ((q[0] - p[0]) * e[1] - (q[1] - p[1]) * e[0]) / den
        return (p[0] + a * d[0], p[1] + a * d[1]), a
    closed = 0
    for e in edges:
        x, z, yaw = poses[e["name"]]
        d = dir_of(yaw)
        half = e["size"][0] / 2.0
        needed = half
        for f in edges:
            if f is e:
                continue
            fx, fz, fyaw = poses[f["name"]]
            fd = dir_of(fyaw)
            hit = intersect((x, z), d, (fx, fz), fd)
            if hit is None:
                continue
            (ix, iz), a = hit
            # the meeting point must be near this wall's end and inside the other wall's reach
            b = (ix - fx) * fd[0] + (iz - fz) * fd[1]
            fhalf = f["size"][0] / 2.0
            if abs(a) <= half + 4.0 and abs(b) <= fhalf + 4.0:
                needed = max(needed, abs(a) + 0.5)
        if needed > half + 1e-6:
            e["size"][0] = math.ceil(needed * 2.0 / POS_STEP) * POS_STEP
            closed += 1
            report.append("CORNER %s length %.1f -> %.1f" % (e["name"], half * 2, needed * 2))
    report.append("CORNERS_CLOSED %d walls lengthened" % closed)

    # ---- 3. rename
    renames = {}
    # cliffs: edge, edge2.. -> cliff_1, cliff_2..
    for e in edges:
        num = e["name"][4:] or "1"
        renames[path_of(e)] = "cliff_%s" % num
    forest = by_path.get("east/east forest")
    if forest is not None:
        kids = [n for n in nodes if n["parent"] == "east/east forest"]
        p_i = c_i = t_i = 0
        for k in kids:
            sx, _, sz = k["size"]
            long, short = max(sx, sz), min(sx, sz)
            if k["op"] == 2:
                if long / max(short, 0.1) >= 2.5 and short <= 25:
                    p_i += 1
                    renames[path_of(k)] = "path_%d" % p_i
                else:
                    c_i += 1
                    renames[path_of(k)] = "clearing_%d" % c_i
            else:
                t_i += 1
                renames[path_of(k)] = "thicket_%d" % t_i
    for n in nodes:
        m = re.match(r"^Floor(\d*)$", n["name"])
        if m:
            renames[path_of(n)] = "floor_%s" % (m.group(1) or "1")
    for old, new in renames.items():
        report.append("RENAME %s -> %s" % (old, new))

    # ---- 4. east forest cut boxes outside the east floors (report only)
    floors = []
    for name in ("east/east field/Floor9", "east/east field/Floor11"):
        f = by_path.get(name)
        if f is None:
            continue
        x, y, z, yaw = world_of(by_path, f)
        sx, _, sz = f["size"]
        floors.append((x - sx / 2, x + sx / 2, z - sz / 2, z + sz / 2, name))
    def inside(px, pz):
        return any(x0 - 1e-6 <= px <= x1 + 1e-6 and z0 - 1e-6 <= pz <= z1 + 1e-6 for x0, x1, z0, z1, _ in floors)
    if forest is not None:
        for k in [n for n in nodes if n["parent"] == "east/east forest" and n["op"] == 2]:
            x, y, z, yaw = world_of(by_path, k)
            sx, _, sz = k["size"]
            outs = [(cx, cz) for cx, cz in corners(x, z, yaw, sx, sz) if not inside(cx, cz)]
            if outs:
                report.append("OUTSIDE_FLOOR %s (now %s) centre=(%.1f, %.1f) yaw=%.0f size=%.0fx%.0f corners_out=%d %s" % (
                    k["name"], renames.get(path_of(k), k["name"]), x, z, yaw, sx, sz, len(outs),
                    " ".join("(%.0f,%.0f)" % c for c in outs)))

    # ---- write
    for n in nodes:
        if n["tf_line"] is not None:
            lines[n["tf_line"]] = "transform = Transform3D(%s)" % ", ".join(fmt(v) for v in n["tf"])
        if n["size_line"] is not None:
            lines[n["size_line"]] = "size = Vector3(%s)" % ", ".join(fmt(v) for v in n["size"])
    # names: rewrite the [node ...] line and every parent="..." path that starts with the old path
    old_to_new_path = {}
    for n in nodes:
        old = path_of(n)
        parts = old.split("/") if old != "." else []
        new_parts = []
        acc = ""
        for p in parts:
            acc = p if acc == "" else acc + "/" + p
            new_parts.append(renames.get(acc, p))
        old_to_new_path[old] = "/".join(new_parts) if new_parts else "."
    for n in nodes:
        line = lines[n["start"]]
        new_name = renames.get(path_of(n), n["name"])
        line = line.replace('name="%s"' % n["name"], 'name="%s"' % new_name, 1)
        if n["parent"] is not None:
            line = line.replace('parent="%s"' % n["parent"], 'parent="%s"' % old_to_new_path.get(n["parent"], n["parent"]), 1)
        lines[n["start"]] = line
    open(dst, "w", encoding="utf-8", newline="\n").write("\n".join(lines))
    open(rep, "w", encoding="utf-8").write("\n".join(report) + "\n")
    print("\n".join(report))


if __name__ == "__main__":
    main()
