#!/usr/bin/env python3
"""Offline installer tests: tiny synthetic files, no apt/pip, services or GPU."""
import copy
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import Mock, patch

sys.dont_write_bytecode = True
INSTALLER = Path(__file__).with_name('install.sh')
SOURCE = INSTALLER.read_text().split("<<'COMFYUI_INSTALLER_PYTHON'\n", 1)[1].rsplit('\nCOMFYUI_INSTALLER_PYTHON', 1)[0]
m = types.ModuleType('comfy_installer')
m.__file__ = str(INSTALLER)
exec(compile(SOURCE, str(INSTALLER) + ':python', 'exec'), m.__dict__)


class Response(io.BytesIO):
    pass


def response(data):
    return Response(json.dumps(data).encode())


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.parent = Path(self.temp.name).resolve()
        self.root = self.parent / 'ComfyUI'
        self.root.mkdir()
        self.state = self.root / '.comfyui-install'
        self.state.mkdir()
        self.content = b'small synthetic model\x00\x01'
        self.item = m.model('acestep', 'example/model', 'a' * 40, 'weight.safetensors',
                            'diffusion_models/weight.safetensors', len(self.content),
                            hashlib.sha256(self.content).hexdigest())
        self.receipts = {}
        mask = os.umask(0o022)
        os.umask(mask)
        self.addCleanup(os.umask, mask)

    def target(self):
        path = self.root / self.item['target']
        path.parent.mkdir(parents=True, exist_ok=True)
        return path

    def test_actual_baseline_and_fixed_manifest(self):
        self.assertEqual(m.PROFILE['comfyui_version'], '0.42.0')
        self.assertEqual(m.PROFILE['python'], '3.12.3')
        self.assertEqual(m.PROFILE['packages']['torch'], '2.14.1+cu130')
        self.assertEqual(m.PROFILE['packages']['comfyui-workflow-templates'], '0.11.89')
        self.assertEqual(len(m.MODELS), 14)
        self.assertEqual(len({item['target'] for item in m.MODELS}), 14)
        for item in m.MODELS:
            self.assertRegex(item['revision'], r'^[0-9a-f]{40}$')
            self.assertRegex(item['sha256'], r'^[0-9a-f]{64}$')
            self.assertTrue(item['target'].startswith('models/'))
            self.assertGreater(item['size'], 0)
        targets = {item['target'] for item in m.MODELS}
        self.assertIn('models/diffusion_models/qwen-image-2.1-UC-fp8.safetensors', targets)
        self.assertIn('models/text_encoders/qwen3vl_32b_heretic_minimax_h3_nvfp4.safetensors', targets)
        self.assertIn('models/text_encoders/qwen_4b_ace15.safetensors', targets)
        self.assertFalse(any('aio' in item or 'xl_sft' in item for item in targets))

    def test_only_selected_component_files(self):
        self.assertEqual(m.selected_models(['comfyui']), [])
        self.assertEqual(len(m.selected_models(['h3'])), 5)
        self.assertEqual(len(m.selected_models(['qwen-image'])), 5)
        self.assertEqual(len(m.selected_models(['acestep'])), 4)
        self.assertEqual(m.parse_components('acestep,h3,h3'), ['h3', 'acestep'])
        with self.assertRaises(m.InstallError):
            m.parse_components('h3,unknown')

    def test_data_directory_default_never_falls_back_to_home(self):
        data = self.parent / 'data'
        with self.assertRaisesRegex(m.InstallError, '不存在'):
            m.resolve_directory(None, data)
        self.assertFalse(data.exists())
        data.mkdir()
        with patch.object(m.os.path, 'ismount', return_value=False):
            with self.assertRaisesRegex(m.InstallError, '未挂载'):
                m.resolve_directory(None, data)
        with patch.object(m.os.path, 'ismount', return_value=True):
            self.assertEqual(m.resolve_directory(None, data), data / 'ComfyUI')

    def test_explicit_directory_and_symlink_mount_guard(self):
        data = self.parent / 'data'
        data.mkdir()
        alias = self.parent / 'alias'
        alias.symlink_to(data, target_is_directory=True)
        with patch.object(m.os.path, 'ismount', return_value=False):
            self.assertEqual(m.resolve_directory(str(self.root), data), self.root)
            with self.assertRaisesRegex(m.InstallError, '未挂载'):
                m.resolve_directory(str(alias / 'ComfyUI'), data)
        for value in ('/', 'relative', '/tmp/with space', '/tmp/a\nb'):
            with self.subTest(value=value), self.assertRaises(m.InstallError):
                m.resolve_directory(value, data)

    def test_paths_cannot_escape_root(self):
        (self.root / 'outside').symlink_to(self.parent)
        for value in ('../escape', 'outside/escape'):
            with self.subTest(value=value), self.assertRaises(m.InstallError):
                m.safe_path(self.root, value)

    def test_complete_model_reused_and_receipt_caches_verified_bytes(self):
        target = self.target()
        target.write_bytes(self.content)
        with patch.object(m, 'digest', wraps=m.digest) as hasher:
            self.assertTrue(m.verified(target, self.item, self.receipts))
            self.assertTrue(m.verified(target, self.item, self.receipts))
            self.assertEqual(hasher.call_count, 1)
            self.assertTrue(m.verified(target, self.item, self.receipts, force=True))
            self.assertEqual(hasher.call_count, 2)
        with patch.object(m, 'curl_download') as download:
            self.assertFalse(m.download_model(self.root, self.item, self.receipts, self.state))
            download.assert_not_called()

    def test_changed_same_size_file_is_not_trusted(self):
        target = self.target()
        target.write_bytes(self.content)
        m.verified(target, self.item, self.receipts)
        target.write_bytes(b'x' * len(self.content))
        with self.assertRaisesRegex(m.InstallError, '校验不符'):
            m.verified(target, self.item, self.receipts)
        self.assertEqual(target.read_bytes(), b'x' * len(self.content))

    def test_existing_wrong_size_is_never_overwritten(self):
        target = self.target()
        target.write_bytes(b'user file')
        with patch.object(m, 'curl_download') as download, self.assertRaises(m.InstallError):
            m.download_model(self.root, self.item, self.receipts, self.state)
        self.assertEqual(target.read_bytes(), b'user file')
        download.assert_not_called()

    def test_partial_download_is_resumed_then_published_once(self):
        target = self.target()
        partial = target.with_name(target.name + '.part')
        partial.write_bytes(self.content[:5])
        self.assertEqual(m.missing_bytes(self.root, [self.item]), len(self.content) - 5)
        def download(url, path):
            self.assertIn('/resolve/' + 'a' * 40 + '/', url)
            self.assertEqual(path.read_bytes(), self.content[:5])
            with path.open('ab') as stream:
                stream.write(self.content[5:])
        with patch.object(m, 'curl_download', side_effect=download) as curl:
            self.assertTrue(m.download_model(self.root, self.item, self.receipts, self.state))
            self.assertFalse(m.download_model(self.root, self.item, self.receipts, self.state))
            self.assertEqual(curl.call_count, 1)
        self.assertEqual(target.read_bytes(), self.content)
        self.assertFalse(partial.exists())

    def test_completed_partial_needs_no_network(self):
        target = self.target()
        target.with_name(target.name + '.part').write_bytes(self.content)
        with patch.object(m, 'curl_download') as curl:
            m.download_model(self.root, self.item, self.receipts, self.state)
            curl.assert_not_called()
        self.assertEqual(target.read_bytes(), self.content)

    def test_corrupt_download_never_published(self):
        target = self.target()
        def download(url, path):
            path.write_bytes(b'x' * len(self.content))
        with patch.object(m, 'curl_download', side_effect=download), self.assertRaises(m.InstallError):
            m.download_model(self.root, self.item, self.receipts, self.state)
        self.assertFalse(target.exists())
        self.assertTrue(target.with_name(target.name + '.part').exists())

    def test_concurrent_file_creation_is_not_overwritten(self):
        target = self.target()
        def download(url, path):
            path.write_bytes(self.content)
            target.write_bytes(b'created by another user')
        with patch.object(m, 'curl_download', side_effect=download), self.assertRaises(m.InstallError):
            m.download_model(self.root, self.item, self.receipts, self.state)
        self.assertEqual(target.read_bytes(), b'created by another user')

    def test_token_is_not_in_command_arguments_or_urls(self):
        fake_token = 'hf_test_only_do_not_use'
        with patch.dict(os.environ, HF_TOKEN=fake_token), patch.object(m, 'run') as runner:
            m.curl_download('https://huggingface.co/example/model/resolve/' + 'a'*40 + '/file', self.parent / 'part')
            command = runner.call_args.args[0]
            self.assertEqual(command[:2], ['curl', '-q'])
            self.assertNotIn(fake_token, ' '.join(map(str, command)))
            self.assertIn(fake_token, runner.call_args.kwargs['input'])
            m.curl_download('https://raw.githubusercontent.com/example/file', self.parent / 'part')
            self.assertEqual(runner.call_args.kwargs['input'], '')

    def test_nested_workflow_uses_actual_model_and_keeps_links(self):
        original = {'nodes': [{'type':'subgraph', 'inputs':[{'link':7}], 'widgets_values':[
            'qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors', 'minimax_h3_video_vae_int8_convrot.safetensors']}],
            'definitions': {'nodes':[{'properties': {'models': [{
                'name': 'qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors',
                'url':'https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors'}]}}]}}
        result = m.patch_workflow(original, 'h3')
        self.assertEqual(result['nodes'][0]['inputs'], [{'link':7}])
        self.assertEqual(result['nodes'][0]['widgets_values'][0], 'qwen3vl_32b_heretic_minimax_h3_nvfp4.safetensors')
        self.assertEqual(result['nodes'][0]['widgets_values'][1], 'minimax_h3_video_vae_fp16.safetensors')
        self.assertIn('Momoking/', result['definitions']['nodes'][0]['properties']['models'][0]['url'])
        self.assertIn('awq', original['nodes'][0]['widgets_values'][0])

    def test_workflow_download_pinned_and_modified_user_file_preserved(self):
        data = {'nodes':[{'widgets_values':['qwen_image_2.1_int8_convrot.safetensors']}], 'links':[[1,2,3]]}
        raw = json.dumps(data).encode()
        workflow = dict(component='qwen-image', source='test.json', name='test.json', sha256=hashlib.sha256(raw).hexdigest())
        with patch.object(m, 'WORKFLOWS', [workflow]), patch.object(m.urllib.request, 'urlopen', return_value=Response(raw)) as fetch:
            self.assertTrue(m.install_workflows(self.root, ['qwen-image']))
            self.assertIn(m.TEMPLATE_COMMIT, fetch.call_args.args[0])
        target = self.root / 'user/default/workflows/test.json'
        self.assertEqual(json.loads(target.read_text())['nodes'][0]['widgets_values'], ['qwen-image-2.1-UC-fp8.safetensors'])
        target.write_text('my changed workflow')
        with patch.object(m, 'WORKFLOWS', [workflow]), patch.object(m.urllib.request, 'urlopen') as fetch:
            self.assertFalse(m.install_workflows(self.root, ['qwen-image']))
            fetch.assert_not_called()
        self.assertEqual(target.read_text(), 'my changed workflow')

    def test_failed_workflow_checksum_writes_nothing(self):
        workflow = dict(component='acestep', source='test.json', name='test.json', sha256='a'*64)
        with patch.object(m, 'WORKFLOWS', [workflow]), patch.object(m.urllib.request, 'urlopen', return_value=Response(b'{}')):
            with self.assertRaises(m.InstallError):
                m.install_workflows(self.root, ['acestep'])
        self.assertFalse((self.root / 'user').exists())

    def test_runtime_drift_fails_instead_of_running_pip(self):
        (self.root / 'comfyui_version.py').write_text('__version__ = "0.42.0"\n')
        actual = {'python':'3.12.3', 'packages':copy.deepcopy(m.PROFILE['packages'])}
        actual['packages']['torch'] = '2.15.0+cu130'
        with patch.object(m, 'environment', return_value=actual), patch.object(m, 'run') as runner:
            with self.assertRaisesRegex(m.InstallError, '版本不同'):
                m.verify_runtime(self.root, '/not/executed', m.PROFILE)
            runner.assert_not_called()

    def test_runtime_lock_validated_and_model_override_applied(self):
        saved = dict(schema=1, **copy.deepcopy(m.PROFILE))
        saved['models'] = {m.MODELS[0]['target']: {'size':12, 'sha256':'b'*64, 'revision':None}}
        target = self.parent / 'lock.json'
        target.write_text(json.dumps(saved))
        profile = m.load_profile(target)
        models = m.selected_models(['h3'], profile)
        self.assertEqual(models[0]['sha256'], 'b'*64)
        self.assertIsNone(models[0]['revision'])
        saved['packages']['invalid'] = '1.0 --index-url https://evil'
        target.write_text(json.dumps(saved))
        with self.assertRaises(m.InstallError):
            m.load_profile(target)

    def test_model_without_known_source_can_only_be_reused(self):
        unknown = dict(self.item, revision=None)
        with patch.object(m, 'curl_download') as curl, self.assertRaisesRegex(m.InstallError, '缺少可核实'):
            m.download_model(self.root, unknown, {}, self.state)
        curl.assert_not_called()
        self.target().write_bytes(self.content)
        self.assertFalse(m.download_model(self.root, unknown, {}, self.state))

    def test_snapshot_reads_actual_versions_and_hashes_without_service_actions(self):
        self.target().write_bytes(self.content)
        actual = {'python':'3.12.3', 'packages':{'torch':'2.14.1+cu130'}}
        with patch.object(m, 'MODELS', [self.item]), patch.object(m, 'environment', return_value=actual), \
                patch.object(m, 'run', side_effect=['c'*40, '']) as runner:
            saved = m.snapshot(self.root, '/not/executed', include_models=True)
        self.assertEqual(saved['comfyui_commit'], 'c'*40)
        self.assertEqual(saved['models'][self.item['target']]['sha256'], self.item['sha256'])
        self.assertFalse(saved['tracked_source_modified'])
        self.assertTrue(all(call.args[0][0] == 'git' for call in runner.call_args_list))

    def test_service_preserved_and_no_service_does_not_run_commands(self):
        info = dict(LoadState='loaded', ActiveState='active')
        args = types.SimpleNamespace(no_service=False, restart=False, service_name='comfyui.service', port=8188)
        with patch.object(m, 'run') as runner:
            m.configure_service(args, self.root, info, 'tester', '/home/tester')
            args.no_service = True
            m.configure_service(args, self.root, {'LoadState':'not-found'}, 'tester', '/home/tester')
            runner.assert_not_called()

    def test_wrong_service_directory_user_or_port_rejected(self):
        good = dict(LoadState='loaded', WorkingDirectory=str(self.root), User='tester',
                    ExecStart=f'{{ path={self.root}/.venv/bin/python ; argv[]={self.root}/.venv/bin/python main.py --listen 127.0.0.1 --port 8188 ; }}')
        m.check_service(good, self.root, 'tester', 8188)
        for change in ({'User':'other'}, {'WorkingDirectory':'/tmp/other'}, {'ExecStart':'python other.py'}):
            with self.assertRaises(m.InstallError):
                m.check_service(dict(good, **change), self.root, 'tester', 8188)
        with self.assertRaises(m.InstallError):
            m.check_service(good, self.root, 'tester', 8189)

    def test_busy_or_unknown_queue_prevents_restart(self):
        args = types.SimpleNamespace(no_service=False, restart=True, service_name='comfyui.service', port=8188)
        for data in ({'queue_running':[[1]],'queue_pending':[]}, {}, {'queue_running':[],'queue_pending':[[2]]},
                     {'queue_running':None,'queue_pending':[]}, {'queue_running':[],'queue_pending':{}}):
            with patch.object(m.urllib.request, 'urlopen', return_value=response(data)), patch.object(m, 'run') as runner:
                with self.assertRaises(m.InstallError):
                    m.configure_service(args, self.root, {'LoadState':'loaded','ActiveState':'active'}, 'tester', '/home/tester')
                runner.assert_not_called()
        with patch.object(m.urllib.request, 'urlopen', side_effect=OSError('offline')):
            with self.assertRaises(m.InstallError):
                m.require_idle(8188)

    def test_explicit_idle_restart_uses_existing_unit(self):
        args = types.SimpleNamespace(no_service=False, restart=True, service_name='comfyui.service', port=8188)
        with patch.object(m, 'require_idle') as idle, patch.object(m, 'run') as runner, \
                patch.object(m.urllib.request, 'urlopen', return_value=response({'system':{'comfyui_version':'0.42.0'}})), \
                patch.object(m, 'service_info', return_value={'ActiveState':'active'}):
            m.configure_service(args, self.root, {'LoadState':'loaded','ActiveState':'active'}, 'tester', '/home/tester')
        idle.assert_called_once_with(8188)
        self.assertEqual(runner.call_args.args[0], ['sudo','systemctl','restart','comfyui.service'])

    def test_source_copy_resumes_preserves_user_models_and_refuses_overwrite(self):
        stage = self.state / 'source'
        (stage / '.git').mkdir(parents=True)
        (stage / '.git/HEAD').write_text('synthetic')
        (stage / 'main.py').write_text('main')
        (stage / 'models').mkdir()
        (stage / 'models/README').write_text('model layout')
        self.target().write_bytes(self.content)
        (self.root / 'main.py').write_text('partial existing identical source')
        with self.assertRaises(m.InstallError):
            m.copy_checkout(stage, self.root)
        self.assertFalse((self.root / '.git').exists())
        self.assertEqual((self.root / 'main.py').read_text(), 'partial existing identical source')
        (self.root / 'main.py').write_text('main')
        m.copy_checkout(stage, self.root)
        self.assertTrue((self.root / '.git/HEAD').exists())
        self.assertEqual(self.target().read_bytes(), self.content)

    def test_new_runtime_installs_fixed_versions_and_resumes_after_pip_failure(self):
        calls = []
        interrupted = [False]
        def execute(command, **kwargs):
            command = [str(value) for value in command]
            calls.append(command)
            if command[:2] == ['git', 'init']:
                (Path(command[2]) / '.git').mkdir(parents=True)
            if command[0] == 'git' and 'checkout' in command:
                stage = Path(command[2])
                (stage / 'comfyui_version.py').write_text('__version__ = "0.42.0"')
                (stage / 'requirements.txt').write_text('comfyui-frontend-package==1.55.18\n')
                (stage / 'main.py').write_text('# synthetic source')
            if command[1:4] == ['-m', 'venv', str(self.root / '.venv')]:
                python = self.root / '.venv/bin/python'
                python.parent.mkdir(parents=True)
                python.write_text('synthetic interpreter; never execute')
            if '-m' in command and 'pip' in command and not interrupted[0]:
                interrupted[0] = True
                raise m.InstallError('simulated interrupted pip')
        saved = dict(schema=1, **copy.deepcopy(m.PROFILE))
        with patch.object(m, 'run', side_effect=execute), patch.object(m, 'safe_origin'), \
                patch.object(m, 'verify_runtime') as verify, patch.object(m, 'snapshot', return_value=saved):
            with self.assertRaisesRegex(m.InstallError, 'interrupted pip'):
                m.create_runtime(self.root, self.state, '/synthetic/python3.12', m.PROFILE)
            self.assertTrue((self.state / 'runtime-installing.json').exists())
            self.assertTrue((self.root / '.git').is_dir())
            python = m.create_runtime(self.root, self.state, '/synthetic/python3.12', m.PROFILE)
            verify.assert_called_once_with(self.root, python, m.PROFILE)
        self.assertFalse((self.state / 'runtime-installing.json').exists())
        self.assertEqual(sum(call[:2] == ['git', 'init'] for call in calls), 1)
        self.assertEqual(sum(call[1:3] == ['-m', 'venv'] for call in calls), 1)
        fetch = next(call for call in calls if 'fetch' in call)
        self.assertEqual(fetch[-1], m.PROFILE['comfyui_commit'])
        torch_calls = [call for call in calls if 'torch==2.14.1+cu130' in call]
        self.assertEqual(len(torch_calls), 2)
        self.assertTrue(all(m.TORCH_INDEX in call for call in torch_calls))
        self.assertFalse(any('torchaudio==' in value for call in calls for value in call))
        self.assertIn('comfyui-frontend-package==1.55.18', (self.state / 'constraints.txt').read_text())

    def test_first_service_creation_and_retry_after_enable_failure(self):
        args = types.SimpleNamespace(no_service=False, restart=False, service_name='comfyui.service', port=8188)
        identity = dict(service='comfyui.service', directory=str(self.root), port=8188)
        def execute(command, **kwargs):
            if 'enable' in command:
                raise m.InstallError('simulated enable failure')
        with patch.object(m, 'run', side_effect=execute) as runner:
            with self.assertRaisesRegex(m.InstallError, 'enable failure'):
                m.configure_service(args, self.root, {'LoadState':'not-found'}, 'tester', '/home/tester')
            unit = runner.call_args_list[0].kwargs['input']
            self.assertIn(f'RequiresMountsFor={self.root}', unit)
            self.assertIn('--listen 127.0.0.1 --port 8188', unit)
            self.assertEqual(json.loads((self.state / 'service-pending.json').read_text()), identity)
        with patch.object(m, 'run') as runner, \
                patch.object(m.urllib.request, 'urlopen', return_value=response({'system':{'comfyui_version':'0.42.0'}})), \
                patch.object(m, 'service_info', return_value={'ActiveState':'active'}):
            m.configure_service(args, self.root, {'LoadState':'loaded'}, 'tester', '/home/tester')
            self.assertIn(['sudo','systemctl','enable','--now','comfyui.service'],
                          [call.args[0] for call in runner.call_args_list])
        self.assertFalse((self.state / 'service-pending.json').exists())

    def test_preflight_hash_is_reused_after_lock_even_with_verify(self):
        self.target().write_bytes(self.content)
        python = self.root / '.venv/bin/python'
        python.parent.mkdir(parents=True)
        python.write_text('not executed')
        checked = (python, True, False, 'tester', '/home/tester', {'LoadState':'loaded'})
        with patch.object(m, 'MODELS', [self.item]), patch.object(m, 'WORKFLOWS', []), \
                patch.object(m, 'preflight', return_value=checked), patch.object(m, 'verify_runtime'), \
                patch.object(m, 'snapshot', return_value={}), patch.object(m, 'configure_service'), \
                patch.object(m, 'digest', wraps=m.digest) as hasher:
            m.main(['--components','acestep','--install-dir',str(self.root),'--verify'])
            self.assertEqual(hasher.call_count, 1)

    def test_repeated_model_only_install_never_touches_pip_or_existing_workflows(self):
        venv_python = self.root / '.venv/bin/python'
        venv_python.parent.mkdir(parents=True)
        venv_python.write_text('not executable: tests must never invoke this')
        preflight = (venv_python, True, False, 'tester', '/home/tester', {'LoadState':'loaded','ActiveState':'active'})
        saved = dict(schema=1, **copy.deepcopy(m.PROFILE), models={})
        def download(url, path): path.write_bytes(self.content)
        with patch.object(m, 'MODELS', [self.item]), patch.object(m, 'WORKFLOWS', []), \
                patch.object(m, 'preflight', return_value=preflight), patch.object(m, 'verify_runtime'), \
                patch.object(m, 'snapshot', return_value=saved), patch.object(m, 'configure_service') as service, \
                patch.object(m, 'create_runtime') as create, patch.object(m, 'run') as runner, \
                patch.object(m, 'curl_download', side_effect=download) as curl:
            args = ['--components','acestep','--install-dir',str(self.root),'--no-runtime']
            m.main(args)
            m.main(args)
            self.assertEqual(curl.call_count, 1)
            create.assert_not_called()
            runner.assert_not_called()
            self.assertTrue(all(call.args[0].restart is False for call in service.call_args_list))
        installed = json.loads((self.state / 'installed.json').read_text())
        self.assertEqual(installed['components'], ['acestep'])
        self.assertEqual(self.target().read_bytes(), self.content)

    def test_cli_plan_help_and_invalid_options_do_not_write(self):
        destination = self.parent / 'not-created'
        base = ['bash',str(INSTALLER)]
        result = subprocess.run(base+['--components','acestep','--install-dir',str(destination),'--plan'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        plan = json.loads(result.stdout)
        self.assertEqual(len(plan['models']), 4)
        self.assertEqual(plan['runtime']['packages']['torch'], '2.14.1+cu130')
        self.assertFalse(destination.exists())
        self.assertEqual(subprocess.run(base+['--help'],capture_output=True).returncode,0)
        self.assertEqual(subprocess.run(base+['--list'],capture_output=True).returncode,0)
        for args in (['--components','typo','--install-dir',str(destination),'--plan'], ['--port','0'], ['--no-service','--restart'], ['--install-dir']):
            with self.subTest(args=args):
                self.assertNotEqual(subprocess.run(base+args,capture_output=True).returncode,0)
        self.assertFalse(destination.exists())


if __name__ == '__main__':
    unittest.main(verbosity=2)
