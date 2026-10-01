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
import {MockERC20} from "./mocks/MockERC20.sol";

contract BuyOnlyVoteHookTest is Test {
    using PoolIdLibrary for PoolKey;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 constant FLAGS = HookFlags.BEFORE_INITIALIZE | HookFlags.BEFORE_SWAP | HookFlags.AFTER_SWAP;
    uint256 constant START = 1_700_000_000;

    PoolManager manager;
    SurfToken token;
    BuyOnlyVoteHook hook;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest lpRouter;
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

        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: 3_000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        manager.initialize(key, SQRT_PRICE_1_1);
        q = hook.quorum();

        vm.deal(address(this), 10_000 ether);
        token.approve(address(lpRouter), type(uint256).max);
        lpRouter.modifyLiquidity{value: 1_000 ether}(
            key, ModifyLiquidityParams({tickLower: -887_220, tickUpper: 887_220, liquidityDelta: 1_000e18, salt: 0}), ""
        );

        address[3] memory users = [alice, bob, carol];
        for (uint256 i = 0; i < users.length; i++) {
            vm.deal(users[i], 1_000 ether);
            vm.startPrank(users[i]);
            token.approve(address(swapRouter), type(uint256).max);
            token.approve(address(hook), type(uint256).max);
            vm.stopPrank();
        }
    }

    // ------------------------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------------------------

    function deployHook(PoolManager pm) internal returns (BuyOnlyVoteHook deployed) {
        bytes memory creationCode = abi.encodePacked(type(BuyOnlyVoteHook).creationCode, abi.encode(pm));
        // Each deployment starts its salt search further along so two hooks for one manager never collide.
        (address predicted, bytes32 salt) = HookMiner.find(address(this), FLAGS, creationCode, hookNonce++ * 1_000_000);
        deployed = new BuyOnlyVoteHook{salt: salt}(IPoolManager(address(pm)));
        assertEq(address(deployed), predicted, "mined address");
    }

    function warpTo(uint256 day, uint256 secondsInto) internal {
        vm.warp(hook.genesis() + day * 1 days + secondsInto);
    }

    function buy(address user, uint256 ethIn) internal returns (uint256 tokensOut) {
        vm.prank(user);
        BalanceDelta delta = swapRouter.swap{value: ethIn}(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(ethIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        tokensOut = uint256(int256(delta.amount1()));
    }

    function sellParams(uint256 tokensIn) internal pure returns (SwapParams memory) {
        return SwapParams({
            zeroForOne: false, amountSpecified: -int256(tokensIn), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });
    }

    function sell(address user, uint256 tokensIn) internal returns (uint256 ethOut) {
        vm.prank(user);
        BalanceDelta delta = swapRouter.swap(
            key, sellParams(tokensIn), PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), ""
        );
        ethOut = uint256(int256(delta.amount0()));
    }

    function expectSellRevert(address user, uint256 tokensIn, bytes memory reason) internal {
        vm.expectRevert(reason);
        vm.prank(user);
        swapRouter.swap(
            key, sellParams(tokensIn), PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), ""
        );
    }

    /// @dev The ERC-7751 wrapper the pool manager puts around a hook revert.
    function hookRevert(address target, bytes4 callback, bytes memory reason) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            target,
            callback,
            reason,
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    function fundAndStake(address user, uint256 amount) internal {
        token.transfer(user, amount);
        vm.prank(user);
        hook.stake(amount);
    }

    /// @dev Stake `amount` for `user` and vote during the voting hours of the current day.
    function stakeAndVote(address user, uint256 amount, bool support) internal {
        fundAndStake(user, amount);
        vm.prank(user);
        hook.vote(support);
    }

    /// @dev Cached in `setUp`: an external view call inside a pranked call's arguments would consume the prank.
    function quorum() internal view returns (uint256) {
        return q;
    }

    // ------------------------------------------------------------------------------------------
    // Deployment and initialization
    // ------------------------------------------------------------------------------------------

    function test_addressCarriesExactlyTheDeclaredFlags() public view {
        assertEq(HookFlags.flagsOf(address(hook)), FLAGS);
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeInitialize);
        assertTrue(p.beforeSwap);
        assertTrue(p.afterSwap);
        assertFalse(p.afterInitialize);
        assertFalse(p.beforeAddLiquidity);
        assertFalse(p.afterAddLiquidity);
        assertFalse(p.beforeRemoveLiquidity);
        assertFalse(p.afterRemoveLiquidity);
        assertFalse(p.beforeDonate);
        assertFalse(p.afterDonate);
        assertFalse(p.beforeSwapReturnDelta);
        assertFalse(p.afterSwapReturnDelta);
        assertFalse(p.afterAddLiquidityReturnDelta);
        assertFalse(p.afterRemoveLiquidityReturnDelta);
    }

    function test_constructorRejectsAddressWithWrongFlags() public {
        vm.expectRevert();
        new BuyOnlyVoteHook(IPoolManager(address(manager)));
    }

    function test_initializeBindsThePool() public view {
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(address(hook.token()), address(token));
        assertEq(PoolId.unwrap(hook.poolId()), PoolId.unwrap(key.toId()));
        assertEq(hook.genesis(), START);
        assertEq(hook.quorum(), token.TOTAL_SUPPLY() / 100);
        assertEq(hook.currentDay(), 0);
        assertEq(hook.secondsIntoDay(), 0);
        assertTrue(hook.votingOpen());
        assertFalse(hook.sellWindowOpen());
    }

    function test_initializeRefusesASecondPool() public {
        PoolKey memory other = key;
        other.fee = 500;
        other.tickSpacing = 10;
        vm.expectRevert(
            hookRevert(
                address(hook),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(BuyOnlyVoteHook.AlreadyInitialized.selector)
            )
        );
        manager.initialize(other, SQRT_PRICE_1_1);
    }

    function test_initializeRefusesAPoolWhoseCurrency0IsNotNative() public {
        BuyOnlyVoteHook fresh = deployHook(manager);
        MockERC20 a = new MockERC20("A", "A", 1e24);
        MockERC20 b = new MockERC20("B", "B", 1e24);
        (address lo, address hi) = address(a) < address(b) ? (address(a), address(b)) : (address(b), address(a));
        PoolKey memory erc20Key = PoolKey({
            currency0: Currency.wrap(lo),
            currency1: Currency.wrap(hi),
            fee: 3_000,
            tickSpacing: 60,
            hooks: IHooks(address(fresh))
        });
        vm.expectRevert(
            hookRevert(
                address(fresh),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(BuyOnlyVoteHook.Currency0MustBeNative.selector)
            )
        );
        manager.initialize(erc20Key, SQRT_PRICE_1_1);
        assertEq(fresh.genesis(), 0);
    }

    function test_callbacksRefuseCallersOtherThanThePoolManager() public {
        vm.expectRevert(BuyOnlyVoteHook.NotPoolManager.selector);
        hook.beforeInitialize(address(this), key, SQRT_PRICE_1_1);

        vm.expectRevert(BuyOnlyVoteHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, sellParams(1 ether), "");

        vm.expectRevert(BuyOnlyVoteHook.NotPoolManager.selector);
        hook.afterSwap(address(this), key, sellParams(1 ether), BalanceDelta.wrap(0), "");
    }

    function test_undeclaredCallbacksRevert() public {
        ModifyLiquidityParams memory lp = ModifyLiquidityParams(-60, 60, 1 ether, 0);
        bytes4 err = BuyOnlyVoteHook.HookNotImplemented.selector;

        vm.expectRevert(err);
        hook.afterInitialize(address(this), key, SQRT_PRICE_1_1, 0);
        vm.expectRevert(err);
        hook.beforeAddLiquidity(address(this), key, lp, "");
        vm.expectRevert(err);
        hook.afterAddLiquidity(address(this), key, lp, BalanceDelta.wrap(0), BalanceDelta.wrap(0), "");
        vm.expectRevert(err);
        hook.beforeRemoveLiquidity(address(this), key, lp, "");
        vm.expectRevert(err);
        hook.afterRemoveLiquidity(address(this), key, lp, BalanceDelta.wrap(0), BalanceDelta.wrap(0), "");
        vm.expectRevert(err);
        hook.beforeDonate(address(this), key, 1, 1, "");
        vm.expectRevert(err);
        hook.afterDonate(address(this), key, 1, 1, "");
    }

    // ------------------------------------------------------------------------------------------
    // Buys
    // ------------------------------------------------------------------------------------------

    function test_buyIsAlwaysAllowedAndRecorded() public {
        uint256 out1 = buy(alice, 1 ether);
        assertGt(out1, 0);
        assertEq(token.balanceOf(alice), out1);
        assertEq(hook.bought(0), out1);

        // Still a buy at the end of the day, with no vote at all.
        warpTo(0, 23 hours + 30 minutes);
        assertFalse(hook.sellWindowOpen());
        uint256 out2 = buy(bob, 2 ether);
        assertEq(hook.bought(0), out1 + out2);

        // A new day starts a new counter.
        warpTo(1, 1);
        uint256 out3 = buy(carol, 0.5 ether);
        assertEq(hook.bought(1), out3);
        assertEq(hook.bought(0), out1 + out2);
    }

    function test_exactOutputBuyIsRecordedByTokensReceived() public {
        vm.prank(alice);
        BalanceDelta delta = swapRouter.swap{value: 5 ether}(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: int256(1 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        assertEq(uint256(int256(delta.amount1())), 1 ether);
        assertEq(hook.bought(0), 1 ether);
    }

    function test_buyEmitsBought() public {
        vm.expectEmit(true, true, false, false, address(hook));
        emit BuyOnlyVoteHook.Bought(0, address(swapRouter), 0);
        buy(alice, 1 ether);
    }

    function test_buyOnAFreshPoolSeededWithTokensOnly() public {
        PoolManager freshManager = new PoolManager(address(this));
        BuyOnlyVoteHook freshHook = deployHook(freshManager);
        PoolSwapTest freshSwap = new PoolSwapTest(freshManager);
        PoolModifyLiquidityTest freshLp = new PoolModifyLiquidityTest(freshManager);
        PoolKey memory freshKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: 3_000,
            tickSpacing: 60,
            hooks: IHooks(address(freshHook))
        });
        freshManager.initialize(freshKey, SQRT_PRICE_1_1);

        // Token-only liquidity strictly below the current price (buys push the price down through it):
        // the manager holds no ETH at all.
        token.approve(address(freshLp), type(uint256).max);
        freshLp.modifyLiquidity(
            freshKey, ModifyLiquidityParams({tickLower: -60_000, tickUpper: -60, liquidityDelta: 1_000e18, salt: 0}), ""
        );
        assertEq(address(freshManager).balance, 0);

        vm.prank(alice);
        BalanceDelta delta = freshSwap.swap{value: 1 ether}(
            freshKey,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        uint256 out = uint256(int256(delta.amount1()));
        assertGt(out, 0);
        assertEq(freshHook.bought(0), out);
        assertEq(address(freshManager).balance, 1 ether);
    }

    // ------------------------------------------------------------------------------------------
    // Sells: closed by default
    // ------------------------------------------------------------------------------------------

    function test_sellRevertsWhenNoVoteWasHeld() public {
        uint256 out = buy(alice, 1 ether);
        warpTo(1, 23 hours + 1);
        assertFalse(hook.sellWindowOpen());
        expectSellRevert(
            alice,
            out / 2,
            hookRevert(
                address(hook), IHooks.beforeSwap.selector, abi.encodeWithSelector(BuyOnlyVoteHook.SellsClosed.selector)
            )
        );
        assertEq(token.balanceOf(alice), out);
    }

    function test_sellRevertsDuringVotingHoursEvenWhenTheVoteHasPassed() public {
        uint256 out = buy(alice, 1 ether);
        warpTo(1, 1 hours);
        stakeAndVote(bob, quorum(), true);
        assertTrue(hook.votePassed(1));
        assertFalse(hook.sellWindowOpen());
        expectSellRevert(
            alice,
            out / 4,
            hookRevert(
                address(hook), IHooks.beforeSwap.selector, abi.encodeWithSelector(BuyOnlyVoteHook.SellsClosed.selector)
            )
        );
    }

    function test_sellRevertsOnceTheWindowHasClosed() public {
        uint256 out = buy(alice, 1 ether);
        warpTo(1, 1 hours);
        stakeAndVote(bob, quorum(), true);
        warpTo(1, 23 hours + 59 minutes + 59 seconds);
        assertTrue(hook.sellWindowOpen());
        warpTo(2, 0);
        assertFalse(hook.sellWindowOpen());
        expectSellRevert(
            alice,
            out / 4,
            hookRevert(
                address(hook), IHooks.beforeSwap.selector, abi.encodeWithSelector(BuyOnlyVoteHook.SellsClosed.selector)
            )
        );
    }

    function test_dayZeroHasNoSellCapEvenIfTheVotePasses() public {
        uint256 out = buy(alice, 1 ether);
        stakeAndVote(bob, quorum(), true);
        warpTo(0, 23 hours + 1);
        assertTrue(hook.sellWindowOpen());
        assertEq(hook.sellCap(0), 0);
        expectSellRevert(
            alice,
            out / 2,
            hookRevert(
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(BuyOnlyVoteHook.SellCapExceeded.selector, out / 2, 0)
            )
        );
    }

    // ------------------------------------------------------------------------------------------
    // Sells: open after a successful vote, capped at half of yesterday's buys
    // ------------------------------------------------------------------------------------------

    function test_sellAllowedUpToHalfOfPreviousDayBuys() public {
        uint256 out = buy(alice, 10 ether);
        warpTo(1, 2 hours);
        stakeAndVote(bob, quorum(), true);
        warpTo(1, 23 hours + 10 minutes);

        uint256 cap = out / 2;
        assertEq(hook.sellCap(1), cap);
        assertEq(hook.sellRemaining(1), cap);

        uint256 ethBefore = alice.balance;
        uint256 ethOut = sell(alice, cap);
        assertGt(ethOut, 0);
        assertEq(alice.balance, ethBefore + ethOut);
        assertEq(token.balanceOf(alice), out - cap);
        assertEq(hook.sold(1), cap);
        assertEq(hook.sellRemaining(1), 0);

        expectSellRevert(
            alice,
            1,
            hookRevert(
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(BuyOnlyVoteHook.SellCapExceeded.selector, 1, 0)
            )
        );
    }

    function test_sellCapIsSharedAcrossSellers() public {
        uint256 outA = buy(alice, 4 ether);
        uint256 outB = buy(bob, 4 ether);
        warpTo(1, 2 hours);
        stakeAndVote(carol, quorum(), true);
        warpTo(1, 23 hours);

        uint256 cap = (outA + outB) / 2;
        uint256 first = (cap * 60) / 100;
        sell(alice, first);
        sell(bob, cap - first);
        assertEq(hook.sellRemaining(1), 0);
        expectSellRevert(
            bob,
            1,
            hookRevert(
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(BuyOnlyVoteHook.SellCapExceeded.selector, 1, 0)
            )
        );
    }

    function test_exactInputSellOverTheCapFailsBeforeTheSwap() public {
        uint256 out = buy(alice, 10 ether);
        warpTo(1, 2 hours);
        stakeAndVote(bob, quorum(), true);
        warpTo(1, 23 hours);
        uint256 cap = out / 2;
        expectSellRevert(
            alice,
            cap + 1,
            hookRevert(
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(BuyOnlyVoteHook.SellCapExceeded.selector, cap + 1, cap)
            )
        );
    }

    function test_exactOutputSellIsCappedByTheTokensActuallyPaid() public {
        uint256 out = buy(alice, 10 ether);
        warpTo(1, 2 hours);
        stakeAndVote(bob, quorum(), true);
        warpTo(1, 23 hours);
        uint256 cap = out / 2;

        // Ask for far more ETH than half the tokens can buy: the pool computes the input, afterSwap refuses.
        SwapParams memory params = SwapParams({
            zeroForOne: false, amountSpecified: int256(5 ether), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });
        vm.expectRevert();
        vm.prank(alice);
        swapRouter.swap(key, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");

        // A small exact-output sell goes through and is recorded by the tokens paid.
        params.amountSpecified = int256(0.01 ether);
        vm.prank(alice);
        BalanceDelta delta =
            swapRouter.swap(key, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");
        uint256 paid = uint256(int256(-delta.amount1()));
        assertGt(paid, 0);
        assertLe(paid, cap);
        assertEq(hook.sold(1), paid);
    }

    function test_exactOutputSellOverTheCapRevertsInAfterSwap() public {
        uint256 out = buy(alice, 10 ether);
        warpTo(1, 2 hours);
        stakeAndVote(bob, quorum(), true);
        warpTo(1, 23 hours);
        uint256 cap = out / 2;

        // Quote the exact-output sell first (reverting snapshot) to learn the token input it needs.
        SwapParams memory params = SwapParams({
            zeroForOne: false, amountSpecified: int256(10 ether), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });
        uint256 snapshot = vm.snapshotState();
        // Temporarily lift the cap by pretending yesterday's buys were huge, to get the pool's quote.
        vm.store(address(hook), boughtSlot(0), bytes32(uint256(type(uint128).max)));
        vm.prank(alice);
        token.approve(address(swapRouter), type(uint256).max);
        token.transfer(alice, 100 ether);
        vm.prank(alice);
        BalanceDelta quoted =
            swapRouter.swap(key, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");
        uint256 needed = uint256(int256(-quoted.amount1()));
        vm.revertToState(snapshot);
        assertGt(needed, cap, "test premise: the sell needs more than the cap");

        token.transfer(alice, 100 ether);
        vm.expectRevert(
            hookRevert(
                address(hook),
                IHooks.afterSwap.selector,
                abi.encodeWithSelector(BuyOnlyVoteHook.SellCapExceeded.selector, needed, cap)
            )
        );
        vm.prank(alice);
        swapRouter.swap(key, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");
    }

    /// @dev Storage slot of `bought[day]`: `bought` is the 5th declared storage variable (slot 4).
    function boughtSlot(uint256 day) internal pure returns (bytes32) {
        return keccak256(abi.encode(day, uint256(4)));
    }

    function test_sellEmitsSold() public {
        uint256 out = buy(alice, 1 ether);
        warpTo(1, 2 hours);
        stakeAndVote(bob, quorum(), true);
        warpTo(1, 23 hours);
        vm.expectEmit(true, true, false, true, address(hook));
        emit BuyOnlyVoteHook.Sold(1, address(swapRouter), out / 2);
        sell(alice, out / 2);
    }

    function test_eachDayNeedsItsOwnVote() public {
        uint256 out0 = buy(alice, 10 ether);
        warpTo(1, 1 hours);
        stakeAndVote(bob, quorum(), true);
        warpTo(1, 23 hours);
        sell(alice, out0 / 4);

        // Day 2: yesterday (day 1) had no buys, and nobody voted.
        warpTo(2, 23 hours);
        assertFalse(hook.sellWindowOpen());
        expectSellRevert(
            alice,
            1,
            hookRevert(
                address(hook), IHooks.beforeSwap.selector, abi.encodeWithSelector(BuyOnlyVoteHook.SellsClosed.selector)
            )
        );

        // Day 2 buys, day 3 vote, day 3 window: cap is half of day 2's buys only.
        uint256 out2 = buy(carol, 2 ether);
        warpTo(3, 1 hours);
        vm.prank(bob);
        hook.vote(true);
        warpTo(3, 23 hours);
        assertEq(hook.sellCap(3), out2 / 2);
        sell(alice, out2 / 2);
        assertEq(hook.sellRemaining(3), 0);
    }

    // ------------------------------------------------------------------------------------------
    // Voting
    // ------------------------------------------------------------------------------------------

    function test_voteFailsBelowQuorum() public {
        buy(alice, 1 ether);
        warpTo(1, 1 hours);
        stakeAndVote(bob, quorum() - 1, true);
        assertFalse(hook.votePassed(1));
        warpTo(1, 23 hours);
        assertFalse(hook.sellWindowOpen());
    }

    function test_votePassesAtExactlyQuorum() public {
        warpTo(1, 1 hours);
        stakeAndVote(bob, quorum(), true);
        assertTrue(hook.votePassed(1));
    }

    function test_voteFailsOnTieOrNoMajority() public {
        warpTo(1, 1 hours);
        stakeAndVote(bob, quorum(), true);
        stakeAndVote(carol, quorum(), false);
        assertFalse(hook.votePassed(1), "tie");

        warpTo(2, 1 hours);
        vm.prank(carol);
        hook.vote(false);
        stakeAndVote(alice, 1, true);
        assertFalse(hook.votePassed(2), "no majority");
        assertEq(hook.yesVotes(2), 1);
        assertEq(hook.noVotes(2), quorum());
    }

    function test_quorumCountsBothSidesButMajorityDecides() public {
        warpTo(1, 1 hours);
        stakeAndVote(bob, quorum() / 2 + 1, true);
        stakeAndVote(carol, quorum() / 2, false);
        assertGe(hook.yesVotes(1) + hook.noVotes(1), quorum());
        assertTrue(hook.votePassed(1));
    }

    function test_voteRevertsOutsideVotingHours() public {
        fundAndStake(bob, quorum());
        warpTo(1, 23 hours);
        vm.expectRevert(BuyOnlyVoteHook.VotingClosed.selector);
        vm.prank(bob);
        hook.vote(true);

        warpTo(1, 23 hours - 1);
        vm.prank(bob);
        hook.vote(true);
        assertEq(hook.yesVotes(1), quorum());
    }

    function test_voteRevertsTwiceInOneDay() public {
        warpTo(1, 1 hours);
        stakeAndVote(bob, quorum(), true);
        vm.expectRevert(BuyOnlyVoteHook.AlreadyVoted.selector);
        vm.prank(bob);
        hook.vote(false);
        (bool voted, uint256 day) = hook.lastVoteDay(bob);
        assertTrue(voted);
        assertEq(day, 1);
    }

    function test_voteRevertsWithNothingStaked() public {
        vm.expectRevert(BuyOnlyVoteHook.NothingStaked.selector);
        vm.prank(bob);
        hook.vote(true);
    }

    function test_stakeAddedAfterVotingDoesNotCountUntilTheNextDay() public {
        warpTo(1, 1 hours);
        stakeAndVote(bob, 1, true);
        fundAndStake(bob, quorum());
        assertEq(hook.yesVotes(1), 1);
        assertFalse(hook.votePassed(1));

        warpTo(2, 1 hours);
        vm.prank(bob);
        hook.vote(true);
        assertEq(hook.yesVotes(2), quorum() + 1);
    }

    function test_stakeAndVoteRevertBeforeInitialization() public {
        BuyOnlyVoteHook fresh = deployHook(manager);
        vm.expectRevert(BuyOnlyVoteHook.NotInitialized.selector);
        fresh.stake(1);
        vm.expectRevert(BuyOnlyVoteHook.NotInitialized.selector);
        fresh.vote(true);
        vm.expectRevert(BuyOnlyVoteHook.NotInitialized.selector);
        fresh.currentDay();
    }

    function test_stakeRejectsZero() public {
        vm.expectRevert(BuyOnlyVoteHook.ZeroAmount.selector);
        vm.prank(bob);
        hook.stake(0);
    }

    // ------------------------------------------------------------------------------------------
    // Staking
    // ------------------------------------------------------------------------------------------

    function test_stakeMovesTokensAndUnstakeReturnsThem() public {
        fundAndStake(bob, 5 ether);
        assertEq(token.balanceOf(address(hook)), 5 ether);
        assertEq(hook.staked(bob), 5 ether);
        assertEq(token.balanceOf(bob), 0);

        vm.prank(bob);
        hook.unstake(2 ether);
        assertEq(hook.staked(bob), 3 ether);
        assertEq(token.balanceOf(bob), 2 ether);
        assertEq(token.balanceOf(address(hook)), 3 ether);
    }

    function test_unstakeIsLockedForTheRestOfADayAfterVoting() public {
        warpTo(1, 1 hours);
        stakeAndVote(bob, quorum(), true);

        vm.expectRevert(BuyOnlyVoteHook.StakeLockedByVote.selector);
        vm.prank(bob);
        hook.unstake(1);

        warpTo(1, 23 hours + 30 minutes);
        vm.expectRevert(BuyOnlyVoteHook.StakeLockedByVote.selector);
        vm.prank(bob);
        hook.unstake(1);

        warpTo(2, 0);
        vm.prank(bob);
        hook.unstake(quorum());
        assertEq(hook.staked(bob), 0);
        assertEq(token.balanceOf(bob), quorum());
    }

    function test_unstakeRejectsMoreThanStakedAndZero() public {
        fundAndStake(bob, 1 ether);
        vm.expectRevert(BuyOnlyVoteHook.InsufficientStake.selector);
        vm.prank(bob);
        hook.unstake(1 ether + 1);
        vm.expectRevert(BuyOnlyVoteHook.ZeroAmount.selector);
        vm.prank(bob);
        hook.unstake(0);
    }

    function test_aStakeCannotVoteTwiceByMovingBetweenAccounts() public {
        warpTo(1, 1 hours);
        stakeAndVote(bob, quorum(), true);
        // Bob cannot pull the stake out to re-stake it from Carol today.
        vm.expectRevert(BuyOnlyVoteHook.StakeLockedByVote.selector);
        vm.prank(bob);
        hook.unstake(quorum());
        assertEq(hook.yesVotes(1), quorum());
    }

    // ------------------------------------------------------------------------------------------
    // Liquidity is not gated
    // ------------------------------------------------------------------------------------------

    function test_liquidityCanBeAddedAndRemovedAtAnyTime() public {
        lpRouter.modifyLiquidity{value: 10 ether}(
            key, ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 10e18, salt: 0}), ""
        );
        warpTo(5, 12 hours);
        lpRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: -10e18, salt: 0}), ""
        );
    }

    // ------------------------------------------------------------------------------------------
    // Fuzz
    // ------------------------------------------------------------------------------------------

    function testFuzz_dayAndWindowArithmetic(uint32 elapsed) public {
        vm.warp(START + elapsed);
        assertEq(hook.currentDay(), uint256(elapsed) / 1 days);
        assertEq(hook.secondsIntoDay(), uint256(elapsed) % 1 days);
        assertEq(hook.votingOpen(), uint256(elapsed) % 1 days < 23 hours);
        // Nobody voted, so the window is never open.
        assertFalse(hook.sellWindowOpen());
    }

    function testFuzz_sellCapIsHalfOfYesterdaysBuys(uint96 ethIn, uint96 overshoot) public {
        ethIn = uint96(bound(ethIn, 0.001 ether, 100 ether));
        uint256 out = buy(alice, ethIn);
        uint256 cap = out / 2;
        overshoot = uint96(bound(overshoot, 1, 1e24));

        warpTo(1, 1 hours);
        stakeAndVote(bob, quorum(), true);
        warpTo(1, 23 hours);
        assertEq(hook.sellCap(1), cap);

        // More than the cap is refused, exactly the cap is accepted, then nothing more.
        expectSellRevert(
            alice,
            cap + overshoot,
            hookRevert(
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(BuyOnlyVoteHook.SellCapExceeded.selector, cap + overshoot, cap)
            )
        );
        if (cap > 0) {
            sell(alice, cap);
            assertEq(hook.sold(1), cap);
            assertEq(hook.sellRemaining(1), 0);
            expectSellRevert(
                alice,
                1,
                hookRevert(
                    address(hook),
                    IHooks.beforeSwap.selector,
                    abi.encodeWithSelector(BuyOnlyVoteHook.SellCapExceeded.selector, 1, 0)
                )
            );
        }
    }

    function testFuzz_voteOutcome(uint128 yes, uint128 no) public {
        uint256 q = quorum();
        yes = uint128(bound(yes, 0, 2 * q));
        no = uint128(bound(no, 0, 2 * q));
        warpTo(1, 1 hours);
        if (yes > 0) stakeAndVote(bob, yes, true);
        if (no > 0) stakeAndVote(carol, no, false);
        bool expected = uint256(yes) > uint256(no) && uint256(yes) + uint256(no) >= q;
        assertEq(hook.votePassed(1), expected);
        warpTo(1, 23 hours);
        assertEq(hook.sellWindowOpen(), expected);
    }

    function testFuzz_stakeUnstakeConservesTokens(uint128 amountA, uint128 amountB) public {
        amountA = uint128(bound(amountA, 1, 1e26));
        amountB = uint128(bound(amountB, 1, 1e26));
        fundAndStake(bob, amountA);
        fundAndStake(carol, amountB);
        assertEq(token.balanceOf(address(hook)), uint256(amountA) + amountB);
        vm.prank(bob);
        hook.unstake(amountA);
        vm.prank(carol);
        hook.unstake(amountB);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(token.balanceOf(bob), amountA);
        assertEq(token.balanceOf(carol), amountB);
    }
}
