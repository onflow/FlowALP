access(all) contract TidalMath {

    access(all) let one: UFix128
    access(all) let zero: UFix128
    access(self) let ufix64Step: UFix128
    access(self) let ufix64HalfStep: UFix128

    access(all) let decimals: UInt8
    access(all) let ufix64Decimals: UInt8

    access(all) enum RoundingMode: UInt8 {
        access(all) case RoundDown
        access(all) case RoundUp
        access(all) case RoundHalfUp
        access(all) case RoundEven
    }

    // mul removed: use the built-in * operator directly

    access(all) view fun div(_ x: UFix128, _ y: UFix128): UFix128 {
        pre {
            y > 0.0 as UFix128: "Division by zero"
        }
        return x / y
    }

    access(all) view fun toUFix128(_ value: UFix64): UFix128 {
        return UFix128(value)
    }

    access(all) view fun toUFix64(_ value: UFix128, rounding: RoundingMode): UFix64 {
        let truncated: UFix64 = UFix64(value)
        let truncatedAs128: UFix128 = UFix128(truncated)
        let remainder: UFix128 = value - truncatedAs128

        if remainder == 0.0 as UFix128 {
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
        }
        return truncated
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
        let scaled: UFix64 = base * 100_000_000.0
        let scaledInt: UInt64 = UInt64(scaled)
        return scaledInt % UInt64(2) == UInt64(1) ? self.roundUp(base) : base
    }

    init() {
        self.one = 1.0 as UFix128
        self.zero = 0.0 as UFix128
        self.ufix64Step = 0.00000001 as UFix128
        self.ufix64HalfStep = self.ufix64Step / 2.0 as UFix128
        self.decimals = 24
        self.ufix64Decimals = 8
    }
}
