#!/usr/bin/env bash
set -e

echo "=== 开始初始化优选环境 ==="
mkdir -p result

# 1. 编译运行根目录下的 Go 测速程序
if [ -f "main.go" ]; then
    echo "正在编译 Go 测速程序..."
    go build -o cf-speedtest main.go
    echo "开始执行 IP 优选测速..."
    ./cf-speedtest -t 200 -n 10 > result/raw_result.txt
else
    echo "未检测到 main.go，开始下载 XIU2/CloudflareSpeedTest 二进制文件..."
    
    # 动态获取最新的 Release 版本下载地址（跟随 302 重定向 `-L`）
    DOWNLOAD_URL=$(curl -s https://api.github.com/repos/XIU2/CloudflareSpeedTest/releases/latest | grep "browser_download_url.*CloudflareSpeedTest_linux_amd64.tar.gz" | cut -d '"' -f 4)
    
    # 如果 API 请求受限或未获取到，使用备用固定链接
    if [ -z "$DOWNLOAD_URL" ]; then
        DOWNLOAD_URL="https://github.com/XIU2/CloudflareSpeedTest/releases/download/v2.2.5/CloudflareSpeedTest_linux_amd64.tar.gz"
    fi

    echo "下载链接: $DOWNLOAD_URL"
    
    # 使用 -L 允许重定向，-f 在 404/500 时直接报错停止
    curl -sSLf "$DOWNLOAD_URL" -o speedtest.tar.gz
    
    # 检查文件是否正常下载
    if [ ! -s speedtest.tar.gz ]; then
        echo "错误：下载的压缩包为空，请检查网络或 GitHub Release 链接！"
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

# 3. 生成配置与信息
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
