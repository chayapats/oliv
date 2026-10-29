//! Bounded HTTP/1 origin for an outbound tunnel. TLS terminates at the edge;
//! production config only permits loopback or an explicit private overlay IP.
use std::convert::Infallible;
use std::net::TcpListener;
use std::sync::Arc;
use std::time::{Duration, Instant};

use http_body_util::{BodyExt, Full, Limited};
use hyper::body::{Bytes, Incoming};
use hyper::server::conn::http1;
use hyper::service::service_fn;
use hyper::{Request, Response};
use hyper_util::rt::{TokioIo, TokioTimer};
use tokio::sync::Semaphore;

use crate::api::{App, Reply, error};

pub const MAX_CONNECTIONS: usize = 32;
pub const HEADER_TIMEOUT: Duration = Duration::from_secs(5);
pub const BODY_TIMEOUT: Duration = Duration::from_secs(15);
pub const PROCESS_TIMEOUT: Duration = Duration::from_secs(95);

pub fn bind(addr: &str) -> Result<TcpListener, String> {
    let listener = TcpListener::bind(addr).map_err(|e| format!("bind {addr}: {e}"))?;
    listener.set_nonblocking(true).map_err(|e| e.to_string())?;
    Ok(listener)
}

fn response((status, body): Reply) -> Response<Full<Bytes>> {
    let mut builder = Response::builder()
        .status(status)
        .header("Content-Type", "application/json; charset=utf-8")
        .header("Cache-Control", "no-store")
        .header("X-Content-Type-Options", "nosniff")
        .header("Connection", "close");
    if matches!(status, 429 | 503) {
        builder = builder.header("Retry-After", "60");
    }
    if status == 401 {
        builder = builder.header("WWW-Authenticate", "Bearer");
    }
    builder
        .body(Full::new(Bytes::from(serde_json::to_vec(&body).unwrap())))
        .unwrap()
}

async fn dispatch(
    app: Arc<App>,
    rq: Request<Incoming>,
    observed: &mut crate::audit::Observation,
) -> Reply {
    // Cloudflare overwrites this with the visitor's protocol. This is deny-only:
    // it never grants authentication, and direct private/loopback callers may
    // omit it. Check before health, credentials, quota or request-body reads.
    if let Some(proto) = rq.headers().get("x-forwarded-proto")
        && (rq.headers().get_all("x-forwarded-proto").iter().count() != 1
            || proto.as_bytes() != b"https")
    {
        return error(403, "HTTPS is required");
    }
    if rq.uri().query().is_some() || rq.uri().scheme().is_some() {
        return error(
            400,
            "only origin-form paths without query parameters are supported",
        );
    }
    let path = rq.uri().path().to_owned();
    let method = rq.method().as_str().to_owned();
    if path == "/health" {
        return app.handle(&method, &path, None, b"");
    }
    if rq.headers().get_all("authorization").iter().count() != 1 {
        return error(401, "one Authorization bearer header is required");
    }
    let auth = rq
        .headers()
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .map(str::to_owned);
    let check = Arc::clone(&app);
    let check_path = path.clone();
    let check_method = method.clone();
    let admitted = match tokio::task::spawn_blocking(move || {
        let mut observation = crate::audit::Observation::default();
        let result = check.preflight_observed(
            &check_method,
            &check_path,
            auth.as_deref(),
            &mut observation.key_id,
            &mut observation.charged,
        );
        (result, observation)
    })
    .await
    {
        Ok((result, observation)) => {
            *observed = observation;
            match result {
                Ok(p) => p,
                Err(r) => return r,
            }
        }
        Err(_) => return error(503, "authentication worker unavailable"),
    };
    let max = admitted.route.max_body(&method);
    if max > 0 {
        let ctype = rq
            .headers()
            .get("content-type")
            .and_then(|v| v.to_str().ok())
            .unwrap_or("");
        if !ctype
            .split(';')
            .next()
            .unwrap_or("")
            .trim()
            .eq_ignore_ascii_case("application/json")
        {
            return error(415, "Content-Type must be application/json");
        }
    }
    if rq.headers().get("content-encoding").is_some() {
        return error(415, "compressed request bodies are not supported");
    }
    if rq
        .headers()
        .get("content-length")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.parse::<u64>().ok())
        .is_some_and(|n| n > max as u64)
    {
        return error(413, "body too large");
    }
    let collected =
        tokio::time::timeout(BODY_TIMEOUT, Limited::new(rq.into_body(), max).collect()).await;
    let bytes = match collected {
        Err(_) => return error(408, "upload deadline exceeded"),
        Ok(Err(e)) if e.is::<http_body_util::LengthLimitError>() => {
            return error(413, "body too large");
        }
        Ok(Err(_)) => return error(400, "could not read body"),
        Ok(Ok(body)) => body.to_bytes(),
    };
    // The admission slot moves INTO the blocking task. If a client disconnects
    // or this response times out, the job still occupies it until it really ends.
    let job = tokio::task::spawn_blocking(move || app.handle_admitted(&method, &bytes, admitted));
    match tokio::time::timeout(PROCESS_TIMEOUT, job).await {
        Ok(Ok(r)) => r,
        Ok(Err(_)) => error(503, "processing worker unavailable"),
        Err(_) => error(
            504,
            "processing deadline exceeded; do not automatically retry",
        ),
    }
}

pub fn serve(app: Arc<App>, listener: TcpListener) {
    serve_inner(app, listener, None);
}

pub fn serve_with_audit(app: Arc<App>, listener: TcpListener, audit: Arc<crate::audit::Audit>) {
    serve_inner(app, listener, Some(audit));
}

fn serve_inner(app: Arc<App>, listener: TcpListener, audit: Option<Arc<crate::audit::Audit>>) {
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .max_blocking_threads(MAX_CONNECTIONS + 4)
        .enable_all()
        .build()
        .expect("HTTP runtime");
    runtime.block_on(async move {
        let listener = tokio::net::TcpListener::from_std(listener).expect("nonblocking listener");
        eprintln!(
            "oliv-api {} on http://{}",
            env!("CARGO_PKG_VERSION"),
            listener.local_addr().unwrap()
        );
        let connections = Arc::new(Semaphore::new(MAX_CONNECTIONS));
        loop {
            let (stream, _) = match listener.accept().await {
                Ok(v) => v,
                Err(_) => continue,
            };
            // Do not create an unbounded queue of connections or tasks.
            let Ok(permit) = Arc::clone(&connections).try_acquire_owned() else {
                drop(stream);
                continue;
            };
            let app = Arc::clone(&app);
            let audit = audit.clone();
            tokio::spawn(async move {
                let _connection_permit = permit;
                let service = service_fn(move |rq| {
                    let app = Arc::clone(&app);
                    let audit = audit.clone();
                    async move {
                        let start = Instant::now();
                        let started_at = crate::audit::now_ms();
                        let route = rq.uri().path().to_owned();
                        let method = rq.method().as_str().to_owned();
                        let mut observed = crate::audit::Observation::default();
                        let reply = dispatch(app, rq, &mut observed).await;
                        if route != "/health"
                            && let Some(audit) = audit
                        {
                            let elapsed = start.elapsed().as_millis() as i64;
                            let result = reply.clone();
                            let saved = tokio::task::spawn_blocking(move || {
                                audit.record(
                                    &observed, &method, &route, started_at, elapsed, &result,
                                )
                            })
                            .await;
                            if !matches!(saved, Ok(Ok(()))) {
                                eprintln!("usage audit write failed");
                            }
                        }
                        // No URL, headers, identity, backend errors, audio or transcript.
                        eprintln!(
                            "request status={} elapsed_ms={}",
                            reply.0,
                            start.elapsed().as_millis()
                        );
                        Ok::<_, Infallible>(response(reply))
                    }
                });
                let mut builder = http1::Builder::new();
                builder
                    .timer(TokioTimer::new())
                    .header_read_timeout(HEADER_TIMEOUT)
                    .max_headers(32)
                    .max_buf_size(16384)
                    .keep_alive(false);
                // Also bounds stalled response readers. Dropping a connection
                // cannot release an inference permit still held by a model job.
                let _ = tokio::time::timeout(
                    Duration::from_secs(120),
                    builder.serve_connection(TokioIo::new(stream), service),
                )
                .await;
            });
        }
    });
}
