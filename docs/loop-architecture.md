# 設計: 捨てる前提のループエンジニアリング（推奨アーキテクチャ）

**設計の核: ループの制御は Claude Code の組み込み機構に任せ、外側には「消しても製品が困らないもの」しか置かない。**
根拠と調査は [research-loop-harness-engineering.md](research-loop-harness-engineering.md)。
本書は「何を・どこに・どれだけ置くか」「いつ消すか」を決める。

前提: Claude Code v2.1.270（`mise.lock` で固定）。`mise run check` が短時間で終わる決定的な関門として既にある。

---

## 0. 決めたこと

| 決めたこと | 実装 | 理由 |
|---|---|---|
| 関門は製品側に置く | `mise run check`（型検査 + lint + 版整合）と、今後足すテスト | ハーネスを全部捨てても残る唯一の資産。モデルが進んでも「合否を返す機械」は要る |
| ループの制御は自作しない | `/goal` → Stop hook → `claude -p` の組み込み 3 段だけ使う | 内側のハーネスはリリースごとに更新される。外側で同じものを作ると二重管理になり、内側の改善が届かない |
| 外側スクリプトは 1 ファイル・状態を持たない | `scripts/loop.sh`（40 行以内）。状態は git と `TASK.md` | 消すコストがゼロ。状態がファイルにあれば、スクリプトを差し替えても続きから再開できる |
| 補償型の構成要素は入れない | 手順書・自作計画モード・自作メモリ・ルーター・自作オーケストレータ・独自サブエージェントを既定で禁止 | モデルの弱点補償は次のモデルで負債になる。入れるなら「見た失敗」と「消す条件」を書く |
| 全構成要素に削除条件を書く | 本書 §5 の表 | 「足したものは外されない」のを防ぐ。削除条件が書けないものは入れない |
| モデルのメジャー更新ごとにアブレーション | 本書 §6 の手順 | Claude Code 自身がそうしている（Opus 5 でシステムプロンプト 80% 削除） |
| 終了条件は機械的に | exit code、`TASK.md` の `STATUS:` 行、上限回数 | モデルの自己申告を終了条件にしない。「できたように見えた」で止まるのが既定の失敗 |
| 段階は引き金駆動で上げる | 下の段で実際に失敗したときだけ一段上げる | 最初から全部を設定しない（公式 features-overview と同じ） |

---

## 1. 層の構成

```
                              捨てやすさ   モデル向上で
┌────────────────────────────────────────────────────────┐
│ L4  外側スクリプト   scripts/loop.sh（claude -p の周回）│  最高        真っ先に消える
├────────────────────────────────────────────────────────┤
│ L3  ループ制御       /goal ・ Stop hook ・ /loop         │  高          Claude Code 側で更新される
├────────────────────────────────────────────────────────┤
│ L2  境界             permissions ・ 外部通信遮断         │  中          薄いまま残る（方針なので増えない）
├────────────────────────────────────────────────────────┤
│ L1  情報             CLAUDE.md（30 行以内）・TASK.md     │  中          縮んでいく
├────────────────────────────────────────────────────────┤
│ L0  関門（製品）     mise run check ・ テスト            │  捨てない    残る。ここに投資する
└────────────────────────────────────────────────────────┘
```

依存は上から下への一方向。**上の層を消しても下の層は動く**ことを保つ。
逆に、下の層が上の層を知っていたら（例: テストが Stop hook の存在を前提にする）設計違反。

---

## 2. ループの選び方

「誰が次の周回を始めるか」で選ぶ。上から順に試し、失敗したときだけ下へ。

| 段 | 状況 | 使うもの | 終了条件 | 外側に置くもの |
|---|---|---|---|---|
| A | 人が見ている。作業は 1 セッションに収まる | 素のプロンプト: 「`mise run check` が通るまで直して」 | モデルの判断 + 人の目 | 無し |
| B | 人が離れる。1 セッションに収まる | `/goal mise run check が exit 0 で、TASK.md の全項目が [x]。or stop after 30 turns`（auto mode で） | Haiku の評価器が transcript から判定 | 無し（`/goal` はセッション限定） |
| C | B で「できたと言って止まる」が再発した | Stop hook（`command` 型）で `mise run check` を実行し、失敗なら exit 2 | スクリプトの exit code。8 回連続阻止で強制終了 | `.claude/hooks/stop-gate.sh`（20 行） |
| D | 複数コンテキストにまたがる。無人で長時間 | `scripts/loop.sh` が `claude -p` を周回。周回ごとに文脈は新品 | `mise run check` 成功 **かつ** `TASK.md` に `STATUS: DONE`。`BLOCKED` なら異常終了。上限回数 | `scripts/loop.sh` + `TASK.md` |
| E | 時間駆動（CI 待ち、PR 世話） | `/loop`（セッション内）か Routines（クラウド） | 手動 / 7 日失効 / Claude の停止判断 | 無し |

判断の流れ:

```
1 セッションで終わる？ ── yes ─→ 人が見ている？ ── yes ─→ A
        │                              └── no ──→ B ──失敗再発──→ C
        no
        ↓
   D（loop.sh）        ※ 時間駆動なら E
```

段 B 以上は `loop/<task>` ブランチで回し、人が `--no-ff` でマージする（[branching.md](branching.md)）。

**ralph-wiggum プラグイン（公式）について。** 段 C〜D の中間で、Stop hook を使って同じプロンプトを再投入する。
完了文字列が 1 種類しか持てず、`--max-iterations` が主な安全装置。本設計では採用しない。
理由は、D の `loop.sh` の方が終了条件を 2 種類（DONE / BLOCKED）持てて、文脈も周回ごとに新品になるため。
ただし「プラグインを入れるだけで済む」利点はあるので、`loop.sh` を書くのが嫌なら代替として可。

---

## 3. 最小構成ファイル

置くのは 5 つ。合計 150 行以内を目安にする。それ以上になったら §5 の表で削る。

```
CLAUDE.md                     L1  30 行以内。情報型だけ
TASK.md                       L1  今の仕事。人が書き、Claude が更新する。git 管理
.claude/settings.json         L2  permissions。Stop hook は段 C に上げたときだけ足す
.claude/hooks/stop-gate.sh    L3  段 C で足す。20 行以内
scripts/loop.sh               L4  段 D で足す。40 行以内
```

### 3-1. `CLAUDE.md`（案）

```markdown
# ai-driven-workflow-sample

TypeScript のサンプルアプリ。ツールの版は mise.toml（変更しない）。

## コマンド
- 関門: `mise run check`（型検査 + lint + 版整合）。これが exit 0 になるまでが仕事
- 整形: `mise run fmt`
- 依存: `mise run deps`（pnpm。npm は使わない）

## 作業の進め方
- 仕事は TASK.md にある。1 回の作業で 1 項目だけ進め、終えたら `[x]` にして commit する
- 全項目が済んだら TASK.md の先頭行を `STATUS: DONE` にする
- 自力で進められないときは `STATUS: BLOCKED` にして理由を 1 行書く。推測で進めない

## やらないこと
- 関門を通すためにテスト・lint 設定・tsconfig を緩めない
- mise.lock / pnpm-lock.yaml を手で編集しない
- git push はしない（人がやる）
```

「必ず〜せよ」型の行動矯正は入れない。入れたくなったら、それは hook か permissions（L2/L3）の仕事。

### 3-2. `TASK.md`（形式）

```markdown
STATUS: IN_PROGRESS

# やること
- [ ] ...
- [ ] ...

# メモ（Claude が周回ごとに追記。次の周回が読む）
```

Anthropic の long-running 記事の「機能一覧 + 進捗ファイル」を 1 ファイルに畳んだもの。
`STATUS:` 行が外側ループの終了条件になる。**テストを消したり緩めたりして `DONE` にすることは禁止**（CLAUDE.md と permissions の両方で言う）。

### 3-3. `.claude/settings.json`（段 B まで）

```json
{
  "permissions": {
    "allow": [
      "Bash(mise run check)",
      "Bash(mise run fmt)",
      "Bash(mise run deps)",
      "Bash(pnpm test *)",
      "Bash(git add *)",
      "Bash(git commit *)",
      "Bash(git status *)",
      "Bash(git diff *)",
      "Bash(git log *)"
    ],
    "deny": [
      "Bash(git push *)",
      "Edit(mise.lock)",
      "Edit(pnpm-lock.yaml)",
      "Edit(.devcontainer/**)"
    ]
  }
}
```

段 C に上げたら `hooks` を足す:

```json
{
  "hooks": {
    "Stop": [
      { "hooks": [ { "type": "command", "command": "bash .claude/hooks/stop-gate.sh", "timeout": 300 } ] }
    ]
  }
}
```

### 3-4. `.claude/hooks/stop-gate.sh`（段 C）

```bash
#!/usr/bin/env bash
# Stop hook: 関門が赤いうちは止まらせない。
# 消し方: settings.json の hooks を消すだけ。他は何も依存していない。
set -u
input=$(cat)
# 既に自分が続行させた周回なら、8 回上限に当たる前に手を引く（無限ループ防止）
if [ "$(printf '%s' "$input" | jq -r '.stop_hook_active')" = "true" ]; then exit 0; fi
# TASK.md が BLOCKED なら止めてよい（人の判断が要る）
grep -q '^STATUS: BLOCKED' TASK.md 2>/dev/null && exit 0
out=$(mise run check 2>&1) && exit 0
printf '関門 mise run check が失敗。直してから終えること。\n%s\n' "$(printf '%s' "$out" | tail -40)" >&2
exit 2
```

`stop_hook_active` を見て即 exit 0 にしているので、**続行は 1 回だけ**。それでも赤いなら次のターンで人に返る。
「8 回まで粘らせる」方が良い結果になる証拠が出るまでは 1 回にしておく（増やすのは `CLAUDE_CODE_STOP_HOOK_BLOCK_CAP` ではなく、この行を消すだけ）。

### 3-5. `scripts/loop.sh`（段 D）

```bash
#!/usr/bin/env bash
# claude -p を周回する使い捨てのループ。状態は git と TASK.md にしか無い。
#   scripts/loop.sh [最大周回数=20]
# 終了: 0 = DONE で関門も緑 / 2 = BLOCKED / 1 = 上限到達
set -euo pipefail
max=${1:-20}
prompt='TASK.md を読み、未完了の項目を 1 つだけ進めて commit する。CLAUDE.md の手順に従う。'
for i in $(seq 1 "$max"); do
  echo "== 周回 $i/$max =="
  claude -p "$prompt" \
    --permission-mode auto --permission-prompts none \
    --output-format json > "/tmp/loop-$i.json" || true
  jq -r '"cost: \(.total_cost_usd) session: \(.session_id)"' "/tmp/loop-$i.json" || true
  if grep -q '^STATUS: BLOCKED' TASK.md; then echo "BLOCKED"; exit 2; fi
  if grep -q '^STATUS: DONE' TASK.md && mise run check; then echo "DONE"; exit 0; fi
done
echo "上限 $max 周回に到達"; exit 1
```

- **周回ごとに文脈は新品**。前の周回の知識は `TASK.md` のメモと git log にしか残らない。それが狙い（Ralph と同じ）。
- 終了条件は「モデルが DONE と書いた」**かつ**「関門が緑」の二重鍵。片方だけでは止まらない。
- `--permission-mode auto` は分類器が危険な操作を止める。コンテナ + 外部通信遮断の中でだけ `--dangerously-skip-permissions` に替えてよい。
- `--bare` は使わない（CLAUDE.md を読ませたいので）。CI で同一結果が要るときだけ検討する。
- 各周回のコストが JSON に出る。上限回数と合わせて、これが予算の管理のすべて。

---

## 4. 終了条件の書き方

| 悪い | 良い |
|---|---|
| 「バグを直す」 | 「`mise run check` が exit 0」 |
| 「品質を上げる」 | 「`pnpm test` が全件通り、変更したファイルは `src/` 配下だけ」 |
| 「できたら止まる」 | 「`TASK.md` の全項目が `[x]` で `STATUS: DONE`。or stop after 30 turns」 |

- **証拠が transcript に残る形**にする（`/goal` の評価器はコマンドを実行せず、会話に出た結果しか見ない）。
- 終了状態は **DONE と BLOCKED の 2 つ**を必ず用意する。1 つしか無いと、不可能な仕事で上限まで回る。
- 上限（回数・ターン・時間）を必ず書く。
- 周回は冪等に: 既に終わっている状態で走らせたら、何もせず安く終わること。

---

## 5. 削除条件

構成要素ごとに「何が成り立てば消すか」を先に決める。**書けないものは入れない。**

| 構成要素 | 型 | 入れる引き金 | 消す条件 | 消すコスト |
|---|---|---|---|---|
| `CLAUDE.md` の各行 | 情報 | 同じ間違いを 2 回見た | 消しても 10 タスクで再発しない | 1 行削除 |
| `TASK.md` | 情報 | 段 B 以上 | Claude が git log と `/goal` の条件だけで進捗を把握できる | ファイル削除 + loop.sh の grep 2 行 |
| permissions allow | 境界 | 承認プロンプトが繰り返し出る | auto mode の分類器が同じ判断をする | 行削除 |
| permissions deny | 境界 | 方針 | 方針が変わったとき（モデル向上では消さない） | 行削除 |
| Stop hook | 補償寄り | 「できたと言って止まる」が `/goal` でも再発 | `/goal` だけで 10 タスク連続で最後まで走る | settings の `hooks` 削除 + sh 1 本 |
| `scripts/loop.sh` | 補償寄り | 1 セッションに収まらない仕事 | `/goal` か `--continue` 付きの `claude -p` 1 回で完走する | ファイル削除 |
| `/loop` の `loop.md` | 情報 | 既定の保守プロンプトで足りない | 既定で足りる | ファイル削除 |
| 外部通信遮断 | 境界 | 方針 | 方針が変わったとき | 既存の仕組み |

**入れないもの（削除条件が書けない、または補償型）:**
自作オーケストレータ、自作メモリ／RAG、独自サブエージェント定義（組み込みの `Explore` / `/code-review` で足りるまで）、
MCP サーバー（外部サービスが仕事に要るまで）、プラグイン、Dynamic workflows / `ultracode`、Agent SDK、
複数エージェントのトポロジー、`PostToolUse` での自動整形（`mise run fmt` を関門の前に呼ぶだけでよい）。

---

## 6. アブレーション（削る運用）

Claude Code チームの手順を利用者向けに縮めたもの。**モデルのメジャー更新ごと、または半年ごと**に行う。

1. 基準を凍結する: 現在の設定のまま、実際の仕事 10 件（人工的なものでなく）を記録しておく。
2. 全部消す: `CLAUDE.md`、`hooks`、`loop.sh` を退避して、素の Claude Code で同じ 10 件を走らせる。
3. 計る: 完走率、`mise run check` 到達までの周回数、コスト（`total_cost_usd`）、範囲外の変更の有無。
4. **繰り返し失敗したものだけ戻す**。戻すときは最小の 1 行・1 ファイル単位で。
5. 戻した理由と、次に消す条件を §5 の表に書く。

結果は `docs/ablation/<日付>.md` に「消したもの / 戻したもの / 数字」だけ残す。

---

## 7. やってはいけない形

| アンチパターン | なぜ | 代わりに |
|---|---|---|
| Stop hook で無条件に exit 2 | 8 回で強制終了されるまで空回りし、`stop_hook_active` を見ないと無限化 | 関門の結果で分岐し、続行は 1 回 |
| 手順書（「まず A、次に B、必ず C」）を CLAUDE.md に書く | 補償型。次のモデルでは能力を隠す | 結果（関門）だけ書き、手順はモデルに任せる |
| 完了をモデルの自己申告だけで判定 | 「できたように見えた」で止まる | exit code との二重鍵 |
| 外側スクリプトが状態を持つ（独自 DB、独自ログ形式） | スクリプトを消せなくなる | git と `TASK.md` |
| モデル更新後も設定が増え続ける | 補償型が溜まっている兆候 | §6 のアブレーション |
| 「念のため」の hook・rule | 失敗に紐づかない構成要素は削除条件が書けない | 引き金（実際の失敗 2 回）を待つ |
| ループ内で `git push` / deploy | 無人で不可逆操作 | deny に入れ、人が押す |

---

## 8. このリポジトリでの導入順

各段は「前の段で足りなかった証拠」を見てから進める。先回りしない。

| 順 | すること | 完了の目安 |
|---|---|---|
| 1 | `CLAUDE.md`（§3-1）と `.claude/settings.json` の permissions（§3-3）を置く | 段 A で `mise run check` まで人が口を挟まずに通る |
| 2 | サンプルアプリに **テストを足し、`mise run test` を `check` に含める** | 関門が「型と lint」だけでなく「振る舞い」も見る。ここが L0 への投資 |
| 3 | `TASK.md` を書き、`/goal` で段 B を試す（auto mode） | 3〜5 項目の仕事が無人で `DONE` に到達する |
| 4 | 段 B で「早すぎる完了」が再発したら Stop hook（§3-4） | 再発が止まる。止まらないなら hook を消して原因を関門側で直す |
| 5 | 1 セッションに収まらない仕事が出たら `scripts/loop.sh`（§3-5） | 周回をまたいで `TASK.md` のメモだけで続きから進む |
| 6 | 次のモデル更新で §6 のアブレーション | 構成が減る。減らないなら §5 の表を見直す |

順 2 が最も価値が高い。ハーネスを全部捨てても残るのはここだけ。
