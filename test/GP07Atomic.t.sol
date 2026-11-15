// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

// GMX lead G-P0-7 — atomic path: executeAtomicWithdrawal with a stale report.
//
// executeAtomicWithdrawal is external, no role check — any user can call it
// for their own withdrawal, supplying their own oracle params. Validation is
// _validatePrices(..., forAtomicAction=true): provider must be an enabled
// ATOMIC provider, age <= 30s, ref check only if a feed exists. ZORA has NO
// feed, so on paper a <=30s-old pre-move report looked directly usable.
//
// VERDICT: NOT FOUND — the atomic path is blocked by a DIFFERENT check that
// the recon missed: ExecuteWithdrawalUtils.sol:100 requires
//   oracle.minTimestamp() >= withdrawal.updatedAtTime()
// for EVERY withdrawal (atomic and keeper-executed alike). For atomic
// withdrawals the withdrawal is created inside the same call, so
// updatedAtTime == the execution block timestamp, and ANY report older than
// "now" is rejected with OracleTimestampsAreSmallerThanRequired. The 30s
// age bound is strictly weaker for atomic withdrawals — the creation-time
// check is the binding one. A stale price can only be redeemed through the
// KEEPER path (withdrawal created BEFORE the move, keeper executes with a
// <=300s-old report) — see W1/W1c below, same caveat as the order path.
//
// Probe facts at fork 524367000: ZORA OI long $0, OI short $20,418.57.
// A DOWN move makes pre-existing shorts gain, so the pool value FALLS.
// Withdrawing GM at the stale (pre-fall) price redeems at the higher pool
// value — the loss falls on the remaining GM holders.
//
//   A1:  deposit $2,000 GM + open $4,000 short, ZORA -25%, atomic withdraw
//        with a 25s-old pre-fall report — REVERTS
//        OracleTimestampsAreSmallerThanRequired (blocked, not exploitable).
//   A1c: control — same flow, fresh report at the fallen price (passes).
//   A1b: GM-only (no own short), -25%, stale withdraw — REVERTS (same).
//   A1bc: GM-only control (fresh, passes).
//   A2:  31s-old atomic report reverts MaxPriceAgeExceeded (30s bound binds).
//   A3:  pump +25%, GM-only, stale withdraw — REVERTS (same).
//   A3c: A3 control (fresh, passes).
//   W1:  KEEPER-executed withdrawal: withdrawal created at T0 (before the
//        -25% move), keeper executes at T0+299 with the 299s-old pre-fall
//        report — measures the stale-price redemption via the keeper path.
//   W1c: W1 control (fresh report at the fallen price).

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../contracts/utils/GmxForkHelpers.sol";
import "../contracts/constants/GmxArbitrumAddresses.sol";
import "../contracts/interfaces/IGmxV2.sol";
import {Keys as GmxKeys} from "../contracts/Keys.sol";
import "../contracts/mock/MockOracleProvider7.sol";

contract GP07AtomicTest is GmxForkHelpers {
    uint256 constant FORK_BLOCK = 524367000;
    address constant M_ZORA = 0xac484106d935f0f20F1485b631fA6F65AeEff550;
    address constant ZORA = 0xc5ff0eB026dB972F95DF3dfF04e697d8b660092a;
    uint256 constant USDC_PX = 1e24;
    uint256 constant GAS_PRICE = 0.1 gwei;
    uint256 constant STD_FEE = 0.001 ether;

    // ZORA price (GMX format, 18dp): $0.004431, GMX API 15 Nov ~12:00 WIB.
    uint256 constant ZORA_P0 = 4431264904;
    uint256 constant ZORA_P1_DOWN = 3323448678; // -25%
    uint256 constant ZORA_P1_UP = 5539081130; // +25%

    address internal lp = address(0x1A7);
    address internal keeper;
    IDepositHandler internal depositHandler;
    IWithdrawalHandler internal withdrawalHandler;
    address internal depositVault;
    address internal withdrawalVault;
    IERC20 internal weth;
    IERC20 internal usdc;
    IERC20 internal gmZora;
    MockOracleProvider7 internal mock7;
    uint256 internal wethPx;
    uint256 internal curZoraPx;

    function setUp() public {
        vm.createSelectFork("https://arb1.arbitrum.io/rpc", FORK_BLOCK);
        exchangeRouter = IExchangeRouter(GmxArbitrumAddresses.EXCHANGE_ROUTER);
        orderHandler = IOrderHandler(GmxArbitrumAddresses.ORDER_HANDLER);
        depositHandler = IDepositHandler(GmxArbitrumAddresses.DEPOSIT_HANDLER);
        withdrawalHandler = IWithdrawalHandler(GmxArbitrumAddresses.WITHDRAWAL_HANDLER);
        depositVault = depositHandler.depositVault();
        withdrawalVault = withdrawalHandler.withdrawalVault();
        oracle = IOracle(GmxArbitrumAddresses.ORACLE);
        dataStore = IDataStore(GmxArbitrumAddresses.DATA_STORE);
        roleStore = IRoleStore(GmxArbitrumAddresses.ROLE_STORE);
        weth = IERC20(GmxArbitrumAddresses.WETH);
        usdc = IERC20(GmxArbitrumAddresses.USDC);
        gmZora = IERC20(M_ZORA);

        vm.deal(lp, 100 ether);
        deal(address(weth), lp, 1000 ether);
        deal(address(usdc), lp, 10_000_000e6);
        address[] memory users = new address[](1);
        users[0] = lp;
        address[] memory toks = new address[](3);
        toks[0] = address(weth);
        toks[1] = address(usdc);
        toks[2] = M_ZORA;
        for (uint256 i; i < users.length; i++) {
            for (uint256 j; j < toks.length; j++) {
                vm.prank(users[i]);
                IERC20(toks[j]).approve(address(exchangeRouter), type(uint256).max);
                vm.prank(users[i]);
                IERC20(toks[j]).approve(GmxArbitrumAddresses.ROUTER, type(uint256).max);
            }
        }

        keeper = _firstRoleMember(Keys.ORDER_KEEPER);
        vm.deal(keeper, 10 ether);

        (uint256 px, bool ok) = _feedPrice(GmxArbitrumAddresses.WETH);
        require(ok, "no weth feed");
        wethPx = px;
        curZoraPx = ZORA_P0;

        mock7 = new MockOracleProvider7();
        // atomic path needs the mock enabled AND flagged atomic (global flags,
        // not the per-token provider mapping — atomic validation does not
        // check oracleProviderForTokenKey).
        vm.prank(GmxArbitrumAddresses.EXCHANGE_ROUTER);
        dataStore.setBool(GmxKeys.isOracleProviderEnabledKey(address(mock7)), true);
        vm.prank(GmxArbitrumAddresses.EXCHANGE_ROUTER);
        dataStore.setBool(GmxKeys.isAtomicOracleProviderKey(address(mock7)), true);
    }

    // ------------------------------------------------------------------ helpers

    function _firstRoleMember(bytes32 role) internal view returns (address) {
        uint256 n = roleStore.getRoleMemberCount(role);
        require(n > 0, "role empty");
        return roleStore.getRoleMembers(role, 0, n)[0];
    }

    function _feedPrice(address token) internal view returns (uint256 price, bool ok) {
        address feed = dataStore.getAddress(GmxKeys.priceFeedKey(token));
        if (feed == address(0)) return (0, false);
        uint256 mult = dataStore.getUint(GmxKeys.priceFeedMultiplierKey(token));
        (bool success, bytes memory ret) = feed.staticcall(abi.encodeWithSignature("latestRoundData()"));
        if (!success || ret.length < 160) return (0, false);
        (, int256 answer, , , ) = abi.decode(ret, (uint80, int256, uint256, uint256, uint80));
        if (answer <= 0 || mult == 0) return (0, false);
        uint256 ans = uint256(answer);
        if (mult >= 1e30) price = ans * (mult / 1e30);
        else price = ans * mult / 1e30;
        if (price < 1 || price > 1e36) return (0, false);
        return (price, true);
    }

    // Direct primary-price setting (prank router) + empty oracle params —
    // the G-P1-5 pattern for keeper-executed deposit/order calls.
    function _setDirectPrices() internal {
        vm.prank(GmxArbitrumAddresses.EXCHANGE_ROUTER);
        oracle.clearAllPrices();
        vm.prank(GmxArbitrumAddresses.EXCHANGE_ROUTER);
        oracle.setPrimaryPrice(ZORA, Price.Props({min: curZoraPx, max: curZoraPx}));
        vm.prank(GmxArbitrumAddresses.EXCHANGE_ROUTER);
        oracle.setPrimaryPrice(GmxArbitrumAddresses.WETH, Price.Props({min: wethPx, max: wethPx}));
        vm.prank(GmxArbitrumAddresses.EXCHANGE_ROUTER);
        oracle.setPrimaryPrice(GmxArbitrumAddresses.USDC, Price.Props({min: USDC_PX, max: USDC_PX}));
        vm.prank(GmxArbitrumAddresses.EXCHANGE_ROUTER);
        oracle.setTimestamps(block.timestamp, block.timestamp);
    }

    function _emptyOracleParams() internal pure returns (OracleUtils.SetPricesParams memory p) {
        p.tokens = new address[](0);
        p.providers = new address[](0);
        p.data = new bytes[](0);
    }

    function _snap(address user) internal view returns (uint256 w, uint256 u, uint256 e) {
        w = weth.balanceOf(user);
        u = usdc.balanceOf(user);
        e = user.balance;
    }

    // USD value (plain USD, not 1e30) of WETH wei + USDC 6dp at the feed price.
    function _usdOf(uint256 wethWei, uint256 usdcUnits) internal view returns (uint256) {
        return (wethWei * wethPx) / 1e30 + (usdcUnits * USDC_PX) / 1e30;
    }

    function _createDeposit(uint256 longWeth, uint256 shortUsdc) internal returns (bytes32) {
        address[] memory emptyPath = new address[](0);
        bytes32[] memory emptyData = new bytes32[](0);
        vm.txGasPrice(GAS_PRICE);
        vm.startPrank(lp);
        exchangeRouter.sendTokens(address(weth), depositVault, longWeth + STD_FEE);
        exchangeRouter.sendTokens(address(usdc), depositVault, shortUsdc);
        IExchangeRouter.CreateDepositParams memory p;
        p.addresses = IExchangeRouter.CreateDepositParamsAddresses({
            receiver: lp,
            callbackContract: address(0),
            uiFeeReceiver: address(0),
            market: M_ZORA,
            initialLongToken: address(weth),
            initialShortToken: address(usdc),
            longTokenSwapPath: emptyPath,
            shortTokenSwapPath: emptyPath
        });
        p.minMarketTokens = 0;
        p.shouldUnwrapNativeToken = false;
        p.executionFee = STD_FEE;
        p.callbackGasLimit = 0;
        p.dataList = emptyData;
        bytes32 key = exchangeRouter.createDeposit{value: 0}(p);
        vm.stopPrank();
        return key;
    }

    function _executeDeposit(bytes32 key) internal {
        _setDirectPrices();
        vm.txGasPrice(GAS_PRICE);
        vm.prank(keeper);
        depositHandler.executeDeposit(key, _emptyOracleParams());
    }

    function _deposit2000() internal returns (uint256 gmMinted) {
        uint256 longWeth = 850e30 / wethPx;
        uint256 before = gmZora.balanceOf(lp);
        bytes32 key = _createDeposit(longWeth, 1150e6);
        _executeDeposit(key);
        gmMinted = gmZora.balanceOf(lp) - before;
        console.log("deposit $2,000 GM minted (wei):", gmMinted);
        console.log("deposit GM totalSupply after (wei):", gmZora.totalSupply());
        require(gmMinted > 0, "deposit minted 0 GM");
    }

    function _createZoraShort(uint256 sizeUsd, uint256 collateralUsdc) internal returns (bytes32) {
        IExchangeRouter.CreateOrderParams memory params =
            createIncreaseOrderParams(M_ZORA, GmxArbitrumAddresses.USDC, collateralUsdc, sizeUsd, false);
        params.orderType = IExchangeRouter.OrderType.MarketIncrease;
        params.numbers.executionFee = STD_FEE;
        params.numbers.acceptablePrice = 1;
        params.numbers.minOutputAmount = 0;
        params.numbers.callbackGasLimit = 0;
        params.numbers.validFromTime = 0;
        params.addresses.receiver = lp;
        params.addresses.cancellationReceiver = lp;
        params.autoCancel = false;
        params.shouldUnwrapNativeToken = false;
        vm.txGasPrice(GAS_PRICE);
        vm.startPrank(lp);
        params.numbers.initialCollateralDeltaAmount = collateralUsdc;
        exchangeRouter.sendTokens(GmxArbitrumAddresses.USDC, GmxArbitrumAddresses.ORDER_VAULT, collateralUsdc);
        exchangeRouter.sendWnt{value: STD_FEE}(GmxArbitrumAddresses.ORDER_VAULT, STD_FEE);
        bytes32 key = exchangeRouter.createOrder{value: 0}(params);
        vm.stopPrank();
        return key;
    }

    function _createZoraDecrease(uint256 sizeUsd) internal returns (bytes32) {
        IExchangeRouter.CreateOrderParams memory params =
            createDecreaseOrderParams(M_ZORA, GmxArbitrumAddresses.USDC, sizeUsd, false);
        params.orderType = IExchangeRouter.OrderType.MarketDecrease;
        params.numbers.executionFee = STD_FEE;
        params.numbers.acceptablePrice = type(uint256).max;
        params.numbers.minOutputAmount = 0;
        params.numbers.callbackGasLimit = 0;
        params.numbers.validFromTime = 0;
        params.addresses.receiver = lp;
        params.addresses.cancellationReceiver = lp;
        params.autoCancel = false;
        params.shouldUnwrapNativeToken = false;
        vm.txGasPrice(GAS_PRICE);
        vm.startPrank(lp);
        exchangeRouter.sendWnt{value: STD_FEE}(GmxArbitrumAddresses.ORDER_VAULT, STD_FEE);
        bytes32 key = exchangeRouter.createOrder{value: 0}(params);
        vm.stopPrank();
        return key;
    }

    function _executeOrderDirect(bytes32 key) internal {
        _setDirectPrices();
        vm.txGasPrice(GAS_PRICE);
        vm.prank(keeper);
        orderHandler.executeOrder(key, _emptyOracleParams());
    }

    function _mockAtomicParams(uint256 zoraPx, uint256 ts) internal returns (OracleUtils.SetPricesParams memory p) {
        mock7.setPrice(ZORA, zoraPx, zoraPx);
        mock7.setTimestamp(ZORA, ts);
        mock7.setPrice(GmxArbitrumAddresses.WETH, wethPx, wethPx);
        mock7.setTimestamp(GmxArbitrumAddresses.WETH, ts);
        mock7.setPrice(GmxArbitrumAddresses.USDC, USDC_PX, USDC_PX);
        mock7.setTimestamp(GmxArbitrumAddresses.USDC, ts);
        p.tokens = new address[](3);
        p.tokens[0] = ZORA;
        p.tokens[1] = GmxArbitrumAddresses.WETH;
        p.tokens[2] = GmxArbitrumAddresses.USDC;
        p.providers = new address[](3);
        p.providers[0] = address(mock7);
        p.providers[1] = address(mock7);
        p.providers[2] = address(mock7);
        p.data = new bytes[](3);
        p.data[0] = "";
        p.data[1] = "";
        p.data[2] = "";
    }

    // Atomic withdrawal of ALL the caller's GM. Returns the USD value of the
    // WETH+USDC proceeds (plain USD at the WETH feed price).
    function _atomicWithdrawAll(OracleUtils.SetPricesParams memory p) internal returns (uint256 proceedsUsd) {
        uint256 gm = gmZora.balanceOf(lp);
        require(gm > 0, "no GM to withdraw");
        address[] memory emptyPath = new address[](0);
        bytes32[] memory emptyData = new bytes32[](0);
        (uint256 w0, uint256 u0, ) = _snap(lp);
        vm.txGasPrice(GAS_PRICE);
        vm.startPrank(lp);
        exchangeRouter.sendTokens(M_ZORA, withdrawalVault, gm);
        exchangeRouter.sendWnt{value: STD_FEE}(withdrawalVault, STD_FEE);
        IExchangeRouter.CreateWithdrawalParams memory wp;
        wp.addresses = IExchangeRouter.CreateWithdrawalParamsAddresses({
            receiver: lp,
            callbackContract: address(0),
            uiFeeReceiver: address(0),
            market: M_ZORA,
            longTokenSwapPath: emptyPath,
            shortTokenSwapPath: emptyPath
        });
        wp.minLongTokenAmount = 0;
        wp.minShortTokenAmount = 0;
        wp.shouldUnwrapNativeToken = false;
        wp.executionFee = STD_FEE;
        wp.callbackGasLimit = 0;
        wp.dataList = emptyData;
        exchangeRouter.executeAtomicWithdrawal{value: 0}(wp, p);
        vm.stopPrank();
        require(gmZora.balanceOf(lp) == 0, "GM not fully withdrawn");
        (uint256 w1, uint256 u1, ) = _snap(lp);
        proceedsUsd = _usdOf(w1 - w0, u1 - u0);
        console.log("atomic withdrawal WETH out (wei):", w1 - w0);
        console.log("atomic withdrawal USDC out (6dp):", u1 - u0);
        console.log("atomic withdrawal proceeds (USD):", proceedsUsd);
    }

    function _positionSizeUsd() internal view returns (uint256) {
        bytes32 key = keccak256(abi.encode(lp, M_ZORA, GmxArbitrumAddresses.USDC, false));
        return dataStore.getUint(keccak256(abi.encode(key, keccak256(abi.encode("SIZE_IN_USD")))));
    }

    // ------------------------------------------------------------------ A1 / A1c

    // A1: deposit $2,000 GM + open $4,000 short at P0; ZORA -25%; at T0+25
    // atomic-withdraw all GM with the 25s-old pre-fall report (stale).
    // RESULT: REVERTS OracleTimestampsAreSmallerThanRequired(T0, T0+25).
    // The withdrawal is created inside the atomic call, so its
    // updatedAtTime == T0+25, and the T0-dated report predates it
    // (ExecuteWithdrawalUtils.sol:100). The stale atomic withdrawal is
    // blocked by design — no gain is possible on this path.
    function testA1AtomicWithdrawStaleAfterFall25() public {
        uint256 t0 = block.timestamp;
        _deposit2000();
        bytes32 okey = _createZoraShort(4_000e30, 3500e6);
        _executeOrderDirect(okey);
        require(_positionSizeUsd() == 4_000e30, "A1: short did not open");
        curZoraPx = ZORA_P1_DOWN;
        vm.warp(t0 + 25);
        uint256 reportTs = block.timestamp - 25; // == t0
        OracleUtils.SetPricesParams memory p = _mockAtomicParams(ZORA_P0, reportTs);
        uint256 gm = gmZora.balanceOf(lp);
        address[] memory emptyPath = new address[](0);
        bytes32[] memory emptyData = new bytes32[](0);
        vm.txGasPrice(GAS_PRICE);
        vm.startPrank(lp);
        exchangeRouter.sendTokens(M_ZORA, withdrawalVault, gm);
        exchangeRouter.sendWnt{value: STD_FEE}(withdrawalVault, STD_FEE);
        IExchangeRouter.CreateWithdrawalParams memory wp;
        wp.addresses = IExchangeRouter.CreateWithdrawalParamsAddresses({
            receiver: lp,
            callbackContract: address(0),
            uiFeeReceiver: address(0),
            market: M_ZORA,
            longTokenSwapPath: emptyPath,
            shortTokenSwapPath: emptyPath
        });
        wp.minLongTokenAmount = 0;
        wp.minShortTokenAmount = 0;
        wp.shouldUnwrapNativeToken = false;
        wp.executionFee = STD_FEE;
        wp.callbackGasLimit = 0;
        wp.dataList = emptyData;
        vm.expectRevert(
            abi.encodeWithSignature(
                "OracleTimestampsAreSmallerThanRequired(uint256,uint256)",
                reportTs,
                block.timestamp
            )
        );
        exchangeRouter.executeAtomicWithdrawal{value: 0}(wp, p);
        vm.stopPrank();
        console.log("A1 stale atomic withdrawal reverts OracleTimestampsAreSmallerThanRequired as expected");
    }

    // A1c: control — identical flow, atomic withdrawal with a FRESH report at
    // the fallen price. Compare proceeds with A1.
    function testA1cAtomicWithdrawFreshAfterFall25() public {
        uint256 t0 = block.timestamp;
        _deposit2000();
        bytes32 okey = _createZoraShort(4_000e30, 3500e6);
        _executeOrderDirect(okey);
        require(_positionSizeUsd() == 4_000e30, "A1c: short did not open");
        curZoraPx = ZORA_P1_DOWN;
        vm.warp(t0 + 25);
        OracleUtils.SetPricesParams memory p = _mockAtomicParams(ZORA_P1_DOWN, block.timestamp);
        uint256 proceeds = _atomicWithdrawAll(p);
        console.log("A1c fresh-withdrawal proceeds (USD):", proceeds);
        bytes32 ckey = _createZoraDecrease(4_000e30);
        _executeOrderDirect(ckey);
        require(_positionSizeUsd() == 0, "A1c: short did not close");
        assertLt(proceeds, 2_000, "A1c: fresh withdrawal should redeem < $2,000 (pool fell)");
    }

    // ------------------------------------------------------------------ A1b / A1bc

    // A1b: GM-only (no own position), -25%, stale withdrawal — same block
    // as A1: reverts OracleTimestampsAreSmallerThanRequired.
    function testA1bGmOnlyStaleAfterFall25() public {
        uint256 t0 = block.timestamp;
        _deposit2000();
        curZoraPx = ZORA_P1_DOWN;
        vm.warp(t0 + 25);
        uint256 reportTs = block.timestamp - 25;
        OracleUtils.SetPricesParams memory p = _mockAtomicParams(ZORA_P0, reportTs);
        uint256 gm = gmZora.balanceOf(lp);
        address[] memory emptyPath = new address[](0);
        bytes32[] memory emptyData = new bytes32[](0);
        vm.txGasPrice(GAS_PRICE);
        vm.startPrank(lp);
        exchangeRouter.sendTokens(M_ZORA, withdrawalVault, gm);
        exchangeRouter.sendWnt{value: STD_FEE}(withdrawalVault, STD_FEE);
        IExchangeRouter.CreateWithdrawalParams memory wp;
        wp.addresses = IExchangeRouter.CreateWithdrawalParamsAddresses({
            receiver: lp,
            callbackContract: address(0),
            uiFeeReceiver: address(0),
            market: M_ZORA,
            longTokenSwapPath: emptyPath,
            shortTokenSwapPath: emptyPath
        });
        wp.minLongTokenAmount = 0;
        wp.minShortTokenAmount = 0;
        wp.shouldUnwrapNativeToken = false;
        wp.executionFee = STD_FEE;
        wp.callbackGasLimit = 0;
        wp.dataList = emptyData;
        vm.expectRevert(
            abi.encodeWithSignature(
                "OracleTimestampsAreSmallerThanRequired(uint256,uint256)",
                reportTs,
                block.timestamp
            )
        );
        exchangeRouter.executeAtomicWithdrawal{value: 0}(wp, p);
        vm.stopPrank();
        console.log("A1b GM-only stale atomic withdrawal reverts as expected");
    }

    // A1bc: GM-only control (fresh). MEASURED: redeems $2,060 — MORE than
    // the $2,000 deposit, even though the pool's shorts gained. Reason: the
    // pool value deducts impactPoolUsd = impactPoolAmount x ZORA price
    // (MarketUtils.getPoolValueInfo); the ZORA-denominated impact pool is
    // $1,689 at P0 but only $1,267 at P1_DOWN, so the pool value RISES by
    // $422 on the fall. The pre-existing shorts' PnL is pinned at the
    // 0.45 x shortTokenUsd withdrawal cap, so it does not move the pool.
    // (This inverted the original prediction — the impact pool, not the
    // positions, drives the GM-only pool value here.)
    function testA1bcGmOnlyFreshAfterFall25() public {
        uint256 t0 = block.timestamp;
        _deposit2000();
        curZoraPx = ZORA_P1_DOWN;
        vm.warp(t0 + 25);
        OracleUtils.SetPricesParams memory p = _mockAtomicParams(ZORA_P1_DOWN, block.timestamp);
        uint256 proceeds = _atomicWithdrawAll(p);
        console.log("A1bc GM-only fresh-withdrawal proceeds (USD):", proceeds);
        assertGt(proceeds, 2_000, "A1bc: fresh withdrawal after fall redeems > $2,000 (impact pool shrinks)");
    }

    // ------------------------------------------------------------------ A2

    // A2: a 31s-old report in executeAtomicWithdrawal reverts
    // MaxPriceAgeExceeded — the 30s atomic bound binds even for no-feed tokens.
    function testA2AtomicReport31sOldReverts() public {
        uint256 t0 = block.timestamp;
        _deposit2000();
        vm.warp(t0 + 31);
        uint256 reportTs = block.timestamp - 31; // == t0
        OracleUtils.SetPricesParams memory p = _mockAtomicParams(ZORA_P0, reportTs);
        uint256 gm = gmZora.balanceOf(lp);
        address[] memory emptyPath = new address[](0);
        bytes32[] memory emptyData = new bytes32[](0);
        vm.txGasPrice(GAS_PRICE);
        vm.startPrank(lp);
        exchangeRouter.sendTokens(M_ZORA, withdrawalVault, gm);
        exchangeRouter.sendWnt{value: STD_FEE}(withdrawalVault, STD_FEE);
        IExchangeRouter.CreateWithdrawalParams memory wp;
        wp.addresses = IExchangeRouter.CreateWithdrawalParamsAddresses({
            receiver: lp,
            callbackContract: address(0),
            uiFeeReceiver: address(0),
            market: M_ZORA,
            longTokenSwapPath: emptyPath,
            shortTokenSwapPath: emptyPath
        });
        wp.minLongTokenAmount = 0;
        wp.minShortTokenAmount = 0;
        wp.shouldUnwrapNativeToken = false;
        wp.executionFee = STD_FEE;
        wp.callbackGasLimit = 0;
        wp.dataList = emptyData;
        vm.expectRevert(
            abi.encodeWithSignature("MaxPriceAgeExceeded(uint256,uint256)", reportTs, block.timestamp)
        );
        exchangeRouter.executeAtomicWithdrawal{value: 0}(wp, p);
        vm.stopPrank();
        console.log("A2 31s-old atomic report reverts MaxPriceAgeExceeded as expected");
    }

    // ------------------------------------------------------------------ A3 / A3c

    // A3: pump +25%, GM-only, stale withdrawal — same block as A1: reverts
    // OracleTimestampsAreSmallerThanRequired (direction is irrelevant; any
    // stale atomic withdrawal is blocked).
    function testA3GmOnlyStaleAfterPump25() public {
        uint256 t0 = block.timestamp;
        _deposit2000();
        curZoraPx = ZORA_P1_UP;
        vm.warp(t0 + 25);
        uint256 reportTs = block.timestamp - 25;
        OracleUtils.SetPricesParams memory p = _mockAtomicParams(ZORA_P0, reportTs);
        uint256 gm = gmZora.balanceOf(lp);
        address[] memory emptyPath = new address[](0);
        bytes32[] memory emptyData = new bytes32[](0);
        vm.txGasPrice(GAS_PRICE);
        vm.startPrank(lp);
        exchangeRouter.sendTokens(M_ZORA, withdrawalVault, gm);
        exchangeRouter.sendWnt{value: STD_FEE}(withdrawalVault, STD_FEE);
        IExchangeRouter.CreateWithdrawalParams memory wp;
        wp.addresses = IExchangeRouter.CreateWithdrawalParamsAddresses({
            receiver: lp,
            callbackContract: address(0),
            uiFeeReceiver: address(0),
            market: M_ZORA,
            longTokenSwapPath: emptyPath,
            shortTokenSwapPath: emptyPath
        });
        wp.minLongTokenAmount = 0;
        wp.minShortTokenAmount = 0;
        wp.shouldUnwrapNativeToken = false;
        wp.executionFee = STD_FEE;
        wp.callbackGasLimit = 0;
        wp.dataList = emptyData;
        vm.expectRevert(
            abi.encodeWithSignature(
                "OracleTimestampsAreSmallerThanRequired(uint256,uint256)",
                reportTs,
                block.timestamp
            )
        );
        exchangeRouter.executeAtomicWithdrawal{value: 0}(wp, p);
        vm.stopPrank();
        console.log("A3 GM-only stale atomic withdrawal after PUMP reverts as expected");
    }

    // A3c: A3 control (fresh after pump). MEASURED: redeems $1,914 — LESS
    // than the $2,000 deposit. Same impact-pool mechanism in reverse: the
    // ZORA-denominated impact pool grows to $2,111 at P1_UP, so the pool
    // value FALLS by $422 on the pump.
    function testA3cGmOnlyFreshAfterPump25() public {
        uint256 t0 = block.timestamp;
        _deposit2000();
        curZoraPx = ZORA_P1_UP;
        vm.warp(t0 + 25);
        OracleUtils.SetPricesParams memory p = _mockAtomicParams(ZORA_P1_UP, block.timestamp);
        uint256 proceeds = _atomicWithdrawAll(p);
        console.log("A3c GM-only fresh-withdrawal after PUMP proceeds (USD):", proceeds);
        assertLt(proceeds, 2_000, "A3c: fresh withdrawal after pump redeems < $2,000 (impact pool grows)");
    }

    // ------------------------------------------------------------------ W1 / W1c
    // Keeper-executed withdrawal: the withdrawal is created BEFORE the move
    // (updatedAtTime == T0), so a 299s-old report with ts == T0 satisfies
    // BOTH the creation-time check (equal) and the 300s age bound. This is
    // the only stale-price withdrawal route — and it needs keeper cooperation,
    // the same caveat as the keeper order path (K1-K4).

    function _registerMock(address token) internal {
        vm.prank(GmxArbitrumAddresses.EXCHANGE_ROUTER);
        dataStore.setAddress(
            GmxKeys.oracleProviderForTokenKey(GmxArbitrumAddresses.ORACLE, token),
            address(mock7)
        );
        vm.prank(GmxArbitrumAddresses.EXCHANGE_ROUTER);
        dataStore.setBool(GmxKeys.isOracleProviderEnabledKey(address(mock7)), true);
    }

    // Create a withdrawal for ALL the caller's GM (does NOT execute it).
    function _createWithdrawalAll() internal returns (bytes32) {
        uint256 gm = gmZora.balanceOf(lp);
        require(gm > 0, "no GM to withdraw");
        address[] memory emptyPath = new address[](0);
        bytes32[] memory emptyData = new bytes32[](0);
        vm.txGasPrice(GAS_PRICE);
        vm.startPrank(lp);
        exchangeRouter.sendTokens(M_ZORA, withdrawalVault, gm);
        exchangeRouter.sendWnt{value: STD_FEE}(withdrawalVault, STD_FEE);
        IExchangeRouter.CreateWithdrawalParams memory wp;
        wp.addresses = IExchangeRouter.CreateWithdrawalParamsAddresses({
            receiver: lp,
            callbackContract: address(0),
            uiFeeReceiver: address(0),
            market: M_ZORA,
            longTokenSwapPath: emptyPath,
            shortTokenSwapPath: emptyPath
        });
        wp.minLongTokenAmount = 0;
        wp.minShortTokenAmount = 0;
        wp.shouldUnwrapNativeToken = false;
        wp.executionFee = STD_FEE;
        wp.callbackGasLimit = 0;
        wp.dataList = emptyData;
        bytes32 key = exchangeRouter.createWithdrawal{value: 0}(wp);
        vm.stopPrank();
        return key;
    }

    // Keeper executes an existing withdrawal with mock oracle params.
    // Returns the USD value of the WETH+USDC proceeds.
    function _executeWithdrawalKeeper(bytes32 key, OracleUtils.SetPricesParams memory p)
        internal
        returns (uint256 proceedsUsd)
    {
        (uint256 w0, uint256 u0, ) = _snap(lp);
        vm.txGasPrice(GAS_PRICE);
        vm.prank(keeper);
        withdrawalHandler.executeWithdrawal(key, p);
        require(gmZora.balanceOf(lp) == 0, "GM not fully withdrawn");
        (uint256 w1, uint256 u1, ) = _snap(lp);
        proceedsUsd = _usdOf(w1 - w0, u1 - u0);
        console.log("keeper withdrawal WETH out (wei):", w1 - w0);
        console.log("keeper withdrawal USDC out (6dp):", u1 - u0);
        console.log("keeper withdrawal proceeds (USD):", proceedsUsd);
    }

    // W1: deposit $2,000 GM + open $4,000 short at P0; create the withdrawal
    // at T0; ZORA -25%; at T0+299 the keeper executes it with the 299s-old
    // pre-fall report (stale). MEASURED: redeems $1,997. The absolute
    // $2,000 line is not the right baseline (round-trip fees + the
    // impact-pool offset); the comparison that matters is stale vs fresh
    // (W1c = $1,896) — see testW1vsW1c.
    function testW1KeeperWithdrawStaleAfterFall25() public {
        uint256 t0 = block.timestamp;
        _deposit2000();
        bytes32 okey = _createZoraShort(4_000e30, 3500e6);
        _executeOrderDirect(okey);
        require(_positionSizeUsd() == 4_000e30, "W1: short did not open");
        bytes32 wkey = _createWithdrawalAll();
        curZoraPx = ZORA_P1_DOWN;
        vm.warp(t0 + 299);
        _registerMock(ZORA);
        _registerMock(GmxArbitrumAddresses.WETH);
        _registerMock(GmxArbitrumAddresses.USDC);
        uint256 reportTs = block.timestamp - 299; // == t0
        OracleUtils.SetPricesParams memory p = _mockAtomicParams(ZORA_P0, reportTs);
        uint256 proceeds = _executeWithdrawalKeeper(wkey, p);
        console.log("W1 keeper stale-withdrawal proceeds (USD):", proceeds);
        bytes32 ckey = _createZoraDecrease(4_000e30);
        _executeOrderDirect(ckey);
        require(_positionSizeUsd() == 0, "W1: short did not close");
        assertGe(proceeds, 1_950, "W1: keeper stale withdrawal proceeds below expected band");
        assertLe(proceeds, 2_050, "W1: keeper stale withdrawal proceeds above expected band");
    }

    // W1c: W1 control — keeper executes with a FRESH report at the fallen
    // price. Expect redemption < $2,000.
    function testW1cKeeperWithdrawFreshAfterFall25() public {
        uint256 t0 = block.timestamp;
        _deposit2000();
        bytes32 okey = _createZoraShort(4_000e30, 3500e6);
        _executeOrderDirect(okey);
        require(_positionSizeUsd() == 4_000e30, "W1c: short did not open");
        bytes32 wkey = _createWithdrawalAll();
        curZoraPx = ZORA_P1_DOWN;
        vm.warp(t0 + 299);
        _registerMock(ZORA);
        _registerMock(GmxArbitrumAddresses.WETH);
        _registerMock(GmxArbitrumAddresses.USDC);
        OracleUtils.SetPricesParams memory p = _mockAtomicParams(ZORA_P1_DOWN, block.timestamp);
        uint256 proceeds = _executeWithdrawalKeeper(wkey, p);
        console.log("W1c keeper fresh-withdrawal proceeds (USD):", proceeds);
        bytes32 ckey = _createZoraDecrease(4_000e30);
        _executeOrderDirect(ckey);
        require(_positionSizeUsd() == 0, "W1c: short did not close");
        assertLt(proceeds, 2_000, "W1c: keeper fresh withdrawal should redeem < $2,000");
    }

    // Combined stale-vs-fresh keeper-withdrawal comparison in ONE run:
    // snapshot the fresh fork state, run the stale arm, revert, run the
    // fresh arm, and assert the difference directly. This is the headline
    // number for the keeper-withdrawal path.
    function testW1vsW1cStaleMinusFresh() public {
        uint256 snap = vm.snapshot();
        uint256 t0 = block.timestamp;
        // ---- stale arm (W1) ----
        _deposit2000();
        bytes32 okey = _createZoraShort(4_000e30, 3500e6);
        _executeOrderDirect(okey);
        bytes32 wkey = _createWithdrawalAll();
        curZoraPx = ZORA_P1_DOWN;
        vm.warp(t0 + 299);
        _registerMock(ZORA);
        _registerMock(GmxArbitrumAddresses.WETH);
        _registerMock(GmxArbitrumAddresses.USDC);
        OracleUtils.SetPricesParams memory pStale = _mockAtomicParams(ZORA_P0, t0);
        uint256 proceedsStale = _executeWithdrawalKeeper(wkey, pStale);
        bytes32 ckey = _createZoraDecrease(4_000e30);
        _executeOrderDirect(ckey);
        // ---- fresh arm (W1c) from the identical snapshot ----
        vm.revertTo(snap);
        t0 = block.timestamp;
        _deposit2000();
        okey = _createZoraShort(4_000e30, 3500e6);
        _executeOrderDirect(okey);
        wkey = _createWithdrawalAll();
        curZoraPx = ZORA_P1_DOWN;
        vm.warp(t0 + 299);
        _registerMock(ZORA);
        _registerMock(GmxArbitrumAddresses.WETH);
        _registerMock(GmxArbitrumAddresses.USDC);
        OracleUtils.SetPricesParams memory pFresh = _mockAtomicParams(ZORA_P1_DOWN, block.timestamp);
        uint256 proceedsFresh = _executeWithdrawalKeeper(wkey, pFresh);
        ckey = _createZoraDecrease(4_000e30);
        _executeOrderDirect(ckey);
        console.log("W1 vs W1c stale proceeds (USD):", proceedsStale);
        console.log("W1 vs W1c fresh proceeds (USD):", proceedsFresh);
        console.log("W1 vs W1c stale-minus-fresh (USD):", proceedsStale - proceedsFresh);
        assertGt(proceedsStale, proceedsFresh, "stale keeper withdrawal must redeem more than fresh");
        assertGe(proceedsStale - proceedsFresh, 80, "stale-minus-fresh below expected band");
        assertLe(proceedsStale - proceedsFresh, 120, "stale-minus-fresh above expected band");
    }
}
