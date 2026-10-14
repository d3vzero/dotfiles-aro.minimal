# aro-bar-audio.sh -- dipakai aro-bar dan aro-bar-refresh (di-source, bukan dijalankan):
# teks segmen SPK (output) dan MIC (input). Nama perangkat di-cache per perangkat
# default, jadi pactl/jq hanya dipanggil saat perangkat default berganti.
_AUDIO_SINK="" _AUDIO_SINK_DESC="" _AUDIO_SRC="" _AUDIO_SRC_DESC=""

_audio_desc() {   # _audio_desc sinks|sources NAME -> nama pendek untuk bar
    # "Meteor condenser microphone Analog Stereo" -> "Meteor condenser":
    # buang akhiran profil (Analog/Digital Stereo, Mono, IEC958), potong di batas kata
    pactl -f json list "$1" 2>/dev/null |
        jq -r --arg n "$2" '.[] | select(.name == $n) | .description' | head -n1 |
        sed -E 's/ (Analog|Digital|Pro|Multichannel)( Stereo| Mono| Surround[^ ]*)?( \(IEC958\))?$//; s/ (Stereo|Mono)$//' |
        awk -v max=18 '{ out = ""
            for (i = 1; i <= NF; i++) { t = out (out == "" ? "" : " ") $i; if (length(t) > max) break; out = t }
            if (out == "") out = substr($0, 1, max); print out }'
}

_audio_text() {   # _audio_text LABEL @DEFAULT_AUDIO_...@ DESC
    local v pct
    v="$(wpctl get-volume "$2" 2>/dev/null)" || { echo "~$1 -"; return; }
    pct="$(awk '{ printf "%d", $2 * 100 + 0.5 }' <<<"$v")"
    case "$v" in
        *MUTED*) echo "~$1 muted${3:+ $3}" ;;
        *)       echo "$1 $pct%${3:+ $3}" ;;
    esac
}

spk_text() {
    local d; d="$(pactl get-default-sink 2>/dev/null)"
    if [ "$d" != "$_AUDIO_SINK" ]; then _AUDIO_SINK="$d"; _AUDIO_SINK_DESC="$(_audio_desc sinks "$d")"; fi
    _audio_text SPK @DEFAULT_AUDIO_SINK@ "$_AUDIO_SINK_DESC"
}

mic_text() {
    local d; d="$(pactl get-default-source 2>/dev/null)"
    if [ "$d" != "$_AUDIO_SRC" ]; then _AUDIO_SRC="$d"; _AUDIO_SRC_DESC="$(_audio_desc sources "$d")"; fi
    _audio_text MIC @DEFAULT_AUDIO_SOURCE@ "$_AUDIO_SRC_DESC"
}
