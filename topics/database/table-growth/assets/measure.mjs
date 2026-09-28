// Measure the drawn extent of each SVG, so a diagram's canvas height can be set
// from what it actually contains instead of from hand arithmetic.
//
//   node measure.mjs            # prints id -> content height for every diagram
//
// It renders each file in headless Chrome and reports the union bounding box of
// everything the SVG draws, plus the declared viewBox and height attributes.
import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, basename } from "node:path";
import { globSync } from "node:fs";

const CHROME =
  process.env.CHROME || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";

const files = process.argv.slice(2).length
  ? process.argv.slice(2)
  : globSync("*.svg").sort();

const dir = mkdtempSync(join(tmpdir(), "svg-measure-"));
const rows = [];

for (const file of files) {
  const svg = readFileSync(file, "utf8");
  const declared = {
    viewBox: /viewBox="([^"]+)"/.exec(svg)?.[1],
    height: Number(/<svg[^>]*height="(\d+)"/.exec(svg)?.[1]),
  };
  const page = join(dir, `${basename(file)}.html`);
  writeFileSync(
    page,
    `<!doctype html><meta charset="utf-8"><body style="margin:0">
${svg}
<script>
  const svg = document.querySelector("svg");
  const bb = svg.getBBox();
  document.title = JSON.stringify({
    y: Math.round(bb.y), bottom: Math.round(bb.y + bb.height),
    x: Math.round(bb.x), right: Math.round(bb.x + bb.width),
  });
</script>`,
  );
  const dom = execFileSync(
    CHROME,
    ["--headless", "--disable-gpu", "--dump-dom", "--virtual-time-budget=3000",
      `file://${page}`],
    { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] },
  );
  const m = /<title>([^<]+)<\/title>/.exec(dom);
  const box = m ? JSON.parse(m[1].replace(/&quot;/g, '"').replace(/&amp;/g, "&")) : null;
  rows.push({ file, ...declared, ...box });
}

let worst = 0;
for (const r of rows) {
  const overflow = r.bottom - r.height;
  worst = Math.max(worst, overflow);
  console.log(
    `${r.file.padEnd(28)} viewBox=${r.viewBox.padEnd(14)} height=${String(r.height).padEnd(5)}` +
      ` content bottom=${String(r.bottom).padEnd(5)} right=${String(r.right).padEnd(5)}` +
      (overflow > 0 ? `  OVERFLOW by ${overflow}` : "  fits"),
  );
}
process.exit(worst > 0 ? 1 : 0);
