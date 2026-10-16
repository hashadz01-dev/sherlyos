import { spawn } from "node:child_process"
import { execFileSync } from "node:child_process"
import { readFileSync } from "node:fs"

const setupSql = readFileSync(new URL("./phase_3_2_storage.sql", import.meta.url), "utf8")
const cleanupSql = readFileSync(new URL("./phase_3_2_storage_cleanup.sql", import.meta.url), "utf8")
const password = "local-only"

const jpeg = Buffer.from([0xff, 0xd8, 0xff, 0xd9])
const png = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00])
const webp = Buffer.from([
  0x52, 0x49, 0x46, 0x46, 0x00, 0x00, 0x00, 0x00, 0x57, 0x45, 0x42, 0x50,
])
const textBytes = Buffer.from("not-an-image")

function psql(sql) {
  return new Promise((resolve, reject) => {
    const child = spawn(
      "docker",
      ["exec", "-i", "supabase_db_sherlyos", "psql", "-U", "postgres", "-d", "postgres", "-v", "ON_ERROR_STOP=1", "-q"],
      { stdio: ["pipe", "pipe", "pipe"] },
    )
    let output = ""
    child.stdout.on("data", (chunk) => {
      output += chunk
    })
    child.stderr.on("data", (chunk) => {
      output += chunk
    })
    child.on("close", (code) => {
      if (code === 0) resolve(output)
      else reject(new Error(output.trim()))
    })
    child.stdin.end(sql)
  })
}

function localApi() {
  let text = ""
  try {
    text = execFileSync("npx", ["supabase", "status", "-o", "env"], {
      encoding: "utf8",
      shell: true,
      stdio: ["ignore", "pipe", "pipe"],
    })
  } catch {
    throw new Error("local supabase status failed")
  }
  const read = (name) => {
    const match = text.match(new RegExp(`^${name}=(?:"([^"]+)"|([^\\n]+))$`, "m"))
    return match?.[1] ?? match?.[2] ?? ""
  }
  const apiUrl = read("API_URL")
  const anonKey = read("ANON_KEY") || read("PUBLISHABLE_KEY")
  if (!apiUrl.startsWith("http://127.0.0.1:") || !anonKey) {
    throw new Error("local supabase API is not available")
  }
  return { apiUrl, anonKey }
}

async function signIn(api, email) {
  const response = await fetch(`${api.apiUrl}/auth/v1/token?grant_type=password`, {
    method: "POST",
    headers: { apikey: api.anonKey, "content-type": "application/json" },
    body: JSON.stringify({ email, password }),
  })
  const body = await response.json()
  if (!response.ok || !body.access_token) {
    throw new Error(`sign-in failed for ${email}`)
  }
  return body.access_token
}

async function rpc(api, token, name, args) {
  const response = await fetch(`${api.apiUrl}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: {
      apikey: api.anonKey,
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
    },
    body: JSON.stringify(args),
  })
  const text = await response.text()
  let body = text
  try {
    body = text ? JSON.parse(text) : null
  } catch {
    body = text
  }
  if (!response.ok) {
    const message = typeof body === "object" && body && "message" in body ? body.message : text
    const error = new Error(String(message))
    error.status = response.status
    throw error
  }
  return body
}

async function expectFail(action, snippet) {
  try {
    await action()
  } catch (error) {
    if (!snippet || String(error.message).toLowerCase().includes(snippet.toLowerCase())) return
    throw error
  }
  throw new Error(`expected failure containing ${snippet}`)
}

async function uploadObject(api, token, path, bytes, mime) {
  const headers = {
    apikey: api.anonKey,
    "content-type": mime,
    "x-upsert": "false",
  }
  if (token) headers.authorization = `Bearer ${token}`
  const response = await fetch(
    `${api.apiUrl}/storage/v1/object/stock-verification-evidence/${path}`,
    { method: "POST", headers, body: bytes },
  )
  const text = await response.text()
  if (!response.ok) {
    const error = new Error(text || `upload failed ${response.status}`)
    error.status = response.status
    throw error
  }
}

async function attach(api, token, verificationId, bytes, mime, note) {
  const created = await rpc(api, token, "create_verification_photo_upload", {
    target_verification: verificationId,
    photo_note: note,
    target_line: null,
  })
  await uploadObject(api, token, created.path, bytes, mime)
  await rpc(api, token, "finalize_verification_photo_upload", {
    target_evidence: created.id,
    image_base64: bytes.toString("base64"),
  })
  return created
}

const api = localApi()
try {
  await psql(setupSql)
  const manager = await signIn(api, "manager.phase32photo@example.com")
  const keeper = await signIn(api, "keeper.phase32photo@example.com")
  const admin = await signIn(api, "admin.phase32photo@example.com")
  const other = await signIn(api, "other.phase32photo@example.com")
  const options = await rpc(api, manager, "list_verification_options", {})
  const godown = options.godowns.find((item) => item.code === "phase32_photo")
  const zone = options.zones.find((item) => item.code === "pz")
  const crate = options.crates.find((item) => item.code === "pca")
  const verificationId = await rpc(api, manager, "start_stock_verification", {
    target_godown: godown.id,
    verification_date: new Date().toISOString().slice(0, 10),
    zone_ids: [zone.id],
    crate_ids: [crate.id],
  })
  const detail = await rpc(api, manager, "get_stock_verification", {
    target_verification: verificationId,
  })
  const line = detail.lines[0]
  await rpc(api, manager, "save_verification_count", {
    target_line: line.id,
    counted_cases: line.expected_cases,
    expected_version: line.line_version,
  })
  await rpc(api, manager, "submit_stock_verification", { target_verification: verificationId })

  await expectFail(
    () =>
      rpc(api, manager, "close_stock_verification", {
        target_verification: verificationId,
        closure_result: "matched",
        closure_note: "missing photo",
      }),
    "photo evidence is required",
  )
  console.log("PASS missing photo blocks closure")

  const pending = await rpc(api, manager, "create_verification_photo_upload", {
    target_verification: verificationId,
    photo_note: "not finalized",
    target_line: null,
  })
  await expectFail(
    () =>
      rpc(api, manager, "close_stock_verification", {
        target_verification: verificationId,
        closure_result: "matched",
        closure_note: "unfinalized photo",
      }),
    "photo evidence is required",
  )
  console.log("PASS unfinalized upload does not satisfy closure")

  await uploadObject(api, manager, pending.path, jpeg, "image/jpeg")
  await rpc(api, manager, "finalize_verification_photo_upload", {
    target_evidence: pending.id,
    image_base64: jpeg.toString("base64"),
  })
  const located = await rpc(api, manager, "get_verification_photo_url", {
    target_evidence: pending.id,
  })
  const signed = await fetch(`${api.apiUrl}/storage/v1/object/sign/${located.bucket}/${located.path}`, {
    method: "POST",
    headers: {
      apikey: api.anonKey,
      authorization: `Bearer ${manager}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({ expiresIn: 60 }),
  })
  const signedBody = await signed.json()
  if (!signed.ok) throw new Error("authorized preview was denied")
  const signedPath = signedBody.signedURL || signedBody.signedUrl
  const preview = await fetch(`${api.apiUrl}/storage/v1${signedPath}`)
  const previewBytes = Buffer.from(await preview.arrayBuffer())
  if (!preview.ok || previewBytes[0] !== 0xff || previewBytes[1] !== 0xd8) {
    throw new Error("authorized preview did not return the photo")
  }
  const publicPreview = await fetch(
    `${api.apiUrl}/storage/v1/object/public/${located.bucket}/${located.path}`,
  )
  if (publicPreview.ok) throw new Error("public photo URL was accepted")
  console.log("PASS valid JPEG upload and authorized preview")

  await attach(api, manager, verificationId, png, "image/png", "png")
  console.log("PASS valid PNG upload")
  await attach(api, manager, verificationId, webp, "image/webp", "webp")
  console.log("PASS valid WebP upload")

  const oversized = Buffer.alloc(10_485_761, 0)
  oversized[0] = 0xff
  oversized[1] = 0xd8
  oversized[2] = 0xff
  const oversizedTicket = await rpc(api, manager, "create_verification_photo_upload", {
    target_verification: verificationId,
    photo_note: "too large",
    target_line: null,
  })
  await expectFail(
    () => uploadObject(api, manager, oversizedTicket.path, oversized, "image/jpeg"),
    "",
  )
  console.log("PASS oversized image rejected")

  const gifTicket = await rpc(api, manager, "create_verification_photo_upload", {
    target_verification: verificationId,
    photo_note: "gif",
    target_line: null,
  })
  await expectFail(() => uploadObject(api, manager, gifTicket.path, jpeg, "image/gif"), "")
  console.log("PASS unsupported MIME rejected")

  const spoof = await rpc(api, manager, "create_verification_photo_upload", {
    target_verification: verificationId,
    photo_note: "spoof",
    target_line: null,
  })
  await uploadObject(api, manager, spoof.path, textBytes, "image/jpeg")
  await expectFail(
    () =>
      rpc(api, manager, "finalize_verification_photo_upload", {
        target_evidence: spoof.id,
        image_base64: textBytes.toString("base64"),
      }),
    "photo content could not be verified",
  )
  console.log("PASS spoofed MIME/content rejected")

  await expectFail(() => uploadObject(api, null, pending.path, jpeg, "image/jpeg"), "")
  console.log("PASS anonymous upload rejected")

  await expectFail(
    () =>
      rpc(api, other, "create_verification_photo_upload", {
        target_verification: verificationId,
        photo_note: "other godown",
        target_line: null,
      }),
    "not authorized",
  )
  await expectFail(() => uploadObject(api, other, pending.path, jpeg, "image/jpeg"), "")
  console.log("PASS other-godown upload rejected")

  await expectFail(
    () => rpc(api, other, "get_verification_photo_url", { target_evidence: pending.id }),
    "not authorized",
  )
  const otherSign = await fetch(`${api.apiUrl}/storage/v1/object/sign/${located.bucket}/${located.path}`, {
    method: "POST",
    headers: {
      apikey: api.anonKey,
      authorization: `Bearer ${other}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({ expiresIn: 60 }),
  })
  if (otherSign.ok) throw new Error("other godown could sign a photo")
  console.log("PASS other-godown download rejected")

  const adminLocated = await rpc(api, admin, "get_verification_photo_url", {
    target_evidence: pending.id,
  })
  const adminSign = await fetch(
    `${api.apiUrl}/storage/v1/object/sign/${adminLocated.bucket}/${adminLocated.path}`,
    {
      method: "POST",
      headers: {
        apikey: api.anonKey,
        authorization: `Bearer ${admin}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({ expiresIn: 60 }),
    },
  )
  if (!adminSign.ok) throw new Error("admin preview was denied")
  await expectFail(
    () =>
      rpc(api, admin, "create_verification_photo_upload", {
        target_verification: verificationId,
        photo_note: "admin upload",
        target_line: null,
      }),
    "not authorized",
  )
  console.log("PASS admin read-only download")

  await attach(api, keeper, verificationId, jpeg, "image/jpeg", "keeper")
  console.log("PASS keeper authorized upload")

  await rpc(api, manager, "close_stock_verification", {
    target_verification: verificationId,
    closure_result: "matched",
    closure_note: "photos checked",
  })
  await expectFail(
    () =>
      rpc(api, manager, "create_verification_photo_upload", {
        target_verification: verificationId,
        photo_note: "after close",
        target_line: null,
      }),
    "closed verification cannot be changed",
  )
  console.log("PASS closed verification upload rejected")

  const deleted = await fetch(`${api.apiUrl}/storage/v1/object/stock-verification-evidence`, {
    method: "DELETE",
    headers: {
      apikey: api.anonKey,
      authorization: `Bearer ${manager}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({ prefixes: [located.path] }),
  })
  const deletedText = await deleted.text()
  if (deletedText.includes(located.path)) {
    throw new Error("closed photo deletion was accepted")
  }
  const stillThere = await fetch(`${api.apiUrl}/storage/v1/object/sign/${located.bucket}/${located.path}`, {
    method: "POST",
    headers: {
      apikey: api.anonKey,
      authorization: `Bearer ${manager}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({ expiresIn: 60 }),
  })
  const stillBody = await stillThere.json()
  const stillPath = stillBody.signedURL || stillBody.signedUrl
  const stillPreview = stillPath ? await fetch(`${api.apiUrl}/storage/v1${stillPath}`) : null
  if (!stillThere.ok || !stillPreview?.ok) throw new Error("closed photo deletion was accepted")
  console.log("PASS closed verification deletion rejected")
} finally {
  await psql(cleanupSql)
}
console.log("Phase 3.2 storage cleanup completed")
console.log("Phase 3.2 storage tests passed")
