import "FlowALPMath"

access(all) contract FlowALPRateCurves {

    /// InterestCurve
    ///
    /// A simple interface to calculate interest rate for a token type.
    access(all) struct interface InterestCurve {
        /// Returns the annual interest rate for the given credit and debit balance, for some token T.
        /// @param creditBalance The credit (deposit) balance of token T
        /// @param debitBalance The debit (withdrawal) balance of token T
        access(all) fun interestRate(creditBalance: UFix128, debitBalance: UFix128): UFix128 {
            post {
                // Max rate is 400% (4.0) to accommodate high-utilization scenarios
                // with kink-based curves like Aave v3's interest rate strategy
                result <= 4.0:
                    "Interest rate can't exceed 400%"
            }
        }
    }

    /// FixedRateInterestCurve
    ///
    /// A fixed-rate interest curve implementation that returns a constant yearly interest rate
    /// regardless of utilization. This is suitable for stable assets like MOET where predictable
    /// rates are desired.
    /// @param yearlyRate The fixed yearly interest rate as a UFix128 (e.g., 0.05 for 5% APY)
    access(all) struct FixedRateInterestCurve: InterestCurve {

        access(all) let yearlyRate: UFix128

        init(yearlyRate: UFix128) {
            pre {
                yearlyRate <= 1.0: "Yearly rate cannot exceed 100%, got \(yearlyRate)"
            }
            self.yearlyRate = yearlyRate
        }

        access(all) fun interestRate(creditBalance: UFix128, debitBalance: UFix128): UFix128 {
            return self.yearlyRate
        }
    }

    /// KinkInterestCurve
    ///
    /// A kink-based interest rate curve implementation. The curve has two linear segments:
    /// - Before the optimal utilization ratio (the "kink"): a gentle slope
    /// - After the optimal utilization ratio: a steep slope to discourage over-utilization
    ///
    /// This creates a "kinked" curve that incentivizes maintaining utilization near the
    /// optimal point while heavily penalizing over-utilization to protect protocol liquidity.
    ///
    /// Formula:
    /// - utilization = debitBalance / (creditBalance + debitBalance)
    /// - Before kink (utilization <= optimalUtilization):
    ///   rate = baseRate + (slope1 × utilization / optimalUtilization)
    /// - After kink (utilization > optimalUtilization):
    ///   rate = baseRate + slope1 + (slope2 × excessUtilization)
    ///   where excessUtilization = (utilization - optimalUtilization) / (1 - optimalUtilization)
    ///
    /// @param optimalUtilization The target utilization ratio (e.g., 0.80 for 80%)
    /// @param baseRate The minimum yearly interest rate (e.g., 0.01 for 1% APY)
    /// @param slope1 The total rate increase from 0% to optimal utilization (e.g., 0.04 for 4%)
    /// @param slope2 The total rate increase from optimal to 100% utilization (e.g., 0.60 for 60%)
    access(all) struct KinkInterestCurve: InterestCurve {

        /// The optimal utilization ratio (the "kink" point), e.g., 0.80 = 80%
        access(all) let optimalUtilization: UFix128

        /// The base yearly interest rate applied at 0% utilization
        access(all) let baseRate: UFix128

        /// The slope of the interest curve before the optimal point (gentle slope)
        access(all) let slope1: UFix128

        /// The slope of the interest curve after the optimal point (steep slope)
        access(all) let slope2: UFix128

        init(
            optimalUtilization: UFix128,
            baseRate: UFix128,
            slope1: UFix128,
            slope2: UFix128
        ) {
            pre {
                optimalUtilization >= 0.01:
                    "Optimal utilization must be at least 1%, got \(optimalUtilization)"
                optimalUtilization <= 0.99:
                    "Optimal utilization must be at most 99%, got \(optimalUtilization)"
                slope2 >= slope1:
                    "Slope2 (\(slope2)) must be >= slope1 (\(slope1))"
                baseRate + slope1 + slope2 <= 4.0:
                    "Maximum rate cannot exceed 400%, got \(baseRate + slope1 + slope2)"
            }
            self.optimalUtilization = optimalUtilization
            self.baseRate = baseRate
            self.slope1 = slope1
            self.slope2 = slope2
        }

        access(all) fun interestRate(creditBalance: UFix128, debitBalance: UFix128): UFix128 {
            // If no debt, return base rate
            if debitBalance == 0.0 {
                return self.baseRate
            }

            // Calculate utilization ratio: debitBalance / (creditBalance + debitBalance)
            // Note: totalBalance > 0 is guaranteed since debitBalance > 0 and creditBalance >= 0
            let totalBalance = creditBalance + debitBalance
            let utilization = debitBalance / totalBalance

            // If utilization is below or at the optimal point, use slope1
            if utilization <= self.optimalUtilization {
                // rate = baseRate + (slope1 × utilization / optimalUtilization)
                let utilizationFactor = utilization / self.optimalUtilization
                let slope1Component = self.slope1 * utilizationFactor
                return self.baseRate + slope1Component
            } else {
                // If utilization is above the optimal point, use slope2 for excess
                // excessUtilization = (utilization - optimalUtilization) / (1 - optimalUtilization)
                let excessUtilization = utilization - self.optimalUtilization
                let maxExcess = FlowALPMath.one - self.optimalUtilization
                let excessFactor = excessUtilization / maxExcess

                // rate = baseRate + slope1 + (slope2 × excessFactor)
                let slope2Component = self.slope2 * excessFactor
                return self.baseRate + self.slope1 + slope2Component
            }
        }
    }
}
