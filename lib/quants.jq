# hub-fzf — group a repo's .gguf files into quants.
# Input: [{path, size}] (any files; non-.gguf are ignored).
# Output, one TSV row per quant, main quants by size then extras (mmproj,
# imatrix, mtp, eagle drafts):
#   label <TAB> size <TAB> shards <TAB> file <TAB> include-pattern
# Split shards (name-00001-of-00003.gguf) collapse into one row whose
# include pattern is a glob matching every shard.

def human: if . >= 1e9 then "\((. / 1e8 | round) / 10)G"
           elif . >= 1e6 then "\((. / 1e5 | round) / 10)M"
           elif . >= 1e3 then "\((. / 1e2 | round) / 10)k"
           else "\(.)B" end;

def shard_re: "-[0-9]{5}-of-[0-9]{5}\\.gguf$";

def quant_re:
  "(?i)(?:UD-)?(?:I?Q[0-9]+(?:_[0-9K])?(?:_(?:XXS|XS|S|M|L|XL|NL|[0-9]))*|TQ[0-9]_[0-9]|MXFP4(?:_MOE)?|BF16|F16|F32|FP8)";

[ .[] | select(.path | test("\\.gguf$"; "i")) ]
| map(. + {key: (.path | sub(shard_re; ".gguf"))})
| group_by(.key)
| map({
    key: .[0].key,
    size: (map(.size // 0) | add),
    n: length,
    pattern: (if length > 1 then (.[0].key | sub("\\.gguf$"; "-*-of-*.gguf"))
              else .[0].path end)
  })
| map(. + {base: (.key | split("/") | last | sub("\\.gguf$"; ""; "i"))})
| map(. + {
    aux: (.base | test("^(mmproj|imatrix|mtp|eagle)"; "i")),
    quant: ([.base | scan(quant_re)] | last // null)
  })
| map(. + {label: (
    if .aux then
      (.base | capture("^(?<k>mmproj|imatrix|mtp|eagle[0-9]*)"; "i").k | ascii_downcase)
        + (if .quant then " " + (.quant | ascii_upcase) else "" end)
    elif .quant then .quant | ascii_upcase
    else .base
    end)})
| sort_by(.aux, .size)
| .[]
| [.label, (.size | human), (if .n > 1 then "\(.n) shards" else "" end), .key, .pattern]
| @tsv
