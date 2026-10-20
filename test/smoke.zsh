#!/usr/bin/env zsh
# hub-fzf — non-interactive smoke test. Usage: test/smoke.zsh
# Exercises everything except the interactive fzf UI (which needs a TTY).

set -u
zmodload zsh/datetime

PLUGIN_DIR=${0:A:h:h}
export HUB_FZF_CACHE_DIR=${HUB_FZF_SMOKE_CACHE:-/tmp/hub-fzf-smoke}
export HUB_FZF_AUTOUPDATE=0
export HUB_FZF_MAX_MODELS=3000   # small, fast crawl

# hermetic run: stale preview/tree entries would mask format changes;
# the index itself is kept so reruns stay fast
rm -f "$HUB_FZF_CACHE_DIR"/preview/*(N) "$HUB_FZF_CACHE_DIR"/tree/*(N) 2>/dev/null

integer failures=0
check() {  # check <name> <cmd...>
  local name=$1; shift
  if "$@" &> /dev/null; then
    print "  ok   $name"
  else
    print "  FAIL $name"
    (( failures += 1 ))
  fi
}

print "== syntax =="
for f in "$PLUGIN_DIR"/hub-fzf.plugin.zsh "$PLUGIN_DIR"/lib/*.zsh "$PLUGIN_DIR"/bin/*(N); do
  check "zsh -n ${f#$PLUGIN_DIR/}" zsh -n "$f"
done

print "== crawler (small index, network) =="
check "update-index hf" "$PLUGIN_DIR/lib/update-index.zsh" hf
check "index file exists" test -s "$HUB_FZF_CACHE_DIR/hf.tsv"
check "stamp file exists" test -s "$HUB_FZF_CACHE_DIR/hf.stamp"
check "scope marker written (gguf)" zsh -c '[[ $(<"$1/hf.scope") == gguf ]]' _ "$HUB_FZF_CACHE_DIR"
check "index rows carry no badge column" zsh -c '
  awk -F"\t" "NF != 3 { bad=1 } END { exit bad+0 }" "$1/hf.tsv"
' _ "$HUB_FZF_CACHE_DIR"
check "index is GGUF-only (top 20 repos tagged gguf)" zsh -c '
  for id in $(cut -f1 "$1/hf.tsv" | head -n 20); do
    curl -sfS "https://huggingface.co/api/models/$id" | jq -e ".tags | index(\"gguf\")" > /dev/null || exit 1
  done
' _ "$HUB_FZF_CACHE_DIR"
check "scope string tracks HUB_FZF_FILTER" zsh -c '
  [[ $(HUB_FZF_FILTER= zsh -c "source \$1/lib/common.zsh; _hub_fzf_scope hf" _ "$2") == gguf &&
     $(HUB_FZF_FILTER=mlx zsh -c "source \$1/lib/common.zsh; _hub_fzf_scope hf" _ "$2") == gguf+mlx &&
     $(HUB_FZF_GGUF_ONLY=0 zsh -c "source \$1/lib/common.zsh; _hub_fzf_scope ms" _ "$2") == all ]]
' _ "$HUB_FZF_CACHE_DIR" "$PLUGIN_DIR"
check "resume artifacts cleaned after success" zsh -c '
  [[ ! -e $1/hf.raw && ! -e $1/hf.cursor ]]
' _ "$HUB_FZF_CACHE_DIR"
top=$(head -n1 "$HUB_FZF_CACHE_DIR/hf.tsv")
if [[ $top == *M*↓* ]]; then
  print "  ok   sorted by downloads (top: ${top%%$'\t'*})"
else
  print "  FAIL top row does not look like the most-downloaded model: $top"
  (( failures += 1 ))
fi

print "== matching (the headline feature) =="
match=$(fzf --filter='uns/gemm4e2b' < "$HUB_FZF_CACHE_DIR/hf.tsv" | head -n1 | cut -f1)
if [[ $match == unsloth/*gemma* ]]; then
  print "  ok   'uns/gemm4e2b' → $match"
else
  print "  FAIL 'uns/gemm4e2b' → ${match:-<no match>}"
  (( failures += 1 ))
fi

print "== display =="
check "pretty: dim counters + badge highlight" zsh -c '
  esc=$(printf "\033")
  out=$(print "a/b\t1.0k ↓\t42 ♥\tGGUF" | "$1/bin/hub-fzf-pretty")
  [[ $out == *${esc}"[2m"* && $out == *${esc}"[1;33mGGUF"* ]]
' _ "$PLUGIN_DIR"
check "pretty: id column aligned" zsh -c '
  esc=$(printf "\033")
  clean=$(print "s/a\t1 ↓\t1 ♥\nlonger-org/b\t2 ↓\t3 ♥" | "$1/bin/hub-fzf-pretty" | sed "s/${esc}\[[0-9;]*m//g")
  l1=$(print -r -- "$clean" | sed -n 1p | cut -f1)
  l2=$(print -r -- "$clean" | sed -n 2p | cut -f1)
  [[ ${#l1} -eq ${#l2} && ${#l1} -eq 12 ]]
' _ "$PLUGIN_DIR"
check "pretty: id padding capped at 50" zsh -c '
  long=org/${(l:60::x:)}
  clean=$(print "s/a\t1 ↓\t1 ♥\n$long\t2 ↓\t3 ♥" | NO_COLOR=1 "$1/bin/hub-fzf-pretty")
  l1=$(print -r -- "$clean" | sed -n 1p | cut -f1)
  [[ ${#l1} -eq 50 ]]
' _ "$PLUGIN_DIR"
check "pretty: NO_COLOR disables colors" zsh -c '
  esc=$(printf "\033")
  out=$(NO_COLOR=1 print "a/b\t1 ↓\t1 ♥\tGGUF" | NO_COLOR=1 "$1/bin/hub-fzf-pretty")
  [[ $out != *${esc}"["* ]]
' _ "$PLUGIN_DIR"
check "index on disk stays plain TSV" zsh -c '
  esc=$(printf "\033")
  [[ $(<"$1/hf.tsv") != *${esc}"["* ]]
' _ "$HUB_FZF_CACHE_DIR"
check "fzf --ansi strips colors from selection" zsh -c '
  id=$(print "a/b\t1.0k ↓\t42 ♥\tGGUF" | "$1/bin/hub-fzf-pretty" | fzf --ansi --filter=a/b | cut -f1)
  [[ ${id%% *} == "a/b" ]]
' _ "$PLUGIN_DIR"
check "HUB_FZF_GGUF_ONLY=0: crawl scope + ms criterion" zsh -c '
  d="$1/full"; rm -rf "$d"
  HUB_FZF_GGUF_ONLY=0 HUB_FZF_CACHE_DIR="$d" "$2/lib/update-index.zsh" ms 100 > /dev/null 2>&1 &&
  [[ $(<"$d/ms.scope") == all ]] &&
  (( $(wc -l < "$d/ms.tsv") == 100 ))
' _ "$HUB_FZF_CACHE_DIR" "$PLUGIN_DIR"
check "HUB_FZF_GGUF_ONLY=0: whole hub + GGUF badge" zsh -c '
  d="$1/full"
  HUB_FZF_GGUF_ONLY=0 HUB_FZF_CACHE_DIR="$d" "$2/lib/update-index.zsh" hf 1000 > /dev/null 2>&1 &&
  [[ $(<"$d/hf.scope") == all ]] &&
  cut -f1 "$d/hf.tsv" | grep -qx "google-bert/bert-base-uncased" &&
  grep -q "	GGUF$" "$d/hf.tsv"
' _ "$HUB_FZF_CACHE_DIR" "$PLUGIN_DIR"

print "== preview + cache =="
check "preview fetch" "$PLUGIN_DIR/bin/hub-fzf-preview" hf google/gemma-3n-E2B-it
check "preview lists quants first" zsh -c '
  out=$(HUB_FZF_CACHE_DIR="$1" "$2/bin/hub-fzf-preview" hf unsloth/gemma-3-1b-it-GGUF)
  [[ ${out%%$'"'"'\n'"'"'*} == quants* && $out == *Q4_K_M* && $out == *"id:        unsloth/"* ]]
' _ "$HUB_FZF_CACHE_DIR" "$PLUGIN_DIR"
check "preview cache written" zsh -c '[[ -n "$1"/preview/*(N) ]]' _ "$HUB_FZF_CACHE_DIR"

print "== modelscope =="
check "update-index ms (2 pages)" "$PLUGIN_DIR/lib/update-index.zsh" ms 200
check "ms index exists" test -s "$HUB_FZF_CACHE_DIR/ms.tsv"
msrow=$(head -n1 "$HUB_FZF_CACHE_DIR/ms.tsv")
if [[ $msrow == */*$'\t'* ]]; then
  print "  ok   ms row format (${msrow%%$'\t'*})"
else
  print "  FAIL ms row malformed: $msrow"
  (( failures += 1 ))
fi
check "ms index is GGUF-only (name heuristic)" zsh -c '
  # most ModelScope GGUF repos say so in the name; a mixed index would not
  integer n=$(head -n 50 "$1/ms.tsv" | cut -f1 | grep -ci gguf)
  (( n >= 25 ))
' _ "$HUB_FZF_CACHE_DIR"
check "ms preview" "$PLUGIN_DIR/bin/hub-fzf-preview" ms Qwen/Qwen2.5-0.5B-Instruct
check "ms quants (network)" zsh -c '
  HUB_FZF_CACHE_DIR="$1" "$2/bin/hub-fzf-quants" ms unsloth/Qwen3.8-27B-GGUF | cut -f1 | grep -qx "UD-Q4_K_M"
' _ "$HUB_FZF_CACHE_DIR" "$PLUGIN_DIR"
check "ms preview humanized" zsh -c '
  HUB_FZF_CACHE_DIR="$1" "$2/bin/hub-fzf-preview" ms Qwen/Qwen2.5-0.5B-Instruct | grep -qE "downloads: [0-9.]+M"
' _ "$HUB_FZF_CACHE_DIR" "$PLUGIN_DIR"

echo "== local cache search =="
check "local list (hf)" zsh -c '
  fake="$1/fake-hf"
  mkdir -p "$fake/models--acme--fancy-model/snapshots/deadbeef"
  touch "$fake/models--acme--fancy-model/snapshots/deadbeef/model.safetensors"
  HF_HUB_CACHE="$fake" HUB_FZF_CACHE_DIR="$1" "$2/bin/hub-fzf-local" hf | grep -q "^acme/fancy-model"
' _ "$HUB_FZF_CACHE_DIR" "$PLUGIN_DIR"
check "local list newest-first" zsh -c '
  fake="$1/fake-hf"
  mkdir -p "$fake/models--zz--older/snapshots/x" && touch -d "2020-01-01" "$fake/models--zz--older"
  HF_HUB_CACHE="$fake" HUB_FZF_CACHE_DIR="$1" "$2/bin/hub-fzf-local" hf | head -1 | grep -q "^acme/fancy-model"
' _ "$HUB_FZF_CACHE_DIR" "$PLUGIN_DIR"
check "local preview (hf)" zsh -c '
  HF_HUB_CACHE="$1/fake-hf" HUB_FZF_CACHE_DIR="$1" "$2/bin/hub-fzf-preview" hf acme/fancy-model local | grep -q "files:    1"
' _ "$HUB_FZF_CACHE_DIR" "$PLUGIN_DIR"
check "local list size column" zsh -c '
  HF_HUB_CACHE="$1/fake-hf" HUB_FZF_CACHE_DIR="$1" "$2/bin/hub-fzf-local" hf \
    | awk -F"\t" "NF != 3 || \$2 !~ /^ *[0-9]/ { bad=1 } END { exit bad+0 }"
' _ "$HUB_FZF_CACHE_DIR" "$PLUGIN_DIR"
check "local list (ms, both layouts)" zsh -c '
  fake="$1/fake-ms"
  mkdir -p "$fake/hub/models/iic/some-model" "$fake/hub/acme/old-style"
  MODELSCOPE_CACHE="$fake" HUB_FZF_CACHE_DIR="$1" "$2/bin/hub-fzf-local" ms > "$1/ms-local.out"
  grep -q "^iic/some-model" "$1/ms-local.out" && grep -q "^acme/old-style" "$1/ms-local.out"
' _ "$HUB_FZF_CACHE_DIR" "$PLUGIN_DIR"

echo "== quants + local delete =="
check "quant grouping: shards, extras, size order" zsh -c '
  out=$(print -r -- '"'"'[
    {"path":"BF16/m-BF16-00001-of-00002.gguf","size":5000000000},
    {"path":"BF16/m-BF16-00002-of-00002.gguf","size":1000000000},
    {"path":"m-Q8_0.gguf","size":3000000000},
    {"path":"m-UD-Q4_K_XL.gguf","size":2000000000},
    {"path":"mmproj-F16.gguf","size":900000000},
    {"path":"README.md","size":10}]'"'"' | jq -r -f "$1/lib/quants.jq" | cut -f1,2,3,5 | tr "\t" "|")
  [[ $out == "UD-Q4_K_XL|2G||m-UD-Q4_K_XL.gguf
Q8_0|3G||m-Q8_0.gguf
BF16|6G|2 shards|BF16/m-BF16-*-of-*.gguf
mmproj F16|900M||mmproj-F16.gguf" ]]
' _ "$PLUGIN_DIR"
check "hf quants (network, recursive tree)" zsh -c '
  HUB_FZF_CACHE_DIR="$1" "$2/bin/hub-fzf-quants" hf unsloth/Qwen3.8-27B-GGUF > "$1/q.out" &&
  grep -q "^BF16	.*	2 shards	" "$1/q.out" && grep -q "^UD-Q4_K_M	" "$1/q.out"
' _ "$HUB_FZF_CACHE_DIR" "$PLUGIN_DIR"
check "non-gguf repo → no quants" zsh -c '
  out=$(HUB_FZF_CACHE_DIR="$1" "$2/bin/hub-fzf-quants" hf google-bert/bert-base-uncased)
  [[ -z $out ]]
' _ "$HUB_FZF_CACHE_DIR" "$PLUGIN_DIR"
check "tree cache written" zsh -c '
  [[ -n "$1"/tree/*.json(N[1]) ]]
' _ "$HUB_FZF_CACHE_DIR"
check "local preview lists quants on disk" zsh -c '
  fake="$1/fake-q"; snap="$fake/models--acme--q-GGUF/snapshots/abc"
  mkdir -p "$snap" && print -n xxxx > "$snap/q-Q4_K_M.gguf"
  HF_HUB_CACHE="$fake" HUB_FZF_CACHE_DIR="$1/q-cache" "$2/bin/hub-fzf-preview" hf acme/q-GGUF local \
    | grep -q "^  Q4_K_M "
' _ "$HUB_FZF_CACHE_DIR" "$PLUGIN_DIR"
check "local delete confirm" zsh -c '
  fake="$1/fake-del"; mkdir -p "$fake/models--acme--doomed"
  print y | HF_HUB_CACHE="$fake" HUB_FZF_CACHE_DIR="$1" "$2/bin/hub-fzf-delete" hf acme/doomed >/dev/null
  [[ ! -d "$fake/models--acme--doomed" ]]
' _ "$HUB_FZF_CACHE_DIR" "$PLUGIN_DIR"
check "local delete abort keeps dir" zsh -c '
  fake="$1/fake-del"; mkdir -p "$fake/models--acme--keeper"
  print n | HF_HUB_CACHE="$fake" HUB_FZF_CACHE_DIR="$1" "$2/bin/hub-fzf-delete" hf acme/keeper >/dev/null 2>&1
  [[ -d "$fake/models--acme--keeper" ]]
' _ "$HUB_FZF_CACHE_DIR" "$PLUGIN_DIR"

print "== plugin load =="
check "sources cleanly, commands defined" zsh -c '
  HUB_FZF_AUTOUPDATE=0; HUB_FZF_CACHE_DIR="$1"; source "$2" &&
  (( $+functions[hfz] && $+functions[msz] && $+functions[hub-update] &&
     $+functions[_hub_fzf_handle_action] && $+functions[_hub_fzf_quant_pick] && $+functions[_hub_fzf_widget] &&
     $+functions[_hub_fzf_local_dir] && $+functions[_hub_fzf_seed_download] &&
     $+functions[_hub_fzf_widget_ms_hub] && $+functions[_hub_fzf_widget_ms_local] &&
     $+functions[_hub_fzf_update_notify] ))
' _ "$HUB_FZF_CACHE_DIR" "$PLUGIN_DIR/hub-fzf.plugin.zsh" < /dev/null
check "no hf/ms shadowing (real CLI stays usable)" zsh -c '
  HUB_FZF_AUTOUPDATE=0; HUB_FZF_CACHE_DIR="$1"; source "$2" &&
  (( ! $+functions[hf] && ! $+functions[ms] ))
' _ "$HUB_FZF_CACHE_DIR" "$PLUGIN_DIR/hub-fzf.plugin.zsh" < /dev/null
check "missing index → clean error" zsh -c '
  HUB_FZF_AUTOUPDATE=0; HUB_FZF_CACHE_DIR=/nonexistent; source "$1"
  hfz foo 2>&1 | grep -q "index missing"
' _ "$PLUGIN_DIR/hub-fzf.plugin.zsh" < /dev/null
check "local dir helper (hf)" zsh -c '
  HUB_FZF_AUTOUPDATE=0; HUB_FZF_CACHE_DIR="$1"; HF_HUB_CACHE="$1/fake-hf"
  mkdir -p "$HF_HUB_CACHE/models--acme--fancy-model"
  source "$2/hub-fzf.plugin.zsh"
  [[ $(_hub_fzf_local_dir hf acme/fancy-model) == "$HF_HUB_CACHE/models--acme--fancy-model" ]] &&
  ! _hub_fzf_local_dir hf acme/no-such-model
' _ "$HUB_FZF_CACHE_DIR" "$PLUGIN_DIR" < /dev/null
check "background-update notification" zsh -c '
  HUB_FZF_AUTOUPDATE=0; HUB_FZF_CACHE_DIR="$1"; source "$2/hub-fzf.plugin.zsh"
  print "ok hf" > "$HUB_FZF_CACHE_DIR/update.status"
  touch -d "2030-01-01" "$HUB_FZF_CACHE_DIR/update.status"
  HUB_FZF_UPDATE_SEEN=0
  # redirect, not $(...)/pipe: those fork a subshell and lose the global
  _hub_fzf_update_notify > "$HUB_FZF_CACHE_DIR/notify.out"
  grep -q "index updated (hf)" "$HUB_FZF_CACHE_DIR/notify.out" &&
  [[ $HUB_FZF_UPDATE_SEEN -gt 0 ]] &&
  _hub_fzf_update_notify > "$HUB_FZF_CACHE_DIR/notify.out" &&
  [[ ! -s "$HUB_FZF_CACHE_DIR/notify.out" ]]   # seen: no repeat notice
' _ "$HUB_FZF_CACHE_DIR" "$PLUGIN_DIR" < /dev/null
mkdir -p /tmp/hub-fzf-zdot   # empty ZDOTDIR: -i without sourcing any user zshrc
check "hotkey widgets register with zle" env ZDOTDIR=/tmp/hub-fzf-zdot zsh -ic '
  HUB_FZF_AUTOUPDATE=0; HUB_FZF_CACHE_DIR="$1"
  source "${2}/hub-fzf.plugin.zsh"
  # zle -N registers widgets even for missing functions — check BOTH
  [[ -n ${widgets[_hub_fzf_widget_hub]-} && -n ${widgets[_hub_fzf_widget_local]-} &&
     $+functions[_hub_fzf_widget_hub] -eq 1 && $+functions[_hub_fzf_widget_local] -eq 1 ]]
' _ "$HUB_FZF_CACHE_DIR" "$PLUGIN_DIR"

print "== pickers (scripted fzf) =="
shimrun() {  # shimrun <name> <steps> <zsh code>  → output of the code
  local d=$HUB_FZF_CACHE_DIR/shim-$1
  mkdir -p "$d/hub/models--acme--thing-GGUF/snapshots/x"
  print -r -- "$2" > "$d/script"; : > "$d/script.n"; : > "$d/script.log"
  PATH="$PLUGIN_DIR/test/shim:$PATH" FAKE_FZF_SCRIPT="$d/script" HF_HUB_CACHE="$d/hub" \
    zsh -c "source ${(q)PLUGIN_DIR}/hub-fzf.plugin.zsh; $3" < /dev/null 2>/dev/null
}
out=$(shimrun toggle $'ctrl-l|.\n|acme/thing' \
  '_hub_fzf_select hf gemma index && print -r -- "$HUB_FZF_MODE $HUB_FZF_ID"')
check "ctrl-l switches index → local (query kept)" zsh -c '
  [[ $1 == "local acme/thing-GGUF" ]] && grep -c "query=gemma" "$2" | grep -qx 2
' _ "$out" "$HUB_FZF_CACHE_DIR/shim-toggle/script.log"
out=$(shimrun quant $'|unsloth/gemma-3-1b-it-GGUF\n|^Q4_K_M\t' \
  '_hub_fzf_select hf unsloth/gemma-3-1b index && _hub_fzf_seed_download hf $HUB_FZF_ID && print -r -- $HUB_FZF_SEED')
check "enter → quant picker → --include" test "$out" = "hf download unsloth/gemma-3-1b-it-GGUF --include gemma-3-1b-it-Q4_K_M.gguf"
out=$(shimrun quant-esc $'|unsloth/gemma-3-1b-it-GGUF\nesc|' \
  '_hub_fzf_select hf unsloth/gemma-3-1b index && _hub_fzf_seed_download hf $HUB_FZF_ID && print -r -- $HUB_FZF_SEED')
check "esc in quant picker → whole repo" test "$out" = "hf download unsloth/gemma-3-1b-it-GGUF"
out=$(shimrun esc 'esc|' '_hub_fzf_select hf x index; print rc=$?')
check "esc in main picker cancels" test "$out" = "rc=1"

print
if (( failures )); then
  print "SMOKE TEST FAILED ($failures failure(s))"
  exit 1
else
  print "smoke test passed (cache: $HUB_FZF_CACHE_DIR)"
fi
