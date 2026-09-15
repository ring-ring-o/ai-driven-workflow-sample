#!/usr/bin/env bash
# =============================================================================
# ホスト（WSL）側で動く唯一のフック。devcontainer.json の initializeCommand から
# 呼ばれる。VS Code を使わない人は、初回に手で 1 度実行すればよい。
#
#   bash .devcontainer/init-host.sh
#
# やること:
#   1. ホストユーザーの uid/gid を .devcontainer/.env に書き出す
#      コンテナ内のユーザーを同じ uid/gid で作ることが、バインドマウントで
#      「root 所有のファイルができてホストから消せない」を防ぐ唯一の確実な方法。
#   2. WSL で踏みやすい置き場所の問題を警告する
#
# 失敗してもコンテナ起動を止めないようにしてある（.env.example の既定値で動く）。
# =============================================================================
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "${here}/.." && pwd)"
env_file="${here}/.env"
example="${here}/.env.example"

warn() { printf '\033[1;33m==> WARN:\033[0m %s\n' "$*" >&2; }

# --- 置き場所の確認 -----------------------------------------------------------
# /mnt/c などの Windows ドライブは 9p 経由でマウントされ、パーミッションが
# すべて同じに見える（chmod が効かない）うえに I/O が桁違いに遅い。
case "${repo}" in
  /mnt/[a-zA-Z]/*)
    warn "リポジトリが Windows ドライブ上にある (${repo})。"
    warn "WSL のホーム（例: ~/src）に clone し直すこと。権限と速度の問題が必ず出る。"
    ;;
esac

# CRLF で checkout されているとコンテナ内のシェルスクリプトが動かない。
if grep -q $'\r' "${here}/entrypoint.sh" 2>/dev/null; then
  warn "改行コードが CRLF になっている。git config --global core.autocrlf false で clone し直すこと。"
fi

# --- uid / gid ----------------------------------------------------------------
[ -f "${env_file}" ] || cp "${example}" "${env_file}" 2>/dev/null || exit 0

uid="$(id -u 2>/dev/null || echo 1000)"
gid="$(id -g 2>/dev/null || echo 1000)"

# root で開いている場合は書き換えない（コンテナ内ユーザーを uid 0 で作れないため）。
# WSL の既定ユーザーを一般ユーザーにしてから開き直すこと。
if [ "${uid}" = "0" ] || [ "${gid}" = "0" ]; then
  warn "ホストで root として実行されている。.env の USER_UID/USER_GID は変更しない。"
  exit 0
fi

# 既に一致していれば何もしない（.env が書き換わるとイメージが再ビルドされるため）
if grep -q "^USER_UID=${uid}$" "${env_file}" && grep -q "^USER_GID=${gid}$" "${env_file}"; then
  exit 0
fi

tmp="$(mktemp)" || exit 0
sed -e "s/^USER_UID=.*/USER_UID=${uid}/" -e "s/^USER_GID=.*/USER_GID=${gid}/" \
  "${env_file}" >"${tmp}" && mv "${tmp}" "${env_file}"

echo "==> .devcontainer/.env をホストに合わせた (USER_UID=${uid} USER_GID=${gid})" >&2
