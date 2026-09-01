#!/usr/bin/env bash
# 完整审查回路：主审 -> 交叉稽核 -> 综合 -> 判收敛，最多 N 轮。
#
#   loop.sh --paper FILE --outdir BASE [--code-root DIR]
#           [--max-rounds N] [--jobs N] [--timeout SEC]
#           [--auditor codex|claude] [--group A,B,C] [--only dim,dim]
#           [--no-audit] [--yes]
#
# 每轮产物落在 $BASE/rN/，报告是 $BASE/rN/PRE_SUBMIT_REPORT.md。
# 轮次之间需要人去改论文/代码——所以默认在交互式终端里暂停等回车。
# 非交互环境（CI、后台任务）跑完一轮就停，并提示改完后重跑，绝不空转。
#
# 收敛判据见 converged.py：比的是 CRITICAL 的证据锚点集合，不是条数。
#
# 退出码: 0 收敛 / 1 用法错 / 6 跑满轮次仍未收敛 / 7 停滞（改动未生效）
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PAPER="" BASE="" CODE_ROOT="" MAX_ROUNDS=3 JOBS=4 TIMEOUT=900
AUDITOR="" GROUP_SEL="" ONLY="" NO_AUDIT=0 ASSUME_YES=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --paper)      PAPER="$2"; shift 2 ;;
    --outdir)     BASE="$2"; shift 2 ;;
    --code-root)  CODE_ROOT="$2"; shift 2 ;;
    --max-rounds) MAX_ROUNDS="$2"; shift 2 ;;
    --jobs)       JOBS="$2"; shift 2 ;;
    --timeout)    TIMEOUT="$2"; shift 2 ;;
    --auditor)    AUDITOR="$2"; shift 2 ;;
    --group)      GROUP_SEL="$2"; shift 2 ;;
    --only)       ONLY="$2"; shift 2 ;;
    --no-audit)   NO_AUDIT=1; shift ;;
    --yes)        ASSUME_YES=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

[[ -z "$PAPER" || -z "$BASE" ]] && {
  echo "usage: --paper FILE --outdir BASE [--code-root DIR] [--max-rounds N]" >&2; exit 1; }
[[ -r "$PAPER" ]] || { echo "paper not readable: $PAPER" >&2; exit 1; }
[[ "$MAX_ROUNDS" =~ ^[1-9][0-9]*$ ]] || { echo "--max-rounds 必须是正整数" >&2; exit 1; }
if [[ -n "$CODE_ROOT" ]]; then
  [[ -d "$CODE_ROOT" ]] || { echo "code-root 不是目录: $CODE_ROOT" >&2; exit 1; }
  CODE_ROOT="$(cd "$CODE_ROOT" && pwd)"
fi

PAPER_ABS="$(cd "$(dirname "$PAPER")" && pwd)/$(basename "$PAPER")"
mkdir -p "$BASE"
LOG="$BASE/convergence.log"
: >"$LOG"

log() { echo "$*" | tee -a "$LOG"; }

log "===== oh-my-review 回路 ====="
log "论文: $PAPER_ABS"
[[ -n "$CODE_ROOT" ]] && log "代码: $CODE_ROOT" || log "代码: (未提供，B/C 组维度将跳过)"
log "最多 $MAX_ROUNDS 轮，并发 $JOBS"
log ""

FINAL_RC=6
PREV_MERGED=""

for (( round=1; round<=MAX_ROUNDS; round++ )); do
  RD="$BASE/r$round"
  mkdir -p "$RD"
  log "───── 第 $round 轮 ─────"

  # ---- 阶段1：主审 ----
  log "[1/4] 主审各维度..."
  run_args=(--paper "$PAPER_ABS" --outdir "$RD" --jobs "$JOBS" --timeout "$TIMEOUT")
  [[ -n "$CODE_ROOT" ]] && run_args+=(--code-root "$CODE_ROOT")
  [[ -n "$GROUP_SEL" ]] && run_args+=(--group "$GROUP_SEL")
  [[ -n "$ONLY" ]] && run_args+=(--only "$ONLY")
  "$ROOT/scripts/run_all.sh" "${run_args[@]}" 2>&1 | tee -a "$LOG"
  run_rc=${PIPESTATUS[0]}
  # 2 = 全部维度失败，没有任何可稽核可综合的东西
  if [[ $run_rc -eq 2 ]]; then
    log "主审全部失败，中止（见 $RD/*.run.log）"
    FINAL_RC=6; break
  fi

  # ---- 阶段2：交叉稽核 ----
  # 只稽核真正产出了 findings 文件的维度。用 manifest 列举维度名，
  # 不 glob——outdir 里还有 .raw.json / .rejected.json / .audit.json
  if [[ $NO_AUDIT -eq 1 ]]; then
    log "[2/4] 交叉稽核：已用 --no-audit 跳过"
  else
    log "[2/4] 交叉稽核（对侧引擎复核）..."
    while IFS=$'\t' read -r dim group engine _rest; do
      [[ -z "$dim" || "$dim" == \#* ]] && continue
      [[ -f "$RD/$dim.json" ]] || continue
      while [[ "$(jobs -rp | wc -l)" -ge "$JOBS" ]]; do wait -n 2>/dev/null || break; done
      (
        aud_args=(--paper "$PAPER_ABS" --dim "$dim" --outdir "$RD" --timeout "$TIMEOUT")
        [[ -n "$CODE_ROOT" ]] && aud_args+=(--code-root "$CODE_ROOT")
        [[ -n "$AUDITOR" ]] && aud_args+=(--auditor "$AUDITOR")
        "$ROOT/scripts/cross_audit.sh" "${aud_args[@]}" >"$RD/$dim.audit.run.log" 2>&1
        rc=$?
        case $rc in
          0) echo "  ok    稽核 $dim" ;;
          3) echo "  skip  稽核 $dim（缺前置条件）" ;;
          *) echo "  FAIL  稽核 $dim rc=$rc（见 $RD/$dim.audit.run.log）" ;;
        esac
      ) &
    done <"$ROOT/dimensions/manifest.tsv"
    wait
    # 汇总稽核结果（子 shell 里 echo 的内容已经到 stdout，这里只补日志）
    n_audit=$(ls "$RD"/*.audit.json 2>/dev/null | wc -l)
    log "  稽核产出 $n_audit 个维度"
  fi

  # ---- 阶段3：综合 ----
  log "[3/4] 综合与去重..."
  MERGED="$RD/merged.json"
  syn_args=(--outdir "$RD" --report "$RD/PRE_SUBMIT_REPORT.md"
            --paper "$PAPER_ABS" --json-out "$MERGED")
  [[ -n "$CODE_ROOT" ]] && syn_args+=(--code-root "$CODE_ROOT")
  python3 "$ROOT/scripts/synthesize.py" "${syn_args[@]}" 2>&1 | tee -a "$LOG"
  if [[ ! -s "$MERGED" ]]; then
    log "综合失败，没有 merged.json，中止"
    FINAL_RC=6; break
  fi

  # ---- 阶段4：判收敛 ----
  log "[4/4] 判收敛..."
  conv_args=(--curr "$MERGED" --severity CRITICAL)
  [[ -n "$PREV_MERGED" ]] && conv_args+=(--prev "$PREV_MERGED")
  conv_out="$(python3 "$ROOT/scripts/converged.py" "${conv_args[@]}")"
  conv_rc=$?
  log "  $conv_out"
  log "  报告: $RD/PRE_SUBMIT_REPORT.md"

  case $conv_rc in
    0) log ""; log "✓ 收敛：CRITICAL 已清零"; FINAL_RC=0; break ;;
    2) log ""; log "⚠ 停滞：与上一轮完全相同，说明改动未生效。停止以免空烧 token。"
       FINAL_RC=7; break ;;
  esac

  PREV_MERGED="$MERGED"

  if [[ $round -eq $MAX_ROUNDS ]]; then
    log ""
    log "已跑满 $MAX_ROUNDS 轮，仍有 CRITICAL 未清。如实报告，不强行收敛。"
    FINAL_RC=6
    break
  fi

  # ---- 轮次间：等人改稿 ----
  log ""
  if [[ $ASSUME_YES -eq 1 ]]; then
    log "（--yes：不等待，直接进入下一轮。注意：论文未改时下一轮必然停滞）"
  elif [[ -t 0 ]]; then
    echo "─────────────────────────────────────────"
    echo "请按报告修复 CRITICAL 问题，改完后按回车继续第 $((round+1)) 轮"
    echo "（Ctrl-C 退出，已有报告不会丢）"
    read -r
  else
    log "非交互环境：本轮结束。请按 $RD/PRE_SUBMIT_REPORT.md 修复后重跑本命令继续。"
    break
  fi
done

log ""
log "===== 回路结束（rc=$FINAL_RC）====="
exit $FINAL_RC
