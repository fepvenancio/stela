// Share math utilities for Stela protocol
// Implements ERC-4626 style share conversion with virtual offset to prevent inflation attacks.

/// Virtual offset added to total supply to prevent first-depositor inflation attacks.
/// Using 1e16 provides precision for BPS-based percentages.
pub const VIRTUAL_SHARE_OFFSET: u256 = 10_000_000_000_000_000; // 1e16

/// Maximum basis points (100%).
pub const MAX_BPS: u256 = 10_000;

/// Convert a debt percentage (in BPS) to shares for a given inscription.
///
/// Formula: shares = issuedDebtPercentage * (totalSupply + VIRTUAL_SHARE_OFFSET) / (currentIssuedDebtPercentage + 1)
///
/// The virtual offset ensures that:
/// - First depositor can't manipulate the share price
/// - Division by zero is prevented (denominator is always >= 1)
///
/// # Arguments
/// * `issued_debt_percentage` - The percentage of debt being issued (in BPS, max 10,000)
/// * `total_supply` - Current total supply of shares for this inscription
/// * `current_issued_debt_percentage` - Current issued debt percentage for the inscription
///
/// # Returns
/// The number of shares to mint
pub fn convert_to_shares(
    issued_debt_percentage: u256, total_supply: u256, current_issued_debt_percentage: u256,
) -> u256 {
    // shares = issuedDebtPercentage * (totalSupply + 1e16) / max(currentIssuedDebtPercentage, 1)
    let numerator = issued_debt_percentage * (total_supply + VIRTUAL_SHARE_OFFSET);
    let denominator = if current_issued_debt_percentage == 0 {
        1_u256
    } else {
        current_issued_debt_percentage
    };
    numerator / denominator
}

/// Convert shares to a debt percentage (in BPS) for redemption.
///
/// Formula: percentage = shares * (currentIssuedDebtPercentage + 1) / (totalSupply + VIRTUAL_SHARE_OFFSET)
///
/// This is the inverse of convert_to_shares.
///
/// # Arguments
/// * `shares` - The number of shares being redeemed
/// * `total_supply` - Current total supply of shares for this inscription
/// * `current_issued_debt_percentage` - Current issued debt percentage for the inscription
///
/// # Returns
/// The percentage of assets to receive (in BPS)
pub fn convert_to_percentage(shares: u256, total_supply: u256, current_issued_debt_percentage: u256) -> u256 {
    // percentage = shares * max(currentIssuedDebtPercentage, 1) / (totalSupply + 1e16)
    let effective_pct = if current_issued_debt_percentage == 0 {
        1_u256
    } else {
        current_issued_debt_percentage
    };
    let numerator = shares * effective_pct;
    let denominator = total_supply + VIRTUAL_SHARE_OFFSET;
    numerator / denominator
}

/// Scale an asset value by a percentage (in BPS).
///
/// # Arguments
/// * `value` - The asset value to scale
/// * `percentage` - The percentage to apply (in BPS, e.g., 5000 = 50%)
///
/// # Returns
/// The scaled value
pub fn scale_by_percentage(value: u256, percentage: u256) -> u256 {
    (value * percentage) / MAX_BPS
}

/// Calculate fee shares from lender shares.
///
/// # Arguments
/// * `shares` - The lender's shares
/// * `fee_bps` - The fee in BPS (e.g., 10 = 0.1%)
///
/// # Returns
/// The number of shares to mint to treasury
pub fn calculate_fee_shares(shares: u256, fee_bps: u256) -> u256 {
    (shares * fee_bps) / MAX_BPS
}

/// Ceiling division: ceil(a / b) = (a + b - 1) / b.
/// Panics if b == 0 (Cairo built-in).
pub fn div_ceil(a: u256, b: u256) -> u256 {
    (a + b - 1) / b
}

/// Pro-rata interest for early repayment.
/// Rounds UP (ceiling) to protect lenders — borrower never underpays.
///
/// Formula: ceil(amount * elapsed / duration)
///
/// Edge cases:
/// - amount == 0 → 0
/// - elapsed == 0 → 0 (instant repay, no interest)
/// - elapsed >= duration → amount (full interest, capped)
/// - duration == 0 → caller must handle (swaps use full interest)
///
/// Overflow safety: amount (u128 max) * elapsed (u64 max) ≈ 2^192, fits in u256.
pub fn pro_rata_interest(amount: u256, elapsed: u64, duration: u64) -> u256 {
    if amount == 0 || elapsed == 0 {
        return 0;
    }
    if elapsed >= duration {
        return amount;
    }
    let elapsed_u256: u256 = elapsed.into();
    let duration_u256: u256 = duration.into();
    div_ceil(amount * elapsed_u256, duration_u256)
}

#[cfg(test)]
mod tests {
    use super::{
        MAX_BPS, VIRTUAL_SHARE_OFFSET, calculate_fee_shares, convert_to_percentage, convert_to_shares,
        div_ceil, pro_rata_interest, scale_by_percentage,
    };

    #[test]
    fn test_first_deposit_shares() {
        // First deposit: 100% debt (10,000 BPS)
        // totalSupply = 0, currentIssuedDebtPercentage = 0
        // Expected: 10,000 * (0 + 1e16) / (0 + 1) = 1e20
        let shares = convert_to_shares(MAX_BPS, 0, 0);
        assert!(shares == MAX_BPS * VIRTUAL_SHARE_OFFSET, "first deposit should get 1e20 shares");
    }

    #[test]
    fn test_second_deposit_equal_shares() {
        // First depositor took 50% (5,000 BPS)
        // They received: 5,000 * (0 + 1e16) / (0 + 1) = 5e19 shares
        let first_shares = convert_to_shares(5000, 0, 0);

        // Second depositor also takes 50% (5,000 BPS)
        // totalSupply = 5e19, currentIssuedDebtPercentage = 5,000
        // Expected: 5,000 * (5e19 + 1e16) / (5,000 + 1) ≈ 5e19
        let second_shares = convert_to_shares(5000, first_shares, 5000);

        // The shares should be approximately equal (within rounding error)
        // Both depositors get roughly equal shares for equal percentages.
        // The virtual offset (1e16) causes a small constant difference.
        let diff = if first_shares > second_shares {
            first_shares - second_shares
        } else {
            second_shares - first_shares
        };

        // Allow for small rounding differences (up to the virtual offset)
        assert!(diff <= VIRTUAL_SHARE_OFFSET, "equal deposits should get roughly equal shares");
    }

    #[test]
    fn test_convert_to_percentage_roundtrip() {
        // Deposit 50% (5,000 BPS)
        let shares = convert_to_shares(5000, 0, 0);
        let total_supply = shares;
        let issued_debt_percentage: u256 = 5000;

        // Convert back to percentage
        let percentage = convert_to_percentage(shares, total_supply, issued_debt_percentage);

        // Should get back approximately 5,000 BPS
        let diff = if percentage > 5000 {
            percentage - 5000
        } else {
            5000 - percentage
        };
        assert!(diff <= 1, "roundtrip should preserve percentage");
    }

    #[test]
    fn test_scale_by_percentage() {
        // 1000 tokens scaled by 50% (5,000 BPS)
        let scaled = scale_by_percentage(1000, 5000);
        assert!(scaled == 500, "50% of 1000 should be 500");

        // 100 tokens scaled by 100% (10,000 BPS)
        let full = scale_by_percentage(100, MAX_BPS);
        assert!(full == 100, "100% should return full amount");

        // 100 tokens scaled by 0%
        let zero = scale_by_percentage(100, 0);
        assert!(zero == 0, "0% should return 0");
    }

    #[test]
    fn test_calculate_fee_shares() {
        // 10,000 shares with 10 BPS fee (0.1%)
        let fee = calculate_fee_shares(10000, 10);
        assert!(fee == 10, "0.1% of 10,000 should be 10");

        // 1,000,000 shares with 100 BPS fee (1%)
        let fee2 = calculate_fee_shares(1000000, 100);
        assert!(fee2 == 10000, "1% of 1,000,000 should be 10,000");
    }

    // ─── div_ceil tests ───

    #[test]
    fn test_div_ceil_exact() {
        assert!(div_ceil(10, 5) == 2, "10/5 = 2 exact");
        assert!(div_ceil(0, 7) == 0, "0/7 = 0");
    }

    #[test]
    fn test_div_ceil_rounds_up() {
        assert!(div_ceil(7, 3) == 3, "ceil(7/3) = 3");
        assert!(div_ceil(1, 3) == 1, "ceil(1/3) = 1");
        assert!(div_ceil(10, 3) == 4, "ceil(10/3) = 4");
    }

    // ─── pro_rata_interest tests ───

    #[test]
    fn test_pro_rata_zero_amount() {
        assert!(pro_rata_interest(0, 100, 200) == 0, "zero amount => zero interest");
    }

    #[test]
    fn test_pro_rata_zero_elapsed() {
        assert!(pro_rata_interest(1000, 0, 200) == 0, "zero elapsed => zero interest");
    }

    #[test]
    fn test_pro_rata_full_duration() {
        // elapsed == duration => full interest
        assert!(pro_rata_interest(1000, 200, 200) == 1000, "full duration => full interest");
    }

    #[test]
    fn test_pro_rata_over_duration() {
        // elapsed > duration => capped at full interest
        assert!(pro_rata_interest(1000, 300, 200) == 1000, "over duration => capped at full");
    }

    #[test]
    fn test_pro_rata_half_duration() {
        // 1000 * 100 / 200 = 500 (exact)
        assert!(pro_rata_interest(1000, 100, 200) == 500, "half duration => half interest");
    }

    #[test]
    fn test_pro_rata_rounds_up() {
        // 1000 * 1 / 3 = 333.33... => ceil = 334
        assert!(pro_rata_interest(1000, 1, 3) == 334, "rounds up to protect lenders");
    }

    #[test]
    fn test_pro_rata_one_second() {
        // 1000 * 1 / 86400 = 0.0115... => ceil = 1
        assert!(pro_rata_interest(1000, 1, 86400) == 1, "1 second of 1 day => at least 1 wei");
    }

    #[test]
    fn test_pro_rata_large_amount() {
        // u128 max * u64 halfway => fits in u256
        let amount: u256 = 340282366920938463463374607431768211455; // u128::MAX
        let duration: u64 = 31536000; // 1 year
        let elapsed: u64 = 15768000; // half year
        let result = pro_rata_interest(amount, elapsed, duration);
        // Should be approximately half, rounded up
        let half = amount / 2;
        assert!(result >= half, "large amount half should be >= half");
        assert!(result <= half + 1, "large amount half should be <= half + 1");
    }
}
