/// TidalProtocolUtils
///
/// This contract contains utility methods used by TidalProtocol.
///
access(all) contract TidalProtocolUtils {

    /// Constant for 10^18
    access(all) let e18: UInt256
    /// Constant for 10^8
    access(all) let e8: UInt256
    /// Constant for the number of decimal places/precision of the fixed point numbers
    access(all) let decimals: UInt8
    /// Constant for the number of seconds in a year
    access(all) let secondsInYearE18: UInt256

    /**************
     * MATH UTILS *
     **************/

    /// Raises the base to the power of the exponent
    ///
    /// @param base: The base to raise to the power of the exponent
    /// @param to: The exponent to raise the base to
    /// @return: The result of the base raised to the power of the exponent
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
    ///
    /// @param base: The base to raise to the power of the exponent
    /// @param to: The exponent to raise the base to
    /// @return: The result of the base raised to the power of the exponent
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
    ///
    /// @param value: The UFix64 value to convert
    /// @param decimals: The number of decimal places to convert to
    /// @return: The UInt256 value
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
    ///
    /// @param value: The UInt256 value to convert
    /// @param decimals: The number of decimal places the value has
    /// @return: The UFix64 value
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
    ///
    /// @param value: The UInt256 value to convert
    /// @param decimals: The number of decimal places to convert to
    /// @return: The UFix64 value
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
    ///
    /// @param value: The UInt256 value to get the number of digits for
    /// @return: The number of digits in the given UInt256
    access(all) view fun getNumberOfDigits(_ value: UInt256): UInt8 {
        var tmp = value
        var digits: UInt8 = 0
        while tmp > 0 {
            tmp = tmp / 10
            digits = digits + 1
        }
        return digits
    }

    /************************
     * BALANCE CONVERSIONS *
     ************************/

    /// Converts a UFix64 balance to UInt256 with 18 decimal precision for internal calculations
    ///
    /// @param value: The UFix64 value to convert
    /// @return: The 18-decimal UInt256 value
    access(all) view fun toUInt256Balance(_ value: UFix64): UInt256 {
        return self.ufix64ToUInt256(value, decimals: 18)
    }

    /// Converts a UInt256 balance with 18 decimal precision to UFix64 for external interfaces
    ///
    /// @param value: The UInt256 value to convert
    /// @return: The 18-decimal UFix64 value
    access(all) view fun toUFix64Balance(_ value: UInt256): UFix64 {
        return self.uint256ToUFix64(value, decimals: 18)
    }

    /***********************
     * FIXED POINT MATH   *
     ***********************/

    /// Multiplies two 18-decimal fixed-point numbers
    /// Both operands and result are scaled by 10^18
    ///
    /// Formula: (x * y) / WAD
    /// Example: 1.5 * 2.0 = (1.5e18 * 2.0e18) / 1e18 = 3.0e18
    ///
    /// @param x: First operand (scaled by 10^18)
    /// @param y: Second operand (scaled by 10^18)
    /// @return: Product scaled by 10^18
    access(all) view fun mul(_ x: UInt256, _ y: UInt256): UInt256 {
        return (x * y) / self.e18
    }

    /// Divides two 18-decimal fixed-point numbers
    /// Both operands and result are scaled by 10^18
    ///
    /// Formula: (x * WAD) / y
    /// Example: 6.0 / 2.0 = (6.0e18 * 1e18) / 2.0e18 = 3.0e18
    ///
    /// @param x: Dividend (scaled by 10^18)
    /// @param y: Divisor (scaled by 10^18)
    /// @return: Quotient scaled by 10^18
    access(all) view fun div(_ x: UInt256, _ y: UInt256): UInt256 {
        pre {
            y > 0: "Division by zero"
        }
        return (x * self.e18) / y
    }

    /// Multiplies a 18-decimal fixed-point number by a regular UInt256 scalar
    /// Result maintains 18-decimal precision
    ///
    /// Formula: x * y (no scaling adjustment needed)
    /// Example: 1.5e18 * 3 = 4.5e18
    ///
    /// @param x: Fixed-point number (scaled by 10^18)
    /// @param y: Regular integer scalar (not scaled)
    /// @return: Product scaled by 10^18
    access(all) view fun mulScalar(_ x: UInt256, _ y: UInt256): UInt256 {
        return x * y
    }

    /// Divides a 18-decimal fixed-point number by a regular UInt256 scalar
    /// Result maintains 18-decimal precision
    ///
    /// Formula: x / y (no scaling adjustment needed)
    /// Example: 4.5e18 / 3 = 1.5e18
    ///
    /// @param x: Fixed-point number (scaled by 10^18)
    /// @param y: Regular integer scalar (not scaled)
    /// @return: Quotient scaled by 10^18
    access(all) view fun divScalar(_ x: UInt256, _ y: UInt256): UInt256 {
        pre {
            y > 0: "Division by zero"
        }
        return x / y
    }

    init() {
        self.e18 = 1_000_000_000_000_000_000
        self.e8 = 100_000_000
        self.decimals = 18
        self.secondsInYearE18 = 31_536_000 * self.e18
    }
}
