// PIM operations. Azure resource roles go to ARM with a token from the Azure
// CLI; Entra ID roles go through graph.ts, which holds its own token because
// the CLI's app registration can never obtain the Graph role-management scopes.

import { randomUUID } from "node:crypto";
import { armAccessToken, signedInUser } from "./cli";
import { GRAPH, GraphClient } from "./graph";
import { PimItem } from "./model";

const ARM = "https://management.azure.com";
const ARM_API = "2020-10-01";

export interface RequestOptions {
  justification: string;
  duration?: string;
  ticketNumber?: string;
  ticketSystem?: string;
}

export class ArmError extends Error {}

async function arm(method: string, url: string, body?: unknown): Promise<any> {
  const token = await armAccessToken();
  const res = await fetch(url, {
    method: method.toUpperCase(),
    headers: {
      Authorization: `Bearer ${token}`,
      // Node's fetch would otherwise send `Accept-Language: *`, which ARM
      // rejects outright with CultureNotFoundException.
      "Accept-Language": "en-US",
      ...(body === undefined ? {} : { "Content-Type": "application/json" }),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  let data: any = {};
  if (text.trim()) {
    try {
      data = JSON.parse(text);
    } catch {
      throw new ArmError(`could not parse the ARM response as JSON: ${text.slice(0, 300)}`);
    }
  }
  if (!res.ok || data.error) {
    const e = data.error;
    const message = (e && (e.message || e.code)) || `ARM returned HTTP ${res.status}`;
    throw new ArmError(message);
  }
  return data;
}

/** GET a URL, following `nextLink` until exhausted. */
async function armGetAll(url: string): Promise<any[]> {
  const out: any[] = [];
  let next: string | undefined = url;
  while (next) {
    const data = await arm("get", next);
    out.push(...(data.value ?? []));
    next = data.nextLink ?? data["@odata.nextLink"];
  }
  return out;
}

// ---------------------------------------------------------------------------
// Azure resource roles (ARM)
// ---------------------------------------------------------------------------

const AS_TARGET = `?api-version=${ARM_API}&$filter=${encodeURIComponent("asTarget()")}`;

export async function azureEligible(): Promise<PimItem[]> {
  const items = await armGetAll(
    `${ARM}/providers/Microsoft.Authorization/roleEligibilityScheduleInstances${AS_TARGET}`,
  );
  return items.map((it) => {
    const p = it.properties ?? {};
    const ex = p.expandedProperties ?? {};
    return {
      kind: "azure",
      state: "eligible",
      role: ex.roleDefinition?.displayName ?? p.roleDefinitionId,
      scope: ex.scope?.displayName ?? p.scope,
      scopeType: ex.scope?.type,
      scopeId: p.scope,
      roleDefinitionId: p.roleDefinitionId,
      eligibilityId: p.roleEligibilityScheduleId,
      memberType: p.memberType,
      endTime: p.endDateTime ?? undefined,
    } satisfies PimItem;
  });
}

export async function azureActive(): Promise<PimItem[]> {
  const items = await armGetAll(
    `${ARM}/providers/Microsoft.Authorization/roleAssignmentScheduleInstances${AS_TARGET}`,
  );
  const seen = new Set<string>();
  return items
    // Only PIM activations, not standing/permanent assignments.
    .filter((it) => (it.properties ?? {}).assignmentType === "Activated")
    .map((it) => {
      const p = it.properties ?? {};
      const ex = p.expandedProperties ?? {};
      return {
        kind: "azure",
        state: "active",
        role: ex.roleDefinition?.displayName ?? p.roleDefinitionId,
        scope: ex.scope?.displayName ?? p.scope,
        scopeType: ex.scope?.type,
        scopeId: p.scope,
        roleDefinitionId: p.roleDefinitionId,
        eligibilityId: p.linkedRoleEligibilityScheduleId,
        memberType: p.memberType,
        endTime: p.endDateTime ?? undefined,
      } satisfies PimItem;
    })
    // The same activation can be reported once per inherited group path;
    // collapse those down to a single row per role+scope.
    .filter((item) => {
      const key = `${item.scopeId}|${item.roleDefinitionId}`;
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    });
}

async function azureRequest(item: PimItem, action: "activate" | "deactivate", opts: RequestOptions): Promise<void> {
  const oid = await signedInUser();
  const props: Record<string, unknown> = {
    principalId: oid,
    roleDefinitionId: item.roleDefinitionId,
    requestType: action === "activate" ? "SelfActivate" : "SelfDeactivate",
    justification: opts.justification,
  };
  if (action === "activate") {
    props.linkedRoleEligibilityScheduleId = item.eligibilityId;
    props.scheduleInfo = {
      startDateTime: new Date().toISOString(),
      expiration: { type: "AfterDuration", duration: opts.duration },
    };
    if (opts.ticketNumber) {
      props.ticketInfo = { ticketNumber: opts.ticketNumber, ticketSystem: opts.ticketSystem };
    }
  }
  const url =
    ARM +
    item.scopeId +
    "/providers/Microsoft.Authorization/roleAssignmentScheduleRequests/" +
    randomUUID() +
    "?api-version=" +
    ARM_API;
  await arm("put", url, { properties: props });
}

// ---------------------------------------------------------------------------
// Entra ID (directory) roles (Microsoft Graph)
// ---------------------------------------------------------------------------

function graphScopeLabel(it: any): string {
  const scope = it.directoryScopeId ?? "/";
  return scope === "/" ? "Directory" : scope;
}

function entraUrl(collection: string, oid: string): string {
  return (
    `${GRAPH}/roleManagement/directory/${collection}` +
    `?$filter=${encodeURIComponent(`principalId eq '${oid}'`)}&$expand=roleDefinition`
  );
}

export async function entraEligible(graph: GraphClient): Promise<PimItem[]> {
  const oid = await signedInUser();
  const items = await graph.getAll(entraUrl("roleEligibilityScheduleInstances", oid));
  return items.map((it) => ({
    kind: "entra",
    state: "eligible",
    role: it.roleDefinition?.displayName ?? it.roleDefinitionId,
    scope: graphScopeLabel(it),
    scopeId: it.directoryScopeId ?? "/",
    roleDefinitionId: it.roleDefinitionId,
    eligibilityId: it.roleEligibilityScheduleId,
    memberType: it.memberType,
    endTime: it.endDateTime ?? undefined,
  }));
}

export async function entraActive(graph: GraphClient): Promise<PimItem[]> {
  const oid = await signedInUser();
  const items = await graph.getAll(entraUrl("roleAssignmentScheduleInstances", oid));
  return (
    items
      // Permanent directory assignments have no linked eligibility and no end;
      // treat anything time-bound or eligibility-linked as an activation.
      .filter((it) => it.assignmentType === "Activated" || it.endDateTime || it.roleEligibilityScheduleInstanceId)
      .map((it) => ({
        kind: "entra",
        state: "active",
        role: it.roleDefinition?.displayName ?? it.roleDefinitionId,
        scope: graphScopeLabel(it),
        scopeId: it.directoryScopeId ?? "/",
        roleDefinitionId: it.roleDefinitionId,
        memberType: it.memberType,
        endTime: it.endDateTime ?? undefined,
      }))
  );
}

async function entraRequest(
  graph: GraphClient,
  item: PimItem,
  action: "activate" | "deactivate",
  opts: RequestOptions,
): Promise<void> {
  const oid = await signedInUser();
  const body: Record<string, unknown> = {
    action: action === "activate" ? "selfActivate" : "selfDeactivate",
    principalId: oid,
    roleDefinitionId: item.roleDefinitionId,
    directoryScopeId: item.scopeId || "/",
    justification: opts.justification,
  };
  if (action === "activate") {
    body.scheduleInfo = {
      startDateTime: new Date().toISOString(),
      expiration: { type: "afterDuration", duration: opts.duration },
    };
    if (opts.ticketNumber) {
      body.ticketInfo = { ticketNumber: opts.ticketNumber, ticketSystem: opts.ticketSystem };
    }
  }
  await graph.request("post", `${GRAPH}/roleManagement/directory/roleAssignmentScheduleRequests`, body);
}

export function dispatch(
  graph: GraphClient,
  item: PimItem,
  action: "activate" | "deactivate",
  opts: RequestOptions,
): Promise<void> {
  return item.kind === "azure" ? azureRequest(item, action, opts) : entraRequest(graph, item, action, opts);
}
