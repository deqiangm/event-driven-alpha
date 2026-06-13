# B2: SEC EDGAR 限速管道设计

> 验证日期: 2026-06-13  
> 状态: ✅ 验证通过

## SEC EDGAR Rate Limit 实测

- **官方限制**: 10 requests/sec/IP
- **实测**:
  - 10 并发请求: 全 200，524ms 完成（说明 SEC 不严格限并发，但官方仍要求顺序）
  - 11 顺序请求 + sleep 0.11s: 全 200
- **结论**: `sleep 0.11` (≈9 req/s) 安全，留出 buffer

## 必备 Headers

```
User-Agent: <ESAD-Research> <email>
```
SEC 强制要求标识身份的 User-Agent，缺失或泛用 UA 会被 403。

## 双 Endpoint 策略

### 1. Full-Text Search (efts.sec.gov)
- **用途**: 按表单类型 + 日期范围扫描全市场（B2 主要场景）
- **URL 模板**:
  ```
  https://efts.sec.gov/LATEST/search-index?
    forms={S-1|424B4|S-1/A}
    &dateRange=custom
    &startdt=YYYY-MM-DD
    &enddt=YYYY-MM-DD
  ```
- **响应**: 默认返回前 10 条，加 `&from=10` 翻页，`hits.total.value` 是总数
- **频次**: 每周 1 次，扫描过去 7 天，2~5 个 form types
- **预估调用**: ≤20 req/周，远低于限速

### 2. Submissions API (data.sec.gov)
- **用途**: 已知 CIK 后取该公司全部历史 filings
- **URL**: `https://data.sec.gov/submissions/CIK{padded10}.json`
- **典型场景**: NASDAQ API 给出 ticker → 反查 CIK → 取最新 S-1 → 解析承销商

## 限速实现 (Shell)

```bash
# token bucket 简化版：sleep 0.11s
edgar_get() {
  local url="$1"
  local out="$2"
  curl -s \
    -A "ESAD-Research deqiangm@gmail.com" \
    -o "$out" \
    -w "%{http_code}" \
    "$url"
  sleep 0.11   # ≈9 req/s, 安全余量
}
```

## 缓存策略

```
data/raw/edgar/
  ├── search/
  │   └── 424B4_2026-06-01_2026-06-13.json   # 按 (form, dateRange) 缓存
  └── submissions/
      └── CIK0001181412.json                  # 按 CIK 缓存，TTL 24h
```

- Search 结果 TTL: 1h（盘中频繁更新）
- Submissions TTL: 24h（公司基本信息变化慢）
- 用 `find -mmin` 判定 staleness

## 日期范围窄化

不要扫描 "all time"。建议:
- S-1: 过去 90 天（IPO 流程 = filing → pricing 通常 30-60 天）
- 424B4: 过去 7 天（最终招股书，定价当周）
- S-1/A: 过去 30 天（修订版，临近定价）

## 风险/坑

1. **JSON 翻页**: `from=10,20,30...`，不是 `page=N`
2. **400 vs 403**: 400 = 参数错（dateRange 格式），403 = 无 User-Agent / 被封
3. **CIK 必须 10 位补零**: `0001181412` 而非 `1181412`
4. **forms 大小写敏感**: `424B4` ≠ `424b4`
5. **跨月查询**: NASDAQ 按月，EDGAR 按日期范围，可跨月

## 已验证的实例

```
$ curl "...&forms=424B4&startdt=2026-06-01&enddt=2026-06-13"
→ 35 hits
→ 第 1 条: SPACE EXPLORATION TECHNOLOGIES CORP (SPCX) CIK 0001181412
```

✅ 完美命中 ESAD 设计的 SpaceX case study。
