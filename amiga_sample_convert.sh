#!/usr/bin/env bash
#
# amiga_sample_convert.sh
# Convert WAV/AIFF/etc to IFF 8SVX format for OctaMED 4 on Amiga
#
# Requires: sox (brew install sox)
#
# Usage:
#   ./amiga_sample_convert.sh [options] input_file [output_file]
#
# Options:
#   -r RATE    Target sample rate in Hz (default: 22050)
#              Common Amiga rates:
#                8363  - ProTracker C-3 standard (low quality, saves memory)
#                11025 - Telephony standard
#                16726 - 2x ProTracker C-3 (conservative, smaller files)
#                22050 - CD/2 (high quality, good default)
#                27928 - 4x ProTracker C-3 (near max safe rate for PAL)
#              Note: Paula is fixed 8-bit; rate is the primary quality lever.
#              MiSTer Minimig can be configured with 2MB chip RAM, so higher
#              rates are usually worth it for any percussive or tonal material.
#   -n         Normalize audio to 0 dBFS before conversion
#   -g GAIN    Apply gain in dB before conversion (e.g., -3, +6)
#   -f FREQ    Manual anti-alias LPF cutoff in Hz (default: auto Nyquist-based)
#   -l         Apply Amiga-style low-pass at 4.9 kHz (emulates A500 always-on
#              output filter, 6 dB/oct). Use -f 3300 for the switchable
#              "LED filter" instead. Skip this if your MiSTer Minimig core
#              already has A500 filtering enabled (double-filtering sounds bad).
#   -t         Trim silence from start and end (threshold: -48 dB)
#   -d         Use TPDF dither when reducing to 8-bit (default: on)
#   -D         Disable dither (truncate to 8-bit)
#   -P SEMI    Pre-pitch sample UP by SEMI semitones before conversion.
#              In OctaMED, play SEMI semitones LOWER than normal to restore
#              original pitch. This forces Paula to play samples at a lower
#              rate, reducing Nyquist and allowing HF content to fold back
#              as aliasing — the classic crunchy Amiga jungle/breakcore sound.
#              Examples:
#                -P 12  → pitch up 1 octave, play at C-2 (was C-3)
#                -P 24  → pitch up 2 octaves, play at C-1 (was C-3)
#                -P 7   → pitch up a fifth, play 7 semis lower
#              Auto-disables anti-alias LPF (-l, -f) since aliasing is the goal.
#              Uses sox's `speed` effect (raw resample, like tape speed-up):
#              +12 semis halves the sample's duration. The pitch cancels out
#              when you play it back at a lower note in OctaMED, but Paula's
#              nearest-neighbor playback math generates the aliasing on the
#              way. This matches authentic Amiga/sampler workflow — we avoid
#              sox's `pitch` effect because its phase vocoder adds audible
#              cyclic window artifacts that aren't musically useful here.
#   -V SEMI    Vocoder-pitch shift (duration-preserving phase vocoder).
#              Like -P but uses sox's `pitch` effect, which preserves sample
#              duration at the cost of cyclic window-crossfade artifacts.
#              That glitchy, warbly, "time-stretched" texture is itself a
#              distinctive sound — useful for IDM, breakcore pads, and
#              vaporwave-adjacent textures. Play the sample at its original
#              note in OctaMED (no pitch compensation needed).
#              Examples:
#                -V 12  → pitched up 1 octave, plays at C-3 still, warbly
#                -V -5  → pitched down 5 semis, duration unchanged
#              Auto-disables anti-alias LPF like -P does.
#              Mutually exclusive with -P.
#   -p         Preview: print file info and conversion plan, don't convert
#   -b         Batch mode: treat all non-option args as input files
#              (auto-enabled when a directory is passed, or when more than
#              two input paths are given)
#   -o DIR     Output directory for batch mode. If omitted, each converted
#              sample is written to the SAME directory as its source file.
#              Input paths may be individual files, directories (all audio
#              files inside are processed non-recursively), or shell globs.
#   --self-test Run smoke tests to verify the conversion pipeline
#   -h         Show this help
#
# OctaMED 4 notes:
#   - Uses IFF 8SVX format (8-bit signed mono PCM)
#   - Max sample memory depends on your Amiga's chip RAM
#   - OctaMED supports up to 8 channels (4 hardware + 4 software-mixed)
#   - For best results, tune your sample rate to match the note you'll play
#     at most often. 16726 Hz gives clean playback at C-3 on PAL Amiga.
#   - Samples can be looped in OctaMED; this script preserves no loop points.
#     Set loops in OctaMED's sample editor after loading.

set -euo pipefail

# ─── defaults ───────────────────────────────────────────────────────────────

SAMPLE_RATE=22050
NORMALIZE=false
GAIN=""
LPF_CUTOFF=""
AMIGA_LPF=false
TRIM_SILENCE=false
DITHER=true
PREPITCH_SEMITONES=0
VOCODER_SEMITONES=0
PREVIEW=false
BATCH=false
OUT_DIR=""
OUT_DIR_EXPLICIT=false

# Audio extensions we'll pick up when a directory is passed as input.
AUDIO_EXTS=(wav wave aif aiff aifc flac mp3 ogg oga opus m4a mp4 caf au snd w64 voc)

# ─── colors (if terminal) ──────────────────────────────────────────────────

if [[ -t 1 ]]; then
    BOLD='\033[1m'
    DIM='\033[2m'
    GREEN='\033[32m'
    YELLOW='\033[33m'
    RED='\033[31m'
    CYAN='\033[36m'
    RESET='\033[0m'
else
    BOLD='' DIM='' GREEN='' YELLOW='' RED='' CYAN='' RESET=''
fi

# ─── helpers ────────────────────────────────────────────────────────────────

die()  { echo -e "${RED}Error:${RESET} $*" >&2; exit 1; }
warn() { echo -e "${YELLOW}Warning:${RESET} $*" >&2; }
info() { echo -e "${CYAN}→${RESET} $*"; }

# Convert semitones to a human-readable target note relative to C-3
semitones_to_playback_hint() {
    local semis=$1
    # OctaMED note naming: C-1, C#1, D-1, ..., C-2, ..., C-5
    local notes=("C-" "C#" "D-" "D#" "E-" "F-" "F#" "G-" "G#" "A-" "A#" "B-")
    # C-3 is reference. Going DOWN by $semis semitones from C-3.
    # Semitone number of C-3 in semitones from C-0: 3*12 = 36
    local c3_abs=36
    local target_abs=$((c3_abs - semis))
    if (( target_abs < 0 )); then
        echo "below playable range"
        return
    fi
    local octave=$((target_abs / 12))
    local note_idx=$((target_abs % 12))
    echo "${notes[$note_idx]}${octave}"
}

usage() {
    sed -nE '/^# Usage:/,/^# Options:/{ /^# Options:/!s/^# ?//p; }' "$0"
    echo ""
    sed -nE '/^# Options:/,/^# OctaMED/{ /^# OctaMED/!s/^# ?//p; }' "$0"
    echo ""
    sed -nE '/^# OctaMED 4 notes:/,/^[^#]/{ /^#/s/^# ?//p; }' "$0"
    exit 0
}

check_deps() {
    if ! command -v sox &>/dev/null; then
        die "sox not found. Install it with: brew install sox"
    fi
}

# ─── IFF 8SVX writer ───────────────────────────────────────────────────────
#
# We construct the IFF 8SVX file using Python's struct module for reliable
# big-endian binary output. This avoids depending on xxd and handles the
# IFF container format correctly.
#
# IFF 8SVX structure:
#   FORM <size> 8SVX
#     VHDR <20>
#       oneShotHiSamples : ULONG  (number of samples in one-shot part)
#       repeatHiSamples  : ULONG  (0 = no loop)
#       samplesPerHiCycle: ULONG  (0 = not applicable)
#       samplesPerSec    : UWORD  (sample rate)
#       ctOctave         : UBYTE  (1)
#       sCompression     : UBYTE  (0 = none)
#       volume           : ULONG  (0x00010000 = 1.0 in 16.16 fixed point)
#     BODY <size>
#       <raw 8-bit signed PCM data>

write_8svx() {
    local raw_file="$1"
    local out_file="$2"
    local sample_rate="$3"

    python3 - "$raw_file" "$out_file" "$sample_rate" << 'PYEOF'
import struct, sys, os

raw_file, out_file, sample_rate = sys.argv[1], sys.argv[2], int(sys.argv[3])

raw_data = open(raw_file, "rb").read()
body_size = len(raw_data)

# IFF chunks must be even-length; pad BODY if needed
body_pad = body_size % 2

vhdr_size = 20
# FORM payload = "8SVX"(4) + VHDR chunk(8+20) + BODY chunk(8+body+pad)
form_payload = 4 + (8 + vhdr_size) + (8 + body_size + body_pad)

with open(out_file, "wb") as f:
    # FORM header
    f.write(b"FORM")
    f.write(struct.pack(">I", form_payload))
    f.write(b"8SVX")

    # VHDR chunk
    f.write(b"VHDR")
    f.write(struct.pack(">I", vhdr_size))
    f.write(struct.pack(">I", body_size))       # oneShotHiSamples
    f.write(struct.pack(">I", 0))               # repeatHiSamples
    f.write(struct.pack(">I", 0))               # samplesPerHiCycle
    f.write(struct.pack(">H", sample_rate))     # samplesPerSec
    f.write(struct.pack("B", 1))                # ctOctave
    f.write(struct.pack("B", 0))                # sCompression
    f.write(struct.pack(">I", 0x00010000))      # volume = 1.0 fixed-point

    # BODY chunk
    f.write(b"BODY")
    f.write(struct.pack(">I", body_size))
    f.write(raw_data)
    if body_pad:
        f.write(b"\x00")
PYEOF
}

# ─── file info ──────────────────────────────────────────────────────────────

print_info() {
    local file="$1"
    echo -e "${BOLD}Source:${RESET} $(basename "$file")"
    soxi "$file" 2>/dev/null | grep -E '(Channels|Sample Rate|Precision|Duration|Bit Rate|Sample Encoding)' | \
        sed "s/^/  ${DIM}/${RESET}/"
    local src_rate src_bits src_chans
    src_rate=$(soxi -r "$file" 2>/dev/null)
    src_bits=$(soxi -b "$file" 2>/dev/null)
    src_chans=$(soxi -c "$file" 2>/dev/null)
    local src_samples
    src_samples=$(soxi -s "$file" 2>/dev/null)

    echo -e "  ${DIM}Samples:     ${src_samples}${RESET}"

    # estimate output size
    local est_samples
    est_samples=$(python3 -c "import math; print(math.ceil($src_samples * $SAMPLE_RATE / $src_rate))" 2>/dev/null || echo "?")
    if [[ "$est_samples" != "?" ]]; then
        local est_bytes=$est_samples
        local est_kb
        est_kb=$(python3 -c "print(f'{$est_bytes / 1024:.1f}')" 2>/dev/null || echo "?")
        echo ""
        echo -e "${BOLD}Conversion plan:${RESET}"
        echo -e "  ${src_rate} Hz ${src_bits}-bit ${src_chans}ch → ${SAMPLE_RATE} Hz 8-bit mono"
        echo -e "  Estimated output: ~${est_samples} samples (${est_kb} KB)"
        echo -e "  Dither: $(${DITHER} && echo 'TPDF' || echo 'off (truncate)')"
        echo -e "  Normalize: ${NORMALIZE}"
        [[ -n "$GAIN" ]] && echo -e "  Gain: ${GAIN} dB"
        [[ -n "$LPF_CUTOFF" ]] && echo -e "  LPF cutoff: ${LPF_CUTOFF} Hz"
        ${AMIGA_LPF} && echo -e "  A500-style LPF: yes (4.9 kHz always-on filter)"
        ${TRIM_SILENCE} && echo -e "  Trim silence: yes"
        if (( PREPITCH_SEMITONES != 0 )); then
            local hint
            hint=$(semitones_to_playback_hint "$PREPITCH_SEMITONES")
            echo -e "  ${YELLOW}Pre-pitch: +${PREPITCH_SEMITONES} semitones (play at ${hint} in OctaMED to restore pitch)${RESET}"
            echo -e "  ${YELLOW}Anti-alias LPF: disabled (aliasing is the goal)${RESET}"
        fi
        if (( VOCODER_SEMITONES != 0 )); then
            local sign=""
            (( VOCODER_SEMITONES > 0 )) && sign="+"
            echo -e "  ${YELLOW}Vocoder pitch: ${sign}${VOCODER_SEMITONES} semitones (duration preserved, warbly artifacts)${RESET}"
            echo -e "  ${YELLOW}Anti-alias LPF: disabled${RESET}"
        fi

        # chip RAM context
        if (( est_bytes > 512000 )); then
            warn "Output exceeds 500 KB — will consume significant chip RAM on a stock Amiga"
        fi
    fi
}

# ─── convert one file ──────────────────────────────────────────────────────

convert_file() {
    local input="$1"
    local output="$2"

    [[ -f "$input" ]] || die "Input file not found: $input"

    local tmpdir
    tmpdir=$(mktemp -d)
    trap "rm -rf '$tmpdir'" EXIT

    local raw_out="${tmpdir}/output.raw"

    # build sox effects chain
    local effects=()

    # downmix to mono by averaging (preserves loudness, unlike `remix -`
    # which sums channels and can clip correlated stereo material)
    local src_chans
    src_chans=$(soxi -c "$input" 2>/dev/null) || die "Cannot read input file: $input"
    if (( src_chans > 1 )); then
        effects+=(channels 1)
    fi

    # trim silence
    if ${TRIM_SILENCE}; then
        effects+=(silence 1 0.01 -48d reverse silence 1 0.01 -48d reverse)
    fi

    # gain / normalize
    if ${NORMALIZE}; then
        effects+=(gain -n)
    elif [[ -n "$GAIN" ]]; then
        effects+=(gain "$GAIN")
    fi

    # 1 dB headroom before resampling. Normalized or near-full-scale material
    # produces inter-sample peaks during sinc interpolation; trimming 1 dB
    # here prevents sox's internal rate stage from clipping, and also leaves
    # room so the final 8-bit truncation (±127) doesn't hard-clip either.
    effects+=(gain -1)

    # Pre-pitch shift (for intentional aliasing on playback).
    # `speed` resamples the audio straight — pitch up = duration down.
    # This is the authentic Amiga workflow: pitch-shift by resampling at
    # the source, then let Paula do its zero-interpolation nearest-neighbor
    # resampling on playback. The aliasing/crunch comes from Paula's
    # playback math, not from any time-stretching artifacts.
    #
    # We explicitly do NOT use sox's `pitch` effect — that uses a phase
    # vocoder that creates audible cyclic window-crossfade artifacts,
    # which defeat the authentic sound we're going for.
    #
    # speed factor = 2^(semitones/12), e.g. +12 semis = 2.0x
    # Must happen BEFORE the rate conversion stage.
    if (( PREPITCH_SEMITONES != 0 )); then
        local speed_factor
        speed_factor=$(python3 -c "print(2 ** ($PREPITCH_SEMITONES / 12.0))")
        effects+=(speed "$speed_factor")
    fi

    # Vocoder-style pitch shift (for glitchy, warbly texture).
    # Uses sox's `pitch` effect which IS a phase vocoder — preserves
    # duration at the cost of cyclic window artifacts. Those artifacts
    # are the feature, not a bug. Argument is in cents (semitones × 100).
    if (( VOCODER_SEMITONES != 0 )); then
        local cents=$((VOCODER_SEMITONES * 100))
        effects+=(pitch "$cents")
    fi

    # resample to target rate with very-high-quality sinc interpolation
    local src_rate
    src_rate=$(soxi -r "$input" 2>/dev/null)
    if (( src_rate != SAMPLE_RATE )); then
        effects+=(rate -v "$SAMPLE_RATE")
    fi

    # optional Amiga-style low-pass (A500 always-on filter, ~4.9 kHz, 6 dB/oct)
    # For the switchable "LED filter" effect, pass -f 3300 instead.
    # Auto-disabled when pre-pitching or vocoder-pitching, since the pitch
    # effects are creative and LPF would defeat them.
    if ${AMIGA_LPF} && (( PREPITCH_SEMITONES == 0 )) && (( VOCODER_SEMITONES == 0 )); then
        effects+=(lowpass 4900)
    fi

    # manual LPF override — also skipped during pitch effects
    if [[ -n "$LPF_CUTOFF" ]] && (( PREPITCH_SEMITONES == 0 )) && (( VOCODER_SEMITONES == 0 )); then
        effects+=(lowpass "$LPF_CUTOFF")
    fi

    # dither (TPDF — better suited than noise-shaped dither for 8-bit,
    # where we don't have enough resolution to carry HF shaped noise cleanly)
    if ${DITHER}; then
        effects+=(dither)
    fi

    info "Converting: $(basename "$input")"
    info "  → ${SAMPLE_RATE} Hz, 8-bit signed mono"
    if (( PREPITCH_SEMITONES != 0 )); then
        local hint
        hint=$(semitones_to_playback_hint "$PREPITCH_SEMITONES")
        info "  → pre-pitched +${PREPITCH_SEMITONES} semis; play at ${hint} in OctaMED"
    fi
    if (( VOCODER_SEMITONES != 0 )); then
        local sign=""
        (( VOCODER_SEMITONES > 0 )) && sign="+"
        info "  → vocoder-pitched ${sign}${VOCODER_SEMITONES} semis (duration preserved); play at C-3"
    fi

    # run sox: output as raw signed 8-bit.
    # Rate and channels are handled by the effects chain, not the output
    # format spec, so intent is unambiguous and sox doesn't double-convert.
    sox "$input" \
        --encoding signed-integer \
        --bits 8 \
        --type raw \
        "$raw_out" \
        ${effects[@]+"${effects[@]}"}

    # wrap in IFF 8SVX
    write_8svx "$raw_out" "$output" "$SAMPLE_RATE"

    local out_size
    out_size=$(stat -f%z "$output" 2>/dev/null || stat -c%s "$output" 2>/dev/null)
    local out_kb
    out_kb=$(python3 -c "print(f'{$out_size / 1024:.1f}')" 2>/dev/null || echo "?")

    local body_size
    body_size=$(stat -f%z "$raw_out" 2>/dev/null || stat -c%s "$raw_out" 2>/dev/null)
    local duration
    duration=$(python3 -c "print(f'{$body_size / $SAMPLE_RATE:.2f}')" 2>/dev/null || echo "?")

    info "  → ${output} (${out_kb} KB, ${duration}s, ${body_size} samples)"
    echo -e "  ${GREEN}✓ Done${RESET}"
}

# ─── main ───────────────────────────────────────────────────────────────────

main() {
    check_deps

    local inputs=()
    local explicit_output=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -r) SAMPLE_RATE="$2"; shift 2 ;;
            -n) NORMALIZE=true; shift ;;
            -g) GAIN="$2"; shift 2 ;;
            -f) LPF_CUTOFF="$2"; shift 2 ;;
            -l) AMIGA_LPF=true; shift ;;
            -t) TRIM_SILENCE=true; shift ;;
            -d) DITHER=true; shift ;;
            -D) DITHER=false; shift ;;
            -P) PREPITCH_SEMITONES="$2"; shift 2 ;;
            -V) VOCODER_SEMITONES="$2"; shift 2 ;;
            -p) PREVIEW=true; shift ;;
            -b) BATCH=true; shift ;;
            -o) OUT_DIR="$2"; OUT_DIR_EXPLICIT=true; shift 2 ;;
            -h|--help) usage ;;
            --self-test) run_self_test; exit $? ;;
            -*) die "Unknown option: $1" ;;
            *)  inputs+=("$1"); shift ;;
        esac
    done

    if (( ${#inputs[@]} == 0 )); then
        die "No input file(s) specified. Use -h for help."
    fi

    # Expand any directory arguments into their audio-file contents.
    # Non-recursive: only files directly inside the directory are picked up.
    # If a directory is passed, batch mode is implicitly enabled.
    local expanded=()
    local saw_directory=false
    local arg
    for arg in "${inputs[@]}"; do
        if [[ -d "$arg" ]]; then
            saw_directory=true
            local found=()
            local ext f
            # Collect matches across all known extensions (case-insensitive).
            shopt -s nullglob nocaseglob
            for ext in "${AUDIO_EXTS[@]}"; do
                for f in "$arg"/*."$ext"; do
                    [[ -f "$f" ]] && found+=("$f")
                done
            done
            shopt -u nullglob nocaseglob
            if (( ${#found[@]} == 0 )); then
                warn "No audio files found in directory: $arg"
                continue
            fi
            # Stable ordering
            IFS=$'\n' found=($(printf '%s\n' "${found[@]}" | sort))
            unset IFS
            expanded+=("${found[@]}")
        else
            expanded+=("$arg")
        fi
    done
    inputs=("${expanded[@]}")

    if (( ${#inputs[@]} == 0 )); then
        die "No input files to process."
    fi

    # Auto-enable batch mode when a directory was expanded or when we
    # have more than two inputs total.
    if ${saw_directory} || (( ${#inputs[@]} > 2 )); then
        BATCH=true
    fi

    # validate sample rate range
    if (( SAMPLE_RATE < 2000 || SAMPLE_RATE > 28867 )); then
        warn "Sample rate ${SAMPLE_RATE} Hz is outside typical Amiga range (2000-28867 Hz)"
    fi

    # validate pre-pitch value — sanity-check extreme values
    if (( PREPITCH_SEMITONES < -60 || PREPITCH_SEMITONES > 60 )); then
        warn "Pre-pitch ${PREPITCH_SEMITONES} semitones is extreme (>5 octaves). Typical useful range: 7 to 24."
    fi
    if (( PREPITCH_SEMITONES < 0 )); then
        warn "Negative pre-pitch: this will force HIGHER playback notes in OctaMED to restore pitch. Unusual but not blocked."
    fi

    # validate vocoder value
    if (( VOCODER_SEMITONES < -60 || VOCODER_SEMITONES > 60 )); then
        warn "Vocoder pitch ${VOCODER_SEMITONES} semitones is extreme (>5 octaves). Expect heavy artifacts."
    fi

    # -P and -V are mutually exclusive
    if (( PREPITCH_SEMITONES != 0 )) && (( VOCODER_SEMITONES != 0 )); then
        die "-P and -V cannot be used together. Pick one pitch-shift method."
    fi

    # warn when user passes LPF flags that will be silently disabled
    if (( PREPITCH_SEMITONES != 0 )) || (( VOCODER_SEMITONES != 0 )); then
        local pitch_mode="pre-pitch"
        (( VOCODER_SEMITONES != 0 )) && pitch_mode="vocoder"
        if ${AMIGA_LPF}; then
            warn "${pitch_mode^} active: -l Amiga LPF disabled (would defeat the effect)"
        fi
        if [[ -n "$LPF_CUTOFF" ]]; then
            warn "${pitch_mode^} active: -f manual LPF (${LPF_CUTOFF} Hz) disabled (would defeat the effect)"
        fi
    fi

    # single file mode
    if ! ${BATCH} && (( ${#inputs[@]} <= 2 )); then
        local input="${inputs[0]}"
        if (( ${#inputs[@]} == 2 )); then
            explicit_output="${inputs[1]}"
        fi

        if ${PREVIEW}; then
            print_info "$input"
            exit 0
        fi

        # derive output name
        if [[ -z "$explicit_output" ]]; then
            local base src_dir
            src_dir=$(dirname "$input")
            base=$(basename "$input")
            base="${base%.*}"
            # Amiga filenames: keep it short, no spaces
            base=$(echo "$base" | tr ' ' '_' | cut -c1-24)
            # Tag aliased/vocoder output so you don't confuse it with clean version
            if (( PREPITCH_SEMITONES != 0 )); then
                base="${base}_P${PREPITCH_SEMITONES}"
                # Re-truncate in case the tag pushed it over 24 chars
                base=$(echo "$base" | cut -c1-24)
            elif (( VOCODER_SEMITONES != 0 )); then
                base="${base}_V${VOCODER_SEMITONES}"
                base=$(echo "$base" | cut -c1-24)
            fi
            # Write alongside the source by default so converted samples
            # live next to the originals.
            explicit_output="${src_dir}/${base}.iff"
        fi

        convert_file "$input" "$explicit_output"
        return
    fi

    # batch mode
    if ${OUT_DIR_EXPLICIT}; then
        mkdir -p "$OUT_DIR"
        info "Batch converting ${#inputs[@]} files → ${OUT_DIR}/"
    else
        info "Batch converting ${#inputs[@]} files (output alongside each source)"
    fi
    echo ""

    local count=0
    for input in "${inputs[@]}"; do
        if [[ ! -f "$input" ]]; then
            warn "Skipping (not found): $input"
            continue
        fi

        if ${PREVIEW}; then
            print_info "$input"
            echo ""
            continue
        fi

        # Pick output directory: explicit -o wins; otherwise write next to
        # the source file so a processed directory stays self-contained.
        local out_dir
        if ${OUT_DIR_EXPLICIT}; then
            out_dir="$OUT_DIR"
        else
            out_dir=$(dirname "$input")
        fi

        local base
        base=$(basename "$input")
        base="${base%.*}"
        base=$(echo "$base" | tr ' ' '_' | cut -c1-24)
        if (( PREPITCH_SEMITONES != 0 )); then
            base="${base}_P${PREPITCH_SEMITONES}"
            base=$(echo "$base" | cut -c1-24)
        elif (( VOCODER_SEMITONES != 0 )); then
            base="${base}_V${VOCODER_SEMITONES}"
            base=$(echo "$base" | cut -c1-24)
        fi
        local output="${out_dir}/${base}.iff"

        # avoid overwrites in batch
        if [[ -f "$output" ]]; then
            local i=2
            while [[ -f "${out_dir}/${base}_${i}.iff" ]]; do ((i++)); done
            output="${out_dir}/${base}_${i}.iff"
        fi

        convert_file "$input" "$output"
        ((count++)) || true
        echo ""
    done

    if ! ${PREVIEW}; then
        if ${OUT_DIR_EXPLICIT}; then
            echo -e "${GREEN}${BOLD}Converted ${count} file(s) to ${OUT_DIR}/${RESET}"
        else
            echo -e "${GREEN}${BOLD}Converted ${count} file(s) alongside their sources${RESET}"
        fi
    fi
}

# ─── self-test ──────────────────────────────────────────────────────────────

run_self_test() {
    check_deps

    local tmpdir
    tmpdir=$(mktemp -d)
    # shellcheck disable=SC2064
    trap "rm -rf '$tmpdir'" EXIT

    local passed=0
    local failed=0
    local total=0

    _pass() { ((passed++)) || true; ((total++)) || true; echo -e "  ${GREEN}✓${RESET} $1"; }
    _fail() { ((failed++)) || true; ((total++)) || true; echo -e "  ${RED}✗${RESET} $1"; }

    # helper: verify IFF structure via python, returns JSON-ish on stdout
    _read_iff() {
        python3 - "$1" << 'PYEOF'
import struct, sys, json

path = sys.argv[1]
with open(path, "rb") as f:
    data = f.read()

result = {}
result["file_size"] = len(data)
result["form_tag"] = data[0:4].decode("ascii", errors="replace")
result["form_size"] = struct.unpack(">I", data[4:8])[0]
result["type_tag"] = data[8:12].decode("ascii", errors="replace")
result["vhdr_tag"] = data[12:16].decode("ascii", errors="replace")
result["vhdr_size"] = struct.unpack(">I", data[16:20])[0]
result["one_shot_samples"] = struct.unpack(">I", data[20:24])[0]
result["repeat_samples"] = struct.unpack(">I", data[24:28])[0]
result["samples_per_cycle"] = struct.unpack(">I", data[28:32])[0]
result["sample_rate"] = struct.unpack(">H", data[32:34])[0]
result["ct_octave"] = data[34]
result["compression"] = data[35]
result["volume"] = struct.unpack(">I", data[36:40])[0]
result["body_tag"] = data[40:44].decode("ascii", errors="replace")
result["body_size"] = struct.unpack(">I", data[44:48])[0]

# extract first 16 and last 4 sample bytes as signed
body = data[48:48 + result["body_size"]]
first = [b if b < 128 else b - 256 for b in body[:min(16, len(body))]]
last = [b if b < 128 else b - 256 for b in body[-min(4, len(body)):]]
result["first_samples"] = first
result["last_samples"] = last

# check if any sample exceeds half the dynamic range (loudness check)
peak = max(abs(b) for b in (bb if bb < 128 else bb - 256 for bb in body)) if body else 0
result["peak"] = peak

json.dump(result, sys.stdout)
PYEOF
    }

    _iff_field() {
        echo "$1" | python3 -c "import sys,json; print(json.load(sys.stdin)['$2'])"
    }

    # Reset all config to known defaults. Used between tests so a leftover
    # env var from a previous test doesn't silently influence the next one.
    _reset_opts() {
        SAMPLE_RATE=16726
        NORMALIZE=false
        GAIN=""
        LPF_CUTOFF=""
        AMIGA_LPF=false
        TRIM_SILENCE=false
        DITHER=false
        PREPITCH_SEMITONES=0
        VOCODER_SEMITONES=0
        PREVIEW=false
        BATCH=false
    }

    echo -e "${BOLD}Running self-tests...${RESET}"
    echo ""

    # ── Test 1: Basic conversion — 16-bit stereo WAV → IFF 8SVX ────────────

    echo -e "${BOLD}Test 1: Basic stereo WAV → IFF 8SVX${RESET}"

    _reset_opts
    sox -n -r 44100 -b 16 -c 2 "${tmpdir}/t1_in.wav" synth 0.05 sine 440
    convert_file "${tmpdir}/t1_in.wav" "${tmpdir}/t1_out.iff"

    local iff
    iff=$(_read_iff "${tmpdir}/t1_out.iff")

    [[ $(_iff_field "$iff" form_tag) == "FORM" ]] && _pass "FORM tag" || _fail "FORM tag"
    [[ $(_iff_field "$iff" type_tag) == "8SVX" ]] && _pass "8SVX type" || _fail "8SVX type"
    [[ $(_iff_field "$iff" vhdr_tag) == "VHDR" ]] && _pass "VHDR chunk" || _fail "VHDR chunk"
    [[ $(_iff_field "$iff" vhdr_size) == "20" ]] && _pass "VHDR size = 20" || _fail "VHDR size = 20 (got $(_iff_field "$iff" vhdr_size))"
    [[ $(_iff_field "$iff" body_tag) == "BODY" ]] && _pass "BODY chunk" || _fail "BODY chunk"
    [[ $(_iff_field "$iff" sample_rate) == "16726" ]] && _pass "Sample rate = 16726" || _fail "Sample rate (got $(_iff_field "$iff" sample_rate))"
    [[ $(_iff_field "$iff" compression) == "0" ]] && _pass "No compression" || _fail "Compression flag"
    [[ $(_iff_field "$iff" volume) == "65536" ]] && _pass "Volume = 1.0 (0x10000)" || _fail "Volume field"
    [[ $(_iff_field "$iff" repeat_samples) == "0" ]] && _pass "No loop" || _fail "Loop field"

    # body should be roughly 0.05s × 16726 ≈ 836 samples (±10%)
    local body_size
    body_size=$(_iff_field "$iff" body_size)
    local one_shot
    one_shot=$(_iff_field "$iff" one_shot_samples)
    [[ "$body_size" == "$one_shot" ]] && _pass "BODY size = oneShotHiSamples ($body_size)" || _fail "BODY/oneShot mismatch ($body_size vs $one_shot)"

    if (( body_size > 750 && body_size < 920 )); then
        _pass "Output length plausible (~836 samples, got $body_size)"
    else
        _fail "Output length unexpected (expected ~836, got $body_size)"
    fi

    # FORM size consistency: form_size should = file_size - 8
    local form_size file_size
    form_size=$(_iff_field "$iff" form_size)
    file_size=$(_iff_field "$iff" file_size)
    if (( form_size == file_size - 8 )); then
        _pass "FORM size consistent with file size"
    else
        _fail "FORM size inconsistent ($form_size != $file_size - 8)"
    fi

    echo ""

    # ── Test 2: Sample rate variants ────────────────────────────────────────

    echo -e "${BOLD}Test 2: Sample rate accuracy${RESET}"

    for rate in 8363 16726 22050; do
        _reset_opts
        SAMPLE_RATE=$rate
        sox -n -r 48000 -b 24 -c 1 "${tmpdir}/t2_in.wav" synth 0.1 sine 1000
        convert_file "${tmpdir}/t2_in.wav" "${tmpdir}/t2_out.iff"

        iff=$(_read_iff "${tmpdir}/t2_out.iff")
        local got_rate
        got_rate=$(_iff_field "$iff" sample_rate)
        if [[ "$got_rate" == "$rate" ]]; then
            _pass "Rate $rate Hz stored correctly"
        else
            _fail "Rate $rate Hz (got $got_rate)"
        fi

        # check body size proportional to rate: 0.1s × rate
        local expected_approx=$((rate / 10))
        body_size=$(_iff_field "$iff" body_size)
        local lo=$(( expected_approx * 90 / 100 ))
        local hi=$(( expected_approx * 110 / 100 ))
        if (( body_size >= lo && body_size <= hi )); then
            _pass "Body size at $rate Hz plausible ($body_size ≈ $expected_approx)"
        else
            _fail "Body size at $rate Hz unexpected ($body_size, expected ~$expected_approx)"
        fi

        rm -f "${tmpdir}/t2_out.iff"
    done

    echo ""

    # ── Test 3: Normalize boosts quiet signal ───────────────────────────────

    echo -e "${BOLD}Test 3: Normalization${RESET}"

    # generate a very quiet sine (-40 dB)
    sox -n -r 44100 -b 16 -c 1 "${tmpdir}/t3_in.wav" synth 0.05 sine 440 gain -40

    # without normalize
    _reset_opts
    convert_file "${tmpdir}/t3_in.wav" "${tmpdir}/t3_quiet.iff"

    # with normalize
    _reset_opts
    NORMALIZE=true
    convert_file "${tmpdir}/t3_in.wav" "${tmpdir}/t3_norm.iff"

    local quiet_peak norm_peak
    quiet_peak=$(_iff_field "$(_read_iff "${tmpdir}/t3_quiet.iff")" peak)
    norm_peak=$(_iff_field "$(_read_iff "${tmpdir}/t3_norm.iff")" peak)

    if (( norm_peak > quiet_peak )); then
        _pass "Normalized peak ($norm_peak) > quiet peak ($quiet_peak)"
    else
        _fail "Normalize didn't boost signal ($norm_peak vs $quiet_peak)"
    fi

    # With 1 dB of safety headroom before dither, normalized peak should land
    # around 113 (127 × 10^(-1/20) ≈ 113), not pinned at 127.
    if (( norm_peak > 100 )); then
        _pass "Normalized signal uses most of 8-bit range (peak=$norm_peak/127)"
    else
        _fail "Normalized signal still quiet (peak=$norm_peak/127)"
    fi

    if (( norm_peak <= 127 )); then
        _pass "Normalized signal has headroom (peak=$norm_peak ≤ 127)"
    else
        _fail "Normalized signal clipped (peak=$norm_peak > 127)"
    fi

    echo ""

    # ── Test 4: Odd-length BODY gets IFF pad byte ──────────────────────────

    echo -e "${BOLD}Test 4: IFF pad byte for odd-length BODY${RESET}"

    # create a raw file with odd number of bytes and wrap it
    python3 -c "open('${tmpdir}/t4_odd.raw','wb').write(b'\\x00' * 127)"
    write_8svx "${tmpdir}/t4_odd.raw" "${tmpdir}/t4_odd.iff" 16726

    local t4_file_size t4_body_size
    iff=$(_read_iff "${tmpdir}/t4_odd.iff")
    t4_file_size=$(_iff_field "$iff" file_size)
    t4_body_size=$(_iff_field "$iff" body_size)

    if [[ "$t4_body_size" == "127" ]]; then
        _pass "Odd BODY size preserved (127)"
    else
        _fail "BODY size wrong (expected 127, got $t4_body_size)"
    fi

    # file should be: 12 (FORM+size+8SVX) + 28 (VHDR chunk) + 8 (BODY header) + 127 + 1 pad = 176
    if (( t4_file_size == 176 )); then
        _pass "File size includes pad byte (176)"
    else
        _fail "File size wrong (expected 176, got $t4_file_size)"
    fi

    # even BODY — no pad needed
    python3 -c "open('${tmpdir}/t4_even.raw','wb').write(b'\\x00' * 128)"
    write_8svx "${tmpdir}/t4_even.raw" "${tmpdir}/t4_even.iff" 16726

    iff=$(_read_iff "${tmpdir}/t4_even.iff")
    t4_file_size=$(_iff_field "$iff" file_size)

    # file should be: 12 + 28 + 8 + 128 = 176 (same by coincidence, but no pad)
    if (( t4_file_size == 176 )); then
        _pass "Even BODY — no unnecessary pad (176)"
    else
        _fail "Even BODY file size wrong (expected 176, got $t4_file_size)"
    fi

    echo ""

    # ── Test 5: High sample rate input (192kHz 32-bit) ─────────────────────

    echo -e "${BOLD}Test 5: Extreme input format (192kHz/32-bit float)${RESET}"

    sox -n -r 192000 -b 32 -e floating-point -c 1 "${tmpdir}/t5_in.wav" synth 0.02 sine 440

    _reset_opts
    SAMPLE_RATE=8363
    NORMALIZE=true
    convert_file "${tmpdir}/t5_in.wav" "${tmpdir}/t5_out.iff"

    iff=$(_read_iff "${tmpdir}/t5_out.iff")
    [[ $(_iff_field "$iff" form_tag) == "FORM" ]] && _pass "192kHz/32-float → valid FORM" || _fail "192kHz input failed"
    [[ $(_iff_field "$iff" sample_rate) == "8363" ]] && _pass "Downsampled to 8363 Hz" || _fail "Wrong output rate"

    echo ""

    # ── Test 6: DC signal round-trip (verify 8-bit signed encoding) ────────

    echo -e "${BOLD}Test 6: DC signal → 8-bit signed encoding${RESET}"

    # generate 0.5s of silence — should produce near-zero samples
    sox -n -r 16726 -b 16 -c 1 "${tmpdir}/t6_in.wav" synth 0.01 sine 0

    _reset_opts
    convert_file "${tmpdir}/t6_in.wav" "${tmpdir}/t6_out.iff"

    iff=$(_read_iff "${tmpdir}/t6_out.iff")
    local peak
    peak=$(_iff_field "$iff" peak)
    if (( peak <= 1 )); then
        _pass "Silence → near-zero samples (peak=$peak)"
    else
        _fail "Silence produced non-zero samples (peak=$peak)"
    fi

    echo ""

    # ── Test 7: Filename sanitization ──────────────────────────────────────

    echo -e "${BOLD}Test 7: Filename sanitization${RESET}"

    # file with spaces and long name
    local longname="this is a very long sample name with spaces and stuff"
    cp "${tmpdir}/t6_in.wav" "${tmpdir}/${longname}.wav"

    _reset_opts
    mkdir -p "${tmpdir}/sanitized"
    convert_file "${tmpdir}/${longname}.wav" "${tmpdir}/sanitized/this_is_a_very_long_sampl.iff"

    if [[ -f "${tmpdir}/sanitized/this_is_a_very_long_sampl.iff" ]]; then
        iff=$(_read_iff "${tmpdir}/sanitized/this_is_a_very_long_sampl.iff")
        [[ $(_iff_field "$iff" form_tag) == "FORM" ]] && _pass "Long filename → valid output" || _fail "Long filename output corrupt"
    else
        _fail "Long filename → no output created"
    fi

    echo ""

    # ── Test 8: Headroom prevents clipping of loud source ──────────────────

    echo -e "${BOLD}Test 8: Headroom prevents clipping${RESET}"

    # Full-scale sine minus 0.1 dB. Represents realistic "hot" source
    # material — sample packs often ship near 0 dBFS. (Square waves are
    # pathological due to Gibbs ringing during resampling and aren't a
    # useful test of real conversion behavior.)
    sox -n -r 44100 -b 16 -c 1 "${tmpdir}/t8_in.wav" synth 0.05 sine 1000 gain -0.1

    _reset_opts
    convert_file "${tmpdir}/t8_in.wav" "${tmpdir}/t8_out.iff"

    iff=$(_read_iff "${tmpdir}/t8_out.iff")
    peak=$(_iff_field "$iff" peak)
    # Signed 8-bit range is -128..+127, so abs() max is 128.
    # With -1 dB headroom we expect peak ≈ 113 (well inside range).
    if (( peak <= 128 )); then
        _pass "Loud source within 8-bit range (peak=$peak, max 128)"
    else
        _fail "Loud source exceeded 8-bit range (peak=$peak)"
    fi

    if (( peak >= 100 && peak <= 120 )); then
        _pass "Headroom in expected range (peak=$peak, target ~113)"
    else
        _fail "Headroom unexpected (peak=$peak, expected 100-120)"
    fi

    echo ""

    # ── Test 9: Pre-pitch shift produces valid output ──────────────────────

    echo -e "${BOLD}Test 9: Pre-pitch shift (-P flag)${RESET}"

    # Generate a 1 kHz sine. After +12 semitones via `speed`, duration
    # should be halved (2x speed) AND pitch should be doubled to 2 kHz.
    sox -n -r 44100 -b 16 -c 1 "${tmpdir}/t9_in.wav" synth 0.1 sine 1000

    _reset_opts
    SAMPLE_RATE=22050
    PREPITCH_SEMITONES=12
    convert_file "${tmpdir}/t9_in.wav" "${tmpdir}/t9_octave.iff"

    iff=$(_read_iff "${tmpdir}/t9_octave.iff")
    [[ $(_iff_field "$iff" form_tag) == "FORM" ]] && _pass "Pre-pitched +12 → valid FORM" || _fail "Pre-pitched output corrupt"
    [[ $(_iff_field "$iff" sample_rate) == "22050" ]] && _pass "Stored rate preserved (22050)" || _fail "Rate changed unexpectedly"

    # With `speed` (not `pitch`), +12 semis = 2x speed, so 0.1s source
    # becomes 0.05s. At 22050 Hz that's ~1102 samples ±10%.
    body_size=$(_iff_field "$iff" body_size)
    if (( body_size >= 990 && body_size <= 1215 )); then
        _pass "Duration halved by 2x speed (got $body_size samples, expected ~1102)"
    else
        _fail "Duration unexpected after speed shift ($body_size, expected ~1102)"
    fi

    # Also verify a non-octave value: +7 semis (perfect fifth) = ~1.498x speed.
    # 0.1s → ~0.0667s → ~1471 samples at 22050 Hz ±10%.
    _reset_opts
    SAMPLE_RATE=22050
    PREPITCH_SEMITONES=7
    convert_file "${tmpdir}/t9_in.wav" "${tmpdir}/t9_fifth.iff"

    iff=$(_read_iff "${tmpdir}/t9_fifth.iff")
    body_size=$(_iff_field "$iff" body_size)
    if (( body_size >= 1324 && body_size <= 1618 )); then
        _pass "+7 semis produces ~1.498x speed ($body_size samples, expected ~1471)"
    else
        _fail "+7 semis duration unexpected ($body_size, expected ~1471)"
    fi

    echo ""

    # ── Test 10: Pre-pitch auto-disables LPF ───────────────────────────────

    echo -e "${BOLD}Test 10: Pre-pitch auto-disables anti-alias LPF${RESET}"

    # White noise has energy across the full spectrum. With LPF it would be
    # dulled; without, HF content folds back as aliasing.
    sox -n -r 44100 -b 16 -c 1 "${tmpdir}/t10_in.wav" synth 0.1 whitenoise

    # Convert once with LPF flags but NO pre-pitch (LPF should apply)
    _reset_opts
    SAMPLE_RATE=22050
    AMIGA_LPF=true
    LPF_CUTOFF=3000
    convert_file "${tmpdir}/t10_in.wav" "${tmpdir}/t10_lpf.iff" 2>/dev/null

    # Convert with both LPF flags AND pre-pitch (LPF should be bypassed)
    _reset_opts
    SAMPLE_RATE=22050
    AMIGA_LPF=true
    LPF_CUTOFF=3000
    PREPITCH_SEMITONES=12
    convert_file "${tmpdir}/t10_in.wav" "${tmpdir}/t10_aliased.iff" 2>/dev/null

    # Both files should exist and be valid IFF.
    local iff_lpf iff_alias
    iff_lpf=$(_read_iff "${tmpdir}/t10_lpf.iff")
    iff_alias=$(_read_iff "${tmpdir}/t10_aliased.iff")

    [[ $(_iff_field "$iff_lpf" form_tag) == "FORM" ]] && _pass "LPF-only output valid" || _fail "LPF-only output corrupt"
    [[ $(_iff_field "$iff_alias" form_tag) == "FORM" ]] && _pass "Pre-pitched output valid" || _fail "Pre-pitched output corrupt"

    # Check HF content via sample-to-sample variance. A heavily LPF'd signal
    # should have lower average absolute delta between adjacent samples than
    # one that still has HF content / aliasing. We compute mean |Δ| for each
    # file and assert aliased > lpf.
    local delta_lpf delta_alias
    delta_lpf=$(python3 - "${tmpdir}/t10_lpf.iff" << 'PYEOF'
import struct
data = open(__import__('sys').argv[1],'rb').read()
body_off = 48
body_size = struct.unpack(">I", data[44:48])[0]
body = data[body_off:body_off+body_size]
signed = [b if b < 128 else b - 256 for b in body]
if len(signed) < 2:
    print(0)
else:
    deltas = [abs(signed[i+1] - signed[i]) for i in range(len(signed)-1)]
    print(sum(deltas) / len(deltas))
PYEOF
)
    delta_alias=$(python3 - "${tmpdir}/t10_aliased.iff" << 'PYEOF'
import struct
data = open(__import__('sys').argv[1],'rb').read()
body_off = 48
body_size = struct.unpack(">I", data[44:48])[0]
body = data[body_off:body_off+body_size]
signed = [b if b < 128 else b - 256 for b in body]
if len(signed) < 2:
    print(0)
else:
    deltas = [abs(signed[i+1] - signed[i]) for i in range(len(signed)-1)]
    print(sum(deltas) / len(deltas))
PYEOF
)

    # Compare as floats in python (bash can't float-compare natively)
    if python3 -c "import sys; sys.exit(0 if $delta_alias > $delta_lpf else 1)"; then
        _pass "Pre-pitched output has more HF content than LPF'd (Δ: $delta_alias > $delta_lpf)"
    else
        _fail "Pre-pitched output not brighter than LPF'd (Δ: $delta_alias vs $delta_lpf) — LPF may not be bypassed"
    fi

    echo ""

    # ── Test 11: semitones_to_playback_hint calculation ────────────────────

    echo -e "${BOLD}Test 11: Playback hint calculation${RESET}"

    local hint
    hint=$(semitones_to_playback_hint 12)
    [[ "$hint" == "C-2" ]] && _pass "+12 semis → C-2 (was C-3)" || _fail "+12 semis → expected C-2, got $hint"

    hint=$(semitones_to_playback_hint 24)
    [[ "$hint" == "C-1" ]] && _pass "+24 semis → C-1 (was C-3)" || _fail "+24 semis → expected C-1, got $hint"

    hint=$(semitones_to_playback_hint 7)
    [[ "$hint" == "F-2" ]] && _pass "+7 semis → F-2 (perfect fifth down)" || _fail "+7 semis → expected F-2, got $hint"

    hint=$(semitones_to_playback_hint 0)
    [[ "$hint" == "C-3" ]] && _pass "0 semis → C-3 (unchanged)" || _fail "0 semis → expected C-3, got $hint"

    echo ""

    # ── Test 12: Vocoder-pitch shift preserves duration ────────────────────

    echo -e "${BOLD}Test 12: Vocoder-pitch (-V flag) preserves duration${RESET}"

    # 0.2s source — needs to be long enough for phase vocoder windows to
    # settle. At 22050 Hz output, expect ~4410 samples ±10%.
    sox -n -r 44100 -b 16 -c 1 "${tmpdir}/t12_in.wav" synth 0.2 sine 1000

    _reset_opts
    SAMPLE_RATE=22050
    VOCODER_SEMITONES=12
    convert_file "${tmpdir}/t12_in.wav" "${tmpdir}/t12_vocoder.iff"

    iff=$(_read_iff "${tmpdir}/t12_vocoder.iff")
    [[ $(_iff_field "$iff" form_tag) == "FORM" ]] && _pass "Vocoder-pitched +12 → valid FORM" || _fail "Vocoder-pitched output corrupt"

    # With `pitch` (phase vocoder), duration is PRESERVED. 0.2s × 22050 = 4410
    # samples ±10% for vocoder window alignment slop.
    body_size=$(_iff_field "$iff" body_size)
    if (( body_size >= 3969 && body_size <= 4851 )); then
        _pass "Duration preserved by vocoder (got $body_size samples, expected ~4410)"
    else
        _fail "Duration unexpected after vocoder shift ($body_size, expected ~4410)"
    fi

    # Compare against -P 12 on the same source: with speed, duration halves.
    _reset_opts
    SAMPLE_RATE=22050
    PREPITCH_SEMITONES=12
    convert_file "${tmpdir}/t12_in.wav" "${tmpdir}/t12_speed.iff"

    local speed_body vocoder_body
    speed_body=$(_iff_field "$(_read_iff "${tmpdir}/t12_speed.iff")" body_size)
    vocoder_body=$(_iff_field "$(_read_iff "${tmpdir}/t12_vocoder.iff")" body_size)

    # Vocoder body should be ~2x speed body (vocoder preserves, speed halves).
    local ratio_pct
    ratio_pct=$(( vocoder_body * 100 / speed_body ))
    if (( ratio_pct >= 180 && ratio_pct <= 220 )); then
        _pass "Vocoder duration ≈ 2× speed duration (ratio: ${ratio_pct}%, expected ~200%)"
    else
        _fail "Vocoder/speed ratio unexpected (${ratio_pct}%, expected ~200%)"
    fi

    echo ""

    # ── Test 13: -P and -V mutual exclusion ────────────────────────────────

    echo -e "${BOLD}Test 13: -P and -V mutual exclusion${RESET}"

    # Direct CLI invocation — should fail with exit code != 0.
    # Use a subshell to isolate from the test's `set -e` behavior.
    if (bash "$0" -P 12 -V 7 /dev/null 2>/dev/null); then
        _fail "-P and -V together did not error out"
    else
        _pass "-P and -V together correctly rejected"
    fi

    echo ""

    # ── Test 14: Directory input globbing & per-source output ──────────────

    echo -e "${BOLD}Test 14: Directory input globbing${RESET}"

    local gdir="${tmpdir}/globtest"
    mkdir -p "$gdir"

    # Create a mix of audio files with varied extensions/casing, plus a
    # non-audio file that must be ignored.
    sox -n -r 22050 -b 16 -c 1 "${gdir}/one.wav"  synth 0.02 sine 440
    sox -n -r 22050 -b 16 -c 1 "${gdir}/two.WAV"  synth 0.02 sine 440
    sox -n -r 22050 -b 16 -c 1 "${gdir}/three.aiff" synth 0.02 sine 440
    sox -n -r 22050 -b 16 -c 1 "${gdir}/four.flac" synth 0.02 sine 440
    echo "not audio" > "${gdir}/readme.txt"

    # Invoke the script via its own CLI so we exercise the real argument
    # parsing path (directory expansion + auto-batch + default output dir).
    bash "$0" -r 16726 -D "$gdir" > "${tmpdir}/globtest.log" 2>&1 || true

    # Each of the four audio files should produce an .iff alongside itself.
    local expected_outs=(
        "${gdir}/one.iff"
        "${gdir}/two.iff"
        "${gdir}/three.iff"
        "${gdir}/four.iff"
    )
    local missing=0
    for f in "${expected_outs[@]}"; do
        [[ -f "$f" ]] || ((missing++))
    done
    if (( missing == 0 )); then
        _pass "Directory expanded → 4 audio files converted next to sources"
    else
        _fail "Directory expansion missing $missing/4 outputs (see ${tmpdir}/globtest.log)"
    fi

    # The non-audio file must not spawn an .iff
    if [[ ! -f "${gdir}/readme.iff" ]]; then
        _pass "Non-audio files ignored during directory expansion"
    else
        _fail "readme.txt was incorrectly processed"
    fi

    # No rogue default output directory should be created when -o is omitted
    if [[ ! -d "${gdir}/amiga_samples" && ! -d "./amiga_samples" ]]; then
        _pass "No implicit ./amiga_samples directory created"
    else
        _fail "Implicit amiga_samples directory appeared unexpectedly"
    fi

    # Validate one of the produced files is a real IFF 8SVX
    if [[ -f "${gdir}/one.iff" ]]; then
        iff=$(_read_iff "${gdir}/one.iff")
        [[ $(_iff_field "$iff" form_tag) == "FORM" && $(_iff_field "$iff" type_tag) == "8SVX" ]] \
            && _pass "Directory-expanded output is valid IFF 8SVX" \
            || _fail "Directory-expanded output not a valid IFF"
    fi

    # Case-insensitive matching worked (two.WAV → two.iff)
    if [[ -f "${gdir}/two.iff" ]]; then
        _pass "Case-insensitive extension matching (WAV)"
    else
        _fail "Uppercase .WAV extension was not matched"
    fi

    # Explicit -o DIR still overrides per-source output placement
    local odir="${tmpdir}/globtest_out"
    bash "$0" -r 16726 -D -o "$odir" "$gdir" > "${tmpdir}/globtest_o.log" 2>&1 || true
    local o_count
    o_count=$(find "$odir" -maxdepth 1 -name '*.iff' 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$o_count" == "4" ]]; then
        _pass "Explicit -o DIR collects all outputs in one directory"
    else
        _fail "Explicit -o DIR produced $o_count/4 outputs (see ${tmpdir}/globtest_o.log)"
    fi

    # Empty directory should warn but not crash
    local empty_dir="${tmpdir}/empty"
    mkdir -p "$empty_dir"
    if bash "$0" -r 16726 -D "$empty_dir" > "${tmpdir}/empty.log" 2>&1; then
        _fail "Empty directory should have caused a non-zero exit"
    else
        if grep -q "No input files to process" "${tmpdir}/empty.log" \
           || grep -q "No audio files found" "${tmpdir}/empty.log"; then
            _pass "Empty directory handled gracefully with warning"
        else
            _fail "Empty directory failed but without expected message"
        fi
    fi

    echo ""

    # ── Summary ────────────────────────────────────────────────────────────

    echo -e "${BOLD}────────────────────────────${RESET}"
    if (( failed == 0 )); then
        echo -e "${GREEN}${BOLD}All ${total} tests passed ✓${RESET}"
    else
        echo -e "${RED}${BOLD}${failed}/${total} tests failed${RESET}"
    fi

    return "$failed"
}

main "$@"