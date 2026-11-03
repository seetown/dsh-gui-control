# 发布清单

## 0. 发布前必须改的地方

| 位置 | 改什么 | 改成 |
|---|---|---|
| `README.md` | 三处 `seetown` | 你的 GitHub 用户名 |
| `package.json` → `repository.url` / `homepage` / `bugs.url` | 三处 `seetown` | 同上（**npm 包靠它关联仓库，不能漏**） |
| `package.json` → `name` | `dsh-gui-control` 若被占用 | `@你的npm用户名/dsh-gui-control` |
| `cordis.patch.yml` → `name:` | 与 package.json 保持一致 | 同上 |

> 改了 `name` 之后，`locale/*.json` 不用动；`cordis.patch.yml` 里的 `id: gui-control` 也不用动。

## 1. 本地验证

```powershell
node --check lib/index.js
dsh plugin add C:\path\to\dsh-gui-control
```

装完在任意会话里调用一次 `gui_snapshot`，确认三个工具都出现。

## 2. 建仓库

```powershell
cd C:\path\to\dsh-gui-control
git init
git add -A
git commit -m "dsh-gui-control 0.1.0: Windows desktop control with task files and delivery verdicts"
git branch -M main
git remote add origin https://github.com/seetown/dsh-gui-control.git
git push -u origin main
```

**仓库设置**：

- Description：`Repeatable Windows desktop automation for DeepSeek Harness — task files, delivery verdicts, three perception channels.`
- **Topics（必须含 `dsh-plugin`，市场 CI 会检查）**：
  ```
  dsh  dsh-plugin  deepseek-harness  computer-use  desktop-automation
  ui-automation  accessibility  windows  gui-agent  ai-agent
  ```

## 3. 发 npm

```powershell
npm login
npm publish --access public     # scoped 包名必须带 --access public
```

发之前可以 `npm pack --dry-run` 看一眼打包内容（应该是 ~130 KB，`demo/` 不进包）。

## 4. 别人怎么装

```bash
dsh plugin add dsh-gui-control
dsh plugin add seetown/dsh-gui-control    # 或从 GitHub
```

## 5. 投递插件市场（awesome-dsh-plugin）

**硬性门槛（先看这条）：仓库必须建满 1 天**，CI 会自动检查。所以顺序是：先建仓库 → 等一天 → 再提 PR。

**提交方式**：向 https://github.com/awesome-dsh-plugin/awesome-dsh-plugin 提一个 PR，**只加一个文件**：

`data/plugins/seetown__dsh-gui-control.yml`

```yaml
url: https://github.com/seetown/dsh-gui-control
name: seetown/dsh-gui-control
category: tools
description:
  en: Windows desktop control for DeepSeek Harness: accessibility-tree snapshots, click by control name, delivery verdicts, and repeatable task files.
  zh: DeepSeek Harness 的 Windows 桌面操控：读无障碍树、按控件名点击、动作投递判定，以及可重复执行的任务文件。
icon: https://raw.githubusercontent.com/seetown/dsh-gui-control/main/assets/icon-180.png
```

注意事项（来自官方贡献指南）：

- **描述必须属实**，会被逐条对着代码核对。别写「N 个工具、M 项能力」这类数字，除非真的对得上。我们就是 3 个工具：`gui_snapshot` / `gui_act` / `gui_task`。
- **不要带营销词**（"最强""颠覆"之类），只写做什么。
- 描述里如果出现 `: `（冒号+空格），YAML 必须加引号。
- 分类：`tools`。可用值里有 `ui`/`vision`/`browser`，但我们是桌面操作能力，`tools` 最贴切；选不准维护者会直接改，不会打回。
- 仓库 `package.json` 必须有 `dsh.bundle`（✅ 已有），只声明 `dsh.client` 会被拒。
- 一个 PR 最多 3 条。

**截图**：仓库根目录已放 `screenshots.json`（3 张 PNG，在 `assets/` 下），市场详情页会自动读取，之后换图推自己仓库就行，不用再提 PR。

**图标**：`assets/icon-180.png`（180×180 PNG）。SVG 会被拒——必须是 GitHub 托管的位图。

## 6. 发布后

- README 顶部加 npm 版本徽章
- 确认 `demo/*.gif` 的绝对链接能打开
- 开 issue 模板（要求反馈带：DSH 版本、Windows 版本、哪一步失败、`delivery` 判定）
- 记 CHANGELOG

## 已知限制（写进 README，别藏着）

- 仅 Windows（Win32 + UI Automation）
- 需要 PowerShell 5.1
- 画布类应用（WPS 表格、游戏）没有无障碍树，只能截图 + OCR，准确率下降
- 网页任务目前基于截图，CDP 通道已实现但还没接进工具
