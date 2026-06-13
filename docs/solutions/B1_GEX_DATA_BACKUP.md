# B1: GEX 数据备份方案（Squeezemetrics 替代）

## 问题
- Squeezemetrics 网站无明显数据 API endpoint
- SpotGamma 403 拒绝
- pygex 库（PyPI）触发 Cloudflare 挑战

## 调研结果

### 选项 A：FlashAlpha-lab/gex-explained（推荐 → 自计算）
- GitHub 公开仓库（2★）：`https://github.com/FlashAlpha-lab/gex-explained`
- 完整模块：`compute_gex.py`、`gamma_exposure_by_strike.py`、`gamma_flip_level_tracker.py`
- 核心逻辑：Black-Scholes gamma × OI × 100 × spot²，对全期权链按 strike 聚合
- 已通过 `curl raw.githubusercontent.com` 拉取代码可读

### 选项 B：FlashAlpha API（付费回退）
- 官网：`flashalpha.com/pricing`
- 付费层有 GEX/DEX/charm/vanna 终端 API
- ❌ 不符合"免费数据源"原则，仅作应急后备

### 选项 C：CBOE 直接数据
- `cdn.cboe.com/api/us/options/daily_volume/` → 403
- `www.cboe.com/delayed_quotes/SPY/quote_table` → 200 但需解析 HTML
- 仅作为期权链原始数据补充

### 选项 D：Yahoo Finance 期权链（已验证 200）
- `query1.finance.yahoo.com/v7/finance/options/SPY` → 完整 strike/IV/OI/价格
- 免费、稳定、含全期权链
- ✅ **作为 GEX 自算的输入源最优解**

## 推荐方案：Yahoo Options Chain + 自算 GEX

### 数据流
```
Yahoo /v7/finance/options/{SYM}      期权链原始数据
          ↓
解析 calls + puts × 全 expiry × 全 strike
          ↓
对每张期权：BS gamma × OI × 100 × spot² × (-1 if put)
          ↓
按 strike 聚合 → GEX(strike) profile
按 expiry 加权 → Total GEX、Zero Gamma Level
```

### Shell+Python 混合实现
- Shell 拉数据：`curl yahoo /v7/finance/options/$SYM` → JSON 落地
- Python 算 GEX：约 40 行（BS gamma 公式 + 聚合）
- 缓存 TTL：6小时（OpEx 周）/ 24小时（普通周）

### 风险与坑
1. **Yahoo 限速**：每秒 ≤2 次，加 `User-Agent: Mozilla/5.0`，失败重试 backoff
2. **IV 缺失**：部分远期合约 implied_volatility=0，需用历史 IV 拟合或剔除
3. **dividend yield**：BS gamma 公式中 q=0 近似（个股忽略影响 <5%）
4. **risk-free rate**：用 3M T-bill 当代理，从 FRED 拿（DGS3MO 系列）
5. **零 OI 期权**：直接跳过，避免污染

### 主备链
```
Primary:  Yahoo /v7/finance/options + 自算 GEX (FlashAlpha 公式)
Fallback: CBOE delayed_quotes HTML 抓取（仅 SPY/QQQ/IWM）
Emergency: FlashAlpha API 付费层（保留入口）
```

### 验证方法
- 拿 SPY 自算 GEX vs 公开网站（如 SqueezeMetrics 截图）对比 R²
- 阈值：自算与第三方 R²>0.9 即视为合格

## 实施任务
- [ ] 写 `fetch_options_chain.sh`（curl Yahoo）
- [ ] 写 `compute_gex.py`（参考 FlashAlpha-lab BS 实现）
- [ ] 写 `gex_cache.sh`（6h/24h TTL 控制）
- [ ] 写 `verify_gex.py`（vs 公开图表对比）
