import { readFileSync, writeFileSync } from "node:fs";

const shouldBump = process.argv.includes("--bump");
const bumpType = process.argv.includes("--major")
  ? "major"
  : process.argv.includes("--minor")
    ? "minor"
    : "patch";

const packageJson = JSON.parse(readFileSync("package.json", "utf8"));
let version = packageJson.version;

if (shouldBump) {
  const match = /^(\d+)\.(\d+)\.(\d+)$/.exec(version);
  if (!match) throw new Error(`Cannot bump non-stable version: ${version}`);
  let [, major, minor, patch] = match.map(Number);
  if (bumpType === "major") {
    major += 1;
    minor = 0;
    patch = 0;
  } else if (bumpType === "minor") {
    minor += 1;
    patch = 0;
  } else {
    patch += 1;
  }
  version = `${major}.${minor}.${patch}`;
  packageJson.version = version;
  writeFileSync("package.json", JSON.stringify(packageJson, null, 2) + "\n");
}

if (!/^\d+\.\d+\.\d+$/.test(version)) throw new Error(`Invalid stable version: ${version}`);
writeFileSync("src/version.ts", `export const VERSION = '${version}';\n`);

const lockPath = "package-lock.json";
try {
  const lock = JSON.parse(readFileSync(lockPath, "utf8"));
  lock.version = version;
  if (lock.packages?.[""]) lock.packages[""].version = version;
  writeFileSync(lockPath, JSON.stringify(lock, null, 2) + "\n");
} catch (error) {
  if (error.code !== "ENOENT") throw error;
}

const cargoPath = "launcher/Cargo.toml";
const cargo = readFileSync(cargoPath, "utf8");
const cargoPattern = /^version\s*=\s*"[^"]+"\s*$/m;
if (!cargoPattern.test(cargo)) throw new Error(`Cannot find package version in ${cargoPath}`);
writeFileSync(cargoPath, cargo.replace(cargoPattern, `version = "${version}"`));

const buildPath = "launcher/build.rs";
let build = readFileSync(buildPath, "utf8");
const csv = `${version.split(".").join(",")},0`;
const replacements = [
  [/FILEVERSION\s+\d+,\d+,\d+,\d+/, `FILEVERSION ${csv}`],
  [/PRODUCTVERSION\s+\d+,\d+,\d+,\d+/, `PRODUCTVERSION ${csv}`],
  [/"FileVersion",\s*"[^"]*?(\\0)?"/, `"FileVersion", "${version}.0$1"`],
  [/"ProductVersion",\s*"[^"]*?(\\0)?"/, `"ProductVersion", "${version}$1"`],
];
for (const [pattern, replacement] of replacements) {
  if (!pattern.test(build)) throw new Error(`Cannot find version resource ${pattern} in ${buildPath}`);
  build = build.replace(pattern, replacement);
}
writeFileSync(buildPath, build);

console.log(`DeskPilot version synchronized to ${version}${shouldBump ? ` (${bumpType} bump)` : ""}.`);
