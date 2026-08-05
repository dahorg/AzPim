// Thin wrapper over the Azure CLI. It is used for three things only —
// identifying the signed-in user, naming the tenant, and minting ARM tokens.
// Every actual PIM call goes out over HTTP from here.

import { execFile } from "node:child_process";
import * as vscode from "vscode";

export class AzError extends Error {}

function azPath(): string {
  return vscode.workspace.getConfiguration("azpim").get<string>("azureCliPath") || "az";
}

/** Run `az <args>` and parse its stdout as JSON. */
export function azJson<T = any>(args: string[]): Promise<T> {
  return new Promise((resolve, reject) => {
    execFile(
      azPath(),
      args,
      // az.cmd is a batch file, so Windows needs a shell to launch it.
      { shell: process.platform === "win32", maxBuffer: 32 * 1024 * 1024, windowsHide: true },
      (err, stdout, stderr) => {
        if (err) {
          const msg = (stderr || stdout || String(err)).trim();
          const notFound = (err as NodeJS.ErrnoException).code === "ENOENT";
          reject(new AzError(notFound ? "the Azure CLI (`az`) was not found on your PATH" : msg));
          return;
        }
        if (!stdout.trim()) {
          resolve({} as T);
          return;
        }
        try {
          resolve(JSON.parse(stdout) as T);
        } catch (e) {
          reject(new AzError(`could not parse az output as JSON: ${String(e)}`));
        }
      },
    );
  });
}

export interface Account {
  id?: string;
  name?: string;
  tenantId?: string;
  tenantDisplayName?: string;
  user?: { name?: string; type?: string };
}

export function account(): Promise<Account> {
  return azJson<Account>(["account", "show", "-o", "json"]);
}

let cachedOid: string | undefined;

/** Object id of the signed-in user. Cached for the session. */
export async function signedInUser(): Promise<string> {
  if (!cachedOid) {
    const data = await azJson<{ id?: string }>(["ad", "signed-in-user", "show", "-o", "json"]);
    if (!data.id) {
      throw new AzError("could not determine the signed-in user's object id");
    }
    cachedOid = data.id;
  }
  return cachedOid;
}

interface CliToken {
  accessToken: string;
  expiresOn?: string;
  expires_on?: number;
}

const armToken: { value?: string; expiresAt: number } = { expiresAt: 0 };

/** ARM access token from the CLI's own cache, refreshed a minute before expiry. */
export async function armAccessToken(): Promise<string> {
  if (armToken.value && armToken.expiresAt - 60_000 > Date.now()) {
    return armToken.value;
  }
  const data = await azJson<CliToken>([
    "account",
    "get-access-token",
    "--resource",
    "https://management.azure.com",
    "-o",
    "json",
  ]);
  if (!data.accessToken) {
    throw new AzError("the Azure CLI returned no access token — try `az login`");
  }
  armToken.value = data.accessToken;
  // expires_on is epoch seconds; expiresOn is a local-time string with no zone.
  armToken.expiresAt = data.expires_on ? data.expires_on * 1000 : Date.parse(data.expiresOn ?? "") || Date.now() + 3_000_000;
  return armToken.value;
}

export function forgetArmToken(): void {
  armToken.value = undefined;
  armToken.expiresAt = 0;
}
