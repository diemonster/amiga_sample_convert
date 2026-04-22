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

# Convert a kick drum sample (defaults to 22050 Hz, dithered 8-bit)
./amiga_sample_convert.sh kick.wav
```

## Usage

```text
./amiga_sample_convert.sh [options] input_file [output_file]
```

In single-file mode, the output filename is optional — it defaults to the input name with `.iff` extension, spaces replaced with underscores, truncated to 24 characters. When `-P` or `-V` is used, the suffix `_P<semis>` or `_V<semis>` is appended to the default name so pitched variants don't collide with the clean version.

## Options

| Flag          | Description                                                    |
| ------------- | -------------------------------------------------------------- |
| `-r RATE`     | Target sample rate in Hz (default: 22050)                      |
| `-n`          | Normalize audio to 0 dBFS before conversion                    |
| `-g GAIN`     | Apply gain in dB (e.g., `-3`, `+6`)                            |
| `-f FREQ`     | Manual anti-alias LPF cutoff in Hz                             |
| `-l`          | Apply A500-style low-pass at 4.9 kHz (always-on output filter) |
| `-t`          | Trim silence from start and end (-48 dB threshold)             |
| `-d`          | TPDF dither (default: on)                                      |
| `-D`          | Disable dither — truncate to 8-bit                             |
| `-P SEMI`     | Pre-pitch UP by SEMI semitones via raw resample (aliasing)     |
| `-V SEMI`     | Vocoder-pitch shift by SEMI semitones (duration-preserving)    |
| `-p`          | Preview: show file info and conversion plan, don't convert     |
| `-b`          | Batch mode: treat all positional args as input files           |
| `-o DIR`      | Output directory for batch mode (default: `./amiga_samples`)   |
| `--self-test` | Run built-in smoke tests                                       |
| `-h`          | Show help                                                      |

## Sample rates

| Rate     | Notes                                                           |
| -------- | --------------------------------------------------------------- |
| 8363 Hz  | ProTracker C-3 standard. Low quality, saves chip RAM.           |
| 11025 Hz | Telephony standard.                                             |
| 16726 Hz | 2× ProTracker C-3. Conservative, smaller files.                 |
| 22050 Hz | CD÷2. High quality, good general-purpose default. **(default)** |
| 27928 Hz | 4× ProTracker C-3. Near the max safe rate for PAL Amiga.        |

Paula is fixed 8-bit, so rate is the primary quality lever. The default of 22050 Hz gives clean, bright playback and is usually worth it — MiSTer Minimig cores can be configured with 2 MB of chip RAM, which makes higher rates practical for anything percussive or tonal. If you know the note you'll trigger the sample at most often, you can tune the rate to match (16726 Hz is 2× ProTracker C-3, which gives clean C-3 playback on PAL).

## Examples

**Simple conversion:**

```bash
./amiga_sample_convert.sh kick.wav
# → kick.iff (22050 Hz, 8-bit signed mono, TPDF dithered)
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
