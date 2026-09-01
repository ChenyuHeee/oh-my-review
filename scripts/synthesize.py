#!/usr/bin/env python3
"""综合阶段：应用稽核裁定 -> 按证据锚点去重 -> 出报告。

    synthesize.py --outdir DIR --report FILE [--paper FILE] [--code-root DIR]
                  [--manifest FILE]

输入是各维度的产物（run_dimension.sh 与 cross_audit.sh 落在同一个 outdir）：
    $DIM.json         主审方 findings（已过闸门2）
    $DIM.audit.json   稽核裁定 + 稽核方补的漏报（已过闸门3）

维度 id 从 manifest 读，不用 glob——outdir 里同时有 $DIM.json、$DIM.audit.json、
$DIM.raw.json、$DIM.rejected.json，glob 极易串味。

裁定的处理：
    FALSE_POSITIVE  丢弃（但记进统计，报告末尾给出数量）
    DOWNGRADE       按 corrected_severity 降级，保留 steelman 说明
    CONFIRMED       原样保留
    NO_VERDICT      保留原判，标注"未经复核"

退出码 0 = 正常，1 = 用法或解析错。
"""
import argparse
import json
import sys
from collections import defaultdict
from datetime import datetime
from pathlib import Path

SEVERITY_ORDER = {"MINOR": 0, "RECOMMENDED": 1, "CRITICAL": 2}
SEVERITY_DESC = ["CRITICAL", "RECOMMENDED", "MINOR"]


def load_dimensions(manifest: Path):
    """读 manifest，返回 [(dim, group, lead), ...]，保持登记顺序。"""
    dims = []
    if not manifest.is_file():
        return dims
    for raw in manifest.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = raw.split("\t")
        if len(parts) >= 3:
            dims.append((parts[0].strip(), parts[1].strip(), parts[2].strip()))
    return dims


def read_json(path: Path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None


def collect(outdir: Path, dims):
    """把主审 findings 与稽核裁定合到一起。

    返回 (findings, stats)。findings 里每条都带 verdict / dimension /
    audited 三个字段，供去重与报告使用。
    """
    findings = []
    stats = {
        "dimensions_present": 0, "dimensions_missing": [],
        "audited": 0, "unaudited": [],
        "false_positive": 0, "downgraded": 0, "no_verdict": 0,
        "auditor_added": 0,
    }

    for dim, group, lead in dims:
        fpath = outdir / f"{dim}.json"
        data = read_json(fpath)
        if data is None:
            stats["dimensions_missing"].append(dim)
            continue
        stats["dimensions_present"] += 1
        items = data.get("findings", []) if isinstance(data, dict) else data

        apath = outdir / f"{dim}.audit.json"
        audit = read_json(apath)
        verdict_by_id = {}
        if audit is not None:
            stats["audited"] += 1
            for v in audit.get("verdicts", []):
                if isinstance(v, dict) and "id" in v:
                    verdict_by_id[v["id"]] = v
        else:
            stats["unaudited"].append(dim)

        for f in items:
            if not isinstance(f, dict):
                continue
            entry = dict(f)
            entry.setdefault("dimension", dim)
            entry["group"] = group
            entry["lead_engine"] = lead
            entry["found_by"] = entry.get("found_by", "lead")

            v = verdict_by_id.get(entry.get("id"))
            if v is None:
                entry["verdict"] = "UNAUDITED"
                entry["audit_reason"] = None
                entry["paper_already_addresses"] = None
            else:
                verdict = v.get("verdict", "NO_VERDICT")
                entry["verdict"] = verdict
                entry["audit_reason"] = v.get("reason")
                entry["paper_already_addresses"] = v.get("paper_already_addresses")
                if verdict == "FALSE_POSITIVE":
                    stats["false_positive"] += 1
                    continue  # 丢弃
                if verdict == "DOWNGRADE":
                    cs = v.get("corrected_severity")
                    if cs in SEVERITY_ORDER:
                        entry["original_severity"] = entry.get("severity")
                        entry["severity"] = cs
                        stats["downgraded"] += 1
                elif verdict == "NO_VERDICT":
                    stats["no_verdict"] += 1
            findings.append(entry)

        # 稽核方补的漏报（已过闸门3 的引文校验）
        if audit is not None:
            for m in audit.get("missed", []):
                if not isinstance(m, dict):
                    continue
                entry = dict(m)
                entry.setdefault("dimension", dim)
                entry["group"] = group
                entry["lead_engine"] = lead
                entry["found_by"] = "auditor"
                entry["verdict"] = "AUDITOR_FOUND"
                entry["audit_reason"] = "主审方漏报，稽核方补充"
                entry.setdefault("paper_already_addresses", None)
                findings.append(entry)
                stats["auditor_added"] += 1

    return findings, stats


def anchor_key(f):
    """去重键。同一处证据的条目应当归并。

    优先用代码锚点：B 组（代码与实验）和 C 组（论文 vs 代码）常常就同一行配置
    各出一条，框架不同但底层证据相同。其次用论文锚点。都没有就按 id 独立。
    """
    src = (f.get("counter_source") or "").strip()
    cq = (f.get("counter_quote") or "").strip()
    if src and cq:
        return ("code", src, cq)
    quote = (f.get("quote") or "").strip()
    if quote:
        return ("paper", quote)
    return ("id", f.get("id", id(f)))


def merge_group(group):
    """归并同锚点的多条 finding。

    取最高等级作底；C 组的表述更具体（"论文说 X，代码是 Y"），同级时优先。
    各维度的视角合并进 issue，不丢信息。
    """
    if len(group) == 1:
        return group[0]

    def rank(f):
        sev = SEVERITY_ORDER.get((f.get("severity") or "").upper(), 0)
        specific = 1 if f.get("group") == "C" else 0
        return (sev, specific)

    base = dict(max(group, key=rank))
    dims, issues, ids = [], [], []
    for f in group:
        d = f.get("dimension", "?")
        if d not in dims:
            dims.append(d)
        issue = (f.get("issue") or "").strip()
        if issue and issue not in issues:
            issues.append(f"[{d}] {issue}")
        if f.get("id"):
            ids.append(f["id"])

    base["issue"] = " | ".join(issues) if issues else base.get("issue", "")
    base["dimensions"] = dims
    base["merged_from"] = ids
    base["merged_count"] = len(group)

    # 稽核状态取组内最强信号。base 可能来自某个未稽核的维度，若组里另一条
    # 已被对侧引擎确认，报"未经交叉稽核"会低估这条 finding 的可信度。
    AUDIT_RANK = {
        "UNAUDITED": 0, "NO_VERDICT": 1,
        "AUDITOR_FOUND": 2, "DOWNGRADE": 3, "CONFIRMED": 4,
    }
    best = max(group, key=lambda f: AUDIT_RANK.get(f.get("verdict", "UNAUDITED"), 0))
    if AUDIT_RANK.get(best.get("verdict", "UNAUDITED"), 0) > \
       AUDIT_RANK.get(base.get("verdict", "UNAUDITED"), 0):
        base["verdict"] = best.get("verdict")
        base["audit_reason"] = best.get("audit_reason")
        if best.get("original_severity"):
            base["original_severity"] = best["original_severity"]
    # steelman 线索只要有一条给了就保留
    for f in group:
        if f.get("paper_already_addresses"):
            base["paper_already_addresses"] = f["paper_already_addresses"]
            break

    fixes = []
    for f in group:
        fx = (f.get("fix") or "").strip()
        if fx and fx not in fixes:
            fixes.append(fx)
    if fixes:
        base["fix"] = " / ".join(fixes)
    return base


def dedup(findings):
    buckets = defaultdict(list)
    for f in findings:
        buckets[anchor_key(f)].append(f)
    merged = [merge_group(g) for g in buckets.values()]
    merged.sort(key=lambda f: (
        -SEVERITY_ORDER.get((f.get("severity") or "").upper(), 0),
        f.get("line") or 0,
        f.get("dimension", ""),
    ))
    return merged, len(findings) - len(merged)


HEADLINE_MAX = 100
# 在这些位置断句都比硬截好。半角逗号后面常跟着数字（"51.4, 48.6"），不收。
CLAUSE_BREAKS = "，。；、！？,;!?"


def headline(f):
    """标题取第一条 issue，去掉归并时加的 [维度] 前缀——维度已在元信息行列出。

    过长时在最近的分句处断开，不在数字或公式中间硬截——
    "51.4 - 48" 这种截断会让读者以为报告本身出错了。完整描述在下面的
    **问题** 一行里，标题只需要能扫读。
    """
    first = (f.get("issue") or "(无描述)").split(" | ")[0].strip()
    if first.startswith("["):
        close = first.find("]")
        if close != -1:
            first = first[close + 1:].strip() or first
    if len(first) <= HEADLINE_MAX:
        return first

    window = first[:HEADLINE_MAX]
    cut = max(window.rfind(c) for c in CLAUSE_BREAKS)
    # 断点太靠前就宁可退回按空格断，避免标题只剩几个字
    if cut < HEADLINE_MAX // 2:
        cut = window.rfind(" ")
    if cut < HEADLINE_MAX // 3:
        cut = HEADLINE_MAX
    return first[:cut].rstrip(CLAUSE_BREAKS + " ") + "…"


def fmt_finding(f, tag):
    L = []
    L.append(f"### [{tag}] {headline(f)}")
    L.append("")

    loc = f.get("location") or "?"
    line = f.get("line")
    meta = f"**位置**: {loc}"
    if line:
        meta += f" · `paper.md:{line}`"
    dims = f.get("dimensions") or [f.get("dimension", "?")]
    meta += f" · **维度**: {', '.join(dims)}"
    L.append(meta)

    if f.get("counter_source"):
        cl = f.get("counter_line")
        ref = f"`{f['counter_source']}"
        ref += f":{cl}`" if cl else "`"
        L.append(f"**代码**: {ref}")
    L.append("")

    if f.get("merged_count", 1) > 1:
        L.append(f"> 由 {f['merged_count']} 条同证据的 finding 归并"
                 f"（{', '.join(f.get('merged_from', []))}）")
        L.append("")

    L.append(f"**问题**: {f.get('issue', '')}")
    L.append("")

    if f.get("quote"):
        L.append("**论文原文**:")
        L.append("")
        for ln in f["quote"].strip().splitlines():
            L.append(f"> {ln}")
        L.append("")

    if f.get("counter_quote"):
        L.append("**代码原文**:")
        L.append("")
        L.append("```")
        L.append(f["counter_quote"].strip())
        L.append("```")
        L.append("")

    L.append(f"**建议**: {f.get('fix', '(未给)')}")
    L.append("")

    verdict = f.get("verdict", "UNAUDITED")
    vtext = {
        "CONFIRMED": "稽核确认",
        "DOWNGRADE": f"稽核降级（原 {f.get('original_severity', '?')}）",
        "NO_VERDICT": "稽核方未裁定，保留主审原判",
        "UNAUDITED": "未经交叉稽核",
        "AUDITOR_FOUND": "稽核方补充（主审漏报）",
    }.get(verdict, verdict)
    line_v = f"**稽核**: {vtext}"
    if f.get("audit_reason"):
        line_v += f" — {f['audit_reason']}"
    L.append(line_v)

    if f.get("paper_already_addresses"):
        L.append("")
        L.append(f"**论文已部分自答**: {f['paper_already_addresses']}")
    L.append("")
    L.append("---")
    L.append("")
    return L


CHECKLIST = [
    ("可复现性", [
        "数据集与版本已明确",
        "主结果超参已报告",
        "代码/数据发布计划已说明",
        "随机种子已固定并报告",
    ]),
    ("统计有效性", [
        "主张带误差范围",
        "必要处做了显著性检验",
        "多次运行结果已报告（n ≥ 3）",
        "基线方差已记录",
    ]),
    ("实验设计", [
        "消融隔离了每项贡献",
        "基线排除了混淆因素",
        "测试集在最终评测前未被使用",
        "无 data leakage（划分已核对）",
    ]),
    ("主张与证据", [
        "每条“X 提升 Y”都有证据支撑",
        "无仅凭挑选样例、缺聚合结果的主张",
        "局限性章节覆盖失败模式",
        "新颖性声明与已有工作区分清楚",
    ]),
    ("论文-代码一致性", [
        "报告的超参与配置文件一致",
        "表格数字可由脚本复现",
        "基线实现与所引文献一致",
        "评测指标与论文定义一致",
    ]),
    ("表达质量", [
        "跨章节数字无矛盾",
        "引用完整、格式统一",
    ]),
]


def build_report(findings, stats, meta):
    tally = {s: 0 for s in SEVERITY_DESC}
    for f in findings:
        sev = (f.get("severity") or "MINOR").upper()
        if sev in tally:
            tally[sev] += 1

    L = []
    L.append("# 投稿前审查报告")
    L.append("")
    L.append(f"生成时间: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    L.append(f"论文: `{meta['paper']}`")
    if meta.get("code_root"):
        L.append(f"代码: `{meta['code_root']}`")
    L.append("")
    L.append("---")
    L.append("")
    L.append("## 概览")
    L.append("")
    L.append(f"- **CRITICAL**: {tally['CRITICAL']} 条 —— 投稿前必须处理")
    L.append(f"- **RECOMMENDED**: {tally['RECOMMENDED']} 条 —— 强烈建议处理")
    L.append(f"- **MINOR**: {tally['MINOR']} 条 —— 打磨项")
    L.append("")
    L.append(f"维度覆盖 {stats['dimensions_present']}/{stats['dimensions_present'] + len(stats['dimensions_missing'])}"
             f"，其中 {stats['audited']} 个经过交叉稽核。")
    if stats["false_positive"]:
        L.append(f"稽核阶段判定 {stats['false_positive']} 条为误报并已剔除"
                 f"；{stats['downgraded']} 条降级；稽核方另补 {stats['auditor_added']} 条漏报。")
    if stats.get("deduped"):
        L.append(f"按证据锚点归并了 {stats['deduped']} 条重复 finding。")
    L.append("")
    if stats["dimensions_missing"]:
        L.append(f"> 未产出的维度: {', '.join(stats['dimensions_missing'])}")
        L.append("")
    if stats["unaudited"]:
        L.append(f"> 未经交叉稽核的维度: {', '.join(stats['unaudited'])}"
                 f"（这些维度的 finding 只经过引文校验，未被对侧引擎复核）")
        L.append("")
    L.append("---")
    L.append("")

    prefix = {"CRITICAL": "C", "RECOMMENDED": "R", "MINOR": "M"}
    for sev in SEVERITY_DESC:
        group = [f for f in findings if (f.get("severity") or "").upper() == sev]
        if not group:
            continue
        L.append(f"## {sev}（{len(group)} 条）")
        L.append("")
        for i, f in enumerate(group, 1):
            L.extend(fmt_finding(f, f"{prefix[sev]}-{i}"))

    # 维度矩阵
    L.append("## 维度矩阵")
    L.append("")
    L.append("| 维度 | CRITICAL | RECOMMENDED | MINOR | 合计 |")
    L.append("|---|---|---|---|---|")
    per_dim = defaultdict(lambda: {"CRITICAL": 0, "RECOMMENDED": 0, "MINOR": 0})
    for f in findings:
        sev = (f.get("severity") or "MINOR").upper()
        for d in (f.get("dimensions") or [f.get("dimension", "?")]):
            if sev in per_dim[d]:
                per_dim[d][sev] += 1
    for d in sorted(per_dim):
        c = per_dim[d]
        total = c["CRITICAL"] + c["RECOMMENDED"] + c["MINOR"]
        L.append(f"| {d} | {c['CRITICAL']} | {c['RECOMMENDED']} | {c['MINOR']} | {total} |")
    L.append("")
    L.append("> 归并后的 finding 会同时计入它涉及的每个维度，因此各行合计可能大于问题总数。")
    L.append("")
    L.append("---")
    L.append("")

    n_items = sum(len(v) for _, v in CHECKLIST)
    L.append(f"## 投稿前自检清单（{n_items} 项）")
    L.append("")
    L.append("本工作流只能机械核验其中一部分，逐项确认仍需作者自己过一遍。")
    L.append("")
    for section, items in CHECKLIST:
        L.append(f"### {section}")
        L.append("")
        for it in items:
            L.append(f"- [ ] {it}")
        L.append("")

    L.append("---")
    L.append("")
    L.append("## 下一步")
    L.append("")
    L.append("1. 逐条处理 CRITICAL —— 投稿前的硬门槛")
    L.append("2. 与合作者一起过一遍 RECOMMENDED")
    L.append("3. 改完后重跑本工作流，确认收敛（见 `scripts/loop.sh`）")
    L.append("")
    return "\n".join(L)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--outdir", required=True, type=Path)
    ap.add_argument("--report", required=True, type=Path)
    ap.add_argument("--paper", default="(未记录)")
    ap.add_argument("--code-root", default=None)
    ap.add_argument("--manifest", type=Path, default=None)
    ap.add_argument("--json-out", type=Path, default=None,
                    help="同时输出归并后的 findings JSON，供 loop.sh 判收敛")
    args = ap.parse_args()

    if not args.outdir.is_dir():
        print(f"--outdir 不是目录: {args.outdir}", file=sys.stderr)
        return 1

    manifest = args.manifest or (Path(__file__).resolve().parent.parent
                                 / "dimensions" / "manifest.tsv")
    dims = load_dimensions(manifest)
    if not dims:
        print(f"manifest 里读不到维度: {manifest}", file=sys.stderr)
        return 1

    findings, stats = collect(args.outdir, dims)
    findings, n_dedup = dedup(findings)
    stats["deduped"] = n_dedup

    report = build_report(findings, stats, {
        "paper": args.paper,
        "code_root": args.code_root,
    })
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(report, encoding="utf-8")

    if args.json_out:
        args.json_out.write_text(json.dumps(
            {"findings": findings, "stats": stats}, ensure_ascii=False, indent=2
        ), encoding="utf-8")

    tally = defaultdict(int)
    for f in findings:
        tally[(f.get("severity") or "MINOR").upper()] += 1
    print(f"[synthesize] 维度 {stats['dimensions_present']} 个"
          f"（稽核 {stats['audited']} 个）"
          f" -> CRITICAL={tally['CRITICAL']} "
          f"RECOMMENDED={tally['RECOMMENDED']} MINOR={tally['MINOR']}")
    if n_dedup:
        print(f"  按证据锚点归并 {n_dedup} 条")
    if stats["false_positive"]:
        print(f"  稽核剔除误报 {stats['false_positive']} 条，降级 {stats['downgraded']} 条")
    if stats["auditor_added"]:
        print(f"  稽核方补充漏报 {stats['auditor_added']} 条")
    print(f"  报告: {args.report}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
