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


# ==========================================
# 🛠️ 2. 编译与获取大容量纯净 IP 库
# ==========================================
echo "=== [2/5] 获取/编译测速核心并下载扩展全球 IP 库 ==="

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

echo "正在获取多来源 Cloudflare 全球 IP 库..."

# 1. 下载多个可用的 Cloudflare IP 段来源
curl -sSL "https://www.cloudflare.com/ips-v4" -o extra_ips_1.txt || true
curl -sSL "https://raw.githubusercontent.com/cf-m/cf-ips/main/ipv4.txt" -o extra_ips_2.txt || true

# 2. 严苛正则过滤：只提取格式为 x.x.x.x/x 的合法 IPv4 CIDR 行，彻底杜绝 404 或 html 报错混入
cat ip.txt extra_ips_1.txt extra_ips_2.txt 2>/dev/null \
  | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$' \
  | sort -u > full_ip.txt

rm -f extra_ips_1.txt extra_ips_2.txt

# 3. 打散纯净的 IP 库
shuf full_ip.txt > ip_shuffled.txt
rm -f full_ip.txt

VALID_COUNT=$(wc -l < ip_shuffled.txt)
echo "IP 库清理验证完成！共解析出 ${VALID_COUNT} 个合法 CIDR 网段。"


# ==========================================
# 🚀 3. 大样本广域打散测速
# ==========================================
echo "=== [3/5] 执行全球打散大样本测速 ==="

PORT=443

./CloudflareSpeedTest \
  -f ip_shuffled.txt \
  -n 1000 \
  -dn 1000 \
  -dt 2 \
  -tp $PORT \
  -url "https://speed.cloudflare.com/__down?bytes=10000000" \
  -o result/result.csv

rm -f ip_shuffled.txt


# ==========================================
# 📊 4. 官方 Colo 机房解析 & 提取 10 国家 IP
# ==========================================
echo "=== [4/5] 官方机房映射与多国家黑名单过滤提取 ==="

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

# 按速度降序、延迟升序排序
results.sort(key=lambda x: (-x['speed'], x['latency']))

# 3. 批量解析最多 800 个 IP 的地理位置
ip_list = [x['ip'] for x in results[:800]]
ip_geo_map = {}

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
                    
                    resolved_cc = colo_to_country.get(city_code, cc)
                    if resolved_cc and len(resolved_cc) == 2 and resolved_cc.isalpha():
                        ip_geo_map[ip] = resolved_cc
                    else:
                        ip_geo_map[ip] = 'US'
        except Exception as e:
            pass

# 4. 剔除黑名单地区，并归类按国家分组
country_buckets = {}
for item in results:
    ip = item['ip']
    country = ip_geo_map.get(ip, 'US')
    
    if country in BLOCKED_COUNTRIES:
        continue
        
    if country not in country_buckets:
        country_buckets[country] = []
    country_buckets[country].append(item)

# 5. 取速度最快的前 10 个合规国家
selected_countries = sorted(
    country_buckets.keys(),
    key=lambda c: max([x['speed'] for x in country_buckets[c]], default=0),
    reverse=True
)[:10]

final_ips = []
PORT = 443

for country in selected_countries:
    items = country_buckets[country][:15] # 每个国家取最多 15 个 IP
    flag = get_flag(country)
    for item in items:
        final_ips.append(f"{item['ip']}:{PORT}#{country}{flag}\n")

with open('result/ip.txt', 'w', encoding='utf-8') as f:
    f.writelines(final_ips)

print(f"成功筛选出 {len(selected_countries)} 个合规国家/地区，共计 {len(final_ips)} 个 IP。")
EOF


# ==========================================
# 📤 5. 输出地区统计分布
# ==========================================
echo "=== [5/5] 最终生成的 10 国家/地区分布图 ==="
cut -d'#' -f2 result/ip.txt | sort | uniq -c

echo "=== 所有优选与提取任务完成！ ==="
