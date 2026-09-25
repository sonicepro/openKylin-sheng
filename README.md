# openKylin-sheng

用 **GitHub Actions** 为**小米平板 6S Pro（sheng / 高通 SM8550）**构建 **openKylin arm64** 的
`rootfs.img` 与 `boot.img`，产物可直接用 `fastboot` 刷入设备。

结构参照 [code002-2/ubuntu-sheng](https://github.com/code002-2/ubuntu-sheng)（同一设备的 Ubuntu 构建），
把发行版相关的部分（基础引导、桌面、显示管理器、软件源）换成 openKylin，其余（内核、boot 镜像、
设备功能包）与 Ubuntu 构建**完全复用**——它们都是发行版无关的 Debian 包。

> ⚠️ 刷机有风险，操作需谨慎，一切后果自负。刷写步骤请阅读
> [Xiaomi-pad-6s-pro-Linux 的安装指南](https://github.com/code002-2/Xiaomi-pad-6s-pro-Linux/blob/main/docs/安装指南.md)。

## 与 ubuntu-sheng 的差异

| 维度 | ubuntu-sheng | openKylin-sheng |
|---|---|---|
| 基础引导 | `ubuntu-base` tarball 优先，mmdebstrap 兜底 | **debootstrap** 从 openKylin 归档引导（无官方 base tarball） |
| 归档 | `archive.ubuntu.com` / `ports.ubuntu.com` | `archive.build.openkylin.top/openkylin/`（**直接含 arm64**） |
| 版本代号 | resolute / stonking / questing | **nile (2.0) / huanghe (3.0) / yangtze (1.0)** |
| 组件 | main restricted universe multiverse | **main cross pty** |
| 桌面 | GNOME / KDE Plasma / Lomiri / server | **UKUI / server**（UKUI 是 openKylin 默认桌面） |
| 显示管理器 | gdm3 / sddm / greetd | **lightdm + ukui-greeter** |
| 自动登录 | `custom.conf` / `sddm.conf.d` / greetd | **`/etc/lightdm/lightdm.conf.d/50-ok-autologin.conf`** |
| 默认语言 | `C.UTF-8` | **`zh_CN.UTF-8`** |
| snap | 硬性禁用（三重保障） | 无 snap 过渡包问题，不特判 |
| 内核 / boot.img / 设备包 | — | **完全相同**（复用 `ianchb/*` 的 release） |

openKylin 2.0（nile）基础是 **Debian 13 系**（`base-files 13-ok2.2`、`systemd 255.2`），
因此 debootstrap 借 Debian 的脚本（`trixie`，等价 `sid`）引导 openKylin 自己的 suite。

## 参数说明

| 参数 | 默认值 | 说明 |
|---|---|---|
| **openkylin_series** | `nile (2.0)` | `nile (2.0)` / `huanghe (3.0)` / `yangtze (1.0)` |
| **desktop** | `UKUI` | `UKUI` / `server`（无图形界面） |
| **autologin** | `true` | LightDM 自动登录 |
| **username / hostname** | `user` / `xiaomi-sheng` | 仅允许字母数字与 `_ . -` |
| **password** | *(空)* | 优先本输入项；留空用 Secret `ROOTFS_PASSWORD`；都空则 `password` |
| **language** | `zh_CN.UTF-8` | 选择后生成该 locale + `en_US.UTF-8`；`None (C.UTF-8)` 表示不生成 |
| **boot_mode** | `dual (linux)` | `single (userdata)` / `dual (linux)` / `custom` |
| **custom_partition** | *(空)* | 仅 `boot_mode=custom` 需要，且必须搭配 `kernel_source=custom_build` |
| **quiet_boot** | `true` | 安装 Plymouth 并选用 `*_plymouth.img`；`server` 模式忽略 |
| **kernel_source** | `prebuilt` | `prebuilt` = 取 [ianchb/sm8550-mainline](https://github.com/ianchb/sm8550-mainline) 的 release；`custom_build` = 自行编译 |
| **kernel_release** | `7.2.6` | `prebuilt` 取哪个 release（留空取最新） |
| **firmware_repo / firmware_branch** | `ianchb/sheng-firmware` / `master` | 设备固件来源 |
| **rootfs_size** | `10G` | 镜像初始大小（构建后收缩，首启 `x-systemd.growfs` 扩到分区实际大小） |
| **shrink_image** | `true` | 构建后 `e2fsck -fy` + `resize2fs -M` 收缩 |
| **upload_artifacts** | `true` | 设为 `false` 只验证流程、不产出 Artifact |

## 目录结构

```
scripts/
  common/distro-env.sh      # openKylin suite↔镜像↔密钥环 映射
  host/                     # 宿主阶段（在 arm64 runner 上跑）
    00-prepare-image.sh     #   建 rootfs.img 并挂载
    01-bootstrap.sh         #   ★ debootstrap 引导 openKylin
    02-mount-chroot.sh      #   挂载 /dev /proc /sys，拷脚本与 deb 入镜像
    03-umount-chroot.sh
    04-finalize-image.sh    #   收缩镜像、固定 UUID
    10-fetch-kernel.sh      #   prebuilt boot.img + 内核 deb
    11-make-bootimg.sh      #   custom_build 时本地生成 boot.img
  in-chroot/                # 镜像内阶段（chroot 执行）
    10-base.sh              #   基础包
    20-desktop.sh           #   ★ UKUI / server
    30-device-packages.sh   #   安装 linux-xiaomi-sheng 等设备 deb
    40-system-config.sh     #   ★ lightdm 自动登录 + locale + fstab
    90-verify.sh            #   构建末尾硬校验
  lists/                    # 包列表（base / ukui / runtime-libs / plymouth）
  packages/                 # 设备 deb 的源码/打包脚本（复用 ubuntu-sheng）
```

## 构建

在 GitHub 上 Actions → **Build RootFS (openKylin)** → Run workflow，选择参数即可
（需要 arm64 runner `ubuntu-24.04-arm`）。产物为 `rootfs-openkylin-*.img` 与 `boot-openkylin-*.img`。

**本地构建**（需 arm64 主机 + root + 联网）：

```bash
sudo apt-get install -y debootstrap curl git e2fsprogs
# 1) 先把设备包准备好放到 debs/（见 .github/workflows/_packages.yml 的各作业）
#    并准备 boot.img（scripts/host/10-fetch-kernel.sh 需要 gh 已登录）
# 2) 依次执行宿主脚本
sudo scripts/host/00-prepare-image.sh rootfs.img 10G /mnt/rootfs
sudo env DISTRO_SERIES=nile scripts/host/01-bootstrap.sh /mnt/rootfs
sudo scripts/host/02-mount-chroot.sh /mnt/rootfs
# 3) 写 /mnt/rootfs/root/build.env（见 rootfs.yml 的 Write Build Environment）
# 4) chroot 执行镜像内脚本
sudo chroot /mnt/rootfs /root/ok-build/in-chroot/10-base.sh
sudo chroot /mnt/rootfs /root/ok-build/in-chroot/20-desktop.sh
sudo chroot /mnt/rootfs /root/ok-build/in-chroot/30-device-packages.sh
sudo chroot /mnt/rootfs /root/ok-build/in-chroot/40-system-config.sh
sudo chroot /mnt/rootfs /root/ok-build/in-chroot/90-verify.sh
# 5) 收尾
sudo scripts/host/03-umount-chroot.sh /mnt/rootfs
sudo scripts/host/04-finalize-image.sh rootfs.img /mnt/rootfs
```

## 许可与第三方组件

本仓库是构建脚本集合，自身不声明开源许可证。仓库内包含的第三方内容版权归各自权利人：

| 内容 | 来源 | 许可 |
|---|---|---|
| `mkbootimg` | AOSP `system/tools/mkbootimg` | Apache-2.0 |
| `sm8550.config` | [ianchb/sm8550-mainline](https://github.com/ianchb/sm8550-mainline) | GPL-2.0 |
| `patches/` | 上游 `debian-sheng` 及其各自上游 | 随各上游仓库 |
| `sheng-sensors-files/`、`alsa-xiaomi-sheng/` | 上游 `sheng-sensors` / `alsa-xiaomi-sheng` 包 | 随上游 |
| 构建期下载的内核 deb、`xiaomi-*` deb、设备固件 | 各自 GitHub release / 仓库 | 见对应上游仓库 |

`firmware-xiaomi-sheng` 在本仓库内只有包骨架，**固件二进制在构建时从上游 `sheng-firmware` 下载**，
本仓库不重新分发。

## 致谢

- **map220v** — TWRP、主线内核移植与大量设备适配
- **ianchb** — [debian-sheng](https://github.com/ianchb/debian-sheng) 与 `xiaomi-*` 设备功能包
- **code002-2** — [ubuntu-sheng](https://github.com/code002-2/ubuntu-sheng)（本仓库的结构蓝本）
- **Dylan Van Assche** — `libssc` 与 `iio-sensor-proxy` 的 SSC 后端
- **openKylin 社区** — openKylin 发行版与 UKUI 桌面
