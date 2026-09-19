//! `tb.pairing.pair` — who plays whom, and on which map.
//!
//! Pure and seeded: the same demand document and the same occurrence id propose the same plan,
//! which is what lets a retried occurrence be harmless and an audit ask "why this opponent".
//!
//! It decides *quality*, never correctness. Every rule here could be replaced by "pick uniformly"
//! and the ladder would still be right, only slower to learn — the correctness lives in the insert
//! statement (pair's `insert`), which derives the hashes, the ladders and the contesting
//! check itself and refuses anything paired against a roster that has since moved. That division
//! is what lets this plugin be tuned freely.
//!
//! **Input** is the demand document (pair's `demand` read) plus the policy knobs:
//!
//! ```json
//! { "demand": { "room": 12, "wants": [...], "pool": [...], "played": [...],
//!               "limits": { "maps": [ { "id": "<season_maps.id>", "players": 2 }, ... ] } },
//!   "cross_class_fraction": 0.20,
//!   "seed": "<the occurrence id>" }
//! ```
//!
//! **The map decides the seat count**, not the game — so the map is chosen first and the opponents
//! drawn afterwards. The maps are the season's ENABLED boards, read by pair on every
//! run, because an admin may change them while the season is live; there is no deploy list to fall
//! back to, so a season with none enabled is refused here and pairs nothing.
//!
//! **Output** is the plan, in the shape pair's insert loop walks:
//!
//! ```json
//! { "n": 2, "pairings": [ { "seats": ["<a>", "<b>", "<c>", "<d>"], "map": "<id>", "seed": 12 } ] }
//! ```
//!
//! Trials are not here: pair prepends them from SQL (its `trials` read), so a waiting candidate
//! is never crowded out by the queue and the choice cannot depend on this plugin's state.

mod choose;

use choose::{Entry, Input, Map, Rating, Rng, Want};
use serde_json::{Value, json};
use std::collections::HashMap;

#[derive(Debug, PartialEq)]
pub struct Fault {
    pub code: &'static str,
    pub message: String,
}

impl Fault {
    fn new(code: &'static str, message: impl Into<String>) -> Fault {
        Fault { code, message: message.into() }
    }
}

pub const FUNCTION: &str = "tb.pairing.pair";

pub fn invoke(function: &str, input: Value) -> Result<Value, Fault> {
    match function {
        FUNCTION => pair(&input),
        other => Err(Fault::new(
            "UNKNOWN_FUNCTION",
            format!("this component exports no '{other}', only '{FUNCTION}'"),
        )),
    }
}

fn ratings_of(v: &Value) -> Vec<Rating> {
    v.get("ratings")
        .and_then(Value::as_array)
        .map(|rs| {
            rs.iter()
                .filter_map(|r| {
                    Some(Rating {
                        ladder: r.get("ladder")?.as_str()?.to_string(),
                        mu: r.get("mu")?.as_f64()?,
                        sigma: r.get("sigma")?.as_f64()?,
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

fn pair(input: &Value) -> Result<Value, Fault> {
    let demand = input
        .get("demand")
        .filter(|d| d.is_object())
        .ok_or_else(|| Fault::new("BAD_DEMAND", "'demand' must be the demand document"))?;

    // No room is not an error: the queue is at its depth target, or nothing wants a match. It is
    // the ordinary state of a settled ladder, and it must cost one empty plan, not a refusal.
    let room = demand.get("room").and_then(Value::as_i64).unwrap_or(0).max(0) as usize;

    // Each map carries the number of seats it is played at: the map decides the seat count, not
    // the game. They are the season's enabled boards, each `{id, players}`; one declaring fewer
    // than two seats is a refusal, because there is no match to play on it.
    let limits = demand.get("limits").filter(|l| l.is_object());
    let maps: Vec<Map> = limits
        .and_then(|l| l.get("maps"))
        .and_then(Value::as_array)
        .map(|a| {
            a.iter()
                .filter_map(|m| {
                    Some(Map {
                        id: m.get("id")?.as_str()?.to_string(),
                        players: m.get("players")?.as_u64()? as usize,
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    if maps.is_empty() {
        return Err(Fault::new(
            "NO_MAPS",
            "the season has no enabled map; a match has to be played on something",
        ));
    }
    if let Some(bad) = maps.iter().find(|m| m.players < 2) {
        return Err(Fault::new(
            "BAD_MAP",
            format!("map '{}' declares {} seats; a match needs at least two", bad.id, bad.players),
        ));
    }

    let cross_class_fraction = limits
        .and_then(|l| l.get("cross_class_fraction"))
        .or_else(|| input.get("cross_class_fraction"))
        .and_then(Value::as_f64)
        .unwrap_or(0.0);

    // Absent is false: a season that says nothing about self-pairing does not permit it.
    let self_pairing =
        limits.and_then(|l| l.get("self_pairing")).and_then(Value::as_bool).unwrap_or(false);
    if !(0.0..=1.0).contains(&cross_class_fraction) {
        return Err(Fault::new(
            "BAD_FRACTION",
            "'cross_class_fraction' must be between zero and one inclusive",
        ));
    }

    // Refused rather than defaulted: a plugin that silently paired from a fixed seed would look
    // identical until someone tried to replay a decision.
    let seed =
        input.get("seed").and_then(Value::as_str).filter(|s| !s.is_empty()).ok_or_else(|| {
            Fault::new("NO_SEED", "'seed' must be a non-empty string, normally the occurrence id")
        })?;

    let wants: Vec<Want> = demand
        .get("wants")
        .and_then(Value::as_array)
        .map(|a| {
            a.iter()
                .filter_map(|w| {
                    Some(Want {
                        model_id: w.get("model_id")?.as_str()?.to_string(),
                        want: w.get("want")?.as_i64()?,
                    })
                })
                .collect()
        })
        .unwrap_or_default();

    let pool: Vec<Entry> = demand
        .get("pool")
        .and_then(Value::as_array)
        .map(|a| {
            a.iter()
                .filter_map(|e| {
                    Some(Entry {
                        model_id: e.get("model_id")?.as_str()?.to_string(),
                        // SKIPPED, not defaulted, when absent: an entry whose owner cannot be
                        // established cannot be proven distinct from anyone else's, and a shared
                        // default would make every such entry the same competitor.
                        owner_id: e.get("owner_id")?.as_str()?.to_string(),
                        weight_class: e
                            .get("weight_class")
                            .and_then(Value::as_str)
                            .unwrap_or("")
                            .to_string(),
                        ratings: ratings_of(e),
                    })
                })
                .collect()
        })
        .unwrap_or_default();

    let mut played: HashMap<String, HashMap<String, i64>> = HashMap::new();
    if let Some(rows) = demand.get("played").and_then(Value::as_array) {
        for r in rows {
            if let (Some(m), Some(p), Some(n)) = (
                r.get("model_id").and_then(Value::as_str),
                r.get("map").and_then(Value::as_str),
                r.get("n").and_then(Value::as_i64),
            ) {
                played.entry(m.to_string()).or_default().insert(p.to_string(), n);
            }
        }
    }

    // owner_id -> seats left. Absent from the array means uncapped, so an empty map is the
    // uncapped roster and needs no special case.
    let mut owner_room: HashMap<String, i64> = HashMap::new();
    if let Some(rows) = demand.get("owners").and_then(Value::as_array) {
        for r in rows {
            if let (Some(o), Some(n)) =
                (r.get("owner_id").and_then(Value::as_str), r.get("room").and_then(Value::as_i64))
            {
                owner_room.insert(o.to_string(), n);
            }
        }
    }

    let plan = choose::choose(
        &Input { room, wants, pool, played, maps, cross_class_fraction, self_pairing, owner_room },
        &mut Rng::from_str(seed),
    );

    Ok(json!({
        "n": plan.len(),
        "pairings": plan.iter().map(|p| json!({
            "seats": p.seats,
            "map": p.map,
            "seed": p.seed,
        })).collect::<Vec<_>>(),
    }))
}

#[cfg(target_arch = "wasm32")]
mod exported {
    use orion_plugin_sdk::{Plugin, PluginError, export_plugin, serde_json::Value};

    struct TbPairing;

    impl Plugin for TbPairing {
        fn invoke(function: &str, input: Value) -> Result<Value, PluginError> {
            super::invoke(function, input).map_err(|f| PluginError::caller_input(f.code, f.message))
        }
    }

    export_plugin!(TbPairing);
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The owner defaults to the model id, which is what today's roster looks like: one model per
    /// competitor means the two are the same string.
    fn model(id: &str, class: &str, role: &str, mu: f64, sigma: f64) -> Value {
        json!({ "model_id": id, "owner_id": id, "weight_class": class, "role": role,
                "ratings": [ {"ladder": class, "mu": mu, "sigma": sigma},
                             {"ladder": "open", "mu": mu, "sigma": sigma} ] })
    }

    fn two_seats(ids: &[&str]) -> Value {
        json!(ids.iter().map(|id| json!({ "id": id, "players": 2 })).collect::<Vec<_>>())
    }

    fn doc(room: i64) -> Value {
        json!({
            "demand": {
                "demand": 6, "depth": 0, "room": room,
                "wants": [ { "model_id": "a", "weight_class": "nano", "role": "competitor",
                             "state": "placement", "sigma": 8.3, "played": 0, "in_flight": 0,
                             "want": 6 } ],
                "pool": [ model("a", "nano", "competitor", 25.0, 8.3),
                          model("base", "nano", "baseline", 25.0, 3.0) ],
                "played": [],
                // The season's pairing policy travels INSIDE the demand document, and so do its
                // boards: the season's enabled maps, which are the only source there is.
                "limits": { "self_pairing": false, "cross_class_fraction": 0.20,
                            "maps": two_seats(&["standard", "maze", "cell"]) },
                "owners": []
            },
            "cross_class_fraction": 0.20,
            "seed": "occ-1"
        })
    }

    #[test]
    fn the_plan_is_in_the_shape_pair_inserts() {
        let out = invoke(FUNCTION, doc(3)).unwrap();
        assert_eq!(out["n"], 3);
        let ps = out["pairings"].as_array().unwrap();
        assert_eq!(ps.len(), 3);
        for p in ps {
            assert_eq!(p["seats"].as_array().unwrap().len(), 2);
            assert!(p["map"].as_str().is_some());
            assert!(p["seed"].as_i64().unwrap() >= 0);
            assert_ne!(p["seats"][0], p["seats"][1]);
        }
    }

    #[test]
    fn an_empty_ladder_is_an_empty_plan_not_a_refusal() {
        // The ordinary state of a settled ladder: nothing wants a match, so nothing is paired.
        assert_eq!(invoke(FUNCTION, doc(0)).unwrap(), json!({ "n": 0, "pairings": [] }));

        let mut d = doc(10);
        d["demand"]["wants"] = json!([]);
        assert_eq!(invoke(FUNCTION, d).unwrap(), json!({ "n": 0, "pairings": [] }));
    }

    #[test]
    fn a_missing_room_is_no_room() {
        let mut d = doc(5);
        d["demand"].as_object_mut().unwrap().remove("room");
        assert_eq!(invoke(FUNCTION, d).unwrap()["n"], 0);
    }

    #[test]
    fn the_same_occurrence_proposes_the_same_plan() {
        assert_eq!(invoke(FUNCTION, doc(3)).unwrap(), invoke(FUNCTION, doc(3)).unwrap());
        let mut other = doc(3);
        other["seed"] = json!("occ-2");
        assert_ne!(invoke(FUNCTION, doc(3)).unwrap(), invoke(FUNCTION, other).unwrap());
    }

    #[test]
    fn a_map_carries_its_own_seat_count() {
        // The map decides the seat count, through the JSON boundary.
        let mut d = doc(2);
        d["demand"]["pool"] = json!([
            model("a", "nano", "competitor", 25.0, 8.3),
            model("b", "nano", "competitor", 26.0, 8.0),
            model("c", "nano", "competitor", 24.0, 7.5),
            model("base", "nano", "baseline", 25.0, 3.0)
        ]);
        d["demand"]["limits"]["maps"] = json!([{ "id": "melee", "players": 4 }]);
        let out = invoke(FUNCTION, d).unwrap();
        assert!(out["n"].as_i64().unwrap() > 0, "{out}");
        for p in out["pairings"].as_array().unwrap() {
            assert_eq!(p["seats"].as_array().unwrap().len(), 4, "{p}");
            assert_eq!(p["map"], "melee");
        }
    }

    #[test]
    fn a_map_with_more_seats_than_the_roster_has_owners_is_never_chosen() {
        // Three owners and a season's boards running to eight seats: every want is spent on the
        // maps three can play, rather than on the ones no draw could fill.
        let mut d = doc(6);
        d["demand"]["pool"] = json!([
            model("a", "nano", "competitor", 25.0, 8.3),
            model("b", "nano", "competitor", 26.0, 8.0),
            model("base", "nano", "baseline", 25.0, 3.0)
        ]);
        d["demand"]["limits"]["maps"] = json!([
            { "id": "open-8", "players": 8 }, { "id": "maze-6", "players": 6 },
            { "id": "cave-3", "players": 3 }, { "id": "open-2", "players": 2 }
        ]);
        let out = invoke(FUNCTION, d).unwrap();
        let ps = out["pairings"].as_array().unwrap();
        assert!(!ps.is_empty(), "{out}");
        for p in ps {
            let n = p["seats"].as_array().unwrap().len();
            assert!(n <= 3, "{p}");
            assert!(["cave-3", "open-2"].contains(&p["map"].as_str().unwrap()), "{p}");
        }

        // And a roster no map fits is an empty plan, not a refusal.
        let mut d = doc(6);
        d["demand"]["limits"]["maps"] = json!([{ "id": "open-8", "players": 8 }]);
        assert_eq!(invoke(FUNCTION, d).unwrap(), json!({ "n": 0, "pairings": [] }));
    }

    #[test]
    fn a_map_without_a_seat_count_is_no_map() {
        // A board states its own seats; there is no default to read an unsized one as, so it is
        // skipped -- and a season whose maps are all like that has nothing to play on.
        let mut d = doc(2);
        d["demand"]["limits"]["maps"] = json!([{ "id": "standard" }, "maze"]);
        assert_eq!(invoke(FUNCTION, d).unwrap_err().code, "NO_MAPS");
    }

    #[test]
    fn a_map_below_two_seats_is_refused() {
        let mut d = doc(2);
        d["demand"]["limits"]["maps"] = json!([{ "id": "solitaire", "players": 1 }]);
        let e = invoke(FUNCTION, d).unwrap_err();
        assert_eq!(e.code, "BAD_MAP", "{}", e.message);
    }

    #[test]
    fn refusals() {
        let mut no_seed = doc(3);
        no_seed.as_object_mut().unwrap().remove("seed");
        assert_eq!(invoke(FUNCTION, no_seed).unwrap_err().code, "NO_SEED");

        let mut empty_seed = doc(3);
        empty_seed["seed"] = json!("");
        assert_eq!(invoke(FUNCTION, empty_seed).unwrap_err().code, "NO_SEED");

        // A season with no map enabled: pair halts on this rather than queueing a match with none.
        let mut no_maps = doc(3);
        no_maps["demand"]["limits"]["maps"] = json!([]);
        assert_eq!(invoke(FUNCTION, no_maps).unwrap_err().code, "NO_MAPS");

        let mut bad_fraction = doc(3);
        bad_fraction["demand"]["limits"]["cross_class_fraction"] = json!(1.5);
        assert_eq!(invoke(FUNCTION, bad_fraction).unwrap_err().code, "BAD_FRACTION");

        let mut no_demand = doc(3);
        no_demand["demand"] = json!("nonsense");
        assert_eq!(invoke(FUNCTION, no_demand).unwrap_err().code, "BAD_DEMAND");

        assert_eq!(invoke("tb.pairing.other", doc(3)).unwrap_err().code, "UNKNOWN_FUNCTION");
    }

    #[test]
    fn a_malformed_pool_entry_is_skipped_rather_than_fatal() {
        // A row without a model_id cannot be seated, but it must not take the whole run down:
        // the rest of the roster is still pairable.
        let mut d = doc(2);
        d["demand"]["pool"] = json!([
            { "weight_class": "nano" },
            model("a", "nano", "competitor", 25.0, 8.3),
            model("base", "nano", "baseline", 25.0, 3.0)
        ]);
        let out = invoke(FUNCTION, d).unwrap();
        assert_eq!(out["n"], 2);
    }
}
