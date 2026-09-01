#!/usr/bin/env bash
# 跑单个审查维度：装配 brief -> 调主审引擎 -> 过闸门2（引文校验）。
#
#   run_dimension.sh --paper FILE --dim ID --outdir DIR
#                    [--engine codex|claude] [--timeout SEC] [--code-root DIR]
#
# --engine 缺省时按 dimensions/manifest.tsv 里登记的主审方。
# --code-root 是 group B（代码与实验）和 group C（论文 vs 代码）的前置条件；
# 不给则这两组跳过。group A 只读 paper.md，不受影响。
# 退出码: 0 成功（含"零问题"这一合法结果）/ 1 用法错 / 2 引擎失败
#         3 缺前置条件，本维度跳过 / 5 闸门2 无法解析引擎输出
# 注意：某维度查无问题时 findings 为空数组，仍是成功。不要把空结果当失败。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PAPER="" DIM="" OUTDIR="" ENGINE="" TIMEOUT=900 CODE_ROOT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --paper)     PAPER="$2"; shift 2 ;;
    --dim)       DIM="$2"; shift 2 ;;
    --outdir)    OUTDIR="$2"; shift 2 ;;
    --engine)    ENGINE="$2"; shift 2 ;;
    --timeout)   TIMEOUT="$2"; shift 2 ;;
    --code-root) CODE_ROOT="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

[[ -z "$PAPER" || -z "$DIM" || -z "$OUTDIR" ]] && {
  echo "usage: --paper FILE --dim ID --outdir DIR [--engine codex|claude]" >&2; exit 1; }
[[ -r "$PAPER" ]] || { echo "paper not readable: $PAPER" >&2; exit 1; }

SPEC="$ROOT/dimensions/$DIM.md"
[[ -r "$SPEC" ]] || { echo "unknown dimension: $DIM (缺 $SPEC)" >&2; exit 1; }

MANIFEST="$ROOT/dimensions/manifest.tsv"
GROUP="$(awk -F'\t' -v d="$DIM" '$1==d && $1 !~ /^#/ {print $2; exit}' "$MANIFEST")"
if [[ -z "$ENGINE" ]]; then
  ENGINE="$(awk -F'\t' -v d="$DIM" '$1==d && $1 !~ /^#/ {print $3; exit}' "$MANIFEST")"
  [[ -z "$ENGINE" ]] && { echo "$DIM 未在 manifest 登记，且未给 --engine" >&2; exit 1; }
fi

# B、C 两组的证据都在代码里，拿不到代码就没有可核对的一侧，
# 跳过而不是空跑一遍引擎（B 组的 finding 没有代码引文也过不了闸门2）
if [[ "$GROUP" == "B" || "$GROUP" == "C" ]] && [[ -z "$CODE_ROOT" ]]; then
  echo "[$DIM] 跳过：group $GROUP 需要 --code-root" >&2; exit 3
fi
if [[ -n "$CODE_ROOT" ]]; then
  [[ -d "$CODE_ROOT" ]] || { echo "code-root 不是目录: $CODE_ROOT" >&2; exit 1; }
  CODE_ROOT="$(cd "$CODE_ROOT" && pwd)"
fi
case "$ENGINE" in
  codex|claude) ;;
  *) echo "--engine 只能是 codex 或 claude，收到: $ENGINE" >&2; exit 1 ;;
esac

mkdir -p "$OUTDIR"
PAPER_ABS="$(cd "$(dirname "$PAPER")" && pwd)/$(basename "$PAPER")"
BRIEF="$OUTDIR/$DIM.brief.md"
RAW="$OUTDIR/$DIM.raw.json"
KEPT="$OUTDIR/$DIM.json"
REJ="$OUTDIR/$DIM.rejected.json"

# 装配 brief：定位待审文件 + 维度规格。schema 契约由桥脚本追加。
{
  printf '# 待审文件\n\n`%s`\n\n' "$PAPER_ABS"
  printf '先完整读一遍该文件（含附录）再开始判断。行号以该文件为准。\n'
  printf '你只有只读权限，不要尝试修改任何文件。\n\n'
  if [[ -n "$CODE_ROOT" ]]; then
    printf '# 代码根目录\n\n`%s`\n\n' "$CODE_ROOT"
    printf '这是你当前的工作目录。`counter_source` 必须填相对该目录的路径。\n\n'
  fi
  printf -- '---\n\n'
  cat "$SPEC"
} >"$BRIEF"

# 给了代码就把 cwd 设在代码根目录：模型顺手写出的相对路径正好符合
# counter_source 契约（闸门2 会拒绝越出 code-root 的路径）
WORKDIR="$(dirname "$PAPER_ABS")"
[[ -n "$CODE_ROOT" ]] && WORKDIR="$CODE_ROOT"

"$ROOT/scripts/${ENGINE}_call.sh" \
  --brief "$BRIEF" --out "$RAW" \
  --schema "$ROOT/scripts/schema/findings.json" \
  --workdir "$WORKDIR" \
  --timeout "$TIMEOUT" --label "$ENGINE:$DIM" || exit 2

gate_args=(--paper "$PAPER_ABS" --findings "$RAW" --out "$KEPT" --rejected "$REJ")
[[ -n "$CODE_ROOT" ]] && gate_args+=(--code-root "$CODE_ROOT")
python3 "$ROOT/scripts/quote_check.py" "${gate_args[@]}"
gate=$?
[[ $gate -eq 0 ]] || exit 5

echo "[$DIM] 主审=$ENGINE -> $KEPT"
