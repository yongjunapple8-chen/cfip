#!/usr/bin/env bash
set -e

mkdir -p result

if [ -f "main.go" ]; then
    echo "正在编译仓库根目录的 Go 测速程序..."
    go build -o cf-speedtest main.go
    echo "开始执行 IP 优选测速..."
    ./cf-speedtest -t 200 -n 10 > result/raw_result.txt
else
    echo "未检测到本地 main.go，使用 go install 直接安装 XIU2/CloudflareSpeedTest 最新版..."
    
    # 彻底告别 404！直接拉取官方源码并在 Actions 中现场编译
    go install github.com/XIU2/CloudflareSpeedTest@latest
    
    # GOBIN 默认在 ~/go/bin/CloudflareSpeedTest
    SPEEDTEST_BIN="$(go env GOPATH)/bin/CloudflareSpeedTest"

    if [ ! -f "$SPEEDTEST_BIN" ]; then
        echo "错误：CloudflareSpeedTest 编译安装失败！"
        exit 1
    fi

    echo "编译完成，开始运行 CloudflareSpeedTest 测速..."
    "$SPEEDTEST_BIN" -n 500 -pt 10 -o result/result.csv
fi

# 2. 提取纯 IP 列表
echo "正在提取最优 IP..."
if [ -f "result/result.csv" ]; then
    awk -F',' 'NR>1 {print $1}' result/result.csv | head -n 10 > result/ip.txt
elif [ -f "result/raw_result.txt" ]; then
    grep -E '([0-9]{1,3}\.){3}[0-9]{1,3}' result/raw_result.txt | head -n 10 > result/ip.txt
fi

# 3. 生成 JSON 文件
echo "正在生成订阅与节点文件..."
BEST_IP=$(head -n 1 result/ip.txt || echo "104.16.1.1")

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
