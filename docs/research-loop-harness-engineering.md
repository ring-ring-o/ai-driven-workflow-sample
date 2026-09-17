# 調査: ループエンジニアリングとハーネスエンジニアリングの現在地（2026-09）

**結論を先に。** 「ハーネスは負債である」という視点は、一次資料（Anthropic / OpenAI の当事者発言、
実測データ、複数の独立した論者）によって概ね裏付けられる。ただし正確には
**「モデルの弱点を補償するために作った構成要素」が負債**であって、
「検証の関門」「権限の境界」「プロジェクト固有の事実」は負債ではなく、モデルが賢くなっても残る。
この区別が設計の骨格になる（→ [loop-architecture.md](loop-architecture.md)）。

調査日: 2026-09-17。対象の Claude Code は v2.1.270（`mise.lock` で固定している版）。

---

## 0. 用語の整理

| 用語 | 意味 | 出典 |
|---|---|---|
| ハーネス | モデル以外の全部。「Agent = Model + Harness。モデルでないなら、それはハーネス」 | Osmani (2026-04) |
| 内側のハーネス | ベンダーが作る部分。システムプロンプト・ツール・コンテキスト管理・権限・サブエージェント機構。Claude Code そのもの | Lee (2026-05), Böckeler (2026-04) |
| 外側のハーネス | 利用者が作る部分。CLAUDE.md・skills・hooks・permissions・MCP・ラッパースクリプト | 同上 |
| ハーネスエンジニアリング | 外側のハーネスを設計する営み。プロンプト → コンテキスト → ハーネス、の第 3 段階 | OpenAI (2026-02), Faros |
| ループエンジニアリング | 「自分がプロンプトを打つ人であることをやめ、代わりに打つ仕組みを設計する」。計画 → 実行 → 観測 → 検証 → 続行/停止 の周回を、人でなく仕組みが回す | Osmani, classmethod (2026) |

ループエンジニアリングはハーネスエンジニアリングの一部で、特に **「いつ次の周回を始めるか」「いつ止まるか」** を扱う。

---

## 1. 一次資料の要点

### 1-1. Anthropic

| 資料 | 要点 |
|---|---|
| Building effective agents (2024-12) | 「可能な限り単純な解を探し、必要になったときだけ複雑さを足す」。フレームワークは抽象層を増やしてデバッグを難しくする。ワークフロー（コードが経路を決める）とエージェント（モデルが経路を決める）を区別せよ |
| Effective harnesses for long-running agents (2025-11-26) | 複数コンテキストウィンドウにまたがる作業の失敗は 2 種類: 全部を一度にやろうとして中途半端に終わる / 早すぎる完了宣言。対策は initializer + coding agent の 2 段構成、機能一覧（JSON）・進捗ファイル・init スクリプト・git という **ファイルに置いた状態**。「テストの削除や改変は許されない」 |
| Agent SDK 紹介記事 | 設計原理は「モデルにコンピュータを渡す」。ループは「文脈を集める → 行動する → 検証する → 繰り返す」。SDK が基盤を持ち、開発者はドメイン固有の検証とツールだけを書く |
| Claude Code 公式 best practices | 「Claude は *できたように見えた* ところで止まる。実行できる検査を渡せば、ループは自分で閉じる」。CLAUDE.md は 200 行以下、「この行を消したら Claude が間違えるか？」で残す。**「Claude がすでに正しくやることは、消すか hook にせよ」** |
| Boris Cherny, YC Startup School (2026-08-02) | Opus 5 向けに Claude Code の **システムプロンプトを約 80% 削除**。「古い指示は、新しいモデルにはもう無い弱点を補償していた」。利用者への助言: **「半年ごとに CLAUDE.md・skills・hooks を消して、モデルが素で何をするか見てから足し直せ」**。残すべきは **ガードレールと検証ループ**、消すべきは行動の矯正 |
| features-overview（公式） | 導入は引き金駆動で: 「同じ規約を 2 回間違えたら CLAUDE.md」「同じプロンプトを 3 回打ったら skill」「毎回必ず起こしたいなら hook」。最初から全部を設定しない |

### 1-2. OpenAI

| 資料 | 要点 |
|---|---|
| Harness engineering (2026-02) | 3 人で 5 か月、約 100 万行、手書きコード 0 行、1,500 PR。エンジニアの仕事は「コードを書く」から「環境を設計し、意図を明示し、構造化されたフィードバックを与える」へ。AGENTS.md、`docs/` を唯一の情報源にする、アーキテクチャ制約を **linter と CI で機械的に強制**、観測基盤をエージェントに渡す。「ドキュメントのガベージコレクション」にも触れている |
| Codex as a platform (2026-08-19) | Codex のハーネス自体をオープンに。ハーネスとは「モデルとタスクの間にあって、文脈収集・ツール呼び出し・サンドボックス・承認境界・進捗ストリーム・複数ターンの継続を担う実行系」 |

OpenAI の記事は「ハーネスは資産」寄りの語り口で、縮小や陳腐化には触れていない。
ただし彼らが挙げる実践の中身（linter / CI / 型による機械的強制）は、次節の分類で「検証型」に当たり、負債論とは矛盾しない。

### 1-3. 独立した論者

| 論者 | 立場 | 要点 |
|---|---|---|
| Birgitta Böckeler / martinfowler.com (2026-04-02) | 中立 | ハーネス = **ガイド（先行制御: 文書・規約）+ センサー（帰還制御: テスト・lint・レビュー）**。それぞれ計算的（決定的）と推論的（LLM 判定）がある。「センサーは LLM 向けに最適化された信号を出すと特に強力」 |
| Addy Osmani (2026-04-19) | ハーネス重視 | 「良いハーネスを持つ並のモデルは、悪いハーネスを持つ優れたモデルに勝つ」。ただし AGENTS.md は **60 行以下、パイロットのチェックリスト**、全ルールは実際の失敗に紐づけ、推測で足さない |
| Geoffrey Huntley (Ralph) | 最小主義 | 「Ralph は技術であり、純粋な形では bash の while ループ」。周回ごとに文脈を捨てる。「一周に一項目だけ」。既存コードベースには使わない。上級者の指導が要る |
| Han Lee (2026-05-08) | 負債論 | 「ほぼ全部が次世代モデルに溶ける」。RAG 基盤 → 長文脈、オーケストレータ／ワーカー → 単一トレース、ツールラッパー → OpenAPI 直読、ルーティンググラフ → 単一モデルの推論。**「薄いハーネス、厚いスキル」「取り外し可能性を設計せよ。消すのに数週間かかるなら、それは荷重を負った負債」「ハーネスは 90 日の成果物として扱え」** |
| Lance Martin (via hugobowne) | 負債論 | Bitter Lesson がアプリ層に来た。「モデルが良くなるたび、構造を剥がし、前提を外し、ハーネスを単純にしなければならない」。Manus は 2024-03 以降 5 回作り直し、LangChain Deep Research は 1 年で複数回 |
| Hugo Bowne-Anderson / O'Reilly | 負債論 | 「**ハーネスの各構成要素は、モデルが単独ではできない何かについての仮定を符号化している**」。モデルが進むと仮定は期限切れになる（Kirby 効果）。コーディングエージェントは 131 行の Python で作れる |
| Guy Erez (2026-08) | 負債論 | 「ハーネスの各部分は仮説」。足したものは外されない。賢くなるほど **外す** のが正しい方向 |
| pardel.dev (2026-07-11) | 実装分類 | ループを「誰が再開を決めるか」で 6 層に分類（→ §2）。「出口条件は検証可能に: 通るテスト、DONE と書かれたファイル、上限ターン数」「周回は冪等に」 |

### 1-4. 反証側の資料

| 資料 | 主張 | 評価 |
|---|---|---|
| Harness as an Asset / CAAF (arXiv 2604.17025) | ドメイン不変条件を実行可能なハーネスに形式化すると「モデルがコモディティ化するほど価値が複利で増える企業資産」になる。安全クリティカル領域では決定的な強制が要る | 主張の対象は **境界型**（不変条件・決定性の強制）。行動矯正型のハーネスを擁護しているわけではない。負債論と両立する |
| Same Model, Different Score (Santana) | NVIDIA の報告として「ハーネス設計だけで二桁のスコア差」 | 著者自身が「モデルとハーネスを同時に変えている比較」と交絡を指摘。ハーネス投資の価値は「振る舞いを計測可能・再現可能にすること」にある、という控えめな結論 |
| Letta Code の例（Lee 経由） | 同じ Opus 4.5 で Letta Code 59.1% vs Claude Code 41.6%。メモリに集中投資した外部ハーネスが一次ハーネスを上回った | **今のモデルに対しては** ハーネスの差が効く実例。ただし同じ資料が「この優位は次のモデルで消える」と論じている |
| Harness Engineering for Agentic AI Coding Tools (arXiv 2602.14690) | 2,853 リポジトリの実測。**コンテキストファイル（CLAUDE.md / AGENTS.md）が支配的で、多くはそれだけ**。Skills / Subagents の採用は少数。Skill の中身はほぼ静的な指示 | 現場は既に最小構成が多数派。高度な機構の採用が伸びていないのは「要らなかった」可能性を示唆する |

---

## 2. Claude Code が今すでに持っているループ機構

「Claude Code の機能に乗せる」ための棚卸し。自作しなくてよいものを確認する。
pardel.dev の分類（誰が次の周回を始めるか）に、公式ドキュメントの仕様を当てた。

| 層 | 機構 | 次の周回を始めるのは | 止まるのは | 仕様上の要点 |
|---|---|---|---|---|
| 0 | 内側のループ | モデル（ツールを呼ぶ限り続く） | モデルが「できた」と判断したとき | ここには手を入れられないし、入れる必要もない |
| 1 | `/goal <条件>` | 前のターンが終わったとき | **別の小型モデル（Haiku）が条件成立と判定** / 不可能と判定 / `/goal clear` | 実体は **セッション限定の prompt 型 Stop hook**。評価器はコマンドを実行しない。会話に出た証拠だけで判定するので「`mise run check` が exit 0」のように **証拠が transcript に残る条件** を書く。4,000 文字まで。「or stop after 20 turns」で上限を書ける。ツールを使わないターンが数回続くと停止。`claude -p "/goal ..."` で無人実行できる |
| 2 | Stop hook（`command` 型） | 前のターンが終わったとき | **自分のスクリプトが exit 0** を返したとき | exit 2 で停止を阻止し stderr を Claude に返す。入力 JSON の `stop_hook_active` を見て早期 exit しないと無限化。**8 回連続で阻止すると Claude Code 側が強制終了**（`CLAUDE_CODE_STOP_HOOK_BLOCK_CAP` で変更）。`prompt` 型 / `agent` 型（実験的）もある |
| 3 | `/loop [間隔] [プロンプト]` | 時間経過（最短 1 分）、または Claude が自分で間隔を決める（1 分〜1 時間） | 手動キャンセル / **7 日で自動失効** / 自己ペースなら Claude が `ScheduleWakeup stop` | セッション限定。`.claude/loop.md` で既定プロンプトを差し替え可能。`Monitor` ツールがあればポーリングの代わりに使う。裏側は `CronCreate/List/Delete` |
| 4 | `claude -p` | 外側のスクリプト | スクリプト | 周回ごとに **文脈が新品**。`--output-format json`（`session_id`, `total_cost_usd`）、`--json-schema` で構造化出力、`--permission-mode auto|acceptEdits|dontAsk`、`--permission-prompts none`（v2.1.259+）、`--allowedTools`、`--continue/--resume`、`--bare`（hooks/skills/CLAUDE.md を読まない。将来の既定）。exit code で成否分岐可 |
| 4' | `ralph-wiggum` プラグイン（Anthropic 公式） | Stop hook が同じプロンプトを再投入 | `--completion-promise` の完全一致文字列 / `--max-iterations` / `/cancel-ralph` | 層 2 を使ったプラグイン。完了文字列は 1 種類しか持てないので `--max-iterations` が主な安全装置 |
| 5 | Routines（`/schedule`、研究プレビュー） | クラウド側のスケジューラ / API POST / GitHub イベント | 実行終了 | Anthropic 管理のクラウド、リポジトリは毎回クローン、最短 1 時間、承認プロンプト無し。ローカルファイルは見えない |
| 5' | Desktop scheduled tasks | ローカルのスケジューラ | 実行終了 | 最短 1 分、ローカルファイルが見える、Desktop アプリが必要 |
| 6 | Dynamic workflows（`ultracode`） | Claude が書いた JS スクリプト | スクリプト終了 | 数十〜数百のサブエージェント。**コストが跳ねる**。最小運用の対象外 |
| 6' | Agent SDK | 自作アプリ | 自作アプリ | 自作ハーネスそのもの。最小運用の対象外 |

補足:

- **`/goal` と Stop hook の使い分け**は公式に明記されている。`/goal` はセッション限定で判定は LLM、
  Stop hook は settings に置いて全セッションに効き、スクリプトなら決定的。
- **`/verify` スキル**（`disable-model-invocation: true`）は人が打つ想定で、`/loop` からは実行されない。
- 公式 best practices の「検証の段階」: 1 プロンプト内で反復 → `/goal` → Stop hook → 別コンテキストのレビュー
  （`/code-review` やサブエージェント）。「各段階は設定の手間と注意力を交換している」。

---

## 3. 「ハーネスは負債」論の検証

### 3-1. 賛成側の根拠（事実）

1. **当事者が実際に削っている。** Claude Code はシステムプロンプトを Opus 5 で約 80% 削除した。
   理由は「古い指示が、もう無い弱点を補償していた」。残した指示は「消すと繰り返し失敗したもの」だけ。
2. **溶けた前例が複数ある。** RAG パイプライン、オーケストレータ／ワーカー分割、ツールラッパー、
   計画モード、圧縮戦略。Manus 5 回、Open Deep Research 複数回の作り直し。
3. **論理的な根拠。** 「各構成要素はモデルにできないことの仮定」（Bowne-Anderson）。
   仮定は検証されずに残り、次のモデルでは **能力を隠す側** に回る（「古いハーネスは新モデルが既に持つ能力の発揮を妨げる」）。
4. **公式ガイドがそう書いている。** 「Claude がすでに正しくやることは消せ」「半年ごとに消して素の挙動を見ろ」。

### 3-2. 反論と、その射程

| 反論 | 妥当な範囲 | 妥当でない範囲 |
|---|---|---|
| 今のモデルではハーネスの差でスコアが二桁動く | 事実。今日の成果を最大化したいなら投資は効く | 「だから恒久的に価値がある」とは言えない。同じ資料が次のモデルで消えると認めている |
| 安全・決定性・監査性は外側でしか担保できない（CAAF） | 事実。権限・サンドボックス・不変条件は **能力ではなく方針** なので、モデルが賢くなっても消えない | これは「行動を矯正するハーネス」の擁護ではない |
| 検証がボトルネック（Cherny） | 事実。2 週間自走した事例はすべて「機械的で曖昧さの無い検証」を持っていた | 検証はハーネスではなく **製品側の品質関門**。モデルが進んでも `mise run check` は要る |
| プロジェクト固有の事実は教えないと分からない | 事実。ビルドコマンド、環境の癖、受け入れ基準 | ただしモデルがコードを読む力が上がるほど、書く量は減る |

### 3-3. 総合判定と、構成要素の 4 分類

「ハーネスは負債」は **補償型に対しては正しく、他の型には当てはまらない**。設計ではこの 4 つを分けて扱う。

| 型 | 何か | モデル向上で | 例 |
|---|---|---|---|
| **補償型** | モデルの弱点の埋め合わせ | **消える（負債）** | 段階を固定した手順書、自作の計画モード、再試行ロジック、自作メモリ、ルーター、「必ず〜せよ」の行動矯正、自作オーケストレータ |
| **情報型** | モデルが推測できない事実 | 縮む | ビルド／検査コマンド、環境の癖、受け入れ基準、リポジトリの作法 |
| **検証型** | 合否を返す機械的な検査 | 残る（製品の資産） | テスト、型検査、lint、exit code、スクリーンショット比較 |
| **境界型** | 方針としての制限 | 残る（薄いまま） | permissions の deny、サンドボックス、外部通信遮断、テストファイルへの書き込み禁止 |

したがって:

- **補償型は原則入れない**。入れるときは「どの失敗を見て入れたか」「何が成り立てば消すか」を書く。
- **検証型に投資する**。ここはハーネスではなく製品なので、ハーネスを捨てても残る。
- **境界型は薄く保つ**。方針は増えないはずなので、増えていたら補償型が混ざっている。
- **情報型は定期的に削る**。「消したら間違えるか」で残す。

「モデルの性能向上とともにハーネスが複雑化するなら、それはオーバーエンジニアリング」という指摘は、
この分類で言えば「モデルが進んでいるのに補償型が増えている」状態を指す。これは事実として起きやすい
（足したものは外されない、という Erez / Lee の観察）ので、**定期的な削除（アブレーション）を運用に組み込む**ことが対策になる。

---

## 4. 設計への含意

1. **ループの制御は組み込み機構（`/goal`, Stop hook, `/loop`, `claude -p`）に任せ、自作しない。**
   Claude Code のリリースごとに内側のハーネスが更新される。外側で同じものを作ると二重管理になり、
   しかも内側の改善が届かなくなる。
2. **外側に置くものは「1 ファイル・状態を持たない・消しても製品が困らない」に限定する。**
   状態は git と作業ディレクトリのファイルに置く（Anthropic の long-running 記事も Ralph も同じ結論）。
3. **終了条件は機械的に。** `mise run check` の exit code、DONE/BLOCKED を書いたファイル、上限回数。
   モデルの自己申告を終了条件にしない。
4. **各構成要素に削除条件を書き、モデルのメジャー更新ごとに削除を試す。**
5. **段階は引き金駆動で上げる。** 素のプロンプト → `/goal` → Stop hook → `claude -p` ループ。
   一段上げるのは、下の段で実際に失敗したときだけ。

具体的な構成は [loop-architecture.md](loop-architecture.md)。

---

## 参考資料

公式・一次資料:

- Anthropic, Building effective agents (2024-12) — https://www.anthropic.com/engineering/building-effective-agents
- Anthropic, Effective harnesses for long-running agents (2025-11-26) — https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents
- Anthropic, Building agents with the Claude Agent SDK — https://claude.com/blog/building-agents-with-the-claude-agent-sdk
- Claude Code docs: best practices — https://code.claude.com/docs/en/best-practices
- Claude Code docs: /goal — https://code.claude.com/docs/en/goal
- Claude Code docs: hooks reference / guide — https://code.claude.com/docs/en/hooks , https://code.claude.com/docs/en/hooks-guide
- Claude Code docs: scheduled tasks (/loop) — https://code.claude.com/docs/en/scheduled-tasks
- Claude Code docs: headless (`claude -p`) — https://code.claude.com/docs/en/headless
- Claude Code docs: routines — https://code.claude.com/docs/en/routines
- Claude Code docs: dynamic workflows — https://code.claude.com/docs/en/workflows
- Claude Code docs: extend (features overview) — https://code.claude.com/docs/en/features-overview
- Anthropic, ralph-wiggum plugin README — https://github.com/anthropics/claude-code/blob/main/plugins/ralph-wiggum/README.md
- OpenAI, Harness engineering (2026-02) — https://openai.com/index/harness-engineering/ （本文は 403 のため InfoQ https://www.infoq.com/news/2026/02/openai-harness-engineering-codex/ と Ken Huang の要約で補完）
- OpenAI, Codex as a platform (2026-08-19) — https://developers.openai.com/blog/codex-as-a-platform
- Boris Cherny, YC Startup School (2026-08-02) の要約 — https://www.barath.ai/learnings/boris-cherny-yc-startup-school-2026 , https://www.ai.joaoqueiros.com/blog/claude-code-cut-system-prompt-boris-cherny-ablation-playbook

論考:

- Birgitta Böckeler, Harness engineering for coding agent users (2026-04-02) — https://martinfowler.com/articles/harness-engineering.html
- Addy Osmani, Agent Harness Engineering (2026-04-19) — https://addyosmani.com/blog/agent-harness-engineering/
- Geoffrey Huntley, Ralph — https://ghuntley.com/ralph/
- Han Lee, Hidden Technical Debt of AI Systems: Agent Harness (2026-05-08) — https://leehanchung.github.io/blogs/2026/05/08/hidden-technical-debt-agent-harness/
- Lance Martin / Hugo Bowne-Anderson, AI Agent Harness, 3 Principles, Bitter Lesson Revisited — https://hugobowne.substack.com/p/ai-agent-harness-3-principles-for
- Hugo Bowne-Anderson, Stop Overengineering Your Agent Harness — https://www.oreilly.com/radar/stop-overengineering-your-agent-harness/
- Guy Erez, Your Agent Harness Is Probably Overengineered (2026-08) — https://levelup.gitconnected.com/your-agent-harness-is-probably-overengineered-cba28f13ba80 （本文は 403、検索スニペットで確認）
- pardel.dev, Claude loops (2026-07-11) — https://www.pardel.dev/2026/07/11/claude-loops.html
- classmethod, Loop Engineering — https://dev.classmethod.jp/en/articles/loop-engineering-claude-code-autonomous/
- Kunal Ganglani, Loop Engineering — https://www.kunalganglani.com/blog/loop-engineering-agent-loops

反証・実測:

- Harness as an Asset (CAAF), arXiv 2604.17025 — https://arxiv.org/abs/2604.17025
- Cristóbal Santana, Same Model, Different Score — https://cristobalsantana.substack.com/p/agent-harness-scaffolding-decides
- Harness Engineering for Agentic AI Coding Tools: An Exploratory Study, arXiv 2602.14690 — https://arxiv.org/abs/2602.14690
