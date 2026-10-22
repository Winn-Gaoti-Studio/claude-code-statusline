#!/bin/bash
set -f
# Byte-wise C locale for the whole script, so cell_width, split_chars and every
# ${#var} count bytes whatever the caller's locale. Switching per call with
# `local LC_ALL=C` inside $(...) intermittently yields empty output under
# bash 5.3 when no locale is inherited.
export LC_ALL=C

input=$(cat)

if [ -z "$input" ]; then
    printf "Claude"
    exit 0
fi

cache_helper="$HOME/.claude/lib/statusline-cache.sh"
if [ -r "$cache_helper" ]; then
    . "$cache_helper" >/dev/null 2>&1 || true
fi

# ── Colors ──────────────────────────────────────────────
# One pastel family of similar lightness and saturation, used by every segment:
# accents mark identity (model and directory blue, branch lavender), the
# ok → warn → high → crit scale marks state (context, cache, usage, bars), text
# marks labels, and dim marks secondary detail.
accent_rgb='130;170;255'
accent2_rgb='195;165;255'
text_rgb='205;210;220'
ok_rgb='125;205;160'
warn_rgb='225;195;110'
high_rgb='240;160;110'
crit_rgb='240;120;135'
accent="\033[38;2;${accent_rgb}m"
accent_bold="\033[1;38;2;${accent_rgb}m"
accent2="\033[38;2;${accent2_rgb}m"
text="\033[38;2;${text_rgb}m"
ok="\033[38;2;${ok_rgb}m"
warn="\033[38;2;${warn_rgb}m"
high="\033[38;2;${high_rgb}m"
crit="\033[38;2;${crit_rgb}m"
dim='\033[2m'
reset='\033[0m'

sep=" ${dim}│${reset} "

# ── Helpers ─────────────────────────────────────────────
format_tokens() {
    local num=$1
    if [ "$num" -ge 1000000 ]; then
        awk "BEGIN {printf \"%.1fm\", $num / 1000000}"
    elif [ "$num" -ge 1000 ]; then
        awk "BEGIN {printf \"%.0fk\", $num / 1000}"
    else
        printf "%d" "$num"
    fi
}

# cell_width and split_chars are kept identical in subagent-statusline.sh; the
# smoke test compares the two copies.
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

truncate_middle() {
    # Cap a string to maxlen cells with a single-char ellipsis "…" in the
    # middle, preserving the head and tail equally. p10k-style — long branches
    # and worktree slugs stay recognizable at both ends. Cuts fall between
    # whole characters.
    local s=$1 maxlen=$2 head="" tail="" w=0 i
    cell_width "$s"
    if [ "$_cw" -le "$maxlen" ]; then
        printf "%s" "$s"
        return
    fi
    local keep=$(( (maxlen - 1) / 2 ))
    split_chars "$s"
    for (( i = 0; i < ${#_chars[@]}; i++ )); do
        [ $(( w + _cwidths[i] )) -gt "$keep" ] && break
        head+=${_chars[i]}
        w=$(( w + _cwidths[i] ))
    done
    w=0
    for (( i = ${#_chars[@]} - 1; i >= 0; i-- )); do
        [ $(( w + _cwidths[i] )) -gt "$keep" ] && break
        tail=${_chars[i]}$tail
        w=$(( w + _cwidths[i] ))
    done
    printf "%s…%s" "$head" "$tail"
}

color_for_pct() {
    local pct=$1
    if [ "$pct" -ge 90 ]; then printf "$crit"
    elif [ "$pct" -ge 70 ]; then printf "$high"
    elif [ "$pct" -ge 50 ]; then printf "$warn"
    else printf "$ok"
    fi
}

# Cache hit ratio runs the other way: a high percentage is the healthy state.
color_for_hit() {
    local pct=$1
    if [ "$pct" -ge 80 ]; then printf "$ok"
    elif [ "$pct" -ge 60 ]; then printf "$warn"
    elif [ "$pct" -ge 40 ]; then printf "$high"
    else printf "$crit"
    fi
}

short_miss_cause() {
    case "$1" in
        tools_changed)         printf "tools" ;;
        system_prompt_changed) printf "system prompt" ;;
        ttl_expired_5m)        printf "ttl 5m" ;;
        ttl_expired_1h)        printf "ttl 1h" ;;
        likely_server_side)    printf "server" ;;
        *)                     printf "%s" "$1" ;;
    esac
}

visible_len() {
    # Terminal cells a segment occupies, stored in _vlen: expand the literal
    # \033 color codes, drop every SGR sequence, then measure with cell_width.
    local plain re=$'\033''\[[0-9;]*m'
    printf -v plain '%b' "$1"
    while [[ $plain =~ $re ]]; do
        plain=${plain//"${BASH_REMATCH[0]}"/}
    done
    cell_width "$plain"
    _vlen=$_cw
}

layout_segments() {
    # Join segments with sep into _layout. With a known width, start a new row
    # whenever the next segment would overflow the current one; without it,
    # keep a single row.
    local out="" row_len=0 seg
    for seg in "$@"; do
        [ -z "$seg" ] && continue
        if [ "$max_width" -gt 0 ]; then
            visible_len "$seg"
            if [ -z "$out" ]; then
                out="$seg"
                row_len=$_vlen
                continue
            fi
            if [ $(( row_len + 3 + _vlen )) -gt "$max_width" ]; then
                out+="\n${seg}"
                row_len=$_vlen
                continue
            fi
            row_len=$(( row_len + 3 + _vlen ))
        elif [ -z "$out" ]; then
            out="$seg"
            continue
        fi
        out+="${sep}${seg}"
    done
    _layout="$out"
}

build_bar() {
    local pct=$1
    local width=$2
    [ "$pct" -lt 0 ] 2>/dev/null && pct=0
    [ "$pct" -gt 100 ] 2>/dev/null && pct=100

    local filled=$(( pct * width / 100 ))
    local denom=$(( width - 1 ))
    [ "$denom" -lt 1 ] && denom=1

    # Per-cell RGB interpolation along the palette's ok → warn → high → crit.
    # Filled cells take the gradient at their own bar position; empty cells
    # form a dim track. DOUBLE HORIZONTAL ═ is a box-drawing extender, so
    # cells tile edge-to-edge with no seams (unlike geometric ▬), and its
    # two parallel strokes give noticeably more vertical presence than the
    # single-stroke ━ while staying vertically centered.
    local i t sub r g b r1 g1 b1 r2 g2 b2
    for ((i=0; i<width; i++)); do
        if [ "$i" -lt "$filled" ]; then
            t=$(( i * 100 / denom ))
            if [ "$t" -le 50 ]; then
                IFS=';' read -r r1 g1 b1 <<< "$ok_rgb";   IFS=';' read -r r2 g2 b2 <<< "$warn_rgb"; sub=$(( t * 2 ))
            elif [ "$t" -le 75 ]; then
                IFS=';' read -r r1 g1 b1 <<< "$warn_rgb"; IFS=';' read -r r2 g2 b2 <<< "$high_rgb"; sub=$(( (t - 50) * 4 ))
            else
                IFS=';' read -r r1 g1 b1 <<< "$high_rgb"; IFS=';' read -r r2 g2 b2 <<< "$crit_rgb"; sub=$(( (t - 75) * 4 ))
            fi
            r=$(( (r1*(100-sub) + r2*sub) / 100 ))
            g=$(( (g1*(100-sub) + g2*sub) / 100 ))
            b=$(( (b1*(100-sub) + b2*sub) / 100 ))
            printf "\033[0;38;2;%d;%d;%dm═" "$r" "$g" "$b"
        else
            printf "\033[0;2m═"
        fi
    done
    printf "\033[0m"
}

iso_to_epoch() {
    local iso_str="$1"

    local epoch
    epoch=$(date -d "${iso_str}" +%s 2>/dev/null)
    if [ -n "$epoch" ]; then
        echo "$epoch"
        return 0
    fi

    local stripped="${iso_str%%.*}"
    stripped="${stripped%%Z}"
    stripped="${stripped%%+*}"
    stripped="${stripped%%-[0-9][0-9]:[0-9][0-9]}"

    if [[ "$iso_str" == *"Z"* ]] || [[ "$iso_str" == *"+00:00"* ]] || [[ "$iso_str" == *"-00:00"* ]]; then
        epoch=$(env TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$stripped" +%s 2>/dev/null)
    else
        epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$stripped" +%s 2>/dev/null)
    fi

    if [ -n "$epoch" ]; then
        echo "$epoch"
        return 0
    fi

    return 1
}

format_reset_time() {
    # Native stdin fields carry Unix epoch seconds; the usage API cache carries
    # ISO-8601 strings.
    local when="$1"
    [ -z "$when" ] || [ "$when" = "null" ] && return

    local epoch
    case "$when" in
        *[!0-9]*) epoch=$(iso_to_epoch "$when") ;;
        *) epoch="$when" ;;
    esac
    [ -z "$epoch" ] && return

    local diff=$(( epoch - now_epoch ))

    if [ "$diff" -le 0 ]; then
        printf "now"
        return
    fi

    local days=$(( diff / 86400 ))
    local hours=$(( (diff % 86400) / 3600 ))
    local minutes=$(( (diff % 3600) / 60 ))

    local result=""
    if [ "$days" -gt 0 ]; then
        result="in ${days}d"
        [ "$hours" -gt 0 ] && result="${result} ${hours}h"
    elif [ "$hours" -gt 0 ]; then
        result="in ${hours}h"
        [ "$minutes" -gt 0 ] && result="${result} ${minutes}m"
    else
        result="in ${minutes}m"
    fi

    if [ "$compact" = "true" ]; then
        result=${result#in }
        result=${result// /}
    fi
    printf "%s" "$result"
}

read_git_cache() {
    # Read the Git result for this directory from $git_cache_file. Set
    # git_branch, git_dirty and main_repo only if the file is complete, has the
    # key $git_cache_key, and is younger than the TTL. Any other state returns 1.
    # Only a regular file is read: a read from a FIFO can block the render.
    local key ts branch dirty repo end
    [ -f "$git_cache_file" ] && [ -r "$git_cache_file" ] || return 1
    {
        IFS= read -r key && IFS= read -r ts && IFS= read -r branch &&
            IFS= read -r dirty && IFS= read -r repo && IFS= read -r end
    } 2>/dev/null <"$git_cache_file" || return 1
    [ "$key" = "$git_cache_key" ] && [ "$end" = "end" ] || return 1
    case "$ts" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "${#ts}" -le 12 ] || return 1
    [ "$(( now_epoch - ts ))" -ge 0 ] && [ "$(( now_epoch - ts ))" -lt "$git_ttl" ] || return 1
    git_branch=$branch
    git_dirty=$dirty
    main_repo=$repo
}

write_git_cache() {
    # Write the Git result atomically. The temporary file lives in the same
    # directory, so mv replaces the old file in one step. A failure is silent.
    (
        umask 077
        tmp="$git_cache_file.$$"
        [ ! -d "$git_cache_file" ] || exit 1
        [ -d "$git_cache_dir" ] || mkdir -p "$git_cache_dir" || exit 1
        printf '%s\n%s\n%s\n%s\n%s\nend\n' "$git_cache_key" "$now_epoch" \
            "$git_branch" "$git_dirty" "$main_repo" >"$tmp" || { rm -f "$tmp"; exit 1; }
        mv -f "$tmp" "$git_cache_file" || { rm -f "$tmp"; exit 1; }
    ) >/dev/null 2>&1 || true
}

# ── Extract JSON data ───────────────────────────────────
# rate_limits and prompt_cache are absent until the first API response, and
# each rate-limit window can be absent on its own; a non-number maps to "".
eval "$(jq -r '
  def num: if type == "number" then . else empty end;
  def obj: if type == "object" then . else {} end;
  (.rate_limits | obj) as $rl |
  (.prompt_cache | obj) as $pc |
  "model_name="   + (.model.display_name // "Claude" | @sh),
  "size="         + (.context_window.context_window_size // 0 | tostring | @sh),
  "pct_used="     + (.context_window.used_percentage // 0 | floor | tostring | @sh),
  "input_tokens=" + (.context_window.current_usage.input_tokens // 0 | tostring | @sh),
  "cache_create=" + (.context_window.current_usage.cache_creation_input_tokens // 0 | tostring | @sh),
  "cache_read="     + (.context_window.current_usage.cache_read_input_tokens // 0 | tostring | @sh),
  "cwd="            + (.cwd // "" | @sh),
  "git_worktree="   + (.workspace.git_worktree // "" | @sh),
  "effort_level="   + (.effort.level // "" | @sh),
  "rl_five_pct="    + (($rl.five_hour | obj | .used_percentage | num | round | tostring) // "" | @sh),
  "rl_five_reset="  + (($rl.five_hour | obj | .resets_at | num | floor | tostring) // "" | @sh),
  "rl_seven_pct="   + (($rl.seven_day | obj | .used_percentage | num | round | tostring) // "" | @sh),
  "rl_seven_reset=" + (($rl.seven_day | obj | .resets_at | num | floor | tostring) // "" | @sh),
  "pc_observed="    + ($pc.caching_observed == true | tostring | @sh),
  "pc_warm="        + ($pc.warm == true | tostring | @sh),
  "pc_hit="         + (($pc.hit_ratio | num | . * 100 | round | tostring) // "" | @sh),
  "pc_expires="     + (($pc.expires_at | num | floor | tostring) // "" | @sh),
  "pc_recache="     + (($pc.recache_tokens_if_cold | num | floor | tostring) // "" | @sh),
  "pc_misses="      + (($pc.misses | num | floor | tostring) // "0" | @sh),
  "pc_cause="       + (($pc.last_miss_cause | obj | .causes | if type == "array" then .[0] else empty end | strings) // "" | @sh)
' <<< "$input")"
[ "$size" -eq 0 ] 2>/dev/null && size=200000

# Context size counts input only (fresh, cache writes, cache reads), the same
# formula as used_percentage; output tokens are not part of the context.
current=$(( input_tokens + cache_create + cache_read ))

used_tokens=$(format_tokens $current)
total_tokens=$(format_tokens $size)

now_epoch=$(date +%s)

# Claude Code sets COLUMNS to the terminal width (v2.1.153+); reserve four
# cells for its own row padding. Without COLUMNS every line stays one row at
# the full-width sizes. Below 100 columns, for example in a split pane, the
# bars are shorter and every segment uses its compact form: 5h and 7d labels,
# reset times such as 1h38m, and no secondary words. The width alone selects
# the form, so the form does not change between renders as the content changes.
max_width=0
bar_width=6
compact=false
case "${COLUMNS:-}" in
    ''|*[!0-9]*) ;;
    *)
        max_width=$(( COLUMNS - 4 ))
        if [ "$COLUMNS" -lt 100 ]; then
            bar_width=5
            compact=true
        fi
        ;;
esac
five_hour_label="current"
seven_day_label="weekly"
if [ "$compact" = "true" ]; then
    five_hour_label="5h"
    seven_day_label="7d"
fi

reset_suffix() {
    # The reset marker and time for $1, or nothing when the time is unknown.
    [ -z "$1" ] && return
    if [ "$compact" = "true" ]; then
        printf " ${dim}⟳${reset}${text}%s${reset}" "$1"
    else
        printf " ${dim}⟳${reset} ${text}%s${reset}" "$1"
    fi
}

settings_path="$HOME/.claude/settings.json"

# Prefer the live session effort level from stdin; fall back to the persisted config.
effort="$effort_level"
if [ -z "$effort" ]; then
    if [ -f "$settings_path" ]; then
        effort=$(jq -r '.effortLevel // "default"' "$settings_path" 2>/dev/null)
    fi
fi
[ -z "$effort" ] && effort="default"

# Ultracode has no stdin field (unlike effort.level) — it only ever lives in
# settings.json as a top-level sibling of effortLevel — so this read always
# runs, independent of whether effort above came from stdin or the fallback.
# The badge therefore shows the configured default: a session-only toggle via
# /effort (Tab, or `/effort ultracode on|off`) is invisible here until Claude
# Code reports ultracode on stdin (anthropics/claude-code#69068).
ultracode_enabled="false"
if [ -f "$settings_path" ]; then
    ultracode_enabled=$(jq -r '.ultracode // false' "$settings_path" 2>/dev/null)
fi
[ "$ultracode_enabled" = "true" ] || ultracode_enabled="false"

# ── LINE 1: Model+Effort │ Context % │ Directory (branch) ──
pct_color=$(color_for_pct "$pct_used")
[ -z "$cwd" ] && cwd=$(pwd)
dirname=$(basename "$cwd")

git_branch=""
git_dirty=""
main_repo=""

# Every refresh of every session runs this probe, and the status scan is costly
# in a large repository. Keep the result per directory for CLAUDE_STATUSLINE_GIT_TTL
# seconds (default 30). A value of 0 turns the cache off. A missing, corrupt or
# unwritable cache falls back to the live probe. A value that is not a number of
# 1 to 9 digits is invalid and gives the default.
git_ttl=${CLAUDE_STATUSLINE_GIT_TTL:-30}
case "$git_ttl" in
    ''|*[!0-9]*) git_ttl=30 ;;
esac
[ "${#git_ttl}" -le 9 ] || git_ttl=30
# GIT_DIR, GIT_WORK_TREE, GIT_COMMON_DIR and GIT_INDEX_FILE change the repository
# or the index that Git reads, but the cache key has only the directory. If one
# of them is set, the cache is off.
if [ -n "${GIT_DIR+x}${GIT_WORK_TREE+x}${GIT_COMMON_DIR+x}${GIT_INDEX_FILE+x}" ]; then
    git_ttl=0
fi
git_cache_dir=${CLAUDE_STATUSLINE_RUNTIME_DIR:-/tmp/claude}
git_cache_file=""
git_cache_key="${cwd}|${git_worktree:+w}"
if [ "$git_ttl" -gt 0 ]; then
    case "$cwd" in
        *$'\n'*) ;;
        *)
            git_cache_hash=$(printf '%s' "$cwd" | cksum 2>/dev/null)
            git_cache_hash=${git_cache_hash// /-}
            [ -n "$git_cache_hash" ] && git_cache_file="$git_cache_dir/statusline-git-$git_cache_hash"
            ;;
    esac
fi

if [ -z "$git_cache_file" ] || ! read_git_cache; then
    if git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        git_branch=$(git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null)
        # A jj workspace leaves Git HEAD detached, and a bookmark takes the place of
        # the branch: show the newest bookmark on the working-copy commit or its
        # parent. --ignore-working-copy and --at-op @ keep the query read-only (no
        # snapshot, no new operation), so a render never changes the operation log.
        if [ -z "$git_branch" ] && command -v jj >/dev/null 2>&1; then
            git_branch=$(cd "$cwd" 2>/dev/null && jj --ignore-working-copy --at-op @ --no-pager --color never \
                log --no-graph -r 'latest((@ | @-) & bookmarks())' \
                -T 'local_bookmarks.map(|b| b.name()).join(" ")' 2>/dev/null)
        fi
        # Untracked files are not scanned: that scan costs most of the time.
        if [ -n "$(git -C "$cwd" --no-optional-locks status --porcelain --untracked-files=no 2>/dev/null)" ]; then
            git_dirty="*"
        fi
        if [ -n "$git_worktree" ] && [ -n "$git_branch" ]; then
            common_git=$(git -C "$cwd" rev-parse --git-common-dir 2>/dev/null)
            if [ -n "$common_git" ]; then
                case "$common_git" in
                    /*) ;;
                    *) common_git="$cwd/$common_git" ;;
                esac
                main_repo=$(basename "$(dirname "$common_git")")
            fi
        fi
    fi
    [ -n "$git_cache_file" ] && write_git_cache
fi

# Model and effort are grouped: a plain space (not sep) keeps them visually
# adjacent, matching the same convention used for dir+branch below. When
# ultracode is on the word follows the effort label, not in place of it: since
# Claude Code 2.1.284 ultracode is a toggle independent of the effort level, so
# both facts are true at once and both are worth showing.
# The whole segment takes the accent so it reads as one unit; weight alone
# separates the bold model name from the effort level and ultracode words.
model_segment="${accent_bold}${model_name}${reset} ${accent}${effort}"
[ "$ultracode_enabled" = "true" ] && model_segment+=" ultracode"
model_segment+="${reset}"
context_segment="${pct_color}${pct_used}%${reset} ${dim}${used_tokens}/${total_tokens}${reset}"
# Dir/branch segment. In worktree mode dirname == worktree slug (the basename
# of .worktrees/<user>/<scope>) and the branch is <user>/<scope>, so the
# slug would appear twice; we replace the dirname with the MAIN repo name
# (derived from the worktree's common .git dir — its parent IS the main
# checkout, so basename gives the repo name) and strip the implicit user/
# prefix from the branch. Long names get middle-ellipsis truncation so the
# head and tail (issue ID, last word) stay recognizable.
if [ -n "$git_worktree" ] && [ -n "$git_branch" ]; then
    [ -z "$main_repo" ] && main_repo="$dirname"
    display_branch="${git_branch#*/}"
fi

build_dir_segment() {
    # $1/$2: directory and branch caps. Sets _dir_segment.
    local dir_cap=$1 branch_cap=$2
    if [ -n "$git_worktree" ] && [ -n "$git_branch" ]; then
        _dir_segment="${accent}$(truncate_middle "$main_repo" "$dir_cap")${reset} 🌳 ${accent2}$(truncate_middle "$display_branch" "$branch_cap")${crit}${git_dirty}${reset}"
    elif [ -n "$git_branch" ]; then
        _dir_segment="${accent}$(truncate_middle "$dirname" "$dir_cap")${reset}"
        _dir_segment+=" ${accent2}($(truncate_middle "$git_branch" "$branch_cap")${crit}${git_dirty}${accent2})${reset}"
    else
        _dir_segment="${accent}$(truncate_middle "$dirname" "$dir_cap")${reset}"
    fi
}

# Render a stable cache snapshot and ask the helper to refresh stale data in a
# detached process for the next invocation. Helper failure never blocks output.
usage_data=""
if declare -F claude_statusline_read_usage >/dev/null 2>&1; then
    usage_data="$(claude_statusline_read_usage 2>/dev/null)" || usage_data=""
fi
if declare -F claude_statusline_refresh_usage_async >/dev/null 2>&1; then
    claude_statusline_refresh_usage_async || true
fi

# ── Rate limit lines ────────────────────────────────────
rate_segments=()
extra_segment=""
extra_reset=""
cache_valid="false"
five_hour_pct=""
five_hour_reset_at=""
seven_day_pct=""
seven_day_reset_at=""

if [ -n "$usage_data" ] && echo "$usage_data" | jq -e . >/dev/null 2>&1; then
    cache_valid="true"

    # Single jq pass over the cache instead of ~10 separate jq/awk subprocesses.
    # Percentages arrive pre-rounded; dollar amounts come through as plain
    # numbers and are %.2f-formatted with a bash builtin below. extra_unlimited
    # is true when extra usage is on but has no monthly cap (limit null or 0).
    eval "$(echo "$usage_data" | jq -r '
      "extra_enabled="       + ((.extra_usage.is_enabled // false)        | tostring | @sh),
      "extra_unlimited="     + (((.extra_usage.monthly_limit // 0) == 0)  | tostring | @sh),
      "five_hour_pct="       + ((.five_hour.utilization // 0)  | round | tostring | @sh),
      "seven_day_pct="       + ((.seven_day.utilization // 0)  | round | tostring | @sh),
      "five_hour_reset_at="  + ((.five_hour.resets_at // "")             | @sh),
      "seven_day_reset_at="  + ((.seven_day.resets_at // "")            | @sh),
      "extra_used_usd="      + ((.extra_usage.used_credits // 0)  / 100  | tostring | @sh),
      "extra_limit_usd="     + ((.extra_usage.monthly_limit // 0) / 100  | tostring | @sh)
    ')"
fi

# Each 5h/7d window has two sources that lag in different ways. Native stdin
# rate_limits need no network or credentials but change only when this session
# gets an API response, so an idle session keeps an old snapshot while other
# sessions spend the same account quota. The usage API cache is account-wide
# but polled at most once a minute, and stdin is the only source when the API
# is unreachable. Resets more than five minutes apart are different windows, so
# the later one is current; within one window usage only grows, so the higher
# percentage is the fresher reading.
merge_window() {
    # $1/$2: stdin percentage and epoch reset; $3/$4: cache percentage and
    # ISO reset. Sets _pct and _reset.
    local stdin_pct=$1 stdin_reset=$2 cache_pct=$3 cache_reset=$4
    local cache_epoch="" gap
    _pct="$cache_pct"
    _reset="$cache_reset"
    [ -z "$stdin_pct" ] && return
    if [ -z "$cache_pct" ]; then
        _pct="$stdin_pct"
        _reset="$stdin_reset"
        return
    fi
    [ -n "$cache_reset" ] && cache_epoch=$(iso_to_epoch "$cache_reset")
    if [ -n "$stdin_reset" ] && [ -n "$cache_epoch" ]; then
        gap=$(( stdin_reset - cache_epoch ))
        [ "$gap" -lt -300 ] && return
        if [ "$gap" -gt 300 ]; then
            _pct="$stdin_pct"
            _reset="$stdin_reset"
            return
        fi
    fi
    if [ "$stdin_pct" -ge "$cache_pct" ]; then
        _pct="$stdin_pct"
        [ -n "$stdin_reset" ] && _reset="$stdin_reset"
    fi
}

merge_window "$rl_five_pct" "$rl_five_reset" "$five_hour_pct" "$five_hour_reset_at"
five_hour_pct="$_pct"
five_hour_reset_at="$_reset"
merge_window "$rl_seven_pct" "$rl_seven_reset" "$seven_day_pct" "$seven_day_reset_at"
seven_day_pct="$_pct"
seven_day_reset_at="$_reset"

if [ -n "$five_hour_pct" ]; then
    five_hour_reset=$(format_reset_time "$five_hour_reset_at")
    five_hour_bar=$(build_bar "$five_hour_pct" "$bar_width")
    five_hour_pct_color=$(color_for_pct "$five_hour_pct")
    rate_segments+=("${text}${five_hour_label}${reset} ${five_hour_bar} ${five_hour_pct_color}${five_hour_pct}%${reset}$(reset_suffix "$five_hour_reset")")
fi

if [ -n "$seven_day_pct" ]; then
    seven_day_reset=$(format_reset_time "$seven_day_reset_at")
    seven_day_bar=$(build_bar "$seven_day_pct" "$bar_width")
    seven_day_pct_color=$(color_for_pct "$seven_day_pct")
    rate_segments+=("${text}${seven_day_label}${reset} ${seven_day_bar} ${seven_day_pct_color}${seven_day_pct}%${reset}$(reset_suffix "$seven_day_reset")")
fi

# Scoped weekly caps and extra usage exist only in the usage API cache.
if [ "$cache_valid" = "true" ]; then
    # Per-model scoped weekly limits (a "limits" entry with kind
    # "weekly_scoped" — Anthropic can cap a single model's weekly usage
    # independently of the aggregate five_hour/seven_day figures above, e.g.
    # today's "Fable"). Codenames rotate, so label from display_name
    # generically instead of hardcoding one; this also picks up any future
    # second scoped cap for free.
    while IFS= read -r scoped_json; do
        [ -z "$scoped_json" ] && continue
        eval "$(echo "$scoped_json" | jq -r '
          "s_name="   + (.scope.model.display_name // "" | @sh),
          "s_pct="    + ((.percent // 0)                 | round | tostring | @sh),
          "s_reset="  + (.resets_at // ""                | @sh),
          "s_active=" + (.is_active // false              | tostring | @sh)
        ')"
        [ -z "$s_name" ] && continue
        s_bar=$(build_bar "$s_pct" "$bar_width")
        s_color=$(color_for_pct "$s_pct")
        s_reset_fmt=$(format_reset_time "$s_reset")
        s_mark=""
        [ "$s_active" = "true" ] && s_mark="${text}*${reset}"
        s_seg="${text}${s_name}${reset} ${s_bar} ${s_color}${s_pct}%${reset}${s_mark}$(reset_suffix "$s_reset_fmt")"
        rate_segments+=("$s_seg")
    done < <(echo "$usage_data" | jq -c '.limits[]? | select(.kind == "weekly_scoped" and .scope.model.display_name != null)')

    if [ "$extra_enabled" = "true" ]; then
        extra_used=$(printf "%.2f" "$extra_used_usd")

        # The usage API gives no billing-cycle date, so the reset is the first
        # day of the next month. The full form shows it with or without a
        # monthly cap. The compact form omits it, so that line 1 stays on one
        # row in a split pane.
        extra_reset=$(date -v+1m -v1d +"%b %-d" 2>/dev/null | tr '[:upper:]' '[:lower:]')
        if [ -z "$extra_reset" ]; then
            extra_reset=$(date -d "$(date +%Y-%m-01) +1 month" +"%b %-d" 2>/dev/null | tr '[:upper:]' '[:lower:]')
        fi

        if [ "$extra_unlimited" = "true" ] && [ "$compact" = "true" ]; then
            extra_segment="${text}↗${reset} ${text}\$${extra_used}${reset}"
        elif [ "$extra_unlimited" = "true" ]; then
            extra_segment="${text}↗${reset} ${text}\$${extra_used} used${reset} ${dim}· unlimited${reset}"
        else
            extra_limit=$(printf "%.2f" "$extra_limit_usd")
            extra_segment="${text}↗${reset} ${text}\$${extra_used}${dim}/${reset}${text}\$${extra_limit}${reset}"
        fi
        [ "$compact" = "true" ] || extra_segment+=$(reset_suffix "$extra_reset")
    fi
fi

# ── Prompt cache (native stdin, v2.1.251+) ──────────────
# Hidden until a response reports cache tokens. Warm shows the hit ratio and
# the time left before the cached prefix goes cold; cold shows how many tokens
# the next request re-caches. Misses add their count and the likely cause of
# the latest one.
cache_segment=""
if [ "$pc_observed" = "true" ]; then
    cache_segment="${text}cache${reset}"
    [ -n "$pc_hit" ] && cache_segment+=" $(color_for_hit "$pc_hit")${pc_hit}%${reset}"

    pc_state="cold"
    if [ "$pc_warm" = "true" ]; then
        pc_state="warm"
        # A snapshot taken before expires_at still says warm once it passes.
        [ -n "$pc_expires" ] && [ "$pc_expires" -le "$now_epoch" ] && pc_state="cold"
    fi

    if [ "$pc_state" = "warm" ]; then
        cache_segment+=$(reset_suffix "$(format_reset_time "$pc_expires")")
    else
        cache_segment+=" ${accent}cold${reset}"
        if [ -n "$pc_recache" ] && [ "$pc_recache" -gt 0 ] && [ "$compact" = "true" ]; then
            cache_segment+=" ${dim}$(format_tokens "$pc_recache")${reset}"
        elif [ -n "$pc_recache" ] && [ "$pc_recache" -gt 0 ]; then
            cache_segment+=" ${dim}$(format_tokens "$pc_recache") to re-cache${reset}"
        fi
    fi

    if [ "$pc_misses" -gt 0 ] 2>/dev/null; then
        cache_segment+=" ${crit}✗${pc_misses}${reset}"
        [ -n "$pc_cause" ] && cache_segment+=" ${dim}$(short_miss_cause "$pc_cause")${reset}"
    fi
fi

# Tighter caps apply only where they help: they bring the dir segment back onto
# the line 1 row with every other line 1 segment, or the full-cap segment
# overflows even a row of its own. Otherwise a wrapped dir segment keeps its
# full caps.
build_dir_segment 24 28
if [ "$max_width" -gt 0 ]; then
    visible_len "$model_segment"
    line1_len=$_vlen
    visible_len "$context_segment"
    line1_len=$(( line1_len + 3 + _vlen ))
    for seg in "$cache_segment" "$extra_segment"; do
        [ -z "$seg" ] && continue
        visible_len "$seg"
        line1_len=$(( line1_len + 3 + _vlen ))
    done
    visible_len "$_dir_segment"
    full_dir_len=$_vlen
    if [ $(( line1_len + 3 + full_dir_len )) -gt "$max_width" ]; then
        full_dir_segment="$_dir_segment"
        build_dir_segment 16 20
        visible_len "$_dir_segment"
        if [ $(( line1_len + 3 + _vlen )) -gt "$max_width" ] && [ "$full_dir_len" -le "$max_width" ]; then
            _dir_segment="$full_dir_segment"
        fi
    fi
fi
dir_segment="$_dir_segment"

# ── Output ──────────────────────────────────────────────
# The prompt cache describes this session like the context does, so it sits beside
# the context on line 1; line 2 keeps only the account-wide usage windows.
line1_segments=("$model_segment" "$context_segment")
[ -n "$cache_segment" ] && line1_segments+=("$cache_segment")
line1_segments+=("$dir_segment")
[ -n "$extra_segment" ] && line1_segments+=("$extra_segment")
layout_segments "${line1_segments[@]}"
line1="$_layout"

line2=""
if [ "${#rate_segments[@]}" -gt 0 ]; then
    layout_segments "${rate_segments[@]}"
    line2="$_layout"
fi

printf "%b" "$line1"
[ -n "$line2" ] && printf "\n\n%b" "$line2"

exit 0
