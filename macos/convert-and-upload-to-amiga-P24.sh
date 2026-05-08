#!/bin/zsh
#
# convert-and-upload-to-amiga-P24.sh
#
# Variant: pre-pitch +24 semitones for crunchy Paula aliasing, then upload
# to the configured SMB share. Play at C-1 in OctaMED to restore pitch.

export AMIGA_CONVERT_FLAGS="-P 24"
exec "${0:A:h}/convert-and-upload-to-amiga.sh" "$@"
