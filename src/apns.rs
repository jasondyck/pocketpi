//! Apple Push Notification service, for the native iOS app (ios/). Sits next
//! to web push: `Push::send` delivers to both.
//!
//! The provider key is the .p8 from developer.apple.com (Keys, APNs), kept in
//! ~/.config/pocketpi/apns/AuthKey_<KEYID>.p8 (0600); the Key ID comes from the
//! file name. Team and topic (the app's bundle id) default to the app's and can
//! be overridden with POCKETPI_APNS_TEAM / POCKETPI_APNS_TOPIC. Without a key,
//! APNs is simply off. Device tokens live in ~/.local/share/pocketpi/apns.json.
//!
//! Debug builds of the app get sandbox tokens and TestFlight/App Store builds
//! production ones; the app says which it has, and a token the other service
//! rejects as BadDeviceToken is retried there once and remembered.

use serde::{Deserialize, Serialize};
use serde_json::json;
use std::path::{Path, PathBuf};
use std::sync::Mutex as StdMutex;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use web_push_native::jwt_simple::algorithms::{ECDSAP256KeyPairLike, ES256KeyPair};
use web_push_native::jwt_simple::claims::Claims;

const DEFAULT_TEAM: &str = "57YB5MQBTL";
const DEFAULT_TOPIC: &str = "ca.caldron.pocketpi";
/// Apple refuses tokens older than an hour and throttles ones renewed more
/// often than every 20 minutes.
const JWT_LIFETIME: u64 = 50 * 60;

#[derive(Serialize, Deserialize, Clone, Copy, PartialEq, Eq, Debug, Default)]
#[serde(rename_all = "lowercase")]
pub enum Env {
    #[default]
    Production,
    Sandbox,
}

impl Env {
    fn host(self) -> &'static str {
        match self {
            Env::Production => "https://api.push.apple.com",
            Env::Sandbox => "https://api.sandbox.push.apple.com",
        }
    }
    fn other(self) -> Env {
        match self {
            Env::Production => Env::Sandbox,
            Env::Sandbox => Env::Production,
        }
    }
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct Device {
    pub token: String,
    #[serde(default)]
    pub env: Env,
    #[serde(default)]
    pub label: String,
    #[serde(default)]
    pub created: u64,
}

pub struct Apns {
    key: ES256KeyPair,
    pub key_id: String,
    team: String,
    topic: String,
    devices_path: PathBuf,
    devices: StdMutex<Vec<Device>>,
    jwt: StdMutex<Option<(String, u64)>>,
    http: reqwest::Client,
}

enum Outcome {
    Sent,
    /// The token is dead (Unregistered) or unknown to both services.
    Gone,
    /// The token belongs to the other service.
    WrongEnv,
    Failed,
}

fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs()
}

/// APNs device tokens are hex; 32 bytes today, and Apple says not to assume
/// the length.
pub fn valid_token(t: &str) -> bool {
    (32..=200).contains(&t.len()) && t.len() % 2 == 0 && t.bytes().all(|b| b.is_ascii_hexdigit())
}

/// The first AuthKey_<KEYID>.p8 in the folder, with its Key ID.
fn find_key(dir: &Path) -> Option<(String, String)> {
    let mut entries: Vec<_> = std::fs::read_dir(dir).ok()?.flatten().map(|e| e.path()).collect();
    entries.sort();
    for p in entries {
        let name = p.file_name()?.to_str()?;
        if let Some(id) = name.strip_prefix("AuthKey_").and_then(|r| r.strip_suffix(".p8")) {
            if !id.is_empty() {
                if let Ok(pem) = std::fs::read_to_string(&p) {
                    return Some((id.to_string(), pem));
                }
            }
        }
    }
    None
}

impl Apns {
    /// None when there's no key (APNs off) or the key doesn't load.
    pub fn load(config_dir: &Path, data_dir: &Path) -> Option<Apns> {
        let (key_id, pem) = find_key(&config_dir.join("apns"))?;
        let key = match ES256KeyPair::from_pem(&pem) {
            Ok(k) => k.with_key_id(&key_id),
            Err(e) => {
                eprintln!("apns: AuthKey_{key_id}.p8 doesn't load: {e}");
                return None;
            }
        };
        let devices_path = data_dir.join("apns.json");
        let devices = std::fs::read_to_string(&devices_path)
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_default();
        let _ = rustls::crypto::ring::default_provider().install_default();
        eprintln!("apns: key {key_id} loaded");
        Some(Apns {
            key,
            key_id,
            team: std::env::var("POCKETPI_APNS_TEAM").unwrap_or_else(|_| DEFAULT_TEAM.into()),
            topic: std::env::var("POCKETPI_APNS_TOPIC").unwrap_or_else(|_| DEFAULT_TOPIC.into()),
            devices_path,
            devices: StdMutex::new(devices),
            jwt: StdMutex::new(None),
            http: reqwest::Client::builder()
                .timeout(Duration::from_secs(15))
                .http2_prior_knowledge()
                .build()
                .expect("http client"),
        })
    }

    fn save(&self) {
        let devices = self.devices.lock().unwrap();
        if let Ok(b) = serde_json::to_vec_pretty(&*devices) {
            let _ = crate::push::write_private(&self.devices_path, &b);
        }
    }

    pub fn register(&self, token: &str, env: Env, label: &str) {
        {
            let mut d = self.devices.lock().unwrap();
            d.retain(|x| !x.token.eq_ignore_ascii_case(token));
            d.push(Device { token: token.to_ascii_lowercase(), env, label: label.to_string(), created: now() });
        }
        self.save();
    }

    pub fn unregister(&self, token: &str) {
        self.devices.lock().unwrap().retain(|x| !x.token.eq_ignore_ascii_case(token));
        self.save();
    }

    pub fn count(&self) -> usize {
        self.devices.lock().unwrap().len()
    }

    /// The provider token: `{alg, kid}` / `{iss, iat}`, signed with the .p8,
    /// reused until it is 50 minutes old.
    fn bearer(&self) -> Option<String> {
        let mut cached = self.jwt.lock().unwrap();
        if let Some((t, at)) = cached.as_ref() {
            if now() - at < JWT_LIFETIME {
                return Some(t.clone());
            }
        }
        let mut claims = Claims::create(web_push_native::jwt_simple::prelude::Duration::from_hours(1)).with_issuer(&self.team);
        claims.expires_at = None;
        claims.invalid_before = None;
        let t = self.key.sign(claims).map_err(|e| eprintln!("apns: signing: {e}")).ok()?;
        *cached = Some((t.clone(), now()));
        Some(t)
    }

    /// Sends to every registered device; returns how many accepted it.
    pub async fn send(&self, title: &str, body: &str, url: &str, tag: &str) -> usize {
        let payload = json!({
            "aps": {
                "alert": { "title": title, "body": body },
                "sound": "default",
                "thread-id": tag,
            },
            "url": url,
        })
        .to_string();
        let devices: Vec<Device> = self.devices.lock().unwrap().clone();
        let mut delivered = 0;
        let mut gone = Vec::new();
        let mut moved = Vec::new();
        for d in devices {
            match self.send_one(&d.token, d.env, &payload, tag).await {
                Outcome::Sent => delivered += 1,
                Outcome::Gone => gone.push(d.token.clone()),
                Outcome::WrongEnv => match self.send_one(&d.token, d.env.other(), &payload, tag).await {
                    Outcome::Sent => {
                        delivered += 1;
                        moved.push(d.token.clone());
                    }
                    Outcome::Gone | Outcome::WrongEnv => gone.push(d.token.clone()),
                    Outcome::Failed => {}
                },
                Outcome::Failed => {}
            }
        }
        if !gone.is_empty() || !moved.is_empty() {
            let mut list = self.devices.lock().unwrap();
            list.retain(|d| !gone.contains(&d.token));
            for d in list.iter_mut().filter(|d| moved.contains(&d.token)) {
                d.env = d.env.other();
            }
            drop(list);
            self.save();
        }
        delivered
    }

    async fn send_one(&self, token: &str, env: Env, payload: &str, tag: &str) -> Outcome {
        let Some(bearer) = self.bearer() else { return Outcome::Failed };
        let mut req = self
            .http
            .post(format!("{}/3/device/{token}", env.host()))
            .header("authorization", format!("bearer {bearer}"))
            .header("apns-topic", &self.topic)
            .header("apns-push-type", "alert")
            .header("apns-priority", "10")
            .body(payload.to_string());
        if !tag.is_empty() && tag.len() <= 64 {
            // A newer notification with the same tag replaces the older one.
            req = req.header("apns-collapse-id", tag);
        }
        let res = match req.send().await {
            Ok(r) => r,
            Err(e) => {
                eprintln!("apns send: {e}");
                return Outcome::Failed;
            }
        };
        let status = res.status().as_u16();
        if status == 200 {
            return Outcome::Sent;
        }
        let reason = res
            .bytes()
            .await
            .ok()
            .and_then(|b| serde_json::from_slice::<serde_json::Value>(&b).ok())
            .and_then(|v| v.get("reason").and_then(|r| r.as_str()).map(String::from))
            .unwrap_or_default();
        match (status, reason.as_str()) {
            (410, _) | (400, "DeviceTokenNotForTopic") => Outcome::Gone,
            (400, "BadDeviceToken") => Outcome::WrongEnv,
            (403, "ExpiredProviderToken") | (403, "InvalidProviderToken") => {
                *self.jwt.lock().unwrap() = None;
                eprintln!("apns: {reason} (key {}, team {})", self.key_id, self.team);
                Outcome::Failed
            }
            _ => {
                eprintln!("apns: {status} {reason}");
                Outcome::Failed
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64ct::{Base64UrlUnpadded, Encoding};
    use web_push_native::jwt_simple::algorithms::ECDSAP256PublicKeyLike;

    fn scratch(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("pocketpi-apns-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(d.join("apns")).unwrap();
        d
    }

    #[test]
    fn provider_token_has_only_what_apple_wants() {
        let dir = scratch("jwt");
        let k = ES256KeyPair::generate();
        std::fs::write(dir.join("apns/AuthKey_ABCDE12345.p8"), k.to_pem().unwrap()).unwrap();
        let a = Apns::load(&dir, &dir).expect("loads");
        assert_eq!(a.key_id, "ABCDE12345");
        let t = a.bearer().unwrap();
        assert_eq!(a.bearer().unwrap(), t, "cached");
        let parts: Vec<_> = t.split('.').collect();
        let header: serde_json::Value = serde_json::from_slice(&Base64UrlUnpadded::decode_vec(parts[0]).unwrap()).unwrap();
        let claims: serde_json::Value = serde_json::from_slice(&Base64UrlUnpadded::decode_vec(parts[1]).unwrap()).unwrap();
        assert_eq!(header["alg"], "ES256");
        assert_eq!(header["kid"], "ABCDE12345");
        let keys: Vec<_> = claims.as_object().unwrap().keys().cloned().collect();
        assert_eq!(keys, vec!["iat".to_string(), "iss".to_string()]);
        assert_eq!(claims["iss"], DEFAULT_TEAM);
        // And it verifies with the key's public half.
        k.public_key().verify_token::<web_push_native::jwt_simple::claims::NoCustomClaims>(&t, None).unwrap();
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn devices_persist_and_dedupe() {
        let dir = scratch("dev");
        std::fs::write(dir.join("apns/AuthKey_ABCDE12345.p8"), ES256KeyPair::generate().to_pem().unwrap()).unwrap();
        let a = Apns::load(&dir, &dir).unwrap();
        let tok = "ab".repeat(32);
        a.register(&tok, Env::Sandbox, "phone");
        a.register(&tok.to_uppercase(), Env::Sandbox, "phone");
        assert_eq!(a.count(), 1);
        let b = Apns::load(&dir, &dir).unwrap();
        assert_eq!(b.count(), 1);
        b.unregister(&tok);
        assert_eq!(Apns::load(&dir, &dir).unwrap().count(), 0);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn no_key_means_off() {
        let dir = scratch("off");
        assert!(Apns::load(&dir, &dir).is_none());
        let _ = std::fs::remove_dir_all(dir);
    }

    /// Real key, real Apple, fake device: Apple says BadDeviceToken only when
    /// it accepted the provider token (key, Key ID, team). Run by hand:
    /// `cargo test apns_credentials -- --ignored --nocapture`
    #[tokio::test]
    #[ignore]
    async fn apns_credentials_are_accepted() {
        let home = PathBuf::from(std::env::var("HOME").unwrap());
        let scratch = scratch("live");
        let a = Apns::load(&home.join(".config/pocketpi"), &scratch).expect("key in ~/.config/pocketpi/apns");
        for env in [Env::Sandbox, Env::Production] {
            let res = a
                .http
                .post(format!("{}/3/device/{}", env.host(), "00".repeat(32)))
                .header("authorization", format!("bearer {}", a.bearer().unwrap()))
                .header("apns-topic", &a.topic)
                .header("apns-push-type", "alert")
                .body(r#"{"aps":{"alert":"test"}}"#)
                .send()
                .await
                .unwrap();
            let status = res.status().as_u16();
            let body = String::from_utf8_lossy(&res.bytes().await.unwrap()).to_string();
            println!("{env:?}: {status} {body}");
            assert!(body.contains("BadDeviceToken"), "{env:?}: {status} {body}");
        }
        let _ = std::fs::remove_dir_all(scratch);
    }

    #[test]
    fn token_shape() {
        assert!(valid_token(&"0f".repeat(32)));
        assert!(!valid_token("abc"));
        assert!(!valid_token(&"zz".repeat(32)));
        assert!(!valid_token(&"0".repeat(65)));
    }
}
