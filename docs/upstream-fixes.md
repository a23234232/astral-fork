# 上游 issue 修复记录

本文件记录本 fork 对上游 [`ldoubil/astral`](https://github.com/ldoubil/astral) open issue 的修复情况，便于用户对照与复测。

> 上游状态：维护者 2026-09-22 在 #261 表示「会保持维护不会加大改动了」，此后无代码提交、无 issue 回复。本 fork 在此基础上集中修复了一批可定位的缺陷。

## 一、已修复（本仓库有代码改动）

### 依赖与安全

| Issue | 问题 | 修复 |
| --- | --- | --- |
| PR #262 | `quinn-proto 0.11.14` 受 4 个远程内存耗尽 CVE 影响、`openssl` 落后两个补丁版 | 采用上游 dependabot 补丁：`quinn-proto 0.11.17`、`openssl 0.10.81`（`rust/Cargo.lock`） |
| #260 | `TUN 错误: rust tun error Failed to create adapter` 用户无从下手 | 在 `TunDeviceError` 事件中按平台追加排查建议（Windows：残留虚拟网卡驱动 / VMware / WSL / 管理员权限；Linux：`tun` 模块与 `CAP_NET_ADMIN`；macOS：需提权） |

### Linux

| Issue | 问题 | 修复 |
| --- | --- | --- |
| #193 | 干净系统安装 rpm/deb 后启动即报 `libayatana-appindicator3.so.1: cannot open shared object file` | 打包时补依赖：deb `libayatana-appindicator3-1` + `libgtk-3-0`；rpm `libayatana-appindicator3.so.1()(64bit/aarch64)` + `gtk3`（此前 deb 无 `Depends:`、rpm `REQUIRENAME` 为空） |
| #250 | 必须 `sudo` 才能打开；从图标启动毫无反应；装完没有图标 | 1) 非 root 时不再静默 `exit(1)`：读取 `CapEff` 判断能力，打印 setcap/sudo/NO-TUN 提示后**继续启动**，图形会话下尝试 `pkexec` 提权（失败自动回退，`ASTRAL_NO_PKEXEC=1` 可关）；2) 恢复 v2.8.6 起丢失的 `/usr/bin/astral` 包装脚本、`.desktop` 桌面入口与图标；3) sudo 运行时数据库改写到真实用户目录 |
| #194 | `.deb` 安装后启动闪退 | 1) 主因同 #250（旧版从图标启动看不到那句 `print`，被当成闪退）；2) x64 构建机固定 `ubuntu-22.04`，消除产物对 `GLIBC_2.39` 的硬依赖（Ubuntu 22.04 / Debian 12 可运行） |

### Windows

| Issue | 问题 | 修复 |
| --- | --- | --- |
| #259 #253 | 开机自启无效；且每次运行 Astral 都会删掉/覆盖用户自己建的自启项 | 计划任务触发器由 `ONSTART`（系统启动、登录前，GUI 程序实际不会跑）改为 `ONLOGON` + `/rl HIGHEST`（登录时免 UAC 提权）；改为幂等——已存在就不重建，旧 `ONSTART` 任务自动迁移一次；旧 `HKCU\...\Run` 与启动文件夹项的清理只在用户主动切换开关时执行，启动路径不再删除任何用户自建项 |

### Android

| Issue | 问题 | 修复 |
| --- | --- | --- |
| #263 | 连接通知在进程被杀后永久残留，只能清应用数据或重启手机 | 通知改由独立前台服务 `AstralKeepAliveService` 持有：服务随进程被系统回收时通知自动清理；TUN 与 NO-TUN 两种模式都覆盖；断开连接时正常取消。社区 PR #264 未采用——它把 `TauriVpnService` 改成 `startForegroundService` 却从不调用 `startForeground`，按 Android 官方行为会导致进程被系统 crash，且删掉了重启前的 `onRevoke`（造成重复 start / fd 泄漏）、未覆盖 NO-TUN |
| #246 | 部分机型「小窗模式」下显示异常 | 删除全局 `MediaQuery` 改写（`devicePixelRatio=1.0` 等 hack 会让整个 UI 缩放错乱）；小窗改由 `LayoutBuilder` 实际约束驱动，主界面/状态栏/底部导航增加紧凑布局（可滚动内容、可横向滚动导航） |

### 网络 / 功能

| Issue | 问题 | 修复 |
| --- | --- | --- |
| #254 | 隧道类型只有 IPv4，容易走转发而不是 P2P | `withListeners` 不再直接过滤含 `[::]` 的监听，改为规范化去重 + 同端口冲突保护 |
| #243 | 连别人分享的房间时，自己的全局服务器会被混进去；想全局列表只做管理 | 房间自带服务器时默认只用房间服务器；新增设置「连接房间时同时使用我的全局服务器」（默认关）可恢复旧行为 |
| #214 | 更新提示点击后提示「无法保存」 | 下载失败不再统一报「无法保存」：区分网络/超时/HTTP 状态码/写盘/取消，并提示检查更新加速或代理 |
| #249 | 设置里提示重复、弹框两个按钮行为相同 | 删除与「启动说明」重复的小字；「已是最新」时只保留一个按钮 |

### macOS

| Issue | 问题 | 修复 |
| --- | --- | --- |
| #189 | 是否有 macOS 支持 | root+utun 提权路线收尾：提权失败（取消密码框）不再 panic；启动时 `await` 提权结果，消除「双实例 + 一个没有权限」；README 平台说明与实际产物对齐（macOS 为实验性、未签名，需按 `macos/INSTALL.txt` 放行） |

## 二、无需改代码（已修复 / 外部原因 / 需复测）

| Issue | 结论 |
| --- | --- |
| #212 缺失 Linux-arm64 | **自 v2.8.9 起已提供**（tar.gz / deb / rpm），v2.9.60 发布资产里就有 |
| #221 Windows 触摸点击错位 | Flutter 引擎回归（flutter/flutter#184954），修复 #185850 / CP #186034 已于 2026-05-06 合入；用当前版本复测即可 |
| #207 faketcp 回退把 `ip:port` 当网卡名 | 上游 EasyTier 于 2026-04-30（`41b6d656`）修复，本项目锁定的 `8e1d079`（2026-05-09）已包含该修复 |
| #255 「需要重启才能完成设置」弹窗 | 截图是 **Windows 通知中心**的设备安装提示，不是 Astral 弹窗；仓库中不存在该字符串 |
| #206 网站教程过时 | 教程在 `astral.fan`，不在本仓库 |
| #218 AUR 构建失败 | AUR `astral-bin` 的 PKGBUILD 用了多点 tag `v.2.7.3`（与 `v2.7.3` 同一提交），需要 AUR 侧把 `source` 改成 `v2.7.3`；本仓库无法修 |
| #202 Ubuntu 无法连接 | 2.6.9999 时期问题，连接链路与本地数据库结构均已大改；请升级后复测（必要时清 `~/.local/share/astral`） |
| #258 自建服务器连不上 | DHCP 只影响虚拟 IP；关 DHCP 时「已连接」判定只看虚拟 IP，会产生假连接。需要服务端版本 + 客户端日志才能定位握手被关闭的原因 |

## 三、明确不支持

| Issue | 结论 |
| --- | --- |
| #242 #252 macOS 发布 | 本 fork 提供 ad-hoc 签名的 DMG（未付费证书签名，首次启动需右键打开或清 quarantine）。要免 Gatekeeper 提示需 Apple 付费开发者账号做 Developer ID 签名 + 公证 |
| #257 iOS | **不提供**。iOS 的 TUN 必须走 NetworkExtension + 付费开发者账号与签名分发渠道，当前没有可用 IPA 产物；`README` 已移除 iOS 宣称 |

## 四、行为变更提醒（升级前请读）

1. **#243 服务器合并默认值变更**：房间自带服务器时，不再自动把你的全局服务器加进去。如果你依赖全局服务器连房间，请到「设置 → 网络 → 连接房间时同时使用我的全局服务器」打开。
2. **#250 Linux 启动**：不再因为非 root 直接退出。缺 `CAP_NET_ADMIN` 时会尝试 `pkexec` 提权（弹一次系统授权框），取消后以 NO-TUN 模式继续启动。可用 `ASTRAL_NO_PKEXEC=1` 关闭自动提权，改用 `sudo setcap 'cap_net_admin,cap_net_raw+ep' /opt/astral/astral`。
3. **#259 #253 Windows 自启**：计划任务改为「登录时 + 最高权限」，旧的「系统启动时」任务会在应用启动时自动迁移一次。若你手工改过该任务，升级后请确认是否符合预期。
4. **#263 Android 通知**：关闭「连接通知」后，Android 仍会保留一条最小化的前台服务通知（系统对前台服务的强制要求）；区别是进程被杀后这条通知会随服务一起消失，不再永久残留。

## 五、验证状态

| 项目 | 状态 |
| --- | --- |
| Linux 构建（x64/arm64，含打包依赖与桌面入口） | CI `linux-build.yaml` |
| Windows 构建与安装包 | CI `windows-build.yml` / `windows-build-Setup.yml` |
| Android APK（含前台服务与 manifest） | CI `android-build-*.yaml` |
| macOS DMG | CI `macos-build.yaml` |
| 真机行为（#246 小窗、#244 拓扑、#263 通知清理、#250 提权） | **需要真机回归**，CI 只能验证编译与打包 |
