//! Winsock hooks that bind Discord's own new sockets to the tunnel.
//!
//! Inline-detour (via `retour`) four ws2_32 entry points, so every caller is
//! caught no matter how it resolved the function — the native voice engine
//! included, which is the whole reason a proxy isn't enough:
//!
//!   bind       Chromium binds TCP sockets (ConnectEx requires it) and its UDP
//!              sockets to the wildcard before use. The hook rewrites that
//!              wildcard to the tunnel IP, which steers them — and covers the
//!              ConnectEx path without hooking ConnectEx itself.
//!   connect    Sockets that connect without an explicit bind (e.g. the voice
//!              engine) are bound to the tunnel IP first, if still unbound.
//!   sendto     Same bind-if-unbound for UDP that sends without connecting.
//!   WSASendTo
//!
//! What "steer" means per mode (state::current): arm binds every new socket;
//! keep binds only UDP (voice/Go Live); disarm binds nothing. A socket already
//! bound is never rebound, so switching modes never disturbs a live connection
//! — it only changes what new sockets get, exactly like the Linux side.
//!
//! Local destinations (loopback, LAN, link-local, multicast) are unreachable
//! from the tunnel address, so connect/sendto never bind sockets headed there.
//! bind can't tell (no destination yet), so a wildcard bind later used for a
//! local destination is still a known gap.
//!
//! IPv6: the tunnel carries IPv4 only (no v6 route on it), so a socket the mode
//! wants tunneled can't go out over v6. Rather than let it slip out direct, the
//! hook refuses it, and Discord falls back to v4, which it tunnels — the
//! Windows take on the Linux namespace having no IPv6 at all. Concretely, for
//! such a socket:
//!   - a native v6 destination fails with WSAENETUNREACH;
//!   - a v4-mapped destination (dual-stack socket) is v4: bound to the tunnel's
//!     v4-mapped address, like any v4 socket;
//!   - a `::` wildcard bind becomes the tunnel's v4-mapped address, so a
//!     dual-stack socket reaches v4 through the tunnel and the OS refuses its
//!     v6 sends, while a v6-only socket fails to bind (WSAEADDRNOTAVAIL).
//!
//! v6 the mode doesn't want tunneled (disarm, keep's TCP) is left alone.
//!
//! Failure: when binding to the tunnel fails (e.g. the tunnel went down and its
//! address with it), the app's call fails with that error instead of quietly
//! going direct — fail closed, like the Linux side, where armed traffic dies
//! with wg0. Switching to disarm is the way back.

use core::ffi::c_void;
use core::mem::{size_of, transmute_copy, zeroed};
use std::net::{Ipv4Addr, Ipv6Addr};
use std::sync::OnceLock;

use retour::{Function, GenericDetour};
use windows_sys::Win32::Networking::WinSock::{
    getsockname, getsockopt, WSAGetLastError, WSASetLastError, SOCKADDR, SOCKADDR_IN,
    SOCKADDR_IN6, SOCKADDR_STORAGE, WSABUF,
};
use windows_sys::Win32::System::LibraryLoader::{GetProcAddress, LoadLibraryA};

use crate::state::{self, Mode};

type Socket = usize;

// ws2_32 signatures (from windows-sys). The two trailing WSASendTo pointers
// (OVERLAPPED, completion routine) are opaque to the hooks, which only pass
// them on.
type BindFn = unsafe extern "system" fn(Socket, *const SOCKADDR, i32) -> i32;
type ConnectFn = BindFn;
type SendtoFn = unsafe extern "system" fn(Socket, *const u8, i32, i32, *const SOCKADDR, i32) -> i32;
type WsaSendToFn = unsafe extern "system" fn(
    Socket, *const WSABUF, u32, *mut u32, u32, *const SOCKADDR, i32, *mut c_void, *const c_void,
) -> i32;

// Values from winsock2.h, spelled out to avoid typed-constant friction.
const AF_INET: u16 = 2;
const AF_INET6: u16 = 23;
const SOCK_DGRAM: i32 = 2;
const SOL_SOCKET: i32 = 0xffff;
const SO_TYPE: i32 = 0x1008;
const SOCKET_ERROR: i32 = -1;
const WSAEINVAL: i32 = 10022;
const WSAENETUNREACH: i32 = 10051;

/// A detour installed once (on the hook thread) then only called. Sound to
/// share because `set` happens before `enable`, and detours merely read it.
struct Detour<T: Function>(OnceLock<GenericDetour<T>>);
unsafe impl<T: Function> Sync for Detour<T> {}
impl<T: Function> Detour<T> {
    const fn new() -> Self {
        Self(OnceLock::new())
    }
    /// Create, store, and enable a detour of `name` in the given module.
    unsafe fn install(&self, module: *mut c_void, name: &core::ffi::CStr, detour: T) {
        let Some(target) = GetProcAddress(module, name.as_ptr() as *const u8) else { return };
        // target is a pointer-sized FARPROC; transmute_copy to the fn type T
        // (plain transmute can't see T's size through the generic).
        let Ok(hook) = GenericDetour::new(transmute_copy(&target), detour) else { return };
        if self.0.set(hook).is_ok() {
            let _ = self.0.get().unwrap().enable();
        }
    }
    /// The original function. Only valid after a successful install().
    fn original(&self) -> &GenericDetour<T> {
        self.0.get().expect("detour called before install")
    }
}

static BIND: Detour<BindFn> = Detour::new();
static CONNECT: Detour<ConnectFn> = Detour::new();
static SENDTO: Detour<SendtoFn> = Detour::new();
static WSASENDTO: Detour<WsaSendToFn> = Detour::new();

/// Detour each function if ws2_32 and the export are present. Runs on a thread
/// off DllMain (never under the loader lock), in every process that loads the
/// DLL; the detours pass straight through until the state file arms them.
/// Failures are left un-hooked rather than crashing Discord.
pub unsafe fn install() {
    let ws2 = LoadLibraryA(c"ws2_32.dll".as_ptr() as *const u8);
    if ws2.is_null() {
        return;
    }
    BIND.install(ws2, c"bind", bind_detour);
    CONNECT.install(ws2, c"connect", connect_detour);
    SENDTO.install(ws2, c"sendto", sendto_detour);
    WSASENDTO.install(ws2, c"WSASendTo", wsasendto_detour);
}

// --- detours --------------------------------------------------------------

unsafe extern "system" fn bind_detour(s: Socket, name: *const SOCKADDR, namelen: i32) -> i32 {
    let wildcard = wildcard_of(name, namelen);
    if let Some((mode, ip)) = wildcard.and_then(|_| state::current()) {
        if want_tunnel(mode, sock_type(s) == SOCK_DGRAM) {
            // Keep the app's port, just move it onto the tunnel address.
            return match wildcard {
                Some(Family::V4) => {
                    let mut repl = *(name as *const SOCKADDR_IN);
                    repl.sin_addr.S_un.S_addr = u32::from_ne_bytes(ip.octets());
                    BIND.original().call(s, &repl as *const _ as *const SOCKADDR, namelen)
                }
                _ => {
                    let mut repl = *(name as *const SOCKADDR_IN6);
                    repl.sin6_addr.u.Byte = ip.to_ipv6_mapped().octets();
                    repl.Anonymous.sin6_scope_id = 0;
                    BIND.original().call(s, &repl as *const _ as *const SOCKADDR, namelen)
                }
            };
        }
    }
    BIND.original().call(s, name, namelen)
}

unsafe extern "system" fn connect_detour(s: Socket, name: *const SOCKADDR, namelen: i32) -> i32 {
    // UDP connects too (connected sends), so ask the socket its type.
    if let Err(e) = steer(s, name, namelen, || sock_type(s) == SOCK_DGRAM) {
        WSASetLastError(e);
        return SOCKET_ERROR;
    }
    CONNECT.original().call(s, name, namelen)
}

unsafe extern "system" fn sendto_detour(
    s: Socket, buf: *const u8, len: i32, flags: i32, to: *const SOCKADDR, tolen: i32,
) -> i32 {
    if let Err(e) = steer(s, to, tolen, || true) {
        WSASetLastError(e);
        return SOCKET_ERROR;
    }
    SENDTO.original().call(s, buf, len, flags, to, tolen)
}

unsafe extern "system" fn wsasendto_detour(
    s: Socket, bufs: *const WSABUF, count: u32, sent: *mut u32, flags: u32,
    to: *const SOCKADDR, tolen: i32, ovl: *mut c_void, cr: *const c_void,
) -> i32 {
    // Failing before the real call posts no completion, so a synchronous
    // error is correct for overlapped callers too.
    if let Err(e) = steer(s, to, tolen, || true) {
        WSASetLastError(e);
        return SOCKET_ERROR;
    }
    WSASENDTO.original().call(s, bufs, count, sent, flags, to, tolen, ovl, cr)
}

// --- steering -------------------------------------------------------------

fn want_tunnel(mode: Mode, is_udp: bool) -> bool {
    match mode {
        Mode::Arm => true,
        Mode::Keep => is_udp,
        Mode::Disarm => false,
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Family {
    V4,
    V6,
}

/// Where a socket is headed, as far as steering cares.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Dest {
    /// Nothing to steer: no usable address (null, another family, `len` too
    /// short), or a local one the tunnel can't reach.
    Leave,
    /// A remote IPv4 host, written as a plain v4 address or (`Family::V6`) as
    /// a v4-mapped one on a dual-stack socket. Reachable through the tunnel.
    V4(Family),
    /// A remote native IPv6 host. The tunnel has no v6 route.
    V6,
}

/// For a socket the mode wants tunneled and that isn't bound yet: bind it to
/// the tunnel (v4 destinations) or refuse it (v6 ones). Cheap checks come
/// first, so a socket that's already bound skips the per-packet state read on
/// sendto. `is_udp` is lazy because asking the socket costs a syscall that's
/// usually not needed. Err carries the WSA error the app's call must fail with.
unsafe fn steer(
    s: Socket, dest: *const SOCKADDR, destlen: i32, is_udp: impl FnOnce() -> bool,
) -> Result<(), i32> {
    let dest = dest_of(dest, destlen);
    if dest == Dest::Leave || !is_unbound(s) {
        return Ok(());
    }
    let Some((mode, ip)) = state::current() else { return Ok(()) };
    if !want_tunnel(mode, is_udp()) {
        return Ok(());
    }
    match dest {
        Dest::V4(family) => bind_to_tunnel(s, ip, family),
        Dest::V6 => Err(WSAENETUNREACH),
        Dest::Leave => Ok(()),
    }
}

/// Bind `s` to the tunnel address on an ephemeral port, as a plain v4 address
/// or a v4-mapped v6 one to match the socket's family. Fails closed, except
/// for WSAEINVAL: that means another thread bound the socket since the check,
/// and an already-bound socket is never the hook's to steer.
unsafe fn bind_to_tunnel(s: Socket, ip: Ipv4Addr, family: Family) -> Result<(), i32> {
    let r = match family {
        Family::V4 => {
            let mut sa: SOCKADDR_IN = zeroed();
            sa.sin_family = AF_INET;
            sa.sin_addr.S_un.S_addr = u32::from_ne_bytes(ip.octets());
            BIND.original().call(s, &sa as *const _ as *const SOCKADDR, size_of::<SOCKADDR_IN>() as i32)
        }
        Family::V6 => {
            let mut sa: SOCKADDR_IN6 = zeroed();
            sa.sin6_family = AF_INET6;
            sa.sin6_addr.u.Byte = ip.to_ipv6_mapped().octets();
            BIND.original().call(s, &sa as *const _ as *const SOCKADDR, size_of::<SOCKADDR_IN6>() as i32)
        }
    };
    if r == 0 {
        return Ok(());
    }
    match WSAGetLastError() {
        WSAEINVAL => Ok(()),
        e => Err(e),
    }
}

/// Destinations a tunnel-bound socket can't reach: the strong-host model sends
/// from the tunnel IP only out the tunnel, so loopback fails outright
/// (WSAEADDRNOTAVAIL) and LAN hosts (e.g. the router's DNS) silently time out
/// — both confirmed. These keep going direct.
fn v4_is_local(d: Ipv4Addr) -> bool {
    d.is_loopback()
        || d.is_private()
        || d.is_link_local()
        || d.is_multicast()
        || d.is_broadcast()
        || d.is_unspecified()
}

/// The v6 counterparts: loopback, link-local, unique-local (the v6 LAN),
/// multicast. Refusing these would break local traffic for nothing.
fn v6_is_local(d: Ipv6Addr) -> bool {
    d.is_loopback()
        || d.is_unicast_link_local()
        || d.is_unique_local()
        || d.is_multicast()
        || d.is_unspecified()
}

fn classify_v4(d: Ipv4Addr, written_as: Family) -> Dest {
    if v4_is_local(d) { Dest::Leave } else { Dest::V4(written_as) }
}

fn classify_v6(d: Ipv6Addr) -> Dest {
    match d.to_ipv4_mapped() {
        Some(v4) => classify_v4(v4, Family::V6),
        None if v6_is_local(d) => Dest::Leave,
        None => Dest::V6,
    }
}

unsafe fn dest_of(sa: *const SOCKADDR, len: i32) -> Dest {
    match family_of(sa) {
        AF_INET if len >= size_of::<SOCKADDR_IN>() as i32 => {
            let addr = (*(sa as *const SOCKADDR_IN)).sin_addr.S_un.S_addr;
            classify_v4(Ipv4Addr::from(addr.to_ne_bytes()), Family::V4)
        }
        AF_INET6 if len >= size_of::<SOCKADDR_IN6>() as i32 => {
            classify_v6(Ipv6Addr::from((*(sa as *const SOCKADDR_IN6)).sin6_addr.u.Byte))
        }
        _ => Dest::Leave,
    }
}

/// The family of a wildcard bind address (`0.0.0.0` or `::`), None for any
/// other address or a sockaddr shorter than its family needs (the real call
/// rejects that itself; the hook just mustn't read past the caller's buffer).
unsafe fn wildcard_of(sa: *const SOCKADDR, len: i32) -> Option<Family> {
    match family_of(sa) {
        AF_INET if len >= size_of::<SOCKADDR_IN>() as i32 => {
            ((*(sa as *const SOCKADDR_IN)).sin_addr.S_un.S_addr == 0).then_some(Family::V4)
        }
        AF_INET6 if len >= size_of::<SOCKADDR_IN6>() as i32 => {
            ((*(sa as *const SOCKADDR_IN6)).sin6_addr.u.Byte == [0; 16]).then_some(Family::V6)
        }
        _ => None,
    }
}

// --- socket helpers -------------------------------------------------------

/// Address family of a sockaddr, 0 for a null pointer (connected-UDP sends).
unsafe fn family_of(sa: *const SOCKADDR) -> u16 {
    if sa.is_null() {
        0
    } else {
        (*sa).sa_family
    }
}

/// getsockname fails (WSAEINVAL) on an unbound socket; success means bound.
/// The buffer fits any family: a v6 name in a v4-sized one would fail too.
unsafe fn is_unbound(s: Socket) -> bool {
    let mut sa: SOCKADDR_STORAGE = zeroed();
    let mut len = size_of::<SOCKADDR_STORAGE>() as i32;
    getsockname(s, &mut sa as *mut _ as *mut SOCKADDR, &mut len) != 0
}

unsafe fn sock_type(s: Socket) -> i32 {
    let mut ty = 0i32;
    let mut len = size_of::<i32>() as i32;
    getsockopt(s, SOL_SOCKET, SO_TYPE, &mut ty as *mut i32 as *mut u8, &mut len);
    ty
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sin(ip: &str) -> SOCKADDR_IN {
        let mut sa: SOCKADDR_IN = unsafe { zeroed() };
        sa.sin_family = AF_INET;
        sa.sin_addr.S_un.S_addr = u32::from_ne_bytes(ip.parse::<Ipv4Addr>().unwrap().octets());
        sa
    }

    fn sin6(ip: &str) -> SOCKADDR_IN6 {
        let mut sa: SOCKADDR_IN6 = unsafe { zeroed() };
        sa.sin6_family = AF_INET6;
        sa.sin6_addr.u.Byte = ip.parse::<Ipv6Addr>().unwrap().octets();
        sa
    }

    fn dest<T>(sa: &T) -> Dest {
        unsafe { dest_of(sa as *const T as *const SOCKADDR, size_of::<T>() as i32) }
    }

    #[test]
    fn local_v4_destinations_are_left_alone() {
        for d in [
            "127.0.0.1", "192.168.50.1", "10.2.0.1", "172.16.0.1",
            "169.254.1.1", "224.0.0.251", "255.255.255.255", "0.0.0.0",
        ] {
            assert_eq!(dest(&sin(d)), Dest::Leave, "{d}");
        }
    }

    #[test]
    fn public_v4_destinations_are_tunneled() {
        for d in ["162.159.128.233", "1.1.1.1", "35.214.1.1"] {
            assert_eq!(dest(&sin(d)), Dest::V4(Family::V4), "{d}");
        }
    }

    #[test]
    fn v6_destinations() {
        assert_eq!(dest(&sin6("2606:4700:4700::1111")), Dest::V6);
        for d in ["::1", "fe80::1", "fd00::1", "ff02::fb", "::"] {
            assert_eq!(dest(&sin6(d)), Dest::Leave, "{d}");
        }
    }

    #[test]
    fn v4_mapped_destinations_count_as_v4() {
        assert_eq!(dest(&sin6("::ffff:1.1.1.1")), Dest::V4(Family::V6));
        assert_eq!(dest(&sin6("::ffff:127.0.0.1")), Dest::Leave);
        assert_eq!(dest(&sin6("::ffff:192.168.50.1")), Dest::Leave);
    }

    #[test]
    fn short_or_null_sockaddrs_are_left_alone() {
        unsafe {
            let v4 = sin("1.1.1.1");
            let v6 = sin6("2606:4700:4700::1111");
            let p4 = &v4 as *const _ as *const SOCKADDR;
            let p6 = &v6 as *const _ as *const SOCKADDR;
            assert_eq!(dest_of(p4, size_of::<SOCKADDR_IN>() as i32 - 1), Dest::Leave);
            assert_eq!(dest_of(p6, size_of::<SOCKADDR_IN>() as i32), Dest::Leave);
            assert_eq!(dest_of(core::ptr::null(), 28), Dest::Leave);
            assert_eq!(wildcard_of(p4, 8), None);
        }
    }

    #[test]
    fn wildcards() {
        unsafe {
            let w = |sa: *const SOCKADDR, len: usize| wildcard_of(sa, len as i32);
            let (a, b) = (sin("0.0.0.0"), sin("10.2.0.2"));
            assert_eq!(w(&a as *const _ as _, size_of::<SOCKADDR_IN>()), Some(Family::V4));
            assert_eq!(w(&b as *const _ as _, size_of::<SOCKADDR_IN>()), None);
            let (c, d) = (sin6("::"), sin6("::1"));
            assert_eq!(w(&c as *const _ as _, size_of::<SOCKADDR_IN6>()), Some(Family::V6));
            assert_eq!(w(&d as *const _ as _, size_of::<SOCKADDR_IN6>()), None);
        }
    }
}
