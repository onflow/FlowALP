/// TidalProtocolUtils
///
/// This contract contains utility methods used by TidalProtocol
///
access(all) contract TidalProtocolUtils {

    /**************
     * MATH UTILS *
     **************/

    /// Raises the base to the power of the exponent
    access(all) view fun pow(_ base: UInt256, to: UInt8): UInt256 {
        if to == 0 {
            return 1
        }

        var r = base
        var exp: UInt8 = 1
        while exp < to {
            r = r * base
            exp = exp + 1
        }

        return r
    }

    /// Raises the fixed point base to the power of the exponent
    access(all) view fun ufixPow(_ base: UFix64, to: UInt8): UFix64 {
        if to == 0 {
            return 1.0
        }

        var r = base
        var exp: UInt8 = 1
        while exp < to {
            r = r * base
            exp = exp + 1
        }

        return r
    }

    /// Converts a UFix64 to a UInt256
    access(all) view fun ufix64ToUInt256(_ value: UFix64, decimals: UInt8): UInt256 {
        // Default to 10e8 scale, catching instances where decimals are less than default and scale appropriately
        let ufixScaleExp: UInt8 = decimals < 8 ? decimals : 8
        var ufixScale = self.ufixPow(10.0, to: ufixScaleExp)

        // Separate the fractional and integer parts of the UFix64
        let integer = UInt256(value)
        var fractional = (value % 1.0) * ufixScale

        // Calculate the multiplier for integer and fractional parts
        var integerMultiplier: UInt256 = self.pow(10, to: decimals)
        let fractionalMultiplierExp: UInt8 = decimals < 8 ? 0 : decimals - 8
        var fractionalMultiplier: UInt256 = self.pow(10, to: fractionalMultiplierExp)

        // Scale and sum the parts
        return integer * integerMultiplier + UInt256(fractional) * fractionalMultiplier
    }

    /// Converts a UInt256 to a UFix64
    access(all) view fun uint256ToUFix64(_ value: UInt256, decimals: UInt8): UFix64 {
        // Calculate scale factors for the integer and fractional parts
        let absoluteScaleFactor = self.pow(10, to: decimals)

        // Separate the integer and fractional parts of the value
        let scaledValue = value / absoluteScaleFactor
        var fractional = value % absoluteScaleFactor
        // Scale the fractional part
        let scaledFractional = self.uint256FractionalToScaledUFix64Decimals(fractional, decimals: decimals)

        // Ensure the parts do not exceed the max UFix64 value before conversion
        assert(
            scaledValue <= UInt256(UFix64.max),
            message: "Scaled integer value \(value.toString()) exceeds max UFix64 value"
        )
        /// Check for the max value that can be converted to a UFix64 without overflowing
        assert(
            scaledValue == UInt256(UFix64.max) ? scaledFractional < 0.09551616 : true,
            message: "Scaled integer value \(value.toString()) exceeds max UFix64 value"
        )

        return UFix64(scaledValue) + scaledFractional
    }

    /// Converts a UInt256 fractional value with the given decimal places to a scaled UFix64. Note that UFix64 has
    /// decimal precision of 8 places so converted values may lose precision and be rounded down.
    access(all) view fun uint256FractionalToScaledUFix64Decimals(_ value: UInt256, decimals: UInt8): UFix64 {
        pre {
            self.getNumberOfDigits(value) <= decimals: "Fractional digits exceed the defined decimal places"
        }
        post {
            result < 1.0: "Resulting scaled fractional exceeds 1.0"
        }

        var fractional = value
        // Truncate fractional to the first 8 decimal places which is the max precision for UFix64
        if decimals >= 8 {
            fractional = fractional / self.pow(10, to: decimals - 8)
        }
        // Return early if the truncated fractional part is now 0
        if fractional == 0 {
            return 0.0
        }

        // Scale the fractional part
        let fractionalMultiplier = self.ufixPow(0.1, to: decimals < 8 ? decimals : 8)
        return UFix64(fractional) * fractionalMultiplier
    }

    /// Returns the number of digits in the given UInt256
    access(all) view fun getNumberOfDigits(_ value: UInt256): UInt8 {
        var tmp = value
        var digits: UInt8 = 0
        while tmp > 0 {
            tmp = tmp / 10
            digits = digits + 1
        }
        return digits
    }
}
