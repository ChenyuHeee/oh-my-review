#!/usr/bin/env bash
# 交叉稽核：让**另一个**引擎复核主审方的 findings。
#
#   cross_audit.sh --paper FILE --dim ID --outdir DIR
#                  [--findings FILE] [--auditor codex|claude]
#                  [--code-root DIR] [--timeout SEC]
#
# 稽核方逐条裁定 CONFIRMED / DOWNGRADE / FALSE_POSITIVE，并做 steelman：
# 主动去找论文是否已经自答了该质疑。同时报告主审方漏掉的问题。
#
# --auditor 缺省取 manifest 里主审方的**对侧**。同家族自查抓不出幻觉，
# 所以默认必须换引擎；显式传 --auditor 可以覆盖（如 codex 网关挂了时降级）。
#
# 退出码: 0 成功 / 1 用法错 / 2 稽核引擎失败 / 3 无需稽核（零 findings）
#         5 闸门2 无法解析稽核输出
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PAPER="" DIM="" OUTDIR="" FINDINGS="" AUDITOR="" TIMEOUT=900 CODE_ROOT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --paper)     PAPER="$2"; shift 2 ;;
    --dim)       DIM="$2"; shift 2 ;;
    --outdir)    OUTDIR="$2"; shift 2 ;;
    --findings)  FINDINGS="$2"; shift 2 ;;
    --auditor)   AUDITOR="$2"; shift 2 ;;
    --timeout)   TIMEOUT="$2"; shift 2 ;;
    --code-root) CODE_ROOT="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

[[ -z "$PAPER" || -z "$DIM" || -z "$OUTDIR" ]] && {
  echo "usage: --paper FILE --dim ID --outdir DIR [--auditor codex|claude]" >&2; exit 1; }
[[ -r "$PAPER" ]] || { echo "paper not readable: $PAPER" >&2; exit 1; }

SPEC="$ROOT/dimensions/$DIM.md"
[[ -r "$SPEC" ]] || { echo "unknown dimension: $DIM (缺 $SPEC)" >&2; exit 1; }

# 默认取 run_dimension.sh 的产物
[[ -z "$FINDINGS" ]] && FINDINGS="$OUTDIR/$DIM.json"
[[ -r "$FINDINGS" ]] || { echo "findings not readable: $FINDINGS" >&2; exit 1; }

MANIFEST="$ROOT/dimensions/manifest.tsv"
GROUP="$(awk -F'\t' -v d="$DIM" '$1==d && $1 !~ /^#/ {print $2; exit}' "$MANIFEST")"
LEAD="$(awk -F'\t' -v d="$DIM" '$1==d && $1 !~ /^#/ {print $3; exit}' "$MANIFEST")"

# 稽核方默认取主审方对侧——跨模型家族才抓得住幻觉
if [[ -z "$AUDITOR" ]]; then
  case "$LEAD" in
    claude) AUDITOR="codex" ;;
    codex)  AUDITOR="claude" ;;
    *) echo "$DIM 未在 manifest 登记 lead_engine，且未给 --auditor" >&2; exit 1 ;;
  esac
fi
case "$AUDITOR" in
  codex|claude) ;;
  *) echo "--auditor 只能是 codex 或 claude，收到: $AUDITOR" >&2; exit 1 ;;
esac
[[ "$AUDITOR" == "$LEAD" ]] && \
  echo "[$DIM] 警告：稽核方与主审方同为 $AUDITOR，同家族自查抓幻觉能力弱" >&2

# 零 findings 无可稽核。但仍要给稽核方一次找漏报的机会——
# 主审方一条都没报，恰恰可能是它漏了。所以只在文件损坏时才退出。
N_FINDINGS="$(python3 -c "
import json,sys
try:
    d = json.load(open('$FINDINGS'))
    print(len(d.get('findings', []) if isinstance(d, dict) else d))
except Exception:
    print(-1)
")"
[[ "$N_FINDINGS" == "-1" ]] && { echo "[$DIM] findings 解析失败: $FINDINGS" >&2; exit 1; }

if [[ -n "$CODE_ROOT" ]]; then
  [[ -d "$CODE_ROOT" ]] || { echo "code-root 不是目录: $CODE_ROOT" >&2; exit 1; }
  CODE_ROOT="$(cd "$CODE_ROOT" && pwd)"
fi
# B/C 组的证据在代码里，没有 code-root 稽核方无法核对 counter_quote
if [[ "$GROUP" == "B" || "$GROUP" == "C" ]] && [[ -z "$CODE_ROOT" ]]; then
  echo "[$DIM] 跳过稽核：group $GROUP 需要 --code-root" >&2; exit 3
fi

mkdir -p "$OUTDIR"
PAPER_ABS="$(cd "$(dirname "$PAPER")" && pwd)/$(basename "$PAPER")"
BRIEF="$OUTDIR/$DIM.audit.brief.md"
RAW="$OUTDIR/$DIM.audit.raw.json"
AUDIT="$OUTDIR/$DIM.audit.json"

# 装配稽核 brief。findings 直接内联，稽核方按 id 逐条回裁定。
{
  printf '# 交叉稽核任务\n\n'
  printf '另一个引擎已经审过这个维度，产出了下面的 findings。你的工作**不是**复审整篇论文，\n'
  printf '而是逐条裁定这些 findings 是否站得住脚，外加报告它漏掉的问题。\n\n'

  printf '## 你要做三件事\n\n'
  printf '**1. 逐条裁定**（对每条 finding 给一个 verdict，用它的 `id` 对应）：\n\n'
  printf -- '- `CONFIRMED`：问题成立，引文确实支持这个主张\n'
  printf -- '- `DOWNGRADE`：问题存在但等级被高估，或论文已部分自答。给出 `corrected_severity`\n'
  printf -- '- `FALSE_POSITIVE`：引文不支持该主张，或问题本身不成立。必须在 `reason` 里说清是哪一种\n\n'

  printf '**2. Steelman（关键）**：对每条 finding，主动去论文里找它是否已经被回答过——\n'
  printf '局限性章节、附录、脚注、相关工作里的一句话都算。找到了就填 `paper_already_addresses`\n'
  printf '（如 `§5.2` 或 `Limitations`），并考虑据此降级。\n\n'
  printf '你的职责不是给主审方盖章。一条"论文 §5.2 已经承认了的局限"被报成 CRITICAL，\n'
  printf '就该判 DOWNGRADE 或 FALSE_POSITIVE。宁可放过一条，不要让作者去修一个不存在的问题。\n\n'

  printf '**3. 漏报**：在**同一维度范围内**，主审方漏掉了什么？填进 `missed`。\n'
  printf '没有就给空数组——不要为了凑数编。`missed` 条目同样会被机械校验引文，编造的会被丢弃。\n\n'

  printf -- '---\n\n'
  printf '# 待审文件\n\n`%s`\n\n' "$PAPER_ABS"
  printf '先完整读一遍该文件再开始裁定。行号以该文件为准。\n'
  printf '你只有只读权限，不要尝试修改任何文件。\n\n'
  if [[ -n "$CODE_ROOT" ]]; then
    printf '# 代码根目录\n\n`%s`\n\n' "$CODE_ROOT"
    printf '这是你当前的工作目录。findings 里的 `counter_source` 是相对该目录的路径，\n'
    printf '逐条去核对那些代码引文是否真的存在、是否真的支持该主张。\n\n'
  fi

  printf -- '---\n\n'
  printf '# 该维度的原始规格\n\n'
  printf '主审方是按下面这份规格审的。判定"是否越界报了别的维度的问题"时以此为准。\n\n'
  cat "$SPEC"

  printf '\n\n---\n\n'
  printf '# 待稽核的 findings\n\n'
  if [[ "$N_FINDINGS" == "0" ]]; then
    printf '主审方一条都没报。`verdicts` 给空数组。\n\n'
    printf '**但这不代表论文这个维度没问题**——也可能是主审方漏了。\n'
    printf '请按规格独立审一遍，把发现的问题填进 `missed`。\n\n'
  else
    printf '共 %s 条。`verdicts` 数组必须覆盖全部 %s 个 id。\n\n' "$N_FINDINGS" "$N_FINDINGS"
    printf '```json\n'
    python3 -c "
import json
d = json.load(open('$FINDINGS'))
items = d.get('findings', []) if isinstance(d, dict) else d
# 只传裁定需要的字段，别把闸门2的内部标记也塞进去
keys = ('id','severity','location','line','issue','fix','quote',
        'counter_source','counter_quote','counter_line')
slim = [{k: f[k] for k in keys if k in f} for f in items]
print(json.dumps(slim, ensure_ascii=False, indent=2))
"
    printf '```\n'
  fi
} >"$BRIEF"

"$ROOT/scripts/${AUDITOR}_call.sh" \
  --brief "$BRIEF" --out "$RAW" \
  --schema "$ROOT/scripts/schema/audit.json" \
  --workdir "${CODE_ROOT:-$(dirname "$PAPER_ABS")}" \
  --timeout "$TIMEOUT" --label "$AUDITOR:audit:$DIM" || exit 2

# missed 条目要过闸门2 才能进报告——稽核方也会幻觉
gate_args=(--paper "$PAPER_ABS" --audit "$RAW" --findings "$FINDINGS" --out "$AUDIT")
[[ -n "$CODE_ROOT" ]] && gate_args+=(--code-root "$CODE_ROOT")
python3 "$ROOT/scripts/audit_gate.py" "${gate_args[@]}"
gate=$?
[[ $gate -eq 0 ]] || exit 5

echo "[$DIM] 稽核方=$AUDITOR -> $AUDIT"
