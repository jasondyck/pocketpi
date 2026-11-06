//! Web Push (RFC 8030/8291/8292) to the user's phone. The VAPID key pair is
//! generated on first start and kept in ~/.local/share/pocketpi/vapid.key
//! (0600); subscriptions live next to it in push.json. Subscriptions the push
//! service reports as gone (404/410) are dropped.

use base64ct::{Base64UrlUnpadded, Encoding};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::path::PathBuf;
use std::sync::Mutex as StdMutex;
use web_push_native::jwt_simple::algorithms::{ECDSAP256PublicKeyLike, ES256KeyPair};
use web_push_native::{Auth, WebPushBuilder, p256};

#[derive(Serialize, Deserialize, Clone)]
pub struct Sub {
    pub endpoint: String,
    pub p256dh: String,
    pub auth: String,
    #[serde(default)]
    pub label: String,
    #[serde(default)]
    pub created: u64,
}

pub struct Push {
    key: ES256KeyPair,
    pub public_key: String,
    subs_path: PathBuf,
    subs: StdMutex<Vec<Sub>>,
    http: reqwest::Client,
    contact: String,
    /// The native app's notifications, when an APNs key is installed.
    pub apns: Option<crate::apns::Apns>,
}

pub(crate) fn write_private(path: &PathBuf, bytes: &[u8]) -> std::io::Result<()> {
    use std::io::Write;
    #[cfg(unix)]
    use std::os::unix::fs::OpenOptionsExt;
    let tmp = path.with_extension("tmp");
    let mut opts = std::fs::OpenOptions::new();
    opts.write(true).create(true).truncate(true);
    #[cfg(unix)]
    opts.mode(0o600);
    let mut f = opts.open(&tmp)?;
    f.write_all(bytes)?;
    std::fs::rename(tmp, path)
}

impl Push {
    pub fn new(home: &std::path::Path) -> Push {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let data = std::env::var("XDG_DATA_HOME").map(PathBuf::from).unwrap_or_else(|_| home.join(".local/share")).join("pocketpi");
        let _ = std::fs::create_dir_all(&data);
        let key_path = data.join("vapid.key");
        let key = std::fs::read_to_string(&key_path)
            .ok()
            .and_then(|s| Base64UrlUnpadded::decode_vec(s.trim()).ok())
            .and_then(|b| ES256KeyPair::from_bytes(&b).ok())
            .unwrap_or_else(|| {
                let k = ES256KeyPair::generate();
                let _ = write_private(&key_path, Base64UrlUnpadded::encode_string(&k.to_bytes()).as_bytes());
                k
            });
        let public_key = Base64UrlUnpadded::encode_string(&key.public_key().public_key().to_bytes_uncompressed());
        let subs_path = data.join("push.json");
        let subs = std::fs::read_to_string(&subs_path).ok().and_then(|s| serde_json::from_str(&s).ok()).unwrap_or_default();
        let config = std::env::var("XDG_CONFIG_HOME").map(PathBuf::from).unwrap_or_else(|_| home.join(".config")).join("pocketpi");
        let apns = crate::apns::Apns::load(&config, &data);
        Push {
            apns,
            key,
            public_key,
            subs_path,
            subs: StdMutex::new(subs),
            http: reqwest::Client::builder().timeout(std::time::Duration::from_secs(15)).build().expect("http client"),
            contact: std::env::var("POCKETPI_PUSH_CONTACT").unwrap_or_else(|_| "mailto:pocketpi@localhost".into()),
        }
    }

    fn save(&self) {
        let subs = self.subs.lock().unwrap();
        if let Ok(b) = serde_json::to_vec_pretty(&*subs) {
            let _ = write_private(&self.subs_path, &b);
        }
    }

    pub fn subscribe(&self, sub: Sub) {
        {
            let mut subs = self.subs.lock().unwrap();
            subs.retain(|s| s.endpoint != sub.endpoint);
            subs.push(sub);
        }
        self.save();
    }

    pub fn unsubscribe(&self, endpoint: &str) {
        self.subs.lock().unwrap().retain(|s| s.endpoint != endpoint);
        self.save();
    }

    pub fn has(&self, endpoint: &str) -> bool {
        self.subs.lock().unwrap().iter().any(|s| s.endpoint == endpoint)
    }

    pub fn count(&self) -> usize {
        self.subs.lock().unwrap().len()
    }

    /// Sends to every web push subscription and every iOS app device. `url`
    /// is opened when the notification is tapped.
    pub async fn send(&self, title: &str, body: &str, url: &str, tag: &str) -> usize {
        let native = match &self.apns {
            Some(a) => a.send(title, body, url, tag).await,
            None => 0,
        };
        native + self.send_web(title, body, url, tag).await
    }

    async fn send_web(&self, title: &str, body: &str, url: &str, tag: &str) -> usize {
        let payload = json!({ "title": title, "body": body, "url": url, "tag": tag }).to_string();
        let subs: Vec<Sub> = self.subs.lock().unwrap().clone();
        let mut delivered = 0;
        let mut gone = Vec::new();
        for s in subs {
            match self.send_one(&s, &payload).await {
                Ok(()) => delivered += 1,
                Err(Some(code)) if code == 404 || code == 410 => gone.push(s.endpoint.clone()),
                Err(code) => eprintln!("push to {}: failed ({code:?})", s.label),
            }
        }
        if !gone.is_empty() {
            self.subs.lock().unwrap().retain(|s| !gone.contains(&s.endpoint));
            self.save();
        }
        delivered
    }

    async fn send_one(&self, s: &Sub, payload: &str) -> Result<(), Option<u16>> {
        let endpoint = s.endpoint.parse().map_err(|_| None)?;
        let p256dh = Base64UrlUnpadded::decode_vec(&s.p256dh).map_err(|_| None)?;
        let auth = Base64UrlUnpadded::decode_vec(&s.auth).map_err(|_| None)?;
        if auth.len() != 16 {
            return Err(None);
        }
        let pk = p256::PublicKey::from_sec1_bytes(&p256dh).map_err(|_| None)?;
        let req = WebPushBuilder::new(endpoint, pk, Auth::clone_from_slice(&auth))
            .with_vapid(&self.key, &self.contact)
            .build(payload.as_bytes().to_vec())
            .map_err(|_| None)?;
        let mut rb = self.http.post(req.uri().to_string()).body(req.body().clone());
        for (k, v) in req.headers() {
            rb = rb.header(k.as_str(), v.as_bytes());
        }
        // Apple's push service wants an urgency hint to wake the phone promptly.
        rb = rb.header("Urgency", "high");
        let res = rb.send().await.map_err(|e| {
            eprintln!("push send: {e}");
            None
        })?;
        let code = res.status().as_u16();
        if res.status().is_success() { Ok(()) } else { Err(Some(code)) }
    }
}

pub fn sub_from_json(v: &Value, label: &str) -> Option<Sub> {
    Some(Sub {
        endpoint: v.get("endpoint")?.as_str()?.to_string(),
        p256dh: v.pointer("/keys/p256dh")?.as_str()?.to_string(),
        auth: v.pointer("/keys/auth")?.as_str()?.to_string(),
        label: label.to_string(),
        created: std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs(),
    })
}
