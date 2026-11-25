use std::{
    collections::HashMap,
    io::{self, Read, Write},
    net::{Shutdown as SocketShutdown, SocketAddr, TcpListener, TcpStream},
    sync::{
        atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering},
        Arc, Mutex,
    },
    thread,
    time::{Duration, Instant},
};

pub const PUBLIC_PORT: u16 = 8080;
pub const UPSTREAM_PORT: u16 = 18080;
pub const PUBLIC_ADDR: &str = "127.0.0.1:8080";
pub const UPSTREAM_ADDR: &str = "127.0.0.1:18080";

const MAX_HEADER_BYTES: usize = 64 * 1024;
const MAX_REQUEST_LINE_BYTES: usize = 8 * 1024;
const HEADER_TIMEOUT: Duration = Duration::from_secs(15);
const MAX_CONNECTIONS: usize = 32;

struct TrackedConnection {
    client: TcpStream,
    upstream: Option<TcpStream>,
}

#[derive(Clone)]
struct ProxyState {
    stop: Arc<AtomicBool>,
    connections: Arc<Mutex<HashMap<u64, TrackedConnection>>>,
    workers: Arc<Mutex<Vec<thread::JoinHandle<()>>>>,
    active: Arc<AtomicUsize>,
    next_connection: Arc<AtomicU64>,
}

impl ProxyState {
    fn try_reserve_slot(&self) -> bool {
        loop {
            let current = self.active.load(Ordering::Acquire);
            if current >= MAX_CONNECTIONS {
                return false;
            }
            if self
                .active
                .compare_exchange(current, current + 1, Ordering::AcqRel, Ordering::Acquire)
                .is_ok()
            {
                return true;
            }
        }
    }

    fn release_slot(&self) {
        self.active.fetch_sub(1, Ordering::AcqRel);
    }
}

fn trusted_base_path(path: &str) -> bool {
    let Some(token) = path.strip_prefix("/deskpilot-") else {
        return false;
    };
    token.len() == 24
        && token
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-')
}

pub(crate) type UpstreamValidator = Arc<dyn Fn() -> bool + Send + Sync>;

pub struct DashboardProxy {
    state: ProxyState,
    thread: Option<thread::JoinHandle<()>>,
    base_path: String,
}

impl DashboardProxy {
    pub fn start(
        public: SocketAddr,
        upstream: SocketAddr,
        base_path: &str,
        validator: UpstreamValidator,
    ) -> io::Result<Self> {
        if !public.ip().is_loopback() || !upstream.ip().is_loopback() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "dashboard proxy endpoints must be loopback-only",
            ));
        }
        if !trusted_base_path(base_path) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "dashboard base path is not trusted",
            ));
        }
        let listener = TcpListener::bind(public)?;
        listener.set_nonblocking(true)?;
        let state = ProxyState {
            stop: Arc::new(AtomicBool::new(false)),
            connections: Arc::new(Mutex::new(HashMap::new())),
            workers: Arc::new(Mutex::new(Vec::new())),
            active: Arc::new(AtomicUsize::new(0)),
            next_connection: Arc::new(AtomicU64::new(1)),
        };
        let worker_state = state.clone();
        let base_path = Arc::new(base_path.to_string());
        let worker_base_path = Arc::clone(&base_path);
        let thread = thread::Builder::new()
            .name("deskpilot-dashboard-proxy".into())
            .spawn(move || {
                accept_loop(
                    listener,
                    upstream,
                    worker_state,
                    worker_base_path,
                    validator,
                )
            })?;
        Ok(Self {
            state,
            thread: Some(thread),
            base_path: (*base_path).clone(),
        })
    }

    pub fn url(&self) -> String {
        format!("http://{PUBLIC_ADDR}{}/ui", self.base_path)
    }

    pub fn base_path(&self) -> &str {
        &self.base_path
    }

    fn shutdown_connections(&self) {
        let connections: Vec<_> = self
            .state
            .connections
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .drain()
            .map(|(_, connection)| connection)
            .collect();
        for connection in connections {
            let _ = connection.client.shutdown(SocketShutdown::Both);
            if let Some(upstream) = connection.upstream {
                let _ = upstream.shutdown(SocketShutdown::Both);
            }
        }
    }

    pub fn stop(&mut self) {
        self.state.stop.store(true, Ordering::Release);
        self.shutdown_connections();
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
        self.shutdown_connections();
        let workers = std::mem::take(
            &mut *self
                .state
                .workers
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner()),
        );
        for worker in workers {
            let _ = worker.join();
        }
    }
}

impl Drop for DashboardProxy {
    fn drop(&mut self) {
        self.stop();
    }
}

fn accept_loop(
    listener: TcpListener,
    upstream: SocketAddr,
    state: ProxyState,
    base_path: Arc<String>,
    validator: UpstreamValidator,
) {
    while !state.stop.load(Ordering::Acquire) {
        state
            .workers
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .retain(|worker| !worker.is_finished());
        match listener.accept() {
            Ok((client, _)) => {
                if state.stop.load(Ordering::Acquire) {
                    break;
                }
                if !state.try_reserve_slot() {
                    let _ = client.shutdown(SocketShutdown::Both);
                    continue;
                }
                let id = state.next_connection.fetch_add(1, Ordering::Relaxed);
                let tracked = match client.try_clone() {
                    Ok(stream) => stream,
                    Err(_) => {
                        state.release_slot();
                        continue;
                    }
                };
                let inserted = {
                    let mut connections = state
                        .connections
                        .lock()
                        .unwrap_or_else(|poisoned| poisoned.into_inner());
                    if state.stop.load(Ordering::Acquire) {
                        false
                    } else {
                        connections.insert(
                            id,
                            TrackedConnection {
                                client: tracked,
                                upstream: None,
                            },
                        );
                        true
                    }
                };
                if !inserted {
                    state.release_slot();
                    continue;
                }
                let connection_state = state.clone();
                let worker_base_path = Arc::clone(&base_path);
                let worker_validator = Arc::clone(&validator);
                let worker = thread::Builder::new()
                    .name(format!("deskpilot-dashboard-{id}"))
                    .spawn(move || {
                        handle_client(
                            id,
                            client,
                            upstream,
                            worker_base_path,
                            worker_validator,
                            connection_state.clone(),
                        );
                        connection_state.release_slot();
                        connection_state
                            .connections
                            .lock()
                            .unwrap_or_else(|poisoned| poisoned.into_inner())
                            .remove(&id);
                    });
                match worker {
                    Ok(worker) => state
                        .workers
                        .lock()
                        .unwrap_or_else(|poisoned| poisoned.into_inner())
                        .push(worker),
                    Err(_) => {
                        state.release_slot();
                        state
                            .connections
                            .lock()
                            .unwrap_or_else(|poisoned| poisoned.into_inner())
                            .remove(&id);
                    }
                }
            }
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                thread::sleep(Duration::from_millis(20));
            }
            Err(_) => break,
        }
    }
}

fn handle_client(
    id: u64,
    mut client: TcpStream,
    upstream: SocketAddr,
    base_path: Arc<String>,
    validator: UpstreamValidator,
    state: ProxyState,
) {
    let request = match read_request_head(&mut client) {
        Ok(request) => request,
        Err(_) => return,
    };
    let public_port = client
        .local_addr()
        .ok()
        .map(|address| address.port())
        .unwrap_or(PUBLIC_PORT);
    let forwarded = match rewrite_request(&request.head, public_port, &base_path) {
        Ok(forwarded) => forwarded,
        Err(message) => {
            write_error(&mut client, 403, message);
            return;
        }
    };
    if !validator() {
        write_error(
            &mut client,
            502,
            "DeskPilot tunnel dashboard is unavailable",
        );
        return;
    }
    let mut upstream = match TcpStream::connect_timeout(&upstream, Duration::from_secs(3)) {
        Ok(stream) => stream,
        Err(_) => {
            write_error(
                &mut client,
                502,
                "DeskPilot tunnel dashboard is unavailable",
            );
            return;
        }
    };
    if !validator() {
        write_error(
            &mut client,
            502,
            "DeskPilot tunnel dashboard is unavailable",
        );
        return;
    }
    let tracked = match upstream.try_clone() {
        Ok(stream) => stream,
        Err(_) => return,
    };
    let stopping = {
        let mut connections = state
            .connections
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if state.stop.load(Ordering::Acquire) {
            true
        } else if let Some(connection) = connections.get_mut(&id) {
            connection.upstream = Some(tracked);
            false
        } else {
            true
        }
    };
    if stopping {
        let _ = upstream.shutdown(SocketShutdown::Both);
        return;
    }
    if upstream.write_all(&forwarded).is_err()
        || (!request.body.is_empty() && upstream.write_all(&request.body).is_err())
    {
        return;
    }
    let Ok(mut client_upload) = client.try_clone() else {
        return;
    };
    let Ok(mut upstream_download) = upstream.try_clone() else {
        return;
    };
    let upload = thread::spawn(move || {
        let _ = io::copy(&mut client_upload, &mut upstream_download);
        let _ = upstream_download.shutdown(SocketShutdown::Write);
    });
    let _ = io::copy(&mut upstream, &mut client);
    let _ = client.shutdown(SocketShutdown::Both);
    let _ = upload.join();
}

fn write_error(client: &mut TcpStream, status: u16, message: &str) {
    let reason = match status {
        403 => "Forbidden",
        502 => "Bad Gateway",
        _ => "Error",
    };
    let response = format!(
        "HTTP/1.1 {status} {reason}\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n{message}",
        message.len()
    );
    let _ = client.write_all(response.as_bytes());
    let _ = client.flush();
}

struct RequestHead {
    head: Vec<u8>,
    body: Vec<u8>,
}

fn read_request_head(client: &mut TcpStream) -> io::Result<RequestHead> {
    let deadline = Instant::now() + HEADER_TIMEOUT;
    let mut bytes = Vec::new();
    let mut buffer = [0u8; 8192];
    let header_end = loop {
        if bytes.len() > MAX_HEADER_BYTES {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "dashboard request headers are too large",
            ));
        }
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "dashboard request headers timed out",
            ));
        }
        client.set_read_timeout(Some(remaining))?;
        let count = client.read(&mut buffer)?;
        if count == 0 {
            return Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "dashboard request ended before its headers",
            ));
        }
        bytes.extend_from_slice(&buffer[..count]);
        if let Some(position) = bytes.windows(4).position(|window| window == b"\r\n\r\n") {
            break position + 4;
        }
    };
    client.set_read_timeout(None)?;
    let head = bytes[..header_end].to_vec();
    let body = bytes[header_end..].to_vec();
    Ok(RequestHead { head, body })
}

fn rewrite_request(
    head: &[u8],
    public_port: u16,
    base_path: &str,
) -> Result<Vec<u8>, &'static str> {
    let text = std::str::from_utf8(head).map_err(|_| "invalid dashboard request headers")?;
    let mut lines = text.split("\r\n");
    let request_line = lines.next().ok_or("missing dashboard request line")?;
    if request_line.len() > MAX_REQUEST_LINE_BYTES {
        return Err("dashboard request line is too large");
    }
    let mut request_parts = request_line.split_whitespace();
    let method = request_parts.next().ok_or("missing request method")?;
    let target = request_parts.next().ok_or("missing request target")?;
    let version = request_parts.next().ok_or("missing HTTP version")?;
    if request_parts.next().is_some()
        || !is_token(method.as_bytes())
        || !target.starts_with('/')
        || target.contains(['\r', '\n', ' '])
        || !matches!(version, "HTTP/1.0" | "HTTP/1.1")
        || method.eq_ignore_ascii_case("CONNECT")
    {
        return Err("invalid dashboard request line");
    }
    let base_route = base_path.to_string();
    if target != "/readyz"
        && target != "/favicon.ico"
        && target != base_route
        && !target.starts_with(&format!("{base_route}/"))
    {
        return Err("dashboard route is not allowed");
    }

    let allowed_hosts = [
        format!("127.0.0.1:{public_port}"),
        format!("localhost:{public_port}"),
    ];
    let mut host_count = 0usize;
    let mut content_length_count = 0usize;
    let mut transfer_encoding_count = 0usize;
    let mut unsafe_cross_site = false;
    let mut origin: Option<&str> = None;
    let mut referer: Option<&str> = None;
    let mut output = Vec::with_capacity(head.len() + 96);
    output.extend_from_slice(request_line.as_bytes());
    output.extend_from_slice(b"\r\n");

    for line in lines {
        if line.is_empty() {
            continue;
        }
        if line.starts_with([' ', '\t']) || line.contains(['\r', '\n', '\0']) {
            return Err("invalid dashboard header");
        }
        let (name, value) = line.split_once(':').ok_or("invalid dashboard header")?;
        if !is_token(name.as_bytes()) {
            return Err("invalid dashboard header name");
        }
        let value = value.trim();
        let lower = name.to_ascii_lowercase();
        match lower.as_str() {
            "host" => {
                host_count += 1;
                if !allowed_hosts
                    .iter()
                    .any(|allowed| allowed.eq_ignore_ascii_case(value))
                {
                    return Err("dashboard Host header is not allowed");
                }
                output.extend_from_slice(line.as_bytes());
                output.extend_from_slice(b"\r\n");
            }
            "content-length" => {
                content_length_count += 1;
                if value.is_empty()
                    || !value.bytes().all(|byte| byte.is_ascii_digit())
                    || value.len() > 20
                {
                    return Err("invalid dashboard Content-Length");
                }
                output.extend_from_slice(line.as_bytes());
                output.extend_from_slice(b"\r\n");
            }
            "transfer-encoding" => {
                transfer_encoding_count += 1;
                if !value.eq_ignore_ascii_case("chunked") {
                    return Err("unsupported dashboard Transfer-Encoding");
                }
                output.extend_from_slice(line.as_bytes());
                output.extend_from_slice(b"\r\n");
            }
            "sec-fetch-site" => {
                unsafe_cross_site = value.eq_ignore_ascii_case("cross-site");
            }
            "origin" => origin = Some(value),
            "referer" => referer = Some(value),
            "connection"
            | "proxy-connection"
            | "keep-alive"
            | "upgrade"
            | "proxy-authenticate"
            | "proxy-authorization"
            | "te"
            | "trailer" => {}
            _ => {
                output.extend_from_slice(line.as_bytes());
                output.extend_from_slice(b"\r\n");
            }
        }
    }

    if host_count != 1 {
        return Err("dashboard request must have exactly one Host header");
    }
    if content_length_count > 1 || transfer_encoding_count > 1 {
        return Err("ambiguous dashboard request framing");
    }
    if content_length_count != 0 && transfer_encoding_count != 0 {
        return Err("ambiguous dashboard request framing");
    }
    let unsafe_method = !matches!(
        method.to_ascii_uppercase().as_str(),
        "GET" | "HEAD" | "OPTIONS" | "TRACE"
    );
    if unsafe_method {
        if unsafe_cross_site {
            return Err("cross-site dashboard action is not allowed");
        }
        if let Some(origin) = origin {
            if !is_local_origin(origin, public_port, false) {
                return Err("dashboard action origin is not allowed");
            }
        } else if let Some(referer) = referer {
            if !is_local_origin(referer, public_port, true) {
                return Err("dashboard action referer is not allowed");
            }
        }
    }
    output.extend_from_slice(b"Connection: close\r\nX-DeskPilot-Dashboard-Proxy: 1\r\n\r\n");
    Ok(output)
}

fn is_local_origin(value: &str, public_port: u16, allow_path: bool) -> bool {
    let Some((scheme, rest)) = value.split_once("://") else {
        return false;
    };
    if !scheme.eq_ignore_ascii_case("http") {
        return false;
    }
    let (host, path) = rest
        .split_once('/')
        .map(|(host, path)| (host, format!("/{path}")))
        .unwrap_or_else(|| (rest, String::new()));
    if host.contains(['@', '?', '#']) {
        return false;
    }
    let host_ok = host.eq_ignore_ascii_case(&format!("127.0.0.1:{public_port}"))
        || host.eq_ignore_ascii_case(&format!("localhost:{public_port}"));
    host_ok && (allow_path || path.is_empty() || path == "/")
}

fn is_token(bytes: &[u8]) -> bool {
    !bytes.is_empty()
        && bytes
            .iter()
            .all(|byte| byte.is_ascii_alphanumeric() || b"!#$%&'*+-.^_`|~".contains(byte))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::IpAddr;
    use std::sync::mpsc;

    const BASE_PATH: &str = "/deskpilot-abcdefghijklmnopqrstuvwx";

    fn request(method: &str, headers: &str) -> Vec<u8> {
        format!("{method} {BASE_PATH}/api/logs HTTP/1.1\r\n{headers}\r\n").into_bytes()
    }

    #[test]
    fn rejects_dns_rebinding_host() {
        let result = rewrite_request(
            &request(
                "GET",
                "Host: attacker.example:8080\r\nOrigin: http://attacker.example:8080",
            ),
            PUBLIC_PORT,
            BASE_PATH,
        );
        assert!(result.is_err());
    }

    #[test]
    fn rejects_cross_site_unsafe_action() {
        let result = rewrite_request(
            &request(
                "POST",
                "Host: 127.0.0.1:8080\r\nOrigin: https://attacker.example\r\nContent-Length: 0",
            ),
            PUBLIC_PORT,
            BASE_PATH,
        );
        assert!(result.is_err());
    }

    #[test]
    fn rejects_missing_duplicate_and_ambiguous_headers() {
        assert!(rewrite_request(&request("GET", ""), PUBLIC_PORT, BASE_PATH).is_err());
        assert!(rewrite_request(
            &request("GET", "Host: 127.0.0.1:8080\r\nHost: localhost:8080"),
            PUBLIC_PORT,
            BASE_PATH,
        )
        .is_err());
        assert!(rewrite_request(
            &request(
                "POST",
                "Host: 127.0.0.1:8080\r\nContent-Length: 0\r\nTransfer-Encoding: chunked",
            ),
            PUBLIC_PORT,
            BASE_PATH,
        )
        .is_err());
    }

    #[test]
    fn rejects_predictable_upstream_routes() {
        let head = b"GET /api/logs HTTP/1.1\r\nHost: 127.0.0.1:8080\r\n\r\n";
        assert!(rewrite_request(head, PUBLIC_PORT, BASE_PATH).is_err());
    }

    #[test]
    fn forwards_only_loopback_dashboard_requests() {
        let forwarded = rewrite_request(
            &request(
                "GET",
                "Host: 127.0.0.1:8080\r\nConnection: keep-alive\r\nAccept: application/json",
            ),
            PUBLIC_PORT,
            BASE_PATH,
        )
        .unwrap();
        let text = String::from_utf8(forwarded).unwrap();
        assert!(text.contains("Host: 127.0.0.1:8080\r\n"));
        assert!(text.contains("Connection: close\r\n"));
        assert!(text.contains("X-DeskPilot-Dashboard-Proxy: 1\r\n"));
        assert!(!text.contains("Connection: keep-alive"));
    }

    #[test]
    fn proxy_blocks_rebinding_before_upstream_and_serves_local_dashboard() {
        let upstream_listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let upstream_addr = upstream_listener.local_addr().unwrap();
        let (tx, rx) = mpsc::channel();
        let upstream_thread = thread::spawn(move || {
            let (mut stream, _) = upstream_listener.accept().unwrap();
            let mut bytes = Vec::new();
            let mut buffer = [0u8; 4096];
            loop {
                let count = stream.read(&mut buffer).unwrap();
                if count == 0 {
                    break;
                }
                bytes.extend_from_slice(&buffer[..count]);
                if bytes.windows(4).any(|window| window == b"\r\n\r\n") {
                    break;
                }
            }
            tx.send(bytes).unwrap();
            stream
                .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK")
                .unwrap();
        });

        let public_listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let public_addr = public_listener.local_addr().unwrap();
        drop(public_listener);
        let mut proxy =
            DashboardProxy::start(public_addr, upstream_addr, BASE_PATH, Arc::new(|| true))
                .unwrap();

        let mut attacker = TcpStream::connect(public_addr).unwrap();
        attacker
            .write_all(&request(
                "GET",
                &format!("Host: attacker.example:{}\r\n", public_addr.port()),
            ))
            .unwrap();
        let mut response = Vec::new();
        attacker.read_to_end(&mut response).unwrap();
        assert!(String::from_utf8_lossy(&response).starts_with("HTTP/1.1 403 "));
        assert!(rx.recv_timeout(Duration::from_millis(200)).is_err());

        let mut local = TcpStream::connect(public_addr).unwrap();
        local
            .write_all(&request(
                "GET",
                &format!("Host: 127.0.0.1:{}\r\n", public_addr.port()),
            ))
            .unwrap();
        let mut response = Vec::new();
        local.read_to_end(&mut response).unwrap();
        assert!(String::from_utf8_lossy(&response).starts_with("HTTP/1.1 200 "));
        assert!(response.ends_with(b"OK"));
        let forwarded = rx.recv_timeout(Duration::from_secs(2)).unwrap();
        assert!(String::from_utf8_lossy(&forwarded).contains("X-DeskPilot-Dashboard-Proxy: 1"));
        upstream_thread.join().unwrap();
        proxy.stop();
    }

    #[test]
    fn proxy_streams_sse_without_buffering() {
        let upstream_listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let upstream_addr = upstream_listener.local_addr().unwrap();
        let (release_tx, release_rx) = mpsc::channel();
        let upstream_thread = thread::spawn(move || {
            let (mut stream, _) = upstream_listener.accept().unwrap();
            let mut bytes = Vec::new();
            let mut buffer = [0u8; 4096];
            loop {
                let count = stream.read(&mut buffer).unwrap();
                if count == 0 {
                    break;
                }
                bytes.extend_from_slice(&buffer[..count]);
                if bytes.windows(4).any(|window| window == b"\r\n\r\n") {
                    break;
                }
            }
            stream
                .write_all(
                    b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\ndata: one\n\n",
                )
                .unwrap();
            stream.flush().unwrap();
            release_rx.recv_timeout(Duration::from_secs(2)).unwrap();
            stream.write_all(b"data: two\n\n").unwrap();
            stream.flush().unwrap();
        });
        let public_listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let public_addr = public_listener.local_addr().unwrap();
        drop(public_listener);
        let mut proxy =
            DashboardProxy::start(public_addr, upstream_addr, BASE_PATH, Arc::new(|| true))
                .unwrap();
        let mut client = TcpStream::connect(public_addr).unwrap();
        client
            .set_read_timeout(Some(Duration::from_secs(2)))
            .unwrap();
        client
            .write_all(&request(
                "GET",
                &format!("Host: 127.0.0.1:{}\r\n", public_addr.port()),
            ))
            .unwrap();
        let mut response = Vec::new();
        let mut buffer = [0u8; 1024];
        while !String::from_utf8_lossy(&response).contains("data: one") {
            let count = client.read(&mut buffer).unwrap();
            assert_ne!(count, 0);
            response.extend_from_slice(&buffer[..count]);
        }
        release_tx.send(()).unwrap();
        client.read_to_end(&mut response).unwrap();
        assert!(String::from_utf8_lossy(&response).contains("data: two"));
        upstream_thread.join().unwrap();
        proxy.stop();
    }

    #[test]
    fn proxy_rejects_untrusted_upstream_before_forwarding() {
        let upstream_listener = TcpListener::bind("127.0.0.1:0").unwrap();
        upstream_listener.set_nonblocking(true).unwrap();
        let upstream_addr = upstream_listener.local_addr().unwrap();
        let public_listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let public_addr = public_listener.local_addr().unwrap();
        drop(public_listener);
        let mut proxy =
            DashboardProxy::start(public_addr, upstream_addr, BASE_PATH, Arc::new(|| false))
                .unwrap();
        let mut client = TcpStream::connect(public_addr).unwrap();
        client
            .write_all(&request(
                "GET",
                &format!("Host: 127.0.0.1:{}\r\n", public_addr.port()),
            ))
            .unwrap();
        let mut response = Vec::new();
        client.read_to_end(&mut response).unwrap();
        assert!(String::from_utf8_lossy(&response).starts_with("HTTP/1.1 502 "));
        assert_eq!(
            upstream_listener.accept().unwrap_err().kind(),
            io::ErrorKind::WouldBlock
        );
        proxy.stop();
    }

    #[test]
    fn connection_slots_are_bounded() {
        let state = ProxyState {
            stop: Arc::new(AtomicBool::new(false)),
            connections: Arc::new(Mutex::new(HashMap::new())),
            workers: Arc::new(Mutex::new(Vec::new())),
            active: Arc::new(AtomicUsize::new(0)),
            next_connection: Arc::new(AtomicU64::new(1)),
        };
        for _ in 0..MAX_CONNECTIONS {
            assert!(state.try_reserve_slot());
        }
        assert!(!state.try_reserve_slot());
        for _ in 0..MAX_CONNECTIONS {
            state.release_slot();
        }
        assert!(state.try_reserve_slot());
        state.release_slot();
    }

    #[test]
    fn refuses_non_loopback_proxy_endpoints() {
        assert!(DashboardProxy::start(
            "0.0.0.0:0".parse::<SocketAddr>().unwrap(),
            "127.0.0.1:0".parse::<SocketAddr>().unwrap(),
            BASE_PATH,
            Arc::new(|| true),
        )
        .is_err());
        assert!(DashboardProxy::start(
            "127.0.0.1:0".parse::<SocketAddr>().unwrap(),
            "0.0.0.0:0".parse::<SocketAddr>().unwrap(),
            BASE_PATH,
            Arc::new(|| true),
        )
        .is_err());
        assert!(DashboardProxy::start(
            "127.0.0.1:0".parse::<SocketAddr>().unwrap(),
            "127.0.0.1:0".parse::<SocketAddr>().unwrap(),
            "/predictable",
            Arc::new(|| true),
        )
        .is_err());
    }

    #[test]
    fn loopback_check_handles_ipv4_and_ipv6() {
        assert!("127.0.0.1".parse::<IpAddr>().unwrap().is_loopback());
        assert!("::1".parse::<IpAddr>().unwrap().is_loopback());
        assert!(!"192.0.2.1".parse::<IpAddr>().unwrap().is_loopback());
    }
}
