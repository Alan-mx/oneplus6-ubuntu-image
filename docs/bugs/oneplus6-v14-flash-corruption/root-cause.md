# 一加 6 V14 首次启动 ext4 损坏

## 现象

刷入 V14 并启动后，`orbital-resize-rootfs.service` 失败：

```text
resize2fs: /usr/sbin/resize2fs: Permission denied to resize filesystem
EXT4-fs warning: ext4_resize_begin: There are errors in the filesystem,
so online resizing is not allowed
```

rootfs 仍为 3.4 GiB，没有扩展到约 110 GiB 的 `userdata` 分区。

## 证据

内核日志：

```text
EXT4-fs error (device sda17): ext4_mb_generate_buddy:1317: group 16,
block bitmap and bg descriptor inconsistent: 14240 vs 32254 free clusters
```

V14 源镜像可以通过 `e2fsck -fn`，经过 `simg2img` 往返转换后也能逐字节一致。
第一个受影响的 ext4 块是 2 GiB 偏移处的块 524288。源镜像和刷入设备后的该块
SHA-256 不同：

```text
source image: 2fc54cee58422a83ce548a3fb1a5f9a4dafcfccc3fa78be1a69ecfc2be036d3d
device:       2f0bc7bfb66a2dc8a637d180696b7f0cbe1b3fe38852752f2e859c12861afb07
```

sparse 镜像包含一个强制 RAW chunk，覆盖块 524288 至 524289。源镜像有效，但该块在
fastboot 传输期间没有被正确写入，尽管 fastboot 报告成功。

第二次使用标准 `img2simg` 输出但未先擦除 `userdata`，在组 16、17、18、23、24 和
27 中出现同样错误。该 sparse 镜像使用 RAW 或 FILL chunk 覆盖所有逻辑块。证据表明，
当 FILL 块覆盖旧文件系统时，bootloader/fastboot 路径没有正确清除陈旧数据。

离线修复确认存在更大范围的写入损坏：`e2fsck` 发现多个文件存在重复占用块，修复了
孤儿 inode 列表，把断开目录重新连接到 `/lost+found`，并修正组摘要计数。第二次只读
检查以退出码 0 完成，并报告 `REPAIR SUCCESS`。

## 重建 V14 镜像后的进一步验证

再次使用 Android SDK 的 `simg2img` 解包标准 V14 sparse 镜像。得到的 ext4 镜像通过
`e2fsck -fn`，退出码为 0，文件系统状态干净。

随后比较源镜像和手机中 ext4 组 27 的块位图。标准 sparse 镜像将其保存为 RAW chunk：

```text
sparse chunk 194: RAW
logical blocks:    884961-884962
source block hash: 7d5af105d5763defde0098fb2e2794f1d5dc59ace6eb1cadef0bafb4f9a17ea4
device block hash: ad7facb2586fc6e966c004d7d1d16b024f5805ff7cb47c7a85dabd8b48892ca7
```

设备块哈希等于全零 4 KiB 块的 SHA-256。这不是正常的运行中文件系统修改：源数据块
包含组 27 位图，而设备在预期位置没有任何位图数据。

启动后手机报告：

```text
EXT4-fs error (device sda17): ext4_validate_block_bitmap:432:
comm systemd: bg 27: block 884961: invalid block bitmap
```

因此 `orbital-resize-rootfs.service` 失败：

```text
resize2fs: /usr/sbin/resize2fs: Permission denied to resize filesystem
EXT4-fs warning: ext4_resize_begin: There are errors in the filesystem,
so online resizing is not allowed
```

手动执行 `sudo resize2fs /dev/sda17` 也无法修复。该服务本来执行的就是同一命令；
失败原因是 ext4 元数据无效，不是缺少权限或没有调用。

同时，手机并没有占用 2.4 GiB 内存。新的运行时检查显示约 647 MiB 已使用、
6.7 GiB 可用。root 文件系统约使用 1.7 GiB，`du -x` 统计约 1.6 GiB，与已安装
软件包和日志规模一致。

## 分段刷入后的设备验证

3.5 GiB ext4 raw 镜像被拆分成 10 个小于 512 MiB 的 sparse 分卷。每个分卷只使用
`RAW` 和 `DONT_CARE` chunk。按顺序刷入全部 10 个分卷后，在设备上完成验证：

```text
root device:            /dev/sda17
userdata size:          118112366592 bytes
root filesystem size:   109 GiB
ext4 block count:       28835840
ext4 state:             clean
resize service:         exit status 0 / success
failed systemd units:   0
ext4 errors in dmesg:   none
locked packages:        520
package set SHA-256:    7c08610d03127668970b2b29256a21fdc71e2443b847b0b89d7db2be436b09d9
memory used:            664 MiB
memory available:       6.7 GiB
```

这证明 V14 文件系统内容和首次启动扩容本身有效，也证明分段 `RAW`/`DONT_CARE`
传输避开了该 fastboot 路径上用单个 sparse 文件产生的损坏。

## 解决

- 使用 `oneplus6-boot-repair-v14.img` 离线修复已安装文件系统。
- 使用 Android SDK 的 `img2simg` 重新生成分享镜像，不再使用自定义 sparse 编码器。
- 将 `img2simg` 输出转换回 raw，与源 raw 镜像逐字节比较，并执行 `e2fsck -fn`。
- 在发布目录中保留 V14 repair boot。

标准 sparse 镜像仍是构建产物，但在该 fastboot 路径上还不能安全地作为单文件发布。
`out/v14-segmented-flash/` 下的分段产物已经在目标手机上刷入并验证。

由于第一次刷写产生了多个交叉链接块，修复后的 rootfs 只能用于诊断。不要把修复后的
文件系统作为发布产物；应重新刷入标准 rootfs。

所需刷写顺序为：

```text
fastboot flash boot oneplus6-boot.img
fastboot erase userdata
fastboot flash userdata oneplus6-rootfs-orbital.img
fastboot reboot
```

不能省略 `fastboot erase userdata`；否则旧数据块可能残留，新的 ext4 文件系统会在
与签名无关的一致性检查中失败。
