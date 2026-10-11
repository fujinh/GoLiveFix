/*
 * Windows tunnel backend (Electron MAIN process).
 *
 * Steering here is per-socket, not per-namespace: a proxy version.dll
 * (windows-hook/) loaded into every Discord process binds new sockets to the
 * WireGuard tunnel's local address, which makes Windows route them over the
 * tunnel, while unbound sockets go direct. The DLL and the plugin share one
 * file, <userData>\goLiveFix\state: the mode, then (unless disarmed) the
 * tunnel's IPv4, e.g. "arm 10.2.0.2". The DLL reads it per new socket.
 *
 * So set()/mode() here are just writing and reading that file — no privileged
 * helper, unlike the Linux namespace. Once the DLL sits next to Discord.exe
 * it's loaded by every Discord start, so a running Discord enters the tunnel
 * by arming and reloading its UI; only placing the DLL (first time, and after
 * each Discord update) takes a restart.
 */

import { createSocket } from "dgram";
import { app } from "electron";
import { existsSync, mkdirSync, readdirSync, readFileSync, renameSync, unlinkSync, writeFileSync } from "fs";
import vpnDllBase64 from "file://windows-hook/version.dll?base64";
import { networkInterfaces } from "os";
import { dirname, join } from "path";

import type { TunnelBackend, WgMode } from "./tunnel";

// Must match windows-hook/src/lib.rs. GOLIVEFIX_STATE overrides it there too.
const STATE_PATH = process.env.GOLIVEFIX_STATE || join(app.getPath("userData"), "goLiveFix", "state");

// WireGuard for Windows names the adapter after the tunnel.
const TUNNEL_ADAPTER = process.env.GOLIVEFIX_ADAPTER || "golivefix";

// Set on a Discord relaunched into the tunnel: it boots armed and counts as
// already in. Read once and dropped, so later restarts don't inherit it.
const BOOT_ARMED_ENV = "GOLIVEFIX_BOOT_ARMED";
const bootArmed = !!process.env[BOOT_ARMED_ENV];
delete process.env[BOOT_ARMED_ENV];
// Older builds passed the address in the env; it would override the file in
// the DLL of every process Discord spawns from now on.
delete process.env.GOLIVEFIX_TUNNEL_IP;

export class WindowsTunnel implements TunnelBackend {
    // Whether this session is in the tunnel: it booted armed or entered in
    // place. The DLL being loaded only means it can be.
    private entered = bootArmed;

    constructor() {
        // The DLL acts in every Discord start, so a mode left by an earlier
        // session (say, one that crashed armed) would steer this one's first
        // connections. Start disarmed unless this Discord was relaunched armed.
        if (!bootArmed && this.mode() !== "disarm")
            writeState("disarm").catch(() => { /* nothing to do; logged nowhere yet */ });
    }

    get available(): boolean {
        return this.entered && proxyLoaded();
    }

    mode(): WgMode | null {
        try {
            const word = readFileSync(STATE_PATH, "utf8").trim().split(/\s+/)[0];
            return word === "arm" || word === "keep" ? word : "disarm";
        } catch {
            return "disarm";
        }
    }

    async set(mode: WgMode): Promise<void> {
        if (!proxyLoaded())
            throw new Error("túnel indisponível: ligue pelo escudo para o Discord reiniciar com o GoLiveFix");
        // The address is re-read each time: the tunnel may have come up (or
        // changed) since. Disarm needs none, so it works with the tunnel down.
        await writeState(mode === "disarm" ? mode : `${mode} ${tunnelIp()}`);
    }

    async enterInPlace(): Promise<boolean> {
        if (!proxyLoaded()) return false;
        await checkTunnelRoute(tunnelIp());
        await this.set("arm");
        this.entered = true;
        return true;
    }

    /**
     * Place the proxy DLL next to Discord.exe and relaunch Discord armed (or
     * not), so the new process and its children load the DLL. Fails with
     * Discord still open if the WireGuard tunnel isn't up or can't carry
     * traffic.
     */
    async relaunchIntoTunnel(_baseDir: string, arm: boolean): Promise<void> {
        const ip = tunnelIp();
        await checkTunnelRoute(ip);

        // Discord.exe's folder. Discord updates make a new app-x.y.z folder
        // without the DLL, so it's placed on every relaunch.
        placeProxyDll(join(dirname(process.execPath), "version.dll"));

        await writeState(arm ? `arm ${ip}` : "disarm");
        // The relaunched process is spawned at exit and inherits this env.
        if (arm) process.env[BOOT_ARMED_ENV] = "1";
        app.relaunch();
        // Give the renderer time to get the reply and persist settings.
        setTimeout(() => app.exit(0), 1500);
    }
}

/**
 * Atomic rewrite: the DLL reads the file fresh per socket and never holds it
 * open, so replacing it by rename is safe and the next new connection sees
 * the change. In-place writes could be seen half-done.
 */
async function writeState(line: string): Promise<void> {
    mkdirSync(dirname(STATE_PATH), { recursive: true });
    const tmp = STATE_PATH + ".tmp";
    writeFileSync(tmp, line + "\n");
    // Replacing fails while another process (antivirus, indexer) has either
    // file open without delete sharing; that's brief, so retry.
    for (let i = 0; ; i++) {
        try {
            renameSync(tmp, STATE_PATH);
            return;
        } catch (e: any) {
            if (!["EPERM", "EACCES", "EBUSY"].includes(e?.code) || i >= 20) throw e;
            await new Promise(r => setTimeout(r, 25));
        }
    }
}

// A process never gains or loses the DLL, and the report is costly to build
// (getStatus polls `available`), so look once.
let proxyLoadedCache: boolean | undefined;

/**
 * Is this plugin's own proxy version.dll loaded in this process? An older
 * build (one that only hooked when launched with the tunnel env) doesn't
 * count: it would never steer this process, so it takes a relaunch, which
 * replaces it. The copy on disk is what this process loaded, since the DLL is
 * only ever replaced right before a relaunch.
 */
function proxyLoaded(): boolean {
    if (proxyLoadedCache !== undefined) return proxyLoadedCache;
    try {
        const report: any = (process as any).report?.getReport?.();
        const objs: string[] = report?.sharedObjects ?? [];
        const dir = dirname(process.execPath);
        const loaded = objs.some(p => {
            const s = p.toLowerCase();
            return s.endsWith("\\version.dll") && s.startsWith(dir.toLowerCase());
        });
        proxyLoadedCache = loaded && readFileSync(join(dir, "version.dll")).equals(Buffer.from(vpnDllBase64, "base64"));
    } catch {
        proxyLoadedCache = false;
    }
    return proxyLoadedCache;
}

/**
 * Write the embedded DLL unless the exact bytes are already there. Once
 * placed, every Discord start loads it (passive without the env), so an older
 * copy is usually loaded right now and can't be overwritten — but a loaded DLL
 * can be renamed, so move it aside and write the new one under the real
 * name. The moved copies are deleted on a later run, once nothing has them
 * loaded.
 */
function placeProxyDll(dest: string): void {
    const bytes = Buffer.from(vpnDllBase64, "base64");
    const dir = dirname(dest);
    for (const f of safeReaddir(dir)) {
        if (f.startsWith("version.dll.old-")) try { unlinkSync(join(dir, f)); } catch { /* still loaded */ }
    }
    try {
        if (existsSync(dest) && readFileSync(dest).equals(bytes)) return;
    } catch { /* fall through to write */ }
    try {
        if (existsSync(dest)) renameSync(dest, `${dest}.old-${Date.now()}`);
        writeFileSync(dest, bytes);
    } catch (e: any) {
        throw new Error(`não foi possível gravar a version.dll ao lado do Discord (${e?.code ?? e}); feche o Discord por completo e tente de novo`);
    }
}

function safeReaddir(dir: string): string[] {
    try {
        return readdirSync(dir);
    } catch {
        return [];
    }
}

/** The tunnel adapter's IPv4; its presence also shows that it's up. */
function tunnelIp(): string {
    const addrs = networkInterfaces()[TUNNEL_ADAPTER];
    if (!addrs)
        throw new Error(`o túnel WireGuard "${TUNNEL_ADAPTER}" não está ativo; ative-o no app do WireGuard primeiro`);
    // Older Node reports family as a number.
    const v4 = addrs.find(a => (a.family as string | number) === "IPv4" || (a.family as string | number) === 4);
    if (!v4) throw new Error(`o túnel "${TUNNEL_ADAPTER}" não tem endereço IPv4`);
    return v4.address;
}

/**
 * Can a socket bound to the tunnel IP reach the internet? A UDP connect does
 * the route lookup without sending anything. It fails when the tunnel lacks
 * its catch-all route (setup step: 0.0.0.0/0 on the adapter, high metric),
 * which would leave every steered socket unreachable.
 */
function checkTunnelRoute(ip: string): Promise<void> {
    return new Promise((resolve, reject) => {
        const s = createSocket("udp4");
        const done = (e?: any) => {
            try { s.close(); } catch { /* already closed */ }
            if (!e) return resolve();
            reject(new Error(`o túnel "${TUNNEL_ADAPTER}" não tem rota para a internet (${e?.code ?? e}); falta a rota 0.0.0.0/0 nele, veja o README`));
        };
        s.once("error", done);
        s.bind({ address: ip, port: 0 }, () => s.connect(53, "1.1.1.1", done));
    });
}
