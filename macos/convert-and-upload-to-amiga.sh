#!/bin/zsh
#
# convert-and-upload-to-amiga.sh
#
# Convert audio files via amiga_sample_convert.sh AND upload the resulting
# .iff files to a configurable SMB share (e.g. a MiSTer's sd-card mount).
# Designed to be called from a macOS Quick Action / Shortcut so the entire
# "audio file → Amiga sample loaded on hardware" round-trip fits in one
# right-click.
#
# Configuration, in order of precedence (highest first):
#   1. AMIGA_SMB_URL env var
#   2. ~/.config/amiga_sample_convert/config (a zsh-sourceable file that
#      can set AMIGA_SMB_URL and/or AMIGA_CONVERT_FLAGS)
#   3. Built-in default (see below)
#
# AMIGA_SMB_URL accepts a full smb:// URL with optional user@ and an
# arbitrary subpath inside the share, e.g.
#   smb://mister/sdcard/games/Amiga/shared/samples
#   smb://user@nas.local/Music/AmigaSamples
#
# Mounting uses AppleScript's `mount volume`, which:
#   - reuses macOS Keychain credentials transparently when present
#   - falls back to a GUI prompt the first time you connect
#   - is safe to call when the share is already mounted (it's a no-op)
#
# The destination directory inside the share is created if missing, so a
# fresh MiSTer with no `.../samples/` folder yet still works on first run.

set -e

# zsh/system gives us sysread/syswrite — raw byte I/O via shell builtins.
# We use these instead of /bin/cp for the upload step (see comment near
# the upload loop for why).
zmodload zsh/system

# ─── config ─────────────────────────────────────────────────────────────────

DEFAULT_SMB_URL="smb://mister/sdcard/games/Amiga/shared/samples"

config_file="${HOME}/.config/amiga_sample_convert/config"
if [[ -f "$config_file" ]]; then
    # shellcheck disable=SC1090
    source "$config_file"
fi

: ${AMIGA_SMB_URL:=$DEFAULT_SMB_URL}

# ─── byte copy via shell builtins ───────────────────────────────────────────
#
# Why not /bin/cp? When invoked from a Shortcut, macOS TCC gives us read
# access to the input file (and lets sox produce siblings next to it) but
# *separate* binaries like cp need their own Files-and-Folders entitlement
# to traverse protected dirs (Desktop / Documents / Downloads / iCloud).
# Using cp triggers EPERM there. zsh's sysread/syswrite stay inside this
# script's own process, which already has the necessary access, so they
# work for any source the script could see in the first place.

copy_file() {
    local src="$1" dst="$2"
    local buf
    {
        while sysread buf; do
            syswrite -- "$buf" || return 1
        done
    } < "$src" > "$dst"
}

# ─── environment ────────────────────────────────────────────────────────────

# GUI-launched shells don't inherit interactive PATH; Homebrew tools live in
# /opt/homebrew (Apple Silicon) or /usr/local (Intel).
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"

script_dir="${0:A:h}"
converter="${script_dir}/../amiga_sample_convert.sh"

if [[ ! -x "$converter" ]]; then
    echo "Error: converter not found or not executable: $converter" >&2
    exit 1
fi

log_dir="${HOME}/Library/Logs"
log_file="${log_dir}/amiga_sample_convert.log"
mkdir -p "$log_dir"

# ─── SMB URL parser ─────────────────────────────────────────────────────────
#
# Splits the configured URL into:
#   SMB_MOUNT_URL   : URL passed to AppleScript `mount volume`
#                     (smb://[user@]host/share — without subpath, since
#                     macOS mounts at the share root)
#   SMB_MOUNT_POINT : where macOS will mount it (/Volumes/<share>)
#   SMB_TARGET_DIR  : final destination directory we copy into
#                     (mount point + any subpath in the URL)

parse_smb_url() {
    local url="$1"
    local rest="${url#smb://}"
    if [[ "$rest" == "$url" ]]; then
        echo "Error: AMIGA_SMB_URL must start with smb://: $url" >&2
        return 1
    fi

    local user_host_prefix=""
    if [[ "$rest" == *"@"* ]]; then
        user_host_prefix="${rest%%@*}@"
        rest="${rest#*@}"
    fi

    local host="${rest%%/*}"
    local path_part=""
    if [[ "$rest" == */* ]]; then
        path_part="${rest#*/}"
    fi

    if [[ -z "$host" || -z "$path_part" ]]; then
        echo "Error: AMIGA_SMB_URL must include both host and share: $url" >&2
        return 1
    fi

    local share="${path_part%%/*}"
    local subpath=""
    if [[ "$path_part" == */* ]]; then
        subpath="${path_part#*/}"
    fi

    SMB_MOUNT_URL="smb://${user_host_prefix}${host}/${share}"
    SMB_MOUNT_POINT="/Volumes/${share}"
    if [[ -n "$subpath" ]]; then
        SMB_TARGET_DIR="${SMB_MOUNT_POINT}/${subpath}"
    else
        SMB_TARGET_DIR="$SMB_MOUNT_POINT"
    fi
}

# ─── mount handling ─────────────────────────────────────────────────────────

is_mounted() {
    # macOS `mount` output: "//user@host/share on /Volumes/share (smbfs, ...)"
    /sbin/mount | /usr/bin/grep -q " on ${SMB_MOUNT_POINT} "
}

ensure_mounted() {
    if is_mounted; then
        return 0
    fi
    # `mount volume` is idempotent and uses keychain creds when available.
    # Errors are surfaced via the AppleScript exit status, which we treat
    # as fatal here (no point continuing if we can't reach the share).
    /usr/bin/osascript -e "mount volume \"${SMB_MOUNT_URL}\"" >/dev/null 2>&1 || return 1

    # Mount appears asynchronously; poll briefly for it to register.
    local i=0
    while ! is_mounted && (( i < 40 )); do
        /bin/sleep 0.25
        ((i++))
    done
    is_mounted
}

# ─── run ────────────────────────────────────────────────────────────────────

{
    echo ""
    echo "── $(date '+%Y-%m-%d %H:%M:%S') ──"
    echo "mode: convert + SMB upload"
    echo "user: $(id -un) ($(id -u))"
    echo "smb url: $AMIGA_SMB_URL"
    echo "extra flags: ${AMIGA_CONVERT_FLAGS:-(none)}"
    echo "args: $*"

    if ! parse_smb_url "$AMIGA_SMB_URL"; then
        exit 1
    fi
    echo "mount url: $SMB_MOUNT_URL"
    echo "mount point: $SMB_MOUNT_POINT"
    echo "target dir: $SMB_TARGET_DIR"

    if ! ensure_mounted; then
        echo "Error: failed to mount $SMB_MOUNT_URL"
        echo "(check the URL, your network, and macOS Keychain credentials)"
        exit 1
    fi

    # Create the target subdirectory if missing. Failure is fatal — likely
    # a permission problem on the share that we can't fix automatically.
    if [[ ! -d "$SMB_TARGET_DIR" ]]; then
        mkdir -p "$SMB_TARGET_DIR" || {
            echo "Error: cannot create $SMB_TARGET_DIR (permission denied?)"
            exit 1
        }
    fi

    # Run the converter, directing all .iff output into a script-owned
    # tmp dir (-o flag). Why not let it write alongside the source as
    # usual? When the Shortcut input lives in a TCC-protected location
    # like ~/Desktop, ~/Documents, ~/Downloads, or iCloud Drive, macOS
    # only grants this script read access to the *exact* paths Shortcuts
    # passed in. The .iff sibling sox creates next to them inherits no
    # such grant, so we can't read it back to upload — even from this
    # script's own shell. Writing into our tmp dir sidesteps the whole
    # issue: tmp is always readable, and the manifest captures the tmp
    # paths directly.
    #
    # Side effect: the upload wrapper does NOT leave a local .iff next
    # to the source. Use the non-upload Quick Action for that.
    tmp_outdir=$(/usr/bin/mktemp -d -t amiga_outdir)
    manifest=$(/usr/bin/mktemp -t amiga_manifest)
    trap 'rm -rf "$tmp_outdir" "$manifest"' EXIT

    AMIGA_OUTPUT_MANIFEST="$manifest" \
        "$converter" -o "$tmp_outdir" ${=AMIGA_CONVERT_FLAGS:-} "$@"

    if [[ ! -s "$manifest" ]]; then
        echo "(no .iff files produced; nothing to upload)"
        exit 0
    fi

    echo ""
    echo "Uploading to ${SMB_TARGET_DIR}/ ..."
    upload_count=0
    upload_failed=0
    while IFS= read -r iff_path; do
        [[ -z "$iff_path" ]] && continue
        if [[ ! -f "$iff_path" ]]; then
            echo "  (missing, skipping): $iff_path"
            ((upload_failed++)) || true
            continue
        fi
        # Use shell-builtin byte copy (see copy_file above) rather than
        # /bin/cp so this works on protected dirs like ~/Desktop.
        local dest="${SMB_TARGET_DIR}/${iff_path:t}"
        if copy_file "$iff_path" "$dest"; then
            echo "  ✓ ${iff_path:t}"
            ((upload_count++)) || true
        else
            echo "  ✗ failed: ${iff_path:t}"
            ((upload_failed++)) || true
        fi
    done < "$manifest"

    echo "Uploaded ${upload_count} file(s) to ${SMB_TARGET_DIR}/"
    if (( upload_failed > 0 )); then
        echo "Warning: ${upload_failed} upload(s) failed."
        exit 1
    fi
    exit 0

} >> "$log_file" 2>&1
