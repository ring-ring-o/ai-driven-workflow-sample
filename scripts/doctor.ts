// =============================================================================
// 環境の診断（mise run doctor）。ループを回す前に「この環境は想定どおりか」を確認する。
//
//   - ツールチェーン : mise が解決した版と、実際に PATH で見つかる実行ファイルの版
//   - コンテナ       : uid/gid の一致、Claude Code の設定の永続化、自己更新の停止
//   - 外部通信遮断   : 設定値と適用状態
//
// 情報表示が目的なので、問題があっても exit 0 で終わる（警告を出すだけ）。
// 依存は Node 標準ライブラリだけ。
// =============================================================================
import { execFileSync } from "node:child_process";
import { accessSync, constants, existsSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";

const REPO = join(import.meta.dirname, "..");
const GREEN = "\x1b[32m";
const YELLOW = "\x1b[33m";
const DIM = "\x1b[2m";
const BOLD = "\x1b[1m";
const OFF = "\x1b[0m";

let warnings = 0;

/** 全角文字を幅 2 として右を空白で埋める（ラベルの桁揃え用） */
const pad = (text: string, width: number): string => {
  const columns = [...text].reduce((sum, ch) => sum + ((ch.codePointAt(0) ?? 0) > 0xff ? 2 : 1), 0);
  return text + " ".repeat(Math.max(0, width - columns));
};
const heading = (title: string): void => console.log(`\n${BOLD}${title}${OFF}`);
const ok = (label: string, detail: string): void =>
  console.log(`  ${GREEN}✔${OFF} ${pad(label, 22)} ${detail}`);
const warn = (label: string, detail: string): void => {
  warnings++;
  console.log(`  ${YELLOW}!${OFF} ${pad(label, 22)} ${detail}`);
};
const info = (label: string, detail: string): void =>
  console.log(`  ${DIM}-${OFF} ${pad(label, 22)} ${detail}`);

function run(command: string, args: string[]): string | undefined {
  try {
    return execFileSync(command, args, {
      cwd: REPO,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
      timeout: 15_000,
    }).trim();
  } catch {
    return undefined;
  }
}

function writable(path: string): boolean {
  try {
    accessSync(path, constants.W_OK);
    return true;
  } catch {
    return false;
  }
}

// -----------------------------------------------------------------------------
heading("ツールチェーン（mise.toml / mise.lock）");
const current = run("mise", ["ls", "--current", "--json"]);
if (current === undefined) {
  warn("mise", "mise ls が失敗した（mise install 済みか、ワークスペース内で実行しているか）");
} else {
  const tools = JSON.parse(current) as Record<string, { version?: string }[]>;
  for (const [tool, entries] of Object.entries(tools)) {
    info(tool, entries[0]?.version ?? "(未インストール)");
  }
}

heading("実行ファイル");
const binaries: [string, string[]][] = [
  ["node", ["--version"]],
  ["pnpm", ["--version"]],
  ["claude", ["--version"]],
  ["tsc", ["--version"]],
  ["biome", ["--version"]],
];
for (const [bin, args] of binaries) {
  const version = run(bin, args);
  if (version === undefined) {
    warn(bin, "見つからない（tsc / biome は mise run deps のあとで入る）");
  } else {
    ok(bin, version.split("\n")[0] ?? "");
  }
}

// -----------------------------------------------------------------------------
if (process.env.DEVCONTAINER === "true") {
  heading("コンテナ");

  const uid = process.getuid?.();
  const gid = process.getgid?.();
  const repoStat = statSync(REPO);
  if (uid === 0) {
    warn("ユーザー", "root で実行している。docker compose exec に -u root を付けていないか確認");
  } else if (repoStat.uid === uid && repoStat.gid === gid) {
    ok("uid / gid", `${uid}:${gid}（ワークスペースの所有者と一致）`);
  } else {
    warn(
      "uid / gid",
      `コンテナ ${uid}:${gid} / ワークスペース ${repoStat.uid}:${repoStat.gid}。` +
        "bash .devcontainer/init-host.sh を実行してから Rebuild",
    );
  }

  const configDir = process.env.CLAUDE_CONFIG_DIR;
  if (configDir === undefined) {
    warn(
      "CLAUDE_CONFIG_DIR",
      "未設定（~/.claude.json がボリュームの外に書かれ、ログインが消える）",
    );
  } else if (!writable(configDir)) {
    warn("CLAUDE_CONFIG_DIR", `${configDir} に書き込めない（ボリュームの所有権）`);
  } else {
    const auth = existsSync(join(configDir, ".credentials.json"))
      ? "認証情報あり"
      : process.env.ANTHROPIC_API_KEY
        ? "ANTHROPIC_API_KEY を使用"
        : "未ログイン: claude を起動してログイン";
    ok("CLAUDE_CONFIG_DIR", `${configDir}（${auth}）`);
  }

  if (process.env.DISABLE_AUTOUPDATER === "1") {
    ok("Claude Code 自己更新", "停止（版は mise.lock で固定）");
  } else {
    warn("Claude Code 自己更新", "有効（mise.lock の固定が効かなくなる）");
  }

  heading("外部通信遮断");
  const configured = process.env.EGRESS_FIREWALL || "off";
  const appliedAt = "/run/egress-firewall/applied-at";
  if (existsSync(appliedAt)) {
    ok("状態", `遮断中（${readFileSync(appliedAt, "utf8").trim()} に適用 / 設定 ${configured}）`);
  } else if (["on", "true", "yes", "1"].includes(configured.toLowerCase())) {
    warn("状態", `設定は ${configured} だが適用されていない`);
  } else {
    info("状態", `off（有効化は docs/egress-firewall.md）`);
  }
}

console.log(
  warnings === 0 ? `\n${GREEN}問題なし${OFF}\n` : `\n${YELLOW}警告 ${warnings} 件${OFF}\n`,
);
