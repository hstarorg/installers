# Caddy + Cloudflare DNS

用 Caddy 给 HTTP 应用加上 HTTPS。Caddy 通过 Cloudflare DNS 验证域名，自动申请和续期证书。公网和私网服务都可以用。

## 快速开始

示例使用 GHCR 镜像标签 `1.0.0`，支持 `linux/amd64` 和 `linux/arm64`。首次部署前，确认团队已发布这个标签。使用其他已发布版本时，在终端执行 `export CADDY_IMAGE_TAG=实际标签`。如果 GHCR 包是私有的，先执行 `docker login ghcr.io -u 你的GitHub用户名`，密码处输入具有 `read:packages` 权限的 GitHub 个人访问令牌（classic）。[GHCR 登录说明](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry#authenticating-to-the-container-registry)

### 1. 写 Caddyfile

用 `mkdir -p ~/caddy/conf && nano ~/caddy/conf/Caddyfile` 创建配置。把 `app.example.com` 换成你的域名，把 `10.0.0.20:8080` 换成容器能访问的后端地址。

```caddyfile
app.example.com {
    tls {
        dns cloudflare {env.CF_API_TOKEN}
    }
    reverse_proxy 10.0.0.20:8080
}
```

### 2. 设置 Cloudflare API Token

在部署机的 Bash 中执行下面两行，按提示粘贴 Cloudflare API Token。Token 的范围选该域名所在的 Zone，权限选 **Zone Read** 和 **DNS Edit**。[Cloudflare 插件权限说明](https://github.com/caddy-dns/cloudflare#readme)

```bash
read -rsp 'Cloudflare API Token: ' CF_API_TOKEN
export CF_API_TOKEN
```

### 3. 选一种方式启动

**Docker Compose** · 在 [compose.yaml](compose.yaml) 所在目录执行：

```bash
docker compose up -d
```

**docker run** · 在同一个 Bash 终端执行：

```bash
docker run -d --name caddy --restart unless-stopped \
  -e CF_API_TOKEN -p 443:443 \
  -v "$HOME/caddy/conf:/etc/caddy:ro" \
  -v caddy_data:/data -v caddy_config:/config \
  "ghcr.io/hstarorg/caddy-cloudflare:${CADDY_IMAGE_TAG:-1.0.0}"
```

让域名解析到 Caddy 入口，然后打开 `https://你的域名`。证书保存在 `caddy_data` 卷中，重建容器时复用该卷即可。

`443:443` 默认在宿主机所有网卡发布 TCP 443。仅供内网访问时，让内网 DNS 指向宿主机私网 IP，并在云防火墙中将 TCP 443 的来源限制为内网或 VPN 连接器。

## 常用操作

| 用途 | 操作 |
| --- | --- |
| 修改域名或后端 | 编辑 Caddyfile，再运行 `docker exec caddy caddy reload --config /etc/caddy/Caddyfile`。 |
| 查看申请证书或反向代理的日志 | `docker logs --tail 100 caddy` |
| 更新镜像或轮换 Token | 设置新的 `CADDY_IMAGE_TAG` 或 `CF_API_TOKEN` 后，用 Compose 执行 `docker compose up -d --force-recreate`。用 `docker run` 部署时，执行 `docker rm -f caddy` 后重新运行上面的启动命令，沿用两个命名卷。 |

<details>
<summary>其他用法和排错</summary>

- 公网网站也可以使用 Caddy 默认的 HTTPS 验证。使用此方式时，移除 `tls` 配置块和启动配置中的 `CF_API_TOKEN`，确保域名指向 Caddy 且公网可达 TCP 443（TLS-ALPN-01）。通配符证书使用上面的 DNS 验证。[Caddy 自动 HTTPS](https://caddyserver.com/docs/automatic-https#acme-challenges)
- 托管静态页面时，把网页目录只读挂载到 `/srv`，用 `root * /srv` 和 `file_server` 两行替换 `reverse_proxy`。
- 内网域名超时时，检查员工设备的 WARP 分流和隧道路由是否覆盖 Caddy 的私网 IP。遇到 `502` 时，检查 Caddy 能否连到后端的 IP 和端口。

</details>

## 维护者构建与发布

将本目录和[发布工作流](../../.github/workflows/publish-caddy.yml)一同提交到默认分支。在 GitHub 打开 **Actions → Publish Caddy to GHCR → Run workflow**，输入镜像标签（例如 `1.0.0`）。工作流使用内置 `GITHUB_TOKEN` 将两个架构发布到同一标签。

升级 Caddy 或插件时，修改 [Dockerfile](Dockerfile) 中的固定版本，再用新标签发布。在本目录从源码构建本机架构镜像可执行 `docker build -t caddy-cloudflare:local .`。
