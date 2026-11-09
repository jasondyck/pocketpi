//! Goal mode's notifications (docs/dsh-features-plan.md §3.1). pocketpi-goal.ts
//! publishes the chat's goal as `setStatus("pp-goal", json)`; the stdout
//! reader feeds every record here so the server can
//! - hold back the per-settle "pi finished" push while a goal is driving
//!   rounds (one push per round would be noise), and
//! - send one push when the goal completes or is blocked (including by its
//!   round or cost cap).

use serde_json::Value;

/// A goal that just finished: what the push says.
#[derive(Debug, PartialEq)]
pub struct Finished {
    pub title: &'static str,
    pub body: String,
}

#[derive(Default)]
pub struct GoalWatch {
    /// The goal's id and phase as last published.
    last: Option<(String, String)>,
    /// Active and armed as last published: rounds keep coming.
    running: bool,
    /// Ran (or finished) at some point since the last settle.
    since_settle: bool,
}

impl GoalWatch {
    /// Looks at one stdout record; Some when it reports a goal finishing.
    pub fn record(&mut self, v: &Value) -> Option<Finished> {
        if v.get("type").and_then(Value::as_str) != Some("extension_ui_request")
            || v.get("method").and_then(Value::as_str) != Some("setStatus")
            || v.get("statusKey").and_then(Value::as_str) != Some("pp-goal")
        {
            return None;
        }
        let goal = v.get("statusText").and_then(Value::as_str).and_then(|t| serde_json::from_str::<Value>(t).ok());
        let Some(g) = goal.filter(Value::is_object) else {
            (self.last, self.running) = (None, false);
            return None;
        };
        let s = |k: &str| g.get(k).and_then(Value::as_str).unwrap_or("").to_string();
        let (id, phase) = (s("id"), s("phase"));
        self.running = phase == "active" && g.get("armed").and_then(Value::as_bool).unwrap_or(false);
        self.since_settle |= self.running;
        let was_active = self.last.as_ref().is_some_and(|(i, p)| *i == id && p == "active");
        self.last = Some((id, phase.clone()));
        if !was_active || !(phase == "complete" || phase == "blocked") {
            return None;
        }
        self.since_settle = true;
        let num = |k: &str| g.get(k).and_then(Value::as_f64).unwrap_or(0.0);
        let stats = format!("{} rounds · ${:.2}", num("rounds"), num("cost"));
        let objective = s("objective");
        Some(if phase == "complete" {
            Finished { title: "Goal complete", body: format!("{objective}\n{stats}") }
        } else {
            let why = match s("blockedReason").as_str() {
                "round-limit" => format!("Used all {} rounds", num("maxRounds")),
                "cost-limit" => format!("Reached the ${:.2} cost cap", num("maxCost")),
                r => r.to_string(),
            };
            Finished { title: "Goal blocked", body: format!("{why}: {objective}\n{stats}") }
        })
    }

    /// At `agent_settled`: true when the per-turn "pi finished" push should
    /// be held back because a goal is (or was, this turn) driving the chat.
    pub fn settled(&mut self) -> bool {
        let hold = self.since_settle || self.running;
        self.since_settle = self.running;
        hold
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn status(g: Option<Value>) -> Value {
        match g {
            Some(g) => json!({"type": "extension_ui_request", "method": "setStatus", "statusKey": "pp-goal", "statusText": g.to_string()}),
            None => json!({"type": "extension_ui_request", "method": "setStatus", "statusKey": "pp-goal"}),
        }
    }
    fn goal(phase: &str, armed: bool, reason: Option<&str>) -> Option<Value> {
        Some(json!({"id": "g1", "revision": 1, "objective": "ship it", "phase": phase, "rounds": 3, "maxRounds": 3,
            "cost": 0.5, "maxCost": 5, "blockedReason": reason, "armed": armed}))
    }

    #[test]
    fn holds_settle_pushes_while_running_and_reports_the_end() {
        let mut w = GoalWatch::default();
        assert!(!w.settled(), "no goal: normal push");
        assert_eq!(w.record(&status(goal("active", true, None))), None);
        assert!(w.settled());
        assert!(w.settled(), "still running");
        let f = w.record(&status(goal("blocked", false, Some("round-limit")))).unwrap();
        assert_eq!(f.title, "Goal blocked");
        assert!(f.body.starts_with("Used all 3 rounds: ship it"), "{}", f.body);
        assert!(w.settled(), "the turn that finished it is held too");
        assert!(!w.settled(), "after that, normal pushes again");
    }

    #[test]
    fn only_a_change_from_active_pushes() {
        let mut w = GoalWatch::default();
        // Replayed state of an already finished goal: nothing.
        assert_eq!(w.record(&status(goal("complete", false, None))), None);
        w.record(&status(goal("active", false, None)));
        assert!(!w.settled(), "disarmed: normal push");
        assert_eq!(w.record(&status(goal("complete", false, None))).unwrap().title, "Goal complete");
        assert_eq!(w.record(&status(goal("complete", false, None))), None, "only once");
        w.record(&status(goal("paused", false, None)));
        assert_eq!(w.record(&status(goal("blocked", false, Some("x")))), None);
        w.record(&status(None));
        assert!(!w.running);
        let other = json!({"type": "extension_ui_request", "method": "setStatus", "statusKey": "pp-todo", "statusText": "{}"});
        assert_eq!(w.record(&other), None);
    }
}
