# Wick 数据源与接口契约

核对日期：2026-09-24。范围：macOS 本地应用、TradingFloor、CandleKit 数据适配层；不把已弃用的 WickServer 当作生产架构。

**本文记录代码实际做了什么，以及官方资料能够证明什么；不是对所有接口可用性、数据准确性或商业使用权的保证。** 本轮没有向生产数据端点发送带真实 Key 的请求。此前交接记录中的成功调用不能当成本轮实测。

## 证据标记

| 标记 | 含义 |
|---|---|
| `DOC` | 已查阅服务商文档，支持相应接口或业务口径 |
| `CODE` | 在当前工作区找到调用和解析代码；不代表通过了联网测试 |
| `WEB` | 网页内部端点、HTML 或 DOM 解析，未找到对应稳定公开 API 契约 |
| `WIP` | 当前工作区新增或修改，尚未完成应用集成验证 |
| `UNVERIFIED` | 未验证当前账号权限、网络、生产响应或具体字段语义 |
| `PLANNED` | 设置/研究中提及，但没有确认可用调用链 |

所有来源目前均为 `UNVERIFIED`（生产连通性）。下面的返回结构是**代码消费的字段子集**，不是完整 schema；`?` 表示可缺失或 null。示例不是实测数据。

## 1. 数据源目录

| ID | 来源与用途 | 当前消费者/入口 | 认证 | 证据 |
|---|---|---|---|---|
| `yahoo.chart` | 美股/国际市场 K 线、跨资产上下文 | LiveDataStore、WickMarketDataProvider、YahooChartQuote | 无用户 Key | CODE / WEB |
| `yahoo.search-news` | 搜索与新闻回退 | CandleKit YahooSearchAdapter、StockNewsProvider、YahooNewsProvider | 无用户 Key | CODE / WEB |
| `yahoo.summary` | 分析师评级、目标价、财报日期 | YahooQuoteSummaryProvider、USAnalystTools | cookie + crumb，会话生成 | CODE / WEB |
| `eastmoney.*` | A/H 行情、财务、资讯、资金流、板块、中国宏观 | MarketRouter 及 EastMoney 适配器 | 无用户 Key；部分请求有站点参数及 Referer | CODE / WEB |
| `fmp.snapshot` | 行情历史、公司资料、财务、新闻 | AgentRuntime 的非 CN、非国际后缀分支 | 用户 FMP Key | DOC / CODE |
| `finnhub.news` | 公司新闻；**没有调用情绪接口** | FinnhubNewsProvider；NewsStore 新增路径 | 用户 Finnhub Key | DOC / CODE / WIP |
| `fred.observations` | 美国宏观序列 | FredMacroProvider、FredDataStore | 用户 FRED Key | DOC / CODE |
| `sec.edgar` | 申报、Form 4、XBRL 财务 | SECEdgarProvider、USEdgarTools | 无 Key；带可识别 User-Agent | DOC / CODE |
| `finra.short-interest` | 定期空头持仓 | FINRAShortInterestProvider、ShortInterestTools | 当前代码不发送认证 | DOC / CODE，市场覆盖待核实 |
| `hkex.northbound` | 北向持股披露 | CCASSNorthboundDecorator | 无 Key，HTML 读取 | DOC（披露频率）/ CODE / WEB |
| `stocktwits.stream` | 社区帖子和用户情绪标签 | SocialView、StockTwitsSentimentProvider | 当前代码无 Key | CODE / WEB；不要等同付费 Firestream API |
| `xueqiu.browser` | 已移除专用抓取；保留股票外链 | SocialView → 系统默认浏览器 | 用户在自己的浏览器登录 | 历史源码已归档 |
| `x.browser` | 已移除专用抓取；保留搜索外链 | SocialView → 系统默认浏览器 | 用户在自己的浏览器登录 | 历史源码已归档 |
| `adanos.reddit` | Reddit 聚合讨论量、热度、情绪 | AdanosClient、AdanosSection、SocialSentimentTool | 用户 Adanos Key | DOC / WIP；目前只接 Reddit |

Adanos 的 X、News、Polymarket 接口有官方文档，但当前新代码**没有接入**。不能在 UI 标记为已启用。设置目录中的 Sina/Tencent、HKEX short selling 等不能凭一行“Planned”推断已经实现。

## 2. 配置、使用及凭证边界

原生入口：Settings → Data Sources。Finnhub/Adanos 新设置采用草稿 → Save → Test saved key → Remove key；FMP/FRED 仍是现有输入即保存方式，未完成统一。数据源与 LLM provider 是独立配置。

| 服务 | Brainstorm 注册 ID | 环境变量名（开发工具使用） | Wick Keychain account |
|---|---|---|---|
| Finnhub | `finnhub-personal-wick` | `FINNHUB_API_KEY` | `me.impai.wick.finnhub-key` |
| Adanos | `adanos-personal-wick` | `ADANOS_API_KEY` | `me.impai.wick.adanos-key` |
| FMP | `fmp-personal-wick` | `FMP_API_KEY` | `me.impai.wick.fmp-key` |
| FRED | `fred-personal-wick` | `FRED_API_KEY` | `me.impai.wick.fred-key` |

四条注册记录已检查，FMP/FRED 导入值与原本地文件在内存中比对一致。**登记不等于已导入应用，也不等于 Key 有效。** 应用不自动读取 Brainstorm；最终用户无需安装 Brainstorm。

应用使用 service=`Wick` 的 data-protection Keychain，配置由 [AgentSettings](../Wick/Data/AgentSettings.swift) 管理。不要把 Key 加入 UserDefaults、文档、测试 fixture 或命令参数。开发工具通过 credential-registry 的 `run`/`run-many` 注入给可信程序；不要打印整个环境或使用会显示带 Key URL 的调试日志。

[Finnhub SDK/文档](https://github.com/Finnhub-Stock-API/finnhub-python)、[FMP 文档](https://site.financialmodelingprep.com/developer/docs)、[FRED Key](https://fred.stlouisfed.org/docs/api/api_key.html)、[Adanos onboarding](https://adanos.org/register)。收费、商业授权和覆盖范围由各服务的当前套餐决定；BYO Key 不能代替数据授权。

### 使用流程

1. 配置需要的来源；可选源缺失时使用下文定义的回退，不能伪造数据。
2. 打开股票详情：图表、新闻、Social 分别走自己的数据层，**不是一个统一后端响应**。
3. Finnhub 测试使用 AAPL 公司新闻；Adanos 测试使用 AAPL Reddit compare，一次测试各消耗一次相应 API 请求。成功仅证明该端点响应有效，不证明全部套餐权限。
4. Adanos 新 UI 需要点击 Load sentiment；不轮询。UI 与 AI 工具共享 runtime 中的 actor，五分钟缓存。切换 Key 创建新实例。
5. 需要验证失败时，记录状态码、字段集合、样本时间和计量单位；不要记录认证头、cookie 或完整带 Key 的 URL。

## 3. 数据流和公共返回模型

代码入口：[AgentRuntime](../Wick/Data/AgentRuntime.swift)、[MarketData](../TradingFloor/Sources/TradingFloor/Tools/MarketData.swift)、[NewsStore](../Wick/Data/NewsStore.swift)。

```text
图表：LiveDataStore → CN/HK: EastMoney；其他: CandleKit YahooFinanceAdapter
AI：MarketRouter → CN/HK: EastMoneyMarketDataProvider
                  其他: 有 FMP Key 且非国际后缀 → FMP，否则 Yahoo
    → 东方财富财务 / HKEX 北向 / 东方财富新闻
    → 资金流 / 融资融券 / 龙虎榜
    → Finnhub（仅 news 为空）→ Yahoo 新闻（仍为空）
    → 中国宏观 / FRED → 指数 / 板块 / 跨资产 / 隔夜上下文
    → CachingMarketDataProvider（900 秒）
新闻 UI：NewsStore → Finnhub（新路径，美股）→ 空/失败时 StockNewsProvider
          StockNewsProvider → CN/HK 东方财富，其他 Yahoo
社交：Stocktwits 帖子；X/雪球外部链接（不回传数据）；可选 Adanos Reddit 聚合
```

`MarketSnapshot` 将数值和文本摘要组合交给 AI；`NewsArticle` 是结构化文章；`SocialSentiment` 是来源摘要和帖子。特别注意：

- AI 的新闻优先级可能是 FMP → Finnhub → Yahoo；新闻 UI 则没有 FMP 新闻路径。二者尚非严格同一批数据。
- `asOf` 有时只是调用方请求日期，不是上游数据发布时间。下面列出的历史日期问题未解决前不能用于 point-in-time 回测。
- 最外层缓存 900 秒不会使内部“按日/进程寿命缓存”的数据自动刷新。
- `[]`、nil、HTTP 失败被不少旧适配器合并；不能据此断言“没有新闻/没有交易/情绪中性”。

应用归一化模型（完整字段）：

```text
MarketSnapshot {
  symbol: String, asOf: Date, lastPrice: Double?,
  priceSummary: String, technicals: String, fundamentals: [String: String],
  news: [String], macro: String, capitalFlow: String
}
NewsArticle {
  title: String, summary: String?, publisher: String?,
  link: String?, published: Date?
}
SocialSentiment {
  symbol: String, asOf: Date, source: String, summary: String,
  posts: [{source: String, text: String, score: Double?, createdAt: Date?}]
}
```

## 4. Finnhub：公司新闻

依据：[官方公司新闻](https://finnhub.io/docs/api/company-news)、[官方 SDK](https://github.com/Finnhub-Stock-API/finnhub-python)。网站动态文档本轮文本提取有限；SDK 确认 company_news 与 news_sentiment 是不同调用。

代码：[FinnhubNewsProvider.swift](../TradingFloor/Sources/TradingFloor/DataAdapters/FinnhubNewsProvider.swift)。

```http
GET https://finnhub.io/api/v1/company-news?symbol=AAPL&from=YYYY-MM-DD&to=YYYY-MM-DD
X-Finnhub-Token: <由安全存储注入>
```

消费结构：`[{headline: String, datetime: Double, source?: String, summary?: String, url?: String}]`；上游还可有 id、image、related 等，当前不消费。datetime 按 Unix **秒**转换。

新实现请求 asOf 前 14 天，过滤窗口外文章，去重、按时间倒序，再客户端取 limit（UI 默认 20、AI 默认 6）。limit 不传给服务。`articles` 抛出分类错误；旧 `headlines` 继续吞错误返回空，允许回退。

待核实：美股判断复用 StockTwits 符号规则，不能代表 Finnhub 的完整市场覆盖；同 URL 去重及整批严格解码仍需异常样本测试。代码没有 Finnhub quote、财报日历或 news-sentiment 集成。

## 5. Adanos：当前只接 Reddit 聚合

依据：[服务商机器可读文档](https://api.adanos.org/llms.txt)、[OpenAPI](https://api.adanos.org/openapi.json)。本轮 llms 文档可读取，拆分 Reddit YAML 读取失败，未据此声称逐字段 schema 全量验证。

代码：[AdanosClient.swift](../TradingFloor/Sources/TradingFloor/DataAdapters/AdanosClient.swift)。

```http
GET https://api.adanos.org/reddit/stocks/v1/compare?tickers=AAPL&from=YYYY-MM-DD&to=YYYY-MM-DD
X-API-Key: <由安全存储注入>
```

代码消费：

```text
{period_days: Int, stocks: [{
  ticker: String, mentions: Int?, buzz_score: Double?,
  sentiment_score: Double?, bullish_pct: Double?, bearish_pct: Double?
}]}
```

采用最近七个 UTC 日历日（含当前日），明确 from/to；不用已弃用的 days。只传一个 ticker，当前限制 ASCII 字母 1–10 位；官方 compare 支持批量最多十项，代码尚未利用。空 stocks 映射 nil，不能当作中性。

五分钟 actor 缓存按 symbol + 窗口分组，合并同键在途请求，最多约 100 个缓存项；错误不缓存。取消 UI 等待不会必然取消共享请求，仍可能消耗额度。`period_days` 解码但尚未核对是否与请求一致，数值范围也尚未验证。

401/403/429 分别区分认证、权限、额度；400/404/422/5xx 在当前 DataAPI 中统一为 unavailable（信息仍不够细）。不调用原始帖子接口；统计值不能转换成伪造的 SocialPost，也不应与 Stocktwits 的标签比例直接平均。

[套餐](https://adanos.org/pricing) 应实时查看，不在 UI 写死价格。X、News、Polymarket 是可后续接入的独立来源，不是这次 Reddit 响应中的字段。

## 6. FMP：快照的可选基础层

依据：[历史价格](https://site.financialmodelingprep.com/developer/docs/stable/historical-price-eod-full)、[股票新闻](https://site.financialmodelingprep.com/developer/docs/stable/search-stock-news)。
代码：[FMPMarketDataProvider.swift](../TradingFloor/Sources/TradingFloor/DataAdapters/FMPMarketDataProvider.swift)。

Base：`https://financialmodelingprep.com/stable`；GET，查询参数认证名 `apikey`。只能在程序内从安全存储构造 URL，不输出完整请求。

| 路径 | 代码参数（省略认证） | 返回字段子集 |
|---|---|---|
| `/historical-price-eod/full` | symbol | `[{high: Double, low: Double, close: Double}]` |
| `/profile` | symbol | `[{price?, marketCap?, beta?: Double, industry?: String}]` |
| `/income-statement` | symbol, limit=2 | `[{fiscalYear?: String, revenue?, grossProfit?, netIncome?, eps?: Double}]` |
| `/search-stock-news` | symbols（复数）, limit=6 | `[{title: String, site?: String}]` |

四个请求并发；历史数组被反转后计算技术指标，profile 提供无历史时的价格。失败子请求返回 []。这不是“FMP 出错就自动切换 Yahoo”：**有 Key 会选择 FMP，失败后的行情回退并未在路由实现。**

差异/待改：不解析价格日期、不按 asOf 截断；没有明确限制历史窗口；假定倒序；新闻只读 site，需核对 publisher 兼容性；收入格式化固定 `$` 且丢失报表币种；EPS=0 被省略。代码注释“某套餐新闻无数据”是旧观察，不能推断所有账号。

## 7. FRED：宏观观测序列

依据：[series/observations](https://fred.stlouisfed.org/docs/api/fred/series_observations.html)、[使用条款](https://fred.stlouisfed.org/docs/api/terms_of_use.html)。
代码：[FredMacroProvider](../TradingFloor/Sources/TradingFloor/DataAdapters/FredMacroProvider.swift)、[FredDataStore](../Wick/Data/FredDataStore.swift)。

GET `https://api.stlouisfed.org/fred/series/observations`；query：`series_id, api_key, file_type=json, sort_order=desc, limit, units`。

```text
{observations: [{date: "YYYY-MM-DD", value: String, realtime_start?, realtime_end?}], ...}
```

value 为字符串，缺失值 `"."` 不是 0。AI 读取 FEDFUNDS、DGS10、T10Y2Y、UNRATE（units=lin）和 CPIAUCSL（pc1）；每序列 limit=1。UI limit=365，过滤缺失值后按日期升序，并转换为 open=high=low=close 的 Candle，volume=0；这些是宏观序列，不是证券日 K 线。

待改：limit=1 恰为缺失日就失去该指标，应该寻找最近有效观测；AI 不保留观测日期；未设置 observation_end/realtime 参数，asOf 不保证历史时点；UI 缓存无统一 TTL，365 条月度值并不等于一年。不要把“免费”推导成所有第三方序列均可无限商业再分发。

## 8. Yahoo Finance：网页数据路径

官方可核对的资料：[交易所、后缀及延迟](https://help.yahoo.com/kb/SLN2310.html)。本轮没有确认 Wick 使用的下列端点具有面向本应用的正式公开服务契约；标记 WEB，不能称为“保证实时的免费 API”。

| 请求 | 参数/使用方法 | 代码消费结构 |
|---|---|---|
| `GET query1.finance.yahoo.com/v8/finance/chart/{symbol}` | interval、range 等，CandleKit 构造 | `chart.result[].meta`、`timestamp[]`、`indicators.quote[].{open,high,low,close,volume}[]`；`chart.error?` |
| `GET .../v1/finance/search` | q；新闻用 newsCount、quotesCount=0 | `news[]: {title?,publisher?,link?,providerPublishTime?}`；搜索 quotes[] |
| `GET .../v10/finance/quoteSummary/{symbol}` | modules、crumb；先 fc.yahoo.com 获取 cookie，再 /v1/test/getcrumb | `quoteSummary.result[].{recommendationTrend,calendarEvents,financialData,defaultKeyStatistics}` |

代码：[YahooChartQuote](../TradingFloor/Sources/TradingFloor/DataAdapters/YahooChartQuote.swift)、[YahooQuoteSummaryProvider](../TradingFloor/Sources/TradingFloor/DataAdapters/YahooQuoteSummaryProvider.swift)、[StockNewsProvider](../TradingFloor/Sources/TradingFloor/DataAdapters/StockNewsProvider.swift)、[WickMarketDataProvider](../Wick/Data/WickMarketDataProvider.swift)。CandleKit 是外部依赖，检查的是本机兄弟目录代码；与 project.yml 的锁定版本是否完全一致尚未核实。

quoteSummary 的 raw/fmt 包装转换为强买/买/持有/卖/强卖人数、targetMean、currentPrice、recommendationKey、forwardPE、nextEarningsDate。时间戳按秒；OHLCV 数组须按 timestamp 对齐，缺失项不可填零。BRK.B 映射与交易所 `.L/.T` 后缀需区别。

限流/登录墙/crumb 失败不能等价“该股票没有分析师覆盖”；不同交易所行情延迟不同。图表和快照的复权、币种、盘前盘后口径还需统一。

## 9. 东方财富：按端点标记，而非一个“免费源”

资料：[官方数据中心](https://m.data.eastmoney.com/index.html)。以下字段来自代码解析；官网业务页面不能证明内部请求具有稳定 API 承诺。均标记 CODE / WEB。

代码目录：`TradingFloor/Sources/TradingFloor/DataAdapters/EastMoney*.swift`；行情图表桥接 [EastMoneyChartAdapter](../Wick/Data/EastMoneyChartAdapter.swift)，符号转换 [CNSymbol](../TradingFloor/Sources/TradingFloor/DataAdapters/CNSymbol.swift)。示例：600519.SS → secid=1.600519，深市前缀 0，港股走自己的映射，不能只靠补零猜市场。

| 数据 | GET 地址（HTTPS）与关键参数 | 代码消费的返回结构 |
|---|---|---|
| K 线 | `push2his.eastmoney.com/api/qt/stock/kline/get`；secid,klt,fqt=1,fields1/2 | `{data:{klines:["date,open,close,high,low,volume,amount,..."]}}` |
| 报价/简称/指数 | `push2delay.eastmoney.com/api/qt/stock/get`；secid,fields,fltt | `{data:{f43,f44,f45,f46,f47,f48,f57,f58,f60,...}}` |
| 资金流 | `push2his.eastmoney.com/api/qt/stock/fflow/daykline/get`；secid,fields1/2,lmt | `{data:{klines:[CSV]}}`；日期、主力/小/中/大/超大单净流入 |
| 财务/融资/龙虎榜/宏观 | `datacenter-web.eastmoney.com/api/data/v1/get`；reportName,columns,filter,sortColumns,sortTypes,pageSize | `{result:{data:[row]}}` |
| 港股 F10 | `datacenter.eastmoney.com/securities/api/data/v1/get`；reportName、SECUCODE filter | 同 result.data 包装 |
| 涨停池 | `push2ex.eastmoney.com/getTopicZTPool`；date 等 | `{data:{pool:[row],...}}` |
| 所属板块 | `push2delay.eastmoney.com/api/qt/slist/get`；secid,spt=3,fields | `{data:{diff:[{f12,f13,f14,f3}]}}`，f14 名称，f3 涨跌幅 |
| 新闻搜索 | `search-api-web.eastmoney.com/search/jsonp`；cb,param(JSON 字符串) | JSON 或 JSONP；`result.cmsArticleWebOld[]:{title,content,mediaName,url,date}` |
| 公告 | `np-anotice-stock.eastmoney.com/api/security/ann` | `data.list[]`，快照新闻链读取标题等 |

K 线 klt：1/5/15/30/60 为分钟；101/102/103 为日/周/月。代码把 fqt=1 解释为前复权；需要真实拆股/分红样本核实。报价 f 字段的整数缩放/浮点行为与 fltt、市场有关，不可套用单一除数。新闻时间按来源时区处理，不能直接解释为 UTC。

表选择差异（应在复核时特别注意）：

| 消费者 | reportName / 字段 |
|---|---|
| 财务快照 A 股 | `RPT_LICO_FN_CPD` |
| 财务工具 A 股 | `RPT_F10_FINANCE_MAINFINADATA` |
| 港股财务 | `RPT_HKF10_FN_MAININDICATOR` |
| 融资融券 | `RPTA_WEB_RZRQ_GGMX` |
| 龙虎榜快照 / 工具 | `RPT_DAILYBILLBOARD_DETAILSNEW` / `RPT_DAILYBILLBOARD_DETAILS` |
| CPI / PPI | `RPT_ECONOMY_CPI.NATIONAL_SAME` / `RPT_ECONOMY_PPI.BASE_SAME` |
| PMI | `RPT_ECONOMY_PMI.MAKE_INDEX / NMAKE_INDEX` |
| M2 / 贷款 | `RPT_ECONOMY_CURRENCY_SUPPLY.BASIC_CURRENCY_SAME` / `RPT_ECONOMY_RMB_LOAN.LOAN_ACCUMULATE_SAME` |

不同财务表不能假定同周期、同单位。NMAKE_INDEX 当前 UI 文案写“服务业”，但代码未提供证明它等于服务业而非非制造业综合口径；应复核。各解析器有数字字符串、`-`、null 容错，不表示单位语义已验证。代码内固定 ut 等站点参数也不是用户购买的数据 Key。

## 10. SEC EDGAR：申报与财务

依据：[官方 APIs](https://www.sec.gov/search-filings/edgar-application-programming-interfaces)。代码：[SECEdgarProvider](../TradingFloor/Sources/TradingFloor/DataAdapters/SECEdgarProvider.swift)。无 API Key；应遵守 SEC fair access，并使用可联系的 User-Agent；不能把多个实例各自限速当成全应用限速。

| GET 路径 | 返回结构及用途 |
|---|---|
| `www.sec.gov/files/company_tickers.json` | 键控对象 → `{ticker,cik_str,title}`，ticker 找 CIK |
| `data.sec.gov/submissions/CIK{10位}.json` | `filings.recent.{form[],filingDate[],accessionNumber[],primaryDocument[]}` |
| `www.sec.gov/Archives/edgar/data/{cik}/{无横线accession}/{document}` | Form 4 XML，提取报告人和非衍生品交易 |
| `data.sec.gov/api/xbrl/companyconcept/CIK{10位}/us-gaap/{tag}.json` | `{units:{单位:[{end,val,fy?,fp?,form?,...}]}}` |

当前 Form 4 解析净股数、加权价格，**不等于完整内幕交易语义**：授予、税款代扣、衍生品、修正申报都可能影响理解。recent 数组不是全历史；XBRL 的单位、财年、修订、累计值与单季值需区分，当前仅消费部分字段。

## 11. FINRA：Short Interest

依据：[官方 Developer 文档](https://developer.finra.org/docs) 的 Consolidated Short Interest 条目。官方列出该 dataset 与 mock、Public/Firm/Organization credential types；不能由“Public”字样推断永不需要身份验证。官方摘要与项目注释对市场范围的说法需进一步实测核实。

代码：[FINRAShortInterestProvider](../TradingFloor/Sources/TradingFloor/DataAdapters/FINRAShortInterestProvider.swift)。

```http
POST https://api.finra.org/data/group/otcMarket/name/consolidatedShortInterest
Content-Type: application/json
Accept: application/json
```

```json
{"compareFilters":[{"fieldName":"symbolCode","fieldValue":"AAPL","compareType":"EQUAL"}],"dateRangeFilters":[{"fieldName":"settlementDate","startDate":"2025-01-01","endDate":"2025-12-31"}],"limit":1000}
```

上述为构造示例。代码默认近两年；返回数组消费 `settlementDate, currentShortPositionQuantity, changePercent, daysToCoverQuantity, averageDailyVolumeQuantity, marketClassCode`。数值可为 number/string/null；999.99 days-to-cover sentinel 映射 nil。按结算日倒序，非成交日实时更新。没有分页，limit=1000；失败一律 []。Short interest（持仓）不可与 daily short volume（交易量）混用。

### Wick 内调用方法和归一化返回

空头源登记 ID：`finra.short-interest`。凭证登记状态：**不适用，当前实现没有 Key 槽位**；不能为它在 Brainstorm 创建一个虚假的凭证记录。若另有已购买的空头数据服务，须以其服务名/凭证另行登记。

工具代码：[ShortInterestTool.swift](../TradingFloor/Sources/TradingFloor/Tools/ShortInterestTool.swift)。在本地 AgentRuntime 中注册为 `us.short_interest`，参数：

```json
{"symbol":"AAPL"}
```

Swift 层：`await FINRAShortInterestProvider().history(symbol: "AAPL", years: 2)`。

```text
[ShortInterestPoint {
  settlementDate: String, shortShares: Double, changePercent: Double?,
  daysToCover: Double?, adv: Double?, venue: String?
}]
```

AI 工具返回中文文本（不是上述 JSON）：最新结算日、做空股数、较上期变化、回补天数、日均成交量、上报场所，以及最多六期的方向摘要。至少三条记录才生成趋势。代码拒绝含点号的符号，因此也会拒绝 BRK.B 这类美股类别股；这是实现限制，不是 FINRA 的官方市场规则。该工具未提供借券费率、实时可借数量或做空成交量。

## 12. HKEX：北向持股，而非北向当日流量

依据：[官方披露调整通知](https://www.hkex.com.hk/-/media/HKEX-Market/Services/Circulars-and-Notices/Participant-and-Members-Circulars/HKSCC/2024/ce_HKSCC_NOM_096_2024.pdf)。北向持股按季度披露，季后第五个北向交易日发布；不要与香港上市证券 CCASS 日度参与者持股混淆。

代码：[CCASSNorthboundDecorator](../TradingFloor/Sources/TradingFloor/DataAdapters/CCASSNorthboundDecorator.swift)。GET `https://www3.hkexnews.hk/sdw/search/mutualmarket.aspx?t=sh|sz`，返回 **HTML**；解析为 `ParsedList{date?,dateLabel,holdings:[code:Row{shares,percent}]}`，追加 fundamentals。

当前每市场首次成功后缓存，没有按季度自动失效；注释“quarter-cache”不代表实现了季度刷新。需要核对 HTML 日期、百分比分母及跨季度更新。它不是覆盖所有港股的 CCASS 完整产品。

## 13. Stocktwits、雪球、X：三种不同入口

### Stocktwits

依据：[官方情绪解释](https://help.stocktwits.com/c/faqs/articles/using-sentiment-on-stocktwits)、[正式 Firestream 情绪 API](https://firestream-portal.stocktwits.com/documentation/sentiment-detail)。当前代码调用的 v2 stream 不是后者。

代码：[StockTwitsClient](../TradingFloor/Sources/TradingFloor/DataAdapters/StockTwitsClient.swift)。GET `https://api.stocktwits.com/api/2/streams/symbol/{SYMBOL}.json`；无 Key；本地 limit 默认 30。

```text
{messages:[{id:Int,body?:String,created_at?:ISO日期,
  entities?:{sentiment?:{basic?:"Bullish"|"Bearish"}},
  user?:{username?,name?,avatar_url?,followers?,like_count?},
  symbols?:[{symbol?:String}]}]}
```

只代表取回帖子中的标签，不能称为 Stocktwits 全站官方情绪指数。未标记不是中性。当前失败 []，无认证端点的稳定性和使用权限未核实；不要承诺永久免费。

### 雪球（历史实现，已移除）

当前仅提供外部浏览器链接。以下为归档协议说明，非当前运行路径；参阅[知识库](reference/browser-social/README.md)。

业务入口：[雪球](https://xueqiu.com/)；本轮没有取得以下网页内部接口的公开 API 契约。
代码：[XueqiuLiveScraper](reference/browser-social/Wick/Browser/XueqiuLiveScraper.swift)、[BrowserSessionManager](../Wick/Browser/BrowserSessionManager.swift)。

用户先在 WebKit 登录；同源 GET `/statuses/search.json?q={雪球符号}&count=...&page=1&sort=time&source=all`，credentials=include。返回 JSON 的 list 交给帖子解析器；title/text、user、created_at、互动计数等字段有容错，不可把原始 HTML 当正文直接展示。转换后的帖子包含作者、正文、时间、互动、链接；新闻为另一个读取路径。

登录失效、403/HTML 登录页、反爬必须和“没有讨论”分开。cookie 不应导入 Brainstorm API-Key 注册记录，也不应提交到仓库。

### X（历史实现，已移除）

当前仅提供外部浏览器链接。以下为归档说明。

依据：[官方 X API](https://docs.x.com/overview)；**Wick 当前没有使用这个官方 API**。
代码：[XLiveScraper](reference/browser-social/Wick/Browser/XLiveScraper.swift)。打开 `https://x.com/search?q={encoded}&src=typed_query&f=live`，解析 DOM。当前 `XPost{handle:String,text:String}`，ID 由 handle+text 拼接；没有可靠 permalink、发布时间或互动数。不能为它虚构时间或把去重后的 DOM 样本当全量统计。用户网页登录与 OAuth API 授权是两回事。

## 14. 已发现的差异和待修项

| 优先级 | 问题 | 影响 / 验收方式 |
|---|---|---|
| 高 | FMP/FRED/多个装饰器忽略历史 asOf | 对过去日期不能泄露后来发布数据；用有日期的受控 fixture 验证 |
| 高 | 旧适配器把无权限、限流、解析失败合并为 [] | UI/AI 无法解释缺口；分别模拟 401/403/429、空数组及坏 schema |
| 高 | 图表、宏观仍存在 synthetic/demo 回退 | 必须显著标记或空态，严禁混入真实收益/分析 |
| 高 | FMP/FRED URL 含 Key，FredDataStore 保存原始错误描述 | 审计错误对象/日志，必须去除请求 URL 与认证数据 |
| 中 | Keychain 老存储迁移及沙箱权限 | CLI 找不到并不证明应用里没有 Key；需签名应用实测 |
| 中 | Finnhub/Adanos 新集成尚未完成验证 | TradingFloor 192 项测试通过（含四项新接口测试）；临时 SwiftPM 工程完成应用源码编译，签名沙箱/UI 与生产联网仍待验证 |
| 中 | FMP 有 Key 但无套餐权限时无行情回退 | 明确失败状态或实现运行期路由回退 |
| 中 | AI 与新闻 UI 优先级不同 | 同 symbol/window 比较文章来源、时间、去重结果 |
| 中 | CCASS 生命周期缓存、按日缓存与外层 TTL 不一致 | 注入时钟验证跨日/跨季度刷新 |
| 中 | 分析师“机构持仓”等设置文案超出实际解码字段 | 以代码输出能力更新目录；不要用服务商全部产品代替已集成能力 |
| 中 | 新设置仅统一 Finnhub/Adanos，FMP/FRED 仍输入即保存 | 四类密钥应最终统一显式提交和错误提示 |
| 中 | Adanos 当前仅 Reddit，UI 未展示所有已解码字段 | 清楚标记已接入范围；补充字段范围与日期窗验证 |
| 中 | Stocktwits 公开端点长期可用性/许可未确认 | 对照官方 API 权限测试，保留 unavailable 状态 |
| 低 | 老注释仍称 Server SaaS/示例回退 | 更新到本地应用架构；注释不作为生产能力证据 |

## 15. 接口复核与维护方法

每次接入/升级至少记录：来源 ID、文档核对日期、端点版本、代码路径、认证方式、参数、返回子集、单位、时区、缓存、回退、测试证据及未解决项。

最小验证矩阵（未列为通过的项均待执行）：

- 市场：AAPL、一个 A 股、一个港股、一个国际后缀、一个美股类别股；每源注明“不支持”与“无数据”的区别。
- 合约：成功、空响应、null、字符串数值、缺字段、非 JSON 登录页、401/403/429/5xx。
- 时间：秒/毫秒、UTC/上海/纽约、休市日、历史 asOf、宏观修订、季度跨界。
- 缓存：同请求合并、过期、Key 切换、取消、旧请求晚到不能覆盖新配置。
- 凭证：无 Key、保存失败、删除失败、重启恢复、签名沙箱访问；日志无凭证。

真实探测只发最小必要请求，记录 HTTP 状态与字段摘要，不保留凭证、个人持仓或完整社交数据集到 git。联网成功只能证明当时那个 endpoint/symbol/plan 组合有效；mock 测试证明解析分支，不证明源数据真实。

研究背景见 [OpenStock 数据与产品研究](research/openstock-data-product-deep-dive.md)。该研究与旧 handoff 属于历史上下文；当前接口约束与实现差异以本文件及对应源码为核对入口。

### 本轮验证记录

- `docs/data-sources.md` 的相对文件链接已逐个检查存在；README 已加入入口。
- TradingFloor：192 tests / 18 suites 通过；其中四项 `DataProviderContractTests` 使用 URLProtocol 受控响应，验证 Finnhub 认证头、窗口/排序/去重，Adanos 空/缺失/格式限制及错误分类。没有使用真实 Key。
- 应用源码通过临时 SwiftPM 工程构建，生成 arm64 Mach-O 可执行文件；使用本地 CandleKit 和缓存的 MarkdownUI 依赖，补充 Xcode SwiftUI 宏插件路径。此结果不等于正式 Xcode 签名包通过，也不证明依赖锁定版本一致。
- macOS 签名沙箱内 Keychain、真实账号计划权限、生产数据准确性尚未测试。
- 不以 xcodegen 成功或 Swift 语法解析通过代替应用构建和 UI 验证。
