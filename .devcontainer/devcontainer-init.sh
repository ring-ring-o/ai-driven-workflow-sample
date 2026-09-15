#!/usr/bin/env bash
# =============================================================================
# コンテナ起動時に root で 1 回だけ動く初期化（/usr/local/sbin/devcontainer-init）。
# entrypoint から `sudo -n` で呼ばれる。やることは 2 つ:
#
#   1. 名前付きボリュームの所有権を開発ユーザーに揃える
#   2. EGRESS_FIREWALL=on なら外部通信遮断を適用する（同時に sudo を取り上げる）
#
# 設定値（EGRESS_FIREWALL など）はコンテナの環境変数を sudo の env_keep で受け取る
# （Dockerfile の /etc/sudoers.d/10-devcontainer）。起動時の実行はユーザーの
# プロセスより先に走るので、ここで読む値はコンテナ作成時のものになる。
# あとからユーザーが値を変えて呼び直しても、遮断を緩める方向には働かない
# （適用済みなら apply は拒否し、解除する経路はそもそも無い）。
# =============================================================================
set -euo pipefail
# root で動くので、ユーザーが書き換えられる場所（/opt/mise など）を PATH に入れない。
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
umask 022

log() { printf '[devcontainer-init] %s\n' "$*" >&2; }

if [ "$(id -u)" -ne 0 ]; then
  log "root で実行すること（entrypoint から sudo で呼ばれる）"
  exit 1
fi

# -----------------------------------------------------------------------------
# 1. 名前付きボリュームの所有権
# -----------------------------------------------------------------------------
# Docker は空のボリュームを初期化するときイメージ側の所有権を引き継ぐが、
# 一度でも中身が入ったボリュームは所有権が固定され、あとから uid を変えたり
# 誰かが root でファイルを作ったりすると直らない。それを起動のたびに直す。
#
# root がユーザーの書けるディレクトリを触るので、次の点に注意して書いてある。
#   - マウントポイント（＝別ファイルシステム）でなければ触らない
#       → /etc などへのハードリンクを仕込まれても -xdev で辿らない
#   - chown -h / find -P でシンボリックリンクを辿らない
#   - ハードリンク数が 2 以上の通常ファイルは触らない
# 失敗しても起動は止めない（使い勝手の問題で、安全性の問題ではないため）。
fix_volume_ownership() {
  local user uid gid dir
  # SUDO_USER は sudo 自身が設定する（呼び出し元が偽装できない）
  user="${SUDO_USER:-${DEV_USER:-}}"
  if [ -z "${user}" ] || [ "${user}" = root ] || ! uid="$(id -u "${user}" 2>/dev/null)"; then
    log "WARN: 開発ユーザー ('${user}') を特定できないため所有権の修復を省略"
    return 0
  fi
  gid="$(id -g "${user}")"

  for dir in "/home/${user}/.claude" \
             "/home/${user}/.commandhistory" \
             "/home/${user}/.vscode-server"; do
    [ -d "${dir}" ] && [ ! -L "${dir}" ] || continue
    mountpoint -q "${dir}" || continue
    find -P "${dir}" -xdev \
      \( ! -user "${uid}" -o ! -group "${gid}" \) \
      ! \( -type f -links +1 \) \
      -exec chown -h "${uid}:${gid}" {} + \
      || log "WARN: ${dir} の所有権を直しきれなかった"
  done
}

fix_volume_ownership

# -----------------------------------------------------------------------------
# 2. 外部通信遮断（既定: off）
# -----------------------------------------------------------------------------
# 遮断中にもう一度呼ばれた（ユーザーが sudo devcontainer-init した等）なら何もしない。
if ipset list -n egress-allow >/dev/null 2>&1; then
  log "外部通信遮断は適用済み"
  exit 0
fi
# iptables のルールはネットワーク名前空間ごと再起動で消えるが、ファイルは残る。
# 前回起動時の状態ファイルが「遮断中」と誤表示しないよう、消してから始める。
rm -rf /run/egress-firewall

mode="$(printf '%s' "${EGRESS_FIREWALL:-}" | tr '[:upper:]' '[:lower:]')"
case "${mode}" in
  on | true | yes | 1)
    log "EGRESS_FIREWALL=${mode}: 外部通信遮断を適用する"
    egress-firewall apply
    ;;
  "" | off | false | no | 0)
    : # 既定。何もしない
    ;;
  *)
    log "EGRESS_FIREWALL の値が不正: '${mode}'（on / off のどちらか）"
    exit 1
    ;;
esac
