/**
 * A box van on a road, heading for a shop with an awning and a front door.
 * Pointer distance along the road moves the van. At the shop the door slides
 * open, a carton is set on the step, and a tick plate appears. The slider is the trip.
 */
const {
  Cam, clamp, facing, fit, proj, rings, prism, put, solid, poly, circ, seg, open, unproj,
  spring, stepS, tdone, tset, tval, tween, disposer, mk, pointer, register,
} = HL;

function mount({ stage, svg, read }, trip) {
  const bag = disposer();
  const C = Cam(45, 0.5, 2.05);
  fit(C, [[-46, -42, 0], [78, 40, 0], [-46, -42, 48], [78, 40, 48]], 198, 168);
  const P = proj(C), front = facing(C);
  const g = mk("g", {}, svg);

  function slab(parent, x0, y0, x1, y1, z0, z1, r) {
    const s = solid(parent);
    const [ring, inner] = rings(x0, y0, x1, y1, r, 0.75);
    put(s, prism(P, front, ring, inner, z0, z1));
    return s;
  }

  slab(g, -44, 12, 58, 32, 0, 1.6, 1.2);
  const lane = mk("path", { class: "nf dash" }, g);
  lane.setAttribute("d", [-28, -4, 18].map((x) => seg(P(x, 20, 1.7), P(x + 10, 20, 1.7))).join(""));
  const shop = slab(g, 16, -36, 58, -4, 0, 38, 1.6);
  const doorway = mk("path", { class: "nf lo" }, g);
  doorway.setAttribute("d", poly([
    P(36, -4, 0.2), P(52, -4, 0.2), P(52, -4, 20), P(36, -4, 20),
  ]));
  slab(g, 20, -14, 66, 2, 24, 28, 1.2);
  slab(g, 34, -4, 58, 14, 0, 2.4, 1);
  // After the awning, so an open door is not buried under the awning's fill.
  const door = solid(g);
  const carton = solid(g);
  const tick = solid(g);
  const mark = mk("path", { class: "nf" }, g);
  const cargo = solid(g);
  const cab = solid(g);
  const glass = mk("path", { class: "nf lo" }, g);
  const wheels = [0, 1].map(() => mk("path", { class: "sil" }, g));

  const along = spring(0.22);
  const doorT = tween(0);
  const drop = tween(0);
  let arrived = false;

  function pose(t, doorN, dropN) {
    const x0 = -46 + t * trip;
    put(cargo, prism(P, front, ...(() => { const [ring, inner] = rings(x0, 14, x0 + 26, 28, 1.4, 0.55); return [ring, inner, 6, 24]; })()));
    put(cab, prism(P, front, ...(() => { const [ring, inner] = rings(x0 + 24, 15, x0 + 40, 28, 1.3, 0.5); return [ring, inner, 6, 16]; })()));
    const fx = x0 + 40;
    glass.setAttribute("d", poly([P(fx, 18, 9), P(fx, 25.5, 9), P(fx, 25.5, 14.5), P(fx, 18, 14.5)]));
    wheels.forEach((w, i) => {
      const cx = x0 + (i === 0 ? 8 : 32);
      w.setAttribute("d", poly(circ(5.6, 16).map((q) => P(cx + q.u, 28, 5.6 + q.v))));
    });
    const dx = 36 + doorN * 22;
    put(door, prism(P, front, ...(() => {     const [ring, inner] = rings(dx, -6.2, dx + 14, -3.6, 0.4, 0.2); return [ring, inner, 0.4, 19.5]; })()));
    const cz = 2.4 + (1 - dropN) * 14;
    const homeX = x0 + 8;
    const cx = homeX + dropN * (42 - homeX);
    const cy = 18 + dropN * (2 - 18);
    put(carton, prism(P, front, ...(() => { const [ring, inner] = rings(cx, cy, cx + 8, cy + 8, 0.8, 0.35); return [ring, inner, cz, cz + 7]; })()));
    if (dropN < 0.55) {
      tick.sil.setAttribute("d", "");
      tick.cr.setAttribute("d", "");
      mark.setAttribute("d", "");
    } else {
      put(tick, prism(P, front, ...(() => { const [ring, inner] = rings(52, 3, 62, 11, 0.9, 0.4); return [ring, inner, 2.5, 3.6]; })()));
      mark.setAttribute("d", open([P(54, 7.2, 3.7), P(56.4, 4.8, 3.7), P(60.2, 9.2, 3.7)]));
    }
    cargo.sil.classList.toggle("hi", dropN < 0.55);
    tick.sil.classList.toggle("hi", dropN >= 0.55);
    mark.classList.toggle("hi", dropN >= 0.55);
    shop.sil.classList.remove("hi");
  }

  let prev = "";
  const B = register(stage, (dt, now) => {
    const moving = stepS(along, dt) || !tdone(doorT, now) || !tdone(drop, now);
    const want = along.t > 0.82;
    if (want !== arrived) {
      arrived = want;
      tset(doorT, want ? 1 : 0, now, 0);
      tset(drop, want ? 1 : 0, now, want ? 120 : 0);
    }
    const key = [along.x, tval(doorT, now), tval(drop, now)].map((n) => n.toFixed(2)).join(";");
    if (key !== prev) {
      prev = key;
      pose(along.x, tval(doorT, now), tval(drop, now));
    }
    return moving;
  });
  bag.add(B.unregister);

  function aim([sx, sy]) {
    const [x] = unproj(C, sx, sy, 2);
    along.t = clamp((x + 46) / Math.max(trip, 1), 0, 1);
    read.textContent = along.t > 0.82 ? "shop" : "van";
    B.wake();
  }
  function leave() {
    along.t = 0.22;
    read.textContent = "rest";
    B.wake();
  }
  read.textContent = "rest";
  bag.add(pointer(stage, { move: aim, leave }));
  bag.add(() => svg.replaceChildren());
  return { set: (v) => { trip = v; }, destroy: bag.dispose };
}

hairline({
  name: "delivery-van",
  means: "A box van on a road to a shop: at the door it stops, a carton is set down, and a tick plate shows.",
  rules: [1, 3, 5, 8],
  range: [18, 36, 42],
  tour: [[120, 180], [210, 160], [300, 140], null],
  mount,
});
