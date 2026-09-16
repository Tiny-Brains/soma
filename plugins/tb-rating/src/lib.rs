//! `tb.rating.trueskill` — the only arithmetic that writes a ladder.
//!
//! Called once per finished match, between reading the seats' priors and writing the fold. Pure:
//! the same match, priors and parameters give the same posteriors for ever, whoever runs them.
//!
//! **Input** is soma/docs/schema.md §5.2's priors document under `match`, plus the three TrueSkill
//! parameters:
//!
//! ```json
//! { "match": { "ladders": ["nano", "open"], "seat_count": 2,
//!              "seats": [ { "seat": 0, "model_id": "...", "rank": 1, "strikes": 0,
//!                           "ratings": [ { "ladder": "nano", "mu": 25, "sigma": 8.33 } ] } ] },
//!   "beta": 4.1667, "tau": 0.0833, "draw_probability": 0.10 }
//! ```
//!
//! **Output** is the fold statement's fourth parameter exactly — one element per seat per
//! ladder, so the task hands it straight on and the statement, which refuses a document whose
//! length is not `seat_count * cardinality(ladders)`, checks the arithmetic's shape for us:
//!
//! ```json
//! [ { "seat": 0, "model_id": "...", "ladder": "nano", "mu": 29.4, "sigma": 7.17 } ]
//! ```
//!
//! One update per ladder the match feeds, over the seats' priors on that ladder, ordered by rank.
//! A match feeding no ladders — a trial — returns an empty array.
//!
//! **Every refusal is `caller_input`**: the same document cannot succeed on a retry, so Orion
//! records it and never retries. A match whose seats do not line up is a bug, not a transient.

mod gauss;
mod trueskill;

use serde_json::{Map, Value, json};
use trueskill::{Params, Player, RateError};

/// A refusal, in the shape the host's `PluginError::caller_input` takes. Its own type so that
/// everything except the export shim is testable on the host, where the SDK's wasm-only bindings
/// cannot be built.
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

/// The function name this component answers to.
pub const FUNCTION: &str = "tb.rating.trueskill";

pub fn invoke(function: &str, input: Value) -> Result<Value, Fault> {
    match function {
        FUNCTION => trueskill_fn(&input),
        other => Err(Fault::new(
            "UNKNOWN_FUNCTION",
            format!("this component exports no '{other}', only '{FUNCTION}'"),
        )),
    }
}

fn number(v: &Value, field: &str) -> Result<f64, Fault> {
    v.get(field)
        .and_then(Value::as_f64)
        .filter(|n| n.is_finite())
        .ok_or_else(|| Fault::new("BAD_PARAMETER", format!("'{field}' must be a finite number")))
}

// `!(beta > 0.0)` rather than `beta <= 0.0`: a NaN must be refused, not accepted.
#[allow(clippy::neg_cmp_op_on_partial_ord)]
fn trueskill_fn(input: &Value) -> Result<Value, Fault> {
    let beta = number(input, "beta")?;
    let tau = number(input, "tau")?;
    let draw_probability = number(input, "draw_probability")?;
    if !(beta > 0.0) {
        return Err(Fault::new("BAD_PARAMETER", "'beta' must be greater than zero"));
    }
    if tau < 0.0 {
        return Err(Fault::new("BAD_PARAMETER", "'tau' must not be negative"));
    }
    if !(0.0..1.0).contains(&draw_probability) {
        return Err(Fault::new(
            "BAD_PARAMETER",
            "'draw_probability' must be at least zero and below one",
        ));
    }
    let params = Params { beta, tau, draw_probability };

    let m = input
        .get("match")
        .and_then(Value::as_object)
        .ok_or_else(|| Fault::new("BAD_PARAMETER", "'match' must be the priors document"))?;

    let ladders: Vec<&str> = match m.get("ladders") {
        None | Some(Value::Null) => Vec::new(),
        Some(Value::Array(a)) => a
            .iter()
            .map(|l| {
                l.as_str().ok_or_else(|| {
                    Fault::new("BAD_PARAMETER", "'match.ladders' must hold ladder names")
                })
            })
            .collect::<Result<_, _>>()?,
        Some(_) => {
            return Err(Fault::new("BAD_PARAMETER", "'match.ladders' must be an array"));
        }
    };

    let seats = m
        .get("seats")
        .and_then(Value::as_array)
        .ok_or_else(|| Fault::new("BAD_PARAMETER", "'match.seats' must be an array"))?;

    // seat_count is declared as well as implied, and they must agree: the fold statement sizes its
    // length check on the declared one, so a short seats array would surface three steps later.
    if let Some(declared) = m.get("seat_count").and_then(Value::as_i64)
        && declared != seats.len() as i64
    {
        return Err(Fault::new(
            "RANKS_LENGTH_MISMATCH",
            format!("the match declares {declared} seats and carries {}", seats.len()),
        ));
    }
    if seats.len() < 2 {
        return Err(Fault::new(
            "SEATS_BELOW_TWO",
            format!("a match needs at least two seats to rate; this one has {}", seats.len()),
        ));
    }

    // A trial feeds no ladder: an empty array is what `seat_count * 0` expects.
    if ladders.is_empty() {
        return Ok(Value::Array(Vec::new()));
    }

    struct Seat<'a> {
        seat: i64,
        model_id: &'a Value,
        rank: i64,
        ratings: Map<String, Value>,
    }

    let parsed: Vec<Seat> = seats
        .iter()
        .enumerate()
        .map(|(i, s)| {
            let seat = s.get("seat").and_then(Value::as_i64).ok_or_else(|| {
                Fault::new("RANKS_LENGTH_MISMATCH", format!("seats[{i}] has no 'seat' number"))
            })?;
            let model_id = s.get("model_id").filter(|v| !v.is_null()).ok_or_else(|| {
                Fault::new("RANKS_LENGTH_MISMATCH", format!("seat {seat} has no 'model_id'"))
            })?;
            // The fold statement only ever selects finished rows, so a missing rank is a real
            // inconsistency, not a race.
            let rank = s.get("rank").and_then(Value::as_i64).ok_or_else(|| {
                Fault::new(
                    "RANKS_LENGTH_MISMATCH",
                    format!("seat {seat} has no 'rank'; the match cannot have finished"),
                )
            })?;
            let mut ratings = Map::new();
            if let Some(list) = s.get("ratings").and_then(Value::as_array) {
                for r in list {
                    if let Some(name) = r.get("ladder").and_then(Value::as_str) {
                        ratings.insert(name.to_string(), r.clone());
                    }
                }
            }
            Ok(Seat { seat, model_id, rank, ratings })
        })
        .collect::<Result<_, _>>()?;

    let mut out = Vec::with_capacity(parsed.len() * ladders.len());
    for ladder in &ladders {
        let mut players = Vec::with_capacity(parsed.len());
        for s in &parsed {
            let r = s.ratings.get(*ladder).ok_or_else(|| {
                Fault::new(
                    "LADDER_MISSING",
                    format!("seat {} has no rating on '{ladder}', which this match feeds", s.seat),
                )
            })?;
            let mu = r.get("mu").and_then(Value::as_f64).ok_or_else(|| {
                Fault::new(
                    "LADDER_MISSING",
                    format!("seat {}'s '{ladder}' rating has no numeric mu", s.seat),
                )
            })?;
            let sigma = r.get("sigma").and_then(Value::as_f64).ok_or_else(|| {
                Fault::new(
                    "SIGMA_NOT_POSITIVE",
                    format!("seat {}'s '{ladder}' rating has no numeric sigma", s.seat),
                )
            })?;
            players.push(Player { mu, sigma, rank: s.rank });
        }

        let posteriors = trueskill::rate(&players, &params).map_err(|e| match e {
            RateError::SeatsBelowTwo => Fault::new(
                "SEATS_BELOW_TWO",
                "a match needs at least two seats to rate".to_string(),
            ),
            RateError::SigmaNotPositive { index } => Fault::new(
                "SIGMA_NOT_POSITIVE",
                format!(
                    "seat {}'s '{ladder}' sigma is not a positive finite number",
                    parsed[index].seat
                ),
            ),
            RateError::Diverged => Fault::new(
                "SIGMA_NOT_POSITIVE",
                format!(
                    "the update on '{ladder}' did not converge: the result is too improbable \
                     under these priors to represent"
                ),
            ),
        })?;

        for (s, (mu, sigma)) in parsed.iter().zip(posteriors) {
            out.push(json!({
                "seat": s.seat,
                "model_id": s.model_id,
                "ladder": ladder,
                "mu": mu,
                "sigma": sigma,
            }));
        }
    }
    Ok(Value::Array(out))
}

// The only code that reaches the SDK, and only on wasm: its generated bindings target the
// component model and do not build for the host, which is where the tests above run.
#[cfg(target_arch = "wasm32")]
mod exported {
    use orion_plugin_sdk::{Plugin, PluginError, export_plugin, serde_json::Value};

    struct TbRating;

    impl Plugin for TbRating {
        fn invoke(function: &str, input: Value) -> Result<Value, PluginError> {
            super::invoke(function, input).map_err(|f| PluginError::caller_input(f.code, f.message))
        }
    }

    export_plugin!(TbRating);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn seat(seat: i64, model: &str, rank: i64, ratings: Value) -> Value {
        json!({ "seat": seat, "model_id": model, "rank": rank, "strikes": 0, "ratings": ratings })
    }

    fn prior(ladder: &str) -> Value {
        json!({ "ladder": ladder, "mu": 25.0, "sigma": 25.0 / 3.0 })
    }

    fn two_seat_input(ladders: Value, r0: Value, r1: Value) -> Value {
        json!({
            "match": {
                "id": "aaaaaaaa-0000-0000-0000-000000000001",
                "trial_model_id": null,
                "ladders": ladders,
                "seat_count": 2,
                "seats": [
                    seat(0, "20000000-0000-0000-0000-000000000001", 1, r0),
                    seat(1, "10000000-0000-0000-0000-000000000001", 2, r1),
                ]
            },
            "beta": 25.0 / 6.0, "tau": 25.0 / 300.0, "draw_probability": 0.10
        })
    }

    #[test]
    fn one_element_per_seat_per_ladder_in_the_fold_s_shape() {
        let input = two_seat_input(
            json!(["nano", "open"]),
            json!([prior("nano"), prior("open")]),
            json!([prior("nano"), prior("open")]),
        );
        let out = invoke(FUNCTION, input).unwrap();
        let rows = out.as_array().unwrap();
        // seat_count * cardinality(ladders): the length the fold statement checks.
        assert_eq!(rows.len(), 4);
        for r in rows {
            for field in ["seat", "model_id", "ladder", "mu", "sigma"] {
                assert!(r.get(field).is_some(), "missing {field} in {r}");
            }
            assert!(r["mu"].as_f64().unwrap().is_finite());
            assert!(r["sigma"].as_f64().unwrap() > 0.0);
        }
        // The winner gains on both ladders; the loser loses on both.
        let winner: Vec<f64> =
            rows.iter().filter(|r| r["seat"] == 0).map(|r| r["mu"].as_f64().unwrap()).collect();
        assert!(winner.iter().all(|mu| *mu > 25.0), "{winner:?}");
        let loser: Vec<f64> =
            rows.iter().filter(|r| r["seat"] == 1).map(|r| r["mu"].as_f64().unwrap()).collect();
        assert!(loser.iter().all(|mu| *mu < 25.0), "{loser:?}");
    }

    #[test]
    fn each_ladder_is_updated_from_its_own_priors() {
        // Different priors on the two ladders must give different posteriors: a build that
        // rated `open` from the class ladder's numbers would pass every single-ladder test.
        let input = two_seat_input(
            json!(["nano", "open"]),
            json!([prior("nano"), { "ladder": "open", "mu": 40.0, "sigma": 2.0 }]),
            json!([prior("nano"), { "ladder": "open", "mu": 10.0, "sigma": 2.0 }]),
        );
        let out = invoke(FUNCTION, input).unwrap();
        let rows = out.as_array().unwrap();
        let get = |seat: i64, ladder: &str| -> f64 {
            rows.iter().find(|r| r["seat"] == seat && r["ladder"] == ladder).unwrap()["mu"]
                .as_f64()
                .unwrap()
        };
        assert!((get(0, "nano") - 29.4).abs() < 0.1, "{}", get(0, "nano"));
        // A heavy favourite that wins moves barely at all.
        assert!(get(0, "open") > 40.0 && get(0, "open") < 40.2, "{}", get(0, "open"));
    }

    #[test]
    fn a_trial_feeds_no_ladder_and_produces_nothing() {
        let input = two_seat_input(json!([]), json!([prior("nano")]), json!([prior("nano")]));
        assert_eq!(invoke(FUNCTION, input).unwrap(), json!([]));
    }

    #[test]
    fn a_seat_with_no_rating_on_a_fed_ladder_is_refused() {
        let input = two_seat_input(
            json!(["nano", "open"]),
            json!([prior("nano"), prior("open")]),
            json!([prior("nano")]), // no 'open'
        );
        let e = invoke(FUNCTION, input).unwrap_err();
        assert_eq!(e.code, "LADDER_MISSING", "{}", e.message);
        assert!(e.message.contains("open"), "{}", e.message);
    }

    #[test]
    fn the_declared_seat_count_must_match_the_seats() {
        let mut input =
            two_seat_input(json!(["nano"]), json!([prior("nano")]), json!([prior("nano")]));
        input["match"]["seat_count"] = json!(3);
        let e = invoke(FUNCTION, input).unwrap_err();
        assert_eq!(e.code, "RANKS_LENGTH_MISMATCH", "{}", e.message);
    }

    #[test]
    fn a_seat_without_a_rank_is_refused() {
        let mut input =
            two_seat_input(json!(["nano"]), json!([prior("nano")]), json!([prior("nano")]));
        input["match"]["seats"][1]["rank"] = Value::Null;
        let e = invoke(FUNCTION, input).unwrap_err();
        assert_eq!(e.code, "RANKS_LENGTH_MISMATCH", "{}", e.message);
    }

    #[test]
    fn one_seat_is_refused() {
        let input = json!({
            "match": { "ladders": ["nano"], "seat_count": 1,
                       "seats": [seat(0, "m", 1, json!([prior("nano")]))] },
            "beta": 4.0, "tau": 0.08, "draw_probability": 0.1
        });
        let e = invoke(FUNCTION, input).unwrap_err();
        assert_eq!(e.code, "SEATS_BELOW_TWO", "{}", e.message);
    }

    #[test]
    fn a_non_positive_sigma_is_refused() {
        let input = two_seat_input(
            json!(["nano"]),
            json!([{ "ladder": "nano", "mu": 25.0, "sigma": 0.0 }]),
            json!([prior("nano")]),
        );
        let e = invoke(FUNCTION, input).unwrap_err();
        assert_eq!(e.code, "SIGMA_NOT_POSITIVE", "{}", e.message);
    }

    #[test]
    fn bad_parameters_are_refused_rather_than_defaulted() {
        // A missing var arrives as a missing field; defaulting would rate a whole ladder on
        // numbers nobody chose.
        for bad in [
            json!({ "beta": 0.0, "tau": 0.08, "draw_probability": 0.1 }),
            json!({ "tau": 0.08, "draw_probability": 0.1 }),
            json!({ "beta": 4.0, "tau": -1.0, "draw_probability": 0.1 }),
            json!({ "beta": 4.0, "tau": 0.08, "draw_probability": 1.0 }),
            json!({ "beta": 4.0, "tau": 0.08 }),
        ] {
            let mut input =
                two_seat_input(json!(["nano"]), json!([prior("nano")]), json!([prior("nano")]));
            for k in ["beta", "tau", "draw_probability"] {
                input.as_object_mut().unwrap().remove(k);
            }
            for (k, v) in bad.as_object().unwrap() {
                input[k] = v.clone();
            }
            let e = invoke(FUNCTION, input).unwrap_err();
            assert_eq!(e.code, "BAD_PARAMETER", "{bad} gave {}", e.message);
        }
    }

    #[test]
    fn an_unknown_function_is_refused() {
        let e = invoke("tb.rating.elo", json!({})).unwrap_err();
        assert_eq!(e.code, "UNKNOWN_FUNCTION");
    }
}
