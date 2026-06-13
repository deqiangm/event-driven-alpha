# B3: IPO Calendar 数据源验证

> 验证日期: 2026-06-13  
> 状态: ✅ Primary 可用，Fallback 备好

## 验证结果

### Primary: NASDAQ IPO Calendar API ✅
- **Endpoint**: `https://api.nasdaq.com/api/ipo/calendar?date=YYYY-MM`
- **Headers**: `User-Agent: Mozilla/5.0 ...` + `Accept: application/json`
- **2026-06验证**: HTTP 200, 返回 ~10.6KB JSON
- **结构**:
  ```
  data.priced.rows[]      — 已定价 IPO（20条）
  data.upcoming.upcomingTable.rows[]  — 即将定价（含 expectedPriceDate）
  data.filed.rows[]       — 已递表（18条）
  data.withdrawn.rows[]   — 撤回（2条）
  ```
- **关键字段**: `proposedTickerSymbol`, `companyName`, `proposedSharePrice`, `sharesOffered`, `dollarValueOfSharesOffered`, `pricedDate`/`expectedPriceDate`, `proposedExchange`
- **Mega-IPO 识别**: `dollarValueOfSharesOffered` 解析后 ≥$5B 即视为 Mega
- **限速**: 实测无明显限速，建议 1 req/min（每月调用一次足矣）

### Fallback 1: IPOScoop ✅
- **URL**: `https://www.iposcoop.com/ipo-calendar/`
- **HTTP 200** with HTML（需简单解析）
- 优势: 含承销商信息（NASDAQ API 不直接提供）
- 用途: 当 NASDAQ API 失败时，作为日历兜底；常态作为承销商信息补充源

### Fallback 2: SEC EDGAR Full-Text Search ✅（B2 也用此）
- **Endpoint**: `https://efts.sec.gov/LATEST/search-index?forms=424B4&dateRange=custom&startdt=YYYY-MM-DD&enddt=YYYY-MM-DD`
- 424B4 = 最终招股说明书（IPO 定价后立即提交）
- 2026-06-01 ~ 06-13 实测: 35 hits
- 巧合: 第一条是 SpaceX (CIK 0001181412) — 正好是 ESAD 的核心 case study
- 用途: 验证 NASDAQ API 数据，发现遗漏的 IPO

## 实施推荐: 三源融合

```
01_fetch_ipo_calendar.sh:
  1. curl NASDAQ API → 写 data/raw/ipo/nasdaq_YYYYMM.json
  2. 解析 priced + upcoming + filed → events.db
  3. 失败时 → IPOScoop HTML 抓取
  4. 月度对账: SEC EDGAR 424B4 vs NASDAQ priced，差异告警
```

## Mega-IPO 触发逻辑（核心）

```bash
# 解析 dollarValueOfSharesOffered (e.g. "$670,000,000" 或 "$5,000,000,000")
amt_billion=$(echo "$value" | tr -d '$,' | awk '{print $1/1e9}')
if (( $(echo "$amt_billion >= 5.0" | bc -l) )); then
  # MEGA IPO — 触发 underwriter support force
  # window: pricedDate-5 ~ pricedDate-1
fi
```

## 风险/坑

1. **upcoming 嵌套**: `data.upcoming.upcomingTable.rows`（不是 `data.upcoming.rows`），易遗漏
2. **金额格式**: 含逗号和 `$` 前缀，需先清洗
3. **expectedPriceDate**: 格式 `M/D/YYYY` 非 ISO，需 strptime
4. **承销商缺失**: NASDAQ API 不返回 underwriters，需 SEC S-1 或 IPOScoop 补充
5. **月份切换**: API 按月查询，跨月需查两次

## 验证脚本（已可跑）

```bash
curl -s -A "Mozilla/5.0" \
  "https://api.nasdaq.com/api/ipo/calendar?date=$(date +%Y-%m)" \
  -H "Accept: application/json" \
  -o data/raw/ipo/nasdaq_$(date +%Y%m).json
```
