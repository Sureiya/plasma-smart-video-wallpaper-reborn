/*
 *  Copyright 2018 Rog131 <samrog131@hotmail.com>
 *  Copyright 2019 adhe   <adhemarks2@gmail.com>
 *  Copyright 2024 Luis Bocanegra <luisbocanegra17b@gmail.com>
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with this program; if not, write to the Free Software
 *  Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  2.010-1301, USA.
 */

import QtQuick
import QtQuick.Layouts
import QtMultimedia
import Qt5Compat.GraphicalEffects
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.extras as PlasmaExtras
import org.kde.kirigami as Kirigami
import org.kde.ksvg as KSvg
import org.kde.plasma.plasma5support as P5Support
import org.kde.plasma.plasmoid
import "code/utils.js" as Utils
import "code/enum.js" as Enum

WallpaperItem {
    id: main
    anchors.fill: parent
    property bool isLoading: true
    property string videoUrls: main.configuration.VideoUrls
    property string folders: main.configuration.Folders
    property string folderCache: main.configuration.FolderCache
    property list<var> videosConfig: []
    property var randomOrder: []            // shuffled index permutation for random mode
    property string lastRandomSignature: ""  // fingerprint of the current file set
    property var cachedFolderVideos: []      // parsed FolderCache, refreshed only on change
    property string cachedFolderSig: ""      // signature of the FolderCache string we last parsed
    property int longestLoadingTime: 0
    property string longestLoadingVideo
    readonly property int currentLoadingTime: player.player?.loadingTime ?? 0
    onCurrentLoadingTimeChanged: {
        if (currentLoadingTime > longestLoadingTime) {
            longestLoadingTime = currentLoadingTime;
            longestLoadingVideo = currentSource.filename;
        }
    }
    property int videosCount: videosConfig.length || 0
    property bool hasVideos: videosCount > 0
    property bool videoUpdatePending: false
    property int currentVideoIndex: 0
    property string lastSelectedVideo: ""
    property bool resumeLastVideo: main.configuration.ResumeLastVideo
    property alias dayNightPhase: dayNightCycleController.currentPhase
    property bool dayNightPhaseHasChanged: false
    property var currentSource: {
        if (dayNightPhaseHasChanged) {
            let video = Utils.createVideo();
            if (isLoading) {
                return video;
            }
            if (resumeLastVideo) {
                video = Utils.getLastVideo(dayNightCycleEnabled, dayNightPhase, main.configuration, videosConfig);
            }
            if (!video.filename) {
                video = Utils.getVideoByFile(lastSelectedVideo, videosConfig);
            }
            // fall back to the first video of the new list
            return video.filename ? video : Utils.getVideoByIndex(0, videosConfig);
        }
        return Utils.getVideoByIndex(currentVideoIndex, videosConfig);
    }
    property int pauseBatteryLevel: main.configuration.PauseBatteryLevel
    property int pauseCoveragePercent: main.configuration.PauseCoveragePercent
    property bool shouldPlay: {
        if (lockScreenMode) {
            return true;
        }

        if (playbackOverride === Enum.PlaybackOverride.Play) {
            return true;
        } else if (playbackOverride === Enum.PlaybackOverride.Pause) {
            return false;
        }

        let pause = false;
        switch (main.configuration.PauseMode) {
        case Enum.PauseMode.MaximizedOrFullScreen:
            pause = windowModel.maximizedExists || windowModel.fullscreenExists;
            break;
        case Enum.PauseMode.ActiveWindowPresent:
            pause = windowModel.activeExists;
            break;
        case Enum.PauseMode.WindowVisible:
            pause = windowModel.visibleExists;
            break;
        case Enum.PauseMode.Never:
            pause = false;
            break;
        case Enum.PauseMode.ScreenCovered:
            pause = windowModel.coveragePercent >= main.pauseCoveragePercent;
            break;
        }
        return !pause;
    }
    property bool playing: {
        return ((shouldPlay && !batteryPausesVideo && !screenLocked && !screenIsOff && !effectPauseVideo && isCurrentActivity) || effectPlayVideo) && hasVideos;
    }
    property bool shouldBlur: {
        if (!hasVideos) {
            return false;
        }
        let blur = false;
        switch (main.configuration.BlurMode) {
        case Enum.BlurMode.MaximizedOrFullScreen:
            blur = windowModel.maximizedExists;
            break;
        case Enum.BlurMode.ActiveWindowPresent:
            blur = windowModel.activeExists;
            break;
        case Enum.BlurMode.WindowVisible:
            blur = windowModel.visibleExists;
            break;
        case Enum.BlurMode.VideoPaused:
            blur = !main.playing;
            break;
        case Enum.BlurMode.Always:
            blur = true;
            break;
        case Enum.BlurMode.Never:
            blur = false;
        }
        return blur;
    }
    property bool showBlur: (shouldBlur && !batteryDisablesBlur && !effectHideBlur) || effectShowBlur
    property bool screenLocked: screenModel.screenIsLocked
    property bool batteryPausesVideo: pauseBattery && main.configuration.BatteryPausesVideo
    property bool batteryDisablesBlur: pauseBattery && main.configuration.BatteryDisablesBlur

    property bool screenIsOff: screenModel.screenIsOff
    property bool isCurrentActivity: {
        // lock and login screens have no activity
        if (Plasmoid.activity === undefined) {
            return true;
        }
        return Plasmoid.activity === windowModel.currentActivity;
    }
    property bool screenOffPausesVideo: main.configuration.ScreenOffPausesVideo
    property bool lockScreenMode: false
    property bool debugEnabled: main.configuration.DebugEnabled

    property var activeEffects: effectsModel.activeEffects
    property var effectsHideBlur: main.configuration.EffectsHideBlur.split(",").filter(Boolean)
    property var effectsShowBlur: main.configuration.EffectsShowBlur.split(",").filter(Boolean)
    property var effectsAlternativeSpeed: main.configuration.EffectsAlternativeSpeed.split(",").filter(Boolean)
    property bool effectHideBlur: effectsHideBlur.some(item => activeEffects.includes(item))
    property bool effectShowBlur: effectsShowBlur.some(item => activeEffects.includes(item))
    property bool effectAlternativeSpeed: effectsAlternativeSpeed.some(item => activeEffects.includes(item))

    property var effectsPauseVideo: main.configuration.EffectsPauseVideo.split(",").filter(Boolean)
    property var effectsPlayVideo: main.configuration.EffectsPlayVideo.split(",").filter(Boolean)
    property bool effectPauseVideo: effectsPauseVideo.some(item => activeEffects.includes(item))
    property bool effectPlayVideo: effectsPlayVideo.some(item => activeEffects.includes(item))

    property int blurAnimationDuration: main.configuration.BlurAnimationDuration
    property bool crossfadeEnabled: main.configuration.CrossfadeEnabled
    property bool tick: true
    property real playbackRate: main.configuration.PlaybackRate
    property real volume: main.configuration.Volume
    property real volumeOutput2: 0
    property bool randomMode: main.configuration.RandomMode
    property int lastVideoPosition: main.configuration.LastVideoPosition
    property int changeWallpaperMode: main.configuration.ChangeWallpaperMode
    property bool advanceOnVideoEnd: main.configuration.AdvanceOnVideoEnd
    property int changeWallpaperTimerSeconds: main.configuration.ChangeWallpaperTimerSeconds
    property int changeWallpaperTimerMinutes: main.configuration.ChangeWallpaperTimerMinutes
    property int changeWallpaperTimerHours: main.configuration.ChangeWallpaperTimerHours
    property int randomIntervalMinSeconds: main.configuration.RandomIntervalMinSeconds
    property int randomIntervalMinMinutes: main.configuration.RandomIntervalMinMinutes
    property int randomIntervalMinHours: main.configuration.RandomIntervalMinHours
    property int randomIntervalMaxSeconds: main.configuration.RandomIntervalMaxSeconds
    property int randomIntervalMaxMinutes: main.configuration.RandomIntervalMaxMinutes
    property int randomIntervalMaxHours: main.configuration.RandomIntervalMaxHours
    property bool randomStartTime: main.configuration.RandomStartTime
    property int tilesMaxTiles: main.configuration.TilesMaxTiles
    property int tilesMergeDuration: main.configuration.TilesMergeDuration
    property bool tilesRandomize: main.configuration.TilesRandomize
    property int tilesAspectTolerance: main.configuration.TilesAspectTolerance
    property int tilesLayoutStyle: main.configuration.TilesLayoutStyle
    property int tilesTransformsBeforeFull: main.configuration.TilesTransformsBeforeFull
    property int tilesChoreographyMode: main.configuration.TilesChoreographyMode
    property int tilesSegmentMinMs: main.configuration.TilesSegmentMinS * 1000
    property int tilesSegmentMaxMs: main.configuration.TilesSegmentMaxS * 1000
    readonly property bool tilesMode: main.changeWallpaperMode === Enum.ChangeWallpaperMode.Tiles
    property bool dayNightCycleEnabled: main.configuration.DayNightCycleMode !== Enum.DayNightCycleMode.Disabled
    property bool muteAudio: {
        if (muteOverride === Enum.MuteOverride.Mute) {
            return true;
        } else if (muteOverride === Enum.MuteOverride.Unmute) {
            return false;
        }

        let mute = false;
        switch (main.configuration.MuteMode) {
        case Enum.MuteMode.MaximizedOrFullScreen:
            mute = windowModel.maximizedExists;
            break;
        case Enum.MuteMode.ActiveWindowPresent:
            mute = windowModel.activeExists;
            break;
        case Enum.MuteMode.WindowVisible:
            mute = windowModel.visibleExists;
            break;
        //  TODO other application playing audio
        // case Enum.MuteMode.AnotherAppPlayingAudio:
        //  break
        case Enum.MuteMode.Never:
            mute = false;
            break;
        case Enum.MuteMode.Always:
            mute = true;
        }
        return mute;
    }
    property bool useAlternativePlaybackRate: {
        if (lockScreenMode) {
            return false;
        }

        if (effectAlternativeSpeed) {
            return true;
        }

        let r = false;
        switch (main.configuration.AlternativePlaybackRateMode) {
        case Enum.PauseMode.MaximizedOrFullScreen:
            r = windowModel.maximizedExists;
            break;
        case Enum.PauseMode.ActiveWindowPresent:
            r = windowModel.activeExists;
            break;
        case Enum.PauseMode.WindowVisible:
            r = windowModel.visibleExists;
            break;
        case Enum.PauseMode.Never:
            r = false;
        }
        return r;
    }

    property QtObject pmSource: P5Support.DataSource {
        id: pmSource
        engine: "powermanagement"
        connectedSources: sources
        onSourceAdded: source => {
            disconnectSource(source);
            connectSource(source);
        }
        onSourceRemoved: source => {
            disconnectSource(source);
        }
    }

    property bool pauseBattery: {
        let result = false;
        if (pmSource.data.Battery["Has Cumulative"] && pmSource.data["Battery"]["State"] === "Discharging") {
            result = pauseBatteryLevel > pmSource.data.Battery.Percent;
        }
        return result;
    }

    TasksModel {
        id: windowModel
        screenGeometry: main.parent?.screenGeometry ?? null
        filterByScreen: main.configuration.CheckWindowsActiveScreen
    }

    ScreenModel {
        id: screenModel
        checkScreenLock: !main.lockScreenMode
        checkScreenState: main.screenOffPausesVideo && screenStateCmd !== ""
        screenStateCmd: main.configuration.ScreenStateCmd
        instanceId: Plasmoid.id ?? ""
    }

    EffectsModel {
        id: effectsModel
        monitorActive: {
            return [main.effectsPlayVideo, main.effectsPauseVideo, main.effectsShowBlur, main.effectsHideBlur].some(arr => arr.length > 0);
        }
    }

    DayNightCycleController {
        id: dayNightCycleController
        mode: main.configuration.DayNightCycleMode
        sunriseTime: main.configuration.DayNightCycleSunriseTime
        sunsetTime: main.configuration.DayNightCycleSunsetTime
        transitionDuration: main.configuration.DayNightCycleTransitionDuration
        onCurrentPhaseChanged: {
            main.dayNightPhaseHasChanged = true;
        }
        darkLightScheduleState: main.configuration.DarkLightScheduleState
        onDarkLightScheduleStateChanged: {
            if (main.configuration.DarkLightScheduleState != dayNightCycleController.darkLightScheduleState) {
                main.configuration.DarkLightScheduleState = dayNightCycleController.darkLightScheduleState;
                main.configuration.writeConfig();
            }
        }
    }

    function setNextSource() {
        printLog("- Prev " + currentVideoIndex + ": " + currentSource.filename);
        currentVideoIndex = (currentVideoIndex + 1) % videosConfig.length;
        printLog("- Next " + currentVideoIndex + ": " + currentSource.filename);
    }

    function skipNext() {
        player.player.ending = true;
        setNextSource();
    }

    function nextVideo(forceSwitch) {
        const loopThisVideo = currentSource.loop || main.videosConfig.length === 1;
        const advance = main.advanceOnVideoEnd || main.changeWallpaperMode === Enum.ChangeWallpaperMode.Slideshow;
        if (!loopThisVideo && advance) {
            setNextSource();
        } else {
            player.player.ending = true;
            player.loadVideo();
        }
    }
    // qmlformat off
    property int changeWallpaperTimerMs: {
        return ((main.changeWallpaperTimerHours * 60 * 60)
        + (main.changeWallpaperTimerMinutes * 60)
        + main.changeWallpaperTimerSeconds) * 1000
    }
    // qmlformat on

    property int randomIntervalMinMs: {
        return ((main.randomIntervalMinHours * 60 * 60)
        + (main.randomIntervalMinMinutes * 60)
        + main.randomIntervalMinSeconds) * 1000
    }

    property int randomIntervalMaxMs: {
        return ((main.randomIntervalMaxHours * 60 * 60)
        + (main.randomIntervalMaxMinutes * 60)
        + main.randomIntervalMaxSeconds) * 1000
    }

    property int randomIntervalSeed: 0

    function randomIntervalMs() {
        const min = Math.min(main.randomIntervalMinMs, main.randomIntervalMaxMs);
        const max = Math.max(main.randomIntervalMinMs, main.randomIntervalMaxMs);
        return min + Math.floor(Math.random() * (max - min + 1));
    }

    PausableTimer {
        id: changeTimer
        running: !main.tilesMode
            && (main.changeWallpaperMode === Enum.ChangeWallpaperMode.OnATimer
            || main.changeWallpaperMode === Enum.ChangeWallpaperMode.RandomInterval)
            && player.player.playing && !main.currentSource.loop
        interval: main.changeWallpaperMode === Enum.ChangeWallpaperMode.RandomInterval
            ? (main.randomIntervalSeed, main.randomIntervalMs())
            : main.changeWallpaperTimerMs
        repeat: true
        useNewIntervalImmediately: true
        onTriggered: {
            printLog("Timer triggered, changing wallpaper");
            if (main.changeWallpaperMode === Enum.ChangeWallpaperMode.RandomInterval) {
                main.randomIntervalSeed++;
            }
            main.skipNext();
        }
        onIntervalChanged: {
            printLog("Timer changed:", interval);
        }
    }

    Rectangle {
        id: background
        anchors.fill: parent
        color: !main.hasVideos ? Kirigami.Theme.backgroundColor : main.configuration.BackgroundColor

        FadePlayer {
            id: player
            anchors.fill: parent
            muted: main.muteAudio
            lastVideoPosition: main.configuration.LastVideoPosition
            visible: main.videosConfig.length !== 0 && !main.tilesMode
            onSetNextSource: {
                printLog("main.player.onSetNextSource");
                main.nextVideo();
            }
            crossfadeEnabled: main.crossfadeEnabled && !main.tilesMode
            multipleVideos: main.videosConfig.length > 1
            targetCrossfadeDuration: main.configuration.CrossfadeDuration
            debugEnabled: main.debugEnabled
            changeWallpaperMode: main.changeWallpaperMode
            advanceOnVideoEnd: main.advanceOnVideoEnd
            randomStartTime: main.randomStartTime
            fillMode: main.configuration.FillMode
            fillBlur: main.configuration.FillBlur && !main.batteryDisablesBlur
            fillBlurRadius: main.configuration.FillBlurRadius
            globalVolume: main.volume
            globalPlaybackRate: main.playbackRate
            useAlternativePlaybackRate: main.useAlternativePlaybackRate
            alternativePlaybackRateGlobal: main.configuration.AlternativePlaybackRate
            resumeLastVideo: main.configuration.ResumeLastVideo
            audioOutputDevice: main.configuration.AudioOutputDevice
            // Fully stop the full-screen player in tiles mode so its own
            // MediaPlayer/decoder doesn't keep running in parallel with the tiles.
            shouldPlay: main.playing && !main.tilesMode
            audioFadeInOutDuration: main.configuration.AudioFadeInOutDuration * 1000
            loadAheadTime: main.configuration.LoadAheadTime
        }

        Loader {
            id: tilesPlayerLoader
            anchors.fill: parent
            active: main.tilesMode
            sourceComponent: tilesPlayerComponent
        }
    }

    Component {
        id: tilesPlayerComponent
        TilesPlayer {
            anchors.fill: parent
            videosConfig: main.videosConfig
            maxTiles: main.tilesMaxTiles
            mergeDuration: main.tilesMergeDuration
            randomize: main.tilesRandomize
            aspectTolerance: main.tilesAspectTolerance / 100.0
            layoutStyle: main.tilesLayoutStyle
            transformCountBeforeFull: main.tilesTransformsBeforeFull
            choreographyMode: main.tilesChoreographyMode
            metadataCacheJson: main.configuration.VideoMetadataCache
            segmentMinMs: main.tilesSegmentMinMs
            segmentMaxMs: main.tilesSegmentMaxMs
            backgroundColor: main.configuration.BackgroundColor
            muted: main.muteAudio
            fillMode: main.configuration.FillMode
            fillBlur: main.configuration.FillBlur && !main.batteryDisablesBlur
            fillBlurRadius: main.configuration.FillBlurRadius
            globalVolume: main.volume
            globalPlaybackRate: main.playbackRate
            audioOutputDevice: main.configuration.AudioOutputDevice
            shouldPlay: main.playing
            debugEnabled: main.debugEnabled
        }
    }
    FastBlur {
        id: mainBlur
        source: background
        radius: main.showBlur ? main.configuration.BlurRadius : 0
        visible: radius !== 0
        anchors.fill: background
        Behavior on radius {
            NumberAnimation {
                duration: main.blurAnimationDuration
            }
        }
    }

    PlasmaExtras.PlaceholderMessage {
        visible: !main.hasVideos
        anchors.centerIn: parent
        width: parent.width - Kirigami.Units.gridUnit * 2
        iconName: "video-symbolic"
        text: i18nd("plasma_wallpaper_luisbocanegra.smart.video.wallpaper.reborn", "No video source \n" + main.videoUrls)
    }

    Component {
        id: debugOverlay
        Item {
            implicitWidth: debugArea.implicitWidth + debugArea.anchors.leftMargin + debugArea.anchors.rightMargin
            implicitHeight: debugArea.implicitHeight + debugArea.anchors.topMargin + debugArea.anchors.bottomMargin
            x: 40
            y: 100
            KSvg.FrameSvgItem {
                id: frameSvg
                imagePath: "widgets/background"
                anchors.fill: parent
            }
            ColumnLayout {
                id: debugArea
                anchors {
                    fill: parent
                    leftMargin: frameSvg.fixedMargins.left
                    rightMargin: frameSvg.fixedMargins.right
                    topMargin: frameSvg.fixedMargins.top
                    bottomMargin: frameSvg.fixedMargins.bottom
                }
                PlasmaComponents.Label {
                    Layout.margins: Kirigami.Units.largeSpacing
                    text: {
                        let text = `player.filename: ${player.player.playerSource.filename}\n`;
                        text += `main.currentSource.filename: ${main.currentSource.filename}\n`;
                        text += `videos:\n${main.videosConfig.map(v => {
                            const filenameParts = v.filename.split("/");
                            return filenameParts[filenameParts.length - 1];
                        }).join("\n")}\n`;
                        text += `last: ${main.configuration.LastVideo}\n`;
                        text += `lastSunrise: ${main.configuration.LastVideoSunrise}\n`;
                        text += `lastDay: ${main.configuration.LastVideoDay}\n`;
                        text += `lastSunset: ${main.configuration.LastVideoSunset}\n`;
                        text += `lastNight: ${main.configuration.LastVideoNight}\n`;
                        text += `source.loop: ${main.currentSource.loop ?? false}\n`;
                        text += `player.loops: ${player.loops === MediaPlayer.Infinite}\n`;
                        text += `player.depth: ${player.depth}\n`;
                        text += `currentVideoIndex: ${main.currentVideoIndex}\n`;
                        text += `changeWallpaperMode: ${["Never", "Slideshow", `OnATimer time: ${changeTimer.interval}`, `RandomInterval: ${changeTimer.interval}`][main.changeWallpaperMode] ?? main.changeWallpaperMode}\n`;
                        text += `crossfade: ${player.player.crossfadeEnabled}\n`;
                        text += `crossfadeDuration: ${player.targetCrossfadeDuration} current: ${player.player.crossfadeDuration}\n`;
                        text += `loadAheadTime: ${player.player.loadAheadTime}\n`;
                        text += `multipleVideos: ${player.multipleVideos}\n`;
                        text += `mediaStatus: ${["NoMedia", "LoadingMedia", "LoadedMedia", "StalledMedia", "BufferingMedia", "BufferedMedia", "EndOfMedia", "InvalidMedia"][player.player.mediaStatus]}\n`;
                        text += `shouldPlay: ${main.shouldPlay}\n`;
                        text += `playing: ${player.player.playing}\n`;
                        text += `position: ${player.player.position}\n`;
                        text += `duration: ${player.player.duration}\n`;
                        text += `playbackRate: ${player.player.playbackRate.toFixed(2)}\n`;
                        text += `useAlternativePlaybackRate: ${player.useAlternativePlaybackRate}\n`;
                        text += `resumeLastVideo: ${player.resumeLastVideo}\n`;
                        text += `screenOffPausesVideo: ${main.screenOffPausesVideo} off ${main.screenIsOff}\n`;
                        text += `pauseBattery: below ${main.pauseBatteryLevel}% ${main.pauseBattery}\n`;
                        text += `inLockScreen: ${main.lockScreenMode}\n`;
                        text += `screenLocked: ${main.screenLocked}\n`;
                        text += `showBlur: ${main.showBlur}\n`;
                        text += `dayNightPhase: ${main.dayNightPhase} (${["night", "sunrise", "day", "sunset", "unknown"][main.dayNightPhase]})\n`;
                        text += `dayNightCycleMode: ${["disabled", "dayNightCycle", "time", "plasmaStyle", "alwaysDay", "alwaysNight"][main.configuration.DayNightCycleMode]}\n`;
                        text += `id: ${Plasmoid.id}\n`;
                        text += `volume: ${player.player.volume.toFixed(2)}\n`;
                        text += `audioFadeInOutDuration: ${player.player.audioFadeInOutDuration}\n`;
                        text += `currentAudioDevice: ${player.player.currentAudioDevice}\n`;
                        text += `loadingTime: current ${main.currentLoadingTime} longest ${main.longestLoadingTime}\n`;
                        text += `longestLoadingVideo: ${main.longestLoadingVideo}`;
                        return text;
                    }
                }
            }
        }
    }
    Loader {
        sourceComponent: debugOverlay
        active: main.debugEnabled
    }

    Timer {
        id: startTimer
        interval: 100
        onTriggered: {
            main.isLoading = false;
            if (main.debugEnabled)
                Utils.dumpProps(main.configuration);
        }
    }

    function printLog(msg) {
        if (debugEnabled) {
            console.log(main.pluginName, msg);
        }
    }

    function saveLastSource(filename, dayNightPhase) {
        if (filename === "") {
            return;
        }

        main.configuration.LastVideo = filename;
        if (dayNightCycleEnabled) {
            switch (dayNightPhase) {
            case Enum.DayNightPhase.Day:
                main.configuration.LastVideoDay = filename;
                break;
            case Enum.DayNightPhase.Night:
                main.configuration.LastVideoNight = filename;
                break;
            case Enum.DayNightPhase.Sunrise:
                main.configuration.LastVideoSunrise = filename;
                break;
            case Enum.DayNightPhase.Sunset:
                main.configuration.LastVideoSunset = filename;
                break;
            }
        }
    }

    function logPauseBattery() {
        printLog("Pause Battery: " + pauseBatteryLevel + "% " + pauseBattery);
    }

    function logPauseScreenOff() {
        printLog("Pause Screen Off: " + screenOffPausesVideo + " Off: " + screenIsOff);
    }

    function logShouldPlay() {
        printLog("Should Play: " + main.shouldPlay);
    }

    onPauseBatteryChanged: logPauseBattery()
    onPauseBatteryLevelChanged: logPauseBattery()
    onScreenOffPausesVideoChanged: logPauseScreenOff()
    onScreenIsOffChanged: logPauseScreenOff()
    onVideosConfigChanged: {
        if (isLoading) {
            return;
        }
        if (!dayNightPhaseHasChanged && Utils.getVideoByFile(currentSource.filename, videosConfig).filename === "") {
            printLog("main.videosConfig changed, currentSource no longer exists, skipping to next video");
            main.skipNext();
        }
        // Avoid eagerly JSON-stringifying the whole (possibly huge) list when
        // debug logging is off — this was a major freeze cause on Apply.
        if (debugEnabled) {
            printLog("Videos: '" + JSON.stringify(videosConfig) + "'");
        }
    }
    onShouldPlayChanged: logShouldPlay()
    onPlayingChanged: printLog("Video playing: " + playing)
    onShowBlurChanged: printLog("Blur: " + showBlur)
    onCurrentSourceChanged: {
        Qt.callLater(() => {
            const filename = main.currentSource.filename;
            if (!filename) {
                return;
            }
            // reset index for the current set of videos
            const index = Utils.getVideoIndex(filename, main.videosConfig);
            if (index !== -1) {
                main.currentVideoIndex = index;
            }
            main.lastSelectedVideo = filename;
            dayNightPhaseHasChanged = false;
            main.saveLastSource(filename, main.dayNightPhase);
        });
    }
    function updateVideosConfig() {
        // Merge explicit videos with the cached folder enumeration (folder
        // files are not in the UI list, so they come solely from FolderCache).
        let videos = Utils.getVideos(dayNightCycleEnabled, dayNightPhase, videoUrls);

        // Only re-parse the FolderCache when its string actually changed —
        // parsing thousands of paths on every config change froze Apply.
        const folderSig = main.folders + "\u0002" + main.folderCache;
        if (folderSig !== main.cachedFolderSig) {
            main.cachedFolderVideos = Utils.getFolderVideos(main.folders, main.folderCache);
            main.cachedFolderSig = folderSig;
        }
        if (main.cachedFolderVideos.length > 0) {
            videos = videos.concat(main.cachedFolderVideos);
        }

        if (randomMode) {
            // Reshuffle only when the underlying inputs changed (not on every
            // redundant updateVideosConfig call). Signature = the input strings,
            // which fully determine the output list.
            const sig = main.videoUrls + "\u0001" + main.folders + "\u0001" + main.folderCache;
            if (sig !== main.lastRandomSignature || !main.randomOrder.length) {
                main.randomOrder = Utils.shuffledIndices(videos.length);
                main.lastRandomSignature = sig;
            }
            const ordered = main.randomOrder.map(i => videos[i]);
            videosConfig = ordered;
        } else {
            videosConfig = videos;
        }
    }

    // Debounced rebuild: coalesces many rapid config changes (e.g. an Apply that
    // changes several keys at once) into a single updateVideosConfig() call,
    // avoiding redundant full rebuilds of a huge list on the UI thread.
    property bool videosRebuildQueued: false
    function requestVideosConfigRebuild() {
        if (main.videosRebuildQueued) {
            return;
        }
        main.videosRebuildQueued = true;
        Qt.callLater(() => {
            main.videosRebuildQueued = false;
            main.updateVideosConfig();
        });
    }

    onDayNightCycleEnabledChanged: {
        requestVideosConfigRebuild();
    }
    onDayNightPhaseChanged: {
        requestVideosConfigRebuild();
        printLog("DayNight phase changed: " + dayNightPhase);
    }
    onVideoUrlsChanged: {
        requestVideosConfigRebuild();
    }
    onRandomModeChanged: {
        requestVideosConfigRebuild();
        printLog("Random mode changed: " + main.randomMode);
    }

    // Rebuild the list when cached folders change (folder added/removed).
    onFoldersChanged: {
        requestVideosConfigRebuild();
    }
    onFolderCacheChanged: {
        requestVideosConfigRebuild();
    }

    // Persist the random-interval / random-start-time settings as soon as
    // they change. These keys were added to main.xml after the plugin was
    // already loaded in some sessions, so relying solely on the config
    // dialog's cfg_* auto-sync can drop them until a plasmashell restart.
    // Explicitly flushing here guarantees they are always written.
    function flushWallpaperConfig() {
        main.configuration.writeConfig();
    }

    onRandomStartTimeChanged: flushWallpaperConfig()
    onRandomIntervalMinSecondsChanged: flushWallpaperConfig()
    onRandomIntervalMinMinutesChanged: flushWallpaperConfig()
    onRandomIntervalMinHoursChanged: flushWallpaperConfig()
    onRandomIntervalMaxSecondsChanged: flushWallpaperConfig()
    onRandomIntervalMaxMinutesChanged: flushWallpaperConfig()
    onRandomIntervalMaxHoursChanged: flushWallpaperConfig()
    onTilesMaxTilesChanged: flushWallpaperConfig()
    onTilesMergeDurationChanged: flushWallpaperConfig()
    onTilesRandomizeChanged: flushWallpaperConfig()
    onTilesAspectToleranceChanged: flushWallpaperConfig()
    onTilesLayoutStyleChanged: flushWallpaperConfig()
    onTilesTransformsBeforeFullChanged: flushWallpaperConfig()
    onTilesSegmentMinMsChanged: flushWallpaperConfig()
    onTilesSegmentMaxMsChanged: flushWallpaperConfig()
    onTilesChoreographyModeChanged: flushWallpaperConfig()

    Component.onCompleted: {
        startTimer.start();
        Qt.callLater(updateVideosConfig);
        Qt.callLater(() => {
            player.currentSource = Qt.binding(() => {
                return main.currentSource;
            });
        });
    }

    Connections {
        target: Qt.application
        function onAboutToQuit() {
            main.configuration.LastVideoPosition = player.player.position;
            main.configuration.writeConfig();
            printLog("About to quit. Last video position saved:", main.configuration.LastVideoPosition);
        }
    }
    Component.onDestruction: {
        main.configuration.LastVideoPosition = player.player.position;
        main.configuration.writeConfig();
        printLog("Component on destruction. Last video position saved:", main.configuration.LastVideoPosition);
    }
    Item {
        onWindowChanged: window => {
            if (!window)
                return;
            // https://github.com/KDE/plasma-desktop/blob/Plasma/6.3/desktoppackage/contents/views/Desktop.qml
            // https://github.com/KDE/plasma-desktop/blob/Plasma/6.3/desktoppackage/contents/lockscreen/LockScreen.qml
            main.lockScreenMode = "source" in window && window.source.toString().endsWith("LockScreen.qml");
        }
    }

    property int playbackOverride: Enum.PlaybackOverride.Default
    property int muteOverride: Enum.MuteOverride.Default

    contextualActions: [
        PlasmaCore.Action {
            text: main.tilesMode
                ? i18nd("plasma_wallpaper_luisbocanegra.smart.video.wallpaper.reborn", "Next Transform")
                : i18nd("plasma_wallpaper_luisbocanegra.smart.video.wallpaper.reborn", "Next Video")
            icon.name: "media-skip-forward"
            onTriggered: {
                if (main.tilesMode && tilesPlayerLoader.item) {
                    tilesPlayerLoader.item.nextTransform();
                } else {
                    main.skipNext();
                }
            }
            visible: main.tilesMode || player.multipleVideos
        },
        PlasmaCore.Action {
            text: {
                if (main.playbackOverride === Enum.PlaybackOverride.Default) {
                    return main.playing ? i18nd("plasma_wallpaper_luisbocanegra.smart.video.wallpaper.reborn", "Pause") : i18nd("plasma_wallpaper_luisbocanegra.smart.video.wallpaper.reborn", "Play");
                } else {
                    return i18nd("plasma_wallpaper_luisbocanegra.smart.video.wallpaper.reborn", "Default Playback");
                }
            }
            icon.name: {
                if (main.playbackOverride === Enum.PlaybackOverride.Default) {
                    return main.playing ? "media-playback-pause" : "media-playback-start";
                } else {
                    return "view-refresh";
                }
            }
            onTriggered: {
                if (main.playbackOverride === Enum.PlaybackOverride.Default) {
                    main.playbackOverride = main.playing ? Enum.PlaybackOverride.Pause : Enum.PlaybackOverride.Play;
                } else {
                    main.playbackOverride = Enum.PlaybackOverride.Default;
                }
            }
        },
        PlasmaCore.Action {
            text: {
                if (main.muteOverride === Enum.MuteOverride.Default) {
                    return main.muteAudio ? i18nd("plasma_wallpaper_luisbocanegra.smart.video.wallpaper.reborn", "Unmute") : i18nd("plasma_wallpaper_luisbocanegra.smart.video.wallpaper.reborn", "Mute");
                } else {
                    return i18nd("plasma_wallpaper_luisbocanegra.smart.video.wallpaper.reborn", "Default Muting");
                }
            }
            icon.name: {
                if (main.muteOverride === Enum.MuteOverride.Default) {
                    return main.muteAudio ? "audio-volume-high" : "audio-volume-muted";
                } else {
                    return "view-refresh";
                }
            }
            onTriggered: {
                if (main.muteOverride === Enum.MuteOverride.Default) {
                    main.muteOverride = main.muteAudio ? Enum.MuteOverride.Unmute : Enum.MuteOverride.Mute;
                } else {
                    main.muteOverride = Enum.MuteOverride.Default;
                }
            }
        }
    ]
}
