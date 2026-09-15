# syntax=docker/dockerfile:1
# =============================================================================
# 3 段ビルド。
#   stage mise-bin    : mise 本体だけを取ってくる
#   stage toolchains  : mise.toml / mise.lock を読んでツールチェーンを入れる
#   stage dev         : 実行に必要なものだけ。上の 2 段から成果物を COPY する
#
# ★ この Dockerfile にはツールのバージョン番号を書かない。
#   すべて mise.toml（と mise.lock）が決める。ビルドコンテキストはリポジトリルート。
#
# VS Code を使わなくても同じものが立つ（compose.yaml 参照）。compose すら無い
# ランタイムでは docs/devcontainer.md の「docker run / podman で起動する」を参照。
# =============================================================================

ARG DEBIAN_TAG=trixie

# -----------------------------------------------------------------------------
# stage: mise 本体
# -----------------------------------------------------------------------------
FROM debian:${DEBIAN_TAG} AS mise-bin

# 既定は最新。厳密に固定したいときだけ .env で MISE_VERSION=v2026.9.8 のように渡す。
# ツールチェーン自体の再現性は mise.lock が担保する。
ARG MISE_VERSION=latest
ENV DEBIAN_FRONTEND=noninteractive
# mise.run のインストーラは MISE_VERSION を読むので、"latest" のときは unset しないと
# "latest" という版を探して 404 になる。
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl; \
    if [ "${MISE_VERSION}" = "latest" ]; then unset MISE_VERSION; fi; \
    curl -fsSL https://mise.run | MISE_INSTALL_PATH=/usr/local/bin/mise sh; \
    /usr/local/bin/mise --version; \
    rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------------------------
# stage: ツールチェーン構築
# -----------------------------------------------------------------------------
FROM debian:${DEBIAN_TAG} AS toolchains

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    MISE_YES=1 \
    MISE_DATA_DIR=/opt/mise \
    MISE_STATE_DIR=/opt/mise/state \
    MISE_CACHE_DIR=/tmp/mise-cache

# 取得と展開にだけ必要なもの。最終イメージには残らない。
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl git tar gzip xz-utils \
 && rm -rf /var/lib/apt/lists/*

COPY --from=mise-bin /usr/local/bin/mise /usr/local/bin/mise

# バージョンの入力はこの 2 ファイルだけ。
# --locked: mise.lock に URL / sha256 が無いツールがあればビルドを失敗させる
#           （lock を更新し忘れたまま「その時点の最新」が入る事故を防ぐ）。
WORKDIR /toolchains
COPY mise.toml mise.lock ./
RUN mise trust --all \
 && mise install --locked \
 && mise reshim \
 && mise ls --current \
 && rm -rf "${MISE_DATA_DIR}/downloads" "${MISE_CACHE_DIR}"

# -----------------------------------------------------------------------------
# stage: 開発イメージ
# -----------------------------------------------------------------------------
FROM debian:${DEBIAN_TAG} AS dev

ARG USERNAME=vscode
ARG USER_UID=1000
ARG USER_GID=1000
ARG TZ=Asia/Tokyo

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=${TZ}

# OS レベルのパッケージだけを apt で入れる（言語ツールは mise）。
#   sudo / zsh / fzf / tmux       : シェル環境。tmux は claude のループを並べて回すのに便利
#   git / openssh-client / gnupg  : VS Code が SSH / GPG エージェントを転送してくる
#   jq / ripgrep                  : Claude Code とフックのスクリプトがよく使う
#   iptables / ipset / iproute2 /
#   bind9-dnsutils / aggregate    : 外部通信遮断（egress-firewall）。既定では使われない
# bubblewrap は入れない。Docker 既定の seccomp ではユーザー名前空間を作れず、
# Claude Code 組み込みのサンドボックスはこのコンテナ内では動かないため（実測）。
# 隔離はコンテナ自体と外部通信遮断が受け持つ（docs/egress-firewall.md）。
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl wget git openssh-client gnupg \
      sudo zsh bash-completion tzdata \
      less nano procps psmisc file jq ripgrep fzf tmux xz-utils \
      iptables ipset iproute2 bind9-dnsutils aggregate \
 && ln -snf "/usr/share/zoneinfo/${TZ}" /etc/localtime \
 && echo "${TZ}" > /etc/timezone \
 && rm -rf /var/lib/apt/lists/*

# --- 非 root ユーザー -------------------------------------------------------
# debian:trixie には uid/gid 1000 のユーザーが居ない（Ubuntu 系との違い）。
# WSL のホストユーザーと uid/gid を一致させるのが、バインドマウントで権限問題を
# 出さない唯一の確実な方法。既に同じ uid/gid が居るベースでも壊れないようにしてある。
# trixie の /etc/login.defs は HOME_MODE 0700。VS Code Server が不安定になるので 0755 に直す。
RUN set -eux; \
    if [ "${USER_UID}" = "0" ] || [ "${USER_GID}" = "0" ]; then \
      echo "USER_UID / USER_GID に 0 (root) は使えない。.devcontainer/.env を確認すること" >&2; \
      exit 1; \
    fi; \
    if getent group "${USER_GID}" >/dev/null; then \
      groupmod -n "${USERNAME}" "$(getent group "${USER_GID}" | cut -d: -f1)"; \
    else \
      groupadd --gid "${USER_GID}" "${USERNAME}"; \
    fi; \
    if getent passwd "${USER_UID}" >/dev/null; then \
      usermod -l "${USERNAME}" -d "/home/${USERNAME}" -m -s /usr/bin/zsh \
              -g "${USER_GID}" "$(getent passwd "${USER_UID}" | cut -d: -f1)"; \
    else \
      useradd --uid "${USER_UID}" --gid "${USER_GID}" --create-home \
              --shell /usr/bin/zsh "${USERNAME}"; \
    fi; \
    install -d -m 0755 -o "${USERNAME}" -g "${USERNAME}" "/home/${USERNAME}"

# --- sudo は 2 ファイルに分ける ----------------------------------------------
#   10-devcontainer : 起動時の初期化と外部通信遮断のコマンドだけ（常に残る）
#   90-dev-user-all : 何でもできる sudo（快適さのため。既定ではこれが効いている）
# 外部通信遮断を有効にすると egress-firewall が 90 を削除する。
# 残しておくと `sudo iptables -F` で遮断を内側から外せてしまうため。
# env_keep: コンテナの設定値を初期化スクリプトへ渡す（sudo は既定で環境変数を消す）。
RUN set -eux; \
    { \
      echo 'Cmnd_Alias DEVCONTAINER_ROOT = /usr/local/sbin/devcontainer-init, /usr/local/bin/egress-firewall'; \
      echo 'Defaults!DEVCONTAINER_ROOT env_keep += "EGRESS_FIREWALL EGRESS_ALLOW_DOMAINS"'; \
      echo "${USERNAME} ALL=(root) NOPASSWD: DEVCONTAINER_ROOT"; \
    } > /etc/sudoers.d/10-devcontainer; \
    printf '%s ALL=(root) NOPASSWD: ALL\n' "${USERNAME}" > /etc/sudoers.d/90-dev-user-all; \
    chmod 0440 /etc/sudoers.d/10-devcontainer /etc/sudoers.d/90-dev-user-all; \
    visudo -c

# root で git を叩いたとき（sudo git など）だけのための保険。
# uid が一致しているので通常のユーザーでは dubious ownership は起きない。
RUN git config --system --add safe.directory /workspaces \
 && git config --system --add safe.directory '/workspaces/*'

# --- 起動時の初期化と外部通信遮断（root 所有。ユーザーは書き換えられない）------
COPY --chmod=0755 .devcontainer/entrypoint.sh /usr/local/bin/devcontainer-entrypoint
COPY --chmod=0755 .devcontainer/devcontainer-init.sh /usr/local/sbin/devcontainer-init
COPY --chmod=0755 .devcontainer/firewall/egress-firewall.sh /usr/local/bin/egress-firewall
COPY --chmod=0644 .devcontainer/firewall/allowlist.txt /etc/egress-firewall/allowlist.txt

# --- ツールチェーンを持ち込む ------------------------------------------------
# --chown を付けて COPY する。あとから chown -R するとレイヤが二重になる。
# ユーザー所有にしておくのは、コンテナ内で `mise use` などを sudo なしでできるようにするため。
# （root で動くスクリプトは /opt/mise を一切使わない。PATH も固定してある）
COPY --from=mise-bin /usr/local/bin/mise /usr/local/bin/mise
COPY --from=toolchains --chown=${USER_UID}:${USER_GID} /opt/mise /opt/mise

# --- 環境変数 ---------------------------------------------------------------
# ENV として確定させるのが要点。devcontainer.json の containerEnv に書くと
# VS Code 経由でしか効かず、`docker compose exec` した素のシェルでは PATH が通らない。
#
# MISE_TRUSTED_CONFIG_PATHS:
#   ビルド時と実行時で mise.toml のパスが変わる（/toolchains → /workspaces/...）。
# CLAUDE_CONFIG_DIR:
#   ~/.claude にボリュームを当てるだけではログインが残らない。認証情報や
#   プロジェクトごとの信頼設定は既定で ~/.claude.json（ディレクトリの外）に書かれるため。
#   この変数でまとめて ~/.claude 配下へ寄せて、はじめて再作成後もログインが残る。
# DISABLE_AUTOUPDATER:
#   claude が自分で更新すると mise.lock の固定が意味を失うので止める。
# DEV_USER:
#   root で動く devcontainer-init が「誰のためのボリュームか」を知るのに使う。
ENV MISE_DATA_DIR=/opt/mise \
    MISE_STATE_DIR=/opt/mise/state \
    MISE_TRUSTED_CONFIG_PATHS=/workspaces \
    PNPM_HOME=/home/${USERNAME}/.local/share/pnpm \
    HISTFILE=/home/${USERNAME}/.commandhistory/.zsh_history \
    CLAUDE_CONFIG_DIR=/home/${USERNAME}/.claude \
    DISABLE_AUTOUPDATER=1 \
    DEV_USER=${USERNAME} \
    DEVCONTAINER=true
ENV PATH=/opt/mise/shims:${PNPM_HOME}:${PATH}

# --- ボリュームのマウント先を「先に」ユーザー所有で作る ----------------------
# 存在しないパスに volume をマウントすると Docker が root:root で作り、以降の
# 書き込みが EACCES になる。存在していれば、Docker は空ボリュームをこの
# ディレクトリの所有権とパーミッションで初期化する。WSL + devcontainer で
# いちばん踏みやすい権限の罠。compose.yaml の volumes と 1 対 1 で対応させること。
RUN install -d -o "${USERNAME}" -g "${USERNAME}" \
      "/home/${USERNAME}/.cache" \
      "/home/${USERNAME}/.local" \
      "/home/${USERNAME}/.local/share" \
      "/home/${USERNAME}/.local/share/pnpm" \
      "/home/${USERNAME}/.commandhistory" \
      "/home/${USERNAME}/.vscode-server" \
      /workspaces \
 && install -d -m 0700 -o "${USERNAME}" -g "${USERNAME}" "/home/${USERNAME}/.claude"

# --- ログインシェル対策（重要）----------------------------------------------
# Debian の /etc/profile は PATH を「無条件に代入」する。Debian の zsh は
# /etc/zsh/zprofile から /etc/profile を読むので、`zsh -l`（VS Code の統合ターミナル）
# や `bash -lc ...` では上の ENV PATH が丸ごと消え、node も claude も見つからなくなる。
# /etc/profile は最後に /etc/profile.d/*.sh を読むので、そこで前置し直す。
RUN printf '%s\n' \
      '# mise のシムを PATH の先頭へ戻す（/etc/profile が PATH を上書きするため）' \
      'case ":${PATH}:" in' \
      '  *":/opt/mise/shims:"*) ;;' \
      "  *) PATH=\"/opt/mise/shims:/home/${USERNAME}/.local/share/pnpm:\${PATH}\"; export PATH ;;" \
      'esac' \
    > /etc/profile.d/10-mise-path.sh \
 && chmod 0644 /etc/profile.d/10-mise-path.sh

# --- zsh + oh-my-zsh --------------------------------------------------------
# postCreate ではなくイメージに焼く。作り直すたびに取り直すより軽い（.git は落とす）。
USER ${USERNAME}
RUN set -eux; \
    git clone --depth=1 https://github.com/ohmyzsh/ohmyzsh.git "${HOME}/.oh-my-zsh"; \
    git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions \
      "${HOME}/.oh-my-zsh/custom/plugins/zsh-autosuggestions"; \
    git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting \
      "${HOME}/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting"; \
    git clone --depth=1 https://github.com/zsh-users/zsh-completions \
      "${HOME}/.oh-my-zsh/custom/plugins/zsh-completions"; \
    find "${HOME}/.oh-my-zsh" -maxdepth 4 -name .git -prune -exec rm -rf {} +
COPY --chown=${USER_UID}:${USER_GID} .devcontainer/zshrc /home/${USERNAME}/.zshrc

WORKDIR /workspaces

# ENTRYPOINT は VS Code（overrideCommand: false）でも docker compose でも
# docker run でも必ず通る。ボリュームの所有権修復と、有効なら外部通信遮断を行う。
ENTRYPOINT ["/usr/local/bin/devcontainer-entrypoint"]
CMD ["sleep", "infinity"]
