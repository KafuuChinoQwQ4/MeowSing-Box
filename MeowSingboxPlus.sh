#!/bin/sh
# MeowSingboxPlus - install the current stable sing-box with 20 endpoints.
# Usage: sh MeowSingboxPlus.sh [install|update|export|status|help] [--host IP_OR_DOMAIN]
set -eu

if ! command -v python3 >/dev/null 2>&1; then
    if [ "$(id -u)" -ne 0 ]; then
        echo "请先使用 root 运行；脚本需要 Python 3。" >&2
        exit 1
    fi
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y python3
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y python3
    else
        echo "未找到 apt-get 或 dnf，无法自动安装 Python 3。" >&2
        exit 1
    fi
fi

MEOWSINGBOXPLUS_SCRIPT=$0
export MEOWSINGBOXPLUS_SCRIPT
exec python3 - "$@" <<'MEOWSINGBOXPLUS_PY'
# --- PYTHON PROGRAM BEGIN ---
import sys

if sys.version_info < (3, 8):
    print("[错误] 需要 Python 3.8 或更新版本，请升级系统或 Python 后重试。", file=sys.stderr)
    sys.exit(1)

import base64
import configparser
import fcntl
import hashlib
import ipaddress
import json
import os
import platform
import random
import re
import shutil
import socket
import subprocess
import tarfile
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path


APP = "MeowSingboxPlus"
ROOT = Path("/opt/meowsingboxplus")
BIN = Path("/usr/local/bin/meowsingboxplus-sing-box")
UNIT = Path("/etc/systemd/system/meowsingboxplus.service")
DROPIN = Path("/etc/systemd/system/meowsingboxplus.service.d/20-warp-net-raw.conf")
STATE = ROOT / "state.json"
CONFIG = ROOT / "config.json"
EXPORT = ROOT / "export"
DATA = ROOT / "data"
CERT = ROOT / "cert.pem"
CERT_KEY = ROOT / "key.pem"
WGCF_DIR = ROOT / "wgcf"
SERVICE = "meowsingboxplus.service"
REPO = "SagerNet/sing-box"
WGCF_REPO = "ViRb3/wgcf"
NAMES = ["vless-reality", "vless-grpc-reality", "trojan-reality", "hy2",
         "vmess-ws", "hy2-obfs", "ss2022", "ss", "tuic-v5", "anytls"]
UDP_NAMES = {"hy2", "hy2-obfs", "tuic-v5", "ss2022", "ss"}


def say(message):
    try:
        print(message, flush=True)
    except BrokenPipeError:
        sys.stdout = open(os.devnull, "w")


def fail(message):
    raise RuntimeError(message)


class WarpProbeFailure(RuntimeError):
    pass


def run(command, *, check=True, capture=False, timeout=60, env=None):
    try:
        result = subprocess.run(command, check=False, text=True,
                                stdout=subprocess.PIPE if capture else None,
                                stderr=subprocess.PIPE if capture else None,
                                timeout=timeout, env=env)
    except (OSError, subprocess.TimeoutExpired) as exc:
        if check:
            fail(f"执行失败：{command[0]}（{exc}）")
        return None
    if check and result.returncode:
        detail = (result.stderr or result.stdout or "").strip() if capture else ""
        fail(f"执行失败：{' '.join(map(str, command))}" + (f"\n{detail}" if detail else ""))
    return result


def ensure_dependencies():
    missing = [name for name in ("curl", "openssl", "systemctl") if shutil.which(name) is None]
    if not missing:
        return
    if os.geteuid() != 0:
        fail("缺少依赖 " + ", ".join(missing) + "；请使用 root 安装后重试。")
    if shutil.which("apt-get"):
        run(["apt-get", "update"], timeout=300)
        run(["apt-get", "install", "-y", "ca-certificates", "curl", "openssl", "systemd"], timeout=600)
    elif shutil.which("dnf"):
        run(["dnf", "install", "-y", "ca-certificates", "curl", "openssl", "systemd"], timeout=600)
    else:
        fail("仅自动安装 Debian/Ubuntu（apt-get）或 Fedora/RHEL 系（dnf）的依赖。")
    missing = [name for name in ("curl", "openssl", "systemctl") if shutil.which(name) is None]
    if missing:
        fail("依赖安装后仍缺少：" + ", ".join(missing))


def ensure_systemd():
    if shutil.which("systemctl") is None or not Path("/run/systemd/system").exists():
        fail("需要以 systemd 启动的 Linux VPS 运行此脚本。")


def make_dirs():
    for path in (ROOT, EXPORT, DATA, WGCF_DIR, ROOT / "backups"):
        path.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(path, 0o700)


def atomic_write(path, data, mode=0o600):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_name = tempfile.mkstemp(prefix="." + path.name + ".", dir=str(path.parent))
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data if isinstance(data, bytes) else data.encode("utf-8"))
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temp_name, mode)
        os.replace(temp_name, path)
    finally:
        if os.path.exists(temp_name):
            os.unlink(temp_name)


def http_json(url):
    request = urllib.request.Request(url, headers={"User-Agent": APP, "Accept": "application/vnd.github+json"})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    except Exception as exc:
        fail(f"读取发布信息失败：{url}\n{exc}")


def download(url, expected_sha256, target, label):
    if not re.fullmatch(r"[0-9a-fA-F]{64}", expected_sha256 or ""):
        fail(f"{label} 的官方 SHA-256 缺失或格式错误，已停止下载。")
    digest = hashlib.sha256()
    size = 0
    fd, temp_name = tempfile.mkstemp(prefix=".download-", dir=str(ROOT))
    try:
        request = urllib.request.Request(url, headers={"User-Agent": APP})
        with urllib.request.urlopen(request, timeout=60) as response, os.fdopen(fd, "wb") as output:
            while True:
                block = response.read(1024 * 1024)
                if not block:
                    break
                size += len(block)
                if size > 250 * 1024 * 1024:
                    fail(f"{label} 下载包超过大小上限。")
                digest.update(block)
                output.write(block)
            output.flush()
            os.fsync(output.fileno())
        if digest.hexdigest().lower() != expected_sha256.lower():
            fail(f"{label} SHA-256 校验失败，拒绝安装。")
        os.chmod(temp_name, 0o600)
        os.replace(temp_name, target)
    finally:
        if os.path.exists(temp_name):
            os.unlink(temp_name)


def go_arch():
    arch = platform.machine().lower()
    mapping = {"x86_64": "amd64", "amd64": "amd64", "aarch64": "arm64", "arm64": "arm64"}
    if arch not in mapping:
        fail(f"暂不支持 CPU 架构：{arch}（支持 x86_64/amd64 和 aarch64/arm64）。")
    return mapping[arch]


def install_latest_singbox():
    arch = go_arch()
    release = http_json(f"https://api.github.com/repos/{REPO}/releases/latest")
    tag = release.get("tag_name", "")
    version = tag.lstrip("v")
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        fail(f"无法确认 sing-box 稳定版版本号：{tag!r}")
    name = f"sing-box-{version}-linux-{arch}.tar.gz"
    if release.get("prerelease") or release.get("draft"):
        fail("sing-box latest 不是稳定版本。")
    asset = next((item for item in release.get("assets", []) if item.get("name") == name), None)
    if not asset:
        fail(f"最新版 {tag} 未提供所需文件 {name}。")
    digest = asset.get("digest", "")
    if digest.startswith("sha256:"):
        digest = digest[7:]
    say(f"正在获取 sing-box {tag} ({arch})…")
    archive = ROOT / ".sing-box-release.tar.gz"
    download(asset.get("browser_download_url", ""), digest, archive, "sing-box")
    try:
        with tarfile.open(archive, "r:gz") as package:
            members = [m for m in package.getmembers() if m.name.endswith("/sing-box") and m.isfile()]
            if len(members) != 1:
                fail("sing-box 发布包结构异常，拒绝安装。")
            extracted = package.extractfile(members[0])
            if extracted is None:
                fail("无法读取 sing-box 可执行文件。")
            candidate = ROOT / ".sing-box.new"
            atomic_write(candidate, extracted.read(), 0o755)
    finally:
        archive.unlink(missing_ok=True)
    result = run([str(candidate), "version"], capture=True)
    first_line = (result.stdout or "").splitlines()[0] if result.stdout else ""
    if version not in first_line:
        candidate.unlink(missing_ok=True)
        fail(f"下载包版本与发布标签不符：{first_line!r} / {tag}")
    return candidate, tag


def install_latest_wgcf():
    arch = go_arch()
    release = http_json(f"https://api.github.com/repos/{WGCF_REPO}/releases/latest")
    tag = release.get("tag_name", "")
    if release.get("prerelease") or release.get("draft") or not re.fullmatch(r"v?[0-9]+\.[0-9]+\.[0-9]+", tag):
        fail("wgcf latest 不是可确认的稳定版。")
    name = f"wgcf_{tag.lstrip('v')}_linux_{arch}"
    asset = next((item for item in release.get("assets", []) if item.get("name") == name), None)
    if not asset:
        fail(f"wgcf 最新发布没有所需文件：{name}")
    url = asset.get("browser_download_url", "")
    digest = asset.get("digest", "")
    if digest.startswith("sha256:"):
        digest = digest[7:]
    candidate = ROOT / ".wgcf.new"
    say(f"正在获取 WARP 注册工具 wgcf {tag} ({arch})…")
    download(url, digest, candidate, "wgcf")
    os.chmod(candidate, 0o700)
    return candidate


def parse_wgcf_profile(text):
    parser = configparser.ConfigParser(interpolation=None, strict=False)
    parser.optionxform = str
    parser.read_string(text)
    interface = parser["Interface"]
    peer = parser["Peer"]
    endpoint = peer.get("Endpoint", "").strip().strip('"')
    if endpoint.startswith("["):
        host, sep, port_text = endpoint[1:].partition("]:")
        if not sep:
            fail("wgcf 配置中的 Endpoint 格式错误。")
    else:
        host, sep, port_text = endpoint.rpartition(":")
        if not sep:
            fail("wgcf 配置中的 Endpoint 缺少端口。")
    address_items = [value.strip().strip('"') for value in interface.get("Address", "").split(",") if value.strip()]
    reserved_text = peer.get("Reserved", "0, 0, 0").strip().strip('"')
    try:
        reserved = [int(value.strip()) for value in reserved_text.split(",")]
        port = int(port_text)
    except ValueError:
        fail("wgcf 配置中的端口或 Reserved 字段不是数字。")
    if len(reserved) != 3 or any(value < 0 or value > 255 for value in reserved):
        fail("wgcf 配置中的 Reserved 必须是三个 0 到 255 的数字。")
    if not 1 <= port <= 65535:
        fail("wgcf 配置中的 WARP 端口超出范围。")
    try:
        address_v4 = next(item for item in address_items if ipaddress.ip_interface(item).version == 4)
        address_v6 = next(item for item in address_items if ipaddress.ip_interface(item).version == 6)
    except (StopIteration, ValueError):
        fail("wgcf 配置缺少有效的 IPv4/IPv6 隧道地址。")
    private_key = interface.get("PrivateKey", "").strip().strip('"')
    public_key = peer.get("PublicKey", "").strip().strip('"')
    if not private_key or not public_key or not host:
        fail("wgcf 配置缺少 WireGuard 密钥或 Endpoint。")
    return {"private_key": private_key, "public_key": public_key,
            "endpoint_host": host, "endpoint_port": port,
            "address_v4": address_v4, "address_v6": address_v6,
            "reserved": reserved}


def generate_warp():
    make_dirs()
    candidate = install_latest_wgcf()
    account = WGCF_DIR / "wgcf-account.toml"
    profile = WGCF_DIR / "wgcf-profile.conf"
    try:
        if not account.exists():
            say("正在注册 Cloudflare WARP 设备…")
            result = run([str(candidate), "register", "--accept-tos", "--config", str(account)],
                         capture=True, timeout=120, check=False)
            if result is None or result.returncode:
                fail("WARP 设备注册失败；请检查 VPS 是否能访问 Cloudflare WARP 注册服务。")
            if account.exists():
                os.chmod(account, 0o600)
        result = run([str(candidate), "generate", "--config", str(account), "--profile", str(profile)],
                     capture=True, timeout=120, check=False)
        if result is None or result.returncode or not profile.exists():
            fail("wgcf 未能生成 WARP WireGuard 配置。")
        os.chmod(profile, 0o600)
        return parse_wgcf_profile(profile.read_text(encoding="utf-8"))
    finally:
        candidate.unlink(missing_ok=True)


def parse_host(raw):
    value = raw.strip()
    if value.startswith("[") and value.endswith("]"):
        value = value[1:-1]
    try:
        return str(ipaddress.ip_address(value))
    except ValueError:
        try:
            normalized = value.encode("idna").decode("ascii").lower().rstrip(".")
        except UnicodeError:
            fail("服务器地址不是有效 IP 或域名。")
        if len(normalized) > 253 or not normalized or any(not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", label) for label in normalized.split(".")):
            fail("服务器地址不是有效 IP 或域名。")
        return normalized


def discover_host():
    for url in ("https://api.ipify.org", "https://ipv4.icanhazip.com"):
        try:
            request = urllib.request.Request(url, headers={"User-Agent": APP})
            with urllib.request.urlopen(request, timeout=8) as response:
                return str(ipaddress.ip_address(response.read(128).decode().strip()))
        except Exception:
            continue
    fail("无法自动识别 VPS 公网 IPv4。请重新运行并加上 --host 公网IP或域名。")


def allocate_ports():
    occupied = set()
    for file in (Path("/proc/net/tcp"), Path("/proc/net/tcp6"), Path("/proc/net/udp"), Path("/proc/net/udp6")):
        try:
            for line in file.read_text().splitlines()[1:]:
                fields = line.split()
                port = int(fields[1].rsplit(":", 1)[1], 16)
                occupied.add(port)
        except (OSError, ValueError, IndexError):
            pass
    # Do not race automatic outbound sockets, including WARP DNS/TLS connections.
    # The kernel may allocate one after /proc/net was read but before service start.
    ephemeral_start, ephemeral_end = 32768, 60999
    try:
        ephemeral_start, ephemeral_end = map(int, Path("/proc/sys/net/ipv4/ip_local_port_range").read_text().split())
    except (OSError, ValueError):
        pass
    ports = [port for port in range(20000, 60001) if not ephemeral_start <= port <= ephemeral_end]
    random.SystemRandom().shuffle(ports)
    selected = []
    for port in ports:
        if port in occupied:
            continue
        selected.append(port)
        if len(selected) == 20:
            return selected
    fail("没有找到 20 个空闲端口。")


def random_password(size=24):
    return base64.urlsafe_b64encode(os.urandom(size)).decode().rstrip("=")


def listen_address(host):
    """Use dual stack when available, including when --host is an AAAA domain."""
    try:
        with socket.socket(socket.AF_INET6, socket.SOCK_STREAM) as probe:
            probe.bind(("::", 0))
            if probe.getsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY) == 0:
                return "::"
    except OSError:
        if ":" in host:
            fail("指定了 IPv6 地址，但系统未启用 IPv6 监听。")
        return "0.0.0.0"
    if ":" in host:
        return "::"
    try:
        if ipaddress.ip_address(host).version == 4:
            return "0.0.0.0"
    except ValueError:
        families = {item[0] for item in socket.getaddrinfo(host, None, type=socket.SOCK_STREAM)}
        if families == {socket.AF_INET6}:
            return "::"
        if socket.AF_INET6 in families:
            fail("系统启用了 bindv6only，无法用单组端口监听该双栈域名；请用 --host 指定公网 IP。")
    return "0.0.0.0"


def reality_keys(binary):
    result = run([str(binary), "generate", "reality-keypair"], capture=True)
    values = dict(re.findall(r"(PrivateKey|PublicKey):\s*(\S+)", result.stdout or ""))
    if not values.get("PrivateKey") or not values.get("PublicKey"):
        fail("sing-box 没有返回有效的 Reality 密钥对。")
    return values["PrivateKey"], values["PublicKey"]


def create_state(host, binary, warp):
    private_key, public_key = reality_keys(binary)
    return {"schema": 1, "host": host, "listen": listen_address(host), "ports": allocate_ports(), "uuid": str(uuid.uuid4()),
            "reality_private_key": private_key, "reality_public_key": public_key,
            "reality_short_id": os.urandom(8).hex(), "reality_sni": "www.microsoft.com",
            "tls_sni": "www.microsoft.com", "tls_cert": str(CERT), "tls_key": str(CERT_KEY),
            "passwords": {"hy2": random_password(), "hy2_obfs": random_password(),
                          "obfs_password": random_password(),
                          "ss2022": base64.b64encode(os.urandom(32)).decode(),
                          "ss": random_password(), "tuic": random_password(),
                          "anytls": random_password()},
            "warp": warp, "created_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}


def write_certificate(state):
    if CERT.exists() and CERT_KEY.exists():
        os.chmod(CERT, 0o600)
        os.chmod(CERT_KEY, 0o600)
        state["tls_pin"] = tls_pin()
        state["tls_cert_sha256"] = certificate_sha256()
        return
    run(["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1",
         "-days", "3650", "-nodes", "-keyout", str(CERT_KEY), "-out", str(CERT),
         "-subj", f"/CN={state['tls_sni']}", "-addext", f"subjectAltName=DNS:{state['tls_sni']}"], timeout=30)
    os.chmod(CERT, 0o600)
    os.chmod(CERT_KEY, 0o600)
    state["tls_pin"] = tls_pin()
    state["tls_cert_sha256"] = certificate_sha256()


def tls_pin():
    first = subprocess.run(["openssl", "x509", "-in", str(CERT), "-pubkey", "-noout"],
                           stdout=subprocess.PIPE, check=True)
    second = subprocess.run(["openssl", "pkey", "-pubin", "-outform", "DER"], input=first.stdout,
                            stdout=subprocess.PIPE, check=True)
    return base64.b64encode(hashlib.sha256(second.stdout).digest()).decode()


def certificate_sha256():
    result = subprocess.run(["openssl", "x509", "-in", str(CERT), "-outform", "DER"],
                            stdout=subprocess.PIPE, check=True)
    return hashlib.sha256(result.stdout).hexdigest()


def listener(name, tag, port, state):
    item = {"type": "", "tag": tag, "listen": state.get("listen", "::" if ":" in state["host"] else "0.0.0.0"), "listen_port": port}
    base = name
    p = state["passwords"]
    if base in ("vless-reality", "vless-grpc-reality"):
        item.update({"type": "vless", "users": [{"uuid": state["uuid"]}]})
        if base == "vless-reality":
            item["users"][0]["flow"] = "xtls-rprx-vision"
        else:
            item["transport"] = {"type": "grpc", "service_name": "grpc"}
        item["tls"] = {"enabled": True, "server_name": state["reality_sni"],
                       "reality": {"enabled": True,
                                   "handshake": {"server": state["reality_sni"], "server_port": 443},
                                   "private_key": state["reality_private_key"],
                                   "short_id": [state["reality_short_id"]]}}
    elif base == "trojan-reality":
        item.update({"type": "trojan", "users": [{"password": state["uuid"]}],
                     "tls": {"enabled": True, "server_name": state["reality_sni"],
                             "reality": {"enabled": True,
                                         "handshake": {"server": state["reality_sni"], "server_port": 443},
                                         "private_key": state["reality_private_key"],
                                         "short_id": [state["reality_short_id"]]}}})
    elif base in ("hy2", "hy2-obfs"):
        item.update({"type": "hysteria2", "users": [{"name": base, "password": p[base.replace('-', '_')]}],
                     "tls": {"enabled": True, "certificate_path": state["tls_cert"],
                             "key_path": state["tls_key"], "alpn": ["h3"]}})
        if base == "hy2-obfs":
            item["obfs"] = {"type": "salamander", "password": p["obfs_password"]}
    elif base == "vmess-ws":
        item.update({"type": "vmess", "users": [{"uuid": state["uuid"]}],
                     "transport": {"type": "ws", "path": "/vm"}})
    elif base in ("ss2022", "ss"):
        item.update({"type": "shadowsocks",
                     "method": "2022-blake3-aes-256-gcm" if base == "ss2022" else "aes-256-gcm",
                     "password": p[base]})
    elif base == "tuic-v5":
        item.update({"type": "tuic", "users": [{"uuid": state["uuid"], "password": p["tuic"]}],
                     "congestion_control": "bbr",
                     "tls": {"enabled": True, "certificate_path": state["tls_cert"],
                             "key_path": state["tls_key"], "alpn": ["h3"]}})
    elif base == "anytls":
        item.update({"type": "anytls", "users": [{"name": "anytls", "password": p["anytls"]}],
                     "tls": {"enabled": True, "certificate_path": state["tls_cert"],
                             "key_path": state["tls_key"]}})
    else:
        fail(f"未知协议：{base}")
    return item


def build_server_config(state):
    inbounds = []
    for index, name in enumerate(NAMES):
        inbounds.append(listener(name, name, state["ports"][index], state))
        inbounds.append(listener(name, name + "-warp", state["ports"][index + 10], state))
    warp = state["warp"]
    warp_tags = [name + "-warp" for name in NAMES]
    return {"log": {"level": "info", "timestamp": True},
            "dns": {"servers": [{"type": "udp", "tag": "dns-remote", "server": "1.1.1.1"}],
                    "strategy": "prefer_ipv4"},
            "endpoints": [{"type": "wireguard", "tag": "warp", "mtu": 1280,
                           "address": [warp["address_v4"], warp["address_v6"]],
                           "private_key": warp["private_key"],
                           "peers": [{"address": warp["endpoint_host"], "port": warp["endpoint_port"],
                                      "public_key": warp["public_key"],
                                      "allowed_ips": ["0.0.0.0/0", "::/0"],
                                      "reserved": warp["reserved"]}]}],
            "inbounds": inbounds,
            "outbounds": [{"type": "direct", "tag": "direct"}],
            "route": {"rules": [{"inbound": warp_tags, "outbound": "warp"}],
                      "final": "direct", "default_domain_resolver": "dns-remote"}}


def host_for_uri(host):
    try:
        return f"[{ipaddress.IPv6Address(host)}]"
    except ValueError:
        return host


def build_subscription_links(state, config=None):
    host = host_for_uri(state["host"])
    p = state["passwords"]
    ports = state["ports"]
    items = []
    for index, name in enumerate(NAMES):
        for offset, suffix in ((0, ""), (10, "-warp")):
            port = ports[index + offset]
            tag = name + suffix
            encoded_tag = urllib.parse.quote(tag, safe="-._~")
            if name == "vless-reality":
                query = urllib.parse.urlencode({"encryption": "none", "flow": "xtls-rprx-vision", "security": "reality",
                                                "sni": state["reality_sni"], "fp": "chrome",
                                                "pbk": state["reality_public_key"], "sid": state["reality_short_id"],
                                                "type": "tcp"})
                link = f"vless://{state['uuid']}@{host}:{port}?{query}#{encoded_tag}"
            elif name == "vless-grpc-reality":
                query = urllib.parse.urlencode({"encryption": "none", "security": "reality", "sni": state["reality_sni"],
                                                "fp": "chrome", "pbk": state["reality_public_key"],
                                                "sid": state["reality_short_id"], "type": "grpc", "serviceName": "grpc"})
                link = f"vless://{state['uuid']}@{host}:{port}?{query}#{encoded_tag}"
            elif name == "trojan-reality":
                query = urllib.parse.urlencode({"security": "reality", "sni": state["reality_sni"], "fp": "chrome",
                                                "pbk": state["reality_public_key"], "sid": state["reality_short_id"], "type": "tcp"})
                link = f"trojan://{state['uuid']}@{host}:{port}?{query}#{encoded_tag}"
            elif name == "hy2":
                query = urllib.parse.urlencode({"sni": state["tls_sni"], "alpn": "h3", "insecure": "1",
                                                "pinSHA256": state["tls_cert_sha256"], "pcs": state["tls_cert_sha256"]})
                link = f"hysteria2://{urllib.parse.quote(p['hy2'], safe='')}@{host}:{port}?{query}#{encoded_tag}"
            elif name == "vmess-ws":
                obj = {"v": "2", "ps": tag, "add": state["host"], "port": str(port), "id": state["uuid"],
                       "aid": "0", "scy": "auto", "net": "ws", "type": "none", "host": "", "path": "/vm", "tls": ""}
                payload = base64.b64encode(json.dumps(obj, separators=(",", ":")).encode()).decode()
                link = "vmess://" + payload
            elif name == "hy2-obfs":
                query = urllib.parse.urlencode({"sni": state["tls_sni"], "alpn": "h3", "insecure": "1", "obfs": "salamander",
                                                "obfs-password": p["obfs_password"], "pcs": state["tls_cert_sha256"],
                                                "pinSHA256": state["tls_cert_sha256"]})
                link = f"hysteria2://{urllib.parse.quote(p['hy2_obfs'], safe='')}@{host}:{port}?{query}#{encoded_tag}"
            elif name in ("ss2022", "ss"):
                method = "2022-blake3-aes-256-gcm" if name == "ss2022" else "aes-256-gcm"
                # SIP002 requires plain, percent-encoded userinfo for AEAD-2022.
                if name == "ss2022":
                    userinfo = method + ":" + urllib.parse.quote(p[name], safe="")
                else:
                    userinfo = base64.urlsafe_b64encode(f"{method}:{p[name]}".encode()).decode().rstrip("=")
                link = f"ss://{userinfo}@{host}:{port}#{encoded_tag}"
            elif name == "tuic-v5":
                query = urllib.parse.urlencode({"congestion_control": "bbr", "alpn": "h3", "sni": state["tls_sni"],
                                                "pcs": state["tls_cert_sha256"], "allow_insecure": "1"})
                link = f"tuic://{state['uuid']}:{urllib.parse.quote(p['tuic'], safe='')}@{host}:{port}?{query}#{encoded_tag}"
            elif name == "anytls":
                query = urllib.parse.urlencode({"security": "tls", "sni": state["tls_sni"], "pcs": state["tls_cert_sha256"], "insecure": "1"})
                link = f"anytls://{urllib.parse.quote(p['anytls'], safe='')}@{host}:{port}?{query}#{encoded_tag}"
            else:
                fail(f"未知协议：{name}")
            items.append(link)
    return items


def client_outbound(name, tag, port, state):
    host = state["host"]
    p = state["passwords"]
    tls = {"enabled": True, "server_name": state["tls_sni"],
           "certificate_public_key_sha256": [state["tls_pin"]]}
    if name in ("hy2", "hy2-obfs", "tuic-v5"):
        tls["alpn"] = ["h3"]
    if name in ("vless-reality", "vless-grpc-reality"):
        result = {"type": "vless", "tag": tag, "server": host, "server_port": port, "uuid": state["uuid"],
                  "tls": {"enabled": True, "server_name": state["reality_sni"],
                          "utls": {"enabled": True, "fingerprint": "chrome"},
                          "reality": {"enabled": True, "public_key": state["reality_public_key"],
                                      "short_id": state["reality_short_id"]}}}
        if name == "vless-reality":
            result["flow"] = "xtls-rprx-vision"
        else:
            result["transport"] = {"type": "grpc", "service_name": "grpc"}
        return result
    if name == "trojan-reality":
        return {"type": "trojan", "tag": tag, "server": host, "server_port": port, "password": state["uuid"],
                "tls": {"enabled": True, "server_name": state["reality_sni"],
                        "utls": {"enabled": True, "fingerprint": "chrome"},
                        "reality": {"enabled": True, "public_key": state["reality_public_key"], "short_id": state["reality_short_id"]}}}
    if name in ("hy2", "hy2-obfs"):
        result = {"type": "hysteria2", "tag": tag, "server": host, "server_port": port,
                  "password": p[name.replace('-', '_')], "tls": tls}
        if name == "hy2-obfs":
            result["obfs"] = {"type": "salamander", "password": p["obfs_password"]}
        return result
    if name == "vmess-ws":
        return {"type": "vmess", "tag": tag, "server": host, "server_port": port, "uuid": state["uuid"],
                "alter_id": 0, "transport": {"type": "ws", "path": "/vm"}}
    if name in ("ss2022", "ss"):
        return {"type": "shadowsocks", "tag": tag, "server": host, "server_port": port,
                "method": "2022-blake3-aes-256-gcm" if name == "ss2022" else "aes-256-gcm", "password": p[name]}
    if name == "tuic-v5":
        return {"type": "tuic", "tag": tag, "server": host, "server_port": port, "uuid": state["uuid"],
                "password": p["tuic"], "congestion_control": "bbr", "tls": tls}
    if name == "anytls":
        return {"type": "anytls", "tag": tag, "server": host, "server_port": port, "password": p["anytls"],
                "tls": {"enabled": True, "server_name": state["tls_sni"], "certificate_public_key_sha256": [state["tls_pin"]]}}
    fail(f"未知客户端协议：{name}")


def build_client_config(state, config=None):
    outbounds = []
    for index, name in enumerate(NAMES):
        outbounds.append(client_outbound(name, name, state["ports"][index], state))
        outbounds.append(client_outbound(name, name + "-warp", state["ports"][index + 10], state))
    tags = [outbound["tag"] for outbound in outbounds]
    outbounds.append({"type": "selector", "tag": "select", "outbounds": tags, "default": tags[0]})
    return {"log": {"level": "warn"},
            "inbounds": [{"type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": 2080}],
            "outbounds": outbounds, "route": {"final": "select"}}


def write_exports(state, config=None):
    links = build_subscription_links(state, config)
    atomic_write(EXPORT / "MeowSingboxPlus-links.txt", "\n".join(links) + "\n")
    encoded = base64.b64encode("\n".join(links).encode()).decode()
    atomic_write(EXPORT / "MeowSingboxPlus-subscription.txt", encoded + "\n")
    client = build_client_config(state, config)
    atomic_write(EXPORT / "MeowSingboxPlus-sing-box-client.json", json.dumps(client, ensure_ascii=False, indent=2) + "\n")
    atomic_write(EXPORT / "MeowSingboxPlus-sing-box-outbounds.json",
                 json.dumps({"outbounds": client["outbounds"][:20]}, ensure_ascii=False, indent=2) + "\n")
    ports = []
    for index, name in enumerate(NAMES):
        for offset, suffix in ((0, ""), (10, "-warp")):
            protocol = "udp" if name in UDP_NAMES else "tcp"
            if name in ("ss", "ss2022"):
                protocol = "tcp,udp"
            ports.append(f"{state['ports'][index + offset]}/{protocol}  {name}{suffix}")
    atomic_write(EXPORT / "firewall-ports.txt", "\n".join(ports) + "\n")
    return links


def load_state():
    if not STATE.exists():
        return None
    try:
        data = json.loads(STATE.read_text(encoding="utf-8"))
        if data.get("schema") != 1 or len(data.get("ports", [])) != 20 or len(set(data["ports"])) != 20:
            fail("现有 state.json 格式异常；为保护现有凭据，停止更新。")
        return data
    except (ValueError, OSError) as exc:
        fail(f"无法读取现有部署状态：{exc}")


def save_state(state):
    atomic_write(STATE, json.dumps(state, ensure_ascii=False, indent=2) + "\n")


def systemd_unit():
    return f"""[Unit]
Description=MeowSingboxPlus sing-box proxy service
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
ExecStart={BIN} run -c {CONFIG} -D {DATA}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_RAW
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths={DATA}

[Install]
WantedBy=multi-user.target
"""


def snapshot_files(paths):
    saved = {}
    for path in paths:
        path = Path(path)
        saved[str(path)] = (path.read_bytes(), path.stat().st_mode & 0o777) if path.is_file() else None
    return saved


def restore_files(saved):
    for name, entry in saved.items():
        path = Path(name)
        if entry is None:
            path.unlink(missing_ok=True)
        else:
            content, mode = entry
            atomic_write(path, content, mode)


def check_release_binary(candidate, config_file):
    run([str(candidate), "check", "-c", str(config_file)], timeout=60)


def firewall_rules(state):
    ufw = shutil.which("ufw")
    firewalld = shutil.which("firewall-cmd")
    if ufw:
        status = run([ufw, "status"], capture=True, check=False)
        if status and "Status: active" in (status.stdout or ""):
            opened = True
            for index, name in enumerate(NAMES):
                for offset in (0, 10):
                    port = state["ports"][index + offset]
                    protocols = ("tcp", "udp") if name in ("ss", "ss2022") else (("udp",) if name in UDP_NAMES else ("tcp",))
                    for protocol in protocols:
                        result = run([ufw, "allow", f"{port}/{protocol}", "comment", "MeowSingboxPlus"], check=False)
                        opened = opened and result is not None and result.returncode == 0
            say("已在启用的 UFW 中放行本脚本使用的端口。" if opened else
                "UFW 部分端口放行失败，请按 export/firewall-ports.txt 手动检查。")
            return
    if firewalld:
        state_result = run([firewalld, "--state"], capture=True, check=False)
        if state_result and state_result.returncode == 0:
            opened = True
            for index, name in enumerate(NAMES):
                for offset in (0, 10):
                    port = state["ports"][index + offset]
                    protocols = ("tcp", "udp") if name in ("ss", "ss2022") else (("udp",) if name in UDP_NAMES else ("tcp",))
                    for protocol in protocols:
                        result = run([firewalld, "--permanent", "--add-port", f"{port}/{protocol}"], check=False)
                        opened = opened and result is not None and result.returncode == 0
            result = run([firewalld, "--reload"], check=False)
            opened = opened and result is not None and result.returncode == 0
            say("已在启用的 firewalld 中放行本脚本使用的端口。" if opened else
                "firewalld 部分端口放行失败，请按 export/firewall-ports.txt 手动检查。")
            return
    say("未修改防火墙。若 VPS 服务商有云防火墙，请允许 export/firewall-ports.txt 中的 TCP/UDP 端口。")


def build_canary_config(state, local_ports):
    if len(local_ports) != 2 or local_ports[0] == local_ports[1]:
        fail("出口检查需要两个不同的本地端口。")
    local_state = dict(state, host="::1" if state.get("listen") == "::" else "127.0.0.1")
    outbounds = [client_outbound("ss2022", "direct-test", state["ports"][6], local_state),
                 client_outbound("ss2022", "warp-test", state["ports"][16], local_state)]
    return {"log": {"level": "error"},
            "inbounds": [
                {"type": "mixed", "tag": "direct-canary-in", "listen": "127.0.0.1", "listen_port": local_ports[0]},
                {"type": "mixed", "tag": "warp-canary-in", "listen": "127.0.0.1", "listen_port": local_ports[1]},
            ],
            "outbounds": outbounds,
            "route": {"rules": [
                {"inbound": ["direct-canary-in"], "outbound": "direct-test"},
                {"inbound": ["warp-canary-in"], "outbound": "warp-test"},
            ], "final": "direct-test"}}


def canary(state, candidate):
    config_path = ROOT / ".canary-client.json"
    reservations = [socket.socket(), socket.socket()]
    try:
        for reserve in reservations:
            reserve.bind(("127.0.0.1", 0))
        local_ports = [reserve.getsockname()[1] for reserve in reservations]
    finally:
        for reserve in reservations:
            reserve.close()
    canary_config = build_canary_config(state, local_ports)
    atomic_write(config_path, json.dumps(canary_config), 0o600)
    process = subprocess.Popen([str(candidate), "run", "-c", str(config_path), "-D", str(DATA)],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        ready = False
        for _ in range(40):
            if process.poll() is not None:
                fail("sing-box 客户端连通性检查进程提前退出。")
            try:
                for local_port in local_ports:
                    with socket.create_connection(("127.0.0.1", local_port), timeout=0.3):
                        pass
                ready = True
                break
            except OSError:
                time.sleep(0.25)
        if not ready:
            fail("sing-box 客户端连通性检查未能启动本地监听。")
        for local_port, expected in ((local_ports[0], "warp=off"), (local_ports[1], "warp=on")):
            url = "https://www.cloudflare.com/cdn-cgi/trace"
            command = ["curl", "--silent", "--show-error", "--fail", "--max-time", "25",
                       "--retry", "1", "--retry-delay", "2", "--retry-max-time", "55",
                       "--noproxy", "", "--proxy", f"socks5h://127.0.0.1:{local_port}", url]
            result = run(command, capture=True, timeout=65, check=False)
            if result is None or result.returncode or expected not in (result.stdout or ""):
                detail = (result.stderr or "").strip() if result else "curl 检查未能执行"
                if result and not result.returncode:
                    detail = "收到的 trace 中未包含预期出口标记"
                route = "WARP" if expected == "warp=on" else "直连"
                message = f"{route} 出口检查未通过（期望 Cloudflare trace 包含 {expected}）。{detail}"
                if expected == "warp=on":
                    raise WarpProbeFailure(message)
                fail(message)
        say("直连与 WARP 出口检查通过。")
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        config_path.unlink(missing_ok=True)


def validate_service(state, candidate):
    result = run(["systemctl", "is-active", SERVICE], capture=True, check=False)
    if not result or result.returncode:
        detail = run(["journalctl", "-u", SERVICE, "-n", "30", "--no-pager"], capture=True, check=False)
        fail("systemd 服务未能启动。\n" + ((detail.stdout or "") if detail else ""))
    canary(state, candidate)


def validate_with_warp_fallback(state, candidate):
    try:
        validate_service(state, candidate)
        return
    except WarpProbeFailure as exc:
        last_error = exc
    # Cloudflare's documented WireGuard fallback UDP ports. Only use them for
    # the Cloudflare endpoint emitted by wgcf, never an arbitrary custom peer.
    if state["warp"]["endpoint_host"] != "engage.cloudflareclient.com":
        raise last_error
    current = state["warp"]["endpoint_port"]
    for port in (500, 1701, 4500, 2408):
        if port == current:
            continue
        say(f"WARP UDP {state['warp']['endpoint_port']} 检查失败，尝试备用端口 {port}…")
        state["warp"]["endpoint_port"] = port
        atomic_write(CONFIG, json.dumps(build_server_config(state), ensure_ascii=False, indent=2) + "\n", 0o600)
        run(["systemctl", "restart", SERVICE], timeout=60)
        try:
            validate_service(state, candidate)
            return
        except WarpProbeFailure as exc:
            last_error = exc
    raise last_error


def activate(state, candidate, tag):
    stage_config = ROOT / ".config.new.json"
    config_data = json.dumps(build_server_config(state), ensure_ascii=False, indent=2) + "\n"
    atomic_write(stage_config, config_data, 0o600)
    check_release_binary(candidate, stage_config)
    client_file = ROOT / ".client.new.json"
    atomic_write(client_file, json.dumps(build_client_config(state)), 0o600)
    check_release_binary(candidate, client_file)
    export_paths = [EXPORT / name for name in (
        "MeowSingboxPlus-links.txt", "MeowSingboxPlus-subscription.txt",
        "MeowSingboxPlus-sing-box-client.json", "MeowSingboxPlus-sing-box-outbounds.json", "firewall-ports.txt")]
    paths = (BIN, CONFIG, UNIT, DROPIN, STATE, ROOT / "installed-version.txt", *export_paths)
    snapshot = snapshot_files(paths)
    was_active = run(["systemctl", "is-active", SERVICE], capture=True, check=False)
    was_enabled = run(["systemctl", "is-enabled", SERVICE], capture=True, check=False)
    backup = ROOT / "backups" / (time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()) + "-" + uuid.uuid4().hex[:8])
    backup.mkdir(mode=0o700)
    for name, entry in snapshot.items():
        if entry:
            content, mode = entry
            atomic_write(backup / Path(name).name, content, mode if Path(name) != BIN else 0o700)
    try:
        atomic_write(BIN, candidate.read_bytes(), 0o755)
        atomic_write(CONFIG, config_data, 0o600)
        atomic_write(UNIT, systemd_unit(), 0o644)
        DROPIN.parent.mkdir(parents=True, exist_ok=True)
        atomic_write(DROPIN, "[Service]\nAmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_RAW\nCapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_RAW\n", 0o644)
        run(["systemctl", "daemon-reload"])
        run(["systemctl", "enable", SERVICE])
        run(["systemctl", "restart" if was_active and was_active.returncode == 0 else "start", SERVICE], timeout=60)
        validate_with_warp_fallback(state, BIN)
        atomic_write(ROOT / "installed-version.txt", tag + "\n", 0o600)
        state["version"] = tag
        save_state(state)
        write_exports(state)
    except Exception:
        say("部署验证失败，正在恢复此前的 MeowSingboxPlus 服务文件…")
        run(["systemctl", "stop", SERVICE], check=False, timeout=30)
        if not was_enabled or was_enabled.returncode:
            run(["systemctl", "disable", SERVICE], check=False)
        restore_files(snapshot)
        run(["systemctl", "daemon-reload"], check=False)
        if was_active and was_active.returncode == 0:
            restored = run(["systemctl", "start", SERVICE], check=False, timeout=60)
            if restored is None or restored.returncode:
                say("旧服务恢复启动失败，请检查 journalctl；备份目录：" + str(backup))
        raise
    finally:
        stage_config.unlink(missing_ok=True)
        client_file.unlink(missing_ok=True)


def install(host_override=None):
    if os.geteuid() != 0:
        fail("安装和更新需要 root 权限，请使用 sudo -i 或 root 登录。")
    ensure_systemd()
    ensure_dependencies()
    make_dirs()
    lock_file = ROOT / ".install.lock"
    with lock_file.open("w") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        state = load_state()
        if state is not None and host_override is None:
            host = state["host"]
        else:
            host = parse_host(host_override) if host_override else discover_host()
        if state is not None and host_override and host != state["host"]:
            state["host"] = host
        candidate, tag = install_latest_singbox()
        try:
            if state is None:
                warp = generate_warp()
                state = create_state(host, candidate, warp)
            else:
                # Keep credentials, ports, and WARP registration; use the current generated profile if present.
                state["host"] = host
                state["listen"] = listen_address(host)
                profile = WGCF_DIR / "wgcf-profile.conf"
                if profile.exists():
                    warp = parse_wgcf_profile(profile.read_text(encoding="utf-8"))
                    old_warp = state["warp"]
                    same_peer = all(old_warp.get(key) == warp.get(key) for key in ("private_key", "public_key", "endpoint_host"))
                    if same_peer and warp["endpoint_port"] == 2408 and old_warp.get("endpoint_port") in (500, 1701, 4500):
                        warp["endpoint_port"] = old_warp["endpoint_port"]
                    state["warp"] = warp
            write_certificate(state)
            activate(state, candidate, tag)
            firewall_rules(state)
            say(f"\n{APP} 部署完成：sing-box {tag}，10 种协议组合，直连 + WARP 共 20 个节点。")
            say(f"订阅文件：{EXPORT / 'MeowSingboxPlus-subscription.txt'}")
            say(f"原始链接：{EXPORT / 'MeowSingboxPlus-links.txt'}")
            say(f"sing-box 客户端配置：{EXPORT / 'MeowSingboxPlus-sing-box-client.json'}")
            say(f"推荐 v2rayN 导入（含证书固定）：{EXPORT / 'MeowSingboxPlus-sing-box-outbounds.json'}")
            say(f"端口清单：{EXPORT / 'firewall-ports.txt'}")
            say("从自己的电脑下载订阅示例：scp root@服务器地址:/opt/meowsingboxplus/export/MeowSingboxPlus-subscription.txt .")
            say("通用分享链接为兼容客户端启用了跳过自签名证书验证；建议 v2rayN 导入上面的 outbounds.json 保留证书固定。")
        finally:
            candidate.unlink(missing_ok=True)


def launch_install(host=None):
    """Run the transaction under systemd so losing the SSH connection cannot kill it."""
    if os.geteuid() != 0:
        fail("安装和更新需要 root 权限，请使用 sudo -i 或 root 登录。")
    ensure_systemd()
    if not shutil.which("systemd-run"):
        fail("缺少 systemd-run，请安装 systemd 后重试。")
    make_dirs()
    source = Path(os.environ.get("MEOWSINGBOXPLUS_SCRIPT", ""))
    if not source.is_file():
        fail("请先下载脚本为文件，再执行 sh MeowSingboxPlus.sh。")
    job = ROOT / ("install-" + uuid.uuid4().hex)
    job.mkdir(mode=0o700)
    worker = job / "MeowSingboxPlus.sh"
    atomic_write(worker, source.read_bytes(), 0o700)
    log = job / "install.log"
    atomic_write(log, "")
    result_path = job / "result.json"
    command = ["systemd-run", "--quiet", "--collect", "--unit=meowsingboxplus-install-" + uuid.uuid4().hex,
               "--property=Type=oneshot", "--property=TimeoutStartSec=30min",
               "--property=StandardOutput=append:" + str(log),
               "--property=StandardError=append:" + str(log),
               "/bin/sh", str(worker), "__worker", str(job)]
    if host:
        command += ["--host", parse_host(host)]
    run(command)
    say("安装任务已交给 systemd；SSH 断开后仍会继续。日志：" + str(log))
    offset = 0
    start_time = time.monotonic()
    while not result_path.exists():
        with log.open("r", encoding="utf-8", errors="replace") as stream:
            stream.seek(offset)
            chunk = stream.read()
            offset = stream.tell()
        if chunk:
            say(chunk.rstrip("\n"))
        if time.monotonic() - start_time > 1860:
            fail("等待超时，请查看安装日志：" + str(log))
        time.sleep(0.5)
    with log.open("r", encoding="utf-8", errors="replace") as stream:
        stream.seek(offset)
        chunk = stream.read()
    if chunk:
        say(chunk.rstrip("\n"))
    result = json.loads(result_path.read_text())
    if not result["ok"]:
        fail(result["message"] + "\n安装日志：" + str(log))


def do_export():
    if os.geteuid() != 0:
        fail("读取订阅文件需要 root 权限。")
    if not ROOT.exists():
        fail("尚未安装，请先运行 sh MeowSingboxPlus.sh。")
    with (ROOT / ".install.lock").open("a") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        state = load_state()
        if state is None:
            fail("尚未安装，请先运行 sh MeowSingboxPlus.sh。")
        write_exports(state, json.loads(CONFIG.read_text(encoding="utf-8")))
    say(f"已重新导出 20 个节点：{EXPORT}")


def do_status():
    state = load_state()
    if state is None:
        say("MeowSingboxPlus 尚未安装。")
        return
    result = run(["systemctl", "is-active", SERVICE], capture=True, check=False)
    version = run([str(BIN), "version"], capture=True, check=False) if BIN.exists() else None
    say(f"服务状态：{(result.stdout or 'unknown').strip() if result else 'unknown'}")
    say(f"sing-box：{(version.stdout or 'unknown').splitlines()[0] if version and version.stdout else 'unknown'}")
    say(f"节点数量：20（10 种协议组合 × 直连/WARP）")
    say(f"订阅文件：{EXPORT / 'MeowSingboxPlus-subscription.txt'}")


def usage():
    print("""MeowSingboxPlus

  sh MeowSingboxPlus.sh                 安装最新稳定版并生成 20 个节点
  sh MeowSingboxPlus.sh --host example.com
  sh MeowSingboxPlus.sh update           更新 sing-box 并保留节点凭据、端口
  sh MeowSingboxPlus.sh export           重新导出订阅和客户端配置
  sh MeowSingboxPlus.sh status           查看服务状态
  sh MeowSingboxPlus.sh help

支持：VLESS Reality、VLESS gRPC Reality、Trojan Reality、Hysteria2、
VMess WS、Hysteria2 Salamander、Shadowsocks 2022、Shadowsocks、TUIC v5、AnyTLS；
每种协议都生成直连和 Cloudflare WARP 出口节点。
""")


def main(argv):
    args = list(argv)
    host = None
    if "--host" in args:
        index = args.index("--host")
        if index + 1 >= len(args):
            fail("--host 后需要公网 IP 或域名。")
        host = args[index + 1]
        del args[index:index + 2]
    command = args.pop(0) if args else "install"
    if command == "__worker":
        if len(args) != 1:
            fail("内部安装任务参数错误。")
        job = Path(args[0])
        result = {"ok": False, "message": "安装任务异常退出"}
        try:
            install(host)
            # Persist management commands even if the waiting SSH process is gone.
            atomic_write(ROOT / "MeowSingboxPlus.sh", Path(os.environ["MEOWSINGBOXPLUS_SCRIPT"]).read_bytes(), 0o700)
            result = {"ok": True, "message": "安装完成"}
        except Exception as exc:
            result = {"ok": False, "message": str(exc)}
            say("[错误] " + str(exc))
        finally:
            atomic_write(job / "result.json", json.dumps(result, ensure_ascii=False))
        if not result["ok"]:
            sys.exit(1)
        return
    if args:
        fail("未知参数：" + " ".join(args) + "（运行 help 查看用法）")
    if command in ("install", "update"):
        launch_install(host)
    elif command == "export":
        do_export()
    elif command == "status":
        do_status()
    elif command in ("help", "--help", "-h"):
        usage()
    else:
        fail(f"未知命令：{command}（运行 help 查看用法）")


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except (RuntimeError, OSError, ValueError, KeyError) as exc:
        print(f"[错误] {exc}", file=sys.stderr, flush=True)
        sys.exit(1)
# --- PYTHON PROGRAM END ---
MEOWSINGBOXPLUS_PY
