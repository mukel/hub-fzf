#!/usr/bin/env zsh
# hub-fzf — index crawler. Usage: update-index.zsh [hf|ms|all] [max-models]
# Fetches the top models (sorted by downloads) and writes an atomic, sorted
# TSV index to HUB_FZF_CACHE_DIR. max=0 means "no limit" (full hub). With
# HUB_FZF_GGUF_ONLY=1 (default) non-GGUF repos are filtered out server-side.
#
# Raw row format: id <TAB> downloads <TAB> likes/stars [<TAB> badge]
#   hf: cursor-paginated GET /api/models, 1000/page, sorted server-side
#   ms: offset-paginated PUT /api/v1/dolphin/models, 100/page ("Default"
#       order — the API rejects other sorts — so we sort locally)

set -u

HUB_FZF_PLUGIN_DIR=${0:A:h:h}
source "$HUB_FZF_PLUGIN_DIR/lib/common.zsh"

source=${1:-hf}
integer max=${2:-$HUB_FZF_MAX_MODELS}   # optional per-run override

if [[ $source == all ]]; then
  rc=0
  for s in hf ms; do
    "$0" $s $max || rc=1
  done
  exit $rc
fi

mkdir -p "$HUB_FZF_CACHE_DIR"

# single updater at a time
exec 9> "$HUB_FZF_CACHE_DIR/.update.lock"
flock -n 9 || { print -u2 "update-index: another update is running"; exit 0; }

auth=()
[[ -n ${HF_TOKEN:-} ]] && auth=(-H "Authorization: Bearer $HF_TOKEN")

raw="$HUB_FZF_CACHE_DIR/$source.raw"
cur="$HUB_FZF_CACHE_DIR/$source.cursor"
scope=$(_hub_fzf_scope $source)
kind=models
_hub_fzf_gguf_only && kind="GGUF repos"
out="$HUB_FZF_CACHE_DIR/$source.tsv.$$"
hdr=; body=   # may stay empty; referenced by the EXIT trap under `set -u`
# on failure/interruption, keep $raw + $cur so the next run resumes where
# this one stopped; only the unfinished output tsv is always cleaned
trap 'rm -f "$out" ${hdr:+"$hdr"} ${body:+"$body"}' EXIT

# fetch one URL into $body with bounded exponential backoff
fetch() {  # fetch <url> [curl args...]
  local url=$1; shift
  body=$(mktemp)
  local -a dopt=()
  [[ -n $hdr ]] && dopt=(-D "$hdr")
  integer attempt=0
  until curl -sfS "${dopt[@]}" "$@" "$url" -o "$body"; do
    if (( ++attempt >= 6 )); then
      print -u2 "\nupdate-index: giving up after $attempt attempts — run again to resume ($url)"
      exit 1
    fi
    print -u2 "\nupdate-index: request failed, retrying in $(( 2 ** attempt ))s..."
    sleep $(( 2 ** attempt ))
  done
}

integer count=0 page=0

case $source in
  hf)
    url='https://huggingface.co/api/models?limit=1000&sort=downloads&direction=-1'
    _hub_fzf_gguf_only && url+='&filter=gguf'
    if [[ -n $HUB_FZF_FILTER ]]; then
      enc=$(jq -rn --arg f "$HUB_FZF_FILTER" '$f | @uri')
      url+="&filter=$enc"
      print -u2 "update-index: filtering to $kind tagged '$HUB_FZF_FILTER'"
    fi
    rows_jq=$(_hub_fzf_hf_rows_jq)
    # resume an interrupted crawl (same scope only)
    if [[ -f $cur && -f $raw ]] && [[ $(sed -n 1p "$cur") == "$scope" ]]; then
      url=$(sed -n 2p "$cur")
      integer count=$(wc -l < "$raw")
      print -u2 "update-index: resuming ($count models already fetched)"
    else
      : > "$raw"
      rm -f "$cur"
    fi
    while [[ -n $url ]] && (( max == 0 || count < max )); do
      hdr=$(mktemp)
      fetch "$url" "${auth[@]}"
      jq -r "$rows_jq" < "$body" >> "$raw"
      integer n=$(jq 'length' < "$body")
      (( count += n, page += 1 ))
      printf '\r%s: %d models (page %d)' "$source" "$count" "$page" >&2
      url=$(grep -i '^link:' "$hdr" | sed -n 's/.*<\([^>]*\)>; rel="next".*/\1/p' | tr -d '\r')
      rm -f "$hdr" "$body"; hdr=; body=
      print -r -- "$scope" > "$cur"
      print -r -- "$url" >> "$cur"
      (( max == 0 || count < max )) && [[ -n $url ]] && sleep 0.1
    done
    ;;

  ms)
    [[ -n $HUB_FZF_FILTER ]] && print -u2 "update-index: HUB_FZF_FILTER is hf-only, ignoring for ms"
    criterion=$(_hub_fzf_ms_criterion)
    # resume an interrupted crawl (offset pagination: cursor = scope, last page)
    if [[ -f $cur && -f $raw ]] && [[ $(sed -n 1p "$cur") == "$scope" ]]; then
      page=$(sed -n 2p "$cur")
      integer count=$(wc -l < "$raw")
      print -u2 "update-index: resuming from page $page ($count models already fetched)"
    else
      : > "$raw"
      rm -f "$cur"
    fi
    while (( max == 0 || count < max )); do
      (( page += 1 ))
      fetch 'https://modelscope.cn/api/v1/dolphin/models' \
        -X PUT -H 'Content-Type: application/json' \
        -d "{\"Query\":\"\",\"PageSize\":100,\"PageNumber\":$page,\"SortBy\":\"Default\",\"Criterion\":$criterion}"
      jq -r '.Data.Model.Models[]? |
        [(.Path + "/" + .Name), (.Downloads // 0), (.Stars // 0)] | @tsv' \
        < "$body" >> "$raw"
      integer n=$(jq '(.Data.Model.Models // []) | length' < "$body")
      (( count += n ))
      printf '\r%s: %d models (page %d)' "$source" "$count" "$page" >&2
      rm -f "$body"; body=
      print -l -- "$scope" $page > "$cur"
      (( n < 100 )) && break   # short page = end of the catalog
      sleep 0.1
    done
    ;;

  *)
    print -u2 "update-index: unknown source '$source' (expected hf, ms or all)"
    exit 1
    ;;
esac
print >&2

if (( max > 0 )); then
  LC_ALL=C sort -t $'\t' -k2,2nr "$raw" | head -n "$max" \
    | "$HUB_FZF_PLUGIN_DIR/bin/hub-fzf-format" > "$out"
else
  LC_ALL=C sort -t $'\t' -k2,2nr "$raw" \
    | "$HUB_FZF_PLUGIN_DIR/bin/hub-fzf-format" > "$out"
fi
mv -f "$out" "$HUB_FZF_CACHE_DIR/$source.tsv"
date +%s > "$HUB_FZF_CACHE_DIR/$source.stamp"
print -r -- "$scope" > "$HUB_FZF_CACHE_DIR/$source.scope"
rm -f "$raw" "$cur"

# garbage-collect expired preview/tree cache entries (best effort); live/ is
# left over from versions that had live search
rm -rf "$HUB_FZF_CACHE_DIR"/live(N/) 2>/dev/null
rm -f "$HUB_FZF_CACHE_DIR"/preview/*(Nms+$(_hub_fzf_duration_seconds $HUB_FZF_PREVIEW_TTL)) \
      "$HUB_FZF_CACHE_DIR"/tree/*(Nms+$(_hub_fzf_duration_seconds $HUB_FZF_PREVIEW_TTL)) 2>/dev/null

if (( max > 0 )); then
  print "update-index: $source index ready ($count $kind, top $max kept)"
else
  print "update-index: $source index ready ($count $kind, full catalog)"
fi
