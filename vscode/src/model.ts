// Shared shape of a PIM role row, plus the small bits of formatting the tree
// and the quick pick both need.

export type Kind = "azure" | "entra";
export type State = "eligible" | "active";

export interface PimItem {
  kind: Kind;
  state: State;
  /** Display name of the role definition. */
  role: string;
  /** Display name of the scope (resource group, subscription, "Directory", …). */
  scope: string;
  scopeType?: string;
  /** ARM resource id, or a Graph directory scope such as "/". */
  scopeId: string;
  roleDefinitionId: string;
  /** Set on eligibilities; ARM activations must link back to it. */
  eligibilityId?: string;
  /** "Group" when the eligibility is held through group membership. */
  memberType?: string;
  endTime?: string;
}

/** Stable identity of a row, so a checkbox survives a refresh. */
export function keyOf(item: PimItem): string {
  return [item.kind, item.state, item.role, item.scopeId].join("\u0000");
}

export function sortItems(items: PimItem[]): PimItem[] {
  return items.sort(
    (a, b) => a.kind.localeCompare(b.kind) || a.role.localeCompare(b.role) || a.scope.localeCompare(b.scope),
  );
}

/** "7h 42m left" — or "permanent"/"expired" at the edges. */
export function remaining(item: PimItem): string {
  if (!item.endTime) {
    return "permanent";
  }
  const end = Date.parse(item.endTime);
  if (Number.isNaN(end)) {
    return "permanent";
  }
  const secs = Math.floor((end - Date.now()) / 1000);
  if (secs <= 0) {
    return "expired";
  }
  const d = Math.floor(secs / 86400);
  const h = Math.floor((secs % 86400) / 3600);
  const m = Math.floor((secs % 3600) / 60);
  if (d > 0) {
    return `${d}d ${h}h left`;
  }
  if (h > 0) {
    return `${h}h ${m}m left`;
  }
  return `${m}m left`;
}

export function label(item: PimItem): string {
  return `${item.role} @ ${item.scope}`;
}
