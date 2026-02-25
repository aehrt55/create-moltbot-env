import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";
import chalk from "chalk";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const MIGRATIONS_DIR = path.resolve(__dirname, "..", "migrations");

interface Meta {
  version: string;
  createdAt: string;
  lastUpgrade: string | null;
}

function getCliVersion(): string {
  const pkg = JSON.parse(
    fs.readFileSync(path.resolve(__dirname, "..", "package.json"), "utf8")
  );
  return pkg.version;
}

function getRepoMeta(): Meta | null {
  // Try .moltbot-env.json first (v0.2.0+)
  const configPath = path.resolve(process.cwd(), ".moltbot-env.json");
  if (fs.existsSync(configPath)) {
    try {
      const config = JSON.parse(fs.readFileSync(configPath, "utf8"));
      if (config.meta) return config.meta;
    } catch (err) {
      throw new Error(`Failed to parse ${configPath}: ${(err as Error).message}`);
    }
  }

  // Fall back to .moltbot-env-meta.json (v0.1.x)
  const legacyPath = path.resolve(process.cwd(), ".moltbot-env-meta.json");
  if (fs.existsSync(legacyPath)) {
    try {
      return JSON.parse(fs.readFileSync(legacyPath, "utf8"));
    } catch (err) {
      throw new Error(`Failed to parse ${legacyPath}: ${(err as Error).message}`);
    }
  }

  return null;
}

function getMigrationFiles(): { from: string; to: string; file: string }[] {
  if (!fs.existsSync(MIGRATIONS_DIR)) return [];
  return fs
    .readdirSync(MIGRATIONS_DIR)
    .filter((f) => f.endsWith(".md") && f.includes("-to-"))
    .map((f) => {
      const match = f.match(/^(.+)-to-(.+)\.md$/);
      if (!match) return null;
      return { from: match[1], to: match[2], file: f };
    })
    .filter((x): x is { from: string; to: string; file: string } => x !== null)
    .sort((a, b) => compareVersions(a.from, b.from));
}

function compareVersions(a: string, b: string): number {
  const pa = a.split(".").map(Number);
  const pb = b.split(".").map(Number);
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const na = pa[i] ?? 0;
    const nb = pb[i] ?? 0;
    if (na !== nb) return na - nb;
  }
  return 0;
}

function buildMigrationChain(
  currentVersion: string,
  targetVersion: string,
  migrations: { from: string; to: string; file: string }[]
): { from: string; to: string; file: string }[] {
  const chain: { from: string; to: string; file: string }[] = [];
  let version = currentVersion;

  while (compareVersions(version, targetVersion) < 0) {
    const next = migrations.find((m) => m.from === version);
    if (!next) break;
    chain.push(next);
    version = next.to;
  }

  return chain;
}

export async function diff(args: string[]) {
  const jsonOutput = args.includes("--json");

  const meta = getRepoMeta();
  if (!meta) {
    if (jsonOutput) {
      console.log(JSON.stringify({ error: "no_meta", message: ".moltbot-env.json not found in current directory" }));
    } else {
      console.error(chalk.red("Error: .moltbot-env.json not found in current directory."));
      console.error(chalk.dim("Are you running this from a moltbot-env repo?"));
    }
    process.exit(1);
  }

  const cliVersion = getCliVersion();
  const currentVersion = meta.version;

  if (compareVersions(currentVersion, cliVersion) >= 0) {
    if (jsonOutput) {
      console.log(JSON.stringify({ upToDate: true, version: currentVersion }));
    } else {
      console.log(chalk.green(`Already up to date (v${currentVersion})`));
    }
    process.exit(1);
  }

  const allMigrations = getMigrationFiles();
  const chain = buildMigrationChain(currentVersion, cliVersion, allMigrations);

  if (chain.length === 0) {
    if (jsonOutput) {
      console.log(JSON.stringify({
        upToDate: false,
        currentVersion,
        targetVersion: cliVersion,
        error: "no_migration_path",
        message: `No migration path from ${currentVersion} to ${cliVersion}`,
      }));
    } else {
      console.log(`Detected repo version: ${chalk.cyan(currentVersion)}`);
      console.log(`Latest CLI version:    ${chalk.cyan(cliVersion)}`);
      console.log();
      console.log(chalk.yellow(`No migration files found for ${currentVersion} → ${cliVersion}`));
    }
    process.exit(1);
  }

  // Build the version chain for display
  const versionChain = [currentVersion, ...chain.map((m) => m.to)].join(" → ");

  if (!jsonOutput) {
    console.log(`Detected repo version: ${chalk.cyan(currentVersion)}`);
    console.log(`Latest CLI version:    ${chalk.cyan(cliVersion)}`);
    console.log(`Migrations to apply:   ${chalk.cyan(versionChain)}`);
    console.log();
  }

  // Output migration contents
  const migrationContents: { from: string; to: string; content: string }[] = [];

  for (const migration of chain) {
    const content = fs.readFileSync(
      path.join(MIGRATIONS_DIR, migration.file),
      "utf8"
    );
    migrationContents.push({
      from: migration.from,
      to: migration.to,
      content,
    });

    if (!jsonOutput) {
      console.log(`## Migration ${migration.from} → ${migration.to}`);
      console.log();
      console.log(content);
      console.log();
    }
  }

  if (jsonOutput) {
    console.log(JSON.stringify({
      upToDate: false,
      currentVersion,
      targetVersion: cliVersion,
      migrations: migrationContents,
    }));
  }

  process.exit(0);
}
