// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

// GMX lead G-P0-7 — keeper path: no-feed ZORA market, 299s-old report.
//
// ZORA has NO Chainlink price feed (PRICE_FEED = 0), so Oracle._validatePrices
// skips the 50% reference-deviation check entirely. Only the 300s age and
// 60s timestamp-range checks bind. A keeper submitting a 299s-old report from
// before a price move fills the order at the stale price.
//
//   K1:  $2,000 ZORA long, +25% pump, execute at T0+299 with the T0 report.
//   K1c: control — same order, fresh report at the pumped price.
//   K2:  301s-old report reverts MaxPriceAgeExceeded (age bound still binds).
//   K3:  +10% move — gain scales with the move.
//   K4:  $4,000 ZORA long, +25% pump (bigger size, reserve headroom ~$5k).
//
// Caveat recorded with every number: execution needs a keeper to submit the
// stale report (users cannot self-execute) — the same bar G-P0-1 failed on,
// except here there is NO configured tolerance to be inside of.

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../contracts/utils/GmxForkHelpers.sol";
import "../contracts/constants/GmxArbitrumAddresses.sol";
import "../contracts/interfaces/IGmxV2.sol";
import {Keys as GmxKeys} from "../contracts/Keys.sol";
import "../contracts/mock/MockOracleProvider7.sol";

contract GP07KeeperTest is GmxForkHelpers {
    uint256 constant FORK_BLOCK = 524367000;
    address constant M_ZORA = 0xac484106d935f0f20F1485b631fA6F65AeEff550;
    address constant ZORA = 0xc5ff0eB026dB972F95DF3dfF04e697d8b660092a;
    uint256 constant USDC_PX = 1e24;
    uint256 constant GAS_PRICE = 0.1 gwei;
    uint256 constant STD_FEE = 0.001 ether;

    // ZORA price (GMX format, 18dp placeholder): $0.004431, GMX API 15 Nov ~12:00 WIB.
    uint256 constant ZORA_P0 = 4431264904;
    uint256 constant ZORA_P1 = 5539081130; // +25%
    uint256 constant ZORA_P1_10 = 4874391394; // +10%

    bytes32 constant SIZE_IN_USD_KEY = keccak256(abi.encode("SIZE_IN_USD"));
    bytes32 constant SIZE_IN_TOKENS_KEY = keccak256(abi.encode("SIZE_IN_TOKENS"));

    address internal trader = address(0x7Ade);
    address internal keeper;
    IERC20 internal weth;
    IERC20 internal usdc;
    MockOracleProvider7 internal mock7;
    uint256 internal wethPx;

    function setUp() public {
        vm.createSelectFork("https://arb1.arbitrum.io/rpc", FORK_BLOCK);
        exchangeRouter = IExchangeRouter(GmxArbitrumAddresses.EXCHANGE_ROUTER);
        orderHandler = IOrderHandler(GmxArbitrumAddresses.ORDER_HANDLER);
        oracle = IOracle(GmxArbitrumAddresses.ORACLE);
        dataStore = IDataStore(GmxArbitrumAddresses.DATA_STORE);
        roleStore = IRoleStore(GmxArbitrumAddresses.ROLE_STORE);
        weth = IERC20(GmxArbitrumAddresses.WETH);
        usdc = IERC20(GmxArbitrumAddresses.USDC);

        vm.deal(trader, 100 ether);
        deal(address(weth), trader, 1000 ether);
        deal(address(usdc), trader, 10_000_000e6);
        vm.prank(trader);
        weth.approve(address(exchangeRouter), type(uint256).max);
        vm.prank(trader);
        weth.approve(GmxArbitrumAddresses.ROUTER, type(uint256).max);
        vm.prank(trader);
        usdc.approve(address(exchangeRouter), type(uint256).max);
        vm.prank(trader);
        usdc.approve(GmxArbitrumAddresses.ROUTER, type(uint256).max);

        keeper = _firstRoleMember(Keys.ORDER_KEEPER);
        vm.deal(keeper, 10 ether);

        (uint256 px, bool ok) = _feedPrice(GmxArbitrumAddresses.WETH);
        require(ok, "no weth feed");
        wethPx = px;

        mock7 = new MockOracleProvider7();
        _registerMock(ZORA);
        _registerMock(GmxArbitrumAddresses.WETH);
        _registerMock(GmxArbitrumAddresses.USDC);
    }

    // ------------------------------------------------------------------ helpers

    function _firstRoleMember(bytes32 role) internal view returns (address) {
        uint256 n = roleStore.getRoleMemberCount(role);
        require(n > 0, "role empty");
        return roleStore.getRoleMembers(role, 0, n)[0];
    }

    function _registerMock(address token) internal {
        vm.prank(GmxArbitrumAddresses.EXCHANGE_ROUTER);
        dataStore.setAddress(
            GmxKeys.oracleProviderForTokenKey(GmxArbitrumAddresses.ORACLE, token),
            address(mock7)
        );
        vm.prank(GmxArbitrumAddresses.EXCHANGE_ROUTER);
        dataStore.setBool(GmxKeys.isOracleProviderEnabledKey(address(mock7)), true);
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

    function _clearPrices() internal {
        vm.prank(GmxArbitrumAddresses.EXCHANGE_ROUTER);
        oracle.clearAllPrices();
    }

    function _mockParams(uint256 zoraPx, uint256 ts) internal returns (OracleUtils.SetPricesParams memory p) {
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

    function _positionKey(address account, address market, address collateralToken, bool isLong)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(account, market, collateralToken, isLong));
    }

    function _positionSizeUsd(address account, address market, address collateralToken, bool isLong)
        internal
        view
        returns (uint256)
    {
        return dataStore.getUint(
            keccak256(abi.encode(_positionKey(account, market, collateralToken, isLong), SIZE_IN_USD_KEY))
        );
    }

    function _positionSizeInTokens(address account, address market, address collateralToken, bool isLong)
        internal
        view
        returns (uint256)
    {
        return dataStore.getUint(
            keccak256(abi.encode(_positionKey(account, market, collateralToken, isLong), SIZE_IN_TOKENS_KEY))
        );
    }

    function _createZoraLong(uint256 sizeUsd, uint256 collateralWeth) internal returns (bytes32) {
        IExchangeRouter.CreateOrderParams memory params =
            createIncreaseOrderParams(M_ZORA, GmxArbitrumAddresses.WETH, collateralWeth, sizeUsd, true);
        params.orderType = IExchangeRouter.OrderType.MarketIncrease;
        params.numbers.executionFee = STD_FEE;
        params.numbers.acceptablePrice = type(uint256).max;
        params.numbers.minOutputAmount = 0;
        params.numbers.callbackGasLimit = 0;
        params.numbers.validFromTime = 0;
        params.addresses.receiver = trader;
        params.addresses.cancellationReceiver = trader;
        params.autoCancel = false;
        params.shouldUnwrapNativeToken = false;
        vm.txGasPrice(GAS_PRICE);
        vm.startPrank(trader);
        params.numbers.initialCollateralDeltaAmount = collateralWeth + STD_FEE;
        exchangeRouter.sendWnt{value: collateralWeth + STD_FEE}(GmxArbitrumAddresses.ORDER_VAULT, collateralWeth + STD_FEE);
        bytes32 key = exchangeRouter.createOrder{value: 0}(params);
        vm.stopPrank();
        return key;
    }

    function _execMock(bytes32 key, OracleUtils.SetPricesParams memory p) internal {
        _clearPrices();
        vm.txGasPrice(GAS_PRICE);
        vm.prank(keeper);
        orderHandler.executeOrder(key, p);
    }

    // value of `tokens` (ZORA, 18dp) at price px (GMX format) in plain USD
    // (tokens_wei * px / 1e30 = tokens * USD, NOT 1e30-scaled — see G-P0-1 D1)
    function _valueAt(uint256 tokens, uint256 px) internal pure returns (uint256) {
        return (tokens * px) / 1e30;
    }

    // ------------------------------------------------------------------ K1 / K1c

    // K1: $2,000 long created at T0; executed at T0+299 with the T0 report
    // (ZORA $0.004431) while the market has pumped +25%. Fill is at the
    // stale price — the position is worth ~$2,500 at the pumped price.
    function testK1StaleFillAfterPump25() public {
        uint256 t0 = block.timestamp;
        bytes32 key = _createZoraLong(2_000e30, 1 ether);
        vm.warp(t0 + 299);
        uint256 reportTs = block.timestamp - 299; // == t0 (recomputed post-warp; see G-P0-1 C2 note)
        OracleUtils.SetPricesParams memory p = _mockParams(ZORA_P0, reportTs);
        _execMock(key, p);
        assertEq(_positionSizeUsd(trader, M_ZORA, GmxArbitrumAddresses.WETH, true), 2_000e30);
        uint256 tokens = _positionSizeInTokens(trader, M_ZORA, GmxArbitrumAddresses.WETH, true);
        uint256 valueAtP1 = _valueAt(tokens, ZORA_P1);
        console.log("K1 stale-fill sizeInTokens (wei):", tokens);
        console.log("K1 expected tokens at P0:", 2_000e30 / ZORA_P0);
        console.log("K1 position value at pumped P1 (USD):", valueAtP1);
        console.log("K1 stale-fill gain vs $2,000 size (USD):", valueAtP1 > 2_000 ? valueAtP1 - 2_000 : 0);
        assertGt(valueAtP1, 2_400, "K1: stale fill should be worth > $2,400 at P1");
    }

    // K1c: control — same $2,000 order, executed at T0+299 with a FRESH
    // report at the pumped price. Compare sizeInTokens with K1.
    function testK1cFreshControlAfterPump25() public {
        uint256 t0 = block.timestamp;
        bytes32 key = _createZoraLong(2_000e30, 1 ether);
        vm.warp(t0 + 299);
        OracleUtils.SetPricesParams memory p = _mockParams(ZORA_P1, block.timestamp);
        _execMock(key, p);
        assertEq(_positionSizeUsd(trader, M_ZORA, GmxArbitrumAddresses.WETH, true), 2_000e30);
        uint256 tokens = _positionSizeInTokens(trader, M_ZORA, GmxArbitrumAddresses.WETH, true);
        console.log("K1c fresh-fill sizeInTokens (wei):", tokens);
        console.log("K1c expected tokens at P1:", 2_000e30 / ZORA_P1);
        console.log("K1c position value at P1 (USD):", _valueAt(tokens, ZORA_P1));
    }

    // K2: a 301s-old report inside executeOrder reverts MaxPriceAgeExceeded —
    // the 300s age bound still binds for no-feed tokens; only the deviation
    // check is missing.
    function testK2Report301sOldReverts() public {
        uint256 t0 = block.timestamp;
        bytes32 key = _createZoraLong(2_000e30, 1 ether);
        OracleUtils.SetPricesParams memory p = _mockParams(ZORA_P0, t0 - 301);
        _clearPrices();
        vm.txGasPrice(GAS_PRICE);
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSignature("MaxPriceAgeExceeded(uint256,uint256)", t0 - 301, t0)
        );
        orderHandler.executeOrder(key, p);
        console.log("K2 301s-old report reverts MaxPriceAgeExceeded as expected");
    }

    // K3: +10% move — the stale-fill gain scales with the move (~$200 on $2,000).
    function testK3StaleFillAfterPump10() public {
        uint256 t0 = block.timestamp;
        bytes32 key = _createZoraLong(2_000e30, 1 ether);
        vm.warp(t0 + 299);
        uint256 reportTs = block.timestamp - 299;
        OracleUtils.SetPricesParams memory p = _mockParams(ZORA_P0, reportTs);
        _execMock(key, p);
        uint256 tokens = _positionSizeInTokens(trader, M_ZORA, GmxArbitrumAddresses.WETH, true);
        uint256 valueAtP1 = _valueAt(tokens, ZORA_P1_10);
        console.log("K3 stale-fill sizeInTokens (wei):", tokens);
        console.log("K3 position value at +10% price (USD):", valueAtP1);
        console.log("K3 stale-fill gain (USD):", valueAtP1 > 2_000 ? valueAtP1 - 2_000 : 0);
        assertGt(valueAtP1, 2_150, "K3: stale fill should be worth > $2,150 at +10%");
    }

    // K4: $4,000 long (reserve headroom ~$5k), +25% pump, stale fill.
    function testK4StaleFillLargeAfterPump25() public {
        uint256 t0 = block.timestamp;
        bytes32 key = _createZoraLong(4_000e30, 2 ether);
        vm.warp(t0 + 299);
        uint256 reportTs = block.timestamp - 299;
        OracleUtils.SetPricesParams memory p = _mockParams(ZORA_P0, reportTs);
        _execMock(key, p);
        assertEq(_positionSizeUsd(trader, M_ZORA, GmxArbitrumAddresses.WETH, true), 4_000e30);
        uint256 tokens = _positionSizeInTokens(trader, M_ZORA, GmxArbitrumAddresses.WETH, true);
        uint256 valueAtP1 = _valueAt(tokens, ZORA_P1);
        console.log("K4 stale-fill sizeInTokens (wei):", tokens);
        console.log("K4 expected tokens at P0:", 4_000e30 / ZORA_P0);
        console.log("K4 position value at pumped P1 (USD):", valueAtP1);
        console.log("K4 stale-fill gain vs $4,000 size (USD):", valueAtP1 > 4_000 ? valueAtP1 - 4_000 : 0);
        assertGt(valueAtP1, 4_800, "K4: stale fill should be worth > $4,800 at P1");
    }
}
