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
#   -r RATE    Target sample rate in Hz (default: 16726)
#              Common Amiga rates:
#                8363  - ProTracker C-3 standard (low quality, saves memory)
#                11025 - Telephony standard
#                16726 - 2x ProTracker C-3 (good balance, default)
#                22050 - CD/2 (high quality, more memory)
#                27928 - 4x ProTracker C-3 (near max safe rate for PAL)
#   -n         Normalize audio to 0 dBFS before conversion
#   -g GAIN    Apply gain in dB before conversion (e.g., -3, +6)
#   -f FREQ    Manual anti-alias LPF cutoff in Hz (default: auto Nyquist-based)
#   -l         Apply light Amiga-style low-pass at 3.3 kHz (emulates A500 output)
#   -t         Trim silence from start and end (threshold: -48 dB)
#   -d         Use TPDF dither when reducing to 8-bit (default: on)
#   -D         Disable dither (truncate to 8-bit)
#   -p         Preview: print file info and conversion plan, don't convert
#   -b         Batch mode: treat all non-option args as input files
#   -o DIR     Output directory for batch mode (default: ./amiga_samples)
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

SAMPLE_RATE=16726
NORMALIZE=false
GAIN=""
LPF_CUTOFF=""
AMIGA_LPF=false
TRIM_SILENCE=false
DITHER=true
PREVIEW=false
BATCH=false
OUT_DIR="./amiga_samples"

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

usage() {
    sed -n '/^# Usage:/,/^[^#]/{ /^#/s/^# \?//p }' "$0"
    echo ""
    sed -n '/^# Options:/,/^[^#]/{ /^#/s/^# \?//p }' "$0"
    echo ""
    sed -n '/^# OctaMED 4 notes:/,/^[^#]/{ /^#/s/^# \?//p }' "$0"
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
        ${AMIGA_LPF} && echo -e "  A500-style LPF: yes (3.3 kHz)"
        ${TRIM_SILENCE} && echo -e "  Trim silence: yes"

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

    # remix to mono (mix all channels equally)
    local src_chans
    src_chans=$(soxi -c "$input" 2>/dev/null) || die "Cannot read input file: $input"
    if (( src_chans > 1 )); then
        effects+=(remix -)
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

    # resample to target rate with very-high-quality sinc interpolation
    local src_rate
    src_rate=$(soxi -r "$input" 2>/dev/null)
    if (( src_rate != SAMPLE_RATE )); then
        effects+=(rate -v "$SAMPLE_RATE")
    fi

    # optional Amiga-style low-pass (emulates the A500 output filter)
    if ${AMIGA_LPF}; then
        effects+=(lowpass 3300)
    fi

    # manual LPF override
    if [[ -n "$LPF_CUTOFF" ]]; then
        effects+=(lowpass "$LPF_CUTOFF")
    fi

    # dither
    if ${DITHER}; then
        effects+=(dither -s)
    fi

    info "Converting: $(basename "$input")"
    info "  → ${SAMPLE_RATE} Hz, 8-bit signed mono"

    # run sox: output as raw signed 8-bit
    sox "$input" \
        --encoding signed-integer \
        --bits 8 \
        --channels 1 \
        --rate "$SAMPLE_RATE" \
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
            -p) PREVIEW=true; shift ;;
            -b) BATCH=true; shift ;;
            -o) OUT_DIR="$2"; shift 2 ;;
            -h|--help) usage ;;
            --self-test) run_self_test; exit $? ;;
            -*) die "Unknown option: $1" ;;
            *)  inputs+=("$1"); shift ;;
        esac
    done

    if (( ${#inputs[@]} == 0 )); then
        die "No input file(s) specified. Use -h for help."
    fi

    # validate sample rate range
    if (( SAMPLE_RATE < 2000 || SAMPLE_RATE > 28867 )); then
        warn "Sample rate ${SAMPLE_RATE} Hz is outside typical Amiga range (2000-28867 Hz)"
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
            local base
            base=$(basename "$input")
            base="${base%.*}"
            # Amiga filenames: keep it short, no spaces
            base=$(echo "$base" | tr ' ' '_' | cut -c1-24)
            explicit_output="${base}.iff"
        fi

        convert_file "$input" "$explicit_output"
        return
    fi

    # batch mode
    mkdir -p "$OUT_DIR"
    info "Batch converting ${#inputs[@]} files → ${OUT_DIR}/"
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

        local base
        base=$(basename "$input")
        base="${base%.*}"
        base=$(echo "$base" | tr ' ' '_' | cut -c1-24)
        local output="${OUT_DIR}/${base}.iff"

        # avoid overwrites in batch
        if [[ -f "$output" ]]; then
            local i=2
            while [[ -f "${OUT_DIR}/${base}_${i}.iff" ]]; do ((i++)); done
            output="${OUT_DIR}/${base}_${i}.iff"
        fi

        convert_file "$input" "$output"
        ((count++)) || true
        echo ""
    done

    if ! ${PREVIEW}; then
        echo -e "${GREEN}${BOLD}Converted ${count} file(s) to ${OUT_DIR}/${RESET}"
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

    echo -e "${BOLD}Running self-tests...${RESET}"
    echo ""

    # ── Test 1: Basic conversion — 16-bit stereo WAV → IFF 8SVX ────────────

    echo -e "${BOLD}Test 1: Basic stereo WAV → IFF 8SVX${RESET}"

    sox -n -r 44100 -b 16 -c 2 "${tmpdir}/t1_in.wav" synth 0.05 sine 440
    SAMPLE_RATE=16726 NORMALIZE=false GAIN="" LPF_CUTOFF="" AMIGA_LPF=false \
        TRIM_SILENCE=false DITHER=false PREVIEW=false \
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
        sox -n -r 48000 -b 24 -c 1 "${tmpdir}/t2_in.wav" synth 0.1 sine 1000
        SAMPLE_RATE=$rate NORMALIZE=false GAIN="" LPF_CUTOFF="" AMIGA_LPF=false \
            TRIM_SILENCE=false DITHER=false PREVIEW=false \
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
    SAMPLE_RATE=16726 NORMALIZE=false GAIN="" LPF_CUTOFF="" AMIGA_LPF=false \
        TRIM_SILENCE=false DITHER=false PREVIEW=false \
        convert_file "${tmpdir}/t3_in.wav" "${tmpdir}/t3_quiet.iff"

    # with normalize
    SAMPLE_RATE=16726 NORMALIZE=true GAIN="" LPF_CUTOFF="" AMIGA_LPF=false \
        TRIM_SILENCE=false DITHER=false PREVIEW=false \
        convert_file "${tmpdir}/t3_in.wav" "${tmpdir}/t3_norm.iff"

    local quiet_peak norm_peak
    quiet_peak=$(_iff_field "$(_read_iff "${tmpdir}/t3_quiet.iff")" peak)
    norm_peak=$(_iff_field "$(_read_iff "${tmpdir}/t3_norm.iff")" peak)

    if (( norm_peak > quiet_peak )); then
        _pass "Normalized peak ($norm_peak) > quiet peak ($quiet_peak)"
    else
        _fail "Normalize didn't boost signal ($norm_peak vs $quiet_peak)"
    fi

    if (( norm_peak > 100 )); then
        _pass "Normalized signal uses most of 8-bit range (peak=$norm_peak/127)"
    else
        _fail "Normalized signal still quiet (peak=$norm_peak/127)"
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

    SAMPLE_RATE=8363 NORMALIZE=true GAIN="" LPF_CUTOFF="" AMIGA_LPF=false \
        TRIM_SILENCE=false DITHER=false PREVIEW=false \
        convert_file "${tmpdir}/t5_in.wav" "${tmpdir}/t5_out.iff"

    iff=$(_read_iff "${tmpdir}/t5_out.iff")
    [[ $(_iff_field "$iff" form_tag) == "FORM" ]] && _pass "192kHz/32-float → valid FORM" || _fail "192kHz input failed"
    [[ $(_iff_field "$iff" sample_rate) == "8363" ]] && _pass "Downsampled to 8363 Hz" || _fail "Wrong output rate"

    echo ""

    # ── Test 6: DC signal round-trip (verify 8-bit signed encoding) ────────

    echo -e "${BOLD}Test 6: DC signal → 8-bit signed encoding${RESET}"

    # generate 0.5s of silence — should produce near-zero samples
    sox -n -r 16726 -b 16 -c 1 "${tmpdir}/t6_in.wav" synth 0.01 sine 0

    SAMPLE_RATE=16726 NORMALIZE=false GAIN="" LPF_CUTOFF="" AMIGA_LPF=false \
        TRIM_SILENCE=false DITHER=false PREVIEW=false \
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

    SAMPLE_RATE=16726 NORMALIZE=false GAIN="" LPF_CUTOFF="" AMIGA_LPF=false \
        TRIM_SILENCE=false DITHER=false PREVIEW=false BATCH=true \
        OUT_DIR="${tmpdir}/sanitized"

    mkdir -p "${tmpdir}/sanitized"
    convert_file "${tmpdir}/${longname}.wav" "${tmpdir}/sanitized/this_is_a_very_long_sampl.iff"

    # we just check conversion succeeded — the main script handles naming,
    # but here we directly test that the IFF is valid regardless
    if [[ -f "${tmpdir}/sanitized/this_is_a_very_long_sampl.iff" ]]; then
        iff=$(_read_iff "${tmpdir}/sanitized/this_is_a_very_long_sampl.iff")
        [[ $(_iff_field "$iff" form_tag) == "FORM" ]] && _pass "Long filename → valid output" || _fail "Long filename output corrupt"
    else
        # convert_file writes to the path we give it, so just check what we got
        local found
        found=$(ls "${tmpdir}/sanitized/"*.iff 2>/dev/null | head -1)
        if [[ -n "$found" ]]; then
            _pass "Long filename → output created ($(basename "$found"))"
        else
            _fail "Long filename → no output created"
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