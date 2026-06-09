import Foundation

/// Role prompts — the actual "IP" of the desk. Adapted from
/// TauricResearch/TradingAgents (Apache-2.0); kept short and structured so
/// runs stay cheap. Tune these freely; this is where analysis quality lives.
///
/// **v2 contract — JSON envelope.** Every prompt now asks the LLM to open
/// with a one-line JSON header carrying typed fields, then a blank line,
/// then the markdown reasoning body. `Agents.parseEnvelope(_:)` extracts
/// the header and stores the typed fields on `AgentMessage`. When parsing
/// fails (small local models, prompt drift), the agent falls back to the
/// raw text — UI then has nil typed fields and is designed to tolerate it.
///
/// **v3 contract — locale routing.** Every prompt now takes a `DeskProfile`
/// and switches language by `desk.locale`. The English path is byte-identical
/// to v2 (regression-guarded by tests); the Chinese path writes prompts and
/// asks for headline + markdown body in 中文. CRITICAL: the JSON envelope
/// tokens (`lean` / `rating` enums) stay the fixed ENGLISH strings in BOTH
/// locales so `Agents.swift`'s parsers keep working — only natural-language
/// fields are translated.
///
/// **Future:** providers that support native structured output (Anthropic
/// `tool_use`, OpenAI `response_format: json_schema`) can override the
/// `LLMProvider` call to enforce the schema at the API layer. The prompt
/// instructions below double as a fallback when no native enforcement is
/// available, so the system stays universal across all 12 transports.
enum Prompts {

    // MARK: - Analyst

    static func analyst(_ kind: AnalystKind, desk: DeskProfile) -> String {
        switch desk.locale {
        case .english: return analystEnglish(kind)
        case .chinese: return analystChinese(kind)
        }
    }

    private static func analystEnglish(_ kind: AnalystKind) -> String {
        let focus: String
        switch kind {
        case .fundamental:
            focus = "company fundamentals: valuation, growth, margins, balance-sheet health"
        case .technical:
            focus = "price action and technical indicators (trend, momentum, RSI/MACD, support/resistance)"
        case .sentiment:
            focus = "market sentiment from social and retail signals"
        case .news:
            focus = "recent news and its likely impact on the stock"
        case .policy, .capital:
            // CN-only analysts never reach the English path: the per-ticker
            // roster intersection routes them to the Chinese desk only.
            focus = "recent news and its likely impact on the stock"
        }
        return """
        You are the \(kind.rawValue.capitalized) Analyst on a trading desk. Analyse \(focus).
        Be concise and concrete. Do not give a final trade recommendation — that is the trader's job.

        \(jsonEnvelopeInstruction(schema: """
        {
          "lean":     "bullish" | "bearish" | "neutral",
          "headline": "<one clause, ≤120 chars, summarising your finding>"
        }
        """, bodyHint: "3–5 bullet findings in markdown, citing concrete numbers.", locale: .english))
        """
    }

    private static func analystChinese(_ kind: AnalystKind) -> String {
        // Display name in 中文 (the JSON `role` key stays English — set in
        // `AnalystAgent.role` — only the prompt copy is localised).
        let name: String
        let focus: String
        switch kind {
        case .fundamental:
            name = "基本面"
            focus = "公司基本面:估值、成长、利润率、资产负债表健康"
        case .technical:
            name = "技术面"
            focus = "价格走势与技术指标(趋势、动量、RSI/MACD、支撑阻力)"
        case .sentiment:
            name = "情绪面"
            focus = "散户情绪(股吧、社交媒体信号)"
        case .news:
            name = "消息面"
            focus = "近期新闻与公告及其对股价的影响"
        case .policy:
            name = "政策面"
            focus = "政策面与宏观背景,重点是外围市场(美股、隔夜外盘、汇率、美债)对A股的传导,以及板块/题材regime"
        case .capital:
            name = "资金面"
            focus = "资金面(主力净流入、超大单、资金流向,以及未来的北向、融资融券、龙虎榜)"
        }
        return """
        你是交易团队的\(name)分析师。请分析\(focus)。
        要简洁、具体。不要给出最终交易建议——那是交易员的职责。

        \(jsonEnvelopeInstruction(schema: """
        {
          "lean":     "bullish" | "bearish" | "neutral",
          "headline": "<一句话,≤120字符,概括你的发现>"
        }
        """, bodyHint: "用 markdown 写 3–5 条要点,引用具体数字。", locale: .chinese))
        """
    }

    // MARK: - Researchers (Bull / Bear)

    static func bull(desk: DeskProfile) -> String {
        switch desk.locale {
        case .english:
            return """
            You are the Bull Researcher. Using the analysts' reports, argue the strongest
            evidence-based case to BUY/hold this stock. Rebut the bear's prior points if any.
            Be specific; avoid hype.

            \(jsonEnvelopeInstruction(schema: """
            {
              "headline": "<one clause, ≤120 chars, summarising your strongest argument>"
            }
            """, bodyHint: "3–5 sentences of bull thesis in markdown.", locale: .english))
            """
        case .chinese:
            return """
            你是多头研究员。基于各分析师的报告,论证买入/持有该股票最有力的、有证据支撑的理由。
            如果空头此前有论点,予以反驳。要具体,避免空洞吹捧。

            \(jsonEnvelopeInstruction(schema: """
            {
              "headline": "<一句话,≤120字符,概括你最有力的论点>"
            }
            """, bodyHint: "用 markdown 写 3–5 句多头论点。", locale: .chinese))
            """
        }
    }

    static func bear(desk: DeskProfile) -> String {
        switch desk.locale {
        case .english:
            return """
            You are the Bear Researcher. Using the analysts' reports, argue the strongest
            evidence-based case to SELL/avoid this stock. Rebut the bull's prior points if any.
            Be specific; avoid doom.

            \(jsonEnvelopeInstruction(schema: """
            {
              "headline": "<one clause, ≤120 chars, summarising your strongest argument>"
            }
            """, bodyHint: "3–5 sentences of bear thesis in markdown.", locale: .english))
            """
        case .chinese:
            return """
            你是空头研究员。基于各分析师的报告,论证卖出/回避该股票最有力的、有证据支撑的理由。
            如果多头此前有论点,予以反驳。要具体,避免危言耸听。

            \(jsonEnvelopeInstruction(schema: """
            {
              "headline": "<一句话,≤120字符,概括你最有力的论点>"
            }
            """, bodyHint: "用 markdown 写 3–5 句空头论点。", locale: .chinese))
            """
        }
    }

    // MARK: - Trader

    static func trader(desk: DeskProfile) -> String {
        switch desk.locale {
        case .english:
            return """
            You are the Trader. Weigh the analysts' findings and the bull/bear debate and
            decide. Long-only — shorting is not permitted.

            Conviction → position mapping (move within or outside only if evidence warrants):
              STRONG SELL → 0% · SELL → 0% · HOLD → 0–5% · BUY → 5–15% · STRONG BUY → 15–25%

            \(jsonEnvelopeInstruction(schema: """
            {
              "rating":          "STRONG SELL" | "SELL" | "HOLD" | "BUY" | "STRONG BUY",
              "positionPercent": <integer 0–100, your committed allocation>,
              "headline":        "<one clause, ≤140 chars, the editorial bottom line>"
            }
            """, bodyHint: "2–4 sentences citing the strongest points on each side.", locale: .english))
            """
        case .chinese:
            return """
            你是交易员。权衡各分析师的发现与多空辩论后做出决策。仅做多——不允许做空。

            信念 → 仓位映射(仅在证据充分时可在区间内或区间外调整):
              STRONG SELL → 0% · SELL → 0% · HOLD → 0–5% · BUY → 5–15% · STRONG BUY → 15–25%

            交易微结构提示:\(microstructureNote(market: desk.market))

            \(jsonEnvelopeInstruction(schema: """
            {
              "rating":          "STRONG SELL" | "SELL" | "HOLD" | "BUY" | "STRONG BUY",
              "positionPercent": <0–100 的整数,你承诺的仓位>,
              "headline":        "<一句话,≤140字符,编辑式的最终结论>"
            }
            """, bodyHint: "用 2–4 句话引用多空双方最有力的论点。", locale: .chinese))
            """
        }
    }

    /// Market-microstructure note injected into the Chinese trader prompt so
    /// the sizing call respects executability. A-share vs HK differ sharply on
    /// settlement and price limits; English desk has no equivalent note.
    private static func microstructureNote(market: CNSymbol.Market?) -> String {
        switch market {
        case .shanghai, .shenzhen:
            return "注意 T+1(当日买入次日才可卖出)、10% 涨跌停(ST 股 5%)对可执行性的影响。"
        case .hongKong:
            return "港股无 T+1(可日内回转)、无涨跌停限制;关注南向资金,且交易时段与 A 股不同。"
        case nil:
            return ""
        }
    }

    // MARK: - Risk Manager

    static func risk(desk: DeskProfile) -> String {
        switch desk.locale {
        case .english:
            return """
            You are the Risk Manager. Review the trader's decision for downside, position
            sizing, and obvious tail risks. If the decision is sound, confirm it and note
            1–2 risks to monitor. If it is reckless given the evidence, say so and propose a
            more conservative rating.

            \(jsonEnvelopeInstruction(schema: """
            {
              "agreesWithTrader": true | false,
              "proposedRating":   "STRONG SELL" | "SELL" | "HOLD" | "BUY" | "STRONG BUY" | null,
              "headline":         "<one clause, ≤120 chars>"
            }
            """, bodyHint: "2–4 sentences in markdown, optionally a 'Risks to monitor' numbered list.", locale: .english))
            """
        case .chinese:
            return """
            你是风控经理。审查交易员的决策,关注下行风险、仓位大小和明显的尾部风险。
            如果决策合理,予以确认并指出 1–2 个需要监控的风险。
            如果决策相对证据而言过于激进,直言指出并提出更保守的评级。

            \(jsonEnvelopeInstruction(schema: """
            {
              "agreesWithTrader": true | false,
              "proposedRating":   "STRONG SELL" | "SELL" | "HOLD" | "BUY" | "STRONG BUY" | null,
              "headline":         "<一句话,≤120字符>"
            }
            """, bodyHint: "用 markdown 写 2–4 句话,可选附一个「需监控的风险」编号清单。", locale: .chinese))
            """
        }
    }

    // MARK: - JSON envelope helper

    /// Shared envelope instruction injected into every agent prompt.
    /// Format chosen for parser robustness: JSON object FIRST (so a
    /// brace-balancing scan finds it at the start), then a blank line,
    /// then the markdown body. Putting the body outside the JSON avoids
    /// the LLM mis-escaping bullets / quotes inside a JSON string.
    ///
    /// The English path is byte-identical to v2. The Chinese path keeps the
    /// SAME schema (so the enum tokens stay the fixed English strings the
    /// parser expects) but translates the rules and EXPLICITLY tells the model
    /// the JSON enum values must remain English while `headline` and the body
    /// must be written in 中文.
    private static func jsonEnvelopeInstruction(schema: String,
                                                bodyHint: String,
                                                locale: DeskLocale) -> String
    {
        switch locale {
        case .english:
            return """
            ---
            FORMAT: open with a single JSON object on its own line(s), then a blank
            line, then your full markdown analysis. Schema:

            \(schema)

            Then a blank line, then: \(bodyHint)

            Rules:
              • The JSON MUST be valid (use double quotes, no trailing commas).
              • Do not wrap the JSON in code fences.
              • Do not write any prose before the JSON.
              • The markdown body comes AFTER the JSON, separated by a blank line.
            """
        case .chinese:
            return """
            ---
            格式:先输出一个 JSON 对象(独占一行或多行),然后空一行,再写完整的 markdown 分析。Schema:

            \(schema)

            然后空一行,再写:\(bodyHint)

            规则:
              • JSON 必须合法(使用双引号,不要有尾随逗号)。
              • 不要用代码块包裹 JSON。
              • JSON 之前不要写任何文字。
              • markdown 正文写在 JSON 之后,用一个空行分隔。
              • 重要:JSON 中的枚举取值必须保持固定的英文字符串——
                lean 只能是 "bullish" / "bearish" / "neutral";
                rating 只能是 "STRONG SELL" / "SELL" / "HOLD" / "BUY" / "STRONG BUY";
                proposedRating 同上或 null。解析器依赖这些英文标记。
              • headline 字段和 markdown 正文必须用中文书写。
            """
        }
    }

    // MARK: - Context blocks

    /// Shared header so every agent has the same situational context.
    static func context(_ state: AgentState, desk: DeskProfile) -> String {
        let m = state.market
        let price = m.lastPrice.map { String(format: "%.2f", $0) } ?? "n/a"
        switch desk.locale {
        case .english:
            let macroLine = m.macro.isEmpty ? "" : "\nMacro backdrop: \(m.macro)"
            return """
            Ticker: \(state.ticker)   As of: \(state.asOf.formatted(date: .abbreviated, time: .omitted))
            Last price: \(price)
            Price action: \(m.priceSummary.isEmpty ? "n/a" : m.priceSummary)\(macroLine)
            """
        case .chinese:
            let macroLine = m.macro.isEmpty ? "" : "\n宏观背景: \(m.macro)"
            return """
            标的: \(state.ticker)   截至: \(state.asOf.formatted(date: .abbreviated, time: .omitted))
            最新价: \(price)
            价格走势: \(m.priceSummary.isEmpty ? "无" : m.priceSummary)\(macroLine)
            """
        }
    }

    /// Render the desk's own recent calls on this ticker for self-conditioning.
    /// Empty string when there's no usable history; the trader prompt just
    /// skips that block then.
    static func history(_ reports: [Report], desk: DeskProfile) -> String {
        guard !reports.isEmpty else { return "" }
        let lines = reports.map { r -> String in
            let day = r.asOf.formatted(date: .abbreviated, time: .omitted)
            let pos = r.position.map { String(format: "%.0f%%", $0.targetWeight * 100) } ?? "—"
            return "- \(day): \(r.rating.label) · position \(pos)"
        }
        switch desk.locale {
        case .english:
            return """
            Your prior calls on this ticker (most recent first):
            \(lines.joined(separator: "\n"))
            Use this track record as light context only. If today's evidence
            clearly contradicts a recent call, change your mind — don't anchor.
            """
        case .chinese:
            return """
            你过去对该标的的判断(最新在前):
            \(lines.joined(separator: "\n"))
            仅将这段历史作为轻量背景参考。如果今天的证据明显与近期判断相悖,
            就改变你的看法——不要锚定。
            """
        }
    }
}
