# MeowSingboxPlus 快速教程

## （其实并不需要教程，你只需要下载一个Codex或者Claude code等Agent，买个VPS，让AI大人进服务器里，跟它说下载singbox帮忙配置梯子就行，然后跟AI大人说导出订阅，复制粘贴进V2rayN，途中有任何问题直接问AI大人，这里就是装模做样写一篇没有的教程而已。）

## 1. 下载客户端

- **Windows**：[v2rayN](https://github.com/2dust/v2rayN/releases/latest)。
- **Android**：[v2rayNG](https://github.com/2dust/v2rayNG/releases/latest)。

住宅 SOCKS5 用法见[第 7 节](#7-静态住宅-ip-socks5)。

## 2. 购买 VPS

可在 [Vultr](https://www.vultr.com/) 或 [DigitalOcean](https://www.digitalocean.com/) 等服务商购买。入门选择 **share cpu，1 核、1 GB 内存、Debian 13、公网 IPv4** 就足够用了。vultr不一定最好，如果有自己喜欢的服务商也可以去其他地方购买，想代理哪个地区就买哪个地方的服务器，例如代理美国可以买洛杉矶的，比较稳定，也比较便宜。

### 添加 SSH 公钥

在 Windows 打开 PowerShell，检查是否已有密钥：

```powershell
Get-ChildItem $env:USERPROFILE\.ssh
```

如果看到 `id_ed25519.pub`，可直接使用。若没有，生成一对新密钥：

```powershell
ssh-keygen -t ed25519 -C "my-vps"
```

保存路径直接按 Enter，使用默认的 `C:\Users\你的用户名\.ssh\id_ed25519`。设置密钥密码可提高安全性；设置后登录时需要输入这个本地密码。**不要把没有 `.pub` 后缀的私钥发给别人。**

复制公钥：

```powershell
Get-Content $env:USERPROFILE\.ssh\id_ed25519.pub | Set-Clipboard
```

在 VPS 服务商控制台打开 **SSH Keys / SSH 密钥**，新增密钥，粘贴公钥并保存。创建 VPS 时选中这把密钥。若已看到 `id_ed25519.pub` 以外的公钥文件，复制对应的 `.pub` 文件内容即可。

保存 VPS 的公网 IP 和登录用户名。下面的 `xx.xx.xx.xx` 均需替换为自己的 VPS IP。

## 3. 登录 VPS

第一次在电脑 PowerShell 执行：

```powershell
ssh root@xx.xx.xx.xx
```

首次连接出现主机指纹确认时，输入 `yes`。如果创建 VPS 时已选 SSH 密钥，且本机使用默认密钥路径，之后用这条命令即可登录，无需输入 VPS 密码；设置了密钥密码时，按提示输入本地密钥密码。若登录的是普通用户，执行 `sudo -i` 切换到 root。

## 4. 安装脚本

先将仓库中的 `MeowSingboxPlus.sh` 下载到电脑，在文件所在目录打开 PowerShell，上传到 VPS：

```powershell
scp .\MeowSingboxPlus.sh root@xx.xx.xx.xx:/root/
```

在 VPS 执行：

```sh
sh /root/MeowSingboxPlus.sh
```

脚本发布到仓库 `main` 分支后，也可直接在 VPS 下载并安装：

```sh
apt-get update && apt-get install -y ca-certificates curl
curl -fL --retry 3 https://raw.githubusercontent.com/KafuuChinoQwQ4/MeowSing-Box/main/MeowSingboxPlus.sh -o /root/MeowSingboxPlus.sh && sh /root/MeowSingboxPlus.sh
```

脚本会下载最新稳定版 sing-box，部署 10 种协议组合的直连和 WARP 节点，共 **20 个节点**，并导出订阅。

安装成功后查看端口清单，在服务商的安全组/云防火墙中放行对应 TCP、UDP 端口：

```sh
cat /opt/meowsingboxplus/export/firewall-ports.txt
```

## 5. 导出并导入客户端

导出文件位于 `/opt/meowsingboxplus/export/`：

| 文件 | 用途 |
| --- | --- |
| `MeowSingboxPlus-sing-box-outbounds.json` | v2rayN 导入，包含 20 个节点 |
| `MeowSingboxPlus-links.txt` | 普通节点分享链接 |
| `MeowSingboxPlus-subscription.txt` | Base64 订阅内容 |

在**自己电脑的 PowerShell** 下载导出文件：

```powershell
scp root@xx.xx.xx.xx:/opt/meowsingboxplus/export/MeowSingboxPlus-* .
```

### Windows：v2rayN

1. 更新 v2rayN 及其 sing-box 核心。
2. 在 PowerShell 执行以下命令，复制节点配置：

   ```powershell
   Get-Content -Raw .\MeowSingboxPlus-sing-box-outbounds.json | Set-Clipboard
   ```

3. 在 v2rayN 选择“从剪贴板导入”或自定义出站配置导入入口。
4. 选中 `vless-reality` 节点，设为活动服务器，开启系统代理后访问网页。

推荐导入 JSON，它保留证书公钥固定；普通分享链接中的部分 TLS 节点会跳过证书验证。

### Android：v2rayNG

1. 将下载的 `MeowSingboxPlus-links.txt` 发送到手机。
2. 复制其中标签为 `vless-reality` 的 `vless://` 链接。
3. 在 v2rayNG 从剪贴板导入，选中节点并启动，允许 VPN 连接。

v2rayNG 不支持全部 20 个节点，先使用 `vless-reality`。

### 使用订阅 URL

脚本导出的是订阅文件。需要订阅 URL 时，将 `MeowSingboxPlus-subscription.txt` 放到自己的 HTTPS 网站，再把文件地址填入客户端的订阅设置；更新节点后同步该文件。订阅含连接凭据，请勿公开。

## 6. 更新与排错

在 VPS 执行：

```sh
# 更新 sing-box，保留节点信息；切换时短暂重启服务
sh /opt/meowsingboxplus/MeowSingboxPlus.sh update

# 重新导出订阅
sh /opt/meowsingboxplus/MeowSingboxPlus.sh export

# 查看状态
sh /opt/meowsingboxplus/MeowSingboxPlus.sh status

# 查看日志
journalctl -u meowsingboxplus -n 80 --no-pager
```

- 全部超时：检查 IP、服务状态和安全组端口。
- 只有 Hysteria2/TUIC 超时：检查 UDP 是否放行。
- 只有 `-warp` 节点失败：检查 WARP 连接，可先切换直连节点。


## 7. 静态住宅 IP（SOCKS5）

这类服务由代理商（如 Onesproxy 等）提供住宅网络出口，通常不是你自己家里的宽带。购买前确认支持 SOCKS5、IP 固定时长、流量/并发限制和允许用途，并保存服务商提供的 **服务器地址、端口、用户名、密码**。不要把账号密码发到公开仓库或截图里。

### 直接使用住宅 SOCKS5

在 [NekoBox](https://github.com/MatsuriDayo/NekoBoxForAndroid) 或支持 SOCKS5 的指纹浏览器里新增代理。菜单名称随版本变化，按服务商提供的信息填写：

1. 协议类型选 **SOCKS5**。
2. 填代理服务器地址和端口。
3. 服务商提供了用户名、密码时，填入认证栏；没有认证信息则按服务商说明设置。
4. 保存并连接，再访问 IP 查询网站，确认出口显示为购买的住宅 IP。

链路是：

```text
你的设备 → 住宅 SOCKS5 → 网站
```

这种用法不经过 MeowSingboxPlus VPS，网站看到的是住宅代理的出口 IP。服务商若启用了来源 IP 白名单，把实际连接代理的设备公网 IP 加入白名单。

### 经 VPS 转到住宅出口

如果希望先连接 VPS，再由住宅代理访问网站，链路应是：

```text
你的设备 → MeowSingboxPlus VPS → 住宅 SOCKS5 → 网站
```

这需要在 VPS 上把住宅 SOCKS5 配成出站代理，并把入站流量转发到该出口。当前脚本生成的 20 个节点只使用 VPS 直连或 WARP 出口，**还不会自动接入第三方住宅 SOCKS5**；单独把 SOCKS5 加进客户端，也不会改变这些节点的 VPS 出口。要实现这条链路，需要给脚本增加 SOCKS5 出口配置。

若服务商要求 IP 白名单，应添加 VPS 的公网出口 IP，因为连接 SOCKS5 的是 VPS。配置完成后访问 IP 查询网站确认显示住宅代理 IP；若显示 VPS 或 WARP IP，说明请求尚未走住宅出口。

## （这些如果进家宽的卖家，里面会有教程教你怎么使用家宽，一般都会选择配合指纹浏览器使用，如果是用链式代理，一些检测严格的网站会把你ban掉，指纹浏览器安全性更好。还有，一些客户端支持的协议有些差别，例如，一些客户端会不支持新协议，像TUIC这种，如果不支持就算了，或者你换一个。singbox与v2rayN有时会有兼容问题，在最新版没及时兼容时，可能会出现有些协议无法使用，流量进客户端却没处理，这时你可以选择在前面加一个Nginx这种，进行反代，所有流量先过Nginx，监听443，再转发到对应的协议端口。）