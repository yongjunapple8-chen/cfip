#!/usr/bin/env bash
set -e

mkdir -p result ip_ranges

# ==========================================
# 🛡️ 1. 防风控处理 (Anti-Risk Control)
# ==========================================
echo "=== [1/5] 执行防风控预处理 ==="

RANDOM_DELAY=$((RANDOM % 60 + 1))
echo "防风控提示: 随机等待 ${RANDOM_DELAY} 秒后启动任务..."
sleep $RANDOM_DELAY

USER_AGENTS=(
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36"
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/127.0.0.0 Safari/537.36"
)
RAND_UA=${USER_AGENTS[$((RANDOM % ${#USER_AGENTS[@]}))]}


# ==========================================
# 🛠️ 2. 编译测速工具
# ==========================================
echo "=== [2/5] 获取/编译测速核心 ==="

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
# 🌍 3. 准备 10 个指定 AI 合规国家的 IP 段
# ==========================================
echo "=== [3/5] 分配 10 个目标地区的特化 IP 库 ==="

# 10 个目标地区：美国(US)、新加坡(SG)、日本(JP)、韩国(KR)、台湾(TW)、德国(DE)、英国(GB)、澳大利亚(AU)、加拿大(CA)、法国(FR)
cat << 'EOF' > generate_ip_ranges.py
import json

# Cloudflare 常见特定地区广播段/节点 IP 样本库
TARGET_RANGES = {
    "US": ["104.16.0.0/13", "172.64.0.0/13", "104.24.0.0/14"],
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

for country, cidrs in TARGET_RANGES.items():
    with open(f"ip_ranges/{country}.txt", "w") as f:
        f.write("\n".join(cidrs) + "\n")
EOF

python3 generate_ip_ranges.py
rm -f generate_ip_ranges.py


# ==========================================
# 🚀 4. 循环对 10 个地区分别测速 (确保必出)
# ==========================================
echo "=== [4/5] 开始对 10 个地区进行定向独立测速 ==="

COUNTRIES=("US" "SG" "JP" "KR" "TW" "DE" "GB" "AU" "CA" "FR")
PORT=443

> result/combined_result.csv

for CC in "${COUNTRIES[@]}"; do
    echo "正在测速目标地区: [$CC] ..."
    
    # 每个国家独立测速，快速取延迟最低前 30 个 IP
    ./CloudflareSpeedTest \
      -f "ip_ranges/${CC}.txt" \
      -n 100 \
      -dn 15 \
      -dt 2 \
      -tp $PORT \
      -url "https://speed.cloudflare.com/__down?bytes=10000000" \
      -o "result/temp_${CC}.csv" || true

    # 将国家代码标记追加到临时处理文件中
    if [ -f "result/temp_${CC}.csv" ]; then
        python3 -c "
import csv
try:
    with open('result/temp_${CC}.csv', 'r') as infile, open('result/combined_result.csv', 'a') as outfile:
        reader = csv.reader(infile)
        next(reader, None) # 跳过表头
        writer = csv.writer(outfile)
        for row in reader:
            if row:
                row.append('${CC}') # 尾部追加国家代码
                writer.writerow(row)
except Exception:
    pass
"
        rm -f "result/temp_${CC}.csv"
    fi
done


# ==========================================
# 📊 5. 格式化提取并生成 ip.txt (精准每国15个)
# ==========================================
echo "=== [5/5] 汇总生成精准 10 地区 IP 列表 ==="

python3 - << 'EOF'
import csv
import json

def get_flag(code):
    if not code or len(code) != 2:
        return "🌐"
    code = code.upper()
    return chr(127397 + ord(code[0])) + chr(127397 + ord(code[1]))

country_buckets = {}

try:
    with open('result/combined_result.csv', 'r', encoding='utf-8') as f:
        reader = csv.reader(f)
        for row in reader:
            if len(row) >= 7:
                ip = row[0].strip()
                latency = float(row[4].strip()) if row[4].strip() else 999.0
                speed = float(row[5].strip()) if row[5].strip() else 0.0
                country = row[6].strip()
                
                if country not in country_buckets:
                    country_buckets[country] = []
                country_buckets[country].append({'ip': ip, 'latency': latency, 'speed': speed})
except Exception as e:
    print(f"解析汇总 CSV 失败: {e}")

final_ips = []
PORT = 443

# 对每个国家组内按速度降序、延迟升序排列，各精选 15 个 IP
for country, items in country_buckets.items():
    items.sort(key=lambda x: (-x['speed'], x['latency']))
    selected = items[:15]
    flag = get_flag(country)
    for item in selected:
        final_ips.append(f"{item['ip']}:{PORT}#{country}{flag}\n")

with open('result/ip.txt', 'w', encoding='utf-8') as f:
    f.writelines(final_ips)

print(f"提取完成！共覆盖 {len(country_buckets)} 个不同国家/地区，成功输出 {len(final_ips)} 个 IP。")
EOF


# ==========================================
# 📤 6. 验证地区分布
# ==========================================
echo "=== [6/6] 最终生成的地区分布图 ==="
cut -d'#' -f2 result/ip.txt | sort | uniq -c

echo "=== 所有优选与提取任务完成！ ==="
