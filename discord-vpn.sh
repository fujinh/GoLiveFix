#!/usr/bin/env bash
#
# discord-vpn.sh — run Discord inside a rootless network namespace that has a
# WireGuard tunnel next to its normal (direct) uplink, so the plugin can steer
# Discord's traffic — voice/Go Live UDP included — between the two at runtime.
# Doing it at the namespace level is what catches the native voice engine,
# which ignores Chromium's proxy settings.
#
#   host netns ── pasta (user-mode uplink, no root, no host firewall changes)
#        └── Discord's netns: tap0 (direct) + wg0 (WireGuard, e.g. Proton free)
#
# Routing inside the namespace (policy rules, IPv4 only):
#     90  fwmark 51820        → main   wg0's own encrypted packets go direct
#     95  to <wg endpoint>    → main   …and so do replies, as far as the strict
#                                      reverse-path filter is concerned
#    100  from <wg address>   → vpn    sockets opened on wg0 stay on wg0…
#    101  from <tap address>  → main   …and sockets opened direct stay direct
#    110  to <dns>            → vpn
#    150  udp flow pins       → vpn    unconnected UDP sockets (voice/stream
#    151  udp flow pins       → main   media) pick a route per packet; at each
#                                      mode switch, every UDP flow seen in the
#                                      last 2 min is pinned (dst + local port)
#                                      to the path it started on, so a switch
#                                      never moves live media mid-session
#    200  all                 → vpn    mode "arm":  new connections use wg0
#    210  ipproto udp         → vpn    mode "keep": UDP (voice/stream) stays on
#                                      wg0, new TCP goes direct
#   (none)                    → main   mode "disarm": everything new is direct
#
# The plugin switches modes by writing arm/keep/disarm to $DCVPN_CTL (a FIFO)
# and reads the current one from $DCVPN_STATE.
#
# Usage: discord-vpn.sh [--check] [--arm] [--wait-pid PID] [-- discord args…]
#   --check         only verify requirements, launch nothing
#   --arm           start in "arm" mode, so Discord's very first connections
#                   already use the tunnel
#   --wait-pid PID  wait for that Discord to exit first (the plugin uses this
#                   to restart Discord into the namespace)
# The Discord command is $DCVPN_DISCORD (default: discord) plus any args.
# If the tunnel can't be set up, Discord is started normally instead.
#
# Requirements: passt (pasta), wireguard-tools, the wireguard kernel module
# loaded, and a WireGuard config (e.g. from account.protonvpn.com) at
# ~/.config/discord-vpn/wg.conf (override with DCVPN_CONF).

set -euo pipefail

CONF=${DCVPN_CONF:-$HOME/.config/discord-vpn/wg.conf}
DISCORD=${DCVPN_DISCORD:-discord}
RUNDIR=${DCVPN_RUNDIR:-${XDG_RUNTIME_DIR:-/tmp}/discord-vpn}
TABLE=51820

die() { echo "discord-vpn: $*" >&2; exit 1; }
log() { echo "discord-vpn: $*" >&2; }

# ---- stage 0: host side --------------------------------------------------

check() {
    command -v pasta >/dev/null || die "pasta não encontrado (sudo pacman -S passt)"
    command -v wg >/dev/null || die "wg não encontrado (sudo pacman -S wireguard-tools)"
    [[ -d /sys/module/wireguard ]] || die "módulo wireguard não carregado (sudo modprobe wireguard)"
    [[ -r $CONF ]] || die "config WireGuard não encontrada em $CONF"
    [[ -n $(conf_value Address) ]] || die "nenhum Address IPv4 em $CONF"
}

stage0() {
    local only_check=0 wait_pid=""
    export DCVPN_INITIAL_MODE=disarm
    while (($#)); do
        case $1 in
            --check) only_check=1 ;;
            --arm) DCVPN_INITIAL_MODE=arm ;;
            --wait-pid) wait_pid=$2; shift ;;
            --) shift; break ;;
            *) break ;;
        esac
        shift
    done

    check
    ((only_check)) && { log "ok"; return; }

    if [[ -n $wait_pid ]]; then
        while kill -0 "$wait_pid" 2>/dev/null; do sleep 0.2; done
        # Helpers (zygote, GPU…) linger a moment after the main process.
        for _ in {1..50}; do pgrep -x Discord >/dev/null || break; sleep 0.2; done
    fi
    pgrep -x Discord >/dev/null && die "feche o Discord antes (inclusive da bandeja)"

    mkdir -p "$RUNDIR" && chmod 700 "$RUNDIR"
    rm -f "$RUNDIR/ctl" "$RUNDIR/state" "$RUNDIR/started"
    mkfifo -m 600 "$RUNDIR/ctl"

    export DCVPN_UID=${DCVPN_UID:-$(id -u)} DCVPN_GID=${DCVPN_GID:-$(id -g)}
    export DCVPN_CONF=$CONF DCVPN_RUNDIR=$RUNDIR

    # -4: no IPv6 inside, so nothing can sidestep the IPv4-only rules.
    # No port forwarding in either direction.
    local rc=0
    pasta --config-net -4 --quiet --foreground \
        -t none -u none -T none -U none \
        -- "$0" __stage1 "$@" || rc=$?

    # Never leave the user without Discord: if the namespace failed before
    # Discord was started in it, start it normally.
    if [[ ! -e $RUNDIR/started ]]; then
        log "túnel falhou (código $rc); abrindo o Discord sem ele"
        rm -f "$RUNDIR/ctl"
        DCVPN_CTL= DCVPN_STATE= "$DISCORD" "$@" &
        disown
    fi
    rm -f "$RUNDIR/started"
}

# ---- stage 1: root of the new user namespace, inside the new netns -------

conf_value() { # first IPv4 value of `Key = a, b` in the [Interface] section
    sed -n "/^\[Interface\]/,/^\[/{s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p}" "$CONF" \
        | tr ',' '\n' | tr -d ' \t\r' | grep -m1 -E '^[0-9]+(\.[0-9]+){3}' || true
}

stage1() {
    [[ $(id -u) == 0 ]] || die "o script devia ser root no user namespace do pasta"

    local addr dns mtu
    addr=$(conf_value Address)
    [[ -n $addr ]] || die "nenhum Address IPv4 em $CONF"
    [[ $addr == */* ]] || addr+=/32
    dns=$(conf_value DNS); dns=${dns:-1.1.1.1}
    mtu=$(conf_value MTU); mtu=${mtu:-1420}

    ip link add wg0 type wireguard
    wg setconf wg0 <(wg-quick strip "$CONF")
    wg set wg0 fwmark $TABLE
    ip address add "$addr" dev wg0
    ip link set wg0 mtu "$mtu" up
    ip route add default dev wg0 table $TABLE

    ip rule add pref 90 fwmark $TABLE lookup main
    # Without this, rp_filter=1 checks the endpoint's incoming packets against
    # the "everything → wg0" rule and drops them, killing the tunnel on arm.
    local endpoint
    endpoint=$(wg show wg0 endpoints | awk '{print $2}' | head -1)
    endpoint=${endpoint%:*}
    [[ -n $endpoint ]] || die "config sem Endpoint"
    ip rule add pref 95 to "$endpoint" lookup main
    local direct
    direct=$(ip -4 -o address show scope global | awk '$2 != "wg0" {sub("/.*", "", $4); print $4; exit}')
    [[ -n $direct ]] || die "sem endereço IPv4 na interface do pasta"
    ip rule add pref 100 from "${addr%/*}" lookup $TABLE
    ip rule add pref 101 from "$direct" lookup main
    ip rule add pref 110 to "$dns" lookup $TABLE

    # Remember which UDP flows (destination + local port) currently go where;
    # set_mode turns these into pins. wg0's own encrypted packets carry the
    # fwmark and are left out.
    nft -f - <<EOF || die "nftables indisponível no namespace"
table ip dcvpn {
    set udp_vpn { type ipv4_addr . inet_service; flags dynamic,timeout; timeout 2m; }
    set udp_direct { type ipv4_addr . inet_service; flags dynamic,timeout; timeout 2m; }
    chain track {
        type filter hook postrouting priority filter;
        meta l4proto udp meta mark != $TABLE oifname "wg0" update @udp_vpn { ip daddr . udp sport }
        meta l4proto udp meta mark != $TABLE oifname != { "wg0", "lo" } update @udp_direct { ip daddr . udp sport }
    }
}
EOF

    # Anything that still leaves via wg0 with the tap address gets the tunnel
    # address instead of being dropped.
    nft -f - <<EOF 2>/dev/null || log "aviso: masquerade no wg0 indisponível (nf_nat?); seguindo sem"
table ip dcvpn_nat {
    chain post {
        type nat hook postrouting priority srcnat;
        oifname "wg0" masquerade
    }
}
EOF

    # Kick off a handshake so a dead config fails here, not inside Discord.
    ping -c1 -W5 -I wg0 "$dns" >/dev/null 2>&1 || ping -c1 -W5 -I wg0 1.1.1.1 >/dev/null 2>&1 || true
    local hs
    hs=$(wg show wg0 latest-handshakes | awk '{print $2}')
    if [[ ${hs:-0} == 0 ]]; then
        log "aviso: sem handshake WireGuard ainda — confira o config/endpoint"
    else
        log "WireGuard ok (endpoint $(wg show wg0 endpoints | awk '{print $2}'))"
    fi

    printf 'nameserver %s\n' "$dns" > "$RUNDIR/resolv.conf"
    exec unshare --mount --propagation private -- "$0" __stage2 "$@"
}

# ---- stage 2: private mount namespace; supervises Discord ----------------

# "addr.port" for each flow currently in one of the tracking sets.
flows() {
    nft list set ip dcvpn "$1" 2>/dev/null \
        | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3} \. [0-9]+' | tr -d ' '
}

pin_flows() {
    while ip rule del pref 150 2>/dev/null; do :; done
    while ip rule del pref 151 2>/dev/null; do :; done
    local f n=0
    for f in $(flows udp_vpn); do
        ip rule add pref 150 to "${f%.*}" ipproto udp sport "${f##*.}" lookup $TABLE && n=$((n + 1))
    done
    for f in $(flows udp_direct); do
        ip rule add pref 151 to "${f%.*}" ipproto udp sport "${f##*.}" lookup main && n=$((n + 1))
    done
    ((n)) && log "$n fluxo(s) UDP mantido(s) no caminho em que começaram"
    return 0
}

set_mode() {
    local cur
    cur=$(cat "$RUNDIR/state" 2>/dev/null || echo disarm)
    # "keep" is the auto-teardown step; it only makes sense from "arm".
    [[ $1 == keep && $cur != arm ]] && return

    # Pin live UDP first, then add the new rule before removing the old one,
    # so no flow ever changes path.
    pin_flows
    case $1 in
        arm)  ip rule add pref 200 lookup $TABLE 2>/dev/null || true ;;
        keep) ip rule add pref 210 ipproto udp lookup $TABLE 2>/dev/null || true ;;
    esac
    [[ $1 != arm ]] && { ip rule del pref 200 2>/dev/null || true; }
    [[ $1 != keep ]] && { ip rule del pref 210 2>/dev/null || true; }

    printf '%s\n' "$1" > "$RUNDIR/state.tmp" && mv "$RUNDIR/state.tmp" "$RUNDIR/state"
    log "modo: $1"
}

ctl_loop() {
    local cmd
    while :; do
        while read -r cmd; do
            case $cmd in arm|keep|disarm) set_mode "$cmd" ;; esac
        done < "$RUNDIR/ctl"
    done
}

# Is anything besides this supervisor still living in the netns? Discord's
# own relaunch (updates, Vencord restarts) re-parents the new instance, so
# waiting on the first pid isn't enough.
others_alive() {
    local p n comm
    for p in /proc/[0-9]*; do
        n=${p#/proc/}
        [[ $n == "$$" || $n == "$CTL_PID" ]] && continue
        [[ $p/ns/net -ef /proc/self/ns/net ]] || continue
        read -r comm < "$p/comm" 2>/dev/null || continue
        [[ $comm == sleep || $comm == ip ]] && continue
        return 0
    done
    return 1
}

stage2() {
    # Chromium may read resolv.conf itself; the host's 127.0.0.53 stub isn't
    # reachable from here. (glibc's nss-resolve still asks the host daemon.)
    mount --bind "$RUNDIR/resolv.conf" /etc/resolv.conf

    # Applied before Discord starts, so with --arm its first connections
    # already go through the tunnel.
    set_mode "${DCVPN_INITIAL_MODE:-disarm}"
    ctl_loop &
    CTL_PID=$!

    # Run Discord as the real user in a nested user namespace: it keeps the
    # network, but has no capabilities over it, so only the FIFO can change
    # routing.
    touch "$RUNDIR/started"
    DCVPN_CTL=$RUNDIR/ctl DCVPN_STATE=$RUNDIR/state \
        unshare --user --map-user="$DCVPN_UID" --map-group="$DCVPN_GID" -- "$DISCORD" "$@" &

    sleep 5
    while others_alive; do sleep 2; done

    kill "$CTL_PID" 2>/dev/null || true
    rm -f "$RUNDIR/ctl" "$RUNDIR/state" "$RUNDIR/state.tmp" "$RUNDIR/resolv.conf"
    log "Discord encerrado; namespace desfeito"
}

case ${1:-} in
    __stage1) shift; stage1 "$@" ;;
    __stage2) shift; stage2 "$@" ;;
    *) stage0 "$@" ;;
esac
