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
    cp ip.txt ../ip.txt
    cd ..
    rm -rf CloudflareSpeedTest_src
fi


# ==========================================
# 🚀 3. 执行优选测速 (安全策略配置)
# ==========================================
echo "=== [3/5] 开始执行 Cloudflare IP 优选 ==="

PORT=443

# 防风控参数配置：
# -n 250    : 适当降低并发线程，避免触发 Actions 宿主机/CF 边缘流控
# -dn 30    : 仅对延迟最低的前 30 个 IP 进行下载测速，减少无用流量
# -dt 3     : 单个 IP 最多测速 3 秒，防止短时间大流量下载
# -tp 443   : 测速端口
# -url      : 官方测速地址
./CloudflareSpeedTest \
  -n 250 \
  -dn 30 \
  -dt 3 \
  -tp $PORT \
  -url "https://speed.cloudflare.com/__down?bytes=50000000" \
  -o result/result.csv


# ==========================================
# 📊 4. 筛选 10 个不同地区最快前 15 个 IP
# ==========================================
echo "=== [4/5] 多维度数据过滤与格式化 ==="

# 转换 ISO 国家代码为 Unicode 国旗 Emoji 的函数
get_flag() {
    local code=$(echo "$1" | tr '[:lower:]' '[:upper:]')
    if [[ ${#code} -ne 2 ]]; then
        echo "🌐"
        return
    fi
    local c1=$(printf '%d' "'${code:0:1}")
    local c2=$(printf '%d' "'${code:1:1}")
    local f1=$(printf '\\U%X' $((127397 + c1)))
    local f2=$(printf '\\U%X' $((127397 + c2)))
    echo -e "$f1$f2"
}

# 使用 Python 快速进行 IP 地区查询、去重（确保最多涵盖 10 个地区）与筛选（Top 15）
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

# 批量查询 IP 地理位置/数据中心 (使用 ip-api 批量接口)
ip_list = [item['ip'] for item in results[:30]]
ip_geo_map = {}

if ip_list:
    try:
        req = urllib.request.Request(
            'http://ip-api.com/batch?fields=query,countryCode',
            data=json.dumps(ip_list).encode('utf-8'),
            headers={'Content-Type': 'application/json'}
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read().decode('utf-8'))
            for item in data:
                ip_geo_map[item.get('query')] = item.get('countryCode', 'UN')
    except Exception as e:
        print(f"查询 GeoIP 失败: {e}")

# 筛选逻辑：按地区（数据中心）分组去重，最多保留 10 个不同地区，总量取前 15 个 IP
regions_count = {}
final_ips = []

for item in results:
    ip = item['ip']
    country = ip_geo_map.get(ip, 'US')
    
    # 每个地区最多容纳 3 个节点，且地区种类最多 10 个
    current_reg_count = regions_count.get(country, 0)
    if current_reg_count == 0 and len(regions_count) >= 10:
        continue # 已经收集满 10 个不同地区
        
    if current_reg_count < 3:
        regions_count[country] = current_reg_count + 1
        flag = get_flag(country)
        item['country'] = country
        item['flag'] = flag
        final_ips.append(item)
        
    if len(final_ips) >= 15:
        break

# 输出标准 ip.txt (格式: ip:端口#国家代码国旗)
PORT = 443
with open('result/ip.txt', 'w', encoding='utf-8') as f:
    for item in final_ips:
        line = f"{item['ip']}:{PORT}#{item['country']}{item['flag']}\n"
        f.write(line)

# 保存 JSON 汇总信息
with open('result/best_ip.json', 'w', encoding='utf-8') as f:
    json.dump({'total': len(final_ips), 'data': final_ips}, f, ensure_ascii=False, indent=2)

print(f"成功筛选出 {len(final_ips)} 个 IP，覆盖 {len(regions_count)} 个地区。")
EOF


# ==========================================
# 📤 5. 输出格式展示
# ==========================================
echo "=== [5/5] 生成的 ip.txt 内容示例 ==="
cat result/ip.txt

echo "=== 所有优化任务完成！ ==="
