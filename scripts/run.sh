#!/usr/bin/env bash
set -e

mkdir -p result

if [ -f "main.go" ]; then
    echo "正在编译 Go 测速程序..."
    go build -o cf-speedtest main.go
    echo "开始执行 IP 优选测速..."
    ./cf-speedtest -t 200 -n 10 > result/raw_result.txt
else
    echo "未检测到 main.go，开始下载 XIU2/CloudflareSpeedTest 二进制文件..."
    
    # 1. 尝试通过 GitHub API 自动抓取最新版本的 Tag 名
    LATEST_TAG=$(curl -sSL "https://api.github.com/repos/XIU2/CloudflareSpeedTest/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    
    # 2. 如果 API 被限流或失败，回退到指定的稳定 Tag
    if [ -z "$LATEST_TAG" ]; then
        LATEST_TAG="v2.2.5"
    fi
    
    # 移除 Tag 中的 v 前缀（适应不同发布版本的命名格式）
    VERSION_NUM="${LATEST_TAG#v}"

    echo "识别到版本 Tag: ${LATEST_TAG} (版本号: ${VERSION_NUM})"

    # 构造可能的下载 URL 列表（处理带 v 和不带 v 的两种常见 Release 文件命名）
    URLS=(
        "https://github.com/XIU2/CloudflareSpeedTest/releases/download/${LATEST_TAG}/CloudflareSpeedTest_linux_amd64.tar.gz"
        "https://github.com/XIU2/CloudflareSpeedTest/releases/download/${LATEST_TAG}/CloudflareSpeedTest_${VERSION_NUM}_linux_amd64.tar.gz"
        "https://github.com/XIU2/CloudflareSpeedTest/releases/download/v2.2.5/CloudflareSpeedTest_linux_amd64.tar.gz"
    )

    SUCCESS=0
    for URL in "${URLS[@]}"; do
        echo "尝试下载: $URL"
        if curl -sSLf "$URL" -o speedtest.tar.gz; then
            SUCCESS=1
            break
        fi
    done

    if [ $SUCCESS -ne 1 ]; then
        echo "错误：所有下载链接均失败，请检查网络或 GitHub Release 状态！"
        exit 1
    fi

    tar -zxvf speedtest.tar.gz CloudflareSpeedTest
    rm -f speedtest.tar.gz
    chmod +x CloudflareSpeedTest

    echo "开始运行 CloudflareSpeedTest 测速..."
    ./CloudflareSpeedTest -n 500 -pt 10 -o result/result.csv
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
