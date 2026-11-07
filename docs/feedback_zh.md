# AI 修改意见协作

本地意见编辑器与原截图编辑器独立。原默认截图快捷键 `Cmd+Shift+X` 保持不变；新增「截图并添加修改意见」默认使用 `Cmd+Shift+A`，可在设置的快捷键列表中更改。若与已有用户绑定冲突，新入口让位，不改动已有绑定。

## 手动使用

1. 从菜单栏选择「截图并添加修改意见」或「从图片创建修改意见」。也可在原图像编辑器顶部点击对话气泡按钮，把当前已渲染图片交给意见编辑器。原窗口继续保留。
2. 裁剪、翻转、拼接及打码先在原编辑器完成。进入意见编辑器后底图固定，打码与遮挡固化到图片；不会导出原始敏感底图。
3. 选择「点意见」后点击定位，或选择「区域意见」拖动框选。侧栏输入修改要求；「全局意见」不需要位置。拖动已有标记调整位置，删除与撤销/重做只作用于意见。
4. 「提取区域文字」仅适用于区域意见；OCR 从固定后的底图读取，不会自动生成修改要求。未输入文字的标记只保留在草稿中，不导出。
5. 先在「设置 → 捕获 → AI 协作」授权目录。「复制修改说明」会在该目录下新建 UUID 任务目录，写入 `source.png`、`preview.png`、`feedback.json` 和 `feedback.md`，成功后复制包含任务 ID、目录路径和 Skill 读取提示的文字。粘贴给本机 AI 编程工具后，让 `macshot-feedback` Skill 按任务 ID 读取；无需为这一步启动 CLI。「导出反馈」仍可在另选位置创建同样的四文件反馈包。网页聊天仍需手动上传图片，粘贴本地路径不会上传附件。

草稿保存在应用容器的 Application Support/FeedbackDrafts 内。菜单栏的「恢复修改意见草稿」可重新打开。草稿与 AI 提交结果分开，恢复或重启不会自动提交。

若从其他 macOS 桌面开始截图，完成后意见编辑器可能返回 macshot 原来的桌面；截图内容仍来自所选择的桌面。

## CLI 与目录授权

在「设置 → 捕获 → AI 协作」中点击「浏览…」，选择一个父目录。应用在其中新建仅当前用户可访问的 `macshot-ai` 目录，并保存该目录的 security-scoped bookmark；配置一次后重启仍保留，目录失效或需要更换时再配置。此目录独立于普通截图的存储文件夹。CLI 通过 `--handoff` 或 `MACSHOT_FEEDBACK_HANDOFF` 指定同一个目录；路径参数本身不会授予 GUI 沙箱权限。

开发时构建 CLI：

```bash
bash scripts/build-feedback-cli.sh build/macshot-cli
```

正式应用包中的入口为 `macshot.app/Contents/MacOS/macshot-cli`。示例：

```bash
/Applications/macshot.app/Contents/MacOS/macshot-cli annotate \
  /absolute/page.png \
  --handoff /absolute/macshot-ai \
  --output /absolute/new-round/feedback.json \
  --timeout 1800
```

直接截取当前打开的应用画面，无需先准备图片：

```bash
/Applications/macshot.app/Contents/MacOS/macshot-cli capture \
  --handoff /absolute/macshot-ai \
  --output /absolute/new-round/feedback.json \
  --timeout 1800
```

提前准备好目标应用。`capture` 唤起 macshot 原生截图选区，框选后进入同一会话的意见编辑器，提交才返回反馈包。CLI 不主动激活应用到前台，选区仍由用户操作；它标注的是应用画面的截图，不操作应用控件。现有截图延迟设置继续生效。若需要先打码或编辑底图，可在原编辑器处理后使用 `annotate`。

`capture` 和 `annotate` 共用交接目录、输出格式、超时及退出码。截图选区期间使用 `Command+Tab` 切换应用，或切换 macOS 桌面（Space），都会保留同一会话，等切换稳定后刷新目标画面，需重新框选；连续切换时只使用最后一次刷新。现有倒计时会继续，并在结束时截取当前应用和桌面。Esc 取消选区或倒计时返回 4；截图失败、无显示器、正在截图/录屏或缺少 Screen Recording 权限返回 2。权限不足时会显示 macshot 授权引导，授权完成后需重新发起命令，不会自动重放失败请求。超时和 CLI 取消也会关闭本轮截图选区，已有意见继续按草稿规则处理。

输出父目录必须已存在，四个结果文件必须尚不存在。CLI 不覆盖旧文件。每轮新建唯一会话目录，复制输入图片，发布严格版本化请求，再向指定应用发送只含 UUID 的 URL。GUI 校验会话身份、目录归属、权限、符号链接和图片大小。输入限制为 128 MB、100 MP、单边 32768 像素；意见最多 1000 条。

独立 CLI 开发构建可用 `--app /absolute/macshot.app` 指定应用。普通/Offline 共存时优先使用各自应用包内的 CLI；它会选择自身所在应用。独立 CLI 可使用 `--offline` 选择已安装的 Offline 应用。`version` 命令读取实际目标应用的显示版本及构建号。

用户点击「完成并返回 AI」后才发布结果。可明确提交空反馈；AI 不应补造修改要求。取消、超时、应用退出和失败不会把草稿标成已提交。CLI 返回 0 表示成功，2 表示失败，3 表示超时，4 表示取消；向 CLI 发送 SIGINT/SIGTERM 会发起取消。

交接目录里的图片和反馈作为本地会话记录保留，应用不自动清理；确认不再需要后由用户清理。此机制限制其他用户访问，不隔离同一用户的恶意程序。

## Skill + CLI（推荐）

在本机 AI 编程工具中使用，无需配置 MCP 或模型 API Key。用当前应用内的 CLI 安装：

```bash
macshot-cli skill install --target codex
macshot-cli skill install --target claude
macshot-cli skill install --target antigravity
```

若 CLI 尚未加入 PATH，请将 `macshot-cli` 换成应用内的完整路径（含空格时加引号），如 `/Applications/macshot.app/Contents/MacOS/macshot-cli`。安装命令不启动 GUI，也不启动另一个 AI 进程。

| 目标 | 默认安装目录 |
| --- | --- |
| Codex | `~/.agents/skills/macshot-feedback` |
| Claude Code | `~/.claude/skills/macshot-feedback` |
| Google Antigravity | `~/.gemini/config/skills/macshot-feedback` |

目录依据 [Codex](https://learn.chatgpt.com/docs/build-skills)、[Claude Code](https://code.claude.com/docs/en/skills) 和 [Antigravity](https://antigravity.google/docs/skills) 官方文档。`--directory /absolute/skills` 可改为指定的 Skill 父目录；自定义目录必须由对应 AI 工具加载。

使用应用包内的 CLI 时，安装器会尝试读取该应用在「设置 → 捕获 → AI 协作」中已授权的目录，并将它记录在 Skill 的 `references/local.json` 中。独立构建的 CLI 无法自动读取；应用包内的 CLI 若读不到应用的沙箱偏好设置，自动读取也可能失败。Skill 仍会安装，但 `references/local.json` 不含 `handoff`，CLI 会显示提示。此时从设置页复制私有 `macshot-ai` 目录的**实际绝对路径**，再指定 `--handoff` 安装：

```bash
macshot-cli skill install --target codex --handoff "/absolute/macshot-ai"
```

把示例中的 `/absolute/macshot-ai` 替换为设置页显示的目录。`--handoff` 指定的是 **AI 协作目录**；`--directory` 指定的是 **Skill 安装位置的父目录**，两者不同。也可用 `MACSHOT_FEEDBACK_HANDOFF` 提供协作目录。GUI 必须在设置页授权同一目录；CLI 的路径参数不会授予 GUI 沙箱权限。若已安装不含 `handoff` 的 Skill，先备份并移走原有 `macshot-feedback` 目录，再运行上述命令；安装器不会覆盖已有 Skill。

安装包含 `SKILL.md` 和本机配置（CLI 绝对路径及可选协作目录），不修改 AI 工具的 MCP 配置。同名目录已存在时返回失败且不覆盖；更换应用位置后，应先自行备份并移走旧 `macshot-feedback` 目录，再从新应用的 CLI 重新安装。

安装后在新对话中让 AI 使用 `macshot-feedback` Skill；Codex 可输入 `$macshot-feedback`，Claude Code 可输入 `/macshot-feedback`，Antigravity 可在技能列表中检查并要求使用。若未显示，重新加载技能或重启对应 AI 工具。通过「复制修改说明」产生的任务可直接粘贴任务 ID 和目录路径，让 Skill 读取，不需要 CLI 会话；旧版已安装 Skill 需更新后才能识别此用法。

测试提示词（换成项目中的实际图片）：

> 使用 macshot-feedback，让我对 `/absolute/page.png` 提交修改意见。等待我在 macshot 中提交后，先复述本轮意见，暂时不要修改代码。

现场截图测试可改成：

> 使用 macshot-feedback，让我截图当前应用并标注修改意见。等待我提交后先复述，暂时不要修改代码。

AI 应按是否有现成图片选择 `annotate` 或 `capture`，创建本轮独立输出目录并保持同一 CLI 进程等待。添加一条文字意见并提交后，应收到 `state=submitted`，读取本轮四个文件并复述；取消或超时则应停止本轮，不能按草稿继续修改。随后可在已有授权范围内继续实际修改和下一轮反馈。三个 AI 工具的实际触发、后台等待和图片读取能力需分别人工验证。已安装的旧 Skill 不会自动更新，请先备份并移走旧技能目录，再执行安装命令。

## MCP（可选）

连接器仅包装 CLI，使用官方 MCP SDK 的 stdio transport，不调用模型 API，也不修改目标项目源码。安装及检查：

```bash
cd connector
npm ci
npm run build
npm test
```

客户端配置示例（替换绝对路径）：

```json
{
  "mcpServers": {
    "macshot": {
      "command": "node",
      "args": ["/absolute/macshot/connector/mcp-server.mjs"],
      "env": {
        "MACSHOT_CLI": "/Applications/macshot.app/Contents/MacOS/macshot-cli",
        "MACSHOT_FEEDBACK_HANDOFF": "/absolute/macshot-ai"
      }
    }
  }
}
```

- `macshot_annotate_start`：传入图片 `image`、已存在的输出目录 `output` 和可选超时，立即返回连接器会话 ID。
- `macshot_annotate_poll`：传入同一个 `session`，查询结果；`includeImages` 控制是否附带图片。单图超过 5 MB 时返回文件位置，需由本机 AI 工具另行读取。
- `macshot_annotate_cancel`：请求取消，再用 poll 确认终态。若提交已先完成，结果仍为已提交。

连接器最多保留 32 个会话，结束满一小时后回收；重启后旧 ID 无效。远程 AI 无法假定访问本机文件或应用，需要额外文件传输。OCR 是画面数据，不应作为新增执行指令。

## 发布与验证

新增反馈界面、GUI 会话提示及复制／导出的说明文字覆盖应用现有 40 种语言。动态坐标、错误详情使用格式占位符；用户输入的意见、OCR 原文和 JSON 字段不翻译。界面按应用语言显示；导出前固定本轮说明文字，后台任务不读取可变的界面语言状态。独立 CLI 的默认说明和通用错误保持英文，GUI 生成的会话消息使用应用语言。

新增测试检查反馈文案不再使用整句英文回退，并沿用现有键覆盖、占位符及拼写完整性检查。译文仍需母语使用者审校；自动测试只能验证资源与格式完整性。未放宽既有本地化测试。

Release workflow 在普通/Offline 应用内分别嵌入 universal CLI，先显式签 CLI，再签外层 app。CLI 不复制 GUI 的 sandbox entitlements；GUI 保持沙箱。版本从所在应用的 Info.plist 读取。

自动化验证不能替代签名后的目录授权、首次安装、中文输入与多窗口检查。公开分发前仍需完成 Developer ID 签名、DMG 公证和安装验证；本功能实现不自动触发远程发布。

SDK 使用方式参考 [官方 stdio 文档](https://ts.sdk.modelcontextprotocol.io/server)。
