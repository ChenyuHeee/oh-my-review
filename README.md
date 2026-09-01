# oh-my-review (omr)

投稿前论文自审工作流。Claude Code 与 Codex CLI 互相稽核，产出可执行的修改清单。

核心判断：**AI 审稿的瓶颈不是发现问题，而是幻觉发现** —— 编造原文引用、把论文没说的话
归因给论文、报一个第 3 节其实已经回答了的「缺陷」。所以管线里最重的一环是三道闸门，
其中闸门 2 完全确定性、不花 token。

## 快速开始

```bash
# 只审论文文本（A 组，8 个维度）
./scripts/loop.sh --paper paper.md --outdir runs/pass1

# 论文 + 代码全量审（A/B/C 共 14 个维度）
./scripts/loop.sh --paper paper.md --code-root . --outdir runs/pass1

# 先跑一个维度试试
./scripts/loop.sh --paper paper.md --outdir /tmp/try --only numeric-consistency
```

报告落在 `runs/pass1/r1/PRE_SUBMIT_REPORT.md`。改完后重跑同一条命令继续下一轮。

## 管线

```
Stage 0  摄取      pdf2md -> paper.md（带行号锚点）
Stage 1  主审      各维度并行，主审引擎出 findings
Stage 2  闸门2     引文 grep 回原文，对不上即丢弃（零 token，唯一确定性环节）
Stage 3  交叉稽核   对侧引擎逐条裁定 + steelman + 补漏报
Stage 4  闸门3     校验裁定 id、DOWNGRADE 合法性；稽核方的漏报同样过闸门2
Stage 5  综合      按证据锚点去重、应用裁定、出报告
Stage 6  判收敛     比 CRITICAL 的证据锚点集合，最多 3 轮
```

### 三道闸门

| 闸门 | 位置 | 拦什么 |
|---|---|---|
| 1 | 维度 prompt | 强制逐字引文 + `counter_source`/`counter_quote` 成对 |
| 2 | `quote_check.py` | 引文在原文里不存在 / 过短无判别力 / 路径越出 code-root |
| 3 | `audit_gate.py` | 裁定 id 不在送审列表 / 重复裁定 / DOWNGRADE 没给合法新等级 |

闸门 2 是重点：它在调用任何模型**之前**就把幻觉条目丢掉。实测能拦住编造引文、
改写而非逐字、引文过短、以及 `../../etc/passwd` 这类路径逃逸。

### 为什么要两个引擎

同家族模型给自己的发现打分时天然偏袒。Codex（gpt-5.6-sol）是真正的不同模型家族，
不只是换个 subagent。实测 codex 稽核 claude 的数值一致性 finding 时，独立复算
`51.4 - 48.6 = 2.8` 对上摘要的 `3.2`，给出 CONFIRMED 并附算式。

`cross_audit.sh` 默认取 manifest 里主审方的**对侧**。显式传 `--auditor` 可覆盖
（例如某侧网关不稳时降级为同侧自查，会打印警告）。

## 维度

按「审的是哪个物件」分组，因为这决定了需要什么输入：

| 组 | 输入 | 维度 |
|---|---|---|
| A | 只需 `paper.md` | numeric-consistency, citation-integrity, stats-validity, reproducibility, claim-evidence, experiment-design, novelty-positioning, writing-structure |
| B | 需 `--code-root` | purpose-alignment, logic-completeness, design-soundness, implementation-completeness, data-reproducibility |
| C | 需 `--code-root` | code-paper-consistency |

B 组沿用 `~/.claude/skills/exp-review` 的五个维度与判定词。C 组（论文声明 vs 代码实际
取值）是 AI 审稿最难被替代的部分。

不给 `--code-root` 时 B/C 两组整组跳过（退出码 3，是合法结果，不是失败）。

维度登记在 `dimensions/manifest.tsv`，加维度只需写一个 `dimensions/<id>.md` 并登记一行。

## 脚本

| 脚本 | 作用 |
|---|---|
| `loop.sh` | 全流程编排 + 判收敛（**入口**） |
| `run_all.sh` | 按 manifest 并行跑全部维度 |
| `run_dimension.sh` | 跑单个维度：装配 brief -> 主审引擎 -> 闸门2 |
| `cross_audit.sh` | 对侧引擎复核 -> 闸门3 |
| `synthesize.py` | 应用裁定 + 按证据锚点去重 + 出报告 |
| `converged.py` | 比锚点集合判收敛 |
| `quote_check.py` | 闸门2 |
| `audit_gate.py` | 闸门3 |
| `claude_call.sh` / `codex_call.sh` | 两侧引擎的桥，接口对称 |

### 收敛判据

比的是 CRITICAL 的**证据锚点集合**，不是条数 —— 修掉 2 条又引入 2 条时条数不变，
但显然没收敛。

| rc | 含义 |
|---|---|
| 0 | 收敛，CRITICAL 清零 |
| 6 | 跑满轮次仍有 CRITICAL（如实报告，不强行收敛） |
| 7 | 停滞：锚点集合与上一轮完全相同，改动未生效，停止以免空烧 token |

## 依赖

- `claude`、`codex` 均已登录（`codex login` / Claude Code 已配置）
- `python3`（仅标准库）
- `pdf2md` 若要从 PDF 起步（见 `~/.claude/skills/pdf2md.md`）

## 已验证与未验证

已端到端实测：
- A 组 `numeric-consistency`、`claim-evidence` 主审全流程
- B 组 `logic-completeness` 主审（claude，双侧锚定 5 条 findings 全过闸门）
- Codex 稽核 A 组维度，闸门3 正确处理裁定
- 闸门 2/3 的全部拒绝路径（对抗 fixture：编造引文、改写、过短、路径逃逸、
  重复裁定、伪造 id、DOWNGRADE 三种非法情形）
- 去重（同一行 `config.py` 配置被 B/C 两组各报一条，正确归并）
- 收敛判据四条路径

尚未实测：
- 全部 14 维度一次跑满（单维度都通，但没做过完整 full run 的时长/成本测量）
- Codex 主审 B/C 组维度。此前失败的两个原因（schema 严格模式、日志 scraping）
  都已修复，但没有重测。若要让 codex 主审，先小范围试一个维度。

## 已知坑

- **`codex exec` 必须用 `-o` 取最后一条消息**，绝不要 scrape session 日志：codex 探索时
  会把读到的文件内容打进 transcript，「取最后一个能 parse 的 JSON」会抓到那些文件内容，
  静默用无关数据覆盖真正的答复。
- **不要用 `--output-schema`**：OpenAI 的 structured output 要求 `required` 覆盖
  `properties` 全部字段，与「A 组只要 quote、B 组只要代码锚点」的可选字段需求冲突。
  两侧统一走 prompt 注入 + 事后括号配对提取。
- **`claude -p` 的 brief 走 stdin**：`--add-dir` 是可变参数，会把位置参数当目录吞掉。
- **bash 里变量别叫 `GROUPS`**：那是内建数组（当前用户 gid），赋值被静默忽略。
- 网关偶发 502，两个桥都做了三次退避重试。
- `.claude/settings.json` 里的 gateway token 是明文，若要 `git init` 推远端先处理。
