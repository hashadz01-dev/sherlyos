import { readFileSync, writeFileSync } from "node:fs"

const root = "c:/Users/Hash/Desktop/Hashdev/sherlyos"
const names = {
  "order-desk.js": ["orderDesk", "[[160, 200], [212, 180], [270, 205], null]"],
  "verify-ledger.js": ["verifyLedger", "[[130, 210], [175, 193], [230, 205], null]"],
  "pack-rack.js": ["packRack", "[[160, 180], [224, 167], [290, 185], null]"],
  "dispatch-bay.js": ["dispatchBay", "[[300, 230], [230, 200], [170, 170], null]"],
  "invoice-note.js": ["invoiceNote", "[[250, 210], [199, 191], [140, 175], null]"],
  "delivery-van.js": ["deliveryVan", "[[118, 169], [180, 200], [237, 227], null]"],
}

for (const [file, [fn, tour]] of Object.entries(names)) {
  let src = readFileSync(`${root}/drafts/login-figures/${file}`, "utf8").replace(/\r\n/g, "\n")
  src = src.replace(
    /^\/\*\*/,
    'import { HL } from "./kernel"\nimport { create, type FigureContext, type FigureOptions } from "./create"\n\n/**',
  )
  src = src.replace(
    /function mount\(\{ stage, svg, read \}, (\w+)\)/,
    "function mount({ stage, svg, read }: FigureContext, $1: number)",
  )
  src = src.replace(/tour: [\s\S]*?null\],/, `tour: ${tour},`)
  src = src.replace(
    /hairline\(\{([\s\S]*?)\}\)\s*;?\s*$/,
    `const spec = {$1}\n\nexport function ${fn}(el: HTMLElement, options?: FigureOptions) {\n  return create(spec, el, options)\n}\n`,
  )
  const out = `${root}/src/features/auth/stage/hairline/${file.replace(".js", ".ts")}`
  writeFileSync(out, src)
  console.log(file, src.includes("export function"), src.split("\n").length)
}
