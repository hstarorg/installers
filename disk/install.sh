#!/usr/bin/env bash
#
# Interactively select, initialize (only after explicit consent), and mount
# a data disk on a single Linux machine.
#
# This script is self-contained. Python safety checks are embedded below;
# no helper script or Python package is downloaded.
#
# Usage:
#   sudo bash disk/install.sh
#   curl -fsSL https://raw.githubusercontent.com/hstarorg/installers/main/disk/install.sh | sudo bash
#
# Disk selection, target directory and formatting always require a terminal.
# There is no unattended mode or automatic disk selection.

set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: sudo bash disk/install.sh

Interactive data-disk mounting:
  - Select the device and mount directory (default /data).
  - Choose read-only/read-write and whether to persist in /etc/fstab.
  - Type MOUNT to confirm the plan.
  - New disks require an additional FORMAT /dev/actual-device confirmation.
  - Existing ext4/XFS filesystems are reused; system disks are rejected.

Requires Linux, root, Python >=3.10, util-linux, systemd.
Initializing a new disk also requires e2fsprogs (mkfs.ext4).
USAGE
}

fail() {
    printf '[disk-install] ERROR: %s\n' "$*" >&2
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail "Unknown argument: $1; use --help."
            ;;
    esac
done

[[ "$(uname -s)" == Linux ]] || fail "Only Linux is supported."
[[ "${EUID:-$(id -u)}" -eq 0 ]] || fail "Run as root (for example: sudo bash disk/install.sh)."
command -v python3 >/dev/null 2>&1 || fail "Python >=3.10 is required."
python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' \
    || fail "Python >=3.10 is required."

# Prompts read /dev/tty, so curl | sudo bash keeps its interactive confirmations.
exec python3 - <<'MOUNT_DATA_PYTHON'
#!/usr/bin/env python3
"""Interactively mount a data disk on Ubuntu; no device is selected automatically."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from datetime import datetime


class MountError(Exception):
    pass


class Cancelled(Exception):
    pass


def run(*args, check=True):
    result = subprocess.run(args, text=True, capture_output=True)
    if check and result.returncode:
        raise MountError(f"命令失败：{' '.join(args)}\n{result.stderr.strip()}")
    return result


def ask(tty, prompt):
    tty.write(prompt.encode('utf-8'))
    tty.flush()
    line = tty.readline()
    if not line:
        raise Cancelled()
    return line.decode('utf-8').strip()


def disk_index(tree):
    nodes, links = {}, {}

    def visit(node, parent=None):
        name = os.path.realpath(node['name'])
        nodes[name] = node
        links.setdefault(name, set())
        if parent:
            links[name].add(parent)
            links[parent].add(name)
        for child in node.get('children', []):
            visit(child, name)

    for node in tree['blockdevices']:
        visit(node)
    return nodes, links


def component(name, links):
    found, pending = set(), [name]
    while pending:
        current = pending.pop()
        if current not in found:
            found.add(current)
            pending.extend(links[current] - found)
    return found


def validate_device(tree, selected, root_id):
    nodes, links = disk_index(tree)
    if not any(n.get('maj:min') == root_id for n in nodes.values()):
        raise MountError('无法定位系统根文件系统所在的块设备，停止操作')
    selected = os.path.realpath(selected)
    if selected not in nodes:
        raise MountError('设备不在 lsblk 列表中，请输入 /dev/... 或 /dev/disk/by-id/... 路径')
    related = component(selected, links)
    if any(nodes[n].get('maj:min') == root_id for n in related):
        raise MountError('所选设备属于系统盘，禁止操作')
    if any(any(p for p in nodes[n].get('mountpoints') or []) for n in related):
        raise MountError('所选设备或同一磁盘上的其他设备已挂载/用作 swap，停止操作')
    if any(nodes[n].get('fstype') == 'swap' for n in related):
        raise MountError('所选磁盘包含 swap，停止操作')
    node = nodes[selected]
    if node.get('type') not in ('disk', 'part') or node.get('children'):
        raise MountError('请选择没有下级设备的磁盘或具体分区；不会覆盖分区表、LVM 或 RAID')
    if node.get('ro') in (True, 1, '1'):
        raise MountError('所选设备为只读设备')
    return node


def validate_target(value):
    if not value.startswith('/') or not re.fullmatch(r'/[A-Za-z0-9_./-]+', value):
        raise MountError('挂载目录需为绝对路径，仅支持英文字母、数字、点、下划线、连字符和 /')
    target = Path(value).resolve()
    if target == Path('/'):
        raise MountError('不能挂载到系统根目录')
    if target.exists():
        if not target.is_dir():
            raise MountError('挂载位置已经是一个文件')
        if os.path.ismount(target):
            raise MountError('该目录已经是挂载点')
        if any(target.iterdir()):
            raise MountError('该目录非空；为避免隐藏已有文件，停止操作')
    return str(target)


def mount_options(filesystem, mode):
    if mode == 'rw':
        return 'defaults'
    return 'ro,noload' if filesystem == 'ext4' else 'ro,norecovery'


def filesystem_plan(info, signatures=None):
    filesystem = info.get('TYPE', '')
    if filesystem in ('ext4', 'xfs'):
        return filesystem, False
    if filesystem:
        raise MountError(f'当前文件系统为 {filesystem}；不会自动重格式化已有文件系统')
    if info.get('PTTYPE') or info.get('PTUUID'):
        raise MountError('检测到分区表，不能按新盘格式化；请选择具体分区')
    if not isinstance(signatures, dict) or not isinstance(signatures.get('signatures'), list):
        raise MountError('缺少可靠的磁盘签名检查，停止操作')
    if signatures['signatures']:
        raise MountError('检测到分区表或残留签名，停止操作；不会自动擦除')
    return 'ext4', True


def confirm_plan(tty, device, target, filesystem, mode, persist, initialize=False):
    print('\n即将执行：')
    print(f'  设备：{device}')
    print(f'  目录：{target}')
    print(f'  文件系统：{filesystem}')
    print('  文件系统处理：' + ('新建 ext4，格式化会覆盖所选设备上的原数据' if initialize else '复用现有文件系统，不格式化'))
    print(f'  挂载模式：{"只读，不回放文件系统日志" if mode == "ro" else "读写，供应用正常写入"}')
    print(f'  开机挂载：{"是，备份并更新 /etc/fstab" if persist else "否"}')
    if ask(tty, '确认设备和目录后，输入 MOUNT 继续，其他输入取消：') != 'MOUNT':
        raise Cancelled()


def format_new_filesystem(tty, device, revalidate):
    phrase = f'FORMAT {device}'
    print('\n未检测到文件系统签名不代表盘上没有数据。格式化会覆盖所选设备上的原数据。')
    if ask(tty, f'确认此设备可格式化，请完整输入 {phrase}（其他输入取消）：') != phrase:
        raise Cancelled()
    revalidate()  # Check system disk, mounts, identity, target and signatures again.
    print('正在为确认的设备创建 ext4：', device, flush=True)
    run('mkfs.ext4', '-F', '-m', '0', device)


def unescape_fstab(value):
    return re.sub(r'\\([0-7]{3})', lambda m: chr(int(m.group(1), 8)), value)


def fstab_update(contents, device, target, filesystem, tags, mode, preformat=False):
    """Return candidate text; reject conflicting entries instead of replacing them."""
    matched = False
    for raw in contents.splitlines():
        fields = raw.split()
        if not fields or fields[0].startswith('#'):
            continue
        if len(fields) < 4:
            raise MountError('现有 /etc/fstab 含无法解析的条目，请先检查')
        spec, destination, kind = map(unescape_fstab, fields[:3])
        same_device = (
            spec.startswith('/dev/') and os.path.realpath(spec) == device
        ) or any(value and spec == f'{key}={value}' for key, value in tags.items())
        if os.path.normpath(destination) == target:
            if preformat:
                raise MountError(f'/etc/fstab 已包含挂载目录 {target}，格式化前停止操作')
            options = set(fields[3].split(','))
            mode_matches = ('ro' in options) == (mode == 'ro')
            if mode == 'ro':
                mode_matches = mode_matches and (
                    ('noload' if filesystem == 'ext4' else 'norecovery') in options
                ) and len(fields) >= 6 and fields[5] == '0'
            if same_device and kind == filesystem and mode_matches and not matched:
                matched = True
                continue
            raise MountError(f'/etc/fstab 已包含挂载目录 {target}，不会覆盖该条目')
        if same_device:
            raise MountError(f'该设备已在 /etc/fstab 配置到 {destination}，不会自动改变它')
    if matched:
        return contents
    if preformat:
        return contents  # A new UUID is obtained only after explicit formatting consent.
    uuid = tags.get('UUID', '')
    if not re.fullmatch(r'[A-Za-z0-9-]+', uuid):
        raise MountError('无法取得安全有效的文件系统 UUID')
    pass_number = 2 if filesystem == 'ext4' and mode == 'rw' else 0
    options = mount_options(filesystem, mode) + ',nofail'
    return contents.rstrip('\n') + f'\nUUID={uuid} {target} {filesystem} {options} 0 {pass_number}\n'


def probe(device):
    result = run('blkid', '-p', '-o', 'export', device, check=False)
    if result.returncode not in (0, 2):
        raise MountError(f'无法可靠识别设备签名：{result.stderr.strip()}')
    return dict(line.split('=', 1) for line in result.stdout.splitlines() if '=' in line)


def snapshot():
    tree = json.loads(run(
        'lsblk', '--json', '--paths', '--bytes', '--output',
        'NAME,TYPE,SIZE,FSTYPE,UUID,MOUNTPOINTS,MODEL,SERIAL,MAJ:MIN,RO',
    ).stdout)
    root_id = run('findmnt', '--noheadings', '--output', 'MAJ:MIN', '--target', '/').stdout.strip()
    return tree, root_id


def write_fstab(original, candidate, path=Path('/etc/fstab')):
    if path.is_symlink():
        raise MountError('fstab 是符号链接，停止写入')
    if path.read_text() != original:
        raise MountError('/etc/fstab 在确认期间发生变化，当前磁盘已挂载，请重新检查开机挂载配置')
    if candidate == original:
        print('沿用已有 /etc/fstab 条目。')
        return
    backup = path.with_name('fstab.before-mount-data-' + datetime.now().strftime('%Y%m%d-%H%M%S-%f'))
    shutil.copy2(path, backup)
    metadata = path.stat()
    fd, temporary = tempfile.mkstemp(prefix='.fstab.mount-data-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            stream.write(candidate)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, stat.S_IMODE(metadata.st_mode))
        os.chown(temporary, metadata.st_uid, metadata.st_gid)
        run('findmnt', '--verify', '--tab-file', temporary)
        if path.read_text() != original:
            raise MountError('fstab 在验证期间发生变化，停止替换；原文件保持不变')
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    print('fstab 备份：', backup)
    run('systemctl', 'daemon-reload')


def main():
    parser = argparse.ArgumentParser(prog='disk/install.sh', description='交互选择磁盘与目录，确认后挂载；需要 root 和真实终端')
    parser.parse_args()
    if sys.platform != 'linux' or os.geteuid() != 0:
        raise MountError('请在 Linux 服务器以 sudo bash disk/install.sh 执行')
    required = ['lsblk', 'findmnt', 'blkid', 'wipefs', 'mount', 'systemctl']
    for command in required:
        if not shutil.which(command):
            raise MountError(f'缺少 {command}；请检查 Ubuntu 的 util-linux/systemd 安装')
    try:
        tty = open('/dev/tty', 'r+b', buffering=0)
    except OSError:
        raise MountError('需要交互终端；请通过 SSH 登录后执行，不支持无人值守运行') from None
    with tty, open('/run/lock/mount-data.lock', 'w') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise MountError('另一个挂载脚本正在运行') from None
        print(run('lsblk', '--paths', '--output', 'NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL,SERIAL').stdout)
        selected = ask(tty, '请输入要挂载的完整设备路径（例如 /dev/disk/by-id/google-data-disk；q 取消）：')
        if selected.lower() in ('q', 'quit', ''):
            raise Cancelled()
        device = os.path.realpath(selected)
        if not device.startswith('/dev/') or not Path(device).is_block_device():
            raise MountError('请选择有效的 /dev/ 块设备')
        tree, root_id = snapshot()
        node = validate_device(tree, device, root_id)
        print(f"所选设备：{device}，容量 {int(node['size']) / 2**30:.1f} GiB，型号 {node.get('model') or '-'}，序列号 {node.get('serial') or '-'}")
        info = probe(device)
        signatures = None
        if not info.get('TYPE'):
            signatures = json.loads(run('wipefs', '--no-act', '--json', device).stdout)
        filesystem, initialize = filesystem_plan(info, signatures)
        if initialize and not shutil.which('mkfs.ext4'):
            raise MountError('新盘初始化需要 mkfs.ext4；请先安装 e2fsprogs')
        target = validate_target(ask(tty, '请输入挂载目录 [默认 /data]：') or '/data')
        mode = ask(tty, '挂载模式 ro=只读 / rw=读写（安装 ComfyUI 需选 rw）[默认 ro]：').lower() or 'ro'
        if mode not in ('ro', 'rw'):
            raise MountError('挂载模式只能是 ro 或 rw')
        choice = ask(tty, '是否配置开机自动挂载？[Y/n]：').lower()
        if choice not in ('', 'y', 'yes', 'n', 'no'):
            raise MountError('请输入 y 或 n')
        persist = choice not in ('n', 'no')
        tags = {'UUID': info.get('UUID', ''), 'LABEL': info.get('LABEL', ''), 'PARTUUID': info.get('PART_ENTRY_UUID', '')}
        if persist and Path('/etc/fstab').is_symlink():
            raise MountError('/etc/fstab 是符号链接，请手动管理开机挂载配置，或选择不写入 fstab')
        original = Path('/etc/fstab').read_text() if persist else ''
        if persist:
            candidate = fstab_update(original, device, target, filesystem, tags, mode, preformat=initialize)
        confirm_plan(tty, device, target, filesystem, mode, persist, initialize=initialize)

        # Revalidate after user input, before any device or mount changes.
        def revalidate():
            fresh_tree, fresh_root = snapshot()
            fresh = validate_device(fresh_tree, device, fresh_root)
            if any(fresh.get(key) != node.get(key) for key in ('maj:min', 'size', 'serial')):
                raise MountError('设备信息发生变化，停止操作')
            if validate_target(target) != target:
                raise MountError('挂载目录的解析路径发生变化，停止操作')
            if run('findmnt', '--mountpoint', target, check=False).returncode == 0:
                raise MountError('目标目录已被挂载，停止操作')
            if probe(device) != info:
                raise MountError('磁盘签名在确认期间发生变化，停止操作')
            if initialize and not info.get('TYPE'):
                fresh_signatures = json.loads(run('wipefs', '--no-act', '--json', device).stdout)
                filesystem_plan(info, fresh_signatures)
            if persist and Path('/etc/fstab').read_text() != original:
                raise MountError('fstab 在确认期间发生变化，停止操作')

        if initialize:
            format_new_filesystem(tty, device, revalidate)
            info = probe(device)
            if info.get('TYPE') != 'ext4' or not info.get('UUID'):
                raise MountError('格式化后无法确认 ext4/UUID，停止挂载；不要盲目重试格式化')
            tags = {'UUID': info['UUID'], 'LABEL': info.get('LABEL', ''), 'PARTUUID': info.get('PART_ENTRY_UUID', '')}
            if persist:
                candidate = fstab_update(original, device, target, filesystem, tags, mode)
        revalidate()
        if persist:
            matches = run('blkid', '-c', '/dev/null', '-t', f"UUID={tags['UUID']}", '-o', 'device').stdout.splitlines()
            if {os.path.realpath(p) for p in matches} != {device}:
                raise MountError('UUID 不唯一或无法定位，停止挂载')
        Path(target).mkdir(parents=True, exist_ok=True)
        run('mount', '-t', filesystem, '-o', mount_options(filesystem, mode), device, target)
        print('磁盘已挂载：', device, '→', target)
        if persist:
            write_fstab(original, candidate)
        print(run('findmnt', '--mountpoint', target).stdout)
        print(run('df', '-h', target).stdout)
        print('完成。挂载目录属主保持不变；后续安装器可在其中创建属于你的应用目录。')


if __name__ == '__main__':
    try:
        main()
    except (Cancelled, KeyboardInterrupt):
        print('\n已取消。')
        sys.exit(1)
    except (MountError, OSError, ValueError) as exc:
        print(f'\n错误：{exc}', file=sys.stderr)
        sys.exit(1)
MOUNT_DATA_PYTHON
