// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolDonateTest} from "v4-core/src/test/PoolDonateTest.sol";

import {BuyOnlyVoteHook} from "../src/BuyOnlyVoteHook.sol";
import {SurfToken} from "../src/SurfToken.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {HookMiner} from "../src/HookMiner.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Adversarial edges the main suite does not reach: boundary seconds, partial fills, rounding,
/// exact-output sells against a spent cap, the netting of buys against today's sells to the wei, the
/// liquidity rule at its two exact boundaries (the rounding tolerance and the remaining cap), donations
/// as a way to dress up a converted position, and the pool operations the hook does not gate. Companion
/// to `BuyOnlyVoteHook.t.sol`; nothing here is duplicated from it.
/// forge-config: default.fuzz.runs = 512
contract BuyOnlyVoteHookEdgesTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 constant FLAGS = HookFlags.BEFORE_INITIALIZE | HookFlags.AFTER_ADD_LIQUIDITY
        | HookFlags.AFTER_REMOVE_LIQUIDITY | HookFlags.BEFORE_SWAP | HookFlags.AFTER_SWAP;
    uint256 constant START = 1_700_000_000;
    /// @dev Storage slots of the hook's mappings, in declaration order (the pool manager is immutable).
    uint256 constant BOUGHT_SLOT = 4;
    uint256 constant POSITIONS_SLOT = 10;

    PoolManager manager;
    SurfToken token;
    BuyOnlyVoteHook hook;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest lpRouter;
    PoolDonateTest donateRouter;
    PoolKey key;
    uint256 q;
    uint256 hookNonce;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    receive() external payable {}

    function setUp() public {
        vm.warp(START);
        manager = new PoolManager(address(this));
        token = new SurfToken();
        hook = deployHook(manager);
        swapRouter = new PoolSwapTest(manager);
        lpRouter = new PoolModifyLiquidityTest(manager);
        donateRouter = new PoolDonateTest(manager);

        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        manager.initialize(key, SQRT_PRICE_1_1);
        q = hook.quorum();

        vm.deal(address(this), 10_000 ether);
        token.approve(address(lpRouter), type(uint256).max);
        token.approve(address(donateRouter), type(uint256).max);
        lpRouter.modifyLiquidity{value: 1_000 ether}(
            key, ModifyLiquidityParams({tickLower: -887_220, tickUpper: 887_220, liquidityDelta: 1_000e18, salt: 0}), ""
        );

        address[3] memory users = [alice, bob, carol];
        for (uint256 i = 0; i < users.length; i++) {
            vm.deal(users[i], 1_000 ether);
            vm.startPrank(users[i]);
            token.approve(address(swapRouter), type(uint256).max);
            token.approve(address(hook), type(uint256).max);
            token.approve(address(lpRouter), type(uint256).max);
            vm.stopPrank();
        }
    }

    // ------------------------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------------------------

    function deployHook(PoolManager pm) internal returns (BuyOnlyVoteHook deployed) {
        bytes memory creationCode = abi.encodePacked(type(BuyOnlyVoteHook).creationCode, abi.encode(pm));
        (address predicted, bytes32 salt) = HookMiner.find(address(this), FLAGS, creationCode, hookNonce++ * 1_000_000);
        deployed = new BuyOnlyVoteHook{salt: salt}(IPoolManager(address(pm)));
        assertEq(address(deployed), predicted, "mined address");
    }

    function warpTo(uint256 day, uint256 secondsInto) internal {
        vm.warp(hook.genesis() + day * 1 days + secondsInto);
    }

    function settings() internal pure returns (PoolSwapTest.TestSettings memory) {
        return PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
    }

    function buy(address user, uint256 ethIn) internal returns (uint256 tokensOut) {
        vm.prank(user);
        BalanceDelta delta = swapRouter.swap{value: ethIn}(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(ethIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            settings(),
            ""
        );
        tokensOut = uint256(int256(delta.amount1()));
    }

    function buyExactTokens(address user, uint256 tokensOut, uint256 ethBudget) internal returns (uint256 ethPaid) {
        vm.prank(user);
        BalanceDelta delta = swapRouter.swap{value: ethBudget}(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: int256(tokensOut), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            settings(),
            ""
        );
        assertEq(uint256(int256(delta.amount1())), tokensOut);
        ethPaid = uint256(int256(-delta.amount0()));
    }

    function sellParams(uint256 tokensIn) internal pure returns (SwapParams memory) {
        return SwapParams({
            zeroForOne: false, amountSpecified: -int256(tokensIn), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });
    }

    function sell(address user, uint256 tokensIn) internal returns (uint256 ethOut) {
        vm.prank(user);
        BalanceDelta delta = swapRouter.swap(key, sellParams(tokensIn), settings(), "");
        ethOut = uint256(int256(delta.amount0()));
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

    function expectSellRevert(address user, SwapParams memory params, bytes memory reason) internal {
        vm.expectRevert(reason);
        vm.prank(user);
        swapRouter.swap(key, params, settings(), "");
    }

    /// @dev Adds `liquidity` for `user` (salt 0) and returns the SURF it deposited.
    function addLiquidity(address user, int24 lower, int24 upper, int256 liquidity, uint256 ethValue)
        internal
        returns (uint256 surfIn)
    {
        vm.deal(user, user.balance + ethValue);
        vm.prank(user);
        BalanceDelta delta = lpRouter.modifyLiquidity{value: ethValue}(
            key, ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: liquidity, salt: 0}), ""
        );
        surfIn = delta.amount1() < 0 ? uint256(int256(-delta.amount1())) : 0;
    }

    /// @dev Removes `liquidity` for `user` (salt 0) and returns the ETH and SURF it paid out.
    function removeLiquidity(address user, int24 lower, int24 upper, int256 liquidity)
        internal
        returns (uint256 ethOut, uint256 surfOut)
    {
        vm.prank(user);
        BalanceDelta delta = lpRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: -liquidity, salt: 0}), ""
        );
        ethOut = delta.amount0() > 0 ? uint256(int256(delta.amount0())) : 0;
        surfOut = delta.amount1() > 0 ? uint256(int256(delta.amount1())) : 0;
    }

    function expectRemoveRevert(address user, int24 lower, int24 upper, int256 liquidity, bytes memory reason)
        internal
    {
        vm.expectRevert(reason);
        vm.prank(user);
        lpRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: -liquidity, salt: 0}), ""
        );
    }

    function lpKey(int24 lower, int24 upper) internal view returns (bytes32) {
        return hook.positionKey(address(lpRouter), lower, upper, 0);
    }

    /// @dev Overwrite `bought[day]`, checking first that the slot really is the one the getter reads.
    function setBought(uint256 day, uint256 value) internal {
        bytes32 slot = keccak256(abi.encode(day, BOUGHT_SLOT));
        assertEq(uint256(vm.load(address(hook), slot)), hook.bought(day), "bought slot");
        vm.store(address(hook), slot, bytes32(value));
        assertEq(hook.bought(day), value);
    }

    /// @dev Overwrite a position's recorded SURF deposit, checking the slot the same way.
    function setSurfIn(bytes32 positionKey, uint256 value) internal {
        bytes32 slot = bytes32(uint256(keccak256(abi.encode(positionKey, POSITIONS_SLOT))) + 1);
        (uint256 liq, uint256 surfIn) = hook.positions(positionKey);
        assertEq(uint256(vm.load(address(hook), slot)), surfIn, "surfIn slot");
        assertEq(uint256(vm.load(address(hook), bytes32(uint256(slot) - 1))), liq, "liquidity slot");
        vm.store(address(hook), slot, bytes32(value));
        (, uint256 after_) = hook.positions(positionKey);
        assertEq(after_, value);
    }

    function fundAndStake(address user, uint256 amount) internal {
        token.transfer(user, amount);
        vm.prank(user);
        hook.stake(amount);
    }

    function stakeAndVote(address user, uint256 amount, bool support) internal {
        fundAndStake(user, amount);
        vm.prank(user);
        hook.vote(support);
    }

    /// @dev Day 0: alice buys; day 1: bob passes the vote; clock left at `secondsInto` of day 1.
    function openDayOneWindow(uint256 ethIn, uint256 secondsInto) internal returns (uint256 out) {
        out = buy(alice, ethIn);
        warpTo(1, 1 hours);
        stakeAndVote(bob, q, true);
        warpTo(1, secondsInto);
    }

    // ------------------------------------------------------------------------------------------
    // Boundary seconds
    // ------------------------------------------------------------------------------------------

    function test_sellWindowOpensAtExactlyTwentyThreeHours() public {
        uint256 out = openDayOneWindow(10 ether, 23 hours - 1);
        assertTrue(hook.votingOpen());
        assertFalse(hook.sellWindowOpen());
        expectSellRevert(
            alice,
            sellParams(1),
            hookRevert(IHooks.beforeSwap.selector, abi.encodeWithSelector(BuyOnlyVoteHook.SellsClosed.selector))
        );

        warpTo(1, 23 hours);
        assertFalse(hook.votingOpen());
        assertTrue(hook.sellWindowOpen());
        uint256 ethOut = sell(alice, out / 2);
        assertGt(ethOut, 0);
        assertEq(hook.sold(1), out / 2);
    }

    function test_voteAcceptedAtFirstSecondOfDayAndRefusedAtTwentyThreeHours() public {
        fundAndStake(bob, q);
        warpTo(1, 0);
        vm.prank(bob);
        hook.vote(true);
        assertEq(hook.yesVotes(1), q);

        fundAndStake(carol, q);
        warpTo(1, 23 hours);
        vm.expectRevert(BuyOnlyVoteHook.VotingClosed.selector);
        vm.prank(carol);
        hook.vote(false);
        // The outcome is settled once the window opens: nobody can flip it from inside the window.
        assertTrue(hook.sellWindowOpen());
    }

    function test_exactOutputSellRevertsWhenClosedBeforeThePoolDoesAnyWork() public {
        buy(alice, 1 ether);
        warpTo(1, 23 hours);
        SwapParams memory exactOut = SwapParams({
            zeroForOne: false, amountSpecified: int256(0.001 ether), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });
        expectSellRevert(
            alice,
            exactOut,
            hookRevert(IHooks.beforeSwap.selector, abi.encodeWithSelector(BuyOnlyVoteHook.SellsClosed.selector))
        );
    }

    function testFuzz_scheduleAtEverySecondOfADay(uint32 secondsInto) public {
        secondsInto = uint32(bound(secondsInto, 0, 1 days - 1));
        uint256 out = buy(alice, 10 ether);
        warpTo(1, 0);
        stakeAndVote(bob, q, true);
        warpTo(1, secondsInto);

        bool voting = secondsInto < 23 hours;
        assertEq(hook.votingOpen(), voting);
        assertEq(hook.sellWindowOpen(), !voting);

        // A fresh staker can vote exactly when voting is open.
        fundAndStake(carol, 1);
        vm.prank(carol);
        if (voting) {
            hook.vote(false);
        } else {
            vm.expectRevert(BuyOnlyVoteHook.VotingClosed.selector);
            hook.vote(false);
        }

        // A sell within the cap passes exactly when the window is open.
        if (voting) {
            expectSellRevert(
                alice,
                sellParams(out / 2),
                hookRevert(IHooks.beforeSwap.selector, abi.encodeWithSelector(BuyOnlyVoteHook.SellsClosed.selector))
            );
        } else {
            sell(alice, out / 2);
            assertEq(hook.sold(1), out / 2);
        }
    }

    // ------------------------------------------------------------------------------------------
    // Partial fills and rounding: what is recorded is what actually moved
    // ------------------------------------------------------------------------------------------

    function test_partiallyFilledSellIsRecordedByTokensActuallyPaid() public {
        uint256 out = openDayOneWindow(10 ether, 23 hours);
        uint256 cap = out / 2;

        // Stop the swap one tick-spacing above the current price: only part of the input is consumed.
        (uint160 sqrtPrice, int24 tick,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        uint160 limit = TickMath.getSqrtPriceAtTick(tick + 60);
        assertGt(limit, sqrtPrice);
        SwapParams memory params =
            SwapParams({zeroForOne: false, amountSpecified: -int256(cap), sqrtPriceLimitX96: limit});

        vm.prank(alice);
        BalanceDelta delta = swapRouter.swap(key, params, settings(), "");
        uint256 paid = uint256(int256(-delta.amount1()));
        assertGt(paid, 0);
        assertLt(paid, cap, "test premise: the price limit must cut the fill short");
        assertEq(hook.sold(1), paid, "sold must count the tokens paid, not the amount requested");
        assertEq(hook.sellRemaining(1), cap - paid);

        // The unconsumed part of the cap is still available to the next seller.
        token.transfer(bob, cap - paid);
        sell(bob, cap - paid);
        assertEq(hook.sellRemaining(1), 0);
    }

    function test_partiallyFilledBuyIsRecordedByTokensActuallyReceived() public {
        (, int24 tick,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        uint160 limit = TickMath.getSqrtPriceAtTick(tick - 60);
        vm.prank(alice);
        BalanceDelta delta = swapRouter.swap{value: 100 ether}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -int256(100 ether), sqrtPriceLimitX96: limit}),
            settings(),
            ""
        );
        uint256 received = uint256(int256(delta.amount1()));
        uint256 ethSpent = uint256(int256(-delta.amount0()));
        assertLt(ethSpent, 100 ether, "test premise: the price limit must cut the fill short");
        assertEq(hook.bought(0), received);
        assertEq(token.balanceOf(alice), received);
        assertEq(alice.balance, 1_000 ether - ethSpent, "unused ETH refunded");
    }

    function test_dustBuyThatYieldsNoTokensRecordsZero() public {
        uint256 out = buy(alice, 1);
        assertEq(out, 0);
        assertEq(hook.bought(0), 0);
        assertEq(hook.sellCap(1), 0);
    }

    function test_sellCapRoundsDownOnOddBuys() public {
        buyExactTokens(alice, 3, 1 ether);
        assertEq(hook.bought(0), 3);
        warpTo(1, 1 hours);
        stakeAndVote(bob, q, true);
        warpTo(1, 23 hours);
        assertEq(hook.sellCap(1), 1);
        expectSellRevert(
            alice,
            sellParams(2),
            hookRevert(
                IHooks.beforeSwap.selector, abi.encodeWithSelector(BuyOnlyVoteHook.SellCapExceeded.selector, 2, 1)
            )
        );
        sell(alice, 1);
        assertEq(hook.sellRemaining(1), 0);
    }

    function test_oneWeiBuyYesterdayGivesNoCapToday() public {
        buyExactTokens(alice, 1, 1 ether);
        warpTo(1, 1 hours);
        stakeAndVote(bob, q, true);
        warpTo(1, 23 hours);
        assertTrue(hook.sellWindowOpen());
        assertEq(hook.sellCap(1), 0);
        expectSellRevert(
            alice,
            sellParams(1),
            hookRevert(
                IHooks.beforeSwap.selector, abi.encodeWithSelector(BuyOnlyVoteHook.SellCapExceeded.selector, 1, 0)
            )
        );
    }

    // ------------------------------------------------------------------------------------------
    // The cap once spent: exact-output sells cannot squeeze through afterSwap
    // ------------------------------------------------------------------------------------------

    function test_exactOutputSellAgainstASpentCapFailsInAfterSwap() public {
        uint256 out = openDayOneWindow(10 ether, 23 hours);
        sell(alice, out / 2);
        assertEq(hook.sellRemaining(1), 0);

        SwapParams memory params =
            SwapParams({zeroForOne: false, amountSpecified: int256(1), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1});
        vm.prank(alice);
        (bool ok, bytes memory err) =
            address(swapRouter).call(abi.encodeCall(swapRouter.swap, (key, params, settings(), "")));
        assertFalse(ok, "a 1-wei exact-output sell got through a spent cap");

        // Unwrap the ERC-7751 error: it must come from afterSwap and say the remaining cap is zero.
        assertEq(bytes4(err), CustomRevert.WrappedError.selector);
        bytes memory body = new bytes(err.length - 4);
        for (uint256 i = 0; i < body.length; i++) {
            body[i] = err[i + 4];
        }
        (address target, bytes4 callback, bytes memory reason,) = abi.decode(body, (address, bytes4, bytes, bytes));
        assertEq(target, address(hook));
        assertEq(callback, IHooks.afterSwap.selector);
        assertEq(bytes4(reason), BuyOnlyVoteHook.SellCapExceeded.selector);
        bytes memory reasonBody = new bytes(reason.length - 4);
        for (uint256 i = 0; i < reasonBody.length; i++) {
            reasonBody[i] = reason[i + 4];
        }
        (uint256 requested, uint256 remaining) = abi.decode(reasonBody, (uint256, uint256));
        assertGt(requested, 0);
        assertEq(remaining, 0);
        assertEq(hook.sold(1), out / 2, "a failed sell must not be recorded");
    }

    function testFuzz_sequenceOfSellsNeverPassesTheCap(uint256 a, uint256 b, uint256 c) public {
        uint256 out = openDayOneWindow(20 ether, 23 hours);
        uint256 cap = out / 2;
        a = bound(a, 1, cap);
        b = bound(b, 1, cap);
        c = bound(c, 1, cap);
        uint256[3] memory amounts = [a, b, c];
        uint256 soldSoFar;
        for (uint256 i = 0; i < 3; i++) {
            uint256 remaining = cap - soldSoFar;
            if (amounts[i] > remaining) {
                expectSellRevert(
                    alice,
                    sellParams(amounts[i]),
                    hookRevert(
                        IHooks.beforeSwap.selector,
                        abi.encodeWithSelector(BuyOnlyVoteHook.SellCapExceeded.selector, amounts[i], remaining)
                    )
                );
            } else {
                sell(alice, amounts[i]);
                soldSoFar += amounts[i];
            }
            assertEq(hook.sold(1), soldSoFar);
            assertLe(hook.sold(1), cap);
        }
    }

    // ------------------------------------------------------------------------------------------
    // Interactions between buys and sells inside a window
    // ------------------------------------------------------------------------------------------

    function test_buyDuringTheSellWindowCountsTowardTomorrowsCap() public {
        uint256 out0 = buy(alice, 4 ether);
        warpTo(1, 1 hours);
        stakeAndVote(bob, q, true);
        warpTo(1, 23 hours + 30 minutes);
        uint256 out1 = buy(carol, 4 ether);
        assertEq(hook.bought(1), out1);
        assertEq(hook.sellCap(1), out0 / 2, "today's cap is unaffected by today's buys");

        warpTo(2, 1 hours);
        vm.prank(bob);
        hook.vote(true);
        assertEq(hook.sellCap(2), out1 / 2, "tomorrow's cap counts the window-hour buy");
    }

    /// @dev The netting rule, to the wei: a buy inside the window cancels today's sells first, and only
    /// the excess is a buy for tomorrow's cap.
    function testFuzz_aBuyInsideTheWindowCancelsTodaysSellsFirst(uint96 sellSeed, uint96 buySeed) public {
        uint256 out = openDayOneWindow(10 ether, 23 hours);
        uint256 cap = out / 2;
        uint256 sellAmount = bound(sellSeed, 1, cap);
        uint256 buyAmount = bound(buySeed, 1, 2 * cap);
        sell(alice, sellAmount);
        assertEq(hook.sold(1), sellAmount);
        buyExactTokens(carol, buyAmount, 100 ether);

        uint256 cancelled = buyAmount < sellAmount ? buyAmount : sellAmount;
        assertEq(hook.sold(1), sellAmount - cancelled, "sold is reduced by the buy, never below zero");
        assertEq(hook.bought(1), buyAmount - cancelled, "only the excess is a buy");
        assertEq(hook.sellRemaining(1), cap - (sellAmount - cancelled));
        assertEq(hook.sellCap(2), (buyAmount - cancelled) / 2, "tomorrow's cap is half of the net buy");
    }

    function test_buyExactlyEqualToTodaysSellsZeroesBothCounters() public {
        uint256 out = openDayOneWindow(10 ether, 23 hours);
        uint256 cap = out / 2;
        sell(alice, cap);
        buyExactTokens(carol, cap, 100 ether);
        assertEq(hook.sold(1), 0);
        assertEq(hook.bought(1), 0);
        assertEq(hook.sellRemaining(1), cap);
        assertEq(hook.sellCap(2), 0);
        // The next wei bought is a real buy.
        buyExactTokens(carol, 1, 1 ether);
        assertEq(hook.bought(1), 1);
        assertEq(hook.sold(1), 0);
    }

    function test_buyOneWeiShortOfTodaysSellsLeavesOneWeiSold() public {
        uint256 out = openDayOneWindow(10 ether, 23 hours);
        uint256 cap = out / 2;
        sell(alice, cap);
        buyExactTokens(carol, cap - 1, 100 ether);
        assertEq(hook.sold(1), 1);
        assertEq(hook.bought(1), 0);
        assertEq(hook.sellRemaining(1), cap - 1);
        // Exactly one more wei can still be sold today, and not two.
        expectSellRevert(
            alice,
            sellParams(cap),
            hookRevert(
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(BuyOnlyVoteHook.SellCapExceeded.selector, cap, cap - 1)
            )
        );
        sell(alice, cap - 1);
        assertEq(hook.sellRemaining(1), 0);
    }

    function test_buysOutsideTheWindowNeverCancelAnything() public {
        uint256 out = openDayOneWindow(10 ether, 23 hours);
        sell(alice, out / 4);
        // The window closes at midnight; what was sold on day 1 stays sold, and day 2 starts clean.
        warpTo(2, 0);
        uint256 rebought = buy(carol, 1 ether);
        assertEq(hook.sold(1), out / 4, "yesterday's sells are final");
        assertEq(hook.sold(2), 0);
        assertEq(hook.bought(2), rebought, "a buy outside a window counts in full");
    }

    /// @dev Characterisation of the netting rule's limit (see REVIEW.md, "Residual"): with matching buys
    /// between them, several sellers can each sell the whole cap in one window. The net sell stays
    /// capped; the gross volume is not. This is the accepted design, recorded here so that it is visible.
    function test_grossSellsInsideAWindowAreBoundedOnlyNetOfBuys() public {
        uint256 out = openDayOneWindow(10 ether, 23 hours);
        uint256 cap = out / 2;
        token.transfer(bob, cap);
        token.transfer(carol, cap);
        address[3] memory sellers = [alice, bob, carol];
        for (uint256 i = 0; i < sellers.length; i++) {
            sell(sellers[i], cap);
            assertEq(hook.sellRemaining(1), 0);
            if (i + 1 < sellers.length) buyExactTokens(sellers[i], cap, 100 ether);
        }
        assertEq(hook.sold(1), cap, "net sells are at the cap");
        assertEq(hook.bought(1), 0, "the matching buys were all cancellations");
        assertEq(hook.sellCap(2), 0);
    }

    function test_hookHoldsNoEthAndOnlyStakedTokensAfterTrading() public {
        uint256 out = openDayOneWindow(10 ether, 23 hours);
        sell(alice, out / 2);
        buy(carol, 1 ether);
        assertEq(address(hook).balance, 0);
        assertEq(token.balanceOf(address(hook)), hook.staked(bob));
        assertEq(manager.balanceOf(address(hook), 0), 0, "no ETH claims");
        assertEq(manager.balanceOf(address(hook), uint256(uint160(address(token)))), 0, "no SURF claims");
    }

    function test_hookDataIsIgnored() public {
        bytes memory junk = abi.encode(address(this), uint256(123), "open sesame");
        vm.prank(alice);
        BalanceDelta delta = swapRouter.swap{value: 1 ether}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            settings(),
            junk
        );
        uint256 out = uint256(int256(delta.amount1()));
        assertEq(hook.bought(0), out);

        warpTo(1, 23 hours);
        vm.expectRevert(
            hookRevert(IHooks.beforeSwap.selector, abi.encodeWithSelector(BuyOnlyVoteHook.SellsClosed.selector))
        );
        vm.prank(alice);
        swapRouter.swap(key, sellParams(out / 2), settings(), junk);
    }

    // ------------------------------------------------------------------------------------------
    // Votes and stakes: weight snapshots, locks on both sides, no-majority blocking
    // ------------------------------------------------------------------------------------------

    function test_noVotersAreLockedForTheDayToo() public {
        warpTo(1, 1 hours);
        stakeAndVote(bob, q, false);
        vm.expectRevert(BuyOnlyVoteHook.StakeLockedByVote.selector);
        vm.prank(bob);
        hook.unstake(1);
        warpTo(2, 0);
        vm.prank(bob);
        hook.unstake(q);
        assertEq(hook.staked(bob), 0);
    }

    function test_aSingleLargeNoVoteKeepsSellsClosed() public {
        uint256 out = buy(alice, 10 ether);
        warpTo(1, 1 hours);
        stakeAndVote(bob, q, true);
        stakeAndVote(carol, q + 1, false);
        assertFalse(hook.votePassed(1));
        warpTo(1, 23 hours);
        expectSellRevert(
            alice,
            sellParams(out / 2),
            hookRevert(IHooks.beforeSwap.selector, abi.encodeWithSelector(BuyOnlyVoteHook.SellsClosed.selector))
        );
    }

    function test_voteWeightIsTheStakeAtVoteTimeAfterAPartialUnstake() public {
        warpTo(1, 1 hours);
        stakeAndVote(bob, q, true);
        warpTo(2, 0);
        vm.prank(bob);
        hook.unstake(q / 2);
        vm.prank(bob);
        hook.vote(true);
        assertEq(hook.yesVotes(2), q - q / 2);
        assertFalse(hook.votePassed(2), "half the quorum does not pass");
    }

    function test_unstakeBetweenWindowsThenRestakeFromAnotherWalletVotesOncePerDay() public {
        warpTo(1, 1 hours);
        stakeAndVote(bob, q, true);
        assertEq(hook.yesVotes(1), q);

        // Day 2: bob can leave at 0:00, hand the tokens to carol, and carol votes with them: still one vote
        // per stake per day.
        warpTo(2, 0);
        vm.prank(bob);
        hook.unstake(q);
        vm.prank(bob);
        token.transfer(carol, q);
        vm.prank(carol);
        hook.stake(q);
        vm.prank(carol);
        hook.vote(true);
        assertEq(hook.yesVotes(2), q);
        vm.expectRevert(BuyOnlyVoteHook.NothingStaked.selector);
        vm.prank(bob);
        hook.vote(true);
        vm.expectRevert(BuyOnlyVoteHook.StakeLockedByVote.selector);
        vm.prank(carol);
        hook.unstake(1);
    }

    function test_lastVoteDayForAnAccountThatNeverVoted() public view {
        (bool voted, uint256 day) = hook.lastVoteDay(alice);
        assertFalse(voted);
        assertEq(day, 0);
    }

    function testFuzz_voteWeightIsExactlyTheStakeWhenVoting(uint128 before, uint128 after_) public {
        before = uint128(bound(before, 1, 5e25));
        after_ = uint128(bound(after_, 1, 5e25));
        warpTo(1, 1 hours);
        stakeAndVote(bob, before, true);
        fundAndStake(bob, after_);
        assertEq(hook.yesVotes(1), before);
        assertEq(hook.staked(bob), uint256(before) + after_);
        assertEq(hook.votePassed(1), uint256(before) >= q);
    }

    // ------------------------------------------------------------------------------------------
    // Quorum derivation
    // ------------------------------------------------------------------------------------------

    function test_quorumIsOnePercentOfTheBoundTokensSupplyAtInitialization() public {
        PoolManager pm = new PoolManager(address(this));
        BuyOnlyVoteHook fresh = deployHook(pm);
        MockERC20 small = new MockERC20("S", "S", 12_345);
        PoolKey memory k = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(small)),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(fresh))
        });
        pm.initialize(k, SQRT_PRICE_1_1);
        assertEq(fresh.quorum(), 123);
        assertEq(address(fresh.token()), address(small));
    }

    /// @dev Not reachable with SurfToken (fixed 10^27 supply); recorded because the rule degenerates for
    /// any token with fewer than 100 minor units: a single 1-wei yes vote passes.
    function test_quorumIsZeroForATinySupplyAndOneWeiPasses() public {
        PoolManager pm = new PoolManager(address(this));
        BuyOnlyVoteHook fresh = deployHook(pm);
        MockERC20 tiny = new MockERC20("T", "T", 99);
        PoolKey memory k = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(tiny)),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(fresh))
        });
        pm.initialize(k, SQRT_PRICE_1_1);
        assertEq(fresh.quorum(), 0);
        tiny.approve(address(fresh), 1);
        fresh.stake(1);
        fresh.vote(true);
        assertTrue(fresh.votePassed(0));
    }

    // ------------------------------------------------------------------------------------------
    // Pool operations the hook does not gate
    // ------------------------------------------------------------------------------------------

    function test_donationsAreNotGatedAndNotCounted() public {
        warpTo(3, 12 hours);
        donateRouter.donate{value: 1 ether}(key, 1 ether, 1 ether, "");
        assertEq(hook.bought(3), 0);
        assertEq(hook.sold(3), 0);
    }

    // ------------------------------------------------------------------------------------------
    // Liquidity removals at the exact boundaries of the rule
    // ------------------------------------------------------------------------------------------

    /// @dev A removal may fall short of the recorded deposit by exactly the tolerance for free; one wei
    /// more is a sell. The deposit record is set directly so the boundary is hit exactly, since the pool's
    /// own rounding only ever produces a wei or two.
    function test_lpRoundingToleranceIsExactlyOneMillionWei() public {
        token.transfer(carol, 1_000 ether);
        uint256 surfIn = addLiquidity(carol, -600, 600, 10e18, 10 ether);
        bytes32 k = lpKey(-600, 600);
        uint256 tolerance = hook.LP_ROUNDING_TOLERANCE();
        assertEq(tolerance, 1e6);

        // Measure what the untouched position pays back (a wei or two under the deposit).
        warpTo(2, 12 hours);
        assertFalse(hook.sellWindowOpen());
        uint256 snapshot = vm.snapshotState();
        (, uint256 surfOut) = removeLiquidity(carol, -600, 600, 10e18);
        assertLe(surfIn - surfOut, 2, "test premise: rounding is tiny");
        assertEq(hook.sold(2), 0);
        vm.revertToState(snapshot);

        // Shortfall == tolerance: free, even with the window closed.
        setSurfIn(k, surfOut + tolerance);
        snapshot = vm.snapshotState();
        removeLiquidity(carol, -600, 600, 10e18);
        assertEq(hook.sold(2), 0, "a shortfall of exactly the tolerance is not a sell");
        (uint256 liq, uint256 rec) = hook.positions(k);
        assertEq(liq, 0);
        assertEq(rec, 0);
        vm.revertToState(snapshot);

        // Shortfall == tolerance + 1: a sell, so refused while closed...
        setSurfIn(k, surfOut + tolerance + 1);
        expectRemoveRevert(
            carol,
            -600,
            600,
            10e18,
            hookRevert(
                IHooks.afterRemoveLiquidity.selector, abi.encodeWithSelector(BuyOnlyVoteHook.SellsClosed.selector)
            )
        );
        // ...and charged in full, not just the part over the tolerance, once a window with cap is open.
        stakeAndVote(bob, q, true);
        warpTo(2, 23 hours);
        setBought(1, 4 * (tolerance + 1));
        removeLiquidity(carol, -600, 600, 10e18);
        assertEq(hook.sold(2), tolerance + 1);
    }

    /// @dev The cap boundary for a liquidity sell: a shortfall equal to what remains passes, one wei over
    /// is refused with the exact figures.
    function test_lpShortfallExactlyAtTheRemainingCapPassesAndOneWeiOverFails() public {
        token.transfer(carol, 1_000 ether);
        uint256 parked = addLiquidity(carol, -120, -60, 50e18, 0);
        buy(alice, 20 ether);
        (, int24 tick,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertLt(tick, -120, "test premise: the range is entirely ETH, so the whole deposit is the shortfall");
        warpTo(1, 1 hours);
        stakeAndVote(bob, q, true);
        warpTo(1, 23 hours);

        setBought(0, 2 * parked - 2);
        assertEq(hook.sellCap(1), parked - 1);
        expectRemoveRevert(
            carol,
            -120,
            -60,
            50e18,
            hookRevert(
                IHooks.afterRemoveLiquidity.selector,
                abi.encodeWithSelector(BuyOnlyVoteHook.SellCapExceeded.selector, parked, parked - 1)
            )
        );
        assertEq(hook.sold(1), 0, "a refused removal records nothing");

        setBought(0, 2 * parked);
        assertEq(hook.sellCap(1), parked);
        (uint256 ethOut, uint256 surfOut) = removeLiquidity(carol, -120, -60, 50e18);
        assertGt(ethOut, 0);
        assertEq(surfOut, 0);
        assertEq(hook.sold(1), parked);
        assertEq(hook.sellRemaining(1), 0);
    }

    /// @dev A liquidity charge is `sold` like any other and is netted by a later buy the same way.
    function test_aLiquidityChargeIsCancelledByABuyLikeASwapSell() public {
        token.transfer(carol, 1_000 ether);
        uint256 parked = addLiquidity(carol, -120, -60, 50e18, 0);
        buy(alice, 20 ether);
        warpTo(1, 1 hours);
        stakeAndVote(bob, q, true);
        warpTo(1, 23 hours);
        uint256 cap = hook.sellCap(1);
        assertGt(cap, parked, "test premise: the cap can take the position");

        removeLiquidity(carol, -120, -60, 50e18);
        assertEq(hook.sold(1), parked);
        buyExactTokens(bob, parked, 100 ether);
        assertEq(hook.sold(1), 0);
        assertEq(hook.bought(1), 0);
        assertEq(hook.sellRemaining(1), cap);
    }

    /// @dev SURF donated to a partly converted position comes back out as fees. It must not count as the
    /// position's own SURF: the shortfall is measured on principal, so the removal is still a sell.
    function test_donatedSurfDoesNotMaskAnLpShortfall() public {
        token.transfer(carol, 1_000 ether);
        uint256 surfIn = addLiquidity(carol, -120, -60, 5e18, 0);
        bytes32 k = lpKey(-120, -60);

        // Buy down to tick -90: half the position has turned into ETH and it is still in range.
        vm.prank(alice);
        swapRouter.swap{value: 100 ether}(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(-90)
            }),
            settings(),
            ""
        );
        (, int24 tick,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertTrue(tick >= -120 && tick < -60, "test premise: the position is in range");

        // What the principal alone pays back now (measured with the deposit record cleared, then undone).
        uint256 snapshot = vm.snapshotState();
        setSurfIn(k, 0);
        (, uint256 principalOut) = removeLiquidity(carol, -120, -60, 5e18);
        vm.revertToState(snapshot);
        uint256 shortfall = surfIn - principalOut;
        assertGt(shortfall, hook.LP_ROUNDING_TOLERANCE(), "test premise: a real shortfall");

        // Donate SURF: the in-range position accrues it as fees.
        donateRouter.donate(key, 0, 10 ether, "");

        // Outside a window the removal is still a sell.
        assertFalse(hook.sellWindowOpen());
        expectRemoveRevert(
            carol,
            -120,
            -60,
            5e18,
            hookRevert(
                IHooks.afterRemoveLiquidity.selector, abi.encodeWithSelector(BuyOnlyVoteHook.SellsClosed.selector)
            )
        );

        // Inside one, the charge is the principal shortfall; the donation is paid out on top, uncharged.
        warpTo(1, 1 hours);
        stakeAndVote(bob, q, true);
        warpTo(1, 23 hours);
        setBought(0, 4 * shortfall);
        (, uint256 surfOut) = removeLiquidity(carol, -120, -60, 5e18);
        assertGt(surfOut, principalOut, "the donated fees were paid out");
        assertEq(hook.sold(1), shortfall, "charged on principal only");
    }

    /// @dev A position that is removed and re-opened starts a fresh deposit record; nothing from the old
    /// life (charged or not) carries over.
    function test_reopenedPositionStartsAFreshRecord() public {
        token.transfer(carol, 1_000 ether);
        bytes32 k = lpKey(-120, -60);
        uint256 first = addLiquidity(carol, -120, -60, 50e18, 0);
        buy(alice, 20 ether);
        warpTo(1, 1 hours);
        stakeAndVote(bob, q, true);
        warpTo(1, 23 hours);
        removeLiquidity(carol, -120, -60, 50e18);
        assertEq(hook.sold(1), first);
        (uint256 liq, uint256 rec) = hook.positions(k);
        assertEq(liq, 0);
        assertEq(rec, 0);

        // The range is now entirely ETH, so re-opening it deposits ETH only: the record stays at zero
        // SURF and a later removal is free, whatever the window says.
        uint256 second = addLiquidity(carol, -120, -60, 50e18, 10 ether);
        assertEq(second, 0);
        (liq, rec) = hook.positions(k);
        assertEq(liq, 50e18);
        assertEq(rec, 0);
        warpTo(3, 12 hours);
        assertFalse(hook.sellWindowOpen());
        (uint256 ethOut,) = removeLiquidity(carol, -120, -60, 50e18);
        assertGt(ethOut, 0);
        assertEq(hook.sold(3), 0);
    }
}
