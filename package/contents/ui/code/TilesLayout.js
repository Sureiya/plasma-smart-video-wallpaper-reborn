/*
 *  TilesLayout.js — layout search + transformation-graph generator for Tiles mode.
 *
 *  The engine solves a "find the best fit, else make the next best decision"
 *  problem: given the screen size and a set of videos (each with its own aspect
 *  ratio / orientation), it tries to pack tiles into a masonry layout that
 *  minimizes gaps while honouring each video's shape. When a perfect fit is
 *  impossible (mixed arbitrary aspects always leave gaps), it falls back through
 *  a fixed, ordered ladder of relaxation strategies.
 *
 *  Everything is deterministic: a single integer "seed" drives a seeded PRNG, so
 *  the whole choreography (staggered start -> shifts -> converge/merge ->
 *  winner full-screen -> re-expand) can be precomputed ahead of time and replayed
 *  without any runtime randomness.
 */

/*
 * Deterministic seeded PRNG (mulberry32). Same seed => same sequence.
 */
function mulberry32(seed) {
  let a = seed >>> 0;
  return function () {
    a |= 0;
    a = (a + 0x6D2B79F5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/*
 * Infer orientation + aspect from a tile's cell dimensions.
 * Returns { aspect, orientation } where orientation is
 * 'landscape' | 'portrait' | 'square'.
 */
function inferAspect(width, height) {
  const aspect = height > 0 ? width / height : 1;
  let orientation = "square";
  if (aspect > 1.1) {
    orientation = "landscape";
  } else if (aspect < 0.9) {
    orientation = "portrait";
  }
  return { aspect, orientation };
}

/*
 * Total gap area (uncovered screen) — the quantity we try to minimise.
 */
function gapArea(rects, screenW, screenH) {
  const screenArea = screenW * screenH;
  let covered = 0;
  for (const r of rects) {
    covered += Math.max(0, r.w) * Math.max(0, r.h);
  }
  return Math.max(0, screenArea - covered);
}

/*
 * Aspect distortion for a single tile: how much the cell aspect deviates from
 * the video's native aspect. 0 = perfect match, larger = more stretch/crop.
 */
function aspectDistortion(cellAspect, videoAspect) {
  if (videoAspect <= 0) {
    return 0;
  }
  const ratio = Math.max(cellAspect, videoAspect) / Math.min(cellAspect, videoAspect);
  return ratio - 1; // 0 when equal, grows with mismatch
}

/*
 * Unified cost function. Lower is better. Combines gap area (dominant) with
 * aspect distortion and orientation mismatches.
 */
function cost(rects, screenW, screenH, videos, orientationWeight) {
  if (!rects || rects.length === 0) {
    return 1e9;
  }
  const ow = orientationWeight === undefined ? 1 : orientationWeight;
  const gap = gapArea(rects, screenW, screenH) / (screenW * screenH);
  let distortion = 0;
  let orientationPenalty = 0;
  for (const r of rects) {
    const v = videos[r.videoIndex];
    if (v && v.aspect > 0) {
      distortion += aspectDistortion(r.aspect, v.aspect);
      if (r.orientation !== v.orientation && v.orientation !== "square") {
        orientationPenalty += ow;
      }
    }
  }
  const n = rects.length || 1;
  return gap * 1.0 + (distortion / n) * 0.3 + (orientationPenalty / n) * 0.1;
}

/*
 * Scale a layout (in place) so it covers the screen as much as possible while
 * preserving its shape (stagger, variety, offsets). Grows by the min scale
 * needed to touch one full axis, bounded by `maxScale` to avoid over-stretching.
 * This turns large leftover gutters into small, uniform residual ones.
 */
function normalizeToFill(rects, screenW, screenH, maxScale) {
  if (!rects.length) {
    return rects;
  }
  const usedW = Math.max(1, ...rects.map(r => r.x + r.w));
  const usedH = Math.max(1, ...rects.map(r => r.y + r.h));
  const scaleW = screenW / usedW;
  const scaleH = screenH / usedH;
  const scale = Math.min(Math.min(scaleW, scaleH), maxScale);
  if (scale <= 1) {
    return rects;
  }
  for (const r of rects) {
    r.x *= scale;
    r.y *= scale;
    r.w *= scale;
    r.h *= scale;
    r.aspect = r.w / r.h;
    r.orientation = inferAspect(r.w, r.h).orientation;
  }
  return rects;
}

/*
 * Seal hairlines by allowing slight zoom & overlap. Small slivers of gap read
 * worse than either deliberate gaps or full coverage, so we grow each tile by
 * a tiny fraction (zoom, which the VideoOutput crops invisibly) and let
 * adjacent tiles overlap, covering every seam. `tolerance` (0..1) caps the
 * growth so the "floating"/"brick" character is preserved, not destroyed.
 */
function overlapToFill(rects, screenW, screenH, tolerance) {
  if (!rects.length || screenW <= 0 || screenH <= 0) {
    return rects;
  }
  const zoom = 1 + Math.min(0.12, Math.max(0.02, tolerance * 0.5));
  for (const r of rects) {
    // Grow around the tile's center so overlaps are distributed evenly.
    const cx = r.x + r.w / 2;
    const cy = r.y + r.h / 2;
    const nw = r.w * zoom;
    const nh = r.h * zoom;
    r.x = Math.max(0, cx - nw / 2);
    r.y = Math.max(0, cy - nh / 2);
    r.w = Math.min(nw, screenW);
    r.h = Math.min(nh, screenH);
    // Re-clamp to keep tiles within screen bounds (no off-screen spill).
    r.x = Math.max(0, Math.min(screenW - r.w, r.x));
    r.y = Math.max(0, Math.min(screenH - r.h, r.y));
    r.aspect = r.w / r.h;
    r.orientation = inferAspect(r.w, r.h).orientation;
  }
  return rects;
}

/*
 * Layout dispatcher: pick the packing algorithm by style.
 * Styles (TilesLayoutStyle enum values):
 *   0 Brick   — staggered masonry rows (brick-wall offset), varied widths
 *   1 Mosaic  — packed interlocking cells (recursive slicing), full coverage
 *   2 Hero    — one large featured tile + smaller surrounding tiles
 *   3 Collage — overlapping/offset floating tiles with gutters
 *
 * All are deterministic given (seed). Each returns an array of rect
 * { x, y, w, h, aspect, orientation, videoIndex }.
 */
function packLayout(style, screenW, screenH, videos, rng, tolerance) {
  switch (style) {
  case 1: return packMosaic(screenW, screenH, videos, rng, tolerance);
  case 2: return packHero(screenW, screenH, videos, rng, tolerance);
  case 3: return packCollage(screenW, screenH, videos, rng, tolerance);
  case 4: return packColumns(screenW, screenH, videos, rng, tolerance);
  case 5: return packRows(screenW, screenH, videos, rng, tolerance);
  case 6: return packSpiral(screenW, screenH, videos, rng, tolerance);
  case 0:
  default: return packBrick(screenW, screenH, videos, rng, tolerance);
  }
}

/*
 * Brick masonry: staggered rows with varied tile widths and visible gutters.
 * Rows alternate a half-column offset to create the classic running-bond look.
 */
function packBrick(screenW, screenH, videos, rng, tolerance) {
  if (!videos.length || screenW <= 0 || screenH <= 0) {
    return [];
  }
  const gutter = Math.max(3, Math.round(Math.min(screenW, screenH) * 0.008));
  const n = videos.length;
  const targetRows = Math.max(1, Math.round(Math.sqrt(n * (screenW / screenH))));
  const rows = Math.min(targetRows, n);
  const rowH = (screenH - gutter * (rows + 1)) / rows;

  const rects = [];
  let idx = 0;
  for (let r = 0; r < rows && idx < n; r++) {
    const y = gutter + r * (rowH + gutter);
    const cols = Math.max(1, Math.round(2 + rng() * 2));
    const leftover = n - idx;
    const rowCols = (r === rows - 1)
      ? leftover
      : Math.max(1, Math.min(cols, Math.floor(leftover / (rows - r)) || 1));
    const stagger = (r % 2 === 1) ? (screenW / (rowCols + 1)) * 0.5 : 0;
    const usableW = screenW - gutter * 2;
    const colW = usableW / rowCols;

    for (let c = 0; c < rowCols && idx < n; c++) {
      // Vary width but keep it within bounds so rows pack tightly.
      const jitter = 0.85 + rng() * 0.3; // 0.85..1.15 — less extreme than before
      const w = colW * jitter;
      const x = gutter + c * colW + stagger;
      // Fill the full row height for a clean brick band (video crops to fit).
      const h = rowH;
      rects.push({
        x: x,
        y: y,
        w: w,
        h: h,
        aspect: w / h,
        orientation: inferAspect(w, h).orientation,
        videoIndex: idx,
      });
      idx++;
    }
  }

  // Grow the layout to fill leftover space while keeping the stagger shape.
  // Grow to fill leftover space, then seal hairlines with slight overlap.
  const filled = normalizeToFill(rects, screenW, screenH, 1.25);
  return overlapToFill(filled, screenW, screenH, tolerance);
}

/*
 * Mosaic: recursive guillotine slicing, guarantees full coverage (no gaps).
 */
function packMosaic(screenW, screenH, videos, rng, tolerance) {
  if (!videos.length || screenW <= 0 || screenH <= 0) {
    return [];
  }
  const rects = [];
  let nodes = [{ x: 0, y: 0, w: screenW, h: screenH, indices: videos.map((_, i) => i) }];
  while (nodes.length > 0) {
    let bestIdx = 0;
    for (let i = 1; i < nodes.length; i++) {
      if (nodes[i].w * nodes[i].h > nodes[bestIdx].w * nodes[bestIdx].h) bestIdx = i;
    }
    const node = nodes.splice(bestIdx, 1)[0];
    if (node.indices.length === 1) {
      const idx = node.indices[0];
      rects.push({
        x: node.x, y: node.y, w: node.w, h: node.h,
        aspect: node.w / node.h,
        orientation: inferAspect(node.w, node.h).orientation,
        videoIndex: idx,
      });
      continue;
    }
    const half = Math.max(1, Math.floor(node.indices.length / 2));
    const splitVertical = node.w >= node.h;
    const ratio = half / node.indices.length;
    if (splitVertical) {
      const wA = node.w * ratio;
      nodes.push({ x: node.x, y: node.y, w: wA, h: node.h, indices: node.indices.slice(0, half) });
      nodes.push({ x: node.x + wA, y: node.y, w: node.w - wA, h: node.h, indices: node.indices.slice(half) });
    } else {
      const hA = node.h * ratio;
      nodes.push({ x: node.x, y: node.y, w: node.w, h: hA, indices: node.indices.slice(0, half) });
      nodes.push({ x: node.x, y: node.y + hA, w: node.w, h: node.h - hA, indices: node.indices.slice(half) });
    }
  }
  return rects;
}

/*
 * Hero: one large featured tile (first video) with smaller tiles in a side
 * column and a bottom strip.
 */
function packHero(screenW, screenH, videos, rng, tolerance) {
  if (!videos.length || screenW <= 0 || screenH <= 0) {
    return [];
  }
  const gutter = Math.max(6, Math.round(Math.min(screenW, screenH) * 0.02));
  const rects = [];
  const heroW = screenW * 0.62;
  const heroH = screenH - gutter * 2;
  rects.push({
    x: gutter, y: gutter, w: heroW - gutter, h: heroH,
    aspect: (heroW - gutter) / heroH,
    orientation: inferAspect(heroW - gutter, heroH).orientation,
    videoIndex: 0,
  });
  const others = videos.slice(1);
  const colW = screenW - heroW - gutter;
  const perCol = Math.max(1, Math.ceil(others.length / 2));
  const cellStep = (heroH - gutter * (perCol + 1)) / perCol;
  for (let i = 0; i < others.length; i++) {
    const h = cellStep;
    rects.push({
      x: heroW, y: gutter + (i % perCol) * (h + gutter), w: colW, h: h,
      aspect: colW / h,
      orientation: inferAspect(colW, h).orientation,
      videoIndex: i + 1,
    });
  }
  return rects;
}

/*
 * Collage: floating tiles with visible gutters and scatter jitter, like a pile
 * of photos over a blurred backdrop.
 */
function packCollage(screenW, screenH, videos, rng, tolerance) {
  if (!videos.length || screenW <= 0 || screenH <= 0) {
    return [];
  }
  const gutter = Math.max(2, Math.round(Math.min(screenW, screenH) * 0.004));
  const rects = [];
  const n = videos.length;
  const cols = Math.max(1, Math.round(Math.sqrt(n * (screenW / screenH))));
  const rows = Math.ceil(n / cols);
  const cellW = (screenW - gutter * (cols + 1)) / cols;
  const cellH = (screenH - gutter * (rows + 1)) / rows;

  for (let i = 0; i < n; i++) {
    const c = i % cols;
    const r = Math.floor(i / cols);
    // Near-full tiles with tiny scatter: keeps the "floating" feel but leaves
    // almost no black space. Slight overlap (>=1.0 base) closes gaps.
    const jx = (rng() - 0.5) * cellW * 0.08;
    const jy = (rng() - 0.5) * cellH * 0.08;
    const jw = cellW * (1.0 + rng() * 0.06);
    const jh = cellH * (1.0 + rng() * 0.06);
    rects.push({
      x: gutter + c * (cellW + gutter) + jx,
      y: gutter + r * (cellH + gutter) + jy,
      w: jw,
      h: jh,
      aspect: jw / jh,
      orientation: inferAspect(jw, jh).orientation,
      videoIndex: i,
    });
  }

  // Seal hairlines with slight zoom/overlap so the scattered tiles butt
  // together instead of leaving thin gaps.
  return overlapToFill(rects, screenW, screenH, tolerance);
}

/*
 * Columns: vertical masonry columns, gap-free (tiles tile each column fully).
 * Each column spans the full screen height and tiles are stacked to fill it.
 */
function packColumns(screenW, screenH, videos, rng, tolerance) {
  if (!videos.length || screenW <= 0 || screenH <= 0) {
    return [];
  }
  const n = videos.length;
  const cols = Math.max(1, Math.round(Math.sqrt(n * (screenH / screenW))));
  const colW = screenW / cols;
  const rects = [];
  const perCol = Math.ceil(n / cols);
  for (let c = 0; c < cols; c++) {
    // Tiles in this column (gap-free vertical stack).
    let y = 0;
    for (let k = 0; k < perCol; k++) {
      const idx = c * perCol + k;
      if (idx >= n) break;
      const remaining = n - idx;
      const inThisCol = Math.min(perCol, remaining);
      const h = screenH / inThisCol;
      rects.push({
        x: c * colW,
        y: y,
        w: colW,
        h: h,
        aspect: colW / h,
        orientation: inferAspect(colW, h).orientation,
        videoIndex: idx,
      });
      y += h;
    }
  }
  return rects;
}

/*
 * Rows: horizontal bands, gap-free. Each row spans the full screen width and
 * tiles fill it left to right.
 */
function packRows(screenW, screenH, videos, rng, tolerance) {
  if (!videos.length || screenW <= 0 || screenH <= 0) {
    return [];
  }
  const n = videos.length;
  const rows = Math.max(1, Math.round(Math.sqrt(n * (screenW / screenH))));
  const rowH = screenH / rows;
  const rects = [];
  const perRow = Math.ceil(n / rows);
  for (let r = 0; r < rows; r++) {
    let x = 0;
    for (let k = 0; k < perRow; k++) {
      const idx = r * perRow + k;
      if (idx >= n) break;
      const remaining = n - idx;
      const inThisRow = Math.min(perRow, remaining);
      const w = screenW / inThisRow;
      rects.push({
        x: x,
        y: r * rowH,
        w: w,
        h: rowH,
        aspect: w / rowH,
        orientation: inferAspect(w, rowH).orientation,
        videoIndex: idx,
      });
      x += w;
    }
  }
  return rects;
}

/*
 * Spiral: tiles placed in an expanding spiral, scaled so the whole set fills
 * the screen edge-to-edge (gap-free by construction — the spiral only sets
 * ordering, the rects are a full-slice partition).
 */
function packSpiral(screenW, screenH, videos, rng, tolerance) {
  if (!videos.length || screenW <= 0 || screenH <= 0) {
    return [];
  }
  // Use a spiral ordering of video indices, then feed into a gap-free
  // recursive slice so the screen is always fully covered.
  const n = videos.length;
  const order = [];
  // Generate a simple outward spiral index order for variety.
  let top = 0, bottom = Math.ceil(Math.sqrt(n)) - 1;
  let left = 0, right = bottom;
  let idx = 0;
  while (top <= bottom && left <= right && idx < n) {
    for (let i = left; i <= right && idx < n; i++) order.push(i);
    top++;
    for (let i = top; i <= bottom && idx < n; i++) order.push(i * (right + 1) + right);
    right--;
    for (let i = right; i >= left && idx < n; i--) order.push(bottom * (right + 2) + i);
    bottom--;
    for (let i = bottom; i >= top && idx < n; i--) order.push(i * (left + 1) + left);
    left++;
    idx++;
  }
  // Slice into n cells and assign videos in spiral order.
  let nodes = [{ x: 0, y: 0, w: screenW, h: screenH, indices: order.slice(0, n).map((_, i) => i) }];
  const rects = [];
  while (nodes.length > 0) {
    let bi = 0;
    for (let i = 1; i < nodes.length; i++) if (nodes[i].w * nodes[i].h > nodes[bi].w * nodes[bi].h) bi = i;
    const node = nodes.splice(bi, 1)[0];
    if (node.indices.length === 1) {
      const oi = node.indices[0];
      rects.push({
        x: node.x, y: node.y, w: node.w, h: node.h,
        aspect: node.w / node.h,
        orientation: inferAspect(node.w, node.h).orientation,
        videoIndex: oi % n,
      });
      continue;
    }
    const half = Math.max(1, Math.floor(node.indices.length / 2));
    const sv = node.w >= node.h;
    const ratio = half / node.indices.length;
    if (sv) {
      const wA = node.w * ratio;
      nodes.push({ x: node.x, y: node.y, w: wA, h: node.h, indices: node.indices.slice(0, half) });
      nodes.push({ x: node.x + wA, y: node.y, w: node.w - wA, h: node.h, indices: node.indices.slice(half) });
    } else {
      const hA = node.h * ratio;
      nodes.push({ x: node.x, y: node.y, w: node.w, h: hA, indices: node.indices.slice(0, half) });
      nodes.push({ x: node.x, y: node.y + hA, w: node.w, h: node.h - hA, indices: node.indices.slice(half) });
    }
  }
  return rects;
}

/*
 * The layered fallback ladder. Try each strategy in order; return the first
 * candidate whose cost is acceptable, otherwise return the least-bad one found.
 * Strategies:
 *   0 strict     — honour exact aspect
 *   1 aspect     — relax letterbox/crop within tolerance
 *   2 fidelity   — relax cell shape (allow stretch)
 *   3 substitute — reassign videos to better-fitting slots
 *   4 absorb     — accept the gap (background shows through)
 *
 * @returns { rects, strategy, acceptable }
 */
function searchLayout(style, screenW, screenH, videos, seed, tolerance) {
  const tol = tolerance === undefined ? 0.1 : tolerance;
  const rng = mulberry32(seed);

  const strategies = [
    { name: "strict", relax: 0.0, substitute: false, absorb: false },
    { name: "aspect", relax: tol, substitute: false, absorb: false },
    { name: "fidelity", relax: tol * 2, substitute: false, absorb: false },
    { name: "substitute", relax: tol, substitute: true, absorb: false },
    { name: "absorb", relax: tol, substitute: false, absorb: true },
  ];

  let best = null;
  let bestCost = Infinity;

  for (const s of strategies) {
    let ordered = videos;
    if (s.substitute) {
      ordered = videos.slice().sort((a, b) => {
        const r = rng() - 0.5;
        return (b.aspect - a.aspect) + r * 0.1;
      });
    }

    const rects = packLayout(style, screenW, screenH, ordered, rng, s.relax);
    if (!rects.length) {
      continue;
    }

    let c = cost(rects, screenW, screenH, ordered);
    if (s.absorb) {
      c = 0.05; // absorbed gaps are acceptable by definition
    }

    if (c < bestCost) {
      bestCost = c;
      best = { rects, strategy: s.name, cost: c, acceptable: c < 0.5 };
      if (best.acceptable) {
        break;
      }
    }
  }

  return best || { rects: [], strategy: "absorb", cost: 1e9, acceptable: false };
}

/*
 * Build the full transformation graph — the precomputed choreography.
 *
 * Two choreography modes:
 *   MergeToOne — a binary merge tree: tiles pair up (spatially adjacent) and
 *                each pair's two segments end together, then the pair fuses
 *                smoothly into one tile covering their combined region, until
 *                a single monitor-aspect tile remains.
 *   MazeWalk   — the tile count is the "dimension" of a point in an n-dim
 *                lattice. A seeded solver walks this lattice, letting the count
 *                grow and shrink (breathe) while trending toward the center
 *                (count = 1). Each count change is a merge (shrink) or split
 *                (grow) that is spatially continuous.
 *
 * All merges/splits are spatially continuous: a merged tile grows to cover the
 * union of its children's regions (no teleporting). The whole schedule is
 * computed ahead of time and memoized; only per-tile seeks happen live.
 */
function buildGraph(seed, screenW, screenH, videos, mergeDurationMs, style, transformCountBeforeFull, choreographyMode) {
  // Memoize on serializable arguments.
  let key;
  try {
    key = ["choreo", seed, screenW, screenH, mergeDurationMs, style, transformCountBeforeFull, choreographyMode, videos.map(v => [v.filename, v.aspect]).join("|")].join("\u0001");
  } catch (e) {
    key = null;
  }
  if (key !== null && buildGraph._cache && buildGraph._cache.has(key)) {
    return buildGraph._cache.get(key);
  }

  const rng = mulberry32(seed ^ 0x9E3779B9);
  const st = style === undefined ? 0 : style;
  const steps = Math.max(1, transformCountBeforeFull === undefined ? 5 : transformCountBeforeFull);
  const mode = choreographyMode === undefined ? 0 : choreographyMode;
  const n = videos.length;

  function region(x, y, w, h) {
    return { x, y, w, h };
  }
  function unionRegion(regions) {
    const x = Math.min(...regions.map(r => r.x));
    const y = Math.min(...regions.map(r => r.y));
    const x2 = Math.max(...regions.map(r => r.x + r.w));
    const y2 = Math.max(...regions.map(r => r.y + r.h));
    return region(x, y, x2 - x, y2 - y);
  }


  // Generate the count sequence ("walk"): the TILE count over time.
  // Tiles (screen regions) vs segments (video clips) are distinct: `countSeq`
  // tracks the number of tiles, each of which plays its own segment.
  function countWalk() {
    const maxCount = Math.max(1, n);
    // Always start at the maximum tile count.
    const seq = [maxCount];

    if (mode === 1) {
      // MazeWalk: bounded random walk from max -> center (1), then a REVERSE
      // random walk back from the final position up to max. This produces a
      // continuous "pendulum" through the maze — no hard restart/teleport — so
      // the sequence is max ... 1 ... max, all steps ±1.
      let c = maxCount;
      let t = 0;

      // Forward descent toward the center (1).
      while (t < steps * 3) {
        let delta = 0;
        if (c <= 1) {
          delta = 1;
        } else if (c >= maxCount) {
          delta = -1;
        } else {
          const shrink = 0.55;
          delta = rng() < shrink ? -1 : 1;
        }
        c = Math.max(1, Math.min(maxCount, c + delta));
        seq.push(c);
        t++;
        if (c === 1) break;
      }
      // Guarantee reach exactly 1.
      let last = seq[seq.length - 1];
      while (last > 1) {
        last = last - 1;
        seq.push(last);
      }

      // Reverse ascent: a NEW random walk from 1 back up to max (not a mirror
      // of the descent — it is freshly generated so it doesn't retrace exactly).
      c = 1;
      t = 0;
      while (c < maxCount && t < steps * 3) {
        let delta = 0;
        if (c >= maxCount) {
          delta = -1;
        } else if (c <= 1) {
          delta = 1;
        } else {
          const grow = 0.55; // bias toward climbing back up
          delta = rng() < grow ? 1 : -1;
        }
        c = Math.max(1, Math.min(maxCount, c + delta));
        seq.push(c);
        t++;
      }
      // Guarantee reach exactly max.
      last = seq[seq.length - 1];
      while (last < maxCount) {
        last = last + 1;
        seq.push(last);
      }
    } else if (mode === 2) {
      // Reset: collapse to 1 in ±1 steps, then the cycle loop re-expands to
      // max with a NEW seed (reset).
      let c = maxCount;
      while (c > 1) {
        c = c - 1;
        seq.push(c);
      }
    } else {
      // MergeToOne: monotonic reduction to 1, ±1 tile per step for smoothness.
      let c = maxCount;
      while (c > 1) {
        c = c - 1;
        seq.push(c);
      }
    }
    return seq;
  }

  const countSeq = countWalk();

  // Score a candidate subset of video indices for this screen + count.
  // Prefer orientation congruent with the screen, and penalize aspect variance
  // within the set (so tiles look harmonious rather than mismatched).
  function scoreSubset(indices, screenW, screenH) {
    const screenPortrait = screenH > screenW;
    let variance = 0;
    let orientPenalty = 0;
    const aspects = indices.map(i => videos[i].aspect > 0 ? videos[i].aspect : 16 / 9);
    const mean = aspects.reduce((a, b) => a + b, 0) / (aspects.length || 1);
    for (const a of aspects) {
      variance += (a - mean) * (a - mean);
      const portrait = a < 0.9;
      const landscape = a > 1.1;
      if (screenPortrait && landscape) orientPenalty += 1;   // landscape video on portrait screen
      if (!screenPortrait && portrait) orientPenalty += 1;   // portrait video on landscape screen
    }
    variance /= (aspects.length || 1);
    // Lower is better.
    return variance * 1.0 + orientPenalty * 0.3;
  }

  // Pick `cCount` distinct videos, preferring high-quality subsets (aspect
  // congruent with the screen, low within-set variance) while keeping some
  // seeded randomness so the same seed never shows the identical set twice in
  // a row.
  function pickSubset(cCount, screenW, screenH, salt) {
    const all = videos.map((_, i) => i);
    // Sample several random candidates and keep the best-scoring.
    const trials = 12;
    let best = null;
    let bestScore = Infinity;
    for (let t = 0; t < trials; t++) {
      const pool = all.slice();
      const cand = [];
      for (let i = 0; i < Math.min(cCount, pool.length); i++) {
        const j = Math.floor(rng() * pool.length);
        cand.push(pool.splice(j, 1)[0]);
      }
      const s = scoreSubset(cand, screenW, screenH);
      if (s < bestScore) {
        bestScore = s;
        best = cand;
      }
    }
    return best || [];
  }

  // Build per-step keyframes. Each step is a steady state (hold) then a
  // spatially-continuous merge/split into the next count.
  const phases = [];
  let prevTiles = null;

  for (let si = 0; si < countSeq.length; si++) {
    const cCount = countSeq[si];

    const srcIdx = pickSubset(cCount, screenW, screenH, si);

    const aspectVideos = srcIdx.map(idx => ({ filename: videos[idx].filename, aspect: videos[idx].aspect > 0 ? videos[idx].aspect : 16 / 9 }));
    const rects = packLayout(st, screenW, screenH, aspectVideos, mulberry32(seed ^ si), 0.1);

    const tiles = rects.map((r, i) => ({
      srcVideo: srcIdx[i] !== undefined ? srcIdx[i] : 0,
      from: region(r.x, r.y, r.w, r.h),
      to: region(r.x, r.y, r.w, r.h),
    }));

    if (si === 0) {
      phases.push({ name: "grid", count: cCount, tiles, durationMs: 0, sharedSegmentMs: 0 });
    } else {
      // Spatially-continuous interpolation: the merged tile grows from the
      // union of the previous stage's region to its own region.
      const mergedTiles = tiles.map((cur) => ({
        srcVideo: cur.srcVideo,
        from: unionRegion(prevTiles.length > 0 ? prevTiles.map(p => p.to) : [cur.from]),
        to: cur.to,
      }));
      phases.push({ name: "converge", count: cCount, tiles: mergedTiles, prevTiles, durationMs: mergeDurationMs, sharedSegmentMs: 0 });
    }

    prevTiles = tiles;

    if (si < countSeq.length - 1) {
      // Hold duration is driven by segment lengths + the segment-end monitor,
      // NOT a fixed merge interval. 0 here means `tick()` never auto-advances
      // from a hold; only a finished segment advances the choreography.
      phases.push({ name: "hold", count: cCount, tiles, durationMs: 0, sharedSegmentMs: 1 });
    }
  }

  const winnerIndex = Math.floor(rng() * n);

  const result = {
    seed,
    style: st,
    choreographyMode: mode,
    screenW,
    screenH,
    winnerIndex,
    mergeDurationMs,
    transformCountBeforeFull: steps,
    countSeq,
    phases,
  };

  if (key !== null) {
    if (!buildGraph._cache) {
      buildGraph._cache = new Map();
    }
    buildGraph._cache.set(key, result);
    if (buildGraph._cache.size > 256) {
      buildGraph._cache.delete(buildGraph._cache.keys().next().value);
    }
  }
  return result;
}


/*
 * Linear interpolation between two rects at progress p in [0,1].
 */
function interpolateRect(from, to, progress) {
  const p = Math.max(0, Math.min(1, progress));
  return {
    x: from.x + (to.x - from.x) * p,
    y: from.y + (to.y - from.y) * p,
    w: from.w + (to.w - from.w) * p,
    h: from.h + (to.h - from.h) * p,
  };
}





