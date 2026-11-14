import QtQuick
import Quickshell
import qs.Common
import qs.Widgets
import qs.DCommon.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    // ---- settings -------------------------------------------------------------------
    readonly property string dbPath: (pluginData.dbPath || "").trim()
    readonly property int refreshSeconds: Math.max(10, parseInt(pluginData.refreshInterval || 60))
    // "due" = overdue + due today, "overdue", "all" = every open reminder
    readonly property string countMode: pluginData.countMode || "due"
    readonly property int upcomingDays: parseInt(pluginData.upcomingDays !== undefined ? pluginData.upcomingDays : 7)
    readonly property bool showUndated: pluginData.showUndated !== undefined ? pluginData.showUndated : true
    readonly property bool showSubtasks: pluginData.showSubtasks !== undefined ? pluginData.showSubtasks : true
    readonly property bool hideWhenEmpty: pluginData.hideWhenEmpty !== undefined ? pluginData.hideWhenEmpty : false
    readonly property bool showLabel: pluginData.showLabel !== undefined ? pluginData.showLabel : false

    // ---- state ----------------------------------------------------------------------
    readonly property string scriptPath: decodeURIComponent(Qt.resolvedUrl("scripts/skykeep-reminders.sh").toString().replace(/^file:\/\//, ""))
    property var reminders: []
    property bool loaded: false
    property string errorText: ""
    property bool busy: false
    // Bumped every minute so "today"/"overdue" boundaries move without a re-query.
    property real nowMs: Date.now()

    readonly property var buckets: classify(reminders, nowMs)
    readonly property int overdueCount: buckets.overdue.length
    readonly property int todayCount: buckets.today.length
    readonly property int badgeCount: {
        if (countMode === "overdue")
            return overdueCount;
        if (countMode === "all")
            return visibleReminders(reminders).length;
        return overdueCount + todayCount;
    }
    readonly property color accent: errorText ? Theme.surfaceVariantText : overdueCount > 0 ? Theme.error : badgeCount > 0 ? Theme.primary : Theme.surfaceVariantText

    _visibilityOverride: hideWhenEmpty && loaded && !errorText && badgeCount === 0
    _visibilityOverrideValue: false

    // ---- data -----------------------------------------------------------------------
    // Proc.runCommand debounces by id and a repeat call replaces the stored callback, so
    // every widget instance (one per bar / monitor) needs its own id or only the last
    // instance ever receives results.
    readonly property string procId: "skykeepReminders.query." + Math.random().toString(36).slice(2)

    function refresh() {
        busy = true;
        Proc.runCommand(procId, ["bash", scriptPath, "query", dbPath], (stdout, exitCode) => {
            busy = false;
            nowMs = Date.now();
            if (exitCode !== 0) {
                errorText = "Reminder helper failed (exit " + exitCode + ")";
                return;
            }
            try {
                const data = JSON.parse(stdout.trim());
                if (!data.ok) {
                    errorText = data.error || "Could not read Skykeep";
                    return;
                }
                errorText = "";
                reminders = data.reminders || [];
                loaded = true;
            } catch (e) {
                errorText = "Unexpected output from helper";
                console.warn("skykeepReminders: parse error", e, stdout);
            }
        }, 200, 15000, root);
    }

    Component.onDestruction: Proc.release(procId)

    function launch(args) {
        Quickshell.execDetached(["bash", scriptPath, "open"].concat(args));
    }

    function visibleReminders(list) {
        return list.filter(r => showSubtasks || !r.subtask);
    }

    // Due instant as a local Date. All-day reminders are stored at UTC midnight of
    // their date, so rebuild that calendar date in local time.
    function dueDate(r) {
        if (r.due === null || r.due === undefined)
            return null;
        const d = new Date(r.due * 1000);
        if (r.allDay)
            return new Date(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate());
        return d;
    }

    function startOfDay(ms) {
        const d = new Date(ms);
        return new Date(d.getFullYear(), d.getMonth(), d.getDate());
    }

    function classify(list, now) {
        const out = {
            overdue: [],
            today: [],
            upcoming: [],
            later: [],
            undated: []
        };
        const today = startOfDay(now);
        const tomorrow = new Date(today.getFullYear(), today.getMonth(), today.getDate() + 1);
        const horizon = new Date(today.getFullYear(), today.getMonth(), today.getDate() + 1 + upcomingDays);
        for (const r of visibleReminders(list)) {
            const due = dueDate(r);
            if (!due) {
                out.undated.push(r);
            } else if (r.allDay ? due < today : due.getTime() < now) {
                out.overdue.push(r);
            } else if (due < tomorrow) {
                out.today.push(r);
            } else if (due < horizon) {
                out.upcoming.push(r);
            } else {
                out.later.push(r);
            }
        }
        return out;
    }

    function sections() {
        const b = buckets;
        const s = [];
        if (b.overdue.length)
            s.push({ title: "Overdue", color: Theme.error, items: b.overdue });
        if (b.today.length)
            s.push({ title: "Today", color: Theme.primary, items: b.today });
        if (b.upcoming.length)
            s.push({ title: upcomingDays === 1 ? "Tomorrow" : "Next " + upcomingDays + " days", color: Theme.surfaceText, items: b.upcoming });
        if (b.later.length)
            s.push({ title: "Later", color: Theme.surfaceVariantText, items: b.later });
        if (showUndated && b.undated.length)
            s.push({ title: "No date", color: Theme.surfaceVariantText, items: b.undated });
        return s;
    }

    function dueLabel(r) {
        const due = dueDate(r);
        if (!due)
            return "";
        const today = startOfDay(nowMs);
        const dayDiff = Math.round((startOfDay(due.getTime()) - today) / 86400000);
        let day;
        if (dayDiff === 0)
            day = "Today";
        else if (dayDiff === -1)
            day = "Yesterday";
        else if (dayDiff === 1)
            day = "Tomorrow";
        else if (dayDiff > 1 && dayDiff < 7)
            day = Qt.formatDate(due, "dddd");
        else if (due.getFullYear() === today.getFullYear())
            day = Qt.formatDate(due, "d MMM");
        else
            day = Qt.formatDate(due, "d MMM yyyy");
        if (r.allDay)
            return day;
        return day + ", " + Qt.formatTime(due, Locale.ShortFormat);
    }

    function listColour(r) {
        return r.colour && /^#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$/.test(r.colour) ? r.colour : Theme.primary;
    }

    function summaryText() {
        if (errorText)
            return errorText;
        if (!loaded)
            return "Loading…";
        const parts = [];
        if (overdueCount)
            parts.push(overdueCount + " overdue");
        if (todayCount)
            parts.push(todayCount + " due today");
        const open = visibleReminders(reminders).length;
        parts.push(open + " open");
        return parts.join(" · ");
    }

    function tooltip() {
        return "iCloud Reminders: " + summaryText();
    }

    Timer {
        interval: root.refreshSeconds * 1000
        running: root.surfaceLive
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }

    Timer {
        interval: 60000
        running: root.surfaceLive
        repeat: true
        onTriggered: root.nowMs = Date.now()
    }

    onDbPathChanged: refresh()

    pillRightClickAction: () => launch(["--app", "reminders"])

    // ---- bar pills ------------------------------------------------------------------
    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingXS

            DIcon {
                name: root.errorText ? "error" : root.overdueCount > 0 ? "notification_important" : "checklist"
                color: root.accent
                size: root.iconSize
                anchors.verticalCenter: parent.verticalCenter
            }

            StyledText {
                visible: root.loaded && !root.errorText && (root.badgeCount > 0 || root.showLabel)
                text: root.showLabel ? (root.badgeCount > 0 ? root.badgeCount + " Reminders" : "Reminders") : root.badgeCount
                color: root.accent
                font.pixelSize: root.textSize
                font.weight: Theme.fontWeightMedium
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: Theme.spacingXXS

            DIcon {
                name: root.errorText ? "error" : root.overdueCount > 0 ? "notification_important" : "checklist"
                color: root.accent
                size: root.iconSize
                anchors.horizontalCenter: parent.horizontalCenter
            }

            StyledText {
                visible: root.loaded && !root.errorText && root.badgeCount > 0
                text: root.badgeCount
                color: root.accent
                font.pixelSize: root.textSize
                font.weight: Theme.fontWeightMedium
                anchors.horizontalCenter: parent.horizontalCenter
            }
        }
    }

    // ---- popout ---------------------------------------------------------------------
    popoutWidth: 400
    popoutHeight: 520

    popoutContent: Component {
        PopoutComponent {
            id: popout

            headerText: "Reminders"
            detailsText: root.summaryText()

            headerActions: Component {
                Row {
                    spacing: Theme.spacingXS

                    DActionButton {
                        iconName: "refresh"
                        tooltipText: "Refresh"
                        enabled: !root.busy
                        onClicked: root.refresh()
                    }
                    DActionButton {
                        iconName: "add"
                        tooltipText: "New reminder"
                        onClicked: {
                            root.launch(["--new", "reminder"]);
                            popout.closePopout?.();
                        }
                    }
                    DActionButton {
                        iconName: "open_in_new"
                        tooltipText: "Open Skykeep Reminders"
                        onClicked: {
                            root.launch(["--app", "reminders"]);
                            popout.closePopout?.();
                        }
                    }
                }
            }

            Item {
                width: parent.width
                height: root.popoutHeight - popout.headerHeight - popout.detailsHeight - Theme.spacingL * 2

                // Empty / error state
                Column {
                    anchors.centerIn: parent
                    spacing: Theme.spacingS
                    visible: !!root.errorText || (root.loaded && listColumn.sectionCount === 0)
                    width: parent.width - Theme.spacingL * 2

                    DIcon {
                        anchors.horizontalCenter: parent.horizontalCenter
                        name: root.errorText ? "cloud_off" : "task_alt"
                        size: Theme.iconSizeLarge * 1.5
                        color: Theme.surfaceVariantText
                    }
                    StyledText {
                        width: parent.width
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.WordWrap
                        text: root.errorText ? root.errorText : "All done. Nothing to remind you about."
                        color: Theme.surfaceVariantText
                        font.pixelSize: Theme.fontSizeMedium
                    }
                }

                DFlickable {
                    id: flick
                    anchors.fill: parent
                    clip: true
                    contentWidth: width
                    contentHeight: listColumn.implicitHeight
                    visible: !root.errorText && listColumn.sectionCount > 0

                    Column {
                        id: listColumn
                        width: flick.width
                        spacing: Theme.spacingM
                        readonly property var model: root.loaded ? root.sections() : []
                        readonly property int sectionCount: model.length

                        Repeater {
                            model: listColumn.model

                            delegate: Column {
                                id: sectionCol
                                required property var modelData
                                width: listColumn.width
                                spacing: Theme.spacingXXS

                                StyledText {
                                    leftPadding: Theme.spacingS
                                    bottomPadding: Theme.spacingXXS
                                    text: sectionCol.modelData.title + "  " + sectionCol.modelData.items.length
                                    color: sectionCol.modelData.color
                                    font.pixelSize: Theme.fontSizeSmall
                                    font.weight: Theme.fontWeightMedium
                                }

                                Repeater {
                                    model: sectionCol.modelData.items

                                    delegate: StyledRect {
                                        id: row
                                        required property var modelData
                                        width: sectionCol.width
                                        height: rowContent.implicitHeight + Theme.spacingS * 2
                                        radius: Theme.cornerRadius
                                        color: rowMouse.containsMouse ? Theme.withAlpha(Theme.surfaceText, 0.08) : Theme.withAlpha(Theme.surfaceText, 0.03)

                                        Rectangle {
                                            id: dot
                                            width: 10
                                            height: 10
                                            radius: 5
                                            anchors.left: parent.left
                                            anchors.leftMargin: Theme.spacingM
                                            anchors.verticalCenter: parent.verticalCenter
                                            color: "transparent"
                                            border.width: 2
                                            border.color: root.listColour(row.modelData)
                                        }

                                        Column {
                                            id: rowContent
                                            anchors.left: dot.right
                                            anchors.leftMargin: Theme.spacingM
                                            anchors.right: badges.left
                                            anchors.rightMargin: Theme.spacingS
                                            anchors.verticalCenter: parent.verticalCenter
                                            spacing: 2

                                            StyledText {
                                                width: parent.width
                                                text: row.modelData.title || "Untitled"
                                                color: Theme.surfaceText
                                                font.pixelSize: Theme.fontSizeMedium
                                                elide: Text.ElideRight
                                                maximumLineCount: 2
                                                wrapMode: Text.WordWrap
                                            }
                                            StyledText {
                                                width: parent.width
                                                text: {
                                                    const due = root.dueLabel(row.modelData);
                                                    return due ? due + "  ·  " + row.modelData.list : row.modelData.list;
                                                }
                                                color: sectionCol.modelData.title === "Overdue" ? Theme.error : Theme.surfaceVariantText
                                                font.pixelSize: Theme.fontSizeSmall
                                                elide: Text.ElideRight
                                            }
                                        }

                                        Row {
                                            id: badges
                                            anchors.right: parent.right
                                            anchors.rightMargin: Theme.spacingM
                                            anchors.verticalCenter: parent.verticalCenter
                                            spacing: Theme.spacingXXS

                                            StyledText {
                                                visible: row.modelData.priority > 0
                                                anchors.verticalCenter: parent.verticalCenter
                                                // Apple: 1 = high, 5 = medium, 9 = low
                                                text: row.modelData.priority <= 4 ? "!!!" : row.modelData.priority <= 5 ? "!!" : "!"
                                                color: Theme.primary
                                                font.pixelSize: Theme.fontSizeSmall
                                                font.weight: Font.Bold
                                            }
                                            DIcon {
                                                visible: !!row.modelData.repeats
                                                name: "repeat"
                                                size: Theme.iconSizeSmall
                                                color: Theme.surfaceVariantText
                                                anchors.verticalCenter: parent.verticalCenter
                                            }
                                            DIcon {
                                                visible: !!row.modelData.flagged
                                                name: "flag"
                                                filled: true
                                                size: Theme.iconSizeSmall
                                                color: Theme.warning
                                                anchors.verticalCenter: parent.verticalCenter
                                            }
                                        }

                                        MouseArea {
                                            id: rowMouse
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: {
                                                root.launch(["--app", "reminders"]);
                                                popout.closePopout?.();
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
