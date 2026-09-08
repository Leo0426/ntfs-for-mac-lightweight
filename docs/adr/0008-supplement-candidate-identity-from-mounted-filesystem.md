---
status: accepted
---

# 用已挂载文件系统 UUID 补充只读候选身份

2026-09-08 实物 NTFS 的 Disk Arbitration Volume UUID 缺失，但 Foundation 和描述符绑定的
`ATTR_VOL_UUID` 返回同一个有效文件系统 UUID。我们允许从已核对的挂载卷补充外置、用途未知
NTFS 的只读候选身份，因为坚持只接受 DA 会使有公开系统身份的卷永久不可见，而直接读取
路径或替换成分区 UUID 会混淆事实来源与对象身份。

## Considered Options

- 仅接受 DA Volume UUID：接口最少，但在本次实物上无法生成候选。
- 通过 Foundation 路径读取 UUID：公开接口且实物可用，但身份读取本身未绑定目录描述符，
  挂载点复用时需要额外解决对象关联。
- 从同一打开目录描述符读取文件系统 UUID：采用。增加一个系统读取边界，集中封装返回掩码、
  长度、设备/挂载点/文件系统/挂载标志和 fsid 一致性核对；仍保持小的只读接口。

## Consequences

- 生产读取仅对稳定挂载表中的本地 NTFS 进行；目录必须规范、无符号链接，使用只读目录 FD。
  同一 FD 连续两次 UUID 必须一致；FD 读取前后及最终路径的 statfs 必须与枚举挂载事实一致。
  属性缺失、未知掩码、截断、全零 UUID、系统调用失败和对象不一致不能提供补充身份。
  实际执行原生身份读取但未通过验证时，对应挂载记录保持不完整，已有 DA UUID 不能掩盖该失败。
- 补充值只是 `ATTR_VOL_UUID` 文件系统身份；不使用 MediaUUID、分区 UUID、卷名、BSD 名、fsid
  或随机值代替它。fsid 仅用于当前挂载关联，不进入 VolumeID。
- 仅 DA 原始 UUID 为 nil，且外置、unknown-role、NTFS、已挂载及原有核对全部通过时，才能
  用补充身份生成 `ReadOnlyVolumeCandidate`。DA 非空但非法不回退，两来源矛盾失败关闭。
- 原始 DA evidence 保留原值。候选身份供既有 Gate recorder 匿名投影；schema 与目标轮次规则
  不变。没有补充身份且 DA 也缺失时保持 incomplete；不会缓存到卸载后或下一次订阅。
- 补充身份不生成 mutation snapshot，不证明用途、健康、可写安全性或 Gate 通过。卸载后无法
  依靠该来源取得 UUID 的问题，仍需未来变更接线前单独解决，不能复用最后一次候选。
- 本决策补充 ADR 0001/0005 的身份来源，不改变二者的只读与声明边界。实物重插、克隆、多分区
  完整矩阵仍需验证。系统调用等待不等于可取消操作，未完成读取不能产生可信身份。
