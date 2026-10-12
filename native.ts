/*
 * GoLiveFix — native side (Electron MAIN process).
 *
 * Vencord loads every plugin's native.ts in the main process at startup (via
 * ipcPlugins) and exposes its exports to the renderer as
 * VencordNative.pluginHelpers.<Name>. Each exported function receives the IPC
 * event as its first arg (`_`).
 *
 * Owns the tunnel routing control, through the platform's backend (tunnel.ts).
 */

import { RendererSettings } from "@main/settings";
import { app, type IpcMainInvokeEvent, type WebContents } from "electron";
import { join } from "path";

import { createTunnelBackend, type WgMode } from "./tunnel";

const baseDir = join(app.getPath("userData"), "goLiveFix");
const wg = createTunnelBackend();

const recentLogs: string[] = [];
function log(m: string) {
    recentLogs.push(`[${new Date().toLocaleTimeString()}] ${m}`);
    if (recentLogs.length > 40) recentLogs.shift();
    console.log("[GoLiveFix]", m);
}

const errorMessage = (e: any) => String(e?.message ?? e);

// Set when the user turns the tunnel on from inside it: automatic releases
// (stream start, post-restart timer) leave it alone until the user turns it
// off. Lives in the main process so renderer reloads don't forget it.
let held = false;

// Set once a relaunch is under way, so a second click can't start another.
let relaunching = false;

// Mode changes run one at a time, in arrival order. A set() can take a while
// (Linux waits for the supervisor), and overlapping ones could finish in
// either order and leave `held` out of step with the mode.
let chain: Promise<unknown> = Promise.resolve();
function serial<A extends unknown[], R>(fn: (...args: A) => Promise<R>): (...args: A) => Promise<R> {
    return (...args) => {
        const run = chain.then(() => fn(...args));
        chain = run.catch(() => { });
        return run;
    };
}

type EnterResult = { ok: boolean; relaunching?: boolean; reloading?: boolean; error?: string; };

/**
 * Get this Discord into the tunnel, armed and not held, so the new session
 * connects through it from the start. In place when the backend can: the
 * renderer then reloads, which reconnects the gateway and everything else.
 * Otherwise by restarting it there (the main process exits shortly after).
 */
async function enter(sender: WebContents, what: string): Promise<EnterResult> {
    held = false;
    if (await wg.enterInPlace()) {
        // Chromium keeps idle connections (API, CDN) across a page reload;
        // close them so the reloaded UI opens new ones, through the tunnel.
        await sender.session.closeAllConnections();
        log(`${what}: recarregando o Discord`);
        return { ok: true, reloading: true };
    }
    if (wg.available) {
        // Inside the tunnel already (Linux): a plain relaunch inherits it.
        await wg.set("arm");
        // Give the renderer time to get the reply first.
        setTimeout(() => { app.relaunch(); app.exit(0); }, 500);
    } else {
        await wg.relaunchIntoTunnel(baseDir, true);
    }
    relaunching = true;
    log(`${what}: reiniciando o Discord`);
    return { ok: true, relaunching: true };
}

/**
 * With "enter on startup" on, every load of Discord's main page (opening it,
 * Ctrl+R, the reload after a renderer crash, any location.reload()) starts in
 * the tunnel: it's armed here as the navigation starts, before the page opens
 * any connection, rather than by the renderer once it's up, which would take
 * another reload. The renderer then does the usual post-restart release.
 * When this Discord can only get in by restarting, the renderer still does
 * that (enterOnStartup below).
 */
{
    // Discord takes a few seconds to show its page: bring a tunnel that's
    // down up meanwhile, so that page can already load in it.
    const settings = RendererSettings.store.plugins?.GoLiveFix;
    if (settings?.enabled && settings.enterOnStartup)
        wg.startTunnel().catch(e => log(`erro: ${errorMessage(e)}`));
}

app.on("web-contents-created", (_, wc) => {
    wc.on("did-start-navigation", (_e, url, isInPlace, isMainFrame) => {
        if (isMainFrame && !isInPlace && isMainPage(url)) armForPageLoad(wc);
    });
});

// Discord's main page; its popouts (and overlay) share the state but aren't it.
function isMainPage(url: string): boolean {
    try {
        const u = new URL(url);
        return u.protocol === "https:" && !/^\/(popout|overlay)\b/.test(u.pathname);
    } catch {
        return false;
    }
}

function armForPageLoad(wc: WebContents) {
    const settings = RendererSettings.store.plugins?.GoLiveFix;
    if (!settings?.enabled || !settings.enterOnStartup || relaunching) return;
    // Armed already, by the user (held) or an entry that reloads the page.
    if (wg.available && wg.mode() === "arm") return;
    let confirmed: false | Promise<void>;
    try {
        confirmed = wg.armNow();
    } catch (e) {
        log(`não entrou no túnel ao carregar: ${errorMessage(e)}`);
        return;
    }
    if (!confirmed) return;
    held = false;
    // The previous page's idle connections (API, CDN) went direct; close them
    // so the new page opens its own.
    wc.session.closeAllConnections();
    log("carregando o Discord: túnel ligado");
    confirmed.catch(e => log(`túnel desligado de novo: ${errorMessage(e)}`));
}

// --- exported native functions (callable from the renderer) --------------

/**
 * Send every new connection through the tunnel. Outside the tunnel this
 * brings Discord into it (see enter()), armed until the usual automatic
 * release. Inside it, the tunnel is just turned on and held until disarm()
 * or a manual release().
 */
export const prepare = serial(async (_: IpcMainInvokeEvent): Promise<EnterResult> => {
    if (relaunching) return { ok: true, relaunching: true };
    try {
        if (!wg.available) return await enter(_.sender, "entrando no túnel");
        await wg.set("arm");
        held = true;
        log("túnel ligado até você desligar");
        return { ok: true };
    } catch (e) {
        log(`erro: ${errorMessage(e)}`);
        return { ok: false, error: errorMessage(e) };
    }
});

// Stamped (ms) on the env of a Discord relaunched into the tunnel on startup.
// If the relaunched one still comes up outside it, it sees a recent stamp and
// doesn't try again, so a broken setup can't restart Discord in a loop.
const AUTO_ENTER_ENV = "GOLIVEFIX_AUTO_ENTERED";
const AUTO_ENTER_RETRY_MS = 2 * 60_000;
// Once per main process: renderer reloads (Ctrl+R) call it again.
let autoEnterTried = false;

/**
 * The "enter on startup" option: like the first "Ligar" from outside the
 * tunnel, but only once per Discord start and never in a loop.
 */
export const enterOnStartup = serial(async (_: IpcMainInvokeEvent): Promise<EnterResult> => {
    if (wg.available || relaunching || autoEnterTried) return { ok: true };
    autoEnterTried = true;
    const last = Number(process.env[AUTO_ENTER_ENV]);
    if (last && Date.now() - last < AUTO_ENTER_RETRY_MS)
        return { ok: false, error: "o Discord reiniciou mas não entrou no túnel; ligue pelo escudo para ver o motivo" };
    process.env[AUTO_ENTER_ENV] = String(Date.now());
    try {
        return await enter(_.sender, "entrando no túnel ao abrir o Discord");
    } catch (e) {
        delete process.env[AUTO_ENTER_ENV];
        log(`erro: ${errorMessage(e)}`);
        return { ok: false, error: errorMessage(e) };
    }
});

/**
 * Start Discord's session over with the tunnel on from the first connection,
 * in or out of the tunnel (see enter()). The new session starts armed and not
 * held, so it gets the usual post-restart release.
 */
export const restart = serial(async (_: IpcMainInvokeEvent): Promise<EnterResult> => {
    if (relaunching) return { ok: true, relaunching: true };
    try {
        return await enter(_.sender, "túnel ligado desde o início");
    } catch (e) {
        log(`erro: ${errorMessage(e)}`);
        return { ok: false, error: errorMessage(e) };
    }
});

/** Arm without the restart fallback: used right before a stream starts. */
export const arm = serial(async (_: IpcMainInvokeEvent): Promise<{ ok: boolean; error?: string }> => {
    try {
        if (wg.mode() === "arm") return { ok: true };
        await wg.set("arm");
        log("túnel ligado para a stream");
        return { ok: true };
    } catch (e) {
        log(`erro: ${errorMessage(e)}`);
        return { ok: false, error: errorMessage(e) };
    }
});

/**
 * Teardown after the region-gated step is done. Only acts while armed, so
 * repeated triggers (stream start, boot timer) are harmless, and automatic
 * ones skip a tunnel the user turned on (manual releases clear that). TCP
 * opened through the tunnel, like the gateway, stays in it either way;
 * keepUdp also keeps voice/stream media there.
 */
export const release = serial(async (_: IpcMainInvokeEvent, opts?: { keepUdp?: boolean; manual?: boolean; }): Promise<{ ok: boolean; mode: WgMode | null; held?: boolean; error?: string }> => {
    if (held && !opts?.manual) return { ok: true, mode: wg.mode(), held: true };
    held = false;
    if (wg.mode() !== "arm") return { ok: true, mode: wg.mode() };
    const mode: WgMode = opts?.keepUdp ? "keep" : "disarm";
    try {
        await wg.set(mode);
        log(mode === "keep" ? "túnel solto (voz e stream novas ainda pelo túnel)" : "túnel solto");
        return { ok: true, mode };
    } catch (e) {
        log(`erro: ${errorMessage(e)}`);
        return { ok: false, mode: wg.mode(), error: errorMessage(e) };
    }
});

/** Manual stop: everything new goes direct, whatever the current mode. */
export const disarm = serial(async (_: IpcMainInvokeEvent): Promise<{ ok: boolean; error?: string }> => {
    held = false;
    if (!wg.available) return { ok: true };
    try {
        await wg.set("disarm");
        log("túnel desligado");
        return { ok: true };
    } catch (e) {
        log(`erro: ${errorMessage(e)}`);
        return { ok: false, error: errorMessage(e) };
    }
});

export function getStatus(_: IpcMainInvokeEvent): { inTunnel: boolean; mode: WgMode | null; held: boolean; logs: string[]; } {
    return { inTunnel: wg.available, mode: wg.mode(), held, logs: recentLogs.slice(-20) };
}
