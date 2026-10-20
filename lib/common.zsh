# hub-fzf — shared config, formatting helpers, and the fzf picker.
# Sourced by hub-fzf.plugin.zsh and by lib/update-index.zsh (standalone).

# --- configuration (override before OMZ loads plugins) -----------------------

: ${HUB_FZF_CACHE_DIR:="${XDG_CACHE_HOME:-$HOME/.cache}/hub-fzf"}
: ${HUB_FZF_MAX_MODELS:=100000}          # top-N by downloads kept in the index
: ${HUB_FZF_GGUF_ONLY:=1}                # index/search GGUF repos only (0 = whole hub)
: ${HUB_FZF_FILTER:=}                    # extra hf tag filter, e.g. "text-generation"
: ${HUB_FZF_TTL:=7d}                     # auto-update interval (suffix: s/m/h/d)
: ${HUB_FZF_AUTOUPDATE:=1}               # refresh stale index in the background
: ${HUB_FZF_DOWNLOAD_CMD:="hf download"} # command seeded on <enter> (hf)
: ${HUB_FZF_MS_DOWNLOAD_CMD:="modelscope download --model"} # same, for ms
: ${HUB_FZF_FZF_OPTS:=}                  # extra flags appended to every fzf call
: ${HUB_FZF_PREVIEW_TTL:=1d}             # cache preview metadata + quant lists this long
: ${HUB_FZF_COLOR:=1}                     # ANSI-colored columns (0 or NO_COLOR disables)
: ${HUB_FZF_PREVIEW_WINDOW:='right,60%,wrap,hidden'} # fzf --preview-window spec

# exported so the standalone scripts (updater, quants, preview) inherit
# the interactive shell's settings even when the user set them unexported
# (the common case: plain assignments in ~/.zshrc before OMZ loads)
export HUB_FZF_CACHE_DIR HUB_FZF_MAX_MODELS HUB_FZF_GGUF_ONLY HUB_FZF_FILTER HUB_FZF_TTL \
       HUB_FZF_PREVIEW_TTL

# --- small helpers ------------------------------------------------------------

_hub_fzf_cache_file() { print -r -- "$HUB_FZF_CACHE_DIR/$1.tsv" }

# With HUB_FZF_GGUF_ONLY=1 (default) only GGUF repos are indexed or searched,
# filtered server-side:
#   hf: tag filter "gguf" (plus the optional HUB_FZF_FILTER tag, ANDed)
#   ms: the "gguf" library criterion of the dolphin search API
# With 0, the whole hub is listed and GGUF repos get a "GGUF" badge column.
_hub_fzf_gguf_only() { [[ $HUB_FZF_GGUF_ONLY == 1 ]] }

# ModelScope search Criterion (JSON array) for the current setting
_hub_fzf_ms_criterion() {
  if _hub_fzf_gguf_only; then
    print -r -- '[{"category":"libraries","predicate":"contains","values":["gguf"]}]'
  else
    print -r -- '[]'
  fi
}

# jq program turning an HF /api/models page into raw index rows; the badge
# column is only emitted when the listing mixes GGUF and non-GGUF repos
_hub_fzf_hf_rows_jq() {
  if _hub_fzf_gguf_only; then
    print -r -- '.[] | [.id, (.downloads // 0), (.likes // 0)] | @tsv'
  else
    print -r -- '.[] | [.id, (.downloads // 0), (.likes // 0),
      (if (.tags // []) | any(. == "gguf") then "GGUF" else "" end)] | @tsv'
  fi
}

# what an index was crawled with — a mismatch means it must be rebuilt
# (e.g. HUB_FZF_GGUF_ONLY or HUB_FZF_FILTER changed)
_hub_fzf_scope() {  # <hf|ms>
  local base=all
  _hub_fzf_gguf_only && base=gguf
  case $1 in
    hf) print -r -- "$base${HUB_FZF_FILTER:++$HUB_FZF_FILTER}" ;;
    *)  print -r -- $base ;;
  esac
}

_hub_fzf_model_url() {
  case $1 in
    hf) print -r -- "https://huggingface.co/$2" ;;
    ms) print -r -- "https://modelscope.cn/models/$2" ;;
  esac
}

# print the on-disk directory of a cached model; return 1 if not downloaded
_hub_fzf_local_dir() {  # <hf|ms> <id>
  case $1 in
    hf)
      local hub=${HF_HUB_CACHE:-${HF_HOME:-$HOME/.cache/huggingface}/hub}
      local d=$hub/models--${2//\//--}
      [[ -d $d ]] && { print -r -- "$d"; return 0 }
      ;;
    ms)
      local root=${MODELSCOPE_CACHE:-$HOME/.cache/modelscope}
      local d
      for d in "$root/hub/models/$2" "$root/hub/$2"; do
        [[ -d $d ]] && { print -r -- "$d"; return 0 }
      done
      ;;
  esac
  return 1
}

_hub_fzf_copy() {
  if   (( $+commands[pbcopy]  )); then print -rn -- "$1" | pbcopy
  elif (( $+commands[wl-copy] )); then print -rn -- "$1" | wl-copy
  elif (( $+commands[xclip]   )); then print -rn -- "$1" | xclip -selection clipboard
  elif (( $+commands[xsel]    )); then print -rn -- "$1" | xsel --clipboard
  else print -u2 "hub-fzf: no clipboard tool found (pbcopy/wl-copy/xclip/xsel)"; return 1
  fi
  print -r -- "copied: $1"
}

_hub_fzf_open() {
  if   (( $+commands[open]     )); then open "$1"        &!
  elif (( $+commands[xdg-open] )); then xdg-open "$1"    &!
  else print -u2 "hub-fzf: no opener found (open/xdg-open)"; return 1
  fi
}

# parse a duration like 30s / 15m / 12h / 7d into seconds
_hub_fzf_duration_seconds() {
  local t=$1
  integer n=${t%[a-z]}
  case ${t##*[0-9]} in
    d) print $(( n * 86400 )) ;;
    h) print $(( n * 3600  )) ;;
    m) print $(( n * 60    )) ;;
    *) print $n ;;
  esac
}

# is $1 a file modified within the last $2 seconds?
_hub_fzf_cache_fresh() {
  [[ -f $1 ]] || return 1
  zmodload zsh/datetime
  zmodload -F zsh/stat b:zstat
  local -A st
  zstat -H st -- "$1" 2>/dev/null || return 1
  (( EPOCHSECONDS - st[mtime] < $2 ))
}

# stable filesystem-safe key for an arbitrary string
_hub_fzf_cache_key() {
  local raw="$1"
  if   (( $+commands[md5sum] )); then print -rn -- "$raw" | md5sum | cut -d' ' -f1
  elif (( $+commands[md5]    )); then print -rn -- "$raw" | md5 -q
  elif (( $+commands[shasum] )); then print -rn -- "$raw" | shasum | cut -d' ' -f1
  else print -r -- "${raw//[^a-zA-Z0-9_.-]/_}"   # fallback: sanitized, collision-prone
  fi
}

# --- the picker ---------------------------------------------------------------
# Two modes over the same UI: "index" (the crawled hub index) and "local"
# (models already downloaded). ctrl-l flips between them, keeping the query.
#
# _hub_fzf_select <hf|ms> <query> <mode: index|local>
# Runs fzf; on a selection sets globals HUB_FZF_KEY (expect key, "" for enter),
# HUB_FZF_ID (repo id) and HUB_FZF_MODE (the mode it was picked in), returns 0.
# Returns 1 on cancel/no selection.

# list one mode's rows (display TSV, colored) on stdout; 1 if unavailable
_hub_fzf_rows() {  # <hf|ms> <index|local>
  local source=$1 mode=$2 cache=$(_hub_fzf_cache_file $1)
  if [[ $mode == local ]]; then
    "$HUB_FZF_PLUGIN_DIR/bin/hub-fzf-local" $source | "$HUB_FZF_PLUGIN_DIR/bin/hub-fzf-pretty"
    return 0
  fi
  if [[ ! -s $cache ]]; then
    print -u2 "$source: index missing — run 'hub-update $source' (or wait for the background refresh)"
    # interactive CLI call (not a ZLE widget): offer to build it on the spot
    [[ ! -o zle && -t 0 && -t 2 ]] || return 1
    read -q "?build the $source index now? [y/N] " </dev/tty || { print -u2; return 1; }
    print -u2
    "$HUB_FZF_PLUGIN_DIR/lib/update-index.zsh" $source >&2 || return 1
  fi
  "$HUB_FZF_PLUGIN_DIR/bin/hub-fzf-pretty" < "$cache"
}

_hub_fzf_select() {
  local source=$1 query=$2 mode=$3
  # display-time only: hub-fzf-pretty pads/colors, the index on disk stays
  # plain TSV and fzf --ansi strips the codes again for matching/output
  local pretty=" | $HUB_FZF_PLUGIN_DIR/bin/hub-fzf-pretty"
  # keep parens/commas out of headers — they double as fzf action args
  local h_index='enter: download · ^l local · ^y id · ^o open · ^/ quants'
  local h_local='enter: id · ^l index · ^p path · ^y id · ^o open · ^d delete · ^/ quants'

  local input out rc header prompt expect binds
  while true; do
    input=$(_hub_fzf_rows $source $mode) || return 1
    expect=ctrl-l,ctrl-y,ctrl-o binds=()
    if [[ $mode == local ]]; then
      prompt="$source local› " header=$h_local
      expect+=,ctrl-p
      binds=(--bind "ctrl-d:execute($HUB_FZF_PLUGIN_DIR/bin/hub-fzf-delete $source {1})+reload($HUB_FZF_PLUGIN_DIR/bin/hub-fzf-local $source$pretty)")
      [[ -z $input ]] && header="no downloaded $source models yet · ^l index"
    else
      prompt="$source› " header=$h_index
    fi

    out=$({ [[ -n $input ]] && print -r -- "$input" } | command fzf \
      --ansi \
      --query="$query" \
      --print-query \
      --delimiter=$'\t' \
      --tiebreak=index \
      --layout=reverse \
      --height='~80%' \
      --prompt="$prompt" \
      --header="$header" \
      --expect=$expect \
      --bind='ctrl-/:toggle-preview' \
      "${binds[@]}" \
      --preview="$HUB_FZF_PLUGIN_DIR/bin/hub-fzf-preview $source {1} $mode" \
      --preview-window="$HUB_FZF_PREVIEW_WINDOW" \
      $=HUB_FZF_FZF_OPTS)
    rc=$?
    (( rc == 0 || rc == 1 )) || return 1   # 130 = esc/ctrl-c, 2 = error

    # --print-query output: query, key, selected line
    local -a lines=("${(@f)out}")
    query=${lines[1]-} HUB_FZF_KEY=${lines[2]-}
    if [[ $HUB_FZF_KEY == ctrl-l ]]; then
      [[ $mode == local ]] && mode=index || mode=local
      continue
    fi
    local line=${lines[3]-}
    [[ -n $line ]] || return 1

    HUB_FZF_MODE=$mode HUB_FZF_ID=${${line%%$'\t'*}%% *}   # strip id padding
    return 0
  done
}

# handle the copy/open actions shared by the picker and the ZLE widget.
# usage: _hub_fzf_handle_action <source> <key> <id> → 0 if handled, 1 if
# the key was plain <enter> (caller decides what to do with the id)
_hub_fzf_handle_action() {
  case $2 in
    ctrl-y) _hub_fzf_copy "$3" ;;
    ctrl-o) _hub_fzf_open "$(_hub_fzf_model_url $1 "$3")" ;;
    *)      return 1 ;;
  esac
}

# second stage after <enter> on a repo: pick from its available quants
# (shards collapsed, sorted by size, multi-select e.g. for quant + mmproj).
# Sets HUB_FZF_SEED and returns 0 when quants were picked; any other outcome
# (no .gguf files, esc, empty selection, offline / API error) returns 1 and
# the caller seeds the plain whole-repo command — never swallows a selection.
_hub_fzf_quant_pick() {
  local source=$1 id=$2 cmd=$3
  local quants
  quants=$("$HUB_FZF_PLUGIN_DIR/bin/hub-fzf-quants" $source "$id") || return 1
  [[ -z $quants ]] && return 1

  local out
  out=$(print -r -- "$quants" | command fzf \
    --multi \
    --delimiter=$'\t' \
    --with-nth=1,2,3,4 \
    --tiebreak=index \
    --layout=reverse \
    --height='~50%' \
    --prompt='quant› ' \
    --header="$id — pick quants · tab: multi-select · esc: whole repo" \
    $=HUB_FZF_FZF_OPTS) || return 1   # esc/ctrl-c = whole repo

  local -a includes
  local q
  while IFS= read -r q; do
    [[ -n $q ]] && includes+=("${q##*$'\t'}")   # last column: include pattern
  done <<< "$out"
  (( ${#includes} )) || return 1   # enter with nothing selected = whole repo

  local args=""
  for q in $includes; do args+=" --include ${(q)q}"; done
  typeset -g HUB_FZF_SEED="$cmd $id$args"
  return 0
}

# seed the download command for <id>, detouring through the quant picker.
# Never network-gated and never aborted: esc, an empty selection or an
# unreachable API all fall back to the plain whole-repo command. Always
# returns 0 with HUB_FZF_SEED set.
_hub_fzf_seed_download() {  # <hf|ms> <id>
  local source=$1 id=$2 cmd=$HUB_FZF_DOWNLOAD_CMD
  [[ $source == ms ]] && cmd=$HUB_FZF_MS_DOWNLOAD_CMD
  _hub_fzf_quant_pick $source "$id" "$cmd" || typeset -g HUB_FZF_SEED="$cmd $id"
  return 0
}

# usage: _hub_fzf_pick <hf|ms> [--local] [query words...]

_hub_fzf_pick() {
  local source=$1; shift
  local mode=index query
  while (( $# )); do
    case $1 in
      --local) mode=local ;;
      *)       query="${query:+${query} }$1" ;;
    esac
    shift
  done

  _hub_fzf_select $source "$query" $mode || return

  if [[ $HUB_FZF_KEY == ctrl-p ]]; then
    # copy the on-disk path (local picker only)
    local dir
    dir=$(_hub_fzf_local_dir $source "$HUB_FZF_ID") && _hub_fzf_copy "$dir"
    return
  fi

  _hub_fzf_handle_action $source "$HUB_FZF_KEY" "$HUB_FZF_ID" && return

  # already on disk — seed just the id, no download command needed
  if [[ $HUB_FZF_MODE == local ]]; then
    print -z -- "$HUB_FZF_ID"
    return
  fi

  _hub_fzf_seed_download $source "$HUB_FZF_ID" && print -z -- "$HUB_FZF_SEED"
}

# --- ZLE widgets (hotkeys) -------------------------------------------------------
# Opens the picker at the cursor, like fzf's ^t: the query is only the word
# left of the cursor (empty after a space), never the rest of the line. On
# <enter>: if the buffer was empty, seed "$HUB_FZF_DOWNLOAD_CMD <id> --include
# <quant>" (just the id in local mode); otherwise the repo id replaces that
# word. ^p in local mode inserts the on-disk path instead.

_hub_fzf_widget() {
  local source=$1 mode=$2
  local had=$BUFFER word=${LBUFFER##*[[:space:]]}
  if _hub_fzf_select $source "$word" $mode; then
    if [[ $HUB_FZF_KEY == ctrl-p ]]; then
      local dir
      dir=$(_hub_fzf_local_dir $source "$HUB_FZF_ID") && LBUFFER="${LBUFFER%"$word"}${(q)dir}"
    elif ! _hub_fzf_handle_action $source "$HUB_FZF_KEY" "$HUB_FZF_ID"; then
      if [[ -n $had ]]; then
        LBUFFER="${LBUFFER%"$word"}$HUB_FZF_ID"
      elif [[ $HUB_FZF_MODE == local ]]; then
        BUFFER="$HUB_FZF_ID"
        CURSOR=$#BUFFER
      else
        _hub_fzf_seed_download $source "$HUB_FZF_ID"
        BUFFER="$HUB_FZF_SEED"
        CURSOR=$#BUFFER
      fi
    fi
  fi
  zle redisplay
  return 0
}

_hub_fzf_widget_hub()      { _hub_fzf_widget hf index }
_hub_fzf_widget_local()    { _hub_fzf_widget hf local }
_hub_fzf_widget_ms_hub()   { _hub_fzf_widget ms index }
_hub_fzf_widget_ms_local() { _hub_fzf_widget ms local }

# --- background-update notification -------------------------------------------
# The detached auto-update writes "ok <src>" / "fail <src>" lines to
# $HUB_FZF_CACHE_DIR/update.status when it finishes. This precmd hook prints a
# one-line notice the first time it sees a newer status file.

_hub_fzf_update_notify() {
  local sfile=$HUB_FZF_CACHE_DIR/update.status
  [[ -f $sfile ]] || return 0
  zmodload -F zsh/stat b:zstat
  integer mtime=$(zstat +mtime -- "$sfile" 2>/dev/null || print 0)
  (( mtime > ${HUB_FZF_UPDATE_SEEN:-0} )) || return 0
  typeset -g HUB_FZF_UPDATE_SEEN=$mtime
  local -a ok fail
  local line
  while IFS= read -r line; do
    case $line in
      ok\ *)   ok+=("${line#ok }") ;;
      fail\ *) fail+=("${line#fail }") ;;
    esac
  done < "$sfile"
  (( ${#ok} ))   && print -P "%F{green}hub-fzf:%f index updated (${(j:, :)ok})"
  (( ${#fail} )) && print -P "%F{red}hub-fzf:%f index update failed (${(j:, :)fail}) — log: $HUB_FZF_CACHE_DIR/update.log"
  return 0
}
