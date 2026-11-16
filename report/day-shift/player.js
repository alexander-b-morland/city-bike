// The animated map used by the result pages: stations coloured by how full they are, and
// trucks following real streets, on a base map built from OpenStreetMap.
//
// createMapPlayer(container, options) fills `container` with the controls and the map.
// options: stations [{name, lat, lon, cap}], depot [lat, lon], days ["yyyy-mm-dd"],
// truck {stopMinutes, bikeMinutes}, legs {"a>b": [x0, y0, dx, dy, ...]} in 1e-5 degrees,
// map (window.OSLO_MAP), runs [{label, days}], pickLabel, initial {run, day, t}.
// The page's stylesheet provides the colours as CSS variables and the layout classes.
window.createMapPlayer = function (container, options) {
  const S = options.stations, N = S.length, SNAPS = 48, DAYS = options.days.length;
  const M = options.map, RUNS = options.runs, TRUCK = options.truck;
  const css = (name) => getComputedStyle(document.documentElement).getPropertyValue(name).trim();
  const fmt = (n) => Math.round(n).toLocaleString("en-US");
  const dayDate = (d) => new Date(options.days[d] + "T00:00:00");

  container.innerHTML = `
    <div class="bar">
      <div class="pick"><label for="mp-run">${options.pickLabel || "Trucks"}</label><input type="range" id="mp-run" min="0" max="${RUNS.length - 1}" step="1"><output id="mp-runout"></output></div>
      <button type="button" class="btn" id="mp-play">Play</button>
      <button type="button" class="btn" id="mp-speed" aria-label="Playback speed">Speed 1×</button>
      <div class="clock"><span class="chip" id="mp-phase"></span><span id="mp-clock"></span></div>
    </div>
    <div class="mapwrap" id="mp-wrap">
      <canvas id="mp-map" role="img" aria-label="Map of Oslo with bike stations coloured by how full they are and the trucks' routes along the streets"></canvas>
      <div class="tip" id="mp-tip" hidden></div>
    </div>
    <div class="scrub"><input type="range" id="mp-scrub" min="0" max="${DAYS * SNAPS - 1}" step="1" value="0" aria-label="Day and time"></div>
    <div class="facts" id="mp-facts"></div>
    <div class="legend" style="padding:0 16px 8px">
      <span><i class="dot" style="background:var(--empty)"></i>No bikes</span>
      <span><i class="dot" style="background:var(--low)"></i>Under 20% full</span>
      <span><i class="dot" style="background:var(--mid)"></i>Fine</span>
      <span><i class="dot" style="background:var(--high)"></i>Over 80% full</span>
      <span><i class="dot" style="background:var(--full)"></i>No free docks</span>
      <span><i class="line" style="background:var(--route)"></i>Truck routes</span>
    </div>
    <div class="credit">Map data © OpenStreetMap contributors. Bike data: Oslo Bysykkel, NLOD 2.0.</div>`;
  const $ = (id) => container.querySelector("#mp-" + id);
  const state = Object.assign({ run: 0, day: 3, t: 210, playing: false, speed: 1 }, options.initial || {});
  const canvas = $("map"), ctx = canvas.getContext("2d"), wrap = $("wrap"), base = document.createElement("canvas");
  const VIEW = { lat0: 59.8945, lat1: 59.9560, lon0: 10.6440, lon1: 10.8210 }, K = Math.cos(59.92 * Math.PI / 180);
  let W = 0, H = 0, proj = null, colors = {}, legCache = {};

  const level = (run, d, k, i) => { const c = run.days[d].levels.charCodeAt(k * N + i); return c < 58 ? c - 48 : c < 91 ? c - 29 : c - 87; };
  const startOf = (truck) => truck.start || 0;
  const atWork = (truck, t) => t >= startOf(truck) && t < startOf(truck) + truck.minutes;
  function readColors() { for (const n of ["ink", "ink2", "optimal", "empty", "low", "mid", "high", "full", "land", "sea", "park", "road1", "road2", "road3", "roadedge", "route"]) colors[n] = css("--" + n); }
  function resize() {
    const ratio = window.devicePixelRatio || 1;
    W = wrap.clientWidth; H = wrap.clientHeight; if (!W || !H) return false;
    for (const c of [canvas, base]) { c.width = Math.round(W * ratio); c.height = Math.round(H * ratio); }
    ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
    const scale = Math.max(W / ((VIEW.lon1 - VIEW.lon0) * K), H / (VIEW.lat1 - VIEW.lat0));
    const ox = (W - (VIEW.lon1 - VIEW.lon0) * K * scale) / 2, oy = (H - (VIEW.lat1 - VIEW.lat0) * scale) / 2;
    proj = (lat, lon) => [ox + (lon - VIEW.lon0) * K * scale, H - oy - (lat - VIEW.lat0) * scale];
    for (const s of S) [s.x, s.y] = proj(s.lat, s.lon);
    legCache = {}; drawBase(ratio); return true;
  }
  function trace(g, numbers, lat0, lon0, unit) {
    let x = numbers[0], y = numbers[1], p = proj(lat0 + y * unit, lon0 + x * unit);
    g.moveTo(p[0], p[1]);
    for (let i = 2; i < numbers.length; i += 2) { x += numbers[i]; y += numbers[i + 1]; p = proj(lat0 + y * unit, lon0 + x * unit); g.lineTo(p[0], p[1]); }
  }
  // The base map is drawn once per size and theme, then copied under every frame.
  function drawBase(ratio) {
    const g = base.getContext("2d"), [south, west, north, east] = M.box, u = M.unit;
    g.setTransform(ratio, 0, 0, ratio, 0, 0);
    g.fillStyle = colors.land; g.fillRect(0, 0, W, H);
    const fillAll = (lines, color) => { g.fillStyle = color; g.beginPath(); for (const l of lines) { trace(g, l, south, west, u); g.closePath(); } g.fill(); };
    fillAll(M.parks, colors.park);
    g.fillStyle = colors.sea;
    const rows = M.sea.rows, dLat = (north - south) / rows.length, dLon = (east - west) / M.sea.columns;
    rows.forEach((runs, r) => { for (let i = 0; i < runs.length; i += 2) {
      const a = proj(north - r * dLat, west + runs[i] * dLon), b = proj(north - (r + 1) * dLat, west + (runs[i] + runs[i + 1]) * dLon);
      g.fillRect(a[0], a[1], b[0] - a[0] + 0.6, b[1] - a[1] + 0.6); } });
    fillAll(M.lakes, colors.sea);
    const strokeAll = (lines, color, width, dash) => { g.strokeStyle = color; g.lineWidth = width; g.lineJoin = g.lineCap = "round"; g.setLineDash(dash || []); g.beginPath(); for (const l of lines) trace(g, l, south, west, u); g.stroke(); g.setLineDash([]); };
    strokeAll(M.rivers, colors.sea, 2.5);
    const z = Math.max(0.6, W / 1000);
    for (const [name, width] of [["minor", 1.6], ["medium", 2.6], ["major", 3.6]]) strokeAll(M.roads[name], colors.roadedge, (width + 1.2) * z);
    strokeAll(M.roads.minor, colors.road3, 1.6 * z); strokeAll(M.roads.medium, colors.road2, 2.6 * z); strokeAll(M.roads.major, colors.road1, 3.6 * z);
    strokeAll(M.roads.tunnel, colors.roadedge, 1.5 * z, [4, 4]);
    if (W < 520) return;
    g.font = "500 12px Inter, system-ui, sans-serif"; g.textAlign = "center"; g.lineWidth = 3; g.strokeStyle = colors.land;
    for (const [text, lat, lon] of [["Oslofjord", 59.9005, 10.722], ["Nydalen", 59.9515, 10.7665], ["Majorstuen", 59.9305, 10.713], ["Skøyen", 59.9245, 10.682], ["Grünerløkka", 59.9245, 10.7585], ["Bygdøy", 59.906, 10.682], ["Tøyen", 59.9165, 10.772], ["Blindern", 59.9415, 10.7215]]) {
      const [x, y] = proj(lat, lon); if (text !== "Oslofjord") g.strokeText(text, x, y); g.fillStyle = colors.ink2; g.fillText(text, x, y); }
  }
  function legPoints(a, b) {
    const key = a + ">" + b; if (legCache[key]) return legCache[key];
    const numbers = options.legs[key], pts = []; let x = numbers[0], y = numbers[1], length = 0;
    pts.push(proj(y / 1e5, x / 1e5));
    for (let i = 2; i < numbers.length; i += 2) { x += numbers[i]; y += numbers[i + 1]; const p = proj(y / 1e5, x / 1e5); length += Math.hypot(p[0] - pts[pts.length - 1][0], p[1] - pts[pts.length - 1][1]); pts.push(p); }
    return (legCache[key] = { pts, length });
  }
  // Draw one truck's route up to time t and return where the truck is, if it is at work.
  function drawTruck(truck, t) {
    const start = startOf(truck);
    let from = N, leave = start, position = null;
    const stops = truck.stops.concat([[N, 0, start + truck.minutes]]);
    ctx.beginPath();
    for (let s = 0; s < stops.length; s++) {
      const [to, change, done] = stops[s], home = s === stops.length - 1;
      if (t <= leave) break;
      const arrive = home ? Math.max(leave, done) : Math.max(leave, done - TRUCK.stopMinutes - TRUCK.bikeMinutes * Math.abs(change));
      if (to !== from) {
        const leg = legPoints(from, to), f = arrive > leave ? Math.min(1, (t - leave) / (arrive - leave)) : 1;
        let left = leg.length * f; ctx.moveTo(leg.pts[0][0], leg.pts[0][1]); position = leg.pts[0];
        for (let i = 1; i < leg.pts.length; i++) {
          const a = leg.pts[i - 1], b = leg.pts[i], d = Math.hypot(b[0] - a[0], b[1] - a[1]);
          if (d >= left) { const q = d ? left / d : 0; position = [a[0] + (b[0] - a[0]) * q, a[1] + (b[1] - a[1]) * q]; ctx.lineTo(position[0], position[1]); break; }
          ctx.lineTo(b[0], b[1]); left -= d; position = b; }
      }
      from = to; leave = home ? Infinity : done;
    }
    ctx.stroke();
    return atWork(truck, t) ? position : null;
  }
  function draw() {
    const run = RUNS[state.run], { day, t } = state, r = run.days[day];
    const dark = t < 300, k = Math.min(SNAPS - 1, Math.floor(t / 30)), working = r.trucks.some((truck) => atWork(truck, t));
    ctx.drawImage(base, 0, 0, W, H);
    if (dark) { ctx.fillStyle = "rgba(20,30,60,0.10)"; ctx.fillRect(0, 0, W, H); }
    ctx.lineWidth = Math.max(1.6, 2.2 * W / 1000); ctx.lineJoin = ctx.lineCap = "round"; ctx.strokeStyle = colors.route; ctx.globalAlpha = working ? 0.9 : 0.28;
    const positions = r.trucks.map((truck) => drawTruck(truck, t));
    ctx.globalAlpha = 1;
    let empty = 0, full = 0; const small = W < 520 ? 0.75 : 1;
    for (let i = 0; i < N; i++) {
      const s = S[i], b = level(run, day, k, i), share = b / s.cap;
      let radius = (2.2 + Math.sqrt(s.cap) * 0.55) * small, fill = colors.mid;
      if (b === 0) { fill = colors.empty; radius += 1.5; empty++; } else if (b === s.cap) { fill = colors.full; radius += 1.5; full++; }
      else if (share < 0.2) fill = colors.low; else if (share > 0.8) fill = colors.high;
      ctx.beginPath(); ctx.arc(s.x, s.y, radius, 0, 7); ctx.fillStyle = fill; ctx.fill(); ctx.lineWidth = 1; ctx.strokeStyle = colors.land; ctx.stroke();
    }
    const depot = proj(options.depot[0], options.depot[1]);
    ctx.fillStyle = colors.route; ctx.fillRect(depot[0] - 5, depot[1] - 5, 10, 10);
    ctx.font = "600 12px Inter, system-ui, sans-serif"; ctx.textAlign = "left"; ctx.lineWidth = 3; ctx.strokeStyle = colors.land; ctx.strokeText("Base", depot[0] + 9, depot[1] + 4); ctx.fillStyle = colors.ink; ctx.fillText("Base", depot[0] + 9, depot[1] + 4);
    for (const p of positions) if (p) { ctx.beginPath(); ctx.arc(p[0], p[1], 6 * small, 0, 7); ctx.fillStyle = colors.optimal; ctx.fill(); ctx.lineWidth = 2; ctx.strokeStyle = colors.route; ctx.stroke(); }
    const clock = new Date(dayDate(day).getTime() + (60 + t) * 60000);
    $("clock").textContent = clock.toLocaleDateString("en-GB", { weekday: "short", day: "numeric", month: "short" }) + " · " + String(clock.getHours()).padStart(2, "0") + ":" + String(clock.getMinutes()).padStart(2, "0");
    $("phase").textContent = working ? "Trucks at work" : dark ? "Night" : "Riders on the road";
    const moved = r.trucks.reduce((a, truck) => a + truck.stops.reduce((b, s) => b + Math.max(s[1], 0), 0), 0), km = r.trucks.reduce((a, truck) => a + truck.km, 0);
    $("facts").innerHTML = `<span>Stations with no bikes now: <b>${empty}</b></span><span>Stations with no free docks now: <b>${full}</b></span>` +
      `<span>Riders let down this day: <b>${fmt(r.noBike + r.noDock)}</b> of ${fmt(r.trips)}</span>` +
      (r.trucks.length ? `<span>Trucks this day: <b>${fmt(moved)}</b> bikes moved, ${fmt(km)} km driven</span>` : "<span>No trucks this day</span>");
    $("scrub").value = day * SNAPS + k; $("scrub").setAttribute("aria-valuetext", $("clock").textContent);
  }
  function runLabel() { $("runout").textContent = RUNS[state.run].label; $("run").setAttribute("aria-valuetext", RUNS[state.run].label); }
  $("run").value = state.run;
  $("run").addEventListener("input", (e) => { state.run = +e.target.value; runLabel(); draw(); });
  $("scrub").addEventListener("input", (e) => { const v = +e.target.value; state.day = Math.floor(v / SNAPS); state.t = (v % SNAPS) * 30; draw(); });
  $("speed").addEventListener("click", () => { state.speed = state.speed === 1 ? 3 : state.speed === 3 ? 8 : 1; $("speed").textContent = "Speed " + state.speed + "×"; });
  let last = 0;
  function tick(now) {
    if (!state.playing) return;
    const dt = Math.min(100, now - last) / 1000; last = now;
    const slow = RUNS[state.run].days[state.day].trucks.some((truck) => atWork(truck, state.t));
    state.t += dt * state.speed * (slow ? 30 : 130);
    if (state.t >= 1440) { if (state.day === DAYS - 1) { state.t = 1439; setPlaying(false); } else { state.day++; state.t -= 1440; } }
    draw(); requestAnimationFrame(tick);
  }
  function setPlaying(on) {
    state.playing = on; $("play").textContent = on ? "Pause" : "Play";
    if (on) { if (state.day === DAYS - 1 && state.t >= 1439) { state.day = 0; state.t = 0; } last = performance.now(); requestAnimationFrame(tick); }
  }
  $("play").addEventListener("click", () => setPlaying(!state.playing));
  canvas.addEventListener("mousemove", (e) => {
    const rect = canvas.getBoundingClientRect(), x = e.clientX - rect.left, y = e.clientY - rect.top;
    let best = -1, dist = 144;
    for (let i = 0; i < N; i++) { const d = (S[i].x - x) ** 2 + (S[i].y - y) ** 2; if (d < dist) { dist = d; best = i; } }
    const tip = $("tip"); if (best < 0) { tip.hidden = true; return; }
    const run = RUNS[state.run], b = level(run, state.day, Math.min(SNAPS - 1, Math.floor(state.t / 30)), best);
    const change = run.days[state.day].trucks.reduce((a, truck) => a + truck.stops.reduce((c, s) => c + (s[0] === best ? s[1] : 0), 0), 0);
    tip.innerHTML = `<b>${S[best].name}</b><br>${b} bikes, ${S[best].cap - b} free docks` + (change ? `<br>Trucks ${change > 0 ? "added " + change : "took " + -change} this day` : "");
    tip.hidden = false; tip.style.left = Math.max(4, Math.min(W - tip.offsetWidth - 4, S[best].x + 10)) + "px"; tip.style.top = Math.max(4, S[best].y - 60) + "px";
  });
  canvas.addEventListener("mouseleave", () => { $("tip").hidden = true; });

  function render() { readColors(); runLabel(); if (resize()) draw(); }
  render();
  return { render, show(run, day, t) { Object.assign(state, { run, day, t }); $("run").value = run; runLabel(); draw(); } };
};
