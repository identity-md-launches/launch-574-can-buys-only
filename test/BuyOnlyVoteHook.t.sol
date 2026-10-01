// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
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
    uint160 constant FLAGS = HookFlags.BEFORE_INITIALIZE | HookFlags.AFTER_ADD_LIQUIDITY
        | HookFlags.AFTER_REMOVE_LIQUIDITY | HookFlags.BEFORE_SWAP | HookFlags.AFTER_SWAP;
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
            fee: 0,
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
            token.approve(address(lpRouter), type(uint256).max);
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

    /// @dev Exact-output buy of `tokensOut` SURF, paying at most `maxEth`; the router refunds the rest.
    function buyExactOut(address user, uint256 tokensOut, uint256 maxEth) internal returns (uint256 received) {
        vm.prank(user);
        BalanceDelta delta = swapRouter.swap{value: maxEth}(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: int256(tokensOut), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        received = uint256(int256(delta.amount1()));
    }

    /// @dev Adds `liquidity` for `user` (salt 0) and returns the SURF it deposited.
    function addLiquidity(address user, int24 lower, int24 upper, int256 liquidity, uint256 ethValue)
        internal
        returns (uint256 surfIn)
    {
        if (user != address(this)) {
            vm.deal(user, user.balance + ethValue);
            vm.prank(user);
        }
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
        if (user != address(this)) vm.prank(user);
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
        assertTrue(p.afterAddLiquidity);
        assertTrue(p.afterRemoveLiquidity);
        assertTrue(p.beforeSwap);
        assertTrue(p.afterSwap);
        assertFalse(p.afterInitialize);
        assertFalse(p.beforeAddLiquidity);
        assertFalse(p.beforeRemoveLiquidity);
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
            fee: 0,
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

    function test_initializeRefusesAFeeBearingPool() public {
        BuyOnlyVoteHook fresh = deployHook(manager);
        PoolKey memory feeKey = key;
        feeKey.hooks = IHooks(address(fresh));
        feeKey.fee = 3_000;
        vm.expectRevert(
            hookRevert(
                address(fresh),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(BuyOnlyVoteHook.FeeMustBeZero.selector)
            )
        );
        manager.initialize(feeKey, SQRT_PRICE_1_1);

        // A dynamic-fee key is refused too: the hook overrides no fee, so only a literal zero is "no fees".
        feeKey.fee = LPFeeLibrary.DYNAMIC_FEE_FLAG;
        vm.expectRevert(
            hookRevert(
                address(fresh),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(BuyOnlyVoteHook.FeeMustBeZero.selector)
            )
        );
        manager.initialize(feeKey, SQRT_PRICE_1_1);
        assertEq(fresh.genesis(), 0);

        feeKey.fee = 0;
        manager.initialize(feeKey, SQRT_PRICE_1_1);
        assertEq(fresh.genesis(), block.timestamp);
    }

    function test_zeroFeePoolAccruesNoLpFees() public {
        buy(alice, 10 ether);
        // Collecting fees on the seed position (liquidityDelta 0) yields nothing.
        BalanceDelta collected = lpRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: -887_220, tickUpper: 887_220, liquidityDelta: 0, salt: 0}), ""
        );
        assertEq(collected.amount0(), 0);
        assertEq(collected.amount1(), 0);
    }

    function test_callbacksRefuseCallersOtherThanThePoolManager() public {
        ModifyLiquidityParams memory lp = ModifyLiquidityParams(-60, 60, 1 ether, 0);

        vm.expectRevert(BuyOnlyVoteHook.NotPoolManager.selector);
        hook.beforeInitialize(address(this), key, SQRT_PRICE_1_1);

        vm.expectRevert(BuyOnlyVoteHook.NotPoolManager.selector);
        hook.afterAddLiquidity(address(this), key, lp, BalanceDelta.wrap(0), BalanceDelta.wrap(0), "");

        lp.liquidityDelta = -1 ether;
        vm.expectRevert(BuyOnlyVoteHook.NotPoolManager.selector);
        hook.afterRemoveLiquidity(address(this), key, lp, BalanceDelta.wrap(0), BalanceDelta.wrap(0), "");

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
        hook.beforeRemoveLiquidity(address(this), key, lp, "");
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
            fee: 0,
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

        // Ask for more ETH than half the tokens can buy: the pool computes the input, afterSwap refuses.
        SwapParams memory params = SwapParams({
            zeroForOne: false, amountSpecified: int256(6 ether), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
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
    // Sells netted against buys inside the window
    // ------------------------------------------------------------------------------------------

    function test_sellAndRebuyInsideTheWindowFreesTheCapForOthers() public {
        buy(alice, 10 ether);
        buy(carol, 12 ether);
        warpTo(1, 1 hours);
        stakeAndVote(bob, quorum(), true);
        warpTo(1, 23 hours);
        uint256 cap = hook.sellCap(1);

        // Carol sells the whole cap and immediately buys the same amount back.
        uint256 carolSurf = token.balanceOf(carol);
        sell(carol, cap);
        assertEq(hook.sellRemaining(1), 0);
        buyExactOut(carol, cap, 100 ether);
        assertEq(token.balanceOf(carol), carolSurf, "carol is flat in SURF");

        // The cap is free again for everybody else, and the round trip did not count as a buy.
        assertEq(hook.sold(1), 0);
        assertEq(hook.sellRemaining(1), cap);
        assertEq(hook.bought(1), 0, "a rebuy that cancels a sell is not a new buy");
        uint256 ethOut = sell(alice, 0.001e18);
        assertGt(ethOut, 0);
        assertEq(hook.sold(1), 0.001e18);
    }

    function test_repeatedSellAndRebuyCyclesCannotRaiseTomorrowsCap() public {
        buy(alice, 10 ether);
        warpTo(1, 1 hours);
        stakeAndVote(bob, quorum(), true);
        warpTo(1, 23 hours);
        uint256 cap = hook.sellCap(1);
        token.transfer(carol, cap);

        for (uint256 i = 0; i < 5; i++) {
            sell(carol, cap);
            buyExactOut(carol, cap, 100 ether);
        }
        assertEq(hook.bought(1), 0);
        assertEq(hook.sold(1), 0);
        assertEq(hook.sellCap(2), 0);
    }

    function test_buyLargerThanTodaysSellsCountsOnlyTheExcess() public {
        buy(alice, 10 ether);
        warpTo(1, 1 hours);
        stakeAndVote(bob, quorum(), true);
        warpTo(1, 23 hours);
        uint256 soldAmount = hook.sellCap(1) / 2;
        sell(alice, soldAmount);
        assertEq(hook.sold(1), soldAmount);

        uint256 out = buyExactOut(carol, soldAmount + 1 ether, 100 ether);
        assertEq(out, soldAmount + 1 ether);
        assertEq(hook.sold(1), 0);
        assertEq(hook.bought(1), 1 ether);
        assertEq(hook.sellCap(2), 0.5 ether);
    }

    function test_buysOutsideTheWindowAreCountedInFull() public {
        uint256 out = buy(alice, 3 ether);
        assertEq(hook.bought(0), out);
        assertEq(hook.sold(0), 0);
    }

    // ------------------------------------------------------------------------------------------
    // Liquidity: additions are free, removals that return less SURF than deposited are sells
    // ------------------------------------------------------------------------------------------

    function test_lpPositionCannotSellSurfOutsideTheWindow() public {
        // Day 0: the holder buys some SURF.
        uint256 out = buy(carol, 1 ether);
        warpTo(2, 1 hours);
        assertFalse(hook.sellWindowOpen());
        assertEq(hook.sellCap(2), 0);

        // Park it as SURF-only liquidity just below the price: a resting sell order.
        uint256 surfIn = addLiquidity(carol, -120, -60, 50e18, 0);
        assertLe(surfIn, out);
        (uint256 liq, uint256 recorded) = hook.positions(hook.positionKey(address(lpRouter), -120, -60, 0));
        assertEq(liq, 50e18);
        assertEq(recorded, surfIn);

        // A buy crosses the range and converts the parked SURF into ETH inside the position.
        buy(alice, 20 ether);

        // Withdrawing the ETH is a sell, and sells are closed.
        expectRemoveRevert(
            carol,
            -120,
            -60,
            50e18,
            hookRevert(
                address(hook),
                IHooks.afterRemoveLiquidity.selector,
                abi.encodeWithSelector(BuyOnlyVoteHook.SellsClosed.selector)
            )
        );
        assertEq(hook.sold(2), 0);
    }

    function test_lpPositionSellIsChargedAgainstTheCapInsideTheWindow() public {
        token.transfer(carol, 1_000 ether);
        uint256 surfIn = addLiquidity(carol, -120, -60, 50e18, 0);
        buy(alice, 20 ether); // crosses the range; day 0 buys are large
        warpTo(1, 1 hours);
        stakeAndVote(bob, quorum(), true);
        warpTo(1, 23 hours);
        uint256 cap = hook.sellCap(1);
        assertGt(cap, surfIn);

        uint256 ethBefore = carol.balance;
        vm.expectEmit(true, true, true, false, address(hook));
        emit BuyOnlyVoteHook.LiquiditySold(1, address(lpRouter), hook.positionKey(address(lpRouter), -120, -60, 0), 0);
        (uint256 ethOut, uint256 surfOut) = removeLiquidity(carol, -120, -60, 50e18);
        assertGt(ethOut, 0);
        assertEq(surfOut, 0);
        assertEq(carol.balance, ethBefore + ethOut);
        assertEq(hook.sold(1), surfIn, "the whole deposit became ETH, so the whole deposit is charged");
        assertEq(hook.sellRemaining(1), cap - surfIn);
        (uint256 liq, uint256 recorded) = hook.positions(hook.positionKey(address(lpRouter), -120, -60, 0));
        assertEq(liq, 0);
        assertEq(recorded, 0);
    }

    function test_lpPositionSellOverTheRemainingCapIsRefused() public {
        token.transfer(carol, 1_000 ether);
        uint256 surfIn = addLiquidity(carol, -120, -60, 50e18, 0);
        buy(alice, 20 ether);
        warpTo(1, 1 hours);
        stakeAndVote(bob, quorum(), true);
        warpTo(1, 23 hours);

        // Swappers use up most of the cap first.
        uint256 cap = hook.sellCap(1);
        uint256 leave = surfIn / 2;
        sell(alice, cap - leave);
        assertEq(hook.sellRemaining(1), leave);

        expectRemoveRevert(
            carol,
            -120,
            -60,
            50e18,
            hookRevert(
                address(hook),
                IHooks.afterRemoveLiquidity.selector,
                abi.encodeWithSelector(BuyOnlyVoteHook.SellCapExceeded.selector, surfIn, leave)
            )
        );

        // Half the position fits in what is left (proportional attribution).
        (, uint256 surfOut) = removeLiquidity(carol, -120, -60, 25e18);
        assertEq(surfOut, 0);
        assertEq(hook.sold(1), cap - leave + leave, "cap fully used");
        assertEq(hook.sellRemaining(1), 0);
    }

    function test_unchangedLiquidityCanBeRemovedAtAnyTime() public {
        addLiquidity(address(this), -600, 600, 10e18, 10 ether);
        warpTo(5, 12 hours);
        assertFalse(hook.sellWindowOpen());
        (uint256 ethOut, uint256 surfOut) = removeLiquidity(address(this), -600, 600, 10e18);
        assertGt(ethOut, 0);
        assertGt(surfOut, 0);
        (uint256 liq, uint256 recorded) = hook.positions(hook.positionKey(address(lpRouter), -600, 600, 0));
        assertEq(liq, 0);
        assertEq(recorded, 0);
    }

    function test_partialRemovalsOfAnUnchangedPositionAreNotSells() public {
        uint256 surfIn = addLiquidity(address(this), -600, 600, 10e18, 10 ether);
        warpTo(3, 12 hours);
        (, uint256 out1) = removeLiquidity(address(this), -600, 600, 3e18);
        (, uint256 out2) = removeLiquidity(address(this), -600, 600, 3e18);
        (, uint256 out3) = removeLiquidity(address(this), -600, 600, 4e18);
        assertApproxEqAbs(out1 + out2 + out3, surfIn, 10);
        assertEq(hook.sold(3), 0);
    }

    function test_lpPositionThatGainedSurfIsNotCharged() public {
        token.transfer(carol, 1_000 ether);
        // Day 0: alice buys, then carol provides two-sided liquidity around the (lower) price.
        buy(alice, 10 ether);
        uint256 surfIn = addLiquidity(carol, -600, 600, 100e18, 100 ether);
        // Day 1: a voted window; alice sells within the cap, pushing the price up through carol's range,
        // which converts some of carol's ETH into SURF.
        warpTo(1, 1 hours);
        stakeAndVote(bob, quorum(), true);
        warpTo(1, 23 hours);
        sell(alice, hook.sellCap(1));
        // Day 2, sells closed: carol can still withdraw, her position holds more SURF than she put in.
        warpTo(2, 12 hours);
        (, uint256 surfOut) = removeLiquidity(carol, -600, 600, 100e18);
        assertGt(surfOut, surfIn);
        assertEq(hook.sold(2), 0);
    }

    function test_feeCollectionOnAConvertedPositionIsNotCharged() public {
        token.transfer(carol, 1_000 ether);
        addLiquidity(carol, -120, -60, 50e18, 0);
        buy(alice, 20 ether);
        warpTo(2, 1 hours);
        // liquidityDelta == 0 moves no principal; the pool has no fee, so nothing is collected either.
        vm.prank(carol);
        BalanceDelta collected = lpRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: -120, tickUpper: -60, liquidityDelta: 0, salt: 0}), ""
        );
        assertEq(collected.amount0(), 0);
        assertEq(collected.amount1(), 0);
    }

    function test_lpCannotInflateTheCapAndRecoverTheEthForFree() public {
        token.transfer(carol, 1_000 ether);
        // Carol parks SURF below the price, then buys through her own range with her own ETH.
        uint256 parked = addLiquidity(carol, -120, -60, 50e18, 0);
        uint256 out = buy(carol, 20 ether);
        assertEq(hook.bought(0), out, "the buy counts like any other buy");
        // Tomorrow's cap grew, but the ETH that landed in her position can only leave as a sell.
        warpTo(1, 1 hours);
        stakeAndVote(bob, quorum(), true);
        assertFalse(hook.sellWindowOpen());
        expectRemoveRevert(
            carol,
            -120,
            -60,
            50e18,
            hookRevert(
                address(hook),
                IHooks.afterRemoveLiquidity.selector,
                abi.encodeWithSelector(BuyOnlyVoteHook.SellsClosed.selector)
            )
        );
        warpTo(1, 23 hours);
        removeLiquidity(carol, -120, -60, 50e18);
        assertEq(hook.sold(1), parked, "recovering the ETH consumed the cap it helped create");
    }

    function test_addingLiquidityToAConvertedPositionIsTrackedProportionally() public {
        token.transfer(carol, 1_000 ether);
        uint256 first = addLiquidity(carol, -120, -60, 50e18, 0);
        buy(alice, 20 ether); // the range is now entirely ETH
        // Adding to the same position now needs ETH only; the recorded SURF deposit does not change.
        uint256 second = addLiquidity(carol, -120, -60, 50e18, 1 ether);
        assertEq(second, 0);
        (uint256 liq, uint256 recorded) = hook.positions(hook.positionKey(address(lpRouter), -120, -60, 0));
        assertEq(liq, 100e18);
        assertEq(recorded, first);

        warpTo(1, 1 hours);
        stakeAndVote(bob, quorum(), true);
        warpTo(1, 23 hours);
        // Removing half attributes half of the deposit; removing the rest attributes the rest.
        removeLiquidity(carol, -120, -60, 50e18);
        assertEq(hook.sold(1), first / 2);
        removeLiquidity(carol, -120, -60, 50e18);
        assertEq(hook.sold(1), first / 2 + (first - first / 2));
    }

    function test_positionsOfDifferentOwnersAndSaltsAreSeparate() public {
        token.transfer(carol, 1_000 ether);
        uint256 inA = addLiquidity(carol, -120, -60, 50e18, 0);
        vm.prank(carol);
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -120, tickUpper: -60, liquidityDelta: 50e18, salt: bytes32(uint256(1))}),
            ""
        );
        (uint256 liqA, uint256 recA) = hook.positions(hook.positionKey(address(lpRouter), -120, -60, 0));
        (uint256 liqB, uint256 recB) =
            hook.positions(hook.positionKey(address(lpRouter), -120, -60, bytes32(uint256(1))));
        assertEq(liqA, 50e18);
        assertEq(liqB, 50e18);
        assertEq(recA, inA);
        assertEq(recB, inA);
        (uint256 liqOther,) = hook.positions(hook.positionKey(address(this), -120, -60, 0));
        assertEq(liqOther, 0);
    }

    function test_launchStyleSeedIsAcceptedOnAFreshManagerAndCanBeWithdrawnInAWindow() public {
        // The launch seeds SURF-only liquidity below the price and no ETH at all; that must be accepted.
        PoolManager freshManager = new PoolManager(address(this));
        BuyOnlyVoteHook freshHook = deployHook(freshManager);
        PoolModifyLiquidityTest freshLp = new PoolModifyLiquidityTest(freshManager);
        PoolSwapTest freshSwap = new PoolSwapTest(freshManager);
        PoolKey memory freshKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(freshHook))
        });
        freshManager.initialize(freshKey, SQRT_PRICE_1_1);
        token.approve(address(freshLp), type(uint256).max);
        BalanceDelta seeded = freshLp.modifyLiquidity(
            freshKey, ModifyLiquidityParams({tickLower: -60_000, tickUpper: -60, liquidityDelta: 1_000e18, salt: 0}), ""
        );
        uint256 surfSeeded = uint256(int256(-seeded.amount1()));
        assertGt(surfSeeded, 0);

        // A buyer converts part of the seed into ETH. Withdrawing the seed outside a window is refused.
        vm.prank(alice);
        freshSwap.swap{value: 1 ether}(
            freshKey,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.expectRevert(
            hookRevert(
                address(freshHook),
                IHooks.afterRemoveLiquidity.selector,
                abi.encodeWithSelector(BuyOnlyVoteHook.SellsClosed.selector)
            )
        );
        freshLp.modifyLiquidity(
            freshKey,
            ModifyLiquidityParams({tickLower: -60_000, tickUpper: -60, liquidityDelta: -1_000e18, salt: 0}),
            ""
        );
    }

    // ------------------------------------------------------------------------------------------
    // Fuzz: liquidity
    // ------------------------------------------------------------------------------------------

    function testFuzz_removingAnUntouchedPositionIsNeverASell(uint128 liquidity, uint8 lowerSteps, uint8 width) public {
        liquidity = uint128(bound(liquidity, 1e12, 1e21));
        int24 lower = -int24(uint24(bound(lowerSteps, 1, 200))) * 60;
        int24 upper = lower + int24(uint24(bound(width, 1, 200))) * 60;
        vm.deal(address(this), 100_000 ether);
        uint256 ethNeeded = upper > 0 ? 1_000 ether : 0;
        uint256 surfIn = addLiquidity(address(this), lower, upper, int256(uint256(liquidity)), ethNeeded);
        warpTo(4, 5 hours);
        assertFalse(hook.sellWindowOpen());
        (, uint256 surfOut) = removeLiquidity(address(this), lower, upper, int256(uint256(liquidity)));
        assertLe(surfIn, surfOut + hook.LP_ROUNDING_TOLERANCE());
        assertEq(hook.sold(4), 0);
    }

    function testFuzz_lpShortfallIsChargedExactly(uint128 liquidity, uint96 ethIn) public {
        token.transfer(carol, 1e24);
        liquidity = uint128(bound(liquidity, 1e15, 1e21));
        ethIn = uint96(bound(ethIn, 1 ether, 500 ether));
        uint256 surfIn = addLiquidity(carol, -120, -60, int256(uint256(liquidity)), 0);
        buy(alice, ethIn);
        warpTo(1, 1 hours);
        stakeAndVote(bob, quorum(), true);
        warpTo(1, 23 hours);
        uint256 cap = hook.sellCap(1);
        // Make sure the cap can take the whole position so the charge itself is what is tested.
        vm.store(address(hook), boughtSlot(0), bytes32(uint256(type(uint128).max)));
        cap = hook.sellCap(1);
        (, uint256 surfOut) = removeLiquidity(carol, -120, -60, int256(uint256(liquidity)));
        uint256 expected = surfIn > surfOut + hook.LP_ROUNDING_TOLERANCE() ? surfIn - surfOut : 0;
        assertEq(hook.sold(1), expected);
        assertEq(hook.sellRemaining(1), cap - expected);
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
