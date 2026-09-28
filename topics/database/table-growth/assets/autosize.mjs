// Fit each diagram's canvas to the content it actually draws.
//
//   node autosize.mjs           # add bottom padding, but never crop
//
// The generator sets a provisional height for each diagram; hand arithmetic
// drifts as soon as a note line is added. This script renders every SVG in
// headless Chrome, measures the union bounding box of its content, and rewrites
// the viewBox and height attributes to that extent plus PADDING. It never shrinks
// a diagram below its current height, so a diagram that already has slack keeps
// it, and it exits non-zero if any diagram overflows after the pass.
import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, mkdtempSync, globSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, basename } from "node:path";

const CHROME =
  process.env.CHROME || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const PADDING = 0;

const files = process.argv.slice(2).length ? process.argv.slice(2) : globSync("*.svg").sort();
const dir = mkdtempSync(join(tmpdir(), "svg-autosize-"));

function measure(file) {
  const page = join(dir, `${basename(file)}.html`);
  writeFileSync(
    page,
    `<!doctype html><meta charset="utf-8"><body style="margin:0">
${readFileSync(file, "utf8")}
<script>
  const bb = document.querySelector("svg").getBBox();
  document.title = JSON.stringify({
    y: Math.round(bb.y), bottom: Math.round(bb.y + bb.height),
    x: Math.round(bb.x), right: Math.round(bb.x + bb.width),
  });
</script>`,
  );
  const dom = execFileSync(
    CHROME,
    ["--headless", "--disable-gpu", "--dump-dom", "--virtual-time-budget=3000", `file://${page}`],
    { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] },
  );
  const raw = /<title>([^<]+)<\/title>/.exec(dom)?.[1];
  return raw ? JSON.parse(raw.replace(/&quot;/g, '"').replace(/&amp;/g, "&")) : null;
}

let bad = 0;
for (const file of files) {
  const svg = readFileSync(file, "utf8");
  const before = measure(file);
  const declared = Number(/<svg[^>]*height="(\d+)"/.exec(svg)[1]);
  const width = Number(/<svg[^>]*width="(\d+)"/.exec(svg)[1]);
  if (!before) {
    console.log(`${file.padEnd(28)} could not measure`);
    bad++;
    continue;
  }
  const target = Math.max(declared, before.bottom + PADDING, width ? 0 : 0);
  if (target !== declared) {
    const next = svg
      .replace(/viewBox="0 0 (\d+) (\d+)"/, `viewBox="0 0 ${width} ${target}"`)
      .replace(/(<svg[^>]*height=")(\d+)(")/, `$1${target}$3`);
    writeFileSync(file, next);
  }
  const after = measure(file);
  const overflow = after.bottom - target;
  if (overflow > 0) bad++;
  console.log(
    `${file.padEnd(28)} ${declared} -> ${target}  content bottom=${after.bottom}` +
      (overflow > 0 ? `  STILL OVERFLOWS by ${overflow}` : ""),
  );
}
process.exit(bad ? 1 : 0);
