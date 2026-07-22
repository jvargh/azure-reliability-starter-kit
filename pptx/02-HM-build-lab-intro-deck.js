// Build: Health Model Hands-On Lab customer intro deck (deck 02)
// Theme matches deck 01 (navy + teal). Light content slides, dark bookends.
const pptxgen = require("pptxgenjs");

const pres = new pptxgen();
pres.layout = "LAYOUT_WIDE"; // 13.33 x 7.5
const PW = 13.33, PH = 7.5;
pres.author = "Azure Reliability Starter Kit";
pres.title = "Azure Monitor Health Model Hands-On Lab";

// ---- Palette ----
const NAVY   = "0A2540";
const NAVY2  = "10314F";
const TEAL   = "2DD4BF";
const TEALDK = "0D9488";
const ICE    = "F4F7FB";
const WHITE  = "FFFFFF";
const INK    = "1E293B";
const MUTED  = "64748B";
const LINE   = "E2E8F0";
const AMBER  = "F59E0B";
const RED    = "E1495B";
const GREEN  = "3FB984";
const GRAY   = "94A3B8";
const CODEBG = "0B2137";

const HFONT = "Segoe UI Semibold";
const BFONT = "Segoe UI";
const MONO  = "Consolas";

const MX = 0.7; // left/right margin

const shadow = () => ({ type: "outer", color: "0A2540", blur: 9, offset: 3, angle: 90, opacity: 0.16 });

function lightHeader(slide, kicker, title) {
  slide.background = { color: ICE };
  slide.addShape(pres.shapes.RECTANGLE, { x: MX, y: 0.55, w: 0.16, h: 0.16, fill: { color: TEAL }, line: { type: "none" } });
  slide.addText(kicker.toUpperCase(), {
    x: MX + 0.28, y: 0.44, w: 10, h: 0.35, margin: 0,
    fontFace: BFONT, fontSize: 12, bold: true, color: TEALDK, charSpacing: 2, valign: "middle"
  });
  slide.addText(title, {
    x: MX, y: 0.82, w: PW - MX * 2, h: 0.9, margin: 0,
    fontFace: HFONT, fontSize: 30, bold: true, color: NAVY, valign: "middle"
  });
}

function footer(slide, n) {
  slide.addText("Azure Monitor  ·  Health Model Hands-On Lab", {
    x: MX, y: PH - 0.42, w: 7, h: 0.3, margin: 0,
    fontFace: BFONT, fontSize: 9, color: MUTED, valign: "middle"
  });
  slide.addText(String(n), {
    x: PW - MX - 0.6, y: PH - 0.42, w: 0.6, h: 0.3, margin: 0,
    fontFace: BFONT, fontSize: 9, color: MUTED, align: "right", valign: "middle"
  });
}

function badge(slide, x, y, num, color = TEAL, txtcol = NAVY, d = 0.5) {
  slide.addShape(pres.shapes.OVAL, { x, y, w: d, h: d, fill: { color }, line: { type: "none" } });
  slide.addText(String(num), { x, y, w: d, h: d, margin: 0, fontFace: HFONT, fontSize: 16, bold: true, color: txtcol, align: "center", valign: "middle" });
}

// =====================================================================
// SLIDE 1 — Title (dark)
// =====================================================================
{
  const s = pres.addSlide();
  s.background = { color: NAVY };
  s.addShape(pres.shapes.RECTANGLE, { x: 0, y: 0, w: 0.22, h: PH, fill: { color: TEAL }, line: { type: "none" } });
  s.addShape(pres.shapes.RECTANGLE, { x: PW - 3.2, y: PH - 3.2, w: 3.2, h: 3.2, fill: { color: NAVY2 }, line: { type: "none" } });
  s.addShape(pres.shapes.RECTANGLE, { x: PW - 2.0, y: PH - 2.0, w: 2.0, h: 2.0, fill: { color: TEALDK, transparency: 55 }, line: { type: "none" } });

  s.addText("AZURE MONITOR  ·  HANDS-ON LAB  ·  PART 2", {
    x: 1.0, y: 1.55, w: 11, h: 0.4, margin: 0,
    fontFace: BFONT, fontSize: 14, bold: true, color: TEAL, charSpacing: 3
  });
  s.addText("Health Models: one honest\nscore for the whole workload", {
    x: 0.95, y: 2.05, w: 11.4, h: 1.9, margin: 0,
    fontFace: HFONT, fontSize: 44, bold: true, color: WHITE, lineSpacingMultiple: 1.02
  });
  s.addText("Roll your SLIs and resource signals into one top-down health state, then drill straight to the failing component.", {
    x: 1.0, y: 4.05, w: 10.2, h: 0.8, margin: 0,
    fontFace: BFONT, fontSize: 17, color: "C7D6E5", lineSpacingMultiple: 1.15
  });

  const tags = ["Entities", "Signals", "Rollup", "State alerts"];
  let tx = 1.0;
  tags.forEach(t => {
    const w = 0.42 + t.length * 0.115;
    s.addShape(pres.shapes.ROUNDED_RECTANGLE, { x: tx, y: 5.15, w, h: 0.44, rectRadius: 0.08, fill: { color: NAVY2 }, line: { color: TEALDK, width: 1 } });
    s.addText(t, { x: tx, y: 5.15, w, h: 0.44, margin: 0, fontFace: BFONT, fontSize: 12, bold: true, color: TEAL, align: "center", valign: "middle" });
    tx += w + 0.25;
  });

  s.addText("Builds directly on the SLI/SLO lab (Part 1)  ·  for platform, SRE, and engineering teams", {
    x: 1.0, y: PH - 0.7, w: 11, h: 0.35, margin: 0, fontFace: BFONT, fontSize: 11, color: "7E93A8"
  });
  s.addNotes(
    "Welcome to Part 2. In Part 1 we authored SLIs; here we roll them up into a health model. Still hands-on, not a lecture.\n\n" +
    "The one-liner: instead of staring at hundreds of metrics, the whole workload gets a single health state that you can drill into to find the exact failing component.\n\n" +
    "Key framing: a health model does not replace SLIs, it consumes them, so reliability and health agree on the same numbers. Prereq is the SLI demo from Part 1 being in place."
  );
}

// =====================================================================
// SLIDE 2 — Concept: Why health models
// =====================================================================
{
  const s = pres.addSlide();
  lightHeader(s, "Concept  ·  1 of 3", "Why a health model, not just more alerts?");
  s.addText("Alert-based monitoring tells you a metric crossed a line. A health model tells you the state of the whole workload and what is causing it.", {
    x: MX, y: 1.7, w: PW - MX * 2, h: 0.5, margin: 0, fontFace: BFONT, fontSize: 15, color: MUTED
  });

  const cardY = 2.45, cardH = 3.45, cardW = (PW - MX * 2 - 0.5) / 2;
  s.addShape(pres.shapes.RECTANGLE, { x: MX, y: cardY, w: cardW, h: cardH, fill: { color: WHITE }, line: { color: LINE, width: 1 }, shadow: shadow() });
  s.addShape(pres.shapes.RECTANGLE, { x: MX, y: cardY, w: cardW, h: 0.12, fill: { color: MUTED }, line: { type: "none" } });
  s.addText("ALERT-BASED MONITORING", { x: MX + 0.35, y: cardY + 0.35, w: cardW - 0.7, h: 0.4, margin: 0, fontFace: HFONT, fontSize: 14, bold: true, color: INK, charSpacing: 1 });
  s.addText([
    { text: "Noisy: one incident fires ten alerts", options: { bullet: { indent: 16 }, breakLine: true, paraSpaceAfter: 8 } },
    { text: "Local: each alert knows nothing of the others", options: { bullet: { indent: 16 }, breakLine: true, paraSpaceAfter: 8 } },
    { text: "Stateless: nothing says \u201Cthe workload is unhealthy\u201D", options: { bullet: { indent: 16 }, breakLine: true, paraSpaceAfter: 8 } },
    { text: "No sense of blast radius", options: { bullet: { indent: 16 } } }
  ], { x: MX + 0.35, y: cardY + 0.95, w: cardW - 0.7, h: cardH - 1.3, margin: 0, fontFace: BFONT, fontSize: 14.5, color: INK, lineSpacingMultiple: 1.05 });

  const rx = MX + cardW + 0.5;
  s.addShape(pres.shapes.RECTANGLE, { x: rx, y: cardY, w: cardW, h: cardH, fill: { color: NAVY }, line: { type: "none" }, shadow: shadow() });
  s.addShape(pres.shapes.RECTANGLE, { x: rx, y: cardY, w: cardW, h: 0.12, fill: { color: TEAL }, line: { type: "none" } });
  s.addText("HEALTH MODEL", { x: rx + 0.35, y: cardY + 0.35, w: cardW - 0.7, h: 0.4, margin: 0, fontFace: HFONT, fontSize: 14, bold: true, color: TEAL, charSpacing: 1 });
  s.addText([
    { text: "One health state for the whole workload", options: { bullet: { indent: 16 }, breakLine: true, paraSpaceAfter: 8 } },
    { text: "Shows which component is causing it", options: { bullet: { indent: 16 }, breakLine: true, paraSpaceAfter: 8 } },
    { text: "Rolls state up along dependencies", options: { bullet: { indent: 16 }, breakLine: true, paraSpaceAfter: 8 } },
    { text: "One state-change alert replaces many noisy ones", options: { bullet: { indent: 16 } } }
  ], { x: rx + 0.35, y: cardY + 0.95, w: cardW - 0.7, h: cardH - 1.3, margin: 0, fontFace: BFONT, fontSize: 14.5, color: "E5EEF6", lineSpacingMultiple: 1.05 });

  s.addNotes(
    "Spend a minute here, this is the reason health models exist.\n\n" +
    "Left: alert-based monitoring is noisy (ten alerts per incident), local (no alert knows about the others), and stateless (nowhere says the workload as a whole is unhealthy).\n\n" +
    "Right: a health model adds business context. It gives the whole workload one state, points at the component causing it, and rolls that state up along dependencies so you see the blast radius. One state-change alert replaces a pile of metric alerts.\n\n" +
    "Room question: during your last incident, how many alerts fired for one root cause? That noise is what we are collapsing."
  );
  footer(s, 2);
}

// =====================================================================
// SLIDE 3 — Concept: layered mental model + four states
// =====================================================================
{
  const s = pres.addSlide();
  lightHeader(s, "Concept  ·  2 of 3", "Six layers, and four health states");

  // Left: six layers stacked
  const lx = MX, lw = 6.7, ly = 2.1;
  const layers = [
    ["Entity", "a thing whose health you care about"],
    ["Signal", "one measurement compared to thresholds"],
    ["Health state", "Healthy / Degraded / Unhealthy / Unknown"],
    ["Relationship", "\u201CA depends on B\u201D edges"],
    ["Rollup", "parent state from its signals + children"],
    ["Alert", "fire when an entity changes state"]
  ];
  const rowH = 0.62, rGap = 0.11;
  layers.forEach((l, i) => {
    const y = ly + i * (rowH + rGap);
    s.addShape(pres.shapes.ROUNDED_RECTANGLE, { x: lx, y, w: lw, h: rowH, rectRadius: 0.05, fill: { color: WHITE }, line: { color: LINE, width: 1 } });
    badge(s, lx + 0.12, y + (rowH - 0.42) / 2, i + 1, i === 5 ? AMBER : TEAL, NAVY, 0.42);
    s.addText([
      { text: l[0] + "   ", options: { bold: true, color: NAVY, fontFace: HFONT } },
      { text: l[1], options: { color: MUTED } }
    ], { x: lx + 0.7, y, w: lw - 0.85, h: rowH, margin: 0, fontFace: BFONT, fontSize: 12.5, valign: "middle" });
  });
  s.addText("Each layer builds on the one before it.", {
    x: lx, y: ly + 6 * (rowH + rGap) + 0.02, w: lw, h: 0.3, margin: 0, fontFace: BFONT, fontSize: 11, italic: true, color: MUTED
  });

  // Right: four states card
  const rx = MX + lw + 0.6, rw = PW - MX - (MX + lw + 0.6);
  s.addShape(pres.shapes.RECTANGLE, { x: rx, y: ly, w: rw, h: 4.35, fill: { color: NAVY }, line: { type: "none" }, shadow: shadow() });
  s.addText("FOUR HEALTH STATES", { x: rx + 0.35, y: ly + 0.28, w: rw - 0.7, h: 0.35, margin: 0, fontFace: HFONT, fontSize: 13, bold: true, color: TEAL, charSpacing: 1 });
  const states = [
    ["Healthy", "all signals within thresholds", GREEN],
    ["Degraded", "past the degraded threshold", AMBER],
    ["Unhealthy", "past the unhealthy threshold", RED],
    ["Unknown", "no data (for example no traffic)", GRAY]
  ];
  let sy = ly + 0.85;
  states.forEach(st => {
    s.addShape(pres.shapes.OVAL, { x: rx + 0.4, y: sy + 0.08, w: 0.26, h: 0.26, fill: { color: st[2] }, line: { type: "none" } });
    s.addText(st[0], { x: rx + 0.85, y: sy - 0.03, w: rw - 1.1, h: 0.32, margin: 0, fontFace: HFONT, fontSize: 15, bold: true, color: WHITE });
    s.addText(st[1], { x: rx + 0.85, y: sy + 0.3, w: rw - 1.1, h: 0.3, margin: 0, fontFace: BFONT, fontSize: 11.5, color: "C7D6E5" });
    sy += 0.82;
  });

  s.addNotes(
    "Two things to land on this slide: the vocabulary stack and the states.\n\n" +
    "Read the six layers bottom to top of the pyramid of ideas: an Entity is a thing you care about; a Signal measures it against thresholds; those resolve to a Health state; Relationships connect entities; Rollup combines a parent with its children; and an Alert fires on a state change, not a single metric.\n\n" +
    "On the right, the four states are simple traffic lights: Healthy, Degraded, Unhealthy, and Unknown. Call out Unknown specifically: it means no data, which in this demo usually means traffic stopped. An entity's state is the worst of its own signals and whatever rolls up from its children."
  );
  footer(s, 3);
}

// =====================================================================
// SLIDE 4 — Concept: the scenario (Checkout/Login model)
// =====================================================================
{
  const s = pres.addSlide();
  lightHeader(s, "Concept  ·  3 of 3", "The scenario: a model for Checkout & Login");
  s.addText("The same online store from Part 1, now represented as a health model built by discovery and driven by your existing SLIs.", {
    x: MX, y: 1.7, w: PW - MX * 2, h: 0.5, margin: 0, fontFace: BFONT, fontSize: 15, color: MUTED
  });

  const items = [
    ["Discover entities", "App Insights topology", "Import Login (frontend) and Checkout (backend) as entities, with dependency edges and recommended signals."],
    ["Tap your SLIs", "Azure Monitor Workspace", "PromQL signals read the same AMW: Checkout availability % and Login p95 latency."],
    ["Roll up & alert", "State-based", "Combine signals into one health state; alert on Degraded (Sev2) and Unhealthy (Sev1)."]
  ];
  const n = 3, gap = 0.4;
  const cardW = (PW - MX * 2 - gap * (n - 1)) / n;
  const cardY = 2.5, cardH = 2.85;
  items.forEach((it, i) => {
    const x = MX + i * (cardW + gap);
    s.addShape(pres.shapes.RECTANGLE, { x, y: cardY, w: cardW, h: cardH, fill: { color: WHITE }, line: { color: LINE, width: 1 }, shadow: shadow() });
    s.addShape(pres.shapes.RECTANGLE, { x, y: cardY, w: 0.12, h: cardH, fill: { color: TEAL }, line: { type: "none" } });
    s.addText(it[0], { x: x + 0.35, y: cardY + 0.3, w: cardW - 0.6, h: 0.4, margin: 0, fontFace: HFONT, fontSize: 17, bold: true, color: NAVY });
    s.addText(it[1].toUpperCase(), { x: x + 0.35, y: cardY + 0.78, w: cardW - 0.6, h: 0.35, margin: 0, fontFace: BFONT, fontSize: 10.5, bold: true, color: TEALDK, charSpacing: 1 });
    s.addText(it[2], { x: x + 0.35, y: cardY + 1.2, w: cardW - 0.65, h: cardH - 1.4, margin: 0, fontFace: BFONT, fontSize: 12.5, color: INK, lineSpacingMultiple: 1.12, valign: "top" });
  });

  const by = cardY + cardH + 0.35;
  s.addShape(pres.shapes.ROUNDED_RECTANGLE, { x: MX, y: by, w: PW - MX * 2, h: 0.78, rectRadius: 0.08, fill: { color: NAVY }, line: { type: "none" } });
  s.addText([
    { text: "Consumes your SLIs  ", options: { fontFace: HFONT, bold: true, color: TEAL } },
    { text: "the model taps the same Azure Monitor Workspace, so health and reliability agree on the same numbers.", options: { color: "E5EEF6" } }
  ], { x: MX + 0.4, y: by, w: PW - MX * 2 - 0.8, h: 0.78, margin: 0, fontFace: BFONT, fontSize: 13.5, valign: "middle" });

  s.addNotes(
    "Concrete scenario, same app as Part 1 so it is familiar.\n\n" +
    "Three moves, left to right. First, discovery: point an Application Insights topology discovery at the Part 1 app and it imports Login and Checkout as entities, draws the dependency edges, and adds recommended signals automatically. Second, tap the SLIs: attach PromQL signals that read the same Azure Monitor Workspace, Checkout availability and Login p95 latency. Third, roll up and alert on state: Degraded is Sev2, Unhealthy is Sev1.\n\n" +
    "The bottom bar is the headline: because it consumes the same workspace the SLIs write to, the health model and the SLIs never disagree on the numbers."
  );
  footer(s, 4);
}

// =====================================================================
// SLIDE 5 — Contents (one slide)
// =====================================================================
{
  const s = pres.addSlide();
  lightHeader(s, "Contents", "What is in the hands-on lab");

  const lx = MX, lw = 4.7, ly = 2.0;
  const groups = [
    ["Health model + identity", "A Microsoft.CloudHealth model in its own RG, with a system-assigned managed identity and Monitoring Reader on the app."],
    ["App Insights discovery", "Topology discovery imports the Login and Checkout components as entities with relationships."],
    ["SLI-driven signals", "AMW PromQL signals map each SLI value onto the right App Service entity."],
    ["State-based alerts", "Degraded (Sev2) and Unhealthy (Sev1) health-state alerts on the app entities."]
  ];
  let gy = ly;
  groups.forEach((g, i) => {
    badge(s, lx, gy, i + 1, TEAL, NAVY, 0.42);
    s.addText(g[0], { x: lx + 0.6, y: gy - 0.04, w: lw - 0.6, h: 0.35, margin: 0, fontFace: HFONT, fontSize: 14.5, bold: true, color: NAVY });
    s.addText(g[1], { x: lx + 0.6, y: gy + 0.32, w: lw - 0.6, h: 0.75, margin: 0, fontFace: BFONT, fontSize: 11.5, color: MUTED, lineSpacingMultiple: 1.08 });
    gy += 1.15;
  });

  const rx = MX + lw + 0.6;
  const rw = PW - MX - rx;
  s.addShape(pres.shapes.RECTANGLE, { x: rx, y: ly, w: rw, h: 4.75, fill: { color: WHITE }, line: { color: LINE, width: 1 }, shadow: shadow() });
  s.addText("HOW THE MODEL COMES TOGETHER", { x: rx + 0.35, y: ly + 0.28, w: rw - 0.7, h: 0.35, margin: 0, fontFace: HFONT, fontSize: 12, bold: true, color: TEALDK, charSpacing: 1 });

  const flow = [
    ["App Insights topology", "discovers the components"],
    ["Entities: Login + Checkout", "with dependency relationships"],
    ["AMW PromQL signals", "SLI value per entity"],
    ["Health-state rollup", "worst-of signals + children"],
    ["State-change alerts", "Degraded Sev2 / Unhealthy Sev1"]
  ];
  const fx = rx + 0.4, fw = rw - 0.8;
  let fy = ly + 0.8;
  const fh = 0.58, fgap = 0.24;
  flow.forEach((f, i) => {
    const dark = i === flow.length - 1;
    s.addShape(pres.shapes.ROUNDED_RECTANGLE, { x: fx, y: fy, w: fw, h: fh, rectRadius: 0.06, fill: { color: dark ? NAVY : ICE }, line: { color: dark ? NAVY : LINE, width: 1 } });
    s.addText([
      { text: f[0] + "   ", options: { bold: true, color: dark ? TEAL : NAVY, fontFace: HFONT } },
      { text: f[1], options: { color: dark ? "C7D6E5" : MUTED } }
    ], { x: fx + 0.25, y: fy, w: fw - 0.4, h: fh, margin: 0, fontFace: BFONT, fontSize: 12, valign: "middle" });
    if (i < flow.length - 1) {
      s.addText("\u25BC", { x: fx + fw / 2 - 0.15, y: fy + fh - 0.02, w: 0.3, h: fgap, margin: 0, fontFace: BFONT, fontSize: 10, color: TEALDK, align: "center", valign: "middle" });
    }
    fy += fh + fgap;
  });

  s.addNotes(
    "What the kit actually deploys, so people know the moving parts.\n\n" +
    "Left, four things: the health model plus a system-assigned identity with Monitoring Reader on the app RG; the Application Insights topology discovery; the SLI-driven PromQL signals; and the state-based alerts. Note the model lives in its own resource group and references the app across resource groups.\n\n" +
    "Right shows the assembly line: topology discovery finds the components, they become Login and Checkout entities with relationships, PromQL signals attach the SLI value to each, health rolls up worst-of, and state changes fire alerts. One callout: the model region is limited to the CloudHealth regions (default centralus); the app itself can live anywhere."
  );
  footer(s, 5);
}

// =====================================================================
// SLIDE 6 — Run steps: quickstart
// =====================================================================
{
  const s = pres.addSlide();
  lightHeader(s, "Run the lab  ·  Quickstart", "One prerequisite, then one command");

  const steps = [
    ["Have Part 1 in place", "The SLI demo deployed and its SLIs authored (skip if you did Part 1).", "./infra/infra-deploy.ps1 `\n  -ResourceGroup rg-sli-demo\n./infra/sli/deploy-sli.ps1 `\n  -ResourceGroup rg-sli-demo"],
    ["Keep traffic running  (Terminal 1)", "SLI :value series must be fresh or signals read Unknown.", "pwsh -File load/generate-traffic-all.ps1 `\n  -ResourceGroup rg-sli-demo `\n  -Rps 30 -DurationSeconds 1800"],
    ["Run the lab  (Terminal 2)", "Walks phases 1-6: create model, discover, map SLIs, alert.", "cd 02-healthmodel-demo\n./healthmodel-run-lab.ps1"]
  ];
  const n = 3, gap = 0.4;
  const cardW = (PW - MX * 2 - gap * (n - 1)) / n;
  const cardY = 2.1, cardH = 4.2;
  steps.forEach((st, i) => {
    const x = MX + i * (cardW + gap);
    s.addShape(pres.shapes.RECTANGLE, { x, y: cardY, w: cardW, h: cardH, fill: { color: WHITE }, line: { color: LINE, width: 1 }, shadow: shadow() });
    badge(s, x + 0.35, cardY + 0.35, i + 1, NAVY, TEAL, 0.5);
    s.addText(st[0], { x: x + 1.0, y: cardY + 0.35, w: cardW - 1.2, h: 0.55, margin: 0, fontFace: HFONT, fontSize: 14.5, bold: true, color: NAVY, valign: "middle" });
    s.addText(st[1], { x: x + 0.35, y: cardY + 1.05, w: cardW - 0.7, h: 0.9, margin: 0, fontFace: BFONT, fontSize: 12, color: MUTED, lineSpacingMultiple: 1.1 });
    const codeY = cardY + 2.05, codeH = cardH - 2.05 - 0.3;
    s.addShape(pres.shapes.ROUNDED_RECTANGLE, { x: x + 0.3, y: codeY, w: cardW - 0.6, h: codeH, rectRadius: 0.05, fill: { color: CODEBG }, line: { type: "none" } });
    s.addText(st[2], { x: x + 0.5, y: codeY + 0.12, w: cardW - 1.0, h: codeH - 0.24, margin: 0, fontFace: MONO, fontSize: 10.5, color: TEAL, valign: "top", lineSpacingMultiple: 1.15 });
  });

  s.addText("Prerequisites: Azure CLI signed in, PowerShell 7+, Contributor on the subscription. Health model region defaults to centralus (Microsoft.CloudHealth is region-limited).", {
    x: MX, y: cardY + cardH + 0.15, w: PW - MX * 2, h: 0.35, margin: 0, fontFace: BFONT, fontSize: 11.5, italic: true, color: MUTED
  });

  s.addNotes(
    "Reassure them it is short: one prerequisite and essentially one command.\n\n" +
    "One: Part 1 must be in place, the SLI demo deployed and SLIs authored. If they did Part 1 in this environment, they skip straight to step two.\n\n" +
    "Two: keep the traffic generator running in its own terminal. Stress this: the health signals read the SLI :value series, so if traffic stops the series go stale and signals show Unknown.\n\n" +
    "Three: run healthmodel-run-lab.ps1, which walks all six phases. Interactive runs pause and confirm before the two write steps. Mention the region note: the model itself must be in a CloudHealth region (default centralus), independent of where the app lives."
  );
  footer(s, 6);
}

// =====================================================================
// SLIDE 7 — Run steps: the 6 phases
// =====================================================================
{
  const s = pres.addSlide();
  lightHeader(s, "Run the lab  ·  What healthmodel-run-lab.ps1 does", "The six-phase build");

  const phases = [
    ["Environment setup & access checks", "Discovers the app, workspace, and SLIs; confirms the SLI series carry recent data."],
    ["Create the health model", "Creates the model and its managed identity (idempotent deploy script)."],
    ["Discover the app as entities", "Verifies the App Insights topology imported Login and Checkout."],
    ["Map the SLIs to entities", "Derives each mapping from the SLI label; writes the entity-map CSV."],
    ["Configure signals + alerts", "Attaches AMW PromQL signals and Degraded / Unhealthy state alerts."],
    ["Validate end to end", "Confirms entities, signals, and alerts are wired and reporting."]
  ];
  const colGap = 0.6;
  const colW = (PW - MX * 2 - colGap) / 2;
  const y0 = 2.15, rowH = 1.45;
  phases.forEach((p, i) => {
    const col = Math.floor(i / 3);
    const row = i % 3;
    const x = MX + col * (colW + colGap);
    const y = y0 + row * rowH;
    badge(s, x, y, i + 1, i < 4 ? TEAL : AMBER, NAVY, 0.46);
    s.addText(p[0], { x: x + 0.62, y: y - 0.05, w: colW - 0.62, h: 0.34, margin: 0, fontFace: HFONT, fontSize: 14.5, bold: true, color: NAVY });
    s.addText(p[1], { x: x + 0.62, y: y + 0.32, w: colW - 0.62, h: 0.7, margin: 0, fontFace: BFONT, fontSize: 11.5, color: MUTED, lineSpacingMultiple: 1.06 });
  });

  s.addNotes(
    "This is what the runner does, and it mirrors how you would build a health model for any workload.\n\n" +
    "Phases 1 to 4 (teal) are setup and modelling: check access and that the SLI series are live, create the model and its identity, verify discovery imported the entities, and map each SLI to the right App Service entity, derived automatically from the SLI label, no manual table.\n\n" +
    "Phases 5 and 6 (amber) are the wiring and proof: attach the PromQL signals and the state alerts, then validate everything is reporting.\n\n" +
    "Point to make: the runner is idempotent and phase-scoped, so you can re-run just the mapping or just validation without rebuilding."
  );
  footer(s, 7);
}

// =====================================================================
// SLIDE 8 — What follows: roadmap (Phase 1 highlighted)
// =====================================================================
{
  const s = pres.addSlide();
  lightHeader(s, "What follows", "Where this sits on the reliability journey");
  s.addText("The health model is Phase 1. It reuses the SLI foundation and becomes the focus for AI-assisted operations next.", {
    x: MX, y: 1.7, w: PW - MX * 2, h: 0.5, margin: 0, fontFace: BFONT, fontSize: 15, color: MUTED
  });

  const phases = [
    ["PHASE 0", "SLI foundation", "SLIs, SLOs, error budgets and burn alerts on a Service Group.", "PART 1", false],
    ["PHASE 1", "Health Models", "Roll SLIs + resource health into one honest, top-down health score.", "THIS LAB", true],
    ["PHASE 2", "AI operations", "Observability Agent explains incidents; SRE Agent takes approved action.", "NEXT", false],
    ["PHASE 3", "Operating model", "Error budgets gate releases: ship when healthy, stabilize when burning.", "GOAL", false]
  ];
  const n = 4, gap = 0.38;
  const cardW = (PW - MX * 2 - gap * (n - 1)) / n;
  const cardY = 2.5, cardH = 3.5;
  phases.forEach((p, i) => {
    const x = MX + i * (cardW + gap);
    const hl = p[4];
    s.addShape(pres.shapes.RECTANGLE, { x, y: cardY, w: cardW, h: cardH, fill: { color: hl ? NAVY : WHITE }, line: { color: hl ? NAVY : LINE, width: 1 }, shadow: shadow() });
    s.addText(p[0], { x: x + 0.3, y: cardY + 0.3, w: cardW - 0.6, h: 0.3, margin: 0, fontFace: BFONT, fontSize: 11, bold: true, color: hl ? TEAL : TEALDK, charSpacing: 1 });
    s.addText(p[1], { x: x + 0.3, y: cardY + 0.65, w: cardW - 0.6, h: 0.6, margin: 0, fontFace: HFONT, fontSize: 17, bold: true, color: hl ? WHITE : NAVY });
    s.addText(p[2], { x: x + 0.3, y: cardY + 1.35, w: cardW - 0.6, h: 1.6, margin: 0, fontFace: BFONT, fontSize: 12, color: hl ? "C7D6E5" : INK, lineSpacingMultiple: 1.12, valign: "top" });
    const pillW = 0.4 + p[3].length * 0.085;
    s.addShape(pres.shapes.ROUNDED_RECTANGLE, { x: x + 0.3, y: cardY + cardH - 0.65, w: pillW, h: 0.36, rectRadius: 0.07, fill: { color: hl ? TEAL : ICE }, line: { color: hl ? TEAL : LINE, width: 1 } });
    s.addText(p[3], { x: x + 0.3, y: cardY + cardH - 0.65, w: pillW, h: 0.36, margin: 0, fontFace: BFONT, fontSize: 9, bold: true, color: hl ? NAVY : MUTED, align: "center", valign: "middle", charSpacing: 1 });
    if (i < n - 1) {
      s.addText("\u2192", { x: x + cardW - 0.02, y: cardY + cardH / 2 - 0.25, w: gap + 0.04, h: 0.5, margin: 0, fontFace: BFONT, fontSize: 20, bold: true, color: TEALDK, align: "center", valign: "middle" });
    }
  });

  s.addNotes(
    "Place this lab on the bigger journey so it does not feel like a one-off.\n\n" +
    "Phase 0 was Part 1: the SLI foundation. Phase 1, highlighted, is what you build today: the health model that rolls those SLIs plus resource health into one honest score and lets you drill to the failing entity.\n\n" +
    "Phase 2 is where AI comes in: the Observability Agent explains what broke and why, and the SRE Agent takes approved action, with the health model focusing them. Phase 3 is the operating model, where error budgets gate releases.\n\n" +
    "The through-line: every phase reuses the previous one with no rework. The health model you build now is exactly what the agents reason over next."
  );
  footer(s, 8);
}

// =====================================================================
// SLIDE 9 — Closing (dark)
// =====================================================================
{
  const s = pres.addSlide();
  s.background = { color: NAVY };
  s.addShape(pres.shapes.RECTANGLE, { x: 0, y: 0, w: 0.22, h: PH, fill: { color: TEAL }, line: { type: "none" } });

  s.addText("TAKEAWAYS", { x: 1.0, y: 0.95, w: 10, h: 0.4, margin: 0, fontFace: BFONT, fontSize: 14, bold: true, color: TEAL, charSpacing: 3 });
  s.addText("You will leave the lab able to\u2026", { x: 0.95, y: 1.35, w: 11, h: 0.8, margin: 0, fontFace: HFONT, fontSize: 32, bold: true, color: WHITE });

  const points = [
    ["Build a real health model", "Discover entities from App Insights and attach SLI-driven signals."],
    ["See one honest score", "Roll signals and children up into a single state, then drill to the failing entity."],
    ["Alert on state, not noise", "Degraded and Unhealthy alerts replace piles of single-metric alerts."]
  ];
  const n = 3, gap = 0.5;
  const cardW = (PW - 2.0 - gap * (n - 1)) / n;
  const cy = 2.7, ch = 2.4;
  points.forEach((p, i) => {
    const x = 1.0 + i * (cardW + gap);
    s.addShape(pres.shapes.RECTANGLE, { x, y: cy, w: cardW, h: ch, fill: { color: NAVY2 }, line: { color: TEALDK, width: 1 } });
    badge(s, x + 0.3, cy + 0.3, i + 1, TEAL, NAVY, 0.46);
    s.addText(p[0], { x: x + 0.3, y: cy + 0.95, w: cardW - 0.6, h: 0.5, margin: 0, fontFace: HFONT, fontSize: 16, bold: true, color: WHITE });
    s.addText(p[1], { x: x + 0.3, y: cy + 1.45, w: cardW - 0.6, h: 0.85, margin: 0, fontFace: BFONT, fontSize: 12, color: "C7D6E5", lineSpacingMultiple: 1.1, valign: "top" });
  });

  s.addShape(pres.shapes.ROUNDED_RECTANGLE, { x: 1.0, y: cy + ch + 0.4, w: PW - 2.0, h: 0.75, rectRadius: 0.08, fill: { color: TEAL }, line: { type: "none" } });
  s.addText([
    { text: "Ready to start?   ", options: { bold: true, color: NAVY, fontFace: HFONT } },
    { text: "Keep traffic running, then run  ./healthmodel-run-lab.ps1", options: { color: "07314A", fontFace: MONO } }
  ], { x: 1.0, y: cy + ch + 0.4, w: PW - 2.0, h: 0.75, margin: 0, fontSize: 15, align: "center", valign: "middle" });

  s.addNotes(
    "Recap the three outcomes: you will have built a real health model by discovering entities and attaching SLI-driven signals; you will see one honest health score that rolls up and drills down to the failing component; and you will alert on state changes instead of metric noise.\n\n" +
    "Call to action: make sure traffic is running, then run healthmodel-run-lab.ps1.\n\n" +
    "Then hand off: open your terminals and start. Offer to stay on for questions, and tease Part 3, the AI operations lab, as the natural next step."
  );
}

pres.writeFile({ fileName: "02-HealthModel-Lab-Intro.pptx" }).then(f => console.log("WROTE", f));
