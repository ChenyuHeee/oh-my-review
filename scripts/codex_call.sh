#!/usr/bin/env bash
# 调用 codex-cli 做只读审查。稽核方不得改文件。
#
#   codex_call.sh --brief FILE --out FILE [--schema FILE] [--workdir DIR]
#                 [--timeout SEC] [--label NAME]
#
# 退出码: 0 成功 / 1 用法错 / 2 codex 失败 / 3 超时 / 4 输出为空
set -uo pipefail

BRIEF="" OUT="" SCHEMA="" WORKDIR="$PWD" TIMEOUT=900 LABEL="codex"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --brief)   BRIEF="$2"; shift 2 ;;
    --out)     OUT="$2"; shift 2 ;;
    --schema)  SCHEMA="$2"; shift 2 ;;
    --workdir) WORKDIR="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --label)   LABEL="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

[[ -z "$BRIEF" || -z "$OUT" ]] && { echo "usage: --brief FILE --out FILE" >&2; exit 1; }
[[ -r "$BRIEF" ]] || { echo "brief not readable: $BRIEF" >&2; exit 1; }

command -v codex >/dev/null || { echo "codex not on PATH" >&2; exit 2; }

mkdir -p "$(dirname "$OUT")"
LOG="${OUT%.json}.codex.log"

# --sandbox read-only     稽核方只读，不能改稿
# --skip-git-repo-check   工作区未必是 git 仓库
# --ephemeral             不落 session 文件
# --color never           无 ANSI 色
# -C                      工作区
#
# 不再用 --output-schema（OpenAI 的 structured output 要求 required 覆盖全部字段，
# 与我们的可选字段需求冲突），改为 prompt 注入 + 事后提取，与 claude 对称。
# -o 只取"最后一条消息"，即 codex 的最终答复。
# 绝不要去 scrape 整个 session 日志：codex 探索时会把读到的文件内容打进
# transcript，正则"取最后一个能 parse 的 JSON 块"会抓到那些文件内容，
# 静默用无关数据覆盖真正的答复（曾把 b_group_findings.json 当成稽核结果）。
LAST_MSG="${OUT%.json}.last.txt"
args=(exec
  --sandbox read-only
  --skip-git-repo-check
  --ephemeral
  --color never
  -C "$WORKDIR"
  -o "$LAST_MSG")

# 装配 prompt：brief + schema（若有）
PROMPT_FILE=$(mktemp)
cat "$BRIEF" >"$PROMPT_FILE"
if [[ -n "$SCHEMA" && -r "$SCHEMA" ]]; then
  echo >>"$PROMPT_FILE"
  echo "---" >>"$PROMPT_FILE"
  echo >>"$PROMPT_FILE"
  echo "# 输出格式" >>"$PROMPT_FILE"
  echo >>"$PROMPT_FILE"
  echo '只输出符合下述 JSON Schema 的 JSON，不要任何解释性文字：' >>"$PROMPT_FILE"
  echo >>"$PROMPT_FILE"
  echo '```json' >>"$PROMPT_FILE"
  cat "$SCHEMA" >>"$PROMPT_FILE"
  echo '```' >>"$PROMPT_FILE"
fi

# stdin 必须重定向，否则 codex 会停在 "Reading additional input from stdin..."
# 网关偶发 502（codex 内部重试 5 次仍可能失败），外层再退避重试三次
rc=0
for attempt in 1 2 3; do
  rm -f "$LAST_MSG"
  timeout --signal=TERM --kill-after=30 "$TIMEOUT" \
    codex "${args[@]}" "$(cat "$PROMPT_FILE")" </dev/null >"$LOG" 2>&1
  rc=$?

  # 只解析 codex 的最终答复。剥掉 markdown 围栏，从第一个 { 起做
  # 带字符串感知的括号配对——正则数括号会在嵌套或引号内的括号上出错。
  if [[ $rc -eq 0 ]]; then
    python3 - "$LAST_MSG" "$OUT" <<'PYEOF' 2>/dev/null
import json, re, sys
from pathlib import Path

src, dst = Path(sys.argv[1]), Path(sys.argv[2])
text = src.read_text(encoding="utf-8", errors="replace").strip()
text = re.sub(r"^\s*```(?:json)?|```\s*$", "", text, flags=re.M).strip()

start = text.find("{")
if start == -1:
    sys.exit(1)
depth, in_str, esc, end = 0, False, False, None
for i, ch in enumerate(text[start:], start):
    if in_str:
        if esc:
            esc = False
        elif ch == "\\":
            esc = True
        elif ch == '"':
            in_str = False
        continue
    if ch == '"':
        in_str = True
    elif ch == "{":
        depth += 1
    elif ch == "}":
        depth -= 1
        if depth == 0:
            end = i + 1
            break
if end is None:
    sys.exit(1)
obj = json.loads(text[start:end])
dst.write_text(json.dumps(obj, ensure_ascii=False, indent=2), encoding="utf-8")
PYEOF
    if [[ $? -eq 0 && -s "$OUT" ]]; then
      rm -f "$PROMPT_FILE" "$LAST_MSG"
      break
    else
      rc=4  # 标记为输出解析失败
    fi
  fi

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
  echo "[$LABEL] codex 三次均失败，退出码 $rc，日志尾部:" >&2
  tail -n 15 "$LOG" >&2
  exit 2
fi
if [[ ! -s "$OUT" ]]; then
  echo "[$LABEL] 输出为空，日志尾部:" >&2
  tail -n 15 "$LOG" >&2
  exit 4
fi

echo "[$LABEL] ok -> $OUT"
