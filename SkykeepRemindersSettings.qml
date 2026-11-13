import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    id: root
    pluginId: "skykeepReminders"

    StyledText {
        width: parent.width
        text: "Shows your iCloud Reminders from Skykeep's local library. Skykeep must be installed and signed in; it keeps the library in sync with iCloud. The plugin only reads it."
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
