pragma ComponentBehavior: Bound
import QtQuick
import QtMultimedia
import "code/utils.js" as Utils

/*
 * A single animated video tile for Tiles mode. Wraps a VideoPlayer and drives
 * its geometry (x/y/width/height) from the precomputed transformation graph.
 * The video is cropped to the tile so that, when the tile converges to
 * full-screen during the merge, the frame is seamless.
 */
Item {
    id: root

    // -- Inputs (set by TilesPlayer) --
    property var videoSource            // Utils video object { filename, ... }
    property real globalVolume: 1.0
    property bool muted: true
    property int fillMode: VideoOutput.PreserveAspectCrop
    property bool fillBlur: false
    property int fillBlurRadius: 0
    property string audioOutputDevice
    property real globalPlaybackRate: 1.0
    property bool shouldPlay: true
    property bool debugEnabled: false
    property int loadAheadTime: 0

    // Geometry (driven by the transformation graph). These are set directly
    // by TilesPlayer each frame rather than being animated internally, so the
    // whole graph stays deterministic and coordinated.
    property real tileX: 0
    property real tileY: 0
    property real tileW: 0
    property real tileH: 0

    // -- Outputs (read by TilesPlayer) --
    readonly property alias duration: player.duration
    readonly property alias position: player.position
    readonly property real videoAspect: player.videoAspect

    // Planned end-of-segment (ms) set by TilesPlayer's segment scheduler.
    property int _segmentEndMs: 0

    x: tileX
    y: tileY
    width: tileW
    height: tileH
    clip: true

    VideoPlayer {
        id: player
        anchors.fill: parent
        playerSource: root.videoSource
        globalVolume: root.globalVolume
        muted: root.muted
        fillMode: root.fillMode
        fillBlur: root.fillBlur
        fillBlurRadius: root.fillBlurRadius
        audioOutputDevice: root.audioOutputDevice
        globalPlaybackRate: root.globalPlaybackRate
        useAlternativePlaybackRate: false
        crossfadeEnabled: false
        changeWallpaperMode: false
        randomStartTime: false
        loops: MediaPlayer.Infinite
        shouldPlay: root.shouldPlay
        debugEnabled: root.debugEnabled
        loadAheadTime: root.loadAheadTime
    }

    function seek(ms) {
        if (player.seekable) {
            player.position = ms;
        }
    }

    function play() {
        player.play();
    }

    function pause() {
        player.pause();
    }
}
