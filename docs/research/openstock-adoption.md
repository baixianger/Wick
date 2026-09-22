# OpenStock 功能采纳建议

调研日期：2026-09-22。对象：[Open-Dev-Society/OpenStock](https://github.com/Open-Dev-Society/OpenStock) 的公开 `main` 分支。核对 README、关键源码及 Wick 当前实现；未固定提交版本、未运行 OpenStock 服务，因此以下不是完整安全审计或线上行为验证。

后续深度研究见 [数据与产品设计结合方案](openstock-data-product-deep-dive.md)，补充数据权限、市场覆盖、请求预算及页面流程，并将首批重点细化为真实新闻/财报日历与持仓动态。

建议把 OpenStock 作为功能参考，在 Wick 的本地 macOS 架构里独立实现。优先补齐价格提醒和持仓简报，沿用现有行情适配器、持仓、自选分组和 LLM/Codex OAuth 接入。

## 已有实现与值得采纳的部分

| 能力 | OpenStock 源码观察 | Wick 的采纳方式 |
| --- | --- | --- |
| 价格提醒 | 有方向、阈值、有效期与触发状态；后台每五分钟检查，但命中后仅记录日志并更新数据库，尚未发送通知。[模型](https://github.com/Open-Dev-Society/OpenStock/blob/main/database/models/alert.model.ts)、[任务](https://github.com/Open-Dev-Society/OpenStock/blob/main/lib/inngest/functions.ts) | 高优先级：自选/持仓行添加提醒入口，本地规则计算，macOS 通知，保留触发记录。 |
| 新闻简报 | 当前周报任务汇总一般市场新闻并广播邮件。[任务源码](https://github.com/Open-Dev-Society/OpenStock/blob/main/lib/inngest/functions.ts) | 高优先级：扩展为与当前持仓、自选分组相关的应用内简报；复用用户所选模型，包含新闻出处和时间。个性化持仓简报是我们的设计建议。 |
| 多来源情绪 | 聚合 Reddit、X、新闻、Polymarket，展示覆盖来源和分歧。[数据处理](https://github.com/Open-Dev-Society/OpenStock/blob/main/lib/actions/adanos.helpers.ts)、[卡片](https://github.com/Open-Dev-Society/OpenStock/blob/main/components/stocks/StockSentimentCard.tsx) | 中优先级：将 Wick 已有社交数据做成可查看证据的来源卡片；不同来源分开显示样本量、时效和缺失状态。 |
| 快捷搜索 | Cmd/Ctrl K 搜索，输入防抖，显示交易所等识别信息。[实现](https://github.com/Open-Dev-Society/OpenStock/blob/main/components/SearchCommand.tsx) | 小型体验改进：在现有搜索上增加原生 Cmd K 面板，并提供打开股票、开始分析、创建提醒等入口。 |

OpenStock 使用 Next.js、MongoDB、BetterAuth、Inngest 等 Web 服务组件；详情页大量图表和公司信息来自 TradingView 嵌入组件。它不是可以直接接进 Swift 的行情或技术分析 SDK。Wick 已有原生图表和市场首页，当前应继续使用这些实现。[依赖](https://github.com/Open-Dev-Society/OpenStock/blob/main/package.json)、[股票详情页](https://github.com/Open-Dev-Society/OpenStock/blob/main/app/%28root%29/stocks/%5Bsymbol%5D/page.tsx)

## 第一阶段：数据时效与本地价格提醒

当前 [LiveDataStore](../../Wick/Data/LiveDataStore.swift) 的图表读取会直接返回已有缓存，也允许展示模拟数据。它不能直接充当提醒的实时价格源。需要先给现有适配器补充明确的报价契约，再接提醒功能。

建议新增以下组件（名称为拟议设计，尚未实现）：

- `QuoteSnapshot` / `QuoteProvider`：包含规范化证券标识、市场、币种、价格、提供方报价时间、抓取时间及数据来源状态。报价时间与抓取时间必须区分；无法证明足够新鲜时不触发提醒。
- `PriceAlert` / `AlertEvaluator`：Foundation 层保存规则和纯函数判断。首版支持大于等于、小于等于、到期和单次触发；明确这是满足阈值条件，不是检测两次采样之间的穿越。
- `AlertStore` / `AlertMonitor`：本地持久化、按证券合并请求、限流、失败退避。先保存有唯一标识的触发事件，再提交通知；记录投递状态并用同一标识重试，避免重复通知。
- 通知桥接与 SwiftUI 入口：使用系统本地通知，提供未授权、暂停、行情过期、已触发等可理解状态；通知未获授权时仍可查看应用内触发记录。

首版边界是 **Wick 进程运行且电脑未休眠时检查**。醒来后重新拉取报价；关闭应用或休眠期间无法保证监测，也不能从醒来后的单点价格推断期间曾触发。界面应显示最后成功检查时间。后续若需要独立运行，再设计本地常驻组件。

规则判断不调用模型。后续 Wicker 可通过现有工具注册机制创建、列出或取消提醒，模型只负责将自然语言转换为明确规则。首版交付测试应覆盖阈值边界、过期/模拟/缺失报价、币种不匹配、提醒到期、重启恢复和通知重试去重。

## 第二阶段：持仓与自选简报

复用 [WatchlistStore](../../Wick/Data/WatchlistStore.swift) 的分组与持仓范围，由拟议的 `BriefService` 组织有时间戳的行情变化和新闻，调用现有用户选定的 LLM Provider 或 Codex OAuth Provider，保存可回看的本地简报。先提供手动生成，再考虑应用运行期间的定时刷新与用量预算。

[NewsStore](../../Wick/Data/NewsStore.swift) 的展示接口在无真实新闻时会返回 `NewsFixtures`，且已有缓存不会自动按时间失效。简报应消费原始新闻提供方的真实文章，保留发布时间和链接，明确显示无数据或过期状态；不得把展示用样例当作事实。相同文章按 URL 去重，限制文章数和模型输入长度。

后台任务须遵守现有 [SocialSentimentProvider](../../TradingFloor/Sources/TradingFloor/Tools/SocialSentiment.swift) 的 `interactiveOnly` 约束；需要用户交互的浏览器数据源不能自动加入无人值守轮询。情绪卡片先利用已有适配器，新增聚合商应另行核对市场覆盖、费用和使用条款。不同平台的情绪分数不直接平均成“上涨概率”。

## 许可与实施范围

OpenStock 使用 [AGPL-3.0](https://github.com/Open-Dev-Society/OpenStock/blob/main/LICENSE)，而 Wick 的 [README](../../README.md) 当前声明专有许可。直接复制或翻译移植源码，需要先解决许可兼容性或取得另行授权；桌面本地运行并不意味着分发衍生代码时没有许可义务。本方案采用独立编写的 Swift 实现，不复制其源码、提示词或素材。

建议实施顺序：**报价时效契约 → 原生价格提醒 → 持仓简报 → 情绪证据卡片**。Cmd K 可以作为独立的小改进穿插完成。全部沿用 Wick 的本地执行架构；本次只交付研究与设计建议，未接入新的服务或修改应用行为。
