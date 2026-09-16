//! Who plays whom, and on which map: docs/design.md §6.2, in the order the rules are applied.
//!
//! It never seats a version against itself, never seats one twice in a pairing, and never seats
//! anything that is not in the pool -- and the pool is `status = 'active'` only, which is what
//! keeps a `verified`, `superseded` or `rejected` version out without this code knowing those
//! words. Trials are chosen in SQL (§6.4), not here.

use std::collections::HashMap;

/// A small deterministic generator: not for cryptography or statistics, but for making one run's
/// arbitrary choices reproducible from its occurrence id. SplitMix64.
pub struct Rng(u64);

impl Rng {
    /// FNV-1a over the occurrence id's bytes, so any string works.
    pub fn from_str(s: &str) -> Rng {
        let mut h: u64 = 0xcbf2_9ce4_8422_2325;
        for b in s.as_bytes() {
            h ^= *b as u64;
            h = h.wrapping_mul(0x0000_0100_0000_01b3);
        }
        Rng(h | 1)
    }

    pub fn next_u64(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9e37_79b9_7f4a_7c15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
        z ^ (z >> 31)
    }

    /// A float in [0, 1).
    pub fn next_f64(&mut self) -> f64 {
        (self.next_u64() >> 11) as f64 / (1u64 << 53) as f64
    }

    pub fn below(&mut self, n: usize) -> usize {
        if n == 0 { 0 } else { (self.next_u64() % n as u64) as usize }
    }

    /// A world seed for one match: positive and inside a Postgres bigint.
    pub fn seed(&mut self) -> i64 {
        (self.next_u64() >> 1) as i64 & 0x7fff_ffff
    }
}

#[derive(Clone, Debug)]
pub struct Rating {
    pub ladder: String,
    pub mu: f64,
    pub sigma: f64,
}

/// Deliberately no `role`, and the pool document carries none: a baseline is paced like every
/// version, so there is nothing here to treat differently. The one thing a baseline does alone,
/// sit opposite every trial, is chosen in SQL where this plugin never sees it (design §6.4).
///
/// `owner_id` is here for the same class of reason it is NOT a role: two versions of one owner in
/// one match is a free rating transfer between a competitor's own models, which became possible
/// the day a competitor could hold more than one. The plugin declines to propose one; the insert
/// statement refuses one independently, because that is the half that is correctness.
#[derive(Clone, Debug)]
pub struct Entry {
    pub model_id: String,
    pub owner_id: String,
    pub weight_class: String,
    pub ratings: Vec<Rating>,
}

impl Entry {
    fn on(&self, ladder: &str) -> Option<&Rating> {
        self.ratings.iter().find(|r| r.ladder == ladder)
    }
}

#[derive(Clone, Debug)]
pub struct Want {
    pub model_id: String,
    pub want: i64,
}

/// A map, and how many seats are played on it.
///
/// The seat count is the PRESET's, not the game's: a game may offer a two-seat map and a four-seat
/// one, which is why the preset is picked first below and the opponents drawn afterwards.
#[derive(Clone, Debug)]
pub struct Preset {
    pub name: String,
    pub players: usize,
}

pub struct Input {
    pub room: usize,
    pub wants: Vec<Want>,
    pub pool: Vec<Entry>,
    /// model_id -> preset -> counted matches on it.
    pub played: HashMap<String, HashMap<String, i64>>,
    pub presets: Vec<Preset>,
    pub cross_class_fraction: f64,
    /// Whether a season permits two versions of one owner in one match. False everywhere the
    /// platform ships: a season that allows it has standings that mean less, and should say so.
    pub self_pairing: bool,
    /// owner_id -> how many more seats that owner may hold across every model they have.
    /// ABSENT MEANS UNCAPPED -- the same convention `wants` uses for a version with no cap -- and
    /// a season that sets a share names every owner in it, baselines included. The demand view
    /// subtracts what is already in flight, so these are seats remaining and not a ceiling.
    ///
    /// Looked up by key and never iterated: the document is built by `json_agg`, which promises no
    /// order, and a plan that depended on one would not be replayable from its own occurrence id.
    pub owner_room: HashMap<String, i64>,
}

#[derive(Debug, PartialEq)]
pub struct Pairing {
    /// As many seats as the chosen preset is played at. Seat order is the array order.
    pub seats: Vec<String>,
    pub preset: String,
    pub seed: i64,
}

/// Choose up to `room` pairings.
///
/// The wanting side drives: a version that wants a match is seated and an opponent is drawn for
/// it. A version at its cap is never the wanting side, but a settled version or one whose want is
/// spent may be seated opposite, limited only by its owner's room (docs/design.md §4).
pub fn choose(input: &Input, rng: &mut Rng) -> Vec<Pairing> {
    let mut out = Vec::new();
    if input.room == 0 || input.pool.len() < 2 || input.presets.is_empty() {
        return out;
    }

    // The pool arrives from `json_agg` with no ORDER BY, so it is sorted here: a plugin that is
    // seeded and reproducible must not depend on the order Postgres aggregated rows in.
    let mut pool: Vec<&Entry> = input.pool.iter().collect();
    pool.sort_by(|a, b| a.model_id.cmp(&b.model_id));

    let mut remaining: HashMap<&str, i64> = HashMap::new();
    for w in &input.wants {
        if w.want > 0 {
            *remaining.entry(w.model_id.as_str()).or_insert(0) += w.want;
        }
    }

    // Seats each owner may still take, spent as the plan is built. An owner absent from the map is
    // uncapped; the demand view names no owner at all when the season sets no share.
    let mut owner_budget: HashMap<&str, i64> = input
        .owner_room
        .iter()
        .map(|(o, n)| (o.as_str(), *n))
        .collect();
    let room_for = |budget: &HashMap<&str, i64>, owner: &str| -> i64 {
        budget.get(owner).copied().unwrap_or(i64::MAX)
    };

    // Largest want first, ties by id so the order is the document's rather than the hash map's.
    let mut queue: Vec<&Want> = input.wants.iter().filter(|w| w.want > 0).collect();
    queue.sort_by(|a, b| b.want.cmp(&a.want).then(a.model_id.cmp(&b.model_id)));

    while out.len() < input.room {
        // The next version that still wants a match, in want order.
        let Some(seat_a) = queue
            .iter()
            .map(|w| w.model_id.as_str())
            .find(|id| remaining.get(id).copied().unwrap_or(0) > 0)
        else {
            break; // wants exhausted before the room was: the next run continues
        };
        let Some(a) = pool.iter().find(|e| e.model_id == seat_a).copied() else {
            // Wanting but not in the pool: cannot happen, both come from the same read, but
            // spending the want rather than looping is the safe response.
            remaining.insert(seat_a, 0);
            continue;
        };

        // Its owner is at their share of the queue across every model they hold. Spend the want
        // rather than spin, exactly as an unfillable preset does: the next run may find room.
        if room_for(&owner_budget, &a.owner_id) < 1 {
            remaining.insert(seat_a, 0);
            continue;
        }

        // The preset comes FIRST, because it decides how many seats there are to fill.
        let preset = preset_for(a, input, rng);
        let opponents = opponents(a, &pool, &remaining, input, &owner_budget, preset.players - 1, rng);
        if opponents.len() + 1 < preset.players {
            // Not enough distinct versions to seat this map. Spend the want rather than spin:
            // the next run may have a fuller roster, or a smaller preset.
            remaining.insert(seat_a, 0);
            continue;
        }

        let mut seats = Vec::with_capacity(preset.players);
        seats.push(a.model_id.clone());
        for b in &opponents {
            seats.push(b.model_id.clone());
        }
        out.push(Pairing { seats, preset: preset.name.clone(), seed: rng.seed() });

        // Every seat of the match spends one of its owner's, the wanting side included.
        for owner in std::iter::once(&a.owner_id).chain(opponents.iter().map(|b| &b.owner_id)) {
            if let Some(r) = owner_budget.get_mut(owner.as_str()) {
                *r -= 1;
            }
        }

        *remaining.get_mut(seat_a).expect("the wanting seat is in the map") -= 1;
        // And for every opponent that wanted one too: one row then serves several wants.
        for b in &opponents {
            if let Some(r) = remaining.get_mut(b.model_id.as_str())
                && *r > 0
            {
                *r -= 1;
            }
        }
    }
    out
}

/// The preset this version has played least, ties broken by the seed. Map coverage: a rating
/// should reflect the game, not whichever map the version happened to be given.
fn preset_for<'a>(a: &Entry, input: &'a Input, rng: &mut Rng) -> &'a Preset {
    let mut best: Vec<&Preset> = Vec::new();
    let mut best_n = i64::MAX;
    for p in &input.presets {
        let n = input
            .played
            .get(a.model_id.as_str())
            .and_then(|by_preset| by_preset.get(p.name.as_str()))
            .copied()
            .unwrap_or(0);
        if n < best_n {
            best_n = n;
            best.clear();
            best.push(p);
        } else if n == best_n {
            best.push(p);
        }
    }
    let i = rng.below(best.len());
    best[i]
}

/// Draw the opponents.
///
/// Cross-class with probability `cross_class_fraction`, so `open` stays one connected graph rather
/// than a union of class ladders. Within the chosen set, prefer someone who also wants a match --
/// one row then serves several wants -- and among those the closest rating on the ladder the pair
/// share, weighted toward larger sigma, which is where a result teaches the most.
///
/// Returns fewer than `n` only when the pool cannot supply them; the caller treats that as
/// unseatable rather than seating a version twice.
fn opponents<'a>(
    a: &Entry,
    pool: &[&'a Entry],
    remaining: &HashMap<&str, i64>,
    input: &Input,
    owner_budget: &HashMap<&str, i64>,
    n: usize,
    rng: &mut Rng,
) -> Vec<&'a Entry> {
    let mut chosen: Vec<&'a Entry> = Vec::with_capacity(n);
    while chosen.len() < n {
        // Never the wanting version, and never anyone already seated in this match.
        //
        // ALL OWNERS IN A PAIRING ARE DISTINCT, which is a stronger rule than "not the wanting
        // seat's owner" and the difference only shows above two seats: on a four-seat map two
        // OPPONENTS can share an owner with each other while neither shares with `a`. Every seat
        // already taken is checked, not just the first.
        let others: Vec<&&Entry> = pool
            .iter()
            .filter(|e| {
                e.model_id != a.model_id
                    && !chosen.iter().any(|c| c.model_id == e.model_id)
                    && (input.self_pairing
                        || (e.owner_id != a.owner_id
                            && !chosen.iter().any(|c| c.owner_id == e.owner_id)))
                    // and their owner must have a seat left to spend
                    && owner_budget
                        .get(e.owner_id.as_str())
                        .copied()
                        .unwrap_or(i64::MAX)
                        > chosen.iter().filter(|c| c.owner_id == e.owner_id).count() as i64
            })
            .collect();
        if others.is_empty() {
            break;
        }

        let cross = rng.next_f64() < input.cross_class_fraction;
        let mut set: Vec<&&Entry> = others
            .iter()
            .copied()
            .filter(|e| (e.weight_class != a.weight_class) == cross)
            .collect();
        // No one in the class the coin asked for. A pairing on the wrong side of a fraction beats
        // no match at all, and on a small roster one class is often the only class.
        if set.is_empty() {
            set = others.clone();
        }

        // Prefer an opponent who also wants a match.
        let wanting: Vec<&&Entry> = set
            .iter()
            .copied()
            .filter(|e| remaining.get(e.model_id.as_str()).copied().unwrap_or(0) > 0)
            .collect();
        let set = if wanting.is_empty() { set } else { wanting };

        // The ladder they share: their class where it is the same, `open` otherwise.
        let best = set
            .iter()
            .map(|e| {
                let ladder =
                    if e.weight_class == a.weight_class { a.weight_class.as_str() } else { "open" };
                (*e, affinity(a, e, ladder))
            })
            .fold(Vec::<(&&Entry, f64)>::new(), |mut acc, (e, score)| match acc.first() {
                Some((_, best)) if *best < score => acc,
                Some((_, best)) if (*best - score).abs() < f64::EPSILON => {
                    acc.push((e, score));
                    acc
                }
                _ => {
                    acc.clear();
                    acc.push((e, score));
                    acc
                }
            });

        let i = rng.below(best.len());
        chosen.push(best[i].0);
    }
    chosen
}

/// Lower is a better opponent: the rating gap on the shared ladder, discounted by how uncertain
/// the opponent is, because a result against an uncertain opponent moves two ratings instead of
/// one. A version with no rating on the ladder scores as a perfectly good opponent -- it is new.
fn affinity(a: &Entry, b: &Entry, ladder: &str) -> f64 {
    match (a.on(ladder), b.on(ladder)) {
        (Some(ra), Some(rb)) => (ra.mu - rb.mu).abs() / (1.0 + rb.sigma),
        _ => 0.0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Every entry its own owner, which is what today's roster genuinely looks like: before a
    /// competitor could hold several models, one model WAS one owner. That is why every assertion
    /// written before this field existed keeps its exact meaning.
    fn entry(id: &str, class: &str, mu: f64, sigma: f64) -> Entry {
        owned(id, id, class, mu, sigma)
    }

    /// The same, with the owner named -- for the tests that are about two models of one person.
    fn owned(id: &str, owner: &str, class: &str, mu: f64, sigma: f64) -> Entry {
        Entry {
            model_id: id.to_string(),
            owner_id: owner.to_string(),
            weight_class: class.to_string(),
            ratings: vec![
                Rating { ladder: class.to_string(), mu, sigma },
                Rating { ladder: "open".to_string(), mu, sigma },
            ],
        }
    }

    fn presets(players: usize) -> Vec<Preset> {
        ["standard", "maze", "cell"]
            .iter()
            .map(|n| Preset { name: n.to_string(), players })
            .collect()
    }

    fn input(room: usize, wants: &[(&str, i64)], pool: Vec<Entry>) -> Input {
        Input {
            room,
            wants: wants
                .iter()
                .map(|(id, w)| Want { model_id: id.to_string(), want: *w })
                .collect(),
            pool,
            played: HashMap::new(),
            presets: presets(2),
            cross_class_fraction: 0.20,
            self_pairing: false,
            owner_room: HashMap::new(),
        }
    }

    fn nano_pool() -> Vec<Entry> {
        vec![
            entry("a", "nano", 25.0, 8.3),
            entry("b", "nano", 30.0, 2.0),
            entry("base", "nano", 25.0, 3.0),
        ]
    }

    #[test]
    fn the_same_seed_gives_the_same_pairings() {
        // What makes a pairing auditable: a retry proposes exactly what the first attempt did.
        let inp = input(6, &[("a", 4), ("b", 2)], nano_pool());
        let first = choose(&inp, &mut Rng::from_str("occurrence-1"));
        let again = choose(&inp, &mut Rng::from_str("occurrence-1"));
        assert_eq!(first, again);
        let other = choose(&inp, &mut Rng::from_str("occurrence-2"));
        assert_ne!(first, other, "a different occurrence must not propose the same plan");
    }

    #[test]
    fn pool_order_does_not_change_the_plan() {
        // `json_agg` gives no ORDER BY guarantee. Without the sort in `choose` this fails.
        let inp = input(4, &[("a", 4)], nano_pool());
        let mut reversed = nano_pool();
        reversed.reverse();
        let inp2 = Input { pool: reversed, ..input(4, &[("a", 4)], vec![]) };
        assert_eq!(
            choose(&inp, &mut Rng::from_str("occ")),
            choose(&inp2, &mut Rng::from_str("occ"))
        );
    }

    #[test]
    fn the_room_is_the_ceiling() {
        for room in 0..8 {
            let inp = input(room, &[("a", 20), ("b", 20)], nano_pool());
            assert_eq!(choose(&inp, &mut Rng::from_str("occ")).len(), room, "room {room}");
        }
    }

    #[test]
    fn wants_bound_the_plan_when_they_run_out_before_the_room() {
        // One want, a big room: one pairing, and the run ends rather than inventing work.
        let inp = input(50, &[("a", 1)], nano_pool());
        assert_eq!(choose(&inp, &mut Rng::from_str("occ")).len(), 1);
    }

    #[test]
    fn one_row_can_serve_two_wants() {
        // Two versions that each want one match should need one row between them, not two.
        let pool = vec![entry("a", "nano", 25.0, 8.3), entry("b", "nano", 25.0, 8.3)];
        let inp = input(50, &[("a", 1), ("b", 1)], pool);
        assert_eq!(choose(&inp, &mut Rng::from_str("occ")).len(), 1);
    }

    // ------------------------------------------------------- two models of one competitor

    /// THE TEST THAT LICENSES THE CHANGE. With one model per owner -- which is every roster that
    /// has ever existed until now -- forbidding self-pairing and permitting it produce the SAME
    /// PLAN, seed for seed. The constraint cannot have changed anyone's pairings today.
    #[test]
    fn the_constraint_is_inert_when_every_owner_is_distinct() {
        for seed in 0..200u64 {
            let mut forbidden = input(4, &[("a", 2), ("b", 2)], nano_pool());
            let mut permitted = input(4, &[("a", 2), ("b", 2)], nano_pool());
            permitted.self_pairing = true;
            assert_eq!(
                choose(&forbidden, &mut Rng::from_str(&format!("occ-{seed}"))),
                choose(&permitted, &mut Rng::from_str(&format!("occ-{seed}"))),
                "seed {seed}: the owner rule moved a plan on a roster of one model per owner"
            );
            forbidden.room = 0;
            permitted.room = 0;
        }
    }

    #[test]
    fn two_versions_of_one_owner_are_never_seated_together() {
        for seed in 0..200u64 {
            let pool = vec![
                owned("a1", "alice", "nano", 25.0, 8.3),
                owned("a2", "alice", "nano", 25.0, 8.3),
                owned("b", "bob", "nano", 25.0, 8.3),
            ];
            let plan = choose(&input(6, &[("a1", 3), ("a2", 3)], pool), &mut Rng::from_str(&format!("occ-{seed}")));
            for p in &plan {
                let alice = p.seats.iter().filter(|s| s.starts_with("a")).count();
                assert!(alice <= 1, "seed {seed}: alice took {alice} seats of {:?}", p.seats);
            }
        }
    }

    /// The four-seat case, which is the one a "not the wanting seat's owner" rule would miss: two
    /// OPPONENTS can share an owner with each other while neither shares with the wanting side.
    #[test]
    fn every_seat_of_a_larger_map_has_a_different_owner() {
        for seed in 0..200u64 {
            let pool = vec![
                owned("w", "wanda", "nano", 25.0, 8.3),
                owned("a1", "alice", "nano", 25.0, 8.3),
                owned("a2", "alice", "nano", 25.0, 8.3),
                owned("b", "bob", "nano", 25.0, 8.3),
                owned("c", "carol", "nano", 25.0, 8.3),
            ];
            let mut i = input(4, &[("w", 4)], pool);
            i.presets = presets(4);
            for p in choose(&i, &mut Rng::from_str(&format!("occ-{seed}"))) {
                let mut owners: Vec<&str> =
                    p.seats.iter().map(|s| if s.starts_with("a") { "alice" } else { s }).collect();
                owners.sort_unstable();
                let before = owners.len();
                owners.dedup();
                assert_eq!(before, owners.len(), "seed {seed}: repeated owner in {:?}", p.seats);
            }
        }
    }

    #[test]
    fn a_season_that_permits_self_pairing_gets_it() {
        // The flag is read, not ignored: with only one competitor's two models wanting matches and
        // no one else in the pool, forbidding it yields nothing and permitting it yields matches.
        let pool =
            vec![owned("a1", "alice", "nano", 25.0, 8.3), owned("a2", "alice", "nano", 25.0, 8.3)];
        let forbidden = input(4, &[("a1", 2), ("a2", 2)], pool.clone());
        assert!(choose(&forbidden, &mut Rng::from_str(&format!("occ-{}", 7))).is_empty());

        let mut permitted = input(4, &[("a1", 2), ("a2", 2)], pool);
        permitted.self_pairing = true;
        assert!(!choose(&permitted, &mut Rng::from_str(&format!("occ-{}", 7))).is_empty());
    }

    #[test]
    fn an_owner_at_its_share_is_seated_nowhere() {
        let pool = vec![
            owned("a", "alice", "nano", 25.0, 8.3),
            owned("b", "bob", "nano", 25.0, 8.3),
            owned("c", "carol", "nano", 25.0, 8.3),
        ];
        let mut i = input(6, &[("a", 3), ("b", 3)], pool);
        i.owner_room = HashMap::from([("alice".to_string(), 0)]);
        for p in choose(&i, &mut Rng::from_str(&format!("occ-{}", 11))) {
            assert!(!p.seats.contains(&"a".to_string()), "alice was seated at her cap: {:?}", p.seats);
        }
    }

    /// The budget is the OWNER'S and is spent across the whole plan, not per model -- which is the
    /// difference between a cap and five times a cap.
    #[test]
    fn the_owner_budget_is_spent_across_the_plan() {
        let pool = vec![
            owned("a1", "alice", "nano", 25.0, 8.3),
            owned("a2", "alice", "nano", 25.0, 8.3),
            owned("a3", "alice", "nano", 25.0, 8.3),
            owned("b", "bob", "nano", 25.0, 8.3),
        ];
        let mut i = input(12, &[("a1", 4), ("a2", 4), ("a3", 4)], pool);
        i.owner_room = HashMap::from([("alice".to_string(), 2)]);
        let seats: usize = choose(&i, &mut Rng::from_str(&format!("occ-{}", 3)))
            .iter()
            .map(|p| p.seats.iter().filter(|s| s.starts_with("a")).count())
            .sum();
        assert!(seats <= 2, "alice took {seats} seats against a share of 2");
    }

    #[test]
    fn an_owner_absent_from_the_room_map_is_uncapped() {
        // A season with no share: the demand view omits an owner it does not cap, so absent must
        // not read as zero -- the same convention `wants` uses.
        let mut i = input(4, &[("a", 2), ("b", 2)], nano_pool());
        i.owner_room = HashMap::from([("nobody".to_string(), 0)]);
        assert!(!choose(&i, &mut Rng::from_str(&format!("occ-{}", 5))).is_empty());
    }

    #[test]
    fn owner_room_order_does_not_change_the_plan() {
        // A HashMap has no order and `json_agg` promises none either, so the plan must be a
        // function of the values and never of the order they arrived in.
        let pool = vec![
            owned("a", "alice", "nano", 25.0, 8.3),
            owned("b", "bob", "nano", 25.0, 8.3),
            owned("c", "carol", "nano", 25.0, 8.3),
        ];
        let rooms: Vec<(String, i64)> =
            vec![("alice".into(), 3), ("bob".into(), 3), ("carol".into(), 3)];
        let mut forward = input(6, &[("a", 2), ("b", 2)], pool.clone());
        forward.owner_room = rooms.iter().cloned().collect();
        let mut backward = input(6, &[("a", 2), ("b", 2)], pool);
        backward.owner_room = rooms.into_iter().rev().collect();
        assert_eq!(choose(&forward, &mut Rng::from_str(&format!("occ-{}", 9))), choose(&backward, &mut Rng::from_str(&format!("occ-{}", 9))));
    }

    #[test]
    fn a_version_is_never_seated_against_itself() {
        for occ in 0..200 {
            let inp = input(8, &[("a", 4), ("b", 4)], nano_pool());
            for p in choose(&inp, &mut Rng::from_str(&format!("occ-{occ}"))) {
                assert_ne!(p.seats[0], p.seats[1], "seed occ-{occ} seated a version twice");
            }
        }
    }

    #[test]
    fn only_the_pool_is_ever_seated() {
        // The pool is `status = 'active'` alone -- how "never seat a verified, superseded or
        // rejected version" holds without this code knowing those words.
        let inp = input(8, &[("a", 4), ("ghost", 4)], nano_pool());
        let ids: Vec<String> = nano_pool().into_iter().map(|e| e.model_id).collect();
        for p in choose(&inp, &mut Rng::from_str("occ")) {
            assert!(ids.contains(&p.seats[0]) && ids.contains(&p.seats[1]), "{p:?}");
        }
    }

    #[test]
    fn a_version_wanting_but_absent_from_the_pool_does_not_spin() {
        // Belt and braces: if the two reads ever disagreed, the loop must still terminate.
        let inp = input(4, &[("ghost", 10)], nano_pool());
        assert!(choose(&inp, &mut Rng::from_str("occ")).is_empty());
    }

    #[test]
    fn a_pool_of_one_pairs_nothing() {
        let inp = input(4, &[("a", 4)], vec![entry("a", "nano", 25.0, 8.3)]);
        assert!(choose(&inp, &mut Rng::from_str("occ")).is_empty());
    }

    #[test]
    fn every_preset_gets_played() {
        // Map coverage: with no history, repeated pairings must not all land on one preset.
        let inp = input(30, &[("a", 30)], nano_pool());
        let seen: std::collections::HashSet<String> =
            choose(&inp, &mut Rng::from_str("occ")).into_iter().map(|p| p.preset).collect();
        assert_eq!(seen.len(), 3, "expected all three presets, saw {seen:?}");
    }

    #[test]
    fn the_least_played_preset_is_chosen() {
        let mut inp = input(1, &[("a", 1)], nano_pool());
        inp.played.insert(
            "a".into(),
            [("standard", 10), ("maze", 10), ("cell", 1)]
                .into_iter()
                .map(|(preset, n)| (preset.to_string(), n))
                .collect(),
        );
        for occ in 0..50 {
            let out = choose(&inp, &mut Rng::from_str(&format!("o{occ}")));
            assert_eq!(out[0].preset, "cell", "the least-played preset must win outright");
        }
    }

    #[test]
    fn cross_class_happens_at_roughly_the_declared_rate() {
        let pool = vec![
            entry("a", "nano", 25.0, 8.3),
            entry("n2", "nano", 25.0, 8.3),
            entry("m1", "micro", 25.0, 8.3),
        ];
        let mut inp = input(400, &[("a", 400)], pool);
        inp.cross_class_fraction = 0.20;
        let out = choose(&inp, &mut Rng::from_str("occ"));
        let cross = out.iter().filter(|p| p.seats[1] == "m1").count();
        let rate = cross as f64 / out.len() as f64;
        assert!((0.12..0.30).contains(&rate), "cross-class rate {rate} is not near 0.20");

        // And zero means zero: the coin is read, not ignored.
        inp.cross_class_fraction = 0.0;
        let none = choose(&inp, &mut Rng::from_str("occ"));
        assert!(none.iter().all(|p| p.seats[1] == "n2"), "no pairing should cross at 0.0");
    }

    #[test]
    fn a_closer_more_uncertain_opponent_is_preferred() {
        let pool = vec![
            entry("a", "nano", 25.0, 8.3),
            entry("near", "nano", 26.0, 8.0),
            entry("far", "nano", 45.0, 0.5),
        ];
        let mut inp = input(20, &[("a", 20)], pool);
        inp.cross_class_fraction = 0.0;
        let out = choose(&inp, &mut Rng::from_str("occ"));
        assert!(out.iter().all(|p| p.seats[1] == "near"), "{out:?}");
    }

    #[test]
    fn a_settled_opponent_is_seated_without_a_want_of_its_own() {
        // A settled version has cap 0 and appears in no `want`, yet must still be seatable.
        let pool = vec![entry("new", "nano", 25.0, 8.3), entry("settled", "nano", 30.0, 1.0)];
        let inp = input(5, &[("new", 5)], pool);
        let out = choose(&inp, &mut Rng::from_str("occ"));
        assert_eq!(out.len(), 5);
        assert!(out.iter().all(|p| p.seats[1] == "settled"));
    }

    #[test]
    fn a_preset_s_seat_count_decides_the_match_s_size() {
        // A four-seat preset produces four-seat pairings from the same roster and code path.
        let pool = vec![
            entry("a", "nano", 25.0, 8.3),
            entry("b", "nano", 26.0, 8.0),
            entry("c", "nano", 24.0, 7.5),
            entry("d", "nano", 25.5, 8.1),
        ];
        let mut inp = input(4, &[("a", 4)], pool);
        inp.presets = presets(4);
        let out = choose(&inp, &mut Rng::from_str("occ"));
        assert!(!out.is_empty());
        for p in &out {
            assert_eq!(p.seats.len(), 4, "a four-seat preset must seat four: {p:?}");
            let unique: std::collections::HashSet<&String> = p.seats.iter().collect();
            assert_eq!(unique.len(), 4, "a version was seated twice: {p:?}");
        }
    }

    #[test]
    fn presets_of_different_sizes_coexist() {
        // One map at two seats, one at four, each pairing sized by whichever came up.
        let pool = vec![
            entry("a", "nano", 25.0, 8.3),
            entry("b", "nano", 26.0, 8.0),
            entry("c", "nano", 24.0, 7.5),
            entry("d", "nano", 25.5, 8.1),
        ];
        let mut inp = input(20, &[("a", 20)], pool);
        inp.presets = vec![
            Preset { name: "duel".into(), players: 2 },
            Preset { name: "melee".into(), players: 4 },
        ];
        let out = choose(&inp, &mut Rng::from_str("occ"));
        let sizes: std::collections::HashSet<(String, usize)> =
            out.iter().map(|p| (p.preset.clone(), p.seats.len())).collect();
        assert!(sizes.contains(&("duel".to_string(), 2)), "{sizes:?}");
        assert!(sizes.contains(&("melee".to_string(), 4)), "{sizes:?}");
        // And every pairing is sized by its own preset, never by the other's.
        for p in &out {
            let want = if p.preset == "duel" { 2 } else { 4 };
            assert_eq!(p.seats.len(), want, "{p:?}");
        }
    }

    #[test]
    fn a_preset_the_pool_cannot_fill_is_skipped_rather_than_half_seated() {
        // Three versions and a four-seat map: seating one twice is worse than not pairing.
        let mut inp = input(4, &[("a", 4)], nano_pool());
        inp.presets = vec![Preset { name: "melee".into(), players: 4 }];
        assert!(choose(&inp, &mut Rng::from_str("occ")).is_empty());
    }

    #[test]
    fn world_seeds_are_positive_and_distinct() {
        let inp = input(20, &[("a", 20)], nano_pool());
        let out = choose(&inp, &mut Rng::from_str("occ"));
        let seeds: std::collections::HashSet<i64> = out.iter().map(|p| p.seed).collect();
        assert!(out.iter().all(|p| p.seed >= 0), "a world seed must fit a positive bigint");
        assert_eq!(seeds.len(), out.len(), "two matches in one run shared a world seed");
    }
}
