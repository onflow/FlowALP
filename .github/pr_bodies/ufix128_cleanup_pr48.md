### UFix128 cleanup and math utilities consolidation

#### What changed
- Removed `TidalMath.mul` and replaced with the built-in `*` across the codebase. Kept `TidalMath.div` for its division-by-zero precondition.
- Standardized on `TidalMath.one`/`TidalMath.zero`; replaced ad‑hoc `TidalMath.toUFix128(1.0)` and `0.0 as UFix128`. Tests updated accordingly.
- Simplified `perSecondInterestRate`: compute `yearlyRate / 31_536_000.0 as UFix128` and add `TidalMath.one`.
- Kept `UFix128` for `compoundInterestIndex` to match indices/rates and avoid type churn; can optimize exponentiation later if needed.
- Renamed misleading locals (e.g., `uintPrice`, `uintBorrowFactor`) to descriptive names (`price`, `borrowFactor`, `collateralFactor`, `depositPrice`, `withdrawBorrowFactor`, etc.).
- Removed commented‑out code and minor formatting noise.
- Tightened zero comparisons where types are unsigned: use `== TidalMath.zero` instead of `<= 0.0 as UFix128`.

#### Why
- The `mul` wrapper was a no‑op; built‑ins are clearer and idiomatic. Keeping `div` preserves safety semantics.
- Using constants improves readability and consistency, and reduces mixed literal typing.
- Decoupling protocol math from DeFiActions and standardizing on `UFix128` simplifies interfaces and testing.

#### Responses to review points
- mul convenience: removed; `*` works for `UFix128`.
- `one/zero` constants: both used; `zero` is used in liquidation math and clamping.
- `liquidationBonus` as `0.05`: correct for fractional `UFix128`.
- Indices/rates: use `TidalMath.one` to represent no‑interest; swapped remaining literals to constants.
- Unsigned checks: changed `<= 0.0` to `== TidalMath.zero` where appropriate.
- Precondition optional‑chaining: explicit nil/type checks retained for clearer error messages.
- Commented blocks: removed.
- Variable names: moved away from `uint*` labels now that values are `UFix128`.
- `perSecondInterestRate`: removed redundant multiply by one.
- `compoundInterestIndex`: kept on `UFix128`; can revisit for faster exponentiation later.
- `decreaseDebitBalance` saturating behavior: still clamp‑to‑zero to avoid negative accounting; can add an assert with small epsilon in a follow‑up if we want stricter guarantees.

#### Tests
- All Cadence tests pass locally via `./run_tests.sh` on `feature/ufix128-upgrade`.


