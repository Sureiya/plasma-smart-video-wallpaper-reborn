pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import QtMultimedia
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
    property string metadataCacheJson: "{}"  // VideoMetadataCache config string
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
    // MediaPlayer instances (heavy). Instantiate exactly maxTiles tiles up front.
    Item {
        id: tileHost
        anchors.fill: parent

        property var tiles: []

        Component.onCompleted: {
            for (let i = 0; i < root.maxSimultaneousTiles; i++) {
                const t = tileComponent.createObject(tileHost, { z: 1 });
                tileHost.tiles.push(t);
            }
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

    // Maximum tiles to instantiate = the cascade's starting count, which is
    // bounded by maxTiles (the user's decode cap).
    readonly property int maxSimultaneousTiles: Math.max(1, root.maxTiles)

    Timer {
        id: advanceTimer
        interval: 16
        repeat: true
        running: root.graph !== null
        onTriggered: root.tick();
    }

    // Monitor segment ends: when a tile's segment finishes, advance the
    // transform (converge) instead of looping the segment. Segments play once;
    // the transform is what moves the tiles.
    Timer {
        id: segmentTimer
        interval: 250
        repeat: true
        running: root.graph !== null
        onTriggered: {
            if (!root.graph) return;
            const tiles = tileHost.tiles;
            for (let i = 0; i < tiles.length; i++) {
                const t = tiles[i];
                if (!t.visible || t.duration <= 0) continue;
                if (t._segmentEndMs && t.position >= t._segmentEndMs) {
                    // Segment done: advance the transform. Let the other tiles
                    // finish via the same path on their next trigger.
                    root.advanceTransform();
                    return;
                }
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
    // by maxTiles — the user's limit on simultaneous decoders. The reduction
    // cascade then starts from this many tiles and converges to one.
    function pickCycleVideos() {
        let list = root.videosConfig.slice();
        if (root.randomize) {
            Utils.shuffleArray(list);
        }
        return list.slice(0, Math.max(1, root.maxTiles));
    }

    function rebuildGraph() {
        if (!root.videosConfig || root.videosConfig.length === 0) {
            root.graph = null;
            return;
        }
        if (root.width <= 0 || root.height <= 0) {
            root.graph = null;
            return;
        }
        const chosen = root.pickCycleVideos();
        root.activeVideos = chosen;

        // Kick off async border detection for any videos not yet cached.
        for (const v of chosen) {
            root.detectBorders(v.filename);
        }

        const aspects = root.buildVideoAspects(chosen);

        root.cycleSeed = (root.cycleSeed + 1) >>> 0;
        const seed = root.cycleSeed;

        // Resolve the effective layout style. "Random" picks a different
        // concrete style at the start of each cycle (i.e. after a convergence
        // completes and the graph rebuilds).
        let effectiveStyle = root.layoutStyle;
        if (effectiveStyle === Enum.TilesLayoutStyle.Random) {
            effectiveStyle = Math.floor(Math.random() * 7); // 0..6 (concrete styles)
        }

        root.graph = TilesLayout.buildGraph(
            seed,
            root.width,
            root.height,
            aspects,
            root.mergeDuration,
            effectiveStyle,
            root.transformCountBeforeFull,
            root.choreographyMode
        );
        root.phaseIndex = 0;
        root.phaseElapsed = 0;
        root.applyPhase(0);
        root.applySegments();
    }

    // Assign the current phase's geometry/video to each tile. When `progress`
    // is given (0..1), interpolate so tiles visibly slide/scale between states.
    // Each phase has a `tiles[]` list (varying length as tiles merge) and, for
    // converge/merge phases, a `prevTiles[]` holding the prior stage's tiles.
    function applyPhase(phaseIdx, progress) {
        if (!root.graph) {
            return;
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
        root.phaseIndex = (root.phaseIndex + 1) % root.graph.phases.length;
        root.phaseElapsed = 0;
        if (root.phaseIndex === 0) {
            root.rebuildGraph();
        } else {
            root.applyPhase(root.phaseIndex, 0);
            root.applySegments();
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

    // Give each visible tile a fresh random segment (random start, uniform
    // length). The length is shared across all tiles so they end "together"
    // and the segment-end monitor fires a single transform when they finish.
    function applySegments() {
        if (!root.graph) {
            return;
        }
        const phase = root.graph.phases[root.phaseIndex];
        if (!phase) {
            return;
        }
        // One shared segment length for this phase so all tiles end together.
        const sharedLen = root.segmentMinMs + Math.random() * (root.segmentMaxMs - root.segmentMinMs);
        const tiles = tileHost.tiles;
        for (let i = 0; i < tiles.length; i++) {
            const t = tiles[i];
            if (!t.visible) {
                continue;
            }
            const dur = t.duration > 0 ? t.duration : root.segmentMaxMs;
            const maxStart = Math.max(0, dur - sharedLen);
            t.seek(Math.random() * maxStart);
            t._segmentEndMs = t.position + sharedLen;
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
        let target = -1;
        for (let k = 1; k <= root.graph.phases.length; k++) {
            const idx = (srcIdx + k) % root.graph.phases.length;
            const name = root.graph.phases[idx].name;
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

    // Rebuild when config changes materially.
    onVideosConfigChanged: root.rebuildGraph()
    onMaxTilesChanged: root.rebuildGraph()
    onMergeDurationChanged: root.rebuildGraph()
    onRandomizeChanged: root.rebuildGraph()
    onLayoutStyleChanged: root.rebuildGraph()
    onTransformCountBeforeFullChanged: root.rebuildGraph()
    onChoreographyModeChanged: root.rebuildGraph()
    onWidthChanged: root.rebuildGraph()
    onHeightChanged: root.rebuildGraph()

    Component.onDestruction: {
        for (const t of tileHost.tiles) {
            if (t) {
                t.destroy();
            }
        }
    }
}




