/*
 * Guards the font picker.
 *
 * Canvas can only draw a face the browser has loaded. The stylesheet requests
 * specific weights and styles per family, and asking for anything else makes
 * canvas fall back to a generic serif -- which is indistinguishable from the
 * picker being broken. Every family in the picker had this problem except
 * Playfair Display.
 *
 * Run: node --test photo-booth/tests/fonts.test.js
 */
const test = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");

const SRC = fs.readFileSync(path.join(__dirname, "..", "index.html"), "utf8")
  .split("\r\n").join("\n");

// Families offered in the setup panel.
function pickerFamilies() {
  const seg = SRC.match(/<div class="seg" id="seg-font">([\s\S]*?)<\/div>/);
  assert.ok(seg, "font segment not found");
  return [...seg[1].matchAll(/data-val="([^"]+)"/g)].map((m) => m[1]);
}

// Families and weights the stylesheet actually requests, parsed from the
// Google Fonts URL: family=Name:ital,wght@0,500;1,600
function stylesheetFaces() {
  const link = SRC.match(/fonts\.googleapis\.com\/css2\?([^"]+)/);
  assert.ok(link, "Google Fonts link not found");
  const faces = {};
  for (const part of link[1].split("&")) {
    const m = part.match(/^family=([^:]+)(?::(.*))?$/);
    if (!m) continue;
    const name = decodeURIComponent(m[1].replace(/\+/g, " "));
    const weights = new Set();
    if (!m[2]) {
      weights.add(400); // no axis spec means regular 400 only
    } else {
      const spec = m[2];
      const axes = spec.split("@")[0].split(",");
      const tuples = (spec.split("@")[1] || "400").split(";");
      const wghtAt = axes.indexOf("wght");
      for (const t of tuples) {
        const parts = t.split(",");
        weights.add(wghtAt === -1 ? 400 : parseInt(parts[wghtAt], 10));
      }
    }
    faces[name] = weights;
  }
  return faces;
}

// The FONT_FACES table the renderer draws with.
function fontFacesTable() {
  const block = SRC.match(/var FONT_FACES = \{([\s\S]*?)\n  \};/);
  assert.ok(block, "FONT_FACES table not found");
  const table = {};
  for (const m of block[1].matchAll(
    /"([^"]+)":\s*\{\s*title:\s*(\d+),\s*venue:\s*(\d+),\s*italic:\s*(true|false)([^}]*)\}/g
  )) {
    table[m[1]] = {
      title: +m[2], venue: +m[3], italic: m[4] === "true",
      system: /system:\s*true/.test(m[5] || "")
    };
  }
  return table;
}

test("every family in the picker has a FONT_FACES entry", () => {
  const table = fontFacesTable();
  const missing = pickerFamilies().filter((f) => !table[f]);
  assert.deepStrictEqual(
    missing, [],
    "these are offered but have no declared face, so they fall back to a " +
    "generic serif: " + missing.join(", ")
  );
});

test("every FONT_FACES weight is actually loaded by the stylesheet", () => {
  const table = fontFacesTable();
  const sheet = stylesheetFaces();
  const problems = [];
  for (const [fam, face] of Object.entries(table)) {
    // Faces that ship with the OS are not downloaded, so the stylesheet has
    // nothing to say about them.
    if (face.system) continue;
    const loaded = sheet[fam];
    if (!loaded) { problems.push(fam + ": not requested in the stylesheet"); continue; }
    for (const [role, weight] of [["title", face.title], ["venue", face.venue]]) {
      if (!loaded.has(weight)) {
        problems.push(
          `${fam}: ${role} asks for ${weight} but only ${[...loaded].join("/")} is loaded`
        );
      }
    }
  }
  assert.deepStrictEqual(problems, [], "unloaded faces:\n  " + problems.join("\n  "));
});

test("the renderer draws through the face table, not fixed weights", () => {
  const body = SRC.match(/\n  function drawFooter\([^)]*\) \{[\s\S]*?\n  \}\n/);
  assert.ok(body, "drawFooter not found");
  assert.doesNotMatch(
    body[0], /"italic 600 "|"italic 500 "/,
    "drawFooter still hardcodes a weight; it must use fontFace(fam) so each " +
    "family draws with a face that was loaded"
  );
  assert.match(body[0], /face\.title/, "title should take its weight from the face");
  assert.match(
    body[0], /fontFace\(vfam\)\.venue/,
    "venue should look up the face for its own family, not the headline's"
  );
  assert.match(
    body[0], /fontFace\(dfam\)\.venue/,
    "date should look up the face for its own family"
  );
  assert.doesNotMatch(
    body[0], /px 'Jost'/,
    "the date font is configurable now; it must not be hardcoded to Jost"
  );
});

test("the preview waits for the font before its final draw", () => {
  const re = new RegExp("\\n  function renderStripPreview\\([^)]*\\) \\{[\\s\\S]*?\\n  \\}\\n");
  const body = SRC.match(re);
  assert.ok(body, "renderStripPreview not found");
  assert.match(
    body[0], /ensureFonts\(/,
    "renderStripPreview must preload the selected face itself; leaving it to " +
    "callers means any path that forgets renders in a fallback serif"
  );
  assert.match(body[0], /getSeg\("#seg-font"\)/, "it must use the family from the form");
});

test("ensureFonts loads both roles for the chosen family", () => {
  const body = SRC.match(/\n  function ensureFonts\([^)]*\) \{[\s\S]*?\n  \}\n/);
  assert.ok(body, "ensureFonts not found");
  assert.match(body[0], /face\.title/, "must load the title face");
  assert.match(body[0], /face\.venue/, "must load the venue face");
});

test("ensureFonts activates the face in the DOM, not just in the font set", () => {
  const body = SRC.match(/\n  function ensureFonts\([^)]*\) \{[\s\S]*?\n  \}\n/);
  assert.ok(body, "ensureFonts not found");
  // iOS Safari hands canvas a fallback unless the face has laid out real DOM
  // text, so a probe element and fonts.ready are both load bearing.
  assert.match(body[0], /font-probe/, "must set the off-screen probe element");
  assert.match(body[0], /document\.fonts\.ready/, "must wait for activation, not just the fetch");
});

test("the font probe stays in the layout", () => {
  // display:none skips font loading entirely, which defeats the probe.
  const css = SRC.match(/#font-probe \{([^}]*)\}/);
  assert.ok(css, "#font-probe rule not found");
  assert.doesNotMatch(css[1], /display:\s*none/, "display:none stops the face loading");
  assert.match(css[1], /position:\s*absolute/, "keep it off-screen but laid out");
  assert.match(SRC, /<span id="font-probe"/, "probe element missing from the page");
});

test("system faces carry their own fallback stack", () => {
  const table = fontFacesTable();
  const block = SRC.match(/var FONT_FACES = \{([\s\S]*?)\n  \};/)[1];
  for (const [fam, face] of Object.entries(table)) {
    if (!face.system) continue;
    const entry = block.split('"' + fam + '"')[1] || "";
    assert.match(
      entry.split("},")[0], /stack:/,
      fam + " is a system face and needs an explicit stack, or an iPad " +
      "without it falls back to a generic serif with no second choice"
    );
  }
});

test("the strip preview has enough resolution to show a border", () => {
  const m = SRC.match(/<canvas id="strip-preview" width="(\d+)" height="(\d+)">/);
  assert.ok(m, "preview canvas not found");
  const scale = 1200 / Number(m[1]);
  // A single border strokes at round(2.5 * 1200/700) = 4px on the real canvas.
  const bordered = 4 / scale;
  assert.ok(
    bordered >= 1.2,
    `border would render at ${bordered.toFixed(2)}px in the preview, which is ` +
    `invisible; raise the canvas resolution above ${m[1]}x${m[2]}`
  );
});
