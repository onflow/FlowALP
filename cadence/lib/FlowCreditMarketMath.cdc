access(all) contract FlowCreditMarketMath {

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

    init() {
        self.ufix64Step = 0.00000001
        self.ufix64HalfStep = self.ufix64Step / 2.0
        self.decimals = 24
        self.ufix64Decimals = 8

        self.one = 1.0
        self.zero = 0.0
    }
}
