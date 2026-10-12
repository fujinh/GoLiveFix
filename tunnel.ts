/*
 * Tunnel backends (Electron MAIN process).
 *
 * A backend steers Discord's new connections — voice/Go Live UDP included —
 * between the direct uplink and a WireGuard tunnel, in one of three modes:
 *
 *   arm     every new connection goes through WireGuard
 *   keep    UDP (voice/Go Live) stays on WireGuard, new TCP goes direct
 *   disarm  everything new goes direct
 *
 * Switching modes never moves a connection that is already open.
 * How that's done is up to each platform (tunnel-linux.ts: network namespace).
 */

import { LinuxTunnel } from "./tunnel-linux";
import { WindowsTunnel } from "./tunnel-windows";

export type WgMode = "arm" | "keep" | "disarm";

export interface TunnelBackend {
    /** Can this Discord's routing be steered right now? */
    readonly available: boolean;

    /** The current mode, or null when not available. */
    mode(): WgMode | null;

    /** Apply a mode and wait until it's in effect. Throws when not available. */
    set(mode: WgMode): Promise<void>;

    /**
     * Restart Discord so that the new instance can be steered, starting armed
     * if `arm`. Fails with Discord still open if the platform's requirements
     * are missing; otherwise Discord exits shortly after this resolves.
     */
    relaunchIntoTunnel(baseDir: string, arm: boolean): Promise<void>;

    /**
     * Arm and bring this running Discord into the tunnel without restarting
     * it; the caller then reloads the UI so it reconnects. False when only
     * relaunchIntoTunnel() can (nothing was changed then).
     */
    enterInPlace(): Promise<boolean>;

    /**
     * Arm right away, for a page that is starting to load and can't be held
     * back: by the time this returns, the mode is in effect (Windows) or in
     * the supervisor's hands (Linux), ahead of the page's connections. Only
     * when this Discord can be steered without a restart, entering in place
     * if needed; false otherwise, with nothing changed. Throws if it can't
     * arm. The promise settles once the arm is confirmed, or rejects once
     * it's been undone (say, the tunnel can't reach the internet).
     */
    armNow(): false | Promise<void>;
}

class UnsupportedTunnel implements TunnelBackend {
    readonly available = false;

    mode(): WgMode | null {
        return null;
    }

    async set(): Promise<void> {
        throw new Error(`túnel não suportado neste sistema (${process.platform})`);
    }

    async relaunchIntoTunnel(): Promise<void> {
        throw new Error(`túnel não suportado neste sistema (${process.platform})`);
    }

    async enterInPlace(): Promise<boolean> {
        return false;
    }

    armNow(): false {
        return false;
    }
}

export function createTunnelBackend(): TunnelBackend {
    switch (process.platform) {
        case "linux": return new LinuxTunnel();
        case "win32": return new WindowsTunnel();
        default: return new UnsupportedTunnel();
    }
}
