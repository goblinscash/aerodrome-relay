// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.19;

import "src/Relay.sol";
import "src/Registry.sol";
import "src/autoConverter/AutoConverter.sol";
import "src/autoConverter/AutoConverterFactory.sol";

import "@velodrome/test/BaseTest.sol";

contract AutoConverterTest is BaseTest {
    uint256 tokenId;
    uint256 mTokenId;

    AutoConverterFactory autoConverterFactory;
    AutoConverter autoConverter;
    Registry keeperRegistry;
    LockedManagedReward lockedManagedReward;
    FreeManagedReward freeManagedReward;

    address[] bribes;
    address[] fees;
    address[][] tokensToClaim;
    address[] tokensToSwap;
    uint256[] slippages;
    address[] recipients;

    constructor() {
        deploymentType = Deployment.FORK;
    }

    function _setUp() public override {
        // create managed veNFT
        vm.prank(escrow.allowedManager());
        mTokenId = escrow.createManagedLockFor(address(owner));
        lockedManagedReward = LockedManagedReward(escrow.managedToLocked(mTokenId));
        freeManagedReward = FreeManagedReward(escrow.managedToFree(mTokenId));

        vm.startPrank(address(owner));

        // Create normal veNFT and deposit into managed
        deal(address(VELO), address(owner), TOKEN_1);
        VELO.approve(address(escrow), TOKEN_1);
        tokenId = escrow.createLock(TOKEN_1, MAXTIME);

        skipToNextEpoch(1 hours + 1);
        voter.depositManaged(tokenId, mTokenId);

        keeperRegistry = new Registry(new address[](0));
        // Create auto converter
        autoConverterFactory = new AutoConverterFactory(
            address(forwarder),
            address(voter),
            address(router),
            address(keeperRegistry)
        );
        escrow.approve(address(autoConverterFactory), mTokenId);
        autoConverter = AutoConverter(
            autoConverterFactory.createRelay(address(owner), mTokenId, "AutoConverter", abi.encode(address(USDC)))
        );

        skipToNextEpoch(1 hours + 1);

        vm.stopPrank();

        // Add the owner as a keeper
        vm.prank(escrow.team());
        keeperRegistry.approve(address(owner));

        // Create a VELO pool for USDC, WETH, and FRAX (seen as OP in CompoundOptimizer)
        deal(address(VELO), address(owner), TOKEN_100K * 3);
        deal(address(WETH), address(owner), TOKEN_1 * 3);

        // @dev these pools have a higher VELO price value than v1 pools
        _createPoolAndSimulateSwaps(address(USDC), address(VELO), USDC_1, TOKEN_1, address(USDC), 10, 3);
        _createPoolAndSimulateSwaps(address(WETH), address(VELO), TOKEN_1, TOKEN_100K, address(VELO), 1e6, 3);
        _createPoolAndSimulateSwaps(address(FRAX), address(VELO), TOKEN_1, TOKEN_1, address(VELO), 1e6, 3);
        _createPoolAndSimulateSwaps(address(FRAX), address(DAI), TOKEN_1, TOKEN_1, address(FRAX), 1e6, 3);

        tokensToSwap.push(address(USDC));
        tokensToSwap.push(address(FRAX));
        tokensToSwap.push(address(DAI));

        // 5% slippage
        slippages.push(500);
        slippages.push(500);
        slippages.push(500);

        // skip to last day where claiming becomes public
        skipToNextEpoch(6 days + 1);
    }

    function testManagedTokenID() public {
        assertEq(autoConverter.mTokenId(), mTokenId);
        assertEq(escrow.ownerOf(mTokenId), address(autoConverter));
        assertTrue(escrow.escrowType(mTokenId) == IVotingEscrow.EscrowType.MANAGED);
    }

    function testCannotInitializeIfAlreadyInitialized() external {
        vm.expectRevert("Initializable: contract is already initialized");
        autoConverter.initialize(1);
    }

    function testCannotInitializeTokenNotOwned() external {
        AutoConverter comp = new AutoConverter(
            address(forwarder),
            address(voter),
            address(owner),
            "",
            address(router),
            address(USDC),
            address(autoConverterFactory)
        );
        uint256 _mTokenId = escrow.createManagedLockFor(address(owner));
        vm.prank(escrow.allowedManager());
        vm.expectRevert(IRelay.ManagedTokenNotOwned.selector);
        comp.initialize(_mTokenId);
    }

    function testCannotInitializeTokenNotManaged() external {
        AutoConverter comp = new AutoConverter(
            address(forwarder),
            address(voter),
            address(owner),
            "",
            address(router),
            address(USDC),
            address(autoConverterFactory)
        );
        vm.prank(escrow.allowedManager());
        vm.expectRevert(IRelay.TokenIdNotManaged.selector);
        comp.initialize(2);
    }

    function _createPoolAndSimulateSwaps(
        address token1,
        address token2,
        uint256 liquidity1,
        uint256 liquidity2,
        address tokenIn,
        uint256 amountSwapped,
        uint256 numSwapped
    ) internal {
        address tokenOut = tokenIn == token1 ? token2 : token1;
        _addLiquidityToPool(address(owner), address(router), token1, token2, false, liquidity1, liquidity2);

        IRouter.Route[] memory routes = new IRouter.Route[](1);

        // for every hour, simulate a swap to add an observation
        for (uint256 i = 0; i < numSwapped; i++) {
            skipAndRoll(1 hours);
            routes[0] = IRouter.Route(tokenIn, tokenOut, false, address(0));

            IERC20(tokenIn).approve(address(router), amountSwapped);
            router.swapExactTokensForTokens(amountSwapped, 0, routes, address(owner), block.timestamp);
        }
    }

    function testLastKeeperRunSetup() public {
        assertEq(autoConverter.keeperLastRun(), 0);
    }

    function testClaimAndConvertClaimRebaseOnly() public {
        address[] memory pools = new address[](2);
        pools[0] = address(pool);
        pools[1] = address(pool2);
        uint256[] memory weights = new uint256[](2);
        weights[0] = 1;
        weights[1] = 1;

        autoConverter.vote(pools, weights);

        skipToNextEpoch(6 days + 1);
        minter.updatePeriod();

        uint256 claimable = distributor.claimable(mTokenId);
        assertGt(distributor.claimable(mTokenId), 0);

        uint256 balanceBefore = escrow.balanceOfNFT(mTokenId);
        autoConverter.claimFees(fees, tokensToClaim);
        autoConverter.claimBribes(bribes, tokensToClaim);
        assertEq(escrow.balanceOfNFT(mTokenId), balanceBefore + claimable);
    }

    function testIncreaseAmount() public {
        uint256 amount = TOKEN_1;
        deal(address(VELO), address(owner), amount);
        VELO.approve(address(autoConverter), amount);

        uint256 balanceBefore = escrow.balanceOfNFT(mTokenId);
        uint256 supplyBefore = escrow.totalSupply();

        autoConverter.increaseAmount(amount);

        assertEq(escrow.balanceOfNFT(mTokenId), balanceBefore + amount);
        assertEq(escrow.totalSupply(), supplyBefore + amount);
    }

    function testVote() public {
        address[] memory poolVote = new address[](1);
        uint256[] memory weights = new uint256[](1);
        poolVote[0] = address(pool2);
        weights[0] = 1;

        assertFalse(escrow.voted(mTokenId));

        autoConverter.vote(poolVote, weights);

        assertEq(autoConverter.keeperLastRun(), block.timestamp);
        assertTrue(escrow.voted(mTokenId));
        assertEq(voter.weights(address(pool2)), escrow.balanceOfNFT(mTokenId));
        assertEq(voter.votes(mTokenId, address(pool2)), escrow.balanceOfNFT(mTokenId));
        assertEq(voter.poolVote(mTokenId, 0), address(pool2));
    }

    function testSwapTokenToToken() public {
        deal(address(FRAX), address(autoConverter), TOKEN_1 / 1000, true);

        IRouter.Route[] memory routes = new IRouter.Route[](1);
        routes[0] = IRouter.Route(address(FRAX), address(USDC), false, address(0));
        uint256 amountIn = TOKEN_1 / 1000;
        uint256 amountOutMin = 1;

        uint256 balanceBefore = USDC.balanceOf(address(autoConverter));
        autoConverter.swapTokenToToken(routes, amountIn, amountOutMin);
        assertEq(autoConverter.keeperLastRun(), block.timestamp);
        assertGt(USDC.balanceOf(address(autoConverter)), balanceBefore);
        assertEq(
            autoConverter.amountTokenEarned(VelodromeTimeLibrary.epochStart(block.timestamp)),
            USDC.balanceOf(address(autoConverter))
        );
    }

    function testHandleRouterApproval() public {
        deal(address(FRAX), address(autoConverter), TOKEN_1 / 1000, true);

        // give a fake approval to impersonate a dangling approved amount
        vm.prank(address(autoConverter));
        FRAX.approve(address(router), 100);

        // resets and properly approves swap amount
        IRouter.Route[][] memory allRoutes = new IRouter.Route[][](1);
        IRouter.Route[] memory routes = new IRouter.Route[](1);
        routes[0] = IRouter.Route(address(FRAX), address(USDC), false, address(0));
        allRoutes[0] = routes;
        uint256 amountIn = TOKEN_1 / 1000;
        uint256 amountOutMin = 1;

        autoConverter.swapTokenToToken(routes, amountIn, amountOutMin);
        assertEq(FRAX.allowance(address(autoConverter), address(router)), 0);
    }

    function testCannotSwapTokenToTokenIfNotKeeper() public {
        vm.startPrank(address(owner2));
        vm.expectRevert(IRelay.NotKeeper.selector);
        autoConverter.swapTokenToToken(new IRouter.Route[](0), 0, 0);
    }

    function testCannotSwapKeeperIfAmountInZero() public {
        IRouter.Route[][] memory allRoutes = new IRouter.Route[][](1);
        uint256 amountIn = 0;
        uint256 amountOutMin = 0;
        vm.expectRevert(IAutoConverter.AmountInZero.selector);
        autoConverter.swapTokenToToken(allRoutes[0], amountIn, amountOutMin);
    }

    function testCannotSwapKeeperIfSlippageTooHigh() public {
        IRouter.Route[][] memory allRoutes = new IRouter.Route[][](1);
        uint256 amountIn = 1;
        uint256 amountOutMin = 0;
        vm.expectRevert(IAutoConverter.SlippageTooHigh.selector);
        autoConverter.swapTokenToToken(allRoutes[0], amountIn, amountOutMin);
    }

    function testCannotSwapKeeperIfInvalidPath() public {
        IRouter.Route[][] memory allRoutes = new IRouter.Route[][](1);
        IRouter.Route[] memory routes = new IRouter.Route[](1);
        routes[0] = IRouter.Route(address(0), address(0), false, address(0));
        allRoutes[0] = routes;
        uint256 amountIn = 1;
        uint256 amountOutMin = 1;
        vm.expectRevert(IAutoConverter.InvalidPath.selector);
        autoConverter.swapTokenToToken(allRoutes[0], amountIn, amountOutMin);
    }

    function testCannotSwapKeeperFromUSDC() public {
        IRouter.Route[][] memory allRoutes = new IRouter.Route[][](1);
        IRouter.Route[] memory routes = new IRouter.Route[](1);
        routes[0] = IRouter.Route(address(USDC), address(0), false, address(0));
        allRoutes[0] = routes;
        uint256 amountIn = 1;
        uint256 amountOutMin = 1;
        vm.expectRevert(IAutoConverter.InvalidPath.selector);
        autoConverter.swapTokenToToken(allRoutes[0], amountIn, amountOutMin);
    }

    function testCannotSwapKeeperIfAmountInTooHigh() public {
        IRouter.Route[][] memory allRoutes = new IRouter.Route[][](1);
        IRouter.Route[] memory routes = new IRouter.Route[](1);
        routes[0] = IRouter.Route(address(WETH), address(USDC), false, address(0));
        allRoutes[0] = routes;
        uint256 amountIn = 1;
        uint256 amountOutMin = 1;
        vm.expectRevert(IAutoConverter.AmountInTooHigh.selector);
        autoConverter.swapTokenToToken(allRoutes[0], amountIn, amountOutMin);
    }

    function testCannotSweepIfNotAdmin() public {
        deal(address(USDC), address(autoConverter), TOKEN_1);
        bytes memory revertString = bytes(
            "AccessControl: account 0x7d28001937fe8e131f76dae9e9947adedbd0abde is missing role 0x0000000000000000000000000000000000000000000000000000000000000000"
        );
        vm.startPrank(address(owner2));
        vm.expectRevert(revertString);
        autoConverter.sweep(address(0), address(owner2), TOKEN_1);
    }

    function testSweep() public {
        // partial withdraw
        deal(address(USDC), address(autoConverter), TOKEN_1);
        uint256 amount = TOKEN_1 / 4;
        uint256 balanceBefore = USDC.balanceOf(address(owner3));
        autoConverter.sweep(address(USDC), address(owner3), amount);
        assertEq(balanceBefore + amount, USDC.balanceOf(address(owner3)));
        assertEq(TOKEN_1 - amount, USDC.balanceOf(address(autoConverter)));

        // full withdraw
        deal(address(WETH), address(autoConverter), TOKEN_1);
        amount = TOKEN_1;
        balanceBefore = WETH.balanceOf(address(owner3));
        autoConverter.sweep(address(WETH), address(owner3), amount);
        assertEq(balanceBefore + amount, WETH.balanceOf(address(owner3)));
        assertEq(WETH.balanceOf(address(autoConverter)), 0);
    }
}
