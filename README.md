# Skykeep Reminders for Dux / DankMaterialShell

A DankBar widget that shows your **iCloud Reminders** in the bar, using
[Skykeep](https://github.com/YashwanthKamireddi/Skykeep) as the iCloud sync engine.

- **Bar pill:** a checklist icon and a count of overdue + due-today reminders. It turns
  red when something is overdue.
- **Popout:** open reminders grouped into Overdue, Today, Next *N* days, Later and No date.
  Each row shows the list colour, due time, priority, repeat and flag.
- **Header buttons:** refresh, new reminder (`skykeep --new reminder`), and open Skykeep
  Reminders.
- **Right-click** the pill to open Skykeep Reminders directly.

## How it works

Skykeep syncs iCloud into a local SQLite library and keeps it current over Apple's push
channel. This plugin never talks to Apple. A small helper, `scripts/skykeep-reminders.sh`,
opens that library **read-only** (`mode=ro`) and prints the open reminders as JSON:

```
Skykeep app ⇄ iCloud
     │ writes
     ▼
library.db ──(sqlite3, read-only)──▶ skykeep-reminders.sh ──JSON──▶ DankBar widget
```

The helper looks for the library in these places, in order:

| Install | Path |
|---|---|
| Native / AppImage / AUR | `$XDG_DATA_HOME/io.github.yashwanthkamireddi.Skykeep/library.db` |
| Flatpak | `~/.var/app/io.github.yashwanthkamireddi.Skykeep/data/…/library.db` |
| Snap | `~/snap/skykeep/{current,common}/.local/share/…/library.db` |

You can override the path in the plugin settings.

To launch Skykeep, the helper uses `skykeep` from `PATH`. If that isn't found, it reads the
`Exec=` line from `Skykeep.desktop`, which covers AppImage installs.

## Requirements

- Dux / DankMaterialShell ≥ 2.0
- [Skykeep](https://github.com/YashwanthKamireddi/Skykeep#install), installed and signed in
  at least once
- `sqlite3` and `bash`

## Install

```sh
git clone <this repo> ~/.config/dms/plugins/skykeepReminders
# or, while developing:
ln -s "$PWD" ~/.config/dms/plugins/skykeepReminders
```

Then open **Settings → Plugins**, scan for plugins, enable **Skykeep Reminders**, and add it
to a DankBar section.

## Settings

| Setting | Default | |
|---|---|---|
| Bar count | Overdue and due today | or Overdue only / All open |
| Refresh interval | 1 minute | 15 s – 5 min |
| Upcoming window | 7 days | how far ahead "upcoming" reaches |
| Show reminders without a date | on | |
| Show subtasks | on | |
| Show "Reminders" label | off | |
| Hide when nothing to count | off | hides the pill when the count is 0 |
| Library path | auto | override for unusual installs |

## Development

```sh
scripts/skykeep-reminders.sh locate      # which library.db will be used
scripts/skykeep-reminders.sh query | jq  # what the widget sees
scripts/skykeep-reminders.sh open --app reminders
```

Reminder titles are your data. Avoid pasting raw `query` output into issues.

## Roadmap

- Tick reminders off from the popout. Skykeep would need to expose a write path such as a
  CLI or IPC, because writing to its library directly would bypass its outbox.
- Per-list filtering
- A Control Center tile and a desktop widget
- Deep-link to a specific reminder, if Skykeep adds support for it

## License

MIT. Skykeep itself is GPL-3.0. This plugin uses none of Skykeep's code; it only reads the
library file that Skykeep creates.
