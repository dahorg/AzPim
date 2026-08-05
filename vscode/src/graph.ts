// Microsoft Graph auth + requests, for the Entra ID (directory) PIM endpoints.
//
// The Azure CLI cannot help here. Its first-party app is not preauthorized for
// the Graph role-management scopes, so `az login --scope
// https://graph.microsoft.com/RoleManagement.Read.Directory ...` is rejected
// outright with AADSTS65002, and a plain CLI token is refused by Graph with
// PermissionScopeNotGranted.
//
// Two ways out, tried in that order:
//   1. VS Code's built-in Microsoft account provider — no code to type, and it
//      can be pointed at your own app registration through the VSCODE_CLIENT_ID
//      scope. Its default client may still be refused the PIM scopes.
//   2. Our own device-code flow against a public client that *is* preauthorized
//      for the delegated Graph surface, with the refresh token in SecretStorage.
//
// Azure *resource* roles need none of this — see pim.ts, which reaches ARM with
// a token from `az account get-access-token`.

import * as vscode from "vscode";

export const GRAPH = "https://graph.microsoft.com/v1.0";

const AUTHORITY = "https://login.microsoftonline.com";

/** Microsoft Graph PowerShell's public client id — preauthorized tenant-wide. */
export const DEFAULT_CLIENT_ID = "14d82eec-204b-4c2f-b7e8-296a70dab67e";

const SCOPES = [
  "https://graph.microsoft.com/RoleEligibilitySchedule.Read.Directory",
  "https://graph.microsoft.com/RoleAssignmentSchedule.ReadWrite.Directory",
  "https://graph.microsoft.com/RoleManagement.Read.Directory",
];

const SECRET_KEY = "azpim.graph.refreshToken";
const VSCODE_AUTH_REJECTED = "azpim.graph.vscodeAuthRejected";

export interface DeviceCode {
  userCode: string;
  verificationUri: string;
  expiresIn: number;
}

export class GraphError extends Error {
  constructor(
    message: string,
    readonly missingScope = false,
  ) {
    super(message);
  }
}

function config() {
  const c = vscode.workspace.getConfiguration("azpim");
  return {
    mode: c.get<"auto" | "vscode" | "device">("entraAuth", "auto"),
    clientId: c.get<string>("graphClientId")?.trim() || DEFAULT_CLIENT_ID,
    tenantId: c.get<string>("graphTenantId")?.trim() || "",
  };
}

/** Graph says this when the token lacks the role-management scopes. */
function looksLikeMissingScope(message: string): boolean {
  return /PermissionScopeNotGranted|Authorization_RequestDenied|insufficient privileges/i.test(message);
}

export class GraphAuth {
  /** Set once the extension knows which tenant `az` is pointed at. */
  cliTenantId: string | undefined;

  /** Replaced by the UI so the code can be shown in the sidebar. */
  onDeviceCode: (info: DeviceCode) => void = (info) => {
    void vscode.window.showWarningMessage(`Azure PIM: open ${info.verificationUri} and enter code ${info.userCode}`);
  };

  onAuthenticated: () => void = () => {};

  private accessToken: string | undefined;
  private expiresAt = 0;
  /** Which flow produced the current access token. */
  private source: "vscode" | "device" | undefined;
  private inFlight: Promise<string> | undefined;

  constructor(
    private readonly secrets: vscode.SecretStorage,
    private readonly memento: vscode.Memento,
  ) {}

  /** True when a token is already held or cached, i.e. no prompt is imminent. */
  async authenticated(): Promise<boolean> {
    if (this.accessToken) {
      return true;
    }
    if (await this.secrets.get(SECRET_KEY)) {
      return true;
    }
    if (config().mode !== "device" && !this.memento.get<boolean>(VSCODE_AUTH_REJECTED)) {
      const session = await vscode.authentication.getSession("microsoft", this.vscodeScopes(), { silent: true });
      return session !== undefined;
    }
    return false;
  }

  /**
   * A Graph access token. Concurrent callers share one acquisition — otherwise
   * the first refresh would start several device-code flows at once.
   */
  token(): Promise<string> {
    if (this.accessToken && this.expiresAt - 60_000 > Date.now()) {
      return Promise.resolve(this.accessToken);
    }
    if (!this.inFlight) {
      this.inFlight = this.acquire().finally(() => {
        this.inFlight = undefined;
      });
    }
    return this.inFlight;
  }

  /** Give up on the token in hand; the next call acquires a fresh one. */
  async invalidate(): Promise<void> {
    if (this.source === "vscode") {
      // The provider's token was refused the PIM scopes — stop asking it.
      await this.memento.update(VSCODE_AUTH_REJECTED, true);
    }
    this.accessToken = undefined;
    this.expiresAt = 0;
    this.source = undefined;
  }

  /** True when there is another flow left to try after invalidate(). */
  canRetryWithAnotherFlow(): boolean {
    return this.source === "vscode" && config().mode === "auto";
  }

  async logout(): Promise<void> {
    this.accessToken = undefined;
    this.expiresAt = 0;
    this.source = undefined;
    await this.secrets.delete(SECRET_KEY);
    await this.memento.update(VSCODE_AUTH_REJECTED, undefined);
  }

  // -------------------------------------------------------------------------

  private vscodeScopes(): string[] {
    const { clientId, tenantId } = config();
    const scopes = [...SCOPES];
    // The built-in provider understands these pseudo-scopes; they let it sign
    // in with your own registration instead of VS Code's own client.
    if (clientId !== DEFAULT_CLIENT_ID) {
      scopes.push(`VSCODE_CLIENT_ID:${clientId}`);
    }
    const tenant = tenantId || this.cliTenantId;
    if (tenant) {
      scopes.push(`VSCODE_TENANT:${tenant}`);
    }
    return scopes;
  }

  private async acquire(): Promise<string> {
    const { mode } = config();
    const rejected = this.memento.get<boolean>(VSCODE_AUTH_REJECTED) === true;

    if (mode !== "device" && !(mode === "auto" && rejected)) {
      try {
        const scopes = this.vscodeScopes();
        // A session may already exist for these scopes; only prompt if not.
        const session =
          (await vscode.authentication.getSession("microsoft", scopes, { silent: true })) ??
          (await vscode.authentication.getSession("microsoft", scopes, { createIfNone: true }));
        if (session) {
          this.accessToken = session.accessToken;
          // The provider refreshes on its own; re-ask often enough to notice.
          this.expiresAt = Date.now() + 10 * 60_000;
          this.source = "vscode";
          this.onAuthenticated();
          return session.accessToken;
        }
        if (mode === "vscode") {
          throw new GraphError("VS Code's Microsoft account provider returned no session");
        }
      } catch (e) {
        if (mode === "vscode") {
          throw e instanceof GraphError ? e : new GraphError(String((e as Error).message ?? e));
        }
        // The provider cannot get the PIM scopes here — remember that, so the
        // next refresh goes straight to the device-code flow.
        await this.memento.update(VSCODE_AUTH_REJECTED, true);
      }
    }

    const token = await this.deviceOrRefresh();
    this.source = "device";
    this.onAuthenticated();
    return token;
  }

  private async deviceOrRefresh(): Promise<string> {
    const refresh = await this.secrets.get(SECRET_KEY);
    if (refresh) {
      try {
        return await this.refreshFlow(refresh);
      } catch {
        // Expired or revoked: sign in again rather than fail.
        await this.secrets.delete(SECRET_KEY);
      }
    }
    return this.deviceFlow();
  }

  private async tenant(): Promise<string> {
    return config().tenantId || this.cliTenantId || "organizations";
  }

  private async post(path: string, form: Record<string, string>): Promise<any> {
    const res = await fetch(`${AUTHORITY}/${await this.tenant()}${path}`, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams(form).toString(),
    });
    const text = await res.text();
    try {
      return JSON.parse(text);
    } catch {
      throw new GraphError(`unexpected sign-in response (HTTP ${res.status}): ${text.slice(0, 300)}`);
    }
  }

  private store(data: any): string {
    this.accessToken = data.access_token;
    this.expiresAt = Date.now() + (Number(data.expires_in) || 3600) * 1000;
    if (data.refresh_token) {
      // SecretStorage keeps this in the OS keychain — it can mint Graph tokens.
      void this.secrets.store(SECRET_KEY, data.refresh_token);
    }
    return this.accessToken!;
  }

  private async refreshFlow(refreshToken: string): Promise<string> {
    const data = await this.post("/oauth2/v2.0/token", {
      grant_type: "refresh_token",
      client_id: config().clientId,
      refresh_token: refreshToken,
      scope: [...SCOPES, "offline_access"].join(" "),
    });
    if (!data.access_token) {
      throw new GraphError(data.error_description || data.error || "refresh failed");
    }
    return this.store(data);
  }

  private async deviceFlow(): Promise<string> {
    const clientId = config().clientId;
    const start = await this.post("/oauth2/v2.0/devicecode", {
      client_id: clientId,
      scope: [...SCOPES, "offline_access"].join(" "),
    });
    if (!start.device_code) {
      throw new GraphError(start.error_description || start.error || "could not start device-code sign-in");
    }
    this.onDeviceCode({
      userCode: start.user_code,
      verificationUri: start.verification_uri ?? "https://login.microsoft.com/device",
      expiresIn: Number(start.expires_in) || 900,
    });

    const deadline = Date.now() + (Number(start.expires_in) || 900) * 1000;
    let interval = (Number(start.interval) || 5) * 1000;
    for (;;) {
      await new Promise((r) => setTimeout(r, interval));
      const data = await this.post("/oauth2/v2.0/token", {
        grant_type: "urn:ietf:params:oauth:grant-type:device_code",
        client_id: clientId,
        device_code: start.device_code,
      });
      if (data.access_token) {
        return this.store(data);
      }
      if (data.error === "authorization_pending" || data.error === "slow_down") {
        if (Date.now() > deadline) {
          throw new GraphError("device-code sign-in timed out");
        }
        if (data.error === "slow_down") {
          interval += 5000;
        }
        continue;
      }
      throw new GraphError(data.error_description || data.error || "device-code sign-in failed");
    }
  }
}

export class GraphClient {
  constructor(readonly auth: GraphAuth) {}

  /** One Graph call, retrying once if a token turns out to lack the scopes. */
  async request(method: string, url: string, body?: unknown, retried = false): Promise<any> {
    const token = await this.auth.token();
    const res = await fetch(url, {
      method: method.toUpperCase(),
      headers: {
        Authorization: `Bearer ${token}`,
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
        throw new GraphError(`could not parse Graph response as JSON: ${text.slice(0, 300)}`);
      }
    }
    if (data.error || !res.ok) {
      const message = graphErrorMessage(data) ?? `Graph returned HTTP ${res.status}`;
      const missing = looksLikeMissingScope(message) || res.status === 403;
      if (missing && !retried && this.auth.canRetryWithAnotherFlow()) {
        await this.auth.invalidate();
        return this.request(method, url, body, true);
      }
      if (missing) {
        await this.auth.invalidate();
      }
      throw new GraphError(message, missing);
    }
    return data;
  }

  /** GET a URL, following `@odata.nextLink` until exhausted. */
  async getAll(url: string): Promise<any[]> {
    const out: any[] = [];
    let next: string | undefined = url;
    while (next) {
      const data = await this.request("get", next);
      out.push(...(data.value ?? []));
      next = data["@odata.nextLink"];
    }
    return out;
  }
}

function graphErrorMessage(data: any): string | undefined {
  const e = data?.error;
  if (e && typeof e === "object") {
    return e.message || e.code || JSON.stringify(e);
  }
  if (typeof e === "string") {
    return data.error_description || e;
  }
  return undefined;
}

export const GRAPH_SCOPE_HINT =
  "Entra ID roles need the Graph role-management scopes consented for the client in use. " +
  "A Global Admin must grant them — see the README. Then run “Azure PIM: Forget Cached Entra ID Sign-in” and retry.";
