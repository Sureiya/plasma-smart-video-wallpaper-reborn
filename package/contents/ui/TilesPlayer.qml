pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import QtMultimedia
import QtQml
import "code/utils.js" as Utils
import "code/TilesLayout.js" as TilesLayout
import "code/enum.js" as Enum

/*
 * TilesPlayer — coordinator for Tiles mode.
 *
 * Renders up to `maxTiles` simultaneous video tiles arranged by a masonry
 * layout computed from the screen size and each video's aspect/orientation.
 * The entire choreography (staggered start -> shifts -> converge/merge ->
 * winner full-screen -> re-expand) is precomputed as a transformation graph by
 * TilesLayout and replayed deterministically here.
 */
Item {
    id: root

    // -- Inputs --
    property var videosConfig: []            // Utils video objects
    property int maxTiles: 6
    property int mergeDuration: 1500         // ms
    property bool randomize: true
    property real aspectTolerance: 0.1       // 0..1
    property int layoutStyle: 0              // TilesLayoutStyle enum
    property int transformCountBeforeFull: 5 // converge stages before full screen
    property int segmentMinMs: 3000          // min video segment length
    property int segmentMaxMs: 15000         // max video segment length
    property int choreographyMode: 0         // TilesChoreographyMode enum
    property int heroSecondaryMode: 0        // TilesHeroSecondaryMode enum (Hero side region)
    property int mazeSize: 5                 // TilesMazeSize: maze walk state-space breadth
    property string metadataCacheJson: "{}"  // per-video metadata cache JSON string (from cache file)
    // Per-monitor salt so two wallpapers on different screens never replay the
    // identical choreography / video sequence in lockstep.
    property int monitorSalt: 0
    // Rank of this monitor (0 = leftmost) and the total number of monitors.
    // Together they partition the shared video library so no video can play on
    // two tiles at once (each monitor only draws from its own disjoint slice).
    property int monitorRank: 0
    property int monitorCount: 2
    property color backgroundColor: "#000000"
    property bool muted: true
    property int fillMode: VideoOutput.PreserveAspectCrop
    property bool fillBlur: true
    property int fillBlurRadius: 32
    property real globalVolume: 1.0
    property real globalPlaybackRate: 1.0
    property string audioOutputDevice
    property bool shouldPlay: true
    property bool debugEnabled: false

    // -- Border (letterbox/pillarbox) detection cache --
    // Maps filename -> { x, y, w, h } crop rect (in source pixels) or null if
    // no significant bars were found. Filled asynchronously via ffprobe.
    property var cropCache: ({})

    RunCommand {
        id: borderCommand
    }

    // WorkerScript runs TilesWorker.js on a separate thread, so the masonry
    // packing (packLayout) never blocks the UI thread when the choreography
    // rebuilds at the end of a cycle. Outbound messages are queued by Qt until
    // the worker thread is ready, so we don't need a "ready" handler; we just
    // send and handle replies via onMessage.
    WorkerScript {
        id: graphWorker
        source: "code/TilesWorker.js"
        onMessage: (msg) => root.onWorkerMessage(msg)
    }

    // Best-effort detection of black bars using ffprobe's cropdetect on the
    // first few seconds. Results are cached so each video is only probed once.
    function detectBorders(filename) {
        if (!filename || filename in root.cropCache) {
            return;
        }
        root.cropCache[filename] = null; // mark in-flight to avoid re-probing
        // Query stream dims and container duration with clear delimiters so the
        // parse is robust (stream entries then a DURATION= line).
        const cmd = `ffprobe -v error -select_streams v:0 ` +
            `-show_entries stream=width,height -show_entries format=duration ` +
            `-of csv=p=0 -of default=noprint_wrappers=0 "${filename}" ` +
            `&& echo DURATION= && ffprobe -v error -show_entries format=duration ` +
            `-of csv=p=0 "${filename}"`;
        borderCommand.exec(cmd, res => {
            const out = (res.stdout || "");
            // width,height are the first csv line; duration is after DURATION=.
            const lines = out.split("\n").map(l => l.trim()).filter(l => l.length > 0);
            let w = 0, h = 0, durMs = 0;
            // width,height from the first numeric csv line
            for (const l of lines) {
                if (l === "DURATION=" || l.includes("DURATION")) continue;
                const parts = l.split(",");
                if (parts.length >= 2) {
                    const pw = parseInt(parts[0], 10);
                    const ph = parseInt(parts[1], 10);
                    if (pw > 0 && ph > 0 && w === 0) {
                        w = pw;
                        h = ph;
                        break;
                    }
                }
            }
            // duration from the segment after DURATION=
            const dIdx = lines.indexOf("DURATION=");
            if (dIdx >= 0 && lines[dIdx + 1] !== undefined) {
                const dv = parseFloat(lines[dIdx + 1]);
                if (!isNaN(dv)) durMs = Math.round(dv * 1000);
            }
            if (w > 0 && h > 0) {
                root.cropCache[filename] = { x: 0, y: 0, w, h, duration: durMs };
            }
        });
    }

    function getCropRect(filename) {
        return root.cropCache[filename] || null;
    }

    // -- Internal state --
    property int cycleSeed: 0
    property var activeVideos: []

    // Full-screen background so layout gaps read as intentional negative space
    // rather than rendering errors.
    Rectangle {
        anchors.fill: parent
        color: root.backgroundColor
    }

    // We manage tiles explicitly (not a Repeater) so each TileVideo can be
    // re-targeted and re-geometry'd from the graph without destroying/recreating
    // MediaPlayer instances (heavy). The pool is sized to EXACTLY the maximum
    // simultaneous tile count, and kept in sync whenever `maxTiles` changes so
    // every monitor gets its own full set of `maxTiles` (never a fraction of a
    // shared number).
    Item {
        id: tileHost
        anchors.fill: parent

        property var tiles: []

        // Resize the tile instance pool so `tileHost.tiles.length === maxTiles`.
        // Grow by creating fresh TileVideo instances; shrink by destroying the
        // trailing extras (their MediaPlayers are released). This guarantees each
        // monitor independently renders up to `maxTiles` tiles regardless of how
        // many screens share a config.
        function syncTilePool() {
            const want = root.maxSimultaneousTiles;
            while (tileHost.tiles.length < want) {
                const t = tileComponent.createObject(tileHost, { z: 1 });
                tileHost.tiles.push(t);
            }
            while (tileHost.tiles.length > want) {
                const t = tileHost.tiles.pop();
                if (t) {
                    t.destroy();
                }
            }
        }

        Component.onCompleted: {
            tileHost.syncTilePool();
            root.rebuildGraph();
        }
    }

    Component {
        id: tileComponent
        TileVideo {
            muted: true
            fillMode: root.fillMode
            // Disable per-tile fill blur: the ShaderEffectSource + FastBlur in
            // VideoPlayer are far too expensive with many simultaneous tiles,
            // and tiles crop-fill their cells so there is nothing to blur.
            fillBlur: false
            fillBlurRadius: 0
            globalVolume: root.globalVolume
            globalPlaybackRate: root.globalPlaybackRate
            audioOutputDevice: root.audioOutputDevice
            shouldPlay: root.shouldPlay
            debugEnabled: root.debugEnabled
        }
    }

    // The running graph + phase cursor.
    property var graph: null
    property int phaseIndex: 0
    property real phaseElapsed: 0
    // Timestamp (ms) of the last time the choreography advanced (either a tick
    // auto-advance or a segment-end advance). Used by freezeWatchdog to detect a
    // stalled phase and force progress so the wallpaper never freezes.
    property real lastAdvanceTime: 0

    // -- Worker offload state (graph precomputation on a separate thread) --
    property int graphId: 0
    // Packet for the currently-building graph (main thread -> worker "build").
    property var buildingGraph: null       // { graphId, aspects, seed, style }
    property bool building: false
    // The next cycle's precomputed graph, ready to adopt when the current wraps.
    property var nextGraph: null           // assembled graph object (worker result)
    // True once the worker has produced at least one result (so we know it's up).
    property bool workerAlive: false

    // Timestamp captured when a graph build is dispatched, so we can report the
    // worker round-trip latency when debugging is enabled (see onWorkerMessage).
    property real buildStartTime: 0

    // Maximum tiles to instantiate = the cascade's starting count, which is
    // bounded by maxTiles (the user's decode cap).
    readonly property int maxSimultaneousTiles: Math.max(1, root.maxTiles)

    Timer {
        id: advanceTimer
        interval: 16
        repeat: true
        running: root.graph !== null && root.shouldPlay
        onTriggered: root.tick();
    }

    // Watchdog: safety net that forces forward progress if the choreography
    // stalls (e.g. media not loading / a phase that never advances). With
    // time-based phases this should rarely fire, but it guarantees the wallpaper
    // can never deadlock. Paused when the wallpaper should stop (screen covered).
    Timer {
        id: freezeWatchdog
        interval: 500
        repeat: true
        running: root.graph !== null && root.shouldPlay
        onTriggered: {
            if (!root.graph || !root.shouldPlay) return;
            const now = Date.now();
            // Grace = longest phase duration + merge time + a safety margin.
            const graceMs = root.segmentMaxMs + root.mergeDuration + 2500;
            if (now - root.lastAdvanceTime > graceMs) {
                root.advanceTransform();
            }
        }
    }

    function buildVideoAspects(videos) {
        const metaCache = Utils.parseMetadataCache(root.metadataCacheJson);
        return videos.map(v => {
            let aspect = 16 / 9;
            // Prefer cached metadata (native aspect + resolution) for accurate
            // layout, then the crop rect, then a default.
            const meta = Utils.getCachedMetadata(metaCache, v.filename);
            if (meta && meta.aspect > 0) {
                aspect = meta.aspect;
            } else if (meta && meta.width > 0 && meta.height > 0) {
                aspect = meta.width / meta.height;
            } else {
                const crop = root.getCropRect(v.filename);
                if (crop && crop.w > 0 && crop.h > 0) {
                    aspect = crop.w / crop.h;
                } else if (v.aspect > 0) {
                    aspect = v.aspect;
                }
            }
            return {
                filename: v.filename,
                aspect: aspect,
                orientation: aspect > 1.1 ? "landscape" : (aspect < 0.9 ? "portrait" : "square"),
                duration: meta ? (meta.duration || 0) : (v.duration || 0),
            };
        });
    }

    // Return videos for this cycle (shuffled if randomize). The count is capped
    // by maxTiles. A working window of the full library is selected per cycle and
    // rotated so successive cycles surface DIFFERENT videos rather than
    // re-sampling the same leading slice forever. The shuffle is seeded (cycleSeed
    // ^ monitorSalt) so it is deterministic per monitor and diverges across screens,
    // instead of using Math.random which lets two monitors replay in lockstep.
    // Canonical, deterministic ordering of the shared library so every monitor
    // agrees on which video occupies which global slot. Sorted by filename, so
    // even when different instances shuffled the list differently they converge
    // on the same order and the rank partition below stays disjoint.
    function canonicalLibrary() {
        return root.videosConfig.slice().sort((a, b) =>
            String(a && a.filename ? a.filename : "").localeCompare(String(b && b.filename ? b.filename : "")));
    }

    // Return videos for this cycle (shuffled if randomize). The count is capped
    // by maxTiles. A working window of the full library is selected per cycle and
    // rotated so successive cycles surface DIFFERENT videos rather than
    // re-sampling the same leading slice forever. The shuffle is seeded (cycleSeed
    // ^ monitorSalt) so it is deterministic per monitor and diverges across screens,
    // instead of using Math.random which lets two monitors replay in lockstep.
    //
    // UNIQUENESS: each monitor draws only from a disjoint slice of the canonical
    // library (round-robin by monitorRank / monitorCount), so the same video can
    // never play on two tiles at once as long as there are enough distinct files.
    // When the library is smaller than the monitors' combined demand, slices
    // shrink (and may degrade gracefully), which is the "not enough videos" case.
    function pickCycleVideos() {
        if (!root.videosConfig || root.videosConfig.length === 0) return [];
        const count = Math.max(1, root.monitorCount);
        const rank = ((root.monitorRank % count) + count) % count;

        // Canonical order (shared across monitors), then keep only this monitor's
        // round-robin slice: indices rank, rank+count, rank+2*count, ...
        const canon = root.canonicalLibrary();
        const list = [];
        for (let i = rank; i < canon.length; i += count) {
            list.push(canon[i]);
        }

        const total = list.length;
        if (total === 0) return [];
        const want = Math.max(1, Math.min(root.maxTiles, total));
        if (!root.randomize) {
            return list.slice(0, want);
        }
        // Seeded Fisher–Yates producing a permutation of 0..total-1.
        const seed = ((root.cycleSeed + root.monitorSalt) >>> 0) || 1;
        let a = seed >>> 0;
        const rnd = () => {
            a |= 0; a = (a + 0x6D2B79F5) | 0;
            let t = Math.imul(a ^ (a >>> 15), 1 | a);
            t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
            return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
        };
        const perm = list.map((_, i) => i);
        for (let i = perm.length - 1; i > 0; i--) {
            const j = Math.floor(rnd() * (i + 1));
            const t = perm[i]; perm[i] = perm[j]; perm[j] = t;
        }
        // Rotate the window: advance the starting offset every cycle so the set of
        // `want` videos changes over time (wraps around this monitor's slice).
        const offset = (root.cycleSeed * want) % total;
        const out = [];
        for (let k = 0; k < want; k++) {
            out.push(list[perm[(offset + k) % total]]);
        }
        return out;
    }

    // Compute the per-cycle inputs (cheap, stays on the main thread) and return
    // a "build packet" describing the graph to materialize off-thread.
    function buildPacket() {
        if (!root.videosConfig || root.videosConfig.length === 0) return null;
        if (root.width <= 0 || root.height <= 0) return null;
        // Advance the cycle first so pickCycleVideos() sees the new offset/seed
        // (otherwise the window never rotates across cycles).
        root.cycleSeed = (root.cycleSeed + 1) >>> 0;
        const chosen = root.pickCycleVideos();
        root.activeVideos = chosen;

        // Kick off async border detection for any videos not yet cached.
        for (const v of chosen) {
            root.detectBorders(v.filename);
        }

        const aspects = root.buildVideoAspects(chosen);

        const seed = root.cycleSeed;

        let effectiveStyle = root.layoutStyle;
        if (effectiveStyle === Enum.TilesLayoutStyle.Random) {
            effectiveStyle = Math.floor(Math.random() * 7); // 0..6 (concrete styles)
        }
        return { aspects: aspects, seed: seed, style: effectiveStyle };
    }

    // Send a "build" request to the worker for the given packet.
    function sendBuild(packet) {
        root.buildingGraph = packet;
        root.building = true;
        if (root.debugEnabled) {
            root.buildStartTime = Date.now();
        }
        graphWorker.sendMessage({
            type: "build",
            graphId: packet.graphId,
            seed: packet.seed,
            screenW: root.width,
            screenH: root.height,
            videos: packet.aspects,
            mergeDurationMs: root.mergeDuration,
            style: packet.style,
            transformCountBeforeFull: root.transformCountBeforeFull,
            choreographyMode: root.choreographyMode,
            heroSecondaryMode: root.heroSecondaryMode,
            mazeSize: root.mazeSize,
            debug: root.debugEnabled,
        });
    }

    // Assemble a usable graph object from a worker "built" first-chunk reply.
    // `phases` keeps growing via chunk requests issued by `ensurePhases`.
    function assembleGraph(meta, firstChunkPhases) {
        const g = {
            graphId: meta.graphId,
            winnerIndex: meta.winnerIndex,
            totalSteps: meta.totalSteps,
            totalPhases: meta.totalPhases,
            countSeq: null,
            phases: firstChunkPhases.slice(),
            ensurePhases: null,
            _chunkDone: false,
            _chunkRequested: false,
        };
        g.ensurePhases = function (phaseIndex) {
            if (phaseIndex < g.phases.length) return;   // already materialized
            if (g._chunkDone || g._chunkRequested) return;
            g._chunkRequested = true;
            graphWorker.sendMessage({ type: "chunk", graphId: g.graphId });
        };
        return g;
    }

    // Handle replies from the worker thread.
    function onWorkerMessage(msg) {
        if (!msg) return;
        if (msg.type === "built") {
            root.building = false;
            root.workerAlive = true;
            if (root.debugEnabled && root.buildStartTime > 0) {
                const roundTripMs = Date.now() - root.buildStartTime;
                // Surface graph-build latency so stalls from an over-long plan
                // (worker saturated) are visible instead of invisible. A worker
                // build over ~50ms is a sign the plan precompute is the bottleneck
                // and the memo cache / look-ahead aren't covering it.
                if (roundTripMs > 50) {
                    console.warn("[TilesPlayer] graph build round-trip took",
                        roundTripMs.toFixed(1), "ms (graphId", msg.graphId + ")");
                } else {
                    console.log("[TilesPlayer] graph build round-trip",
                        roundTripMs.toFixed(1), "ms");
                }
                root.buildStartTime = 0;
            }
            const g = root.assembleGraph(msg, msg.phases);
            if (root.buildingGraph && root.buildingGraph.graphId === msg.graphId) {
                const wasPreload = root.buildingGraph.preload === true;
                root.buildingGraph = null;
                if (wasPreload) {
                    root.nextGraph = g;
                    // Eagerly drain remaining chunks so the next graph is fully
                    // materialized (and fully off-thread) before it's adopted.
                    if (g.phases.length < g.totalPhases) {
                        g._chunkRequested = true;
                        graphWorker.sendMessage({ type: "chunk", graphId: g.graphId });
                    }
                } else {
                    root.startGraph(g);
                }
            } else {
                root.nextGraph = g;
            }
        } else if (msg.type === "chunk") {
            const target = root.graph && root.graph.graphId === msg.graphId ? root.graph
                         : (root.nextGraph && root.nextGraph.graphId === msg.graphId ? root.nextGraph : null);
            if (!target) return;
            target._chunkRequested = false;
            if (msg.done) {
                target._chunkDone = true;
            } else if (msg.phases) {
                for (const p of msg.phases) target.phases.push(p);
                // Keep draining a look-ahead graph until it is fully materialized.
                if (target === root.nextGraph && target.phases.length < target.totalPhases) {
                    target._chunkRequested = true;
                    graphWorker.sendMessage({ type: "chunk", graphId: target.graphId });
                }
            }
        }
    }

    // Begin playing a freshly assembled graph.
    function startGraph(g) {
        root.graph = g;
        root.phaseIndex = 0;
        root.phaseElapsed = 0;
        root.lastAdvanceTime = Date.now();
        root.applyPhase(0);
        root.applySegments();
    }

    // Precompute the NEXT cycle's graph during the current one (look-ahead), so
    // the end-of-cycle wrap never stalls the UI thread.
    function requestNextGraph() {
        if (root.nextGraph || root.building) return;
        const packet = root.buildPacket();
        if (!packet) return;
        packet.graphId = ++root.graphId;
        packet.preload = true;
        root.sendBuild(packet);
    }

    function rebuildGraph() {
        const packet = root.buildPacket();
        if (!packet) {
            root.graph = null;
            return;
        }
        // Prefer a precomputed next graph if one is waiting.
        packet.graphId = ++root.graphId;

        if (root.workerAlive) {
            root.sendBuild(packet);
        } else {
            // Worker hasn't replied yet: synchronous deterministic fallback.
            const plan = TilesLayout.buildGraphPlan(
                packet.seed, root.width, root.height, packet.aspects,
                root.mergeDuration, packet.style,
                root.transformCountBeforeFull, root.choreographyMode, root.heroSecondaryMode,
                root.mazeSize
            );
            const phases = [];
            let prev = null;
            for (let si = 0; si < plan.totalSteps; si++) {
                const st = TilesLayout.materializePlanStep(plan, si, prev);
                for (const p of st.phases) phases.push(p);
                prev = st.tiles;
            }
            root.startGraph({
                graphId: packet.graphId,
                winnerIndex: plan.winnerIndex,
                totalSteps: plan.totalSteps,
                totalPhases: plan.totalPhases,
                phases: phases,
                ensurePhases: null,
                _chunkDone: true,
            });
        }
    }

    // Assign the current phase's geometry/video to each tile. When `progress`
    // is given (0..1), interpolate so tiles visibly slide/scale between states.
    // Each phase has a `tiles[]` list (varying length as tiles merge) and, for
    // converge/merge phases, a `prevTiles[]` holding the prior stage's tiles.
    function applyPhase(phaseIdx, progress) {
        if (!root.graph) {
            return;
        }
        // Lazily materialize the chunk containing this phase so long Maze Walk
        // chains never block the UI thread (or balloon memory) building every
        // phase up front.
        if (root.graph.ensurePhases) {
            root.graph.ensurePhases(phaseIdx);
        }
        const phase = root.graph.phases[phaseIdx];
        if (!phase) {
            return;
        }
        const tiles = tileHost.tiles;
        const p = progress === undefined ? 1.0 : progress;

        // Map srcVideo -> previous rect for stable interpolation across the
        // tile-count reduction (tiles that "merge into" another use the target's
        // geometry).
        const prevByVideo = {};
        const prevTiles = phase.prevTiles || phase.tiles;
        for (const pt of prevTiles) {
            prevByVideo[pt.srcVideo] = pt;
        }

        const phaseCount = phase.tiles.length;
        for (let i = 0; i < tiles.length; i++) {
            const t = tiles[i];
            if (i >= phaseCount) {
                t.visible = false;
                continue;
            }
            const rect = phase.tiles[i];
            t.visible = true;
            const srcIdx = rect.srcVideo !== undefined ? rect.srcVideo : i;
            t.videoSource = root.activeVideos[srcIdx] || root.activeVideos[0];

            const prev = prevByVideo[srcIdx] || rect;
            const from = phase.prevTiles && prev ? prev.to : rect.from;
            const r = TilesLayout.interpolateRect(from, rect.to, p);

            t.tileX = r.x;
            t.tileY = r.y;
            t.tileW = r.w;
            t.tileH = r.h;
            t.muted = root.muted || i !== root.graph.winnerIndex;
        }
    }

    // Advance to the next phase (a transform step). Shared by the timer-driven
    // tick and the segment-end monitor, so a finished segment moves the tiles.
    function advanceTransform() {
        if (!root.graph) {
            return;
        }
        const totalPhases = root.graph.totalPhases || root.graph.phases.length;
        root.phaseIndex = (root.phaseIndex + 1) % totalPhases;
        root.phaseElapsed = 0;
        root.lastAdvanceTime = Date.now();
        if (root.phaseIndex === 0) {
            // Cycle wrapped. Adopt the precomputed next graph if available so
            // the wrap never blocks on a graph rebuild; otherwise rebuild now.
            if (root.nextGraph) {
                const g = root.nextGraph;
                root.nextGraph = null;
                root.startGraph(g);
            } else {
                root.rebuildGraph();
            }
        } else {
            root.applyPhase(root.phaseIndex, 0);
            root.applySegments();
            // Look-ahead: once we've passed ~70% of the cycle, precompute the
            // next graph off-thread so it's ready before the next wrap.
            if (!root.nextGraph && !root.building && root.phaseIndex / totalPhases > 0.7) {
                root.requestNextGraph();
            }
        }
    }

    function tick() {
        if (!root.graph) {
            return;
        }
        root.phaseElapsed += advanceTimer.interval;
        const phase = root.graph.phases[root.phaseIndex];
        if (!phase) {
            return;
        }

        if (phase.durationMs > 0 && root.phaseElapsed >= phase.durationMs) {
            root.advanceTransform();
            return;
        }

        // Animate the current phase: progress through its duration.
        const p = phase.durationMs > 0 ? Math.min(1, root.phaseElapsed / phase.durationMs) : 1;
        root.applyPhase(root.phaseIndex, p);
    }

    // Assign a time-based hold duration to the current phase. Tiles no longer
    // re-seek at phase boundaries: each tile just loops its own video
    // continuously (MediaPlayer.Infinite), and the choreography advances purely
    // on a timer. Zero-duration phases (grid/hold) get a random duration in
    // [segmentMinMs, segmentMaxMs] so the arrangement "holds" for that long,
    // while converge phases keep their own mergeDuration animation.
    function applySegments() {
        if (!root.graph) {
            return;
        }
        const phase = root.graph.phases[root.phaseIndex];
        if (!phase) {
            return;
        }
        // Only assign a fresh hold duration to phases that don't already have
        // a fixed one (grid/hold). Converge phases keep their mergeDuration.
        if (phase.durationMs <= 0) {
            phase.durationMs = root.segmentMinMs + Math.random() * (root.segmentMaxMs - root.segmentMinMs);
        }
    }

    // Manually trigger the next transform: skip ahead to the next
    // converge/merge stage (rather than jumping straight to full screen).
    function nextTransform() {
        if (!root.graph) {
            return;
        }
        const srcIdx = root.phaseIndex;
        // Find the next converge/merge/grid boundary after the current phase.
        const totalPhases = root.graph.totalPhases || root.graph.phases.length;
        let target = -1;
        for (let k = 1; k <= totalPhases; k++) {
            const idx = (srcIdx + k) % totalPhases;
            if (root.graph.ensurePhases) {
                root.graph.ensurePhases(idx);
            }
            const phase = root.graph.phases[idx];
            if (!phase) {
                continue;
            }
            const name = phase.name;
            if (name === "converge" || name === "merge" || name === "grid") {
                target = idx;
                break;
            }
        }
        if (target < 0) {
            target = srcIdx;
        }
        if (target === 0) {
            root.rebuildGraph();
            return;
        }
        root.phaseIndex = target;
        root.phaseElapsed = 0;
        root.applyPhase(target, 0);
        root.applySegments();
    }

    // Reset the choreography: rebuild with a fresh seed, re-expanding to the
    // maximum tile count (used by the right-click context menu).
    function resetChoreography() {
        root.rebuildGraph();
    }

    // When playback toggles (e.g. screen becomes covered/uncovered), re-check
    // and resync. On resume, re-schedule the current phase's segments so tiles
    // don't rely on stale end markers from before the pause.
    onShouldPlayChanged: {
        if (root.shouldPlay && root.graph) {
            root.lastAdvanceTime = Date.now();
            root.applySegments();
        }
    }

    // Rebuild when config changes materially.
    onVideosConfigChanged: root.rebuildGraph()
    onMaxTilesChanged: {
        // Keep the tile pool in sync with the new max so each monitor renders its
        // own full set of `maxTiles` (not a stale pool sized to an older value).
        tileHost.syncTilePool()
        root.rebuildGraph()
    }
    onMergeDurationChanged: root.rebuildGraph()
    onRandomizeChanged: root.rebuildGraph()
    onLayoutStyleChanged: root.rebuildGraph()
    onTransformCountBeforeFullChanged: root.rebuildGraph()
    onChoreographyModeChanged: root.rebuildGraph()
    onHeroSecondaryModeChanged: root.rebuildGraph()
    onMazeSizeChanged: root.rebuildGraph()
    onWidthChanged: root.rebuildGraph()
    onHeightChanged: root.rebuildGraph()

    // Mirror the debug toggle into the layout module's timing instrumentation so
    // slow layout functions (packLayout, buildGraphPlan) warn when they exceed
    // their UI-stall threshold.
    onDebugEnabledChanged: TilesLayout.setProfilingEnabled(root.debugEnabled)

    Component.onDestruction: {
        for (const t of tileHost.tiles) {
            if (t) {
                t.destroy();
            }
        }
    }
}




