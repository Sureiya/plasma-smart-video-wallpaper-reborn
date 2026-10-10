pragma ComponentBehavior: Bound
import QtQuick
import QtMultimedia
import com.github.luisbocanegra.svwr 1.0

/*
 * A single animated video tile for Tiles mode. Decodes via the native
 * CappedVideoPlayer (GStreamer, capped to maxDecodeWidth/Height) and displays
 * through a VideoOutput bound to its videoSink. Geometry (x/y/width/height) is
 * driven from the precomputed transformation graph. The video is cropped to the
 * tile (PreserveAspectCrop) so frames are seamless during the merge.
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

    // Decode cap (set by TilesPlayer from monitor resolution: 1080p on 4K, 720p
    // on 1080p). CappedVideoPlayer decodes/scale to at most this size.
    property int maxDecodeWidth: 1280
    property int maxDecodeHeight: 720

    // Geometry (driven by the transformation graph). These are set directly
    // by TilesPlayer each frame rather than being animated internally, so the
    // whole graph stays deterministic and coordinated.
    property real tileX: 0
    property real tileY: 0
    property real tileW: 0
    property real tileH: 0

    x: tileX
    y: tileY
    width: tileW
    height: tileH
    clip: true

    // Native capped decoder (GStreamer playbin -> videoconvert -> videoscale ->
    // capsfilter -> appsink), feeding frames to QVideoSink at <= the cap.
    // VideoOutput's `videoSink` is read-only (it owns the sink); we assign that
    // sink to the player (whose `videoSink` is writable), so the player renders
    // into the VideoOutput.
    CappedVideoPlayer {
        id: player
        source: root.videoSource ? root.videoSource.filename : ""
        maxWidth: root.maxDecodeWidth
        maxHeight: root.maxDecodeHeight
        loops: true
        videoSink: videoOutput.videoSink
    }

    VideoOutput {
        id: videoOutput
        anchors.fill: parent
        fillMode: root.fillMode
    }

    onShouldPlayChanged: {
        if (root.shouldPlay) {
            player.play();
        } else {
            // Full stop frees the decoded frame + GPU texture (tiles loop, so
            // losing position on resume is fine).
            player.stop();
        }
    }

    onVideoSourceChanged: {
        if (root.shouldPlay) {
            player.play();
        }
    }

    Component.onCompleted: {
        if (root.shouldPlay) {
            player.play();
        }
    }

    function seek(ms) {
        player.seek(ms);
    }

    function play() {
        player.play();
    }

    function pause() {
        player.pause();
    }
}
