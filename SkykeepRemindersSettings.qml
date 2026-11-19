import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    id: root
    pluginId: "skykeepReminders"

    StyledText {
        width: parent.width
        text: "Shows your iCloud Reminders from Skykeep's local library. Skykeep 0.1.24 or newer must be installed and signed in: the plugin reads the library and asks Skykeep to tick reminders off, put them back, add one or open it, so every change reaches iCloud through its outbox. Adding from the popout needs 0.1.31."
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    SelectionSetting {
        settingKey: "countMode"
        label: "Bar count"
        description: "Which reminders the number in the bar counts"
        options: [
            { label: "Overdue and due today", value: "due" },
            { label: "Overdue only", value: "overdue" },
            { label: "All open reminders", value: "all" }
        ]
        defaultValue: "due"
    }

    SelectionSetting {
        settingKey: "refreshInterval"
        label: "Refresh interval"
        description: "How often to re-read the library (it's a local file, so this is cheap)"
        options: [
            { label: "15 seconds", value: "15" },
            { label: "30 seconds", value: "30" },
            { label: "1 minute", value: "60" },
            { label: "5 minutes", value: "300" }
        ]
        defaultValue: "60"
    }

    SliderSetting {
        settingKey: "upcomingDays"
        label: "Upcoming window (days)"
        description: "Reminders due after today but within this many days are grouped as upcoming"
        minimum: 1
        maximum: 30
        defaultValue: 7
    }

    ToggleSetting {
        settingKey: "showUndated"
        label: "Show reminders without a date"
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "showSubtasks"
        label: "Show subtasks"
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "showCompleted"
        label: "Show recently completed reminders"
        description: "Ticked-off reminders appear under Recently completed, where a click puts them back"
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "inlineCreate"
        label: "Add reminders from the popout"
        description: "Show a text field that adds a reminder without opening Skykeep. Needs Skykeep 0.1.31 or newer; turn it off on an older build."
        defaultValue: true
    }

    SliderSetting {
        settingKey: "completedHours"
        label: "Recently completed window"
        description: "How far back the Recently completed section looks"
        minimum: 1
        maximum: 168
        unit: "h"
        defaultValue: 24
    }

    ToggleSetting {
        settingKey: "showLabel"
        label: "Show \"Reminders\" label in the bar"
        defaultValue: false
    }

    ToggleSetting {
        settingKey: "hideWhenEmpty"
        label: "Hide when nothing to count"
        description: "Hide the bar widget entirely when the count is zero"
        defaultValue: false
    }

    StringSetting {
        settingKey: "dbPath"
        label: "Library path (optional)"
        description: "Leave empty to find Skykeep's library.db automatically (native, Flatpak or Snap install)"
        placeholder: "~/.local/share/io.github.yashwanthkamireddi.Skykeep/library.db"
        defaultValue: ""
    }
}
