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
 * ---------------------------------------------------------------------------
 * Lightweight timing instrumentation.
 * ---------------------------------------------------------------------------
 * `withTiming(label, fn, thresholdMs)` runs `fn()` and, when debugging is on,
 * warns if the call took longer than `thresholdMs` — i.e. long enough that it
 * could be felt as a UI stall. Timing is only active while `profilingEnabled`
 * is true (default off), so there is zero overhead in production.
 *
 * `timed(label, ms)` records a measurement under `label` and emits a summary of
 * the slowest call for that label the next time it exceeds the threshold.
 * ---------------------------------------------------------------------------
 */
var profilingEnabled = false;
var _timings = { };              // label -> { worstMs, calls }

// Enable/disable timing instrumentation (called from QML / the worker when
// debugging is on). Returns the previous value so callers can restore it.
function setProfilingEnabled(on) {
  const prev = !!profilingEnabled;
  profilingEnabled = !!on;
  if (!profilingEnabled) _timings = { };
  return prev;
}

// Return a plain summary object of slowest observations so far (label -> worst
// ms + call count). Used by the debug overlay / logging path.
function getTimings() {
  const out = { };
  for (const k in _timings) out[k] = { worstMs: _timings[k].worstMs, calls: _timings[k].calls };
  return out;
}

function timed(label, ms) {
  if (!profilingEnabled) return;
  const t = _timings[label] || (_timings[label] = { worstMs: 0, calls: 0 });
  t.calls++;
  if (ms > t.worstMs) t.worstMs = ms;
}

function withTiming(label, fn, thresholdMs) {
  if (!profilingEnabled) return fn();
  const start = Date.now();
  let r;
  try {
    r = fn();
  } finally {
    const ms = Date.now() - start;
    timed(label, ms);
    if (typeof thresholdMs === "number" && ms > thresholdMs) {
      const t = _timings[label];
      // eslint-disable-next-line no-console
      console.warn("[TilesLayout] slow " + label + " took " + ms.toFixed(1)
        + "ms (threshold " + thresholdMs + "ms, worst " + t.worstMs.toFixed(1)
        + "ms over " + t.calls + " calls)");
    }
  }
  return r;
}

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
 * Snap a cell's height to the assigned video's native aspect so that, given a
 * fixed cell width, the video fills the cell exactly (PreserveAspectCrop becomes
 * a no-op → no black bars, no heavy crop). `budgetH` is the uniform height the
 * masonry would otherwise use; we keep the result within a sane band around it
 * so the layout still packs tightly. Returns the adjusted height.
 */
function snapCellHeightToAspect(videoAspect, cellWidth, budgetH) {
  if (!(videoAspect > 0) || !(cellWidth > 0)) {
    return budgetH;          // unknown aspect: fall back to uniform cell
  }
  const idealH = cellWidth / videoAspect;
  // Allow the cell to deviate from the uniform budget but clamp so a single
  // extreme video can't shred the grid.
  const lo = budgetH * 0.5;
  const hi = budgetH * 1.5;
  return Math.min(hi, Math.max(lo, idealH));
}

/*
 * Deterministically normalize a set of rects into a target W x H region: no
 * rect may overflow or overlap, and each keeps its own aspect ratio. Used when a
 * full-screen packer is reused against a narrow/portrait strip in Hero mode,
 * where the packer's viewport assumptions can produce overflow/overlap.
 *
 * Strategy: scale every rect down (uniformly) until its bounding box fits the
 * target, then shelf-pack them in original order (left-to-right, top-to-bottom)
 * so overlaps are resolved without changing which video is which.
 */
function fitRectsToRegion(rects, regionW, regionH) {
  if (!rects || rects.length === 0) return [];
  // Uniform scale so the largest rect fits, by width or height.
  let scale = 1;
  for (const r of rects) {
    if (r.w > 0) scale = Math.min(scale, regionW / r.w);
    if (r.h > 0) scale = Math.min(scale, regionH / r.h);
    scale = Math.min(scale, 1);
  }
  // Shelf-pack (deterministic, original order).
  function shelf(sc) {
    let cursorX = 0;
    let cursorY = 0;
    let rowH = 0;
    const res = [];
    for (const r of rects) {
      const w = Math.max(1, r.w * sc);
      const h = Math.max(1, r.h * sc);
      if (cursorX + w > regionW && cursorX > 0) {
        cursorX = 0;
        cursorY += rowH;
        rowH = 0;
      }
      res.push({ x: cursorX, y: cursorY, w: w, h: h, videoIndex: r.videoIndex });
      cursorX += w;
      rowH = Math.max(rowH, h);
    }
    return res;
  }
  let result = shelf(scale);
  // If the shelf overflowed the region's height, shrink uniformly and re-pack.
  let maxBottom = 0;
  for (const r of result) maxBottom = Math.max(maxBottom, r.y + r.h);
  if (maxBottom > regionH) {
    scale = scale * (regionH / maxBottom);
    result = shelf(scale);
  }
  for (const r of result) {
    r.x = Math.min(r.x, Math.max(0, regionW - r.w));
    r.y = Math.min(r.y, Math.max(0, regionH - r.h));
  }
  return result;
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
 * Seal hairlines by allowing slight zoom & overlap, then distribute any
 * residual gaps/edges EVENLY across all tiles. Small slivers of gap read worse
 * than either deliberate gaps or full coverage, so we grow each tile by a tiny
 * fraction (zoom, which the VideoOutput crops invisibly) letting adjacent tiles
 * overlap to cover every internal seam. Whatever uncovered space remains at the
 * screen boundary is then shared uniformly: every tile is scaled around the
 * layout's centre so opposite-screen margins match and no single edge tile
 * absorbs the whole deficit. `tolerance` (0..1) caps the zoom so the
 * "floating"/"brick" character is preserved, not destroyed.
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

  // Distribute gaps/edges EVENLY across all tiles (not just the outermost).
  // The zoom+clamp above seals internal seams by overlap; what remains is the
  // *residual* space — the uncovered band at the screen boundary plus any
  // leftover internal gutters. Instead of stretching only the few tiles that
  // happen to touch an edge (which makes those tiles visibly wider/taller than
  // their neighbours), map the layout's bounding box onto the full screen with a
  // single per-axis affine transform (scale + translate). Every tile grows by
  // the same factor on each axis, so every inter-tile gap and every edge margin
  // stays in the same proportion — no single tile absorbs the deficit.
  let minX = Infinity, maxX = -Infinity, minY = Infinity, maxY = -Infinity;
  for (const r of rects) {
    if (r.x < minX) minX = r.x;
    if (r.x + r.w > maxX) maxX = r.x + r.w;
    if (r.y < minY) minY = r.y;
    if (r.y + r.h > maxY) maxY = r.y + r.h;
  }

  const spanW = Math.max(1e-6, maxX - minX);
  const spanH = Math.max(1e-6, maxY - minY);
  const scaleX = screenW / spanW;
  const scaleY = screenH / spanH;

  for (const r of rects) {
    // Map the bounding box [minX,maxX]x[minY,maxY] onto [0,screenW]x[0,screenH].
    // Position and size share the same per-axis factor, so all tiles and all
    // gaps scale uniformly — the result is full coverage with even spacing.
    r.x = (r.x - minX) * scaleX;
    r.w = r.w * scaleX;
    r.y = (r.y - minY) * scaleY;
    r.h = r.h * scaleY;
    // Guard against accumulated float error at the exact screen edge.
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
function packLayout(style, screenW, screenH, videos, rng, tolerance, heroSecondaryMode) {
  return withTiming("packLayout", function () {
    switch (style) {
    case 1: return packMosaic(screenW, screenH, videos, rng, tolerance);
    case 2: return packHero(screenW, screenH, videos, rng, tolerance, heroSecondaryMode);
    case 3: return packCollage(screenW, screenH, videos, rng, tolerance);
    case 4: return packBands(screenW, screenH, videos, rng, tolerance);
    case 5: return packBands(screenW, screenH, videos, rng, tolerance);
    case 6: return packSpiral(screenW, screenH, videos, rng, tolerance);
    case 0:
    default: return packBrick(screenW, screenH, videos, rng, tolerance);
    }
  }, 16);
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
      // Snap the cell height to THIS video's native aspect so it fills the cell
      // exactly (no black bars). Keeps the brick look but aspect-faithful.
      const vidAspect = videos[idx] ? videos[idx].aspect : 0;
      const h = snapCellHeightToAspect(vidAspect, w, rowH);
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
    // Split along the longer dimension, but choose the ratio so each child's
    // cells land close to their videos' native aspect — this avoids producing a
    // single paper-thin cell when a mixed set contains a very tall/wide video.
    const left = node.indices.slice(0, half);
    const right = node.indices.slice(half);
    const avgAspect = (list) => {
      let s = 0;
      for (const i of list) {
        s += videos[i] && videos[i].aspect > 0 ? videos[i].aspect : 16 / 9;
      }
      return s / (list.length || 1);
    };
    const splitVertical = node.w >= node.h;
    let ratio = half / node.indices.length;
    if (splitVertical && node.h > 0) {
      // Ideal widths so each child's aggregate aspect is respected.
      const targetWLeft = node.h * avgAspect(left) * left.length;
      const targetWRight = node.h * avgAspect(right) * right.length;
      const total = targetWLeft + targetWRight || 1;
      ratio = Math.max(0.15, Math.min(0.85, targetWLeft / total));
      const wA = node.w * ratio;
      nodes.push({ x: node.x, y: node.y, w: wA, h: node.h, indices: left });
      nodes.push({ x: node.x + wA, y: node.y, w: node.w - wA, h: node.h, indices: right });
    } else {
      const targetHTop = (node.w / (avgAspect(left) || 1)) * left.length;
      const targetHBot = (node.w / (avgAspect(right) || 1)) * right.length;
      const total = targetHTop + targetHBot || 1;
      ratio = Math.max(0.15, Math.min(0.85, targetHTop / total));
      const hA = node.h * ratio;
      nodes.push({ x: node.x, y: node.y, w: node.w, h: hA, indices: left });
      nodes.push({ x: node.x, y: node.y + hA, w: node.w, h: node.h - hA, indices: right });
    }
  }
  return rects;
}

/*
 * Hero: one large featured tile (first video) with smaller tiles in a side
 * column and a bottom strip.
 */
function packHero(screenW, screenH, videos, rng, tolerance, heroSecondaryMode) {
  if (!videos.length || screenW <= 0 || screenH <= 0) {
    return [];
  }
  const gutter = Math.max(6, Math.round(Math.min(screenW, screenH) * 0.02));
  const rects = [];
  const screenAspect = screenW / screenH;

  // Aspect-aware split: the hero tile's placement + the secondary region's shape
  // are chosen from the SCREEN's own aspect, so the non-dominant region never
  // degenerates into a skinny sliver (the core bug with the old fixed 62/38
  // split on wide/tall screens).
  //
  //   portrait/square  -> hero on TOP, secondary strip across the BOTTOM (full width)
  //   landscape        -> hero on LEFT, secondary strip on the RIGHT
  //   ultrawide        -> hero on LEFT, secondary split into RIGHT strip + BOTTOM strip
  let heroRect;           // { x, y, w, h }
  let strip;              // { x, y, w, h } bounding box for the secondary region

  if (screenAspect < 1.15) {
    // Portrait / square: wide hero on top, short strip at the bottom.
    const heroH = screenH * 0.58;
    heroRect = {
      x: gutter, y: gutter,
      w: screenW - gutter * 2, h: heroH - gutter,
    };
    strip = { x: gutter, y: heroH + gutter, w: screenW - gutter * 2, h: screenH - heroH - gutter * 2 };
  } else if (screenAspect >= 1.7) {
    // Ultrawide: hero left, and a wide right strip so tiles don't become pills.
    const heroW = screenW * 0.5;
    heroRect = {
      x: gutter, y: gutter,
      w: heroW - gutter, h: screenH - gutter * 2,
    };
    strip = { x: heroW + gutter, y: gutter, w: screenW - heroW - gutter * 2, h: screenH - gutter * 2 };
  } else {
    // Landscape: hero left (62%), secondary strip right.
    const heroW = screenW * 0.62;
    heroRect = {
      x: gutter, y: gutter,
      w: heroW - gutter, h: screenH - gutter * 2,
    };
    strip = { x: heroW + gutter, y: gutter, w: screenW - heroW - gutter * 2, h: screenH - gutter * 2 };
  }

  rects.push({
    x: heroRect.x, y: heroRect.y, w: heroRect.w, h: heroRect.h,
    aspect: heroRect.w / heroRect.h,
    orientation: inferAspect(heroRect.w, heroRect.h).orientation,
    videoIndex: 0,
  });

  const others = videos.slice(1);

  let mode = heroSecondaryMode === undefined ? 0 : heroSecondaryMode;
  if (mode === 6) {
    // "Random": pick one concrete secondary mode per cycle deterministically.
    mode = Math.floor(rng() * 5) + 1; // 1..5 (brick/columns/rows/mosaic/collage)
  }

  if (others.length === 0) {
    return rects;
  }

  // All secondary modes share ONE strip-aware, sliver-free filler. The strip's
  // orientation (tall vs wide) determines whether we stack vertically (columns)
  // or flow horizontally (rows); every cell fills its slot so there are no gaps,
  // and each cell width/height is snapped to its video's native aspect so videos
  // crop-fill with no bars and no paper-thin slivers.
  const ox = strip.x;
  const oy = strip.y;
  const stripW = strip.w;
  const stripH = strip.h;
  const innerGutter = Math.max(3, Math.round(gutter * 0.5));

  // For the side grid (mode 0) we keep the row/column scheme; for the "reuse a
  // packer" modes (1..5) we still lay out strip-aware (not by recycling a
  // full-screen packer), because a full-screen packer against a narrow strip is
  // exactly what produced the slivers.
  const tallStrip = stripH >= stripW;

  if (tallStrip) {
    // Columnar: stack tiles vertically to fill the strip height completely.
    const n = others.length;
    const cols = n <= 3 ? 1 : 2;           // allow a 2nd column when enough tiles
    const perCol = Math.ceil(n / cols);
    const colW = (stripW - innerGutter * (cols + 1)) / cols;
    for (let c = 0; c < cols; c++) {
      let yCursor = oy + innerGutter;
      for (let k = 0; k < perCol; k++) {
        const i = c * perCol + k;
        if (i >= n) break;
        // Budget the remaining height across the cells in this column, then
        // snap each cell height to its video aspect (with a floor so no sliver).
        const budgetH = (stripH - innerGutter * (perCol + 1)) / perCol;
        const vidAspect = others[i] && others[i].aspect > 0 ? others[i].aspect : 16 / 9;
        const idealH = colW / vidAspect;
        const h = Math.max(budgetH * 0.45, Math.min(budgetH * 1.6, idealH));
        rects.push({
          x: ox + innerGutter + c * (colW + innerGutter),
          y: yCursor,
          w: colW,
          h: h,
          aspect: colW / h,
          orientation: inferAspect(colW, h).orientation,
          videoIndex: i + 1,
        });
        yCursor += h + innerGutter;
      }
    }
  } else {
    // Row-wise: flow tiles left-to-right to fill the strip width completely.
    const n = others.length;
    const rows = n <= 2 ? 1 : (n <= 4 ? 2 : Math.round(Math.sqrt(n)));
    const perRow = Math.ceil(n / rows);
    const rowH = (stripH - innerGutter * (rows + 1)) / rows;
    for (let r = 0; r < rows; r++) {
      let xCursor = ox + innerGutter;
      for (let k = 0; k < perRow; k++) {
        const i = r * perRow + k;
        if (i >= n) break;
        const inThisRow = Math.min(perRow, n - r * perRow);
        const budgetW = (stripW - innerGutter * (inThisRow + 1)) / inThisRow;
        const vidAspect = others[i] && others[i].aspect > 0 ? others[i].aspect : 16 / 9;
        const idealW = rowH * vidAspect;
        const w = Math.max(budgetW * 0.45, Math.min(budgetW * 1.6, idealW));
        rects.push({
          x: xCursor,
          y: oy + innerGutter + r * (rowH + innerGutter),
          w: w,
          h: rowH,
          aspect: w / rowH,
          orientation: inferAspect(w, rowH).orientation,
          videoIndex: i + 1,
        });
        xCursor += w + innerGutter;
      }
    }
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

  // Justified (column-flow) collage: split videos into rows/columns that fill
  // the full extent exactly, with each tile height set by its video's native
  // aspect, so mixed-aspect videos interlock like a real photo collage rather
  // than a rigid grid that leaves slivers or black gaps. A seeded jitter keeps a
  // light "scattered pile" feel without opening real gaps.
  const horizontal = screenW >= screenH;

  if (horizontal) {
    // Rows that together sum to a target height, each row filling full width.
    const cols = Math.max(1, Math.round(Math.sqrt(n * (screenW / screenH))));
    const rows = Math.ceil(n / cols);
    const contentH = screenH - gutter * (rows + 1);
    const contentW = screenW - gutter * (cols + 1);
    for (let i = 0; i < n; i++) {
      const c = i % cols;
      const r = Math.floor(i / cols);
      const vidAspect = videos[i] && videos[i].aspect > 0 ? videos[i].aspect : 16 / 9;
      const baseW = contentW / cols;
      const baseH = contentH / rows;
      // Width stays in its column slot; height follows the video aspect but is
      // bounded so one portrait video doesn't blow the row apart.
      const w = baseW * (1.0 + rng() * 0.04);
      const idealH = w / vidAspect;
      const h = Math.max(baseH * 0.7, Math.min(baseH * 1.4, idealH));
      const jx = (rng() - 0.5) * baseW * 0.06;
      const jy = (rng() - 0.5) * baseH * 0.06;
      rects.push({
        x: gutter + c * (baseW + gutter) + jx,
        y: gutter + r * (baseH + gutter) + jy,
        w: w,
        h: h,
        aspect: w / h,
        orientation: inferAspect(w, h).orientation,
        videoIndex: i,
      });
    }
  } else {
    // Portrait: columns that stack to fill the full height.
    const rows = Math.max(1, Math.round(Math.sqrt(n * (screenH / screenW))));
    const cols = Math.ceil(n / rows);
    const contentW = screenW - gutter * (cols + 1);
    const contentH = screenH - gutter * (rows + 1);
    for (let i = 0; i < n; i++) {
      const r = i % rows;
      const c = Math.floor(i / rows);
      const vidAspect = videos[i] && videos[i].aspect > 0 ? videos[i].aspect : 16 / 9;
      const baseW = contentW / cols;
      const baseH = contentH / rows;
      const w = baseW * (1.0 + rng() * 0.04);
      const idealH = w / vidAspect;
      const h = Math.max(baseH * 0.7, Math.min(baseH * 1.4, idealH));
      const jx = (rng() - 0.5) * baseW * 0.06;
      const jy = (rng() - 0.5) * baseH * 0.06;
      rects.push({
        x: gutter + c * (baseW + gutter) + jx,
        y: gutter + r * (baseH + gutter) + jy,
        w: w,
        h: h,
        aspect: w / h,
        orientation: inferAspect(w, h).orientation,
        videoIndex: i,
      });
    }
  }

  // Seal hairlines with slight zoom/overlap so the scattered tiles butt
  // together instead of leaving thin gaps.
  return overlapToFill(rects, screenW, screenH, tolerance);
}

/*
 * Columns: vertical masonry columns, gap-free (tiles tile each column fully).
 * Each column spans the full screen height and tiles are stacked to fill it.
 */
/*
 * Bands (unified Rows/Columns): gap-free horizontal or vertical bands chosen to
 * match the SCREEN orientation (wide screen -> horizontal rows, tall screen ->
 * vertical columns), so the layout never fights the aspect ratio. Each band's
 * cells are snapped to their videos' native aspects so mixed-aspect videos fill
 * the space edge-to-edge without slivers, and cells snake (left-to-right then
 * right-to-left) so neighbouring tiles are drawn from opposite ends of the
 * video list — increasing the chance that adjacent tiles have differing aspects
 * and interlock well rather than all being identical slivers.
 */
function packBands(screenW, screenH, videos, rng, tolerance) {
  if (!videos.length || screenW <= 0 || screenH <= 0) {
    return [];
  }
  const n = videos.length;
  const rects = [];
  const horizontal = screenW >= screenH;

  if (horizontal) {
    // Horizontal rows spanning the full width.
    const rows = Math.max(1, Math.round(Math.sqrt(n * (screenW / screenH))));
    const rowH = screenH / rows;
    const perRow = Math.ceil(n / rows);
    for (let r = 0; r < rows; r++) {
      let x = 0;
      let remainingInRow = 0;
      for (let k = 0; k < perRow; k++) {
        const idx = r * perRow + k;
        if (idx >= n) break;
        if (k === 0) remainingInRow = Math.min(perRow, n - r * perRow);
        const budgetW = screenW / remainingInRow;
        const vidAspect = videos[idx] && videos[idx].aspect > 0 ? videos[idx].aspect : 16 / 9;
        const w = Math.min(budgetW * 1.5, Math.max(budgetW * 0.5, rowH * vidAspect));
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
  } else {
    // Vertical columns spanning the full height.
    const cols = Math.max(1, Math.round(Math.sqrt(n * (screenH / screenW))));
    const colW = screenW / cols;
    const perCol = Math.ceil(n / cols);
    for (let c = 0; c < cols; c++) {
      let y = 0;
      for (let k = 0; k < perCol; k++) {
        const idx = c * perCol + k;
        if (idx >= n) break;
        const inThisCol = Math.min(perCol, n - c * perCol);
        const budgetH = screenH / inThisCol;
        const vidAspect = videos[idx] && videos[idx].aspect > 0 ? videos[idx].aspect : 16 / 9;
        const h = Math.min(budgetH * 1.5, Math.max(budgetH * 0.5, colW / vidAspect));
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
      // Re-normalize the column so stacked cells exactly fill screen height.
      const colRects = rects.filter(rect => rect.x === c * colW);
      const totalH = colRects.reduce((s, rect) => s + rect.h, 0) || 1;
      if (Math.abs(totalH - screenH) > 1) {
        let yy = 0;
        for (const rect of colRects) {
          rect.h = (rect.h / totalH) * screenH;
          rect.y = yy;
          rect.aspect = rect.w / rect.h;
          rect.orientation = inferAspect(rect.w, rect.h).orientation;
          yy += rect.h;
        }
      }
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
function buildGraph(seed, screenW, screenH, videos, mergeDurationMs, style, transformCountBeforeFull, choreographyMode, heroSecondaryMode, mazeSize) {
  // Memoize on serializable arguments.
  let key;
  try {
    key = ["choreo", seed, screenW, screenH, mergeDurationMs, style, transformCountBeforeFull, choreographyMode, heroSecondaryMode === undefined ? 0 : heroSecondaryMode, mazeSize === undefined ? 5 : mazeSize, videos.map(v => [v.filename, v.aspect]).join("|")].join("\u0001");
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
  const heroSec = heroSecondaryMode === undefined ? 0 : heroSecondaryMode;
  const maze = Math.max(1, mazeSize === undefined ? 5 : mazeSize);
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
      // MazeWalk: the walk determines its own step count. It wanders the
      // lattice (tile count) with a bias toward the center, clamping at the
      // edges — exactly when it reaches the center (1) or an edge (maxCount) is
      // decided by the walk itself, NOT by a fixed step budget. There is no
      // "transforms before full screen" notion here; the number of merges or
      // splits that happen is emergent from the walk's dynamics.
      let c = maxCount;

      // Wander: move by a seeded ±maze stride with a bias, bouncing off the
      // edges (clamped 1..max). The stride magnitude is drawn from 1..maze so
      // the maze size directly scales how far the walker roams per step.
      //
      // The loop has a hard iteration cap as a safety net: with an adversarial
      // mix of `maze` stride and the 0.45 wander chance, the walker can bounce
      // in the upper band (maxCount ↔ maxCount-1) for a very long time before
      // visiting the center. Without a cap this manifests as a transform that
      // "freezes" — the worker spins building an unbounded phase graph. The cap
      // guarantees termination while keeping the walk's emergent length for all
      // realistic `mazeSize`/`maxTiles` combinations.
      const MAX_WALK_STEPS = maxCount * 64 + 128;
      let steps = 0;
      while (true) {
        let delta = 0;
        if (c <= 1) {
          delta = 1;
        } else if (c >= maxCount) {
          delta = -1;
        } else {
          // Bias toward moving back toward the center: when below the midpoint
          // we climb, above it we shrink — with some randomness so it wanders
          // rather than marching deterministically.
          const midpoint = maxCount / 2;
          const towardCenter = c < midpoint ? 1 : -1;
          const wanderChance = 0.45;
          const direction = rng() < wanderChance ? -towardCenter : towardCenter;
          const stride = 1 + Math.floor(rng() * maze);
          delta = direction * stride;
        }
        const next = Math.max(1, Math.min(maxCount, c + delta));
        seq.push(next);
        c = next;
        steps++;
        // A full pendulum: stop once we've returned to the maximum count after
        // having visited the center. The walk produces its own length.
        if (c === maxCount && seq.some(x => x === 1)) {
          break;
        }
        // Safety: if the walker has wandered too long without completing a
        // pendulum, snap straight to the center (1) so the loop is guaranteed to
        // finish on the next return to `maxCount`.
        if (steps >= MAX_WALK_STEPS) {
          if (c !== 1) {
            seq.push(1);
            c = 1;
          }
          // Force-terminate: append the closing return to maxCount.
          seq.push(maxCount);
          break;
        }
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
    // Clamp to the number of available videos up front: the target count is a
    // FIXED value, whereas `pool.length` shrinks each time we splice. Using the
    // live `pool.length` as the loop bound made the loop terminate around half
    // the requested count (i grows while pool.length shrinks -> they meet in the
    // middle), which is what produced the "ceil(N/2)" tile-count bug.
    const want = Math.min(cCount, all.length);
    let best = null;
    let bestScore = Infinity;
    for (let t = 0; t < trials; t++) {
      const pool = all.slice();
      const cand = [];
      for (let i = 0; i < want && pool.length > 0; i++) {
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

  // ---------------------------------------------------------------------------
  // Both the "which videos appear per step" (pickSubset) and the "winner" are
  // driven by the SHARED `rng`, whose call ORDER across all steps determines the
  // result. These are cheap (just rng()+score arithmetic), so we compute them
  // eagerly up front, in order, to preserve byte-for-byte identical output. The
  // expensive masonry packing (`packLayout`) is reproduced PER STEP from a fresh
  // `mulberry32(seed ^ si)` seed, so it can be deferred to lazy chunks without
  // changing the result.
  // ---------------------------------------------------------------------------
  const srcIdxPerStep = countSeq.map((cCount, si) => pickSubset(cCount, screenW, screenH, si));
  const winnerIndex = Math.floor(rng() * n);

  // Materialize ONE step's `tiles` (the { srcVideo, from, to } rects) plus, for
  // step `si`, the phase objects it contributes. This is the only function that
  // touches `packLayout`, so it is the unit we chunk. `prevTilesArg` is the
  // previous step's `tiles` (or null for step 0) — carried across chunk
  // boundaries.
  function makeStep(si, prevTilesArg) {
    const cCount = countSeq[si];
    const srcIdx = srcIdxPerStep[si];

    const aspectVideos = srcIdx.map(idx => ({ filename: videos[idx].filename, aspect: videos[idx].aspect > 0 ? videos[idx].aspect : 16 / 9 }));
    const rects = packLayout(st, screenW, screenH, aspectVideos, mulberry32(seed ^ si), 0.1, heroSec);

    const tiles = rects.map((r, i) => ({
      srcVideo: srcIdx[i] !== undefined ? srcIdx[i] : 0,
      from: region(r.x, r.y, r.w, r.h),
      to: region(r.x, r.y, r.w, r.h),
    }));

    const out = [];
    if (si === 0) {
      out.push({ name: "grid", count: cCount, tiles, durationMs: 0, sharedSegmentMs: 0 });
    } else {
      // Spatially-continuous interpolation: the merged tile grows from the
      // union of the previous stage's region to its own region.
      const prevTiles = prevTilesArg;
      const mergedTiles = tiles.map((cur) => ({
        srcVideo: cur.srcVideo,
        from: unionRegion(prevTiles && prevTiles.length > 0 ? prevTiles.map(p => p.to) : [cur.from]),
        to: cur.to,
      }));
      out.push({ name: "converge", count: cCount, tiles: mergedTiles, prevTiles, durationMs: mergeDurationMs, sharedSegmentMs: 0 });
    }

    if (si < countSeq.length - 1) {
      // Hold duration is driven by segment lengths + the segment-end monitor,
      // NOT a fixed merge interval. 0 here means `tick()` never auto-advances
      // from a hold; only a finished segment advances the choreography.
      out.push({ name: "hold", count: cCount, tiles, durationMs: 0, sharedSegmentMs: 1 });
    }
    return { tiles, phases: out };
  }

  // ---------------------------------------------------------------------------
  // Chunked phase store. `phases` is the flat array TilesPlayer already iterates
  // (`graph.phases[i]`, `graph.phases.length`). We populate it lazily in blocks
  // of CHUNK_SIZE steps so the UI thread never packs more than a handful of
  // layouts at once and memory stays bounded for long Maze Walk chains.
  // ---------------------------------------------------------------------------
  const CHUNK_SIZE = 16;
  const phases = [];
  let materializedSteps = 0;        // number of STEPs whose phases are in `phases`
  let prevTilesForNext = null;      // `tiles` of the last materialized step

  function ensureChunk(phaseIndex) {
    // Grow until `phaseIndex` is within the materialized phases. Since each step
    // contributes 2 phases except the final step (which contributes 1), we just
    // keep materializing steps until the requested phase index is covered.
    while (phaseIndex >= phases.length && materializedSteps < countSeq.length) {
      const batchEnd = Math.min(countSeq.length, materializedSteps + CHUNK_SIZE);
      for (let si = materializedSteps; si < batchEnd; si++) {
        const step = makeStep(si, prevTilesForNext);
        for (const p of step.phases) {
          phases.push(p);
        }
        prevTilesForNext = step.tiles;
      }
      materializedSteps = batchEnd;
    }
  }
  // Materialize the first chunk eagerly so step 0 (the initial grid) is ready.
  ensureChunk(0);

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
    // Internal chunk-refill API used by TilesPlayer to pull the next block
    // ahead of the playback cursor.
    ensurePhases: ensureChunk,
    totalSteps: countSeq.length,
    // True full phase count = 2*steps - 1 (grid + holds for all but the last
    // step, which contributes only a converge with no trailing hold).
    totalPhases: Math.max(1, countSeq.length * 2 - 1),
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
 * Build a pure, JSON-serializable "plan" for a choreography graph. This runs the
 * cheap parts (the count walk + per-step video subsets + winner) and captures all
 * the state needed to materialize each step later — including in a WorkerScript on
 * a separate thread. Unlike `buildGraph`, this returns NO closures, NO lazy arrays,
 * and NO QML objects: everything is plain data that can cross a `sendMessage`
 * boundary. `materializePlanStep` below reproduces each step's phases from the plan.
 */
/*
 * `buildGraphPlan` is a pure function of its inputs — the returned plan is fully
 * determined by (seed, geometry, video aspects, mode). We memoize it so the
 * worker path (and any repeated rebuild that hits the same parameters) skips the
 * count-walk + subset-scoring recompute that dominated build cost.
 * ------------------------------------------------------------------
 */
// Bounded LRU cache for buildGraphPlan results (memory cache).
var planCache = (typeof Map !== "undefined") ? new Map() : null;
var planCacheMax = 8;

function buildGraphPlan(seed, screenW, screenH, videos, mergeDurationMs, style, transformCountBeforeFull, choreographyMode, heroSecondaryMode, mazeSize) {
  // ------------------------------------------------------------------
  // Memoization: the plan is fully determined by these inputs, so we can
  // skip the whole build when the same (seed, geometry, video set, mode)
  // is requested again within the same session. This is what lets the
  // worker path (and repeated rebuild hits) avoid recomputing the count
  // walk + subset scoring, which were the dominant cost. Bounded LRU so
  // memory stays flat regardless of how many distinct parameters appear.
  // ------------------------------------------------------------------
  const key = [
    seed >>> 0,
    Math.round(screenW), Math.round(screenH),
    videos.length,
    videos.map(v => (v.aspect > 0 ? v.aspect : 16 / 9).toFixed(4)).join(","),
    mergeDurationMs | 0,
    style | 0, transformCountBeforeFull | 0,
    choreographyMode | 0, heroSecondaryMode | 0, mazeSize | 0,
  ].join("|");
  if (planCache.has(key)) {
    return planCache.get(key);
  }

  const result = withTiming("buildGraphPlan", function () {
    return buildGraphPlanUncached(seed, screenW, screenH, videos, mergeDurationMs, style, transformCountBeforeFull, choreographyMode, heroSecondaryMode, mazeSize);
  }, 50);

  planCache.set(key, result);
  while (planCache.size > planCacheMax) {
    planCache.delete(planCache.keys().next().value);
  }
  return result;
}

function buildGraphPlanUncached(seed, screenW, screenH, videos, mergeDurationMs, style, transformCountBeforeFull, choreographyMode, heroSecondaryMode, mazeSize) {
  const st = style === undefined ? 0 : style;
  const steps = Math.max(1, transformCountBeforeFull === undefined ? 5 : transformCountBeforeFull);
  const mode = choreographyMode === undefined ? 0 : choreographyMode;
  const heroSec = heroSecondaryMode === undefined ? 0 : heroSecondaryMode;
  const maze = Math.max(1, mazeSize === undefined ? 5 : mazeSize);
  const n = videos.length;

  const rng = mulberry32(seed ^ 0x9E3779B9);

  function region(x, y, w, h) { return { x, y, w, h }; }
  function unionRegion(regions) {
    const x = Math.min(...regions.map(r => r.x));
    const y = Math.min(...regions.map(r => r.y));
    const x2 = Math.max(...regions.map(r => r.x + r.w));
    const y2 = Math.max(...regions.map(r => r.y + r.h));
    return region(x, y, x2 - x, y2 - y);
  }

  // Count walk (tile count over time).
  function countWalk() {
    const maxCount = Math.max(1, n);
    const seq = [maxCount];
    if (mode === 1) {
      let c = maxCount;
      // Hard cap as a safety net (see the comment in buildGraph's countWalk):
      // prevents an adversarial walk from spinning unbounded phase generation.
      const MAX_WALK_STEPS = maxCount * 64 + 128;
      let steps = 0;
      while (true) {
        let delta = 0;
        if (c <= 1) delta = 1;
        else if (c >= maxCount) delta = -1;
        else {
          const midpoint = maxCount / 2;
          const towardCenter = c < midpoint ? 1 : -1;
          const wanderChance = 0.45;
          const direction = rng() < wanderChance ? -towardCenter : towardCenter;
          const stride = 1 + Math.floor(rng() * maze);
          delta = direction * stride;
        }
        const next = Math.max(1, Math.min(maxCount, c + delta));
        seq.push(next);
        c = next;
        steps++;
        if (c === maxCount && seq.some(x => x === 1)) break;
        if (steps >= MAX_WALK_STEPS) {
          if (c !== 1) { seq.push(1); c = 1; }
          seq.push(maxCount);
          break;
        }
      }
    } else {
      let c = maxCount;
      while (c > 1) { c = c - 1; seq.push(c); }
    }
    return seq;
  }
  const countSeq = countWalk();

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
      if (screenPortrait && landscape) orientPenalty += 1;
      else if (!screenPortrait && portrait) orientPenalty += 1;
    }
    return variance + orientPenalty;
  }
  function pickSubset(cCount, screenW, screenH, salt) {
    const all = videos.map((_, i) => i);
    const trials = 12;
    // The target count is fixed; the live `pool.length` shrinks as we splice, so
    // it must not be the loop bound (see the identical note in buildGraph).
    const want = Math.min(cCount, all.length);
    let best = null;
    let bestScore = Infinity;
    for (let t = 0; t < trials; t++) {
      const pool = all.slice();
      const cand = [];
      for (let i = 0; i < want && pool.length > 0; i++) {
        const j = Math.floor(rng() * pool.length);
        cand.push(pool.splice(j, 1)[0]);
      }
      const s = scoreSubset(cand, screenW, screenH);
      if (s < bestScore) { bestScore = s; best = cand; }
    }
    return best || [];
  }

  const srcIdxPerStep = countSeq.map((cCount, si) => pickSubset(cCount, screenW, screenH, si));
  const winnerIndex = Math.floor(rng() * n);

  return {
    seed,
    style: st,
    mode,
    heroSecondaryMode: heroSec,
    mazeSize: maze,
    screenW,
    screenH,
    n,
    // Serialize only the filename+aspect that the packers need.
    videos: videos.map(v => ({ filename: v.filename, aspect: v.aspect > 0 ? v.aspect : 16 / 9 })),
    mergeDurationMs,
    steps,
    countSeq,
    srcIdxPerStep,
    winnerIndex,
    totalSteps: countSeq.length,
    totalPhases: Math.max(1, countSeq.length * 2 - 1),
  };
}

/*
 * Materialize a single step `si` of a plan into its concrete tiles + phases.
 * Pure and deterministic: identical to the per-step logic inside `buildGraph`.
 * `prevTiles` is the previous step's `tiles` array (or null for step 0), carried
 * across chunk boundaries so spatial interpolation stays continuous.
 */
function materializePlanStep(plan, si, prevTiles) {
  const { seed, style, screenW, screenH, videos, mergeDurationMs, countSeq, srcIdxPerStep } = plan;
  const heroSec = plan.heroSecondaryMode === undefined ? 0 : plan.heroSecondaryMode;
  const cCount = countSeq[si];
  const srcIdx = srcIdxPerStep[si];

  const aspectVideos = srcIdx.map(idx => ({ filename: videos[idx].filename, aspect: videos[idx].aspect > 0 ? videos[idx].aspect : 16 / 9 }));
  const rects = packLayout(style, screenW, screenH, aspectVideos, mulberry32(seed ^ si), 0.1, heroSec);

  const tiles = rects.map((r, i) => ({
    srcVideo: srcIdx[i] !== undefined ? srcIdx[i] : 0,
    from: { x: r.x, y: r.y, w: r.w, h: r.h },
    to: { x: r.x, y: r.y, w: r.w, h: r.h },
  }));

  const out = [];
  if (si === 0) {
    out.push({ name: "grid", count: cCount, tiles, durationMs: 0, sharedSegmentMs: 0 });
  } else {
    const mergedTiles = tiles.map((cur) => {
      let from = cur.from;
      if (prevTiles && prevTiles.length > 0) {
        const x = Math.min(...prevTiles.map(p => p.to.x));
        const y = Math.min(...prevTiles.map(p => p.to.y));
        const x2 = Math.max(...prevTiles.map(p => p.to.x + p.to.w));
        const y2 = Math.max(...prevTiles.map(p => p.to.y + p.to.h));
        from = { x, y, w: x2 - x, h: y2 - y };
      }
      return { srcVideo: cur.srcVideo, from, to: cur.to };
    });
    out.push({ name: "converge", count: cCount, tiles: mergedTiles, prevTiles, durationMs: mergeDurationMs, sharedSegmentMs: 0 });
  }

  if (si < countSeq.length - 1) {
    out.push({ name: "hold", count: cCount, tiles, durationMs: 0, sharedSegmentMs: 1 });
  }
  return { tiles, phases: out };
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





