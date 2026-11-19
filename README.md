# Skykeep Reminders for Dux / DankMaterialShell

A DankBar widget that shows your **iCloud Reminders** and lets you manage them from the
bar, using [Skykeep](https://github.com/YashwanthKamireddi/Skykeep) as the iCloud sync
engine.

- **Bar pill:** a checklist icon and a count of overdue + due-today reminders. It turns
  red when something is overdue.
- **Popout:** open reminders grouped into Overdue, Today, Next *N* days, Later and No date.
  Each row shows the list colour, due time, priority, repeat and flag.
- **Add inline:** a field at the top of the popout adds a reminder to the chosen list,
  optionally due today, this evening, tomorrow, tomorrow morning or next week, without
  opening a window (Skykeep 0.1.31+).
- **Tick off:** click the circle at the left of a row. It fills in and the reminder moves
  to *Recently completed*.
- **Undo:** a small bar under the list keeps the last change for a few seconds, with Undo.
- **Put back:** recently completed reminders are listed at the bottom; click their circle
  to restore one.
- **Open in Skykeep:** click anywhere else on a row to open Skykeep Reminders on that
  reminder, in its list.
- **Header buttons:** refresh, new reminder (the inline field when it is enabled, otherwise
  Skykeep's quick capture), and open Skykeep Reminders.
- **Right-click** the pill to open Skykeep Reminders directly.

## How it works

Skykeep syncs iCloud into a local SQLite library and keeps it current over Apple's push
channel. Reads go straight to that library; writes go back through Skykeep. The plugin
never talks to Apple and never writes to `library.db` itself.

```
Skykeep app ⇄ iCloud
     │ writes
     ▼
library.db ──(sqlite3, read-only)──▶ skykeep-reminders.sh query ──JSON──▶ DankBar widget

DankBar widget ──▶ skykeep --complete-reminder <id>     ┐
                ──▶ skykeep --uncomplete-reminder <id>   ├─▶ Skykeep outbox ──▶ iCloud
                ──▶ skykeep --app reminders --reminder <id>
                ──▶ skykeep --create-reminder=<title> --list <list-id> [--due <s> [--all-day]]
```

Ticking and restoring use [Skykeep's command line](https://github.com/YashwanthKamireddi/Skykeep/issues/35)
(0.1.24+). Skykeep records the change in its outbox the same way an edit made in Reminders
does, so it reaches iCloud and your other devices. If Skykeep is already running the call
is handed to it and the new process exits at once; if it isn't, Skykeep starts in the tray
and sends the change. Completing a repeating reminder moves it on to its next date, as it
does in Skykeep.

Creating a reminder uses the same idea through `--create-reminder`, part of the command
line Skykeep 0.1.31 opened to other programs ([docs/cli.md](https://github.com/YashwanthKamireddi/Skykeep/blob/main/docs/cli.md)).
On an older Skykeep, turn off **Add reminders from the popout**: that build would open
its main window instead, and `+` then opens Skykeep's quick-capture window.

The helper looks for the library in these places, in order:

| Install | Path |
|---|---|
| Native / AppImage / AUR | `$XDG_DATA_HOME/io.github.yashwanthkamireddi.Skykeep/library.db` |
| Flatpak | `~/.var/app/io.github.yashwanthkamireddi.Skykeep/data/…/library.db` |
| Snap | `~/snap/skykeep/{current,common}/.local/share/…/library.db` |

You can override the path in the plugin settings.

To launch Skykeep, the helper uses `skykeep` from `PATH`. If that isn't found, it reads the
`Exec=` line from `Skykeep.desktop`, which covers AppImage installs.

A launch from the bar carries no xdg-activation token. On niri and Hyprland, that means an
already-open Skykeep window would stay where it is without taking focus. To handle this, the
helper waits for the window, matched by app_id `io.github.yashwanthkamireddi.Skykeep.<App>`,
and focuses it through `niri msg` or `hyprctl`. Launch output is logged to
`$XDG_RUNTIME_DIR/skykeep-reminders-open.log`.

## Requirements

- Dux / DankMaterialShell ≥ 2.0
- Skykeep **≥ 0.1.24**, installed and signed in at least once. The read-only list works with
  older versions; ticking, restoring and opening a specific reminder need 0.1.24.
  Adding from the popout needs 0.1.31.
- `sqlite3` and `bash`

## Install

```sh
dms plugins install skykeepReminders   # once it is listed in the registry
# or manually:
git clone https://github.com/Dukko/dms-skykeep-reminders ~/.config/dms/plugins/skykeepReminders
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
| Add reminders from the popout | on | inline add field; needs Skykeep 0.1.31+ |
| Show recently completed | on | the section that lets you put a tick back |
| Recently completed window | 24 h | 1 h – 7 days |
| Show "Reminders" label | off | |
| Hide when nothing to count | off | hides the pill when the count is 0 |
| Library path | auto | override for unusual installs |

## Development

```sh
scripts/skykeep-reminders.sh locate                  # which library.db will be used
scripts/skykeep-reminders.sh query | jq              # what the widget sees
scripts/skykeep-reminders.sh complete   <id>         # tick it off
scripts/skykeep-reminders.sh uncomplete <id>         # put it back
scripts/skykeep-reminders.sh show       <id>         # open it in Skykeep
scripts/skykeep-reminders.sh create "Buy milk" "List/…" # add one (0.1.31+)
scripts/skykeep-reminders.sh create "Call" "List/…" "$(date -d 'tomorrow 9:00' +%s)" 0
scripts/skykeep-reminders.sh open --app reminders
```

`<id>` is a reminder's `guid` from the query output. Reminder titles are your data. Avoid
pasting raw `query` output into issues.

## Roadmap

- Edit reminder titles and dates in the popout
- Per-list filtering
- A Control Center tile and a desktop widget
- Snooze and due-date changes, if Skykeep exposes them on the command line

## License

MIT. Skykeep itself is GPL-3.0. This plugin uses none of Skykeep's code; it reads the
library file that Skykeep creates and calls the command line Skykeep ships.
