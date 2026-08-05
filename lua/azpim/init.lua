local M = {}

---@class azpim.Config
local defaults = {
  --- Default activation length, ISO 8601 duration.
  duration = "PT8H",
  --- Default justification sent with activation requests.
  justification = "Activated from Neovim (:AzPim)",
  --- Ask for justification/duration before activating. false = use defaults silently.
  prompt = true,
  --- Public client used for the Microsoft Graph sign-in that Entra ID roles
  --- need. Defaults to Microsoft Graph PowerShell, whose tokens carry every
  --- scope your tenant has consented for it; point this at your own
  --- registration to get a token limited to the three PIM scopes.
  graph_client_id = nil,
  window = {
    width = 124,
    height = 42,
    border = "rounded",
  },
}

M.config = vim.deepcopy(defaults)

---@param opts azpim.Config|nil
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})

  if M.config.graph_client_id then
    require("azpim.graph").client_id = M.config.graph_client_id
  end

  vim.api.nvim_create_user_command("AzPim", function()
    require("azpim.ui").open(M.config)
  end, { desc = "Azure PIM: activate/deactivate eligible roles" })

  vim.api.nvim_create_user_command("AzPimClose", function()
    require("azpim.ui").close()
  end, { desc = "Close the Azure PIM window" })

  vim.api.nvim_create_user_command("AzPimGraphLogout", function()
    require("azpim.graph").logout()
    vim.notify("AzPim: forgot the cached Microsoft Graph token", vim.log.levels.INFO, { title = "AzPim" })
  end, { desc = "Azure PIM: forget the cached Graph token (Entra ID roles)" })
end

function M.open()
  require("azpim.ui").open(M.config)
end

return M
