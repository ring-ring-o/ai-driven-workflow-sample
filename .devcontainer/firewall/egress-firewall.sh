#!/usr/bin/env bash
# =============================================================================
# 外部通信遮断（/usr/local/bin/egress-firewall）。既定では使われない。
#
#   egress-firewall status          状態と疎通の確認（sudo 不要）
#   sudo egress-firewall apply      許可リスト以外への通信を遮断し、sudo を取り上げる
#   sudo egress-firewall refresh    許可済みドメインの IP を引き直して追加する
#
# 通常は EGRESS_FIREWALL=on でコンテナを作れば、起動時に devcontainer-init が apply する。
#
# 解除コマンドは「意図的に」無い。遮断したコンテナの内側（= Claude Code が
# 動いている側）から外せないことが、この機能の価値だから。
# 解除はホスト側で EGRESS_FIREWALL=off にしてコンテナを作り直す。
#
# 方式は Anthropic 公式 devcontainer の init-firewall.sh と同じ
# （ipset に許可先の IP を入れ、iptables の既定ポリシーを DROP にする）。違い:
#   - filter テーブルだけを触る（Docker の埋め込み DNS の NAT ルールを壊さない）
#   - DNS は resolv.conf のネームサーバー宛てだけ許可する
#   - 許可先はファイル（allowlist.txt）で管理し、GitHub の IP 範囲は @github-meta 行で指定
#   - ホストのネットワーク（/24）を丸ごとは許可しない
#   - IPv6 は全面 DROP（許可リストは IPv4 のみ）
#   - 適用と同時に無制限の sudo を削除する（sudo iptables -F で外されないように）
#   - refresh で CDN の IP 変動に追従できる（既に許可したドメインの IP を足すだけ）
#
# 環境変数 EGRESS_ALLOW_DOMAINS は sudo の env_keep で受け取る。呼び出し元が値を
# 変えられるが、apply は適用済みなら拒否し、refresh は許可リストを読み直さないので、
# 遮断中のコンテナの内側から許可先を増やすことはできない。
# =============================================================================
set -euo pipefail
IFS=$'\n\t'
# root で動くので、ユーザーが書き換えられる場所（/opt/mise など）を PATH に入れない。
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

readonly IPSET_NAME=egress-allow
readonly ALLOWLIST=/etc/egress-firewall/allowlist.txt
readonly STATE_DIR=/run/egress-firewall
readonly SUDOERS_ALL=/etc/sudoers.d/90-dev-user-all
# 検証に使う宛先。PROBE_BLOCKED を許可リストに入れると apply が失敗する。
readonly PROBE_BLOCKED=https://example.com
readonly PROBE_ALLOWED=https://api.anthropic.com

log() { printf '[egress-firewall] %s\n' "$*" >&2; }
die() {
  log "ERROR: $*"
  exit 1
}

usage() {
  cat >&2 <<'EOS'
usage: egress-firewall <command>

  status         状態と疎通の確認（sudo 不要）
  apply          許可リスト以外への通信を遮断し、sudo を取り上げる（要 sudo・元に戻せない）
  refresh        許可済みドメインの IP を引き直して追加する（要 sudo・遮断中のみ）

解除はホスト側で .devcontainer/.env を EGRESS_FIREWALL=off にしてコンテナを作り直す。
詳細: docs/egress-firewall.md
EOS
}

need_root() {
  [ "$(id -u)" -eq 0 ] || die "root 権限が必要: sudo egress-firewall $1"
}

is_applied() {
  ipset list -n "${IPSET_NAME}" >/dev/null 2>&1
}

valid_domain() {
  [[ "$1" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]([a-z0-9-]{0,61}[a-z0-9])?$ ]]
}

# 許可リスト（ファイル + EGRESS_ALLOW_DOMAINS）を 1 行 1 エントリで出す
allowlist_entries() {
  {
    sed -e 's/#.*$//' "${ALLOWLIST}"
    printf '%s\n' "${EGRESS_ALLOW_DOMAINS:-}" | tr ',' '\n'
  } | tr -d ' \t\r' | tr '[:upper:]' '[:lower:]' | sed '/^$/d' | sort -u
}

resolve_ipv4() {
  dig +short +time=3 +tries=2 A "$1" 2>/dev/null |
    sed -n -E '/^[0-9]{1,3}(\.[0-9]{1,3}){3}$/p'
}

# GitHub が公開している web / api / git の IPv4 範囲（集約済み）
github_meta_ranges() {
  local meta
  meta="$(curl -q -fsS --max-time 15 https://api.github.com/meta)" || return 1
  jq -e '.web and .api and .git' >/dev/null <<<"${meta}" || return 1
  jq -r '(.web + .api + .git)[]' <<<"${meta}" |
    sed -n -E '/^[0-9]{1,3}(\.[0-9]{1,3}){3}\/[0-9]{1,2}$/p' |
    aggregate -q
}

nameservers() {
  awk '$1 == "nameserver" { print $2 }' /etc/resolv.conf |
    sed -n -E '/^[0-9]{1,3}(\.[0-9]{1,3}){3}$/p'
}

probe() {
  curl -q -sS -o /dev/null --connect-timeout 5 --max-time 10 "$1" 2>/dev/null
}

# -----------------------------------------------------------------------------
# apply
# -----------------------------------------------------------------------------
cmd_apply() {
  need_root apply
  if is_applied; then
    die "既に適用済み。許可先を変えるにはホスト側で設定を直し、コンテナを作り直すこと"
  fi
  iptables -S >/dev/null 2>&1 ||
    die "iptables を操作できない。NET_ADMIN ケーパビリティが付いているか確認（compose.yaml の cap_add）"
  [ -r "${ALLOWLIST}" ] || die "許可リストが読めない: ${ALLOWLIST}"

  # --- 1. 許可先の IP を集める（まだ遮断していないので通信できる）------------
  # 途中で失敗したときに半端な ipset を残さないよう、別名で作ってから差し替える。
  local building="${IPSET_NAME}-new"
  ipset destroy "${building}" 2>/dev/null || true
  ipset create "${building}" hash:net family inet
  trap 'ipset destroy '"${building}"' 2>/dev/null || true' EXIT

  local entry item n github=no
  local -a domains=()
  log "許可先を解決する"
  while read -r entry; do
    n=0
    case "${entry}" in
      @github-meta)
        local ranges
        ranges="$(github_meta_ranges)" || die "GitHub の IP 範囲（api.github.com/meta）を取得できない"
        for item in ${ranges}; do
          ipset add -exist "${building}" "${item}"
          n=$((n + 1))
        done
        github=yes
        log "  @github-meta: ${n} 範囲"
        ;;
      *)
        valid_domain "${entry}" ||
          die "許可リストの書式が不正: '${entry}'（ワイルドカードや URL は書けない）"
        for item in $(resolve_ipv4 "${entry}"); do
          ipset add -exist "${building}" "${item}"
          n=$((n + 1))
        done
        domains+=("${entry}")
        if [ "${n}" -eq 0 ]; then
          # 許可が減る方向なので止めずに進める（refresh であとから足せる）
          log "  WARN: ${entry} を名前解決できない（このドメインには届かない）"
        else
          log "  ${entry}: ${n} 件"
        fi
        ;;
    esac
  done < <(allowlist_entries)

  # --- 2. ルールを組む（IPv4）-------------------------------------------------
  log "ルールを適用する"
  iptables -P INPUT ACCEPT
  iptables -P FORWARD ACCEPT
  iptables -P OUTPUT ACCEPT
  iptables -F
  iptables -X
  ipset rename "${building}" "${IPSET_NAME}"
  trap - EXIT

  iptables -A INPUT -i lo -j ACCEPT
  iptables -A OUTPUT -o lo -j ACCEPT
  iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  # DNS は resolv.conf のネームサーバー宛てだけ。compose のネットワークでは
  # 127.0.0.11（Docker の埋め込み DNS）なので lo の許可で足りるが、既定ブリッジ等の
  # ためにここでも明示する。
  for item in $(nameservers); do
    iptables -A OUTPUT -d "${item}" -p udp --dport 53 -j ACCEPT
    iptables -A OUTPUT -d "${item}" -p tcp --dport 53 -j ACCEPT
  done
  iptables -A OUTPUT -m set --match-set "${IPSET_NAME}" dst -j ACCEPT
  # 黙って捨てるとタイムアウトまで待たされるので、即座に拒否を返す
  iptables -A OUTPUT -p tcp -j REJECT --reject-with tcp-reset
  iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited
  iptables -P INPUT DROP
  iptables -P FORWARD DROP
  iptables -P OUTPUT DROP

  # --- 3. IPv6 は全面遮断 -----------------------------------------------------
  if ip6tables -S >/dev/null 2>&1; then
    ip6tables -P INPUT ACCEPT
    ip6tables -P FORWARD ACCEPT
    ip6tables -P OUTPUT ACCEPT
    ip6tables -F
    ip6tables -X
    ip6tables -A INPUT -i lo -j ACCEPT
    ip6tables -A OUTPUT -o lo -j ACCEPT
    ip6tables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    ip6tables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    ip6tables -A OUTPUT -p tcp -j REJECT --reject-with tcp-reset
    ip6tables -A OUTPUT -j REJECT --reject-with icmp6-adm-prohibited
    ip6tables -P INPUT DROP
    ip6tables -P FORWARD DROP
    ip6tables -P OUTPUT DROP
  elif ip -6 addr show scope global 2>/dev/null | grep -q inet6; then
    die "IPv6 のグローバルアドレスがあるのに ip6tables を操作できない"
  fi

  # --- 4. sudo を取り上げる ---------------------------------------------------
  # 残すのは devcontainer-init と egress-firewall（どちらも遮断を緩められない）だけ。
  rm -f "${SUDOERS_ALL}"
  log "無制限の sudo を削除した（コンテナを作り直すまで戻らない）"

  # --- 5. 状態を記録（status / refresh が読む。root 所有・ユーザーは書けない）-----
  install -d -m 0755 "${STATE_DIR}"
  printf '%s\n' "${domains[@]}" >"${STATE_DIR}/domains"
  printf '%s\n' "${github}" >"${STATE_DIR}/github-meta"
  date -Iseconds >"${STATE_DIR}/applied-at"

  # --- 6. 検証 ----------------------------------------------------------------
  if probe "${PROBE_BLOCKED}"; then
    die "検証失敗: ${PROBE_BLOCKED} に到達できてしまう"
  fi
  log "検証: ${PROBE_BLOCKED} は遮断されている"
  if grep -qx 'api.anthropic.com' "${STATE_DIR}/domains"; then
    probe "${PROBE_ALLOWED}" || die "検証失敗: ${PROBE_ALLOWED} に到達できない"
    log "検証: ${PROBE_ALLOWED} に到達できる"
  fi
  log "外部通信遮断を適用した"
}

# -----------------------------------------------------------------------------
# refresh
# -----------------------------------------------------------------------------
# 許可済みのドメインだけを引き直す。許可リスト自体は読み直さないので、
# 呼べるのが誰であっても「許可先が増える」ことはない。
cmd_refresh() {
  need_root refresh
  is_applied || die "外部通信遮断は適用されていない"
  [ -r "${STATE_DIR}/domains" ] || die "状態ファイルが無い: ${STATE_DIR}/domains"

  local domain ip added=0
  while read -r domain; do
    valid_domain "${domain}" || continue
    for ip in $(resolve_ipv4 "${domain}"); do
      if ! ipset test "${IPSET_NAME}" "${ip}" 2>/dev/null; then
        ipset add -exist "${IPSET_NAME}" "${ip}"
        added=$((added + 1))
        log "  + ${ip} (${domain})"
      fi
    done
  done <"${STATE_DIR}/domains"
  log "追加した IP: ${added} 件"
}

# -----------------------------------------------------------------------------
# status
# -----------------------------------------------------------------------------
cmd_status() {
  printf '設定  EGRESS_FIREWALL=%s\n' "${EGRESS_FIREWALL:-off}"

  if [ -r "${STATE_DIR}/applied-at" ]; then
    printf '状態  遮断中（%s に適用）\n' "$(cat "${STATE_DIR}/applied-at")"
    printf '許可  %s\n' "$(paste -sd ' ' "${STATE_DIR}/domains")"
    if [ "$(cat "${STATE_DIR}/github-meta" 2>/dev/null)" = yes ]; then
      printf '      + GitHub の IP 範囲（@github-meta）\n'
    fi
  else
    printf '状態  遮断していない\n'
  fi

  if sudo -n -l 2>/dev/null | grep -q 'NOPASSWD: ALL'; then
    printf 'sudo  無制限\n'
  else
    printf 'sudo  制限あり（devcontainer-init / egress-firewall のみ）\n'
  fi

  printf '疎通\n'
  local url
  for url in "${PROBE_BLOCKED}" "${PROBE_ALLOWED}"; do
    if probe "${url}"; then
      printf '  %-28s 到達できる\n' "${url}"
    else
      printf '  %-28s 到達できない\n' "${url}"
    fi
  done

  if [ "$(id -u)" -eq 0 ] && is_applied; then
    printf '\nipset %s: %s 件\n' "${IPSET_NAME}" \
      "$(ipset list "${IPSET_NAME}" | sed -n 's/^Number of entries: //p')"
    iptables -S
  fi
}

case "${1:-status}" in
  apply) cmd_apply ;;
  refresh) cmd_refresh ;;
  status) cmd_status ;;
  -h | --help | help) usage ;;
  *)
    usage
    exit 2
    ;;
esac
