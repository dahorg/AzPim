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
  loading_sections = {}, -- "azure_eligible"|"azure_active"|"entra_eligible"|"entra_active" -> true
  account = nil,
  eligible = {}, -- azpim.Item[]
  active = {}, -- azpim.Item[]
  errors = {}, -- string[]
  hint = nil, -- string|nil
  device = nil, -- pending device-code sign-in, or nil
  rows = {}, -- lnum -> item
  selected = {}, -- key -> true
  cfg = nil,
  generation = 0, -- refresh counter; responses from older refreshes are dropped
  pending = {}, -- requests submitted but not yet visible in Azure
  poll_attempt = 0,
  poll_armed = false,
}

local SPINNER_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local spinner_frame = 1
local spinner_timer = nil
local render -- forward declaration; defined in the rendering section below

local function any_section_loading()
  for _, v in pairs(state.loading_sections) do
    if v then
      return true
    end
  end
  return false
end

--- Keep the spinner glyph animating while any section is still loading, and
--- stop the timer (rather than tick forever in the background) once nothing
--- is pending.
local function ensure_spinner()
  if spinner_timer or not any_section_loading() then
    return
  end
  spinner_timer = vim.uv.new_timer()
  spinner_timer:start(
    0,
    120,
    vim.schedule_wrap(function()
      if not any_section_loading() then
        spinner_timer:stop()
        spinner_timer:close()
        spinner_timer = nil
        return
      end
      spinner_frame = (spinner_frame % #SPINNER_FRAMES) + 1
      render()
    end)
  )
end

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

function render()
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

  local function section(title, items, kind, is_active, loading_key)
    local subset = vim.tbl_filter(function(it)
      return it.kind == kind
    end, items)
    add(string.format("%s (%d)", title, #subset), "AzPimHeader")
    if #subset == 0 then
      if loading_key and state.loading_sections[loading_key] then
        add("    " .. SPINNER_FRAMES[spinner_frame] .. " loading…", "AzPimDim")
      else
        add("    none", "AzPimDim")
      end
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

  section("ELIGIBLE — Azure resources", state.eligible, "azure", false, "azure_eligible")
  section("ELIGIBLE — Entra ID roles", state.eligible, "entra", false, "entra_eligible")
  section("ACTIVE — Azure resources", state.active, "azure", true, "azure_active")
  section("ACTIVE — Entra ID roles", state.active, "entra", true, "entra_active")

  if #state.pending > 0 then
    add(string.format("  waiting on Azure for %d request(s)…", #state.pending), "AzPimHint")
  end

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

--- Defined below; called at the end of every refresh that wasn't superseded.
local evaluate_pending

---@param on_done fun()|nil called once every section has settled
function M.refresh(on_done)
  -- Every refresh gets a generation. A refresh started while another is still
  -- in flight (the poll loop below, or 'r' pressed twice) used to let the older
  -- refresh's five callbacks append into the tables the newer one had just
  -- cleared, and let its on_done fire against a half-built list — so a role
  -- could be judged activated, or not activated, from someone else's data.
  state.generation = state.generation + 1
  local gen = state.generation
  state.loading = true
  state.errors = {}
  state.hint = nil
  state.eligible, state.active = {}, {}
  state.loading_sections = {
    azure_eligible = true,
    azure_active = true,
    entra_eligible = true,
    entra_active = true,
  }
  ensure_spinner()
  render()

  -- Azure's tenant-wide role-assignment endpoints can take many seconds to
  -- fan out across subscriptions (Azure-side, not something we can speed
  -- up). Rather than blank the window until every one of the 5 requests
  -- below finishes, fill in each section as soon as its own call returns.
  local pending = 5
  local function done()
    if gen ~= state.generation then
      return -- superseded by a newer refresh
    end
    pending = pending - 1
    if pending == 0 then
      state.loading = false
      render()
      evaluate_pending()
      if on_done then
        on_done()
      end
      return
    end
    render()
  end

  local function collect(target_key, loading_key, fetch, label)
    fetch(function(items, err)
      if gen ~= state.generation then
        return
      end
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
      state.loading_sections[loading_key] = nil
      done()
    end)
  end

  az.account(function(data, err)
    if not err and gen == state.generation then
      state.account = data
    end
    done()
  end)
  collect("eligible", "azure_eligible", az.azure_eligible, "azure eligible")
  collect("active", "azure_active", az.azure_active, "azure active")
  collect("eligible", "entra_eligible", az.entra_eligible, "entra eligible")
  collect("active", "entra_active", az.entra_active, "entra active")
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

--- Has `item` reached the expected post-request state in `state.active` yet?
local function settled(item, action)
  local found = false
  for _, active in ipairs(state.active) do
    if
      active.kind == item.kind
      and active.role_definition_id == item.role_definition_id
      and active.scope_id == item.scope_id
    then
      found = true
      break
    end
  end
  return action == "activate" and found or not found
end

-- Azure resource-role activations are provisioned asynchronously: the PUT
-- returns immediately (often before roleAssignmentScheduleInstances has
-- caught up), and fan-out across subscriptions can take well past a single
-- short delay. Poll with backoff instead of refreshing once and giving up.
local POLL_DELAYS_MS = { 2500, 4000, 8000, 15000, 30000 }

local arm_poll

--- Promote the requests Azure has finally caught up on, and keep polling the
--- rest. Runs after *any* completed refresh (including a manual 'r'), so the
--- poll loop can't be orphaned by a refresh that supersedes it.
function evaluate_pending()
  if #state.pending == 0 then
    return
  end
  if not (state.win and vim.api.nvim_win_is_valid(state.win)) then
    state.pending, state.poll_attempt = {}, 0
    return
  end
  local still = {}
  for _, p in ipairs(state.pending) do
    if settled(p.item, p.action) then
      notify(("%s: %s"):format(p.action == "activate" and "activated" or "deactivated", p.label))
    else
      table.insert(still, p)
    end
  end
  state.pending = still
  if #still == 0 then
    state.poll_attempt = 0
    return
  end
  state.poll_attempt = state.poll_attempt + 1
  local delay = POLL_DELAYS_MS[state.poll_attempt]
  if not delay then
    -- Azure accepted the request but never showed the role as active. Say that
    -- rather than leaving the earlier "submitted" message to imply success.
    local names = {}
    for _, p in ipairs(still) do
      table.insert(names, p.label)
    end
    notify(
      ("Azure accepted the request but these are still not active:\n  %s\nCheck the portal, or press 'r' to look again."):format(
        table.concat(names, "\n  ")
      ),
      vim.log.levels.WARN
    )
    state.pending, state.poll_attempt = {}, 0
    return
  end
  arm_poll(delay)
end

--- One timer at a time, so overlapping submissions can't stack refreshes.
function arm_poll(delay)
  if state.poll_armed then
    return
  end
  state.poll_armed = true
  vim.defer_fn(function()
    state.poll_armed = false
    if #state.pending == 0 then
      return
    end
    if not (state.win and vim.api.nvim_win_is_valid(state.win)) then
      state.pending, state.poll_attempt = {}, 0
      return
    end
    M.refresh()
  end, delay)
end

local function watch(item, action, label)
  for _, p in ipairs(state.pending) do
    if p.key == key_of(item) and p.action == action then
      return
    end
  end
  table.insert(state.pending, { item = item, action = action, label = label, key = key_of(item) })
end

local function submit(items, action)
  if #items == 0 then
    return notify("no role under cursor", vim.log.levels.WARN)
  end
  with_opts(action, #items, function(opts)
    local left = #items
    local watching = 0
    for _, item in ipairs(items) do
      local label = string.format("%s @ %s", item.role, item.scope)
      az.dispatch(item, action, opts, function(data, err)
        if err then
          notify(("%s %s failed:\n%s"):format(action, label, err), vim.log.levels.ERROR)
        else
          -- A 2xx only means PIM recorded the request. Its own status says
          -- whether the role was actually granted, parked for approval, or
          -- rejected — announcing "activated" here regardless was how a
          -- non-activation could look like a success.
          local outcome, status = az.request_status(data)
          if outcome == "failed" then
            notify(("%s %s was rejected by PIM (%s)"):format(action, label, status), vim.log.levels.ERROR)
          elseif outcome == "approval" then
            state.selected[key_of(item)] = nil
            notify(
              ("%s: %s is waiting for approval (%s) — it is not active yet"):format(action, label, status),
              vim.log.levels.WARN
            )
          else
            state.selected[key_of(item)] = nil
            watch(item, action, label)
            watching = watching + 1
          end
        end
        left = left - 1
        if left == 0 and watching > 0 then
          state.poll_attempt = 0
          M.refresh()
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
