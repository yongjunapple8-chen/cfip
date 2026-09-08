#!/usr/bin/env bash
set -e

mkdir -p result ip_pools result/raw

# ==========================================
# 🛡️ 1. 防风控预处理
# ==========================================
echo "=== [1/5] 执行防风控预处理 ==="
RANDOM_DELAY=$((RANDOM % 10 + 1))
sleep $RANDOM_DELAY

# ==========================================
# 🛠️ 2. 编译测速核心
# ==========================================
echo "=== [2/5] 编译 Cloudflare 测速核心 ==="

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
# 🌍 3. 构建 10 个独立国家/地区的专属 CIDR 池
# ==========================================
echo "=== [3/5] 构建 10 个独立国家/地区的专属 CIDR 池 ==="

python3 - << 'EOF'
import os

COUNTRY_CIDRS = {
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

for code, cidrs in COUNTRY_CIDRS.items():
    with open(f"ip_pools/{code}.txt", "w", encoding="utf-8") as f:
        f.write("\n".join(cidrs) + "\n")

print("10 个地区专属 IP 节点池创建完成。")
EOF

# ==========================================
# 🚀 4. 多路并发：按国家/地区独立测速
# ==========================================
echo "=== [4/5] 启动多地区并行隔离测速 ==="

COUNTRIES=("US" "SG" "JP" "KR" "TW" "DE" "GB" "AU" "CA" "FR")
PORT=443

for CC in "${COUNTRIES[@]}"; do
    echo "正在扫描国家/地区: [${CC}] ..."
    
    ./CloudflareSpeedTest \
      -f "ip_pools/${CC}.txt" \
      -n 100 \
      -dn 20 \
      -dt 2 \
      -tp $PORT \
      -url "https://speed.cloudflare.com/__down?bytes=3000000" \
      -o "result/raw/${CC}.csv" > /dev/null 2>&1 || true
done

# ==========================================
# 📊 5. 提取并生成 ip.txt + 性能对照表文件
# ==========================================
echo "=== [5/5] 生成优选列表与性能指标明细文件 ==="

python3 - << 'EOF'
import csv
import os

def get_flag(code):
    if not code or len(code) != 2:
        return "🌐"
    code = code.upper()
    return chr(127397 + ord(code[0])) + chr(127397 + ord(code[1]))

COUNTRIES = ["US", "SG", "JP", "KR", "TW", "DE", "GB", "AU", "CA", "FR"]
PORT = 443

final_ip_lines = []
detailed_rows = []

for cc in COUNTRIES:
    csv_file = f"result/raw/{cc}.csv"
    if not os.path.exists(csv_file):
        continue
        
    records = []
    try:
        with open(csv_file, 'r', encoding='utf-8') as f:
            reader = csv.reader(f)
            header = next(reader, None)
            for row in reader:
                if row and len(row) >= 6:
                    ip = row[0].strip()
                    latency = float(row[4].strip()) if row[4].strip() else 999.0
                    speed = float(row[5].strip()) if row[5].strip() else 0.0
                    records.append({'ip': ip, 'latency': latency, 'speed': speed})
    except Exception:
        continue

    if not records:
        continue

    # 按下载速度降序、延迟升序排序，截取前 15 个
    records.sort(key=lambda x: (-x['speed'], x['latency']))
    top15 = records[:15]
    flag = get_flag(cc)
    
    for item in top15:
        # 1. 生成 ip.txt 用的订阅格式
        final_ip_lines.append(f"{item['ip']}:{PORT}#{cc}{flag}\n")
        
        # 2. 收集数据用于生成详细性能报表
        detailed_rows.append({
            'country': f"{cc}{flag}",
            'ip': item['ip'],
            'port': PORT,
            'latency': f"{item['latency']:.2f} ms",
            'speed': f"{item['speed']:.2f} MB/s"
        })

# 写入 1: 节点订阅格式 ip.txt
with open('result/ip.txt', 'w', encoding='utf-8') as f:
    f.writelines(final_ip_lines)

# 写入 2: CSV 格式表 result/ip_details.csv
with open('result/ip_details.csv', 'w', encoding='utf-8', newline='') as f:
    writer = csv.writer(f)
    writer.writerow(['Country', 'IP', 'Port', 'Latency', 'Download Speed'])
    for row in detailed_rows:
        writer.writerow([row['country'], row['ip'], row['port'], row['latency'], row['speed']])

# 写入 3: 美化 Markdown 报表 result/ip_details.md (方便直接在 GitHub 查看)
with open('result/ip_details.md', 'w', encoding='utf-8') as f:
    f.write("# 🌐 Cloudflare 优选 IP 性能测速明细表\n\n")
    f.write(f"共计导出 **{len(detailed_rows)}** 个 IP，各地区最多精选 15 个。\n\n")
    f.write("| 地区 | IP 地址 | 端口 | 延迟 (Latency) | 下载速度 (Speed) |\n")
    f.write("| :---: | :--- | :---: | :---: | :---: |\n")
    for row in detailed_rows:
        f.write(f"| {row['country']} | `{row['ip']}` | {row['port']} | {row['latency']} | **{row['speed']}** |\n")

print(f"数据生成成功！已另外保存 'result/ip_details.csv' 和 'result/ip_details.md' 文件。")
EOF

# 清理临时文件
rm -rf ip_pools result/raw

# ==========================================
# 📤 6. 最终分布验证
# ==========================================
echo "=== [6/6] 最终导出的国家/地区分布图 ==="
cut -d'#' -f2 result/ip.txt | sort | uniq -c

echo "=== 所有优选与提取任务完成！ ==="
