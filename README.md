# Surf launch: buy-only pool with daily voted sell windows

A Uniswap v4 hook (`BuyOnlyVoteHook`) and a fixed-supply ERC-20 (`SurfToken`, "Surf" / `SURF`) for an
ETH/SURF pool in which the token can only be bought, unless the holders vote each day to open a
one-hour sell window, during which at most half of the previous day's buys can be sold back.

Nobody administers either contract: there is no owner, no fee, no pause and no parameter that can be
changed after deployment.

## The rules the hook enforces

Time is split into 24-hour days counted from the pool's initialization timestamp (`genesis`). Day `d`
starts at `genesis + d * 24h`. Within every day:

| Hours of the day | What is allowed |
| --- | --- |
| 0:00 to 23:00 | Buys. Stakers may vote on whether sells open today. |
| 23:00 to 24:00 | Buys. Sells, only if today's vote passed, and only up to the day's sell cap. |

- **Buys always pass.** A buy is a swap with `zeroForOne == true` (ETH in, SURF out). The SURF amount
  the swapper receives is added to `bought[day]` in `afterSwap`.
- **Sells are closed by default.** A sell (`zeroForOne == false`, SURF in, ETH out) reverts with
  `SellsClosed` unless the sell window is open: it is the last hour of the day *and* that day's vote
  passed.
- **Vote rule.** A day's vote passes when `yes > no` (strict majority of votes cast) **and**
  `yes + no >= quorum`, where `quorum` is 1% of the token's total supply (10,000,000 SURF), fixed at
  initialization. A tie, a losing majority, or a turnout under quorum keeps sells closed.
- **Sell cap.** During an open window the total SURF sold across all sellers is capped at 50% of the
  SURF bought on the previous day: `sellCap(day) = bought[day - 1] / 2`. Day 0 has a cap of zero.
  The cap is first come, first served. An exact-input sell over the remaining cap fails in
  `beforeSwap` (`SellCapExceeded(requested, remaining)`); every sell, including exact-output ones, is
  re-checked in `afterSwap` against the SURF actually paid, so the pool's own computation cannot
  exceed it.
- **Each day needs its own vote.** Tallies and caps are per day; nothing carries over.

### Voting weight: staked SURF

"People can vote" is implemented as token-weighted voting with staked tokens, so a balance cannot
vote twice by moving between wallets:

- `stake(amount)` deposits SURF into the hook (requires an ERC-20 approval to the hook).
- `vote(support)` commits the caller's whole current stake to yes or no for the current day. It is
  allowed only during hours 0 to 23, once per account per day, and only with a non-zero stake. Stake
  added after voting counts from the next day.
- `unstake(amount)` returns SURF. It is refused for the rest of any day in which the caller has voted
  (`StakeLockedByVote`), so the committed weight stays locked until the window has closed.

Staked SURF is held by the hook and can only ever be withdrawn by the account that staked it.

### When the hook acts

| Callback | Enabled | What it does |
| --- | --- | --- |
| `beforeInitialize` | yes | Binds the hook to its single pool, records `genesis` and `quorum`. Refuses a second pool (`AlreadyInitialized`) and any pool whose `currency0` is not native ETH (`Currency0MustBeNative`). |
| `beforeSwap` | yes | Rejects sells outside an open window; rejects exact-input sells over the remaining cap. Returns a zero delta and no fee override. |
| `afterSwap` | yes | Records buys; records sells and enforces the cap on the SURF actually paid. |
| everything else | no | Not declared in the address bits; the implementations revert with `HookNotImplemented` and the pool manager never calls them. |

All three callbacks accept calls only from the pool manager (`NotPoolManager` otherwise). The hook
returns no deltas, charges no fee and moves no funds inside a swap.

### Hook configuration record (the Wizard's canonical shape)

```json
{
  "hook": "BaseHook",
  "name": "BuyOnlyVoteHook",
  "pausable": false,
  "currencySettler": false,
  "safeCast": false,
  "transientStorage": false,
  "shares": { "options": false },
  "permissions": {
    "beforeInitialize": true,
    "afterInitialize": false,
    "beforeAddLiquidity": false,
    "beforeRemoveLiquidity": false,
    "afterAddLiquidity": false,
    "afterRemoveLiquidity": false,
    "beforeSwap": true,
    "afterSwap": true,
    "beforeDonate": false,
    "afterDonate": false,
    "beforeSwapReturnDelta": false,
    "afterSwapReturnDelta": false,
    "afterAddLiquidityReturnDelta": false,
    "afterRemoveLiquidityReturnDelta": false
  },
  "inputs": {},
  "access": "none (immutable, no administrator)",
  "info": { "license": "MIT" }
}
```

The vendored v4-periphery carries no `BaseHook`, so the hook implements `IHooks` directly on v4-core
and validates its own address bits in the constructor with `Hooks.validateHookPermissions`. The
address must carry exactly `BEFORE_INITIALIZE | BEFORE_SWAP | AFTER_SWAP` = `0x20C0` (decimal 8384);
`src/HookMiner.sol` finds a CREATE2 salt for that.

## Fees

The brief says "no fees" and names `surfsurf.eth` as the fee recipient. The hook charges nothing:
no swap fee, no hook fee, no return deltas, so there is nothing to send to `surfsurf.eth` and the
hook holds no address for it. The pool's own LP fee (`PoolKey.fee`) is a launch parameter chosen by
the deployer and goes to liquidity providers as in any v4 pool; the hook does not override it.

## The token

`SurfToken` is a plain OpenZeppelin ERC-20: name "Surf", symbol `SURF`, 18 decimals, exactly
1,000,000,000 tokens (10^27 minor units) minted to `msg.sender` in the constructor, no constructor
arguments, and no mint, burn, owner, pause, blocklist, fee or upgrade functions. The brief asked for
nothing of the token beyond trading rules, and all of those live in the hook. The token does not
restrict transfers: "buys only" is a rule of the hooked pool, not of the token.

## Assumptions and known limitations

- **Pair.** The pool is native ETH / SURF, with ETH as `currency0`. The hook refuses any other pool
  at initialization; a WETH or stablecoin pair would need a different hook.
- **Clock.** Days use `block.timestamp`. Validators can skew a block by seconds, not hours, so a
  boundary can only move by that much.
- **Quorum and shares are constants.** 1% of supply for quorum, 50% of yesterday's buys for the cap,
  23 h voting + 1 h window. Nobody can change them; a different setting is a new deployment.
- **Vote weight is staked SURF, not held SURF.** Holders who do not stake do not vote. This is the
  only Sybil-resistant choice with a plain ERC-20 and no snapshot machinery.
- **Liquidity operations are not gated.** Adding or removing liquidity is allowed at any time. A
  liquidity provider who places SURF-only liquidity below the price and later withdraws the ETH that
  buys deposited there has, economically, sold SURF outside the window and the cap. The launch
  factory seeds the pool, and gating liquidity against an unknown factory flow risked breaking the
  launch itself, so this is documented rather than blocked. If the operator wants it blocked, a
  `beforeAddLiquidity` rule restricted to the launch transaction is the natural follow-up.
- **The cap counts tokens, not value.** Half of yesterday's bought SURF may be sold regardless of
  price moves since.
- **Anyone can buy to raise tomorrow's cap**, including a seller planning ahead; that is the rule as
  briefed.
- **No hook fee means no ETH ever sits in the hook**, so none of the "fee transfer fails on a fresh
  manager" failure modes apply. A buy on a freshly deployed manager seeded with SURF only is tested.

## Interface

`BuyOnlyVoteHook`

| Function | Purpose |
| --- | --- |
| `stake(uint256)` / `unstake(uint256)` | Deposit or withdraw voting weight. |
| `vote(bool support)` | Vote with the whole stake for the current day. |
| `currentDay()`, `secondsIntoDay()` | Position in the day schedule (revert before initialization). |
| `votingOpen()`, `sellWindowOpen()` | Whether voting or selling is possible right now. |
| `votePassed(day)`, `yesVotes(day)`, `noVotes(day)` | Vote state. |
| `bought(day)`, `sold(day)`, `sellCap(day)`, `sellRemaining(day)` | Volume and cap state. |
| `staked(account)`, `lastVoteDay(account)` | Per-account state. |
| `token()`, `poolId()`, `genesis()`, `quorum()`, `poolManager()` | Binding. |
| `getHookPermissions()` | The declared callbacks. |

Events: `PoolBound`, `Bought`, `Sold`, `Staked`, `Unstaked`, `Voted`.

Errors: `NotPoolManager`, `HookNotImplemented`, `AlreadyInitialized`, `NotInitialized`,
`Currency0MustBeNative`, `SellsClosed`, `SellCapExceeded(requested, remaining)`, `VotingClosed`,
`AlreadyVoted`, `NothingStaked`, `StakeLockedByVote`, `ZeroAmount`, `InsufficientStake`.

ABIs: `docs/abi/BuyOnlyVoteHook.json`, `docs/abi/SurfToken.json`.

## Build and test (offline)

Dependencies are vendored as ordinary files under `lib/` (v4-core 1.0.2 with its solmate, forge-std
1.9.3, OpenZeppelin Contracts 5.7.0). Nothing is fetched at build time.

```sh
forge build
forge test
forge fmt --check
EXPECTED_CHAIN_ID=0 forge script script/Deploy.s.sol:Deploy --offline
```

`foundry.toml` pins `solc = "0.8.26"`, `evm_version = "cancun"` (the pool manager uses transient
storage), optimizer at 200 runs, `ffi = false`, `fs_permissions = []`. Tests read no environment
variables and pass in any order.

## Deployment parameters and operator responsibilities

The IMD launch factory deploys the token and the hook and initializes the pool in one transaction.
This repository holds no keys and broadcasts nothing.

| Parameter | Value |
| --- | --- |
| Token constructor | none; supply minted to the deployer (the factory). |
| Hook constructor | `(IPoolManager poolManager)`; in the manifest this is `"$poolManager"`, filled by the deployer with the chain's pool manager. Never hardcode it. |
| Hook address bits | `0x20C0` (`beforeInitialize`, `beforeSwap`, `afterSwap`); mine the CREATE2 salt with `HookMiner.find(create2Deployer, 0x20C0, creationCode)`. |
| Pool key | `currency0 = address(0)` (native ETH), `currency1 = SurfToken`, `hooks = BuyOnlyVoteHook`; `fee` and `tickSpacing` are the deployer's choice (tests use 3000 / 60). |
| Target chain | Sepolia (11155111) unless the job says otherwise; `script/Deploy.s.sol` accepts 31337 and 11155111 only. |

`script/Deploy.s.sol:Deploy` is a rehearsal of those steps. `run()` reads `EXPECTED_CHAIN_ID`
(0 or unset accepts the connected chain) and `POOL_MANAGER` (required on Sepolia, optional locally
where a fresh pool manager is deployed), and hands them to `deploy(Config)`, which the tests call
directly. The operator-only command, with the deployer's own key management outside this repository:

```sh
EXPECTED_CHAIN_ID=11155111 POOL_MANAGER=<chain pool manager> \
  forge script script/Deploy.s.sol:Deploy --rpc-url <rpc> --broadcast
```

After deployment the operator should: verify both sources on the explorer
(`forge verify-contract`), confirm the hook address ends in bits `0x20C0`, initialize the pool with
ETH as `currency0`, and tell holders the schedule: voting from 0:00 to 23:00 of each pool day,
selling from 23:00 to 24:00 if the vote passed, with the pool day starting at the initialization
timestamp (`genesis()`). No ongoing operation is required: no keeper, no parameter updates, no
funds to collect.

Tests passing are not a security audit. Review by an independent contributor is expected before
release; `REVIEW.md` records the self-review and what was re-run.
