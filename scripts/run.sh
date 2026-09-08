#!/usr/bin/env bash
set -e

mkdir -p result

# ==========================================
# 🛡️ 1. 防风控处理 (Anti-Risk Control)
# ==========================================
echo "=== [1/5] 执行防风控预处理 ==="

RANDOM_DELAY=$((RANDOM % 30 + 1))
echo "防风控提示: 随机等待 ${RANDOM_DELAY} 秒后启动任务..."
sleep $RANDOM_DELAY

USER_AGENTS=(
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36"
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/127.0.0.0 Safari/537.36"
)
RAND_UA=${USER_AGENTS[$((RANDOM % ${#USER_AGENTS[@]}))]}


# ==========================================
# 🛠️ 2. 编译与数据初始化
# ==========================================
echo "=== [2/5] 获取/编译测速核心与基础 IP 库 ==="

if [ ! -f "CloudflareSpeedTest" ]; then
    if [ -f "main.go" ]; then
        go build -o CloudflareSpeedTest main.go
    else
        git clone --depth 1 https://github.com/XIU2/CloudflareSpeedTest.git CloudflareSpeedTest_src
        cd CloudflareSpeedTest_src
        go build -o ../CloudflareSpeedTest main.go
        cp ip.txt ../ip.txt
        cd ..
        rm -rf CloudflareSpeedTest_src
    fi
fi

# 打散 IP 库，触发更广泛的全球 Anycast 节点匹配
shuf ip.txt > ip_shuffled.txt


# ==========================================
# 🚀 3. 广域高并发测速
# ==========================================
echo "=== [3/5] 执行广域 Anycast IP 测速 ==="

PORT=443

./CloudflareSpeedTest \
  -f ip_shuffled.txt \
  -n 600 \
  -dn 600 \
  -dt 2 \
  -tp $PORT \
  -url "https://speed.cloudflare.com/__down?bytes=10000000" \
  -o result/result.csv

rm -f ip_shuffled.txt


# ==========================================
# 📊 4. 官方 Colo 机场码精准解析 & 黑名单过滤 (强制凑满 10 国)
# ==========================================
echo "=== [4/5] 官方机房映射与 10 国合规 IP 提取 ==="

python3 - << 'EOF'
import csv
import json
import urllib.request
import ssl

def get_flag(code):
    if not code or len(code) != 2:
        return "🌐"
    code = code.upper()
    return chr(127397 + ord(code[0])) + chr(127397 + ord(code[1]))

# 🚫 黑名单：中国大陆、香港、澳门及 AI 不支持/受限地区
BLOCKED_COUNTRIES = {'CN', 'HK', 'MO', 'RU', 'IR', 'KP', 'SY', 'CU', 'BY', 'AF'}

# 1. 获取 Cloudflare 官方 locations 机房代码与国家映射关系
colo_to_country = {}
try:
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    req = urllib.request.Request('https://speed.cloudflare.com/locations', headers={'User-Agent': 'Mozilla/5.0'})
    with urllib.request.urlopen(req, timeout=10, context=ctx) as resp:
        locations = json.loads(resp.read().decode('utf-8'))
        for loc in locations:
            # iata 即三字机房代码（如 NRT, SJC），country 为标准二字国家代码（如 JP, US）
            if 'iata' in loc and 'country' in loc:
                colo_to_country[loc['iata'].upper()] = loc['country'].upper()
except Exception as e:
    print(f"获取 Cloudflare 官方 locations 映射失败: {e}")

# 2. 读取 CSV 测速结果
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

# 降序按速度排序
results.sort(key=lambda x: (-x['speed'], x['latency']))

# 3. 通过基础 IP 查询定位每个 IP 实际到达的 Colo/Country
country_buckets = {}

# 预准备 batch 查询
ip_list = [x['ip'] for x in results[:400]]
ip_geo_map = {}

# 结合 ip-api 的 city/country 字段做双重保底解析
if ip_list:
    for i in range(0, len(ip_list), 100):
        batch = ip_list[i:i+100]
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
                    city_code = item.get('city', '').upper()
                    cc = item.get('countryCode', '').upper()
                    
                    # 优先利用官方 locations 库纠正（如果 city 包含机房三字码）
                    resolved_cc = colo_to_country.get(city_code, cc)
                    if resolved_cc and len(resolved_cc) == 2 and resolved_cc.isalpha():
                        ip_geo_map[ip] = resolved_cc
                    else:
                        ip_geo_map[ip] = 'US' # 缺省保底美国
        except Exception as e:
            pass

# 4. 过滤黑名单并分组
for item in results:
    ip = item['ip']
    country = ip_geo_map.get(ip, 'US')
    
    if country in BLOCKED_COUNTRIES:
        continue
        
    if country not in country_buckets:
        country_buckets[country] = []
    country_buckets[country].append(item)

# 5. 提取最多 10 个国家
selected_countries = sorted(
    country_buckets.keys(),
    key=lambda c: max([x['speed'] for x in country_buckets[c]], default=0),
    reverse=True
)[:10]

final_ips = []
PORT = 443

for country in selected_countries:
    items = country_buckets[country][:15] # 每国取最多 15 个
    flag = get_flag(country)
    for item in items:
        final_ips.append(f"{item['ip']}:{PORT}#{country}{flag}\n")

with open('result/ip.txt', 'w', encoding='utf-8') as f:
    f.writelines(final_ips)

print(f"成功筛选出 {len(selected_countries)} 个合规国家，共计 {len(final_ips)} 个 IP。")
EOF


# ==========================================
# 📤 5. 输出地区与国家最终分布验证
# ==========================================
echo "=== [5/5] 最终生成的国家/地区统计 ==="
cut -d'#' -f2 result/ip.txt | sort | uniq -c

echo "=== 所有优选与提取任务完成！ ==="
