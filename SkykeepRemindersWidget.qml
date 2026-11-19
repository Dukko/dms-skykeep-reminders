import QtQuick
import QtQuick.Layouts
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
    readonly property bool showCompleted: pluginData.showCompleted !== undefined ? pluginData.showCompleted : true
    readonly property int completedHours: {
        const hours = parseInt(pluginData.completedHours);
        return isNaN(hours) ? 24 : Math.min(720, Math.max(1, hours));
    }
    // Needs Skykeep 0.1.31+: an older build opens its main window on --create-reminder
    // instead of adding anything, so the setting turns it off there.
    readonly property bool inlineCreate: pluginData.inlineCreate !== undefined ? pluginData.inlineCreate : true
    readonly property string savedListGuid: pluginData.lastListGuid || ""

    // ---- state ----------------------------------------------------------------------
    readonly property string scriptPath: decodeURIComponent(Qt.resolvedUrl("scripts/skykeep-reminders.sh").toString().replace(/^file:\/\//, ""))
    property var reminders: []
    property var completed: []
    property var lists: []
    property string chosenListGuid: ""
    readonly property var dueChoices: ["No date", "Today", "This evening", "Tomorrow", "Tomorrow morning", "Next week"]
    property string chosenDue: "No date"
    // Titles handed to Skykeep, waiting for the library to show them.
    property var pendingCreates: []
    property bool loaded: false
    property string errorText: ""
    property bool busy: false
    // The little bar under the list: "Completed …" with Undo, or a quiet failure.
    property string noticeText: ""
    property bool noticeError: false
    property var undoAction: null
    // Bumped every minute so "today"/"overdue" boundaries move without a re-query.
    property real nowMs: Date.now()

    readonly property string selectedListGuid: {
        const known = id => lists.some(l => l.id === id);
        if (chosenListGuid && known(chosenListGuid))
            return chosenListGuid;
        if (savedListGuid && known(savedListGuid))
            return savedListGuid;
        return lists.length > 0 ? lists[0].id : "";
    }
    readonly property var selectedList: {
        const id = selectedListGuid;
        return lists.find(l => l.id === id) || null;
    }
    readonly property bool canCreateInline: inlineCreate && lists.length > 0
    readonly property var listColourMap: {
        const map = {};
        for (const list of lists)
            map[list.title] = listColour(list);
        return map;
    }

    signal composerFocusRequested()

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
        Proc.runCommand(procId, ["bash", scriptPath, "query", dbPath, String(completedHours * 3600)], (stdout, exitCode) => {
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
                completed = data.completed || [];
                lists = data.lists || [];
                loaded = true;
                resolvePendingCreates();
            } catch (e) {
                errorText = "Unexpected output from helper";
                console.warn("skykeepReminders: parse error", e, stdout);
            }
        }, 200, 15000, root);
    }

    Component.onDestruction: Proc.release(procId)

    // Launch Skykeep with the helper's `open` path (it also fixes focus on niri/Hyprland).
    function launch(args) {
        console.info("skykeepReminders: launching Skykeep", JSON.stringify(args));
        Proc.runCommand(null, ["bash", scriptPath, "open"].concat(args), (out, code) => {
            if (code !== 0)
                console.warn("skykeepReminders: launch failed, exit", code, out);
        }, 0, 15000, root);
    }

    function visibleReminders(list) {
        return list.filter(r => showSubtasks || !r.subtask);
    }

    function isDone(r) {
        return r.completedAt !== null && r.completedAt !== undefined && r.completedAt > 0;
    }

    // The tick and the restore go through Skykeep's own edit path, so the change reaches
    // iCloud through its outbox. Never write to library.db from here.
    function toggle(r) {
        if (!r || !r.id)
            return;
        act(isDone(r) ? "uncomplete" : "complete", r);
    }

    function act(kind, r, remember) {
        if (!r || !r.id)
            return;
        if (kind === "show") {
            launch(["--app", "reminders", "--reminder", r.id]);
            return;
        }

        // Move the row at once; the settle refreshes below put it back if Skykeep refuses.
        const id = r.id;
        if (kind === "complete") {
            reminders = reminders.filter(x => x.id !== id);
            if (showCompleted)
                completed = [Object.assign({}, r, { completedAt: Math.floor(Date.now() / 1000) })].concat(completed.filter(x => x.id !== id));
        } else {
            completed = completed.filter(x => x.id !== id);
            reminders = [Object.assign({}, r, { completedAt: null })].concat(reminders.filter(x => x.id !== id));
        }

        Proc.runCommand(null, ["bash", scriptPath, kind, id], (out, code) => {
            if (code !== 0) {
                console.warn("skykeepReminders: " + kind + " failed, exit", code, out);
                undoAction = null;
                refresh();
                showNotice(kind === "complete" ? "Could not tick that reminder off" : "Could not put that reminder back", true);
                return;
            }
            settleTimer.run();
        }, 0, 15000, root);

        if (remember !== false) {
            undoAction = {
                kind: kind,
                reminder: r
            };
            showNotice((kind === "complete" ? "Completed “" : "Put back “") + shortTitle(r) + "”", false);
        }
    }

    function undo() {
        if (!undoAction)
            return;
        const action = undoAction;
        undoAction = null;
        noticeTimer.stop();
        const undoKind = action.kind === "complete" ? "uncomplete" : "complete";
        act(undoKind, action.reminder, false);
        showNotice((undoKind === "complete" ? "Completed “" : "Put back “") + shortTitle(action.reminder) + "”", false);
    }

    function showNotice(text, isError) {
        noticeText = text;
        noticeError = !!isError;
        noticeTimer.restart();
    }

    function shortText(text) {
        const title = (text || "").trim();
        return title.length > 40 ? title.slice(0, 39) + "…" : title;
    }

    function shortTitle(r) {
        return shortText(r.title || "Untitled");
    }

    function chooseList(id) {
        if (!id || id === selectedListGuid)
            return;
        chosenListGuid = id;
        try {
            if (pluginService)
                pluginService.savePluginData(pluginId, "lastListGuid", id);
        } catch (e) {
            console.warn("skykeepReminders: could not remember the list", e);
        }
    }

    // { due, allDay } for a "When" choice, or null for no date. All-day dues are the date's
    // midnight UTC, as Skykeep stores them and dueDate() reads them back.
    function dueFor(choice, nowMs) {
        const now = new Date(nowMs);
        const day = offset => new Date(now.getFullYear(), now.getMonth(), now.getDate() + offset);
        const allDay = d => ({ due: Date.UTC(d.getFullYear(), d.getMonth(), d.getDate()) / 1000, allDay: true });
        const at = (d, hour) => ({ due: Math.floor(new Date(d.getFullYear(), d.getMonth(), d.getDate(), hour).getTime() / 1000), allDay: false });
        switch (choice) {
        case "Today":
            return allDay(day(0));
        case "This evening":
            // Past 18:00, the next full hour, so it is never already overdue.
            return at(day(0), Math.max(18, now.getHours() + 1));
        case "Tomorrow":
            return allDay(day(1));
        case "Tomorrow morning":
            return at(day(1), 9);
        case "Next week":
            // The coming Monday, a week away when today is Monday.
            return allDay(day(((8 - now.getDay()) % 7) || 7));
        default:
            return null;
        }
    }

    // One field, one title: Skykeep adds it to the list it was told, and the new row arrives
    // on the settle refresh. No window, no library write from here.
    function submitComposer(field) {
        if (!field || !inlineCreate || lists.length === 0)
            return;
        const title = (field.text || "").trim();
        if (!title) {
            field.shake();
            return;
        }
        const listGuid = selectedListGuid;
        const listTitle = selectedList ? selectedList.title : "";
        const when = dueFor(chosenDue, Date.now());
        const pending = {
            title: title,
            listTitle: listTitle,
            before: reminders.map(r => r.id),
            at: Date.now()
        };
        pendingCreates = pendingCreates.concat([pending]);
        field.text = "";
        field.forceActiveFocus();
        chosenDue = "No date";
        showNotice("Adding “" + shortText(title) + "”…", false);

        const argv = ["bash", scriptPath, "create", title, listGuid];
        if (when)
            argv.push(String(when.due), when.allDay ? "1" : "0");
        Proc.runCommand(null, argv, (out, code) => {
            if (code !== 0) {
                console.warn("skykeepReminders: create failed, exit", code, out);
                pendingCreates = pendingCreates.filter(p => p !== pending);
                if (Qt.isQtObject(field) && field.text === "")
                    field.text = title;
                showNotice("Could not add that reminder", true);
                return;
            }
            settleTimer.run();
        }, 0, 15000, root);
    }

    // "Adding …" becomes "Added …" once the new row is actually in the library. If the
    // build has no create command, nothing arrives and the notice simply fades.
    function resolvePendingCreates() {
        if (pendingCreates.length === 0)
            return;
        const now = Date.now();
        const remaining = [];
        let added = null;
        for (const p of pendingCreates) {
            if (now - p.at > 60000)
                continue;
            const found = reminders.concat(completed).some(r => p.before.indexOf(r.id) === -1 && r.title === p.title);
            if (found)
                added = p;
            else
                remaining.push(p);
        }
        pendingCreates = remaining;
        if (added)
            showNotice("Added “" + shortText(added.title) + "”" + (added.listTitle ? " to " + added.listTitle : ""), false);
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
        const done = visibleReminders(completed);
        if (showCompleted && done.length)
            s.push({ title: "Recently completed", color: Theme.surfaceVariantText, items: done });
        return s;
    }

    function dayLabel(ms) {
        const due = new Date(ms);
        const today = startOfDay(nowMs);
        const dayDiff = Math.round((startOfDay(due.getTime()) - today) / 86400000);
        if (dayDiff === 0)
            return "Today";
        if (dayDiff === -1)
            return "Yesterday";
        if (dayDiff === 1)
            return "Tomorrow";
        if (dayDiff > 1 && dayDiff < 7)
            return Qt.formatDate(due, "dddd");
        if (due.getFullYear() === today.getFullYear())
            return Qt.formatDate(due, "d MMM");
        return Qt.formatDate(due, "d MMM yyyy");
    }

    function dueLabel(r) {
        const due = dueDate(r);
        if (!due)
            return "";
        const day = dayLabel(due.getTime());
        if (r.allDay)
            return day;
        // Qt.formatTime would read Locale.ShortFormat as Qt.ISODate ("15:30:00").
        return day + ", " + due.toLocaleTimeString(Qt.locale(), Locale.ShortFormat);
    }

    function completedLabel(r) {
        const at = r.completedAt;
        if (!at)
            return "";
        const seconds = Math.max(0, Math.floor(nowMs / 1000) - at);
        if (seconds < 60)
            return "just now";
        if (seconds < 3600)
            return Math.floor(seconds / 60) + " min ago";
        if (seconds < 86400)
            return Math.floor(seconds / 3600) + " h ago";
        const days = Math.floor(seconds / 86400);
        return days === 1 ? "yesterday" : days + " days ago";
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

    // Not surfaceLive: that follows effectiveVisible, so with hideWhenEmpty a hidden
    // widget would stop polling and never come back.
    readonly property bool pollLive: surfaceContext?.live ?? true

    Timer {
        interval: root.refreshSeconds * 1000
        running: root.pollLive
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }

    Timer {
        interval: 60000
        running: root.pollLive
        repeat: true
        onTriggered: root.nowMs = Date.now()
    }

    // After a tick, the library is written before Skykeep's process returns, but a
    // cold-started Skykeep can take a few seconds. Re-read a few times to catch up.
    Timer {
        id: settleTimer
        interval: 1500
        repeat: true
        property int remaining: 0
        function run() {
            remaining = 4;
            restart();
        }
        onTriggered: {
            root.refresh();
            remaining -= 1;
            if (remaining <= 0)
                stop();
        }
    }

    Timer {
        id: noticeTimer
        interval: 5000
        onTriggered: {
            root.undoAction = null;
            root.noticeText = "";
        }
    }

    onDbPathChanged: refresh()
    onCompletedHoursChanged: refresh()

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

            Connections {
                target: root
                function onComposerFocusRequested() {
                    if (composer.visible)
                        newTitle.forceActiveFocus();
                }
            }

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
                        tooltipText: root.canCreateInline ? "Add a reminder" : "New reminder"
                        onClicked: {
                            if (root.canCreateInline) {
                                root.composerFocusRequested();
                            } else {
                                root.launch(["--new", "reminder"]);
                                popout.closePopout?.();
                            }
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

                // Inline add through Skykeep's --create-reminder (0.1.31+).
                StyledRect {
                    id: composer
                    visible: root.canCreateInline
                    anchors.top: parent.top
                    anchors.left: parent.left
                    anchors.right: parent.right
                    height: composerRow.implicitHeight + Theme.spacingS * 2
                    radius: Theme.cornerRadius
                    color: Theme.withAlpha(Theme.surfaceText, 0.04)

                    ColumnLayout {
                        id: composerRow
                        anchors.fill: parent
                        anchors.margins: Theme.spacingS
                        spacing: Theme.spacingS

                        DTextField {
                            id: newTitle
                            Layout.fillWidth: true
                            placeholderText: "New reminder"
                            showAcceptButton: true
                            acceptButtonName: "add"
                            showClearButton: true
                            controlHeight: 36
                            onAccepted: root.submitComposer(newTitle)
                        }

                        RowLayout {
                            id: pickerRow
                            Layout.fillWidth: true
                            spacing: Theme.spacingS
                            // DDropdown in compact mode is as wide as dropdownWidth.
                            readonly property int half: Math.floor((width - spacing) / 2)

                            DDropdown {
                                id: listPicker
                                Layout.preferredWidth: pickerRow.half
                                dropdownWidth: pickerRow.half
                                showLabel: true
                                compactMode: true
                                triggerHeight: 32
                                popupWidth: 220
                                options: root.lists.map(l => l.title)
                                optionColorMap: root.listColourMap
                                currentValue: root.selectedList ? root.selectedList.title : ""
                                onValueChanged: title => {
                                    const list = root.lists.find(l => l.title === title);
                                    if (list)
                                        root.chooseList(list.id);
                                }
                            }

                            DDropdown {
                                id: duePicker
                                Layout.preferredWidth: pickerRow.half
                                dropdownWidth: pickerRow.half
                                showLabel: true
                                compactMode: true
                                triggerHeight: 32
                                popupWidth: 200
                                options: root.dueChoices
                                currentValue: root.chosenDue
                                onValueChanged: value => root.chosenDue = value
                            }
                        }
                    }
                }

                // Empty / error / loading state
                Column {
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.verticalCenter: flick.verticalCenter
                    spacing: Theme.spacingS
                    visible: listColumn.sectionCount === 0
                    width: parent.width - Theme.spacingL * 2

                    DIcon {
                        anchors.horizontalCenter: parent.horizontalCenter
                        name: root.errorText ? "cloud_off" : root.loaded ? "task_alt" : "hourglass_empty"
                        size: Theme.iconSizeLarge * 1.5
                        color: Theme.surfaceVariantText
                    }
                    StyledText {
                        width: parent.width
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.WordWrap
                        text: root.errorText ? root.errorText : root.loaded ? "All done. Nothing to remind you about." : "Loading…"
                        color: Theme.surfaceVariantText
                        font.pixelSize: Theme.fontSizeMedium
                    }
                }

                DFlickable {
                    id: flick
                    anchors.top: composer.visible ? composer.bottom : parent.top
                    anchors.topMargin: composer.visible ? Theme.spacingS : 0
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    clip: true
                    contentWidth: width
                    contentHeight: listColumn.implicitHeight + (root.noticeText ? 64 : Theme.spacingS)
                    visible: listColumn.sectionCount > 0

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
                                        readonly property bool done: root.isDone(modelData)
                                        width: sectionCol.width
                                        height: Math.max(rowContent.implicitHeight + Theme.spacingS * 2, 44)
                                        radius: Theme.cornerRadius
                                        color: rowMouse.containsMouse ? Theme.withAlpha(Theme.surfaceText, 0.08) : Theme.withAlpha(Theme.surfaceText, 0.03)

                                        // The whole row opens this reminder in Skykeep; the circle
                                        // in front of it ticks the reminder off or puts it back.
                                        MouseArea {
                                            id: rowMouse
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: {
                                                root.act("show", row.modelData);
                                                popout.closePopout?.();
                                            }
                                        }

                                        Item {
                                            id: checkButton
                                            z: 2
                                            width: Theme.iconSize + Theme.spacingXS
                                            height: width
                                            anchors.left: parent.left
                                            anchors.leftMargin: Theme.spacingS
                                            anchors.verticalCenter: parent.verticalCenter

                                            Rectangle {
                                                anchors.centerIn: parent
                                                width: Math.round(Theme.iconSize * 0.82)
                                                height: width
                                                radius: width / 2
                                                color: row.done ? root.listColour(row.modelData) : "transparent"
                                                border.width: 2
                                                border.color: root.listColour(row.modelData)
                                            }

                                            DIcon {
                                                anchors.centerIn: parent
                                                visible: row.done || checkMouse.containsMouse
                                                name: "check"
                                                size: Math.round(Theme.iconSize * 0.6)
                                                color: row.done ? "white" : root.listColour(row.modelData)
                                            }

                                            MouseArea {
                                                id: checkMouse
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: root.toggle(row.modelData)
                                            }
                                        }

                                        Column {
                                            id: rowContent
                                            anchors.left: checkButton.right
                                            anchors.leftMargin: Theme.spacingXS
                                            anchors.right: badges.left
                                            anchors.rightMargin: Theme.spacingS
                                            anchors.verticalCenter: parent.verticalCenter
                                            spacing: Theme.spacingXXS

                                            StyledText {
                                                width: parent.width
                                                text: row.modelData.title || "Untitled"
                                                color: row.done ? Theme.surfaceVariantText : Theme.surfaceText
                                                font.pixelSize: Theme.fontSizeMedium
                                                font.strikeout: row.done
                                                elide: Text.ElideRight
                                                maximumLineCount: 2
                                                wrapMode: Text.WordWrap
                                            }
                                            StyledText {
                                                width: parent.width
                                                text: {
                                                    if (row.done) {
                                                        const when = root.completedLabel(row.modelData);
                                                        return (when ? "Completed " + when + "  ·  " : "") + row.modelData.list;
                                                    }
                                                    const due = root.dueLabel(row.modelData);
                                                    return due ? due + "  ·  " + row.modelData.list : row.modelData.list;
                                                }
                                                color: !row.done && sectionCol.modelData.title === "Overdue" ? Theme.error : Theme.surfaceVariantText
                                                font.pixelSize: Theme.fontSizeSmall
                                                elide: Text.ElideRight
                                            }
                                        }

                                        Row {
                                            id: badges
                                            visible: !row.done
                                            width: visible ? implicitWidth : 0
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
                                    }
                                }
                            }
                        }
                    }
                }

                // The result of the last tick, with a way back.
                StyledRect {
                    id: notice
                    visible: root.noticeText !== ""
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    anchors.leftMargin: Theme.spacingS
                    anchors.rightMargin: Theme.spacingS
                    anchors.bottomMargin: Theme.spacingS
                    height: noticeRow.implicitHeight + Theme.spacingS * 2
                    radius: Theme.cornerRadius
                    color: Theme.surfaceContainerHigh
                    border.width: 1
                    border.color: root.noticeError ? Theme.error : Theme.outline
                    z: 10

                    RowLayout {
                        id: noticeRow
                        anchors.fill: parent
                        anchors.leftMargin: Theme.spacingM
                        anchors.rightMargin: Theme.spacingM
                        spacing: Theme.spacingS

                        StyledText {
                            Layout.fillWidth: true
                            text: root.noticeText
                            color: root.noticeError ? Theme.error : Theme.surfaceText
                            font.pixelSize: Theme.fontSizeSmall
                            elide: Text.ElideRight
                        }

                        StyledText {
                            id: undoLabel
                            visible: root.undoAction !== null
                            text: "Undo"
                            color: Theme.primary
                            font.pixelSize: Theme.fontSizeSmall
                            font.weight: Theme.fontWeightMedium

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.undo()
                            }
                        }
                    }
                }
            }
        }
    }
}
