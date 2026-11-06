/**
 * Dispatch bay: rollers, a short ramp, and the open rear of a box truck.
 * The pointer runs the belt. Cartons ride toward the door; the truck hides
 * any that have gone inside. The slider is how far one turn of the belt carries them.
 */
const {
  Cam, clamp, facing, fit, proj, rings, prism, put, solid, poly, circ, unproj,
  spring, stepS, disposer, mk, pointer, register,
} = HL;

const BED = 8;

function mount({ stage, svg, read }, reach) {
  const bag = disposer();
  const C = Cam(45, 0.5, 1.88);
  fit(C, [[-78, -36, 0], [96, 48, 0], [-78, -36, 44], [96, 48, 44]], 200, 170);
  const P = proj(C), front = facing(C);
  const g = mk("g", {}, svg);

  function slab(parent, x0, y0, x1, y1, z0, z1, r) {
    const s = solid(parent);
    const [ring, inner] = rings(x0, y0, x1, y1, r, 0.7);
    put(s, prism(P, front, ring, inner, z0, z1));
    return s;
  }

  const rollers = [];
  for (let i = 0; i < 7; i++) {
    const x = 8 + i * 11;
    rollers.push(slab(g, x, -6, x + 7, 18, BED, BED + 3.2, 3.2));
  }
  slab(g, -8, -4, 4, 16, BED, BED + 4, 1);
  slab(g, -18, -2, -6, 14, BED + 4, BED + 8, 1);
  slab(g, -28, 0, -16, 12, BED + 8, BED + 12, 1);

  const homes = [78, 56, 34];
  const cartons = homes.map(() => solid(g));
  const truck = slab(g, -74, -24, -22, 28, BED + 6, 36, 2);
  const opening = mk("path", { class: "nf lo" }, g);
  opening.setAttribute("d", poly([
    P(-22, -8, BED + 10), P(-22, 16, BED + 10), P(-22, 16, 32), P(-22, -8, 32),
  ]));
  slab(g, -20, 18, -14, 40, BED + 8, 33, 0.8);
  const wheels = [ -62, -36 ].map((x) => mk("path", { class: "sil" }, g));
  wheels.forEach((w, i) => {
    const x = [-62, -36][i];
    w.setAttribute("d", poly(circ(6.5, 18).map((q) => P(x + q.u, 28, 6.5 + q.v))));
  });

  function drawCarton(i, belt) {
    const x = homes[i] - belt * reach;
    const [ring, inner] = rings(x, -1, x + 12, 11, 1.1, 0.45);
    put(cartons[i], prism(P, front, ring, inner, BED + 3.2, BED + 12));
  }

  const belt = spring(0.18);
  let prev = -1, lit = -1, hot = false;
  const B = register(stage, (dt) => {
    const moving = stepS(belt, dt);
    const q = Math.round(belt.x * 40);
    if (q !== prev) {
      prev = q;
      homes.forEach((_, i) => drawCarton(i, belt.x));
      const lead = homes.findIndex((h, i) => h - belt.x * reach > -22);
      const on = lead < 0 ? 0 : lead;
        if (hot && on !== lit) {
        lit = on;
        cartons.forEach((c, i) => c.sil.classList.toggle("hi", i === on));
        truck.sil.classList.remove("hi");
      }
    }
    return moving;
  });
  bag.add(B.unregister);
  truck.sil.classList.add("hi");

  function aim([sx, sy]) {
    const [x] = unproj(C, sx, sy, BED);
    hot = true;
    belt.t = clamp((82 - x) / 96, 0, 1);
    const n = 1 + Math.round(belt.t * 4);
    read.textContent = "roll " + n;
    B.wake();
  }
  function leave() {
    hot = false;
    belt.t = 0.18;
    read.textContent = "rest";
    truck.sil.classList.add("hi");
    cartons.forEach((c) => c.sil.classList.remove("hi"));
    lit = -1;
    B.wake();
  }
  read.textContent = "rest";
  bag.add(pointer(stage, { move: aim, leave }));
  bag.add(() => svg.replaceChildren());
  return { set: (v) => { reach = v; }, destroy: bag.dispose };
}

hairline({
  name: "dispatch-bay",
  means: "Rollers run up a ramp into the back of a box truck, and the cartons ride in with the pointer.",
  rules: [1, 3, 6, 8],
  range: [36, 64, 96],
  tour: [[250, 180], [190, 160], [130, 150], null],
  mount,
});
