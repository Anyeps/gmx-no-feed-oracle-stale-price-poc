// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/**
 * @title MockOracleProvider7
 * @notice Mock oracle provider returning the DEPLOYED GMX Oracle's 7-word
 * ValidatedPrice layout.
 * @dev CORRECTED layout (G-P1-7, 2026-11-15): the deployed struct is
 *   (token, min, max, minOracleBlockNumber, maxOracleBlockNumber, timestamp, provider)
 * NOT the (token, min, max, provider, feedId, timestamp, extra) layout
 * G-P0-8 documented. Evidence (GP17DebugTest, fork 524281269):
 *   - _validatePrices reads min/max from words 1,2 (ref check uses word1).
 *   - _setPrices enforces word3 <= word4, else
 *     InvalidMinMaxForPrice(token, word3, word4) -- i.e. words 3,4 are a
 *     (min,max) block-number pair, not (provider, feedId).
 *   - timestamp is read from word 5 (G-P0-8 was right about that).
 *   - provider is read from word 6.
 * A mock returning (token, min, max, provider-addr, feedId=0, ts, 0) fails
 * _setPrices because provider-addr (huge) > 0. This mock sets
 * minBlock = block.number - 1, maxBlock = block.number, so the check passes.
 */
contract MockOracleProvider7 {
    struct ValidatedPrice7 {
        address token;
        uint256 min;
        uint256 max;
        uint256 minOracleBlockNumber;
        uint256 maxOracleBlockNumber;
        uint256 timestamp;
        address provider;
    }

    mapping(address => uint256) public minPrices;
    mapping(address => uint256) public maxPrices;
    mapping(address => uint256) public timestamps; // 0 = block.timestamp
    bool public checkRefPrice = true;

    function setPrice(address token, uint256 minPrice, uint256 maxPrice) external {
        minPrices[token] = minPrice;
        maxPrices[token] = maxPrice;
    }

    function setTimestamp(address token, uint256 ts) external {
        timestamps[token] = ts;
    }

    /// The deployed IOracleProvider has shouldCheckRefPrice(), which the repo
    /// interface lacks. The deployed Oracle consults it before running the
    /// ref-price deviation check: a provider that returns false skips the
    /// check entirely for its tokens.
    function setCheckRefPrice(bool v) external {
        checkRefPrice = v;
    }

    function shouldCheckRefPrice() external view returns (bool) {
        return checkRefPrice;
    }

    function getOraclePrice(address token, bytes memory /* data */)
        external
        returns (ValidatedPrice7 memory validatedPrice)
    {
        uint256 ts = timestamps[token];
        if (ts == 0) {
            ts = block.timestamp;
        }
        validatedPrice.token = token;
        validatedPrice.min = minPrices[token];
        validatedPrice.max = maxPrices[token];
        validatedPrice.minOracleBlockNumber = block.number - 1;
        validatedPrice.maxOracleBlockNumber = block.number;
        validatedPrice.timestamp = ts;
        validatedPrice.provider = address(this);
        return validatedPrice;
    }

    function shouldAdjustTimestamp() external pure returns (bool) {
        return false;
    }

    function isChainlinkOnChainProvider() external pure returns (bool) {
        return false;
    }
}
