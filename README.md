# amiga_sample_convert.sh

Convert any audio file to IFF 8SVX format for OctaMED 4 on Amiga.

Takes WAV, AIFF, FLAC, MP3, or anything else sox can read and produces a proper IFF 8SVX file with VHDR and BODY chunks that OctaMED 4 will load directly. Handles sample rate conversion, bit depth reduction, mono mixdown, normalization, A500-style filtering, optional pre-pitching for intentional Paula aliasing, and Amiga filesystem name sanitization.

## Requirements

- **sox** — `brew install sox`
- **python3** — ships with macOS

Note: this has been tested on MacOS. It should work on Linux, etc but may need some small adjustments.

## Quick start

```bash
chmod +x amiga_sample_convert.sh

# Convert a kick drum sample (defaults to 16574 Hz — Paula's PAL playback
# rate at C-3 in 4-channel mode, so triggering at C-3 in OctaMED gives
# original pitch with no aliasing)
./amiga_sample_convert.sh kick.wav
```

For a Finder right-click → **Quick Actions → Convert to Amiga 8SVX** workflow, see [macos/README.md](macos/README.md).

## Usage

```text
./amiga_sample_convert.sh [options] input_file [output_file]
```

In single-file mode, the output filename is optional — it defaults to the input name with `.iff` extension, spaces replaced with underscores, truncated to 24 characters. When `-P` or `-V` is used, the suffix `_P<semis>` or `_V<semis>` is appended to the default name so pitched variants don't collide with the clean version.

## Options

| Flag          | Description                                                             |
| ------------- | ----------------------------------------------------------------------- |
| `-r RATE`     | Target sample rate in Hz (default: 16574 — Paula at C-3, PAL 4-channel) |
| `-N NOTE`     | Pick rate so original pitch plays at NOTE in OctaMED 4-channel mode     |
| `-n`          | Normalize audio to 0 dBFS before conversion                             |
| `-g GAIN`     | Apply gain in dB (e.g., `-3`, `+6`)                                     |
| `-f FREQ`     | Manual anti-alias LPF cutoff in Hz                                      |
| `-l`          | Apply A500-style low-pass at 4.9 kHz (always-on output filter)          |
| `-t`          | Trim silence from start and end (-48 dB threshold)                      |
| `-d`          | TPDF dither (default: on)                                               |
| `-D`          | Disable dither — truncate to 8-bit                                      |
| `-P SEMI`     | Pre-pitch UP by SEMI semitones via raw resample (aliasing)              |
| `-V SEMI`     | Vocoder-pitch shift by SEMI semitones (duration-preserving)             |
| `-p`          | Preview: show file info and conversion plan, don't convert              |
| `-b`          | Batch mode: treat all positional args as input files                    |
| `-o DIR`      | Output directory (applies to single-file and batch modes)               |
| `--self-test` | Run built-in smoke tests                                                |
| `-h`          | Show help                                                               |

## Sample rates

Paula in 4-channel mode is fixed 8-bit and DMA-fetches sample bytes at `clock / period`, where period is determined entirely by the note you trigger — the stored 8SVX rate is metadata, not a playback target. So the trick is to render the source at the rate Paula will fetch it at when you play the note you intend to trigger.

| Note (PAL) | Period  | Paula playback rate | Use as conversion rate when…                                   |
| ---------- | ------- | ------------------- | -------------------------------------------------------------- |
| C-1        | 856     | 4,144 Hz            | Sub-bass anchor; play melodically up from C-1.                 |
| C-2        | 428     | 8,287 Hz            | Octave-down anchor; saves chip RAM, plenty of headroom up.     |
| **C-3**    | **214** | **16,574 Hz**       | **PT-natural note. Default. Best general-purpose anchor.**     |
| A-3        | ~127    | ~27,867 Hz          | Anchor near brightness ceiling — don't trigger below A-3.      |
| B-3 / C-4  | ~124    | ~28,604 Hz          | Hardware ceiling. Need source content meant to play that high. |

Effective Nyquist is half the playback rate, so default 16574 Hz gives ~8.3 kHz Nyquist at C-3 — cymbal air above that gets filtered. If your sample lives in a higher register, anchor higher: `-N A-3` stores ~27867 Hz so a sample triggered at A-3 reproduces full ~14 kHz Nyquist (just don't trigger below A-3 or you'll under-sample and alias).

Use `-N` to anchor original pitch to a different OctaMED note: `-N C-2` for low-register playing, `-N A-3` to push toward Paula's ceiling, etc. The `-r` flag accepts an explicit Hz value if you'd rather think in rates than notes.

### Why 4-channel mode is the highest-fidelity option

OctaMED's `CH.MODE: HQ` setting on the PLAY panel only matters in 5/6/7/8-channel **Split Channel Mode**, where Paula's 4 hardware voices each carry two software-mixed software voices. The trade-offs there:

- 5–8ch with HQ off: software mixer runs at ~15.8 kHz, runs on stock 68000.
- 5–8ch with HQ on: mixer runs at ~28.9 kHz, needs 68020+ accelerator.
- Switching into split mode prompts “Halve samples?” (default yes), which downsamples loaded instruments to ~7-bit so two voices can sum into one channel without clipping. Hold **Shift** while clicking `LOAD: INSTR` to skip halving — only safe for instruments on the un-split hardware channels.
- 4-channel mode has no software mixer; samples go straight to Paula DMA at full 8-bit. **This is the highest-fidelity path.**
- Also turn `FILTER` off on the PLAY panel — that's Paula's ~3 kHz LED low-pass and it kills the top end on samples that would otherwise reach the hardware ceiling.

If you need >28.6 kHz playback rates or >4 voices without halving, the upgrade path is OctaMED Soundstudio's Mix mode (free mixing frequency up to ~56 kHz, pseudo-14-bit Paula output) — not a different setting in V4.

## Examples

**Simple conversion:**

```bash
./amiga_sample_convert.sh kick.wav
# → kick.iff (16574 Hz — trigger at C-3 in OctaMED 4-channel mode for original pitch)
```

**Anchor original pitch to a different note (e.g. brighter samples meant to play high):**

```bash
./amiga_sample_convert.sh -N A-3 hat.wav
# → hat.iff (~27867 Hz, ~14 kHz Nyquist; play at A-3, don't trigger below)
```

**Normalize and convert at ProTracker rate:**

```bash
./amiga_sample_convert.sh -n -r 8363 snare.wav
# → snare.iff (8363 Hz, normalized to 0 dBFS)
```

**Preview conversion plan without writing anything:**

```bash
./amiga_sample_convert.sh -p -r 22050 pad.aiff
```

**Batch convert with A500 filter character:**

```bash
./amiga_sample_convert.sh -b -n -l -r 16726 -o ./amiga_kit *.wav
# → ./amiga_kit/*.iff (all normalized, 4.9 kHz A500 LPF applied)
```

**SP-1200 style — low rate, no dither (truncation artifacts):**

```bash
./amiga_sample_convert.sh -D -r 8363 breakbeat.wav
# → breakbeat.iff (harsh 8-bit truncation, lo-fi character)
```

**Explicit output name:**

```bash
./amiga_sample_convert.sh -n -r 16726 "My Long Sample Name.wav" bd_808.iff
```

**Trim dead air from a vinyl rip before converting:**

```bash
./amiga_sample_convert.sh -t -n stab.wav
```

**Crunchy Amiga jungle-style break (pre-pitch for aliasing):**

```bash
./amiga_sample_convert.sh -n -P 24 amen.wav
# → amen_P24.iff — play 24 semis LOWER than normal in OctaMED
#   (e.g. C-1 instead of C-3) to restore original pitch. Paula's
#   nearest-neighbor resample generates the classic crunchy aliasing.
```

**Warbly phase-vocoder texture (duration preserved):**

```bash
./amiga_sample_convert.sh -V 12 pad.wav
# → pad_V12.iff — pitched up one octave, same duration,
#   with cyclic window artifacts. Play at the original note.
```

## What the flags actually do

**Dither (`-d` / `-D`):** When reducing from 16-bit (or higher) to 8-bit, you lose the bottom bits. TPDF dither (on by default) adds shaped noise to randomize the rounding, which sounds like a faint hiss but preserves low-level detail. Disabling dither with `-D` truncates instead, which produces harsher quantization artifacts ala the SP-1200. Use `-D` when you _want_ grit.

**A500 low-pass (`-l`):** The Amiga 500's analog output stage had an always-on ~4.9 kHz low-pass (6 dB/oct) that rolled off highs. This flag emulates that filter. Use `-f 3300` instead if you want the switchable "LED filter" (the steeper cutoff engaged by toggling the power LED). Skip `-l` entirely if your MiSTer Minimig core is already applying A500 filtering — double-filtering sounds muddy.

**Normalize (`-n`):** Maximizes the signal to 0 dBFS before converting to 8-bit. Important because 8-bit only gives you ~48 dB of dynamic range — a quiet source signal wastes bits on silence. Almost always worth enabling unless you're deliberately preserving relative levels across a batch.

**Rate conversion:** Sox's very-high-quality sinc resampler handles anti-alias filtering during downsampling, so you won't get unintended aliasing from the rate conversion itself. Any aliasing character you want should come from OctaMED's playback engine when pitch-shifting, or from the pre-pitch trick below.

**Pre-pitch for aliasing (`-P SEMI`):** Uses sox's `speed` effect to raw-resample the sample upward (tape-speed-up style) before writing the IFF. Playing the pitched-up sample back at a correspondingly lower note in OctaMED cancels the pitch shift — but Paula's nearest-neighbor playback math generates aliasing on the way back down. This is the classic crunchy jungle/breakcore Amiga sound. `+12` halves the sample's duration and shifts it up one octave; play at C-2 to restore the original pitch (instead of C-3). Typical useful range is `7` to `24`. The anti-alias LPF is automatically bypassed when `-P` is used, since aliasing is the point. Extreme values (> 5 octaves) warn but proceed.

**Auto-scaled stored rate with `-P`/`-V`:** When you pitch up and play back lower, Paula's actual playback period is multiplied by `2^(SEMI/12)`, leaving plenty of headroom below its period-124 hardware floor. To take advantage of that, the stored 8SVX rate is automatically scaled up by the same factor (capped at the format ceiling of 65535 Hz) so Paula sees full bandwidth at the played-back note rather than at C-3. Pass `-r RATE` explicitly to opt out. Examples with the default base of 28604: `-P 12` → stored at 57208 Hz; `-P 24` → capped at 65535 Hz.

**Vocoder pitch (`-V SEMI`):** Uses sox's `pitch` effect (phase vocoder), which shifts pitch while preserving duration. The tradeoff is cyclic window-crossfade artifacts that sound warbly and glitchy — which is itself a distinctive IDM/breakcore/vaporwave texture. Play the sample at its original note in OctaMED; no pitch compensation needed. Mutually exclusive with `-P`, and also bypasses the anti-alias LPF.

## Output format

The script produces standard IFF 8SVX files:

```text
FORM <size> 8SVX
  VHDR <20>
    oneShotHiSamples : ULONG   (sample count)
    repeatHiSamples  : ULONG   (0 = no loop)
    samplesPerHiCycle: ULONG   (0)
    samplesPerSec    : UWORD   (target rate)
    ctOctave         : UBYTE   (1)
    sCompression     : UBYTE   (0 = uncompressed)
    volume           : ULONG   (0x00010000 = 1.0 fixed-point)
  BODY <size>
    <raw 8-bit signed PCM>
```

Loop points are not set by the script. Set them in OctaMED's sample editor after loading.

The IFF writer is built in pure bash/python (no sox 8SVX support needed) for maximum portability. Odd-length BODY chunks are padded to even length per IFF spec.

## Self-test

```bash
./amiga_sample_convert.sh --self-test
```

Runs a suite of checks covering IFF structure, sample rate accuracy, normalization, pad byte handling, extreme input formats (192 kHz/32-bit float), signed encoding, filename sanitization, A500 LPF behavior, pre-pitch aliasing (verifies `-P` shortens duration and bypasses the anti-alias LPF so highs are preserved), and vocoder pitch (verifies `-V` preserves duration). Requires sox. Cleans up after itself.

## OctaMED notes

- IFF 8SVX is the native sample format for OctaMED 4 (and ProTracker, etc.)
- Max sample memory depends on your Amiga's chip RAM
- OctaMED supports up to 8 channels (4 hardware + 4 software-mixed)
- Filenames are auto-truncated to 24 characters with spaces → underscores
- The script warns if estimated output exceeds 500 KB (significant for stock Amigas)
- When you use `-P`, remember to transpose DOWN in OctaMED by the same number of semitones to restore the original pitch — that's where the aliasing character comes from

## Transfer to Amiga

Once converted, copy your `.iff` files to your Amiga via whatever method you use — Compact Flash card, serial transfer, Aminet, etc. The files are ready to load directly into OctaMED's sample slots.

For a one-click "convert + upload to a network share" workflow on macOS (auto-mounts an SMB target like a MiSTer's `sdcard` and copies the `.iff` straight there), see [macos/README.md](macos/README.md#smb-upload-workflow).
