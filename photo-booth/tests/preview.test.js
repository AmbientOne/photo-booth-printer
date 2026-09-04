/*
 * Guards against the recurring bug where a new setting changes nothing in the
 * setup preview.
 *
 * The setup panel previews the strip from the live form, not from saved
 * settings. Two rules make that work, and both have been broken by accident --
 * once for the date colour, once for the font:
 *
 *   1. Rendering code must not read CONFIG directly. CONFIG only changes when
 *      settings are saved, so a control changed in the panel appears dead.
 *      Read through ftext() / fconf(), which consult the preview override.
 *
 *   2. Every key those helpers resolve must be supplied by previewText, or the
 *      override silently falls through to the saved value.
 *
 * Run: node --test photo-booth/tests/preview.test.js
 */
const test = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");

// Normalise line endings: git checks out CRLF on Windows, and the function
// patterns below anchor on a closing brace at the start of a line.
const SRC = fs.readFileSync(path.join(__dirname, "..", "index.html"), "utf8")
  .split("\r\n").join("\n");

function fnBody(name) {
  const re = new RegExp("\\n  function " + name + "\\([^)]*\\) \\{[\\s\\S]*?\\n  \\}\\n");
  const m = SRC.match(re);
  assert.ok(m, "function not found in index.html: " + name);
  return m[0];
}

// Everything that contributes to the printed image.
const RENDER_FNS = [
  "drawFooter", "drawLogo", "drawOverlay", "drawPhoto", "drawCover",
  "renderStrip", "renderGrid", "stripDesign", "placeholderShots",
  "designFromForm", "renderStripPreview"
];

// ensureFonts is excluded on purpose: it takes an explicit family override for
// the preview and consults CONFIG only for the real capture path.
const ALLOWED_DIRECT_CONFIG = {};

test("no rendering function reads CONFIG directly", () => {
  const offenders = [];
  for (const name of RENDER_FNS) {
    const allowed = ALLOWED_DIRECT_CONFIG[name] || [];
    const hits = (fnBody(name).match(/CONFIG\.[A-Za-z_$][A-Za-z0-9_$]*/g) || [])
      .filter((h) => !allowed.includes(h));
    if (hits.length) offenders.push(name + ": " + [...new Set(hits)].join(", "));
  }
  assert.deepStrictEqual(
    offenders, [],
    "these read saved settings instead of the preview override, so the setup " +
    "preview will not respond to them:\n  " + offenders.join("\n  ")
  );
});

test("every previewed setting is supplied by previewText", () => {
  // Keys the renderer resolves through the preview-aware helpers.
  const used = new Set(
    [...SRC.matchAll(/\b(?:ftext|fconf)\("([A-Za-z0-9_]+)"\)/g)].map((m) => m[1])
  );
  assert.ok(used.size > 0, "found no ftext/fconf calls; were the helpers renamed?");

  // Keys the setup preview actually overrides.
  const block = SRC.match(/previewText = \{([\s\S]*?)\};/);
  assert.ok(block, "previewText assignment not found in renderStripPreview");
  const supplied = new Set(
    [...block[1].matchAll(/^\s*([A-Za-z0-9_]+)\s*:/gm)].map((m) => m[1])
  );

  const missing = [...used].filter((k) => !supplied.has(k)).sort();
  assert.deepStrictEqual(
    missing, [],
    "the renderer reads these but the preview does not override them, so " +
    "changing them in setup does nothing until saved: " + missing.join(", ")
  );
});

test("the preview-aware helpers still exist", () => {
  assert.match(SRC, /function ftext\(key\)/, "ftext is gone");
  assert.match(SRC, /function fconf\(key\)/, "fconf is gone");
});

test("the font picker loads the chosen face before rendering", () => {
  // Rendering before the webfont has loaded silently falls back to a generic
  // serif, which is indistinguishable from the picker not working.
  const seg = SRC.match(/\$\(id\)\.addEventListener\("click", function \(e\) \{[\s\S]*?\n  \}\);/);
  assert.ok(seg, "segment click handler not found");
  assert.match(
    seg[0], /ensureFonts\(renderStripPreview, getSeg\("#seg-font"\)\)/,
    "the segment handler must render through ensureFonts with the selected " +
    "family, or a newly chosen font renders as a fallback face"
  );
});
