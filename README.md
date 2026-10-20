# hub-fzf

Fuzzy-search **GGUF** models on Hugging Face **and ModelScope** straight from
your zsh prompt. Type a shorthand like `hfz uns/gemm4e2b`, pick
`unsloth/gemma-4-E2B-it-GGUF`, choose a quant, and get
`hf download unsloth/gemma-4-E2B-it-GGUF --include gemma-4-E2B-it-Q4_K_M.gguf`
on your command line.

Two things, one UI:

- **index** — a local, auto-refreshed snapshot of the hub's top GGUF repos
  (instant, works offline)
- **local** — the models already downloaded to your cache

`ctrl-l` flips between them, keeping your query. The commands are named
`hfz`/`msz` so the official `hf` CLI keeps working — the seeded
`hf download …` lines run the real thing.

## Install

```zsh
git clone https://github.com/mukel/hub-fzf ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/hub-fzf
# then add to ~/.zshrc:
plugins=(... hub-fzf)
```

Without oh-my-zsh, clone it anywhere and add to `~/.zshrc`:

```zsh
fpath+=(/path/to/hub-fzf)            # tab completion
source /path/to/hub-fzf/hub-fzf.plugin.zsh
```

Dependencies: `fzf` ≥ 0.45, `jq`, `curl`, `flock` (util-linux). Optional: `wl-copy` /
`xclip` / `pbcopy` for `ctrl-y`, `xdg-open` / `open` for `ctrl-o`.

## Usage

```zsh
hfz gemm4e2b         # fuzzy search the index
hfz uns/gemm4e2b     # org/name shorthand — fzf subsequence matching
hfz --local          # search downloaded models only (no network)
msz qwen3            # same, against ModelScope (msz --local too)
hub-update            # rebuild the index in the foreground
hub-update all        # both hubs
hub-update hf 20000   # one-off: smaller/larger top-N
```

Results are ranked by downloads (ties and equal-length matches resolve to
the more popular repo, via fzf's `--tiebreak=index`).

### Quants

`enter` on a repo opens the **quant picker**: every quant the repo offers,
smallest first, with its size. Split shards (`…-00001-of-00003.gguf`) are
one entry, and extras — `mmproj` (vision projector), `imatrix`, `mtp` /
`eagle` draft models — are listed after the main quants:

```
quant› 
  UD-Q4_K_M    16.5G   Qwen3.8-27B-UD-Q4_K_M.gguf
  Q8_0           29G   Qwen3.8-27B-Q8_0.gguf
  BF16         54.7G   2 shards   BF16/Qwen3.8-27B-BF16.gguf
  mmproj F16  927.6M   mmproj-F16.gguf
```

`tab` multi-selects (e.g. a quant plus its `mmproj`); each pick becomes an
`--include` (a glob for sharded quants). `esc` — or a repo with no `.gguf`
files, or no network — seeds the plain whole-repo command instead.

The **preview** (`ctrl-/`) shows the same quant list on top of the repo
metadata, so you can compare repos before picking; in local mode it shows
the quants actually on disk. Quant lists are fetched once per repo and
cached for `HUB_FZF_PREVIEW_TTL`. Want the preview always open? Drop
`hidden` from `HUB_FZF_PREVIEW_WINDOW`.

### Keys

| Key      | Index                               | Local                                |
|----------|-------------------------------------|--------------------------------------|
| `enter`  | quant picker → download command     | seed the model id                    |
| `ctrl-l` | switch to local                     | switch to index                      |
| `ctrl-y` | copy repo id                        | copy repo id                         |
| `ctrl-o` | open model page                     | open model page                      |
| `ctrl-p` |                                     | copy on-disk **path**                |
| `ctrl-d` |                                     | **delete** from disk (asks first)    |
| `ctrl-/` | toggle preview (quants + metadata)  | toggle preview (path, size, quants)  |

The prompt shows the mode — `hf›` or `hf local›`. Columns are aligned and
colorized (counters dimmed, `local` badge green); `HUB_FZF_COLOR=0` or
`NO_COLOR=1` disables colors.

### Hotkeys

**`alt-m`** opens the index picker at any prompt, **`alt-M`** the local one:

- command line **empty** → `enter` seeds the download command (via the
  quant picker), or just `<id>` from local mode
- command line **has text** → like fzf's `ctrl-t`, only the word left of
  the cursor seeds the query, and `enter` puts the repo id in its place
  (e.g. `ollama run <alt-m>`); `ctrl-p` in local mode inserts the path

Rebind or disable via `HUB_FZF_HOTKEY` / `HUB_FZF_LOCAL_HOTKEY` (any `bindkey`
sequence; `''` disables). ModelScope's are off by default:
`HUB_FZF_MS_HOTKEY` / `HUB_FZF_MS_LOCAL_HOTKEY` — e.g. `'^[n'` / `'^[N'`.

Tab completion for `hfz`/`msz`/`hub-update` ships in `_hub-fzf` (oh-my-zsh
loads it from the plugin directory).

## Configuration

Set these in `~/.zshrc` **before** oh-my-zsh is sourced:

| Variable               | Default                 | Meaning                              |
|------------------------|-------------------------|--------------------------------------|
| `HUB_FZF_CACHE_DIR`     | `~/.cache/hub-fzf`       | where the index lives                |
| `HUB_FZF_GGUF_ONLY`     | `1`                     | GGUF repos only; `0` = whole hub (with `GGUF` badge) |
| `HUB_FZF_MAX_MODELS`    | `100000`                | top-N by downloads; `0` = all        |
| `HUB_FZF_FILTER`        | *(empty)*               | extra hf tag filter (ANDed with `gguf`), e.g. `text-generation` |
| `HUB_FZF_TTL`           | `7d`                    | auto-update interval (`s`/`m`/`h`/`d`) |
| `HUB_FZF_AUTOUPDATE`    | `1`                     | background refresh on shell start    |
| `HUB_FZF_DOWNLOAD_CMD`  | `hf download`           | command seeded on `enter` (hf)       |
| `HUB_FZF_MS_DOWNLOAD_CMD` | `modelscope download --model` | command seeded on `enter` (ms) |
| `HUB_FZF_FZF_OPTS`      | *(empty)*               | extra flags for every fzf call       |
| `HUB_FZF_COLOR`         | `1`                     | colored columns (`0`/`NO_COLOR` = plain) |
| `HUB_FZF_PREVIEW_WINDOW` | `right,60%,wrap,hidden` | fzf `--preview-window` spec         |
| `HUB_FZF_PREVIEW_TTL`   | `1d`                    | cache preview metadata + quant lists |
| `HUB_FZF_HOTKEY`        | `alt-m`                 | index picker hotkey (`''` = off)     |
| `HUB_FZF_LOCAL_HOTKEY`  | `alt-M`                 | local picker hotkey                  |
| `HUB_FZF_MS_HOTKEY`     | *(off)*                 | ModelScope index picker hotkey       |
| `HUB_FZF_MS_LOCAL_HOTKEY` | *(off)*               | ModelScope local picker hotkey       |
| `HF_TOKEN`             | *(unset)*               | HF token → higher API rate limits    |

### GGUF-only (default)

- The HF crawler requests `/api/models?filter=gguf`, the ModelScope crawler
  adds the `gguf` library criterion — non-GGUF repos never reach the index.
  `HUB_FZF_FILTER` narrows HF further.
- An index crawled with a different `HUB_FZF_GGUF_ONLY` / `HUB_FZF_FILTER`
  is treated as stale and rebuilt by the next background refresh (or run
  `hub-update all` now). An interrupted crawl only resumes under the same
  setting.
- With `HUB_FZF_GGUF_ONLY=0` the index covers the whole hub and GGUF repos
  get a `GGUF` badge column, so typing `gguf` in fzf narrows any search.
- The local picker lists everything on disk, GGUF or not.

### Being nice to the API

- **Searching never goes online** — both modes are local.
- The **index refresh** is the only bulk traffic: up to ~100 requests (1000
  models/page) once per `HUB_FZF_TTL` (default: weekly), 100 ms apart, with
  exponential backoff. A crawl that dies mid-way **resumes from the last
  page** on the next run. `HUB_FZF_AUTOUPDATE=0` + manual `hub-update` for
  full control.
- **Preview metadata and quant lists are cached per repo** for
  `HUB_FZF_PREVIEW_TTL` (default 1 day) — failures are never cached, and
  stale entries are pruned on every index refresh.

The index holds the **top N GGUF repos by downloads** — ~100k rows is a
~5 MB file that fzf searches instantly. Set `HUB_FZF_MAX_MODELS=0` to crawl
every GGUF repo (consider `HF_TOKEN` for a higher rate limit).

## How it works

```
lib/update-index.zsh   paginates the hub search API (GGUF-filtered), writes
                       <src>.tsv atomically (tmp + mv), guarded by flock
lib/common.zsh         the pickers (index/local, quants), helpers, config
lib/quants.jq          groups a repo's .gguf files into quants (shards merged)
bin/hub-fzf-quants      a repo's quants (hf tree / ms file API), cached per repo
bin/hub-fzf-local       lists on-disk cached models, newest first
bin/hub-fzf-delete      removes a cached model, with confirmation (ctrl-d)
bin/hub-fzf-format      raw id/↓/♥ → aligned display columns
bin/hub-fzf-pretty      pads the id column + ANSI colors (display-time only)
bin/hub-fzf-preview     preview pane: quants + metadata (or on-disk details)
```

Auto-update: on shell start, any source whose index is older than
`HUB_FZF_TTL` or was crawled with a different filter (`ms` only once you've
built its index) is refreshed by a detached background job (log:
`$HUB_FZF_CACHE_DIR/update.log`). You get a one-line notice at the next
prompt when it finishes — `hub-fzf: index updated (hf)` — or a pointer to
the log on failure.

## ModelScope

`msz` mirrors `hfz` — same pickers, keys, quants and caching. Notes:

- The index comes from ModelScope's search API (`PUT /api/v1/dolphin/models`,
  100 models/page). It only supports its default ordering, so the crawler
  sorts by downloads **locally**. The GGUF catalog is ~22k repos — a couple
  of minutes.
- `HUB_FZF_FILTER` is HF-only and ignored for `ms`, with a warning.
- Picks seed `modelscope download --model <id> --include <quant>` (needs the
  `modelscope` Python package).

## Local cache locations

- **HF**: `$HF_HUB_CACHE` (or `$HF_HOME/hub`, default `~/.cache/huggingface/hub`)
- **ModelScope**: `$MODELSCOPE_CACHE/hub/models/...` (or `hub/...`, default
  `~/.cache/modelscope`)

Newest downloads first, with on-disk size and download date — metadata-only
entries (a tool fetched just the config) are obvious at a glance.

## Development

```zsh
./test/smoke.zsh     # end-to-end: syntax, crawl, matching, quants, previews,
                     # plugin load, and the pickers driven by test/shim/fzf
```

`test/shim/fzf` is a scripted stand-in for fzf, so the picker flows (mode
switch, quant pick, esc fallbacks) run without a terminal. Only the real fzf
rendering itself is untested.

## Roadmap

- merged search across both hubs (`hfz --all`, source badge per row)
- a preferred-quant setting that pre-selects e.g. `Q4_K_M`

## License

[Apache-2.0](LICENSE)
