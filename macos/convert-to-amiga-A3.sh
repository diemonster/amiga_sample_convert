#!/bin/zsh
#
# convert-to-amiga-A3.sh
#
# Variant wrapper that anchors the converted sample's original pitch to
# A-3 in OctaMED 4-channel mode. The conversion rate (~27867 Hz) gives
# Paula's full PAL bandwidth (~14 kHz Nyquist) — useful for breaks,
# loops, and any sample with HF energy you want to preserve.
#
# Play the resulting .iff at A-3 in OctaMED to hear original pitch and
# tempo. Don't trigger below A-3 or you'll under-sample and alias.

export AMIGA_CONVERT_FLAGS="-N A-3"
exec "${0:A:h}/convert-to-amiga.sh" "$@"
