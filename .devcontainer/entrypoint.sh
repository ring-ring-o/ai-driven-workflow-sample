#!/bin/sh
# =============================================================================
# イメージの ENTRYPOINT（/usr/local/bin/devcontainer-entrypoint）。
# コンテナ内ユーザーとして動き、root が必要な初期化だけを sudo で呼ぶ。
#
# VS Code（overrideCommand: false）/ docker compose / docker run のどれで起動しても
# ここを通るので、起動経路によって初期化の有無が分岐しない。
#
# 初期化に失敗したら起動を止める（fail closed）。外部通信遮断を有効にしたのに
# 適用できなかったとき、遮断されていない状態で黙って動き続けるのを防ぐため。
# 原因は `docker compose logs dev` で見られる。
# =============================================================================
set -eu

if ! sudo -n /usr/local/sbin/devcontainer-init; then
  echo "[devcontainer] 初期化に失敗したため起動を中止します（上のログを参照）" >&2
  exit 1
fi

exec "$@"
