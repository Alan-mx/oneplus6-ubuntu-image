# 一加 6 在 32 位 Windows fastboot 中刷写 raw userdata 失败

## 现象

刷写 3.5 GiB 未压缩 ext4 测试镜像时，fastboot 尚未打印第一行 `Sending` 就退出：

```text
fastboot.exe flash userdata oneplus6-rootfs-orbital-v14-raw-test.raw
libc++abi: terminating due to uncaught exception of type std::bad_alloc:
std::bad_alloc
```

## 证据

本机安装的客户端为 platform-tools 37.0.1。PE 头显示它是 32 位 x86 程序：

```text
Machine:      0x014C
Architecture: x86
```

raw 镜像信息：

```text
size:   3,758,096,384 bytes
format: uncompressed ext4
sparse: false
```

手机仍处于 fastboot 模式：

```text
product:               sdm845
current-slot:          b
max-download-size:     805306368 bytes
partition-size:userdata: 0x1B800BB000
partition-type:userdata: ext4
```

崩溃发生在 fastboot 打印任何 `Sending 'userdata'` 进度之前。这说明客户端在准备或
映射过大的 raw 输入时已经失败，尚未开始传输。

## 根因

platform-tools 37.0.1 附带的 Google Windows fastboot 客户端是 32 位 x86 程序。
未压缩 raw 镜像为 3.5 GiB，超过该进程实际可用的用户态地址空间。加载或映射 raw
镜像时触发 `std::bad_alloc`。

这个问题与此前的 sparse 镜像损坏无关。V14 的 sparse 文件本身约 1.5 GiB，因此
32 位客户端可以接受。

## 影响

- 失败命令没有进入第一阶段的 `Sending`，因此没有成功写入 raw 镜像。
- 手机仍停留在 fastboot 模式，分区也没有 AVB footer。
- 如果已经执行过 `fastboot erase userdata`，刷入有效 rootfs 前不能把现有 rootfs
  当作可启动系统。

## 验证方案

每次只改变一个变量：

1. 生成小于 512 MiB 的连续 sparse 分卷。
2. 保持 sparse 逻辑大小仍为完整 3.5 GiB，并把当前分卷之外的数据表示为
   `DONT_CARE` chunk。
3. 不生成 FILL chunk；每个分卷只在自己的连续区间内包含 RAW 数据。
4. 刷写前验证每个分卷的 sparse 结构和文件大小。
5. 擦除 `userdata`，使用官方 32 位客户端按顺序刷入所有分卷，然后启动并验证
   ext4 健康和在线扩容。

该方案消除了超大 raw 内存分配，同时也在不含 FILL chunk 的情况下测试 bootloader。

## 验证结果

分段测试在一加 6 上成功完成：

```text
root filesystem:       109 GiB
ext4 state:            clean
resize service:        exit status 0
failed systemd units:  0
locked packages:       520
package set SHA-256:   7c08610d03127668970b2b29256a21fdc71e2443b847b0b89d7db2be436b09d9
```

机器可读验证记录位于
`state/v14-segmented-flash-device-verification.json`。
