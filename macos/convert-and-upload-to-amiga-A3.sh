#!/bin/zsh
#
# convert-and-upload-to-amiga-A3.sh
#
# Variant: anchor original pitch to A-3 (~27867 Hz, near Paula's PAL
# bandwidth ceiling) and upload to the configured SMB share. Use for
# breaks, loops, and bright samples where HF detail matters. Play at A-3
# in OctaMED 4-channel mode.

export AMIGA_CONVERT_FLAGS="-N A-3"
exec "${0:A:h}/convert-and-upload-to-amiga.sh" "$@"
