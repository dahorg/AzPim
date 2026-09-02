-- Microsoft Graph auth + requests, for the Entra ID (directory) PIM endpoints.
--
-- The Azure CLI cannot help here. Its first-party app is not preauthorized for
-- the Graph role-management scopes, so `az login --scope
-- https://graph.microsoft.com/RoleManagement.Read.Directory ...` is rejected
-- outright with AADSTS65002, and a plain CLI token is refused by Graph with
-- PermissionScopeNotGranted. We therefore run our own device-code flow against
-- a public client that *is* preauthorized for the delegated Graph surface, and
-- cache the resulting refresh token.
--
-- Azure *resource* roles need none of this — see az.lua, which reaches ARM
-- through `az rest` with whatever `az login` already gave you.
local http = require("azpim.http")

local M = {}

local AUTHORITY = "https://login.microsoftonline.com"

--- Microsoft Graph PowerShell's public client id. Override via
--- `require("azpim").setup({ graph_client_id = ... })` if your tenant blocks it
--- and you have registered your own public client instead.
M.client_id = "14d82eec-204b-4c2f-b7e8-296a70dab67e"

local SCOPES = {
  "https://graph.microsoft.com/RoleEligibilitySchedule.Read.Directory",
  "https://graph.microsoft.com/RoleAssignmentSchedule.ReadWrite.Directory",
  "https://graph.microsoft.com/RoleManagement.Read.Directory",
  "offline_access",
}

--- Called when an interactive sign-in is needed, with
--- `{ user_code, verification_uri, expires_in }`. The UI replaces this.
function M.on_device_code(info)
  vim.notify(
    ("AzPim: open %s and enter code %s"):format(info.verification_uri, info.user_code),
    vim.log.levels.WARN,
    { title = "AzPim" }
  )
end

--- Called once a token has been obtained, so the UI can clear any prompt.
function M.on_authenticated() end

-- ---------------------------------------------------------------------------
-- token cache
-- ---------------------------------------------------------------------------

local session = {
  access_token = nil,
  expires_at = 0,
  refresh_token = nil,
  tenant = nil,
  loaded = false,
}

local function cache_path()
  return vim.fs.joinpath(vim.fn.stdpath("cache"), "azpim-graph-token.json")
end

local function load_cache()
  if session.loaded then
    return
  end
  session.loaded = true
  local fh = io.open(cache_path(), "r")
  if not fh then
    return
  end
  local raw = fh:read("*a")
  fh:close()
  local ok, data = pcall(vim.json.decode, raw)
  if ok and type(data) == "table" then
    session.access_token = data.access_token
    session.expires_at = tonumber(data.expires_at) or 0
    session.refresh_token = data.refresh_token
  end
end

--- Persist tokens at 0600 — this file can mint privileged Graph tokens.
local function save_cache()
  local fd = vim.uv.fs_open(cache_path(), "w", 384) -- 0600
  if not fd then
    return
  end
  vim.uv.fs_write(
    fd,
    vim.json.encode({
      access_token = session.access_token,
      expires_at = session.expires_at,
      refresh_token = session.refresh_token,
    })
  )
  vim.uv.fs_close(fd)
end

--- Forget the cached tokens; the next call signs in again.
function M.logout()
  session.access_token, session.refresh_token, session.expires_at = nil, nil, 0
  session.loaded = true
  os.remove(cache_path())
end

local function store(data)
  session.access_token = data.access_token
  session.expires_at = os.time() + (tonumber(data.expires_in) or 3600)
  if data.refresh_token then
    session.refresh_token = data.refresh_token
  end
  save_cache()
  vim.schedule(M.on_authenticated)
  return session.access_token, nil
end

local curl = http.curl
local encode_query = http.encode_query

-- ---------------------------------------------------------------------------
-- device code flow
-- ---------------------------------------------------------------------------

--- Sign in to the same tenant the CLI is pointed at, so the two agree.
local function tenant(cb)
  if session.tenant then
    return cb(session.tenant)
  end
  local ok = pcall(
    vim.system,
    { "az", "account", "show", "--query", "tenantId", "-o", "tsv" },
    { text = true },
    function(out)
      vim.schedule(function()
        local t = vim.trim(out.stdout or "")
        session.tenant = (out.code == 0 and t ~= "") and t or "organizations"
        cb(session.tenant)
      end)
    end
  )
  if not ok then
    session.tenant = "organizations"
    vim.schedule(function()
      cb(session.tenant)
    end)
  end
end

local function token_endpoint(t)
  return AUTHORITY .. "/" .. t .. "/oauth2/v2.0/token"
end

local function poll_device_code(t, device_code, interval, deadline, cb)
  vim.defer_fn(function()
    curl({
      "-X",
      "POST",
      token_endpoint(t),
      "--data-urlencode",
      "grant_type=urn:ietf:params:oauth:grant-type:device_code",
      "--data-urlencode",
      "client_id=" .. M.client_id,
      "--data-urlencode",
      "device_code=" .. device_code,
    }, function(data, err)
      if err then
        return cb(nil, err)
      end
      if data.access_token then
        return cb(store(data))
      end
      if data.error == "authorization_pending" or data.error == "slow_down" then
        if os.time() > deadline then
          return cb(nil, "device-code sign-in timed out")
        end
        local next_interval = interval + (data.error == "slow_down" and 5 or 0)
        return poll_device_code(t, device_code, next_interval, deadline, cb)
      end
      cb(nil, data.error_description or data.error or "device-code sign-in failed")
    end)
  end, interval * 1000)
end

local function device_flow(cb)
  tenant(function(t)
    curl({
      "-X",
      "POST",
      AUTHORITY .. "/" .. t .. "/oauth2/v2.0/devicecode",
      "--data-urlencode",
      "client_id=" .. M.client_id,
      "--data-urlencode",
      "scope=" .. table.concat(SCOPES, " "),
    }, function(data, err)
      if err then
        return cb(nil, err)
      end
      if not data.device_code then
        return cb(nil, data.error_description or data.error or "could not start device-code sign-in")
      end
      M.on_device_code({
        user_code = data.user_code,
        verification_uri = data.verification_uri or "https://login.microsoft.com/device",
        expires_in = data.expires_in,
      })
      poll_device_code(t, data.device_code, data.interval or 5, os.time() + (data.expires_in or 900), cb)
    end)
  end)
end

local function refresh_flow(cb)
  tenant(function(t)
    curl({
      "-X",
      "POST",
      token_endpoint(t),
      "--data-urlencode",
      "grant_type=refresh_token",
      "--data-urlencode",
      "client_id=" .. M.client_id,
      "--data-urlencode",
      "refresh_token=" .. session.refresh_token,
      "--data-urlencode",
      "scope=" .. table.concat(SCOPES, " "),
    }, function(data, err)
      if err then
        return cb(nil, err)
      end
      if data.access_token then
        return cb(store(data))
      end
      -- Expired or revoked refresh token: sign in again rather than fail.
      session.refresh_token = nil
      device_flow(cb)
    end)
  end)
end

-- A refresh triggers several Graph calls at once; without this queue each one
-- would start its own device-code flow.
local waiters = nil

---@param cb fun(token: string|nil, err: string|nil)
function M.token(cb)
  load_cache()
  if session.access_token and session.expires_at - 60 > os.time() then
    return cb(session.access_token, nil)
  end
  if waiters then
    return table.insert(waiters, cb)
  end
  waiters = { cb }
  local function finish(token, err)
    local pending = waiters
    waiters = nil
    for _, f in ipairs(pending) do
      f(token, err)
    end
  end
  if session.refresh_token then
    refresh_flow(finish)
  else
    device_flow(finish)
  end
end

--- True once a token is cached, i.e. no sign-in prompt is imminent.
function M.authenticated()
  load_cache()
  return session.refresh_token ~= nil or session.access_token ~= nil
end

-- ---------------------------------------------------------------------------
-- requests
-- ---------------------------------------------------------------------------

local function graph_error(data)
  local e = data.error
  if type(e) == "table" then
    return e.message or e.code or vim.inspect(e)
  end
  return data.error_description or tostring(e)
end

---@param cb fun(data: table|nil, err: string|nil)
function M.request(method, url, body, cb)
  M.token(function(token, err)
    if err then
      return cb(nil, err)
    end
    local args = {
      "-X",
      method:upper(),
      encode_query(url),
      "-H",
      "Authorization: Bearer " .. token,
    }
    local path
    if body then
      path = vim.fn.tempname() .. ".json"
      local fh, ferr = io.open(path, "w")
      if not fh then
        return cb(nil, "could not write request body: " .. tostring(ferr))
      end
      fh:write(vim.json.encode(body))
      fh:close()
      vim.list_extend(args, { "-H", "Content-Type: application/json", "--data-binary", "@" .. path })
    end
    curl(args, function(data, cerr, status)
      if path then
        os.remove(path)
      end
      if cerr then
        return cb(nil, cerr)
      end
      if data.error then
        return cb(nil, graph_error(data))
      end
      -- Graph normally sends `{"error":{…}}`, but a throttle/gateway failure can
      -- come back as a bare 429/503 with a body we'd otherwise read as success.
      local herr = http.http_error(data, status, "Graph")
      if herr then
        return cb(nil, herr)
      end
      cb(data, nil)
    end)
  end)
end

--- GET a URL, following `@odata.nextLink` until exhausted.
function M.get_all(url, cb, acc)
  acc = acc or {}
  M.request("get", url, nil, function(data, err)
    if err then
      return cb(nil, err)
    end
    vim.list_extend(acc, data.value or {})
    if data["@odata.nextLink"] then
      M.get_all(data["@odata.nextLink"], cb, acc)
    else
      cb(acc, nil)
    end
  end)
end

return M
