# Linux 权限、桌面图标与故障排查

本文对应上游 issue [#250](https://github.com/ldoubil/astral/issues/250)（必须 root 才能打开）
与 [#193](https://github.com/ldoubil/astral/issues/193)（rpm/deb 缺少运行库依赖）、
[#194](https://github.com/ldoubil/astral/issues/194)（旧发行版启动闪退）的修复说明。

## 1. 为什么需要提权

Astral 在 Linux 上会**在进程内**创建并配置 TUN 虚拟网卡：

- 打开 `/dev/net/tun` 并执行 `TUNSETIFF`（`tun` 库）→ 需要 `CAP_NET_ADMIN`；
- 通过 netlink 给网卡配置地址、路由（不是调用 `ip` 子进程）→ 需要 `CAP_NET_ADMIN`；
- 启用 **faketcp** 时走 `AF_PACKET`/`SOCK_RAW` → 额外需要 `CAP_NET_RAW`；
- 启用 **magic-dns** 时修改系统 DNS（NetworkManager D-Bus / resolvconf / 直写 `resolv.conf`）
  → 需要 polkit 授权或 root；setcap 模式下该功能可能降级（仅日志报错）。

因此「能连上」不一定需要 root，但「TUN 模式能建虚拟网卡」一定需要 `CAP_NET_ADMIN`。

> 旧版本（≤ v2.9.60）在非 root 启动时只往终端打印一句提示然后 `exit(1)`，
> 从桌面图标启动时用户完全看不到输出，表现就是「双击没反应 / 闪退」。
> 现已改为：**缺少能力不再退出**，打印可操作提示并继续启动（NO-TUN 模式可用）。

## 2. 三种方案

| 方案 | 命令 / 操作 | 优点 | 缺点 |
| --- | --- | --- | --- |
| A. sudo 运行 | `sudo /opt/astral/astral` 或 `sudo astral` | 最直接，所有功能可用 | 整个 GUI 以 root 跑；数据库/配置在 root 名下；升级后仍要 sudo |
| B. setcap（推荐） | `sudo setcap 'cap_net_admin,cap_net_raw+ep' /opt/astral/astral` | 日常免 sudo，GUI 以普通用户运行，数据归普通用户 | **每次升级/重装覆盖二进制后失效，必须重做**；magic-dns 可能降级 |
| C. NO-TUN 模式 | 应用内：设置 → 网络 → 关闭 TUN 模式 | 完全不需要任何权限 | 需自行用 Clash 等工具接管 TUN/路由 |

### A. sudo 运行

```bash
sudo /opt/astral/astral        # deb / rpm 安装后的实际二进制
sudo astral                    # 走 /usr/bin/astral 包装脚本，等价
```

注意：sudo 下 `HOME` 通常是 `/root`。程序已优先使用 `SUDO_USER` 对应的真实用户目录
（见第 5 节）；若沿用旧版本写下的 root 数据，会继续使用旧路径。

### B. setcap（推荐）

```bash
# 1) 给真实二进制加能力（不是 /usr/bin/astral 这个包装脚本）
sudo setcap 'cap_net_admin,cap_net_raw+ep' /opt/astral/astral

# 2) 验证
getcap /opt/astral/astral
# 期望输出：/opt/astral/astral cap_net_admin,cap_net_raw=ep

# 3) 正常启动（不要再加 sudo）
astral
```

**升级后必须重做**：deb/rpm 升级或重新下载 tar.gz 会覆盖 `/opt/astral/astral`，
新文件的 file capabilities 为空，TUN 模式会重新失效。升级后重新执行上面的 `setcap` 即可
（可在发行版 hook 或自己的更新脚本里加一行）。

补充说明：

- 能力给的是 `/opt/astral/astral`，**不要**给 `/usr/bin/astral`（它只是 `exec` 的 shell 脚本，
  脚本上的 capabilities 不会传递给最终二进制）。
- `cap_net_raw` 只有 faketcp 需要；不想开可只给 `cap_net_admin`。
- magic-dns 改系统 DNS 需要 polkit/root，setcap 模式下可能失败（仅影响 DNS 接管）。

### C. NO-TUN 模式

不需要任何权限：在「设置 → 网络」关闭 TUN 模式，由 Clash / sing-box 等外部工具接管 TUN，
Astral 只做 P2P 组网。当前版本没有 `--no-tun` 命令行开关，只能用设置项切换。

## 3. 自动提权（pkexec）行为

当检测到缺少 `CAP_NET_ADMIN`、当前是图形会话（有 `DISPLAY` / `WAYLAND_DISPLAY`）、
系统存在 `/usr/bin/pkexec` 且不是登录自启动时，程序会尝试用 pkexec 弹出系统授权框并
**以 root 重启自身**：

- 授权成功：由 root 实例运行；关闭应用后原进程静默退出，不会出现两个窗口；
- 取消授权 / 失败：**回退为以无特权模式继续启动**，不会阻塞启动、不会静默退出。

想关闭自动提权（例如已统一下发 setcap，或不想每次弹密码框）：

```bash
ASTRAL_NO_PKEXEC=1 astral
```

也可以 `sudo setcap ...` 之后就不再触发（有 `CAP_NET_ADMIN` 时根本不会走到提权分支）。

## 4. 桌面图标 / 命令缺失排查

deb / rpm 会安装以下文件（tar.gz 是绿色包，不含这些文件，需自行创建）：

| 路径 | 作用 |
| --- | --- |
| `/opt/astral/` | 应用本体（bundle） |
| `/usr/bin/astral` | 包装脚本，`exec /opt/astral/astral "$@"` |
| `/usr/share/applications/astral.desktop` | 桌面入口（`Exec=/usr/bin/astral %u`） |
| `/usr/share/pixmaps/astral.png` | 图标（`Icon=astral`） |

排查步骤：

```bash
# 1) 包装脚本是否安装、是否可执行
ls -l /usr/bin/astral
command -v astral
astral --help 2>&1 | head -n 1        # 有无报错

# 2) 桌面入口是否存在且语法正确
ls -l /usr/share/applications/astral.desktop
desktop-file-validate /usr/share/applications/astral.desktop   # 若已安装 desktop-file-utils

# 3) 图标
ls -l /usr/share/pixmaps/astral.png
gtk-update-icon-cache -f -t /usr/share/icons/hicolor 2>/dev/null || true
update-desktop-database ~/.local/share/applications 2>/dev/null || true

# 4) 从终端直接启动，抓 stderr（区分「无输出即旧版 exit(1)」和动态库/glibc 报错）
/opt/astral/astral
```

若安装后仍没有图标，优先确认包内容：

```bash
dpkg -L astral | grep -E 'applications|pixmaps|/usr/bin/astral'   # deb
rpm -ql astral | grep -E 'applications|pixmaps|/usr/bin/astral'   # rpm
```

## 5. 数据库目录（sudo 场景）

- 默认：`$HOME/.local/share/astral/db`（Isar 数据库）。
- sudo / pkexec 提权时，程序优先用 `SUDO_USER` / `PKEXEC_UID` 反查**真实用户**家目录，
  即 `/home/<user>/.local/share/astral/db`，避免普通用户与 root 数据分叉。
- 向后兼容：若旧路径（提权后的 `HOME`，通常是 `/root/.local/share/astral/db`）已有数据，
  则继续沿用旧路径，升级不会丢配置。
- root 创建的数据库文件会在启动时 `chown` 回真实用户，保证后续普通用户
  （如 setcap 方式启动）可读写；若 chown 失败，手动执行：

```bash
sudo chown -R "$USER":"$USER" ~/.local/share/astral
```

## 6. 运行库依赖（#193）

deb / rpm 已声明以下运行依赖（fpm `--depends`）：

- deb：`libayatana-appindicator3-1`、`libgtk-3-0`（Ubuntu 24.04+ 的 GTK3 包名为 `libgtk-3-0t64`）；
- rpm：`libayatana-appindicator3.so.1()(64bit)`（arm64 为 `()(aarch64)`）、`gtk3`。

若手工安装（如解压 tar.gz）后启动报
`error while loading shared libraries: libayatana-appindicator3.so.1`：

```bash
# Debian / Ubuntu
sudo apt install libayatana-appindicator3-1
# Fedora
sudo dnf install libayatana-appindicator-gtk3
# OpenEuler
sudo dnf install libayatana-appindicator3-1
```

## 7. 启动即闪退的其它原因（#194）

- **旧版本**：非 root 被 `exit(1)`，见第 1 节，升级到包含本修复的版本即可。
- **glibc 过旧**：v2.9.60 及以前的 x64 包在 Ubuntu 24.04 级构建机上产出，
  要求 `GLIBC_2.39`；Ubuntu 22.04（2.35）/ Debian 12（2.36）会报
  `version 'GLIBC_2.39' not found`。现已把 x64 构建机固定为 `ubuntu-22.04`。
  从终端运行 `/opt/astral/astral` 可看到具体 `GLIBC_x.y not found` 报错。
- 其余情况请附上终端输出与 `~/.local/share/astral` 内容再排查。
