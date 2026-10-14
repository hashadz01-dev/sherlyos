import { createClient } from "jsr:@supabase/supabase-js@2"

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
}

type CreateEmployeeBody = {
  fullName?: unknown
  email?: unknown
  phone?: unknown
  roleCode?: unknown
  password?: unknown
  passwordConfirm?: unknown
}

function json(status: number, body: { error?: string; id?: string }) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  })
}

function text(value: unknown) {
  return typeof value === "string" ? value.trim() : ""
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders })
  }

  if (request.method !== "POST") {
    return json(405, { error: "Use POST to add a user." })
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL")
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY")
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")
  const authorization = request.headers.get("Authorization")

  if (!supabaseUrl || !anonKey || !serviceKey || !authorization) {
    return json(401, { error: "Not signed in." })
  }

  let body: CreateEmployeeBody
  try {
    body = (await request.json()) as CreateEmployeeBody
  } catch {
    return json(400, { error: "The request could not be read." })
  }

  const fullName = text(body.fullName)
  const email = text(body.email).toLowerCase()
  const phone = text(body.phone)
  const roleCode = text(body.roleCode)
  const password = typeof body.password === "string" ? body.password : ""
  const passwordConfirm =
    typeof body.passwordConfirm === "string" ? body.passwordConfirm : ""

  if (fullName.length < 1 || fullName.length > 160) {
    return json(400, { error: "Enter the employee's name." })
  }
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
    return json(400, { error: "Enter a valid email address." })
  }
  if (phone.length < 7 || phone.length > 24 || phone !== phone.trim()) {
    return json(400, { error: "Enter a phone number." })
  }
  if (!/^[a-z0-9_]+$/.test(roleCode)) {
    return json(400, { error: "Select a user role." })
  }
  if (password.length < 8 || password.length > 72) {
    return json(400, { error: "Password must be 8 to 72 characters." })
  }
  if (password !== passwordConfirm) {
    return json(400, { error: "Password and re-typed password do not match." })
  }

  const caller = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false },
  })
  const { data: userData, error: userError } = await caller.auth.getUser()
  if (userError || !userData.user) {
    return json(401, { error: "Not signed in." })
  }

  const admin = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  })

  const { data: profile, error: profileError } = await admin
    .from("profiles")
    .select("is_active")
    .eq("id", userData.user.id)
    .maybeSingle()

  if (profileError || !profile?.is_active) {
    return json(403, { error: "Not authorized." })
  }

  const { data: memberships, error: membershipError } = await admin
    .from("user_roles")
    .select("role_id")
    .eq("user_id", userData.user.id)

  if (membershipError) {
    return json(500, { error: "The user could not be created." })
  }

  const roleIds = (memberships ?? []).map((row) => row.role_id as string)
  if (roleIds.length === 0) {
    return json(403, { error: "Not authorized." })
  }

  const { data: grants, error: grantError } = await admin
    .from("role_permissions")
    .select("permissions(code)")
    .in("role_id", roleIds)

  if (grantError) {
    return json(500, { error: "The user could not be created." })
  }

  const codes = new Set<string>()
  for (const grant of grants ?? []) {
    const permission = grant.permissions as
      { code: string } | { code: string }[] | null
    const list = Array.isArray(permission)
      ? permission
      : permission
        ? [permission]
        : []
    for (const item of list) {
      if (item?.code) codes.add(item.code)
    }
  }

  if (!codes.has("employees.manage") || !codes.has("roles.assign")) {
    return json(403, { error: "Not authorized." })
  }

  const { data: role, error: roleError } = await admin
    .from("roles")
    .select("id")
    .eq("code", roleCode)
    .maybeSingle()

  if (roleError || !role) {
    return json(400, { error: "Select a user role." })
  }

  const created = await admin.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
    user_metadata: { full_name: fullName, phone_number: phone },
  })

  if (created.error || !created.data.user) {
    const message = created.error?.message ?? ""
    if (/already|registered|exists/i.test(message)) {
      return json(409, { error: "A user with this email already exists." })
    }
    return json(400, {
      error: message || "The user could not be created.",
    })
  }

  const userId = created.data.user.id
  // The new-user trigger writes the name and phone. Direct profile updates
  // are revoked from service_role, so this function does not update that table.

  const assigned = await caller.rpc("assign_user_role", {
    target_user: userId,
    role_code: roleCode,
  })

  if (assigned.error) {
    await admin.auth.admin.deleteUser(userId)
    return json(400, { error: assigned.error.message })
  }

  return json(200, { id: userId })
})
