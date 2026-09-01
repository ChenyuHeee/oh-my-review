#!/usr/bin/env python3
"""闸门 2：确定性引文校验。不花 token。

把每条 finding 的 quote 匹配回 paper.md。对不上就是幻觉，就地丢弃——
在调用任何模型之前。这是整条管线里唯一确定性的一环。

    quote_check.py --paper paper.md --findings f.json --out kept.json
                   [--rejected rej.json] [--require-quote-above MINOR]
                   [--code-root DIR]

C 组（论文 vs 代码）的 finding 断言的是两个来源之间的矛盾，因此额外带
`counter_quote` + `counter_source`（相对 --code-root 的文件路径）。两侧都要
逐字命中才保留：只有这样"论文说 X，代码实际是 Y"才不是编出来的。缺 --code-root
而条目带 counter_source 时直接丢弃——宁可漏报，不可让未校验的条目混进去。

B 组（代码与实验）的证据只在代码里，没有可引的论文原话，因此允许只带
counter_quote + counter_source 而没有 quote；此时代码侧必须命中。校验的是
"有据可查"，不是"必须出现在论文里"。

输出 kept.json（存活条目，补上校验后的真实行号并分配 id）。
退出码 0 = 正常（哪怕全被丢），1 = 用法或解析错。
"""
import argparse
import json
import re
import sys
import unicodedata
from pathlib import Path

SEVERITY_ORDER = {"MINOR": 0, "RECOMMENDED": 1, "CRITICAL": 2}
PAIR_REQUIRED = "counter_quote 与 counter_source 必须成对出现"


def normalize(text: str, code: bool = False) -> str:
    """抹掉不影响语义的排版差异，但不放松实质内容。

    统一 Unicode 标点（模型常把 " 输出成弯引号）、折叠空白、去掉
    markdown 强调记号。大小写保留——记号的大小写差异是有意义的。
    """
    text = unicodedata.normalize("NFKC", text)
    for a, b in (("“", '"'), ("”", '"'), ("‘", "'"),
                 ("’", "'"), ("—", "-"), ("–", "-"),
                 ("−", "-"), (" ", " ")):
        text = text.replace(a, b)
    # code=True 时保留 * _ ` 三个字符：在源码里它们是标识符的一部分，
    # 抹掉会让 use_real_data 和 userealdata 归一化成同一个串。
    if not code:
        text = re.sub(r"[*_`]", "", text)
    text = re.sub(r"\s+", " ", text)
    return text.strip()


def load_paper(path: Path):
    """返回 (归一化全文, 每行归一化文本列表)。

    paper.md 带 tab 分隔的行号锚点前缀，剥掉后才能匹配。
    """
    raw_lines = path.read_text(encoding="utf-8").splitlines()
    stripped = []
    for ln in raw_lines:
        m = re.match(r"^\s*(\d+)\t(.*)$", ln)
        stripped.append(m.group(2) if m else ln)
    return normalize(" ".join(stripped)), [normalize(x) for x in stripped]


_SOURCE_CACHE = {}


def load_code_source(code_root: Path, rel: str):
    """按需读入并缓存一个代码文件，返回 (归一化全文, 归一化行列表)。

    找不到或读不了返回 None——调用方据此丢弃条目，而不是当作命中。
    路径必须落在 code_root 内：模型给出的 counter_source 是不可信输入，
    ../ 逃逸会把校验范围扩大到仓库之外。
    """
    key = (str(code_root), rel)
    if key in _SOURCE_CACHE:
        return _SOURCE_CACHE[key]
    result = None
    try:
        target = (code_root / rel).resolve()
        root = code_root.resolve()
        if target.is_file() and (target == root or root in target.parents):
            lines = target.read_text(encoding="utf-8", errors="replace").splitlines()
            result = (normalize(" ".join(lines), code=True),
                      [normalize(x, code=True) for x in lines])
    except OSError:
        result = None
    _SOURCE_CACHE[key] = result
    return result


def check_counter(finding: dict, code_root):
    """校验 C 组 finding 的代码侧引文。返回 (是否保留, 原因)。

    没有 counter_source 的条目（A/B 组）直接放行，不受影响。
    """
    src = (finding.get("counter_source") or "").strip()
    cq = finding.get("counter_quote") or ""
    if not src and not cq:
        return True, ""
    if not src or not cq:
        return False, PAIR_REQUIRED
    if code_root is None:
        return False, f"条目引用代码 {src}，但未提供 --code-root，无法校验"

    loaded = load_code_source(code_root, src)
    if loaded is None:
        return False, f"counter_source 不存在、不可读或越出 --code-root: {src}"

    code_full, code_lines = loaded
    q = normalize(cq, code=True)
    if len(q) < 8:
        return False, f"代码引文过短（{len(q)} 字符），无判别力"
    if q in code_full:
        finding["counter_line"] = locate_line(q, code_lines)
        return True, "两侧逐字命中"

    parts = [normalize(p, code=True).strip(". ") for p in re.split(r"\.{3,}|…", q)]
    parts = [p for p in parts if len(p) >= 8]
    if len(parts) > 1 and all(p in code_full for p in parts):
        finding["counter_line"] = locate_line(parts[0], code_lines)
        return True, "两侧命中（代码侧分段）"

    return False, f"代码引文在 {src} 中不存在（幻觉）"


def locate_line(quote: str, lines: list) -> int:
    """定位引文首行，1-based。跨行引文只需匹配开头片段。"""
    head = quote[:60]
    for i, line in enumerate(lines, start=1):
        if line and (head in line or (len(line) > 20 and line in quote)):
            return i
    return 0


def check(finding: dict, paper_full: str, paper_lines: list, require_above: str,
          has_code_anchor: bool = False):
    """返回 (是否保留, 原因, 校验后行号)。

    has_code_anchor=True 表示条目带成对的 counter_quote + counter_source：
    B 组（代码与实验）的证据本来就在代码里，没有对应的论文原话可引。这类条目
    允许没有 quote，但随后必须通过 check_counter——门槛是"有据可查"，
    不是"必须出现在论文里"。
    """
    sev = (finding.get("severity") or "").upper()
    quote = finding.get("quote") or ""
    q = normalize(quote)

    threshold = SEVERITY_ORDER.get(require_above.upper(), 0)
    needs_quote = SEVERITY_ORDER.get(sev, 0) >= threshold

    if not q:
        if needs_quote and not has_code_anchor:
            # 给了一半的代码侧锚定时，说清缺的是哪一半——rejected.json 是给
            # 下一轮改的，"无引文"会把作者引向错误的方向。
            half = bool(finding.get("counter_quote")) != bool(
                (finding.get("counter_source") or "").strip())
            return False, PAIR_REQUIRED if half else "无引文", 0
        reason = "仅代码侧锚定" if has_code_anchor else "免校验（低于引文门槛）"
        return True, reason, finding.get("line", 0) or 0

    # 太短的引文没有判别力，容易碰巧命中
    if len(q) < 12:
        return False, f"引文过短（{len(q)} 字符），无判别力", 0

    if q in paper_full:
        return True, "逐字命中", locate_line(q, paper_lines)

    # 允许省略号切分的引文：各段都必须独立命中。
    # 切分后要剥掉残留的首尾句点——"results....outperforming" 这类
    # 四点写法会给下一段留一个前导点，导致本该命中的引文被误判为幻觉。
    parts = [normalize(p).strip(". ") for p in re.split(r"\.{3,}|…", q)]
    parts = [p for p in parts if len(p) >= 12]
    if len(parts) > 1 and all(p in paper_full for p in parts):
        return True, "分段命中（省略号）", locate_line(parts[0], paper_lines)

    return False, "引文在原文中不存在（幻觉）", 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--paper", required=True, type=Path)
    ap.add_argument("--findings", required=True, type=Path)
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--rejected", type=Path)
    ap.add_argument("--require-quote-above", default="MINOR",
                    help="该等级及以上必须带引文，默认 MINOR 即全部")
    ap.add_argument("--code-root", type=Path, default=None,
                    help="C 组代码根目录；counter_source 相对它解析")
    args = ap.parse_args()

    if not args.paper.is_file():
        print(f"paper 不存在: {args.paper}", file=sys.stderr)
        return 1
    if args.code_root is not None and not args.code_root.is_dir():
        print(f"--code-root 不是目录: {args.code_root}", file=sys.stderr)
        return 1
    try:
        payload = json.loads(args.findings.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as e:
        print(f"findings 解析失败: {e}", file=sys.stderr)
        return 1

    paper_full, paper_lines = load_paper(args.paper)
    dimension = payload.get("dimension", "unknown") if isinstance(payload, dict) else "unknown"
    items = payload.get("findings", []) if isinstance(payload, dict) else payload

    kept, rejected = [], []
    for idx, f in enumerate(items, start=1):
        if not isinstance(f, dict):
            rejected.append({"raw": f, "reject_reason": "条目不是对象"})
            continue
        has_code_anchor = bool((f.get("counter_source") or "").strip()
                               and (f.get("counter_quote") or ""))
        ok, reason, line = check(f, paper_full, paper_lines,
                                 args.require_quote_above, has_code_anchor)
        entry = dict(f)
        entry["id"] = f"{dimension}-{idx:02d}"
        if ok:
            # 论文侧过了还要看代码侧（C 组）。两侧都得是真的。
            ok, creason = check_counter(entry, args.code_root)
            if not ok:
                reason = creason
            elif creason:
                reason = f"{reason}；{creason}"
        if ok:
            entry["line"] = line or f.get("line", 0)
            entry["quote_check"] = reason
            kept.append(entry)
        else:
            entry["reject_reason"] = reason
            rejected.append(entry)

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(
        {"dimension": dimension, "findings": kept}, ensure_ascii=False, indent=2),
        encoding="utf-8")
    if args.rejected:
        args.rejected.parent.mkdir(parents=True, exist_ok=True)
        args.rejected.write_text(json.dumps(
            {"dimension": dimension, "rejected": rejected}, ensure_ascii=False, indent=2),
            encoding="utf-8")

    total = len(kept) + len(rejected)
    print(f"[quote_check] {dimension}: 送检 {total}，保留 {len(kept)}，丢弃 {len(rejected)}")
    for r in rejected:
        loc = r.get("location", "?")
        print(f"  丢弃 [{r.get('severity', '?')}] {loc}: {r.get('reject_reason')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
