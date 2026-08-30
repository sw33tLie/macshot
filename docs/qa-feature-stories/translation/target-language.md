# QA 功能说明: 截图翻译目标语言

## 功能标识

- 功能域: `translation`
- 功能点: `target-language`
- 最近更新: `codex/translation-target-language-pr`

## 背景

截图 OCR 和原位翻译需要一个明确的目标语言。用户希望默认使用 macOS 系统语言，同时可在设置页固定选择某种目标语言。

## 当前确认行为

- 翻译调用通过 `TranslationService.translateBatch(texts:targetLang:completion:)` 进入 Google Translate 或 Apple Translation。
- OCR 结果窗口和截图原位翻译都会传入目标语言代码。
- 偏好使用 `UserDefaults` 键 `translateTargetLang` 保存。

## 本次变更

- 设置的 Capture → Translation 区域新增 `Target language:` popup。
- popup 第一项是 `Follow System`；选择它会删除显式偏好。
- 选择任一具体语言会保存对应语言代码，之后翻译使用该固定目标。
- 未保存显式偏好时，系统读取第一项 macOS 首选语言。
- `zh-Hans`、`zh-SG` 与 `zh` 解析为 `zh-CN`；`zh-Hant`、`zh-TW`、`zh-HK`、`zh-MO` 解析为 `zh-TW`。
- 不在支持列表中的系统语言会回退到 `en`。
- 设置窗口重开时会刷新 popup，反映 OCR 或截图翻译控件后来保存的显式语言。

## 触发入口

- 设置入口：Capture tab 的 Translation 区域。
- 翻译入口：OCR 结果窗口的翻译操作、截图原位翻译，以及 `macshot://ocr-translate`。
- 系统条件：macOS 15+ 可显示 Apple Translation Engine 与语言包入口；所有支持的 macOS 版本均可选择目标语言并使用 Google Provider。

## 主流程

1. 用户打开设置，在 Target language 中选择 `Follow System` 或具体语言。
2. 选择具体语言时，应用将语言代码写入 `translateTargetLang`；选择 Follow System 时删除该键。
3. 发起 OCR 或原位翻译时，应用先读取有效显式偏好；没有时解析 macOS 首选语言。
4. 应用将解析得到的语言代码传给当前翻译 Provider，并显示对应译文。

## 分支与异常流程

- macOS 首选语言为空或不被支持：使用英语 `en`。
- 已保存的语言代码不在支持列表：忽略该值，按系统语言解析；读取时不删除旧值。
- Apple Translation 不可用或当前语言包不可用：用户仍可选择目标语言，应用按现有 Provider 逻辑使用 Google Translate 或显示既有错误。
- OCR 未识别到文本或 Provider 请求失败：沿用既有错误提示，不创建翻译覆盖层。

## 数据与接口影响

- 本地数据：继续使用 `UserDefaults.translateTargetLang`；没有新增数据库、迁移或服务器配置。
- 外部服务：Google Translate 的 `tl` 参数和 Apple Translation 的 target locale 接收解析后的目标语言代码。
- 兼容性：原先已保存且在支持列表中的语言代码继续有效。

## 前端/App 细节

- 页面/组件：`SettingsWindowController.makeCaptureTabView()`、`OCRResultController`、`OverlayView`。
- 用户可见状态：具体语言被选中时显示该语言；无有效显式偏好时显示 `Follow System`。
- 本地状态：`translationTargetLanguagePopup` 在 `loadSettings()` 时刷新。
- 权限：本次未改变 Screen Recording、网络或文件权限。

## 测试关注点

- 首选语言为 `zh-Hans`、`zh-Hant`、`zh-HK`、`zh-SG`、`pt-BR`、不支持语言时的解析结果。
- 固定语言、切回 Follow System、无效旧偏好三种 `UserDefaults` 状态。
- macOS 12–14：目标语言 popup 可见，Apple Engine 控件不可见。
- macOS 15+：目标语言 popup、Apple Engine 和语言包入口均可见。
- OCR 窗口或原位翻译修改语言后，再打开设置页时 selection 与显式偏好一致。
