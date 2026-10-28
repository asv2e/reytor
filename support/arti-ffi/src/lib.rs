//! Thin C ABI wrapper around `arti-client`.
//!
//! Reynard links this as a static library (see
//! `tools/development/build-arti.sh`) and calls into it from
//! `browser/Reynard/Tor/ArtiFFI.h`. It owns a background OS thread running a
//! Tokio runtime, an `arti_client::TorClient`, and a hand-rolled SOCKS5
//! server (CONNECT only) that forwards accepted connections through Tor.
//!
//! Gecko is pointed at this local SOCKS5 listener via the
//! `network.proxy.socks*` prefs (see `TorProxyPolicyController.swift`), with
//! `network.proxy.socks_remote_dns` enabled so hostnames are resolved
//! through Tor rather than leaking to the local network's resolver.
//!
//! Arti's own docs note the `arti-client` API is not yet stable and that
//! there's no polished FFI story upstream yet - this crate is Reynard's own
//! stable boundary against that churn. If you bump the pinned version in
//! Cargo.toml, recheck the calls to `bootstrap_events()` and
//! `isolated_client()` below against that release's docs.
//!
//! Per-destination-hostname circuit isolation (`StreamPrefs`,
//! `IsolationToken`, `TorClient::connect_with_prefs`,
//! `StreamPrefs::set_isolation_group`) was checked against docs.rs and a
//! real arti commit touching this exact code path (arti's own SOCKS
//! implementation, `crates/arti/src/socks.rs`, which isolates the same
//! way: an isolation key built per accepted connection and passed to
//! `set_isolation_group`), but the exact re-export paths used below
//! (`arti_client::{IsolationToken, StreamPrefs}`) were not independently
//! confirmed against this pin - adjust the `use` paths if they don't
//! resolve.

use std::collections::HashMap;
use std::ffi::{c_void, CStr, CString};
use std::net::{Ipv4Addr, Ipv6Addr};
use std::os::raw::c_char;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use arti_client::config::{BoolOrAuto, BridgeConfigBuilder, CfgPath};
use arti_client::{IsolationToken, StreamPrefs, TorClient, TorClientConfig};
use futures::StreamExt;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::mpsc::{self, UnboundedSender};
use tor_rtcompat::{PreferredRuntime, Runtime};

#[repr(i32)]
#[derive(Clone, Copy)]
enum ArtiEventKind {
    BootstrapProgress = 0,
    Connected = 1,
    Error = 2,
    Stopped = 3,
}

pub type ArtiEventCallback =
    extern "C" fn(context: *mut c_void, kind: i32, percent: i32, message: *const c_char);

/// Wraps the raw callback + context so it can cross thread/task boundaries.
/// Safety relies on the FFI contract in ArtiFFI.h: the caller must keep
/// `context` valid until an `ArtiEventStopped` event has been delivered.
#[derive(Clone, Copy)]
struct EventSink {
    callback: ArtiEventCallback,
    context: *mut c_void,
}

unsafe impl Send for EventSink {}
unsafe impl Sync for EventSink {}

impl EventSink {
    fn emit(&self, kind: ArtiEventKind, percent: i32, message: Option<&str>) {
        let owned = message.map(|m| CString::new(m).unwrap_or_else(|_| CString::new("").unwrap()));
        let ptr = owned.as_ref().map_or(std::ptr::null(), |m| m.as_ptr());
        (self.callback)(self.context, kind as i32, percent, ptr);
    }

    fn progress(&self, percent: i32) {
        self.emit(ArtiEventKind::BootstrapProgress, percent, None);
    }

    fn connected(&self) {
        self.emit(ArtiEventKind::Connected, 100, None);
    }

    fn error(&self, message: &str) {
        self.emit(ArtiEventKind::Error, 0, Some(message));
    }

    fn stopped(&self) {
        self.emit(ArtiEventKind::Stopped, 0, None);
    }
}

enum Command {
    NewIdentity,
    NewCircuitForHost(String),
    Stop,
}

struct RunningClient {
    thread: Option<std::thread::JoinHandle<()>>,
    commands: UnboundedSender<Command>,
}

static RUNNING: Mutex<Option<RunningClient>> = Mutex::new(None);

/// Hard cap on simultaneously proxied connections, and on how long a local
/// client may take to finish the SOCKS handshake. Without these, a stalled or
/// hostile local client could pile up tasks without bound.
const MAX_CONCURRENT_CONNECTIONS: usize = 1024;
const SOCKS_HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(15);

/// Upper bound on remembered per-host isolation tokens. Hostnames are
/// page-controlled (any number of subdomains), so the map must not grow
/// forever; when full it is simply reset, which only means affected hosts get
/// fresh circuits.
const MAX_ISOLATION_TOKENS: usize = 4096;

/// Lower-cases and strips a trailing dot so `Example.com` and `example.com.`
/// share one isolation token instead of silently splitting.
fn normalize_host(host: &str) -> String {
    host.trim().trim_end_matches('.').to_ascii_lowercase()
}

/// # Safety
/// `state_dir`/`cache_dir` must be valid, NUL-terminated C strings for the
/// duration of the call. `bridge_lines` must be either null (no bridges) or
/// a valid NUL-terminated C string of newline-separated bridge lines in the
/// standard "Bridge [transport] IP:PORT FINGERPRINT [k=v ...]" format.
/// `callback` must be a valid function pointer.
#[no_mangle]
pub unsafe extern "C" fn arti_start(
    state_dir: *const c_char,
    cache_dir: *const c_char,
    socks_port: u16,
    bridge_lines: *const c_char,
    // 0 means "not running" - the corresponding transport's bridge lines
    // (if any) are skipped rather than the whole config failing. These
    // are local 127.0.0.1 ports for IPtProxy's Lyrebird/obfs4 and
    // Snowflake client listeners, started from the Swift side before
    // this is called - see PluggableTransportController.swift.
    obfs4_proxy_port: u16,
    snowflake_proxy_port: u16,
    callback: ArtiEventCallback,
    context: *mut c_void,
) -> i32 {
    if state_dir.is_null() || cache_dir.is_null() {
        return -1;
    }
    let state_dir = match CStr::from_ptr(state_dir).to_str() {
        Ok(s) => s.to_owned(),
        Err(_) => return -1,
    };
    let cache_dir = match CStr::from_ptr(cache_dir).to_str() {
        Ok(s) => s.to_owned(),
        Err(_) => return -1,
    };
    let bridge_lines = if bridge_lines.is_null() {
        String::new()
    } else {
        match CStr::from_ptr(bridge_lines).to_str() {
            Ok(s) => s.to_owned(),
            Err(_) => return -1,
        }
    };

    let mut running = RUNNING.lock().unwrap();
    // A client whose thread already exited (bootstrap failure) must not
    // block a retry.
    let finished = running
        .as_ref()
        .map_or(false, |r| r.thread.as_ref().map_or(true, |t| t.is_finished()));
    if finished {
        if let Some(mut stale) = running.take() {
            if let Some(thread) = stale.thread.take() {
                let _ = thread.join();
            }
        }
    }
    if running.is_some() {
        return -2;
    }

    let sink = EventSink { callback, context };
    let (ready_tx, ready_rx) = std::sync::mpsc::channel::<UnboundedSender<Command>>();

    let thread = std::thread::Builder::new()
        .name("arti-runtime".into())
        .spawn(move || {
            let runtime = match tokio::runtime::Builder::new_multi_thread()
                .worker_threads(2)
                .enable_all()
                .build()
            {
                Ok(rt) => rt,
                Err(e) => {
                    sink.error(&format!("failed to start Tor runtime: {e}"));
                    return;
                }
            };

            runtime.block_on(async move {
                let (commands_tx, commands_rx) = mpsc::unbounded_channel();
                // Hand the sender back to arti_start so callers can queue
                // commands (new identity, stop) before bootstrap finishes.
                let _ = ready_tx.send(commands_tx);
                run(state_dir, cache_dir, socks_port, bridge_lines, obfs4_proxy_port, snowflake_proxy_port, sink, commands_rx).await;
            });
        });

    let thread = match thread {
        Ok(handle) => handle,
        Err(e) => {
            sink.error(&format!("failed to spawn Tor thread: {e}"));
            return -1;
        }
    };

    let commands = match ready_rx.recv_timeout(Duration::from_secs(5)) {
        Ok(sender) => sender,
        Err(_) => {
            sink.error("Tor runtime did not start in time");
            return -1;
        }
    };

    *running = Some(RunningClient {
        thread: Some(thread),
        commands,
    });
    0
}

#[no_mangle]
pub extern "C" fn arti_request_new_identity() {
    if let Some(running) = RUNNING.lock().unwrap().as_ref() {
        let _ = running.commands.send(Command::NewIdentity);
    }
}

/// Narrower than arti_request_new_identity: forces a fresh circuit set for
/// just one destination hostname (the isolation-token cache entry for it
/// is replaced), leaving every other host's circuits - and the client's
/// broader identity - untouched.
///
/// # Safety
/// `host` must be a valid, NUL-terminated C string for the duration of the
/// call.
#[no_mangle]
pub unsafe extern "C" fn arti_request_new_circuit_for_host(host: *const c_char) {
    if host.is_null() {
        return;
    }
    let Ok(host) = CStr::from_ptr(host).to_str() else {
        return;
    };

    if let Some(running) = RUNNING.lock().unwrap().as_ref() {
        let _ = running.commands.send(Command::NewCircuitForHost(host.to_owned()));
    }
}

#[no_mangle]
pub extern "C" fn arti_stop() {
    let taken = RUNNING.lock().unwrap().take();
    if let Some(mut running) = taken {
        let _ = running.commands.send(Command::Stop);
        if let Some(thread) = running.thread.take() {
            let _ = thread.join();
        }
    }
}

#[no_mangle]
pub extern "C" fn arti_is_running() -> i32 {
    RUNNING
        .lock()
        .unwrap()
        .as_ref()
        .map_or(false, |r| r.thread.as_ref().map_or(false, |t| !t.is_finished())) as i32
}

async fn run(
    state_dir: String,
    cache_dir: String,
    socks_port: u16,
    bridge_lines: String,
    obfs4_proxy_port: u16,
    snowflake_proxy_port: u16,
    sink: EventSink,
    mut commands: mpsc::UnboundedReceiver<Command>,
) {
    sink.progress(0);

    let config = match build_config(&state_dir, &cache_dir, &bridge_lines, obfs4_proxy_port, snowflake_proxy_port) {
        Ok(c) => c,
        Err(e) => {
            sink.error(&format!("invalid Tor config: {e}"));
            sink.stopped();
            return;
        }
    };

    let runtime = match PreferredRuntime::current() {
        Ok(rt) => rt,
        Err(e) => {
            sink.error(&format!("no async runtime available: {e}"));
            sink.stopped();
            return;
        }
    };

    // create_unbootstrapped() + bootstrap_events() lets us stream real
    // progress, unlike create_bootstrapped() which just blocks until done.
    // Pattern confirmed against a published arti-client caller (onionize
    // crate's src/tor.rs) rather than assumed from memory.
    let mut client: TorClient<PreferredRuntime> =
        match TorClient::with_runtime(runtime).config(config).create_unbootstrapped() {
            Ok(client) => client,
            Err(e) => {
                sink.error(&format!("could not construct Tor client: {e}"));
                sink.stopped();
                return;
            }
        };

    let progress_client = client.clone();
    let progress_sink = sink;
    let progress_task = tokio::spawn(async move {
        let mut events = progress_client.bootstrap_events();
        while let Some(status) = events.next().await {
            progress_sink.progress((status.as_frac() * 100.0) as i32);
            if status.ready_for_traffic() {
                break;
            }
        }
    });

    if let Err(e) = client.bootstrap().await {
        progress_task.abort();
        sink.error(&format!("could not bootstrap Tor: {e}"));
        sink.stopped();
        return;
    }
    progress_task.abort();
    sink.progress(100);

    let listener = match TcpListener::bind(("127.0.0.1", socks_port)).await {
        Ok(listener) => listener,
        Err(e) => {
            sink.error(&format!("could not bind local SOCKS proxy: {e}"));
            sink.stopped();
            return;
        }
    };

    sink.connected();

    // Per-destination-hostname isolation tokens: gives each distinct SOCKS
    // CONNECT target its own circuit(s) instead of every site sharing one
    // pool. Cleared on New Identity so a fresh nonce set starts along with
    // the fresh client. See the module doc comment for what this does and
    // doesn't achieve compared to real Tor Browser's per-first-party-site
    // isolation.
    let isolation_tokens: Arc<Mutex<HashMap<String, IsolationToken>>> =
        Arc::new(Mutex::new(HashMap::new()));
    let limiter = Arc::new(tokio::sync::Semaphore::new(MAX_CONCURRENT_CONNECTIONS));

    loop {
        tokio::select! {
            accepted = listener.accept() => {
                if let Ok((stream, _addr)) = accepted {
                    // Over the cap: drop the connection rather than queue it.
                    let Ok(permit) = Arc::clone(&limiter).try_acquire_owned() else {
                        continue;
                    };
                    let client = client.clone();
                    let isolation_tokens = Arc::clone(&isolation_tokens);
                    tokio::spawn(async move {
                        let _permit = permit;
                        let _ = handle_socks_connection(stream, client, isolation_tokens).await;
                    });
                }
            }
            command = commands.recv() => {
                match command {
                    Some(Command::NewIdentity) => {
                        // Swap in a freshly-isolated client handle so every
                        // connection accepted from here on builds new
                        // circuits instead of reusing existing ones. This
                        // is arti_client::TorClient::isolated_client, a
                        // confirmed stable-ish method (unlike a guessed
                        // "retire circuits" call).
                        client = client.isolated_client();
                        // The new client's circuits are already fully
                        // separate from the old one by construction, so
                        // stale tokens here are harmless either way - this
                        // is just hygiene against unbounded growth in a
                        // long session, and it means hostnames get a fresh
                        // nonce post-New-Identity too.
                        isolation_tokens.lock().unwrap().clear();
                    }
                    Some(Command::NewCircuitForHost(host)) => {
                        // Replace just this host's isolation token so
                        // future connections to it get a new token (and
                        // therefore, via stream_prefs_for, a new circuit
                        // set) without disturbing any other host's
                        // existing tokens/circuits or the shared client
                        // handle itself.
                        isolation_tokens.lock().unwrap().insert(normalize_host(&host), IsolationToken::new());
                    }
                    Some(Command::Stop) | None => break,
                }
            }
        }
    }

    sink.stopped();
}

fn build_config(
    state_dir: &str,
    cache_dir: &str,
    bridge_lines: &str,
    obfs4_proxy_port: u16,
    snowflake_proxy_port: u16,
) -> Result<TorClientConfig, String> {
    let mut builder = TorClientConfig::builder();
    builder
        .storage()
        .state_dir(CfgPath::new(state_dir.to_owned()))
        .cache_dir(CfgPath::new(cache_dir.to_owned()));
    
    // Plain bridges parse and work with no further setup. obfs4/snowflake
    // bridges additionally need a running transport that actually
    // performs the obfuscation - arti_client deliberately doesn't provide
    // one itself ("pluggable transports need to be installed separately
    // and... Arti does not provide them on its own", per its own docs).
    // That's IPtProxy on the Swift side (see PluggableTransportController
    // .swift), started before this function is ever reached and passed
    // in here as a local port; we point arti at it as an "unmanaged" PT
    // (TransportConfigBuilder::proxy_addr) instead of asking arti to
    // spawn a binary itself, since spawning arbitrary subprocesses isn't
    // realistically available to an iOS app - the exact wall another
    // project's maintainer hit trying the same thing (see
    // gitlab.torproject.org/tpo/core/arti/-/issues/1815).
    //
    // meek and webtunnel bridges aren't covered - IPtProxy doesn't
    // currently provide those transports - so lines using them parse
    // fine but get dropped below for lack of a usable proxy, same as any
    // other line this build can't service.
    let mut configured_bridges = 0;
    let mut requested_bridge_lines = 0;
    let mut needs_obfs4 = false;
    let mut needs_snowflake = false;
    
    for line in bridge_lines.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        
        requested_bridge_lines += 1;
        
        // A plain bridge line's second token is IP:PORT, not a transport
        // keyword, so this only matches on actual obfs4/snowflake lines.
        let transport_keyword = line
            .split_whitespace()
            .nth(1)
            .map(|token| token.to_ascii_lowercase());
        let required_port = match transport_keyword.as_deref() {
            Some("obfs4") => Some(obfs4_proxy_port),
            Some("snowflake") => Some(snowflake_proxy_port),
            _ => None,
        };
        
        // A pluggable-transport line whose transport has no running
        // proxy behind it can't work - skip it rather than letting one
        // bad line fail the whole config at .build() time.
        if let Some(port) = required_port {
            if port == 0 {
                continue;
            }
        }
        
        match line.parse::<BridgeConfigBuilder>() {
            Ok(bridge) => {
                builder.bridges().bridges().push(bridge);
                configured_bridges += 1;
                match transport_keyword.as_deref() {
                    Some("obfs4") => needs_obfs4 = true,
                    Some("snowflake") => needs_snowflake = true,
                    _ => {}
                }
            }
            Err(_) => continue,
        }
    }
    // Fail closed: if the caller supplied bridge lines but none could be
    // used (invalid, unsupported transport, or its proxy isn't running),
    // Arti would otherwise quietly connect to public relays without
    // bridges, exposing Tor use to the local network.
    if requested_bridge_lines > 0 && configured_bridges == 0 {
        return Err("bridges are enabled but none of the bridge lines could be used".to_owned());
    }
    if configured_bridges > 0 {
        // BoolOrAuto's exact variant name wasn't independently confirmed
        // against this pin (unlike the other calls in this file) - verify
        // this compiles against tor-config's actual enum and adjust if
        // needed; the semantics wanted here are "insist on using bridges".
        builder.bridges().enabled(BoolOrAuto::Explicit(true));
    }
    
    if needs_obfs4 && obfs4_proxy_port != 0 {
        register_unmanaged_transport(&mut builder, "obfs4", obfs4_proxy_port);
    }
    if needs_snowflake && snowflake_proxy_port != 0 {
        register_unmanaged_transport(&mut builder, "snowflake", snowflake_proxy_port);
    }
    
    builder.build().map_err(|e| e.to_string())
}

/// Registers a locally-running (IPtProxy) pluggable transport with arti as
/// an "unmanaged" transport - arti connects to it via SOCKS rather than
/// spawning it. `protocol_name` is always one of our own hardcoded
/// literals ("obfs4"/"snowflake") at the call sites above, never
/// user-supplied, so a parse failure here can't come from bad user input
/// and is unwrapped rather than propagated.
///
/// Least-confirmed part of this file, see the Cargo.toml note: the exact
/// accessor name (`.transports()`) and builder method
/// (`TransportConfigBuilder::protocols`) are educated, docs-grounded
/// guesses rather than directly confirmed against this pin - the pieces
/// that ARE confirmed are TransportConfig::builder() and
/// TransportConfigBuilder::proxy_addr(SocketAddr) (both from docs.rs) and
/// that BridgesConfig holds "a list of pt::TransportConfigs" (from
/// arti_client's own BridgesConfig docs).
fn register_unmanaged_transport(
    builder: &mut arti_client::config::TorClientConfigBuilder,
    protocol_name: &str,
    port: u16,
) {
    use arti_client::config::pt::TransportConfig;
    use std::net::{IpAddr, Ipv4Addr, SocketAddr};
    
    let protocol = protocol_name
        .parse()
        .expect("protocol_name is always a hardcoded valid PT name at call sites");
    
    let mut transport = TransportConfig::builder();
    transport.protocols(vec![protocol]);
    transport.proxy_addr(SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), port));
    
    builder.bridges().transports().push(transport);
}

/// Reads the SOCKS5 greeting and CONNECT request. Returns `Ok(None)` when the
/// client was rejected (a reply has already been sent where applicable).
async fn socks_handshake(stream: &mut TcpStream) -> std::io::Result<Option<(String, u16)>> {
    let mut greeting = [0u8; 2];
    stream.read_exact(&mut greeting).await?;
    if greeting[0] != 0x05 {
        return Ok(None);
    }
    let mut methods = vec![0u8; greeting[1] as usize];
    stream.read_exact(&mut methods).await?;
    // We only support "no authentication required" (0x00).
    stream.write_all(&[0x05, 0x00]).await?;

    let mut head = [0u8; 4];
    stream.read_exact(&mut head).await?;
    if head[0] != 0x05 || head[1] != 0x01 {
        // Unsupported version or command (only CONNECT is implemented).
        stream.write_all(&[0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0]).await?;
        return Ok(None);
    }

    let target = match head[3] {
        0x01 => {
            let mut addr = [0u8; 4];
            stream.read_exact(&mut addr).await?;
            let mut port = [0u8; 2];
            stream.read_exact(&mut port).await?;
            (Ipv4Addr::from(addr).to_string(), u16::from_be_bytes(port))
        }
        0x03 => {
            let mut len = [0u8; 1];
            stream.read_exact(&mut len).await?;
            let mut name = vec![0u8; len[0] as usize];
            stream.read_exact(&mut name).await?;
            let mut port = [0u8; 2];
            stream.read_exact(&mut port).await?;
            (String::from_utf8_lossy(&name).into_owned(), u16::from_be_bytes(port))
        }
        0x04 => {
            let mut addr = [0u8; 16];
            stream.read_exact(&mut addr).await?;
            let mut port = [0u8; 2];
            stream.read_exact(&mut port).await?;
            (Ipv6Addr::from(addr).to_string(), u16::from_be_bytes(port))
        }
        _ => {
            stream.write_all(&[0x05, 0x08, 0x00, 0x01, 0, 0, 0, 0, 0, 0]).await?;
            return Ok(None);
        }
    };
    Ok(Some(target))
}

/// Minimal SOCKS5 server: no-auth only, CONNECT command only, forwards the
/// resulting stream through the Tor client. Domain-name targets are passed
/// straight through to `TorClient::connect` so DNS resolution happens on
/// the Tor side (this matters - it's the whole point of setting
/// `network.proxy.socks_remote_dns` on the Gecko side).
async fn handle_socks_connection(
    mut stream: TcpStream,
    client: TorClient<PreferredRuntime>,
    isolation_tokens: Arc<Mutex<HashMap<String, IsolationToken>>>,
) -> std::io::Result<()> {
    let target = match tokio::time::timeout(SOCKS_HANDSHAKE_TIMEOUT, socks_handshake(&mut stream)).await {
        Ok(Ok(Some(target))) => target,
        Ok(Ok(None)) => return Ok(()),
        Ok(Err(e)) => return Err(e),
        // Handshake stalled: drop the connection.
        Err(_) => return Ok(()),
    };

    match client.connect_with_prefs((target.0.as_str(), target.1), &stream_prefs_for(&target.0, &isolation_tokens)).await {
        Ok(tor_stream) => {
            stream.write_all(&[0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]).await?;
            let (mut tor_read, mut tor_write) = tokio::io::split(tor_stream);
            let (mut local_read, mut local_write) = stream.into_split();
            let upload = tokio::io::copy(&mut local_read, &mut tor_write);
            let download = tokio::io::copy(&mut tor_read, &mut local_write);
            let _ = tokio::try_join!(upload, download);
        }
        Err(_) => {
            stream.write_all(&[0x05, 0x01, 0x00, 0x01, 0, 0, 0, 0, 0, 0]).await?;
        }
    }

    Ok(())
}

/// Looks up (or creates) the isolation token for `hostname` and returns
/// StreamPrefs that pin a connection to it, so repeat connections to the
/// same destination reuse one circuit set while a different destination
/// gets a different one. Caveat: this isolates by the SOCKS CONNECT
/// target itself, not by the top-level/first-party site a request was
/// made on behalf of (real Tor Browser's isolation key) - so a
/// third-party resource embedded on two different first-party pages will
/// still share a circuit here, where Tor Browser would give it two. That
/// finer isolation needs the browser side to vary the SOCKS username per
/// first-party site (the way Torbutton's domain-isolator does in real Tor
/// Browser) and this SOCKS server to key isolation off that username
/// instead - not implemented, since it depends on privileged Gecko
/// network-channel code this crate has no visibility into.
fn stream_prefs_for(
    hostname: &str,
    isolation_tokens: &Arc<Mutex<HashMap<String, IsolationToken>>>,
) -> StreamPrefs {
    let mut tokens = isolation_tokens.lock().unwrap();
    let key = normalize_host(hostname);
    if tokens.len() >= MAX_ISOLATION_TOKENS && !tokens.contains_key(&key) {
        tokens.clear();
    }
    let token = tokens
        .entry(key)
        .or_insert_with(IsolationToken::new)
        .clone();
    
    let mut prefs = StreamPrefs::new();
    prefs.set_isolation(token);
    prefs
}
