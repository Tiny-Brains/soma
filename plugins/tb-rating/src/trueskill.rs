//! The TrueSkill update as a factor graph, for a match of N individually-ranked seats.
//!
//! Every seat is its own side: TinyBrains pairs models, not teams, so the "team" layer of the
//! general algorithm is a sum over one element with coefficient one -- an exact identity -- and
//! is collapsed here. What remains is four kinds of factor over three layers of variable:
//!
//! ```text
//!     rating[i]   O  O  O      what we believed about each seat before the match
//!                 |  |  |      PriorFactor      -- the stored rating, with `tau` added
//!     perf[i]     O  O  O      how it actually played on the day
//!                  \/ \/       LikelihoodFactor -- performance is skill plus beta noise
//!     diff[j]      O   O       the gap between adjacently-ranked seats
//!                  |   |       SumFactor        -- diff[j] = perf[j] - perf[j+1]
//!     (result)     O   O       TruncateFactor   -- and the result says which way, by how much
//! ```
//!
//! Messages are passed until the truncation factors stop moving, then pulled back up to the
//! rating layer, whose marginals are the answer. Seats are sorted best-rank-first on the way in
//! and restored to seat order on the way out.
//!
//! VERIFIED against the reference implementation (the `trueskill` Python package, itself Herbrich,
//! Minka and Graepel's paper) by the vectors in `tests`: matches spanning two to four seats, ties
//! in every position, asymmetric priors and non-default parameters, each agreeing to 1e-9. See
//! `gauss.rs` on why that tolerance is meaningful rather than lucky.

use crate::gauss::{self, Gauss};

/// Stop passing messages once no truncation factor moves further than this.
const MIN_DELTA: f64 = 0.0001;

/// Message passing is a fixed point iteration; this bounds it, so a pathological input costs a
/// bounded amount of time rather than the host's whole deadline. Two seats converge in one pass.
const MAX_ITERATIONS: usize = 10;

#[derive(Clone, Copy, Debug)]
pub struct Player {
    pub mu: f64,
    pub sigma: f64,
    /// Lower is better, equal ranks are a draw. Only the order and which entries are equal reach
    /// this code, so dense (1, 1, 3) and competition-style (1, 1, 2) ties are the same input.
    pub rank: i64,
}

#[derive(Clone, Copy, Debug)]
pub struct Params {
    /// The performance noise: how much a single match's outcome can differ from true skill.
    pub beta: f64,
    /// The dynamics factor, added to every prior variance before the update: what stops a settled
    /// rating from being frozen for ever.
    pub tau: f64,
    pub draw_probability: f64,
}

#[derive(Debug, PartialEq)]
pub enum RateError {
    /// Fewer than two seats: there is no comparison to make.
    SeatsBelowTwo,
    /// A prior sigma that is zero, negative or not finite. Precision is `1/sigma^2`, so a
    /// zero sigma is an infinitely confident prior no result could ever move.
    SigmaNotPositive { index: usize },
    /// The result was so improbable under the priors that the variance update left `(0, 1)`.
    /// Reported rather than written: the alternative is a rating that grew more uncertain from
    /// having observed something.
    Diverged,
}

/// Run the update. Returns `(mu, sigma)` per player, in the order given.
//
// `!(x > 0.0)` rather than `x <= 0.0` so a NaN is refused rather than passed, and the sweep indexes
// five parallel arrays through `&mut` slices, which an iterator cannot borrow.
#[allow(clippy::neg_cmp_op_on_partial_ord, clippy::needless_range_loop)]
pub fn rate(players: &[Player], p: &Params) -> Result<Vec<(f64, f64)>, RateError> {
    let n = players.len();
    if n < 2 {
        return Err(RateError::SeatsBelowTwo);
    }
    for (i, pl) in players.iter().enumerate() {
        if !(pl.sigma > 0.0) || !pl.sigma.is_finite() || !pl.mu.is_finite() {
            return Err(RateError::SigmaNotPositive { index: i });
        }
    }

    // Best-rank-first. A stable sort keeps seats that drew in seat order, so the graph a given
    // match builds is a function of the match alone.
    let mut order: Vec<usize> = (0..n).collect();
    order.sort_by_key(|&i| players[i].rank);

    // ---- variables. Each holds its current marginal.
    let mut rating: Vec<Gauss> = vec![Gauss::UNIFORM; n];
    let mut perf: Vec<Gauss> = vec![Gauss::UNIFORM; n];
    let mut diff: Vec<Gauss> = vec![Gauss::UNIFORM; n - 1];

    // ---- messages, one slot per (variable, factor) edge. Uniform is the identity under `mul`.
    let mut m_prior = vec![Gauss::UNIFORM; n]; // PriorFactor_i      -> rating[i]
    let mut m_lik_rating = vec![Gauss::UNIFORM; n]; // LikelihoodFactor_i -> rating[i]
    let mut m_lik_perf = vec![Gauss::UNIFORM; n]; // LikelihoodFactor_i -> perf[i]
    let mut m_sum_diff = vec![Gauss::UNIFORM; n - 1]; // SumFactor_j        -> diff[j]
    let mut m_sum_perf = vec![[Gauss::UNIFORM; 2]; n - 1]; // SumFactor_j   -> perf[j], perf[j+1]
    let mut m_trunc = vec![Gauss::UNIFORM; n - 1]; // TruncateFactor_j   -> diff[j]

    let beta_sq = p.beta * p.beta;
    let margin = gauss::draw_margin(p.draw_probability, 2.0, p.beta);
    let drawn: Vec<bool> =
        (0..n - 1).map(|j| players[order[j]].rank == players[order[j + 1]].rank).collect();

    // ---- the priors, and skill -> performance. One pass down; nothing above has spoken yet.
    for i in 0..n {
        let src = &players[order[i]];
        let sigma = (src.sigma * src.sigma + p.tau * p.tau).sqrt();
        update_value(&mut rating[i], &mut m_prior[i], Gauss::from_mu_sigma(src.mu, sigma));
    }
    for i in 0..n {
        let msg = rating[i].div(m_lik_rating[i]);
        let a = 1.0 / (1.0 + beta_sq * msg.pi);
        update_message(
            &mut perf[i],
            &mut m_lik_perf[i],
            Gauss { pi: a * msg.pi, tau: a * msg.tau },
        );
    }

    // ---- the loop: performances -> differences -> what the result says -> back again.
    //
    // One difference needs no iteration; a single down-and-up is exact. With more, each sweep runs
    // the chain forwards then backwards, which is what lets the fourth seat's result inform the
    // first's, until no truncation moves.
    let diffs = n - 1;
    for _ in 0..MAX_ITERATIONS {
        let delta = if diffs == 1 {
            sum_down(&mut diff, &mut m_sum_diff, &perf, &m_sum_perf, 0);
            truncate_up(&mut diff, &mut m_trunc, 0, margin, drawn[0])?
        } else {
            let mut delta: f64 = 0.0;
            for j in 0..diffs - 1 {
                sum_down(&mut diff, &mut m_sum_diff, &perf, &m_sum_perf, j);
                delta = delta.max(truncate_up(&mut diff, &mut m_trunc, j, margin, drawn[j])?);
                sum_up(&mut perf, &mut m_sum_perf, &diff, &m_sum_diff, j, 1);
            }
            for j in (1..diffs).rev() {
                sum_down(&mut diff, &mut m_sum_diff, &perf, &m_sum_perf, j);
                delta = delta.max(truncate_up(&mut diff, &mut m_trunc, j, margin, drawn[j])?);
                sum_up(&mut perf, &mut m_sum_perf, &diff, &m_sum_diff, j, 0);
            }
            delta
        };
        if delta <= MIN_DELTA {
            break;
        }
    }

    // ---- the two ends the sweep never pushed back, then performance -> skill.
    sum_up(&mut perf, &mut m_sum_perf, &diff, &m_sum_diff, 0, 0);
    sum_up(&mut perf, &mut m_sum_perf, &diff, &m_sum_diff, diffs - 1, 1);
    for i in 0..n {
        let msg = perf[i].div(m_lik_perf[i]);
        let a = 1.0 / (1.0 + beta_sq * msg.pi);
        update_message(
            &mut rating[i],
            &mut m_lik_rating[i],
            Gauss { pi: a * msg.pi, tau: a * msg.tau },
        );
    }

    let mut out = vec![(0.0, 0.0); n];
    for i in 0..n {
        out[order[i]] = (rating[i].mu(), rating[i].sigma());
    }
    Ok(out)
}

/// Replace the message this factor last sent along an edge and move the variable by the
/// difference, so it keeps everything the other edges told it.
fn update_message(var: &mut Gauss, slot: &mut Gauss, message: Gauss) -> f64 {
    let old = *slot;
    *slot = message;
    let updated = var.div(old).mul(message);
    let d = var.delta(updated);
    *var = updated;
    d
}

/// Set the variable outright and back out what this factor must have said for that to be the
/// marginal -- the way round the prior and truncation factors work, knowing the answer for the
/// variable rather than the message.
fn update_value(var: &mut Gauss, slot: &mut Gauss, value: Gauss) -> f64 {
    let old = *slot;
    *slot = value.mul(old).div(*var);
    let d = var.delta(value);
    *var = value;
    d
}

/// The weighted sum of Gaussians, in precision form: variances add through the square of the
/// coefficient, means through the coefficient.
fn combine(parts: &[(Gauss, Gauss, f64)]) -> Gauss {
    let mut pi_inv = 0.0f64;
    let mut mu = 0.0f64;
    for &(val, msg, coeff) in parts {
        let div = val.div(msg);
        mu += coeff * div.mu();
        if pi_inv.is_infinite() {
            continue;
        }
        pi_inv = if div.pi == 0.0 { f64::INFINITY } else { pi_inv + coeff * coeff / div.pi };
    }
    let pi = 1.0 / pi_inv; // an infinite pi_inv is a precision of zero: the uniform
    Gauss { pi, tau: pi * mu }
}

/// diff[j] <- perf[j] - perf[j+1]
fn sum_down(
    diff: &mut [Gauss],
    m_sum_diff: &mut [Gauss],
    perf: &[Gauss],
    m_sum_perf: &[[Gauss; 2]],
    j: usize,
) -> f64 {
    let parts = [(perf[j], m_sum_perf[j][0], 1.0), (perf[j + 1], m_sum_perf[j][1], -1.0)];
    update_message(&mut diff[j], &mut m_sum_diff[j], combine(&parts))
}

/// The same factor read backwards: given the difference, say something about one of its terms.
/// `index` 0 updates `perf[j]`, 1 updates `perf[j+1]`.
fn sum_up(
    perf: &mut [Gauss],
    m_sum_perf: &mut [[Gauss; 2]],
    diff: &[Gauss],
    m_sum_diff: &[Gauss],
    j: usize,
    index: usize,
) -> f64 {
    // Solving `diff = perf[j] - perf[j+1]` for the term at `index` flips the coefficients:
    // perf[j] = diff + perf[j+1], and perf[j+1] = perf[j] - diff.
    let (parts, target) = if index == 0 {
        ([(diff[j], m_sum_diff[j], 1.0), (perf[j + 1], m_sum_perf[j][1], 1.0)], j)
    } else {
        ([(perf[j], m_sum_perf[j][0], 1.0), (diff[j], m_sum_diff[j], -1.0)], j + 1)
    };
    let message = combine(&parts);
    update_message(&mut perf[target], &mut m_sum_perf[j][index], message)
}

/// What the recorded result says about the gap: that it was positive by at least the draw
/// margin, or that it was within the margin either way.
fn truncate_up(
    diff: &mut [Gauss],
    m_trunc: &mut [Gauss],
    j: usize,
    margin: f64,
    drawn: bool,
) -> Result<f64, RateError> {
    let div = diff[j].div(m_trunc[j]);
    let sqrt_pi = div.pi.sqrt();
    let d = div.tau / sqrt_pi;
    let m = margin * sqrt_pi;
    let (v, w) = if drawn {
        (gauss::v_draw(d, m), gauss::w_draw(d, m).ok_or(RateError::Diverged)?)
    } else {
        (gauss::v_win(d, m), gauss::w_win(d, m).ok_or(RateError::Diverged)?)
    };
    let denom = 1.0 - w;
    let value = Gauss { pi: div.pi / denom, tau: (div.tau + sqrt_pi * v) / denom };
    if !value.pi.is_finite() || !value.tau.is_finite() {
        return Err(RateError::Diverged);
    }
    Ok(update_value(&mut diff[j], &mut m_trunc[j], value))
}

#[cfg(test)]
mod tests {
    use super::*;

    const MU0: f64 = 25.0;
    const SIGMA0: f64 = 25.0 / 3.0;

    fn default_params() -> Params {
        Params { beta: 25.0 / 6.0, tau: 25.0 / 300.0, draw_probability: 0.10 }
    }

    fn players(spec: &[(f64, f64, i64)]) -> Vec<Player> {
        spec.iter().map(|&(mu, sigma, rank)| Player { mu, sigma, rank }).collect()
    }

    /// Every expectation is the reference implementation's own output for the same input. Ranks
    /// are 0-based only because that is how the reference spells them.
    fn assert_close(got: &[(f64, f64)], want: &[(f64, f64)], case: &str) {
        assert_eq!(got.len(), want.len(), "{case}: wrong length");
        for (i, (g, w)) in got.iter().zip(want).enumerate() {
            assert!(
                (g.0 - w.0).abs() < 1e-9 && (g.1 - w.1).abs() < 1e-9,
                "{case} seat {i}: got ({}, {}), want ({}, {})",
                g.0,
                g.1,
                w.0,
                w.1
            );
        }
    }

    #[test]
    fn two_seats_one_wins() {
        let out = rate(&players(&[(MU0, SIGMA0, 0), (MU0, SIGMA0, 1)]), &default_params()).unwrap();
        assert_close(
            &out,
            &[(29.39583201999916, 7.171475587326195), (20.604167980000835, 7.171475587326195)],
            "2p_win_equal",
        );
    }

    #[test]
    fn two_seats_draw() {
        let out = rate(&players(&[(MU0, SIGMA0, 0), (MU0, SIGMA0, 0)]), &default_params()).unwrap();
        assert_close(
            &out,
            &[(25.000000000000004, 6.457519662317322), (25.000000000000004, 6.457519662317322)],
            "2p_draw_equal",
        );
    }

    #[test]
    fn two_seats_asymmetric_priors() {
        let p = default_params();
        let favourite_wins = rate(&players(&[(30.0, 4.0, 0), (20.0, 7.5, 1)]), &p).unwrap();
        assert_close(
            &favourite_wins,
            &[(30.507638436655, 3.878913961894815), (18.215887646272364, 6.6623631665913345)],
            "2p_win_asym",
        );
        let upset = rate(&players(&[(30.0, 4.0, 1), (20.0, 7.5, 0)]), &p).unwrap();
        assert_close(
            &upset,
            &[(27.592065766768894, 3.752098510683774), (28.462765823603117, 5.695061906143087)],
            "2p_upset_asym",
        );
    }

    #[test]
    fn three_seats_distinct_ranks() {
        let out = rate(
            &players(&[(MU0, SIGMA0, 0), (MU0, SIGMA0, 1), (MU0, SIGMA0, 2)]),
            &default_params(),
        )
        .unwrap();
        assert_close(
            &out,
            &[
                (31.675352419171958, 6.655985377620712),
                (25.00000000000392, 6.207896641224336),
                (18.32464758082412, 6.65598537762185),
            ],
            "3p_distinct",
        );
    }

    #[test]
    fn three_seats_tie_for_first() {
        let out = rate(
            &players(&[(MU0, SIGMA0, 0), (MU0, SIGMA0, 0), (MU0, SIGMA0, 2)]),
            &default_params(),
        )
        .unwrap();
        assert_close(
            &out,
            &[
                (27.55196031712542, 5.974129648733217),
                (27.55733848563666, 5.972007244545816),
                (19.890701197237906, 6.735245186318146),
            ],
            "3p_tie_first",
        );
    }

    #[test]
    fn three_seats_tie_for_last_asymmetric() {
        let out =
            rate(&players(&[(28.0, 5.0, 0), (25.0, 8.0, 1), (22.0, 3.0, 1)]), &default_params())
                .unwrap();
        assert_close(
            &out,
            &[
                (29.496435340370283, 4.478340965500933),
                (22.278356426418934, 4.907225186800432),
                (21.8440022066377, 2.808927082817917),
            ],
            "3p_tie_last_asym",
        );
    }

    #[test]
    fn four_seats_distinct_ranks() {
        let out = rate(
            &players(&[(MU0, SIGMA0, 0), (MU0, SIGMA0, 1), (MU0, SIGMA0, 2), (MU0, SIGMA0, 3)]),
            &default_params(),
        )
        .unwrap();
        assert_close(
            &out,
            &[
                (33.20668096563102, 6.348109169807742),
                (27.40145469384325, 5.7871629348447815),
                (22.598545306188456, 5.78716293484137),
                (16.7933190343615, 6.348109169814532),
            ],
            "4p_distinct",
        );
    }

    #[test]
    fn four_seats_tie_in_the_middle() {
        let out = rate(
            &players(&[(26.0, 6.0, 0), (24.0, 7.0, 1), (25.0, 5.0, 1), (23.0, 8.0, 3)]),
            &default_params(),
        )
        .unwrap();
        assert_close(
            &out,
            &[
                (29.681918874956725, 4.952215117423137),
                (24.156718019963897, 4.731617314408795),
                (24.546425047736122, 4.044126954174926),
                (17.411188009475737, 6.103574757429247),
            ],
            "4p_tie_middle",
        );
    }

    #[test]
    fn four_seats_all_drawn() {
        let out = rate(
            &players(&[(MU0, SIGMA0, 0), (MU0, SIGMA0, 0), (MU0, SIGMA0, 0), (MU0, SIGMA0, 0)]),
            &default_params(),
        )
        .unwrap();
        assert_close(
            &out,
            &[
                (25.000000000000004, 5.280335258988771),
                (25.0, 5.2748071639047245),
                (25.000000000000007, 5.27480716390472),
                (25.000000000000004, 5.280335258988775),
            ],
            "4p_all_draw",
        );
    }

    #[test]
    fn parameters_reach_the_update() {
        // None of the three is baked in: a build that ignored one would be silently unchangeable.
        let out = rate(
            &players(&[(MU0, SIGMA0, 0), (MU0, SIGMA0, 1)]),
            &Params { beta: 3.0, tau: 0.2, draw_probability: 0.25 },
        )
        .unwrap();
        assert_close(
            &out,
            &[(29.812952080779358, 7.014280254239794), (20.187047919220635, 7.014280254239794)],
            "2p_custom_params",
        );

        let no_draws = rate(
            &players(&[(MU0, SIGMA0, 0), (MU0, SIGMA0, 1)]),
            &Params { draw_probability: 0.0, ..default_params() },
        )
        .unwrap();
        assert_close(
            &no_draws,
            &[(29.205473106813677, 7.194816551480743), (20.794526893186323, 7.194816551480743)],
            "2p_zero_draw_prob",
        );
    }

    #[test]
    fn ranks_numbering_is_immaterial() {
        // docs/design.md §8: equal means drew, and the numbering is the engine's business. Any
        // order-preserving relabelling must reach the same update.
        let p = default_params();
        let dense = rate(&players(&[(26.0, 5.0, 1), (24.0, 7.0, 1), (25.0, 6.0, 3)]), &p).unwrap();
        let competition =
            rate(&players(&[(26.0, 5.0, 1), (24.0, 7.0, 1), (25.0, 6.0, 2)]), &p).unwrap();
        let sparse =
            rate(&players(&[(26.0, 5.0, -7), (24.0, 7.0, -7), (25.0, 6.0, 400)]), &p).unwrap();
        assert_eq!(dense, competition);
        assert_eq!(dense, sparse);
    }

    #[test]
    fn seat_order_does_not_change_a_seat_s_result() {
        // `rate` sorts by rank and restores seat order afterwards.
        let p = default_params();
        let a = rate(&players(&[(30.0, 4.0, 1), (20.0, 7.5, 2)]), &p).unwrap();
        let b = rate(&players(&[(20.0, 7.5, 2), (30.0, 4.0, 1)]), &p).unwrap();
        assert_eq!(a[0], b[1]);
        assert_eq!(a[1], b[0]);
    }

    #[test]
    fn winning_raises_mu_and_playing_lowers_sigma() {
        let p = default_params();
        for n in 2..=4usize {
            let spec: Vec<_> = (0..n).map(|i| (MU0, SIGMA0, i as i64)).collect();
            let out = rate(&players(&spec), &p).unwrap();
            for i in 0..n - 1 {
                assert!(out[i].0 > out[i + 1].0, "n={n}: rank {i} must out-rate rank {}", i + 1);
            }
            for (i, (_, sigma)) in out.iter().enumerate() {
                assert!(*sigma < SIGMA0, "n={n} seat {i}: sigma must fall, got {sigma}");
                assert!(*sigma > 0.0);
            }
        }
    }

    #[test]
    fn a_symmetric_match_conserves_the_mean() {
        // A property of the update rather than a reference number, so it holds at any seat count.
        let p = default_params();
        for n in 2..=4usize {
            let spec: Vec<_> = (0..n).map(|i| (MU0, SIGMA0, i as i64)).collect();
            let out = rate(&players(&spec), &p).unwrap();
            let total: f64 = out.iter().map(|(mu, _)| mu).sum();
            assert!(
                (total - MU0 * n as f64).abs() < 1e-6,
                "n={n}: mean not conserved, total {total}"
            );
        }
    }

    #[test]
    fn refusals() {
        let p = default_params();
        assert_eq!(rate(&players(&[(MU0, SIGMA0, 0)]), &p), Err(RateError::SeatsBelowTwo));
        assert_eq!(rate(&[], &p), Err(RateError::SeatsBelowTwo));
        assert_eq!(
            rate(&players(&[(MU0, 0.0, 0), (MU0, SIGMA0, 1)]), &p),
            Err(RateError::SigmaNotPositive { index: 0 })
        );
        assert_eq!(
            rate(&players(&[(MU0, SIGMA0, 0), (MU0, -1.0, 1)]), &p),
            Err(RateError::SigmaNotPositive { index: 1 })
        );
        assert_eq!(
            rate(&players(&[(MU0, SIGMA0, 0), (MU0, f64::NAN, 1)]), &p),
            Err(RateError::SigmaNotPositive { index: 1 })
        );
    }
}
