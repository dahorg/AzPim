# AzPim

Activate Azure PIM roles — both **Azure resource** roles and **Entra ID
(directory)** roles — without leaving your editor.

| Client | Lives in | Docs |
| --- | --- | --- |
| **Neovim plugin** | [`lua/`](lua/), [`plugin/`](plugin/) | this file |
| **VS Code extension** | [`vscode/`](vscode/) | [`vscode/README.md`](vscode/README.md) |

Both hit the same PIM endpoints with the same semantics — eligible roles on top,
your live activations below, activate and deactivate in place. Pick one or use
both; they share nothing at runtime.

```
╭──────────────────────────── Azure PIM ─────────────────────────────╮
│ Azure PIM   admin@contoso.com  ·  Contoso AS                       │
│ <Tab> select  <CR> activate  a activate selected  d deactivate  …   │
│                                                                    │
│ ELIGIBLE — Azure resources (19)                                    │
│   [x] Owner                   Contoso Group ASA                    │
│   [ ] Contributor             Shared Services     via group        │
│                                                                    │
│ ELIGIBLE — Entra ID roles (2)                                      │
│   [ ] Global Reader           Directory                            │
│                                                                    │
│ ACTIVE — Azure resources (1)                                       │
│   ●   Owner                   prod-01             7h 42m left      │
╰────────────────────────────────────────────────────────────────────╯
```

---

# The Neovim plugin

```
:AzPim
```

## Requirements

- Neovim 0.10+ (uses `vim.system`)
- Azure CLI (`az`) on `$PATH`, logged in (`az login`)
- `curl` on `$PATH` (only for Entra ID roles)

Azure **resource** roles work off a plain `az login` and need nothing else.

## Install (lazy.nvim)

```lua
{
  "dahorg/AzPim",
  cmd = { "AzPim", "AzPimClose" },
  keys = { { "<leader>ap", "<cmd>AzPim<cr>", desc = "Azure PIM roles" } },
  main = "azpim",
  opts = {},
}
```

## Keys (inside the window)

| Key             | Action                                  |
| --------------- | --------------------------------------- |
| `<Tab>`/`<Space>` | toggle selection on an eligible role   |
| `<CR>`          | activate the role under the cursor      |
| `a`             | activate every selected role            |
| `d`             | deactivate the active role under cursor |
| `r`             | refresh                                 |
| `g?`            | key help                                |
| `q`/`<Esc>`     | close                                   |

Activation asks for a justification and a duration (pre-filled with your
defaults); the list refreshes a couple of seconds later, once Azure has
provisioned the assignment.

## Options

```lua
require("azpim").setup({
  duration = "PT8H",                                -- ISO 8601 activation length
  justification = "Activated from Neovim (:AzPim)",
  prompt = true,                                    -- false: activate with the defaults, no prompts
  graph_client_id = nil,                            -- public client for the Entra sign-in; see below
  window = { width = 124, height = 42, border = "rounded" },
})
```

## Commands

| Command | Action |
| --- | --- |
| `:AzPim` | open the window |
| `:AzPimClose` | close it |
| `:AzPimGraphLogout` | forget the cached Graph token (Entra ID roles) |

---

# Entra ID roles sign in separately

This applies to both clients. The Azure CLI cannot reach the Entra PIM
endpoints at all, and this is not something you can configure your way out of:

- a plain CLI token is refused by Graph with `PermissionScopeNotGranted`;
- asking for the scopes explicitly — `az login --scope
  https://graph.microsoft.com/RoleManagement.Read.Directory ...` — is rejected
  with `AADSTS65002`, because a Microsoft first-party app can only request
  scopes the API owner has preauthorized it for. Tenant admin consent does not
  override that.

So each client signs in to Graph on its own:

- **Neovim** runs a device-code flow. The first time you open a window with
  Entra roles in it, it shows a code, copies it to `+`, and opens the
  verification page; the Entra sections fill in once you finish. The refresh
  token is cached at `stdpath("cache")/azpim-graph-token.json` (mode `0600`).
  `:AzPimGraphLogout` forgets it.
- **VS Code** asks its built-in Microsoft account provider first and falls back
  to the same device-code flow, keeping the refresh token in SecretStorage.
  See [`vscode/README.md`](vscode/README.md#entra-id-roles-sign-in-separately).

## Preferably, use your own app registration

By default the sign-in uses Microsoft Graph PowerShell's public client, which is
preauthorized for the whole delegated Graph surface. It works with no setup, but
the token it returns carries **every Graph scope your tenant has ever consented
for that app** — often `Directory.ReadWrite.All`, `Sites.FullControl.All` and
dozens more. The cached credential can therefore mint broadly privileged tokens.

Registering a dedicated public client fixes that: the token then carries only
the three PIM scopes. All three are admin-consent-only, so a Global Admin (or
Privileged Role Administrator) runs this once:

```sh
cat > perms.json <<'JSON'
[{"resourceAppId":"00000003-0000-0000-c000-000000000000","resourceAccess":[
  {"id":"eb0788c2-6d4e-4658-8c9e-c0fb8053f03d","type":"Scope"},
  {"id":"8c026be3-8e26-4774-9372-8d5d6f21daff","type":"Scope"},
  {"id":"741c54c3-0c1e-44a1-818b-3f97ab4e8c83","type":"Scope"}]}]
JSON

APP=$(az ad app create --display-name "AzPim" \
  --is-fallback-public-client true \
  --required-resource-accesses @perms.json \
  --query appId -o tsv)
az ad sp create --id "$APP"
az ad app permission admin-consent --id "$APP"
echo "$APP"
```

Then point the client at it and forget the cached sign-in once:

| Client | Setting | Then run |
| --- | --- | --- |
| Neovim | `graph_client_id = "<appId>"` | `:AzPimGraphLogout` |
| VS Code | `azpim.graphClientId` | **Azure PIM: Forget Cached Entra ID Sign-in** |

| Scope | Permission id |
| --- | --- |
| `RoleEligibilitySchedule.Read.Directory` | `eb0788c2-6d4e-4658-8c9e-c0fb8053f03d` |
| `RoleAssignmentSchedule.ReadWrite.Directory` | `8c026be3-8e26-4774-9372-8d5d6f21daff` |
| `RoleManagement.Read.Directory` | `741c54c3-0c1e-44a1-818b-3f97ab4e8c83` |

---

# Notes

- The **ACTIVE** sections list PIM *activations* only — permanent/standing role
  assignments are deliberately hidden, since there is nothing to activate or
  deactivate about them.
- `via group` marks an eligibility you hold through group membership rather than
  directly. Activation is still attempted as yourself; if your tenant requires
  activating the group membership instead, Azure's error is surfaced verbatim.
- Roles that require approval or MFA return the request in a `PendingApproval`
  state — the notification reports success, but the role only appears under
  ACTIVE once approved.
- Entra ID roles cannot be deactivated for the first **5 minutes** after
  activation; Graph rejects `selfDeactivate` with "The Active duration is too
  short". Wait it out, or let the activation expire.
- Neither client writes anything to your project. Credentials live in the
  Neovim cache file above or in VS Code's SecretStorage; nothing else is
  persisted.

## API used

Neovim reaches ARM through `az rest` and Graph through `curl`; VS Code uses
Node's `fetch` with a token from `az account get-access-token`. Same endpoints
either way.

| What | Endpoint |
| --- | --- |
| Azure eligible | `GET /providers/Microsoft.Authorization/roleEligibilityScheduleInstances?$filter=asTarget()` |
| Azure active | `GET /providers/Microsoft.Authorization/roleAssignmentScheduleInstances?$filter=asTarget()` |
| Azure (de)activate | `PUT {scope}/providers/Microsoft.Authorization/roleAssignmentScheduleRequests/{guid}` |
| Entra eligible | `GET /roleManagement/directory/roleEligibilityScheduleInstances` |
| Entra active | `GET /roleManagement/directory/roleAssignmentScheduleInstances` |
| Entra (de)activate | `POST /roleManagement/directory/roleAssignmentScheduleRequests` |

## Repository layout

```
lua/azpim/        the Neovim plugin — init, ui, az, graph
plugin/azpim.lua  its command stub
vscode/           the VS Code extension (TypeScript)
```

## License

[MIT-0](LICENSE) — MIT with the attribution requirement removed. Do whatever you
like with it; no notice to preserve, no conditions to meet.
