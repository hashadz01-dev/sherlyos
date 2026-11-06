/**
 * Order desk: a counter, a tray of paper slips, and a pen.
 * The slip under the pointer lifts; neighbours follow by distance.
 * Rules on each slip are what make the slabs paper. The slider is the stagger.
 */
const {
  Cam, facing, fit, proj, rings, prism, put, solid, seg,
  tdone, tset, tval, tween, disposer, mk, pointer, register,
} = HL;

const SW = 30, SD = 16, SH = 1.2, TOP = 15;
const XS = [-58, -32, -6, 20, 46];
const YS = [2, 7, 0, 6, 3];
const ZS = [0.4, 0, 1.7, 0.3, 0.8];

function mount({ stage, svg, read }, step) {
  const bag = disposer();
  const C = Cam(45, 0.5, 1.72);
  fit(C, [[-86, -26, 0], [96, 54, 0], [-86, -26, 48], [96, 54, 48]], 200, 172);
  const P = proj(C), front = facing(C);
  const g = mk("g", {}, svg);

  function slab(x0, y0, x1, y1, z0, z1, r) {
    const s = solid(g);
    const [ring, inner] = rings(x0, y0, x1, y1, r, 0.9);
    put(s, prism(P, front, ring, inner, z0, z1));
    return s;
  }

  slab(-82, -20, 90, 50, 0, TOP, 3.4);
  const apron = mk("path", { class: "nf lo" }, g);
  apron.setAttribute("d", seg(P(-66, 50, 5.5), P(74, 50, 5.5)) + seg(P(-66, 50, 10), P(74, 50, 10)));
  slab(-68, -12, 74, -6, TOP, TOP + 3.4, 1.2);

  const slips = XS.map(() => {
    const s = solid(g);
    return { s, rules: mk("path", { class: "nf lo" }, s.g), lift: tween(0) };
  });

  function drawSlip(i, lift) {
    const x = XS[i], y = YS[i], z = TOP + ZS[i] + lift;
    const [ring, inner] = rings(x, y, x + SW, y + SD, 1.2, 0.5);
    put(slips[i].s, prism(P, front, ring, inner, z, z + SH));
    slips[i].rules.setAttribute("d", [4.2, 8, 11.8].map((v) => seg(
      P(x + 3.2, y + v, z + SH),
      P(x + SW - 3.2, y + v, z + SH),
    )).join(""));
  }

  slab(-68, 24, 74, 30, TOP, TOP + 3.4, 1.2);
  slab(-8, 36, 36, 39.2, TOP, TOP + 1.6, 0.7);

  const centers = XS.map((x, i) => P(x + SW / 2, YS[i] + SD / 2, TOP + ZS[i] + SH));
  function hit([sx, sy]) {
    let best = -1, bd = 36 * 36;
    centers.forEach((c, i) => {
      const d = (sx - c[0]) ** 2 + (sy - c[1]) ** 2;
      if (d < bd) { bd = d; best = i; }
    });
    return best;
  }

  let prev = "";
  const B = register(stage, (_dt, now) => {
    const key = slips.map((sl) => tval(sl.lift, now).toFixed(2)).join(";");
    const moving = slips.some((sl) => !tdone(sl.lift, now));
    if (key === prev) return moving;
    prev = key;
    slips.forEach((_, i) => drawSlip(i, tval(slips[i].lift, now)));
    return moving;
  });
  bag.add(B.unregister);

  let act = -1;
  function setActive(a) {
    if (a === act) return;
    const now = performance.now(), from = a >= 0 ? a : act;
    act = a;
    slips.forEach((sl, i) => {
      const dist = Math.abs(i - (from < 0 ? 0 : from));
      const up = a < 0 ? 0 : i === a ? 18 + step * 0.1 : dist === 1 ? 5 : 0;
      tset(sl.lift, up, now, dist * step);
      sl.s.sil.classList.toggle("hi", a < 0 ? i === 2 : i === a);
    });
    read.textContent = a < 0 ? "rest" : "slip " + (a + 1);
    B.wake();
  }
  slips[2].s.sil.classList.add("hi");
  read.textContent = "rest";
  bag.add(pointer(stage, { move: (p) => setActive(hit(p)), leave: () => setActive(-1) }));
  bag.add(() => svg.replaceChildren());
  return { set: (v) => { step = v; }, destroy: bag.dispose };
}

hairline({
  name: "order-desk",
  means: "Paper slips in a tray on a counter: the one under the pointer lifts, and its neighbours follow.",
  rules: [1, 2, 5, 8],
  range: [0, 40, 90],
  tour: [[130, 175], [200, 155], [280, 165], null],
  mount,
});
