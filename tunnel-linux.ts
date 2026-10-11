/*
 * Linux tunnel backend (Electron MAIN process).
 *
 * Routing can only be steered when Discord runs under discord-vpn.sh, which
 * puts it in a network namespace with a WireGuard tunnel and hands the plugin
 * a control FIFO. When it doesn't, relaunchIntoTunnel() restarts Discord under
 * the script (bundled into the plugin at build time).
 * It steers *all* traffic, including the native voice engine's UDP, by
 * switching policy-routing modes in that namespace (see tunnel.ts for the
 * modes). In every mode, TCP connections opened through the tunnel stay in it.
 */

import { execFile, spawn } from "child_process";
import { app } from "electron";
import vpnScript from "file://discord-vpn.sh?trim=false";
import { chmodSync, closeSync, constants, existsSync, mkdirSync, openSync, readFileSync, writeFileSync, writeSync } from "fs";
import { join } from "path";

import type { TunnelBackend, WgMode } from "./tunnel";

const CTL = process.env.DCVPN_CTL;
const STATE = process.env.DCVPN_STATE;

const sleep = (ms: number) => new Promise(r => setTimeout(r, ms));

export class LinuxTunnel implements TunnelBackend {
    /** Was Discord launched by discord-vpn.sh (and is its supervisor alive)? */
    get available(): boolean {
        return !!CTL && !!STATE && existsSync(CTL);
    }

    mode(): WgMode | null {
        if (!this.available) return null;
        try { return readFileSync(STATE!, "utf8").trim() as WgMode; } catch { return null; }
    }

    /** Ask the supervisor for a mode and wait until it reports having applied it. */
    async set(mode: WgMode): Promise<void> {
        if (!this.available)
            throw new Error("WireGuard indisponível: abra o Discord pelo discord-vpn.sh");

        // Non-blocking open fails with ENXIO while the supervisor is between
        // reads (or dead) instead of hanging; retry briefly.
        let fd = -1;
        for (let i = 0; fd < 0; i++) {
            try {
                fd = openSync(CTL!, constants.O_WRONLY | constants.O_NONBLOCK);
            } catch (e: any) {
                if (e?.code !== "ENXIO" || i >= 30) throw new Error(`controle do discord-vpn não responde (${e?.code ?? e})`);
                await sleep(100);
            }
        }
        try { writeSync(fd, mode + "\n"); } finally { closeSync(fd); }

        // "keep" is a no-op unless armed, so accept whatever the supervisor settles on.
        const want = (m: WgMode | null) => m === mode || (mode === "keep" && m !== "arm");
        for (let i = 0; i < 50; i++) {
            if (want(this.mode())) return;
            await sleep(100);
        }
        throw new Error(`discord-vpn não confirmou o modo "${mode}"`);
    }

    /** A process can't join the namespace after it started: only a relaunch can. */
    async enterInPlace(): Promise<boolean> {
        return false;
    }

    /**
     * Restart Discord inside discord-vpn's namespace, the same way
     * app.relaunch() would (same binary and args). Requirements are checked
     * first, so a missing dependency fails here with Discord still open; past
     * that, the script falls back to a normal start if the tunnel fails.
     * Discord exits shortly after this resolves.
     */
    async relaunchIntoTunnel(baseDir: string, arm: boolean): Promise<void> {
        // Nothing creates it before the first relaunch on this install.
        mkdirSync(baseDir, { recursive: true });
        const script = join(baseDir, "discord-vpn.sh");
        writeFileSync(script, vpnScript);
        chmodSync(script, 0o700);

        await new Promise<void>((resolve, reject) => {
            execFile(script, ["--check"], (err, _out, stderr) => {
                if (!err) return resolve();
                const last = stderr.trim().split("\n").pop()?.replace(/^discord-vpn: /, "");
                reject(new Error(last || err.message));
            });
        });

        const logFd = openSync(join(baseDir, "discord-vpn.log"), "w");
        const child = spawn(script, [
            "--wait-pid", String(process.pid),
            ...(arm ? ["--arm"] : []),
            "--", ...process.argv.slice(1)
        ], {
            detached: true, // must outlive this Discord
            stdio: ["ignore", logFd, logFd],
            env: { ...process.env, DCVPN_DISCORD: process.execPath }
        });
        closeSync(logFd);
        child.unref();

        // Give the renderer time to get the reply and persist settings.
        setTimeout(() => app.exit(0), 1500);
    }
}
