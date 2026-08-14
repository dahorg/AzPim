-- Shared curl helper + small utilities used by both az.lua (ARM) and
-- graph.lua (Microsoft Graph). Kept dependency-free from the `az` CLI so
-- callers can hit REST endpoints directly once they hold a bearer token,
-- instead of paying an `az` process cold-start (roughly 1-3s of Python
-- interpreter/import overhead) on every single request.
local M = {}

---@param args string[] arguments passed to `curl`
---@param cb fun(data: table|nil, err: string|nil)
function M.curl(args, cb)
  local cmd = { "curl", "-sS", "--max-time", "30" }
  vim.list_extend(cmd, args)
  local ok, err = pcall(vim.system, cmd, { text = true }, function(out)
    vim.schedule(function()
      if out.code ~= 0 then
        return cb(nil, vim.trim(out.stderr or ("curl exited with " .. tostring(out.code))))
      end
      if out.stdout == nil or out.stdout:match("^%s*$") then
        return cb({}, nil)
      end
      -- luanil: JSON null decodes to vim.NIL otherwise, which is *truthy* — so
      -- an absent endDateTime would read as a real value.
      local decoded, data = pcall(vim.json.decode, out.stdout, { luanil = { object = true } })
      if not decoded then
        return cb(nil, "could not parse response as JSON: " .. vim.trim(out.stdout))
      end
      cb(data, nil)
    end)
  end)
  if not ok then
    vim.schedule(function()
      cb(nil, "failed to run curl: " .. tostring(err))
    end)
  end
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
