#!/usr/bin/env bash
set -e

echo "=== 开始初始化优选环境 ==="
mkdir -p result

# 1. 编译运行根目录下的 Go 测速程序（如果使用的是开源的 CloudflareSpeedTest 二进制，亦可在此下载）
if [ -f "main.go" ]; then
    echo "正在编译 Go 测速程序..."
    go build -o cf-speedtest main.go
    echo "开始执行 IP 优选测速..."
    ./cf-speedtest -t 200 -n 10 > result/raw_result.txt
else
    echo "未检测到 main.go，下载第三方开源二进制文件示例 (XIU2/CloudflareSpeedTest)..."
    curl -sSL https://github.com/XIU2/CloudflareSpeedTest/releases/download/v2.2.5/CloudflareSpeedTest_linux_amd64.tar.gz | tar -zxvf - CloudflareSpeedTest
    ./CloudflareSpeedTest -n 500 -pt 10 -o result/result.csv
fi

# 2. 提取纯 IP 列表
echo "正在提取最优 IP..."
if [ -f "result/result.csv" ]; then
    # 解析 CSV 文件的 IP 列（适配 XIU2 格式）
    awk -F',' 'NR>1 {print $1}' result/result.csv | head -n 10 > result/ip.txt
elif [ -f "result/raw_result.txt" ]; then
    # 提取输出格式中的 IP
    grep -E '([0-9]{1,3}\.){3}[0-9]{1,3}' result/raw_result.txt | head -n 10 > result/ip.txt
fi

# 3. 生成 Base64 格式简单订阅示例 (如 VLESS/VMess/Trojan 替换 IP)
echo "正在生成订阅与节点文件..."
BEST_IP=$(head -n 1 result/ip.txt || echo "104.16.1.1")

# 示例：替换模版中的优选 IP，生成配置文件
cat <<EOF > result/best_ip.json
{
  "updated_at": "$(date -u +'%Y-%m-%d %H:%M:%S UTC')",
  "best_ip": "${BEST_IP}",
  "ips": [
$(sed 's/^/"/;s/$/",/' result/ip.txt | sed '$ s/,$//')
  ]
}
EOF

echo "=== 测速与生成完毕 ==="
