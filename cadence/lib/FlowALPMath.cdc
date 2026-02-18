access(all) contract FlowALPMath {

    access(self) let ufix64Step: UFix128
    access(self) let ufix64HalfStep: UFix128

    access(all) let decimals: UInt8
    access(all) let ufix64Decimals: UInt8

    /// Deprecated: Use 1.0 directly
    access(all) let one: UFix128
    /// Deprecated: Use 0.0 directly
    access(all) let zero: UFix128

    access(all) enum RoundingMode: UInt8 {
        access(all) case RoundDown
        access(all) case RoundUp
        access(all) case RoundHalfUp
        access(all) case RoundEven
    }

    /// Fast exponentiation for UFix128 with a non-negative integer exponent (seconds).
    /// Uses exponentiation-by-squaring with truncation at each multiply (fixed-point semantics)
    access(all) view fun powUFix128(_ base: UFix128, _ expSeconds: UFix64): UFix128 {
        if expSeconds == 0.0 { return 1.0 }
        if base == 1.0 { return 1.0 }
        var result: UFix128 = 1.0
        var b = base
        var e = expSeconds
        // Floor the seconds to an integer count
        var remaining = UInt64(e)
        while remaining > 0 {
            if remaining % 2 == 1 {
                result = result * b
            }
            b = b * b
            remaining = remaining / 2
        }
        return result
    }

    access(all) view fun toUFix64(_ value: UFix128, rounding: RoundingMode): UFix64 {
        let truncated = UFix64(value)
        let truncatedAs128 = UFix128(truncated)
        let remainder = value - truncatedAs128

        if remainder == 0.0 {
            return truncated
        }

        switch rounding {
        case self.RoundingMode.RoundDown:
            return truncated
        case self.RoundingMode.RoundUp:
            return self.roundUp(truncated)
        case self.RoundingMode.RoundHalfUp:
            return remainder >= self.ufix64HalfStep ? self.roundUp(truncated) : truncated
        case self.RoundingMode.RoundEven:
            return self.roundHalfToEven(truncated, remainder)
        default:
            panic("Unsupported rounding mode")
        }
    }

    access(all) view fun toUFix64Round(_ value: UFix128): UFix64 {
        return self.toUFix64(value, rounding: self.RoundingMode.RoundHalfUp)
    }

    access(all) view fun toUFix64RoundDown(_ value: UFix128): UFix64 {
        return self.toUFix64(value, rounding: self.RoundingMode.RoundDown)
    }

    access(all) view fun toUFix64RoundUp(_ value: UFix128): UFix64 {
        return self.toUFix64(value, rounding: self.RoundingMode.RoundUp)
    }

    access(self) view fun roundUp(_ base: UFix64): UFix64 {
        let increment: UFix64 = 0.00000001
        return base >= UFix64.max - increment ? UFix64.max : base + increment
    }

    access(self) view fun roundHalfToEven(_ base: UFix64, _ remainder: UFix128): UFix64 {
        if remainder < self.ufix64HalfStep {
            return base
        }
        if remainder > self.ufix64HalfStep {
            return self.roundUp(base)
        }
        let scaled = base * 100_000_000.0
        let scaledInt = UInt64(scaled)
        return scaledInt % 2 == 1 ? self.roundUp(base) : base
    }

    /// Checks that the DEX price does not deviate from the oracle price by more than the given threshold.
    /// The deviation is computed as the absolute difference divided by the smaller price, expressed in basis points.
    access(all) view fun dexOraclePriceDeviationInRange(dexPrice: UFix64, oraclePrice: UFix64, maxDeviationBps: UInt16): Bool {
        let diff: UFix64 = dexPrice < oraclePrice ? oraclePrice - dexPrice : dexPrice - oraclePrice
        let diffPct: UFix64 = dexPrice < oraclePrice ? diff / dexPrice : diff / oraclePrice
        let diffBps = UInt16(diffPct * 10_000.0)
        return diffBps <= maxDeviationBps
    }

    /// Converts a yearly interest rate to a per-second multiplication factor (stored in a UFix128 as a fixed point
    /// number with 18 decimal places). The input to this function will be just the relative annual interest rate
    /// (e.g. 0.05 for 5% interest), and the result will be the per-second multiplier (e.g. 1.000000000001).
    access(all) view fun perSecondInterestRate(yearlyRate: UFix128): UFix128 {
        let perSecondScaledValue = yearlyRate / 31_557_600.0 // 365.25 * 24.0 * 60.0 * 60.0
        assert(
            perSecondScaledValue < UFix128.max,
            message: "Per-second interest rate \(perSecondScaledValue) is too high"
        )
        return perSecondScaledValue + 1.0
    }

    /// Returns the compounded interest index reflecting the passage of time
    /// The result is: newIndex = oldIndex * perSecondRate ^ seconds
    access(all) view fun compoundInterestIndex(
        oldIndex: UFix128,
        perSecondRate: UFix128,
        elapsedSeconds: UFix64
    ): UFix128 {
        let pow = FlowALPMath.powUFix128(perSecondRate, elapsedSeconds)
        return oldIndex * pow
    }

    /// Transforms the provided `scaledBalance` to a true balance (or actual balance)
    /// where the true balance is the scaledBalance + accrued interest
    /// and the scaled balance is the amount a borrower has actually interacted with (via deposits or withdrawals)
    access(all) view fun scaledBalanceToTrueBalance(
        _ scaled: UFix128,
        interestIndex: UFix128
    ): UFix128 {
        return scaled * interestIndex
    }

    /// Transforms the provided `trueBalance` to a scaled balance
    /// where the scaled balance is the amount a borrower has actually interacted with (via deposits or withdrawals)
    /// and the true balance is the amount with respect to accrued interest
    access(all) view fun trueBalanceToScaledBalance(
        _ trueBalance: UFix128,
        interestIndex: UFix128
    ): UFix128 {
        return trueBalance / interestIndex
    }

    /// Returns the effective collateral (denominated in $) for the given credit balance of some token T.
    /// Ce = (Nc)(Pc)(Fc)
    access(all) view fun effectiveCollateral(credit: UFix128, price: UFix128, collateralFactor: UFix128): UFix128 {
        return (credit * price) * collateralFactor
    }

    /// Returns the effective debt (denominated in $) for the given debit balance of some token T.
    /// De = (Nd)(Pd)(Fd)
    access(all) view fun effectiveDebt(debit: UFix128, price: UFix128, borrowFactor: UFix128): UFix128 {
        return (debit * price) / borrowFactor
    }

    /// Returns a health value computed from the provided effective collateral and debt values
    /// where health is a ratio of effective collateral over effective debt
    access(all) view fun healthComputation(effectiveCollateral: UFix128, effectiveDebt: UFix128): UFix128 {
        if effectiveDebt == 0.0 {
            return UFix128.max
        }

        if effectiveCollateral == 0.0 {
            return 0.0
        }

        if (effectiveDebt / effectiveCollateral) == 0.0 {
            return UFix128.max
        }

        return effectiveCollateral / effectiveDebt
    }

    init() {
        self.ufix64Step = 0.00000001
        self.ufix64HalfStep = self.ufix64Step / 2.0
        self.decimals = 24
        self.ufix64Decimals = 8

        self.one = 1.0
        self.zero = 0.0
    }
}
