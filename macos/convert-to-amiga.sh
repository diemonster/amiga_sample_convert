#!/bin/zsh
#
# convert-to-amiga.sh
#
# Wrapper for amiga_sample_convert.sh, designed to be called from a macOS
# Quick Action / Service / Folder Action / Shortcut.
#
# GUI-launched shells don't inherit your interactive PATH, so Homebrew tools
# like sox aren't visible. We fix that here, then forward all arguments to
# the main converter.
#
# Pass extra converter flags via the AMIGA_CONVERT_FLAGS env var if you want
# to specialize this wrapper (the -P24 sibling script is an example).

set -e

# Homebrew on Apple Silicon is /opt/homebrew, on Intel /usr/local.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"

# Resolve the directory of this script so we can find its sibling converter
# even if the script is invoked via a symlink in ~/Library/Services.
script_dir="${0:A:h}"
converter="${script_dir}/../amiga_sample_convert.sh"

if [[ ! -x "$converter" ]]; then
    echo "Error: converter not found or not executable: $converter" >&2
    echo "Make sure the macos/ directory is alongside amiga_sample_convert.sh" >&2
    exit 1
fi

# Surface output in a plain log file so right-click conversions aren't
# silent. We deliberately use a fixed path under $HOME rather than
# $TMPDIR — Quick Actions / Shortcuts can run under a sandboxed TMPDIR
# that points to a per-app container the user can't easily find, which
# makes "tail the log" advice unhelpful. ~/Library/Logs is the canonical
# spot for app-style logs on macOS and is visible from Console.app.
log_dir="${HOME}/Library/Logs"
log_file="${log_dir}/amiga_sample_convert.log"
mkdir -p "$log_dir"
{
    echo ""
    echo "── $(date '+%Y-%m-%d %H:%M:%S') ──"
    echo "pwd: $(pwd)"
    echo "user: $(id -un) ($(id -u))"
    echo "args: $*"
    echo "extra flags: ${AMIGA_CONVERT_FLAGS:-(none)}"
    "$converter" ${=AMIGA_CONVERT_FLAGS:-} "$@"
} >> "$log_file" 2>&1
