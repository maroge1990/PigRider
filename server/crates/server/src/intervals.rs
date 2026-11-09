//! Uploads to intervals.icu with one server-wide API key
//! (`OPENRADLR_INTERVALS_API_KEY`), for a private server with one rider:
//! every ride goes to the key owner's account. See
//! `docs/superpowers/specs/2026-11-09-intervals-upload-design.md`.
//!
//! There is no rider sign-in, so the route accepts only the server's own page:
//! the `Origin` must be the public URL's and the body a ride file type, which
//! another site can send only after a CORS preflight the server never grants.

use std::fmt;
use std::time::Duration;

use axum::extract::{Query, Request, State};
use axum::http::{header, HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::Json;
use serde::{Deserialize, Serialize};

use crate::http::AppState;
use crate::strava_api::{self, RideFile};

pub const DEFAULT_BASE_URL: &str = "https://intervals.icu";
/// intervals.icu documents no limit; a slow upload gives up after this.
const TIMEOUT: Duration = Duration::from_secs(60);
/// The ride file types the route accepts (and the client sends).
const RIDE_FILE_TYPES: [&str; 2] = ["application/vnd.ant.fit", "application/vnd.garmin.tcx+xml"];

/// An intervals.icu API key. Never printed: `Debug` hides it.
#[derive(Clone, PartialEq, Eq)]
pub struct ApiKey(String);

impl ApiKey {
    pub fn new(key: impl Into<String>) -> Self {
        Self(key.into())
    }

    fn expose(&self) -> &str {
        &self.0
    }
}

impl fmt::Debug for ApiKey {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("ApiKey(hidden)")
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IntervalsConfig {
    pub api_key: ApiKey,
    /// `https://intervals.icu`; tests point it at a local stand-in.
    pub base_url: String,
    /// The server's public URL: the only origin allowed to upload, and linked in the description.
    pub public_url: String,
}

/// The upload service: config plus its HTTP client.
pub struct Intervals {
    config: IntervalsConfig,
    origin: String,
    http: reqwest::Client,
}

#[derive(Debug, PartialEq, Eq)]
pub enum IntervalsError {
    /// 401/403: the key is wrong or was revoked.
    KeyRejected,
    /// 429: over intervals.icu's rate limit.
    Busy,
    /// Anything else, including timeouts and unreachable hosts.
    Failed(String),
}

impl IntervalsError {
    fn of_status(status: u16) -> Self {
        match status {
            401 | 403 => Self::KeyRejected,
            429 => Self::Busy,
            _ => Self::Failed(format!("upload failed with HTTP {status}")),
        }
    }
}

impl Intervals {
    pub fn new(config: IntervalsConfig, version: &str) -> Result<Self, reqwest::Error> {
        let http = reqwest::Client::builder()
            // intervals.icu sits behind Cloudflare, which turns away some default agents.
            .user_agent(format!("OpenRadlr/{version}"))
            .timeout(TIMEOUT)
            .build()?;
        let origin = origin_of(&config.public_url);
        Ok(Self { config, origin, http })
    }

    /// Sends a ride to the key's own athlete (`0`); the new activity's id, if the reply names one.
    pub async fn upload(&self, ride: RideFile, name: &str) -> Result<Option<String>, IntervalsError> {
        let part = match ride {
            RideFile::Fit(bytes) => reqwest::multipart::Part::bytes(bytes)
                .file_name("openradlr.fit")
                .mime_str("application/vnd.ant.fit"),
            RideFile::Tcx(text) => reqwest::multipart::Part::text(text)
                .file_name("openradlr.tcx")
                .mime_str("application/vnd.garmin.tcx+xml"),
        }
        .map_err(|e| IntervalsError::Failed(e.to_string()))?;
        let description = strava_api::description(&self.config.public_url);
        let response = self
            .http
            .post(format!("{}/api/v1/athlete/0/activities", self.config.base_url))
            .basic_auth("API_KEY", Some(self.config.api_key.expose()))
            .query(&[("name", name), ("description", description.as_str())])
            .multipart(reqwest::multipart::Form::new().part("file", part))
            .send()
            .await
            .map_err(|e| IntervalsError::Failed(e.without_url().to_string()))?;
        let status = response.status();
        if !status.is_success() {
            return Err(IntervalsError::of_status(status.as_u16()));
        }
        // The reply's shape is undocumented: an id is a bonus, not a requirement.
        let body: serde_json::Value = response.json().await.unwrap_or_default();
        Ok(activity_id(&body))
    }
}

/// The new activity's id: `id`, or the first of `activities`.
pub fn activity_id(reply: &serde_json::Value) -> Option<String> {
    let id = |value: &serde_json::Value| match value.get("id")? {
        serde_json::Value::String(id) if !id.is_empty() => Some(id.clone()),
        serde_json::Value::Number(id) => Some(id.to_string()),
        _ => None,
    };
    id(reply).or_else(|| reply.get("activities")?.as_array()?.first().and_then(id))
}

/// `scheme://host[:port]` of a URL as a browser sends it in `Origin`: lower
/// case, no path, no default port.
pub fn origin_of(url: &str) -> String {
    let url = url.trim().to_ascii_lowercase();
    let (scheme, rest) = url.split_once("://").unwrap_or(("", url.as_str()));
    let authority = rest.split(['/', '?', '#']).next().unwrap_or_default();
    let authority = match (scheme, authority.rsplit_once(':')) {
        ("https", Some((host, "443"))) | ("http", Some((host, "80"))) => host,
        _ => authority,
    };
    format!("{scheme}://{authority}")
}

/// Whether a `Content-Type` is a ride file type (parameters and case ignored).
pub fn is_ride_file_type(content_type: &str) -> bool {
    let essence = content_type
        .split(';')
        .next()
        .unwrap_or_default()
        .trim()
        .to_ascii_lowercase();
    RIDE_FILE_TYPES.contains(&essence.as_str())
}

fn error(status: StatusCode, code: &str, message: &str) -> Response {
    (status, Json(serde_json::json!({ "code": code, "message": message }))).into_response()
}

#[derive(Debug, Deserialize)]
pub struct UploadQuery {
    pub name: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct UploadReply {
    pub activity_id: Option<String>,
}

/// `POST /api/intervals/upload?name=…`: the request's headers are checked
/// before its body is read, so a refused request costs nothing.
pub async fn upload(State(state): State<AppState>, Query(query): Query<UploadQuery>, request: Request) -> Response {
    let Some(intervals) = state.intervals.as_deref() else {
        return error(
            StatusCode::NOT_FOUND,
            "intervals_disabled",
            "this server has no intervals.icu upload",
        );
    };
    if !from_own_page(request.headers(), &intervals.origin) {
        return error(
            StatusCode::FORBIDDEN,
            "foreign_origin",
            "uploads come from this server's own page only",
        );
    }
    let content_type = request
        .headers()
        .get(header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok());
    if !content_type.is_some_and(is_ride_file_type) {
        return error(
            StatusCode::UNSUPPORTED_MEDIA_TYPE,
            "not_a_ride_file_type",
            "send the ride as a FIT or TCX file",
        );
    }
    let body = match axum::body::to_bytes(request.into_body(), crate::http::MAX_UPLOAD_BYTES).await {
        Ok(body) => body,
        Err(_) => return error(StatusCode::PAYLOAD_TOO_LARGE, "too_large", "the ride file is too large"),
    };
    let Some(ride) = RideFile::detect(&body) else {
        return error(
            StatusCode::BAD_REQUEST,
            "not_a_ride",
            "the ride must be a FIT or TCX file",
        );
    };
    let name: String = query
        .name
        .unwrap_or_else(|| "OpenRadlr".into())
        .chars()
        .filter(|c| !c.is_control())
        .take(100)
        .collect();
    match intervals.upload(ride, &name).await {
        Ok(activity_id) => Json(UploadReply { activity_id }).into_response(),
        Err(IntervalsError::KeyRejected) => {
            tracing::warn!("intervals.icu refused the server's API key");
            error(
                StatusCode::BAD_GATEWAY,
                "intervals_key_rejected",
                "the server's intervals.icu key was refused",
            )
        }
        Err(IntervalsError::Busy) => {
            tracing::warn!("intervals.icu rate limit reached");
            error(
                StatusCode::SERVICE_UNAVAILABLE,
                "intervals_busy",
                "intervals.icu is busy, try again in a few minutes",
            )
        }
        Err(IntervalsError::Failed(reason)) => {
            tracing::warn!(error = %reason, "intervals.icu upload failed");
            error(
                StatusCode::BAD_GATEWAY,
                "upload_failed",
                "intervals.icu didn't accept the upload, try again later",
            )
        }
    }
}

fn from_own_page(headers: &HeaderMap, origin: &str) -> bool {
    let sent = headers.get(header::ORIGIN).and_then(|v| v.to_str().ok());
    sent.is_some_and(|sent| sent != "null" && origin_of(sent) == origin)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn the_key_never_shows_in_debug_output() {
        let config = IntervalsConfig {
            api_key: ApiKey::new("s3cret-key"),
            base_url: DEFAULT_BASE_URL.into(),
            public_url: "http://192.168.1.235:8080".into(),
        };
        assert!(!format!("{config:?}").contains("s3cret-key"));
    }

    #[test]
    fn the_activity_id_is_read_from_either_reply_shape() {
        assert_eq!(activity_id(&json!({ "id": "i42" })), Some("i42".into()));
        assert_eq!(
            activity_id(&json!({ "activities": [{ "id": "i7" }, { "id": "i8" }] })),
            Some("i7".into())
        );
        assert_eq!(activity_id(&json!({ "id": 5 })), Some("5".into()));
    }

    #[test]
    fn a_reply_without_an_id_has_none() {
        assert_eq!(activity_id(&json!({})), None);
        assert_eq!(activity_id(&json!({ "id": "" })), None);
        assert_eq!(activity_id(&json!({ "activities": [] })), None);
        assert_eq!(activity_id(&serde_json::Value::Null), None);
    }

    #[test]
    fn refusals_and_rate_limits_are_told_apart() {
        assert_eq!(IntervalsError::of_status(401), IntervalsError::KeyRejected);
        assert_eq!(IntervalsError::of_status(403), IntervalsError::KeyRejected);
        assert_eq!(IntervalsError::of_status(429), IntervalsError::Busy);
        assert!(matches!(IntervalsError::of_status(500), IntervalsError::Failed(_)));
    }

    #[test]
    fn origins_are_compared_as_browsers_send_them() {
        assert_eq!(origin_of("http://192.168.1.235:8080"), "http://192.168.1.235:8080");
        assert_eq!(origin_of("https://Ride.Example.com/"), "https://ride.example.com");
        assert_eq!(
            origin_of("https://ride.example.com:443/app?x=1"),
            "https://ride.example.com"
        );
        assert_eq!(origin_of("http://home.lan:80"), "http://home.lan");
        assert_ne!(origin_of("http://home.lan:8080"), origin_of("http://home.lan"));
        assert_ne!(origin_of("https://home.lan"), origin_of("http://home.lan"));
    }

    #[test]
    fn only_ride_file_types_are_accepted() {
        assert!(is_ride_file_type("application/vnd.ant.fit"));
        assert!(is_ride_file_type("Application/VND.garmin.tcx+xml; charset=utf-8"));
        assert!(!is_ride_file_type("text/plain"));
        assert!(!is_ride_file_type("application/x-www-form-urlencoded"));
        assert!(!is_ride_file_type("multipart/form-data; boundary=x"));
    }
}
