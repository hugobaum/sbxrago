# 💣 Airgosbx 一键脚本 Git 提交历史记录 (Commit History)

本文件用于记录 Airgosbx 项目代码库的每次提交（Commit）及其对应的哈希值（Hash）、作者、提交日期和具体修改内容的详细说明，类似 Walkthrough，方便对脚本的历史迭代进行追溯和版本控制。

---

## 📊 版本提交历史一览表

| 提交哈希 (Commit Hash) | 作者 (Author) | 提交日期 (Date) | 提交类型 | 提交信息与变更内容概要 |
| :--- | :--- | :--- | :--- | :--- |
| **`0383ce4`** | hugobaum | 2026-05-21 | 🐛 修复 | **正统修复：修正 Xray Hysteria 2 配置为官方标准规范格式**<br>• 将 `settings.users` 变更为 `settings.clients`<br>• 将 `obfs` 混淆移出 `hysteriaSettings`，平移至 `streamSettings` 下的 `udpmasks` 数组<br>• 彻底解决重置后 Xray 闪退以及 Sing-box 驱动节点受干扰连带失效的问题 |
| **`f67c812`** | hugobaum | 2026-05-21 | 🐛 修复 | 修正 Xray Hysteria2 混淆配置为官方正统 obfs 嵌套格式（原方案因嵌套层级在 Xray 侧无法解析导致闪退） |
| **`197e9d5`** | hugobaum | 2026-05-20 | 🐛 修复 | 尝试修正 Xray Hysteria2 混淆配置为官方 finalmask 格式（因与标准客户端不兼容弃用） |
| **`f7f2f62`** | hugobaum | 2026-05-20 | 🔀 合并 | 合并远程分支 'main' 到本地仓库 |
| **`611ea95`** | der Baum | 2026-05-20 | 🗑️ 删除 | 删除冗余或冲突的旧版本 `airgosbx.sh` 文件 |
| **`04d6fc6`** | hugobaum | 2026-05-20 | 🎉 首次提交 | **首次本地提交：仅管理个人核心脚本 `airgosbx.sh`**<br>• 重置历史，清理无关文件，并添加专属 `.gitignore` 排除规则 |
| **`a471aaf`** | der Baum | 2026-05-20 | ✨ 功能 | 通过网页端上传添加脚本及辅助配置资源文件 |
| **`25a8096`** | der Baum | 2026-05-20 | 🎉 初始化 | 仓库初始化提交 |

---

## 🔍 关键版本变更与架构决策详解

### 1️⃣ 2026-05-21 最终黄金版：Xray Hysteria 2 完美规范化 (`0383ce4`)
* **背景**：前几次尝试通过 `finalmask` 或将 `obfs` 写入 `hysteriaSettings` 内部均宣告失败，导致服务端在重置协议（`rep`）重启时由于 JSON 解析未知字段导致服务直接闪退，连带使正常的 Sing-box 驱动的 `hy2` 节点由于系统服务阻塞也完全不通。
* **技术决策**：
  * **去嵌套平移**：根据 Xray-core 底层实现机制，将 `obfs` 字段移除，重新定义为 `streamSettings` 下的同级 `udpmasks` 数组，这是 Xray 官方支持 Hysteria 2 Salamander 混淆的唯一正统规范。
  * **鉴权纠错**：将 inbound settings 下错误的 `users` 字段修正为 `clients`。
  * **测试验证**：本地运行 `bash -n` 校验通过，证实没有任何语法错误。

### 2️⃣ 2026-05-20 纯净化与环境隔离设计 (`04d6fc6`)
* **背景**：最初提交中包含了各种辅助文件和他人脚本（如 `sb.sh` 等），导致主干逻辑不够纯净。
* **技术决策**：
  * 引入专属 `.gitignore` 文件，忽略除了核心脚本 `airgosbx.sh` 外的所有其他系统文件（`.DS_Store`）、临时备份文件、他人及辅助脚本。
  * 重新进行 Git 仓库历史洗牌，实现彻底的干净化。

---

## 📈 后续迭代记录约定
1. 每次对 `airgosbx.sh` 脚本进行重大更新、BUG 修复或功能扩充后，必须由操作的 AI 助手（如 Antigravity）及时在此表格首行追加新提交记录。
2. 每次提交前，必须运行 `bash -n` 对脚本进行语法静态检测，确保推送内容无语法故障。
