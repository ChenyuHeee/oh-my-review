#!/usr/bin/env python3
"""判断两轮之间是否收敛。

    converged.py --curr merged.json [--prev merged.json] [--severity CRITICAL]

只数条数不够：作者修掉 2 条、又引入 2 条新的，数量不变但显然没收敛。
所以比的是**证据锚点集合**——同一处证据才算同一个问题。

stdout 输出一行人类可读摘要，退出码给调用方判断：
    0 = 已收敛（该等级零问题）
    1 = 未收敛，仍有新进展（锚点集合有变化）
    2 = 停滞（锚点集合与上一轮完全相同，改动没生效）
"""
import argparse
import json
import sys
from pathlib import Path


def anchors(path: Path, severity: str):
    """取指定等级的 finding 锚点集合。锚点定义与 synthesize.py 保持一致。"""
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    out = set()
    for f in data.get("findings", []):
        if (f.get("severity") or "").upper() != severity.upper():
            continue
        src = (f.get("counter_source") or "").strip()
        cq = (f.get("counter_quote") or "").strip()
        if src and cq:
            out.add(("code", src, cq))
            continue
        q = (f.get("quote") or "").strip()
        out.add(("paper", q) if q else ("id", f.get("id", "")))
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--curr", required=True, type=Path)
    ap.add_argument("--prev", type=Path, default=None)
    ap.add_argument("--severity", default="CRITICAL")
    args = ap.parse_args()

    curr = anchors(args.curr, args.severity)
    if curr is None:
        print(f"读不到本轮结果: {args.curr}")
        return 1

    sev = args.severity.upper()
    if not curr:
        print(f"已收敛：{sev} 清零")
        return 0

    if args.prev is None:
        print(f"未收敛：{sev} 仍有 {len(curr)} 条（首轮，无上一轮可比）")
        return 1

    prev = anchors(args.prev, args.severity)
    if prev is None:
        print(f"未收敛：{sev} 仍有 {len(curr)} 条（读不到上一轮，无法比对）")
        return 1

    fixed = prev - curr
    new = curr - prev
    persist = curr & prev

    if not fixed and not new:
        print(f"停滞：{sev} {len(curr)} 条与上一轮完全相同，改动未生效或未改动")
        return 2

    parts = [f"{sev} 仍有 {len(curr)} 条"]
    if fixed:
        parts.append(f"已修 {len(fixed)}")
    if new:
        parts.append(f"新增 {len(new)}")
    if persist:
        parts.append(f"未动 {len(persist)}")
    print("未收敛：" + "，".join(parts))
    return 1


if __name__ == "__main__":
    sys.exit(main())
