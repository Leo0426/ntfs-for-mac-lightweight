---
status: accepted
---

# 每次启用写入前，由正式 helper 验证一次性镜像

日期：2026-09-30。用户已批准并要求实现。

本机 FSClient 在调用进程中未观察到 macFUSE 模块，但同一登录身份下的独立镜像已通过真实
FSKit local 可写挂载和标准卸载。跨 Team 枚举的空结果不能证明后端禁用；以它作硬门禁会误拒绝。

决定：每次写入请求在操作物理盘前，由正式 helper 通过固定空白 NTFS 镜像验证后端。
安装件的资源受 App 签名封印；解压前后校验固定大小和 SHA-256。helper 独占新建 root 文件、
绑定描述符与 inode，调用同一固定签名驱动，沿用永久 UID 501/GID 20 降权和 FSKit local 参数。
镜像挂载点由本次随机标识生成，接口不接受 UI 路径、存储或挂载参数。

就绪必须同时确认真实可写挂载、完整稳定挂载表、固定用户、驱动持有该镜像、FSKit 虚拟来源、
标准用户卸载成功、挂载消失和 waitpid 回收驱动成功。通过后删除本次镜像及挂载目录；不缓存结果。
随后执行器重新读取物理目标、同盘卷集合与代次，并保留启动扇区、UUID、dirty/休眠和声明检查。
镜像证明不替代目标资格、实盘写删、Windows 复核或 Gate 验收。

资格由进程级协调器持有，并以 `/private/var/db/com.leolu.ntfslite.runtime-probe` 独占目录
覆盖跨进程崩溃场景。未知归属、截断、超时、取消或不完整收尾均不能放行；未知时保留镜像、
子进程和资格，拒绝后续变更且阻止 helper idle exit。只允许确认归属后的标准卸载；不强制卸载
或杀死驱动。异常残留必须先核对现场，不能自动删除持久目录。

固定 root-only `--verify-runtime` 入口仅执行该预检；不接受磁盘或路径参数。
未确认收尾时诊断保持进程运行，与 daemon 一样保留资格。

代价：每次请求额外写入约 128 MiB 临时镜像，耗时数秒；缺空间或后端已确认不可用时在原生卷
卸载前拒绝。全局资格序列化预检，异常时牺牲可用性以保留现场。选择受保护 var/db 而非 group
可写 var/run，避免普通组成员替换资格目录。

## 固定资源

- 解压大小：134217728 字节；压缩大小：252203 字节，raw DEFLATE（Foundation NSData zlib）。
- 解压 SHA-256：`0fa5b73d5f603c9b7c25a9a67f2e003a2cca7cc4c18cbf3e664e76fbe2caff31`。
- 压缩 SHA-256：`bc13f484e9bc508733246b1bc2145068041b883a5eaad32273106d54c09d7c34`。
- 由固定 mkntfs 候选生成新的空白文件；候选 SHA-256：
  `7790efde233476963eae4509581be220cbb1de991eb6bec3a1a2ab4824aec929`。构建不重新生成种子。

## 依据与验收边界

[Apple FSClient](https://developer.apple.com/documentation/fskit/fsclient) 未保证调用者能观察其他
Team 模块；本机 Xcode 27 SDK 与当日对照见[运行时调查](../research/fskit-runtime-preflight.md)。
正式安装件镜像、可牺牲 NTFSLAB 与 Windows 的验证结果分别记录；Gate 状态不因此升级。
