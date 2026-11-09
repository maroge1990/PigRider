//! The intervals.icu upload end to end: the real router, and a local stand-in
//! for intervals.icu that records what it was sent.

use std::collections::HashMap;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use axum::body::Bytes;
use axum::extract::{Path, Query, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::IntoResponse;
use axum::routing::post;
use axum::{Json, Router};
use openradlr_server::app;
use openradlr_server::config::{Config, EventsSetting};
use openradlr_server::intervals::{ApiKey, IntervalsConfig};
use serde_json::{json, Value};

const ROUTES_DIR: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../../routes");
const KEY: &str = "test-key-123";
/// `API_KEY:test-key-123`, as HTTP Basic auth.
const BASIC_AUTH: &str = "Basic QVBJX0tFWTp0ZXN0LWtleS0xMjM=";
const FIT: &str = "application/vnd.ant.fit";

#[derive(Debug, Clone)]
struct Received {
    athlete: String,
    query: HashMap<String, String>,
    authorization: Option<String>,
    content_type: Option<String>,
    body: Vec<u8>,
}

type Log = Arc<Mutex<Vec<Received>>>;

/// intervals.icu's upload endpoint, answering every upload with `reply`.
async fn fake_intervals(status: u16, reply: Value) -> (String, Log) {
    let log: Log = Arc::default();
    let router = Router::new()
        .route("/api/v1/athlete/{athlete}/activities", post(record))
        .with_state((log.clone(), status, reply));
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
    (format!("http://{addr}"), log)
}

async fn record(
    State((log, status, reply)): State<(Log, u16, Value)>,
    Path(athlete): Path<String>,
    Query(query): Query<HashMap<String, String>>,
    headers: HeaderMap,
    body: Bytes,
) -> impl IntoResponse {
    let header = |name: &str| headers.get(name).and_then(|v| v.to_str().ok()).map(str::to_owned);
    log.lock().unwrap().push(Received {
        athlete,
        query,
        authorization: header("authorization"),
        content_type: header("content-type"),
        body: body.to_vec(),
    });
    (StatusCode::from_u16(status).unwrap(), Json(reply))
}

/// Starts the server; with `intervals` (the fake's base URL) it has a key.
/// Returns the server's own origin, which is also its public URL.
async fn start_server(intervals: Option<&str>) -> String {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr: SocketAddr = listener.local_addr().unwrap();
    let origin = format!("http://{addr}");
    let config = Config {
        route_file: PathBuf::from(ROUTES_DIR).join("rolling-hills.json"),
        target_riders: 0,
        events: EventsSetting::Off,
        public_url: Some(origin.clone()),
        intervals: intervals.map(|base_url| IntervalsConfig {
            api_key: ApiKey::new(KEY),
            base_url: base_url.to_owned(),
            public_url: origin.clone(),
        }),
        ..Config::default()
    };
    let router = app::build(&config).expect("app builds");
    tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
    origin
}

/// A minimal FIT file: a 14-byte header with the `.FIT` signature, then data.
fn fit() -> Vec<u8> {
    let mut fit = vec![14, 0x20, 0x54, 0x08, 0, 0, 0, 0];
    fit.extend_from_slice(b".FIT");
    fit.extend_from_slice(&[0, 0, 1, 2, 3, 4]);
    fit
}

/// Posts `body` to the server's upload route; `None` leaves a header out.
async fn upload(server: &str, origin: Option<&str>, content_type: Option<&str>, body: Vec<u8>) -> (u16, Value) {
    let mut request = reqwest::Client::new()
        .post(format!("{server}/api/intervals/upload"))
        .query(&[("name", "OpenRadlr · Rolling Hills")])
        .body(body);
    if let Some(origin) = origin {
        request = request.header("origin", origin);
    }
    if let Some(content_type) = content_type {
        request = request.header("content-type", content_type);
    }
    let response = request.send().await.unwrap();
    let status = response.status().as_u16();
    (status, response.json().await.unwrap_or(Value::Null))
}

async fn info(server: &str) -> Value {
    reqwest::get(format!("{server}/api/info"))
        .await
        .unwrap()
        .json()
        .await
        .unwrap()
}

#[tokio::test]
async fn info_says_whether_the_server_uploads_to_intervals() {
    let (fake, _) = fake_intervals(201, json!({})).await;
    assert_eq!(
        info(&start_server(Some(&fake)).await).await["intervals"],
        json!({ "enabled": true })
    );
    assert_eq!(
        info(&start_server(None).await).await["intervals"],
        json!({ "enabled": false })
    );
}

#[tokio::test]
async fn a_ride_from_the_servers_own_page_goes_to_the_keys_athlete() {
    let (fake, log) = fake_intervals(201, json!({ "id": "i42" })).await;
    let server = start_server(Some(&fake)).await;

    let (status, reply) = upload(&server, Some(&server), Some(FIT), fit()).await;

    assert_eq!((status, reply), (200, json!({ "activity_id": "i42" })));
    let log = log.lock().unwrap();
    let sent = &log[0];
    assert_eq!(sent.athlete, "0");
    assert_eq!(sent.authorization.as_deref(), Some(BASIC_AUTH));
    assert_eq!(sent.query["name"], "OpenRadlr · Rolling Hills");
    assert_eq!(sent.query["description"], format!("Ridden on OpenRadlr: {server}"));
    assert!(sent.content_type.as_deref().unwrap().starts_with("multipart/form-data"));
    let body = String::from_utf8_lossy(&sent.body);
    assert!(body.contains("name=\"file\"; filename=\"openradlr.fit\""));
    assert!(sent.body.windows(fit().len()).any(|w| w == fit()));
}

#[tokio::test]
async fn an_upload_without_an_activity_id_in_the_reply_still_succeeds() {
    let (fake, _) = fake_intervals(201, json!({ "something": "else" })).await;
    let server = start_server(Some(&fake)).await;
    assert_eq!(
        upload(&server, Some(&server), Some(FIT), fit()).await,
        (200, json!({ "activity_id": null }))
    );
}

#[tokio::test]
async fn another_sites_page_cannot_upload() {
    let (fake, log) = fake_intervals(201, json!({})).await;
    let server = start_server(Some(&fake)).await;
    let (status, reply) = upload(&server, Some("http://evil.example"), Some(FIT), fit()).await;
    assert_eq!((status, &reply["code"]), (403, &json!("foreign_origin")));
    assert!(log.lock().unwrap().is_empty());
}

#[tokio::test]
async fn an_upload_without_an_origin_is_refused() {
    let (fake, log) = fake_intervals(201, json!({})).await;
    let server = start_server(Some(&fake)).await;
    assert_eq!(upload(&server, None, Some(FIT), fit()).await.0, 403);
    assert!(log.lock().unwrap().is_empty());
}

#[tokio::test]
async fn an_opaque_null_origin_is_refused() {
    let (fake, log) = fake_intervals(201, json!({})).await;
    let server = start_server(Some(&fake)).await;
    assert_eq!(upload(&server, Some("null"), Some(FIT), fit()).await.0, 403);
    assert!(log.lock().unwrap().is_empty());
}

/// A cross-site form or `text/plain` post needs no CORS preflight; only the
/// ride file types (which do) are accepted.
#[tokio::test]
async fn a_plain_text_ride_file_is_refused_even_from_the_right_origin() {
    let (fake, log) = fake_intervals(201, json!({})).await;
    let server = start_server(Some(&fake)).await;
    let tcx = b"<?xml version=\"1.0\"?><TrainingCenterDatabase/>".to_vec();
    let (status, reply) = upload(&server, Some(&server), Some("text/plain"), tcx).await;
    assert_eq!((status, &reply["code"]), (415, &json!("not_a_ride_file_type")));
    assert!(log.lock().unwrap().is_empty());
}

#[tokio::test]
async fn a_body_that_is_not_a_ride_is_refused() {
    let (fake, log) = fake_intervals(201, json!({})).await;
    let server = start_server(Some(&fake)).await;
    let (status, reply) = upload(&server, Some(&server), Some(FIT), b"not a ride".to_vec()).await;
    assert_eq!((status, &reply["code"]), (400, &json!("not_a_ride")));
    assert!(log.lock().unwrap().is_empty());
}

#[tokio::test]
async fn without_a_key_the_route_is_off() {
    let server = start_server(None).await;
    let (status, reply) = upload(&server, Some(&server), Some(FIT), fit()).await;
    assert_eq!((status, &reply["code"]), (404, &json!("intervals_disabled")));
}

#[tokio::test]
async fn a_refused_key_is_reported_as_such() {
    let (fake, _) = fake_intervals(401, json!({ "error": "unauthorized" })).await;
    let server = start_server(Some(&fake)).await;
    let (status, reply) = upload(&server, Some(&server), Some(FIT), fit()).await;
    assert_eq!((status, &reply["code"]), (502, &json!("intervals_key_rejected")));
    assert!(!reply.to_string().contains(KEY));
}

#[tokio::test]
async fn a_rate_limited_upload_asks_to_try_later() {
    let (fake, _) = fake_intervals(429, json!({})).await;
    let server = start_server(Some(&fake)).await;
    let (status, reply) = upload(&server, Some(&server), Some(FIT), fit()).await;
    assert_eq!((status, &reply["code"]), (503, &json!("intervals_busy")));
}

#[tokio::test]
async fn an_intervals_failure_is_a_bad_gateway() {
    let (fake, _) = fake_intervals(500, json!({})).await;
    let server = start_server(Some(&fake)).await;
    let (status, reply) = upload(&server, Some(&server), Some(FIT), fit()).await;
    assert_eq!((status, &reply["code"]), (502, &json!("upload_failed")));
}
