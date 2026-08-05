// The sidebar: eligible roles on top, active activations below, one section
// per (state, kind) pair — the same four sections the Neovim window shows.

import * as vscode from "vscode";
import { Account, account } from "./cli";
import { DeviceCode, GRAPH_SCOPE_HINT, GraphClient, GraphError } from "./graph";
import { Kind, PimItem, State, keyOf, remaining, sortItems } from "./model";
import { azureActive, azureEligible, entraActive, entraEligible } from "./pim";

export interface SectionNode {
  type: "section";
  id: string;
  title: string;
  kind: Kind;
  state: State;
}

export interface RoleNode {
  type: "role";
  item: PimItem;
}

/** A clickable row that stands in for a section's contents. */
export interface ActionNode {
  type: "action";
  parent: string;
  label: string;
  tooltip?: string;
  icon?: string;
  command?: vscode.Command;
}

export type Node = SectionNode | RoleNode | ActionNode;

const SECTIONS: SectionNode[] = [
  { type: "section", id: "eligible-azure", title: "Eligible — Azure resources", kind: "azure", state: "eligible" },
  { type: "section", id: "eligible-entra", title: "Eligible — Entra ID roles", kind: "entra", state: "eligible" },
  { type: "section", id: "active-azure", title: "Active — Azure resources", kind: "azure", state: "active" },
  { type: "section", id: "active-entra", title: "Active — Entra ID roles", kind: "entra", state: "active" },
];

export class PimTreeProvider implements vscode.TreeDataProvider<Node> {
  private readonly _onDidChangeTreeData = new vscode.EventEmitter<Node | undefined>();
  readonly onDidChangeTreeData = this._onDidChangeTreeData.event;

  /** Fires whenever the header line (loading, errors, sign-in) should change. */
  private readonly _onDidChangeStatus = new vscode.EventEmitter<void>();
  readonly onDidChangeStatus = this._onDidChangeStatus.event;

  loading = false;
  account: Account | undefined;
  errors: string[] = [];
  hint: string | undefined;
  device: DeviceCode | undefined;
  /** Set when Entra roles are listable only after an interactive sign-in. */
  entraNeedsSignIn = false;

  private eligible: PimItem[] = [];
  private active: PimItem[] = [];
  private checked = new Set<string>();
  private refreshing: Promise<void> | undefined;

  constructor(private readonly graph: GraphClient) {}

  // -- data ------------------------------------------------------------------

  /** Reload everything. Concurrent callers share one in-flight load. */
  refresh(interactiveEntra = false): Promise<void> {
    const start = () => {
      this.refreshing = this.load(interactiveEntra).finally(() => {
        this.refreshing = undefined;
      });
      return this.refreshing;
    };
    if (!this.refreshing) {
      return start();
    }
    // A sign-in was asked for while a silent load was running — it would have
    // skipped the Entra sections, so queue a second pass behind it.
    return interactiveEntra ? this.refreshing.then(start) : this.refreshing;
  }

  private async load(interactiveEntra: boolean): Promise<void> {
    this.loading = true;
    this.errors = [];
    this.hint = undefined;
    this.emit();

    const cfg = vscode.workspace.getConfiguration("azpim");
    const wantEntra = cfg.get<boolean>("showEntraRoles", true);
    // Signing in pops a browser, so only do it when the user asked for it.
    const entraReady = wantEntra && (interactiveEntra || (await this.graph.auth.authenticated()));
    this.entraNeedsSignIn = wantEntra && !entraReady;

    const eligible: PimItem[] = [];
    const active: PimItem[] = [];

    const collect = async (target: PimItem[], label: string, fetch: () => Promise<PimItem[]>) => {
      try {
        target.push(...(await fetch()));
      } catch (e) {
        if (e instanceof GraphError && e.missingScope) {
          this.hint = GRAPH_SCOPE_HINT;
        } else {
          this.errors.push(`${label}: ${(e as Error).message ?? String(e)}`);
        }
      }
    };

    await Promise.all([
      account()
        .then((a) => {
          this.account = a;
          this.graph.auth.cliTenantId = a.tenantId;
        })
        .catch((e) => this.errors.push(`azure account: ${(e as Error).message ?? String(e)}`)),
      collect(eligible, "azure eligible", azureEligible),
      collect(active, "azure active", azureActive),
      ...(entraReady
        ? [
            collect(eligible, "entra eligible", () => entraEligible(this.graph)),
            collect(active, "entra active", () => entraActive(this.graph)),
          ]
        : []),
    ]);

    this.eligible = sortItems(eligible);
    this.active = sortItems(active);
    // Drop checkboxes for roles that are gone (usually because they went active).
    const live = new Set(this.eligible.map(keyOf));
    for (const k of [...this.checked]) {
      if (!live.has(k)) {
        this.checked.delete(k);
      }
    }
    this.loading = false;
    this.emit();
  }

  /** Re-render without refetching — used to keep "7h 42m left" honest. */
  rerender(): void {
    this._onDidChangeTreeData.fire(undefined);
  }

  private emit(): void {
    this._onDidChangeTreeData.fire(undefined);
    this._onDidChangeStatus.fire();
  }

  // -- selection -------------------------------------------------------------

  setChecked(item: PimItem, on: boolean): void {
    const k = keyOf(item);
    if (on) {
      this.checked.add(k);
    } else {
      this.checked.delete(k);
    }
    void vscode.commands.executeCommand("setContext", "azpim.hasChecked", this.checked.size > 0);
    this._onDidChangeStatus.fire();
  }

  checkedItems(): PimItem[] {
    return this.eligible.filter((it) => this.checked.has(keyOf(it)));
  }

  clearChecked(): void {
    this.checked.clear();
    void vscode.commands.executeCommand("setContext", "azpim.hasChecked", false);
    this.emit();
  }

  // -- tree ------------------------------------------------------------------

  getChildren(node?: Node): Node[] {
    if (!node) {
      const wantEntra = vscode.workspace.getConfiguration("azpim").get<boolean>("showEntraRoles", true);
      return SECTIONS.filter((s) => wantEntra || s.kind !== "entra");
    }
    if (node.type !== "section") {
      return [];
    }
    const items = this.itemsFor(node);
    if (items.length > 0) {
      return items.map((item) => ({ type: "role", item }) satisfies RoleNode);
    }
    if (node.kind === "entra" && this.entraNeedsSignIn) {
      return [
        {
          type: "action",
          parent: node.id,
          label: "Sign in to Microsoft Graph…",
          tooltip:
            "Entra ID roles need a Microsoft Graph token that the Azure CLI cannot obtain. " +
            "This signs in separately; the result is remembered.",
          icon: "sign-in",
          command: { command: "azpim.entraSignIn", title: "Sign in" },
        },
      ];
    }
    return [
      {
        type: "action",
        parent: node.id,
        label: this.loading ? "loading…" : "none",
        icon: this.loading ? "loading~spin" : undefined,
      },
    ];
  }

  getTreeItem(node: Node): vscode.TreeItem {
    if (node.type === "section") {
      const count = this.itemsFor(node).length;
      const t = new vscode.TreeItem(node.title, vscode.TreeItemCollapsibleState.Expanded);
      t.id = node.id;
      t.description = String(count);
      t.contextValue = `azpim.section.${node.id}`;
      return t;
    }
    if (node.type === "action") {
      const t = new vscode.TreeItem(node.label, vscode.TreeItemCollapsibleState.None);
      t.id = `${node.parent}:${node.label}`;
      t.tooltip = node.tooltip;
      t.command = node.command;
      if (node.icon) {
        t.iconPath = new vscode.ThemeIcon(node.icon);
      }
      return t;
    }
    return this.roleTreeItem(node.item);
  }

  private roleTreeItem(item: PimItem): vscode.TreeItem {
    const t = new vscode.TreeItem(item.role, vscode.TreeItemCollapsibleState.None);
    t.id = keyOf(item);
    const extra =
      item.state === "active" ? remaining(item) : item.memberType === "Group" ? "via group" : undefined;
    t.description = extra ? `${item.scope} · ${extra}` : item.scope;
    t.contextValue = item.state === "active" ? "azpim.active" : "azpim.eligible";
    t.iconPath =
      item.state === "active"
        ? new vscode.ThemeIcon("pass-filled", new vscode.ThemeColor("charts.green"))
        : new vscode.ThemeIcon("circle-outline");
    if (item.state === "eligible") {
      t.checkboxState = this.checked.has(keyOf(item))
        ? vscode.TreeItemCheckboxState.Checked
        : vscode.TreeItemCheckboxState.Unchecked;
    }
    t.tooltip = this.tooltip(item);
    return t;
  }

  private tooltip(item: PimItem): vscode.MarkdownString {
    const md = new vscode.MarkdownString();
    md.appendMarkdown(`**${item.role}**\n\n`);
    md.appendMarkdown(`- Scope: \`${item.scope}\`\n`);
    if (item.scopeType) {
      md.appendMarkdown(`- Scope type: ${item.scopeType}\n`);
    }
    md.appendMarkdown(`- Source: ${item.kind === "azure" ? "Azure resources" : "Entra ID"}\n`);
    if (item.memberType) {
      md.appendMarkdown(`- Held: ${item.memberType === "Group" ? "through group membership" : "directly"}\n`);
    }
    if (item.state === "active") {
      md.appendMarkdown(`- Expires: ${item.endTime ? `${item.endTime} (${remaining(item)})` : "never"}\n`);
    }
    return md;
  }

  private itemsFor(section: SectionNode): PimItem[] {
    const source = section.state === "eligible" ? this.eligible : this.active;
    return source.filter((it) => it.kind === section.kind);
  }

  /** Everything currently listed — used to resolve command arguments. */
  allItems(): PimItem[] {
    return [...this.eligible, ...this.active];
  }
}
