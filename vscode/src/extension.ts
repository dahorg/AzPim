import * as vscode from "vscode";
import { forgetArmToken } from "./cli";
import { GraphAuth, GraphClient } from "./graph";
import { PimItem, label } from "./model";
import { RequestOptions, dispatch, requestStatus } from "./pim";
import { Node, PimTreeProvider, RoleNode } from "./tree";

// Azure provisions activations asynchronously: the request returns long before
// roleAssignmentScheduleInstances catches up, and fan-out across subscriptions
// can take well past a single short delay. Poll with backoff and only call a
// role activated once Azure actually lists it.
const POLL_DELAYS_MS = [2500, 4000, 8000, 15000, 30000];

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

export function activate(context: vscode.ExtensionContext): void {
  const auth = new GraphAuth(context.secrets, context.globalState);
  const graph = new GraphClient(auth);
  const provider = new PimTreeProvider(graph);

  const view = vscode.window.createTreeView<Node>("azpim.roles", {
    treeDataProvider: provider,
    canSelectMany: true,
    showCollapseAll: true,
  });
  context.subscriptions.push(view);

  const syncStatus = () => {
    const parts: string[] = [];
    if (provider.loading) {
      parts.push("Loading roles from Azure…");
    }
    if (provider.device) {
      parts.push(
        `Entra ID sign-in: open ${provider.device.verificationUri} and enter code ${provider.device.userCode}. ` +
          "The Entra sections fill in on their own once you finish.",
      );
    }
    for (const err of provider.errors) {
      parts.push(`⚠ ${err}`);
    }
    if (provider.hint) {
      parts.push(provider.hint);
    }
    const checked = provider.checkedItems().length;
    if (checked > 0) {
      parts.push(`${checked} role${checked === 1 ? "" : "s"} checked — use “Activate Checked Roles”.`);
    }
    view.message = parts.join("\n\n") || undefined;
    const user = provider.account?.user?.name;
    const tenant = provider.account?.tenantDisplayName ?? provider.account?.tenantId;
    view.description = user ? `${user} · ${tenant ?? ""}`.trim() : undefined;
  };
  context.subscriptions.push(provider.onDidChangeStatus(syncStatus));

  auth.onDeviceCode = (info) => {
    provider.device = info;
    syncStatus();
    void vscode.env.clipboard.writeText(info.userCode);
    void vscode.env.openExternal(vscode.Uri.parse(info.verificationUri));
    void vscode.window.showWarningMessage(
      `Azure PIM: enter code ${info.userCode} to sign in for Entra ID roles (copied to the clipboard).`,
      "Copy code again",
      "Open page",
    ).then((choice) => {
      if (choice === "Copy code again") {
        void vscode.env.clipboard.writeText(info.userCode);
      } else if (choice === "Open page") {
        void vscode.env.openExternal(vscode.Uri.parse(info.verificationUri));
      }
    });
  };
  auth.onAuthenticated = () => {
    provider.device = undefined;
    syncStatus();
  };

  context.subscriptions.push(
    view.onDidChangeCheckboxState((e) => {
      for (const [node, state] of e.items) {
        if (node.type === "role") {
          provider.setChecked(node.item, state === vscode.TreeItemCheckboxState.Checked);
        }
      }
    }),
  );

  // Keep the "7h 42m left" column honest without hitting the API.
  const ticker = setInterval(() => {
    if (view.visible) {
      provider.rerender();
    }
  }, 60_000);
  context.subscriptions.push({ dispose: () => clearInterval(ticker) });

  // -------------------------------------------------------------------------

  const itemsFrom = (node?: Node, nodes?: Node[]): PimItem[] => {
    const picked = (nodes && nodes.length > 0 ? nodes : node ? [node] : []) as Node[];
    return picked.filter((n): n is RoleNode => n.type === "role").map((n) => n.item);
  };

  const submit = async (items: PimItem[], action: "activate" | "deactivate") => {
    if (items.length === 0) {
      void vscode.window.showWarningMessage("Azure PIM: no role selected.");
      return;
    }
    const opts = await askOptions(action, items.length);
    if (!opts) {
      return;
    }
    const failures: string[] = [];
    const rejected: string[] = [];
    const awaitingApproval: string[] = [];
    const watching: PimItem[] = [];
    await vscode.window.withProgress(
      {
        location: vscode.ProgressLocation.Notification,
        title: `Azure PIM: ${action === "activate" ? "activating" : "deactivating"} ${items.length} role${
          items.length === 1 ? "" : "s"
        }…`,
      },
      async () => {
        await Promise.all(
          items.map(async (item) => {
            try {
              const data = await dispatch(graph, item, action, opts);
              // A 2xx only means PIM recorded the request. Its own status says
              // whether the role was granted, parked for approval, or
              // rejected — reporting success regardless was how a
              // non-activation could look like an activation.
              const { outcome, status } = requestStatus(data);
              if (outcome === "failed") {
                rejected.push(`${label(item)} (${status})`);
                return;
              }
              provider.setChecked(item, false);
              if (outcome === "approval") {
                awaitingApproval.push(`${label(item)} (${status})`);
                return;
              }
              watching.push(item);
            } catch (e) {
              failures.push(`${label(item)}: ${(e as Error).message ?? String(e)}`);
            }
          }),
        );
      },
    );

    for (const f of failures) {
      void vscode.window.showErrorMessage(`Azure PIM: ${action} failed — ${f}`, { modal: false });
    }
    for (const r of rejected) {
      void vscode.window.showErrorMessage(`Azure PIM: ${action} was rejected by PIM — ${r}`, { modal: false });
    }
    if (awaitingApproval.length > 0) {
      void vscode.window.showWarningMessage(
        `Azure PIM: waiting for approval, not active yet — ${awaitingApproval.join(", ")}`,
      );
    }
    if (watching.length > 0) {
      void confirm(watching, action);
    } else if (awaitingApproval.length > 0) {
      void provider.reload();
    }
  };

  /** Wait for Azure to actually reflect the requests we submitted. */
  const confirm = async (items: PimItem[], action: "activate" | "deactivate") => {
    const want = action === "activate";
    let pending = items;
    await vscode.window.withProgress(
      {
        location: vscode.ProgressLocation.Notification,
        title: `Azure PIM: waiting for Azure to ${want ? "provision" : "revoke"} ${pending.length} role${
          pending.length === 1 ? "" : "s"
        }…`,
      },
      async () => {
        for (const delay of POLL_DELAYS_MS) {
          await sleep(delay);
          await provider.reload();
          const still: PimItem[] = [];
          for (const item of pending) {
            if (provider.isActive(item) === want) {
              void vscode.window.showInformationMessage(
                `Azure PIM: ${want ? "activated" : "deactivated"} ${label(item)}.`,
              );
            } else {
              still.push(item);
            }
          }
          pending = still;
          if (pending.length === 0) {
            return;
          }
        }
      },
    );
    if (pending.length > 0) {
      // Say so rather than leaving the progress notification to imply success.
      void vscode.window.showWarningMessage(
        `Azure PIM: the request was accepted but ${pending.map(label).join(", ")} ${
          pending.length === 1 ? "is" : "are"
        } still ${want ? "not active" : "active"}. Check the Azure portal, or refresh to look again.`,
      );
    }
  };

  const register = (id: string, fn: (...args: any[]) => unknown) =>
    context.subscriptions.push(vscode.commands.registerCommand(id, fn));

  register("azpim.focus", () => vscode.commands.executeCommand("azpim.roles.focus"));
  register("azpim.refresh", () => provider.refresh());
  register("azpim.activate", (node?: Node, nodes?: Node[]) => submit(itemsFrom(node, nodes), "activate"));
  register("azpim.deactivate", (node?: Node, nodes?: Node[]) => submit(itemsFrom(node, nodes), "deactivate"));
  register("azpim.activateChecked", () => submit(provider.checkedItems(), "activate"));
  register("azpim.clearChecked", () => provider.clearChecked());
  register("azpim.entraSignIn", async () => {
    try {
      await vscode.window.withProgress(
        { location: { viewId: "azpim.roles" }, title: "Signing in to Microsoft Graph…" },
        () => provider.refresh(true),
      );
    } catch (e) {
      void vscode.window.showErrorMessage(`Azure PIM: Entra sign-in failed — ${(e as Error).message ?? String(e)}`);
    }
  });
  register("azpim.graphLogout", async () => {
    await auth.logout();
    forgetArmToken();
    void vscode.window.showInformationMessage("Azure PIM: forgot the cached Microsoft Graph sign-in.");
    void provider.refresh();
  });

  context.subscriptions.push(
    vscode.workspace.onDidChangeConfiguration((e) => {
      if (e.affectsConfiguration("azpim")) {
        void provider.refresh();
      }
    }),
  );

  void vscode.commands.executeCommand("setContext", "azpim.hasChecked", false);
  void provider.refresh();
}

export function deactivate(): void {}

/** Collect justification + duration once for a whole batch. */
async function askOptions(action: "activate" | "deactivate", count: number): Promise<RequestOptions | undefined> {
  const cfg = vscode.workspace.getConfiguration("azpim");
  const justification = cfg.get<string>("justification", "Activated from VS Code");
  const duration = cfg.get<string>("duration", "PT8H");

  if (action === "deactivate") {
    return { justification };
  }
  if (!cfg.get<boolean>("prompt", true)) {
    return { justification, duration };
  }

  const just = await vscode.window.showInputBox({
    title: `Activate ${count} role${count === 1 ? "" : "s"}`,
    prompt: "Justification",
    value: justification,
    ignoreFocusOut: true,
  });
  if (just === undefined) {
    return undefined;
  }
  const dur = await vscode.window.showInputBox({
    title: `Activate ${count} role${count === 1 ? "" : "s"}`,
    prompt: "Duration (ISO 8601, e.g. PT8H)",
    value: duration,
    ignoreFocusOut: true,
    validateInput: (v) =>
      /^P(?!$)(\d+D)?(T(?=\d)(\d+H)?(\d+M)?(\d+S)?)?$/.test(v.trim())
        ? undefined
        : "Expected an ISO 8601 duration such as PT8H or PT30M",
  });
  if (dur === undefined) {
    return undefined;
  }
  return { justification: just, duration: dur.trim() };
}
