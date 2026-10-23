# Docker 安装

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
