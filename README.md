# ai-driven-workflow-sample

Claude Code のハーネス（フック・サブエージェント・`claude -p` のヘッドレス実行・`/loop` など）を使った
**ループエンジニアリング**を検証するための開発環境。サンプルアプリはすべて TypeScript で書く。

- ベースイメージは `debian:trixie`。VS Code の Dev Containers でも、VS Code を使わずに
  `docker compose` / `docker run` だけでも**同じ環境**が立つ
- ツールの版は `mise.toml` が唯一の情報源（`mise.lock` で sha256 まで固定）。Dockerfile に版番号は無い
- WSL2 ホスト前提で権限を設計してある（uid/gid 一致・ボリュームの所有権修復）
- シェルは zsh + oh-my-zsh
- 外部通信遮断（egress firewall）を同梱。**既定ではオフ**

入るもの: Node.js（LTS）/ pnpm / Claude Code / shellcheck は `mise.toml`、TypeScript / Biome は `package.json`。
実際の版は `mise.lock` と `pnpm-lock.yaml` にあり、`mise run doctor` で一覧できる。

## はじめかた

### VS Code

WSL 内のフォルダを開いた状態で `Ctrl+Shift+P` → **Dev Containers: Reopen in Container**。

### VS Code を使わない（コンテナランタイムだけ）

```bash
bash .devcontainer/init-host.sh                              # 初回のみ: uid/gid を .env に書く
cd .devcontainer
docker compose up -d --build                                 # 初回は数分
docker compose exec dev bash .devcontainer/post-create.sh    # 初回のみ: 依存解決
docker compose exec dev zsh                                  # 以後はこれだけ
```

compose が無いランタイムでの起動方法は [docs/devcontainer.md](docs/devcontainer.md#1-3-compose-を使わない場合docker-run--podman)。

### コンテナを使わない（素のマシン）

```bash
curl https://mise.run | sh
mise install        # mise.toml / mise.lock のとおりに揃う
mise run deps
mise run check
```

## 日々の操作

```bash
mise tasks                  # タスク一覧
mise run check              # 型検査 + lint（Biome / shellcheck）+ バージョン整合性
mise run fmt                # 整形・自動修正
mise run doctor             # ツールチェーンとコンテナの状態
claude                      # Claude Code（初回はブラウザでログイン。認証はボリュームに残る）
egress-firewall status      # 外部通信遮断の状態
```

`mise run check` は短時間で終わる決定的な関門にしてあるので、フックやループの終了条件にそのまま使える。

## ファイル構成

```
mise.toml / mise.lock        ★ ツールの版の唯一の情報源（lock はコミットする）
mise.tasks.toml              タスク定義
package.json / pnpm-lock.yaml  TypeScript の開発依存（tsc / Biome）
tsconfig.json / biome.json   型検査・lint・整形の設定
scripts/                     補助スクリプト（TypeScript を Node で直接実行）
  pins.ts                    package.json を mise.toml に追従させる / 検証する
  doctor.ts                  環境の診断
.devcontainer/
  compose.yaml               コンテナの実体。VS Code も CLI もこれを起動する
  Dockerfile                 3 段ビルド。版番号は書かない
  devcontainer.json          VS Code 固有の設定（拡張機能・settings）だけ
  entrypoint.sh              起動時に必ず通る入口（→ devcontainer-init）
  devcontainer-init.sh       root で動く初期化（ボリュームの所有権・外部通信遮断）
  firewall/                  外部通信遮断（egress-firewall.sh / allowlist.txt）
  init-host.sh               ホスト側で uid/gid を .env に書く
  post-create.sh             作成後のセットアップ（両方の起動経路で共通）
  zshrc                      コンテナの .zshrc
  .env.example               uid/gid・ワークスペース・外部通信遮断の設定
docs/
  devcontainer.md            環境の設計・WSL の権限・トラブルシュート
  egress-firewall.md         外部通信遮断の使い方と Tips
```

## ドキュメント

- [docs/devcontainer.md](docs/devcontainer.md) — 環境の設計、版の上げ方、WSL の権限、トラブルシュート
- [docs/egress-firewall.md](docs/egress-firewall.md) — 外部通信遮断の有効化・許可リスト・限界と Tips
