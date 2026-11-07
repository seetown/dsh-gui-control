# 发布材料（LAUNCH.md）

> 目标：把「已收录」变成「有人看见」。
> 用法：复制对应段落，替换方括号里的内容，直接发。

---

## 一、定位句（所有渠道通用）

**一句话（中文）**
> 别的桌面 Agent 是「看一眼、点一下、再看一眼」；这个是「一段活，交给它跑完，而且知道每一步有没有真的发出去」。

**One-liner (EN)**
> Most desktop agents do one-off operations. This one turns a sequence into a task file that runs with no model in the loop — and reports whether each action actually landed.

**三行版本（适合 HN / Reddit 开头）**
> - Perception: accessibility tree first, screenshots only when there is no tree.
> - Execution: a task file runs 17 steps in one call, no model in the loop.
> - Safety: every action reports `not_delivered` / `delivered_unverified` / `delivered_verified`, so irreversible steps are never blindly retried.

---

## 二、渠道清单

| # | 渠道 | 语言 | 优先级 | 备注 |
|---|---|---|---|---|
| 1 | Hacker News (Show HN) | EN | ★★★ | 工作日 21:00–23:00 北京时间发布 |
| 2 | Reddit `r/LocalLLaMA` | EN | ★★★ | 技术受众最匹配 |
| 3 | Reddit `r/sideproject` | EN | ★★ | 接受自推 |
| 4 | V2EX `/go/create` 或 `/go/share` | 中 | ★★★ | 技术中文社区，反馈质量高 |
| 5 | 即刻 | 中 | ★★ | 短文案 + GIF |
| 6 | 掘金 / 知乎 | 中 | ★★ | 需要写成文章，不是链接贴 |
| 7 | X / Twitter | EN | ★★ | 配 GIF，带 #dsh #automation |

**节奏**：一天发 1–2 个渠道，不要同一小时全发（会被当 spam）。

---

## 三、Show HN 草稿

**Title**
```
Show HN: Desktop automation where every action reports if it actually landed
```

**Body**
```
I built a DeepSeek Harness plugin for Windows desktop control. The part I think is
interesting isn't the clicking — it's knowing whether the click happened.

Most automation layers report ok/fail. That's the wrong axis when the action is
irreversible. If "send message" fails, did it fail before dispatch, or after? One
of those is safe to retry; the other duplicates the message.

So every action returns one of three verdicts:
  not_delivered        - nothing was sent, safe to retry
  delivered_unverified - input may have landed, do NOT replay
  delivered_verified   - landed, and the post-condition held

The second one is the one nobody models, and it's the one that matters for
"delete this file" / "submit this form".

Two other decisions:
1. Accessibility tree first. Clicking by control name means the mouse never moves
   and the window can be in the background. Screenshots are the fallback, not the
   default.
2. Task files. A list of steps (with conditions, retries, and a risk gate) runs
   inside a resident process. 17 steps in one call; the model isn't in the loop.

Windows only (Win32 + UI Automation). MIT. npm: dsh-gui-control

Repo: https://github.com/seetown/dsh-gui-control
Market listing: https://awesome-dsh-plugin.com/p/seetown/dsh-gui-control/

Happy to answer questions about the delivery-verdict model or the Windows input
injection edge cases (UIPI, SendInput lying about success, etc.).
```

**第一条评论（自己补，说明取舍）**
```
A few things it does NOT do, to save people time:
- Not cross-platform. Win32 + UI Automation only.
- Canvas apps (spreadsheets, games) expose no tree, so it falls back to
  screenshot + OCR, and accuracy drops. I say so in the README.
- Web tasks currently use screenshots; the CDP path exists but isn't wired in.
```

---

## 四、Reddit 草稿（r/LocalLLaMA）

**Title**
```
Desktop agent that reports whether the action actually landed (not just ok/fail)
```

**Body**
```
I kept hitting the same failure mode with desktop agents: the step "failed", but I
couldn't tell whether it failed before sending input or after. For a click that
doesn't matter. For "send the message" it's the difference between a retry and a
duplicate.

So the plugin I built returns a delivery verdict alongside every action, and a task
runner that checks post-conditions:

    { "do": "key", "key": "enter",
      "until": { "op": "pathexists", "text": "C:\\out\\report.xlsx" } }

If the file never appears, it reports delivered_unverified and refuses to replay.

Also: it reads the accessibility tree instead of screenshots whenever possible, so
clicking a button doesn't move the mouse at all.

Windows only, MIT, npm: `dsh-gui-control`.
Repo + demo GIFs: https://github.com/seetown/dsh-gui-control

The README lists what it can't do too — I'd rather people know the boundary before
installing something that drives their mouse.
```

---

## 五、V2EX 草稿

**标题**
```
[分享] 给 DSH 写了个 Windows 桌面操控插件，重点不是点得快，是知道有没有点上
```

**正文**
```
做这个东西的起因很朴素：让 Agent 帮我点个按钮，失败了，我不知道它是"没点上"
还是"点上了但后面一步错了"。前者可以重试，后者重试就是重复操作。

所以每个动作都会带一个投递判定：

  not_delivered        什么都没发出去，可以放心重试
  delivered_unverified 可能已经发出去了，绝不能重放
  delivered_verified   发出去了，而且后置条件验证通过

第二种是大多数自动化层没有建模的，也是"删文件""提交表单"这类操作唯一关心的。

另外两个取舍：
1. 优先读无障碍树，按控件名点击——鼠标不动，窗口在后台也能点。截图只是兜底。
2. 任务文件：一串步骤（带条件、重试、风险闸门）在常驻进程里跑完，17 步一次调用，
   执行时模型完全不参与。

仅 Windows（Win32 + UI Automation），MIT。
npm: dsh-gui-control
仓库：https://github.com/seetown/dsh-gui-control
市场：https://awesome-dsh-plugin.com/p/seetown/dsh-gui-control/

README 里写了它做不到什么（画布类应用没有无障碍树、网页还没接 CDP），
装之前可以先看一眼边界。
```

---

## 六、预判提问 & 答（所有渠道通用）

| 会被问 | 怎么答 |
|---|---|
| 和 pyautogui 有什么区别？ | pyautogui 只发按键；这里先定位控件（UIA），再发语义动作，而且会告诉你动作有没有落地。 |
| 支持 Mac / Linux 吗？ | 不支持，Win32 + UIA 专用。跨平台是 Roadmap，不是现在。 |
| 安全吗？会不会乱点？ | 只监听 127.0.0.1；密码字段脱敏；高风险步骤默认拒绝执行，要显式 confirm；结果不明绝不自动重试。 |
| 为什么不用视觉大模型？ | 成本。一次全屏截图约 2k token；无障碍树过滤后约 850 字符。能读树就不该看图。 |
| 和 dsh-pilot 比呢？ | 它是视觉优先、单次批量；我们是树优先、任务可复用。画布类它更好，重复流程我们更稳。 |
| 为什么只有 3 个工具？ | 工具越多模型越容易选错。读、做、跑任务，三件事够了。 |

---

## 七、素材对照

| 渠道 | 用哪张图 |
|---|---|
| HN / Reddit | `demo/0-hero.gif`（一句话 → 结果） |
| V2EX / 即刻 | `demo/0-hero.gif` + `demo/3-calc.gif`（鼠标 0 位移） |
| 掘金 / 知乎 | 全部三张 + 实测数据表截图 |

---

## 八、发布后

- 每条评论都回，尤其批评（公开回复比私信有效得多）
- 被质疑的点，如果成立就改代码并在 PR/issue 里引用——这是最好的内容
- 一周后复盘：哪个渠道带来最多 star，下个版本往那个方向做
