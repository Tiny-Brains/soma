//! Gaussians in precision form, and the four normal-distribution functions the TrueSkill update
//! is written in terms of.
//!
//! A Gaussian is carried as `(pi, tau)` -- precision `1/sigma^2` and precision-adjusted mean
//! `mu/sigma^2` -- rather than `(mu, sigma)`, because message passing multiplies and divides
//! distributions far more often than it reads them, and in this form both are addition. The
//! uniform distribution, which is what an unsent message is, is `(0, 0)`: representable here and
//! not representable as a `(mu, sigma)` pair at all.
//!
//! ON `erfc`. The Numerical Recipes rational approximation, accurate to a relative 1.2e-7. That is
//! deliberate over a near-machine-precision routine: it is the one the reference implementation
//! this module was verified against uses, so the vectors in `trueskill.rs` agree to 1e-9 and catch
//! real errors rather than drowning them in approximation noise. On a rating near 25 the absolute
//! error is around 3e-6, four orders below the second decimal a rating is ever read at, and it is
//! swamped by `beta` and `tau`. To want more, replace this function and loosen the vectors'
//! epsilon; nothing else in the module changes.

use core::f64::consts::{FRAC_2_SQRT_PI, PI, SQRT_2};

/// A Gaussian as `(precision, precision-adjusted mean)`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Gauss {
    pub pi: f64,
    pub tau: f64,
}

impl Gauss {
    /// The uniform distribution: knows nothing, and is what every message starts as.
    pub const UNIFORM: Gauss = Gauss { pi: 0.0, tau: 0.0 };

    pub fn from_mu_sigma(mu: f64, sigma: f64) -> Gauss {
        let pi = sigma.powi(-2);
        Gauss { pi, tau: pi * mu }
    }

    pub fn mu(&self) -> f64 {
        if self.pi == 0.0 { 0.0 } else { self.tau / self.pi }
    }

    pub fn sigma(&self) -> f64 {
        if self.pi == 0.0 { f64::INFINITY } else { (1.0 / self.pi).sqrt() }
    }

    /// The product of two Gaussians, unnormalised -- which in this parameterisation is addition.
    pub fn mul(self, other: Gauss) -> Gauss {
        Gauss { pi: self.pi + other.pi, tau: self.tau + other.tau }
    }

    /// Division: how a variable's marginal is stripped of one incoming message so the message
    /// that leaves along that edge does not carry its own past back to its sender.
    pub fn div(self, other: Gauss) -> Gauss {
        Gauss { pi: self.pi - other.pi, tau: self.tau - other.tau }
    }

    /// How far this distribution moved, for the convergence test. An infinite change in precision
    /// is reported as none: it means a message went from "unknown" to "known", which is the first
    /// pass rather than a failure to settle.
    pub fn delta(self, other: Gauss) -> f64 {
        let pi_delta = (self.pi - other.pi).abs();
        if pi_delta.is_infinite() {
            return 0.0;
        }
        (self.tau - other.tau).abs().max(pi_delta.sqrt())
    }
}

/// Complementary error function. See the module note on accuracy.
pub fn erfc(x: f64) -> f64 {
    let z = x.abs();
    let t = 1.0 / (1.0 + z / 2.0);
    let r = t
        * (-z * z - 1.265_512_23
            + t * (1.000_023_68
                + t * (0.374_091_96
                    + t * (0.096_784_18
                        + t * (-0.186_288_06
                            + t * (0.278_868_07
                                + t * (-1.135_203_98
                                    + t * (1.488_515_87
                                        + t * (-0.822_152_23 + t * 0.170_872_77)))))))))
            .exp();
    if x < 0.0 { 2.0 - r } else { r }
}

/// The inverse of `erfc`: a rational guess refined by two Newton steps against `erfc` itself, so
/// it inverts whichever `erfc` is in use rather than an ideal one.
///
/// The 0.70711 below is the reference implementation's own literal, not a rounded `FRAC_1_SQRT_2`.
/// Both Newton steps converge regardless, but matching the reference is what keeps `trueskill.rs`'s
/// vectors meaningful to 1e-9, so it is left as written.
#[allow(clippy::approx_constant)]
pub fn erfcinv(y: f64) -> f64 {
    if y >= 2.0 {
        return -100.0;
    }
    if y <= 0.0 {
        return 100.0;
    }
    let below_one = y < 1.0;
    let y = if below_one { y } else { 2.0 - y };
    let t = (-2.0 * (y / 2.0).ln()).sqrt();
    let mut x = -0.70711 * ((2.30753 + t * 0.27061) / (1.0 + t * (0.99229 + t * 0.04481)) - t);
    for _ in 0..2 {
        let err = erfc(x) - y;
        x += err / (FRAC_2_SQRT_PI * (-(x * x)).exp() - x * err);
    }
    if below_one { x } else { -x }
}

/// Standard normal cumulative distribution.
pub fn cdf(x: f64) -> f64 {
    0.5 * erfc(-x / SQRT_2)
}

/// Standard normal density.
pub fn pdf(x: f64) -> f64 {
    (1.0 / (2.0 * PI).sqrt()) * (-(x * x) / 2.0).exp()
}

/// Standard normal quantile: the inverse of `cdf`.
pub fn ppf(x: f64) -> f64 {
    -SQRT_2 * erfcinv(2.0 * x)
}

/// How much the mean of a performance difference moves, given one side won by more than the draw
/// margin. The `else` arm is the saturated case: `cdf` underflowed to zero, meaning the result was
/// effectively impossible under the prior, and `-x` is the limit the ratio tends to.
pub fn v_win(diff: f64, margin: f64) -> f64 {
    let x = diff - margin;
    let denom = cdf(x);
    if denom != 0.0 { pdf(x) / denom } else { -x }
}

/// How much its variance shrinks, in the same case. Outside `(0, 1)` the update would grow more
/// uncertain from having observed something, which always means the inputs were too extreme for
/// f64; the caller reports it rather than writing a rating.
pub fn w_win(diff: f64, margin: f64) -> Option<f64> {
    let x = diff - margin;
    let v = v_win(diff, margin);
    let w = v * (v + x);
    if w > 0.0 && w < 1.0 { Some(w) } else { None }
}

/// The same, given that the two sides finished within the draw margin of each other.
pub fn v_draw(diff: f64, margin: f64) -> f64 {
    let abs_diff = diff.abs();
    let (a, b) = (margin - abs_diff, -margin - abs_diff);
    let denom = cdf(a) - cdf(b);
    let numer = pdf(b) - pdf(a);
    let base = if denom != 0.0 { numer / denom } else { a };
    if diff < 0.0 { -base } else { base }
}

pub fn w_draw(diff: f64, margin: f64) -> Option<f64> {
    let abs_diff = diff.abs();
    let (a, b) = (margin - abs_diff, -margin - abs_diff);
    let denom = cdf(a) - cdf(b);
    if denom == 0.0 {
        return None;
    }
    let v = v_draw(abs_diff, margin);
    Some(v * v + (a * pdf(a) - b * pdf(b)) / denom)
}

/// The performance gap below which a result is called a draw, derived from how often draws are
/// expected. `size` is the number of players across the two sides being compared -- two, here,
/// since every seat is its own side.
pub fn draw_margin(draw_probability: f64, size: f64, beta: f64) -> f64 {
    ppf((draw_probability + 1.0) / 2.0) * size.sqrt() * beta
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gaussian_arithmetic_round_trips() {
        let g = Gauss::from_mu_sigma(25.0, 25.0 / 3.0);
        assert!((g.mu() - 25.0).abs() < 1e-12);
        assert!((g.sigma() - 25.0 / 3.0).abs() < 1e-12);
        // Dividing by what was multiplied in returns the original.
        let h = Gauss::from_mu_sigma(30.0, 4.0);
        let back = g.mul(h).div(h);
        assert!((back.pi - g.pi).abs() < 1e-12 && (back.tau - g.tau).abs() < 1e-12);
    }

    #[test]
    fn uniform_is_the_identity_and_knows_nothing() {
        let g = Gauss::from_mu_sigma(25.0, 8.0);
        assert_eq!(g.mul(Gauss::UNIFORM), g);
        assert_eq!(Gauss::UNIFORM.sigma(), f64::INFINITY);
        assert_eq!(Gauss::UNIFORM.mu(), 0.0);
    }

    /// The bound from the module note, not the observed error (9.4e-8 over [-4, 4]), so these
    /// assertions state the contract rather than the current build's luck.
    const EPS: f64 = 1.2e-7;

    #[test]
    fn cdf_is_a_distribution() {
        assert!((cdf(0.0) - 0.5).abs() < EPS);
        assert!(cdf(-8.0) >= 0.0 && cdf(-8.0) < 1e-12);
        assert!((cdf(8.0) - 1.0).abs() < 1e-12);
        // monotone
        let mut prev = 0.0;
        for i in -60..=60 {
            let c = cdf(i as f64 / 10.0);
            assert!(c >= prev, "cdf not monotone at {i}");
            prev = c;
        }
    }

    #[test]
    fn ppf_inverts_cdf() {
        for p in [0.01, 0.1, 0.25, 0.5, 0.55, 0.75, 0.9, 0.99] {
            let x = ppf(p);
            assert!((cdf(x) - p).abs() < EPS, "ppf/cdf disagree at {p}: {}", cdf(x));
        }
    }

    #[test]
    fn a_zero_draw_probability_is_a_zero_margin() {
        // No expectation of draws, no band around zero in which a result counts as one.
        assert!(draw_margin(0.0, 2.0, 25.0 / 6.0).abs() < 1e-6);
        assert!(draw_margin(0.10, 2.0, 25.0 / 6.0) > 0.0);
        // And a wider expectation is a wider band.
        assert!(draw_margin(0.30, 2.0, 25.0 / 6.0) > draw_margin(0.10, 2.0, 25.0 / 6.0));
    }
}
