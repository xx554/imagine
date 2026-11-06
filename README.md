# 个人自建节点 v1

## 菜单安装脚本 imagine.sh（新）

带菜单的节点搭建脚本（hy2 / vless+reality），面向 Linux，用 root 运行：

```bash
bash imagine.sh
```

首次用 root 运行后会自动安装快捷键，之后在任何目录输入 `x` 或 `X`（不区分大小写）即可打开菜单。

菜单结构：

```
主菜单
  1. 搭建节点
     1. hy2
        1. 搭建 hy2
           1. 没有域名（自签证书）
           2. 有域名
        2. 查看节点（运行状态 + 可复制到 v2rayN 的节点信息）
        3. 更换端口
        4. 卸载 hy2
     2. vless+reality（Xray）
        1. 搭建 reality
        2. 查看节点（运行状态 + 可复制到 v2rayN 的节点信息）
        3. 更换端口
        4. 卸载 reality
     （以后加新协议时在搭建节点下另起一行，如 3. xhttp）
```

- 没有域名：自动生成自签证书，客户端需开启“跳过证书验证”。
- 有域名：用 acme.sh 的 DNS 验证申请有效证书（已固定用 Let's Encrypt，不用邮箱），签发时不需要 80 端口、也不要求域名解析到本机；但节点要能用，域名仍需 A 记录指向服务器 IP（灰云）。需要 DNS 服务商 API 自动验证（Cloudflare / 阿里云 / DNSPod），签发后可自动续期。Cloudflare 建议用 API Token（权限只给 Zone:DNS:Edit + Zone:Zone:Read，区域限定为你的域名），不要用 Global API Key。
- 搭建完成后会打印连接链接（hy2://...），可导入 v2rayN / Clash-Meta 等客户端。
- vless+reality：用 Xray 官方安装脚本安装，配置按官方防偷流量模板生成（dokodemo-door 监听对外端口，转发给本机 127.0.0.1:4431 的 reality 入站；不匹配伪装域名的流量直接丢弃）。不需要域名和证书；端口默认 443，伪装域名默认 speed.cloudflare.com（可改）；UUID、x25519 密钥、shortId 自动生成。搭建完成后打印 vless:// 链接，可导入 v2rayN。reality 走 TCP 443，hy2 走 UDP 443，两者可以同时跑在 443 端口上。
- 需要 systemd 的机器才能安装开机自启服务；不支持 systemd 时脚本会给出手动启动命令。

## 本地代理脚本 node.py（旧版）

一个单文件、零依赖的本地代理节点：一个端口同时支持 **SOCKS5** 和 **HTTP(S)** 代理，
用 Python 3.8+ 就能跑，不用服务器、不用装任何第三方包。

## 快速开始

```bash
# 1. 启动（默认只监听本机 127.0.0.1:1080）
python3 node.py

# 2. 开账号认证
python3 node.py --auth myuser:mypass

# 3. 改端口、打印每个连接、每 60 秒打印一次流量统计
python3 node.py --port 18080 --log --stats-interval 60

# 4. 给局域网内其他设备用（注意：会暴露到局域网，务必开 --auth）
python3 node.py --host 0.0.0.0 --auth myuser:mypass
```

## 在客户端里怎么用

- 浏览器 / 代理工具里填 SOCKS5：`127.0.0.1:1080`
- 或者填 HTTP 代理：`127.0.0.1:1080`
- 开了认证就填上对应的用户名和密码

## 自己测试

```bash
# 先在另一个终端起一个本地网页做靶子
mkdir -p /tmp/nodetest && echo "hello-node" > /tmp/nodetest/index.html
python3 -m http.server 18081 --directory /tmp/nodetest >/dev/null 2>&1 &

# 再起节点（换个端口，避免和 1080 冲突）
python3 node.py --port 18080 --log &

# HTTP 代理测试
curl -x http://127.0.0.1:18080 http://127.0.0.1:18081/

# SOCKS5 代理测试
curl -x socks5h://127.0.0.1:18080 http://127.0.0.1:18081/

# 认证测试（节点用 --auth myuser:mypass 启动时）
curl -x http://myuser:mypass@127.0.0.1:18080 http://127.0.0.1:18081/
curl -x http://127.0.0.1:18080 http://127.0.0.1:18081/   # 没给账号，应返回 407
```

## 流量统计

- 启动时加 `--stats-interval N`，每 N 秒打印一次连接数和上下行流量。
- 按 Ctrl+C 停止时，会打印一份汇总。

## 下一步可以加的功能（等你定）

- UDP Associate（SOCKS5 UDP 转发，游戏/视频类客户端需要）
- 多用户账号
- 简单的网页面板（看在线连接和流量）
- 开机自启（systemd / LaunchAgent）
- 订阅链接生成（给 Clash / v2rayN 直接导入）
- 规则分流（只代理指定域名，其余直连）
