### Interest compounding performance update

#### What changed
- Added `TidalMath.powUFix128(base, expSeconds)` implementing exponentiation-by-squaring with integer-second exponent.
- Updated `TidalProtocol.compoundInterestIndex` to compute `oldIndex * powUFix128(perSecondRate, elapsedSeconds)` instead of looping per-second.

#### Why
- Keeps the math fully on `UFix128` for consistency (rates/indices/health) while eliminating the O(seconds) loop. The new approach is O(log seconds) and avoids type churn to `UInt128`.
- Floors elapsed time to whole seconds (as before), which matches Flow’s `UFix64` timestamp semantics.

#### Tests
- All Cadence tests pass locally with the new implementation via `./run_tests.sh`.


