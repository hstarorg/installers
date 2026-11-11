# Docker 安装

在使用 systemd 的 Linux 主机上执行：

```bash
curl -fsSL https://raw.githubusercontent.com/hstarorg/installers/main/docker/install.sh | sudo bash
```

Docker 数据默认保存在 `/data/docker`。如需自定义目录：

```bash
curl -fsSL https://raw.githubusercontent.com/hstarorg/installers/main/docker/install.sh | sudo bash -s -- --docker-data-root /data2/docker
```

脚本会在启动 Docker 前创建 `docker` 组，并将通过 `sudo` 执行安装的普通用户加入该组。`docker` 组具有等同于 root 的权限。安装后请重新登录，或在原终端运行 `newgrp docker`，再验证：

```bash
docker ps
docker --version
docker compose version
```

如果此前用旧脚本安装过，或安装时直接使用 root，请在需要使用 Docker 的普通用户终端执行：

```bash
sudo groupadd --force --system docker
sudo usermod -aG docker "$(id -un)"
ls -l /var/run/docker.sock
```

使用脚本默认服务配置时，如果 socket 仍显示为 `root root`，可在允许容器短暂停机时运行 `sudo systemctl restart docker.service`，让 Docker 重新创建 socket。然后重新登录，或运行 `newgrp docker` 后再试 `docker ps`。
