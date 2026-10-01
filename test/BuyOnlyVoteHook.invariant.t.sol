// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";

import {BuyOnlyVoteHook} from "../src/BuyOnlyVoteHook.sol";
import {SurfToken} from "../src/SurfToken.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {HookMiner} from "../src/HookMiner.sol";

/// @notice Drives the hook with random, bounded call sequences from three actors and predicts the outcome
/// of every call. The run is configured with `fail_on_revert`, so a revert the handler did not predict
/// (a buy that fails, a sell refused while the window is open and under cap, an unstake refused without a
/// vote, a liquidity removal refused although it returns all the SURF it deposited) fails the campaign
/// instead of being silently skipped.
///
/// Liquidity is the second value path the hook gates: each actor owns up to six positions (one per range
/// of a fixed menu, salted with the actor's address so they are separate in the pool manager), adds to
/// them at any time and removes any part of them. Before a removal the handler recomputes, with the
/// pool's own `SqrtPriceMath`, the SURF the pool will hand back, and from that the shortfall the hook
/// must charge; the call is then required to succeed or fail exactly as the sell rules say.
contract BuyOnlyVoteHookHandler is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 public constant ACTOR_FUNDING = 20_000_000 ether; // twice the quorum each

    PoolManager public manager;
    SurfToken public token;
    BuyOnlyVoteHook public hook;
    PoolSwapTest public swapRouter;
    PoolModifyLiquidityTest public lpRouter;
    PoolKey key;
    PoolId poolId;

    address[] public actors;

    /// @dev Tick ranges liquidity is added to (tick spacing 60). Relative to the genesis price (tick 0):
    /// full range, symmetric, parked SURF below, further below, parked ETH above, tight around.
    int24[6] internal lowers = [int24(-887_220), -600, -120, -1_200, 60, -60];
    int24[6] internal uppers = [int24(887_220), 600, -60, -600, 120, 60];

    struct TrackedPosition {
        address actor;
        int24 lower;
        int24 upper;
    }

    TrackedPosition[] public tracked;
    mapping(bytes32 => bool) internal isTracked;

    // ---- ghost state ------------------------------------------------------------------------------
    uint256 public ghostTotalStaked;
    mapping(address => uint256) public ghostStakedIn;
    mapping(address => uint256) public ghostUnstakedOut;
    mapping(address => uint256) public ghostVoteDayPlusOne; // day + 1 of the actor's last vote
    mapping(address => uint256) public ghostStakeAtVote; // stake committed by that vote

    mapping(uint256 => uint256) public ghostBought; // net of the sells it cancelled, as the hook counts
    mapping(uint256 => uint256) public ghostGrossBought; // every SURF that left the pool through a buy
    mapping(uint256 => uint256) public ghostSold; // net: swap sells + LP charges - cancelled by buys
    mapping(uint256 => uint256) public ghostSwapSold;
    mapping(uint256 => uint256) public ghostLpSold;
    mapping(uint256 => uint256) public ghostCancelled;
    mapping(uint256 => uint256) public ghostYes;
    mapping(uint256 => uint256) public ghostNo;
    mapping(uint256 => uint256) public ghostVotesCast;
    mapping(uint256 => bool) public ghostWindowSeenOpen;

    /// @dev SURF deposited into each position since it was last empty, and SURF it has paid back out.
    mapping(bytes32 => uint256) public ghostSurfDeposited;
    mapping(bytes32 => uint256) public ghostSurfReturned;
    /// @dev Shortfalls within the rounding tolerance that were (rightly) not charged: the only SURF that
    /// can ever turn into ETH outside the rules, bounded by the tolerance per removal.
    uint256 public ghostUnchargedShortfall;
    uint256 public ghostRemovalsSettled;
    /// @dev ETH an actor withdrew from a position while the window was closed; all of it must have been
    /// backed by a SURF-neutral position (asserted in place), never by SURF that became ETH.
    uint256 public ghostEthOutOfLpWhileClosed;

    // A day whose data is frozen once the clock has moved past it.
    mapping(uint256 => bool) public frozen;
    mapping(uint256 => uint256) public frozenBought;
    mapping(uint256 => uint256) public frozenSold;
    mapping(uint256 => uint256) public frozenYes;
    mapping(uint256 => uint256) public frozenNo;

    uint256 public lastSeenDay;
    uint256 public maxDaySeen;

    // Call counters so a vacuous campaign is visible.
    uint256 public buys;
    uint256 public sellsDone;
    uint256 public sellsClosed;
    uint256 public sellsOverCap;
    uint256 public votesDone;
    uint256 public votesRefused;
    uint256 public unstakesDone;
    uint256 public unstakesLocked;
    uint256 public lpAdds;
    uint256 public lpRemovesFree;
    uint256 public lpRemovesCharged;
    uint256 public lpRemovesClosed;
    uint256 public lpRemovesOverCap;

    receive() external payable {}

    constructor(
        PoolManager _manager,
        SurfToken _token,
        BuyOnlyVoteHook _hook,
        PoolSwapTest _swapRouter,
        PoolModifyLiquidityTest _lpRouter,
        PoolKey memory _key
    ) {
        manager = _manager;
        token = _token;
        hook = _hook;
        swapRouter = _swapRouter;
        lpRouter = _lpRouter;
        key = _key;
        poolId = _key.toId();

        actors.push(makeAddr("actor-alice"));
        actors.push(makeAddr("actor-bob"));
        actors.push(makeAddr("actor-carol"));
        for (uint256 i = 0; i < actors.length; i++) {
            vm.deal(actors[i], 10_000 ether);
            vm.startPrank(actors[i]);
            token.approve(address(swapRouter), type(uint256).max);
            token.approve(address(lpRouter), type(uint256).max);
            token.approve(address(hook), type(uint256).max);
            vm.stopPrank();
        }
    }

    /// @dev Called once by the test after it has sent the handler the actors' SURF.
    function fundActors() external {
        for (uint256 i = 0; i < actors.length; i++) {
            token.transfer(actors[i], ACTOR_FUNDING);
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function trackedCount() external view returns (uint256) {
        return tracked.length;
    }

    // ---- helpers ----------------------------------------------------------------------------------

    function pick(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function salt(address actor) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(actor)));
    }

    function posKey(address actor, int24 lower, int24 upper) public view returns (bytes32) {
        return hook.positionKey(address(lpRouter), lower, upper, salt(actor));
    }

    function hookRevert(bytes4 callback, bytes memory reason) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            callback,
            reason,
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    /// @dev Freeze every day that is now in the past, so an invariant can check nothing rewrites it.
    function syncDays() internal {
        uint256 day = hook.currentDay();
        for (uint256 d = lastSeenDay; d < day; d++) {
            if (!frozen[d]) {
                frozen[d] = true;
                frozenBought[d] = hook.bought(d);
                frozenSold[d] = hook.sold(d);
                frozenYes[d] = hook.yesVotes(d);
                frozenNo[d] = hook.noVotes(d);
            }
        }
        lastSeenDay = day;
        if (day > maxDaySeen) maxDaySeen = day;
    }

    /// @dev The amounts the pool moves for a liquidity change of `liquidity` on [lower, upper], computed
    /// exactly as `Pool.modifyLiquidity` does (rounded up when depositing, down when withdrawing).
    function poolAmounts(int24 lower, int24 upper, uint128 liquidity, bool deposit)
        public
        view
        returns (uint256 amount0, uint256 amount1)
    {
        (uint160 sqrtPriceX96, int24 tick,,) = IPoolManager(address(manager)).getSlot0(poolId);
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(lower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(upper);
        if (tick < lower) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtLower, sqrtUpper, liquidity, deposit);
        } else if (tick < upper) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtUpper, liquidity, deposit);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtPriceX96, liquidity, deposit);
        } else {
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtUpper, liquidity, deposit);
        }
    }

    // ---- actions ----------------------------------------------------------------------------------

    /// @notice Move the clock: a random step, or straight to a boundary of the schedule.
    function warp(uint256 mode, uint256 seed) external {
        mode = mode % 5;
        uint256 into = hook.secondsIntoDay();
        uint256 target;
        if (mode == 0 || mode == 4) {
            target = block.timestamp + bound(seed, 1, 6 hours);
        } else if (mode == 1 || mode == 3) {
            // Exactly the opening second of the sell window (or the next day's, if already past it).
            target = into < 23 hours ? block.timestamp + (23 hours - into) : block.timestamp + (47 hours - into);
        } else if (mode == 2) {
            // The last second of today.
            target = block.timestamp + (24 hours - 1 - into);
        } else {
            // The first second of tomorrow.
            target = block.timestamp + (24 hours - into);
        }
        if (mode == 4) target = block.timestamp + (24 hours - into);
        vm.warp(target);
        syncDays();
    }

    function stake(uint256 actorSeed, uint256 amount) external {
        address actor = pick(actorSeed);
        uint256 balance = token.balanceOf(actor);
        if (balance == 0) return;
        _stake(actor, bound(amount, 1, balance));
    }

    /// @notice Clamped path: bring one actor's stake up to the quorum and vote yes, so that windows open
    /// often enough for the sell rules to be exercised. Uses the same bookkeeping as the random paths.
    function rallyYes(uint256 actorSeed) external {
        address actor = pick(actorSeed);
        uint256 q = hook.quorum();
        uint256 have = hook.staked(actor);
        if (have < q) {
            uint256 balance = token.balanceOf(actor);
            uint256 missing = q - have;
            if (balance > 0) _stake(actor, missing > balance ? balance : missing);
        }
        _vote(actor, true);
    }

    function _stake(address actor, uint256 amount) internal {
        vm.prank(actor);
        hook.stake(amount);

        ghostTotalStaked += amount;
        ghostStakedIn[actor] += amount;
    }

    function unstake(uint256 actorSeed, uint256 amount) external {
        address actor = pick(actorSeed);
        uint256 stakedNow = hook.staked(actor);
        if (stakedNow == 0) return;
        amount = bound(amount, 1, stakedNow);
        uint256 day = hook.currentDay();
        bool lockedByVote = ghostVoteDayPlusOne[actor] == day + 1;

        vm.prank(actor);
        try hook.unstake(amount) {
            assertFalse(lockedByVote, "unstake succeeded for an actor who voted today");
            ghostTotalStaked -= amount;
            ghostUnstakedOut[actor] += amount;
            unstakesDone++;
        } catch (bytes memory err) {
            assertTrue(lockedByVote, "unstake refused although the actor has not voted today");
            assertEq(
                err, abi.encodeWithSelector(BuyOnlyVoteHook.StakeLockedByVote.selector), "unexpected unstake error"
            );
            unstakesLocked++;
        }
    }

    function vote(uint256 actorSeed, uint256 supportSeed) external {
        // Biased towards yes so that windows actually open; a quarter of votes still say no.
        _vote(pick(actorSeed), supportSeed % 4 != 0);
    }

    function _vote(address actor, bool support) internal {
        uint256 day = hook.currentDay();
        bool open = hook.votingOpen();
        uint256 weight = hook.staked(actor);
        bool votedToday = ghostVoteDayPlusOne[actor] == day + 1;

        bytes memory expected;
        if (!open) expected = abi.encodeWithSelector(BuyOnlyVoteHook.VotingClosed.selector);
        else if (weight == 0) expected = abi.encodeWithSelector(BuyOnlyVoteHook.NothingStaked.selector);
        else if (votedToday) expected = abi.encodeWithSelector(BuyOnlyVoteHook.AlreadyVoted.selector);

        vm.prank(actor);
        try hook.vote(support) {
            assertEq(expected.length, 0, "vote succeeded where a refusal was expected");
            if (support) ghostYes[day] += weight;
            else ghostNo[day] += weight;
            ghostVotesCast[day] += 1;
            ghostVoteDayPlusOne[actor] = day + 1;
            ghostStakeAtVote[actor] = weight;
            votesDone++;
        } catch (bytes memory err) {
            assertGt(expected.length, 0, "vote refused although it should have been accepted");
            assertEq(err, expected, "unexpected vote error");
            votesRefused++;
        }
    }

    /// @notice A buy must always succeed, whatever the day, the vote or the cap says. Inside an open
    /// window it first cancels SURF counted as sold today; only the rest is a buy for tomorrow's cap.
    function buy(uint256 actorSeed, uint256 ethIn, bool exactOutput) external {
        address actor = pick(actorSeed);
        ethIn = bound(ethIn, 0.0001 ether, 20 ether);
        uint256 day = hook.currentDay();
        uint256 boughtBefore = hook.bought(day);
        uint256 soldBefore = hook.sold(day);
        uint256 tokensBefore = token.balanceOf(actor);

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            // Exact output asks for tokens; priced near 1:1 at genesis, so the ETH sent covers it with margin.
            amountSpecified: exactOutput ? int256(ethIn / 8) : -int256(ethIn),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        vm.prank(actor);
        try swapRouter.swap{value: ethIn}(
            key, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), ""
        ) returns (
            BalanceDelta delta
        ) {
            uint256 out = uint256(int256(delta.amount1()));
            uint256 cancelled = out < soldBefore ? out : soldBefore;
            assertEq(token.balanceOf(actor), tokensBefore + out, "buyer did not receive the delta");
            assertEq(hook.sold(day), soldBefore - cancelled, "a buy must cancel today's sells first");
            assertEq(hook.bought(day), boughtBefore + out - cancelled, "bought[day] must grow by the net buy");
            if (!hook.sellWindowOpen()) assertEq(cancelled, 0, "nothing to cancel outside a window");
            ghostBought[day] += out - cancelled;
            ghostGrossBought[day] += out;
            ghostSold[day] -= cancelled;
            ghostCancelled[day] += cancelled;
            buys++;
        } catch (bytes memory err) {
            // Only the router's own insufficient-ETH guard may stop an exact-output buy; the hook never may.
            assertTrue(exactOutput, string.concat("a buy was refused: ", vm.toString(err)));
            assertTrue(err.length == 0 || bytes4(err) != CustomRevert.WrappedError.selector, "the hook refused a buy");
        }
    }

    /// @notice Sells succeed exactly when the window is open and the amount fits the remaining cap.
    function sell(uint256 actorSeed, uint256 mode, uint256 amountSeed) external {
        address actor = pick(actorSeed);
        uint256 day = hook.currentDay();
        bool open = hook.sellWindowOpen();
        uint256 remaining = hook.sellRemaining(day);
        uint256 balance = token.balanceOf(actor);
        if (balance == 0) return;
        if (open) ghostWindowSeenOpen[day] = true;

        // Boundary stress: exactly the remaining cap, one over it, or anything up to twice the cap.
        uint256 amount;
        mode = mode % 3;
        if (mode == 0) amount = remaining;
        else if (mode == 1) amount = remaining + 1;
        else amount = bound(amountSeed, 1, 2 * remaining + 1);
        if (amount == 0) amount = 1;
        if (amount > balance) amount = balance;

        bytes memory expected;
        if (!open) {
            expected =
                hookRevert(IHooks.beforeSwap.selector, abi.encodeWithSelector(BuyOnlyVoteHook.SellsClosed.selector));
        } else if (amount > remaining) {
            expected = hookRevert(
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(BuyOnlyVoteHook.SellCapExceeded.selector, amount, remaining)
            );
        }

        uint256 soldBefore = hook.sold(day);
        uint256 ethBefore = actor.balance;
        SwapParams memory params = SwapParams({
            zeroForOne: false, amountSpecified: -int256(amount), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });

        vm.prank(actor);
        try swapRouter.swap(
            key, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), ""
        ) returns (
            BalanceDelta delta
        ) {
            assertEq(expected.length, 0, "sell succeeded where a refusal was expected");
            uint256 paid = uint256(int256(-delta.amount1()));
            assertLe(paid, amount, "pool took more than the exact input");
            assertEq(token.balanceOf(actor), balance - paid, "seller balance mismatch");
            assertGe(actor.balance, ethBefore, "seller lost ETH on a sell");
            assertEq(hook.sold(day), soldBefore + paid, "sold[day] did not grow by the tokens paid");
            ghostSold[day] += paid;
            ghostSwapSold[day] += paid;
            sellsDone++;
        } catch (bytes memory err) {
            assertGt(expected.length, 0, "sell refused although the window is open and the amount fits the cap");
            assertEq(err, expected, "unexpected sell error");
            assertEq(token.balanceOf(actor), balance, "a refused sell moved tokens");
            if (open) sellsOverCap++;
            else sellsClosed++;
        }
    }

    /// @notice Adding liquidity is never refused, at any time, in any range, and the hook records exactly
    /// the SURF the position took in.
    function addLiquidity(uint256 actorSeed, uint256 rangeSeed, uint256 liquiditySeed) external {
        LpCall memory c;
        c.actor = pick(actorSeed);
        (c.lower, c.upper) = (lowers[rangeSeed % lowers.length], uppers[rangeSeed % lowers.length]);
        c.amount = bound(liquiditySeed, 1e15, 1e21);
        c.k = posKey(c.actor, c.lower, c.upper);

        (c.eth0, c.surf1) = poolAmounts(c.lower, c.upper, uint128(c.amount), true);
        if (c.surf1 > token.balanceOf(c.actor)) return;
        vm.deal(c.actor, c.actor.balance + c.eth0 + 1);

        (c.liqBefore, c.surfInBefore) = hook.positions(c.k);
        c.surfBefore = token.balanceOf(c.actor);

        vm.prank(c.actor);
        BalanceDelta delta = lpRouter.modifyLiquidity{value: c.eth0 + 1}(key, lpParams(c, int256(c.amount)), "");
        uint256 surfPaid = delta.amount1() < 0 ? uint256(int256(-delta.amount1())) : 0;
        assertEq(surfPaid, c.surf1, "predicted SURF deposit");
        assertEq(uint256(int256(-delta.amount0())), c.eth0, "predicted ETH deposit");
        assertEq(token.balanceOf(c.actor), c.surfBefore - surfPaid, "LP SURF balance");

        (uint256 liqAfter, uint256 surfInAfter) = hook.positions(c.k);
        assertEq(liqAfter, c.liqBefore + c.amount, "position liquidity mirror");
        assertEq(surfInAfter, c.surfInBefore + surfPaid, "position SURF deposit record");

        if (!isTracked[c.k]) {
            isTracked[c.k] = true;
            tracked.push(TrackedPosition({actor: c.actor, lower: c.lower, upper: c.upper}));
        }
        ghostSurfDeposited[c.k] += surfPaid;
        lpAdds++;
    }

    /// @dev Everything one liquidity call needs, kept off the stack.
    struct LpCall {
        address actor;
        int24 lower;
        int24 upper;
        bytes32 k;
        uint256 amount; // liquidity added or removed
        uint256 eth0;
        uint256 surf1; // predicted SURF moved by the pool
        uint256 liqBefore;
        uint256 surfInBefore;
        uint256 surfBefore;
        uint256 ethBefore;
        uint256 day;
        bool open;
        uint256 remaining;
        uint256 expectedSurf; // the removed share of the recorded deposit
        uint256 shortfall; // what the hook must charge, zero within tolerance
        uint256 soldBefore;
        bytes expectedErr;
    }

    function lpParams(LpCall memory c, int256 liquidityDelta) internal pure returns (ModifyLiquidityParams memory) {
        return ModifyLiquidityParams({
            tickLower: c.lower, tickUpper: c.upper, liquidityDelta: liquidityDelta, salt: salt(c.actor)
        });
    }

    /// @notice Removing liquidity returns the position's SURF freely; SURF that became ETH inside it is a
    /// sell and follows the window and the cap, to the wei.
    function removeLiquidity(uint256 actorSeed, uint256 rangeSeed, uint256 mode, uint256 fractionSeed) external {
        LpCall memory c;
        c.actor = pick(actorSeed);
        (c.lower, c.upper) = (lowers[rangeSeed % lowers.length], uppers[rangeSeed % lowers.length]);
        (c.liqBefore, c.surfInBefore) = hook.positions(posKey(c.actor, c.lower, c.upper));
        if (c.liqBefore == 0) {
            // Fall back to any position that exists, so that removals happen often enough to matter.
            if (tracked.length == 0) return;
            uint256 start = fractionSeed % tracked.length;
            for (uint256 i = 0; i < tracked.length; i++) {
                TrackedPosition memory t = tracked[(start + i) % tracked.length];
                (c.liqBefore, c.surfInBefore) = hook.positions(posKey(t.actor, t.lower, t.upper));
                if (c.liqBefore != 0) {
                    (c.actor, c.lower, c.upper) = (t.actor, t.lower, t.upper);
                    break;
                }
            }
            if (c.liqBefore == 0) return;
        }
        c.k = posKey(c.actor, c.lower, c.upper);

        // Remove everything, half, or any part.
        mode = mode % 3;
        if (mode == 0) c.amount = c.liqBefore;
        else if (mode == 1) c.amount = c.liqBefore / 2 == 0 ? c.liqBefore : c.liqBefore / 2;
        else c.amount = bound(fractionSeed, 1, c.liqBefore);

        _remove(c);
    }

    function _remove(LpCall memory c) internal {
        c.day = hook.currentDay();
        c.open = hook.sellWindowOpen();
        c.remaining = hook.sellRemaining(c.day);
        (c.eth0, c.surf1) = poolAmounts(c.lower, c.upper, uint128(c.amount), false);
        // The v4 test router asserts that a removal pays something out; a dust removal that rounds to
        // zero on both sides trips that assert in the router, before and independently of the hook.
        if (c.eth0 == 0 && c.surf1 == 0) return;

        // The hook's rule, restated: the removed share of the recorded deposit, minus what comes back.
        c.expectedSurf = (c.surfInBefore * c.amount) / c.liqBefore;
        c.shortfall = c.expectedSurf > c.surf1 + hook.LP_ROUNDING_TOLERANCE() ? c.expectedSurf - c.surf1 : 0;

        if (c.shortfall > 0 && !c.open) {
            c.expectedErr = hookRevert(
                IHooks.afterRemoveLiquidity.selector, abi.encodeWithSelector(BuyOnlyVoteHook.SellsClosed.selector)
            );
        } else if (c.shortfall > c.remaining) {
            c.expectedErr = hookRevert(
                IHooks.afterRemoveLiquidity.selector,
                abi.encodeWithSelector(BuyOnlyVoteHook.SellCapExceeded.selector, c.shortfall, c.remaining)
            );
        }

        c.soldBefore = hook.sold(c.day);
        c.surfBefore = token.balanceOf(c.actor);
        c.ethBefore = c.actor.balance;
        if (c.open) ghostWindowSeenOpen[c.day] = true;

        vm.prank(c.actor);
        try lpRouter.modifyLiquidity(key, lpParams(c, -int256(c.amount)), "") returns (BalanceDelta delta) {
            _settledRemoval(c, delta);
        } catch (bytes memory err) {
            assertGt(c.expectedErr.length, 0, "liquidity removal refused although it is not a sell");
            assertEq(err, c.expectedErr, "unexpected liquidity removal error");
            assertEq(token.balanceOf(c.actor), c.surfBefore, "a refused removal moved SURF");
            assertEq(c.actor.balance, c.ethBefore, "a refused removal moved ETH");
            assertEq(hook.sold(c.day), c.soldBefore, "a refused removal was recorded");
            if (c.open) lpRemovesOverCap++;
            else lpRemovesClosed++;
        }
    }

    function _settledRemoval(LpCall memory c, BalanceDelta delta) internal {
        assertEq(c.expectedErr.length, 0, "liquidity removal succeeded where the sell rules refuse it");
        uint256 surfOut = delta.amount1() > 0 ? uint256(int256(delta.amount1())) : 0;
        uint256 ethOut = delta.amount0() > 0 ? uint256(int256(delta.amount0())) : 0;
        assertEq(surfOut, c.surf1, "predicted SURF withdrawal");
        assertEq(token.balanceOf(c.actor), c.surfBefore + surfOut, "LP SURF balance");
        assertEq(c.actor.balance, c.ethBefore + ethOut, "LP ETH balance");

        (uint256 liqAfter, uint256 surfInAfter) = hook.positions(c.k);
        assertEq(liqAfter, c.liqBefore - c.amount, "position liquidity mirror");
        assertEq(surfInAfter, c.surfInBefore - c.expectedSurf, "position SURF record after attribution");

        if (c.shortfall > 0) {
            assertEq(hook.sold(c.day), c.soldBefore + c.shortfall, "the shortfall must be charged exactly");
            ghostSold[c.day] += c.shortfall;
            ghostLpSold[c.day] += c.shortfall;
            lpRemovesCharged++;
        } else {
            assertEq(hook.sold(c.day), c.soldBefore, "a SURF-neutral removal is not a sell");
            ghostUnchargedShortfall += c.expectedSurf > surfOut ? c.expectedSurf - surfOut : 0;
            if (!c.open) ghostEthOutOfLpWhileClosed += ethOut;
            lpRemovesFree++;
        }
        ghostSurfReturned[c.k] += surfOut;
        ghostRemovalsSettled++;
        if (liqAfter == 0) {
            // The record is spent; a later add starts a fresh deposit history.
            assertEq(surfInAfter, 0, "an emptied position keeps a SURF record");
            ghostSurfDeposited[c.k] = 0;
            ghostSurfReturned[c.k] = 0;
        }
    }
}

/// forge-config: default.invariant.runs = 48
/// forge-config: default.invariant.depth = 200
/// forge-config: default.invariant.fail-on-revert = true
contract BuyOnlyVoteHookInvariantTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 constant FLAGS = HookFlags.BEFORE_INITIALIZE | HookFlags.AFTER_ADD_LIQUIDITY
        | HookFlags.AFTER_REMOVE_LIQUIDITY | HookFlags.BEFORE_SWAP | HookFlags.AFTER_SWAP;
    uint256 constant START = 1_700_000_000;

    PoolManager manager;
    SurfToken token;
    BuyOnlyVoteHook hook;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest lpRouter;
    PoolKey key;
    BuyOnlyVoteHookHandler handler;

    receive() external payable {}

    function setUp() public {
        vm.warp(START);
        manager = new PoolManager(address(this));
        token = new SurfToken();
        bytes memory creationCode = abi.encodePacked(type(BuyOnlyVoteHook).creationCode, abi.encode(manager));
        (address predicted, bytes32 salt) = HookMiner.find(address(this), FLAGS, creationCode);
        hook = new BuyOnlyVoteHook{salt: salt}(IPoolManager(address(manager)));
        assertEq(address(hook), predicted);
        swapRouter = new PoolSwapTest(manager);
        lpRouter = new PoolModifyLiquidityTest(manager);

        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        manager.initialize(key, SQRT_PRICE_1_1);

        vm.deal(address(this), 100_000 ether);
        token.approve(address(lpRouter), type(uint256).max);
        lpRouter.modifyLiquidity{value: 10_000 ether}(
            key,
            ModifyLiquidityParams({tickLower: -887_220, tickUpper: 887_220, liquidityDelta: 10_000e18, salt: 0}),
            ""
        );

        handler = new BuyOnlyVoteHookHandler(manager, token, hook, swapRouter, lpRouter, key);
        token.transfer(address(handler), 3 * handler.ACTOR_FUNDING());
        handler.fundActors();

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = BuyOnlyVoteHookHandler.warp.selector;
        selectors[1] = BuyOnlyVoteHookHandler.stake.selector;
        selectors[2] = BuyOnlyVoteHookHandler.unstake.selector;
        selectors[3] = BuyOnlyVoteHookHandler.vote.selector;
        selectors[4] = BuyOnlyVoteHookHandler.buy.selector;
        selectors[5] = BuyOnlyVoteHookHandler.sell.selector;
        selectors[6] = BuyOnlyVoteHookHandler.rallyYes.selector;
        selectors[7] = BuyOnlyVoteHookHandler.addLiquidity.selector;
        selectors[8] = BuyOnlyVoteHookHandler.removeLiquidity.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    // ---- conservation -------------------------------------------------------------------------------

    /// @notice The hook holds exactly the SURF its stakers are owed, no more and no less.
    function invariant_hookHoldsExactlyTheStakes() public view {
        uint256 sum;
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address a = handler.actors(i);
            sum += hook.staked(a);
            assertEq(hook.staked(a), handler.ghostStakedIn(a) - handler.ghostUnstakedOut(a), "per-actor stake");
            assertLe(handler.ghostUnstakedOut(a), handler.ghostStakedIn(a), "an actor withdrew more than it staked");
        }
        assertEq(sum, handler.ghostTotalStaked(), "sum of stakes vs ghost");
        assertEq(token.balanceOf(address(hook)), sum, "hook balance vs sum of stakes");
    }

    /// @notice The hook never ends up holding ETH or pool claims: it charges no fee and takes no delta.
    function invariant_hookNeverHoldsEthOrClaims() public view {
        assertEq(address(hook).balance, 0);
        assertEq(manager.balanceOf(address(hook), 0), 0, "ETH claims");
        assertEq(manager.balanceOf(address(hook), uint256(uint160(address(token)))), 0, "SURF claims");
    }

    /// @notice SURF is a fixed supply and every unit is somewhere we can name.
    function invariant_tokenSupplyConserved() public view {
        assertEq(token.totalSupply(), 10 ** 27);
        uint256 sum = token.balanceOf(address(this)) + token.balanceOf(address(manager))
            + token.balanceOf(address(hook)) + token.balanceOf(address(handler)) + token.balanceOf(address(swapRouter))
            + token.balanceOf(address(lpRouter));
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            sum += token.balanceOf(handler.actors(i));
        }
        assertEq(sum, token.totalSupply());
    }

    // ---- the trading rules ------------------------------------------------------------------------

    /// @notice On every day ever touched, net sells never exceeded half of the previous day's net buys.
    function invariant_soldNeverExceedsTheCap() public view {
        uint256 last = hook.currentDay();
        for (uint256 d = 0; d <= last; d++) {
            uint256 cap = hook.sellCap(d);
            assertLe(hook.sold(d), cap, "sold over cap");
            assertEq(cap, d == 0 ? 0 : hook.bought(d - 1) / 2, "cap is not half of yesterday's buys");
            assertEq(hook.sellRemaining(d), cap - hook.sold(d), "remaining");
        }
    }

    /// @notice Anything sold on a day (by swap or by withdrawing converted liquidity) was sold on a day
    /// whose vote passed, and the window was seen open.
    function invariant_sellsHappenOnlyOnVotedDays() public view {
        uint256 last = hook.currentDay();
        for (uint256 d = 0; d <= last; d++) {
            if (hook.sold(d) > 0 || handler.ghostSwapSold(d) > 0 || handler.ghostLpSold(d) > 0) {
                assertTrue(hook.votePassed(d), "sold on a day whose vote did not pass");
                assertTrue(handler.ghostWindowSeenOpen(d), "sold on a day whose window was never open");
            }
        }
    }

    /// @notice Internal accounting equals the deltas the swappers and LPs actually received or paid:
    /// `sold` is swap sells plus liquidity charges minus what buys cancelled; `bought` is the net buy.
    function invariant_accountingMatchesSwapDeltas() public view {
        uint256 last = hook.currentDay();
        for (uint256 d = 0; d <= last; d++) {
            assertEq(hook.bought(d), handler.ghostBought(d), "bought vs deltas");
            assertEq(hook.sold(d), handler.ghostSold(d), "sold vs deltas");
            assertEq(
                hook.sold(d) + handler.ghostCancelled(d),
                handler.ghostSwapSold(d) + handler.ghostLpSold(d),
                "sold decomposition"
            );
            assertEq(hook.bought(d) + handler.ghostCancelled(d), handler.ghostGrossBought(d), "bought decomposition");
            assertLe(handler.ghostCancelled(d), handler.ghostSwapSold(d) + handler.ghostLpSold(d), "over-cancelled");
        }
    }

    /// @notice Tallies equal the weights committed by accepted votes, and nobody voted twice in a day.
    function invariant_voteTalliesMatchAcceptedVotes() public view {
        uint256 last = hook.currentDay();
        for (uint256 d = 0; d <= last; d++) {
            assertEq(hook.yesVotes(d), handler.ghostYes(d), "yes tally");
            assertEq(hook.noVotes(d), handler.ghostNo(d), "no tally");
            assertLe(handler.ghostVotesCast(d), handler.actorCount(), "more votes than actors in one day");
            assertEq(
                hook.votePassed(d),
                hook.yesVotes(d) > hook.noVotes(d) && hook.yesVotes(d) + hook.noVotes(d) >= hook.quorum(),
                "votePassed rule"
            );
        }
    }

    /// @notice A stake that voted today cannot have shrunk since the vote.
    function invariant_votedStakeStaysLockedForTheDay() public view {
        uint256 day = hook.currentDay();
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address a = handler.actors(i);
            if (handler.ghostVoteDayPlusOne(a) == day + 1) {
                assertGe(hook.staked(a), handler.ghostStakeAtVote(a), "a voted stake was withdrawn");
            }
            (bool voted, uint256 d) = hook.lastVoteDay(a);
            assertEq(voted, handler.ghostVoteDayPlusOne(a) != 0, "lastVoteDay flag");
            if (voted) assertEq(d + 1, handler.ghostVoteDayPlusOne(a), "lastVoteDay value");
        }
    }

    /// @notice Once a day is over, nothing about it changes: buys, sells and tallies are final.
    function invariant_pastDaysAreFrozen() public view {
        for (uint256 d = 0; d < hook.currentDay(); d++) {
            if (!handler.frozen(d)) continue;
            assertEq(hook.bought(d), handler.frozenBought(d), "bought rewritten");
            assertEq(hook.sold(d), handler.frozenSold(d), "sold rewritten");
            assertEq(hook.yesVotes(d), handler.frozenYes(d), "yes rewritten");
            assertEq(hook.noVotes(d), handler.frozenNo(d), "no rewritten");
        }
    }

    /// @notice Voting and selling never overlap, and selling always implies a passed vote for today.
    function invariant_scheduleIsConsistent() public view {
        bool voting = hook.votingOpen();
        bool selling = hook.sellWindowOpen();
        assertFalse(voting && selling, "voting and selling at once");
        assertEq(voting, hook.secondsIntoDay() < 23 hours, "voting hours");
        if (selling) assertTrue(hook.votePassed(hook.currentDay()), "window open without a passed vote");
        if (!voting && hook.votePassed(hook.currentDay())) assertTrue(selling, "window closed despite a passed vote");
    }

    /// @notice Immutable binding never moves.
    function invariant_bindingIsImmutable() public view {
        assertEq(address(hook.token()), address(token));
        assertEq(hook.genesis(), START);
        assertEq(hook.quorum(), 10 ** 25);
        assertEq(address(hook.poolManager()), address(manager));
    }

    // ---- liquidity positions ----------------------------------------------------------------------

    /// @notice The hook's mirror of every position's liquidity equals what the pool manager holds for it,
    /// and the SURF it remembers never exceeds what the position actually took in.
    function invariant_positionRecordsMirrorThePool() public view {
        PoolId id = key.toId();
        for (uint256 i = 0; i < handler.trackedCount(); i++) {
            (address actor, int24 lower, int24 upper) = handler.tracked(i);
            bytes32 k = handler.posKey(actor, lower, upper);
            (uint256 liq, uint256 surfIn) = hook.positions(k);
            assertEq(liq, IPoolManager(address(manager)).getPositionLiquidity(id, k), "liquidity mirror");
            assertLe(surfIn, handler.ghostSurfDeposited(k), "recorded SURF exceeds what was deposited");
            if (liq == 0) assertEq(surfIn, 0, "empty position still records SURF");
        }
    }

    /// @notice The only SURF that can turn into ETH without being charged is the rounding tolerance, and at
    /// most once per settled removal.
    function invariant_toleranceLeakIsBounded() public view {
        assertLe(
            handler.ghostUnchargedShortfall(),
            handler.ghostRemovalsSettled() * hook.LP_ROUNDING_TOLERANCE(),
            "uncharged shortfall beyond the per-removal tolerance"
        );
    }

    /// @notice Runs after every sequence: a campaign that never bought, never tried to sell or never touched
    /// liquidity has exercised nothing, and the counters make that visible rather than letting the invariants
    /// pass vacuously.
    function afterInvariant() public view {
        assertGt(handler.buys(), 0, "no buy happened in this sequence");
        assertGt(handler.sellsDone() + handler.sellsClosed() + handler.sellsOverCap(), 0, "no sell was attempted");
        assertGt(handler.lpAdds(), 0, "no liquidity was added in this sequence");
        assertGt(
            handler.lpRemovesFree() + handler.lpRemovesCharged() + handler.lpRemovesClosed()
                + handler.lpRemovesOverCap(),
            0,
            "no liquidity removal was attempted"
        );
    }
}
