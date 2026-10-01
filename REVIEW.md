# Review

Scope: `src/BuyOnlyVoteHook.sol`, `src/SurfToken.sol`, `src/HookFlags.sol`, `src/HookMiner.sol`,
`script/Deploy.s.sol`, the tests, and the vendored libraries' integration. Checklists applied: the
`uniswap-v4-security` pre-deployment list and the ethskills `security` pre-deploy list pinned at
`.imd/reads/skills/eth-security/REFERENCE.md`.

## What was re-run

| Check | Result |
| --- | --- |
| `forge build` (solc 0.8.26, cancun, 200 runs, no via-IR) | compiles; `PoolManager` 19,713 bytes, hook 6,074 bytes, token 1,740 bytes; lint warnings only (sign-guarded int128 casts, timestamp modulo for day arithmetic) |
| `forge test` | 52 passed, 0 failed (41 hook incl. 4 fuzz, 6 token incl. 1 fuzz, 5 script) |
| `forge fmt --check` | clean |
| `EXPECTED_CHAIN_ID=0 forge script script/Deploy.s.sol:Deploy --offline` | runs; hook lands on an address ending in `0x20C0` |
| `EXPECTED_CHAIN_ID=11155111 ... --offline` | reverts `ChainIdMismatch(11155111, 31337)` as intended |
| Pinned floor suite (`Hook.protected.t.sol`, `Token.protected.t.sol`) run from `test/scratch` with `IMD_HOOK_CREATION_CODE` = hook creation code + pool manager argument, `IMD_HOOK_FLAGS=8384`, `IMD_TOKEN_CREATION_CODE`, `IMD_TOKEN_DECIMALS=18` | 9 passed: permissions match the address, no DELEGATECALL/CALLCODE/SELFDESTRUCT in either runtime, callbacks refuse non-manager callers, token mints the whole supply to the deployer, no admin selector mints, transfer is exact |

Slither and Mythril are not available on this box and were not run.

## Findings

| # | Severity | Finding | Disposition |
| --- | --- | --- | --- |
| 1 | Medium (design) | A liquidity provider can place SURF-only liquidity below the price and withdraw the ETH that buys leave there, which is an economic sell outside the window and the cap. | Documented in README "Assumptions and known limitations". Not blocked: the launch factory seeds the pool in a flow this repository cannot see, and a `beforeAddLiquidity` gate risked refusing the launch's own seeding. Follow-up offered: restrict additions to the launch transaction. |
| 2 | Low | Vote weight is staked SURF; holders who do not stake have no voice, and staking requires an approval to the hook. | Accepted. A balance-at-vote-time scheme with a plain ERC-20 lets one balance vote from many wallets; staking with an unstake lock for the voted day is the Sybil-resistant option without an ERC20Votes token, which the launch's token rules exclude. Tested (`test_aStakeCannotVoteTwiceByMovingBetweenAccounts`). |
| 3 | Low | Exact-output sells are only checked in `afterSwap`, after the pool has computed the swap; the whole transaction reverts, so no state leaks, but the user pays the gas of the computation. | Accepted; `beforeSwap` pre-checks exact-input sells so the common path fails early. Tested both ways. |
| 4 | Info | `quorum` is read from `totalSupply()` of `currency1` at initialization. A token whose supply changes would not move the quorum. | `SurfToken` is fixed supply; documented. |
| 5 | Info | Day arithmetic uses `block.timestamp`. | Not randomness; a validator can shift a boundary by seconds. Fuzzed (`testFuzz_dayAndWindowArithmetic`). |
| 6 | Info | The hook is bound to the first pool initialized through it and refuses the rest, so a stray initialization with the hook address before the launch would brick the launch. | This is why `beforeInitialize` exists for IMD launches: the factory deploys the hook and initializes in one transaction, so the window for a stray initialization is the deployment itself. Tested (`test_initializeRefusesASecondPool`). |

No reentrancy path: the hook makes external calls only in `stake`/`unstake` (SafeERC20 on SURF, after
state updates) and `beforeInitialize` (`totalSupply()` view). No ETH is ever held or sent by the
hook. No return deltas are declared, so the NoOp attack surface does not exist. No `delegatecall`,
no `selfdestruct`, no owner, no upgrade path, no hardcoded addresses except the canonical CREATE2
proxy in the rehearsal script.

## Security checklist (uniswap-v4-security)

| # | Item | Status |
| --- | --- | --- |
| 1 | All callbacks verify `msg.sender == poolManager` | yes, `onlyPoolManager` on the three declared callbacks; undeclared ones revert unconditionally |
| 2 | Router allowlisting | not needed; the hook never relies on the end user's identity inside a swap |
| 3 | No unbounded loops | none in the hook; the salt miner is bounded and off the hot path |
| 4 | Reentrancy guards | CEI in `stake`/`unstake`; no ETH handling |
| 5 | Delta accounting sums to zero | the hook returns zero deltas and touches no balances |
| 6 | Fee-on-transfer tokens | SURF is a plain ERC-20; the pool is ETH/SURF only |
| 7 | No hardcoded addresses | none in `src/` |
| 8 | Slippage respected | the hook does not alter amounts |
| 9 | No sensitive data on-chain | none |
| 10 | Upgrade mechanisms | none |
| 11 | `beforeSwapReturnDelta` justified | not enabled |
| 12 | Fuzz testing | 5 fuzz tests, 256 runs each |
| 13 | Invariant testing | not required (no delta returns); stake/unstake conservation is fuzzed |

## Open items for the operator

- Independent adversarial review before release, as the launch policy requires.
- Decide whether finding 1 (LP-side exit) is acceptable for this launch or wants the follow-up gate.
- Source verification on the explorer after deployment.
