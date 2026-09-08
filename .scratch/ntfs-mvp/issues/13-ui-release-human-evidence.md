# 取得 C 版 UI 与本地候选包人工证据

Status: ready-for-human
Labels: enhancement, ready-for-human
Assignee:
Blocked-by: 12-gate4-formal-mutation-integration

## 验收

- 记录被测 App 构建、主程序/Info.plist SHA-256、macOS 构建、显示设置和 Evidence-ID。
- 320 pt 无横向滚动；长卷名、多分区和所有危险/处理中状态仍能用文字理解。
- 浅色、深色、高对比和减少动态效果逐项人工复核。
- Tab、Return、Space、焦点回退和 VoiceOver 阅读/操作顺序符合 UI 指南。
- Setup 阶段、刷新、选择变化、复制诊断和清除结果均能由辅助功能可靠读出。
- 正式 Gate 4 集成后复核写入/推出状态，确认危险状态不暴露旧目标或错误主操作。
- 证据明确区分 ad-hoc 本地包与 Gate 5 Developer ID/公证候选，不能互相替代。

## 评论

编译、预览、静态 accessibility 标注和 Agent 截图不能关闭本 Issue；需要人在真实 macOS UI 中验收。

2026-08-31 的 Agent smoke 已重新构建、验证并启动本地只读 App，进程稳定存活；但当前
Computer Use 连接器对该应用连续三次在返回辅助功能树前报 `native pipe closed`，同时 Finder
的辅助功能读取正常。这次尝试不计作窗口、键盘或 VoiceOver 通过证据，也不改变
`ready-for-human` 状态。

同日进一步用系统窗口列表确认 PID 对应一个可见、alpha=1 的 layer-0 主窗口，标题为
“NTFS 轻量助手”、尺寸为 820×652；按该窗口 ID 定向截图成功，C 版概览、只读边界说明、
侧栏和重新读取入口均完整可见。这只能记为视觉 smoke，临时截图不是 Gate Evidence，也不能
证明 320 pt、键盘焦点或 VoiceOver 顺序。

对失败连接器的本机 crash report 检查显示，崩溃进程是 `SkyComputerUseService`，信号为
`SIGTRAP`，栈位于其辅助功能通知处理中的数组收敛逻辑；目标 App 没有对应崩溃报告，采样时
主线程仍在 AppKit 事件循环。当前 shell 未获辅助功能信任，且本机没有 Xcode Accessibility
Inspector，因此没有第二条可独立读取 AX 树的自动化路径。该证据只把问题收敛为“连接器自身
崩溃或与合法 AX 结构存在兼容问题”，不能推导应用的辅助功能已合格；人工验收继续保留。

同日再次分别按完整 App 路径和 bundle ID 读取 UI，均在取得辅助功能树前超时；进程列表仍能
识别运行中的“NTFS 轻量助手”。这仍不是人工 UI 或 VoiceOver 证据。自动审计另外发现同盘同名
卷的展示与公告变化键缺口，已由 Issue 25 用 RED/GREEN 行为检查修复：多卷物理盘的每个
sibling 取得唯一、隐私安全的前缀序号，公告事件绑定完整选择身份；用户卷名与生成标题的碰撞
反例也已固定。它只补齐人工验收前的软件前置条件，不改变本 Issue 状态。

同日后续自动检查又固定了跨物理盘同名卷的选择控件标签：宽版侧栏与窄版 Picker 都从展示层
取得“物理磁盘 N，卷标题”，不依赖 VoiceOver 是否重复朗读分组标题，也不加入原始身份。该项由
已解决的 Issue 26 固定；仍须人工确认真实 VoiceOver 分组、焦点与阅读顺序。

同日 Issue 27 又把 retained/presented selection、失效卷焦点回落以及 wide/compact 导航焦点
转移固定为纯展示层契约，并覆盖 epoch/dashboard 两种回调顺序与复用相同卷 ID 的反例。独立
静态复核未发现 blocker，但 SwiftUI 条件分支拆装时 FocusState 的真实提交顺序只能在运行中的
macOS 窗口内验证；Tab、Shift-Tab、Return、Space、焦点环和 VoiceOver 光标仍全部留在本 Issue。
