#!/usr/bin/env node

const fs = require("fs");
const path = require("path");
const crypto = require("crypto");

const repoRoot = path.resolve(__dirname, "..");
const metadataRoot = path.join(repoRoot, "hask-redis-mux", "data", "redis-7.2");
const commandsDir = path.join(metadataRoot, "src", "commands");
const manifestPath = path.join(metadataRoot, "manifest.sha256");
const aggregatePath = path.join(metadataRoot, "all-files.sha256");
const defaultOutPath = path.join(
  repoRoot,
  "hask-redis-mux",
  "lib",
  "cluster",
  "Database",
  "Redis",
  "Cluster",
  "Commands",
  "Generated.hs"
);
const outPath = process.argv[2] ? path.resolve(process.argv[2]) : defaultOutPath;

function sha256(buf) {
  return crypto.createHash("sha256").update(buf).digest("hex");
}

function readManifest() {
  const lines = fs.readFileSync(manifestPath, "utf8").split("\n").filter(Boolean);
  const metadata = {};
  const files = [];
  for (const line of lines) {
    if (line.includes("=") && !line.match(/^[0-9a-f]{64}\s/)) {
      const [k, v] = line.split("=", 2);
      metadata[k] = v;
      continue;
    }
    const m = line.match(/^([0-9a-f]{64})\s+(.+)$/);
    if (!m) throw new Error(`Invalid manifest line: ${line}`);
    files.push({ hash: m[1], file: m[2] });
  }
  return { metadata, files };
}

function parseBeginSearch(raw) {
  if (!raw || typeof raw !== "object") return "BeginSearchUnsupported";
  if (raw.index && Number.isInteger(raw.index.pos)) {
    return `(BeginIndex (${raw.index.pos}))`;
  }
  if (raw.keyword && typeof raw.keyword.keyword === "string" && Number.isInteger(raw.keyword.startfrom)) {
    return `(BeginKeyword "${escapeHs(raw.keyword.keyword)}" (${raw.keyword.startfrom}))`;
  }
  return "BeginSearchUnsupported";
}

function parseFindKeys(raw) {
  if (!raw || typeof raw !== "object") return "FindKeysUnsupported";
  if (
    raw.range &&
    Number.isInteger(raw.range.lastkey) &&
    Number.isInteger(raw.range.step) &&
    Number.isInteger(raw.range.limit)
  ) {
    return `(FindRange (${raw.range.lastkey}) (${raw.range.step}) (${raw.range.limit}))`;
  }
  if (
    raw.keynum &&
    Number.isInteger(raw.keynum.keynumidx) &&
    Number.isInteger(raw.keynum.firstkey) &&
    Number.isInteger(raw.keynum.step)
  ) {
    return `(FindKeyNum (${raw.keynum.keynumidx}) (${raw.keynum.firstkey}) (${raw.keynum.step}))`;
  }
  return "FindKeysUnsupported";
}

function escapeHs(s) {
  return s.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
}

function commandSpecToHs(spec) {
  const keySpecs = (spec.key_specs || []).map((ks) =>
    `GeneratedKeySpec ${parseBeginSearch(ks.begin_search)} ${parseFindKeys(ks.find_keys)}`
  );
  const renderedKeySpecs = keySpecs.length === 0 ? "[]" : `[${keySpecs.join(", ")}]`;
  return `GeneratedCommandSpec "${escapeHs(spec.name)}" (${spec.arity}) ${renderedKeySpecs}`;
}

function loadCommandSpecs(files) {
  const entries = [];
  for (const file of files) {
    const abs = path.join(commandsDir, file);
    const raw = fs.readFileSync(abs);
    const actual = sha256(raw);
    const expected = manifest.filesByName.get(file);
    if (!expected) throw new Error(`Missing manifest hash for ${file}`);
    if (actual !== expected) throw new Error(`SHA256 mismatch for ${file}: ${actual} != ${expected}`);
    const parsed = JSON.parse(raw.toString("utf8"));
    for (const [name, value] of Object.entries(parsed)) {
      entries.push({
        name,
        arity: Number.isInteger(value.arity) ? value.arity : 0,
        key_specs: Array.isArray(value.key_specs) ? value.key_specs : [],
      });
    }
  }
  entries.sort((a, b) => a.name.localeCompare(b.name));
  return entries;
}

const manifest = (() => {
  const parsed = readManifest();
  const filesByName = new Map();
  for (const f of parsed.files) filesByName.set(f.file, f.hash);
  return { ...parsed, filesByName };
})();

const commandFiles = fs
  .readdirSync(commandsDir)
  .filter((f) => f.endsWith(".json"))
  .sort();
const commandSpecs = loadCommandSpecs(commandFiles);
const payload = JSON.stringify(commandSpecs);
const payloadDigest = sha256(Buffer.from(payload, "utf8"));
const aggregateDigest = fs.readFileSync(aggregatePath, "utf8").trim();

const moduleText = `{-# LANGUAGE OverloadedStrings #-}

module Database.Redis.Cluster.Commands.Generated
  ( generatedSourceRepo
  , generatedSourceRef
  , generatedSourceCommit
  , generatedSourceAggregateSha256
  , generatedCommandPayloadSha256
  , generatedCommandSpecs
  , generatedCommandSpecCount
  ) where

import           Data.ByteString                          (ByteString)
import           Database.Redis.Cluster.Commands.Types

generatedSourceRepo :: ByteString
generatedSourceRepo = "${escapeHs(manifest.metadata.source_repo || "")}"

generatedSourceRef :: ByteString
generatedSourceRef = "${escapeHs(manifest.metadata.source_ref || "")}"

generatedSourceCommit :: ByteString
generatedSourceCommit = "${escapeHs(manifest.metadata.source_commit || "")}"

generatedSourceAggregateSha256 :: ByteString
generatedSourceAggregateSha256 = "${escapeHs(aggregateDigest)}"

generatedCommandPayloadSha256 :: ByteString
generatedCommandPayloadSha256 = "${escapeHs(payloadDigest)}"

generatedCommandSpecs :: [GeneratedCommandSpec]
generatedCommandSpecs =
  [ ${commandSpecs.map(commandSpecToHs).join("\n  , ")}
  ]

generatedCommandSpecCount :: Int
generatedCommandSpecCount = ${commandSpecs.length}
`;

fs.writeFileSync(outPath, moduleText);
console.log(`Wrote ${outPath} with ${commandSpecs.length} command specs`);
