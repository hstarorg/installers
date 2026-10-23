# ComfyUI 可选组件安装

统一入口 `install.sh`，可重复执行，支持选择 ComfyUI、MiniMax H3、Qwen Image 2.1 UC、ACE-Step 1.5 XL Turbo。入口是独立 Bash 文件，内嵌 Python 标准库，不需要下载其他 installers 仓库文件。模型和官方工作流从各自的固定源版本下载。

## 使用

在 Ubuntu GPU 服务器上，用普通 SSH 用户执行：

```bash
curl -fsSL https://raw.githubusercontent.com/hstarorg/installers/main/comfyui/install.sh | bash
```

下载仓库后，也可以直接执行：

```bash
# 交互选择：输入 1 2 3 4 中需要的编号；a 为全部
bash comfyui/install.sh

# 全部安装
bash comfyui/install.sh --all

# 只补装歌曲组件
bash comfyui/install.sh --components acestep

# 选择两个组件
bash comfyui/install.sh --components h3,qwen-image

# 只准备 ComfyUI，不下载这些模型
bash comfyui/install.sh --components comfyui
```

选择模型组件时，缺失的 ComfyUI 会自动作为依赖准备；若已有完整安装，直接核对并复用。重复执行不卸载未选择组件。

默认 `/data/ComfyUI`。`/data` 不存在或没有挂载会直接报错，不会改装到 HOME 或系统盘；不读取旧的 `~/.comfyui-path`。显式指定其他路径：

```bash
bash comfyui/install.sh --components acestep --install-dir /其他挂载点/ComfyUI
```

任何解析到 `/data` 下的目录仍要求 `/data` 已挂载；脚本不会格式化、挂载磁盘或递归修改已有文件属主。数据盘另用仓库的 [`disk/install.sh`](../disk/install.sh)，操作说明见[数据盘挂载](../disk/README.md)，安装前请选择可写挂载。

## 固定为当前使用的版本

默认配置依据用户提供的 `/system_stats`、已实际连接过的服务、原 H3 安装脚本，以及 ai-studio 中现有 Qwen Image / ACE-Step / H3 工作流：

| 项目 | 固定值 |
| --- | --- |
| ComfyUI | `0.42.0`，新装源码固定 `355cd6b14c92c19ac3188fe528e47a3f21ef5178` |
| Python | `3.12.3` |
| PyTorch | `2.14.1+cu130`，使用 CUDA 13.0 wheel 源 |
| Frontend | `1.55.18` |
| Workflow templates | `0.11.89` |
| Embedded docs | `0.5.14` |
| comfy-kitchen | `0.2.39`，新装启用 cublas extra |
| comfy-aimdo | `0.5.6` |

新装的官方模板源也固定在 `v0.11.89` 对应提交 `7d8ed32f0bf6b8d52129976535422d6f518fe463`。不使用 `git pull`、模型 `main` 或自动更新插件。所有模型下载都固定 repo commit、字节数和 SHA256。

已知版本不代表已经掌握原服务器完整的 pip freeze 或每个模型的历史下载提交：默认模型哈希来自这次核实的上游文件，现有同名模型内容若不同会报错保留，绝不直接覆盖成新版。**要严格沿用自己机器上的实际文件，先导出锁文件：**

```bash
# 在目前可用的 GPU 服务器上导出，目标文件须尚不存在
bash comfyui/install.sh --export-lock /data/comfyui-actual-lock.json

# 后续重跑或新机器安装时使用它
bash comfyui/install.sh --all --runtime-lock /data/comfyui-actual-lock.json
```

导出记录 Python 补丁版本、全部已安装 Python 包版本、实际 Git HEAD，以及清单内已存在模型的 SHA256 和大小。首次需读取几十 GB 的模型，可能耗时数分钟；不联网、不提交生成、不启停服务，也不记录环境变量或密钥。安装时还会自动保存 `/data/ComfyUI/.comfyui-install/environment.json`。

如果同名模型与默认上游内容不同，且旧安装记录不能提供实际源 revision，锁文件允许继续复用原文件，但不会凭空声称可以从固定上游恢复这份不同内容。迁移时需保留原模型或补全其正确源 revision。锁文件不包含本地源码修改、自定义节点源码、系统依赖、驱动、模型权重、用户输出或工作流内容；`tracked_source_modified` 标记 Git 追踪文件是否存在修改。

新装时已知依赖采用上述固定版本；torchvision 若没有实际锁记录，则选用配套的 `0.29.1+cu130`，这是兼容选择，不冒充已测得的原服务器版本。公开源没有 `torchaudio 2.14.1+cu130`，核心依赖也不要求它，因此默认不额外安装；实际锁文件记录了它才按锁文件尝试安装，依赖冲突时报错，不降级 Torch。其他未获知版本的必要依赖仅在新建环境时解析，然后记录实际版本。导出锁文件会将这些版本作为 pip constraints，已有环境不会再次运行 pip 或创建 venv。

## 组件与文件

| 组件 | 内容 | 约占磁盘 |
| --- | --- | --- |
| `comfyui` | 固定版本核心、Python venv、系统依赖和首次开机自启 | 另预留 15 GiB 用于环境和安装临时文件 |
| `h3` | FL2VA pruned FP8、Heretic NVFP4 编码器、FP16 视频 VAE、FP32 音频 VAE、Turbo **8step v1.0** LoRA | 41.36 GiB |
| `qwen-image` | **UC FP8**、Qwen3-VL 8B **INT8 ConvRot**、BF16 VAE、Qwen3.5 9B T2I/I2I 提示词增强编码器 | 33.61 GiB |
| `acestep` | **XL Turbo BF16**、专用 Qwen 0.6B 与 **4B LM**、ACE 1.5 VAE | 18.52 GiB |

全部模型约 93.49 GiB。已有完整文件或 `.part` 下载部分会从剩余空间需求中扣除；重跑已有环境另预留 3 GiB。Qwen 的 I2I 提示词增强编码器用于配套图生图模板，是同系列补充文件，不是换掉原来的 UC 模型。不会额外安装普通 ACE Turbo AIO、SFT、YuE2、GGUF 或 Qwen BF16 主模型。

按选择创建以下工作流，已存在的同名文件始终保留，包括用户改动：

```text
user/default/workflows/
├── MiniMax-H3-Heretic-T2V.json
├── MiniMax-H3-Heretic-I2V.json
├── Qwen-Image-2.1-UC-T2I.json
├── Qwen-Image-2.1-UC-Edit.json
└── ACE-Step-1.5-XL-Turbo-4B.json
```

工作流沿用固定版本的原生节点与连线，只替换对应模型文件及下载元数据，不执行生成示例。图生视频/图生图的 Load Image 请在 UI 中自行选择图片。ACE-Step 默认保留官方示例；中文歌曲需填写中文歌词并将 language 设为 `zh`，保持 `generate_audio_codes=true`、KSampler `8 步/CFG 1`、文本节点 `cfg_scale=2`。

## 兼容性与预检

需要 Linux x86_64、Ubuntu 22.04 / 24.04、NVIDIA 驱动 >=580、git/curl/sudo，以及目标版本 Python。新机器须先完成 DLVM 驱动初始化；脚本不安装/替换 NVIDIA 驱动、不修改 SSH 或防火墙。默认 Python 严格采用已提供的 `3.12.3`，不会在 Ubuntu 22.04 上偷偷改用系统的 3.10，也不会自动安装其他 Python。

```bash
# 已有 .venv/bin/python 优先复用；新机器可指定解释器
bash comfyui/install.sh --all --python /usr/bin/python3.12

# 只看清单，不联网/下载/安装；--plan 不执行 OS/GPU 预检
bash comfyui/install.sh --components h3,acestep --plan

# 只读检查 OS、路径、版本、显卡、服务与已有模型
bash comfyui/install.sh --components h3,acestep --check

# 显式强制重新计算已选模型的 SHA256
bash comfyui/install.sh --components acestep --verify
```

H3 的 NVFP4 编码器只适用于 Blackwell。H100 不会被自动改成另一套 INT8 编码器；其余组件不要求 Blackwell。自定义完整环境锁可用于记录实际 Python 补丁版本，但此入口只负责 ComfyUI 0.42.0 和 CUDA 13.0 的安装路线。

## 重复执行与服务

- 首次导入已有模型会核对完整 SHA256；后续文件身份、大小、mtime、ctime 均未改变时复用本机校验收据，不重复读取全部权重。需要时使用 `--verify`。
- 新下载只写 `.part`，校验成功后原子发布；已存在但内容不符的文件会报错保留，不自动删除或覆盖。下载中断可重跑续传。若最终 `.part` 校验失败，先检查/移走它再重跑。
- 一次只允许一个统一安装进程。不要同时运行旧 H3 脚本或其他下载器写相同模型。
- 已有 Git checkout 和完整 `.venv` 只读核对版本，保留本地源码和插件。版本不同则报错，不自动重置、升级或降级。首次新建环境若中断，保留安装阶段记录以便重跑继续。
- 新安装默认创建 `comfyui.service` 并开机自启，监听 **127.0.0.1:8188**。已有服务指向同一目录/用户/端口时原样保留，默认不重启，即使选择 `--all`。
- `--restart` 明确要求完成后重启已有服务，会检查 `/queue` 中没有运行或待执行任务；检查和重启之间应暂停外部提交，不能用它代替业务侧维护窗口。查询失败或已有任务时拒绝重启。
- `--no-service` 完全不创建/启用/启动/重启 systemd 服务。`--no-runtime` 要求已经存在完整 venv，适合只补模型。

```bash
# 已有服务只补装模型
bash comfyui/install.sh --components acestep --no-runtime

# 完成后明确重启现有服务
bash comfyui/install.sh --components acestep --restart

# 容器或其他进程管理器自行启动
bash comfyui/install.sh --all --no-service

# 已有服务若用了其他名字或端口，必须准确指定
bash comfyui/install.sh --components acestep --service-name comfyui.service --port 8188
```

补装完成后可在空闲时手动执行 `sudo systemctl restart comfyui`。查看日志：`sudo journalctl -u comfyui -n 100 -f`。默认不加入 HTTP 网关/API Key、不开放公网端口，也不改 ai-studio 服务。

## 验证

```bash
bash -n comfyui/install.sh
python3 comfyui/test_install.py
```

测试使用临时目录、合成小文件及模拟命令/HTTP 响应，不执行 apt/pip、不安装 systemd、不绑定端口、不下载模型或调用 GPU。真实 GPU 安装和生成仍需在目标服务器验证。

版本来源：[ComfyUI 0.42.0 依赖](https://github.com/Comfy-Org/ComfyUI/blob/v0.42.0/requirements.txt)、[H3 Heretic](https://huggingface.co/Momoking/Qwen3-VL-32B-Heretic-MiniMax-H3-NVFP4)、[H3 模型](https://huggingface.co/Comfy-Org/MiniMax-H3)、[Qwen UC](https://huggingface.co/abenzerps/Qwen-Image-2.1-Uncensored-Quantized)、[Qwen 配套文件](https://huggingface.co/Comfy-Org/Qwen-Image-2.1)、[ACE-Step ComfyUI 文件](https://huggingface.co/Comfy-Org/ace_step_1.5_ComfyUI_files)。模型许可沿用各自仓库；安装和开源发布本身不代表所有模型均无限制商用。
