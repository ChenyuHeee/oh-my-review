#!/usr/bin/env bash
# 反向桥：从 codex 侧（或脚本）调用 Claude Code 做只读审查。
#
#   claude_call.sh --brief FILE --out FILE [--workdir DIR] [--model NAME]
#                  [--timeout SEC] [--label NAME]
#
# 只读通过工具白名单实现，不用 --dangerously-skip-permissions。
# 退出码: 0 成功 / 1 用法错 / 2 claude 失败 / 3 超时 / 4 输出为空
set -uo pipefail

BRIEF="" OUT="" WORKDIR="$PWD" MODEL="" TIMEOUT=900 LABEL="claude" SCHEMA=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --brief)   BRIEF="$2"; shift 2 ;;
    --out)     OUT="$2"; shift 2 ;;
    --workdir) WORKDIR="$2"; shift 2 ;;
    --model)   MODEL="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --label)   LABEL="$2"; shift 2 ;;
    --schema)  SCHEMA="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

[[ -z "$BRIEF" || -z "$OUT" ]] && { echo "usage: --brief FILE --out FILE" >&2; exit 1; }
[[ -r "$BRIEF" ]] || { echo "brief not readable: $BRIEF" >&2; exit 1; }
[[ -n "$SCHEMA" && ! -r "$SCHEMA" ]] && { echo "schema not readable: $SCHEMA" >&2; exit 1; }

command -v claude >/dev/null || { echo "claude not on PATH" >&2; exit 2; }

mkdir -p "$(dirname "$OUT")"
RAW="${OUT%.json}.claude.raw.json"
LOG="${OUT%.json}.claude.log"

# Claude Code 没有 --output-schema，结构化输出只能靠提示词约束 + 事后校验。
# 把 schema 追加到 brief 末尾，另存一份实际发送的提示，便于复现。
PROMPT="$BRIEF"
if [[ -n "$SCHEMA" ]]; then
  PROMPT="${OUT%.json}.claude.prompt.md"
  { cat "$BRIEF"
    printf '\n\n---\n\n## 输出格式（强制）\n\n'
    printf '只输出一个 JSON 对象，符合下面的 JSON Schema。\n'
    printf '不要有前言、解释、markdown 代码围栏或结尾总结——第一个字符必须是 `{`。\n\n'
    printf '```json\n'; cat "$SCHEMA"; printf '\n```\n'
  } >"$PROMPT"
fi

# brief 走 stdin：--add-dir 是可变参数，会把位置参数当成目录吞掉；
# 且 brief 可能很长，走 stdin 不受 ARG_MAX 限制。
args=(-p
  --output-format json
  --allowed-tools "Read,Grep,Glob"
  --add-dir "$WORKDIR")

[[ -n "$MODEL" ]] && args+=(--model "$MODEL")

# 网关偶发 502，重试三次退避
rc=0
for attempt in 1 2 3; do
  timeout --signal=TERM --kill-after=30 "$TIMEOUT" \
    claude "${args[@]}" <"$PROMPT" >"$RAW" 2>"$LOG"
  rc=$?

  [[ $rc -eq 0 ]] && break
  if [[ $rc -eq 124 || $rc -eq 137 ]]; then
    echo "[$LABEL] 超时 ${TIMEOUT}s，日志: $LOG" >&2
    exit 3
  fi
  if [[ $attempt -lt 3 ]]; then
    echo "[$LABEL] 退出码 $rc，${attempt}/3 重试中..." >&2
    sleep $((attempt * 15))
  fi
done

if [[ $rc -ne 0 ]]; then
  echo "[$LABEL] claude 三次均失败，退出码 $rc，日志尾部:" >&2
  tail -n 15 "$LOG" >&2
  exit 2
fi

# --output-format json 包了一层信封，取 .result 作为正文。
# 给了 schema 时再剥掉围栏、切出首个 JSON 对象、校验必填字段。
python3 -c '
import json, re, sys

raw = json.load(open(sys.argv[1]))
body = raw.get("result", "") if isinstance(raw, dict) else str(raw)
schema_path = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] else None

if not schema_path:
    open(sys.argv[2], "w").write(body)
    sys.exit(0)

text = re.sub(r"^\s*```(?:json)?|```\s*$", "", body.strip(), flags=re.M).strip()
start = text.find("{")
if start < 0:
    sys.exit("no JSON object in output")

# 从第一个 { 起做括号配平，容忍 JSON 之后的尾随文字
depth, in_str, esc, end = 0, False, False, None
for i, ch in enumerate(text[start:], start):
    if in_str:
        if esc: esc = False
        elif ch == "\\": esc = True
        elif ch == chr(34): in_str = False
        continue
    if ch == chr(34): in_str = True
    elif ch == "{": depth += 1
    elif ch == "}":
        depth -= 1
        if depth == 0:
            end = i + 1
            break
if end is None:
    sys.exit("unbalanced JSON object in output")

obj = json.loads(text[start:end])

schema = json.load(open(schema_path))
missing = [k for k in schema.get("required", []) if k not in obj]
if missing:
    sys.exit("missing top-level keys: " + ", ".join(missing))

item_req = (
    schema.get("properties", {}).get("findings", {})
    .get("items", {}).get("required", [])
)
for n, f in enumerate(obj.get("findings", []), 1):
    absent = [k for k in item_req if k not in f]
    if absent:
        sys.exit("finding #%d missing: %s" % (n, ", ".join(absent)))

json.dump(obj, open(sys.argv[2], "w"), ensure_ascii=False)
' "$RAW" "$OUT" "$SCHEMA" 2>>"$LOG" || {
  echo "[$LABEL] 输出不符合 schema，原始输出: $RAW，日志尾部:" >&2
  tail -n 5 "$LOG" >&2
  exit 2
}

if [[ ! -s "$OUT" ]]; then
  echo "[$LABEL] 输出为空，原始输出: $RAW" >&2
  exit 4
fi

echo "[$LABEL] ok -> $OUT"
