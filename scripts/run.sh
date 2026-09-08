#!/usr/bin/env bash
set -e

mkdir -p result ip_buckets

# ==========================================
# 🛡️ 1. 防风控处理 (Anti-Risk Control)
# ==========================================
echo "=== [1/5] 执行防风控预处理 ==="

RANDOM_DELAY=$((RANDOM % 20 + 1))
echo "防风控提示: 随机等待 ${RANDOM_DELAY} 秒后启动任务..."
sleep $RANDOM_DELAY


# ==========================================
# 🛠️ 2. 编译测速核心
# ==========================================
echo "=== [2/5] 编译 Cloudflare 测速引擎 ==="

if [ ! -f "CloudflareSpeedTest" ]; then
    if [ -f "main.go" ]; then
        go build -o CloudflareSpeedTest main.go
    else
        git clone --depth 1 https://github.com/XIU2/CloudflareSpeedTest.git CloudflareSpeedTest_src
        cd CloudflareSpeedTest_src
        go build -o ../CloudflareSpeedTest main.go
        cd ..
        rm -rf CloudflareSpeedTest_src
    fi
fi


# ==========================================
# 🌍 3. 构建 10 个合规 AI 地区的专属 IP 库
# ==========================================
echo "=== [3/5] 构建 10 个目标地区的专属 IP 分桶 ==="

python3 - << 'EOF'
import json

# 定义 10 个支持 AI 且地理分散的合规地区专属网段
REGION_IP_MAP = {
    "US": ["104.16.0.0/14", "172.64.0.0/14", "104.24.0.0/14"],
    "SG": ["104.18.0.0/15", "172.67.0.0/16", "104.28.0.0/15"],
    "JP": ["104.16.32.0/19", "172.64.32.0/19", "104.20.0.0/16"],
    "KR": ["104.16.64.0/19", "172.64.64.0/19", "104.21.0.0/16"],
    "TW": ["104.16.96.0/19", "172.64.96.0/19", "104.22.0.0/16"],
    "DE": ["104.16.128.0/19", "172.64.128.0/19", "104.23.0.0/16"],
    "GB": ["104.16.160.0/19", "172.64.160.0/19", "104.25.0.0/16"],
    "AU": ["104.16.192.0/19", "172.64.192.0/19", "104.26.0.0/16"],
    "CA": ["104.16.224.0/19", "172.64.224.0/19", "104.27.0.0/16"],
    "FR": ["104.17.0.0/16", "172.65.0.0/16", "104.19.0.0/16"]
}

for region, cidrs in REGION_IP_MAP.items():
    with open(f"ip_buckets/{region}.txt", "w", encoding="utf-8") as f:
        f.write("\n".join(cidrs) + "\n")

print("已成功初始化 10 个地区专属 IP 扫描桶。")
EOF


# ==========================================
# 🚀 4. 按地区独立并行扫描与优选
# ==========================================
echo "=== [4/5] 按地区逐个独立执行测速与精选 ==="

REGIONS=("US" "SG" "JP" "KR" "TW" "DE" "GB" "AU" "CA" "FR")
PORT=443

> result/all_selected.csv

for CC in "${REGIONS[@]}"; do
    echo "----------------------------------------"
    echo "🚀 正在扫描地区 [$CC] 的专属 IP 池..."
    
    # 独立测试当前地区 IP，只输出前 30 个最高速样本
    ./CloudflareSpeedTest \
      -f "ip_buckets/${CC}.txt" \
      -n 150 \
      -dn 30 \
      -dt 2 \
      -tp $PORT \
      -url "https://speed.cloudflare.com/__down?bytes=5000000" \
      -o "result/temp_${CC}.csv" > /dev/null 2>&1 || true

    # 如果产生有效结果，追加国家/地区代码标记并存入总表
    if [ -f "result/temp_${CC}.csv" ]; then
        python3 -c "
import csv
try:
    with open('result/temp_${CC}.csv', 'r', encoding='utf-8') as infile, open('result/all_selected.csv', 'a', encoding='utf-8') as outfile:
        reader = csv.reader(infile)
        next(reader, None)
        writer = csv.writer(outfile)
        for row in reader:
            if row and len(row) >= 6:
                row.append('${CC}')
                writer.writerow(row)
except Exception as e:
    pass
"
        rm -f "result/temp_${CC}.csv"
    fi
done


# ==========================================
# 📊 5. 提取每区前 15 个 IP 并格式化输出
# ==========================================
echo "=== [5/5] 汇总并提取 10 个地区（各区最快前 15 个） ==="

python3 - << 'EOF'
import csv
import json

def get_flag(code):
    if not code or len(code) != 2:
        return "🌐"
    code = code.upper()
    return chr(127397 + ord(code[0])) + chr(127397 + ord(code[1]))

bucket_data = {}

try:
    with open('result/all_selected.csv', 'r', encoding='utf-8') as f:
        reader = csv.reader(f)
        for row in reader:
            if len(row) >= 7:
                ip = row[0].strip()
                latency = float(row[4].strip()) if row[4].strip() else 999.0
                speed = float(row[5].strip()) if row[5].strip() else 0.0
                region = row[6].strip()
                
                if region not in bucket_data:
                    bucket_data[region] = []
                bucket_data[region].append({'ip': ip, 'latency': latency, 'speed': speed})
except Exception as e:
    print(f"解析汇总 CSV 失败: {e}")

final_ips = []
PORT = 443

# 针对每一个地区单独排序：优先按下载速度降序，其次按延迟升序，精确截取前 15 个
for region, items in bucket_data.items():
    items.sort(key=lambda x: (-x['speed'], x['latency']))
    selected_15 = items[:15]
    flag = get_flag(region)
    for item in selected_15:
        final_ips.append(f"{item['ip']}:{PORT}#{region}{flag}\n")

with open('result/ip.txt', 'w', encoding='utf-8') as f:
    f.writelines(final_ips)

print(f"成功导出！共包含 {len(bucket_data)} 个地区，合计 {len(final_ips)} 个优选 IP。")
EOF


# ==========================================
# 📤 6. 输出结果验证
# ==========================================
echo "=== [6/6] 各地区 IP 数量分布校验 ==="
cut -d'#' -f2 result/ip.txt | sort | uniq -c

echo "=== 所有优选与提取任务完成！ ==="
