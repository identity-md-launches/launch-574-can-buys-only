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
- **The cap counts net sells.** A buy made while the window is open first cancels SURF already counted
  as sold today (`sold[day]` goes down by the amount bought, floored at zero) and only the remainder
  counts as a buy for tomorrow's cap. So a seller who buys back frees the cap for everybody else, and
  a sell-and-rebuy round trip neither holds the cap hostage nor inflates tomorrow's cap. Before the
  window opens `sold[day]` is always zero, so buys outside the window count in full.
- **Liquidity removals that turn SURF into ETH are sells.** Adding liquidity is always allowed. The
  hook records, per position, the liquidity and the SURF principal deposited. When liquidity is
  removed, the SURF returned is compared with the proportional share of what was deposited; a
  shortfall (SURF that buys converted into ETH inside the position) is treated exactly like a swap
  sell: it must happen in an open window and is charged against the day's cap (`SellsClosed` /
  `SellCapExceeded` from `afterRemoveLiquidity`, event `LiquiditySold`). A position that returns at
  least what it deposited, give or take the pool's rounding (`LP_ROUNDING_TOLERANCE`, 10^6 wei =
  10^-12 SURF), can be removed at any time. Fee collection (`liquidityDelta == 0`) is never charged.
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
| `beforeInitialize` | yes | Binds the hook to its single pool, records `genesis` and `quorum`. Refuses a second pool (`AlreadyInitialized`), any pool whose `currency0` is not native ETH (`Currency0MustBeNative`) and any pool whose LP fee is not zero (`FeeMustBeZero`). |
| `afterAddLiquidity` | yes | Records the position's liquidity and the SURF principal it deposited. Never refuses. Returns a zero delta. |
| `afterRemoveLiquidity` | yes | Compares the SURF returned with the position's proportional deposit; charges a shortfall as a sell (window and cap). Returns a zero delta. |
| `beforeSwap` | yes | Rejects sells outside an open window; rejects exact-input sells over the remaining cap. Returns a zero delta and no fee override. |
| `afterSwap` | yes | Records buys (netting them against today's sells first); records sells and enforces the cap on the SURF actually paid. |
| everything else | no | Not declared in the address bits; the implementations revert with `HookNotImplemented` and the pool manager never calls them. |

All five callbacks accept calls only from the pool manager (`NotPoolManager` otherwise). The hook
returns zero deltas, charges no fee and moves no funds inside a swap or a liquidity change.

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
    "afterAddLiquidity": true,
    "afterRemoveLiquidity": true,
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
address must carry exactly
`BEFORE_INITIALIZE | AFTER_ADD_LIQUIDITY | AFTER_REMOVE_LIQUIDITY | BEFORE_SWAP | AFTER_SWAP` =
`0x25C0` (decimal 9664); `src/HookMiner.sol` finds a CREATE2 salt for that.

## Fees

The brief says "no fees" and names `surfsurf.eth` as the fee recipient. The hook charges nothing:
no swap fee, no hook fee, no return deltas, so there is nothing to send to `surfsurf.eth` and the
hook holds no address for it. The pool's own LP fee (`PoolKey.fee`) must be zero as well: a static
fee is fixed in the pool key at initialization and the hook overrides nothing, so `beforeInitialize`
refuses any key whose `fee` is not `0` (`FeeMustBeZero`), including the dynamic-fee flag. Every test
in this repository and the deploy script use `fee = 0`; liquidity providers earn no fees.

## The token

`SurfToken` is a plain OpenZeppelin ERC-20: name "Surf", symbol `SURF`, 18 decimals, exactly
1,000,000,000 tokens (10^27 minor units) minted to `msg.sender` in the constructor, no constructor
arguments, and no mint, burn, owner, pause, blocklist, fee or upgrade functions. The brief asked for
nothing of the token beyond trading rules, and all of those live in the hook. The token does not
restrict transfers: "buys only" is a rule of the hooked pool, not of the token.

## Assumptions and known limitations

- **Pair.** The pool is native ETH / SURF, with ETH as `currency0` and a zero LP fee. The hook refuses
  any other pool at initialization; a WETH or stablecoin pair would need a different hook.
- **Clock.** Days use `block.timestamp`. Validators can skew a block by seconds, not hours, so a
  boundary can only move by that much.
- **Quorum and shares are constants.** 1% of supply for quorum, 50% of yesterday's buys for the cap,
  23 h voting + 1 h window. Nobody can change them; a different setting is a new deployment.
- **Vote weight is staked SURF, not held SURF.** Holders who do not stake do not vote. This is the
  only Sybil-resistant choice with a plain ERC-20 and no snapshot machinery. Whoever holds the
  undistributed supply (the launch treasury, unlocked allocations) can decide every vote by staking
  it, and if nobody stakes 10,000,000 SURF on a day the window never opens. Both are the rule as
  briefed, not something the contracts control.
- **Liquidity providers are bound by the same rule as swappers.** This includes the launch seed:
  once buys have converted part of a position's SURF into ETH, that ETH can only be withdrawn in an
  open window and within the cap, like any other sell. An LP who adds SURF-only liquidity below the
  price and wants the ETH out must wait for a window with enough cap left; the position can always
  be removed once the price has come back so that it returns its SURF. Positions are tracked under
  the pool manager's own key (`owner, tickLower, tickUpper, salt`, where the owner is the router or
  position manager that called `modifyLiquidity`), so transferring a position NFT does not reset the
  accounting. Proportional attribution on partial removals and the rounding tolerance are the
  approximations involved; the tolerance is 10^-12 SURF per removal.
- **Residual window griefing.** A holder can still sell the whole cap at 23:00 and buy it back at
  23:59, locking others out for most of the hour. Unlike before, the cap is restored when they buy
  back, the round trip does not count as a buy, and they carry the price exposure of every buy that
  happens meanwhile; a per-seller allocation is not possible because the hook only ever sees the
  router, not the end user.
- **The cap counts tokens, not value.** Half of yesterday's bought SURF may be sold regardless of
  price moves since.
- **Anyone can buy to raise tomorrow's cap**, including a seller planning ahead; that is the rule as
  briefed. Buying through one's own liquidity counts like any other buy, but the ETH that lands in
  the position can only leave as a sell, so the cap it created is consumed by recovering it.
- **The rule binds the hooked pool only.** SURF transfers freely, so a second, hookless ETH/SURF pool
  or any other venue can trade it without these rules. The rule bites as long as the hooked pool
  holds the liquidity that matters; the launch token's rules forbid a transfer restriction.
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
| `bought(day)`, `sold(day)`, `sellCap(day)`, `sellRemaining(day)` | Volume and cap state (`sold` is net of in-window rebuys). |
| `staked(account)`, `lastVoteDay(account)` | Per-account state. |
| `positions(key)`, `positionKey(owner, tickLower, tickUpper, salt)` | Liquidity accounting: mirrored liquidity and recorded SURF deposit per position. |
| `token()`, `poolId()`, `genesis()`, `quorum()`, `poolManager()` | Binding. |
| `getHookPermissions()` | The declared callbacks. |
| `DAY`, `VOTING_PERIOD`, `SELL_WINDOW`, `SELL_SHARE_BPS`, `QUORUM_BPS`, `LP_ROUNDING_TOLERANCE` | Constants. |

Events: `PoolBound`, `Bought`, `Sold`, `LiquiditySold`, `Staked`, `Unstaked`, `Voted`.

Errors: `NotPoolManager`, `HookNotImplemented`, `AlreadyInitialized`, `NotInitialized`,
`Currency0MustBeNative`, `FeeMustBeZero`, `SellsClosed`, `SellCapExceeded(requested, remaining)`,
`VotingClosed`, `AlreadyVoted`, `NothingStaked`, `StakeLockedByVote`, `ZeroAmount`,
`InsufficientStake`.

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
| Hook address bits | `0x25C0` (`beforeInitialize`, `afterAddLiquidity`, `afterRemoveLiquidity`, `beforeSwap`, `afterSwap`); mine the CREATE2 salt with `HookMiner.find(create2Deployer, 0x25C0, creationCode)`. |
| Pool key | `currency0 = address(0)` (native ETH), `currency1 = SurfToken`, `fee = 0` (the hook refuses anything else), `hooks = BuyOnlyVoteHook`; `tickSpacing` is the deployer's choice (tests and the script use 60). |
| Initial price | the deployer's choice; the script defaults to `2^96` (1 SURF per ETH). |
| Target chain | Sepolia (11155111) unless the job says otherwise; `script/Deploy.s.sol` accepts 31337 and 11155111 only. |

`script/Deploy.s.sol:Deploy` is a rehearsal of those steps: it deploys the token, mines and deploys
the hook through the public CREATE2 proxy, and **initializes the pool in the same broadcast**, so
there is no gap in which a stray pool could bind the hook first (the hook binds to the first pool
initialized through it). `run()` reads `EXPECTED_CHAIN_ID` (0 or unset accepts the connected chain),
`POOL_MANAGER` (required on Sepolia, optional locally where a fresh pool manager is deployed),
`SQRT_PRICE_X96` and `TICK_SPACING` (defaults above) and `SALT_START` (default 0), and hands them to
`deploy(Config)`, which the tests call directly. The operator-only command, with the deployer's own
key management outside this repository:

```sh
EXPECTED_CHAIN_ID=11155111 POOL_MANAGER=<chain pool manager> \
  forge script script/Deploy.s.sol:Deploy --rpc-url <rpc> --broadcast
```

Because the proxy is public and the salt search is deterministic, someone who sees the creation code
could deploy the hook at the predicted address first and bind it to a stray pool. The script checks
that the predicted address has no code and reverts with `HookAddressTaken` otherwise; the operator
then reruns with a higher `SALT_START`. The deploy and initialize transactions are consecutive in the
broadcast; if the initialize fails with `AlreadyInitialized`, the hook was front-run between the two
and must be redeployed the same way.

After deployment the operator should: verify both sources on the explorer
(`forge verify-contract`), confirm the hook address ends in bits `0x25C0`, confirm the pool key on
chain has `fee = 0`, and tell holders the schedule: voting from 0:00 to 23:00 of each pool day,
selling from 23:00 to 24:00 if the vote passed, with the pool day starting at the initialization
timestamp (`genesis()`), and that liquidity withdrawals which return less SURF than deposited follow
the same window and cap. No ongoing operation is required: no keeper, no parameter updates, no
funds to collect.

Tests passing are not a security audit. Review by an independent contributor is expected before
release; `REVIEW.md` records the self-review and what was re-run.
