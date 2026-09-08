# Issue Tracker

此仓库的 issues 和 PRD 以 Markdown 文件形式存放在 `.scratch/`。

## 约定

- 每个功能一个目录：`.scratch/<feature-slug>/`
- PRD：`.scratch/<feature-slug>/PRD.md`
- Issues：`.scratch/<feature-slug>/issues/<NN>-<slug>.md`
- Issue 从 `01` 开始编号
- Triage 状态记录在文件顶部的 `Status:` 行
- 评论和对话历史追加到 `## 评论`

## 发布与读取

当 skill 要求发布 issue 时，在对应 `.scratch/<feature-slug>/` 下创建文件。

当 skill 要求获取工单时，读取用户提供的路径或编号；不发布到外部系统。

## Wayfinding

- 地图：`.scratch/<effort-slug>/MAP.md`
- 子任务：`.scratch/<effort-slug>/issues/<NN>-<slug>.md`
- 认领：使用 `Assignee:` 行
- 依赖：使用 `Blocked-by:` 行
- 完成：将 `Status:` 设为 `resolved`，并把结论写入 `## Resolution`
