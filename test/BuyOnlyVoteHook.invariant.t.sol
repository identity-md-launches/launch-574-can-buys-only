// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
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
/// vote) fails the campaign instead of being silently skipped.
contract BuyOnlyVoteHookHandler is Test {
    uint256 public constant ACTOR_FUNDING = 20_000_000 ether; // twice the quorum each

    PoolManager public manager;
    SurfToken public token;
    BuyOnlyVoteHook public hook;
    PoolSwapTest public swapRouter;
    PoolKey key;

    address[] public actors;

    // ---- ghost state ------------------------------------------------------------------------------
    uint256 public ghostTotalStaked;
    mapping(address => uint256) public ghostStakedIn;
    mapping(address => uint256) public ghostUnstakedOut;
    mapping(address => uint256) public ghostVoteDayPlusOne; // day + 1 of the actor's last vote
    mapping(address => uint256) public ghostStakeAtVote; // stake committed by that vote

    mapping(uint256 => uint256) public ghostBought;
    mapping(uint256 => uint256) public ghostSold;
    mapping(uint256 => uint256) public ghostYes;
    mapping(uint256 => uint256) public ghostNo;
    mapping(uint256 => uint256) public ghostVotesCast;
    mapping(uint256 => bool) public ghostWindowSeenOpen;

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

    receive() external payable {}

    constructor(
        PoolManager _manager,
        SurfToken _token,
        BuyOnlyVoteHook _hook,
        PoolSwapTest _swapRouter,
        PoolKey memory _key
    ) {
        manager = _manager;
        token = _token;
        hook = _hook;
        swapRouter = _swapRouter;
        key = _key;

        actors.push(makeAddr("actor-alice"));
        actors.push(makeAddr("actor-bob"));
        actors.push(makeAddr("actor-carol"));
        for (uint256 i = 0; i < actors.length; i++) {
            vm.deal(actors[i], 10_000 ether);
            vm.startPrank(actors[i]);
            token.approve(address(swapRouter), type(uint256).max);
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

    // ---- helpers ----------------------------------------------------------------------------------

    function pick(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
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

    /// @notice A buy must always succeed, whatever the day, the vote or the cap says.
    function buy(uint256 actorSeed, uint256 ethIn, bool exactOutput) external {
        address actor = pick(actorSeed);
        ethIn = bound(ethIn, 0.0001 ether, 20 ether);
        uint256 day = hook.currentDay();
        uint256 boughtBefore = hook.bought(day);
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
            assertEq(token.balanceOf(actor), tokensBefore + out, "buyer did not receive the delta");
            assertEq(hook.bought(day), boughtBefore + out, "bought[day] did not grow by the tokens received");
            ghostBought[day] += out;
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
            sellsDone++;
        } catch (bytes memory err) {
            assertGt(expected.length, 0, "sell refused although the window is open and the amount fits the cap");
            assertEq(err, expected, "unexpected sell error");
            assertEq(token.balanceOf(actor), balance, "a refused sell moved tokens");
            if (open) sellsOverCap++;
            else sellsClosed++;
        }
    }
}

/// forge-config: default.invariant.runs = 48
/// forge-config: default.invariant.depth = 200
/// forge-config: default.invariant.fail-on-revert = true
contract BuyOnlyVoteHookInvariantTest is Test {
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 constant FLAGS = HookFlags.BEFORE_INITIALIZE | HookFlags.BEFORE_SWAP | HookFlags.AFTER_SWAP;
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
            fee: 3_000,
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

        handler = new BuyOnlyVoteHookHandler(manager, token, hook, swapRouter, key);
        token.transfer(address(handler), 3 * handler.ACTOR_FUNDING());
        handler.fundActors();

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = BuyOnlyVoteHookHandler.warp.selector;
        selectors[1] = BuyOnlyVoteHookHandler.stake.selector;
        selectors[2] = BuyOnlyVoteHookHandler.unstake.selector;
        selectors[3] = BuyOnlyVoteHookHandler.vote.selector;
        selectors[4] = BuyOnlyVoteHookHandler.buy.selector;
        selectors[5] = BuyOnlyVoteHookHandler.sell.selector;
        selectors[6] = BuyOnlyVoteHookHandler.rallyYes.selector;
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

    /// @notice The hook never ends up holding ETH: it charges no fee and takes no delta.
    function invariant_hookNeverHoldsEth() public view {
        assertEq(address(hook).balance, 0);
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

    /// @notice On every day ever touched, sells never exceeded half of the previous day's buys.
    function invariant_soldNeverExceedsTheCap() public view {
        uint256 last = hook.currentDay();
        for (uint256 d = 0; d <= last; d++) {
            uint256 cap = hook.sellCap(d);
            assertLe(hook.sold(d), cap, "sold over cap");
            assertEq(cap, d == 0 ? 0 : hook.bought(d - 1) / 2, "cap is not half of yesterday's buys");
            assertEq(hook.sellRemaining(d), cap - hook.sold(d), "remaining");
        }
    }

    /// @notice Anything sold on a day was sold on a day whose vote passed, and the window was seen open.
    function invariant_sellsHappenOnlyOnVotedDays() public view {
        uint256 last = hook.currentDay();
        for (uint256 d = 0; d <= last; d++) {
            if (hook.sold(d) > 0) {
                assertTrue(hook.votePassed(d), "sold on a day whose vote did not pass");
                assertTrue(handler.ghostWindowSeenOpen(d), "sold on a day whose window was never open");
            }
        }
    }

    /// @notice Internal accounting equals the deltas the swappers actually received or paid.
    function invariant_accountingMatchesSwapDeltas() public view {
        uint256 last = hook.currentDay();
        for (uint256 d = 0; d <= last; d++) {
            assertEq(hook.bought(d), handler.ghostBought(d), "bought vs deltas");
            assertEq(hook.sold(d), handler.ghostSold(d), "sold vs deltas");
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

    /// @notice Runs after every sequence: a campaign that never bought or never tried to sell has exercised
    /// nothing, and the counters make that visible rather than letting the invariants pass vacuously.
    function afterInvariant() public view {
        assertGt(handler.buys(), 0, "no buy happened in this sequence");
        assertGt(handler.sellsDone() + handler.sellsClosed() + handler.sellsOverCap(), 0, "no sell was attempted");
    }
}
