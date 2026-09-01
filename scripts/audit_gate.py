#!/usr/bin/env python3
"""闸门 3：校验交叉稽核的输出。

稽核方也会幻觉，所以它的产出同样要过机械校验：

1. `verdicts` 里的 id 必须对得上送审的 findings。对不上的丢弃（稽核方编了个
   不存在的条目），没被裁定到的 finding 标记为 NO_VERDICT（稽核方漏裁了）。
2. `missed`（稽核方声称主审方漏报的问题）走与主审方完全相同的引文校验——
   复用 quote_check 的逻辑，不另写一套。
3. DOWNGRADE 必须给 corrected_severity，否则降级为 CONFIRMED（宁可保留
   原等级，也不要让一条问题因为字段缺失而悄悄消失）。

    audit_gate.py --paper paper.md --audit raw.json --findings kept.json
                  --out audit.json [--code-root DIR]

退出码 0 = 正常，1 = 用法或解析错。
"""
import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from quote_check import (  # noqa: E402
    SEVERITY_ORDER, check, check_counter, load_paper,
)

VALID_VERDICTS = {"CONFIRMED", "DOWNGRADE", "FALSE_POSITIVE"}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--paper", required=True, type=Path)
    ap.add_argument("--audit", required=True, type=Path,
                    help="稽核引擎的原始输出")
    ap.add_argument("--findings", required=True, type=Path,
                    help="送审的 findings（用于校验 verdict id）")
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--code-root", type=Path, default=None)
    args = ap.parse_args()

    if not args.paper.is_file():
        print(f"paper 不存在: {args.paper}", file=sys.stderr)
        return 1
    if args.code_root is not None and not args.code_root.is_dir():
        print(f"--code-root 不是目录: {args.code_root}", file=sys.stderr)
        return 1

    try:
        audit = json.loads(args.audit.read_text(encoding="utf-8"))
        submitted = json.loads(args.findings.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as e:
        print(f"解析失败: {e}", file=sys.stderr)
        return 1

    sub_items = submitted.get("findings", []) if isinstance(submitted, dict) else submitted
    dimension = submitted.get("dimension", "unknown") if isinstance(submitted, dict) else "unknown"
    sub_by_id = {f["id"]: f for f in sub_items if isinstance(f, dict) and "id" in f}

    paper_full, paper_lines = load_paper(args.paper)

    # ---- 1. verdicts ----
    verdicts, bogus = [], []
    seen = set()
    for v in (audit.get("verdicts") or []):
        if not isinstance(v, dict):
            bogus.append({"raw": v, "reject_reason": "verdict 不是对象"})
            continue
        vid = v.get("id")
        if vid not in sub_by_id:
            bogus.append({**v, "reject_reason": f"id 不在送审列表里: {vid}"})
            continue
        if vid in seen:
            bogus.append({**v, "reject_reason": f"id 重复裁定: {vid}"})
            continue
        verdict = (v.get("verdict") or "").upper()
        if verdict not in VALID_VERDICTS:
            bogus.append({**v, "reject_reason": f"verdict 取值非法: {verdict}"})
            continue

        entry = dict(v)
        entry["verdict"] = verdict
        # DOWNGRADE 缺 corrected_severity 就退回 CONFIRMED：等级只能由明确的
        # 裁定来降，不能因为字段没填就让问题静默消失
        if verdict == "DOWNGRADE":
            cs = (entry.get("corrected_severity") or "")
            cs = cs.upper() if isinstance(cs, str) else ""
            orig = (sub_by_id[vid].get("severity") or "").upper()
            if cs not in SEVERITY_ORDER:
                entry["verdict"] = "CONFIRMED"
                entry["corrected_severity"] = None
                entry["gate_note"] = "DOWNGRADE 未给合法 corrected_severity，退回 CONFIRMED"
            elif orig in SEVERITY_ORDER and SEVERITY_ORDER[cs] >= SEVERITY_ORDER[orig]:
                # "降级"到同级或更高级是矛盾的
                entry["verdict"] = "CONFIRMED"
                entry["corrected_severity"] = None
                entry["gate_note"] = f"corrected_severity({cs}) 未低于原等级({orig})，退回 CONFIRMED"
            else:
                entry["corrected_severity"] = cs
        else:
            entry["corrected_severity"] = None
        seen.add(vid)
        verdicts.append(entry)

    # 漏裁的 finding：保留原等级，标记出来让综合阶段知道这条没被复核过
    no_verdict = [fid for fid in sub_by_id if fid not in seen]
    for fid in no_verdict:
        verdicts.append({
            "id": fid,
            "verdict": "NO_VERDICT",
            "corrected_severity": None,
            "reason": "稽核方未对该条给出裁定，保留主审方原判",
            "paper_already_addresses": None,
        })

    # ---- 2. missed：与主审方同样的引文校验 ----
    missed_kept, missed_rejected = [], []
    for idx, m in enumerate((audit.get("missed") or []), start=1):
        if not isinstance(m, dict):
            missed_rejected.append({"raw": m, "reject_reason": "条目不是对象"})
            continue
        has_code_anchor = bool((m.get("counter_source") or "").strip()
                               and (m.get("counter_quote") or ""))
        ok, reason, line = check(m, paper_full, paper_lines, "MINOR", has_code_anchor)
        entry = dict(m)
        entry["id"] = f"{dimension}-audit-{idx:02d}"
        entry["found_by"] = "auditor"
        if ok:
            ok, creason = check_counter(entry, args.code_root)
            if not ok:
                reason = creason
            elif creason:
                reason = f"{reason}；{creason}"
        if ok:
            entry["line"] = line or m.get("line", 0)
            entry["quote_check"] = reason
            missed_kept.append(entry)
        else:
            entry["reject_reason"] = reason
            missed_rejected.append(entry)

    out = {
        "dimension": dimension,
        "verdicts": verdicts,
        "missed": missed_kept,
        "gate": {
            "submitted": len(sub_by_id),
            "verdicts_valid": len(seen),
            "verdicts_bogus": bogus,
            "no_verdict": no_verdict,
            "missed_submitted": len(missed_kept) + len(missed_rejected),
            "missed_rejected": missed_rejected,
        },
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(out, ensure_ascii=False, indent=2), encoding="utf-8")

    tally = {}
    for v in verdicts:
        tally[v["verdict"]] = tally.get(v["verdict"], 0) + 1
    summary = "，".join(f"{k}={v}" for k, v in sorted(tally.items())) or "无"
    print(f"[audit_gate] {dimension}: 裁定 {summary}")
    print(f"  漏报补充: 保留 {len(missed_kept)}，丢弃 {len(missed_rejected)}")
    for b in bogus:
        print(f"  丢弃裁定: {b.get('reject_reason')}")
    for r in missed_rejected:
        print(f"  丢弃漏报 [{r.get('severity','?')}] {r.get('location','?')}: {r.get('reject_reason')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
