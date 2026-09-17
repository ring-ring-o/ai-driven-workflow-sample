# ブランチ戦略

**設計の核: `master` は常に緑（`mise run check` が通る）。作業はすべて短命ブランチで行い、`--no-ff` でマージして 1 単位で戻せるようにする。**

ループ（[loop-architecture.md](loop-architecture.md)）で Claude が無人で commit を積むことを前提にしているので、
「人が読む単位」と「機械が積む単位」を分けるのがこの戦略の目的。

## 0. 決めたこと

| 決めたこと | 実装 | 理由 |
|---|---|---|
| 幹は `master` 1 本 | `develop` や `release` は作らない | サンプルリポジトリに複数の幹は要らない。増やすのは必要になってから |
| `master` に直接 commit しない | 必ずブランチ → マージ | `master` が赤くなる経路を 1 つにする |
| `master` は常に緑 | マージ前にブランチで `mise run check` を通す | ループの終了条件が `mise run check` なので、赤い幹からループを始めると終わらない |
| ブランチは短命 | 数日以内にマージか削除 | 長生きすると rebase が痛くなる |
| マージは `--no-ff` | `git merge --no-ff` でマージコミットを残す | ブランチ 1 本 = 1 単位で `git revert -m 1` できる。ループが積んだ細かい commit をまとめて戻せる |
| マージ前に `master` へ rebase | 分岐していたら `git rebase master` | マージコミットの中身が直線になり、読める |
| ループは専用ブランチで回す | `loop/<task>` | 無人の commit が `master` や人のブランチに混ざらない |
| ループ内から push しない | `.claude/settings.json` の deny に `Bash(git push *)` | 不可逆操作は人が押す |
| `master` への force push 禁止 | 運用ルール（GitHub 側の保護は後で） | 履歴を共有の事実として扱う |

## 1. ブランチの種類

| 接頭辞 | 用途 | 作る人 | 例 |
|---|---|---|---|
| `feat/` | 機能追加 | 人 / Claude（監視下） | `feat/todo-api` |
| `fix/` | 修正 | 人 / Claude（監視下） | `fix/biome-format` |
| `docs/` | 文書だけの変更 | 人 / Claude | `docs/branch-strategy` |
| `chore/` | ツールの版・設定・依存 | 人 | `chore/bump-node` |
| `loop/` | 無人ループ（`/goal`, Stop hook, `scripts/loop.sh`）の作業 | Claude（無人） | `loop/todo-api-tests` |
| `claude/` | Routines（クラウド）が自動で切る接頭辞。予約。手で作らない | Claude Code のクラウド側 | `claude/nightly-review` |

接頭辞のあとは `kebab-case`。issue 番号があれば末尾に `-123`。

## 2. 手順

### 2-1. 人が作業する

```bash
git switch master && git pull --ff-only
git switch -c fix/biome-format
# ... 作業 ...
mise run check                      # 緑にしてから
git add -A && git commit
git rebase master                   # 分岐していれば
git switch master && git merge --no-ff fix/biome-format
git push origin master
git branch -d fix/biome-format
```

### 2-2. ループに任せる

```bash
git switch -c loop/todo-api-tests master
# TASK.md を書く → /goal か scripts/loop.sh を回す（push はしない）
# 終わったら人が確認:
git log master..HEAD --oneline       # 積まれた commit を眺める
mise run check                       # 緑を自分の目で確認
git switch master && git merge --no-ff loop/todo-api-tests
git push origin master
```

ループが `STATUS: BLOCKED` で止まったら、ブランチはそのまま残して人が続きをやるか、`git branch -D` で捨てる。
捨てても `master` には何も残らないのが `loop/` を分ける理由。

### 2-3. レビューが要るとき

ブランチを `git push -u origin <branch>` して PR を作る。マージは PR 上でも手元でもよいが、**方式は `--no-ff`（GitHub の "Create a merge commit"）に揃える**。squash はループの commit 履歴を消すので使わない。

## 3. commit メッセージ

- 1 行目はブランチの接頭辞と同じ種別で始める: `fix: devcontainer.json を Biome の整形に合わせる`
- 日本語でよい。本文は「なぜ」を書く。「何を」は diff を見れば分かる
- Claude が commit するときは末尾に `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` を付ける
- 1 commit = 1 つの意図。ループでは「TASK.md の 1 項目 = 1 commit」

## 4. 禁止事項

| してはいけない | 代わりに |
|---|---|
| `master` に直接 commit / push | ブランチを切る |
| `master` への `push --force` | 戻したいなら `git revert -m 1 <merge commit>` |
| squash マージ | `--no-ff` |
| ループ内からの `git push` | 人がマージして push |
| 赤い状態でマージ | `mise run check` を緑にしてから |
| `loop/` ブランチに人が commit を混ぜる | 人が続きをやるなら `fix/` などに切り直す |

## 5. あとで足すかもしれないもの（今は足さない）

- GitHub のブランチ保護（`master` への直接 push と force push の禁止、`mise run check` の必須化）
- CI で `mise run check`（GitHub Actions）
- タグとリリース

いずれも「今困っていない」ので入れない。困ったときに 1 つずつ。
