// Build: SLI/SLO Hands-On Lab customer intro deck
// Theme: dark navy + teal accent (Azure reliability). Light content slides, dark bookends.
const pptxgen = require("pptxgenjs");

const pres = new pptxgen();
pres.layout = "LAYOUT_WIDE"; // 13.33 x 7.5
const PW = 13.33, PH = 7.5;
pres.author = "Azure Reliability Starter Kit";
pres.title = "Azure Monitor SLI/SLO Hands-On Lab";

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
const CODEBG = "0B2137";

const HFONT = "Segoe UI Semibold";
const BFONT = "Segoe UI";
const MONO  = "Consolas";

const MX = 0.7; // left/right margin

const shadow = () => ({ type: "outer", color: "0A2540", blur: 9, offset: 3, angle: 90, opacity: 0.16 });

// ---------- shared header for light slides ----------
function lightHeader(slide, kicker, title) {
  slide.background = { color: ICE };
  // teal motif square
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
  slide.addText("Azure Monitor  ·  SLI / SLO Hands-On Lab", {
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
  // teal side accent bar
  s.addShape(pres.shapes.RECTANGLE, { x: 0, y: 0, w: 0.22, h: PH, fill: { color: TEAL }, line: { type: "none" } });
  // faint corner block motif
  s.addShape(pres.shapes.RECTANGLE, { x: PW - 3.2, y: PH - 3.2, w: 3.2, h: 3.2, fill: { color: NAVY2 }, line: { type: "none" } });
  s.addShape(pres.shapes.RECTANGLE, { x: PW - 2.0, y: PH - 2.0, w: 2.0, h: 2.0, fill: { color: TEALDK, transparency: 55 }, line: { type: "none" } });

  s.addText("AZURE MONITOR  ·  HANDS-ON LAB", {
    x: 1.0, y: 1.55, w: 10, h: 0.4, margin: 0,
    fontFace: BFONT, fontSize: 14, bold: true, color: TEAL, charSpacing: 3
  });
  s.addText("From SLIs to a Reliability\nOperating Model", {
    x: 0.95, y: 2.05, w: 11.0, h: 1.9, margin: 0,
    fontFace: HFONT, fontSize: 46, bold: true, color: WHITE, lineSpacingMultiple: 1.02
  });
  s.addText("Measure reliability the way your customers feel it, prove it against targets, and act with AI assistance.", {
    x: 1.0, y: 4.05, w: 9.6, h: 0.8, margin: 0,
    fontFace: BFONT, fontSize: 17, color: "C7D6E5", lineSpacingMultiple: 1.15
  });

  // three quick tags
  const tags = ["Availability", "Latency", "Error budgets"];
  let tx = 1.0;
  tags.forEach(t => {
    const w = 0.42 + t.length * 0.115;
    s.addShape(pres.shapes.ROUNDED_RECTANGLE, { x: tx, y: 5.15, w, h: 0.44, rectRadius: 0.08, fill: { color: NAVY2 }, line: { color: TEALDK, width: 1 } });
    s.addText(t, { x: tx, y: 5.15, w, h: 0.44, margin: 0, fontFace: BFONT, fontSize: 12, bold: true, color: TEAL, align: "center", valign: "middle" });
    tx += w + 0.25;
  });

  s.addText("A guided introduction for platform, SRE, and engineering teams", {
    x: 1.0, y: PH - 0.7, w: 10, h: 0.35, margin: 0, fontFace: BFONT, fontSize: 11, color: "7E93A8"
  });
  s.addNotes(
    "Welcome. This is a hands-on lab, not a lecture. By the end you will have authored real Service Level Indicators on Azure Monitor and watched an error budget burn in real time.\n\n" +
    "The theme in one line: stop measuring whether servers are up, and start measuring whether customers are succeeding. Everything we build reuses telemetry you already collect, so there is no rip-and-replace.\n\n" +
    "Set expectations: an Azure subscription with the right roles, and roughly an hour end to end."
  );
}

// =====================================================================
// SLIDE 2 — Concept: Why SLIs (traditional vs customer experience)
// =====================================================================
{
  const s = pres.addSlide();
  lightHeader(s, "Concept  ·  1 of 3", "Why measure Service Level Indicators?");
  s.addText("Traditional monitoring tells you what the servers are doing. SLIs tell you what your customers experience.", {
    x: MX, y: 1.7, w: PW - MX * 2, h: 0.5, margin: 0, fontFace: BFONT, fontSize: 15, color: MUTED
  });

  const cardY = 2.45, cardH = 3.45, cardW = (PW - MX * 2 - 0.5) / 2;
  // Left card — traditional
  s.addShape(pres.shapes.RECTANGLE, { x: MX, y: cardY, w: cardW, h: cardH, fill: { color: WHITE }, line: { color: LINE, width: 1 }, shadow: shadow() });
  s.addShape(pres.shapes.RECTANGLE, { x: MX, y: cardY, w: cardW, h: 0.12, fill: { color: MUTED }, line: { type: "none" } });
  s.addText("TRADITIONAL MONITORING", { x: MX + 0.35, y: cardY + 0.35, w: cardW - 0.7, h: 0.4, margin: 0, fontFace: HFONT, fontSize: 14, bold: true, color: INK, charSpacing: 1 });
  s.addText([
    { text: "CPU, memory, disk, request counts", options: { bullet: { indent: 16 }, breakLine: true, paraSpaceAfter: 8 } },
    { text: "Answers \u201Cis the box up?\u201D", options: { bullet: { indent: 16 }, breakLine: true, paraSpaceAfter: 8 } },
    { text: "Green dashboards while customers fail", options: { bullet: { indent: 16 }, breakLine: true, paraSpaceAfter: 8 } },
    { text: "No shared target to argue against", options: { bullet: { indent: 16 } } }
  ], { x: MX + 0.35, y: cardY + 0.95, w: cardW - 0.7, h: cardH - 1.3, margin: 0, fontFace: BFONT, fontSize: 14.5, color: INK, lineSpacingMultiple: 1.05 });

  // Right card — SLI approach
  const rx = MX + cardW + 0.5;
  s.addShape(pres.shapes.RECTANGLE, { x: rx, y: cardY, w: cardW, h: cardH, fill: { color: NAVY }, line: { type: "none" }, shadow: shadow() });
  s.addShape(pres.shapes.RECTANGLE, { x: rx, y: cardY, w: cardW, h: 0.12, fill: { color: TEAL }, line: { type: "none" } });
  s.addText("SLI-BASED RELIABILITY", { x: rx + 0.35, y: cardY + 0.35, w: cardW - 0.7, h: 0.4, margin: 0, fontFace: HFONT, fontSize: 14, bold: true, color: TEAL, charSpacing: 1 });
  s.addText([
    { text: "Availability and latency as customers feel them", options: { bullet: { indent: 16 }, breakLine: true, paraSpaceAfter: 8 } },
    { text: "Answers \u201Cis the journey working?\u201D", options: { bullet: { indent: 16 }, breakLine: true, paraSpaceAfter: 8 } },
    { text: "Scored per application, not per box", options: { bullet: { indent: 16 }, breakLine: true, paraSpaceAfter: 8 } },
    { text: "A number and a target everyone agrees on", options: { bullet: { indent: 16 } } }
  ], { x: rx + 0.35, y: cardY + 0.95, w: cardW - 0.7, h: cardH - 1.3, margin: 0, fontFace: BFONT, fontSize: 14.5, color: "E5EEF6", lineSpacingMultiple: 1.05 });

  s.addNotes(
    "This is the core mindset shift, spend a minute here.\n\n" +
    "Left side is where most teams live: CPU, memory, request counts. The problem is the dashboard is green while customers are failing, and there is no shared target to hold anyone to.\n\n" +
    "Right side is the SLI approach: measure availability and latency the way customers feel them, scored per application rather than per box, against a number everyone agreed on.\n\n" +
    "Room question: how many of you have had an all-green dashboard during a real incident? Almost every hand goes up. That gap is what we are closing today."
  );
  footer(s, 2);
}

// =====================================================================
// SLIDE 3 — Concept: The vocabulary (4 cards)
// =====================================================================
{
  const s = pres.addSlide();
  lightHeader(s, "Concept  ·  2 of 3", "Four ideas that connect the whole lab");

  const items = [
    ["SLI", "Service Level Indicator", "A measured signal of reliability, e.g. the % of checkout requests that succeed."],
    ["SLO", "Service Level Objective", "The target for an SLI over a rolling window, e.g. 99.5% over 7 days."],
    ["Error budget", "100% \u2212 SLO", "The failure you are allowed. At 99.5% the budget is 0.5%."],
    ["Burn rate", "Budget spend speed", "1x uses the whole budget by the window's end; spikes trigger alerts."]
  ];
  const n = items.length;
  const gap = 0.4;
  const cardW = (PW - MX * 2 - gap * (n - 1)) / n;
  const cardY = 2.2, cardH = 3.7;
  items.forEach((it, i) => {
    const x = MX + i * (cardW + gap);
    s.addShape(pres.shapes.RECTANGLE, { x, y: cardY, w: cardW, h: cardH, fill: { color: WHITE }, line: { color: LINE, width: 1 }, shadow: shadow() });
    badge(s, x + 0.3, cardY + 0.32, i + 1, TEAL, NAVY, 0.5);
    s.addText(it[0], { x: x + 0.3, y: cardY + 1.0, w: cardW - 0.6, h: 0.55, margin: 0, fontFace: HFONT, fontSize: 21, bold: true, color: NAVY });
    s.addText(it[1].toUpperCase(), { x: x + 0.3, y: cardY + 1.55, w: cardW - 0.6, h: 0.4, margin: 0, fontFace: BFONT, fontSize: 10.5, bold: true, color: TEALDK, charSpacing: 1 });
    s.addText(it[2], { x: x + 0.3, y: cardY + 2.0, w: cardW - 0.6, h: cardH - 2.2, margin: 0, fontFace: BFONT, fontSize: 13, color: INK, lineSpacingMultiple: 1.12, valign: "top" });
  });

  s.addText("The error budget is the connective tissue: it decides when to alert, when to investigate, and when to ship vs. stabilize.", {
    x: MX, y: cardY + cardH + 0.2, w: PW - MX * 2, h: 0.4, margin: 0, fontFace: BFONT, fontSize: 12.5, italic: true, color: MUTED
  });
  s.addNotes(
    "Four terms that connect the whole lab. Keep it plain.\n\n" +
    "SLI is the measurement. SLO is the target for that measurement. Error budget is what you are allowed to fail: 100 percent minus the SLO, so at 99.5 percent you get 0.5 percent. Burn rate is how fast you are spending that budget: 1x means you use it all exactly by the end of the window, a spike means trouble.\n\n" +
    "The one idea to land: the error budget is the connective tissue. It decides when to alert, when to investigate, and later when to ship versus stabilize. Same number drives reliability and response."
  );
  footer(s, 3);
}

// =====================================================================
// SLIDE 4 — Concept: The lab scenario
// =====================================================================
{
  const s = pres.addSlide();
  lightHeader(s, "Concept  ·  3 of 3", "The scenario: a mission-critical online store");
  s.addText("An e-commerce app with Login and Checkout services, grouped into one Service Group (CheckoutSG) and measured by three SLIs.", {
    x: MX, y: 1.7, w: PW - MX * 2, h: 0.5, margin: 0, fontFace: BFONT, fontSize: 15, color: MUTED
  });

  const items = [
    ["Availability SLI", "Checkout", "% of checkout requests returning success (2xx). Target 99.5%."],
    ["Latency SLI", "Login", "% of login requests completing under 300 ms. Target 99.5%."],
    ["Dependency SLI", "Payment provider", "% of payment-provider calls that succeed. Target 99.5%."]
  ];
  const n = 3, gap = 0.4;
  const cardW = (PW - MX * 2 - gap * (n - 1)) / n;
  const cardY = 2.5, cardH = 2.7;
  items.forEach((it, i) => {
    const x = MX + i * (cardW + gap);
    s.addShape(pres.shapes.RECTANGLE, { x, y: cardY, w: cardW, h: cardH, fill: { color: WHITE }, line: { color: LINE, width: 1 }, shadow: shadow() });
    s.addShape(pres.shapes.RECTANGLE, { x, y: cardY, w: 0.12, h: cardH, fill: { color: TEAL }, line: { type: "none" } });
    s.addText(it[0], { x: x + 0.35, y: cardY + 0.3, w: cardW - 0.6, h: 0.4, margin: 0, fontFace: HFONT, fontSize: 17, bold: true, color: NAVY });
    s.addText(it[1].toUpperCase(), { x: x + 0.35, y: cardY + 0.78, w: cardW - 0.6, h: 0.35, margin: 0, fontFace: BFONT, fontSize: 11, bold: true, color: TEALDK, charSpacing: 1 });
    s.addText(it[2], { x: x + 0.35, y: cardY + 1.2, w: cardW - 0.65, h: cardH - 1.4, margin: 0, fontFace: BFONT, fontSize: 13, color: INK, lineSpacingMultiple: 1.12, valign: "top" });
  });

  // bottom strip: baseline + alerting
  const by = cardY + cardH + 0.35;
  s.addShape(pres.shapes.ROUNDED_RECTANGLE, { x: MX, y: by, w: PW - MX * 2, h: 0.78, rectRadius: 0.08, fill: { color: NAVY }, line: { type: "none" } });
  s.addText([
    { text: "SLO baseline  ", options: { fontFace: HFONT, bold: true, color: TEAL } },
    { text: "99.5% over rolling 7 / 30 days", options: { color: "E5EEF6" } },
    { text: "        Alerting  ", options: { fontFace: HFONT, bold: true, color: TEAL } },
    { text: "baseline + fast-burn + slow-burn to action groups", options: { color: "E5EEF6" } }
  ], { x: MX + 0.4, y: by, w: PW - MX * 2 - 0.8, h: 0.78, margin: 0, fontFace: BFONT, fontSize: 13.5, valign: "middle" });

  s.addNotes(
    "A concrete scenario so none of this stays abstract. An online store with Login and Checkout, grouped into one Service Group called CheckoutSG. SLIs are authored at the service group level, that is the application boundary.\n\n" +
    "Three SLIs, and deliberately three different flavors you will meet in the real world: availability (did checkout succeed), latency (did login respond under 300 milliseconds), and dependency (did the payment provider succeed).\n\n" +
    "All three target 99.5 percent over a rolling 7 and 30 days. When the budget burns, baseline, fast-burn, and slow-burn alerts fire to your action groups: fast burn pages a human, slow burn opens a ticket."
  );
  footer(s, 4);
}

// =====================================================================
// SLIDE 5 — Contents (one slide): what the lab includes / architecture
// =====================================================================
{
  const s = pres.addSlide();
  lightHeader(s, "Contents", "What is in the hands-on lab");

  // Left column — what you get
  const lx = MX, lw = 4.7, ly = 2.0;
  const groups = [
    ["Runnable demo app", "Frontend + backend App Services with tunable failure & latency, emitting OpenTelemetry metrics."],
    ["One-click infrastructure", "Bicep for Azure Monitor Workspace, App Insights, Log Analytics, managed identity, OTel collector."],
    ["Guided lab runner", "sli-run-lab.ps1 walks the 8-phase SLI design method end to end."],
    ["Load generator", "Steady + spike traffic and a failure-injection guide to burn the error budget live."]
  ];
  let gy = ly;
  groups.forEach((g, i) => {
    badge(s, lx, gy, i + 1, TEAL, NAVY, 0.42);
    s.addText(g[0], { x: lx + 0.6, y: gy - 0.04, w: lw - 0.6, h: 0.35, margin: 0, fontFace: HFONT, fontSize: 14.5, bold: true, color: NAVY });
    s.addText(g[1], { x: lx + 0.6, y: gy + 0.32, w: lw - 0.6, h: 0.7, margin: 0, fontFace: BFONT, fontSize: 11.5, color: MUTED, lineSpacingMultiple: 1.08 });
    gy += 1.15;
  });

  // Right column — architecture flow
  const rx = MX + lw + 0.6;
  const rw = PW - MX - rx;
  s.addShape(pres.shapes.RECTANGLE, { x: rx, y: ly, w: rw, h: 4.75, fill: { color: WHITE }, line: { color: LINE, width: 1 }, shadow: shadow() });
  s.addText("HOW THE TELEMETRY FLOWS", { x: rx + 0.35, y: ly + 0.28, w: rw - 0.7, h: 0.35, margin: 0, fontFace: HFONT, fontSize: 12, bold: true, color: TEALDK, charSpacing: 1 });

  const flow = [
    ["Apps (Login / Checkout)", "emit OpenTelemetry metrics"],
    ["OpenTelemetry Collector", "Prometheus remote write"],
    ["Managed-identity proxy", "authenticated ingest"],
    ["Azure Monitor Workspace", "SLI source + destination"],
    ["SLI engine on CheckoutSG", "error budget + burn rate"]
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
    "What is actually in the kit, so people know what they are getting.\n\n" +
    "Four things on the left: a runnable demo app with tunable failure and latency, one-click Bicep infrastructure, the guided lab runner that walks the 8-phase method, and a load generator with a failure-injection guide to burn the budget on demand.\n\n" +
    "On the right is how telemetry flows: the apps emit OpenTelemetry, a collector remote-writes to the Azure Monitor Workspace through a managed-identity proxy, and the SLI engine reads that same workspace. The point to stress: SLIs read from a standard Azure Monitor Workspace. Nothing here is bespoke plumbing."
  );
  footer(s, 5);
}

// =====================================================================
// SLIDE 6 — Run steps: 3-step quickstart with commands
// =====================================================================
{
  const s = pres.addSlide();
  lightHeader(s, "Run the lab  ·  Quickstart", "Three commands, two terminals");

  const steps = [
    ["Deploy the infrastructure", "One script provisions all Azure resources and pushes the app code.", "./infra/infra-deploy.ps1 `\n  -ResourceGroup rg-sli-demo `\n  -Location eastus2"],
    ["Start traffic  (Terminal 1)", "Leave running so the 5-minute rate windows stay populated.", "pwsh -File load/generate-traffic-all.ps1 `\n  -ResourceGroup rg-sli-demo `\n  -Rps 30 -DurationSeconds 1800"],
    ["Run the lab  (Terminal 2)", "Walks phases 1-8: discover journeys, author SLIs, validate.", "./sli-run-lab.ps1 `\n  -ResourceGroup rg-sli-demo"]
  ];
  const n = 3, gap = 0.4;
  const cardW = (PW - MX * 2 - gap * (n - 1)) / n;
  const cardY = 2.1, cardH = 4.2;
  steps.forEach((st, i) => {
    const x = MX + i * (cardW + gap);
    s.addShape(pres.shapes.RECTANGLE, { x, y: cardY, w: cardW, h: cardH, fill: { color: WHITE }, line: { color: LINE, width: 1 }, shadow: shadow() });
    badge(s, x + 0.35, cardY + 0.35, i + 1, NAVY, TEAL, 0.5);
    s.addText(st[0], { x: x + 1.0, y: cardY + 0.35, w: cardW - 1.2, h: 0.55, margin: 0, fontFace: HFONT, fontSize: 15, bold: true, color: NAVY, valign: "middle" });
    s.addText(st[1], { x: x + 0.35, y: cardY + 1.05, w: cardW - 0.7, h: 0.9, margin: 0, fontFace: BFONT, fontSize: 12, color: MUTED, lineSpacingMultiple: 1.1 });
    // code block
    const codeY = cardY + 2.05, codeH = cardH - 2.05 - 0.3;
    s.addShape(pres.shapes.ROUNDED_RECTANGLE, { x: x + 0.3, y: codeY, w: cardW - 0.6, h: codeH, rectRadius: 0.05, fill: { color: CODEBG }, line: { type: "none" } });
    s.addText(st[2], { x: x + 0.5, y: codeY + 0.12, w: cardW - 1.0, h: codeH - 0.24, margin: 0, fontFace: MONO, fontSize: 10.5, color: TEAL, valign: "top", lineSpacingMultiple: 1.15 });
  });

  s.addText("Prerequisites: Azure CLI signed in, PowerShell 7+, Contributor + User Access Administrator on the subscription.", {
    x: MX, y: cardY + cardH + 0.15, w: PW - MX * 2, h: 0.35, margin: 0, fontFace: BFONT, fontSize: 11.5, italic: true, color: MUTED
  });
  s.addNotes(
    "The whole lab is three commands across two terminals. Demystify it up front.\n\n" +
    "One: deploy the infrastructure. A single script provisions every Azure resource and pushes the app code.\n\n" +
    "Two: in its own terminal, start the traffic generator and leave it running. This matters, call it out: every SLI is a rate over a 5-minute window, so no traffic means no data and empty columns. Give it a minute or two to warm up.\n\n" +
    "Three: in a second terminal, run the lab. Prerequisites are on the slide: Azure CLI signed in, PowerShell 7, and Contributor plus User Access Administrator on the subscription."
  );
  footer(s, 6);
}

// =====================================================================
// SLIDE 7 — Run steps: the 8 phases
// =====================================================================
{
  const s = pres.addSlide();
  lightHeader(s, "Run the lab  ·  What sli-run-lab.ps1 does", "The 8-phase SLI design method");

  const phases = [
    ["Environment setup & access checks", "Selects subscription, resolves the workspace, verifies metrics are live."],
    ["Enumerate ALL user journeys", "Builds a journey inventory straight from telemetry."],
    ["Extract the CRITICAL journeys", "Scores each journey; keeps the ones that matter most."],
    ["Data collection per journey", "Confirms source metrics, measures current performance, checks for gaps."],
    ["Consolidate the design checklist", "One row per SLI: type, target, window, budget, burn policy."],
    ["Author the SLIs in the portal", "Creates the Service Group and the three SLIs (optionally automated)."],
    ["Validate end to end", "Confirms the SLI engine is publishing Value / Good / Total results."],
    ["Lab completion checklist", "Summary of what was built and what to explore next."]
  ];
  const colGap = 0.6;
  const colW = (PW - MX * 2 - colGap) / 2;
  const y0 = 2.05, rowH = 1.18;
  phases.forEach((p, i) => {
    const col = Math.floor(i / 4);
    const row = i % 4;
    const x = MX + col * (colW + colGap);
    const y = y0 + row * rowH;
    badge(s, x, y, i + 1, i < 5 ? TEAL : AMBER, NAVY, 0.46);
    s.addText(p[0], { x: x + 0.62, y: y - 0.05, w: colW - 0.62, h: 0.34, margin: 0, fontFace: HFONT, fontSize: 14, bold: true, color: NAVY });
    s.addText(p[1], { x: x + 0.62, y: y + 0.3, w: colW - 0.62, h: 0.62, margin: 0, fontFace: BFONT, fontSize: 11, color: MUTED, lineSpacingMultiple: 1.05 });
  });
  s.addNotes(
    "This is what sli-run-lab.ps1 walks through, and it mirrors how you would design SLIs for any real service, not just this demo.\n\n" +
    "Phases 1 to 5 (teal) are discovery and design: check access, enumerate every user journey from telemetry, score them to find the critical few, collect the supporting data, and consolidate a design checklist.\n\n" +
    "Phases 6 to 8 (amber) are authoring and validation: create the Service Group and the three SLIs, confirm the engine is publishing Value, Good, and Total results, and wrap up.\n\n" +
    "The lab automates the mechanics so participants can focus on the judgement calls: which journeys are critical and what target is honest."
  );
  footer(s, 7);
}

// =====================================================================
// SLIDE 8 — What follows: the path forward roadmap
// =====================================================================
{
  const s = pres.addSlide();
  lightHeader(s, "What follows", "From this lab to a reliability operating model");
  s.addText("The SLI foundation you build here is the bedrock. Each next phase reuses it without rework.", {
    x: MX, y: 1.7, w: PW - MX * 2, h: 0.5, margin: 0, fontFace: BFONT, fontSize: 15, color: MUTED
  });

  const phases = [
    ["PHASE 0", "SLI foundation", "SLIs, SLOs, error budgets and burn alerts on a Service Group.", "DONE IN THIS LAB", TEALDK],
    ["PHASE 1", "Health Models", "Roll SLIs + resource health into one honest, top-down app health score.", "NEXT", NAVY],
    ["PHASE 2", "AI operations", "Observability Agent explains incidents; SRE Agent takes approved action.", "NEXT", NAVY],
    ["PHASE 3", "Operating model", "Error budgets gate releases: ship when healthy, stabilize when burning.", "GOAL", NAVY]
  ];
  const n = 4, gap = 0.38;
  const cardW = (PW - MX * 2 - gap * (n - 1)) / n;
  const cardY = 2.5, cardH = 3.5;
  phases.forEach((p, i) => {
    const x = MX + i * (cardW + gap);
    const done = i === 0;
    s.addShape(pres.shapes.RECTANGLE, { x, y: cardY, w: cardW, h: cardH, fill: { color: done ? NAVY : WHITE }, line: { color: done ? NAVY : LINE, width: 1 }, shadow: shadow() });
    s.addText(p[0], { x: x + 0.3, y: cardY + 0.3, w: cardW - 0.6, h: 0.3, margin: 0, fontFace: BFONT, fontSize: 11, bold: true, color: done ? TEAL : TEALDK, charSpacing: 1 });
    s.addText(p[1], { x: x + 0.3, y: cardY + 0.65, w: cardW - 0.6, h: 0.6, margin: 0, fontFace: HFONT, fontSize: 17, bold: true, color: done ? WHITE : NAVY });
    s.addText(p[2], { x: x + 0.3, y: cardY + 1.35, w: cardW - 0.6, h: 1.6, margin: 0, fontFace: BFONT, fontSize: 12, color: done ? "C7D6E5" : INK, lineSpacingMultiple: 1.12, valign: "top" });
    // status pill
    const pillW = 0.4 + p[3].length * 0.075;
    s.addShape(pres.shapes.ROUNDED_RECTANGLE, { x: x + 0.3, y: cardY + cardH - 0.65, w: pillW, h: 0.36, rectRadius: 0.07, fill: { color: done ? TEAL : ICE }, line: { color: done ? TEAL : LINE, width: 1 } });
    s.addText(p[3], { x: x + 0.3, y: cardY + cardH - 0.65, w: pillW, h: 0.36, margin: 0, fontFace: BFONT, fontSize: 9, bold: true, color: done ? NAVY : MUTED, align: "center", valign: "middle", charSpacing: 1 });
    // connector arrow
    if (i < n - 1) {
      s.addText("\u2192", { x: x + cardW - 0.02, y: cardY + cardH / 2 - 0.25, w: gap + 0.04, h: 0.5, margin: 0, fontFace: BFONT, fontSize: 20, bold: true, color: TEALDK, align: "center", valign: "middle" });
    }
  });
  s.addNotes(
    "Where this goes after today, so the lab lands as a starting point, not a one-off.\n\n" +
    "Phase 0, what you build in this lab, is the foundation and the hardest part done: reliability measured the way customers feel it.\n\n" +
    "Phase 1 rolls your SLIs plus resource health into a single, honest Health Model score, so leadership sees one number and engineers drill to the failing entity.\n\n" +
    "Phase 2 adds AI: the Observability Agent explains what broke and why, the SRE Agent takes approved action. Phase 3 is the operating model, where error budgets gate releases: ship when healthy, stabilize when burning.\n\n" +
    "The message: each phase reuses the previous one with no rework."
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
    ["Author real SLIs", "Availability, latency, and dependency SLIs on a Service Group."],
    ["See the error budget move", "Inject failures and watch fast / slow burn alerts fire."],
    ["Know the path forward", "Health Models, AI-assisted ops, and error-budget-driven releases."]
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
    { text: "Deploy the infra, start traffic, and run  ./sli-run-lab.ps1", options: { color: "07314A", fontFace: MONO } }
  ], { x: 1.0, y: cy + ch + 0.4, w: PW - 2.0, h: 0.75, margin: 0, fontSize: 15, align: "center", valign: "middle" });
  s.addNotes(
    "Recap the three outcomes: you will have authored real SLIs, you will have seen the error budget move by injecting failures, and you will know the path forward to Health Models and AI-assisted operations.\n\n" +
    "Call to action is deliberately simple: deploy the infra, start traffic, and run ./sli-run-lab.ps1.\n\n" +
    "Then hand off: open your terminal and let us start. Offer to stay on for questions as they work through it."
  );
}

pres.writeFile({ fileName: "SLI-SLO-Lab-Intro.pptx" }).then(f => console.log("WROTE", f));
