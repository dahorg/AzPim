-- Floating-window UI: eligible roles on top, active activations below.
local az = require("azpim.az")
local graph = require("azpim.graph")

local M = {}

local NS = vim.api.nvim_create_namespace("azpim")

---@class azpim.State
local state = {
  buf = nil,
  win = nil,
  loading = false,
  account = nil,
  eligible = {}, -- azpim.Item[]
  active = {}, -- azpim.Item[]
  errors = {}, -- string[]
  hint = nil, -- string|nil
  device = nil, -- pending device-code sign-in, or nil
  rows = {}, -- lnum -> item
  selected = {}, -- key -> true
  cfg = nil,
}

-- ---------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------

local function key_of(item)
  return table.concat({ item.kind, item.state, item.role or "", item.scope_id or "" }, "\0")
end

local function pad(s, width)
  s = s or ""
  local w = vim.fn.strdisplaywidth(s)
  if w > width then
    return vim.fn.strcharpart(s, 0, math.max(1, width - 1)) .. "…"
  end
  return s .. string.rep(" ", width - w)
end

local function iso_to_epoch(s)
  if not s then
    return nil
  end
  local y, mo, d, h, mi, sec = s:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):([%d%.]+)")
  if not y then
    return nil
  end
  local t = os.time({
    year = tonumber(y),
    month = tonumber(mo),
    day = tonumber(d),
    hour = tonumber(h),
    min = tonumber(mi),
    sec = math.floor(tonumber(sec)),
    isdst = false,
  })
  -- os.time() treats the table as local time; shift back to UTC.
  local offset = os.difftime(os.time(os.date("*t")), os.time(os.date("!*t")))
  return t + offset
end

local function remaining(item)
  local e = iso_to_epoch(item.end_time)
  if not e then
    return "permanent"
  end
  local secs = e - os.time()
  if secs <= 0 then
    return "expired"
  end
  local d = math.floor(secs / 86400)
  local h = math.floor((secs % 86400) / 3600)
  local m = math.floor((secs % 3600) / 60)
  if d > 0 then
    return string.format("%dd %dh left", d, h)
  end
  if h > 0 then
    return string.format("%dh %dm left", h, m)
  end
  return string.format("%dm left", m)
end

local function sort_items(list)
  table.sort(list, function(a, b)
    if a.kind ~= b.kind then
      return a.kind < b.kind
    end
    if a.role ~= b.role then
      return (a.role or "") < (b.role or "")
    end
    return (a.scope or "") < (b.scope or "")
  end)
end

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "AzPim" })
end

-- ---------------------------------------------------------------------------
-- rendering
-- ---------------------------------------------------------------------------

local function selected_items()
  local out = {}
  for _, it in ipairs(state.eligible) do
    if state.selected[key_of(it)] then
      table.insert(out, it)
    end
  end
  return out
end

local function render()
  if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then
    return
  end
  local lines, marks = {}, {}
  state.rows = {}

  local function add(text, hl)
    table.insert(lines, text)
    if hl then
      table.insert(marks, { #lines - 1, hl })
    end
    return #lines
  end

  local who = state.account
      and string.format("%s  ·  %s", state.account.user and state.account.user.name or "?", state.account.tenantDisplayName or state.account.tenantId or "")
    or "…"
  add("Azure PIM   " .. who, "AzPimTitle")
  add(
    "<Tab> select   <CR> activate   a activate selected   d deactivate   r refresh   q quit",
    "AzPimHelp"
  )
  add("")

  if state.loading then
    add("  loading roles from Azure…", "AzPimDim")
  end

  for _, err in ipairs(state.errors) do
    for _, l in ipairs(vim.split(err, "\n", { plain = true })) do
      add("  ! " .. l, "AzPimError")
    end
  end
  if state.device then
    add("  Entra ID sign-in required (the Azure CLI cannot get these scopes):", "AzPimHint")
    add(
      ("    open %s  and enter code  %s"):format(state.device.verification_uri, state.device.user_code),
      "AzPimHint"
    )
    add("    the Entra sections fill in on their own once you finish", "AzPimDim")
  end
  if state.hint then
    for _, l in ipairs(vim.split(state.hint, "\n", { plain = true })) do
      add("  " .. l, "AzPimHint")
    end
  end
  if #state.errors > 0 or state.hint or state.device then
    add("")
  end

  local function section(title, items, kind, is_active)
    local subset = vim.tbl_filter(function(it)
      return it.kind == kind
    end, items)
    add(string.format("%s (%d)", title, #subset), "AzPimHeader")
    if #subset == 0 then
      add("    none", "AzPimDim")
    end
    for _, it in ipairs(subset) do
      local prefix
      if is_active then
        prefix = "  ● "
      else
        prefix = state.selected[key_of(it)] and "  [x] " or "  [ ] "
      end
      local extra = is_active and remaining(it) or (it.member_type == "Group" and "via group" or "")
      local line = prefix .. pad(it.role, 38) .. " " .. pad(it.scope, 34) .. " " .. extra
      local lnum = add(line:gsub("%s+$", ""), is_active and "AzPimActive" or nil)
      state.rows[lnum] = it
    end
    add("")
  end

  section("ELIGIBLE — Azure resources", state.eligible, "azure", false)
  section("ELIGIBLE — Entra ID roles", state.eligible, "entra", false)
  section("ACTIVE — Azure resources", state.active, "azure", true)
  section("ACTIVE — Entra ID roles", state.active, "entra", true)

  local n = #selected_items()
  if n > 0 then
    add(string.format("  %d selected — press 'a' to activate", n), "AzPimHint")
  end

  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(state.buf, NS, 0, -1)
  for _, m in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(state.buf, NS, m[1], 0, { end_row = m[1] + 1, hl_group = m[2], hl_eol = true })
  end
  -- dim the scope column on role rows
  for lnum, _ in pairs(state.rows) do
    vim.api.nvim_buf_set_extmark(state.buf, NS, lnum - 1, 0, {
      end_col = math.min(6, #lines[lnum]),
      hl_group = "AzPimMark",
    })
  end
end

-- ---------------------------------------------------------------------------
-- graph sign-in
-- ---------------------------------------------------------------------------

--- Show the device code in the window (and in a notification, in case the
--- window is closed), copy it, and open the verification page.
local function install_auth_hooks()
  graph.on_device_code = function(info)
    state.device = info
    render()
    notify(("Entra sign-in: enter code %s"):format(info.user_code), vim.log.levels.WARN)
    pcall(vim.fn.setreg, "+", info.user_code)
    pcall(vim.ui.open, info.verification_uri)
  end
  graph.on_authenticated = function()
    state.device = nil
    render()
  end
end

-- ---------------------------------------------------------------------------
-- data loading
-- ---------------------------------------------------------------------------

function M.refresh()
  state.loading = true
  state.errors = {}
  state.hint = nil
  state.eligible, state.active = {}, {}
  render()

  -- Azure's tenant-wide role-assignment endpoints can take many seconds to
  -- fan out across subscriptions (Azure-side, not something we can speed
  -- up). Rather than blank the window until every one of the 5 requests
  -- below finishes, fill in each section as soon as its own call returns.
  local pending = 5
  local function done()
    pending = pending - 1
    if pending == 0 then
      state.loading = false
    end
    render()
  end

  local function collect(target_key, fetch, label)
    fetch(function(items, err)
      if err then
        if az.is_missing_graph_scope(err) then
          state.hint = az.GRAPH_SCOPE_HINT
        else
          table.insert(state.errors, label .. ": " .. err)
        end
      else
        vim.list_extend(state[target_key], items)
        sort_items(state[target_key])
      end
      done()
    end)
  end

  az.account(function(data, err)
    if not err then
      state.account = data
    end
    done()
  end)
  collect("eligible", az.azure_eligible, "azure eligible")
  collect("active", az.azure_active, "azure active")
  collect("eligible", az.entra_eligible, "entra eligible")
  collect("active", az.entra_active, "entra active")
end

-- ---------------------------------------------------------------------------
-- actions
-- ---------------------------------------------------------------------------

local function ask(prompt, default, cb)
  vim.ui.input({ prompt = prompt, default = default }, function(value)
    if value == nil then
      return
    end
    cb(value)
  end)
end

--- Collect justification + duration once, then run `fn(opts)`.
local function with_opts(action, count, fn)
  local cfg = state.cfg
  if action == "deactivate" then
    return fn({ justification = cfg.justification })
  end
  if not cfg.prompt then
    return fn({ justification = cfg.justification, duration = cfg.duration })
  end
  ask(string.format("Justification (%d role%s): ", count, count == 1 and "" or "s"), cfg.justification, function(just)
    ask("Duration (ISO 8601, e.g. PT8H): ", cfg.duration, function(dur)
      fn({ justification = just, duration = dur })
    end)
  end)
end

local function submit(items, action)
  if #items == 0 then
    return notify("no role under cursor", vim.log.levels.WARN)
  end
  with_opts(action, #items, function(opts)
    local left = #items
    for _, item in ipairs(items) do
      local label = string.format("%s @ %s", item.role, item.scope)
      az.dispatch(item, action, opts, function(_, err)
        if err then
          notify(("%s %s failed:\n%s"):format(action, label, err), vim.log.levels.ERROR)
        else
          notify(("%s: %s"):format(action == "activate" and "activated" or "deactivated", label))
          state.selected[key_of(item)] = nil
        end
        left = left - 1
        if left == 0 then
          -- Activations take a moment to become Provisioned server-side.
          vim.defer_fn(function()
            if state.win and vim.api.nvim_win_is_valid(state.win) then
              M.refresh()
            end
          end, 2500)
        end
      end)
    end
    notify(("submitting %d %s request%s…"):format(#items, action, #items == 1 and "" or "s"))
  end)
end

local function item_under_cursor()
  local lnum = vim.api.nvim_win_get_cursor(state.win)[1]
  return state.rows[lnum]
end

local function toggle()
  local item = item_under_cursor()
  if not item or item.state ~= "eligible" then
    return
  end
  local k = key_of(item)
  state.selected[k] = not state.selected[k] or nil
  local lnum = vim.api.nvim_win_get_cursor(state.win)[1]
  render()
  pcall(vim.api.nvim_win_set_cursor, state.win, { math.min(lnum + 1, vim.api.nvim_buf_line_count(state.buf)), 0 })
end

local function activate_cursor()
  local item = item_under_cursor()
  if not item then
    return notify("no role under cursor", vim.log.levels.WARN)
  end
  if item.state == "active" then
    return notify("already active — press 'd' to deactivate", vim.log.levels.WARN)
  end
  submit({ item }, "activate")
end

local function activate_selected()
  local items = selected_items()
  if #items == 0 then
    return notify("nothing selected (<Tab> to select)", vim.log.levels.WARN)
  end
  submit(items, "activate")
end

local function deactivate_cursor()
  local item = item_under_cursor()
  if not item or item.state ~= "active" then
    return notify("put the cursor on an active role", vim.log.levels.WARN)
  end
  submit({ item }, "deactivate")
end

function M.close()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  state.win = nil
end

-- ---------------------------------------------------------------------------
-- window
-- ---------------------------------------------------------------------------

local function set_highlights()
  local defs = {
    AzPimTitle = { link = "Title" },
    AzPimHelp = { link = "Comment" },
    AzPimHeader = { link = "Function" },
    AzPimDim = { link = "Comment" },
    AzPimError = { link = "DiagnosticError" },
    AzPimHint = { link = "DiagnosticWarn" },
    AzPimActive = { link = "DiagnosticOk" },
    AzPimMark = { link = "Special" },
  }
  for name, def in pairs(defs) do
    vim.api.nvim_set_hl(0, name, vim.tbl_extend("keep", def, { default = true }))
  end
end

local function open_window()
  set_highlights()
  state.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.buf].bufhidden = "wipe"
  vim.bo[state.buf].filetype = "azpim"
  vim.bo[state.buf].modifiable = false

  local cfg = state.cfg.window
  local width = math.min(cfg.width, vim.o.columns - 4)
  local height = math.min(cfg.height, vim.o.lines - 6)
  state.win = vim.api.nvim_open_win(state.buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2 - 1),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = cfg.border,
    title = " Azure PIM ",
    title_pos = "center",
  })
  vim.wo[state.win].cursorline = true
  vim.wo[state.win].wrap = false

  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = state.buf, nowait = true, silent = true })
  end
  map("q", M.close)
  map("<Esc>", M.close)
  map("<Tab>", toggle)
  map("<Space>", toggle)
  map("<CR>", activate_cursor)
  map("a", activate_selected)
  map("d", deactivate_cursor)
  map("r", M.refresh)
  map("g?", function()
    notify(table.concat({
      "<Tab>/<Space>  toggle selection",
      "<CR>           activate role under cursor",
      "a              activate all selected",
      "d              deactivate role under cursor",
      "r              refresh",
      "q/<Esc>        close",
    }, "\n"))
  end)

  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(state.win),
    once = true,
    callback = function()
      state.win = nil
    end,
  })
end

function M.open(cfg)
  state.cfg = cfg
  if vim.fn.executable("az") == 0 then
    return notify("the Azure CLI (`az`) was not found on $PATH", vim.log.levels.ERROR)
  end
  if vim.fn.executable("curl") == 0 then
    return notify("`curl` was not found on $PATH (needed for Entra ID roles)", vim.log.levels.ERROR)
  end
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_set_current_win(state.win)
    return
  end
  install_auth_hooks()
  open_window()
  render()
  M.refresh()
end

return M
