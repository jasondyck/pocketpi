//! Minimal 5-field cron (minute hour day-of-month month day-of-week) in local
//! time. Supports `*`, lists `a,b`, ranges `a-b`, steps `*/n` and `a-b/n`,
//! and day names / month names are not needed for v1. Sunday is 0 or 7.

use chrono::{Datelike, Local, Timelike};

#[derive(Debug, Clone)]
pub struct Cron {
    min: Vec<bool>,
    hour: Vec<bool>,
    dom: Vec<bool>,
    mon: Vec<bool>,
    dow: Vec<bool>,
    dom_any: bool,
    dow_any: bool,
}

fn field(spec: &str, lo: u32, hi: u32, name: &str) -> Result<Vec<bool>, String> {
    let mut set = vec![false; (hi + 1) as usize];
    for part in spec.split(',') {
        let (range, step) = match part.split_once('/') {
            Some((r, s)) => (r, s.parse::<u32>().map_err(|_| format!("bad step in {name}"))?),
            None => (part, 1),
        };
        if step == 0 {
            return Err(format!("zero step in {name}"));
        }
        let (a, b) = if range == "*" {
            (lo, hi)
        } else if let Some((a, b)) = range.split_once('-') {
            (a.parse().map_err(|_| format!("bad {name}"))?, b.parse().map_err(|_| format!("bad {name}"))?)
        } else {
            let v: u32 = range.parse().map_err(|_| format!("bad {name} value {range:?}"))?;
            (v, if part.contains('/') { hi } else { v })
        };
        if a < lo || b > hi || a > b {
            return Err(format!("{name} out of range {lo}-{hi}"));
        }
        let mut v = a;
        while v <= b {
            set[v as usize] = true;
            v += step;
        }
    }
    Ok(set)
}

impl Cron {
    pub fn parse(expr: &str) -> Result<Cron, String> {
        let f: Vec<&str> = expr.split_whitespace().collect();
        if f.len() != 5 {
            return Err("cron needs 5 fields: minute hour day-of-month month day-of-week".into());
        }
        let mut dow = field(f[4], 0, 7, "day-of-week")?;
        if dow[7] {
            dow[0] = true;
        }
        Ok(Cron {
            min: field(f[0], 0, 59, "minute")?,
            hour: field(f[1], 0, 23, "hour")?,
            dom: field(f[2], 1, 31, "day-of-month")?,
            mon: field(f[3], 1, 12, "month")?,
            dow,
            dom_any: f[2] == "*",
            dow_any: f[4] == "*",
        })
    }

    /// Standard cron day matching: if both day fields are restricted, either may match.
    pub fn matches(&self, t: &chrono::DateTime<Local>) -> bool {
        let dom_ok = self.dom[t.day() as usize];
        let dow_ok = self.dow[t.weekday().num_days_from_sunday() as usize];
        let day_ok = match (self.dom_any, self.dow_any) {
            (true, true) => true,
            (false, true) => dom_ok,
            (true, false) => dow_ok,
            (false, false) => dom_ok || dow_ok,
        };
        self.min[t.minute() as usize] && self.hour[t.hour() as usize] && self.mon[t.month() as usize] && day_ok
    }

    /// Next matching minute after `from` (searches up to a year).
    pub fn next_after(&self, from: chrono::DateTime<Local>) -> Option<chrono::DateTime<Local>> {
        let mut t = from.with_second(0)?.with_nanosecond(0)? + chrono::Duration::minutes(1);
        for _ in 0..(366 * 24 * 60) {
            if self.matches(&t) {
                return Some(t);
            }
            t += chrono::Duration::minutes(1);
        }
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    #[test]
    fn parses_and_matches() {
        let c = Cron::parse("30 3 * * 1-5").unwrap();
        let mon = Local.with_ymd_and_hms(2026, 11, 2, 3, 30, 0).unwrap(); // Monday
        let sun = Local.with_ymd_and_hms(2026, 11, 1, 3, 30, 0).unwrap();
        assert!(c.matches(&mon));
        assert!(!c.matches(&sun));
        let every15 = Cron::parse("*/15 * * * *").unwrap();
        assert!(every15.matches(&Local.with_ymd_and_hms(2026, 1, 1, 10, 45, 0).unwrap()));
        assert!(!every15.matches(&Local.with_ymd_and_hms(2026, 1, 1, 10, 46, 0).unwrap()));
        assert!(Cron::parse("61 * * * *").is_err());
        assert!(Cron::parse("* * *").is_err());
        let next = c.next_after(sun).unwrap();
        assert_eq!(next, mon);
    }
}
