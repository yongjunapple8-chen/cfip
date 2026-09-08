#!/usr/bin/env bash
set -e

mkdir -p result

# ==========================================
# 🛡️ 1. 防风控处理 (Anti-Risk Control)
# ==========================================
echo "=== [1/5] 执行防风控预处理 ==="

# 1.1 随机抖动延迟 (1-180 秒)，打破固定定时器特征
RANDOM_DELAY=$((RANDOM % 180 + 1))
echo "防风控提示: 随机等待 ${RANDOM_DELAY} 秒后启动任务..."
sleep $RANDOM_DELAY

# 1.2 随机选定一个真实的 User-Agent
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
    # 拷贝默认 IP 段定义文件
    cp ip.txt ../ip.txt
    cd ..
    rm -rf CloudflareSpeedTest_src
fi


# ==========================================
# 🚀 3. 执行优选测速 (安全策略配置)
# ==========================================
echo "=== [3/5] 开始执行 Cloudflare IP 优选 ==="

PORT=443

# 参数说明：
# -n 300    : 延迟测速并发线程数
# -dn 300   : 进一步扩大下载测速样本到前 300 个 IP，保证过滤掉不可用地区后仍有充足样本
# -dt 3     : 单个 IP 最多测速 3 秒，控制大流量下载触发风控
# -tp 443   : 测速端口
./CloudflareSpeedTest \
  -n 300 \
  -dn 300 \
  -dt 3 \
  -tp $PORT \
  -url "https://speed.cloudflare.com/__down?bytes=50000000" \
  -o result/result.csv


# ==========================================
# 📊 4. 排除中国/香港/无AI地区并分组筛选 (每国15个IP)
# ==========================================
echo "=== [4/5] 地区黑名单过滤与按国家分组提取 ==="

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

# 🚫 定义地区黑名单 (中国大陆、香港、澳门 + 常见 AI 屏蔽/受限国家)
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

# 1. 按下载速度降序、延迟升序排序
results.sort(key=lambda x: (-x['speed'], x['latency']))

# 2. 批量查询 IP 地理位置 (取前 250 个样本进行 GeoIP 查询)
ip_list = [item['ip'] for item in results[:250]]
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

# 3. 剔除黑名单地区，并按国家进行分组归类
country_buckets = {}
for item in results:
    ip = item['ip']
    country = ip_geo_map.get(ip, 'US').upper()
    
    # 核心过滤逻辑：如果在黑名单中，直接跳过
    if country in BLOCKED_COUNTRIES:
        continue
        
    if country not in country_buckets:
        country_buckets[country] = []
    country_buckets[country].append(item)

# 4. 选出响应速度最快的前 10 个合规国家/地区
sorted_countries = sorted(
    country_buckets.keys(),
    key=lambda c: max([x['speed'] for x in country_buckets[c]], default=0),
    reverse=True
)[:10]

# 5. 为这 10 个合规国家/地区各抽取最多 15 个 IP
final_ips = []
for country in sorted_countries:
    ips_in_country = country_buckets[country][:15]
    flag = get_flag(country)
    for item in ips_in_country:
        item['country'] = country
        item['flag'] = flag
        final_ips.append(item)

# 6. 写入 result/ip.txt (格式: ip:端口#国家代码国旗)
PORT = 443
with open('result/ip.txt', 'w', encoding='utf-8') as f:
    for item in final_ips:
        line = f"{item['ip']}:{PORT}#{item['country']}{item['flag']}\n"
        f.write(line)

# 保存 JSON 汇总结构
with open('result/best_ip.json', 'w', encoding='utf-8') as f:
    json.dump({'total': len(final_ips), 'countries_count': len(sorted_countries), 'data': final_ips}, f, ensure_ascii=False, indent=2)

print(f"黑名单过滤完成！成功筛选出 {len(sorted_countries)} 个合规国家，共计 {len(final_ips)} 个 IP (每个国家最多 15 个)。")
EOF


# ==========================================
# 📤 5. 输出格式展示
# ==========================================
echo "=== [5/5] 生成的 ip.txt 内容摘要 ==="
head -n 20 result/ip.txt
echo "... (共 $(wc -l < result/ip.txt) 行)"

echo "=== 所有优选与提取任务完成！ ==="
