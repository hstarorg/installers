# 数据盘挂载

在安装有 Python >=3.10、util-linux 和 systemd 的 Linux 主机上，通过 SSH 终端执行：

```bash
curl -fsSL https://raw.githubusercontent.com/hstarorg/installers/main/disk/install.sh | sudo bash
```

也可以下载仓库后执行：

```bash
sudo bash disk/install.sh
```

入口是 Bash 单文件，内嵌 Python 标准库实现安全检查，不下载其他仓库文件或 Python 包。新盘初始化还需系统提供 `mkfs.ext4`（Ubuntu 的 `e2fsprogs` 包）。

脚本列出磁盘、容量、文件系统、挂载点、型号和序列号，要求手动输入设备路径和挂载目录（默认 `/data`），选择只读或读写、是否保存开机挂载，最后输入 `MOUNT` 才执行。确认输入始终从 `/dev/tty` 读取，管道执行也需要手动确认。设备不会自动选择；不支持无人值守模式。

默认只读，ext4 使用 `ro,noload`，XFS 使用 `ro,norecovery`，避免回放日志；只读开机挂载也不会安排 fsck。需要安装软件或写入数据时，应明确选择 `rw`。挂载目录属主不自动改变。

已有 ext4/XFS 直接复用，不重格式化；其他已识别的文件系统会报错。未识别文件系统的设备还必须通过 `wipefs --no-act` 只读签名检查，检测到分区表或残留签名就停止。对未检测到签名的新盘，先确认设备和目录，再单独完整输入 `FORMAT /dev/实际设备名` 才会创建 ext4；默认取消，输入 `y` 或其他设备名均无效。**格式化会覆盖所选设备上的原数据，未检测到签名不代表盘上没有数据。** 格式化确认后重新检查设备身份、系统盘、挂载状态、目录和签名，检查失败时不执行格式化。

脚本不分区、不擦除签名、不删除用户文件、不卸载设备。系统盘及其分区、已挂载/含 swap 的设备、LVM/RAID、只读设备、非空挂载目录均拒绝操作。开机配置按 UUID 写入 `/etc/fstab`；现有冲突条目在格式化前拦截，写入前备份、验证候选文件并原子替换。若格式化之后的步骤失败，新文件系统可能已创建，不会自动回滚或再次格式化；若写入开机配置失败，当前挂载可能已成功，可用 `findmnt /data` 检查。

测试只使用合成磁盘信息和临时文件，不执行真实磁盘操作：

```bash
python3 disk/test_mount_data.py
```
