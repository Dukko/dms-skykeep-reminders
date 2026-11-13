#!/usr/bin/env bash
# Helper for the Skykeep Reminders DMS/Dux plugin.
#
#   skykeep-reminders.sh query [DB_PATH]   Print open iCloud reminders as one JSON object.
#   skykeep-reminders.sh open  [ARGS...]   Launch Skykeep detached (e.g. --app reminders).
#   skykeep-reminders.sh locate            Print the library.db path that would be used.
#
# Skykeep keeps every account in a local SQLite library and syncs it with iCloud in the
# background. This script only ever opens that library read-only; it never talks to Apple
# and never writes.

set -uo pipefail

APP_ID="io.github.yashwanthkamireddi.Skykeep"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"

json_error() {
    # $1: machine code, $2: human message (must not contain double quotes)
    printf '{"ok":false,"code":"%s","error":"%s"}\n' "$1" "$2"
}

locate_db() {
    local override="${1:-}"
    if [[ -n "$override" ]]; then
        override="${override/#\~/$HOME}"
        [[ -f "$override" ]] && { printf '%s\n' "$override"; return 0; }
        return 1
    fi
    local candidates=(
        "$DATA_HOME/$APP_ID/library.db"
        "$HOME/.var/app/$APP_ID/data/$APP_ID/library.db"
        "$HOME/snap/skykeep/current/.local/share/$APP_ID/library.db"
        "$HOME/snap/skykeep/common/.local/share/$APP_ID/library.db"
    )
    local c
    for c in "${candidates[@]}"; do
        [[ -f "$c" ]] && { printf '%s\n' "$c"; return 0; }
    done
    return 1
}

cmd_query() {
    if ! command -v sqlite3 >/dev/null 2>&1; then
        json_error "no_sqlite" "sqlite3 is not installed"
        return 0
    fi
    local db
    if ! db="$(locate_db "${1:-}")"; then
        json_error "no_library" "Skykeep library not found. Install Skykeep and sign in, or set the library path in the plugin settings."
        return 0
    fi

    # One row, one JSON object, even when there are no reminders. Lists the user has
    # turned off in Skykeep are skipped. Ordering: dated first by due time, then undated.
    local sql="
        SELECT json_object(
            'ok', json('true'),
            'generatedAt', CAST(strftime('%s','now') AS INTEGER),
            'reminders', (
                SELECT COALESCE(json_group_array(json(obj)), json('[]')) FROM (
                    SELECT json_object(
                        'id',       r.guid,
                        'title',    r.title,
                        'list',     l.title,
                        'colour',   l.colour,
                        'due',      r.due_at,
                        'allDay',   r.all_day,
                        'flagged',  r.flagged,
                        'priority', r.priority,
                        'subtask',  r.parent_guid IS NOT NULL,
                        'repeats',  r.recur_frequency IS NOT NULL
                    ) AS obj
                    FROM reminders r
                    JOIN reminder_lists l ON l.guid = r.list_guid
                    WHERE r.completed_at IS NULL AND l.enabled = 1
                    ORDER BY r.due_at IS NULL, r.due_at, r.flagged DESC, r.priority DESC, r.title
                    LIMIT 500
                )
            )
        );"

    local out
    # 'file:...?mode=ro' plus -readonly: never take a write lock on Skykeep's library.
    # busy_timeout covers the moment Skykeep is checkpointing its WAL.
    if ! out="$(sqlite3 -readonly -batch -noheader \
            -cmd ".timeout 2000" \
            "file:${db}?mode=ro" "$sql" 2>&1)"; then
        json_error "query_failed" "Could not read the Skykeep library"
        printf 'skykeep-reminders: %s\n' "$out" >&2
        return 0
    fi
    printf '%s\n' "$out"
}

# Resolve how to launch Skykeep: a binary on PATH (packages, snap), else the Exec line
# of its desktop entry (AppImage installs, flatpak exports).
skykeep_command() {
    if command -v skykeep >/dev/null 2>&1; then
        printf '%s\n' "skykeep"
        return 0
    fi
    local dirs=("$DATA_HOME/applications" "$DATA_HOME/flatpak/exports/share/applications"
                "/var/lib/flatpak/exports/share/applications")
    local IFS=:
    local d
    for d in ${XDG_DATA_DIRS:-/usr/local/share:/usr/share}; do dirs+=("$d/applications"); done
    unset IFS
    local f exec_line
    for d in "${dirs[@]}"; do
        for f in "$d/Skykeep.desktop" "$d/$APP_ID.desktop" "$d/skykeep.desktop"; do
            [[ -f "$f" ]] || continue
            # First Exec= belongs to [Desktop Entry]; drop field codes like %U.
            exec_line="$(grep -m1 '^Exec=' "$f" | sed -e 's/^Exec=//' -e 's/ *%[a-zA-Z]//g')"
            [[ -n "$exec_line" ]] && { printf '%s\n' "$exec_line"; return 0; }
        done
    done
    return 1
}

cmd_open() {
    local launcher
    if ! launcher="$(skykeep_command)"; then
        printf 'skykeep-reminders: Skykeep is not installed\n' >&2
        return 1
    fi
    local -a argv
    read -r -a argv <<<"$launcher"
    setsid -f "${argv[@]}" "$@" >/dev/null 2>&1 </dev/null
}

case "${1:-query}" in
    query)  shift || true; cmd_query "${1:-}" ;;
    open)   shift; cmd_open "$@" ;;
    locate) shift || true; locate_db "${1:-}" || { echo "not found" >&2; exit 1; } ;;
    *)      echo "usage: $0 {query [db]|open [args...]|locate [db]}" >&2; exit 2 ;;
esac
