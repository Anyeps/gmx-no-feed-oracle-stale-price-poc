// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * GMX Synthetics V2 contract addresses on Arbitrum mainnet
 * @dev All addresses from official GMX deployments
 * @dev Source: https://github.com/gmx-io/gmx-synthetics/blob/main/docs/arbitrum-deployments.md
 * @dev Last Updated: Aug 13, 2025
 */
library GmxArbitrumAddresses {
    // ============ Core Protocol Contracts ============

    /// Central key-value store for all protocol data
    address internal constant DATA_STORE = 0xFD70de6b91282D8017aA4E741e9Ae325CAb992d8;

    /// Role-based access control
    address internal constant ROLE_STORE = 0x3c3d99FD298f679DBC2CEcd132b4eC4d0F5e6e72;

    /// Reader contract for querying protocol state
    /// @dev UPDATED 2026-11-14: verified live via docs + on-chain (old 0x65A6CC45... was stale)
    address internal constant READER = 0xfA26cBb46e2614609406de08CA1Dc7f70a684184;

    /// Router contract for plugin transfers
    address internal constant ROUTER = 0x7452c558d45f8afC8c83dAe62C3f8A5BE19c71f6;

    /// Main entry point for creating deposits, withdrawals, and orders
    /// @dev UPDATED 2026-11-14: verified live — hasRole(CONTROLLER)==true (old 0x87d66368... was stale, CONTROLLER==false)
    address internal constant EXCHANGE_ROUTER = 0x7dE39FF2e232A2203196788d37e234cF8F1b83f1;

    /// Handles order execution logic
    /// @dev UPDATED 2026-11-14: verified live via ExchangeRouter.orderHandler() getter (old 0x04315E23... was stale)
    address internal constant ORDER_HANDLER = 0xa5D2d45228ee2E3A18AB122B2cE84997d008f4Eb;

    /// Handles liquidations (keeper only)
    /// @dev VERIFIED 2026-11-14: the deployments doc still lists 0xaf157E...,
    ///      but that address has NO CONTROLLER role (hasRole == false) and its
    ///      decreaseOrderExecutor differs. The LIVE handler is 0x01B85C...,
    ///      identified by (a) holding CONTROLLER, (b) exposing the
    ///      executeLiquidation selector, (c) sharing decreaseOrderExecutor
    ///      0x05920F57... with the live OrderHandler 0xa5D2d4...
    address internal constant LIQUIDATION_HANDLER = 0x01B85C1e0682418f59C4fe37A2cC56c1213C1fa8;

    /// Oracle contract for price feeds
    /// @dev UPDATED 2026-11-14: verified live via OrderHandler.oracle() getter (old 0x7F01614c... was stale)
    address internal constant ORACLE = 0x26C02F221e8dB5A821e12347C7eA8a6b6E10842f;

    /// Oracle price store
    address internal constant ORACLE_STORE = 0xA8AF9B86fC47deAde1bc66B12673706615E2B011;

    /// Chainlink Data Streams oracle provider
    /// @dev UPDATED 2026-11-14: verified live via DataStore oracleProviderForTokenKey
    ///      for WETH and USDC (old 0xE1d5a068... was stale, Oracle reverts
    ///      InvalidOracleProviderForToken for it). This is the CURRENT
    ///      Chainlink Data Streams provider on Arbitrum.
    address internal constant CHAINLINK_DATA_STREAM_PROVIDER = 0x7BA7Ae61887F1aca28E0FE5aB1434ce85b6606aa;

    /// Order vault - holds collateral for pending orders
    address internal constant ORDER_VAULT = 0x31eF83a530Fde1B38EE9A18093A333D8Bbbc40D5;

    /// Deposit handler
    /// @dev UPDATED 2026-11-14: verified live via ExchangeRouter.depositHandler() getter
    address internal constant DEPOSIT_HANDLER = 0x2c60a1890E24a727ccF504A9dA9912ace58b2EAD;

    /// Withdrawal handler
    /// @dev UPDATED 2026-11-14: verified live via ExchangeRouter.withdrawalHandler() getter
    address internal constant WITHDRAWAL_HANDLER = 0xB25dDF7dE751e5c8bFa85c815d1b379732cF4925;

    /// Event emitter
    address internal constant EVENT_EMITTER = 0xC8ee91A54287DB53897056e12D9819156D3822Fb;

    /// Deposit vault
    address internal constant DEPOSIT_VAULT = 0xF89e77e8Dc11691C9e8757e84aaFbCD8A67d7A55;

    /// Withdrawal vault
    address internal constant WITHDRAWAL_VAULT = 0x0628D46b5D145f183AdB6Ef1f2c97eD1C4701C55;

    // ============ Markets ============

    /// ETH/USD perp market
    /// @dev Long collateral: WETH, Short collateral: USDC, Index: WETH
    address internal constant ETH_USD_MARKET = 0x70d95587d40A2caf56bd97485aB3Eec10Bee6336;

    /// BTC/USD perp market
    /// @dev Long collateral: WBTC, Short collateral: USDC, Index: WBTC
    address internal constant BTC_USD_MARKET = 0x47c031236e19d024b42f8AE6780E44A573170703;

    // ============ Tokens ============

    /// Wrapped ETH on Arbitrum
    address internal constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;

    /// Native USDC on Arbitrum (not bridged)
    address internal constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    /// Wrapped BTC on Arbitrum
    address internal constant WBTC = 0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f;

    /// USDC.e (bridged USDC from Ethereum)
    address internal constant USDC_E = 0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8;
}
