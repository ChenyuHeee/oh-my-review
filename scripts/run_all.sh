#!/usr/bin/env bash
# 按 manifest 并行跑全部维度。两侧引擎各自是独立进程，直接用后台作业池并发。
#
#   run_all.sh --paper FILE --outdir DIR
#              [--code-root DIR] [--group A,B,C] [--only dim,dim]
#              [--jobs N] [--timeout SEC]
#
# 未给 --code-root 时 group C 自动跳过（不是失败）。
# 退出码: 0 全部成功或合法跳过 / 1 用法错 / 2 全部维度失败 / 6 部分维度失败
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# 注意：变量名不能叫 GROUPS —— 那是 bash 内建数组（当前用户的 gid），赋值会被静默忽略
PAPER="" OUTDIR="" CODE_ROOT="" GROUP_SEL="" ONLY="" JOBS=4 TIMEOUT=900

while [[ $# -gt 0 ]]; do
  case "$1" in
    --paper)     PAPER="$2"; shift 2 ;;
    --outdir)    OUTDIR="$2"; shift 2 ;;
    --code-root) CODE_ROOT="$2"; shift 2 ;;
    --group)     GROUP_SEL="$2"; shift 2 ;;
    --only)      ONLY="$2"; shift 2 ;;
    --jobs)      JOBS="$2"; shift 2 ;;
    --timeout)   TIMEOUT="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

[[ -z "$PAPER" || -z "$OUTDIR" ]] && {
  echo "usage: --paper FILE --outdir DIR [--code-root DIR] [--group A,B,C]" >&2; exit 1; }
[[ -r "$PAPER" ]] || { echo "paper not readable: $PAPER" >&2; exit 1; }
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || { echo "--jobs 必须是正整数: $JOBS" >&2; exit 1; }

MANIFEST="$ROOT/dimensions/manifest.tsv"
mkdir -p "$OUTDIR"

# 选维度：--only 优先，其次 --group，都没给就跑全部
DIMS=()
while IFS=$'\t' read -r dim group engine _rest; do
  [[ -z "$dim" || "$dim" == \#* ]] && continue
  if [[ -n "$ONLY" ]]; then
    [[ ",$ONLY," == *",$dim,"* ]] || continue
  elif [[ -n "$GROUP_SEL" ]]; then
    [[ ",$GROUP_SEL," == *",$group,"* ]] || continue
  fi
  DIMS+=("$dim")
done <"$MANIFEST"

[[ ${#DIMS[@]} -eq 0 ]] && { echo "没有匹配的维度（--only=$ONLY --group=$GROUP_SEL）" >&2; exit 1; }

echo "[run_all] 待跑 ${#DIMS[@]} 个维度，并发 $JOBS"

# 作业池：每个维度一个后台进程，退出码落盘供收集
STATUS_DIR="$OUTDIR/.status"
mkdir -p "$STATUS_DIR"
rm -f "$STATUS_DIR"/*.rc 2>/dev/null

for dim in "${DIMS[@]}"; do
  while [[ "$(jobs -rp | wc -l)" -ge "$JOBS" ]]; do wait -n 2>/dev/null || break; done
  (
    args=(--paper "$PAPER" --dim "$dim" --outdir "$OUTDIR" --timeout "$TIMEOUT")
    [[ -n "$CODE_ROOT" ]] && args+=(--code-root "$CODE_ROOT")
    "$ROOT/scripts/run_dimension.sh" "${args[@]}" >"$OUTDIR/$dim.run.log" 2>&1
    echo $? >"$STATUS_DIR/$dim.rc"
  ) &
done
wait

# 收集结果
ok=() skipped=() failed=()
for dim in "${DIMS[@]}"; do
  rc="$(cat "$STATUS_DIR/$dim.rc" 2>/dev/null || echo 99)"
  case "$rc" in
    0) ok+=("$dim") ;;
    3) skipped+=("$dim") ;;
    *) failed+=("$dim:rc=$rc") ;;
  esac
done

echo
echo "===== 维度汇总 ====="
for dim in "${ok[@]}"; do
  n="$(python3 -c "
import json,sys
try: print(len(json.load(open('$OUTDIR/$dim.json'))['findings']))
except Exception: print('?')
")"
  echo "  ok      $dim  保留 $n 条"
done
for dim in "${skipped[@]}"; do echo "  skip    $dim  （缺前置条件，见 $OUTDIR/$dim.run.log）"; done
for f in "${failed[@]}"; do echo "  FAIL    ${f%%:*}  ${f#*:}  日志 $OUTDIR/${f%%:*}.run.log"; done
echo "成功 ${#ok[@]} / 跳过 ${#skipped[@]} / 失败 ${#failed[@]}"

[[ ${#failed[@]} -eq 0 ]] && exit 0
[[ ${#ok[@]} -eq 0 ]] && exit 2
exit 6
