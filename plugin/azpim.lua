-- Register :AzPim even when the user never calls require("azpim").setup().
-- setup() re-creates the command afterwards with their options, which is fine.
if vim.g.loaded_azpim then
  return
end
vim.g.loaded_azpim = true

vim.api.nvim_create_user_command("AzPim", function()
  local azpim = require("azpim")
  azpim.open()
end, { desc = "Azure PIM: activate/deactivate eligible roles" })
