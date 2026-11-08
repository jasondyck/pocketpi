//! What pi's extensions have put on screen with the fire-and-forget
//! `extension_ui_request`s (`setStatus`, `setWidget`, `setTitle`), kept per
//! live pi so a client that connects later still sees it: `pocketpi_hello`
//! carries the requests as `ui`, and clients replay them like live events.
//! A new pi (restart, reopen) starts with nothing, like pi itself.

use serde_json::Value;

#[derive(Default)]
pub struct ExtUi {
    /// The latest request per slot (`status:<key>`, `widget:<key>`,
    /// `title`), in the order the slots were first set.
    slots: Vec<(String, Value)>,
}

impl ExtUi {
    /// Remember (or forget, for a clear) one `extension_ui_request`; other
    /// methods are ignored.
    pub fn record(&mut self, req: &Value) {
        let s = |k: &str| req.get(k).and_then(Value::as_str);
        let (slot, clear) = match s("method") {
            Some("setStatus") => (format!("status:{}", s("statusKey").unwrap_or("")), s("statusText").is_none()),
            Some("setWidget") => (
                format!("widget:{}", s("widgetKey").unwrap_or("")),
                !req.get("widgetLines").is_some_and(Value::is_array),
            ),
            Some("setTitle") => ("title".to_string(), false),
            _ => return,
        };
        let at = self.slots.iter().position(|(k, _)| *k == slot);
        match (at, clear) {
            (Some(i), true) => {
                self.slots.remove(i);
            }
            (Some(i), false) => self.slots[i].1 = req.clone(),
            (None, false) => self.slots.push((slot, req.clone())),
            (None, true) => {}
        }
    }

    pub fn replay(&self) -> Vec<Value> {
        self.slots.iter().map(|(_, v)| v.clone()).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn keeps_latest_per_key_and_forgets_clears() {
        let mut ui = ExtUi::default();
        ui.record(&json!({"method": "setStatus", "statusKey": "a", "statusText": "one"}));
        ui.record(&json!({"method": "setStatus", "statusKey": "b", "statusText": "two"}));
        ui.record(&json!({"method": "setStatus", "statusKey": "a", "statusText": "three"}));
        ui.record(&json!({"method": "setWidget", "widgetKey": "w", "widgetLines": ["x"], "widgetPlacement": "belowEditor"}));
        ui.record(&json!({"method": "setTitle", "title": "pi - demo"}));
        ui.record(&json!({"method": "confirm", "id": "1", "title": "?"}));
        ui.record(&json!({"method": "notify", "message": "hi"}));
        let r = ui.replay();
        assert_eq!(r.len(), 4);
        assert_eq!(r[0]["statusText"], "three");
        assert_eq!(r[1]["statusKey"], "b");
        assert_eq!(r[3]["title"], "pi - demo");

        ui.record(&json!({"method": "setStatus", "statusKey": "b"}));
        ui.record(&json!({"method": "setWidget", "widgetKey": "w"}));
        ui.record(&json!({"method": "setStatus", "statusKey": "never-set"}));
        let r = ui.replay();
        assert_eq!(r.len(), 2);
        assert_eq!(r[0]["statusKey"], "a");
        assert_eq!(r[1]["method"], "setTitle");
    }
}
