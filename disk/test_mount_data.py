#!/usr/bin/env python3
"""Safety checks use synthetic metadata only; no real disk is mounted or modified."""
import contextlib
import ast
import copy
import io
import os
from pathlib import Path
import pty
import sys
import subprocess
import tempfile
import types
import unittest
from unittest.mock import patch


sys.dont_write_bytecode = True
INSTALLER = Path(__file__).with_name('install.sh')
WRAPPER = INSTALLER.read_text()
PYTHON_SOURCE = WRAPPER.split("<<'MOUNT_DATA_PYTHON'\n", 1)[1].rsplit('\nMOUNT_DATA_PYTHON', 1)[0]
m = types.ModuleType('mount_data')
m.__file__ = str(INSTALLER)
exec(compile(PYTHON_SOURCE, str(INSTALLER) + ':python', 'exec'), m.__dict__)


def node(name, kind, major, **values):
    return dict(name=name, type=kind, size=100 * 2**30,
                **{'maj:min': major, 'mountpoints': values.pop('mountpoints', [None])},
                **values)


TREE = {'blockdevices': [
    node('/dev/sda', 'disk', '8:0', children=[
        node('/dev/sda1', 'part', '8:1', mountpoints=['/']),
        node('/dev/sda2', 'part', '8:2', mountpoints=['/boot/efi']),
        node('/dev/sda3', 'part', '8:3'),
    ]),
    node('/dev/nvme0n2', 'disk', '259:2', fstype='ext4', ro=False),
    node('/dev/nvme0n3', 'disk', '259:3', children=[
        node('/dev/nvme0n3p1', 'part', '259:4', fstype='xfs'),
        node('/dev/nvme0n3p2', 'part', '259:5'),
    ]),
]}


class Terminal:
    def __init__(self, text):
        self.input = io.BytesIO(text.encode())
        self.output = io.BytesIO()

    def readline(self):
        return self.input.readline()

    def write(self, value):
        return self.output.write(value)

    def flush(self):
        pass


class DiskSafetyTests(unittest.TestCase):
    def setUp(self):
        self.tree = copy.deepcopy(TREE)

    def test_root_disk_and_all_its_partitions_are_rejected(self):
        for name in ['/dev/sda', '/dev/sda1', '/dev/sda2', '/dev/sda3']:
            with self.subTest(name=name), self.assertRaisesRegex(m.MountError, '系统盘'):
                m.validate_device(self.tree, name, '8:1')

    def test_unknown_root_or_device_is_rejected(self):
        with self.assertRaisesRegex(m.MountError, '无法定位'):
            m.validate_device(self.tree, '/dev/nvme0n2', '99:99')
        with self.assertRaisesRegex(m.MountError, '设备不在'):
            m.validate_device(self.tree, '/dev/unknown', '8:1')

    def test_data_disk_and_leaf_partition_are_allowed(self):
        self.assertEqual(m.validate_device(self.tree, '/dev/nvme0n2', '8:1')['type'], 'disk')
        self.assertEqual(m.validate_device(self.tree, '/dev/nvme0n3p1', '8:1')['type'], 'part')

    def test_partitioned_whole_disk_is_rejected(self):
        with self.assertRaisesRegex(m.MountError, '具体分区'):
            m.validate_device(self.tree, '/dev/nvme0n3', '8:1')

    def test_mounted_disk_or_sibling_blocks_selection(self):
        self.tree['blockdevices'][1]['mountpoints'] = ['/other']
        with self.assertRaisesRegex(m.MountError, '已挂载'):
            m.validate_device(self.tree, '/dev/nvme0n2', '8:1')
        self.tree['blockdevices'][2]['children'][1]['mountpoints'] = ['/busy']
        with self.assertRaisesRegex(m.MountError, '已挂载'):
            m.validate_device(self.tree, '/dev/nvme0n3p1', '8:1')

    def test_swap_readonly_and_device_mapper_are_rejected(self):
        self.tree['blockdevices'][1]['fstype'] = 'swap'
        with self.assertRaisesRegex(m.MountError, 'swap'):
            m.validate_device(self.tree, '/dev/nvme0n2', '8:1')
        self.tree['blockdevices'][1]['fstype'] = 'ext4'
        self.tree['blockdevices'][1]['ro'] = True
        with self.assertRaisesRegex(m.MountError, '只读设备'):
            m.validate_device(self.tree, '/dev/nvme0n2', '8:1')
        self.tree['blockdevices'][1]['ro'] = False
        self.tree['blockdevices'][1]['type'] = 'lvm'
        with self.assertRaisesRegex(m.MountError, 'LVM'):
            m.validate_device(self.tree, '/dev/nvme0n2', '8:1')

    def test_existing_filesystem_is_reused_not_reformatted(self):
        self.assertEqual(m.filesystem_plan({'TYPE': 'ext4'}), ('ext4', False))
        self.assertEqual(m.filesystem_plan({'TYPE': 'xfs'}), ('xfs', False))

    def test_unsupported_filesystem_is_not_overwritten(self):
        for info in [{'TYPE': 'crypto_LUKS'}, {'TYPE': 'swap'}, {'TYPE': 'btrfs'}]:
            with self.subTest(info=info), self.assertRaisesRegex(m.MountError, '不会自动重格式化'):
                m.filesystem_plan(info, {'signatures': []})

    def test_new_disk_requires_clean_reliable_signature_scan(self):
        self.assertEqual(m.filesystem_plan({}, {'signatures': []}), ('ext4', True))
        for signatures in [None, {}, [], {'signatures': None}, {'signatures': [{'type': 'gpt'}]}]:
            with self.subTest(signatures=signatures), self.assertRaises(m.MountError):
                m.filesystem_plan({}, signatures)

    def test_partition_table_is_never_overwritten(self):
        for info in [{'PTTYPE': 'gpt'}, {'PTUUID': 'existing-table'}]:
            with self.subTest(info=info), self.assertRaisesRegex(m.MountError, '分区表'):
                m.filesystem_plan(info, {'signatures': []})

    def test_nonempty_file_root_and_unsafe_targets_are_rejected(self):
        with tempfile.TemporaryDirectory() as path:
            target = Path(path)
            (target / 'existing-model').write_text('keep')
            for value in [str(target), str(target / 'existing-model'), '/', 'relative', '/bad path']:
                with self.subTest(value=value), self.assertRaises(m.MountError):
                    m.validate_target(value)
            self.assertEqual((target / 'existing-model').read_text(), 'keep')

    def test_missing_mount_directory_is_not_created_during_validation(self):
        with tempfile.TemporaryDirectory() as path:
            target = Path(path) / 'data'
            self.assertEqual(m.validate_target(str(target)), str(target.resolve()))
            self.assertFalse(target.exists())

    def test_only_exact_mount_confirmation_is_accepted(self):
        with contextlib.redirect_stdout(io.StringIO()):
            for text in ['\n', 'y\n', 'mount\n', 'no\n', '']:
                with self.subTest(text=text), self.assertRaises(m.Cancelled):
                    m.confirm_plan(Terminal(text), '/dev/nvme0n2', '/data', 'ext4', 'ro', True)
            m.confirm_plan(Terminal('MOUNT\n'), '/dev/nvme0n2', '/data', 'ext4', 'rw', True)

    def test_prompt_works_with_unbuffered_terminal_stream(self):
        master, slave = pty.openpty()
        try:
            with os.fdopen(os.dup(slave), 'r+b', buffering=0) as stream:
                os.write(master, b'MOUNT\n')
                self.assertEqual(m.ask(stream, 'confirm: '), 'MOUNT')
        finally:
            os.close(master)
            os.close(slave)

    def test_readonly_mount_disables_journal_replay(self):
        self.assertEqual(m.mount_options('ext4', 'ro'), 'ro,noload')
        self.assertEqual(m.mount_options('xfs', 'ro'), 'ro,norecovery')
        self.assertEqual(m.mount_options('ext4', 'rw'), 'defaults')

    def test_commands_never_partition_erase_or_unmount_and_format_is_isolated(self):
        tree = ast.parse(PYTHON_SOURCE)
        allowed = {'lsblk', 'findmnt', 'blkid', 'mount', 'df', 'systemctl', 'wipefs', 'mkfs.ext4'}
        formats = []
        for item in ast.walk(tree):
            if isinstance(item, ast.Call) and isinstance(item.func, ast.Name) and item.func.id == 'run':
                self.assertIsInstance(item.args[0], ast.Constant)
                self.assertIn(item.args[0].value, allowed)
                if item.args[0].value == 'wipefs':
                    self.assertEqual(item.args[1].value, '--no-act')
                if item.args[0].value == 'mkfs.ext4':
                    formats.append(item)
        self.assertEqual(len(formats), 1)
        helper = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == 'format_new_filesystem')
        self.assertIn(formats[0], list(ast.walk(helper)))

    def test_format_decline_or_wrong_device_never_runs_any_command(self):
        for text in ['', '\n', 'y\n', 'FORMAT /dev/sda\n', 'format /dev/nvme0n2\n']:
            with self.subTest(text=text), contextlib.redirect_stdout(io.StringIO()), patch.object(m, 'run') as command:
                revalidate = unittest.mock.Mock()
                with self.assertRaises(m.Cancelled):
                    m.format_new_filesystem(Terminal(text), '/dev/nvme0n2', revalidate)
                command.assert_not_called()
                revalidate.assert_not_called()

    def test_format_needs_exact_confirmation_then_revalidation(self):
        events = []
        with contextlib.redirect_stdout(io.StringIO()), patch.object(m, 'run', side_effect=lambda *args: events.append(args)):
            m.format_new_filesystem(Terminal('FORMAT /dev/nvme0n2\n'), '/dev/nvme0n2', lambda: events.append('revalidate'))
        self.assertEqual(events, ['revalidate', ('mkfs.ext4', '-F', '-m', '0', '/dev/nvme0n2')])

    def test_changed_state_after_confirmation_prevents_format(self):
        with contextlib.redirect_stdout(io.StringIO()), patch.object(m, 'run') as command:
            with self.assertRaisesRegex(m.MountError, '已挂载'):
                m.format_new_filesystem(
                    Terminal('FORMAT /dev/nvme0n2\n'), '/dev/nvme0n2',
                    unittest.mock.Mock(side_effect=m.MountError('设备已挂载')),
                )
            command.assert_not_called()


class FstabSafetyTests(unittest.TestCase):
    def update(self, text='', filesystem='ext4', mode='rw'):
        return m.fstab_update(text, '/dev/nvme0n2', '/data', filesystem, {'UUID': 'data-123'}, mode)

    def test_append_preserves_existing_entries(self):
        text = '# original\nUUID=root / ext4 defaults 0 1\n'
        updated = self.update(text)
        self.assertTrue(updated.startswith(text))
        self.assertIn('UUID=data-123 /data ext4 defaults,nofail 0 2\n', updated)

    def test_same_entry_is_preserved_without_duplicates(self):
        text = self.update()
        self.assertEqual(self.update(text), text)

    def test_conflicting_target_source_or_mode_is_rejected(self):
        for text in [
            'UUID=other /data ext4 defaults 0 2\n',
            'UUID=data-123 /other ext4 defaults 0 2\n',
            'UUID=data-123 /data xfs defaults 0 0\n',
            'UUID=data-123 /data ext4 ro,noload 0 0\n',
        ]:
            with self.subTest(text=text), self.assertRaises(m.MountError):
                self.update(text)

    def test_later_duplicate_conflict_is_not_hidden_by_matching_entry(self):
        with self.assertRaises(m.MountError):
            self.update(self.update() + 'UUID=other /data ext4 defaults 0 2\n')

    def test_readonly_fstab_does_not_schedule_fsck(self):
        for fs, options in [('ext4', 'ro,noload,nofail'), ('xfs', 'ro,norecovery,nofail')]:
            text = self.update(filesystem=fs, mode='ro')
            self.assertIn(f'{options} 0 0\n', text)
            self.assertEqual(self.update(text, filesystem=fs, mode='ro'), text)

    def test_invalid_uuid_or_malformed_fstab_is_rejected(self):
        with self.assertRaises(m.MountError):
            self.update('not-a-valid-entry\n')
        with self.assertRaises(m.MountError):
            m.fstab_update('', '/dev/nvme0n2', '/data', 'ext4', {'UUID': ''}, 'rw')

    def test_validation_failure_leaves_original_fstab_untouched(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'fstab'
            original = '# retain this configuration\n'
            path.write_text(original)
            with patch.object(m, 'run', side_effect=m.MountError('validation failed')):
                with self.assertRaises(m.MountError):
                    m.write_fstab(original, self.update(original), path=path)
            self.assertEqual(path.read_text(), original)
            self.assertEqual(len(list(path.parent.glob('fstab.before-mount-data-*'))), 1)
            self.assertFalse(list(path.parent.glob('.fstab.mount-data-*')))

    def test_fstab_success_preserves_backup_and_updates_only_after_validation(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'fstab'
            original = '# original\n'
            candidate = self.update(original)
            path.write_text(original)
            with patch.object(m, 'run') as command, contextlib.redirect_stdout(io.StringIO()):
                m.write_fstab(original, candidate, path=path)
            self.assertEqual(path.read_text(), candidate)
            backup = next(path.parent.glob('fstab.before-mount-data-*'))
            self.assertEqual(backup.read_text(), original)
            self.assertEqual(command.call_args_list[0].args[:2], ('findmnt', '--verify'))
            self.assertEqual(command.call_args_list[1].args, ('systemctl', 'daemon-reload'))

    def test_concurrent_fstab_change_is_not_overwritten(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'fstab'
            path.write_text('# changed by admin\n')
            with self.assertRaisesRegex(m.MountError, '发生变化'):
                m.write_fstab('# old\n', self.update(), path=path)
            self.assertEqual(path.read_text(), '# changed by admin\n')

    def test_preformat_fstab_check_does_not_need_or_write_uuid(self):
        text = '# original\n'
        self.assertEqual(m.fstab_update(text, '/dev/nvme0n2', '/data', 'ext4', {}, 'rw', preformat=True), text)

    def test_fstab_conflict_is_rejected_before_formatting(self):
        for text in ['UUID=other /data ext4 defaults 0 2\n', '/dev/nvme0n2 /other ext4 defaults 0 2\n']:
            with self.subTest(text=text), self.assertRaises(m.MountError):
                m.fstab_update(text, '/dev/nvme0n2', '/data', 'ext4', {}, 'rw', preformat=True)


class BashEntryTests(unittest.TestCase):
    def test_local_help_does_not_require_root_or_modify_disks(self):
        result = subprocess.run(['bash', str(INSTALLER), '--help'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('FORMAT /dev/actual-device', result.stdout)

    def test_piped_help_works_without_a_repository_checkout(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(
                ['bash', '-s', '--', '--help'], input=WRAPPER,
                cwd=directory, capture_output=True, text=True,
            )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Usage: sudo bash disk/install.sh', result.stdout)

    def test_unattended_flag_cannot_skip_confirmations(self):
        result = subprocess.run(['bash', str(INSTALLER), '--yes'], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Unknown argument', result.stderr)


if __name__ == '__main__':
    unittest.main(verbosity=2)
