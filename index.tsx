/*
 * GoLiveFix — renderer side (Vencord plugin entry).
 *
 * Install: copy this folder into Vencord/src/userplugins/ and rebuild (pnpm build).
 */

import { showNotification } from "@api/Notifications";
import { definePluginSettings } from "@api/Settings";
import ErrorBoundary from "@components/ErrorBoundary";
import { Flex } from "@components/Flex";
import { Heading } from "@components/Heading";
import { Paragraph } from "@components/Paragraph";
import { IS_LINUX } from "@utils/constants";
import definePlugin, { OptionType, type PluginNative } from "@utils/types";
import { Button, ContextMenuApi, FluxDispatcher, MediaEngineStore, Menu, React, Tooltip, UserStore } from "@webpack/common";

import managedStyle from "./style.css?managed";

const Native = VencordNative.pluginHelpers.GoLiveFix as PluginNative<typeof import("./native")>;

type Status = Awaited<ReturnType<typeof Native.getStatus>>;

const settings = definePluginSettings({
    panelButton: {
        type: OptionType.BOOLEAN,
        description: "Mostrar o escudo ao lado do microfone",
        default: true
    },
    enterOnStartup: {
        type: OptionType.BOOLEAN,
        description: "Entrar no túnel ao abrir o Discord",
        default: false
    },
    autoTeardown: {
        type: OptionType.BOOLEAN,
        description: "Soltar o túnel quando a stream começar",
        default: true
    },
    teardownDelayMs: {
        type: OptionType.NUMBER,
        description: "Espera para soltar após a stream começar (ms)",
        default: 4000
    },
    releaseAfterRelaunchMs: {
        type: OptionType.NUMBER,
        description: "Soltar após entrar no túnel (ms, 0 = só na stream)",
        default: 5000
    },
    keepMediaInTunnel: {
        type: OptionType.BOOLEAN,
        description: "Manter voz e stream no túnel ao soltar",
        default: false
    },
    controls: {
        type: OptionType.COMPONENT,
        description: "",
        component: () => <ControlPanel />
    }
});

let releaseTimer: ReturnType<typeof setTimeout> | undefined;

function notify(title: string, body: string) {
    showNotification({ title: `GoLiveFix — ${title}`, body });
}

const errorText = (res: { error?: string; }) => res.error ?? "erro desconhecido";

// User actions run one at a time, in click order, each starting from the
// state the previous one left: fast clicks alternate instead of repeating an
// action off a stale status or being dropped. Nothing runs once Discord is
// restarting.
let actions: Promise<unknown> = Promise.resolve();
let relaunching = false;

function enqueue(action: () => Promise<unknown>): Promise<unknown> {
    const run = actions.then(() => relaunching ? undefined : action());
    actions = run.catch(() => { });
    return run;
}

/**
 * Follow up on entering the tunnel (see native enter()): a relaunch happens
 * on its own; an in-place entry needs this UI reloaded so everything
 * reconnects through the tunnel. Either way the new session starts armed.
 * False when there's nothing to follow up on.
 */
function followEntry(res: { relaunching?: boolean; reloading?: boolean; }): boolean {
    if (!res.reloading && !res.relaunching) return false;
    relaunching = true;
    if (res.reloading) location.reload();
    return true;
}

// Only errors are notified; the shield and the status show the rest.
async function prepare() {
    const res = await Native.prepare();
    if (!res.ok) { notify("falhou", errorText(res)); return; }
    if (followEntry(res)) return;
    clearTimeout(releaseTimer);
}

async function restart() {
    const res = await Native.restart();
    if (!res.ok) notify("falhou", errorText(res));
    else followEntry(res);
}

/**
 * Leave the tunnel for new connections; no-op unless armed. Automatic calls
 * (stream start, post-restart timer) skip a tunnel the user turned on.
 */
async function release(manual = false) {
    clearTimeout(releaseTimer);
    const res = await Native.release({ keepUdp: settings.store.keepMediaInTunnel, manual });
    if (!res.ok) notify("falhou ao soltar", errorText(res));
}

async function disarm() {
    clearTimeout(releaseTimer);
    const res = await Native.disarm();
    if (!res.ok) notify("falhou", errorText(res));
}

function isOwnStream(e: any): boolean {
    const me = UserStore.getCurrentUser()?.id;
    if (!me) return true; // can't tell → assume it's the user's
    const key: string = e?.streamKey ?? "";
    return key.endsWith(`:${me}`) || !key;
}

// Known once at start; a process never moves in or out of the tunnel.
let inTunnel = false;
const DEFERRED = Symbol("golivefix.deferred");
// Release anyway if the stream never reports STREAM_CREATE (e.g. it failed).
const STREAM_RELEASE_FALLBACK_MS = 30_000;

/** Resolves once the tunnel is armed for the stream being started/watched. */
let armForStream: Promise<void> | null = null;
let armSettled = true;
const watchedKeys = new Set<string>();

function armBeforeStream() {
    clearTimeout(releaseTimer);
    armSettled = false;
    armForStream = Native.arm().then(res => {
        if (!res.ok) notify("falhou ao ligar para a stream", errorText(res));
    }).finally(() => { armSettled = true; });
    releaseTimer = setTimeout(() => release(), STREAM_RELEASE_FALLBACK_MS);
}

/**
 * Flux interceptor. Starting or watching a stream arms the tunnel right away
 * (without holding those actions, so Discord's follow-up calls keep their
 * order). The stream's RTC connections only open on STREAM_SERVER_UPDATE,
 * after a gateway round trip; that one is held in the rare case the tunnel
 * isn't armed yet, then dispatched again.
 */
function interceptStreams(action: any): boolean {
    if (!inTunnel) return false;
    switch (action.type) {
        case "STREAM_START":
            armBeforeStream();
            return false;
        case "STREAM_WATCH":
            if (action.streamKey) watchedKeys.add(action.streamKey);
            armBeforeStream();
            return false;
        case "STREAM_SERVER_UPDATE":
            if (armSettled || action[DEFERRED] || !armForStream) return false;
            armForStream.then(() => FluxDispatcher.dispatch({ ...action, [DEFERRED]: true }));
            return true; // blocks this dispatch until the tunnel is armed
    }
    return false;
}

function removeInterceptor() {
    const list: ((action: any) => boolean)[] | undefined = (FluxDispatcher as any)._interceptors;
    const i = list?.indexOf(interceptStreams) ?? -1;
    if (i >= 0) list!.splice(i, 1);
}

/** Once the user's own or a watched stream is up, release the tunnel after the delay. */
function onStreamCreate(e: any) {
    const watched = watchedKeys.delete(e?.streamKey);
    if (!settings.store.autoTeardown || !(watched || isOwnStream(e))) return;
    clearTimeout(releaseTimer);
    releaseTimer = setTimeout(() => release(), settings.store.teardownDelayMs ?? 4000);
}

function describe(status: Status | null): string {
    if (!status) return "Carregando…";
    if (!status.inTunnel) return "Fora do túnel";
    if (status.mode === "arm") return status.held ? "Ligado" : "Ligado (solta sozinho)";
    return status.mode === "keep" ? "Solto (voz e stream no túnel)" : "Desligado";
}

function useStatus(intervalMs: number): [Status | null, () => void] {
    const [status, setStatus] = React.useState<Status | null>(null);
    const alive = React.useRef(true);
    const refresh = React.useCallback(async () => {
        const s = await Native.getStatus();
        if (alive.current) setStatus(s);
    }, []);
    React.useEffect(() => {
        alive.current = true;
        refresh();
        const id = setInterval(refresh, intervalMs);
        return () => { alive.current = false; clearInterval(id); };
    }, []);
    return [status, refresh];
}

const isOn = (status: Status | null) => !!status?.inTunnel && status.mode === "arm";

/** Decides from a fresh status, not the polled one the button was drawn with. */
function toggle() {
    return enqueue(async () => isOn(await Native.getStatus()) ? disarm() : prepare());
}

const openH264Enabled = (): boolean => !!(MediaEngineStore as any).getOpenH264Enabled?.();

function setOpenH264(enabled: boolean) {
    FluxDispatcher.dispatch({ type: "MEDIA_ENGINE_SET_OPENH264_ENABLED", enabled });
}

function openTunnelMenu(event: React.MouseEvent, status: Status | null, refresh: () => void) {
    const after = (p: Promise<unknown>) => p.finally(refresh);
    const h264 = openH264Enabled();
    ContextMenuApi.openContextMenu(event, () => (
        <Menu.Menu navId="vc-golivefix-tunnel" onClose={ContextMenuApi.closeContextMenu} aria-label="Túnel">
            <Menu.MenuItem
                id="vc-golivefix-toggle"
                label={isOn(status) ? "Desligar túnel" : "Ligar túnel"}
                action={() => after(toggle())}
            />
            <Menu.MenuItem
                id="vc-golivefix-restart"
                label="Reiniciar no túnel"
                action={() => after(enqueue(restart))}
            />
            {/* The OpenH264 glitches are a Linux decoder issue (see README). */}
            {IS_LINUX && <Menu.MenuSeparator />}
            {IS_LINUX && (
                <Menu.MenuCheckboxItem
                    id="vc-golivefix-openh264"
                    label="Decodificador OpenH264"
                    checked={h264}
                    action={() => setOpenH264(!h264)}
                />
            )}
        </Menu.Menu>
    ));
}

function TunnelIcon() {
    return (
        <svg width="20" height="20" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
            <path d="M12 2 4 5v6c0 5 3.4 9.7 8 11 4.6-1.3 8-6 8-11V5l-8-3Zm0 2.2 6 2.25V11c0 3.9-2.5 7.6-6 8.9-3.5-1.3-6-5-6-8.9V6.45l6-2.25Zm-1 4.3v7l5.5-3.5L11 8.5Z" />
        </svg>
    );
}

/** On/off toggle left of the mute/deafen buttons; right click for more. */
/** The shield, unless turned off in the settings (applies without a reload). */
function PanelButtonSlot() {
    const { panelButton } = settings.use(["panelButton"]);
    return panelButton ? <PanelButton /> : null;
}

const PanelButton = ErrorBoundary.wrap(() => {
    const [status, refresh] = useStatus(2000);
    const mode = status?.inTunnel ? status.mode : null;
    const label = isOn(status) ? "Desligar túnel" : "Ligar túnel";
    return (
        <Tooltip text={`${label} (${describe(status).toLowerCase()})`}>
            {tooltipProps => (
                <button
                    {...tooltipProps}
                    className={"vc-golivefix-panel-button" + (mode ? ` vc-golivefix-${mode}` : "")}
                    aria-label={label}
                    onClick={() => toggle().finally(refresh)}
                    onContextMenu={e => openTunnelMenu(e, status, refresh)}
                >
                    <TunnelIcon />
                </button>
            )}
        </Tooltip>
    );
}, { noop: true });

function ControlPanel() {
    const [status, refresh] = useStatus(1500);
    const { panelButton } = settings.use(["panelButton"]);
    const after = (p: Promise<unknown>) => p.finally(refresh);

    return (
        <section>
            <Heading tag="h3">Controle</Heading>
            {panelButton && (
                <Paragraph style={{ marginBottom: 12 }}>
                    Também pelo escudo ao lado do microfone (clique direito: mais opções).
                </Paragraph>
            )}

            <Paragraph style={{ marginBottom: 12, opacity: 0.8 }}>
                Estado: {describe(status)}
            </Paragraph>

            <Flex gap="8px" flexWrap="wrap">
                <Button color={Button.Colors.BRAND} onClick={() => after(enqueue(prepare))}>
                    Ligar túnel
                </Button>
                <Button color={Button.Colors.PRIMARY} onClick={() => after(enqueue(() => release(true)))}>
                    Soltar túnel
                </Button>
                <Button color={Button.Colors.RED} onClick={() => after(enqueue(disarm))}>
                    Desligar túnel
                </Button>
                <Button color={Button.Colors.PRIMARY} onClick={() => after(enqueue(restart))}>
                    Reiniciar no túnel
                </Button>
            </Flex>

            {status?.logs?.length ? (
                <pre style={{ marginTop: 12, maxHeight: 140, overflow: "auto", fontSize: 11, opacity: 0.7 }}>
                    {status.logs.join("\n")}
                </pre>
            ) : null}
        </section>
    );
}

export default definePlugin({
    name: "GoLiveFix",
    description: "Passa o Discord por um túnel WireGuard para transmitir e assistir streams",
    authors: [{ name: "poc", id: 0n }],
    settings,
    managedStyle,

    patches: [
        {
            // Account panel: first child of the mute/deafen/settings row.
            find: "handleOpenSettingsContextMenu=",
            replacement: {
                match: /children:\[(?=\(0,\i\.jsx\)\(\i,\{accountContainerRef:\i,selfMute:)/,
                replace: "$&$self.PanelButton(),"
            }
        }
    ],

    PanelButton: () => <PanelButtonSlot />,

    async start() {
        FluxDispatcher.subscribe("STREAM_CREATE", onStreamCreate);
        (FluxDispatcher as any).addInterceptor(interceptStreams);
        // Booting armed (and not held by the user) means a restart into the
        // tunnel: release once the gateway has had time to connect.
        const status = await Native.getStatus();
        inTunnel = status.inTunnel;
        if (!inTunnel && settings.store.enterOnStartup) {
            const res = await Native.enterOnStartup();
            if (!res.ok) notify("não entrou no túnel", errorText(res));
            else followEntry(res);
            return;
        }
        const ms = settings.store.releaseAfterRelaunchMs ?? 0;
        if (status.mode === "arm" && !status.held && ms > 0) releaseTimer = setTimeout(() => release(), ms);
    },

    stop() {
        FluxDispatcher.unsubscribe("STREAM_CREATE", onStreamCreate);
        removeInterceptor();
        clearTimeout(releaseTimer);
        // Disabling the plugin shouldn't leave Discord stuck in the tunnel.
        Native.disarm();
    }
});
