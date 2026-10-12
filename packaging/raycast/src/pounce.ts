import { closeMainWindow, open, showHUD, showToast, Toast } from "@raycast/api";
import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

/** Commands the pounce:// URL scheme accepts (it opens the app if needed). */
export type UrlCommand = "hint" | "scroll" | "grid" | "windows" | "menu" | "text" | "mouse";

export async function runURL(command: UrlCommand) {
  await closeMainWindow({ clearRootSearch: true });
  try {
    await open(`pounce://${command}`);
  } catch {
    await showHUD("Pounce isn't installed");
  }
}

const cliCandidates = () => [
  "/opt/homebrew/bin/pounce",
  "/usr/local/bin/pounce",
  join(homedir(), ".nix-profile/bin/pounce"),
  "/run/current-system/sw/bin/pounce",
  join(homedir(), ".local/bin/pounce"),
  "/Applications/Pounce.app/Contents/MacOS/Pounce",
  join(homedir(), "Applications/Pounce.app/Contents/MacOS/Pounce"),
];

export function findCLI(): string | undefined {
  return cliCandidates().find((p) => existsSync(p));
}

/** Commands that aren't exposed over the URL scheme go through the `pounce` CLI (IPC to the app). */
export async function runCLI(args: string[], hud?: string) {
  const cli = findCLI();
  if (!cli) {
    await showToast({
      style: Toast.Style.Failure,
      title: "Pounce not found",
      message: "Install Pounce in /Applications or put the `pounce` CLI on your PATH.",
    });
    return;
  }
  await closeMainWindow({ clearRootSearch: true });
  await new Promise<void>((resolve) => {
    execFile(cli, args, { timeout: 10_000 }, async (error, _stdout, stderr) => {
      if (error) {
        await showHUD(`Pounce: ${(stderr || error.message).trim().split("\n")[0]}`);
      } else if (hud) {
        await showHUD(hud);
      }
      resolve();
    });
  });
}
