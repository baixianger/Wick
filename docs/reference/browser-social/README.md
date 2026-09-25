# Swift WebKit 社交浏览器实现归档

2026-09-24：Wick 移除 X/雪球内嵌登录与专用抓取流程，保留外部浏览器链接。这里保存可复用技术经验及移除前源码，**不属于应用编译目标，也不代表网站现在仍可抓取**。

## 从哪里开始

- [完整研究与复盘](../../research/webpage-byo-scraping-feasibility.md)：API 使用、实验过程、失败路径，以及本文对应的经验索引。
- [来源提交及逐文件校验值](manifest.json)：12 个原始源码快照，来自移除前 HEAD，字节内容未改写。源码中的旧结论、日志策略及时间性假设不应直接当作生产建议。
- [雪球适配器](Wick/Browser/XueqiuLiveScraper.swift)：同源 fetch、共享会话、页面就绪合并。
- [X 适配器](Wick/Browser/XLiveScraper.swift)：站内搜索导航、DOM 等待、单次提取。
- [原会话管理器](Wick/Browser/BrowserSessionManager.swift)：可见登录页、无视图页面、登录状态和通用浏览器的组合。
- [原 SocialView](Wick/Views/SocialView.swift)：登录 sheet、会话状态、刷新和逐股票缓存。
- [原 MCP bridge](Wick/Browser/BridgeServer.swift)、[雪球情绪适配器](Wick/Browser/XueqiuSentimentProvider.swift)：浏览器层与 Foundation/AI 层之间的连接。
- [雪球 probe](Wick/Prototypes/Xueqiu/XueqiuProbe.swift)、[X probe](Wick/Prototypes/X/XProbe.swift)：实验步骤；同目录 View/Window 保存调试 UI。

## 两条流程的关键区别

```text
共同：用户在可见 WebView 登录
       → 固定标识的 WKWebsiteDataStore
       → 同一 store 下复用长期持有的 WebPage

雪球：轻量首页就绪 → 页面内同源 fetch → HTTP 状态 + JSON → Swift parser
X：搜索 URL 导航 → 等待结果 DOM 或空态 → 一次 DOM 提取 → handle/text
```

这两种实现不能混为“拿 cookie 后用 URLSession 请求”。旧实现把会话留在 WebKit 内；X 最终采用页面导航，让站点自己发请求，再读取已渲染结果。公开 API OAuth 是另一种集成方式。

## 复用时必须重新验证

1. 用目标 SDK 编译 probe；归档源码本身不是独立 Swift package，需要 TradingFloor 协议/解析器及部分 Wick UI 辅助类型。
2. 在独立实验 target 中接入所需文件，不要将整个 archive 加入 Wick sources。
3. 人工完成登录/二次验证；验证共享 store 的页面实际获得会话，不记录 cookie、密码、token 或完整私有响应。
4. 分别验证：未登录、登录成功、过期、网络失败、无内容、页面变更、超时、连续切股及并发刷新。
5. 为每次实验记录 SDK/系统/日期、最终 URL、状态类别、记录数量和脱敏结构；不要用旧文档中的“已验证”替代新实验。
6. 若迁移到生产，先修复旧实现的缺口：错误与空数组合并、原文日志、DOM 样本覆盖不足、过期缓存、导航相互取消、缺少稳定帖子 ID。

本轮仅校验归档内容与原提交相同、引用存在以及移除后的应用构建；没有重新登录 X/雪球，没有删除旧 WebKit cookie 数据，也没有导出会话。
