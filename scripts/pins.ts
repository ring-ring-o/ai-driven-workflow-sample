// =============================================================================
// mise.toml を唯一の情報源として、package.json の「ピン」を生成／検証する。
//
//   node scripts/pins.ts sync     mise の解決結果で package.json を書き換える
//   node scripts/pins.ts check    ズレていたら差分を出して exit 1
//
// 対象は「そのツール自身が実際に読む値」だけ:
//   packageManager        pnpm はこの値を見て自分を別の版に切り替える。
//                         mise の pnpm とズレると mise.toml と違う pnpm が黙って動く
//   @types/node の major  型定義が実行時（mise の node）と別の major だと、
//                         存在しない API を型検査が通してしまう
//
// これらは入力ではなく mise.toml からの派生物。手で編集せず `mise run pins:sync`。
// 依存は Node 標準ライブラリと mise CLI だけ（pnpm install 前でも動く）。
// =============================================================================
import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const REPO = join(import.meta.dirname, "..");
const PACKAGE_JSON = join(REPO, "package.json");

interface MiseEntry {
  version?: string;
  active?: boolean;
}

interface PackageJson {
  packageManager?: string;
  devDependencies?: Record<string, string>;
  [key: string]: unknown;
}

interface Pin {
  field: string;
  why: string;
  expected: (versions: Map<string, string>) => string;
  read: (pkg: PackageJson) => string | undefined;
  matches: (actual: string, expected: string) => boolean;
  write: (pkg: PackageJson, expected: string) => void;
}

const majorOf = (versionOrRange: string): string | undefined => /\d+/.exec(versionOrRange)?.[0];

function versionOf(versions: Map<string, string>, tool: string): string {
  const version = versions.get(tool);
  if (version === undefined) {
    throw new Error(`mise が ${tool} を解決できない。先に \`mise install\` を実行すること`);
  }
  return version;
}

const PINS: Pin[] = [
  {
    field: "packageManager",
    why: "pnpm はこの値を見て自分を別の版に切り替える",
    expected: (v) => `pnpm@${versionOf(v, "pnpm")}`,
    read: (pkg) => pkg.packageManager,
    matches: (actual, expected) => actual === expected,
    write: (pkg, expected) => {
      pkg.packageManager = expected;
    },
  },
  {
    field: 'devDependencies["@types/node"]',
    why: "型定義の major を実行時の Node と揃える",
    expected: (v) => `^${majorOf(versionOf(v, "node"))}`,
    read: (pkg) => pkg.devDependencies?.["@types/node"],
    // major が同じなら範囲の書き方（^24.13.4 など）は問わない
    matches: (actual, expected) => majorOf(actual) === majorOf(expected),
    write: (pkg, expected) => {
      pkg.devDependencies = { ...pkg.devDependencies, "@types/node": expected };
    },
  },
];

/** mise が解決した実バージョン（例: node → 24.21.0） */
function resolvedVersions(): Map<string, string> {
  const stdout = execFileSync("mise", ["ls", "--current", "--json"], {
    cwd: REPO,
    encoding: "utf8",
  });
  const json = JSON.parse(stdout) as Record<string, MiseEntry[]>;
  const versions = new Map<string, string>();
  for (const [tool, entries] of Object.entries(json)) {
    const entry = entries.find((e) => e.active) ?? entries[0];
    if (entry?.version) versions.set(tool, entry.version);
  }
  return versions;
}

const RED = "\x1b[31m";
const GREEN = "\x1b[32m";
const DIM = "\x1b[2m";
const OFF = "\x1b[0m";

function main(mode: string | undefined): number {
  if (mode !== "sync" && mode !== "check") {
    console.error("usage: node scripts/pins.ts <sync|check>");
    return 2;
  }

  const versions = resolvedVersions();
  const pkg = JSON.parse(readFileSync(PACKAGE_JSON, "utf8")) as PackageJson;
  let drifted = 0;

  for (const pin of PINS) {
    const expected = pin.expected(versions);
    const actual = pin.read(pkg);
    if (actual !== undefined && pin.matches(actual, expected)) {
      console.log(`${GREEN}ok${OFF}    ${pin.field} = ${actual}`);
      continue;
    }
    drifted++;
    if (mode === "sync") {
      pin.write(pkg, expected);
      console.log(`${GREEN}sync${OFF}  ${pin.field}: ${actual ?? "(なし)"} → ${expected}`);
    } else {
      console.log(`${RED}drift${OFF} ${pin.field}: ${actual ?? "(なし)"}（期待値 ${expected}）`);
      console.log(`${DIM}      ${pin.why}${OFF}`);
    }
  }

  if (mode === "sync" && drifted > 0) {
    writeFileSync(PACKAGE_JSON, `${JSON.stringify(pkg, null, 2)}\n`);
    console.log(
      `${DIM}package.json を更新した。依存が変わった場合は \`pnpm install\` も実行すること${OFF}`,
    );
  }
  if (mode === "check" && drifted > 0) {
    console.log(`${RED}mise.toml とズレている。\`mise run pins:sync\` で揃えること${OFF}`);
    return 1;
  }
  return 0;
}

process.exitCode = main(process.argv[2]);
