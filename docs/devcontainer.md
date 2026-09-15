# 開発環境（mise + devcontainer / Debian trixie / WSL2 ホスト）

**設計の核: バージョンを決めるのは `mise.toml` であって Dockerfile ではない。**
Dockerfile には版番号が 1 つも無い。`mise.toml` と `mise.lock` を COPY して `mise install --locked` するだけ。

## 0. 全体像

| 決めたこと | 実装 | 理由 |
|---|---|---|
| 版の情報源は 1 ファイル | `mise.toml` | Dockerfile / devcontainer.json / CI / 素のマシンが同じものを読む |
| 「同じ版」ではなく「同じバイナリ」 | `mise.lock` + `--locked` | URL と sha256 まで固定。lock に無ければビルドが失敗する |
| Claude Code もプロジェクトの定義に入れる | `mise.toml` の `claude` | ハーネスの挙動そのものが検証対象なので、版を lock で固定する |
| VS Code の有無で環境を分岐させない | `compose.yaml` を両方が使う | devcontainer.json は compose を指すだけ |
| Dev Container Features は使わない | すべて mise / apt | Features は `docker compose up` では適用されない |
| 起動時の初期化も分岐させない | イメージの `ENTRYPOINT` | postStartCommand は VS Code でしか走らない |
| タスクランナーも mise | `mise.tasks.toml` | Makefile や package.json scripts と二重管理しない |
| 権限は uid/gid 一致で解決 | build args + `init-host.sh` | WSL の権限問題は結局これしかない |
| 外部通信遮断は同梱・既定オフ | `egress-firewall` | [egress-firewall.md](egress-firewall.md) |

### 起動の流れ

```
[ホスト]  init-host.sh ── uid/gid を .devcontainer/.env へ
             │
[compose] docker compose up（VS Code も内部で同じことをする）
             │
[コンテナ] devcontainer-entrypoint（ユーザー vscode）
             └─ sudo devcontainer-init（root）
                  ├─ 名前付きボリュームの所有権を修復
                  └─ EGRESS_FIREWALL=on なら egress-firewall apply（失敗したら起動を中止）
             │
          sleep infinity
             │
[初回]    post-create.sh ── mise install --locked → pnpm install → pins:check → doctor
```

---

## 1. 起動する

### 1-1. VS Code

WSL 内のフォルダを開いた状態から `Dev Containers: Reopen in Container`。
Windows 側のパス（`\\wsl$\...`）から直接開くと `initializeCommand` が Windows 側で走るので避ける。

### 1-2. docker compose（VS Code なし）

```bash
bash .devcontainer/init-host.sh
cd .devcontainer
docker compose up -d --build
docker compose exec dev bash .devcontainer/post-create.sh
docker compose exec dev zsh
```

VS Code 版との違いは「拡張機能が入らない」ことだけ。停止・破棄:

```bash
docker compose stop
docker compose down        # コンテナを削除（ボリュームは残る = Claude Code のログインも残る）
docker compose down -v     # ボリュームも削除
```

### 1-3. compose を使わない場合（docker run / podman）

compose.yaml と同じ内容をフラグで渡す。

```bash
docker build -f .devcontainer/Dockerfile --target dev \
  --build-arg USER_UID="$(id -u)" --build-arg USER_GID="$(id -g)" \
  -t ai-driven-workflow-sample-dev:latest .

docker run -d --name ai-driven-workflow-sample-dev --init \
  --cap-add NET_ADMIN --cap-add NET_RAW \
  -v "$PWD:/workspaces/ai-driven-workflow-sample" \
  -w /workspaces/ai-driven-workflow-sample \
  -e WORKSPACE_FOLDER=/workspaces/ai-driven-workflow-sample \
  -e EGRESS_FIREWALL=off \
  -v ai-driven-workflow-sample_claude:/home/vscode/.claude \
  -v ai-driven-workflow-sample_command-history:/home/vscode/.commandhistory \
  ai-driven-workflow-sample-dev:latest

docker exec ai-driven-workflow-sample-dev bash .devcontainer/post-create.sh
docker exec -it ai-driven-workflow-sample-dev zsh
```

ボリューム名を compose と揃えておくと、どちらで起動しても Claude Code のログインを共有できる。

**Podman（未検証）**: rootless Podman はコンテナ内の uid をホストの別 uid に写像するため、
そのままではバインドマウントの所有者がずれる。`podman run` なら `--userns=keep-id` を足す。
`podman compose` なら `.devcontainer/compose.override.yaml` を作り、
`services.dev.userns_mode: keep-id` を書く（`-f` を付けずに起動すれば自動で重ねられる）。

### 1-4. コンテナを使わない（素のマシン）

```bash
curl https://mise.run | sh
mise install && mise run deps && mise run check
```

---

## 2. 版を変える

```bash
mise lock --bump node       # 範囲（"24"）内の最新へ lock を進める。引数なしなら全ツール
mise install
mise run pins:sync          # package.json の packageManager / @types/node を追従させる
mise run check
```

- `mise.toml` はメジャー版までしか書かない。メジャーをまたぐ更新（例: `claude = "2"` → `"3"`）は
  `mise.toml` を書き換えたときだけ起きる
- `mise install` だけでは lock 済みの版が使われ続ける（それが lock の目的）
- mise は公開直後のリリースを既定で隠す（`minimum_release_age`）。サプライチェーン対策として効いている
- コンテナは Rebuild すると新しい lock でイメージが作り直される。Rebuild しなくても
  `post-create.sh`（`mise install --locked`）を叩けば差分だけ入る

### package.json のピン

| 値 | 扱い | 理由 |
|---|---|---|
| `packageManager` | `mise.toml` から生成 | pnpm はこの値を見て自分を別の版に切り替える |
| `devDependencies["@types/node"]` の major | `mise.toml` の node と照合 | 型定義と実行時の Node の major がずれると、存在しない API が型検査を通る |

`mise run pins:check`（`mise run check` と post-create に含まれる）がズレを検出する。

---

## 3. WSL2 + Linux の権限

devcontainer でいちばん壊れやすいところなので、対策を明示しておく。

### 3-1. uid/gid をホストに合わせる

`debian:trixie` には uid 1000 のユーザーが居ない。ホスト（WSL）の uid/gid で
コンテナ内ユーザーを作らないと、コンテナが作ったファイルをホストから編集・削除できなくなる。

- `init-host.sh` が `id -u` / `id -g` を `.devcontainer/.env` に書く（root で実行された場合は書かない）
- `compose.yaml` がそれを build args として渡す
- Dockerfile が既存 uid/gid との衝突も考慮してユーザーを作る。uid 0 は拒否する

`updateRemoteUserUID` には頼らない（`false`）。docker compose だけで起動した人には効かないため。

### 3-2. 名前付きボリュームの所有権

Docker は空のボリュームを初期化するとき、イメージ側のディレクトリの所有権をコピーする。
イメージにそのパスが無いと `root:root` で作られ、以後 `EACCES` になる。

1. Dockerfile で `install -d -o vscode` してマウント先を先に作る（`compose.yaml` の `volumes:` と 1 対 1）
2. 起動のたびに `devcontainer-init`（root）が、所有者の違うファイルだけを直す

2 は root がユーザーの書けるディレクトリを触る処理なので、マウントポイント以外は触らない・
シンボリックリンクを辿らない・ハードリンク数 2 以上のファイルは触らない、としてある。

### 3-3. バインドマウントとキャッシュの置き方

リポジトリは **WSL のネイティブ FS（`/home/...`）** に置く。`/mnt/c` 配下は 9p 経由で桁違いに遅く、
パーミッションも正しく扱えない（`init-host.sh` が警告する）。

- `node_modules` はワークスペースに置く（エディタの解決がそのまま効く）
- pnpm の store は `node_modules/.pnpm-store` に入る。ホームの store はバインドマウントと
  別ファイルシステムでハードリンクを張れないため、pnpm が自動でワークスペース側に作る
- 名前付きボリュームに逃がすのは Claude Code の設定・シェル履歴・VS Code Server だけ

### 3-4. `docker compose exec` は root にならない

イメージの `USER` が `vscode` なので `docker compose exec dev ...` も `vscode` で動く。
`-u root` を付けて作業すると root 所有のファイルがワークスペースにでき、ホストから消せなくなる。

### 3-5. ログインシェルの PATH

Debian の `/etc/profile` は PATH を**無条件に代入**する。VS Code の統合ターミナル（`zsh -l`）や
`bash -lc` では Dockerfile の `ENV PATH` が消えるので、`/etc/profile.d/10-mise-path.sh` で mise のシムを前置し直している。

### 3-6. sudo

既定では `vscode` は何でも sudo できる（快適さ優先）。外部通信遮断を有効にしたときだけ、
起動時に無制限の sudo が取り上げられる（[egress-firewall.md](egress-firewall.md)）。
root が必要な初期化はすべて起動時に済むので、`post-create.sh` は sudo を使わない。

### 3-7. 付けていない権限

`SYS_PTRACE` / `seccomp:unconfined` は付けていない（Node の inspector には不要）。
付けているのは外部通信遮断用の `NET_ADMIN` / `NET_RAW` だけで、どちらもコンテナ自身の
ネットワーク名前空間にしか効かない。

---

## 4. Claude Code

- CLI は mise でプロジェクトの定義として固定（`aqua:anthropics/claude-code`、公式ネイティブバイナリ）
- `DISABLE_AUTOUPDATER=1`。自己更新すると `mise.lock` の固定が意味を失うため
- 認証情報と設定は名前付きボリューム `claude` に永続化される
  - `~/.claude` にボリュームを当てるだけでは**足りない**。認証情報やプロジェクトごとの信頼設定は
    既定で `~/.claude.json`（ディレクトリの外）に書かれるため、`CLAUDE_CONFIG_DIR` で `~/.claude` 配下へ寄せている
- `ANTHROPIC_API_KEY` などの秘密情報を `.devcontainer/.env` に書かないこと（ワークスペースは Claude Code から読める）
- 長時間のループは `tmux` の中で回すと、ターミナルを閉じても止まらない
- Claude Code 組み込みのサンドボックス（bubblewrap）は、Docker 既定の seccomp では
  ユーザー名前空間を作れず動かない（実測）。このコンテナでは入れておらず、隔離はコンテナ自体と外部通信遮断が受け持つ

## 5. VS Code 拡張機能

`devcontainer.json` に寄せてある。TypeScript の言語機能は VS Code 組み込み。

| 拡張 | 用途 |
|---|---|
| `anthropic.claude-code` | CLI（コンテナ側）とセットで入れる |
| `biomejs.biome` | lint + format。`mise run lint:ts` と同じ `biome.json` を読む |
| `yoavbls.pretty-ts-errors` | 型エラーを読みやすく表示する |
| `hverlin.mise-vscode` | `mise.toml` の補完とタスク実行（`.vscode/settings.json` は書き換えさせない） |
| `tamasfe.even-better-toml` / `redhat.vscode-yaml` | `mise.toml` / `compose.yaml` |
| `timonwong.shellcheck` | `.devcontainer/*.sh`。mise で固定した shellcheck を使う |
| `EditorConfig.EditorConfig` / `usernamehw.errorlens` | |

- `typescript.tsdk` はワークスペースの TypeScript（`node_modules/typescript/lib`）を指す。
  エディタと `tsc` の版を揃えるため。初回はステータスバーで「ワークスペースのバージョンを使用」を選ぶ
- TypeScript は 6 系を使っている。7 系（ネイティブ版）は `lib/tsserver.js` を同梱しておらず、この設定と組めないため
- Biome は整形結果が版で変わるので `package.json` で完全一致に固定している

## 6. スクリプトを TypeScript で書く

`scripts/*.ts` は Node 24 の型ストリップで**ビルドせずに**実行する（`node scripts/doctor.ts`）。

- `tsconfig.json` の `erasableSyntaxOnly` で、消すだけでは JS にならない構文（`enum` / `namespace` / 引数プロパティ）を禁止
- import には `.ts` 拡張子をそのまま書く（`allowImportingTsExtensions`）
- 型だけの import は `import type`（`verbatimModuleSyntax`）

ただし `.devcontainer/` のスクリプトは bash のまま。ホスト（Node が無い）や、
root で動きユーザーが書き換えられる `/opt/mise` を使ってはいけない処理だから。

---

## 7. トラブルシュート

| 症状 | 原因と対処 |
|---|---|
| コンテナがすぐ止まる | `docker compose logs dev`。`[devcontainer] 初期化に失敗` なら外部通信遮断の適用失敗か `EGRESS_FIREWALL` の値の誤り |
| `mise ERROR No version is set for shim: node` | ワークスペースの外で実行している。`cd /workspaces/ai-driven-workflow-sample` |
| `Config file ... is not trusted` | `MISE_TRUSTED_CONFIG_PATHS=/workspaces` が効いていない。コンテナを作り直す |
| ビルドで `mise install --locked` が失敗 | `mise.lock` にそのプラットフォームの URL が無い。`mise lock --platform linux-x64,linux-arm64,macos-x64,macos-arm64` |
| ログインシェルでツールが見つからない | `/etc/profile.d/10-mise-path.sh` の有無を確認 |
| `EACCES` でボリュームに書けない | コンテナを再起動（起動時に所有権を直す）。直らなければ `docker compose down -v` |
| ホストから消せないファイルができた | uid/gid 不一致。`bash .devcontainer/init-host.sh` → Rebuild |
| `pins:check` が drift | `mise run pins:sync` → `pnpm install` |
| `sudo: a password is required` | 外部通信遮断が有効（仕様）。`egress-firewall status` で確認 |
| VS Code と CLI で別のコンテナが立つ | `compose.yaml` の `name:` と `.env` の `COMPOSE_PROJECT_NAME` を確認 |
| `\r: command not found` | CRLF 混入。`git config --global core.autocrlf false` で clone し直す |
