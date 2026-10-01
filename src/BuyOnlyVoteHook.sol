// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";

/// @title BuyOnlyVoteHook
/// @notice A Uniswap v4 hook for an ETH/SURF pool where the token can only be bought, unless the
/// holders vote each day to open a one-hour sell window during which at most half of the previous
/// day's buys may be sold.
///
/// Time is split into days of 24 hours counted from pool initialization (`genesis`):
///  - hours 0..23 of a day: stakers may vote on whether sells open for that day;
///  - hour 23..24 of a day: the sell window, open only if the day's vote passed
///    (yes > no and yes + no >= quorum, quorum = 1% of the token supply);
///  - during an open window the total token amount sold is capped at 50% of the tokens bought on
///    the previous day, first come first served.
/// Buys (ETH in, SURF out) are always allowed and are recorded per day in `afterSwap`.
///
/// Voting weight is tokens staked in this contract: `stake` deposits SURF, `vote` commits the whole
/// stake to yes or no once per day, `unstake` returns SURF but is blocked for the rest of a day in
/// which the staker has voted, so a stake cannot vote twice in one day.
///
/// There is no owner, no fee, no parameter that can be changed, and the hook binds to exactly one
/// pool: the first pool initialized through it, whose currency0 must be native ETH.
contract BuyOnlyVoteHook is IHooks {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    // ----------------------------------------------------------------------------------------
    // Constants (nobody can change these after deployment)
    // ----------------------------------------------------------------------------------------

    /// @notice Length of one accounting day.
    uint256 public constant DAY = 24 hours;
    /// @notice Voting is open during the first 23 hours of each day.
    uint256 public constant VOTING_PERIOD = 23 hours;
    /// @notice The sell window is the last hour of each day.
    uint256 public constant SELL_WINDOW = 1 hours;
    /// @notice Share of the previous day's buys that may be sold during the window, in basis points.
    uint256 public constant SELL_SHARE_BPS = 5_000;
    /// @notice Quorum: total votes cast (yes + no) must reach this share of the token supply, in bps.
    uint256 public constant QUORUM_BPS = 100;
    uint256 internal constant BPS = 10_000;

    // ----------------------------------------------------------------------------------------
    // State
    // ----------------------------------------------------------------------------------------

    /// @notice The pool manager this hook serves.
    IPoolManager public immutable poolManager;

    /// @notice The launch token (currency1 of the bound pool). Zero until the pool is initialized.
    IERC20 public token;
    /// @notice The bound pool.
    PoolId public poolId;
    /// @notice Timestamp of pool initialization; day 0 starts here. Zero means not initialized.
    uint256 public genesis;
    /// @notice Votes (yes + no) required for a day's vote to count, fixed at initialization.
    uint256 public quorum;

    /// @notice Tokens bought (received by swappers) on each day.
    mapping(uint256 day => uint256 amount) public bought;
    /// @notice Tokens sold (paid by swappers) on each day.
    mapping(uint256 day => uint256 amount) public sold;
    /// @notice Yes votes per day, in staked token units.
    mapping(uint256 day => uint256 weight) public yesVotes;
    /// @notice No votes per day, in staked token units.
    mapping(uint256 day => uint256 weight) public noVotes;
    /// @notice Tokens each account has staked in this contract.
    mapping(address account => uint256 amount) public staked;
    /// @notice `day + 1` of the last day each account voted on (0 = never).
    mapping(address account => uint256 dayPlusOne) internal _lastVoteDayPlusOne;

    // ----------------------------------------------------------------------------------------
    // Events and errors
    // ----------------------------------------------------------------------------------------

    event PoolBound(PoolId indexed poolId, address indexed token, uint256 genesis, uint256 quorum);
    event Bought(uint256 indexed day, address indexed sender, uint256 tokenAmount);
    event Sold(uint256 indexed day, address indexed sender, uint256 tokenAmount);
    event Staked(address indexed account, uint256 amount);
    event Unstaked(address indexed account, uint256 amount);
    event Voted(uint256 indexed day, address indexed account, bool support, uint256 weight);

    error NotPoolManager();
    error HookNotImplemented();
    error AlreadyInitialized();
    error NotInitialized();
    error Currency0MustBeNative();
    error SellsClosed();
    error SellCapExceeded(uint256 requested, uint256 remaining);
    error VotingClosed();
    error AlreadyVoted();
    error NothingStaked();
    error StakeLockedByVote();
    error ZeroAmount();
    error InsufficientStake();

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
        Hooks.validateHookPermissions(this, getHookPermissions());
    }

    // ----------------------------------------------------------------------------------------
    // Permissions
    // ----------------------------------------------------------------------------------------

    /// @notice The callbacks this hook implements; must agree with the bits of its address.
    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ----------------------------------------------------------------------------------------
    // Hook callbacks
    // ----------------------------------------------------------------------------------------

    /// @inheritdoc IHooks
    /// @dev Binds the hook to its single pool. Only the pool manager may call it, only once, and
    /// currency0 must be native ETH so that currency1 is unambiguously the launch token.
    function beforeInitialize(address, PoolKey calldata key, uint160)
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        if (genesis != 0) revert AlreadyInitialized();
        if (!key.currency0.isAddressZero()) revert Currency0MustBeNative();

        IERC20 launchToken = IERC20(Currency.unwrap(key.currency1));
        uint256 quorum_ = (launchToken.totalSupply() * QUORUM_BPS) / BPS;
        PoolId id = key.toId();

        token = launchToken;
        poolId = id;
        genesis = block.timestamp;
        quorum = quorum_;

        emit PoolBound(id, address(launchToken), block.timestamp, quorum_);
        return IHooks.beforeInitialize.selector;
    }

    /// @inheritdoc IHooks
    /// @dev Buys (zeroForOne: ETH in, SURF out) always pass. Sells pass only while the day's sell
    /// window is open; exact-input sells are additionally checked against the remaining cap here so
    /// that an oversized sell fails before the pool does any work. `afterSwap` enforces the cap on the
    /// actual amount for every sell, including exact-output ones.
    function beforeSwap(address, PoolKey calldata, SwapParams calldata params, bytes calldata)
        external
        view
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (!params.zeroForOne) {
            if (!sellWindowOpen()) revert SellsClosed();
            if (params.amountSpecified < 0) {
                uint256 day = currentDay();
                uint256 remaining = sellRemaining(day);
                uint256 requested = uint256(-params.amountSpecified);
                if (requested > remaining) revert SellCapExceeded(requested, remaining);
            }
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @inheritdoc IHooks
    /// @dev Records the token amount actually moved: buys add to today's `bought`, sells add to
    /// today's `sold` and revert if that would exceed half of yesterday's buys.
    function afterSwap(address sender, PoolKey calldata, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, int128)
    {
        uint256 day = currentDay();
        int128 tokenDelta = delta.amount1();

        if (params.zeroForOne) {
            // Buy: the swapper receives currency1 (positive delta).
            uint256 amountOut = tokenDelta > 0 ? uint256(uint128(tokenDelta)) : 0;
            bought[day] += amountOut;
            emit Bought(day, sender, amountOut);
        } else {
            // Sell: the swapper pays currency1 (negative delta).
            uint256 amountIn = tokenDelta < 0 ? uint256(uint128(-tokenDelta)) : 0;
            uint256 remaining = sellRemaining(day);
            if (amountIn > remaining) revert SellCapExceeded(amountIn, remaining);
            sold[day] += amountIn;
            emit Sold(day, sender, amountIn);
        }
        return (IHooks.afterSwap.selector, 0);
    }

    /// @inheritdoc IHooks
    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure override returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    // ----------------------------------------------------------------------------------------
    // Staking and voting
    // ----------------------------------------------------------------------------------------

    /// @notice Deposit SURF to gain voting weight. Requires a prior approval to this contract.
    function stake(uint256 amount) external {
        if (genesis == 0) revert NotInitialized();
        if (amount == 0) revert ZeroAmount();
        staked[msg.sender] += amount;
        emit Staked(msg.sender, amount);
        token.safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @notice Withdraw staked SURF. Blocked for the rest of any day in which the caller has voted.
    function unstake(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        if (_lastVoteDayPlusOne[msg.sender] == currentDay() + 1) revert StakeLockedByVote();
        uint256 balance = staked[msg.sender];
        if (amount > balance) revert InsufficientStake();
        staked[msg.sender] = balance - amount;
        emit Unstaked(msg.sender, amount);
        token.safeTransfer(msg.sender, amount);
    }

    /// @notice Vote with the whole current stake on whether today's sell window opens.
    /// @param support True to open sells in the last hour of today, false to keep them closed.
    function vote(bool support) external {
        if (genesis == 0) revert NotInitialized();
        if (!votingOpen()) revert VotingClosed();
        uint256 weight = staked[msg.sender];
        if (weight == 0) revert NothingStaked();
        uint256 day = currentDay();
        if (_lastVoteDayPlusOne[msg.sender] == day + 1) revert AlreadyVoted();
        _lastVoteDayPlusOne[msg.sender] = day + 1;
        if (support) yesVotes[day] += weight;
        else noVotes[day] += weight;
        emit Voted(day, msg.sender, support, weight);
    }

    // ----------------------------------------------------------------------------------------
    // Views
    // ----------------------------------------------------------------------------------------

    /// @notice The current day index, counted from `genesis`. Reverts before initialization.
    function currentDay() public view returns (uint256) {
        if (genesis == 0) revert NotInitialized();
        return (block.timestamp - genesis) / DAY;
    }

    /// @notice Seconds elapsed in the current day.
    function secondsIntoDay() public view returns (uint256) {
        if (genesis == 0) revert NotInitialized();
        return (block.timestamp - genesis) % DAY;
    }

    /// @notice True during the voting hours of the current day.
    function votingOpen() public view returns (bool) {
        return secondsIntoDay() < VOTING_PERIOD;
    }

    /// @notice True when a day's vote passed: strict majority of yes over no and quorum reached.
    function votePassed(uint256 day) public view returns (bool) {
        uint256 yes = yesVotes[day];
        uint256 no = noVotes[day];
        return yes > no && yes + no >= quorum;
    }

    /// @notice True while sells are allowed: the last hour of the day and today's vote passed.
    function sellWindowOpen() public view returns (bool) {
        return secondsIntoDay() >= VOTING_PERIOD && votePassed(currentDay());
    }

    /// @notice Maximum tokens that may be sold on `day`: 50% of the previous day's buys.
    function sellCap(uint256 day) public view returns (uint256) {
        if (day == 0) return 0;
        return (bought[day - 1] * SELL_SHARE_BPS) / BPS;
    }

    /// @notice Tokens that may still be sold on `day`.
    function sellRemaining(uint256 day) public view returns (uint256) {
        uint256 cap = sellCap(day);
        uint256 used = sold[day];
        return used >= cap ? 0 : cap - used;
    }

    /// @notice The last day index on which `account` voted, and whether it ever has.
    function lastVoteDay(address account) external view returns (bool hasVoted, uint256 day) {
        uint256 stored = _lastVoteDayPlusOne[account];
        if (stored == 0) return (false, 0);
        return (true, stored - 1);
    }
}
