#!/usr/bin/env bash
set -e

mkdir -p result

# ==========================================
# 🛡️ 1. 防风控处理 (Anti-Risk Control)
# ==========================================
echo "=== [1/5] 执行防风控预处理 ==="

RANDOM_DELAY=$((RANDOM % 15 + 1))
echo "防风控提示: 随机等待 ${RANDOM_DELAY} 秒后启动任务..."
sleep $RANDOM_DELAY


# ==========================================
# 🛠️ 2. 获取测速核心与下载全量 Cloudflare CIDR 库
# ==========================================
echo "=== [2/5] 获取测速核心并构建全球 CIDR 库 ==="

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

# 获取 Cloudflare 官方及社区维护的 IPv4 CIDR 全量库
curl -sSL "https://www.cloudflare.com/ips-v4" -o extra_ips_1.txt || true
curl -sSL "https://raw.githubusercontent.com/ipverse/cloudflare-ip-ranges/master/ipv4.txt" -o extra_ips_2.txt || true

# 严格过滤出标准的 CIDR 格式，剔除 404/HTML 垃圾字符
cat extra_ips_1.txt extra_ips_2.txt 2>/dev/null \
  | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$' \
  | sort -u > full_ip.txt

rm -f extra_ips_1.txt extra_ips_2.txt

# 打散全球 IP 库，抽取 2000 个广泛样本
shuf full_ip.txt | head -n 2000 > ip_sampled.txt
rm -f full_ip.txt

echo "抽取了 2000 个全球 CIDR 网段用于广域探查。"


# ==========================================
# 🚀 3. 第一阶段：快速延迟探测（找到活 IP）
# ==========================================
echo "=== [3/5] 第一阶段：全球广域 IP 响应性探测 ==="

PORT=443

# 先只测延迟不测下载（-dd 禁用下载），快速从 2000 个网段中找出 500 个低延迟响应 IP
./CloudflareSpeedTest \
  -f ip_sampled.txt \
  -n 2000 \
  -dn 0 \
  -dt 1 \
  -tp $PORT \
  -o result/ping_result.csv

rm -f ip_sampled.txt


# ==========================================
# 📊 4. 第二阶段：解析真实 Colo/国家并按国家建桶测速
# ==========================================
echo "=== [4/5] 第二阶段：解析真实 Colo 节点，按国家分类测速 ==="

python3 - << 'EOF'
import csv
import json
import urllib.request
import ssl
import subprocess
import os

def get_flag(code):
    if not code or len(code) != 2:
        return "🌐"
    code = code.upper()
    return chr(127397 + ord(code[0])) + chr(127397 + ord(code[1]))

# 黑名单：排除 CN, HK, MO 及受限地区
BLOCKED = {'CN', 'HK', 'MO', 'RU', 'IR', 'KP', 'SY', 'CU', 'BY'}

# 1. 加载 Cloudflare 官方 Locations 机房 -> 国家 映射表
colo_to_country = {}
try:
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    req = urllib.request.Request('https://speed.cloudflare.com/locations', headers={'User-Agent': 'Mozilla/5.0'})
    with urllib.request.urlopen(req, timeout=10, context=ctx) as resp:
        locations = json.loads(resp.read().decode('utf-8'))
        for loc in locations:
            if 'iata' in loc and 'country' in loc:
                colo_to_country[loc['iata'].upper()] = loc['country'].upper()
except Exception as e:
    print(f"获取 locations 映射表警告: {e}")

# 2. 从延迟测试结果中提取 IP
candidate_ips = []
try:
    with open('result/ping_result.csv', 'r', encoding='utf-8') as f:
        reader = csv.reader(f)
        next(reader, None) # 跳过表头
        for row in reader:
            if row and len(row) >= 5:
                candidate_ips.append(row[0].strip())
except Exception as e:
    print(f"读取 ping_result.csv 失败: {e}")

print(f"有效响应候选 IP 数量: {len(candidate_ips)}")

# 3. 批量通过 GeoIP API / 官方机房对 IP 进行真实归属地映射
ip_country_map = {}
batch_size = 100

for i in range(0, min(len(candidate_ips), 600), batch_size):
    batch = candidate_ips[i:i+batch_size]
    try:
        req = urllib.request.Request(
            'http://ip-api.com/batch?fields=query,countryCode,city',
            data=json.dumps(batch).encode('utf-8'),
            headers={'Content-Type': 'application/json'}
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read().decode('utf-8'))
            for item in data:
                ip = item.get('query')
                city = item.get('city', '').upper()
                cc = item.get('countryCode', '').upper()
                # 优先使用 Cloudflare 机场代码映射，其次使用 IP 地理位置
                final_cc = colo_to_country.get(city, cc)
                if final_cc and len(final_cc) == 2:
                    ip_country_map[ip] = final_cc
    except Exception as e:
        pass

# 4. 按国家建桶 (Country Buckets)
country_buckets = {}
for ip, cc in ip_country_map.items():
    if cc in BLOCKED:
        continue
    if cc not in country_buckets:
        country_buckets[cc] = []
    country_buckets[cc].append(ip)

# 选择包含 IP 数量最多的前 10-12 个国家/地区
selected_countries = sorted(country_buckets.keys(), key=lambda k: len(country_buckets[k]), reverse=True)[:12]
print(f"已成功划定 {len(selected_countries)} 个独立国家/地区候选桶: {selected_countries}")

# 5. 对每个选中的国家桶独立写出 IP 文件并测速
final_ips = []
PORT = 443

for cc in selected_countries:
    ips_in_bucket = country_buckets[cc]
    bucket_file = f"result/bucket_{cc}.txt"
    with open(bucket_file, 'w', encoding='utf-8') as f:
        f.write("\n".join(ips_in_bucket) + "\n")
    
    out_csv = f"result/out_{cc}.csv"
    
    # 针对当前国家桶独立测速，选出前 15 个最快的
    cmd = [
        "./CloudflareSpeedTest",
        "-f", bucket_file,
        "-n", str(len(ips_in_bucket)),
        "-dn", "15",
        "-dt", "2",
        "-tp", str(PORT),
        "-url", "https://speed.cloudflare.com/__down?bytes=5000000",
        "-o", out_csv
    ]
    subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    
    # 读取当前国家测速结果
    if os.path.exists(out_csv):
        try:
            with open(out_csv, 'r', encoding='utf-8') as f:
                reader = csv.reader(f)
                next(reader, None)
                flag = get_flag(cc)
                count = 0
                for row in reader:
                    if row and len(row) >= 1 and count < 15:
                        ip = row[0].strip()
                        final_ips.append(f"{ip}:{PORT}#{cc}{flag}\n")
                        count += 1
            os.remove(out_csv)
        except Exception:
            pass
    if os.path.exists(bucket_file):
        os.remove(bucket_file)

# 确保取满 10 个国家/地区的结果
with open('result/ip.txt', 'w', encoding='utf-8') as f:
    f.writelines(final_ips)

print(f"最终成功生成 {len(final_ips)} 个优选 IP，涵盖 {len(selected_countries)} 个国家/地区。")
EOF


# ==========================================
# 📤 5. 输出地区分布校验
# ==========================================
echo "=== [5/5] 最终生成的 10 国家/地区分布校验 ==="
cut -d'#' -f2 result/ip.txt | sort | uniq -c

echo "=== 所有优选与提取任务完成！ ==="
