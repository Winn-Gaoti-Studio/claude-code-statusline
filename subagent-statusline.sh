#!/bin/bash
# Subagent status line: renders one custom row per subagent shown in the agent
# panel below the prompt (Task-tool subagents and Workflow-spawned agents).
# Contract (docs/en/statusline): stdin is a single JSON object with `columns`
# (usable row width) and a `tasks` array; each task carries id/name/type/status/
# description/label/startTime/model/effort/contextWindowSize/tokenCount/
# tokenSamples/cwd. `model` is the resolved model ID, omitted until resolved;
# `effort` is a level string or a numeric token budget, omitted when the task
# inherits the session's effort.
# We emit one JSON line per row we override: {"id","content"}. Omitting a task's
# id keeps its default rendering; an empty content hides the row. `content` is
# printed as-is, so ANSI colors and OSC 8 links pass through.
#
# Palette and token humanizing intentionally mirror ~/.claude/statusline.sh so
# the two lines read as one system. On any parse miss we emit nothing, which
# leaves every row at Claude Code's default `name · description · token count`.
#
# This runs on every panel refresh, so the hot path stays fork-free: one jq
# parses the input, one jq encodes the output, and helpers return through
# globals (_ft, _trunc, _family, _pct_color) instead of $(...) subshells.
set -f
# Byte-wise C locale for the whole script, so cell_width, split_chars and every
# ${#var} count bytes whatever the caller's locale. Switching per call with
# `local LC_ALL=C` inside $(...) intermittently yields empty output under
# bash 5.3 when no locale is inherited.
export LC_ALL=C

# ── Colors (match statusline.sh) ────────────────────────
blue=$'\033[38;2;0;153;255m'
green=$'\033[38;2;0;175;80m'
red=$'\033[38;2;255;85;85m'
yellow=$'\033[38;2;230;200;0m'
orange=$'\033[38;2;255;176;85m'
dim=$'\033[2m'
reset=$'\033[0m'

# Same output as statusline.sh's awk-based format_tokens, stored in _ft. The
# thousands branch is pure arithmetic; printf "%.0f" rounds an exact half to
# even, so 2500 reads as 2k and 3500 as 4k. Millions are rare enough for a
# subagent that they keep awk's binary rounding.
format_tokens() {
    local num=$1 q r
    if [ "$num" -ge 1000000 ]; then
        _ft=$(awk -v n="$num" 'BEGIN {printf "%.1fm", n / 1000000}')
    elif [ "$num" -ge 1000 ]; then
        q=$(( num / 1000 )) r=$(( num % 1000 ))
        if [ "$r" -gt 500 ] || { [ "$r" -eq 500 ] && [ $(( q % 2 )) -eq 1 ]; }; then
            q=$(( q + 1 ))
        fi
        _ft="${q}k"
    else
        _ft=$num
    fi
}

# cell_width and split_chars are kept identical in statusline.sh; the smoke
# test compares the two copies.
cell_width() {
    # Terminal cells of plain text, stored in _cw, counted byte-wise under the
    # script-wide C locale: each double-width character's leading bytes
    # become two cells, then UTF-8 continuation bytes drop out. Double width
    # covers U+2E80-U+DFFF (CJK, kana, Hangul), fullwidth forms (U+FE30-U+FE4F,
    # U+FF00-U+FF60, U+FFE0-U+FFE6) and 4-byte sequences (emoji such as 🌳);
    # wide emoji below U+2E80, such as ⚡, still count as one cell.
    local s=$1
    s=${s//[$'\xe3'-$'\xed'$'\xf0'-$'\xf4']/WW}
    s=${s//$'\xe2'[$'\xba'-$'\xbf']/WW}
    s=${s//$'\xef\xbc'/WW}
    s=${s//$'\xef\xbd'[$'\x80'-$'\xa0']/WW}
    s=${s//$'\xef\xbf'[$'\xa0'-$'\xa6']/WW}
    s=${s//$'\xef\xb8'[$'\xb0'-$'\xbf']/WW}
    s=${s//$'\xef\xb9'[$'\x80'-$'\x8f']/WW}
    s=${s//[$'\x80'-$'\xbf']/}
    _cw=${#s}
}

split_chars() {
    # Split $1 into whole UTF-8 characters (_chars) and their cell widths
    # (_cwidths), byte-wise under the script-wide C locale.
    local s=$1 i=0 n ch b
    n=${#s}
    _chars=()
    _cwidths=()
    while [ "$i" -lt "$n" ]; do
        ch=${s:i:1}
        i=$(( i + 1 ))
        while [ "$i" -lt "$n" ]; do
            b=${s:i:1}
            case "$b" in
                [$'\x80'-$'\xbf']) ch+=$b; i=$(( i + 1 )) ;;
                *) break ;;
            esac
        done
        cell_width "$ch"
        _chars+=("$ch")
        _cwidths+=("$_cw")
    done
}

truncate_end() {
    # Cap s at maxlen cells into _trunc, ending in "…", cutting only between
    # whole characters.
    local s=$1 maxlen=$2 out="" w=0 i
    [ "$maxlen" -lt 1 ] && maxlen=1
    cell_width "$s"
    if [ "$_cw" -le "$maxlen" ]; then _trunc=$s; return; fi
    split_chars "$s"
    for (( i = 0; i < ${#_chars[@]}; i++ )); do
        [ $(( w + _cwidths[i] )) -gt $(( maxlen - 1 )) ] && break
        out+=${_chars[i]}
        w=$(( w + _cwidths[i] ))
    done
    _trunc="${out}…"
}

color_for_pct() {
    local pct=$1
    if [ "$pct" -ge 90 ]; then _pct_color=$red
    elif [ "$pct" -ge 70 ]; then _pct_color=$yellow
    elif [ "$pct" -ge 50 ]; then _pct_color=$orange
    else _pct_color=$green
    fi
}

# Resolved IDs such as claude-opus-5-5[1m] or a provider-prefixed
# us.anthropic.claude-sonnet-5-v1:0 shorten to the family word; anything else
# is shown as given, capped. Stored in _family.
model_family() {
    local m=$1 f
    case "$m" in
        *claude-*) f=${m##*claude-}; f=${f%%[-\[:@]*} ;;
        *) f=$m ;;
    esac
    truncate_end "$f" 12
    _family=$_trunc
}

# Same glyphs and colors as the effort badge in statusline.sh; a numeric token
# budget reads as a humanized count. Sets _badge and its width in _badge_len,
# empty and 0 when the task inherits the session's effort.
effort_badge() {
    local label=$1 glyph="◑" color=$dim
    _badge=""
    _badge_len=0
    case "$1" in
        '')       return ;;
        max)      glyph="●"; color=$red ;;
        xhigh)    glyph="●"; color=$orange ;;
        high)     glyph="◕"; color=$yellow ;;
        medium)   color=$green ;;
        low)      glyph="◔" ;;
        *[!0-9]*) ;;
        *)        format_tokens "$1"; label=$_ft ;;
    esac
    _badge="${color}${glyph} ${label}${reset}"
    cell_width "$label"
    _badge_len=$(( 2 + _cw ))
}

# Width of the "  family badge" segment for the current family/_badge_len.
meta_width() {
    meta_len=0
    if [ -n "$family" ]; then
        cell_width "$family"
        meta_len=$(( 2 + _cw ))
    fi
    if [ "$_badge_len" -gt 0 ]; then
        if [ "$meta_len" -gt 0 ]; then
            meta_len=$(( meta_len + 1 + _badge_len ))
        else
            meta_len=$(( 2 + _badge_len ))
        fi
    fi
}

# One jq pass: the first line is the column count, then one row per task with
# fields joined by U+001F — a non-whitespace unit separator so `read` preserves
# empty fields. A tab delimiter would collapse an empty description (tab is
# whitespace-IFS) and shift every later field left. Any tab/newline/separator
# inside a field is squashed to a space first so each task stays on exactly one
# line. Invalid JSON or a missing `tasks` array yields no rows.
jq -r '
  (.columns // 80 | tostring),
  (.tasks[]? | [
    (.id // ""), (.name // ""), (.description // .label // ""),
    (.tokenCount // 0 | tostring), (.contextWindowSize // 0 | tostring),
    (.model // "" | tostring), (.effort // "" | tostring)
  ] | map(gsub("[\t\n\r\u001f]"; " ")) | join("\u001f"))
' 2>/dev/null | {
IFS= read -r columns || exit 0
if ! [ "$columns" -eq "$columns" ] 2>/dev/null; then
    columns=80
fi
while IFS=$'\037' read -r id name desc tok ctx model effort; do
    [ -z "$id" ] && continue

    # Model family and effort badge sit between the description and the token
    # segment; each is omitted until known.
    family=""
    if [ -n "$model" ]; then model_family "$model"; family=$_family; fi
    effort_badge "$effort"

    # Token segment: dim count + fill-colored percentage, matching the main
    # statusline.sh line-1 treatment so the count recedes next to the dim
    # description and only the percentage carries the fill accent.
    tok=${tok:-0}; ctx=${ctx:-0}
    format_tokens "$tok"
    tok_h=$_ft
    if [ "$ctx" -gt 0 ] 2>/dev/null; then
        pct=$(( tok * 100 / ctx ))
        [ "$pct" -gt 100 ] && pct=100
        color_for_pct "$pct"
        tokseg="${dim}${tok_h}${reset} ${_pct_color}${pct}%${reset}"
    else
        tokseg="${dim}${tok_h}${reset}"
    fi

    # Width budget in terminal cells: keep name short, give the description
    # whatever remains after reserving room for the name, model/effort, token
    # segment and separators. When model/effort would squeeze the description
    # below its 8-cell floor, the badge goes first, then the family.
    truncate_end "$name" 22
    name=$_trunc
    cell_width "$name"
    desc_cap=$(( columns - _cw - 24 ))
    meta_width
    if [ $(( desc_cap - meta_len )) -lt 8 ] && [ "$_badge_len" -gt 0 ]; then
        _badge=""
        _badge_len=0
        meta_width
    fi
    if [ $(( desc_cap - meta_len )) -lt 8 ] && [ -n "$family" ]; then
        family=""
        meta_width
    fi
    desc_cap=$(( desc_cap - meta_len ))
    meta=""
    [ -n "$family" ] && meta="${dim}${family}${reset}"
    if [ -n "$_badge" ]; then
        [ -n "$meta" ] && meta+=" "
        meta+="$_badge"
    fi
    [ "$desc_cap" -lt 8 ] && desc_cap=8
    [ "$desc_cap" -gt 64 ] && desc_cap=64

    # Row body with no leading status glyph: the name, then the dim description
    # (two spaces between them), then model/effort and the token segment. An
    # empty name simply omits that segment so the description starts the row.
    label=""
    [ -n "$name" ] && label="${blue}${name}${reset}"
    if [ -n "$desc" ]; then
        truncate_end "$desc" "$desc_cap"
        desc_r="${dim}${_trunc}${reset}"
        if [ -n "$label" ]; then
            label+="  ${desc_r}"
        else
            label="${desc_r}"
        fi
    fi
    content="${label}"
    [ -n "$meta" ] && content+="  ${meta}"
    content+="  ${tokseg}"

    # Emit id and content as one separator-joined line; the closing jq turns
    # every row into JSON in a single process.
    printf '%s\037%s\n' "$id" "$content"
done
} | jq -cR 'split("\u001f") | {id: .[0], content: .[1]}'

exit 0
