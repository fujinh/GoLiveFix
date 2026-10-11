#!/usr/bin/env bash
#
# Instala o GoLiveFix no Linux do zero (Arch, ou Debian/Ubuntu e derivados):
#
#   1. acha o Discord já instalado (ou usa o caminho de --discord);
#   2. instala os pacotes (passt, wireguard-tools, nftables, git, Node.js, pnpm)
#      e carrega o módulo wireguard;
#   3. coloca o seu .conf do WireGuard em ~/.config/discord-vpn/wg.conf e
#      confere os requisitos do discord-vpn.sh;
#   4. baixa e compila o Vencord com o plugin, injeta no Discord, ativa o
#      plugin e abre o Discord.
#
# Rode como o seu usuário (não como root): o sudo é pedido só para instalar
# pacotes, carregar o módulo e injetar o Vencord num Discord em pasta do
# sistema (/opt, /usr). Rodar de novo é seguro: o que já está feito é pulado,
# e o plugin é copiado e compilado de novo (serve para atualizar).
#
# Uso: bash setup-linux.sh [opções]
#   --conf ARQUIVO       o .conf do WireGuard (sem ele: mantém o atual ou pergunta)
#   --discord CAMINHO    a pasta do Discord (a que tem resources/), o executável,
#                        ~/.config/discord ou a pasta do instalador do Discord
#   --branch RAMO        qual Discord procurar sem --discord: stable (padrão), ptb ou canary
#   --vencord-dir PASTA  onde fica o Vencord (padrão: ./Vencord, ignorada pelo git)
#   --enter-on-startup   liga a opção "Entrar no túnel ao abrir o Discord"
#   --skip-vencord       só pacotes e túnel

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CONF=""
DISCORD_ARG=""
VENCORD_DIR="$SCRIPT_DIR/Vencord"
BRANCH=stable
ENTER_ON_STARTUP=0
SKIP_VENCORD=0

WG_CONF="$HOME/.config/discord-vpn/wg.conf"
# Node.js and pnpm the script installs itself, when the system's won't do.
TOOLS="${XDG_DATA_HOME:-$HOME/.local/share}/golivefix"
# Vencord's package.json requires it.
NODE_MIN=22

step() { printf '\n\033[36m==> %s\033[0m\n' "$*"; }
ok() { printf '    \033[32m%s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '    \033[33m%s\033[0m\n' "$*"; }
die() { printf '\n\033[31mERRO: %s\033[0m\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

ask() {
    local a
    [[ -t 0 ]] || return 1
    read -rp "    $1 [S/n] " a
    [[ -z $a || $a =~ ^[sSyY] ]]
}

while (($#)); do
    case $1 in
        --conf) CONF=${2:?--conf precisa de um arquivo}; shift ;;
        --discord) DISCORD_ARG=${2:?--discord precisa de um caminho}; shift ;;
        --vencord-dir) VENCORD_DIR=${2:?--vencord-dir precisa de uma pasta}; shift ;;
        --branch) BRANCH=${2:?--branch precisa de stable, ptb ou canary}; shift ;;
        --enter-on-startup) ENTER_ON_STARTUP=1 ;;
        --skip-vencord) SKIP_VENCORD=1 ;;
        -h|--help) sed -n '3,/^$/s/^# \{0,1\}//p' "$0"; exit 0 ;;
        *) die "opção desconhecida: $1 (veja --help)" ;;
    esac
    shift
done

# The command packages put in PATH, and the executable's name (also the
# process name and the folder name of the official tarball).
case $BRANCH in
    stable) DISCORD_CMD=discord; DISCORD_NAME=Discord ;;
    ptb) DISCORD_CMD=discord-ptb; DISCORD_NAME=DiscordPTB ;;
    canary) DISCORD_CMD=discord-canary; DISCORD_NAME=DiscordCanary ;;
    *) die "--branch deve ser stable, ptb ou canary" ;;
esac

# --- sistema ---------------------------------------------------------------

detect_distro() {
    [[ -r /etc/os-release ]] || die "não foi possível identificar a distribuição (/etc/os-release)"
    local id like
    id=$(. /etc/os-release; echo "${ID:-}")
    like=$(. /etc/os-release; echo "${ID_LIKE:-}")
    case " $id $like " in
        *" arch "*) DISTRO=arch ;;
        *" debian "*|*" ubuntu "*) DISTRO=debian ;;
        *) die "distribuição não suportada ($id); o script cobre Arch e Debian/Ubuntu e derivados" ;;
    esac
}

# The packages in $@ that aren't installed. pacman -T also counts what
# another package provides (nodejs-lts-* for nodejs).
missing_packages() {
    if [[ $DISTRO == arch ]]; then
        pacman -T "$@" || true
    else
        local pkg
        for pkg in "$@"; do
            [[ $(dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null) == "install ok installed" ]] || echo "$pkg"
        done
    fi
}

# Only what's missing: pacman --needed still offers to reinstall a package
# whose sync database is newer than the installed one.
install_packages() {
    step "Pacotes"
    local pkgs missing
    if [[ $DISTRO == arch ]]; then
        pkgs=(passt wireguard-tools nftables iproute2 util-linux git curl)
        ((SKIP_VENCORD)) || pkgs+=(nodejs pnpm)
    else
        pkgs=(passt wireguard-tools nftables iproute2 util-linux git curl xz-utils ca-certificates)
    fi
    mapfile -t missing < <(missing_packages "${pkgs[@]}")
    if ((${#missing[@]} == 0)); then
        ok "já estão instalados"
        return
    fi
    info "faltam: ${missing[*]}"
    if [[ $DISTRO == arch ]]; then
        # No -y: a partial upgrade (-Sy without -u) can break an Arch system.
        sudo pacman -S --needed "${missing[@]}" \
            || die "o pacman falhou; se for erro 404, rode 'sudo pacman -Syu' e tente de novo"
    else
        sudo apt-get update
        sudo apt-get install -y "${missing[@]}" \
            || die "o apt falhou; o pacote passt existe a partir do Debian 12 e do Ubuntu 23.04"
    fi
    ok "pacotes instalados"
}

load_wireguard() {
    step "Módulo wireguard"
    if [[ ! -d /sys/module/wireguard ]]; then
        sudo modprobe wireguard \
            || die "não foi possível carregar o módulo wireguard; se o kernel foi atualizado agora, reinicie o PC e rode de novo"
    fi
    if [[ ! -e /etc/modules-load.d/wireguard.conf ]]; then
        echo wireguard | sudo tee /etc/modules-load.d/wireguard.conf >/dev/null
    fi
    ok "carregado (e configurado para carregar no boot)"
}

# discord-vpn.sh runs Discord in user namespaces; some distros (Ubuntu 23.10+)
# block them for unconfined programs. That's a system security setting, so
# only explain how to change it.
check_userns() {
    unshare --user --map-root-user true 2>/dev/null && return
    local msg="este sistema não deixa programas comuns criarem user namespaces, que o túnel usa"
    if [[ $(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null) == 1 ]]; then
        msg+=$'.\n       É o AppArmor do Ubuntu. Para liberar (vale até reiniciar):\n'
        msg+=$'         sudo sysctl kernel.apparmor_restrict_unprivileged_userns=0\n'
        msg+=$'       Para manter depois de reiniciar:\n'
        msg+=$'         echo kernel.apparmor_restrict_unprivileged_userns=0 | sudo tee /etc/sysctl.d/60-golivefix-userns.conf'
    fi
    die "$msg"
}

# --- Discord ---------------------------------------------------------------

# Use $1 if it's a Discord install: a folder with resources/ (where Vencord
# goes) and the Discord executable. Sets DISCORD_DIR, DISCORD_EXE and
# DISCORD_PROC (the process name, to see whether it's running).
use_discord_dir() {
    local dir=$1 name
    [[ -d $dir/resources ]] || return 1
    for name in "$DISCORD_NAME" Discord DiscordPTB DiscordCanary; do
        if [[ -f $dir/$name && -x $dir/$name ]]; then
            DISCORD_DIR=$(cd "$dir" && pwd -P)
            DISCORD_EXE=$DISCORD_DIR/$name
            DISCORD_PROC=$name
            return 0
        fi
    done
    return 1
}

# Discord's own Linux installer (the one with updater_bootstrap) keeps the app
# in ~/.config/discord/app-<version>/, with ~/.config/discord/Discord a symlink
# to the current version's executable. Use that version, else the newest app-*.
use_updater_dir() {
    local dir=$1 name app found=0
    for name in "$DISCORD_NAME" Discord DiscordPTB DiscordCanary; do
        [[ -e $dir/$name ]] || continue
        if use_discord_dir "$(dirname "$(readlink -f "$dir/$name")")"; then found=1; break; fi
    done
    if ((!found)); then
        app=$(find "$dir" -mindepth 1 -maxdepth 1 -type d -name 'app-*' -printf '%f\n' 2>/dev/null | sort -V | tail -1)
        [[ -n $app ]] && use_discord_dir "$dir/$app" || return 1
    fi
    DISCORD_UPDATER=1
}

# Where a launcher script sends Discord: the updater's launcher names its
# folder in ~/.config (DIR=discord); a wrapper (exec "$HOME/.../discord" "$@")
# names another launcher.
launcher_target() {
    local script=$1 v
    [[ -f $script && $(head -c 2 "$script" 2>/dev/null) == '#!' ]] || return 1
    v=$(sed -n 's/^[[:space:]]*DIR=["'\'']\{0,1\}\([^"'\''[:space:]]*\).*/\1/p' "$script" | head -1)
    if [[ -n $v ]]; then
        echo "${XDG_CONFIG_HOME:-$HOME/.config}/$v"
        return
    fi
    v=$(sed -n 's/^[[:space:]]*exec[[:space:]]\{1,\}["'\'']\{0,1\}\([^"'\''[:space:]]*\).*/\1/p' "$script" | head -1)
    v=${v/#\~/$HOME}
    v=${v//\$\{HOME\}/$HOME}
    v=${v//\$HOME/$HOME}
    [[ $v == /* ]] || return 1
    echo "$v"
}

# Use $1 if it leads to a Discord install: the install folder, the
# executable, the updater's folder in ~/.config, the folder of the updater's
# launcher (~/.local/opt/Discord), or a launcher script.
try_discord_path() {
    local p=$1 depth=${2:-0} name target
    ((depth < 4)) || return 1
    [[ -e $p ]] || return 1
    p=$(readlink -f "$p")
    if [[ -d $p ]]; then
        use_discord_dir "$p" && return 0
        use_updater_dir "$p" && return 0
        for name in "$DISCORD_CMD" discord discord-ptb discord-canary; do
            [[ -f $p/$name ]] && try_discord_path "$p/$name" $((depth + 1)) && return 0
        done
        return 1
    fi
    use_discord_dir "$(dirname "$p")" && return 0
    target=$(launcher_target "$p") && try_discord_path "$target" $((depth + 1))
}

# The installed Discord: --discord, else the command packages put in PATH,
# else the usual folders of the packages (/opt, /usr), of the official
# .tar.gz (extracted to /opt or the home folder) and of Discord's own installer
# (~/.config/discord).
find_discord() {
    step "Discord"
    DISCORD_UPDATER=0
    if [[ -n $DISCORD_ARG ]]; then
        local p=${DISCORD_ARG/#\~/$HOME}
        [[ -e $p ]] || die "--discord: $p não existe"
        try_discord_path "$p" \
            || die "--discord: Discord não encontrado em $p (passe a pasta que tem resources/ e o executável Discord, o executável, ~/.config/discord ou a pasta do instalador do Discord)"
        ok "usando $DISCORD_DIR"
    else
        local cmd exe d found=0
        cmd=$(command -v "$DISCORD_CMD" 2>/dev/null || true)
        exe=$(readlink -f "$cmd" 2>/dev/null || true)
        for d in ${cmd:+"$cmd"} \
            "/opt/$DISCORD_CMD" "/usr/share/$DISCORD_CMD" "/usr/lib/$DISCORD_CMD" "/usr/lib64/$DISCORD_CMD" \
            "/opt/$DISCORD_NAME" "$HOME/.local/share/$DISCORD_NAME" "$HOME/$DISCORD_NAME" \
            "${XDG_CONFIG_HOME:-$HOME/.config}/${DISCORD_CMD//-/}" "$HOME/.local/opt/$DISCORD_NAME"; do
            if try_discord_path "$d"; then found=1; break; fi
        done
        if ((!found)); then
            if [[ $exe == /snap/* ]] || { have flatpak && flatpak list --app 2>/dev/null | grep -q com.discordapp; }; then
                die "só foi encontrado o Discord do Snap ou do Flatpak, que o Vencord e o GoLiveFix não suportam; instale o pacote normal (do Arch, o .deb ou o .tar.gz oficial)"
            fi
            die "Discord ($BRANCH) não encontrado; instale o Discord (pacote do Arch, .deb ou .tar.gz oficial) ou passe a pasta dele com --discord CAMINHO"
        fi
        ok "encontrado em $DISCORD_DIR"
    fi
    if ((DISCORD_UPDATER)); then
        info "este Discord se atualiza sozinho para uma pasta nova (app-<versão>), sem o Vencord;"
        info "depois de cada atualização dele, rode este script de novo"
    fi
}

# --- WireGuard -------------------------------------------------------------

valid_conf() {
    grep -qiE '^\s*\[Interface\]' "$1" \
        && grep -qiE '^\s*\[Peer\]' "$1" \
        && sed -n '/^\s*\[Interface\]/I,/^\s*\[/{/^\s*Address\s*=/Ip}' "$1" | grep -qE '[0-9]+(\.[0-9]+){3}'
}

setup_conf() {
    step "Config WireGuard"
    if [[ -z $CONF && -r $WG_CONF ]]; then
        ok "já existe em $WG_CONF (para trocar o servidor, rode com --conf ARQUIVO)"
        return
    fi
    if [[ -z $CONF ]]; then
        [[ -t 0 ]] || die "passe o config com --conf ARQUIVO"
        info "baixe um config WireGuard (ex.: account.protonvpn.com → Downloads → WireGuard configuration → Linux)"
        read -rep "    caminho do .conf: " CONF
        CONF=${CONF/#\~/$HOME}
    fi
    [[ -r $CONF ]] || die "config não encontrado: $CONF"
    valid_conf "$CONF" || die "$CONF não parece um config WireGuard com [Interface], Address IPv4 e [Peer]"
    install -D -m 600 "$CONF" "$WG_CONF"
    ok "copiado para $WG_CONF"
}

check_tunnel() {
    step "Conferindo os requisitos do túnel"
    bash "$SCRIPT_DIR/discord-vpn.sh" --check
    check_userns
    ok "tudo certo; o túnel sobe quando o plugin pedir"
}

# --- Node.js e pnpm ----------------------------------------------------------

node_ok() {
    have node || return 1
    local major
    major=$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
    ((major >= NODE_MIN))
}

# The official build from nodejs.org, checked against its SHA-256 list, in a
# folder of the user's: Debian and Ubuntu ship an older Node than Vencord
# accepts.
install_local_node() {
    local arch
    case $(uname -m) in
        x86_64) arch=x64 ;;
        aarch64) arch=arm64 ;;
        *) die "arquitetura $(uname -m) sem Node.js oficial; instale o Node.js $NODE_MIN+ e rode de novo" ;;
    esac
    local base="https://nodejs.org/dist/latest-v$NODE_MIN.x"
    local tmp
    tmp=$(mktemp -d)
    curl -fsSL --proto '=https' -o "$tmp/SHASUMS256.txt" "$base/SHASUMS256.txt" || die "não foi possível consultar o nodejs.org"
    local file
    file=$(awk -v a="linux-$arch.tar.xz" '$2 ~ a"$" {print $2; exit}' "$tmp/SHASUMS256.txt")
    [[ -n $file ]] || die "Node.js para linux-$arch não encontrado no nodejs.org"
    info "baixando $file..."
    curl -fL --proto '=https' -o "$tmp/$file" "$base/$file" || die "não foi possível baixar o Node.js"
    (cd "$tmp" && grep " $file\$" SHASUMS256.txt | sha256sum -c --quiet -) || die "o Node.js baixado não confere com o SHA-256 oficial"
    rm -rf "$TOOLS/node"
    mkdir -p "$TOOLS/node"
    tar -xJf "$tmp/$file" -C "$TOOLS/node" --strip-components=1
    rm -rf "$tmp"
}

setup_node() {
    step "Node.js e pnpm"
    # The script's own first, so a run after installing them reuses them.
    [[ -x $TOOLS/node/bin/node ]] && export PATH="$TOOLS/node/bin:$PATH"
    [[ -x $TOOLS/pnpm/bin/pnpm ]] && export PATH="$TOOLS/pnpm/bin:$PATH"
    # npm is only needed to get pnpm (Debian packages it apart from Node).
    if node_ok && { have pnpm || have npm; }; then
        ok "Node.js $(node -v)"
    else
        info "o Node.js do sistema é antigo ou não existe; instalando o $NODE_MIN em $TOOLS/node"
        install_local_node
        export PATH="$TOOLS/node/bin:$PATH"
        node_ok || die "Node.js instalado, mas não funcionou"
        ok "Node.js $(node -v)"
    fi
    if ! have pnpm; then
        npm install --global --prefix "$TOOLS/pnpm" pnpm >/dev/null || die "não foi possível instalar o pnpm"
        export PATH="$TOOLS/pnpm/bin:$PATH"
    fi
    ok "pnpm $(pnpm --version)"
}

# --- Vencord -----------------------------------------------------------------

# Where Discord's Vencord loads from, or nothing if not injected. A dev install
# (pnpm inject) swaps resources/app.asar for a tiny asar whose index.js is just
# require("<Vencord>/dist/patcher.js"); the real one moves to _app.asar.
injected_patcher() {
    local asar="$DISCORD_DIR/resources/app.asar"
    [[ -f $asar ]] && (($(stat -c %s "$asar") < 65536)) || return 0
    { grep -ao 'require("[^"]*")' "$asar" || true; } | head -1 | sed 's/^require("\(.*\)")$/\1/'
}

discord_running() { pgrep -x "$DISCORD_PROC" >/dev/null; }

# Sets GoLiveFix's entries in Vencord's settings.json (Discord must be closed:
# Vencord reads it only at startup and rewrites it whole on any change).
set_plugin_settings() {
    node - "$HOME/.config/Vencord/settings/settings.json" "$@" <<'EOF'
const fs = require("fs"), path = require("path");
const [file, ...pairs] = process.argv.slice(2);
let s = {};
try { s = JSON.parse(fs.readFileSync(file, "utf8")); } catch (e) { if (e.code !== "ENOENT") throw e; }
const p = ((s.plugins ??= {}).GoLiveFix ??= {});
const changed = [];
for (const pair of pairs) {
    const [k, v] = pair.split("=");
    const value = JSON.parse(v);
    if (p[k] !== value) { p[k] = value; changed.push(k); }
}
if (changed.length) {
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, JSON.stringify(s, null, 4));
}
console.log(changed.join(", "));
EOF
}

setup_vencord() {
    step "Vencord com o GoLiveFix"
    local f
    for f in index.tsx native.ts discord-vpn.sh; do
        [[ -e $SCRIPT_DIR/$f ]] || die "rode este script de dentro da pasta do GoLiveFix (falta $f)"
    done

    if [[ ! -e $VENCORD_DIR ]]; then
        info "baixando o Vencord em $VENCORD_DIR..."
        git clone https://github.com/Vendicated/Vencord "$VENCORD_DIR"
    elif [[ ! -f $VENCORD_DIR/package.json ]]; then
        die "$VENCORD_DIR existe mas não é o Vencord; use --vencord-dir OUTRA_PASTA"
    else
        ok "Vencord já está em $VENCORD_DIR"
    fi
    VENCORD_DIR=$(cd "$VENCORD_DIR" && pwd)

    info "instalando dependências..."
    (cd "$VENCORD_DIR" && pnpm install --frozen-lockfile)

    # The Vencord checkout usually sits inside the plugin folder: skip it.
    local dest="$VENCORD_DIR/src/userplugins/GoLiveFix"
    rm -rf "$dest"
    mkdir -p "$dest"
    tar -C "$SCRIPT_DIR" --exclude=./.git --exclude=./Vencord --exclude="./${VENCORD_DIR#"$SCRIPT_DIR"/}" \
        --exclude=./windows-hook/target --exclude=node_modules -cf - . | tar -C "$dest" -xf -
    ok "plugin copiado"

    info "compilando..."
    (cd "$VENCORD_DIR" && pnpm build)
    ok "compilado"

    local patcher="$VENCORD_DIR/dist/patcher.js" current
    current=$(injected_patcher)
    if [[ -n $current && $current != "$patcher" ]]; then
        info "o Discord carrega o Vencord de outra pasta (${current%/dist/patcher.js}); ele vai passar a carregar desta"
    fi

    # A Discord open from before this build runs the old plugin, and its
    # main-process half (native.ts) only loads at startup: Ctrl+R isn't enough.
    if discord_running; then
        if ! ask "O Discord precisa reiniciar para carregar o plugin (ele abre de novo sozinho). Reiniciar agora?"; then
            [[ $current == "$patcher" ]] || die "feche o Discord e rode de novo"
            warn "o plugin novo só vale depois de reiniciar o Discord; rode de novo com ele fechado para ativar o plugin"
            return
        fi
        pkill -x "$DISCORD_PROC" || true
        local i
        for i in {1..30}; do discord_running || break; sleep 0.5; done
        discord_running && die "o Discord não fechou"
    fi

    if [[ $current == "$patcher" ]]; then
        ok "Vencord já injetado no Discord"
    else
        # The exact folder, not -branch: the installer's own search misses
        # installs outside the usual paths (a .tar.gz in the home folder).
        local inject=(scripts/runInstaller.mjs -- --install -location "$DISCORD_DIR")
        if [[ -w $DISCORD_DIR/resources ]]; then
            info "injetando no Discord..."
            (cd "$VENCORD_DIR" && node "${inject[@]}")
        else
            info "injetando no Discord (ele fica numa pasta do sistema, então pede sudo)..."
            # Vencord's installer doesn't escalate by itself. Absolute node
            # path: sudo resets PATH, and the script's node may live in $TOOLS.
            (cd "$VENCORD_DIR" && sudo "$(command -v node)" "${inject[@]}")
            # It downloads itself into dist/Installer, as root.
            sudo chown -R "$(id -u):$(id -g)" "$VENCORD_DIR/dist/Installer" 2>/dev/null || true
        fi
        [[ $(injected_patcher) == "$patcher" ]] || die "o instalador do Vencord não injetou no Discord em $DISCORD_DIR; veja a saída acima"
        ok "injetado"
    fi

    local pairs=(enabled=true) changed
    ((ENTER_ON_STARTUP)) && pairs+=(enterOnStartup=true)
    changed=$(set_plugin_settings "${pairs[@]}")
    if [[ -n $changed ]]; then ok "GoLiveFix ativado nas configurações do Vencord ($changed)"; else ok "GoLiveFix já estava ativado"; fi

    if [[ -n ${DISPLAY:-}${WAYLAND_DISPLAY:-} ]]; then
        nohup "$DISCORD_EXE" >/dev/null 2>&1 &
        disown
        DISCORD_STARTED=1
        ok "abrindo o Discord"
    fi
}

# --- main ------------------------------------------------------------------

[[ $(id -u) != 0 ]] || die "rode como o seu usuário, sem sudo (o script pede sudo quando precisa)"
DISCORD_STARTED=0

detect_distro
# Before installing anything: without a Discord there's nothing to set up.
((SKIP_VENCORD)) || find_discord
install_packages
load_wireguard
setup_conf
check_tunnel
if ! ((SKIP_VENCORD)); then
    setup_node
    setup_vencord
fi

step "Pronto"
((DISCORD_STARTED)) && info "O Discord está abrindo com o GoLiveFix ativo."
if ((ENTER_ON_STARTUP)); then
    info "Ele entra no túnel sozinho ao abrir."
else
    info "Clique no escudo ao lado do microfone: o Discord reinicia dentro do túnel."
    info "O Discord sempre abre fora do túnel: clique no escudo uma vez a cada abertura."
    info "(Ou rode de novo com --enter-on-startup para ele entrar no túnel sozinho ao abrir.)"
fi
((SKIP_VENCORD)) || info "Não apague nem mova $VENCORD_DIR: o Discord carrega o Vencord de lá."
