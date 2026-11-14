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
        printf 'skykeep-reminders: Skykeep is not installed\n'
        return 1
    fi
    local -a argv
    read -r -a argv <<<"$launcher"
    local log="${XDG_RUNTIME_DIR:-/tmp}/skykeep-reminders-open.log"
    printf '[%s] %s %s\n' "$(date '+%F %T')" "${argv[*]}" "$*" >>"$log"
    setsid -f "${argv[@]}" "$@" >>"$log" 2>&1 </dev/null

    # A launch from the bar carries no xdg-activation token, so compositors with
    # focus-stealing prevention (niri, Hyprland) leave an already-open Skykeep window
    # where it is. Ask the compositor to focus it instead.
    local app
    app="$(target_app "$@")" || return 0
    focus_window "$APP_ID.$app" >>"$log" 2>&1 &
    disown
}

# Which Skykeep window an argument list opens: --app reminders -> Reminders,
# --new note -> Notes, and so on. Each app has app_id io.github...Skykeep.<Name>.
target_app() {
    local -a args=()
    local a want="" i
    for a in "$@"; do # split --flag=value into --flag value
        case "$a" in --app=* | --new=*) args+=("${a%%=*}" "${a#*=}") ;; *) args+=("$a") ;; esac
    done
    for ((i = 0; i < ${#args[@]} - 1; i++)); do
        case "${args[i]}" in
            --app) want="${args[i + 1]}" ;;
            --new) case "${args[i + 1]}" in reminder) want=reminders ;; note) want=notes ;; event) want=calendar ;; esac ;;
        esac
    done
    case "$want" in
        reminders) echo Reminders ;; notes) echo Notes ;; calendar) echo Calendar ;;
        contacts) echo Contacts ;; drive|drivews) echo Drive ;; photos) echo Photos ;;
        *) return 1 ;;
    esac
}

# Focus the first window with this exact app_id, waiting up to ~5s for it to appear.
focus_window() {
    local app_id="$1" i id
    for ((i = 0; i < 25; i++)); do
        if [[ -n "${NIRI_SOCKET:-}" ]] && command -v niri >/dev/null 2>&1; then
            id="$(niri msg windows 2>/dev/null | window_id_for "$app_id")"
            [[ -n "$id" ]] && { niri msg action focus-window --id "$id"; return 0; }
        elif [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]] && command -v hyprctl >/dev/null 2>&1; then
            if hyprctl -j clients 2>/dev/null | grep -q "\"class\": \"$app_id\""; then
                hyprctl dispatch focuswindow "class:^${app_id//./\\.}\$" >/dev/null
                return 0
            fi
        else
            return 0 # unknown compositor: nothing we can do
        fi
        sleep 0.2
    done
    echo "skykeep-reminders: no $app_id window appeared to focus"
}

# Read `niri msg windows` on stdin, print the id of the window with app_id $1:
#   Window ID 30: (focused)
#     App ID: "io.github.yashwanthkamireddi.Skykeep.Reminders"
window_id_for() {
    awk -v want="$1" '
        /^Window ID / { id = $3; sub(/:$/, "", id) }
        $1 == "App" && $2 == "ID:" {
            v = $0; sub(/^[^"]*"/, "", v); sub(/"[^"]*$/, "", v)
            if (v == want) { print id; exit }
        }'
}

case "${1:-query}" in
    query)  shift || true; cmd_query "${1:-}" ;;
    open)   shift; cmd_open "$@" ;;
    locate) shift || true; locate_db "${1:-}" || { echo "not found" >&2; exit 1; } ;;
    *)      echo "usage: $0 {query [db]|open [args...]|locate [db]}" >&2; exit 2 ;;
esac
