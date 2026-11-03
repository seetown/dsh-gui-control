# dsh-gui-control

**给 DeepSeek Harness 的 Windows 桌面操控：不是"帮我点一下这个按钮"，而是"以后这个活都交给你"。**

大多数桌面 Agent 解决的是「一次性操作」——看一眼、点一下、再看一眼。这个插件多做一层：**把一套动作固化成任务文件**，跑的时候模型完全不参与，带条件校验、失败分类、以及"这一次到底有没有真的发出去"的判定。

<!-- TODO: 15 秒 GIF：左边敲一句话，右边 WPS 表格被填好 -->

## 演示

**打开 B 站 → 搜索番剧 → 播到指定集数**（模型自己找搜索框、点卡片、跳剧集）

![B 站选集](https://raw.githubusercontent.com/seetown/dsh-gui-control/main/demo/4-bilibili.gif)

**语义点击：鼠标位移 0 像素**（直接调用控件的 Invoke，鼠标不动、窗口在后台也能点）

![语义点击](https://raw.githubusercontent.com/seetown/dsh-gui-control/main/demo/3-calc.gif)

**填一列数据**（17 步 / 0.9 秒 / 一次调用，执行期间模型完全不参与）

![填表](https://raw.githubusercontent.com/seetown/dsh-gui-control/main/demo/2-sheet.gif)

> 把 `seetown` 换成你的 GitHub 用户名，图才会显示。

## 三个工具

| 工具 | 作用 |
|---|---|
| `gui_snapshot` | 读窗口的无障碍树（文本，精确、便宜、与位置无关），或带屏幕坐标刻度尺的截图 |
| `gui_act` | 做一个动作，带**身份校验**和**投递判定** |
| `gui_task` | 跑一个声明式任务文件：一步调用完成多步，带条件等待、重试、风险闸门 |

## 为什么不是又一个 pyautogui 封装

### 1. 投递语义：知道"有没有真的发出去"

每个动作返回三选一的判定：

| 判定 | 含义 | 能不能重试 |
|---|---|---|
| `not_delivered` | 什么都没发出去（派发前就被拒） | ✅ 安全重试 |
| `delivered_unverified` | 发出去了，但效果没确认 | ❌ **绝对不能盲目重放** |
| `delivered_verified` | 发出去了，且后置条件验证通过 | ❌ |

这条区分决定了「发送消息 / 删除文件 / 提交表单」这类不可逆操作是否安全。实测：控件不存在时判 `not_delivered/retry=safe`；点了但校验超时判 `delivered_unverified/retry=unsafe`。

### 2. 元素身份，而不是坐标或序号

`uia-pick` 支持 `expect`（名字）和 `expectId`（AutomationId）。页面重排后序号漂移，它会**在派发前拒绝**并回报实际值：

```
identity mismatch at index 0: expected id "NoSuchAutomationId", found "CloseButton"
```

### 3. 三通道并存，不赌单一来源

- **UIA**：能读树的窗口，语义点击，鼠标不动、不抢焦点
- **OCR**：文字密集但无树的界面（本地 Windows.Media.Ocr，不外传图片）
- **坐标 + 刻度尺截图**：画布、游戏、自绘列表

WPS 表格这类「有窗口但没有单元格节点」的应用，只有后两条路能走。

## 安装

```bash
# 从本地目录（开发时）
dsh plugin add /absolute/path/to/dsh-gui-control

# 从 npm
dsh plugin add dsh-gui-control
```

装完**无需重启**：三个工具会在当前会话直接出现。

要求：Windows 10 1809+，PowerShell 5.1（系统自带），DeepSeek Harness 0.1.5-rc.2 ~ 0.2.x。

## 用法

```
gui_snapshot { window: "Notepad", mode: "tree" }
→ MenuI 文件
  Butto 关闭标签页
  Docum 文本编辑器
  ...

gui_act { action: "click_text", window: "Notepad", text: "最大化" }
→ click ok via InvokePattern | verified: text appeared

gui_task { file: "C:\\tasks\\fill-sheet.json", dryRun: true }
→ task fill-sheet ok in 0 ms
   1. ok   click         412 ms  not_delivered
   2. ok   type          380 ms  delivered_unverified
```

### 任务文件

```json
{
  "name": "fill-sheet",
  "steps": [
    { "do": "activate", "win": "工作簿1" },
    { "do": "click", "x": 129, "y": 449 },
    { "do": "type", "text": "项目" },
    { "do": "key", "key": "tab" },
    { "do": "type", "text": "金额" },
    { "do": "key", "key": "enter",
      "until": { "op": "pathexists", "text": "C:\\out\\report.xlsx" }, "untilTimeout": 10 }
  ]
}
```

步骤字段：`do` + 该动作的参数，外加 `until`（轮询到条件成立才算过）、`untilTimeout`、`retry`、`risk`。

`risk: "high"` 的步骤默认**拒绝执行**，必须显式 `confirm: true`；`dryRun: true` 只看计划不碰桌面。

## 性能实测

| 操作 | 耗时 |
|---|---|
| 动作（单步，守护进程） | 10.8 ms |
| UIA 点击（语义） | 26–34 ms |
| 紧凑树读取（`uia-mini`） | 86 ms，865 字符（比完整 dump 省 88%） |
| 7 步任务（含启动计算器） | 680 ms，一次调用 |
| 桌面建 3 个文件夹 | 3.45 s，3 次全部成功 |

守护进程常驻，首次调用预热约 1 秒；之后每个动作是一次 loopback TCP 往返。

## 安全

- 只监听 `127.0.0.1:38471`，不对外暴露
- 密码字段读取一律输出 `<redacted>`
- 高风险步骤需要显式确认
- 失败区分「没发出去」和「可能发出去了」，后者绝不自动重放

**注意**：这个插件能操控整台机器的鼠标键盘。装之前请知情，只在可信环境使用。

## 已知限制

- **仅 Windows**（Win32 + UI Automation）
- 需要 PowerShell 5.1；没有它在 PATH 上的发行版会失败
- 部分应用不暴露无障碍树（游戏、画布、未开无障碍的 Electron），此时只能走截图 + OCR，速度和准确率都会下降
- 坐标是物理像素，前提是进程声明了 per-monitor DPI 感知（已内置）

## Roadmap

- [ ] 截图自动编号（Set-of-Marks），把坐标估计降级成编号分类
- [ ] 任务库与意图路由：一句话命中现成任务
- [ ] macOS / Linux 适配（目前是 Win32 专用）

## License

MIT

---

# English

**Windows desktop control for DeepSeek Harness.** Not "click that button for me" — "this job is yours from now on."

Most desktop agents do one-off operations: look, click, look again. This plugin adds a layer underneath: **turn a sequence into a task file** that runs with no model in the loop, with conditions, failure classification, and a verdict on whether the input actually reached the application.

## Three tools

| Tool | Purpose |
|---|---|
| `gui_snapshot` | Read a window's accessibility tree as text, or a screenshot with a screen-coordinate ruler |
| `gui_act` | One action, with an identity check and a delivery verdict |
| `gui_task` | Run a declarative task file: many steps in one call, with conditions, retries and a risk gate |

## Delivery semantics

| Verdict | Meaning | Retry |
|---|---|---|
| `not_delivered` | Nothing was sent | ✅ safe |
| `delivered_unverified` | Input may have landed, effect unconfirmed | ❌ never blind-retry |
| `delivered_verified` | Landed and the post-condition held | ❌ |

That distinction is what makes "send a message / delete a file / submit a form" safe to automate.

## Install

```bash
dsh plugin add dsh-gui-control
```

Windows 10 1809+, PowerShell 5.1, DeepSeek Harness 0.1.5-rc.2 – 0.2.x. Tools appear immediately, no restart.

MIT.
