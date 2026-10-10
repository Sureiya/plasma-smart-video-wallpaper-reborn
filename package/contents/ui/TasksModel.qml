import QtQuick
import org.kde.taskmanager 0.1 as TaskManager
import org.kde.plasma.plasmoid

Item {
    id: root
    property var screenGeometry
    property bool activeExists: false
    property bool maximizedExists: false
    property bool fullscreenExists: false
    property bool visibleExists: false
    property var abstractTasksModel: TaskManager.AbstractTasksModel
    property var isMaximized: abstractTasksModel.IsMaximized
    property var isActive: abstractTasksModel.IsActive
    property var isWindow: abstractTasksModel.IsWindow
    property var isFullScreen: abstractTasksModel.IsFullScreen
    property var isMinimized: abstractTasksModel.IsMinimized
    property var geometry: abstractTasksModel.Geometry
    property var screenGeometryRole: abstractTasksModel.ScreenGeometry
    property real coveragePercent: 0
    property bool filterByActive: false
    property bool filterByScreen: false
    property bool trackLastActive: false
    readonly property string currentActivity: activityInfo.currentActivity

    function getTopTask() {
        let highestTask = null;
        let maxStackingOrder = -1;
        for (var i = 0; i < tasksModel.count; i++) {
            const currentTask = tasksModel.index(i, 0);
            if (currentTask === undefined || !tasksModel.data(currentTask, isWindow))
                continue;

            const stackingOrder = tasksModel.data(currentTask, abstractTasksModel.StackingOrder);
            if (stackingOrder > maxStackingOrder) {
                maxStackingOrder = stackingOrder;
                highestTask = currentTask;
            }
        }
        return highestTask;
    }

    // Intersection area of two rects {x,y,width,height}.
    function intersectArea(a, b) {
        const ax = a.x, ay = a.y, aw = a.width, ah = a.height;
        const bx = b.x, by = b.y, bw = b.width, bh = b.height;
        const x1 = Math.max(ax, bx);
        const y1 = Math.max(ay, by);
        const x2 = Math.min(ax + aw, bx + bw);
        const y2 = Math.min(ay + ah, by + bh);
        const w = x2 - x1;
        const h = y2 - y1;
        return (w > 0 && h > 0) ? w * h : 0;
    }

    function updateWindowsInfo() {
        let activeCount = 0;
        let visibleCount = 0;
        let maximizedCount = 0;
        let fullscreenCount = 0;
        for (var i = 0; i < tasksModel.count; i++) {
            const currentTask = tasksModel.index(i, 0);
            if (currentTask === undefined || !tasksModel.data(currentTask, isWindow))
                continue;

            if (filterByActive && !tasksModel.data(currentTask, isActive))
                continue;

            visibleCount += 1;
            if (tasksModel.data(currentTask, isMaximized))
                maximizedCount += 1;

            if (tasksModel.data(currentTask, isFullScreen))
                fullscreenCount += 1;
        }

        let _activeExists = tasksModel.data(tasksModel.activeTask, isActive) || false;
        let _activeTask = null;
        let _maximizedExists = maximizedCount > 0;
        let _fullscreenExists = fullscreenCount > 0;
        let _visibleExists = visibleCount > 0;
        if (filterByActive && _activeExists) {
            _activeTask = tasksModel.activeTask;
        }

        if (!_activeTask && trackLastActive) {
            _activeTask = getTopTask();
            _activeExists = Boolean(_activeTask);
        }

        if (_activeTask) {
            _maximizedExists = tasksModel.data(_activeTask, isMaximized) || false;
            _fullscreenExists = tasksModel.data(_activeTask, isFullScreen) || false;
            _visibleExists = _activeExists;
        }

        // Compute the fraction (0..100) of the screen covered by visible windows.
        root.updateCoverage();

        activeExists = _activeExists;
        fullscreenExists = _fullscreenExists;
        maximizedExists = _maximizedExists;
        visibleExists = _visibleExists;
    }

    function updateCoverage() {
        const scr = root.screenGeometry;
        if (!scr || !scr.width || !scr.height) {
            root.coveragePercent = 0;
            return;
        }
        const screenArea = scr.width * scr.height;
        let covered = 0;
        for (var i = 0; i < tasksModel.count; i++) {
            const currentTask = tasksModel.index(i, 0);
            if (currentTask === undefined || !tasksModel.data(currentTask, isWindow))
                continue;
            if (tasksModel.data(currentTask, isMinimized))
                continue;

            // A fullscreen window covers the entire screen by definition, even
            // when its reported geometry doesn't perfectly match the screen rect
            // (different origin / coordinate space on some window systems).
            if (tasksModel.data(currentTask, isFullScreen)) {
                root.coveragePercent = 100;
                return;
            }

            const geom = tasksModel.data(currentTask, geometry);
            if (!geom || !geom.width || !geom.height)
                continue;
            covered += root.intersectArea(geom, scr);
        }
        root.coveragePercent = screenArea > 0 ? Math.min(100, covered / screenArea * 100) : 0;
    }

    Connections {
        target: main.configuration
        function onValueChanged() {
            Qt.callLater(root.update);
        }
    }

    TaskManager.VirtualDesktopInfo {
        id: virtualDesktopInfo
    }

    TaskManager.ActivityInfo {
        id: activityInfo
    }

    TaskManager.TasksModel {
        id: tasksModel

        sortMode: TaskManager.TasksModel.SortVirtualDesktop
        groupMode: TaskManager.TasksModel.GroupDisabled
        activity: activityInfo.currentActivity
        screenGeometry: root.screenGeometry
        filterByScreen: root.filterByScreen
        filterByActivity: true
        filterMinimized: true
        onDataChanged: {
            Qt.callLater(root.update);
        }
        onCountChanged: {
            Qt.callLater(root.update);
        }
        Component.onCompleted: {
            // Plasma 6.7 per-output virtual desktops
            // https://invent.kde.org/plasma/plasma-desktop/-/merge_requests/3427
            if (tasksModel.hasOwnProperty("filterByCurrentVirtualDesktop")) {
                tasksModel.filterByCurrentVirtualDesktop = true;
            } else {
                tasksModel.virtualDesktop = Qt.binding(function () {
                    return virtualDesktopInfo.currentDesktop;
                });
                tasksModel.filterByVirtualDesktop = true;
            }
        }
    }

    function update() {
        if (!updateTimer.running) {
            updateTimer.start();
        }
    }

    Timer {
        id: updateTimer

        interval: 5
        onTriggered: {
            root.updateWindowsInfo();
        }
    }

    // Safety net: window geometry/coverage can change without a taskmanager
    // data-change signal (e.g. a window moved over the screen while metadata was
    // unchanged). Re-evaluate coverage periodically so "pause on coverage" reacts
    // reliably — including at the moment a new choreography cycle begins.
    Timer {
        id: coveragePollTimer
        interval: 500
        repeat: true
        running: true
        onTriggered: root.updateCoverage()
    }
}
