# GoLiveFix

Plugin do [Vencord](https://github.com/Vendicated/Vencord) que passa o Discord por um túnel WireGuard
para transmitir e assistir streams (Go Live) quando a sua região está bloqueada.

O túnel só é usado quando precisa: na hora de iniciar ou assistir uma stream. Depois ele é solto, e o
resto do Discord volta a sair direto pela sua conexão. Funciona com voz e vídeo, não só com o chat.

Funciona no **Linux** e no **Windows**.

## Sumário

- [Instalação no Windows](#instalação-no-windows)
  - [Automática](#automática) · [Manual](#manual)
- [Instalação no Linux](#instalação-no-linux)
  - [Automática (Arch e Debian/Ubuntu)](#automática-arch-e-debianubuntu) · [Manual](#manual-1)
- [Primeiro uso](#primeiro-uso)
- [Uso](#uso)
  - [O escudo](#o-escudo) · [Os três modos](#os-três-modos) ·
    [O que o plugin faz sozinho](#o-que-o-plugin-faz-sozinho) · [Configurações](#configurações)
- [Atualizando](#atualizando)
- [Desinstalando](#desinstalando)
- [Solução de problemas](#solução-de-problemas)
- [Problemas conhecidos](#problemas-conhecidos)
- [Como funciona](#como-funciona)
- [Desenvolvimento](#desenvolvimento)
  - [Arquivos](#arquivos) · [Compilando a DLL por conta própria](#compilando-a-dll-por-conta-própria) ·
    [Usando o script direto (Linux)](#usando-o-script-direto-linux)

## Instalação no Windows

O túnel do WireGuard é configurado uma vez, com administrador, e fica ativo. Depois disso o plugin não
precisa de administrador para nada.

### Automática

1. Baixe o GoLiveFix: **Code → Download ZIP** no GitHub, e extraia. Ou use `git clone`.
2. Baixe um config WireGuard. No ProtonVPN (tem servidores gratuitos):
   [account.protonvpn.com](https://account.protonvpn.com) → **Downloads** → **WireGuard configuration**,
   escolha **Windows** e um servidor. O país do servidor é o país de onde o Discord vai te ver enquanto o
   túnel estiver ligado.
3. Na pasta do GoLiveFix, abra um PowerShell (clique direito numa área vazia → **Abrir no Terminal**) e
   rode:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\setup-windows.ps1
   ```

O script:

- instala o que faltar (WireGuard, Git, Node.js e pnpm);
- pede o `.conf`, ajusta ele como no [passo 3 da instalação manual](#3-config-wireguard) e instala como
  o túnel `golivefix`. Esta é a única parte que pede administrador, numa janela do UAC;
- confere se o túnel funciona: o PC tem que sair direto e o túnel pela VPN;
- baixa o Vencord na pasta `Vencord`, dentro da pasta do GoLiveFix (o git ignora essa pasta), compila
  com o plugin e injeta no Discord. Se o Discord já carrega o Vencord dessa pasta, a injeção é pulada;
- ativa o GoLiveFix nas configurações do Vencord e abre o Discord. Se o Discord estiver aberto, pergunta
  antes de reiniciar.

Depois, siga o [primeiro uso](#primeiro-uso).

**Não apague nem mova a pasta do GoLiveFix depois disso.** O Discord carrega o Vencord da pasta
`Vencord` que fica dentro dela. Se precisar mudar de lugar, rode o script de novo no lugar novo.

O config ajustado só fica guardado dentro do WireGuard, criptografado
(`C:\Program Files\WireGuard\Data\Configurations\golivefix.conf.dpapi`, legível só pelo sistema). Para
ver ou editar, use **Editar** no app do WireGuard. A cópia temporária que o script cria para importar é
apagada logo em seguida, e o seu `.conf` original não é alterado.

Rodar de novo é seguro: o `.conf` é pedido de novo e o túnel `golivefix` é reinstalado com ele, e o
resto que já está feito é pulado. Opções:

| Opção | O que faz |
|---|---|
| `-Conf <arquivo.conf>` | Usa esse config, sem abrir a janela para escolher o arquivo |
| `-VencordDir <pasta>` | Onde fica o Vencord (padrão: a pasta `Vencord` ao lado do script) |
| `-Branch ptb` / `canary` | Injeta no Discord PTB ou Canary em vez do normal |
| `-SkipTunnel` | Não mexe no túnel |
| `-SkipVencord` | Não mexe no Vencord (só túnel) |
| `-EnterOnStartup` | Liga a opção [Entrar no túnel ao abrir o Discord](#configurações) |

### Manual

O mesmo que o script faz, passo a passo.

#### 1. Programas

Instale o [WireGuard para Windows](https://www.wireguard.com/install/), o [Git](https://git-scm.com) e o
[Node.js LTS](https://nodejs.org). Pelo terminal:

```powershell
winget install WireGuard.WireGuard
winget install Git.Git
winget install OpenJS.NodeJS.LTS
npm install -g pnpm
```

Abra um terminal novo depois de instalar, para o `git`, o `node` e o `pnpm` entrarem no PATH.

Não precisa de Rust: a `version.dll` já vem compilada no repositório (`windows-hook/version.dll`). Para
compilar a sua, veja [Compilando a DLL por conta própria](#compilando-a-dll-por-conta-própria).

#### 2. Permitir scripts no WireGuard

O túnel usa um `PostUp` para criar a rota de que o plugin precisa, e o WireGuard para Windows só roda
scripts com esta chave. Num PowerShell **como administrador**:

```powershell
reg add HKLM\Software\WireGuard /v DangerousScriptExecution /t REG_DWORD /d 1 /f
```

Depois feche o WireGuard pela bandeja (**Sair**) e abra de novo.

#### 3. Config WireGuard

Qualquer config WireGuard com `Address` IPv4 serve. No ProtonVPN (tem servidores gratuitos):
[account.protonvpn.com](https://account.protonvpn.com) → **Downloads** → **WireGuard configuration**,
escolha **Windows** e um servidor.

Abra o `.conf` num editor de texto e mude a seção `[Interface]`:

1. **Apague** a linha `DNS = ...`. Senão o Windows passa a mandar as consultas DNS do PC inteiro para o
   DNS da VPN.
2. **Adicione** estas duas linhas:

   ```ini
   Table = off
   PostUp = netsh interface ipv4 add route 0.0.0.0/0 golivefix metric=9000 store=active
   ```

Fica assim (chaves e endereços são os seus):

```ini
[Interface]
PrivateKey = ...
Address = 10.2.0.2/32
Table = off
PostUp = netsh interface ipv4 add route 0.0.0.0/0 golivefix metric=9000 store=active

[Peer]
PublicKey = ...
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = ...:51820
```

Deixe o `AllowedIPs` como veio. O que as duas linhas fazem:

- `Table = off` impede o WireGuard de jogar o PC inteiro no túnel;
- a rota de métrica 9000 dá ao túnel um caminho para a internet que o sistema nunca escolhe sozinho.
  Só o Discord, preso ao endereço do túnel, usa esse caminho.

Salve o arquivo como **`golivefix.conf`**. O nome do túnel no WireGuard vem do nome do arquivo, e o
plugin procura a interface `golivefix`.

No WireGuard: **Importar túnel(s) de arquivo** → `golivefix.conf` → **Ativar**. Se aparecer a opção
**Block untunneled traffic (kill-switch)** ao editar o túnel, deixe desmarcada. O túnel volta sozinho
quando o PC liga, se estava ativo ao desligar.

Para conferir, num PowerShell normal:

```powershell
Get-NetRoute -InterfaceAlias golivefix -DestinationPrefix 0.0.0.0/0
```

Tem que aparecer uma linha com `RouteMetric` 9000. Este comando mostra o seu IP de sempre (o PC não
passa pelo túnel):

```powershell
curl.exe https://ifconfig.me
```

E este mostra o IP da VPN (troque pelo `Address` do seu config, sem o `/32`):

```powershell
curl.exe --interface 10.2.0.2 https://ifconfig.me
```

Se a rota não apareceu, o `PostUp` não rodou (confira o passo 2). Até resolver, dá para criar a rota na
mão, como administrador, toda vez que ativar o túnel:

```powershell
netsh interface ipv4 add route 0.0.0.0/0 golivefix metric=9000 store=active
```

#### 4. Vencord com o plugin

Compile **no próprio Windows**. Builds locais do Vencord fixam o sistema de quem compilou, então um
build feito no Linux não tem a parte do Windows. Num PowerShell normal:

```powershell
git clone https://github.com/Vendicated/Vencord
cd Vencord
pnpm install --frozen-lockfile
Copy-Item -Recurse C:\caminho\para\GoLiveFix src\userplugins\GoLiveFix
pnpm build
pnpm inject
```

Antes do `pnpm inject`, feche o Discord por completo, inclusive na bandeja. No instalador, escolha a
instalação do Discord.

## Instalação no Linux

### Automática (Arch e Debian/Ubuntu)

1. Tenha o Discord instalado: o pacote `discord` do Arch, o `.deb` oficial, o `.tar.gz` oficial ou o
   instalador do próprio Discord (o que se atualiza sozinho em `~/.config/discord`). O do Snap e o do
   Flatpak não servem (o Vencord não suporta).
2. Baixe o GoLiveFix (`git clone`, ou **Code → Download ZIP** no GitHub e extraia).
3. Baixe um config WireGuard. No ProtonVPN (tem servidores gratuitos):
   [account.protonvpn.com](https://account.protonvpn.com) → **Downloads** → **WireGuard configuration**,
   escolha **Linux** e um servidor. O país do servidor é o país de onde o Discord vai te ver enquanto o
   túnel estiver ligado.
4. Na pasta do GoLiveFix, rode como o seu usuário (sem `sudo`):

   ```sh
   bash setup-linux.sh --conf ~/Downloads/<arquivo>.conf
   ```

O script pede `sudo` só quando precisa e:

- acha o Discord: pelo comando `discord` no PATH, nas pastas dos pacotes (`/opt/discord`,
  `/usr/share/discord`, `/usr/lib/discord`) ou onde o `.tar.gz` costuma ser extraído (`/opt/Discord`,
  `~/Discord`, `~/.local/share/Discord`) ou onde o instalador do próprio Discord o põe
  (`~/.config/discord/app-<versão>`, aberto por `~/.local/opt/Discord/discord`). Se ele estiver em outro
  lugar, passe com `--discord`;
- instala os pacotes (`passt`, `wireguard-tools`, `nftables`, `git`, Node.js e pnpm) e carrega o módulo
  `wireguard`, também no boot;
- copia o config para `~/.config/discord-vpn/wg.conf` e confere os requisitos do túnel. Se o sistema
  bloquear user namespaces (Ubuntu 23.10+), ele para e explica como liberar;
- se o Node.js do sistema for antigo (o Vencord pede 22+, e o Debian/Ubuntu trazem menos), baixa o
  oficial do nodejs.org, conferido pelo SHA-256, em `~/.local/share/golivefix/`. Nada disso vai para o
  sistema;
- baixa o Vencord na pasta `Vencord`, dentro da pasta do GoLiveFix (o git ignora essa pasta), compila
  com o plugin e injeta no Discord (com `sudo` se o Discord estiver numa pasta do sistema, como `/opt`
  ou `/usr`). Se o Discord já carrega o Vencord dessa pasta, a injeção é pulada;
- ativa o GoLiveFix nas configurações do Vencord e abre o Discord. Se o Discord estiver aberto, pergunta
  antes de reiniciar.

Depois, siga o [primeiro uso](#primeiro-uso). **Não apague nem mova a pasta do GoLiveFix**: o Discord
carrega o Vencord de dentro dela.

Rodar de novo é seguro: o que já está feito é pulado. Sem `--conf`, o config atual é mantido (ou o
script pergunta, se não houver). Opções:

| Opção | O que faz |
|---|---|
| `--conf ARQUIVO` | Usa esse config. Com um config já instalado, troca o servidor |
| `--discord CAMINHO` | A pasta do Discord (a que tem `resources/`), o executável ou o script que o abre, `~/.config/discord` ou a pasta do instalador do Discord (`~/.local/opt/Discord`), em vez de procurar |
| `--branch ptb` / `canary` | Procura o Discord PTB ou Canary em vez do normal |
| `--vencord-dir PASTA` | Onde fica o Vencord (padrão: a pasta `Vencord` ao lado do script) |
| `--enter-on-startup` | Liga a opção [Entrar no túnel ao abrir o Discord](#configurações) |
| `--skip-vencord` | Só pacotes e túnel, sem mexer no Vencord |

### Manual

#### Requisitos

- Linux com suporte a user namespaces (padrão na maioria das distros)
- [Vencord](https://github.com/Vendicated/Vencord) compilado a partir do código-fonte (para plugins de usuário)
- `passt` (fornece o `pasta`), `wireguard-tools`, `nftables`
- módulo `wireguard` carregado
- um config WireGuard em `~/.config/discord-vpn/wg.conf`

No Arch:

```sh
sudo pacman -S passt wireguard-tools nftables
sudo modprobe wireguard
echo wireguard | sudo tee /etc/modules-load.d/wireguard.conf   # carregar no boot
```

#### Config WireGuard

Qualquer config WireGuard com `Address` IPv4 serve. O ProtonVPN tem servidores gratuitos:

1. Em [account.protonvpn.com](https://account.protonvpn.com) → **Downloads** → **WireGuard configuration**,
   escolha **Linux** e um servidor gratuito.
2. Salve o arquivo:

   ```sh
   mkdir -p ~/.config/discord-vpn
   mv ~/Downloads/<arquivo>.conf ~/.config/discord-vpn/wg.conf
   chmod 600 ~/.config/discord-vpn/wg.conf
   ```

O país do servidor é o país de onde o Discord vai te ver enquanto o túnel estiver ligado.

#### Vencord com o plugin

O Vencord pede Node.js 22 ou mais novo.

```sh
git clone https://github.com/Vendicated/Vencord
cd Vencord
pnpm install --frozen-lockfile

# o plugin vai em src/userplugins/
cp -r /caminho/para/GoLiveFix src/userplugins/GoLiveFix

pnpm build
pnpm inject   # com o Discord fechado; escolha a instalação do Discord
```

Para conferir os requisitos sem abrir nada:

```sh
./discord-vpn.sh --check
```

## Primeiro uso

1. Se instalou na mão: abra o Discord, vá em **Configurações → Vencord → Plugins**, ative o
   **GoLiveFix** e aperte **Ctrl+R**. Os scripts de instalação já fazem isso sozinhos.
2. Clique no escudo ao lado do microfone. O Discord entra no túnel:
   - no Windows, na primeira vez ele reinicia, porque o plugin coloca a `version.dll` ao lado do
     `Discord.exe`. Das próximas vezes, só recarrega a tela;
   - no Linux, ele reinicia dentro do namespace.
3. O escudo fica verde e, depois de alguns segundos, apaga (túnel solto). Em **Configurações → Vencord →
   Plugins → GoLiveFix**, o estado não pode ser "Fora do túnel".

Daí em diante:

- O Discord sempre abre fora do túnel. Clique no escudo uma vez e ele entra.
- No Windows, depois de uma atualização do Discord, o clique reinicia o Discord em vez de recarregar. O
  Discord atualizado fica numa pasta nova (`app-x.y.z`), sem a DLL, e o clique coloca a DLL lá.
- Para não precisar clicar, ligue [Entrar no túnel ao abrir o Discord](#configurações).

## Uso

### O escudo

Aparece um ícone de escudo à esquerda dos botões de microfone e fone. Ele pode ser escondido nas
[configurações](#configurações).

- **Clique:** liga ou desliga o túnel.
- **Clique direito:**
  - **Ligar/Desligar túnel**
  - **Reiniciar no túnel:** reconecta o Discord com o túnel ligado desde o início (no Windows,
    recarrega a tela)
  - **Decodificador OpenH264**, só no Linux (veja [Problemas conhecidos](#problemas-conhecidos))

Cor do ícone:

| Cor | Estado |
|---|---|
| verde | ligado |
| amarelo | solto, com voz e stream novas ainda pelo túnel |
| apagado | desligado ou Discord fora do túnel |

Fluxo comum: clique no escudo uma vez (o Discord entra no túnel) e depois é só usar o Discord
normalmente. Transmitir ou assistir uma stream liga o túnel sozinho.

### Os três modos

| Modo | Novas conexões |
|---|---|
| ligado | passam pelo túnel |
| solto | só voz e stream passam pelo túnel (se a opção estiver ativa); o resto sai direto |
| desligado | saem direto |

**Trocar de modo só afeta novas conexões.** As que já estão abertas continuam no caminho em que
começaram (veja [Como funciona](#conexões-abertas-não-mudam-de-caminho)).

### O que o plugin faz sozinho

- **Ligar com o Discord fora do túnel:** coloca o Discord dentro do túnel, já com ele ligado desde a
  primeira conexão. No Windows isso só recarrega a tela, exceto na primeira vez e depois de
  atualizações. No Linux, reinicia o Discord. Depois de alguns segundos (configurável), o túnel é solto.
- **Ligar com o Discord já no túnel:** só liga, sem recarregar nada. Fica ligado até você desligar;
  nada automático solta.
- **Transmitir ou assistir uma stream:** liga o túnel antes de a conexão da stream abrir e solta depois
  que ela começa.
- **Abrir ou recarregar o Discord** (Ctrl+R, ou quando ele recarrega sozinho), com a opção *Entrar no
  túnel ao abrir o Discord* ligada: liga o túnel antes de a tela carregar, então tudo já conecta por ele.
  Depois de alguns segundos ele é solto, como no primeiro item. Quando o Discord só entra reiniciando
  (no Windows, na primeira vez e depois de atualizações; no Linux, fora do `discord-vpn.sh`), ele
  reinicia, como no primeiro item.
- **Desativar o plugin:** desliga o túnel.

### Configurações

Em **Configurações → Vencord → Plugins → GoLiveFix**:

| Opção | Padrão | O que faz |
|---|---|---|
| Mostrar o escudo ao lado do microfone | ligado | Desligado, o escudo some; o túnel continua controlável por esta tela |
| Entrar no túnel ao abrir o Discord | desligado | Ao abrir ou recarregar (Ctrl+R) o Discord, liga o túnel antes de a tela carregar. Se ele só entra reiniciando, reinicia, uma vez por abertura: se o túnel não estiver ativo, só avisa |
| Soltar o túnel quando a stream começar | ligado | Solta o túnel depois que a sua stream, ou a que você assiste, começa |
| Espera para soltar após a stream começar | 4000 ms | Tempo até soltar o túnel |
| Soltar após entrar no túnel | 5000 ms | Tempo até soltar o túnel depois de entrar nele. `0` = só quando uma stream começar |
| Manter voz e stream no túnel ao soltar | desligado | Ao soltar, novas conexões de voz e stream continuam pelo túnel |

A mesma tela tem botões para ligar, soltar, desligar e reiniciar no túnel, e mostra os últimos logs.

## Atualizando

Depois de atualizar o plugin, reinicie o Discord por completo. Ctrl+R não basta: parte do plugin roda no
processo principal, que só carrega ao abrir.

- **Windows:** rode o `setup-windows.ps1` de novo. Ele recopia e recompila o plugin. Na mão: copie a
  pasta para `Vencord\src\userplugins\GoLiveFix` e rode `pnpm build` no Vencord. Se mudou algo em
  `windows-hook\src`, [compile a DLL](#compilando-a-dll-por-conta-própria) antes.
- **Linux:** rode o `setup-linux.sh` de novo. Na mão: copie os arquivos de novo para
  `Vencord/src/userplugins/GoLiveFix` e rode `pnpm build`.

Não precisa injetar de novo, a não ser que uma atualização do Discord desfaça a injeção. O Discord do
instalador próprio (`~/.config/discord/app-<versão>`) instala cada atualização numa pasta nova, sem o
Vencord: depois de uma atualização dele, rode o `setup-linux.sh` de novo.

## Desinstalando

1. Desative o plugin.
2. Para tirar o Vencord do Discord: na pasta do Vencord, rode `pnpm uninject`. Depois pode apagar a
   pasta.
3. No Windows:
   - com o Discord fechado, apague `version.dll` e `version.dll.old-*` de
     `%LOCALAPPDATA%\Discord\app-*\`;
   - remova o túnel no WireGuard.
4. No Linux: apague `~/.config/discord-vpn/` (o config) e, se o script baixou o Node.js,
   `~/.local/share/golivefix/`.

## Solução de problemas

### Windows

Não há arquivo de log. Os últimos eventos aparecem em **Configurações → Vencord → Plugins → GoLiveFix**,
e os erros também aparecem em notificação.

- **"o túnel WireGuard "golivefix" não está ativo":** ative o túnel no WireGuard. Se ele tem outro
  nome, renomeie para `golivefix`, ou crie a variável de ambiente de usuário `GOLIVEFIX_ADAPTER` com o
  nome dele e reabra o Discord.
- **"não tem rota para a internet":** falta a rota de métrica 9000. Confira o
  [passo 3 da instalação manual](#3-config-wireguard).
- **"não foi possível gravar a version.dll":** feche o Discord por completo, inclusive na bandeja, e
  tente de novo.
- **A internet do PC inteiro foi para a VPN, ou sites pararam de abrir com o túnel ativo:** faltou
  `Table = off`, ou o kill-switch está ligado, ou a linha `DNS` continua no config. Veja o
  [passo 3 da instalação manual](#3-config-wireguard).
- **Todo clique no escudo reinicia o Discord, em vez de só recarregar, e ele continua "Fora do
  túnel":** confira se a `version.dll` está em `%LOCALAPPDATA%\Discord\app-<versão>\` (a pasta mais
  nova) e se o Vencord foi compilado no Windows.

### Linux

- **Log:** `~/.config/discord/goLiveFix/discord-vpn.log` tem a saída do script (trocas de modo,
  fluxos fixados) e do próprio Discord.
- **"Discord fora do túnel" mesmo depois de ligar:** veja o log. Se o túnel falhar ao subir, o Discord
  abre normalmente, sem ele, para você não ficar sem Discord.
- **"sem handshake WireGuard":** o config está errado ou o servidor não responde. Teste com outro
  servidor.
- **"feche o Discord antes":** o Discord ainda está rodando, provavelmente na bandeja.

## Problemas conhecidos

- **Vídeo tremendo ou com artefatos ao assistir:** é o decodificador H.264 do Discord no Linux
  (OpenH264), não o túnel. Desligue o OpenH264 pelo menu do escudo. Algumas streams só vêm em H.264 e não
  abrem sem ele; para essas, ligue, assista, e desligue depois. A troca vale para streams abertas depois
  dela.
- **Ping de voz alto depois de soltar o túnel:** uma chamada de voz que começou com o túnel ligado
  continua nele até você sair e entrar no canal de novo.
- **Só IPv4:** o túnel só carrega IPv4. No Linux, o namespace não tem IPv6, para nada escapar das
  regras. No Windows, enquanto o modo quer o túnel, conexões IPv6 novas para a internet são recusadas e o
  Discord tenta de novo por IPv4, que passa pelo túnel.
- **Sem macOS:** não há equivalente sem root ao namespace do Linux nem ao jeito do Windows.

## Como funciona

### Por que um túnel e não um proxy

O Discord tem duas partes de rede:

- a interface (Chromium), que usa TCP: gateway, API, imagens;
- o motor de voz nativo, que manda voz e vídeo de stream por UDP e **ignora as configurações de proxy**.

Um proxy SOCKS só pega a primeira parte. Para pegar a voz e a stream, no Linux o Discord inteiro roda
dentro de um *network namespace* próprio, onde nada consegue escapar do roteamento. No Windows cada
conexão nova é presa ao túnel.

### Linux: o namespace

```
rede do sistema ── pasta (sem root, não mexe no firewall nem nas rotas do sistema)
     └── namespace do Discord
           ├── interface direta → sua conexão normal
           └── wg0 → túnel WireGuard
```

O `discord-vpn.sh` cria o namespace com o [`pasta`](https://passt.top), sobe o `wg0` com o seu config
WireGuard e abre o Discord lá dentro. Tudo roda como o seu usuário. O Discord não tem permissão para
mudar as rotas: só o script muda, quando o plugin pede.

Quando o Discord fecha, o namespace é desfeito sozinho. Reinícios do próprio Discord (atualização,
reinício do Vencord) continuam dentro do túnel.

### Windows: conexões presas ao túnel

Não existe namespace sem administrador no Windows, então o caminho é outro. O Windows manda cada
conexão pela interface do endereço a que ela está presa (*bind*):

- uma conexão presa ao endereço do túnel sai pelo túnel;
- uma conexão sem endereço fixo segue a rota padrão e sai direto.

O túnel do WireGuard fica ativo o tempo todo, mas com `Table = off` e só uma rota padrão de métrica
altíssima. Assim o sistema nunca escolhe o túnel por conta própria. Só usa ele quem se prende ao
endereço dele.

Quem prende é uma `version.dll` (pasta `windows-hook/`, em Rust) que o plugin coloca ao lado do
`Discord.exe`. O Discord carrega essa DLL em todos os seus processos, inclusive no motor de voz. A DLL
repassa tudo para a `version.dll` original do Windows e intercepta a criação de conexões
(`bind`/`connect`/`sendto`): uma conexão nova é presa ao túnel conforme o modo atual. A DLL lê o modo e
o endereço do túnel de um arquivo que o plugin reescreve (`%APPDATA%\discord\goLiveFix\state`, por
exemplo `arm 10.2.0.2`). Sem esse arquivo, ou com o túnel desligado, ela não faz nada. Conexões para a
rede local (localhost, roteador, LAN) nunca são presas. Tudo roda como o seu usuário: não há serviço,
driver nem permissão de administrador no uso diário.

Para entrar no túnel, o plugin liga o modo, fecha as conexões abertas do Discord e recarrega a tela.
Tudo reconecta, já pelo túnel. Só é preciso reiniciar o Discord quando a DLL ainda não está carregada:
na primeira vez e depois de cada atualização do Discord, que cria uma pasta nova sem ela. Ao abrir, o
Discord sempre começa fora do túnel.

### Conexões abertas não mudam de caminho

Trocar de modo só afeta novas conexões. As que já estão abertas continuam no caminho em que começaram:

- TCP: pelo endereço de origem da conexão;
- UDP (voz e stream): no Linux, a cada troca de modo, cada fluxo UDP ativo é fixado no caminho atual
  (destino + porta local, rastreados com nftables). No Windows, a conexão já nasce presa (ou não) ao
  túnel e nunca é presa de novo.

Isso importa: se uma stream em andamento mudasse de caminho, o servidor e o Discord passariam a
discordar sobre o seu endereço, e a mídia quebraria.

## Desenvolvimento

### Arquivos

| Arquivo | Papel |
|---|---|
| `index.tsx` | Interface: botão, menu, configurações, e o que acontece ao transmitir/assistir |
| `native.ts` | Processo principal do Discord: liga, solta e desliga o túnel |
| `tunnel.ts` | Interface dos backends de túnel e escolha do backend pelo sistema |
| `tunnel-linux.ts` | Backend Linux: conversa com o script (FIFO de controle) e reinicia o Discord no túnel |
| `discord-vpn.sh` | Cria o namespace, o túnel e as regras de roteamento |
| `tunnel-windows.ts` | Backend Windows: grava o modo e o endereço para a DLL, e coloca a DLL (reiniciando o Discord) quando ela falta |
| `setup-windows.ps1` | Instalação no Windows: programas, túnel WireGuard, Vencord com o plugin |
| `setup-linux.sh` | Instalação no Linux (Arch, Debian/Ubuntu): pacotes, config WireGuard, Vencord com o plugin |
| `windows-hook/` | A `version.dll` (Rust) que prende as conexões novas do Discord ao túnel |
| `windows-hook/build.ps1` | Recompila a DLL e copia para `windows-hook/version.dll`, que o build do plugin embute |
| `windows-hook/test-wildcard.ps1` | Teste manual: procura conexões locais quebradas pelo túnel no Discord de verdade |
| `style.css` | Estilo do botão |

O plugin grava seus arquivos em `~/.config/discord/goLiveFix/` no Linux (script e log) e em
`%APPDATA%\discord\goLiveFix\` no Windows (o arquivo `state`, com o modo e o endereço do túnel).

### Compilando a DLL por conta própria

O repositório já traz a `windows-hook\version.dll` compilada, e é ela que o build do plugin embute.
Para não depender desse binário (ou depois de mudar o código em `windows-hook\src`), compile a sua.

1. Instale o Rust e as ferramentas de C++ da Microsoft, que o Rust usa para gerar DLLs no Windows:

   ```powershell
   winget install Rustlang.Rustup
   winget install Microsoft.VisualStudio.2022.BuildTools --override "--quiet --wait --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
   ```

   Abra um terminal novo depois. O Rust já vem com o alvo certo (`x86_64-pc-windows-msvc`); para
   conferir, `rustup show`.

2. Na pasta do GoLiveFix, compile:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\windows-hook\build.ps1
   ```

   Ele roda `cargo build --release` e copia o resultado para `windows-hook\version.dll`, por cima da
   que veio no repositório. Para rodar os testes: `cargo test --release` dentro de `windows-hook`.

3. Recompile o plugin: rode o `setup-windows.ps1` de novo (ou `pnpm build` no Vencord, com a pasta
   copiada) e reinicie o Discord.

No próximo clique no escudo, o plugin percebe que a DLL ao lado do `Discord.exe` é diferente da que ele
embute e reinicia o Discord uma vez, para colocar a nova. Depois disso, volta a só recarregar a tela.

A sua DLL não vai ser idêntica byte a byte à do repositório (o compilador e as versões mudam). Isso é
normal: o plugin só compara com a que ele mesmo embute.

### Usando o script direto (Linux)

O plugin já embute o script e roda ele quando precisa. Para abrir o Discord no túnel sem o plugin:

```sh
./discord-vpn.sh          # túnel desligado no início
./discord-vpn.sh --arm    # túnel ligado no início
```

Variáveis de ambiente:

| Variável | Padrão |
|---|---|
| `DCVPN_CONF` | `~/.config/discord-vpn/wg.conf` |
| `DCVPN_DISCORD` | `discord` (comando que abre o Discord) |
| `DCVPN_RUNDIR` | `$XDG_RUNTIME_DIR/discord-vpn` |
