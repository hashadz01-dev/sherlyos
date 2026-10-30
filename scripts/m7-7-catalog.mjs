/**
 * M7.7 Sherlys Distributors catalogue source.
 * Units-per-case live here and on billed_units_per_case after import.
 * The product row itself stores no quantity: stock remains one carton case.
 */
export const CATALOGUE_VERSION = "m7.7"

export const CATEGORIES = [
  { code: "TEA", name: "Tea & Tea Bags", description: "Catalogue code TEA." },
  { code: "COFFEE", name: "Coffee", description: "Catalogue code COFFEE." },
  { code: "EDIBLE_OILS", name: "Edible Oils", description: "Catalogue code EDIBLE_OILS." },
  { code: "RICE", name: "Rice & Grains", description: "Catalogue code RICE." },
  { code: "SUGAR", name: "Sugar & Sweeteners", description: "Catalogue code SUGAR." },
  { code: "JAGGERY", name: "Jaggery", description: "Catalogue code JAGGERY." },
  { code: "DAIRY", name: "Dairy & Milk Products", description: "Catalogue code DAIRY." },
  { code: "GHEE", name: "Ghee", description: "Catalogue code GHEE." },
  { code: "WHITENER", name: "Dairy Whitener", description: "Catalogue code WHITENER." },
  { code: "COCONUT", name: "Coconut Products", description: "Catalogue code COCONUT." },
  { code: "SPICES", name: "Spices & Masalas", description: "Catalogue code SPICES." },
  { code: "ATTA", name: "Wheat Flour & Atta", description: "Catalogue code ATTA." },
  { code: "DESSERTS", name: "Desserts & Mixes", description: "Catalogue code DESSERTS." },
]

/** Invoicing supplier is not verified. Records stay inactive; products keep supplier_id null. */
export const SUPPLIERS = [
  {
    ref: "AVT",
    name: "AVT (pending invoicing confirmation)",
    brands: "AVT Premium, Supreme, Raja, Gold Cup, Dairy Sure",
    verification: "Actual invoicing supplier pending",
    email: null,
    phone: null,
  },
  {
    ref: "KERA",
    name: "Kera (pending invoicing confirmation)",
    brands: "Kera coconut products",
    verification: "Actual invoicing supplier pending",
    email: null,
    phone: null,
  },
  {
    ref: "MK_AGROTECH",
    name: "MK Agrotech Pvt Ltd (manufacturer; invoicing pending)",
    brands: "SUNPURE, Ricebran Health, Palmpure",
    verification:
      "Manufacturer/marketer identified from SUNPURE catalogue. Not proven as Sherlys invoicing supplier. Address and manufacturer email are not stored: schema has no address column and email would imply a verified contact.",
    email: null,
    phone: null,
  },
  {
    ref: "PARRYS",
    name: "Parry's (pending invoicing confirmation)",
    brands: "Parry's sugar and jaggery",
    verification: "Actual invoicing supplier pending",
    email: null,
    phone: null,
  },
  {
    ref: "GOODLIFE",
    name: "GoodLife (pending invoicing confirmation)",
    brands: "GoodLife milk, Slim, Gold, Fresh Cream",
    verification: "Actual invoicing supplier pending",
    email: null,
    phone: null,
  },
  {
    ref: "MATTANAAD",
    name: "MattaNaad (pending invoicing confirmation)",
    brands: "MattaNaad Matta Vadi rice",
    verification:
      "TPF Bharat Private Limited is named on MattaNaad material and is not stored as the invoicing supplier.",
    email: null,
    phone: null,
  },
]

/**
 * @typedef {object} CatalogueProduct
 * @property {string | null} sku
 * @property {string} name
 * @property {string} categoryCode
 * @property {string} supplierRef
 * @property {string} brand
 * @property {string} packSize
 * @property {string} packagingType
 * @property {number | null} unitsPerCase
 * @property {string | null} billingUnit
 * @property {"CONFIRMED_DISTRIBUTION" | "CONFIRMED_PRODUCT" | "MANUFACTURER_CATALOGUE_ONLY"} sourceClass
 * @property {"INSERT" | "STAGE"} disposition
 * @property {string[]} reviewFlags
 * @property {string} notes
 */

function p(partial) {
  return {
    ...partial,
    reviewFlags: partial.reviewFlags ?? [],
    notes: partial.notes ?? "",
    billingUnit: partial.billingUnit ?? (partial.unitsPerCase == null ? null : "nos"),
  }
}

/** @type {CatalogueProduct[]} */
export const PRODUCTS = [
  // AVT Premium Tea Dust
  p({ sku: "AVT-PREM-DUST-100G", name: "AVT Premium Tea Dust 100g", categoryCode: "TEA", supplierRef: "AVT", brand: "AVT Premium", packSize: "100g", packagingType: "pack", unitsPerCase: 240, sourceClass: "CONFIRMED_DISTRIBUTION", disposition: "INSERT" }),
  p({ sku: "AVT-PREM-DUST-250G", name: "AVT Premium Tea Dust 250g", categoryCode: "TEA", supplierRef: "AVT", brand: "AVT Premium", packSize: "250g", packagingType: "pack", unitsPerCase: 96, sourceClass: "CONFIRMED_DISTRIBUTION", disposition: "INSERT" }),
  p({ sku: "AVT-PREM-DUST-500G", name: "AVT Premium Tea Dust 500g", categoryCode: "TEA", supplierRef: "AVT", brand: "AVT Premium", packSize: "500g", packagingType: "pack", unitsPerCase: 48, sourceClass: "CONFIRMED_DISTRIBUTION", disposition: "INSERT" }),
  p({ sku: "AVT-PREM-DUST-1KG", name: "AVT Premium Tea Dust 1kg", categoryCode: "TEA", supplierRef: "AVT", brand: "AVT Premium", packSize: "1kg", packagingType: "pack", unitsPerCase: 24, sourceClass: "CONFIRMED_DISTRIBUTION", disposition: "INSERT" }),
  // AVT Premium Tea Jar
  p({ sku: "AVT-PREM-JAR-100G", name: "AVT Premium Tea Jar 100g", categoryCode: "TEA", supplierRef: "AVT", brand: "AVT Premium", packSize: "100g", packagingType: "jar", unitsPerCase: 120, sourceClass: "CONFIRMED_DISTRIBUTION", disposition: "INSERT" }),
  p({ sku: "AVT-PREM-JAR-250G", name: "AVT Premium Tea Jar 250g", categoryCode: "TEA", supplierRef: "AVT", brand: "AVT Premium", packSize: "250g", packagingType: "jar", unitsPerCase: 48, sourceClass: "CONFIRMED_DISTRIBUTION", disposition: "INSERT" }),
  p({ sku: "AVT-PREM-JAR-500G", name: "AVT Premium Tea Jar 500g", categoryCode: "TEA", supplierRef: "AVT", brand: "AVT Premium", packSize: "500g", packagingType: "jar", unitsPerCase: 24, sourceClass: "CONFIRMED_DISTRIBUTION", disposition: "INSERT" }),
  // AVT Catering Blend
  p({ sku: "AVT-CATER-BLEND-1KG", name: "AVT Catering Blend 1kg", categoryCode: "TEA", supplierRef: "AVT", brand: "AVT", packSize: "1kg", packagingType: "pack", unitsPerCase: 24, sourceClass: "CONFIRMED_DISTRIBUTION", disposition: "INSERT" }),
  // AVT Premium Leaf
  p({ sku: "AVT-PREM-LEAF-100G", name: "AVT Premium Leaf 100g", categoryCode: "TEA", supplierRef: "AVT", brand: "AVT Premium", packSize: "100g", packagingType: "pack", unitsPerCase: 120, sourceClass: "CONFIRMED_DISTRIBUTION", disposition: "INSERT" }),
  p({ sku: "AVT-PREM-LEAF-250G", name: "AVT Premium Leaf 250g", categoryCode: "TEA", supplierRef: "AVT", brand: "AVT Premium", packSize: "250g", packagingType: "pack", unitsPerCase: 48, sourceClass: "CONFIRMED_DISTRIBUTION", disposition: "INSERT" }),
  // AVT Premium Select
  p({ sku: "AVT-PREM-SEL-100G", name: "AVT Premium Select 100g", categoryCode: "TEA", supplierRef: "AVT", brand: "AVT Premium Select", packSize: "100g", packagingType: "pack", unitsPerCase: 120, sourceClass: "CONFIRMED_DISTRIBUTION", disposition: "INSERT" }),
  p({ sku: "AVT-PREM-SEL-250G", name: "AVT Premium Select 250g", categoryCode: "TEA", supplierRef: "AVT", brand: "AVT Premium Select", packSize: "250g", packagingType: "pack", unitsPerCase: 48, sourceClass: "CONFIRMED_DISTRIBUTION", disposition: "INSERT" }),
  // AVT Raja
  p({ sku: "AVT-RAJA-DUST-250G", name: "AVT Raja Tea Dust 250g", categoryCode: "TEA", supplierRef: "AVT", brand: "AVT Raja", packSize: "250g", packagingType: "pack", unitsPerCase: 96, sourceClass: "CONFIRMED_DISTRIBUTION", disposition: "INSERT" }),
  p({ sku: "AVT-RAJA-DUST-1KG", name: "AVT Raja Tea Dust 1kg", categoryCode: "TEA", supplierRef: "AVT", brand: "AVT Raja", packSize: "1kg", packagingType: "pack", unitsPerCase: 24, sourceClass: "CONFIRMED_DISTRIBUTION", disposition: "INSERT" }),
  // AVT Supreme
  p({ sku: "AVT-SUPR-DUST-100G", name: "AVT Supreme Tea Dust 100g", categoryCode: "TEA", supplierRef: "AVT", brand: "AVT Supreme", packSize: "100g", packagingType: "pack", unitsPerCase: 240, sourceClass: "CONFIRMED_DISTRIBUTION", disposition: "INSERT" }),
  p({ sku: "AVT-SUPR-DUST-250G", name: "AVT Supreme Tea Dust 250g", categoryCode: "TEA", supplierRef: "AVT", brand: "AVT Supreme", packSize: "250g", packagingType: "pack", unitsPerCase: 96, sourceClass: "CONFIRMED_DISTRIBUTION", disposition: "INSERT" }),
  p({ sku: "AVT-SUPR-DUST-500G", name: "AVT Supreme Tea Dust 500g", categoryCode: "TEA", supplierRef: "AVT", brand: "AVT Supreme", packSize: "500g", packagingType: "pack", unitsPerCase: 48, sourceClass: "CONFIRMED_DISTRIBUTION", disposition: "INSERT" }),
  p({ sku: "AVT-SUPR-DUST-1KG", name: "AVT Supreme Tea Dust 1kg", categoryCode: "TEA", supplierRef: "AVT", brand: "AVT Supreme", packSize: "1kg", packagingType: "pack", unitsPerCase: 24, sourceClass: "CONFIRMED_DISTRIBUTION", disposition: "INSERT" }),
  // AVT Coffee
  p({ sku: "AVT-COFFEE-50G", name: "AVT Coffee Powder 50g", categoryCode: "COFFEE", supplierRef: "AVT", brand: "AVT", packSize: "50g", packagingType: "pack", unitsPerCase: 320, sourceClass: "CONFIRMED_DISTRIBUTION", disposition: "INSERT" }),
  p({ sku: "AVT-COFFEE-100G", name: "AVT Coffee Powder 100g", categoryCode: "COFFEE", supplierRef: "AVT", brand: "AVT", packSize: "100g", packagingType: "pack", unitsPerCase: 120, sourceClass: "CONFIRMED_DISTRIBUTION", disposition: "INSERT" }),
  p({ sku: "AVT-COFFEE-200G", name: "AVT Coffee Powder 200g", categoryCode: "COFFEE", supplierRef: "AVT", brand: "AVT", packSize: "200g", packagingType: "pack", unitsPerCase: 60, sourceClass: "CONFIRMED_DISTRIBUTION", disposition: "INSERT" }),
  p({ sku: "AVT-COFFEE-500G", name: "AVT Coffee Powder 500g", categoryCode: "COFFEE", supplierRef: "AVT", brand: "AVT", packSize: "500g", packagingType: "pack", unitsPerCase: 24, sourceClass: "CONFIRMED_DISTRIBUTION", disposition: "INSERT" }),
  // AVT Tea Bags — small boxes per outer carton. Stock unit remains the outer case.
  p({ sku: "AVT-TEABAG-25", name: "AVT Tea Bags 25", categoryCode: "TEA", supplierRef: "AVT", brand: "AVT", packSize: "25 bags", packagingType: "small_box", unitsPerCase: 36, billingUnit: "box", sourceClass: "CONFIRMED_DISTRIBUTION", disposition: "INSERT", reviewFlags: ["TEA_BAG_PACKING_MODEL"], notes: "Source counts small boxes per outer case. billed_units_per_case maps boxes; inventory stays one carton case." }),
  p({ sku: "AVT-TEABAG-100", name: "AVT Tea Bags 100", categoryCode: "TEA", supplierRef: "AVT", brand: "AVT", packSize: "100 bags", packagingType: "small_box", unitsPerCase: 18, billingUnit: "box", sourceClass: "CONFIRMED_DISTRIBUTION", disposition: "INSERT", reviewFlags: ["TEA_BAG_PACKING_MODEL"], notes: "Source counts small boxes per outer case. billed_units_per_case maps boxes; inventory stays one carton case." }),
  // AVT Gold Cup
  p({ sku: "AVT-GOLD-100G", name: "AVT Gold Cup 100g", categoryCode: "TEA", supplierRef: "AVT", brand: "AVT Gold Cup", packSize: "100g", packagingType: "pack", unitsPerCase: 120, sourceClass: "CONFIRMED_DISTRIBUTION", disposition: "INSERT" }),
  p({ sku: "AVT-GOLD-250G", name: "AVT Gold Cup 250g", categoryCode: "TEA", supplierRef: "AVT", brand: "AVT Gold Cup", packSize: "250g", packagingType: "pack", unitsPerCase: 48, sourceClass: "CONFIRMED_DISTRIBUTION", disposition: "INSERT" }),
  p({ sku: "AVT-GOLD-500G", name: "AVT Gold Cup 500g", categoryCode: "TEA", supplierRef: "AVT", brand: "AVT Gold Cup", packSize: "500g", packagingType: "pack", unitsPerCase: 24, sourceClass: "CONFIRMED_DISTRIBUTION", disposition: "INSERT" }),
  // AVT Green Tea Leaf — 100g case-pack 30 vs 250g 48 is asymmetric; catalogue values kept.
  p({ sku: "AVT-GTEA-LEAF-100G", name: "AVT Green Tea Leaf 100g", categoryCode: "TEA", supplierRef: "AVT", brand: "AVT", packSize: "100g", packagingType: "pack", unitsPerCase: 30, sourceClass: "CONFIRMED_DISTRIBUTION", disposition: "INSERT", reviewFlags: ["AMBIGUOUS_CASE_PACK"], notes: "100g lists 30 units/case while 250g lists 48. Catalogue values were not averaged or corrected." }),
  p({ sku: "AVT-GTEA-LEAF-250G", name: "AVT Green Tea Leaf 250g", categoryCode: "TEA", supplierRef: "AVT", brand: "AVT", packSize: "250g", packagingType: "pack", unitsPerCase: 48, sourceClass: "CONFIRMED_DISTRIBUTION", disposition: "INSERT", reviewFlags: ["AMBIGUOUS_CASE_PACK"], notes: "See AVT-GTEA-LEAF-100G packing note." }),
  p({ sku: "AVT-GTEA-BAG-10", name: "AVT Green Tea Bags 10", categoryCode: "TEA", supplierRef: "AVT", brand: "AVT", packSize: "10 bags", packagingType: "small_box", unitsPerCase: 24, billingUnit: "box", sourceClass: "CONFIRMED_DISTRIBUTION", disposition: "INSERT", reviewFlags: ["TEA_BAG_PACKING_MODEL"] }),
  p({ sku: "AVT-GTEA-BAG-30", name: "AVT Green Tea Bags 30", categoryCode: "TEA", supplierRef: "AVT", brand: "AVT", packSize: "30 bags", packagingType: "small_box", unitsPerCase: 30, billingUnit: "box", sourceClass: "CONFIRMED_DISTRIBUTION", disposition: "INSERT", reviewFlags: ["TEA_BAG_PACKING_MODEL", "AMBIGUOUS_CASE_PACK"], notes: "30 bags at 30 units/case is an odd packing; catalogue value kept." }),
  p({ sku: "AVT-GTEA-BAG-100", name: "AVT Green Tea Bags 100", categoryCode: "TEA", supplierRef: "AVT", brand: "AVT", packSize: "100 bags", packagingType: "small_box", unitsPerCase: 12, billingUnit: "box", sourceClass: "CONFIRMED_DISTRIBUTION", disposition: "INSERT", reviewFlags: ["TEA_BAG_PACKING_MODEL"] }),
  // AVT Ghee
  p({ sku: "AVT-GHEE-50ML", name: "AVT Ghee 50ml", categoryCode: "GHEE", supplierRef: "AVT", brand: "AVT", packSize: "50ml", packagingType: "pack", unitsPerCase: 72, sourceClass: "CONFIRMED_DISTRIBUTION", disposition: "INSERT" }),
  p({ sku: "AVT-GHEE-100ML", name: "AVT Ghee 100ml", categoryCode: "GHEE", supplierRef: "AVT", brand: "AVT", packSize: "100ml", packagingType: "pack", unitsPerCase: 120, sourceClass: "CONFIRMED_DISTRIBUTION", disposition: "INSERT" }),
  p({ sku: "AVT-GHEE-200ML", name: "AVT Ghee 200ml", categoryCode: "GHEE", supplierRef: "AVT", brand: "AVT", packSize: "200ml", packagingType: "pack", unitsPerCase: 72, sourceClass: "CONFIRMED_DISTRIBUTION", disposition: "INSERT" }),
  p({ sku: "AVT-GHEE-500ML", name: "AVT Ghee 500ml", categoryCode: "GHEE", supplierRef: "AVT", brand: "AVT", packSize: "500ml", packagingType: "pack", unitsPerCase: 36, sourceClass: "CONFIRMED_DISTRIBUTION", disposition: "INSERT" }),
  // AVT Dairy Whitener
  p({ sku: "AVT-WHITENER-10G", name: "AVT Dairy Whitener 10g", categoryCode: "WHITENER", supplierRef: "AVT", brand: "AVT", packSize: "10g", packagingType: "pack", unitsPerCase: 38, sourceClass: "CONFIRMED_DISTRIBUTION", disposition: "INSERT", reviewFlags: ["AMBIGUOUS_CASE_PACK"], notes: "10g lists 38 units/case; catalogue value kept." }),
  p({ sku: "AVT-WHITENER-200G", name: "AVT Dairy Whitener 200g", categoryCode: "WHITENER", supplierRef: "AVT", brand: "AVT", packSize: "200g", packagingType: "pack", unitsPerCase: 45, sourceClass: "CONFIRMED_DISTRIBUTION", disposition: "INSERT" }),
  p({ sku: "AVT-WHITENER-400G", name: "AVT Dairy Whitener 400g", categoryCode: "WHITENER", supplierRef: "AVT", brand: "AVT", packSize: "400g", packagingType: "pack", unitsPerCase: 24, sourceClass: "CONFIRMED_DISTRIBUTION", disposition: "INSERT" }),
  // Dairy Sure
  p({ sku: "DSURE-MS-STRW-200ML", name: "Dairy Sure Milkshake Strawberry 200ml", categoryCode: "DAIRY", supplierRef: "AVT", brand: "Dairy Sure", packSize: "200ml", packagingType: "pack", unitsPerCase: 27, sourceClass: "CONFIRMED_DISTRIBUTION", disposition: "INSERT" }),
  p({ sku: "DSURE-MS-VAN-200ML", name: "Dairy Sure Milkshake Vanilla 200ml", categoryCode: "DAIRY", supplierRef: "AVT", brand: "Dairy Sure", packSize: "200ml", packagingType: "pack", unitsPerCase: 27, sourceClass: "CONFIRMED_DISTRIBUTION", disposition: "INSERT" }),
  p({ sku: "DSURE-MS-CHOC-200ML", name: "Dairy Sure Milkshake Chocolate 200ml", categoryCode: "DAIRY", supplierRef: "AVT", brand: "Dairy Sure", packSize: "200ml", packagingType: "pack", unitsPerCase: 27, sourceClass: "CONFIRMED_DISTRIBUTION", disposition: "INSERT" }),
  p({ sku: "DSURE-MS-BTRSC-200ML", name: "Dairy Sure Milkshake Butterscotch 200ml", categoryCode: "DAIRY", supplierRef: "AVT", brand: "Dairy Sure", packSize: "200ml", packagingType: "pack", unitsPerCase: 27, sourceClass: "CONFIRMED_DISTRIBUTION", disposition: "INSERT" }),
  // Kera
  p({ sku: "KERA-COIL-500ML-PCH", name: "Kera Coconut Oil 500ml Pouch", categoryCode: "EDIBLE_OILS", supplierRef: "KERA", brand: "Kera", packSize: "500ml", packagingType: "pouch", unitsPerCase: 40, sourceClass: "CONFIRMED_DISTRIBUTION", disposition: "INSERT" }),
  p({ sku: "KERA-COIL-1L-PCH", name: "Kera Coconut Oil 1L Pouch", categoryCode: "EDIBLE_OILS", supplierRef: "KERA", brand: "Kera", packSize: "1L", packagingType: "pouch", unitsPerCase: 20, sourceClass: "CONFIRMED_DISTRIBUTION", disposition: "INSERT" }),
  p({ sku: "KERA-DESS-100G", name: "Kera Desiccated Coconut Powder 100g", categoryCode: "COCONUT", supplierRef: "KERA", brand: "Kera", packSize: "100g", packagingType: "pack", unitsPerCase: 48, sourceClass: "CONFIRMED_DISTRIBUTION", disposition: "INSERT" }),
  p({ sku: "KERA-CMPOW-100G", name: "Kera Coconut Milk Powder 100g", categoryCode: "COCONUT", supplierRef: "KERA", brand: "Kera", packSize: "100g", packagingType: "pack", unitsPerCase: 48, sourceClass: "CONFIRMED_DISTRIBUTION", disposition: "INSERT" }),
  // Parry's
  p({ sku: "PARRY-WHITE-500G", name: "Parry's White Label Sugar 500g", categoryCode: "SUGAR", supplierRef: "PARRYS", brand: "Parry's", packSize: "500g", packagingType: "pack", unitsPerCase: 40, sourceClass: "CONFIRMED_DISTRIBUTION", disposition: "INSERT" }),
  p({ sku: "PARRY-WHITE-1KG", name: "Parry's White Label Sugar 1kg", categoryCode: "SUGAR", supplierRef: "PARRYS", brand: "Parry's", packSize: "1kg", packagingType: "pack", unitsPerCase: 20, sourceClass: "CONFIRMED_DISTRIBUTION", disposition: "INSERT" }),
  p({ sku: "PARRY-WHITE-5KG", name: "Parry's White Label Sugar 5kg", categoryCode: "SUGAR", supplierRef: "PARRYS", brand: "Parry's", packSize: "5kg", packagingType: "pack", unitsPerCase: 6, sourceClass: "CONFIRMED_DISTRIBUTION", disposition: "INSERT" }),
  p({ sku: "PARRY-REF-1KG", name: "Parry's Pure Refined Sugar 1kg", categoryCode: "SUGAR", supplierRef: "PARRYS", brand: "Parry's", packSize: "1kg", packagingType: "pack", unitsPerCase: 20, sourceClass: "CONFIRMED_DISTRIBUTION", disposition: "INSERT" }),
  p({ sku: "PARRY-REF-1KG-JAR", name: "Parry's Pure Refined Sugar 1kg Jar", categoryCode: "SUGAR", supplierRef: "PARRYS", brand: "Parry's", packSize: "1kg", packagingType: "jar", unitsPerCase: 12, sourceClass: "CONFIRMED_DISTRIBUTION", disposition: "INSERT" }),
  p({ sku: "PARRY-REF-5KG", name: "Parry's Pure Refined Sugar 5kg", categoryCode: "SUGAR", supplierRef: "PARRYS", brand: "Parry's", packSize: "5kg", packagingType: "pack", unitsPerCase: 6, sourceClass: "CONFIRMED_DISTRIBUTION", disposition: "INSERT" }),
  p({ sku: "PARRY-CUBE-500G", name: "Parry's Pure Refined Sugar Cubes 500g", categoryCode: "SUGAR", supplierRef: "PARRYS", brand: "Parry's", packSize: "500g", packagingType: "pack", unitsPerCase: 24, sourceClass: "CONFIRMED_DISTRIBUTION", disposition: "INSERT" }),
  p({ sku: "PARRY-AMRIT-500G", name: "Parry's Amrit Sugar 500g", categoryCode: "SUGAR", supplierRef: "PARRYS", brand: "Parry's Amrit", packSize: "500g", packagingType: "pack", unitsPerCase: 40, sourceClass: "CONFIRMED_DISTRIBUTION", disposition: "INSERT" }),
  p({ sku: "PARRY-AMRIT-750G-JR", name: "Parry's Amrit Sugar 750g Jar", categoryCode: "SUGAR", supplierRef: "PARRYS", brand: "Parry's Amrit", packSize: "750g", packagingType: "jar", unitsPerCase: 12, sourceClass: "CONFIRMED_DISTRIBUTION", disposition: "INSERT" }),
  p({ sku: "PARRY-JAG-500G", name: "Parry's Amrit Jaggery 500g", categoryCode: "JAGGERY", supplierRef: "PARRYS", brand: "Parry's Amrit", packSize: "500g", packagingType: "pack", unitsPerCase: 24, sourceClass: "CONFIRMED_DISTRIBUTION", disposition: "INSERT" }),
  // GoodLife
  p({ sku: "GOODLIFE-MILK-180ML", name: "GoodLife Milk 180ml", categoryCode: "DAIRY", supplierRef: "GOODLIFE", brand: "GoodLife", packSize: "180ml", packagingType: "pack", unitsPerCase: 36, sourceClass: "CONFIRMED_DISTRIBUTION", disposition: "INSERT" }),
  p({ sku: "GOODLIFE-MILK-500ML", name: "GoodLife Milk 500ml", categoryCode: "DAIRY", supplierRef: "GOODLIFE", brand: "GoodLife", packSize: "500ml", packagingType: "pack", unitsPerCase: 24, sourceClass: "CONFIRMED_DISTRIBUTION", disposition: "INSERT" }),
  p({ sku: "GOODLIFE-MILK-1L", name: "GoodLife Milk 1L", categoryCode: "DAIRY", supplierRef: "GOODLIFE", brand: "GoodLife", packSize: "1L", packagingType: "pack", unitsPerCase: 12, sourceClass: "CONFIRMED_DISTRIBUTION", disposition: "INSERT" }),
  p({ sku: "GOODLIFE-SLIM-500ML", name: "GoodLife Slim Milk 500ml", categoryCode: "DAIRY", supplierRef: "GOODLIFE", brand: "GoodLife Slim", packSize: "500ml", packagingType: "pack", unitsPerCase: 24, sourceClass: "CONFIRMED_DISTRIBUTION", disposition: "INSERT" }),
  p({ sku: "GOODLIFE-SLIM-1L", name: "GoodLife Slim Milk 1L", categoryCode: "DAIRY", supplierRef: "GOODLIFE", brand: "GoodLife Slim", packSize: "1L", packagingType: "pack", unitsPerCase: 12, sourceClass: "CONFIRMED_DISTRIBUTION", disposition: "INSERT" }),
  p({ sku: "GOODLIFE-GOLD-1L", name: "GoodLife Gold Milk 1L", categoryCode: "DAIRY", supplierRef: "GOODLIFE", brand: "GoodLife Gold", packSize: "1L", packagingType: "pack", unitsPerCase: 12, sourceClass: "CONFIRMED_DISTRIBUTION", disposition: "INSERT" }),
  p({ sku: "GOODLIFE-CREAM-500ML", name: "GoodLife Fresh Cream 500ml", categoryCode: "DAIRY", supplierRef: "GOODLIFE", brand: "GoodLife", packSize: "500ml", packagingType: "pack", unitsPerCase: 24, sourceClass: "CONFIRMED_DISTRIBUTION", disposition: "INSERT" }),
  p({ sku: "GOODLIFE-CREAM-1L", name: "GoodLife Fresh Cream 1L", categoryCode: "DAIRY", supplierRef: "GOODLIFE", brand: "GoodLife", packSize: "1L", packagingType: "pack", unitsPerCase: 12, sourceClass: "CONFIRMED_DISTRIBUTION", disposition: "INSERT" }),
  // MattaNaad — confirmed product, unknown case pack. Not inserted.
  p({ sku: "MATTA-VADI-1KG", name: "MattaNaad Matta Vadi Rice 1kg", categoryCode: "RICE", supplierRef: "MATTANAAD", brand: "MattaNaad", packSize: "1kg", packagingType: "pack", unitsPerCase: null, sourceClass: "CONFIRMED_PRODUCT", disposition: "STAGE", notes: "Carton quantity unknown. Sack-as-case representation needs owner approval. 2kg is not listed." }),
  p({ sku: "MATTA-VADI-5KG", name: "MattaNaad Matta Vadi Rice 5kg", categoryCode: "RICE", supplierRef: "MATTANAAD", brand: "MattaNaad", packSize: "5kg", packagingType: "pack", unitsPerCase: null, sourceClass: "CONFIRMED_PRODUCT", disposition: "STAGE", notes: "Packaging images confirm 5kg. Carton quantity unknown." }),
  p({ sku: "MATTA-VADI-10KG", name: "MattaNaad Matta Vadi Rice 10kg", categoryCode: "RICE", supplierRef: "MATTANAAD", brand: "MattaNaad", packSize: "10kg", packagingType: "pack", unitsPerCase: null, sourceClass: "CONFIRMED_PRODUCT", disposition: "STAGE", notes: "Packaging images confirm 10kg. Carton quantity unknown." }),
  p({ sku: "MATTA-VADI-30KG", name: "MattaNaad Matta Vadi Rice 30kg", categoryCode: "RICE", supplierRef: "MATTANAAD", brand: "MattaNaad", packSize: "30kg", packagingType: "sack", unitsPerCase: null, sourceClass: "CONFIRMED_PRODUCT", disposition: "STAGE", notes: "Carton quantity unknown." }),
  p({ sku: "MATTA-VADI-50KG", name: "MattaNaad Matta Vadi Rice 50kg", categoryCode: "RICE", supplierRef: "MATTANAAD", brand: "MattaNaad", packSize: "50kg", packagingType: "sack", unitsPerCase: null, sourceClass: "CONFIRMED_PRODUCT", disposition: "STAGE", notes: "Carton quantity unknown." }),
  // SUNPURE distribution-confirmed
  p({ sku: "SUN-SFO-500ML-PCH", name: "Sunpure Sunflower Oil 500ml Pouch", categoryCode: "EDIBLE_OILS", supplierRef: "MK_AGROTECH", brand: "Sunpure", packSize: "500ml", packagingType: "pouch", unitsPerCase: 20, sourceClass: "CONFIRMED_DISTRIBUTION", disposition: "INSERT" }),
  p({ sku: "SUN-SFO-1L-PCH", name: "Sunpure Sunflower Oil 1L Pouch", categoryCode: "EDIBLE_OILS", supplierRef: "MK_AGROTECH", brand: "Sunpure", packSize: "1L", packagingType: "pouch", unitsPerCase: 10, sourceClass: "CONFIRMED_DISTRIBUTION", disposition: "INSERT" }),
  // SUNPURE manufacturer-only sunflower extras
  p({ sku: null, name: "Sunpure Sunflower Oil ₹10 pouch", categoryCode: "EDIBLE_OILS", supplierRef: "MK_AGROTECH", brand: "Sunpure", packSize: "unspecified", packagingType: "pouch", unitsPerCase: null, sourceClass: "MANUFACTURER_CATALOGUE_ONLY", disposition: "STAGE", notes: "Volume unspecified. No SKU assigned." }),
  p({ sku: "SUN-SFO-100ML-PCH", name: "Sunpure Sunflower Oil 100ml Pouch", categoryCode: "EDIBLE_OILS", supplierRef: "MK_AGROTECH", brand: "Sunpure", packSize: "100ml", packagingType: "pouch", unitsPerCase: null, sourceClass: "MANUFACTURER_CATALOGUE_ONLY", disposition: "STAGE" }),
  p({ sku: "SUN-SFO-200ML-PCH", name: "Sunpure Sunflower Oil 200ml Pouch", categoryCode: "EDIBLE_OILS", supplierRef: "MK_AGROTECH", brand: "Sunpure", packSize: "200ml", packagingType: "pouch", unitsPerCase: null, sourceClass: "MANUFACTURER_CATALOGUE_ONLY", disposition: "STAGE" }),
  p({ sku: "SUN-SFO-1L-PET", name: "Sunpure Sunflower Oil 1L PET Jar", categoryCode: "EDIBLE_OILS", supplierRef: "MK_AGROTECH", brand: "Sunpure", packSize: "1L", packagingType: "pet_jar", unitsPerCase: null, sourceClass: "MANUFACTURER_CATALOGUE_ONLY", disposition: "STAGE" }),
  p({ sku: "SUN-SFO-2L-PET", name: "Sunpure Sunflower Oil 2L PET Jar", categoryCode: "EDIBLE_OILS", supplierRef: "MK_AGROTECH", brand: "Sunpure", packSize: "2L", packagingType: "pet_jar", unitsPerCase: null, sourceClass: "MANUFACTURER_CATALOGUE_ONLY", disposition: "STAGE" }),
  p({ sku: "SUN-SFO-5L", name: "Sunpure Sunflower Oil 5L PET/HDPE", categoryCode: "EDIBLE_OILS", supplierRef: "MK_AGROTECH", brand: "Sunpure", packSize: "5L", packagingType: "pet_hdpe", unitsPerCase: null, sourceClass: "MANUFACTURER_CATALOGUE_ONLY", disposition: "STAGE" }),
  p({ sku: "SUN-SFO-10L-BKT", name: "Sunpure Sunflower Oil 10L Bucket", categoryCode: "EDIBLE_OILS", supplierRef: "MK_AGROTECH", brand: "Sunpure", packSize: "10L", packagingType: "bucket", unitsPerCase: null, sourceClass: "MANUFACTURER_CATALOGUE_ONLY", disposition: "STAGE" }),
  p({ sku: "SUN-SFO-15L-TIN", name: "Sunpure Sunflower Oil 15L/15kg Tin", categoryCode: "EDIBLE_OILS", supplierRef: "MK_AGROTECH", brand: "Sunpure", packSize: "15L/15kg", packagingType: "tin", unitsPerCase: null, sourceClass: "MANUFACTURER_CATALOGUE_ONLY", disposition: "STAGE", reviewFlags: ["AMBIGUOUS_PACK_SIZE"], notes: "Catalogue lists 15L / 15kg tin together." }),
  p({ sku: "SUN-SFO-15L-TAP", name: "Sunpure Sunflower Oil 15L Tap Jar", categoryCode: "EDIBLE_OILS", supplierRef: "MK_AGROTECH", brand: "Sunpure", packSize: "15L", packagingType: "tap_jar", unitsPerCase: null, sourceClass: "MANUFACTURER_CATALOGUE_ONLY", disposition: "STAGE" }),
  // Other SUNPURE manufacturer oils
  p({ sku: "SUN-GNO-500ML", name: "Sunpure Filtered Groundnut Oil 500ml", categoryCode: "EDIBLE_OILS", supplierRef: "MK_AGROTECH", brand: "Sunpure", packSize: "500ml", packagingType: "unspecified", unitsPerCase: null, sourceClass: "MANUFACTURER_CATALOGUE_ONLY", disposition: "STAGE" }),
  p({ sku: "SUN-GNO-1L", name: "Sunpure Filtered Groundnut Oil 1L", categoryCode: "EDIBLE_OILS", supplierRef: "MK_AGROTECH", brand: "Sunpure", packSize: "1L", packagingType: "unspecified", unitsPerCase: null, sourceClass: "MANUFACTURER_CATALOGUE_ONLY", disposition: "STAGE" }),
  p({ sku: "SUN-GNO-5L", name: "Sunpure Filtered Groundnut Oil 5L", categoryCode: "EDIBLE_OILS", supplierRef: "MK_AGROTECH", brand: "Sunpure", packSize: "5L", packagingType: "unspecified", unitsPerCase: null, sourceClass: "MANUFACTURER_CATALOGUE_ONLY", disposition: "STAGE" }),
  p({ sku: "SUN-GNO-15", name: "Sunpure Filtered Groundnut Oil 15kg/15L", categoryCode: "EDIBLE_OILS", supplierRef: "MK_AGROTECH", brand: "Sunpure", packSize: "15kg/15L", packagingType: "unspecified", unitsPerCase: null, sourceClass: "MANUFACTURER_CATALOGUE_ONLY", disposition: "STAGE", reviewFlags: ["AMBIGUOUS_PACK_SIZE"] }),
  p({ sku: "SUN-RBH-500ML", name: "Sunpure Ricebran Health Oil 500ml", categoryCode: "EDIBLE_OILS", supplierRef: "MK_AGROTECH", brand: "Ricebran Health", packSize: "500ml", packagingType: "unspecified", unitsPerCase: null, sourceClass: "MANUFACTURER_CATALOGUE_ONLY", disposition: "STAGE" }),
  p({ sku: "SUN-RBH-1L", name: "Sunpure Ricebran Health Oil 1L", categoryCode: "EDIBLE_OILS", supplierRef: "MK_AGROTECH", brand: "Ricebran Health", packSize: "1L", packagingType: "unspecified", unitsPerCase: null, sourceClass: "MANUFACTURER_CATALOGUE_ONLY", disposition: "STAGE" }),
  p({ sku: "SUN-RBH-5L", name: "Sunpure Ricebran Health Oil 5L", categoryCode: "EDIBLE_OILS", supplierRef: "MK_AGROTECH", brand: "Ricebran Health", packSize: "5L", packagingType: "unspecified", unitsPerCase: null, sourceClass: "MANUFACTURER_CATALOGUE_ONLY", disposition: "STAGE" }),
  p({ sku: "SUN-RBH-15", name: "Sunpure Ricebran Health Oil 15kg/15L", categoryCode: "EDIBLE_OILS", supplierRef: "MK_AGROTECH", brand: "Ricebran Health", packSize: "15kg/15L", packagingType: "unspecified", unitsPerCase: null, sourceClass: "MANUFACTURER_CATALOGUE_ONLY", disposition: "STAGE", reviewFlags: ["AMBIGUOUS_PACK_SIZE"] }),
  p({ sku: "SUN-MST-200ML-PET", name: "Sunpure Kachi Ghani Mustard Oil 200ml PET", categoryCode: "EDIBLE_OILS", supplierRef: "MK_AGROTECH", brand: "Sunpure", packSize: "200ml", packagingType: "pet_jar", unitsPerCase: null, sourceClass: "MANUFACTURER_CATALOGUE_ONLY", disposition: "STAGE" }),
  p({ sku: "SUN-MST-500ML-PET", name: "Sunpure Kachi Ghani Mustard Oil 500ml PET", categoryCode: "EDIBLE_OILS", supplierRef: "MK_AGROTECH", brand: "Sunpure", packSize: "500ml", packagingType: "pet_jar", unitsPerCase: null, sourceClass: "MANUFACTURER_CATALOGUE_ONLY", disposition: "STAGE" }),
  p({ sku: "SUN-MST-1L-PET", name: "Sunpure Kachi Ghani Mustard Oil 1L PET", categoryCode: "EDIBLE_OILS", supplierRef: "MK_AGROTECH", brand: "Sunpure", packSize: "1L", packagingType: "pet_jar", unitsPerCase: null, sourceClass: "MANUFACTURER_CATALOGUE_ONLY", disposition: "STAGE" }),
  p({ sku: "SUN-MST-500ML-PCH", name: "Sunpure Kachi Ghani Mustard Oil 500ml Pouch", categoryCode: "EDIBLE_OILS", supplierRef: "MK_AGROTECH", brand: "Sunpure", packSize: "500ml", packagingType: "pouch", unitsPerCase: null, sourceClass: "MANUFACTURER_CATALOGUE_ONLY", disposition: "STAGE" }),
  p({ sku: "SUN-MST-1L-PCH", name: "Sunpure Kachi Ghani Mustard Oil 1L Pouch", categoryCode: "EDIBLE_OILS", supplierRef: "MK_AGROTECH", brand: "Sunpure", packSize: "1L", packagingType: "pouch", unitsPerCase: null, sourceClass: "MANUFACTURER_CATALOGUE_ONLY", disposition: "STAGE" }),
  p({ sku: "SUN-VAN-50ML", name: "Sunpure Vanaspati 50ml", categoryCode: "EDIBLE_OILS", supplierRef: "MK_AGROTECH", brand: "Sunpure", packSize: "50ml", packagingType: "unspecified", unitsPerCase: null, sourceClass: "MANUFACTURER_CATALOGUE_ONLY", disposition: "STAGE" }),
  p({ sku: "SUN-VAN-100ML", name: "Sunpure Vanaspati 100ml", categoryCode: "EDIBLE_OILS", supplierRef: "MK_AGROTECH", brand: "Sunpure", packSize: "100ml", packagingType: "unspecified", unitsPerCase: null, sourceClass: "MANUFACTURER_CATALOGUE_ONLY", disposition: "STAGE" }),
  p({ sku: "SUN-VAN-200ML", name: "Sunpure Vanaspati 200ml", categoryCode: "EDIBLE_OILS", supplierRef: "MK_AGROTECH", brand: "Sunpure", packSize: "200ml", packagingType: "unspecified", unitsPerCase: null, sourceClass: "MANUFACTURER_CATALOGUE_ONLY", disposition: "STAGE" }),
  p({ sku: "SUN-VAN-500ML", name: "Sunpure Vanaspati 500ml", categoryCode: "EDIBLE_OILS", supplierRef: "MK_AGROTECH", brand: "Sunpure", packSize: "500ml", packagingType: "unspecified", unitsPerCase: null, sourceClass: "MANUFACTURER_CATALOGUE_ONLY", disposition: "STAGE" }),
  p({ sku: "SUN-VAN-1L-PCH", name: "Sunpure Vanaspati 1L Pouch", categoryCode: "EDIBLE_OILS", supplierRef: "MK_AGROTECH", brand: "Sunpure", packSize: "1L", packagingType: "pouch", unitsPerCase: null, sourceClass: "MANUFACTURER_CATALOGUE_ONLY", disposition: "STAGE" }),
  p({ sku: "SUN-VAN-15KG", name: "Sunpure Vanaspati 15kg Tin", categoryCode: "EDIBLE_OILS", supplierRef: "MK_AGROTECH", brand: "Sunpure", packSize: "15kg", packagingType: "tin", unitsPerCase: null, sourceClass: "MANUFACTURER_CATALOGUE_ONLY", disposition: "STAGE" }),
  p({ sku: "PALM-500ML", name: "Palmpure Refined Palmolein Oil 500ml", categoryCode: "EDIBLE_OILS", supplierRef: "MK_AGROTECH", brand: "Palmpure", packSize: "500ml", packagingType: "unspecified", unitsPerCase: null, sourceClass: "MANUFACTURER_CATALOGUE_ONLY", disposition: "STAGE" }),
  p({ sku: "PALM-1L", name: "Palmpure Refined Palmolein Oil 1L", categoryCode: "EDIBLE_OILS", supplierRef: "MK_AGROTECH", brand: "Palmpure", packSize: "1L", packagingType: "unspecified", unitsPerCase: null, sourceClass: "MANUFACTURER_CATALOGUE_ONLY", disposition: "STAGE" }),
  p({ sku: "PALM-15L-TIN", name: "Palmpure Refined Palmolein Oil 15L Tin", categoryCode: "EDIBLE_OILS", supplierRef: "MK_AGROTECH", brand: "Palmpure", packSize: "15L", packagingType: "tin", unitsPerCase: null, sourceClass: "MANUFACTURER_CATALOGUE_ONLY", disposition: "STAGE" }),
  p({ sku: "PALM-15KG-TIN", name: "Palmpure Refined Palmolein Oil 15kg Tin", categoryCode: "EDIBLE_OILS", supplierRef: "MK_AGROTECH", brand: "Palmpure", packSize: "15kg", packagingType: "tin", unitsPerCase: null, sourceClass: "MANUFACTURER_CATALOGUE_ONLY", disposition: "STAGE" }),
  p({ sku: "RBH-SOYA-500ML", name: "Ricebran Health Soya Bean Oil 500ml", categoryCode: "EDIBLE_OILS", supplierRef: "MK_AGROTECH", brand: "Ricebran Health", packSize: "500ml", packagingType: "unspecified", unitsPerCase: null, sourceClass: "MANUFACTURER_CATALOGUE_ONLY", disposition: "STAGE" }),
  p({ sku: "RBH-SOYA-1L", name: "Ricebran Health Soya Bean Oil 1L", categoryCode: "EDIBLE_OILS", supplierRef: "MK_AGROTECH", brand: "Ricebran Health", packSize: "1L", packagingType: "unspecified", unitsPerCase: null, sourceClass: "MANUFACTURER_CATALOGUE_ONLY", disposition: "STAGE" }),
  p({ sku: "RBH-SOYA-15", name: "Ricebran Health Soya Bean Oil 15kg/15L Tin", categoryCode: "EDIBLE_OILS", supplierRef: "MK_AGROTECH", brand: "Ricebran Health", packSize: "15kg/15L", packagingType: "tin", unitsPerCase: null, sourceClass: "MANUFACTURER_CATALOGUE_ONLY", disposition: "STAGE", reviewFlags: ["AMBIGUOUS_PACK_SIZE"] }),
  p({ sku: "SUN-ATTA-1KG", name: "Sunpure Swaad Chakki Atta 1kg", categoryCode: "ATTA", supplierRef: "MK_AGROTECH", brand: "Sunpure", packSize: "1kg", packagingType: "pack", unitsPerCase: null, sourceClass: "MANUFACTURER_CATALOGUE_ONLY", disposition: "STAGE" }),
  p({ sku: "SUN-ATTA-5KG", name: "Sunpure Swaad Chakki Atta 5kg", categoryCode: "ATTA", supplierRef: "MK_AGROTECH", brand: "Sunpure", packSize: "5kg", packagingType: "pack", unitsPerCase: null, sourceClass: "MANUFACTURER_CATALOGUE_ONLY", disposition: "STAGE" }),
  p({ sku: "SUN-ATTA-10KG", name: "Sunpure Swaad Chakki Atta 10kg", categoryCode: "ATTA", supplierRef: "MK_AGROTECH", brand: "Sunpure", packSize: "10kg", packagingType: "pack", unitsPerCase: null, sourceClass: "MANUFACTURER_CATALOGUE_ONLY", disposition: "STAGE" }),
  p({ sku: "SUN-SUGAR-250G", name: "Sunpure Premium Sugar 250g", categoryCode: "SUGAR", supplierRef: "MK_AGROTECH", brand: "Sunpure", packSize: "250g", packagingType: "pack", unitsPerCase: null, sourceClass: "MANUFACTURER_CATALOGUE_ONLY", disposition: "STAGE" }),
  p({ sku: "SUN-SUGAR-500G", name: "Sunpure Premium Sugar 500g", categoryCode: "SUGAR", supplierRef: "MK_AGROTECH", brand: "Sunpure", packSize: "500g", packagingType: "pack", unitsPerCase: null, sourceClass: "MANUFACTURER_CATALOGUE_ONLY", disposition: "STAGE" }),
  p({ sku: "SUN-SUGAR-1KG", name: "Sunpure Premium Sugar 1kg", categoryCode: "SUGAR", supplierRef: "MK_AGROTECH", brand: "Sunpure", packSize: "1kg", packagingType: "pack", unitsPerCase: null, sourceClass: "MANUFACTURER_CATALOGUE_ONLY", disposition: "STAGE" }),
  p({ sku: "SUN-SUGAR-5KG", name: "Sunpure Premium Sugar 5kg", categoryCode: "SUGAR", supplierRef: "MK_AGROTECH", brand: "Sunpure", packSize: "5kg", packagingType: "pack", unitsPerCase: null, sourceClass: "MANUFACTURER_CATALOGUE_ONLY", disposition: "STAGE" }),
  p({ sku: "SUN-KHAND-500G", name: "Sunpure Khandsari Sugar 500g", categoryCode: "SUGAR", supplierRef: "MK_AGROTECH", brand: "Sunpure", packSize: "500g", packagingType: "pack", unitsPerCase: null, sourceClass: "MANUFACTURER_CATALOGUE_ONLY", disposition: "STAGE" }),
  p({ sku: "SUN-KHAND-1KG", name: "Sunpure Khandsari Sugar 1kg", categoryCode: "SUGAR", supplierRef: "MK_AGROTECH", brand: "Sunpure", packSize: "1kg", packagingType: "pack", unitsPerCase: null, sourceClass: "MANUFACTURER_CATALOGUE_ONLY", disposition: "STAGE" }),
  p({ sku: "SUN-JAGPOW-500G", name: "Sunpure Jaggery Powder 500g", categoryCode: "JAGGERY", supplierRef: "MK_AGROTECH", brand: "Sunpure", packSize: "500g", packagingType: "pack", unitsPerCase: null, sourceClass: "MANUFACTURER_CATALOGUE_ONLY", disposition: "STAGE" }),
  p({ sku: "SUN-GULAB-90G", name: "Sunpure Gulab Jamun Mix Kesar Badam 90g", categoryCode: "DESSERTS", supplierRef: "MK_AGROTECH", brand: "Sunpure", packSize: "90g", packagingType: "pack", unitsPerCase: null, sourceClass: "MANUFACTURER_CATALOGUE_ONLY", disposition: "STAGE" }),
  p({ sku: "SUN-GULAB-120G", name: "Sunpure Gulab Jamun Mix Kesar Badam 120g", categoryCode: "DESSERTS", supplierRef: "MK_AGROTECH", brand: "Sunpure", packSize: "120g", packagingType: "pack", unitsPerCase: null, sourceClass: "MANUFACTURER_CATALOGUE_ONLY", disposition: "STAGE" }),
  // Spices: families only. No size matrix.
  p({ sku: null, name: "Sunpure Coriander Powder", categoryCode: "SPICES", supplierRef: "MK_AGROTECH", brand: "Sunpure", packSize: "unassigned", packagingType: "pouch", unitsPerCase: null, sourceClass: "MANUFACTURER_CATALOGUE_ONLY", disposition: "STAGE", notes: "Pouch sizes exist on the spice range but are not assigned per SKU." }),
  p({ sku: null, name: "Sunpure Chilli Powder", categoryCode: "SPICES", supplierRef: "MK_AGROTECH", brand: "Sunpure", packSize: "unassigned", packagingType: "pouch", unitsPerCase: null, sourceClass: "MANUFACTURER_CATALOGUE_ONLY", disposition: "STAGE", notes: "Pouch sizes exist on the spice range but are not assigned per SKU." }),
  p({ sku: null, name: "Sunpure Turmeric Powder", categoryCode: "SPICES", supplierRef: "MK_AGROTECH", brand: "Sunpure", packSize: "unassigned", packagingType: "pouch", unitsPerCase: null, sourceClass: "MANUFACTURER_CATALOGUE_ONLY", disposition: "STAGE", notes: "Pouch sizes exist on the spice range but are not assigned per SKU." }),
  p({ sku: null, name: "Sunpure Sambar Powder", categoryCode: "SPICES", supplierRef: "MK_AGROTECH", brand: "Sunpure", packSize: "unassigned", packagingType: "pouch", unitsPerCase: null, sourceClass: "MANUFACTURER_CATALOGUE_ONLY", disposition: "STAGE", notes: "Pouch sizes exist on the spice range but are not assigned per SKU." }),
  p({ sku: null, name: "Sunpure Rasam Powder", categoryCode: "SPICES", supplierRef: "MK_AGROTECH", brand: "Sunpure", packSize: "unassigned", packagingType: "pouch", unitsPerCase: null, sourceClass: "MANUFACTURER_CATALOGUE_ONLY", disposition: "STAGE", notes: "Pouch sizes exist on the spice range but are not assigned per SKU." }),
  p({ sku: null, name: "Sunpure Puliyogare Powder", categoryCode: "SPICES", supplierRef: "MK_AGROTECH", brand: "Sunpure", packSize: "unassigned", packagingType: "pouch", unitsPerCase: null, sourceClass: "MANUFACTURER_CATALOGUE_ONLY", disposition: "STAGE", notes: "Pouch sizes exist on the spice range but are not assigned per SKU." }),
]

export function insertableProducts() {
  return PRODUCTS.filter((row) => row.disposition === "INSERT")
}

export function stagedProducts() {
  return PRODUCTS.filter((row) => row.disposition === "STAGE")
}

export function skuList() {
  return PRODUCTS.map((row) => row.sku).filter(Boolean)
}
