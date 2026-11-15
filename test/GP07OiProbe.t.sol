// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../contracts/utils/GmxForkHelpers.sol";
import "../contracts/constants/GmxArbitrumAddresses.sol";
import {Keys as GmxKeys} from "../contracts/Keys.sol";

contract GP07OiProbeTest is GmxForkHelpers {
    uint256 constant FORK_BLOCK = 524367000;
    address constant M_ZORA = 0xac484106d935f0f20F1485b631fA6F65AeEff550;

    function setUp() public {
        vm.createSelectFork("https://arb1.arbitrum.io/rpc", FORK_BLOCK);
        dataStore = IDataStore(GmxArbitrumAddresses.DATA_STORE);
    }

    function testOiAllFour() public view {
        address weth = GmxArbitrumAddresses.WETH;
        address usdc = GmxArbitrumAddresses.USDC;
        console.log("OI long  WETH-collat raw:", dataStore.getUint(GmxKeys.openInterestKey(M_ZORA, weth, true)));
        console.log("OI long  USDC-collat raw:", dataStore.getUint(GmxKeys.openInterestKey(M_ZORA, usdc, true)));
        console.log("OI short WETH-collat raw:", dataStore.getUint(GmxKeys.openInterestKey(M_ZORA, weth, false)));
        console.log("OI short USDC-collat raw:", dataStore.getUint(GmxKeys.openInterestKey(M_ZORA, usdc, false)));
        console.log("pool WETH (wei):", dataStore.getUint(GmxKeys.poolAmountKey(M_ZORA, weth)));
        console.log("pool USDC (6dp):", dataStore.getUint(GmxKeys.poolAmountKey(M_ZORA, usdc)));
        console.log("maxPnlFactorForTraders long :", dataStore.getUint(GmxKeys.maxPnlFactorKey(GmxKeys.MAX_PNL_FACTOR_FOR_TRADERS, M_ZORA, true)));
        console.log("maxPnlFactorForTraders short:", dataStore.getUint(GmxKeys.maxPnlFactorKey(GmxKeys.MAX_PNL_FACTOR_FOR_TRADERS, M_ZORA, false)));
        console.log("maxPnlFactorForWithdrawals long :", dataStore.getUint(GmxKeys.maxPnlFactorKey(GmxKeys.MAX_PNL_FACTOR_FOR_WITHDRAWALS, M_ZORA, true)));
        console.log("maxPnlFactorForWithdrawals short:", dataStore.getUint(GmxKeys.maxPnlFactorKey(GmxKeys.MAX_PNL_FACTOR_FOR_WITHDRAWALS, M_ZORA, false)));
        uint256 impactPool = dataStore.getUint(GmxKeys.positionImpactPoolAmountKey(M_ZORA));
        console.log("positionImpactPoolAmount (ZORA wei):", impactPool);
        console.log("impactPoolUsd at P0:", impactPool * 4431264904 / 1e30);
        console.log("impactPoolUsd at P1_DOWN:", impactPool * 3323448678 / 1e30);
        console.log("impactPoolUsd at P1_UP:", impactPool * 5539081130 / 1e30);
        console.log("lentImpactPoolAmount (ZORA wei):", dataStore.getUint(GmxKeys.lentPositionImpactPoolAmountKey(M_ZORA)));
    }
}
