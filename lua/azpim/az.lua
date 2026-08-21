-- PIM operations. Azure resource roles go through ARM, authenticated with a
-- token from `az account get-access-token` that we cache and reuse; Entra ID
-- roles go through graph.lua, which holds its own token because the CLI's
-- app registration can never obtain the Graph role-management scopes.
--
-- We still shell out to `az` to *obtain* the ARM token (it already knows how
-- to refresh silently from the CLI's own login), but every actual REST call
-- goes straight over `curl` with that cached bearer token. Each `az`
-- invocation costs roughly 1-3s of Python interpreter/import overhead before
-- it even reaches the network, and a refresh used to spin up several of
-- them (`az rest` per page, per section); caching the token cuts that down
-- to one `az` call per hour instead of one per request.
local graph = require("azpim.graph")
local http = require("azpim.http")

local M = {}

local ARM = "https://management.azure.com"
local ARM_API = "2020-10-01"
local GRAPH = "https://graph.microsoft.com/v1.0"

---@param args string[] arguments passed to `az`
---@param cb fun(data: table|nil, err: string|nil)
local function az_json(args, cb)
  local cmd = { "az" }
  vim.list_extend(cmd, args)
  local ok, err = pcall(vim.system, cmd, { text = true }, function(out)
    vim.schedule(function()
      if out.code ~= 0 then
        local msg = out.stderr
        if msg == nil or msg:match("^%s*$") then
          msg = out.stdout
        end
        cb(nil, vim.trim(msg or ("az exited with " .. tostring(out.code))))
        return
      end
      if out.stdout == nil or out.stdout:match("^%s*$") then
        cb({}, nil)
        return
      end
      -- luanil: JSON null decodes to vim.NIL otherwise, which is *truthy*.
      local decoded, data = pcall(vim.json.decode, out.stdout, { luanil = { object = true } })
      if not decoded then
        cb(nil, "could not parse az output as JSON: " .. tostring(data))
        return
      end
      cb(data, nil)
    end)
  end)
  if not ok then
    vim.schedule(function()
      cb(nil, "failed to run az: " .. tostring(err))
    end)
  end
end

-- ---------------------------------------------------------------------------
-- ARM token cache
-- ---------------------------------------------------------------------------

local arm_session = { access_token = nil, expires_at = 0, claims = nil }

--- Get a cached ARM bearer token, fetching/refreshing via the Azure CLI only
--- when we don't have one or it's about to expire.
---@param cb fun(token: string|nil, err: string|nil)
local function arm_token(cb)
  if arm_session.access_token and arm_session.expires_at - 60 > os.time() then
    return cb(arm_session.access_token, nil)
  end
  az_json({ "account", "get-access-token", "--resource", ARM, "-o", "json" }, function(data, err)
    if err then
      return cb(nil, err)
    end
    if not data.accessToken then
      return cb(nil, "az did not return an access token")
    end
    arm_session.access_token = data.accessToken
    arm_session.expires_at = tonumber(data.expires_on) or (os.time() + 3000)
    arm_session.claims = http.jwt_claims(data.accessToken)
    cb(arm_session.access_token, nil)
  end)
end

--- GET a URL, following `nextLink` / `@odata.nextLink` until exhausted.
local function get_all(url, cb, acc)
  acc = acc or {}
  arm_token(function(token, terr)
    if terr then
      return cb(nil, terr)
    end
    http.curl({
      "-X",
      "GET",
      http.encode_query(url),
      "-H",
      "Authorization: Bearer " .. token,
    }, function(data, err)
      if err then
        return cb(nil, err)
      end
      if data.error then
        return cb(nil, (data.error.message or data.error.code or vim.inspect(data.error)))
      end
      vim.list_extend(acc, data.value or {})
      local next_link = data.nextLink or data["@odata.nextLink"]
      if next_link then
        get_all(next_link, cb, acc)
      else
        cb(acc, nil)
      end
    end)
  end)
end

local function send(method, url, body, cb)
  arm_token(function(token, terr)
    if terr then
      return cb(nil, terr)
    end
    local path = vim.fn.tempname() .. ".json"
    local fh, ferr = io.open(path, "w")
    if not fh then
      return cb(nil, "could not write request body: " .. tostring(ferr))
    end
    fh:write(vim.json.encode(body))
    fh:close()
    http.curl({
      "-X",
      method:upper(),
      http.encode_query(url),
      "-H",
      "Authorization: Bearer " .. token,
      "-H",
      "Content-Type: application/json",
      "--data-binary",
      "@" .. path,
    }, function(data, err)
      os.remove(path)
      if err then
        return cb(nil, err)
      end
      if data.error then
        return cb(nil, (data.error.message or data.error.code or vim.inspect(data.error)))
      end
      cb(data, nil)
    end)
  end)
end

local function uuid()
  local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
  return (
    template:gsub("[xy]", function(c)
      local v = (c == "x") and math.random(0, 15) or math.random(8, 11)
      return string.format("%x", v)
    end)
  )
end

local function now_iso()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

--- Object id of the signed-in user. The ARM access token already carries it
--- as the `oid` claim, so this piggybacks on `arm_token` instead of spinning
--- up a dedicated `az ad signed-in-user show` process.
local cached_oid
function M.signed_in_user(cb)
  if cached_oid then
    return cb(cached_oid, nil)
  end
  arm_token(function(_, err)
    if err then
      return cb(nil, err)
    end
    local oid = arm_session.claims and arm_session.claims.oid
    if not oid then
      -- Fallback for the unlikely case the token shape changes underneath us.
      return az_json({ "ad", "signed-in-user", "show", "-o", "json" }, function(data, aerr)
        if aerr then
          return cb(nil, aerr)
        end
        cached_oid = data.id
        cb(data.id, nil)
      end)
    end
    cached_oid = oid
    cb(oid, nil)
  end)
end

function M.account(cb)
  az_json({ "account", "show", "-o", "json" }, cb)
end

-- ---------------------------------------------------------------------------
-- Azure resource roles (ARM)
-- ---------------------------------------------------------------------------

function M.azure_eligible(cb)
  local url = ARM
    .. "/providers/Microsoft.Authorization/roleEligibilityScheduleInstances?api-version="
    .. ARM_API
    .. "&$filter=asTarget()"
  get_all(url, function(items, err)
    if err then
      return cb(nil, err)
    end
    local out = {}
    for _, it in ipairs(items) do
      local p = it.properties or {}
      local ex = p.expandedProperties or {}
      table.insert(out, {
        kind = "azure",
        state = "eligible",
        role = (ex.roleDefinition or {}).displayName or p.roleDefinitionId,
        scope = (ex.scope or {}).displayName or p.scope,
        scope_type = (ex.scope or {}).type,
        scope_id = p.scope,
        role_definition_id = p.roleDefinitionId,
        eligibility_id = p.roleEligibilityScheduleId,
        member_type = p.memberType,
        end_time = p.endDateTime,
      })
    end
    cb(out, nil)
  end)
end

function M.azure_active(cb)
  local url = ARM
    .. "/providers/Microsoft.Authorization/roleAssignmentScheduleInstances?api-version="
    .. ARM_API
    .. "&$filter=asTarget()"
  get_all(url, function(items, err)
    if err then
      return cb(nil, err)
    end
    local out = {}
    local seen = {}
    for _, it in ipairs(items) do
      local p = it.properties or {}
      -- Only PIM activations, not standing/permanent assignments.
      if p.assignmentType == "Activated" then
        -- The same activation can be reported once per inherited group path;
        -- collapse those down to a single row per role+scope.
        local key = p.scope .. "|" .. p.roleDefinitionId
        if not seen[key] then
          seen[key] = true
          local ex = p.expandedProperties or {}
          table.insert(out, {
            kind = "azure",
            state = "active",
            role = (ex.roleDefinition or {}).displayName or p.roleDefinitionId,
            scope = (ex.scope or {}).displayName or p.scope,
            scope_type = (ex.scope or {}).type,
            scope_id = p.scope,
            role_definition_id = p.roleDefinitionId,
            eligibility_id = p.linkedRoleEligibilityScheduleId,
            member_type = p.memberType,
            end_time = p.endDateTime,
          })
        end
      end
    end
    cb(out, nil)
  end)
end

function M.azure_request(item, action, opts, cb)
  M.signed_in_user(function(oid, err)
    if err then
      return cb(nil, err)
    end
    local props = {
      principalId = oid,
      roleDefinitionId = item.role_definition_id,
      requestType = action == "activate" and "SelfActivate" or "SelfDeactivate",
      justification = opts.justification,
    }
    if action == "activate" then
      props.linkedRoleEligibilityScheduleId = item.eligibility_id
      props.scheduleInfo = {
        startDateTime = now_iso(),
        expiration = { type = "AfterDuration", duration = opts.duration },
      }
      if opts.ticket_number and opts.ticket_number ~= "" then
        props.ticketInfo = { ticketNumber = opts.ticket_number, ticketSystem = opts.ticket_system }
      end
    end
    local url = ARM
      .. item.scope_id
      .. "/providers/Microsoft.Authorization/roleAssignmentScheduleRequests/"
      .. uuid()
      .. "?api-version="
      .. ARM_API
    send("put", url, { properties = props }, cb)
  end)
end

-- ---------------------------------------------------------------------------
-- Entra ID (directory) roles (Microsoft Graph)
-- ---------------------------------------------------------------------------

local function graph_scope_label(item)
  local scope = item.directoryScopeId or "/"
  if scope == "/" then
    return "Directory"
  end
  return scope
end

function M.entra_eligible(cb)
  M.signed_in_user(function(oid, err)
    if err then
      return cb(nil, err)
    end
    local url = GRAPH
      .. "/roleManagement/directory/roleEligibilityScheduleInstances?$filter=principalId eq '"
      .. oid
      .. "'&$expand=roleDefinition"
    graph.get_all(url, function(items, gerr)
      if gerr then
        return cb(nil, gerr)
      end
      local out = {}
      for _, it in ipairs(items) do
        table.insert(out, {
          kind = "entra",
          state = "eligible",
          role = (it.roleDefinition or {}).displayName or it.roleDefinitionId,
          scope = graph_scope_label(it),
          scope_id = it.directoryScopeId or "/",
          role_definition_id = it.roleDefinitionId,
          eligibility_id = it.roleEligibilityScheduleId,
          member_type = it.memberType,
          end_time = it.endDateTime,
        })
      end
      cb(out, nil)
    end)
  end)
end

function M.entra_active(cb)
  M.signed_in_user(function(oid, err)
    if err then
      return cb(nil, err)
    end
    local url = GRAPH
      .. "/roleManagement/directory/roleAssignmentScheduleInstances?$filter=principalId eq '"
      .. oid
      .. "'&$expand=roleDefinition"
    graph.get_all(url, function(items, gerr)
      if gerr then
        return cb(nil, gerr)
      end
      local out = {}
      for _, it in ipairs(items) do
        -- Permanent directory assignments have no linked eligibility and no end;
        -- treat anything time-bound or eligibility-linked as an activation.
        if it.assignmentType == "Activated" or it.endDateTime or it.roleEligibilityScheduleInstanceId then
          table.insert(out, {
            kind = "entra",
            state = "active",
            role = (it.roleDefinition or {}).displayName or it.roleDefinitionId,
            scope = graph_scope_label(it),
            scope_id = it.directoryScopeId or "/",
            role_definition_id = it.roleDefinitionId,
            member_type = it.memberType,
            end_time = it.endDateTime,
          })
        end
      end
      cb(out, nil)
    end)
  end)
end

function M.entra_request(item, action, opts, cb)
  M.signed_in_user(function(oid, err)
    if err then
      return cb(nil, err)
    end
    local body = {
      action = action == "activate" and "selfActivate" or "selfDeactivate",
      principalId = oid,
      roleDefinitionId = item.role_definition_id,
      directoryScopeId = item.scope_id or "/",
      justification = opts.justification,
    }
    if action == "activate" then
      body.scheduleInfo = {
        startDateTime = now_iso(),
        expiration = { type = "afterDuration", duration = opts.duration },
      }
      if opts.ticket_number and opts.ticket_number ~= "" then
        body.ticketInfo = { ticketNumber = opts.ticket_number, ticketSystem = opts.ticket_system }
      end
    end
    graph.request("post", GRAPH .. "/roleManagement/directory/roleAssignmentScheduleRequests", body, cb)
  end)
end

-- ---------------------------------------------------------------------------

--- Graph refuses PIM endpoints unless the caller holds the role-management
--- scopes. With graph.lua's own token this should not happen; if it does, the
--- client id in use is not consented for them (see the README) — surfacing that
--- is more useful than the raw Graph error.
function M.is_missing_graph_scope(err)
  return type(err) == "string" and err:find("PermissionScopeNotGranted", 1, true) ~= nil
end

M.GRAPH_SCOPE_HINT = table.concat({
  "Entra ID roles need the Graph role-management scopes consented for client",
  graph.client_id .. ".",
  "A Global Admin must grant them — see the README. Then :AzPimGraphLogout and retry.",
}, " ")

function M.dispatch(item, action, opts, cb)
  if item.kind == "azure" then
    M.azure_request(item, action, opts, cb)
  else
    M.entra_request(item, action, opts, cb)
  end
end

return M
