#!/bin/bash

INSTALL_DIR="/opt/ip_sentinel"
CONFIG_FILE="${INSTALL_DIR}/config.conf"
IP_CACHE="${INSTALL_DIR}/core/.last_ip"

[ ! -f "$CONFIG_FILE" ] && exit 1
source "$CONFIG_FILE"

if [ -z "$AGENT_TOKEN" ] && [ -z "$CHAT_ID" ]; then
    echo "Error: Comm credentials (AGENT_TOKEN and CHAT_ID) are missing. Agent exit." >&2
    exit 1
fi

[ -z "$TG_TOKEN" ] || [ -z "$CHAT_ID" ] && exit 0

AGENT_PORT=${AGENT_PORT:-9527}

if [ -z "$NODE_NAME" ]; then
    IP_HASH=$(echo "${PUBLIC_IP:-127.0.0.1}" | md5sum | cut -c 1-4 | tr 'a-z' 'A-Z')
    NODE_NAME="$(hostname | tr -cd 'a-zA-Z0-9' | cut -c 1-10)-${IP_HASH}"
fi
NODE_ALIAS="${NODE_ALIAS:-$NODE_NAME}"

RAW_IP=$(curl -${IP_PREF:-4} -s -m 5 api.ip.sb/ip | tr -d '[:space:]')

if [ -n "$RAW_IP" ]; then
    if [[ "$RAW_IP" == *":"* ]] && [[ "$RAW_IP" != *"["* ]]; then
        AGENT_IP="[${RAW_IP}]"
    else
        AGENT_IP="$RAW_IP"
    fi
else
    AGENT_IP="${PUBLIC_IP:-${BIND_IP:-Unknown}}"
fi

if [ -n "$AGENT_IP" ]; then
    LAST_IP=""
    [ -f "$IP_CACHE" ] && LAST_IP=$(cat "$IP_CACHE" | tr -d '[:space:]')

    if [ "$AGENT_IP" != "$LAST_IP" ]; then
                echo "$AGENT_IP" > "$IP_CACHE"
        echo "ℹ️ [Agent] 发现本地 IP 变动，已静默更新缓存: $AGENT_IP"
    else
        echo "ℹ️ [Agent] IP 未变动 ($AGENT_IP)，继续后台静默监听。"
    fi
fi

echo "🌐 [Agent] 底层网络栈已解锁，准备切入双栈监听模式 (Dual-Stack Universal Bind)"

CERT_FILE="${INSTALL_DIR}/core/cert.pem"
KEY_FILE="${INSTALL_DIR}/core/key.pem"

# 检查证书是否在特定版本前生成，若是则重新生成证书以确保兼容性
if [ -f "$CERT_FILE" ]; then
    CERT_DATE=$(openssl x509 -noout -startdate -in "$CERT_FILE" 2>/dev/null | cut -d= -f2)
    if [[ -n "$CERT_DATE" ]]; then
        CERT_EPOCH=$(date -d "$CERT_DATE" +%s 2>/dev/null || echo 0)
        V422_EPOCH=$(date -d "2026-05-31" +%s 2>/dev/null || echo 1780185600)
        if [ "$CERT_EPOCH" -lt "$V422_EPOCH" ]; then
            echo "🧹 [Agent] 侦测到旧版 (v4.2.2 前) 遗留 TLS 装甲，正在执行强制删除..."
            rm -f "$CERT_FILE" "$KEY_FILE"
        fi
    fi
fi
CERT_FILE="${INSTALL_DIR}/core/cert.pem"
KEY_FILE="${INSTALL_DIR}/core/key.pem"
if [ ! -f "$CERT_FILE" ] || [ ! -f "$KEY_FILE" ]; then
    echo "🔐 [Agent] 正在生成本地自签名 TLS 加密证书 (2048位 RSA)..."
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout "$KEY_FILE" -out "$CERT_FILE" \
        -subj "/C=US/O=IP-Sentinel/CN=Agent-Sec" >/dev/null 2>&1 || true
fi

cat > "${INSTALL_DIR}/core/webhook.py" << 'EOF'
import http.server
import socketserver
import subprocess
import sys
import os
import html
import urllib.parse
import urllib.request
import hmac
import hashlib
import time

try:
    import fcntl
except ImportError:
    import sys
    from types import ModuleType
    mock_fcntl = ModuleType('fcntl')
    mock_fcntl.LOCK_EX = 1
    mock_fcntl.LOCK_SH = 2
    mock_fcntl.LOCK_NB = 4
    mock_fcntl.LOCK_UN = 8
    def flock(fd, operation):
        pass
    mock_fcntl.flock = flock
    sys.modules['fcntl'] = mock_fcntl

PORT = int(sys.argv[1])

USED_SIGNS = {}
def clean_used_signs():
    now = time.time()
    expired = [s for s, t in USED_SIGNS.items() if now - t > 65]
    for s in expired:
        del USED_SIGNS[s]

def write_agent_log(msg_text):
    now_str = time.strftime('%Y-%m-%d %H:%M:%S')
    log_line = f"[{now_str} UTC] [SECURITY WARNING] {msg_text}\n"
    sys.stderr.write(log_line)
    sys.stderr.flush()
    log_dir = '/opt/ip_sentinel/logs'
    if not os.path.exists(log_dir):
        os.makedirs(log_dir, exist_ok=True)
    try:
        with open(os.path.join(log_dir, 'sentinel.log'), 'a', encoding='utf-8') as lf:
            lf.write(log_line)
    except Exception:
        pass

def log_to_sentinel(module, level, msg):
    config = {}
    if os.path.exists('/opt/ip_sentinel/config.conf'):
        try:
            with open('/opt/ip_sentinel/config.conf', 'r', encoding='utf-8', errors='ignore') as f:
                for line in f:
                    line = line.strip()
                    if '=' in line and not line.startswith('#'):
                        k, v = line.split('=', 1)
                        config[k.strip()] = v.strip('"\'')
        except Exception:
            pass
    now_str = time.strftime('%Y-%m-%d %H:%M:%S')
    local_ver = config.get('AGENT_VERSION', '未知')
    region_code = config.get('REGION_CODE', 'US')
    log_line = f"[{now_str} UTC] [v{local_ver:<5}] [{level:<5}] [{module:<7}] [{region_code}] {msg}\n"
    sys.stderr.write(log_line)
    sys.stderr.flush()
    log_dir = '/opt/ip_sentinel/logs'
    if not os.path.exists(log_dir):
        os.makedirs(log_dir, exist_ok=True)
    try:
        with open(os.path.join(log_dir, 'sentinel.log'), 'a', encoding='utf-8') as lf:
            lf.write(log_line)
    except Exception:
        pass

local_agent_token = ""
chat_id_token = ""
if os.path.exists('/opt/ip_sentinel/config.conf'):
    with open('/opt/ip_sentinel/config.conf', 'r', encoding='utf-8', errors='ignore') as f:
        for line in f:
            line = line.strip()
            if line.startswith('AGENT_TOKEN='):
                local_agent_token = line.split('=', 1)[1].strip('"\'')
            elif line.startswith('CHAT_ID='):
                chat_id_token = line.split('=', 1)[1].strip('"\'')

# 通信凭证双重验证，若均未配置则退出以保障安全
if not local_agent_token and not chat_id_token:
    sys.stderr.write("Error: Comm credentials (AGENT_TOKEN and CHAT_ID) are missing. Agent exit.\n")
    sys.stderr.flush()
    sys.exit(1)
    
AUTH_TOKEN = local_agent_token if local_agent_token else chat_id_token

class AgentHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        import os
        parsed = urllib.parse.urlparse(self.path)
        req_path = parsed.path
        
        query = urllib.parse.parse_qs(parsed.query)
        req_t = query.get('t', [''])[0]
        req_sign = query.get('sign', [''])[0]
        
        if not req_t or not req_sign:
            write_agent_log(f"Rejected request: Missing Signature or Timestamp. Path: {req_path}, t: {req_t}, sign: {req_sign}")
            self.send_response(401)
            self.end_headers()
            self.wfile.write(b"401 Unauthorized: Missing Signature\n")
            return
            
        try:
            current_time = int(time.time())
            # 校验时间戳防重放 (±60秒窗口)
            if abs(current_time - int(req_t)) > 60:
                write_agent_log(f"Rejected request: Timestamp expired. Path: {req_path}, t: {req_t}, Server t: {current_time}, Received sign: {req_sign}")
                self.send_response(401)
                self.end_headers()
                self.wfile.write(b"401 Unauthorized: Request Expired\n")
                return
        except ValueError:
            write_agent_log(f"Rejected request: Invalid Timestamp. Path: {req_path}, t: {req_t}, Received sign: {req_sign}")
            self.send_response(401)
            self.end_headers()
            return
        
        # 登记签名以防重放
        clean_used_signs()
        if req_sign in USED_SIGNS:
            write_agent_log(f"Rejected request: Replay Attack Detected. Path: {req_path}, Sign: {req_sign}")
            self.send_response(401)
            self.end_headers()
            self.wfile.write(b"401 Unauthorized: Replay Attack Detected\n")
            return
            
        sig_params = []
        for key in sorted(query.keys()):
            if key in ['sign', 't']:
                continue
            val = query[key][0]
            sig_params.append(f"{key}={val}")
            
        sorted_query_str = "&".join(sig_params)
        
        if sorted_query_str:
            msg = f"{req_path}:{sorted_query_str}:{req_t}".encode('utf-8')
        else:
            msg = f"{req_path}:{req_t}".encode('utf-8')
            
        expected_sign = hmac.new(AUTH_TOKEN.encode('utf-8'), msg, hashlib.sha256).hexdigest()
        
        if not hmac.compare_digest(expected_sign, req_sign):
            write_agent_log(f"Rejected request: Signature Mismatch. Path: {req_path}, Expected sign: {expected_sign}, Received sign: {req_sign}, Payload: {msg.decode('utf-8', errors='ignore')}")
            self.send_response(401)
            self.end_headers()
            self.wfile.write(b"401 Unauthorized: Signature Mismatch\n")
            return
        
        USED_SIGNS[req_sign] = current_time

        
        if req_path == '/trigger_run':
            if os.path.exists('/opt/ip_sentinel/core/runner.sh'):
                log_to_sentinel("SYSTEM", "INFO", "通过 Webhook 外部唤醒全局巡逻调度程序...")
                self.send_response(200)
                self.send_header("Content-type", "text/plain")
                self.end_headers()
                self.wfile.write(b"Action Accepted: runner\n")
                os.system("nohup bash /opt/ip_sentinel/core/runner.sh >/dev/null 2>&1 &")
            else:
                self.send_response(404)
                self.end_headers()
                
        elif req_path == '/trigger_google':
            if os.path.exists('/opt/ip_sentinel/core/mod_google.sh'):
                log_to_sentinel("Google", "START", "通过 Webhook 外部手动触发 Google 区域纠偏任务...")
                self.send_response(200)
                self.send_header("Content-type", "text/plain")
                self.end_headers()
                self.wfile.write(b"Action Accepted: mod_google\n")
                os.system("nohup bash /opt/ip_sentinel/core/mod_google.sh >/dev/null 2>&1 &")
            else:
                self.send_response(403)
                self.send_header("Content-type", "text/plain")
                self.end_headers()
                self.wfile.write(b"403 Forbidden: Google Module Disabled\n")

        elif req_path == '/trigger_trust':
            if os.path.exists('/opt/ip_sentinel/core/mod_trust.sh'):
                log_to_sentinel("Trust", "START", "通过 Webhook 外部手动触发 IP 信用净化任务...")
                self.send_response(200)
                self.send_header("Content-type", "text/plain")
                self.end_headers()
                self.wfile.write(b"Action Accepted: mod_trust\n")
                os.system("nohup bash /opt/ip_sentinel/core/mod_trust.sh >/dev/null 2>&1 &")
            else:
                self.send_response(403)
                self.send_header("Content-type", "text/plain")
                self.end_headers()
                self.wfile.write(b"403 Forbidden: Trust Module Disabled\n")

        elif req_path == '/trigger_report':
            log_to_sentinel("Report", "START", "通过 Webhook 外部手动触发战报生成与发送...")
            self.send_response(200)
            self.send_header("Content-type", "text/plain")
            self.end_headers()
            self.wfile.write(b"Action Accepted: tg_report\n")
            os.system("nohup bash /opt/ip_sentinel/core/tg_report.sh >/dev/null 2>&1 &")

        elif req_path == '/trigger_log':
            self.send_response(200)
            self.send_header("Content-type", "text/plain")
            self.end_headers()
            self.wfile.write(b"Action Accepted: fetch_log\n")
                        
            try:
                config = {}
                if os.path.exists('/opt/ip_sentinel/config.conf'):
                    with open('/opt/ip_sentinel/config.conf', 'r', encoding='utf-8', errors='ignore') as f:
                        for line in f:
                            line = line.strip()
                            if '=' in line and not line.startswith('#'):
                                key, val = line.split('=', 1)
                                config[key] = val.strip('"\'')
                
                log_data = "日志文件不存在或为空"
                log_path = '/opt/ip_sentinel/logs/sentinel.log'
                if os.path.exists(log_path):
                    with open(log_path, 'r', encoding='utf-8', errors='ignore') as f:
                        lines = f.readlines()
                        if lines:
                            log_data = html.escape("".join(lines[-15:]))
                
                local_ver = config.get('AGENT_VERSION', '未知')
                node_alias = config.get('NODE_ALIAS', config.get('NODE_NAME', 'Unknown-Node'))
                
                text_msg = f"📄 <b>[{node_alias}] 实时日志 (v{local_ver}):</b>\n<pre><code>{log_data}</code></pre>"
                
                import json
                node_name_cb = config.get('NODE_NAME', 'Unknown')
                payload = {
                    'chat_id': config.get('CHAT_ID', ''),
                    'text': text_msg,
                    'parse_mode': 'HTML',
                    'reply_markup': {
                        'inline_keyboard': [[{'text': '⚙️ 调出该节点控制台', 'callback_data': f'manage:{node_name_cb}'}]]
                    }
                }
                data = json.dumps(payload).encode('utf-8')
                
                req = urllib.request.Request(
                    config.get('TG_API_URL', ''), 
                    data=data,
                    headers={
                        'User-Agent': f'IP-Sentinel-Agent/{local_ver}',
                        'Content-Type': 'application/json'
                    }
                )
                urllib.request.urlopen(req, timeout=10)
                
            except Exception as e:
                print(f"Log transmission failed: {e}")

        elif req_path == '/trigger_quality':
            self.send_response(200)
            self.send_header("Content-type", "text/plain")
            self.end_headers()
            self.wfile.write(b"Action Accepted: trigger_quality\n")
            
            if os.path.exists('/opt/ip_sentinel/core/mod_quality.sh'):
                log_to_sentinel("Quality", "START", "通过 Webhook 外部手动触发网络质量自检任务...")
                os.system("nohup bash /opt/ip_sentinel/core/mod_quality.sh >/dev/null 2>&1 &")

        elif req_path == '/trigger_rename':
            b64_alias = query.get('b64', [''])[0]
            if not b64_alias:
                self.send_response(400)
                self.end_headers()
                self.wfile.write(b"400 Bad Request: Alias is empty\n")
                return
                
            import re
            import base64
            try:
                # 还原 Base64 编码以防止注入风险
                pad = len(b64_alias) % 4
                if pad > 0:
                    b64_alias += '=' * (4 - pad)
                b64_alias = b64_alias.replace('-', '+').replace('_', '/')
                raw_alias = base64.b64decode(b64_alias).decode('utf-8', errors='ignore')
                
                # 强格式清洗：剔除潜在非法字符，保护 TG 面板不被恶意解析撑爆
                decoded_alias = raw_alias.replace('_', '-')
                safe_alias = re.sub(r'[^a-zA-Z0-9\-\u4e00-\u9fa5]', '', decoded_alias)[:20]
                
                if safe_alias:
                    # 使用文件锁防止并发写入冲突导致配置文件损坏
                    config_path = '/opt/ip_sentinel/config.conf'
                    import fcntl
                    with open(config_path, 'r+', encoding='utf-8', errors='ignore') as f:
                        fcntl.flock(f, fcntl.LOCK_EX)
                        lines = f.readlines()
                        
                        alias_found = False
                        for i, line in enumerate(lines):
                            if line.startswith('NODE_ALIAS='):
                                lines[i] = f'NODE_ALIAS="{safe_alias}"\n'
                                alias_found = True
                                break
                                
                        if not alias_found:
                            lines.append(f'NODE_ALIAS="{safe_alias}"\n')
                            
                        f.seek(0)
                        f.writelines(lines)
                        f.truncate()
                        fcntl.flock(f, fcntl.LOCK_UN)
                        
                    self.send_response(200)
                    self.send_header("Content-type", "text/plain")
                    self.end_headers()
                    self.wfile.write(b"Action Accepted: trigger_rename\n")
                    return
            except Exception as e:
                self.send_response(500)
                self.end_headers()
                self.wfile.write(f"500 Internal Error: {str(e)}\n".encode('utf-8'))
                return
            
            self.send_response(400)
            self.end_headers()
            self.wfile.write(b"400 Bad Request: Invalid Characters\n")

        elif req_path == '/trigger_toggle':
            mod_name = query.get('mod', [''])[0]
            target_state = query.get('state', [''])[0].lower()
            
            if mod_name not in ['google', 'trust'] or target_state not in ['true', 'false']:
                self.send_response(400)
                self.end_headers()
                self.wfile.write(b"400 Bad Request: Invalid parameters\n")
                return
                
            config_key = f"ENABLE_{mod_name.upper()}="
            
            try:
                config_path = '/opt/ip_sentinel/config.conf'
                import fcntl
                
                with open(config_path, 'r+', encoding='utf-8', errors='ignore') as f:
                    fcntl.flock(f, fcntl.LOCK_EX)
                    lines = f.readlines()
                    
                    found = False
                    for i, line in enumerate(lines):
                        if line.startswith(config_key):
                            lines[i] = f'{config_key}"{target_state}"\n'
                            found = True
                            break
                            
                    if not found:
                        lines.append(f'{config_key}"{target_state}"\n')
                        
                    f.seek(0)
                    f.writelines(lines)
                    f.truncate()
                    fcntl.flock(f, fcntl.LOCK_UN)
                
                self.send_response(200)
                self.send_header("Content-type", "text/plain")
                self.end_headers()
                self.wfile.write(b"Action Accepted: trigger_toggle\n")
                
            except Exception as e:
                self.send_response(500)
                self.end_headers()
                self.wfile.write(f"500 Internal Error: {str(e)}\n".encode('utf-8'))

        elif req_path == '/trigger_ota':
            try:
                config_mem = {}
                config_path = '/opt/ip_sentinel/config.conf'
                if os.path.exists(config_path):
                    with open(config_path, 'r', errors='ignore') as f:
                        for line in f:
                            line = line.strip()
                            if '=' in line and not line.startswith('#'):
                                key, val = line.split('=', 1)
                                config_mem[key] = val.strip('"\'')
                                
                if config_mem.get('ENABLE_OTA', 'false').lower() != 'true':
                    self.send_response(403)
                    self.end_headers()
                    self.wfile.write(b"403 Forbidden: OTA Upgrade Disabled locally\n")
                    return
                    
                if config_mem.get('TG_TOKEN', '') == 'OFFICIAL_GATEWAY_MODE':
                    self.send_response(403)
                    self.end_headers()
                    self.wfile.write(b"403 Forbidden: OTA strictly disabled under Public Gateway mode\n")
                    return
                    
                repo_url = "https://raw.githubusercontent.com/Gitucc/IP-Sentinel/main"
                if os.path.exists('/opt/ip_sentinel/core/install.sh'):
                    with open('/opt/ip_sentinel/core/install.sh', 'r') as f:
                        for line in f:
                            line = line.strip()
                            if line.startswith('REPO_RAW_URL='):
                                repo_url = line.split('=', 1)[1].strip('"\' \r\n')
                                break
                
                import re
                if not re.match(r'^https://[a-zA-Z0-9\-\.\/_]+$', repo_url) or ';' in repo_url or '`' in repo_url:
                    write_agent_log(f"OTA rejected: Malicious Repository URL Detected! URL: {repo_url}")
                    self.send_response(400)
                    self.end_headers()
                    self.wfile.write(b"400 Bad Request: Malicious Repository URL Detected\n")
                    return
                
                self.send_response(200)
                self.send_header("Content-type", "text/plain")
                self.end_headers()
                self.wfile.write(b"Action Accepted: trigger_ota\n")
                
                import shutil
                import base64
                err_msg = f"❌ **OTA 熔断告警**\n📍 节点: `{config_mem.get('NODE_ALIAS', '未知')}`\n⚠️ 原因: 脚本语法校验(bash -n)未通过，下载可能不完整。\n🚀 状态: 升级已取消，节点安全。"
                err_msg_b64 = base64.b64encode(err_msg.encode('utf-8')).decode('utf-8')
                
                tg_url = config_mem.get('TG_API_URL', '')
                chat_id = config_mem.get('CHAT_ID', '')
                
                # 将升级逻辑进行 Base64 编码以防指令注入
                ota_script = f"""
echo "=== [$(date '+%Y-%m-%d %H:%M:%S')] OTA 升级指令已接收，开始拉取安装包 ===" > /opt/ip_sentinel/logs/ota_upgrade.log
export SILENT_OTA="true"
curl -fsSL {repo_url}/core/install.sh -o /tmp/ota_agent.sh >> /opt/ip_sentinel/logs/ota_upgrade.log 2>&1
if bash -n /tmp/ota_agent.sh; then
    echo "=== [$(date '+%Y-%m-%d %H:%M:%S')] 安装包语法校验通过，开始执行安装 ===" >> /opt/ip_sentinel/logs/ota_upgrade.log
    bash /tmp/ota_agent.sh >> /opt/ip_sentinel/logs/ota_upgrade.log 2>&1
    echo "=== [$(date '+%Y-%m-%d %H:%M:%S')] OTA 升级流程执行完毕 ===" >> /opt/ip_sentinel/logs/ota_upgrade.log
else
    MSG=$(echo '{err_msg_b64}' | base64 -d)
    curl -s -m 10 -X POST "{tg_url}" -d "chat_id={chat_id}" -d "text=$MSG" -d "parse_mode=Markdown" > /dev/null 2>&1
    echo "=== [$(date '+%Y-%m-%d %H:%M:%S')] 错误: OTA 安装包语法校验失败，可能下载受损 ===" >> /opt/ip_sentinel/logs/ota_upgrade.log
fi
"""
                ota_script_b64 = base64.b64encode(ota_script.encode('utf-8')).decode('utf-8')
                
                if shutil.which("systemd-run"):
                    full_cmd = f"systemd-run --quiet --no-block bash -c \"echo '{ota_script_b64}' | base64 -d | bash\""
                else:
                    full_cmd = f"nohup bash -c \"echo '{ota_script_b64}' | base64 -d | bash\" >/dev/null 2>&1 &"
                    
                os.system(full_cmd)
                
            except Exception as e:
                try:
                    self.send_response(500)
                    self.end_headers()
                    self.wfile.write(f"500 Internal Error: {str(e)}\n".encode('utf-8'))
                except Exception:
                    pass

        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        pass

import socket
class DualStackServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    def server_bind(self):
        # 解除 Linux/Unix 的 IPv6 独占锁以实现双栈监听
        if self.address_family == socket.AF_INET6:
            try:
                self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
            except Exception:
                pass
        super().server_bind()

bind_addr = "::"
address_family = socket.AF_INET6
try:
    # 若内核未加载 IPv6 模块，绑定 :: 会引发 OSError，此时自动回退到 IPv4 监听
    s = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
    s.close()
except OSError:
    bind_addr = "0.0.0.0"
    address_family = socket.AF_INET

DualStackServer.address_family = address_family
httpd = DualStackServer((bind_addr, PORT), AgentHandler)

import ssl
cert_path = '/opt/ip_sentinel/core/cert.pem'
key_path = '/opt/ip_sentinel/core/key.pem'

if os.path.exists(cert_path) and os.path.exists(key_path):
    try:
        context = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
        context.load_cert_chain(certfile=cert_path, keyfile=key_path)
        httpd.socket = context.wrap_socket(httpd.socket, server_side=True)
    except Exception as e:
        print(f"SSL 隧道构建失败，退化为 HTTP: {e}")

try:
    httpd.serve_forever()
except Exception as e:
    sys.exit(1)
EOF

echo "🚀 [Agent] 正在启动 Webhook 监听服务 (端口: $AGENT_PORT)..."
exec python3 "${INSTALL_DIR}/core/webhook.py" "$AGENT_PORT"