#!/usr/bin/env bash
# ComfyUI + MiniMax H3 + Qwen Image 2.1 UC + ACE-Step 1.5 XL Turbo.
# Standalone entry: the Python standard-library installer is embedded below.
# Run as the SSH user. Without --components / --all, select from /dev/tty.
set -Eeuo pipefail
command -v python3 >/dev/null || { echo '需要 Python >=3.10。' >&2; exit 1; }
exec python3 - "$@" <<'COMFYUI_INSTALLER_PYTHON'
from __future__ import annotations

import argparse
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import pwd
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request

PROFILE = {
    'comfyui_version': '0.42.0',
    'comfyui_commit': '355cd6b14c92c19ac3188fe528e47a3f21ef5178',
    'python': '3.12.3',
    'packages': {
        'torch': '2.14.1+cu130',
        'comfyui-frontend-package': '1.55.18',
        'comfyui-workflow-templates': '0.11.89',
        'comfyui-embedded-docs': '0.5.14',
        'comfy-kitchen': '0.2.39',
        'comfy-aimdo': '0.5.6',
    },
}
COMPONENTS = ('comfyui', 'h3', 'qwen-image', 'acestep')
TITLES = {
    'comfyui': 'ComfyUI 0.42.0 / PyTorch 2.14.1+cu130',
    'h3': 'MiniMax H3 FP8 + Heretic NVFP4 + Turbo 8step v1.0',
    'qwen-image': 'Qwen Image 2.1 UC FP8 / Qwen3-VL 8B INT8',
    'acestep': 'ACE-Step 1.5 XL Turbo BF16 + 4B LM',
}
SOURCE = 'https://github.com/Comfy-Org/ComfyUI.git'
TORCH_INDEX = 'https://download.pytorch.org/whl/cu130'
TEMPLATE_COMMIT = '7d8ed32f0bf6b8d52129976535422d6f518fe463'

# Fixed repositories, commits, file names and SHA256 values. Never resolve "main"
# at installation time. These precisions match the user's existing workflows.
def model(component, repo, revision, file, target, size, sha256):
    return dict(component=component, repo=repo, revision=revision, file=file,
                target='models/' + target, size=size, sha256=sha256)


MODELS = [
    model('h3', 'Momoking/Qwen3-VL-32B-Heretic-MiniMax-H3-NVFP4',
          '0a9486d17cfb20c1a7abc97118c4d95910b9b1f4',
          'qwen3vl_32b_heretic_minimax_h3_nvfp4.safetensors',
          'text_encoders/qwen3vl_32b_heretic_minimax_h3_nvfp4.safetensors', 15683129587,
          'a166c7bbbe66a22065159e478335fee4a633c4a3e3bb34c8e8ac4cc91bf4996f'),
    model('h3', 'Comfy-Org/MiniMax-H3', 'e5eb578a89295337b8ff433a035929ce0279e0b6',
          'diffusion_models/minimax_h3_fl2va_pruned_fp8_scaled.safetensors',
          'diffusion_models/minimax_h3_fl2va_pruned_fp8_scaled.safetensors', 20958205608,
          '12944c1f7791637e7de12208aef04da82bd26b95271b1b47d817364315ade993'),
    model('h3', 'Comfy-Org/MiniMax-H3', 'e5eb578a89295337b8ff433a035929ce0279e0b6',
          'vae/minimax_h3_video_vae_fp16.safetensors', 'vae/minimax_h3_video_vae_fp16.safetensors', 5207808496,
          '7c1f131492e7eddacaac9069a61b81bdd39de5cc96561e677c5eab1cdce5e522'),
    model('h3', 'Comfy-Org/MiniMax-H3', 'e5eb578a89295337b8ff433a035929ce0279e0b6',
          'vae/minimax_h3_audio_vae_fp32.safetensors', 'vae/minimax_h3_audio_vae_fp32.safetensors', 605254808,
          '8e505d95dd1561d47abd43d4238fd40d9bb1ae9e147ed0a4cba778d76ae4db48'),
    model('h3', 'lightx2v/Minimax-h3-Turbo', '30f485ed874aa44c8183348ad361c5eabad318da',
          'minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors',
          'loras/minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors', 1956193000,
          '2339acdf19bfe123f46b971ea35d367a84adb85de43627e1eceafa5a5b2b111e'),
    model('qwen-image', 'abenzerps/Qwen-Image-2.1-Uncensored-Quantized',
          '7959e658915f52274897fb573ffeda49de8dc16b', 'qwen-image-2.1-UC-fp8.safetensors',
          'diffusion_models/qwen-image-2.1-UC-fp8.safetensors', 7116818183,
          '877b77290339986bca8f771aead381c7a5777347c27d252bbaa915f76667ab0b'),
    model('qwen-image', 'abenzerps/Qwen-Image-2.1-Uncensored-Quantized',
          '7959e658915f52274897fb573ffeda49de8dc16b', 'text_encoders/qwen3vl_8b_int8_convrot.safetensors',
          'text_encoders/qwen3vl_8b_int8_convrot.safetensors', 9350798360,
          '8bfd0f6e12abf2d2d697ecc888e5e90b0d6741d6708f05799f53afa560452e8f'),
    model('qwen-image', 'abenzerps/Qwen-Image-2.1-Uncensored-Quantized',
          '7959e658915f52274897fb573ffeda49de8dc16b', 'vae/qwen_image_2.1_vae_bf16.safetensors',
          'vae/qwen_image_2.1_vae_bf16.safetensors', 675509688,
          'bb21f7473051e1ac368515dd3f2e15cd44d7a11748ee8823e1ddca3e4876b7c9'),
    model('qwen-image', 'Comfy-Org/Qwen-Image-2.1', '0217efd1d9c9452e84f6448903d6e21bfa171ffd',
          'text_encoders/qwen3.5_9b_qwen_image_2.1_pe_t2i.int8_convrot.safetensors',
          'text_encoders/qwen3.5_9b_qwen_image_2.1_pe_t2i.int8_convrot.safetensors', 9471072252,
          '9182abae56fe05459840a86d22abd21f972061c92fce032630af680c8c5178d3'),
    model('qwen-image', 'Comfy-Org/Qwen-Image-2.1', '0217efd1d9c9452e84f6448903d6e21bfa171ffd',
          'text_encoders/qwen3.5_9b_qwen_image_2.1_pe_i2i.int8_convrot.safetensors',
          'text_encoders/qwen3.5_9b_qwen_image_2.1_pe_i2i.int8_convrot.safetensors', 9471072252,
          '32707d01b427e488af252b95c551989aad59f9fec611a694f5db6bde7f0f1f6c'),
    model('acestep', 'Comfy-Org/ace_step_1.5_ComfyUI_files', '6707deb277e9e0907fd9c14ce6b6f1d695c6a3fc',
          'split_files/diffusion_models/acestep_v1.5_xl_turbo_bf16.safetensors',
          'diffusion_models/acestep_v1.5_xl_turbo_bf16.safetensors', 9974719892,
          '86a1afb0a1f711f0e3304ff65d874df3ae6783db683dcf982513fb9b6d14ae71'),
    model('acestep', 'Comfy-Org/ace_step_1.5_ComfyUI_files', '6707deb277e9e0907fd9c14ce6b6f1d695c6a3fc',
          'split_files/text_encoders/qwen_0.6b_ace15.safetensors', 'text_encoders/qwen_0.6b_ace15.safetensors', 1191588248,
          'fd4590c82153b8ddb67e15a2e7aaa8afa8b83a858c8a9b82a4831063156aa7a7'),
    model('acestep', 'Comfy-Org/ace_step_1.5_ComfyUI_files', '6707deb277e9e0907fd9c14ce6b6f1d695c6a3fc',
          'split_files/text_encoders/qwen_4b_ace15.safetensors', 'text_encoders/qwen_4b_ace15.safetensors', 8379154232,
          'ffe5ffb855086c2ab55e467e9859fb01894781020a0376484dd19de166b79873'),
    model('acestep', 'Comfy-Org/ace_step_1.5_ComfyUI_files', '6707deb277e9e0907fd9c14ce6b6f1d695c6a3fc',
          'split_files/vae/ace_1.5_vae.safetensors', 'vae/ace_1.5_vae.safetensors', 337431732,
          '6de92e3a862acd287e08b024ac90f0783a8635451b728721a33ff03565bcb2bb'),
]
WORKFLOWS = [
    dict(component='h3', source='video_minimax_h3_t2v.json', name='MiniMax-H3-Heretic-T2V.json',
         sha256='8a5eb23b0dd2df9e99b6f7af9684e770f188feca820d241364b729e01dedf3b6'),
    dict(component='h3', source='video_minimax_h3_i2v.json', name='MiniMax-H3-Heretic-I2V.json',
         sha256='34ee39544808fd3b0dc8de9df082940d4d41c3771beb80d3988c1ea5531cec0d'),
    dict(component='qwen-image', source='image_qwen_image_2_1_t2i.json', name='Qwen-Image-2.1-UC-T2I.json',
         sha256='5f2b50eeaf27e56a45456681ad5319df1ae51243d9653ac3f92c7dc05d1e1503'),
    dict(component='qwen-image', source='image_qwen_image_2_1_image_edit.json', name='Qwen-Image-2.1-UC-Edit.json',
         sha256='c1e6551759de131f083a040da072ac6f032c3c8401ceca202412cd912897d0fc'),
    dict(component='acestep', source='audio_ace_step1_5_xl_turbo.json', name='ACE-Step-1.5-XL-Turbo-4B.json',
         sha256='5b0445de2e7ced8fc92cfacd897b31bba2e50bea07539a85bead92cdda358531'),
]


class InstallError(RuntimeError):
    pass


def fail(message):
    raise InstallError(message)


def log(message):
    print(f'[{time.strftime("%H:%M:%S")}] {message}', flush=True)


def run(command, *, cwd=None, capture=False, input=None, check=True, env=None):
    result = subprocess.run([str(x) for x in command], cwd=cwd, text=True,
                            input=input, capture_output=capture, env=env)
    if check and result.returncode:
        # Do not dump command input, environment, pip index credentials or tokens.
        fail(f'命令失败（退出码 {result.returncode}）：{Path(str(command[0])).name}')
    return result.stdout.strip() if capture else result


def canonical(name):
    return re.sub(r'[-_.]+', '-', name).lower()


def parse_components(value):
    selected = set(re.split(r'[,\s]+', value.strip())) - {''}
    if not selected or selected - set(COMPONENTS):
        fail('组件只能是 comfyui,h3,qwen-image,acestep；也可使用 --all')
    return [name for name in COMPONENTS if name in selected]


def choose_components():
    try:
        with open('/dev/tty', 'r+') as tty:
            tty.write('选择安装组件，可输入多个编号（例如 1 3）；a=全部：\n')
            for number, name in enumerate(COMPONENTS, 1):
                tty.write(f'  {number}. {TITLES[name]}\n')
            tty.write('选择（直接回车取消）： ')
            tty.flush()
            choice = tty.readline().strip()
    except OSError:
        fail('没有交互终端；请显式提供 --components 或 --all')
    if choice.lower() == 'a':
        return list(COMPONENTS)
    mapping = {str(i): name for i, name in enumerate(COMPONENTS, 1)}
    words = re.split(r'[,\s]+', choice)
    if not choice or any(word not in mapping for word in words):
        fail('已取消，或选择无效；未执行安装')
    return parse_components(','.join(mapping[word] for word in words))


def resolve_directory(requested, data_root=Path('/data'), *, enforce_mount=True):
    data_root = Path(data_root).resolve()
    if not requested:
        if not data_root.is_dir():
            fail(f'{data_root} 不存在；先挂载数据盘，或用 --install-dir 明确指定目录')
        if enforce_mount and not os.path.ismount(data_root):
            fail(f'{data_root} 未挂载，不会自动安装到系统盘')
        requested = str(data_root / 'ComfyUI')
    if not re.fullmatch(r'/[A-Za-z0-9_./-]+', str(requested)):
        fail('安装目录须为不含空格或特殊字符的绝对路径')
    root = Path(requested).resolve()
    if root == Path('/') or not re.fullmatch(r'/[A-Za-z0-9_./-]+', str(root)):
        fail('安装目录无效，不能是 /')
    if enforce_mount and (root == data_root or data_root in root.parents) and not os.path.ismount(data_root):
        fail(f'{data_root} 未挂载，不会在该路径下写入')
    return root


def safe_path(root, relative):
    path = root / relative
    resolved = path.resolve()
    if resolved == root or root not in resolved.parents:
        fail(f'路径越出安装目录，未写入：{relative}')
    return path


def atomic_json(path, data):
    if path.is_symlink():
        fail(f'状态文件不能是符号链接：{path}')
    fd, name = tempfile.mkstemp(prefix='.' + path.name, dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(data, stream, ensure_ascii=False, indent=2)
            stream.write('\n')
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def read_json(path, default=None):
    if not path.exists():
        return default
    try:
        return json.loads(path.read_text())
    except (ValueError, OSError):
        fail(f'JSON 文件无法读取，原文件未修改：{path}')


def load_profile(path):
    profile = json.loads(json.dumps(PROFILE))
    if path:
        saved = read_json(path)
        if not isinstance(saved, dict) or saved.get('schema') != 1:
            fail('--runtime-lock 须为本脚本导出的 schema=1 环境锁文件')
        packages = saved.get('packages')
        if not isinstance(packages, dict) or not packages:
            fail('环境锁文件缺少 packages')
        if set(PROFILE['packages']) - set(packages):
            fail('环境锁文件缺少本安装配置所需的关键依赖版本')
        for name, version in packages.items():
            if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*', name) or not isinstance(version, str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9.+!_-]*', version):
                fail('环境锁文件含非法包名或版本，不接受 URL/命令/额外 pip 参数')
        if not re.fullmatch(r'[0-9a-f]{40}', saved.get('comfyui_commit', '')):
            fail('环境锁文件缺少完整 ComfyUI commit')
        if not re.fullmatch(r'3\.\d+\.\d+', saved.get('python', '')):
            fail('环境锁文件 Python 版本无效')
        if saved.get('comfyui_version') != PROFILE['comfyui_version']:
            fail('此安装配置只支持已核对的 ComfyUI 0.42.0')
        if not packages['torch'].endswith('+cu130'):
            fail('此安装入口使用 CUDA 13.0 wheel 源，环境锁的 torch 必须为 +cu130')
        profile.update({key: saved[key] for key in ('python', 'packages', 'comfyui_commit', 'comfyui_version')})
        models = saved.get('models', {})
        known = {item['target'] for item in MODELS}
        if not isinstance(models, dict) or set(models) - known:
            fail('环境锁文件含未知模型路径')
        for entry in models.values():
            if (not isinstance(entry, dict) or not isinstance(entry.get('size'), int) or entry['size'] <= 0
                    or not re.fullmatch(r'[0-9a-f]{64}', entry.get('sha256', ''))
                    or (entry.get('revision') is not None and not re.fullmatch(r'[0-9a-f]{40}', entry['revision']))):
                fail('环境锁文件模型校验值或 revision 无效')
        profile['models'] = models
    return profile


def version_file(root):
    try:
        text = (root / 'comfyui_version.py').read_text()
        return re.search(r'__version__\s*=\s*[\'"]([^\'"]+)', text).group(1)
    except (OSError, AttributeError):
        return None


ENV_QUERY = '''import importlib.metadata as m,json,sys
packages={}
for d in m.distributions():
    name=d.metadata.get("Name")
    if name: packages[name.lower().replace("_","-").replace(".","-")]=d.version
print(json.dumps({"python":".".join(map(str,sys.version_info[:3])),"packages":packages}))'''


def environment(python):
    return json.loads(run([python, '-c', ENV_QUERY], capture=True))


def find_python(root, requested, profile):
    existing = root / '.venv/bin/python'
    python = str(existing) if existing.is_file() else shutil.which(requested or 'python3.12') or shutil.which('python3')
    if requested and not existing.is_file():
        python = shutil.which(requested)
    if not python:
        fail(f'找不到 Python {profile["python"]}；请用 --python /解释器路径 指定')
    info = environment(python)
    if info['python'] != profile['python']:
        fail(f'目标 Python {profile["python"]}，当前 {info["python"]}；为保持实际版本，请用 --python 指定相同版本，或使用实际导出的 --runtime-lock')
    return Path(python), info


def verify_runtime(root, python, profile):
    actual = environment(python)
    if version_file(root) != profile['comfyui_version']:
        fail('现有 ComfyUI 不是目标 0.42.0；保留源码，未自动升级/降级')
    required = PROFILE['packages'] if not profile.get('packages') else profile['packages']
    differences = [f'{key}: 实际 {actual["packages"].get(canonical(key), "未安装")} / 目标 {value}'
                   for key, value in required.items() if actual['packages'].get(canonical(key)) != value]
    if actual['python'] != profile['python']:
        differences.insert(0, f'Python: 实际 {actual["python"]} / 目标 {profile["python"]}')
    if differences:
        fail('现有环境版本不同，未修改：\n  ' + '\n  '.join(differences) + '\n如这是你要保留的实际环境，请先 --export-lock，再用 --runtime-lock 重跑。')
    return actual


def snapshot(root, python, include_models=False):
    data = environment(python)
    data.update(schema=1, comfyui_version=version_file(root),
                comfyui_commit=run(['git', '-C', root, 'rev-parse', 'HEAD'], capture=True),
                created_at=datetime.datetime.now(datetime.timezone.utc).isoformat())
    data['tracked_source_modified'] = bool(run(['git', '-C', root, 'status', '--porcelain', '--untracked-files=no'], capture=True))
    data['models'] = {}
    receipts = read_json(root / '.comfyui-install/models.json', {})
    old_revisions = read_json(root / '.h3-install/model-revisions.json', {})
    for item in MODELS:
        path = safe_path(root, item['target'])
        if not path.is_file():
            continue
        receipt = receipts.get(item['target'], {})
        stamp = fingerprint(path)
        if receipt.get('stat') == stamp:
            sha = receipt['sha256']
        elif include_models:
            log(f'记录实际模型 SHA256：{path.name}')
            sha = digest(path)
            if fingerprint(path) != stamp:
                fail(f'导出期间模型发生改变：{path}')
        else:
            continue
        revision = item['revision'] if sha == item['sha256'] else old_revisions.get(item['repo'])
        if revision is not None and not re.fullmatch(r'[0-9a-f]{40}', revision):
            revision = None
        data['models'][item['target']] = dict(size=path.stat().st_size, sha256=sha, revision=revision)
    return data


def selected_models(components, profile=None):
    return [dict(item, **(profile or {}).get('models', {}).get(item['target'], {}))
            for item in MODELS if item['component'] in components]


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(8 * 1024 * 1024), b''):
            value.update(chunk)
    return value.hexdigest()


def fingerprint(path):
    stat = path.stat()
    return [stat.st_dev, stat.st_ino, stat.st_size, stat.st_mtime_ns, stat.st_ctime_ns]


def verified(path, item, receipts, force=False):
    if not path.exists():
        return False
    if not path.is_file() or path.stat().st_size != item['size']:
        fail(f'已有同名文件大小不符，未覆盖：{path}\n请先检查/备份该文件，再重新安装。')
    stamp = fingerprint(path)
    receipt = receipts.get(item['target'], {})
    if not force and receipt == {'stat': stamp, 'sha256': item['sha256']}:
        return True
    log(f'校验已有文件 SHA256：{path.name}')
    if digest(path) != item['sha256'] or fingerprint(path) != stamp:
        fail(f'已有文件校验不符或校验时发生变更，未覆盖：{path}')
    receipts[item['target']] = {'stat': stamp, 'sha256': item['sha256']}
    return True


def missing_bytes(root, models):
    total = 0
    for item in models:
        target = safe_path(root, item['target'])
        if target.exists():
            continue
        partial = target.with_name(target.name + '.part')
        safe_path(root, str(partial.relative_to(root)))
        if partial.exists() and (not partial.is_file() or partial.stat().st_size > item['size']):
            fail(f'断点文件异常，未修改：{partial}')
        total += item['size'] - (partial.stat().st_size if partial.exists() else 0)
    return total


def curl_download(url, partial):
    # -q is first: ignore ~/.curlrc (which may contain debug logging or unsafe
    # redirect flags). Keep HF_TOKEN off argv, logs, state files and systemd.
    config = ''
    token = os.environ.get('HF_TOKEN', '')
    if token and url.startswith('https://huggingface.co/'):
        if not re.fullmatch(r'[A-Za-z0-9_]+', token):
            fail('HF_TOKEN 格式无效')
        config = f'header = "Authorization: Bearer {token}"\n'
    run(['curl', '-q', '--fail', '--location', '--retry', '5', '--connect-timeout', '30',
         '--continue-at', '-', '--output', partial, '--config', '-', url], input=config)


def download_model(root, item, receipts, state_dir, force=False):
    target = safe_path(root, item['target'])
    if verified(target, item, receipts, force):
        log(f'复用：{target.name}')
        atomic_json(state_dir / 'models.json', receipts)
        return False
    target.parent.mkdir(parents=True, exist_ok=True)
    partial = safe_path(root, item['target'] + '.part')
    if not item['revision']:
        fail(f'锁文件记录了实际模型但缺少可核实的下载 revision：{target.name}。只能复用已存在且匹配的文件；请保留原模型或补全锁文件来源。')
    url = f'https://huggingface.co/{item["repo"]}/resolve/{item["revision"]}/{item["file"]}'
    log(f'下载：{target.name}（{item["size"] / 2**30:.2f} GiB）')
    if not partial.exists() or partial.stat().st_size < item['size']:
        curl_download(url, partial)
    if partial.stat().st_size != item['size'] or digest(partial) != item['sha256']:
        fail(f'下载文件未通过校验，保留 .part 以供检查：{partial}')
    if target.exists():
        fail(f'下载期间目标文件被其他进程创建，未覆盖：{target}')
    # hard-link publication is atomic and refuses to overwrite a concurrent file.
    os.link(partial, target)
    partial.unlink()
    receipts[item['target']] = {'stat': fingerprint(target), 'sha256': item['sha256']}
    atomic_json(state_dir / 'models.json', receipts)
    return True


def patch_workflow(data, component):
    # Replace strings recursively, including model metadata and named widget
    # values. Preserve all links/node IDs and never execute prompt text.
    replacements = {}
    if component == 'h3':
        replacements = {
            'qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors': 'qwen3vl_32b_heretic_minimax_h3_nvfp4.safetensors',
            'qwen3vl_32b_minimax_h3_int8_convrot.safetensors': 'qwen3vl_32b_heretic_minimax_h3_nvfp4.safetensors',
            'minimax_h3_fl2va_pruned_int8_convrot.safetensors': 'minimax_h3_fl2va_pruned_fp8_scaled.safetensors',
            'minimax_h3_video_vae_int8_convrot.safetensors': 'minimax_h3_video_vae_fp16.safetensors',
        }
    elif component == 'qwen-image':
        replacements = {'qwen_image_2.1_bf16.safetensors': 'qwen-image-2.1-UC-fp8.safetensors',
                        'qwen_image_2.1_int8_convrot.safetensors': 'qwen-image-2.1-UC-fp8.safetensors'}
    def visit(value):
        if isinstance(value, str):
            for old, new in replacements.items():
                value = value.replace(old, new)
            return value
        if isinstance(value, list):
            return [visit(item) for item in value]
        if isinstance(value, dict):
            result = {key: visit(item) for key, item in value.items()}
            # Correct embedded download links to the selected model's real repo.
            if result.get('name') in {Path(m['target']).name for m in MODELS} and 'url' in result:
                model = next(m for m in MODELS if Path(m['target']).name == result['name'])
                result['url'] = f'https://huggingface.co/{model["repo"]}/resolve/{model["revision"]}/{model["file"]}'
            return result
        return value
    return visit(data)


def install_workflows(root, components):
    changed = False
    for item in WORKFLOWS:
        if item['component'] not in components:
            continue
        target = safe_path(root, 'user/default/workflows/' + item['name'])
        if target.exists():
            log(f'保留已有工作流（包括用户改动）：{target.name}')
            continue
        url = f'https://raw.githubusercontent.com/Comfy-Org/workflow_templates/{TEMPLATE_COMMIT}/templates/{item["source"]}'
        with urllib.request.urlopen(url, timeout=60) as response:
            raw = response.read(8 * 1024 * 1024 + 1)
        if hashlib.sha256(raw).hexdigest() != item['sha256']:
            fail(f'工作流校验不符：{item["source"]}')
        data = patch_workflow(json.loads(raw), item['component'])
        target.parent.mkdir(parents=True, exist_ok=True)
        fd, temporary = tempfile.mkstemp(prefix='.' + target.name, dir=target.parent)
        try:
            with os.fdopen(fd, 'w') as stream:
                json.dump(data, stream, ensure_ascii=False, indent=2)
            os.link(temporary, target)
        finally:
            os.unlink(temporary)
        changed = True
        log(f'创建工作流：{target.name}')
    return changed


def service_info(name):
    text = run(['systemctl', 'show', name, '--no-pager',
                '--property=LoadState,ActiveState,ExecStart,WorkingDirectory,User,FragmentPath'], capture=True)
    return dict(line.split('=', 1) for line in text.splitlines() if '=' in line)


def check_service(info, root, user, port):
    if info.get('LoadState') == 'not-found':
        return
    if info.get('LoadState') != 'loaded':
        fail('现有服务无法正常加载，未修改')
    if Path(info.get('WorkingDirectory', '')).resolve() != root or info.get('User') != user:
        fail('现有服务指向其他安装目录或运行用户，未修改；请检查 --install-dir / --service-name')
    executable = str(root / '.venv/bin/python')
    if executable not in info.get('ExecStart', '') or not re.search(r'(?:^|\s|;)main\.py(?:\s|;|$)', info['ExecStart']):
        fail('现有服务启动命令无法确认，未修改')
    match = re.search(r'--port(?:=|\s+)(\d+)', info['ExecStart'])
    if (int(match[1]) if match else 8188) != port:
        fail('现有服务端口不同；请用 --port 指定实际端口，不会重写现有服务')


def require_idle(port):
    try:
        with urllib.request.urlopen(f'http://127.0.0.1:{port}/queue', timeout=8) as response:
            queue = json.load(response)
    except Exception:
        fail('无法确认现有 ComfyUI 队列为空，未重启；请空闲时手动操作')
    if not isinstance(queue, dict) or not all(isinstance(queue.get(key), list) for key in ('queue_running', 'queue_pending')):
        fail('队列响应不是预期的 ComfyUI 格式，未重启')
    if queue['queue_running'] or queue['queue_pending']:
        fail('ComfyUI 正在生成或有排队任务，未重启；等待空闲后重跑 --restart')


def safe_origin(root):
    origin = run(['git', '-C', root, 'remote', 'get-url', 'origin'], capture=True)
    if not re.fullmatch(r'(?:https://github\.com/|git@github\.com:)Comfy-Org/ComfyUI(?:\.git)?', origin):
        fail('现有 Git origin 不是 Comfy-Org/ComfyUI，未修改')


def copy_checkout(source, root):
    # Only merge new files into data directories; never overwrite user files.
    def copy_file(src, dst):
        path = Path(dst)
        safe_path(root, str(path.relative_to(root)))
        if path.exists():
            if not path.is_file() or digest(Path(src)) != digest(path):
                fail(f'已有源码/模板文件与目标不同，未覆盖：{path}')
            return str(path)
        return shutil.copy2(src, dst)
    for item in source.iterdir():
        if item.name == '.git':
            continue
        destination = safe_path(root, item.name)
        if item.is_dir():
            shutil.copytree(item, destination, dirs_exist_ok=True, copy_function=copy_file)
        elif not destination.exists():
            shutil.copy2(item, destination)
        elif digest(item) != digest(destination):
            fail(f'已有文件与目标不同，未覆盖：{destination}')
    # Publishing .git last lets a failed copy resume from the staged checkout.
    os.rename(source / '.git', root / '.git')


def create_runtime(root, state_dir, python, profile):
    marker = state_dir / 'runtime-installing.json'
    if not marker.exists():
        atomic_json(marker, profile)
    elif read_json(marker) != profile:
        fail('未完成安装的版本配置不同，未修改；请先核对 runtime-installing.json')
    if not (root / '.git').is_dir():
        stage = state_dir / 'source'
        if not (stage / '.git').is_dir():
            if stage.exists() and any(stage.iterdir()):
                fail('源码暂存目录非空且没有 Git 元数据，未删除；请先检查：' + str(stage))
            run(['git', 'init', stage])
            run(['git', '-C', stage, 'remote', 'add', 'origin', SOURCE])
        safe_origin(stage)
        run(['git', '-C', stage, 'fetch', '--depth=1', 'origin', profile['comfyui_commit']])
        run(['git', '-C', stage, 'checkout', '--detach', profile['comfyui_commit']])
        copy_checkout(stage, root)
    safe_origin(root)
    if version_file(root) != profile['comfyui_version']:
        fail('源码版本与锁文件不同，未覆盖现有 checkout')
    venv = root / '.venv'
    if not (venv / 'bin/python').is_file():
        run([python, '-m', 'venv', venv])
    target_python = venv / 'bin/python'
    constraints = state_dir / 'constraints.txt'
    constraints.write_text(''.join(f'{key}=={value}\n' for key, value in sorted(profile['packages'].items())))
    pip = [target_python, '-m', 'pip']
    package_env = dict(os.environ, PIP_CACHE_DIR=str(root / '.cache/pip'),
                       TMPDIR=str(state_dir / 'tmp'), HF_HOME=str(root / '.cache/huggingface'))
    (state_dir / 'tmp').mkdir(exist_ok=True)
    torch_packages = ['torch==' + profile['packages']['torch'],
                      'torchvision==' + profile['packages'].get('torchvision', '0.29.1+cu130')]
    # torchaudio does not publish a matching 2.14.1 wheel. Do not invent a
    # version or downgrade torch; only install it when the actual lock has it.
    if 'torchaudio' in profile['packages']:
        torch_packages.append('torchaudio==' + profile['packages']['torchaudio'])
    run(pip + ['install', *torch_packages, '--index-url', TORCH_INDEX,
               '-c', constraints], env=package_env)
    run(pip + ['install', '-r', root / 'requirements.txt', '-c', constraints], env=package_env)
    run(pip + ['install', 'comfy-kitchen[cublas]==' + profile['packages']['comfy-kitchen'],
               '-c', constraints], env=package_env)
    run(pip + ['check'], env=package_env)
    verify_runtime(root, target_python, profile)
    run([target_python, '-c', 'import torch; assert torch.cuda.is_available(), "CUDA unavailable"; '
         'print(torch.__version__, torch.version.cuda, torch.cuda.get_device_name(0)); '
         'x=torch.randn(128,128,device="cuda",dtype=torch.bfloat16); '
         'assert torch.isfinite(x@x).all().item()'])
    atomic_json(state_dir / 'environment.json', snapshot(root, target_python))
    marker.unlink()
    return target_python


def service_unit(root, user, home, port):
    return f'''[Unit]
Description=ComfyUI (managed by installers/comfyui)
After=network-online.target
Wants=network-online.target
RequiresMountsFor={root}

[Service]
Type=simple
User={user}
WorkingDirectory={root}
Environment="HOME={home}"
Environment="HF_HOME={root}/.cache/huggingface"
Environment="PYTHONUNBUFFERED=1"
ExecStart={root}/.venv/bin/python main.py --listen 127.0.0.1 --port {port}
Restart=on-failure
RestartSec=10
TimeoutStopSec=60
UMask=0022

[Install]
WantedBy=multi-user.target
'''


def configure_service(args, root, info, user, home):
    if args.no_service:
        return
    new = info.get('LoadState') == 'not-found'
    pending_path = root / '.comfyui-install/service-pending.json'
    pending = read_json(pending_path)
    identity = {'service': args.service_name, 'directory': str(root), 'port': args.port}
    if pending and pending != identity:
        fail('上次尚未完成的服务配置不同，原配置保留；请检查 service-pending.json')
    if new or pending:
        destination = '/etc/systemd/system/' + args.service_name
        unit = service_unit(root, user, home, args.port)
        if Path(destination).exists():
            if Path(destination).is_symlink() or Path(destination).read_text() != unit:
                fail('已有不同的 systemd unit 文件，未覆盖：' + destination)
        else:
            code = 'import os,sys; p=sys.argv[1]; fd=os.open(p,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o644); f=os.fdopen(fd,"w"); f.write(sys.stdin.read()); f.close()'
            run(['sudo', 'python3', '-c', code, destination], input=unit)
        atomic_json(pending_path, identity)
        run(['sudo', 'systemctl', 'daemon-reload'])
        run(['sudo', 'systemctl', 'enable', '--now', args.service_name])
    elif args.restart:
        if info.get('ActiveState') == 'active':
            require_idle(args.port)
        run(['sudo', 'systemctl', 'restart', args.service_name])
    else:
        log('保留现有服务及其启动参数；如需刷新模型，请空闲时手动重启。')
        return
    for _ in range(90):
        try:
            with urllib.request.urlopen(f'http://127.0.0.1:{args.port}/system_stats', timeout=2) as response:
                data = json.load(response)
            if data.get('system', {}).get('comfyui_version') == PROFILE['comfyui_version']:
                if service_info(args.service_name).get('ActiveState') == 'active':
                    log('服务就绪；尚未执行实际生成测试。')
                    if pending_path.exists():
                        pending_path.unlink()
                    return
        except (OSError, ValueError):
            pass
        time.sleep(2)
    fail('服务尚未就绪，请执行 sudo journalctl -u ' + args.service_name + ' -n 100 --no-pager')


def preflight(args, root, components, profile):
    if platform.system() != 'Linux' or platform.machine() != 'x86_64':
        fail('安装需要 Linux x86_64；--plan / --list 可在本机查看')
    release = dict(line.split('=', 1) for line in Path('/etc/os-release').read_text().splitlines() if '=' in line)
    if release.get('ID', '').strip('"') != 'ubuntu' or release.get('VERSION_ID', '').strip('"') not in ('22.04', '24.04'):
        fail('支持 Ubuntu 22.04 / 24.04（含 DLVM）')
    if os.geteuid() == 0:
        fail('请用普通 SSH 用户执行 bash install.sh；仅系统依赖/服务步骤使用 sudo')
    if not args.no_service and not Path('/run/systemd/system').is_dir():
        fail('需要 systemd；容器或手动管理请使用 --no-service')
    for command in ('git', 'curl', 'nvidia-smi', 'sudo'):
        if not shutil.which(command):
            fail(f'缺少 {command}，请先安装（驱动由 DLVM 提供）')
    user = pwd.getpwuid(os.getuid()).pw_name
    home = pwd.getpwuid(os.getuid()).pw_dir
    if not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_-]*', user) or not re.fullmatch(r'/[A-Za-z0-9_./-]+', home):
        fail('用户或主目录包含不支持的 systemd 特殊字符')
    if root.exists() and (not root.is_dir() or not os.access(root, os.W_OK)):
        fail('安装目录不存在写权限；不会递归 chown 现有目录')
    resuming = (root / '.comfyui-install/runtime-installing.json').is_file()
    if (root / 'main.py').exists() and not (root / '.git').is_dir() and not resuming:
        fail('现有目录包含非 Git 安装，未覆盖；请用其他 --install-dir')
    if not (root / '.git').exists() and root.exists() and not resuming:
        allowed = {'models', 'user', 'input', 'output', '.cache', 'custom_nodes', '.comfyui-install', '.h3-install', '.h3-install.lock'}
        if any(item.name not in allowed for item in root.iterdir()):
            fail('目录含未识别文件，未覆盖；请选择空目录或现有 ComfyUI Git 安装')
    python, actual = find_python(root, args.python, profile)
    existing = (root / '.venv/bin/python').is_file()
    if (root / '.git').exists():
        if not (root / '.git').is_dir():
            fail('不自动修改 Git worktree/外部 Git 元数据目录')
        safe_origin(root)
        if version_file(root) != profile['comfyui_version']:
            fail('现有源码不是 ComfyUI 0.42.0，未自动更新或回退')
    if existing and not resuming:
        verify_runtime(root, python, profile)
    if not existing or resuming:
        if args.no_runtime:
            fail('--no-runtime 要求目标目录已有完整 .venv')
        for name in ('custom_nodes', '.venv', '.comfyui-install'):
            safe_path(root, name)
    gpu = run(['nvidia-smi', '--query-gpu=driver_version,compute_cap', '--format=csv,noheader'], capture=True).splitlines()
    if not gpu:
        fail('没有检测到 NVIDIA GPU')
    driver, capability = [value.strip() for value in gpu[0].split(',')]
    if int(driver.split('.')[0]) < 580:
        fail('CUDA 13.0 环境要求 NVIDIA 驱动 >=580；脚本不安装/替换驱动')
    if 'h3' in components and int(float(capability)) < 10:
        fail('你当前 H3 编码器为 NVFP4，需要 Blackwell；不会自动改成其他模型')
    info = {'LoadState': 'not-found'} if args.no_service else service_info(args.service_name)
    check_service(info, root, user, args.port)
    if args.restart and info.get('ActiveState') == 'active':
        require_idle(args.port)
    if (not existing or resuming) and info.get('ActiveState') == 'active':
        fail('服务正在使用尚未完成的环境；请先自行停止，脚本不在线替换 Python 依赖')
    if not args.no_service and info.get('LoadState') == 'not-found':
        with socket.socket() as sock:
            try:
                sock.bind(('127.0.0.1', args.port))
            except OSError:
                fail('端口已被其他进程占用；请先确认现有服务，或用 --no-service')
    return python, existing, resuming, user, home, info


def main(argv=None):
    os.umask(0o077)
    parser = argparse.ArgumentParser(description='ComfyUI / H3 / Qwen Image / ACE-Step 可选安装；保留实际版本，支持重复执行')
    group = parser.add_mutually_exclusive_group()
    group.add_argument('--components', help='逗号分隔：comfyui,h3,qwen-image,acestep')
    group.add_argument('--all', action='store_true', help='安装全部四个组件')
    parser.add_argument('--install-dir', help='默认 /data/ComfyUI，要求 /data 存在且已挂载')
    parser.add_argument('--python', help='新建环境使用的 Python 3.12.3 解释器；已有 .venv 优先复用')
    parser.add_argument('--port', type=int, default=8188)
    parser.add_argument('--service-name', default='comfyui.service')
    parser.add_argument('--no-service', action='store_true', help='不创建、启用、启动或重启 systemd 服务')
    parser.add_argument('--no-runtime', action='store_true', help='仅向现有完整环境添加模型/工作流')
    parser.add_argument('--restart', action='store_true', help='明确要求安装后重启现有服务；队列须为空')
    parser.add_argument('--verify', action='store_true', help='重算已有模型 SHA256，不使用校验收据缓存')
    parser.add_argument('--plan', action='store_true', help='仅打印选择、固定版本与文件，不写入、不联网')
    parser.add_argument('--check', action='store_true', help='只读预检环境、服务和已有模型')
    parser.add_argument('--list', action='store_true', help='列出可选组件和默认版本')
    parser.add_argument('--export-lock', type=Path, help='导出现有 Git 提交和 Python 包版本；不安装或重启')
    parser.add_argument('--runtime-lock', type=Path, help='采用本脚本导出的实际环境锁文件')
    args = parser.parse_args(argv)
    if args.no_service and args.restart:
        parser.error('--no-service 与 --restart 不能同时使用')
    if not 1 <= args.port <= 65535 or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]*\.service', args.service_name):
        parser.error('端口或服务名无效')
    if args.list:
        print(json.dumps({'components': TITLES, 'runtime': PROFILE}, ensure_ascii=False, indent=2))
        return
    profile = load_profile(args.runtime_lock)
    root = resolve_directory(args.install_dir, enforce_mount=not args.plan)
    if args.export_lock:
        if not (root / '.venv/bin/python').is_file() or not (root / '.git').is_dir():
            fail('没有可导出的 .venv / Git 安装')
        data = snapshot(root, root / '.venv/bin/python', include_models=True)
        with args.export_lock.open('x') as stream:
            json.dump(data, stream, ensure_ascii=False, indent=2)
        log(f'已导出实际环境及已有模型 SHA256（不含权重/密钥，不改服务）：{args.export_lock}')
        return
    components = list(COMPONENTS) if args.all else parse_components(args.components) if args.components else choose_components()
    models = selected_models(components, profile)
    plan = {'directory': str(root), 'components': components,
            'comfyui_dependency': '自动准备缺失的 ComfyUI；已有环境只核对并复用', 'runtime': profile,
            'model_GiB': round(sum(item['size'] for item in models) / 2**30, 2),
            'models': models, 'workflows': [item for item in WORKFLOWS if item['component'] in components]}
    if args.plan:
        print(json.dumps(plan, ensure_ascii=False, indent=2))
        return
    python, existing, resuming, user, home, info = preflight(args, root, components, profile)
    state_dir = safe_path(root, '.comfyui-install')
    receipts = read_json(state_dir / 'models.json', {})
    for item in models:
        verified(safe_path(root, item['target']), item, receipts, args.verify)
    nearest = root
    while not nearest.exists():
        nearest = nearest.parent
    needed = missing_bytes(root, models) + (15 if not existing or resuming else 3) * 2**30
    free = shutil.disk_usage(nearest).free
    if free < needed:
        fail(f'可用空间 {free / 2**30:.1f} GiB，不足剩余下载及预留 {needed / 2**30:.1f} GiB')
    log('选择：' + ', '.join(components) + f'；目录：{root}；剩余下载约 {missing_bytes(root, models) / 2**30:.1f} GiB')
    if args.check:
        log('只读预检通过；未安装、下载或修改服务。')
        return
    if not root.exists():
        run(['sudo', 'install', '-d', '-o', user, '-g', str(os.getgid()), root])
    state_dir.mkdir(mode=0o700, exist_ok=True)
    if state_dir.is_symlink() or (state_dir / 'installer.lock').is_symlink():
        fail('状态目录/锁不能是符号链接')
    with (state_dir / 'installer.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            fail('另一个统一安装进程正在运行')
        # Re-check after obtaining the lock: another run may have finished while
        # this one was performing the read-only preflight.
        if (root / '.venv/bin/python').is_file() and not (state_dir / 'runtime-installing.json').exists():
            python = root / '.venv/bin/python'
            verify_runtime(root, python, profile)
        else:
            log('准备固定版本 ComfyUI 和 Python 环境')
            run(['sudo', 'apt-get', 'update'])
            run(['sudo', 'env', 'DEBIAN_FRONTEND=noninteractive', 'apt-get', 'install', '-y',
                 'git', 'curl', 'ffmpeg', 'python3-venv', 'build-essential', 'ca-certificates'])
            python = create_runtime(root, state_dir, python, profile)
        if not (state_dir / 'environment.json').exists():
            atomic_json(state_dir / 'environment.json', snapshot(root, python))
        checked_receipts = receipts
        receipts = read_json(state_dir / 'models.json', {})
        # Carry forward hashes from preflight only while the file identity and
        # timestamps still match. This avoids reading large weights twice.
        for item in models:
            path = safe_path(root, item['target'])
            receipt = checked_receipts.get(item['target'], {})
            if path.is_file() and receipt.get('sha256') == item['sha256'] and receipt.get('stat') == fingerprint(path):
                receipts[item['target']] = receipt
        for item in models:
            download_model(root, item, receipts, state_dir)
        install_workflows(root, components)
        atomic_json(state_dir / 'environment.json', snapshot(root, python))
        history = read_json(state_dir / 'installed.json', {'components': []})
        history.update(components=sorted(set(history['components']) | set(components)),
                       profile=profile, updated_at=datetime.datetime.now(datetime.timezone.utc).isoformat())
        atomic_json(state_dir / 'installed.json', history)
        configure_service(args, root, info, user, home)
    log(f'安装完成。已有源码、工作流及未选组件保持原状；模型已通过 SHA256 校验。')
    log(f'环境锁：{state_dir / "environment.json"}')
    if args.no_service:
        print(f'手动启动：cd {root} && .venv/bin/python main.py --listen 127.0.0.1 --port {args.port}')
    else:
        log(f'服务配置地址：http://127.0.0.1:{args.port}')
    if not args.no_service and info.get('LoadState') != 'not-found' and not args.restart:
        print(f'新增模型需刷新时，空闲后执行：sudo systemctl restart {args.service_name}')


if __name__ == '__main__':
    try:
        main()
    except (InstallError, FileExistsError) as exc:
        print(f'\n错误：{exc}\n未自动清理文件或回滚环境；修复后可重复执行。', file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        print('\n已中止；已完成文件与断点下载保留。', file=sys.stderr)
        sys.exit(130)
COMFYUI_INSTALLER_PYTHON
