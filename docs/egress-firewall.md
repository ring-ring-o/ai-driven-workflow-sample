# 外部通信遮断（egress firewall）— 使い方と Tips

コンテナから外への通信を、許可リストに書いたドメインだけに絞る機能。**既定ではオフ**。

`--dangerously-skip-permissions` などで Claude Code を無人のループで回すとき、
プロンプトインジェクションや操作ミスが起きても「どこへでも送れる・どこからでも落とせる」状態にしないための保険。
方式は Anthropic 公式 devcontainer の `init-firewall.sh` と同じ（ipset + iptables）。

---

## 1. 有効化・無効化

### 有効にする

`.devcontainer/.env`:

```bash
EGRESS_FIREWALL=on
```

そのうえでコンテナを**作り直す**。

- VS Code: `Dev Containers: Rebuild Container`
- compose: `cd .devcontainer && docker compose up -d`（環境変数が変わるので自動で作り直される）

起動時に遮断が適用され、プロンプト右側に `[egress: locked]` が出る。

### 無効に戻す

`EGRESS_FIREWALL=off` にして、もう一度作り直す。**コンテナの中から解除する方法は無い（意図的）**。

### 作り直さずに試す

```bash
sudo egress-firewall apply
```

その場で遮断される。ただし同時に無制限の sudo も取り上げられ、**コンテナを作り直すまで元に戻らない**。

---

## 2. 何が起きるか

| 対象 | 挙動 |
|---|---|
| 許可リストのドメイン | 起動時に A レコードを引き、その IPv4 アドレスへの送信だけ許可 |
| `@github-meta` | `api.github.com/meta` が公開する web / api / git の IP 範囲を許可 |
| DNS | `/etc/resolv.conf` のネームサーバー宛てだけ許可（`dig @8.8.8.8` などは遮断） |
| それ以外への送信 | 即座に拒否（TCP は RST、他は ICMP admin-prohibited。タイムアウト待ちにならない） |
| 外からの接続 | 既存接続の応答と localhost 以外は破棄 |
| IPv6 | 全面遮断（許可リストは IPv4 のみ） |
| sudo | `devcontainer-init` と `egress-firewall` 以外は使えなくなる |

sudo を取り上げるのが要点。残しておくと `sudo iptables -F` の一行で外せてしまい、遮断の意味が無い。
残る 2 つのコマンドは遮断を緩められないように作ってある（適用済みなら `apply` は拒否、`refresh` は既存ドメインの IP を足すだけ）。

適用に失敗したら**コンテナの起動を中止する**（fail closed）。遮断したつもりで遮断されていない状態で動き続けないため。

---

## 3. 状態を確認する

```bash
egress-firewall status       # sudo 不要（mise run firewall:status も同じ）
```

```
設定  EGRESS_FIREWALL=on
状態  遮断中（2026-09-15T08:57:02+09:00 に適用）
許可  api.anthropic.com claude.ai claude.com ... registry.npmjs.org ...
      + GitHub の IP 範囲（@github-meta）
sudo  制限あり（devcontainer-init / egress-firewall のみ）
疎通
  https://example.com          到達できない
  https://api.anthropic.com    到達できる
```

適用時のログはホスト側から見る:

```bash
cd .devcontainer && docker compose logs dev
```

---

## 4. 許可先を変える

| やりたいこと | 方法 | 反映 |
|---|---|---|
| とりあえず 1 つ足す | `.devcontainer/.env` の `EGRESS_ALLOW_DOMAINS=pypi.org,files.pythonhosted.org` | コンテナの作り直し |
| 恒久的に足す / 削る | `.devcontainer/firewall/allowlist.txt` を編集してコミット | イメージの再ビルド |
| GitHub への経路を塞ぐ | `allowlist.txt` の `@github-meta` 以下を消す | イメージの再ビルド |
| ホストで動くサービスに繋ぐ | `EGRESS_ALLOW_DOMAINS=host.docker.internal` | コンテナの作り直し |

- ワイルドカード（`*.example.com`）は書けない。サブドメインは 1 つずつ列挙する
- `example.com` は遮断の検証に使うので許可しないこと（起動に失敗する）
- 必要なドメインが分からないときは、遮断を**オフ**にした状態で `curl -v` や対象ツールの詳細ログを見て洗い出してから足す

既定の許可リスト（[allowlist.txt](../.devcontainer/firewall/allowlist.txt)）:

| 用途 | ドメイン |
|---|---|
| Claude Code | `api.anthropic.com` `claude.ai` `claude.com` `platform.claude.com` `downloads.claude.ai` `mcp-proxy.anthropic.com` |
| パッケージ | `registry.npmjs.org` |
| GitHub | `@github-meta` `raw.githubusercontent.com` `objects.githubusercontent.com` `codeload.github.com` |
| VS Code | `marketplace.visualstudio.com` `vscode.blob.core.windows.net` `update.code.visualstudio.com` |

Claude Code の分は [公式のネットワーク要件](https://code.claude.com/docs/en/network-config) に合わせてある。
テレメトリとエラー報告の宛先はコメントアウトしてある（許可しなくても本体は動く）。

---

## 5. Tips

### CDN の IP が変わって急に繋がらなくなったら

許可は起動時に引いた IP で行う。`registry.npmjs.org` などは CDN 配下で IP が入れ替わるので、
長時間回したループの途中で「許可したはずのドメインに繋がらない」が起きうる。

```bash
mise run firewall:refresh     # = sudo egress-firewall refresh（遮断中でも使える）
```

許可済みドメインの IP を引き直して**足す**だけなので、何度実行しても安全。
ループのスクリプトから定期的に呼んでもよい。

### 拡張機能は遮断をオフにした状態で先に入れておく

VS Code の拡張機能は複数の CDN から取得されるため、遮断中は初回インストールに失敗することがある。
拡張機能は名前付きボリューム（`~/.vscode-server`）に残るので、最初の 1 回だけ遮断をオフで作ってから
オンに切り替えると確実。

### GitHub の API レート制限

`@github-meta` は起動のたびに `api.github.com/meta` を未認証で叩く（1 時間あたり 60 回まで）。
コンテナの再起動を短時間に繰り返すと取得に失敗して起動が止まる。しばらく待つか、`@github-meta` を外す。

### Claude Code の設定と重ねる

遮断はネットワークの外枠でしかない。Claude Code 側でも絞っておくと多層になる。
例（`.claude/settings.json`）:

```json
{
  "permissions": {
    "deny": ["WebFetch", "Bash(curl:*)", "Bash(wget:*)"]
  },
  "env": {
    "DISABLE_TELEMETRY": "1",
    "DISABLE_ERROR_REPORTING": "1"
  }
}
```

- テレメトリの宛先は許可リストに入れていないので、送信を止めておくとログが静かになる
- Claude Code 組み込みのサンドボックス（bubblewrap）はこのコンテナ内では動かない（Docker 既定の seccomp で
  ユーザー名前空間を作れない）。隔離はコンテナ自体とこの遮断が受け持つ

### 無人ループを回すとき

- 遮断を**オン**にしてから `claude --dangerously-skip-permissions` を使う。オフのまま使わない
- 長時間のループは `tmux` の中で回す
- 使い終わった検証用コンテナは `docker compose down` で捨てる。より厳密に分けたいなら
  `.env` の `COMPOSE_PROJECT_NAME` を変えて、ボリューム（Claude Code の設定・履歴）ごと別にする

---

## 6. 限界 — これは何を守らないか

この遮断は「うっかり」と「素朴な持ち出し」を防ぐためのもので、完全な隔離ではない。

| 残るリスク | 説明 | 緩和 |
|---|---|---|
| コンテナ内のものはすべて読める | ワークスペース、Claude Code の認証情報（`~/.claude`）、VS Code が転送する git の認証情報や SSH エージェント | 信頼できないリポジトリでは使わない。権限を絞ったトークンを使う |
| 許可先を経由した持ち出し | GitHub を許可していれば、手元の認証情報で push や gist 作成ができる | 不要なら `@github-meta` を外す |
| IP 単位の許可 | CDN の IP は多数のサイトで共有されているため、同じ IP に載っている別サイトにも届きうる | 許可リストを最小にする |
| DNS 経由の持ち出し | Docker の DNS（`127.0.0.11`）への問い合わせは許可しているので、DNS トンネリングは防げない | — |
| 設定ファイルはワークスペース内 | `.env` / `allowlist.txt` / Dockerfile はコンテナ内から書き換えられ、**次の作り直し**で効く | Rebuild の前に `git diff .devcontainer` を確認する |
| 以前のボリュームの中身 | 遮断オフの時期に `~/.claude` へ書かれたもの（フック設定など）はそのまま使われる | 厳密にはボリュームを分ける（上記） |

公開ポート（compose の `ports:`）への外からの接続も遮断される。必要になったら `egress-firewall.sh` に INPUT ルールを足す。

---

## 7. トラブルシュート

| 症状 | 原因と対処 |
|---|---|
| コンテナが起動直後に止まる | `docker compose logs dev` を見る。`NET_ADMIN` が無い（compose 以外で起動した）、`api.github.com/meta` の取得失敗（レート制限）、`api.anthropic.com` に届かない、など |
| 許可したドメインに繋がらない | `egress-firewall status` で許可に入っているか確認 → `mise run firewall:refresh` → それでも駄目なら別ドメインへリダイレクトされていないか `curl -v` で確認 |
| `sudo: a password is required` | 遮断中は仕様。パッケージを足したいなら Dockerfile に書いてイメージを作り直す |
| `許可リストの書式が不正` で起動しない | `EGRESS_ALLOW_DOMAINS` にワイルドカードや URL（`https://...`）を書いていないか |
| `pnpm install` が新しいパッケージで失敗 | `registry.npmjs.org` 以外からバイナリを取りに行くパッケージ。取得先を許可リストに足す |
| 遮断をやめたのにプロンプトに `[egress: locked]` が出る | コンテナを作り直していない（`restart` ではなく作り直しが必要） |
