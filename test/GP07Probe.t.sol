// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

// GMX lead G-P0-7 — probe: live ZORA market state at a fresh fork block.
// Read-only: pool amounts, open interest, GM supply, oracle config.
// No orders, no deposits — just state reads to size the fork tests.

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../contracts/utils/GmxForkHelpers.sol";
import "../contracts/constants/GmxArbitrumAddresses.sol";
import "../contracts/interfaces/IGmxV2.sol";
import {Keys as GmxKeys} from "../contracts/Keys.sol";

contract GP07ProbeTest is GmxForkHelpers {
    uint256 constant FORK_BLOCK = 524367000;
    address constant M_ZORA = 0xac484106d935f0f20F1485b631fA6F65AeEff550;
    address constant ZORA = 0xc5ff0eB026dB972F95DF3dfF04e697d8b660092a;
    uint256 constant USDC_PX = 1e24;

    function setUp() public {
        vm.createSelectFork("https://arb1.arbitrum.io/rpc", FORK_BLOCK);
        exchangeRouter = IExchangeRouter(GmxArbitrumAddresses.EXCHANGE_ROUTER);
        orderHandler = IOrderHandler(GmxArbitrumAddresses.ORDER_HANDLER);
        oracle = IOracle(GmxArbitrumAddresses.ORACLE);
        dataStore = IDataStore(GmxArbitrumAddresses.DATA_STORE);
        roleStore = IRoleStore(GmxArbitrumAddresses.ROLE_STORE);
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

    function testProbeZoraState() public view {
        (uint256 wethPx, bool ok) = _feedPrice(GmxArbitrumAddresses.WETH);
        require(ok, "no weth feed");
        console.log("fork block:", block.number);
        console.log("block.timestamp:", block.timestamp);
        console.log("WETH feed price (USD x 1e12):", wethPx);

        // oracle config
        console.log("MAX_ORACLE_PRICE_AGE:", dataStore.getUint(GmxKeys.MAX_ORACLE_PRICE_AGE));
        console.log("MAX_ATOMIC_ORACLE_PRICE_AGE:", dataStore.getUint(GmxKeys.MAX_ATOMIC_ORACLE_PRICE_AGE));
        console.log("MAX_ORACLE_REF_PRICE_DEVIATION_FACTOR:", dataStore.getUint(GmxKeys.MAX_ORACLE_REF_PRICE_DEVIATION_FACTOR));
        console.log("ZORA priceFeed (expect 0):", dataStore.getAddress(GmxKeys.priceFeedKey(ZORA)));
        console.log(
            "ZORA provider oracle1:",
            dataStore.getAddress(GmxKeys.oracleProviderForTokenKey(GmxArbitrumAddresses.ORACLE, ZORA))
        );
        address oracle2 = 0x7F01614cA5198Ec979B1aAd1DAF0DE7e0a215BDF;
        console.log("ZORA provider oracle2:", dataStore.getAddress(GmxKeys.oracleProviderForTokenKey(oracle2, ZORA)));
        address atomicProv = 0xE1d5a068c5b75E0c7Ea1A9Fe8EA056f9356C6fFD;
        console.log("atomic provider enabled:", dataStore.getBool(GmxKeys.isOracleProviderEnabledKey(atomicProv)));
        console.log("atomic provider isAtomic:", dataStore.getBool(GmxKeys.isAtomicOracleProviderKey(atomicProv)));
        console.log(
            "atomic-withdrawal feature disabled (expect false):",
            dataStore.getBool(GmxKeys.executeAtomicWithdrawalFeatureDisabledKey(GmxArbitrumAddresses.WITHDRAWAL_HANDLER))
        );

        // pool state
        uint256 poolWeth = dataStore.getUint(GmxKeys.poolAmountKey(M_ZORA, GmxArbitrumAddresses.WETH));
        uint256 poolUsdc = dataStore.getUint(GmxKeys.poolAmountKey(M_ZORA, GmxArbitrumAddresses.USDC));
        console.log("ZORA pool WETH (wei):", poolWeth);
        console.log("ZORA pool USDC (6dp):", poolUsdc);
        console.log("ZORA pool long USD (1e30):", poolWeth * wethPx);
        console.log("ZORA pool short USD (1e30):", poolUsdc * USDC_PX);
        console.log(
            "ZORA OI long USD (1e30):",
            dataStore.getUint(GmxKeys.openInterestKey(M_ZORA, GmxArbitrumAddresses.WETH, true))
        );
        console.log(
            "ZORA OI short USD (1e30):",
            dataStore.getUint(GmxKeys.openInterestKey(M_ZORA, GmxArbitrumAddresses.USDC, false))
        );
        console.log("ZORA GM totalSupply (wei):", IERC20(M_ZORA).totalSupply());
    }
}
