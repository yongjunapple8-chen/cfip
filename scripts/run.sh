#!/usr/bin/env bash
set -e

mkdir -p result

# ==========================================
# 🛡️ 1. 防风控处理 (Anti-Risk Control)
# ==========================================
echo "=== [1/5] 执行防风控预处理 ==="

RANDOM_DELAY=$((RANDOM % 180 + 1))
echo "防风控提示: 随机等待 ${RANDOM_DELAY} 秒后启动任务..."
sleep $RANDOM_DELAY

USER_AGENTS=(
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36"
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/127.0.0.0 Safari/537.36"
  "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36"
)
RAND_UA=${USER_AGENTS[$((RANDOM % ${#USER_AGENTS[@]}))]}
echo "分配随机 User-Agent: $RAND_UA"


# ==========================================
# 🛠️ 2. 编译与数据初始化
# ==========================================
echo "=== [2/5] 获取/编译测速核心 ==="

if [ -f "main.go" ]; then
    echo "编译仓库根目录 Go 代码..."
    go build -o cf-speedtest main.go
    ./cf-speedtest -t 200 -n 10 > result/raw_result.txt
else
    echo "克隆 XIU2/CloudflareSpeedTest 源码并构建..."
    rm -rf CloudflareSpeedTest_src
    git clone --depth 1 https://github.com/XIU2/CloudflareSpeedTest.git CloudflareSpeedTest_src
    
    cd CloudflareSpeedTest_src
    go build -o ../CloudflareSpeedTest main.go
    cp ip.txt ../ip.txt
    cd ..
    rm -rf CloudflareSpeedTest_src
fi


# ==========================================
# 🚀 3. 执行打乱打散测速 (打破同机房集中)
# ==========================================
echo "=== [3/5] 开始执行 Cloudflare IP 打散优选 ==="

# 对 ip.txt 进行随机打散乱序，确保能测试到全球不同 CIDR 段的 IP
shuf ip.txt > ip_shuffled.txt

PORT=443

# -f ip_shuffled.txt : 使用打散后的 IP 列表
# -n 500             : 扩大并发线程测速
# -dn 500            : 下载测速前 500 个 IP，保证能覆盖全球更多国家
# -dt 3              : 单 IP 最多 3 秒
./CloudflareSpeedTest \
  -f ip_shuffled.txt \
  -n 500 \
  -dn 500 \
  -dt 3 \
  -tp $PORT \
  -url "https://speed.cloudflare.com/__down?bytes=50000000" \
  -o result/result.csv

rm -f ip_shuffled.txt


# ==========================================
# 📊 4. 强制提取 10 个不同国家/地区的 IP
# ==========================================
echo "=== [4/5] 地区黑名单过滤与 10 国家打散提取 ==="

python3 - << 'EOF'
import csv
import json
import urllib.request
import sys

def get_flag(code):
    if not code or len(code) != 2:
        return "🌐"
    code = code.upper()
    return chr(127397 + ord(code[0])) + chr(127397 + ord(code[1]))

BLOCKED_COUNTRIES = {'CN', 'HK', 'MO', 'RU', 'IR', 'KP', 'SY', 'CU', 'BY', 'AF'}

results = []
try:
    with open('result/result.csv', 'r', encoding='utf-8') as f:
        reader = csv.reader(f)
        header = next(reader, None)
        for row in reader:
            if len(row) >= 6:
                ip = row[0].strip()
                latency = float(row[4].strip()) if row[4].strip() else 999.0
                speed = float(row[5].strip()) if row[5].strip() else 0.0
                results.append({'ip': ip, 'latency': latency, 'speed': speed})
except Exception as e:
    print(f"读取 CSV 失败: {e}")

# 按下载速度降序、延迟升序排序
results.sort(key=lambda x: (-x['speed'], x['latency']))

# 批量查询最多 400 个 IP 的 GeoIP 信息
ip_list = [item['ip'] for item in results[:400]]
ip_geo_map = {}

if ip_list:
    for i in range(0, len(ip_list), 100):
        batch = ip_list[i:i+100]
        try:
            req = urllib.request.Request(
                'http://ip-api.com/batch?fields=query,countryCode',
                data=json.dumps(batch).encode('utf-8'),
                headers={'Content-Type': 'application/json'}
            )
            with urllib.request.urlopen(req, timeout=10) as resp:
                data = json.loads(resp.read().decode('utf-8'))
                for item in data:
                    ip_geo_map[item.get('query')] = item.get('countryCode', 'US')
        except Exception as e:
            print(f"查询 GeoIP 批次失败: {e}")

# 按国家分组归类 (排除黑名单)
country_buckets = {}
for item in results:
    ip = item['ip']
    country = ip_geo_map.get(ip, 'US').upper()
    
    if country in BLOCKED_COUNTRIES:
        continue
        
    if country not in country_buckets:
        country_buckets[country] = []
    country_buckets[country].append(item)

# 强制选出最多 10 个国家
available_countries = sorted(
    country_buckets.keys(),
    key=lambda c: max([x['speed'] for x in country_buckets[c]], default=0),
    reverse=True
)[:10]

final_ips = []
for country in available_countries:
    # 每个国家提取前 15 个（若不够 15 个则取该国全部）
    ips_in_country = country_buckets[country][:15]
    flag = get_flag(country)
    for item in ips_in_country:
        item['country'] = country
        item['flag'] = flag
        final_ips.append(item)

PORT = 443
with open('result/ip.txt', 'w', encoding='utf-8') as f:
    for item in final_ips:
        line = f"{item['ip']}:{PORT}#{item['country']}{item['flag']}\n"
        f.write(line)

with open('result/best_ip.json', 'w', encoding='utf-8') as f:
    json.dump({'total': len(final_ips), 'countries_count': len(available_countries), 'data': final_ips}, f, ensure_ascii=False, indent=2)

print(f"提取完成！成功找到 {len(available_countries)} 个不同国家/地区，共输出 {len(final_ips)} 个 IP。")
EOF


# ==========================================
# 📤 5. 输出格式展示
# ==========================================
echo "=== [5/5] 生成的 ip.txt 地区统计 ==="
cut -d'#' -f2 result/ip.txt | sort | uniq -c

echo "=== 所有优选与提取任务完成！ ==="
