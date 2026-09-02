# installers

经过整理、可审计的 Linux 工具与服务一键安装脚本。

## 安装项

| 安装项 | 脚本 | 默认版本 | 说明 |
| --- | --- | --- | --- |
| [Docker](#docker) | [`docker/install.sh`](docker/install.sh) | Docker Engine 29.7.2、Docker Compose v5.5.0 | 安装 Docker 静态二进制与 Compose CLI 插件，创建并启动 systemd 服务；支持 x86_64 和 ARM64 |

## 一键安装

### Docker

在使用 systemd 的 Linux 主机上执行：

```bash
curl -fsSL https://raw.githubusercontent.com/hstarorg/installers/main/docker/install.sh | sudo bash
```

Docker 数据默认保存在 `/data/docker`。如需自定义目录：

```bash
curl -fsSL https://raw.githubusercontent.com/hstarorg/installers/main/docker/install.sh | sudo bash -s -- --docker-data-root /data2/docker
```

安装完成后可运行以下命令检查版本：

```bash
docker --version
docker compose version
```
