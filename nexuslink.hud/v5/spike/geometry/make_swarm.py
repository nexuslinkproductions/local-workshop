"""Build the swarm point cloud and the data textures from the traced knot.

Input  : knot.json (trace_knot.py output, px at knot height 540, origin = knot
         centre, y up).
Output : under --out (default ../assets):
           swarm-knot-grid.png     P x Q RGBA8, points in a spatial walk order
                                   (option B mesh data source)
           swarm-knot-cells.png    KMAX x NCELLS RGBA8, points grouped per grid
                                   cell (option C lookup source)
           swarm-knot-cellcount.png NCELLX x NCELLY R8, points per cell
           swarm-orb-grid.png      the same three for the crew-orb sphere
           swarm-orb-cells.png
           swarm-orb-cellcount.png
           swarm-knot-sdf.png      1024 x 1024 RGBA8, 2D centre-line distance for
                                   option A (R thick tube, G ring)
           swarm-geometry.json     every number the QML and the docs need

Encoding, one point per texel:
  R,G  high byte of a 12 bit coordinate      n = round((v - lo) / span * 4095)
  B    low nibble of x << 4 | low nibble of y
  A    z, 0 = -0.2 unit, 255 = +0.2 unit
Option A's SDF texture carries two 8 bit distances in R and G.

The cloud is a 3D lattice shell of the tube geometry: sample a lattice at the
dot pitch and keep the sites whose distance to the tube surface is under half a
pitch. Every dot then sits on one shared lattice, which is what makes the
surface read as stacked voxel sheets instead of a smooth spray.
"""
import argparse
import json
import os
import time

import numpy as np
from PIL import Image

# ---------------------------------------------------------------- parameters
PITCH_PX = 3.80           # dot pitch in px at knot height 540 (measured s2: 3.8)
DOT_R_PX = 2.05           # dot radius in px (measured s2 core: ~2.2 at 216 px unit)
GRID_COLS = 160           # option B mesh data texture
GRID_ROWS = 120
CELL_PX = 16.0            # option C spatial cell, px at knot height 540
KMAX = 128                # option C points per cell slot
SDF_SIZE = 1024
SDF_RANGE = 0.42          # distance stored: 0 .. 0.42 unit
ORB_PITCH = 0.0268        # ~3 px at a 112 px radius orb
ORB_CELL = 0.055
STIPPLE = 0.86            # fraction of lattice sites that carry a dot


def seg_dist(px, py, ax, ay, bx, by):
    """Distance from lattice points to one segment, vectorised."""
    vx, vy = bx - ax, by - ay
    wx, wy = px - ax, py - ay
    t = np.clip((wx * vx + wy * vy) / max(vx * vx + vy * vy, 1e-9), 0.0, 1.0)
    return np.hypot(wx - t * vx, wy - t * vy)


def polyline_dist(px, py, chains):
    """Min distance from each lattice point to a set of polylines."""
    d = np.full(px.shape, 1e9, np.float32)
    segs = []
    for ch in chains:
        pts = ch["pts"]
        for i in range(len(pts) - 1):
            segs.append((pts[i][0], pts[i][1], pts[i + 1][0], pts[i + 1][1]))
    for ax, ay, bx, by in segs:
        np.minimum(d, seg_dist(px, py, ax, ay, bx, by), out=d)
    return d


def hash01(ix, iy, iz, seed=0):
    """Deterministic pseudo random in [0,1) from integer indices."""
    h = (ix.astype(np.uint64) * np.uint64(73856093)) ^ \
        (iy.astype(np.uint64) * np.uint64(19349663)) ^ \
        (iz.astype(np.uint64) * np.uint64(83492791)) ^ np.uint64(seed * 2654435761)
    h = h ^ (h >> np.uint64(13))
    h = (h * np.uint64(1274126177)) & np.uint64(0xFFFFFFFF)
    return (h & np.uint64(0xFFFFFF)).astype(np.float32) / np.float32(0x1000000)


# ---------------------------------------------------------------- point clouds
def split_chains(knot):
    thick = [c for c in knot["chains"] if c["hw"] >= 5.0]
    ring = [c for c in knot["chains"] if c["hw"] < 5.0]
    return thick, ring


def knot_cloud(knot, pitch):
    """Lattice shell of the triquetra tubes, in units where ring radius = 1."""
    thick, ring = split_chains(knot)
    ring_r_px = float(np.mean([np.hypot(p[0], p[1]) for c in ring for p in c["pts"]]))
    s = 1.0 / ring_r_px
    r_tube = float(np.median([p[2] for c in thick for p in c["pts"]])) * s
    ring_tube = float(np.median([p[2] for c in ring for p in c["pts"]])) * s
    xy = np.array([[p[0], p[1]] for c in thick for p in c["pts"]])
    lo = (xy.min(0) / ring_r_px).min() - r_tube - 2 * pitch
    hi = (xy.max(0) / ring_r_px).max() + r_tube + 2 * pitch
    nx = int(np.ceil((hi - lo) / pitch))
    xs = lo + (np.arange(nx) + 0.5) * pitch
    X, Y = np.meshgrid(xs, xs, indexing="xy")
    d_thick = polyline_dist(X * ring_r_px, Y * ring_r_px, thick) * s
    d_ring = polyline_dist(X * ring_r_px, Y * ring_r_px, ring) * s

    layers = []
    nz = max(1, int(np.ceil(2 * r_tube / pitch)))
    zs = (np.arange(nz) - (nz - 1) / 2.0) * pitch
    for iz, z in enumerate(zs):
        for name, d2, rad in (("thick", d_thick, r_tube), ("ring", d_ring, ring_tube)):
            surf = np.hypot(d2, np.full_like(d2, z)) - rad
            hit = np.abs(surf) < 0.5 * pitch
            iy, ix = np.nonzero(hit)
            keep = hash01(ix, iy, np.full_like(ix, iz + (0 if name == "thick" else 40))) < STIPPLE
            x = X[iy, ix][keep]
            y = Y[iy, ix][keep]
            if len(x):
                layers.append(np.stack([x, y, np.full_like(x, z)], 1))
    pts = np.concatenate(layers, 0).astype(np.float32)
    info = {"r_tube": r_tube, "ring_tube": ring_tube, "pitch": pitch,
            "ring_r_px": ring_r_px, "px_per_unit": ring_r_px, "layers": int(nz)}
    return pts, info


def orb_cloud(pitch):
    """Fibonacci sphere shell of unit radius, quantised to the same lattice."""
    n = int(round(4 * np.pi / (pitch * pitch) * 0.62))
    i = np.arange(n) + 0.5
    phi = np.arccos(1 - 2 * i / n)
    theta = np.pi * (1 + 5 ** 0.5) * i
    p = np.stack([np.cos(theta) * np.sin(phi), np.sin(theta) * np.sin(phi),
                  np.cos(phi)], 1).astype(np.float32)
    q = np.round(p / pitch).astype(np.int32)
    _, idx = np.unique(q, axis=0, return_index=True)
    p = q[np.sort(idx)].astype(np.float32) * pitch
    return p, {"pitch": pitch, "count": int(len(p))}


# ---------------------------------------------------------------- ordering
def walk_order(pts, cell):
    """Nearest neighbour walk, so consecutive texels are neighbours in space.

    That keeps the mesh quads (option B) small: grid neighbours are real
    neighbours on the surface, so the quad between them is a sliver of the tube
    instead of a jump across the knot.
    """
    n = len(pts)
    keys = np.floor(pts / cell).astype(np.int32)
    buckets = {}
    for i in range(n):
        k = (int(keys[i, 0]), int(keys[i, 1]), int(keys[i, 2]))
        buckets.setdefault(k, []).append(i)
    used = np.zeros(n, bool)
    order = np.empty(n, np.int32)
    cur = int(np.argmin(np.hypot(pts[:, 0], pts[:, 1])))
    used[cur] = True
    order[0] = cur
    for step in range(1, n):
        kx, ky, kz = keys[cur]
        best, bd = -1, 1e30
        for r in range(0, 5):
            for dx in range(-r, r + 1):
                for dy in range(-r, r + 1):
                    for dz in range(-r, r + 1):
                        if max(abs(dx), abs(dy), abs(dz)) != r:
                            continue
                        for j in buckets.get((kx + dx, ky + dy, kz + dz), ()):
                            if used[j]:
                                continue
                            d = float(((pts[j] - pts[cur]) ** 2).sum())
                            if d < bd:
                                bd, best = d, j
            if best >= 0:
                break
        if best < 0:
            best = int(np.argmin(used))
        used[best] = True
        order[step] = best
        cur = best
    return order


# ---------------------------------------------------------------- textures
def encode_grid(pts, pitch, off=(0.0, 0.0, 0.0), offs=(0, 0, 0), cols=GRID_COLS,
                rows=GRID_ROWS):
    """Integer lattice index per axis into RGBA8.

    R = ix - offs[0], G = iy - offs[1], B = iz - offs[2], A = 255.

    Alpha stays 255 on purpose: Qt uploads image textures premultiplied, so a
    byte stored in RGB comes back as round(value * alpha / 255). Fully opaque
    keeps every packed integer exact, and padding is marked with R = 255 (no
    real lattice index reaches it).
    """
    q = np.round((pts - np.array(off, np.float32)) / pitch).astype(np.int32)
    q[:, 0] += offs[0]
    q[:, 1] += offs[1]
    q[:, 2] += offs[2]
    out = np.zeros((rows, cols, 4), np.uint8)
    # Padding is marked, not left at zero: Qt premultiplies image textures, so an
    # alpha-0 texel loses its RGB whatever was stored there. A = 255 keeps the
    # bytes exact everywhere and R = 255 marks a texel that carries no point (no
    # real lattice index reaches it). Both shader stages test R > 0.996 for it.
    out[:, :, 0] = 255
    out[:, :, 3] = 255
    n = min(len(pts), rows * cols)
    r = np.arange(n) // cols
    c = np.arange(n) % cols
    out[r, c, 0] = np.clip(q[:n, 0], 0, 254).astype(np.uint8)
    out[r, c, 1] = np.clip(q[:n, 1], 0, 254).astype(np.uint8)
    out[r, c, 2] = np.clip(q[:n, 2], 0, 254).astype(np.uint8)
    out[r, c, 3] = 255
    return out, {"origin": [float(v) for v in off], "index_offset": [int(v) for v in offs],
                 "pitch": float(pitch), "count": int(n), "cols": int(cols),
                 "rows": int(rows), "capacity": int(cols * rows)}


def cell_layout(pts, cell, kmax, pitch, off=(0.0, 0.0, 0.0), offs=(0, 0, 0)):
    """Group points into a square XY grid of cells, padding each cell to kmax."""
    xy = pts[:, :2]
    lo = xy.min(0) - 1e-4
    hi = xy.max(0) + 1e-4
    nx = int(np.ceil((hi[0] - lo[0]) / cell))
    ny = int(np.ceil((hi[1] - lo[1]) / cell))
    ci = np.clip(((xy[:, 0] - lo[0]) / cell).astype(np.int32), 0, nx - 1)
    cj = np.clip(((xy[:, 1] - lo[1]) / cell).astype(np.int32), 0, ny - 1)
    cid = cj * nx + ci
    order = np.argsort(cid, kind="stable")
    counts = np.bincount(cid, minlength=nx * ny)
    starts = np.concatenate([[0], np.cumsum(counts)[:-1]]).astype(np.int64)
    rows = cid[order]
    slot = np.arange(len(order), dtype=np.int64) - starts[rows]
    q = np.round((pts[order] - np.array(off, np.float32)) / pitch).astype(np.int32)
    q[:, 0] += offs[0]
    q[:, 1] += offs[1]
    q[:, 2] += offs[2]
    tex = np.zeros((nx * ny, kmax, 4), np.uint8)
    tex[:, :, 0] = 255          # padding marker, overwritten for real points
    tex[:, :, 3] = 255
    ok = slot < kmax
    tex[rows[ok], slot[ok], 0] = np.clip(q[ok, 0], 0, 254).astype(np.uint8)
    tex[rows[ok], slot[ok], 1] = np.clip(q[ok, 1], 0, 254).astype(np.uint8)
    tex[rows[ok], slot[ok], 2] = np.clip(q[ok, 2], 0, 254).astype(np.uint8)
    cnt = np.minimum(counts, 255).astype(np.uint8).reshape(ny, nx)
    info = {"lo": [float(lo[0]), float(lo[1])], "cell": float(cell),
            "nx": int(nx), "ny": int(ny), "kmax": int(kmax),
            "dropped": int((~ok).sum()), "max_per_cell": int(counts.max())}
    return tex, cnt, info


def sdf_texture(knot, size=SDF_SIZE, rng=SDF_RANGE):
    """2D distance to the thick centre lines (R) and to the ring (G)."""
    thick, ring = split_chains(knot)
    s = 1.0 / float(np.mean([np.hypot(p[0], p[1]) for c in ring for p in c["pts"]]))
    lo = -1.45
    xs = (np.arange(size) + 0.5) / size * (-2 * lo) + lo
    X, Y = np.meshgrid(xs, xs, indexing="xy")
    d_thick = polyline_dist(X / s, Y / s, thick) * s
    d_ring = polyline_dist(X / s, Y / s, ring) * s
    out = np.zeros((size, size, 4), np.uint8)
    out[:, :, 0] = (np.clip(d_thick / rng, 0, 1) * 255).astype(np.uint8)
    out[:, :, 1] = (np.clip(d_ring / rng, 0, 1) * 255).astype(np.uint8)
    out[:, :, 3] = 255
    return out, {"size": int(size), "lo": lo, "span": -2 * lo, "range": rng}


# ---------------------------------------------------------------- build
def build(knot_path, out_dir):
    t0 = time.time()
    knot = json.load(open(knot_path))
    ring_r_px = float(np.mean([np.hypot(p[0], p[1]) for c in knot["chains"]
                               if c["hw"] < 5.0 for p in c["pts"]]))
    pitch = PITCH_PX / ring_r_px
    dot_r = DOT_R_PX / ring_r_px
    print("ring radius %.2f px  pitch %.5f unit  dot r %.5f unit" % (
        ring_r_px, pitch, dot_r), flush=True)

    kn, kinfo = knot_cloud(knot, pitch)
    print("knot points %d  (%.1fs)" % (len(kn), time.time() - t0), flush=True)
    # lattice index origin: x = lo + (i + 0.5) * pitch
    xy = np.array([[p[0], p[1]] for c in knot["chains"] for p in c["pts"]])
    r_tube = kinfo["r_tube"]
    klo = float((xy.min(0) / ring_r_px).min() - r_tube - 2 * pitch) + 0.5 * pitch
    nz = kinfo["layers"]
    koff = (klo, klo, -(nz - 1) / 2.0 * pitch)
    koffs = (0, 0, 0)

    order = walk_order(kn, pitch * 2.5)
    grid, ginfo = encode_grid(kn[order], pitch, koff, koffs)
    Image.fromarray(grid, "RGBA").save(os.path.join(out_dir, "swarm-knot-grid.png"))
    print("grid walk done (%.1fs) count %d of %d" % (
        time.time() - t0, ginfo["count"], ginfo["capacity"]), flush=True)

    cells, cnt, cinfo = cell_layout(kn, CELL_PX / ring_r_px, KMAX, pitch, koff, koffs)
    Image.fromarray(cells, "RGBA").save(os.path.join(out_dir, "swarm-knot-cells.png"))
    Image.fromarray(cnt).save(os.path.join(out_dir, "swarm-knot-cellcount.png"))
    print("cells %dx%d max/cell %d dropped %d (%.1fs)" % (
        cinfo["nx"], cinfo["ny"], cinfo["max_per_cell"], cinfo["dropped"],
        time.time() - t0), flush=True)

    sdf, sinfo = sdf_texture(knot)
    Image.fromarray(sdf, "RGBA").save(os.path.join(out_dir, "swarm-knot-sdf.png"))
    print("sdf done (%.1fs)" % (time.time() - t0), flush=True)

    ob, oinfo = orb_cloud(ORB_PITCH)
    oorder = walk_order(ob, ORB_PITCH * 2.5)
    ooffs = (64, 64, 64)
    ogrid, oginfo = encode_grid(ob[oorder], ORB_PITCH, (0.0, 0.0, 0.0), ooffs)
    Image.fromarray(ogrid, "RGBA").save(os.path.join(out_dir, "swarm-orb-grid.png"))
    ocells, ocnt, ocinfo = cell_layout(ob, ORB_CELL, KMAX, ORB_PITCH,
                                       (0.0, 0.0, 0.0), ooffs)
    Image.fromarray(ocells, "RGBA").save(os.path.join(out_dir, "swarm-orb-cells.png"))
    Image.fromarray(ocnt).save(os.path.join(out_dir, "swarm-orb-cellcount.png"))
    print("orb points %d cells %dx%d max/cell %d (%.1fs)" % (
        len(ob), ocinfo["nx"], ocinfo["ny"], ocinfo["max_per_cell"],
        time.time() - t0), flush=True)

    meta = {
        "unit": "knot ring radius = 1.0",
        "px_per_unit_at_540": ring_r_px,
        "pitch_units": pitch, "pitch_px": PITCH_PX,
        "dot_r_units": dot_r, "dot_r_px": DOT_R_PX,
        "knot": dict(kinfo, points=int(len(kn)), grid=ginfo, cells=cinfo, sdf=sinfo),
        "orb": dict(oinfo, points=int(len(ob)), grid=oginfo, cells=ocinfo),
    }
    with open(os.path.join(out_dir, "swarm-geometry.json"), "w") as f:
        json.dump(meta, f, indent=2)
    for name in sorted(os.listdir(out_dir)):
        print("  %-28s %8d bytes" % (name, os.path.getsize(os.path.join(out_dir, name))))
    return meta


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser()
    ap.add_argument("--knot", default=os.path.join(here, "knot.json"))
    ap.add_argument("--out", default=os.path.abspath(os.path.join(here, "..", "assets")))
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    build(args.knot, args.out)


if __name__ == "__main__":
    main()
