# Review

Scope: `src/BuyOnlyVoteHook.sol`, `src/SurfToken.sol`, `src/HookFlags.sol`, `src/HookMiner.sol`,
`script/Deploy.s.sol`, the tests, and the vendored libraries' integration. Checklists applied: the
`uniswap-v4-security` pre-deployment list and the ethskills `security` pre-deploy list pinned at
`.imd/reads/skills/eth-security/REFERENCE.md`.

## Revision round (independent review findings)

The accepted first round was reopened with six findings from an independent reviewer. Each was
reproduced on the accepted tree before anything changed (the reviewer's proofs were not in the tree,
so the scenarios were rebuilt from the reports in `test/scratch`, matching their numbers: an LP
withdrew 150669010303811978 wei ETH for 149319140229944084 wei SURF on day 2 with `sold(2) == 0`; the
sell-and-rebuy round trip cost 1 wei and left `sellRemaining == 0`; a fee-3000 pool paid
2999999999999999 wei of LP fees on a 1 ETH buy; a stray pool bound a freshly deployed hook).

| Finding | Severity | Disposition |
| --- | --- | --- |
| Liquidity positions are an ungated sell path | high | **Fixed.** `afterAddLiquidity` and `afterRemoveLiquidity` are enabled (address bits now `0x25C0`). Additions are recorded per position (liquidity and SURF principal); a removal that returns less SURF than the proportional deposit, beyond a 10^6 wei rounding tolerance, is charged as a sell: window required, cap consumed, `LiquiditySold` emitted. Chosen over a `beforeAddLiquidity` gate restricted to the launch block/sender because this repository cannot confirm how and when the factory seeds, and that gate would brick the launch if the guess were wrong, while also forbidding all later LPs. The cap-inflation variant (park, buy through own range, recover the ETH) is closed by the same rule: recovering the ETH consumes the cap. |
| Zero-net sell-and-rebuy consumes the day's cap for everyone | medium | **Fixed.** A buy while the window is open first cancels SURF counted in `sold[day]`; only the remainder counts in `bought[day]`. The cap therefore tracks net sells, and repeated round trips neither lock others out nor raise tomorrow's cap (a side effect netting alone would have created). Per-seller allocation was rejected: the hook sees the router, not the user. Residual: selling at 23:00 and buying back at 23:59 still locks others out for the hour at the cost of the price exposure meanwhile; documented. |
| `beforeInitialize` accepts a fee-bearing pool | low | **Fixed.** `FeeMustBeZero` unless `key.fee == 0` (the dynamic-fee flag is refused too). All tests and the script use fee 0; README corrected. |
| Two-step deployment lets anyone bind a stray pool | low | **Fixed in the script.** `Deploy.deploy` initializes the pool in the same broadcast as the hook deployment, refuses a predicted address that already has code (`HookAddressTaken`) and takes `SALT_START` to move past it. No hook-level sender guard was added, for the reason the finding gives (the public proxy is the deployer). |
| Trust gap: SURF sells freely outside the hooked pool | info | Documented (README "The rule binds the hooked pool only"); not a code change, by the launch token rules. |
| Trust assumptions: supply holders decide votes, quorum needs 10,000,000 SURF staked, majority AND quorum | info | Documented (README "Vote weight is staked SURF"). The AND reading is kept and stated. |

## What was re-run

| Check | Result |
| --- | --- |
| `forge build` (solc 0.8.26, cancun, 200 runs, no via-IR) | compiles; hook 7,326 bytes, token 1,740 bytes; lint warnings only (sign-guarded int casts, timestamp modulo for day arithmetic) |
| `forge test` | 72 passed, 0 failed (59 hook incl. 6 fuzz, 6 token incl. 1 fuzz, 7 script) |
| `forge fmt --check` | clean |
| `EXPECTED_CHAIN_ID=0 forge script script/Deploy.s.sol:Deploy --offline` | runs; hook lands on an address ending in `0x25C0`; the pool is initialized in the same run |
| `EXPECTED_CHAIN_ID=11155111 ... --offline` | reverts `ChainIdMismatch(11155111, 31337)` as intended |
| Pinned floor suite (`Hook.protected.t.sol`, `Token.protected.t.sol`) run from `test/scratch` with `IMD_HOOK_CREATION_CODE` = hook creation code + pool manager argument, `IMD_HOOK_FLAGS=9664`, `IMD_TOKEN_CREATION_CODE`, `IMD_TOKEN_DECIMALS=18` | 9 passed: permissions match the address, no DELEGATECALL/CALLCODE/SELFDESTRUCT in either runtime, all five declared callbacks refuse non-manager callers, token mints the whole supply to the deployer, no admin selector mints, transfer is exact |
| Finding reproductions (`test/scratch/Repro.t.sol`) | the LP removal now reverts `SellsClosed` from `afterRemoveLiquidity`; the round trip leaves `sellRemaining` at the full cap and the next seller succeeds; the fee-3000 initialize reverts `FeeMustBeZero` |

Slither and Mythril are not available on this box and were not run.

## Findings (self-review, cumulative)

| # | Severity | Finding | Disposition |
| --- | --- | --- | --- |
| 1 | High (fixed) | A liquidity provider could place SURF-only liquidity below the price and withdraw the ETH that buys left there: an economic sell outside the window and the cap. | Fixed this round, see above. Tested: `test_lpPositionCannotSellSurfOutsideTheWindow`, `test_lpPositionSellIsChargedAgainstTheCapInsideTheWindow`, `test_lpPositionSellOverTheRemainingCapIsRefused`, `test_lpCannotInflateTheCapAndRecoverTheEthForFree`, `test_launchStyleSeedIsAcceptedOnAFreshManagerAndCanBeWithdrawnInAWindow`, `testFuzz_lpShortfallIsChargedExactly`; the non-sell paths in `test_unchangedLiquidityCanBeRemovedAtAnyTime`, `test_partialRemovalsOfAnUnchangedPositionAreNotSells`, `test_lpPositionThatGainedSurfIsNotCharged`, `test_feeCollectionOnAConvertedPositionIsNotCharged`, `testFuzz_removingAnUntouchedPositionIsNeverASell`. |
| 2 | Medium (fixed) | Sell-and-rebuy inside the window locked the cap for everyone else at a cost of 1 wei. | Fixed this round. Tested: `test_sellAndRebuyInsideTheWindowFreesTheCapForOthers`, `test_repeatedSellAndRebuyCyclesCannotRaiseTomorrowsCap`, `test_buyLargerThanTodaysSellsCountsOnlyTheExcess`. |
| 3 | Low (fixed) | A fee-bearing pool key was accepted, contradicting "no fees". | Fixed this round. Tested: `test_initializeRefusesAFeeBearingPool`, `test_zeroFeePoolAccruesNoLpFees`. |
| 4 | Low (fixed) | The rehearsal script left the hook unbound between deployment and the operator's initialize. | Fixed in the script. Tested: `test_deployLocallyWithAFreshPoolManagerAndInitializeThePool`, `test_noStrayPoolCanBindTheHookAfterTheScriptRan`, `test_refusesAPredictedHookAddressThatAlreadyHasCode`. |
| 5 | Low | The liquidity rule relies on proportional attribution for partial removals and a rounding tolerance of 10^6 wei per removal. | Accepted. The tolerance is 10^-12 SURF, far below any economic amount, and bounds the pool's per-operation rounding with a wide margin. An LP that wants to remove in thousands of dust steps could accumulate a few hundred wei of apparent shortfall; irrelevant at this scale. |
| 6 | Low | An LP whose position has converted to ETH cannot withdraw it until a window with spare cap, which may be never if quorum is never reached. | Accepted as the rule: the LP is in the same position as any SURF holder who wants ETH. Documented for the operator (the launch seed is bound too). |
| 7 | Low | Vote weight is staked SURF; holders who do not stake have no voice, and staking requires an approval to the hook. | Accepted. A balance-at-vote-time scheme with a plain ERC-20 lets one balance vote from many wallets; staking with an unstake lock for the voted day is the Sybil-resistant option without an ERC20Votes token, which the launch's token rules exclude. Tested (`test_aStakeCannotVoteTwiceByMovingBetweenAccounts`). |
| 8 | Low | Exact-output sells are only checked in `afterSwap`, after the pool has computed the swap; the whole transaction reverts, so no state leaks, but the user pays the gas of the computation. | Accepted; `beforeSwap` pre-checks exact-input sells so the common path fails early. Tested both ways. |
| 9 | Info | `quorum` is read from `totalSupply()` of `currency1` at initialization. A token whose supply changes would not move the quorum. | `SurfToken` is fixed supply; documented. |
| 10 | Info | Day arithmetic uses `block.timestamp`. | Not randomness; a validator can shift a boundary by seconds. Fuzzed (`testFuzz_dayAndWindowArithmetic`). |
| 11 | Info | The hook is bound to the first pool initialized through it and refuses the rest. | This is why `beforeInitialize` exists for IMD launches: the factory deploys the hook and initializes in one transaction; the script now does the same. Tested (`test_initializeRefusesASecondPool`, `test_noStrayPoolCanBindTheHookAfterTheScriptRan`). |

No reentrancy path: the hook makes external calls only in `stake`/`unstake` (SafeERC20 on SURF, after
state updates) and `beforeInitialize` (`totalSupply()` view). No ETH is ever held or sent by the
hook. No return deltas are declared (the liquidity callbacks return `ZERO_DELTA`), so the NoOp
attack surface does not exist. No `delegatecall`, no `selfdestruct`, no owner, no upgrade path, no
hardcoded addresses except the canonical CREATE2 proxy in the rehearsal script.

## Security checklist (uniswap-v4-security)

| # | Item | Status |
| --- | --- | --- |
| 1 | All callbacks verify `msg.sender == poolManager` | yes, `onlyPoolManager` on the five declared callbacks; undeclared ones revert unconditionally |
| 2 | Router allowlisting | not needed; the hook never relies on the end user's identity. Positions are keyed by the router, exactly as the pool manager keys them |
| 3 | No unbounded loops | none in the hook; the salt miner is bounded and off the hot path |
| 4 | Reentrancy guards | CEI in `stake`/`unstake`; no ETH handling |
| 5 | Delta accounting sums to zero | the hook returns zero deltas and touches no balances |
| 6 | Fee-on-transfer tokens | SURF is a plain ERC-20; the pool is ETH/SURF only |
| 7 | No hardcoded addresses | none in `src/` |
| 8 | Slippage respected | the hook does not alter amounts |
| 9 | No sensitive data on-chain | none |
| 10 | Upgrade mechanisms | none |
| 11 | `beforeSwapReturnDelta` justified | not enabled |
| 12 | Fuzz testing | 7 fuzz tests, 256 runs each |
| 13 | Invariant testing | not required (no delta returns); stake/unstake conservation and untouched-position removals are fuzzed |

## Open items for the operator

- Independent adversarial review before release, as the launch policy requires.
- Accept that the launch seed liquidity is bound by the window and cap once buys have converted it.
- Source verification on the explorer after deployment; confirm the on-chain pool key has `fee = 0`.
