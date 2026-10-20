# hub-fzf — fuzzy Hugging Face + ModelScope GGUF model search for zsh.
# oh-my-zsh custom plugin.

typeset -g HUB_FZF_PLUGIN_DIR="${${(%):-%x}:A:h}"

source "$HUB_FZF_PLUGIN_DIR/lib/common.zsh"

: ${HUB_FZF_HOTKEY:='^[m'}        # alt-m: search the index; '' to disable
: ${HUB_FZF_LOCAL_HOTKEY:='^[M'}  # alt-M: search downloaded models only
: ${HUB_FZF_MS_HOTKEY:=}          # ModelScope index picker (off; e.g. '^[n')
: ${HUB_FZF_MS_LOCAL_HOTKEY:=}    # ModelScope local picker (off; e.g. '^[N')

# --- user-facing commands -----------------------------------------------------

# Named hfz/msz (not hf/ms) so the official huggingface_hub `hf` CLI keeps
# working — the seeded `hf download <id>` lines run the real thing.

hfz()        { _hub_fzf_pick hf "$@" }
msz()        { _hub_fzf_pick ms "$@" }
hub-update()  { "$HUB_FZF_PLUGIN_DIR/lib/update-index.zsh" "${1:-hf}" ${2:+"$2"} }

# hotkeys: alt-m anywhere on the command line opens the index picker,
# alt-M opens the local (downloaded models) picker; ctrl-l inside either
# switches to the other
_hub_fzf_bind() {  # <keyseq> <widget-function>
  [[ -n $1 ]] || return 0
  zle -N $2 2>/dev/null || { zmodload zsh/zle && zle -N $2 }
  bindkey -M emacs "$1" $2 2>/dev/null
  bindkey -M viins "$1" $2 2>/dev/null
}
if [[ -o interactive ]]; then
  _hub_fzf_bind "$HUB_FZF_HOTKEY"       _hub_fzf_widget_hub
  _hub_fzf_bind "$HUB_FZF_LOCAL_HOTKEY" _hub_fzf_widget_local
  _hub_fzf_bind "$HUB_FZF_MS_HOTKEY"       _hub_fzf_widget_ms_hub
  _hub_fzf_bind "$HUB_FZF_MS_LOCAL_HOTKEY" _hub_fzf_widget_ms_local
  unfunction _hub_fzf_bind
fi

# --- startup checks & background auto-update ----------------------------------

_hub_fzf_init() {
  local dep missing=()
  for dep in fzf jq curl; do
    (( $+commands[$dep] )) || missing+=($dep)
  done
  (( ${#missing} )) && print -u2 "hub-fzf: missing dependencies: ${missing[*]}"

  # tested with fzf 0.45+ (adaptive --height, reload, --print-query/--expect)
  if (( $+commands[fzf] )); then
    local fv=${${(s: :)$(fzf --version 2>/dev/null)}[1]}
    autoload -Uz is-at-least
    is-at-least 0.45.0 ${fv:-0} \
      || print -u2 "hub-fzf: fzf ≥ 0.45 recommended (found ${fv:-unknown})"
  fi

  [[ ${HUB_FZF_AUTOUPDATE} == 1 ]] || return 0
  (( $+commands[flock] && $+commands[jq] && $+commands[curl] )) || return 0

  mkdir -p "$HUB_FZF_CACHE_DIR"
  local ttl=$(_hub_fzf_ttl_seconds) now=$(date +%s)
  local s stamp stale=()
  for s in hf ms; do
    # ms is opt-in: only auto-refresh once its index exists (don't force a
    # 10-minute ModelScope crawl on users who never asked for it)
    [[ $s == ms && ! -f $(_hub_fzf_cache_file ms) ]] && continue
    stamp="$HUB_FZF_CACHE_DIR/$s.stamp"
    # fresh only if within the TTL *and* crawled with the current scope —
    # flipping HUB_FZF_GGUF_ONLY / HUB_FZF_FILTER rebuilds the index
    [[ -f $stamp && $(<"$HUB_FZF_CACHE_DIR/$s.scope" 2>/dev/null) == $(_hub_fzf_scope $s) ]] &&
      (( now - $(<"$stamp") <= ttl )) && continue
    stale+=($s)
  done
  if (( ${#stale} )); then
    # detached refresh; writes ok/fail per source to update.status so the
    # precmd hook (_hub_fzf_update_notify) can announce the outcome
    ( : > "$HUB_FZF_CACHE_DIR/update.log"
      local msg=() s
      for s in $stale; do
        if "$HUB_FZF_PLUGIN_DIR/lib/update-index.zsh" $s >> "$HUB_FZF_CACHE_DIR/update.log" 2>&1; then
          msg+=("ok $s")
        else
          msg+=("fail $s")
        fi
      done
      print -l -- "${msg[@]}" > "$HUB_FZF_CACHE_DIR/.update.status.$$"
      mv -f "$HUB_FZF_CACHE_DIR/.update.status.$$" "$HUB_FZF_CACHE_DIR/update.status"
    ) &!
  fi
}
_hub_fzf_init
unfunction _hub_fzf_init

# announce background refresh results at the next prompt (but not for status
# files written before this shell started)
if [[ -o interactive ]]; then
  zmodload -F zsh/stat b:zstat
  typeset -g HUB_FZF_UPDATE_SEEN=$(zstat +mtime -- "$HUB_FZF_CACHE_DIR/update.status" 2>/dev/null || print 0)
  autoload -Uz add-zsh-hook
  add-zsh-hook precmd _hub_fzf_update_notify
fi
