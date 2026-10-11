//! GoLiveFix proxy `version.dll` (Windows).
//!
//! Discord imports the system `version.dll`, so a `version.dll` sitting next
//! to `Discord.exe` is loaded first — into every Discord process, the voice
//! and network ones included. This DLL uses that foothold for one thing:
//! binding Discord's own freshly created sockets to the WireGuard tunnel's
//! local address, so the OS strong-host model sends them through the tunnel,
//! while unbound sockets keep going direct (confirmed: a socket bound to the
//! tunnel IP routes over it for both TCP and UDP).
//!
//! That's the whole job. This DLL is not a general-purpose injector: it has no
//! effect outside a process that loads it, it's placed and removed by the
//! GoLiveFix plugin at the user's request, and it only touches sockets the
//! host process opens itself.
//!
//! To stay transparent to Discord, every function the real version.dll
//! exports is forwarded to it (resolved once at load, then a bare `jmp`).

#![allow(non_snake_case)]

use core::ffi::c_void;
use windows_sys::Win32::Foundation::{HMODULE, MAX_PATH};
use windows_sys::Win32::System::LibraryLoader::{GetProcAddress, LoadLibraryW};
use windows_sys::Win32::System::SystemInformation::GetSystemDirectoryW;

mod hooks;

// --- forwarding to the real version.dll ----------------------------------

/// The 15 functions the system version.dll exports, in a fixed order. Each
/// exported stub below jumps to REAL[its index].
const FORWARDS: [&[u8]; 15] = [
    b"GetFileVersionInfoA\0",
    b"GetFileVersionInfoByHandle\0",
    b"GetFileVersionInfoExA\0",
    b"GetFileVersionInfoExW\0",
    b"GetFileVersionInfoSizeA\0",
    b"GetFileVersionInfoSizeExA\0",
    b"GetFileVersionInfoSizeExW\0",
    b"GetFileVersionInfoSizeW\0",
    b"GetFileVersionInfoW\0",
    b"VerFindFileA\0",
    b"VerFindFileW\0",
    b"VerInstallFileA\0",
    b"VerInstallFileW\0",
    b"VerQueryValueA\0",
    b"VerQueryValueW\0",
];

/// Resolved addresses in the real version.dll, filled once at load. Read only
/// by the naked stubs after resolve_forwards() has run on PROCESS_ATTACH.
static mut REAL: [*const c_void; 15] = [core::ptr::null(); 15];

/// Each exported name is a thin stub that forwards to the real DLL. The stub
/// takes and returns nothing itself; the `jmp` hands the caller's registers
/// and stack straight to the real function, so its real signature is used.
macro_rules! forward {
    ($idx:literal, $name:ident) => {
        #[unsafe(naked)]
        #[no_mangle]
        pub unsafe extern "system" fn $name() {
            core::arch::naked_asm!(
                "jmp qword ptr [rip + {real} + {off}]",
                real = sym REAL,
                off = const $idx * core::mem::size_of::<*const c_void>(),
            );
        }
    };
}

forward!(0, GetFileVersionInfoA);
forward!(1, GetFileVersionInfoByHandle);
forward!(2, GetFileVersionInfoExA);
forward!(3, GetFileVersionInfoExW);
forward!(4, GetFileVersionInfoSizeA);
forward!(5, GetFileVersionInfoSizeExA);
forward!(6, GetFileVersionInfoSizeExW);
forward!(7, GetFileVersionInfoSizeW);
forward!(8, GetFileVersionInfoW);
forward!(9, VerFindFileA);
forward!(10, VerFindFileW);
forward!(11, VerInstallFileA);
forward!(12, VerInstallFileW);
forward!(13, VerQueryValueA);
forward!(14, VerQueryValueW);

/// Load the genuine version.dll from the system directory (never from next to
/// Discord.exe, which is this DLL) and resolve every forwarded function.
/// Returns false if the DLL or any export is missing, in which case this DLL
/// must not stay loaded — Discord would call a null forwarder and crash.
unsafe fn resolve_forwards() -> bool {
    let mut path = [0u16; MAX_PATH as usize + 16];
    let len = GetSystemDirectoryW(path.as_mut_ptr(), MAX_PATH) as usize;
    if len == 0 || len > MAX_PATH as usize {
        return false;
    }
    // Append "\version.dll\0".
    for (i, c) in "\\version.dll\0".encode_utf16().enumerate() {
        path[len + i] = c;
    }

    let real: HMODULE = LoadLibraryW(path.as_ptr());
    if real.is_null() {
        return false;
    }
    for (i, name) in FORWARDS.iter().enumerate() {
        match GetProcAddress(real, name.as_ptr()) {
            Some(f) => REAL[i] = f as *const c_void,
            None => return false,
        }
    }
    true
}

// --- shared state: the contract with the GoLiveFix plugin -----------------
//
// One file, which the plugin rewrites atomically:
//
//   %APPDATA%\<exe name, lowercased>\goLiveFix\state
//
// i.e. the plugin's folder in Electron's userData (Discord.exe → discord,
// DiscordPTB.exe → discordptb). It holds the mode, "arm" / "keep" / "disarm",
// then, unless disarmed, the tunnel's local IPv4 that new sockets are bound to
// so the OS routes them over the tunnel: "arm 10.2.0.2". It's read fresh on
// each new socket, so a change takes effect on the next connection and never
// disturbs ones already open. No file, or disarm => fully passive.
//
// The hooks are installed in every Discord process that loads this DLL,
// launched into the tunnel or not, so a running Discord can enter the tunnel
// with just a UI reload: no restart once this DLL is in place.
//
// Overrides for test harnesses: GOLIVEFIX_STATE (another state file) and
// GOLIVEFIX_TUNNEL_IP (the address, when the file holds only the mode).
//
// Mirrors the Linux side's DCVPN_STATE file and wg0 address, minus the
// privileged supervisor: here steering is a per-socket bind in-process, so no
// FIFO and no privilege are needed — reading the file is the whole mechanism.

mod state {
    use std::net::Ipv4Addr;
    use std::path::{Path, PathBuf};
    use std::sync::OnceLock;

    #[derive(Clone, Copy, PartialEq, Eq, Debug)]
    pub enum Mode {
        /// Every new connection binds to the tunnel.
        Arm,
        /// Only new UDP (voice/Go Live) binds to the tunnel; TCP goes direct.
        Keep,
        /// Nothing new is bound; everything goes direct.
        Disarm,
    }

    struct Overrides {
        tunnel_ip: Option<Ipv4Addr>,
        state_path: Option<PathBuf>,
        appdata: Option<PathBuf>,
    }

    static OVERRIDES: OnceLock<Overrides> = OnceLock::new();
    static STATE_PATH: OnceLock<Option<PathBuf>> = OnceLock::new();

    /// Read the environment once. Safe to call from DllMain: it only touches
    /// the process environment block, no file or library work under the
    /// loader lock. The state file is found and read later, per socket.
    pub fn init() {
        let _ = OVERRIDES.set(Overrides {
            tunnel_ip: std::env::var("GOLIVEFIX_TUNNEL_IP").ok().and_then(|s| s.parse().ok()),
            state_path: std::env::var_os("GOLIVEFIX_STATE").map(PathBuf::from),
            appdata: std::env::var_os("APPDATA").map(PathBuf::from),
        });
    }

    /// The state file, resolved on first use (never in DllMain: it asks the
    /// loader for the exe's name).
    fn state_path() -> Option<&'static Path> {
        STATE_PATH
            .get_or_init(|| {
                let o = OVERRIDES.get()?;
                if let Some(p) = &o.state_path {
                    return Some(p.clone());
                }
                let exe = std::env::current_exe().ok()?;
                let name = exe.file_stem()?.to_string_lossy().to_lowercase();
                Some(o.appdata.as_ref()?.join(name).join("goLiveFix").join("state"))
            })
            .as_deref()
    }

    /// What new sockets should do right now: the mode and the address to bind
    /// to, or None for "leave everything alone" (disarmed, no address, missing
    /// or unreadable file — anything unexpected fails safe to "go direct").
    pub fn current() -> Option<(Mode, Ipv4Addr)> {
        let bytes = std::fs::read(state_path()?).ok()?;
        let (mode, file_ip) = parse(&bytes);
        let ip = OVERRIDES.get().and_then(|o| o.tunnel_ip).or(file_ip)?;
        (mode != Mode::Disarm).then_some((mode, ip))
    }

    /// "<mode> [<ipv4>]", whitespace-delimited. Tolerates a trailing newline
    /// and stray surrounding whitespace; an unknown mode is Disarm.
    fn parse(bytes: &[u8]) -> (Mode, Option<Ipv4Addr>) {
        let mut tokens = bytes.split(|b| b.is_ascii_whitespace()).filter(|t| !t.is_empty());
        let mode = match tokens.next().unwrap_or(b"") {
            b"arm" => Mode::Arm,
            b"keep" => Mode::Keep,
            _ => Mode::Disarm,
        };
        let ip = tokens.next().and_then(|t| std::str::from_utf8(t).ok()?.parse().ok());
        (mode, ip)
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        const IP: Ipv4Addr = Ipv4Addr::new(10, 2, 0, 2);

        #[test]
        fn parses_each_mode() {
            assert_eq!(parse(b"arm"), (Mode::Arm, None));
            assert_eq!(parse(b"keep"), (Mode::Keep, None));
            assert_eq!(parse(b"disarm"), (Mode::Disarm, None));
        }

        #[test]
        fn parses_the_address() {
            assert_eq!(parse(b"arm 10.2.0.2"), (Mode::Arm, Some(IP)));
            assert_eq!(parse(b"keep 10.2.0.2\n"), (Mode::Keep, Some(IP)));
            assert_eq!(parse(b"arm not-an-ip"), (Mode::Arm, None));
        }

        #[test]
        fn tolerates_whitespace_and_newlines() {
            assert_eq!(parse(b"arm\n").0, Mode::Arm);
            assert_eq!(parse(b"  keep \r\n").0, Mode::Keep);
            assert_eq!(parse(b"\r\narm\r\n10.2.0.2\r\n"), (Mode::Arm, Some(IP)));
        }

        #[test]
        fn unknown_or_empty_is_disarm() {
            assert_eq!(parse(b"").0, Mode::Disarm);
            assert_eq!(parse(b"   ").0, Mode::Disarm);
            assert_eq!(parse(b"garbage 10.2.0.2").0, Mode::Disarm);
        }
    }
}

// --- entry point ----------------------------------------------------------

const DLL_PROCESS_ATTACH: u32 = 1;

#[no_mangle]
pub extern "system" fn DllMain(_module: HMODULE, reason: u32, _reserved: *mut c_void) -> i32 {
    if reason == DLL_PROCESS_ATTACH {
        // Forwarding must work before anything else; if it can't, fail the
        // load rather than leave Discord with dead version.dll exports.
        if unsafe { !resolve_forwards() } {
            return 0;
        }
        state::init();
        // Hook always: the hooks stay passive until the state file says
        // otherwise, so a Discord started normally can still be steered later.
        // Install off the loader lock (hooking calls LoadLibrary/VirtualProtect):
        // the spawned thread's body runs only after DllMain returns. Builder,
        // not thread::spawn: a failed spawn must leave Discord unhooked, not
        // panic (and so abort) inside its loader.
        let _ = std::thread::Builder::new().spawn(|| unsafe { hooks::install() });
    }
    1
}
