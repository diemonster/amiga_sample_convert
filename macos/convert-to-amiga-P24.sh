#!/bin/zsh
#
# convert-to-amiga-P24.sh
#
# Variant wrapper that pitches up 24 semitones for the classic crunchy
# Amiga jungle/breakcore aliasing workflow. Play the resulting .iff at C-1
# in OctaMED to restore original pitch.

export AMIGA_CONVERT_FLAGS="-P 24"
exec "${0:A:h}/convert-to-amiga.sh" "$@"
