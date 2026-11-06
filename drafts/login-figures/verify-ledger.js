/**
 * Accounts ledger: a thick book with a fore-edge, a bookmark, and a stamp press.
 * The band under the pointer is pressed; a tick plate rises there, and the
 * neighbouring bands rise less. The slider is how proud the plate stands.
 */
const {
  Cam, facing, fit, proj, rings, prism, put, solid, seg, open,
  tdone, tset, tval, tween, disposer, mk, pointer, register,
} = HL;

const TOP = 16;
const BANDS = [-24, 0, 24];

function mount({ stage, svg, read }, press) {
  const bag = disposer();
  const C = Cam(45, 0.5, 2.35);
  fit(C, [[-52, -40, 0], [62, 52, 0], [-52, -40, 56], [62, 52, 56]], 200, 166);
  const P = proj(C), front = facing(C);
  const g = mk("g", {}, svg);

  function slab(x0, y0, x1, y1, z0, z1, r) {
    const s = solid(g);
    const [ring, inner] = rings(x0, y0, x1, y1, r, 0.85);
    put(s, prism(P, front, ring, inner, z0, z1));
    return s;
  }

  const book = slab(-40, -16, 44, 36, 0, TOP, 2.2);
  const pages = mk("path", { class: "nf lo" }, g);
  pages.setAttribute("d", [0.2, 0.36, 0.52, 0.68, 0.84].map((t) => seg(P(44, -12, TOP * t), P(44, 32, TOP * t))).join("")
    + [8, 16, 24].map((y) => seg(P(-32, y, TOP), P(36, y, TOP))).join(""));
  slab(-2, 30, 6, 40, TOP - 10, TOP + 1.2, 0.6);
  slab(-5, -34, 9, -18, TOP, TOP + 28, 1.3);
  slab(-7, -32, 11, 4, TOP + 24, TOP + 28, 1.1);
  slab(-3, -30, 7, -22, TOP + 28, TOP + 32, 1.4);

  const head = solid(g);
  const ticks = BANDS.map(() => {
    const s = solid(g);
    return { s, mark: mk("path", { class: "nf" }, s.g), z: tween(0) };
  });

  function drawHead(x, z) {
    const [ring, inner] = rings(x - 8, 4, x + 8, 20, 1.5, 0.6);
    put(head, prism(P, front, ring, inner, z, z + 4.2));
  }
  function drawTick(i, rise) {
    const x = BANDS[i], y = 10, z = TOP + 0.15;
    if (rise < 0.35) {
      ticks[i].s.sil.setAttribute("d", "");
      ticks[i].s.cr.setAttribute("d", "");
      ticks[i].mark.setAttribute("d", "");
      return;
    }
    const [ring, inner] = rings(x - 5.5, y, x + 5.5, y + 9, 1.1, 0.45);
    put(ticks[i].s, prism(P, front, ring, inner, z, z + rise));
    const zf = z + rise;
    ticks[i].mark.setAttribute("d", open([
      P(x - 3.2, y + 4.2, zf), P(x - 0.8, y + 2.2, zf), P(x + 3.6, y + 7, zf),
    ]));
  }

  const centers = BANDS.map((x) => P(x, 16, TOP + 0.4));
  function hit([sx, sy]) {
    let best = -1, bd = 48 * 48;
    centers.forEach((c, i) => {
      const d = (sx - c[0]) ** 2 + (sy - c[1]) ** 2;
      if (d < bd) { bd = d; best = i; }
    });
    return best;
  }

  const headX = tween(0);
  const headZ = tween(TOP + 18);
  let prev = "";
  const B = register(stage, (_dt, now) => {
    const hz = tval(headZ, now), hx = tval(headX, now);
    const rises = ticks.map((tk) => tval(tk.z, now));
    const key = [hx, hz, ...rises].map((n) => n.toFixed(2)).join(";");
    const moving = !tdone(headX, now) || !tdone(headZ, now) || ticks.some((tk) => !tdone(tk.z, now));
    if (key === prev) return moving;
    prev = key;
    drawHead(hx, hz);
    rises.forEach((rise, i) => drawTick(i, rise));
    return moving;
  });
  bag.add(B.unregister);

  let act = -1;
  function setActive(a) {
    if (a === act) return;
    const now = performance.now(), from = a < 0 ? act : a;
    act = a;
    tset(headX, a < 0 ? 0 : BANDS[a], now, 0);
    tset(headZ, a < 0 ? TOP + 18 : TOP + 1.4, now, 50);
    ticks.forEach((tk, i) => {
      const dist = Math.abs(i - (from < 0 ? 1 : from));
      const rise = a < 0 ? 0 : i === a ? press : dist === 1 ? press * 0.28 : 0;
      tset(tk.z, rise, now, dist * 40);
      const on = i === a;
      tk.s.sil.classList.toggle("hi", on);
      tk.mark.classList.toggle("hi", on);
    });
    book.sil.classList.toggle("hi", a < 0);
    read.textContent = a < 0 ? "rest" : "line " + (a + 1);
    B.wake();
  }
  book.sil.classList.add("hi");
  read.textContent = "rest";
  bag.add(pointer(stage, { move: (p) => setActive(hit(p)), leave: () => setActive(-1) }));
  bag.add(() => svg.replaceChildren());
  return { set: (v) => { press = v; }, destroy: bag.dispose };
}

hairline({
  name: "verify-ledger",
  means: "A ledger and a stamp press: the band under the pointer is pressed, and a tick plate rises on it.",
  rules: [1, 2, 4, 8],
  range: [0.8, 2.2, 4.2],
  tour: [[140, 170], [200, 150], [270, 155], null],
  mount,
});
