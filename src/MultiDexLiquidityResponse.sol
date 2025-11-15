// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title MultiDexLiquidityResponse
/// @notice Receives alerts and emits structured logs for off-chain consumption.
contract MultiDexLiquidityResponse {
    event MultiDexLiquidityAlertEvent(
        address indexed primaryPool,
        uint256 indexed blockNumber,
        uint256 currTotal,
        uint256 currPrimary,
        uint256 dropPct,
        uint256 otherIncreasePct,
        uint64 timestamp
    );

    /// Decodes payload: (primaryPool, currBlock, currTotal, currPrimary, dropPct, otherIncreasePct, timestamp)
    function respondToLiquidityAlert(bytes calldata payload) external {
        (
            address primaryPool,
            uint256 currBlock,
            uint256 currTotal,
            uint256 currPrimary,
            uint256 dropPct,
            uint256 otherIncreasePct,
            uint64 timestamp
        ) = abi.decode(payload, (address, uint256, uint256, uint256, uint256, uint256, uint64));

        emit MultiDexLiquidityAlertEvent(primaryPool, currBlock, currTotal, currPrimary, dropPct, otherIncreasePct, timestamp);
    }
}

