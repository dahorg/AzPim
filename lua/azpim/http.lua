-- Shared curl helper + small utilities used by both az.lua (ARM) and
-- graph.lua (Microsoft Graph). Kept dependency-free from the `az` CLI so
-- callers can hit REST endpoints directly once they hold a bearer token,
-- instead of paying an `az` process cold-start (roughly 1-3s of Python
-- interpreter/import overhead) on every single request.
local M = {}

---@param args string[] arguments passed to `curl`
---@param cb fun(data: table|nil, err: string|nil, status: number|nil)
function M.curl(args, cb)
  -- `-w` appends the HTTP status on its own trailing line. curl exits 0 for a
  -- 4xx/5xx as happily as for a 200, so without this an ARM/Graph rejection
  -- whose body isn't shaped like `{"error":{…}}` would read as success.
  local cmd = { "curl", "-sS", "--max-time", "30", "-w", "\n%{http_code}" }
  vim.list_extend(cmd, args)
  local ok, err = pcall(vim.system, cmd, { text = true }, function(out)
    vim.schedule(function()
      if out.code ~= 0 then
        return cb(nil, vim.trim(out.stderr or ("curl exited with " .. tostring(out.code))))
      end
      local text = out.stdout or ""
      local body, code = text:match("^(.-)\n(%d%d%d)$")
      local status = code and tonumber(code) or nil
      body = body or text
      if body:match("^%s*$") then
        return cb({}, nil, status)
      end
      -- luanil: JSON null decodes to vim.NIL otherwise, which is *truthy* — so
      -- an absent endDateTime would read as a real value.
      local decoded, data = pcall(vim.json.decode, body, { luanil = { object = true } })
      if not decoded then
        return cb(nil, "could not parse response as JSON: " .. vim.trim(body), status)
      end
      cb(data, nil, status)
    end)
  end)
  if not ok then
    vim.schedule(function()
      cb(nil, "failed to run curl: " .. tostring(err))
    end)
  end
end

--- Turn a non-2xx response into an error message, preferring whatever the
--- service said over the bare status code. Returns nil when the response is
--- fine. Callers that legitimately expect 4xx bodies (the OAuth device-code
--- poll returns HTTP 400 for `authorization_pending`) simply don't call this.
---@return string|nil
function M.http_error(data, status, who)
  if status and status >= 400 then
    local e = data and data.error
    if type(e) == "table" then
      return e.message or e.code or vim.inspect(e)
    end
    if type(e) == "string" then
      return (data.error_description or e) .. " (HTTP " .. status .. ")"
    end
    return who .. " returned HTTP " .. status
  end
  return nil
end

--- Percent-encode a URL's query string. Both ARM and Graph reject the raw
--- spaces and quotes that `$filter=principalId eq '<oid>'` would otherwise send.
function M.encode_query(url)
  local base, query = url:match("^([^?]*)%??(.*)$")
  if query == "" then
    return base
  end
  query = query:gsub("[^%w%-%._~=&%$%%]", function(c)
    return string.format("%%%02X", string.byte(c))
  end)
  return base .. "?" .. query
end

--- Decode the (unverified) payload of a JWT access token. We only ever read
--- claims out of a token Azure itself just handed us over TLS, so there's
--- nothing to verify here — this just saves a round trip (e.g. an extra `az
--- ad signed-in-user show` process) for claims already sitting in the token.
function M.jwt_claims(token)
  local payload = token:match("^[^.]+%.([^.]+)%.")
  if not payload then
    return nil
  end
  payload = payload:gsub("-", "+"):gsub("_", "/")
  local pad = #payload % 4
  if pad > 0 then
    payload = payload .. string.rep("=", 4 - pad)
  end
  local ok, decoded = pcall(vim.base64.decode, payload)
  if not ok then
    return nil
  end
  local ok2, data = pcall(vim.json.decode, decoded)
  if not ok2 then
    return nil
  end
  return data
end

return M
