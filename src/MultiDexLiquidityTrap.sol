// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ITrap} from "./interfaces/ITrap.sol";

interface IUniswapV2Pair {
    function getReserves() external view returns (uint112 r0, uint112 r1, uint32 ts);
}

interface IUniswapV3Pool {
    function liquidity() external view returns (uint128);
}

/**
 * @title MultiDexLiquidityTrap
 * @notice Detects cross-DEX liquidity migration from a primary pool to others.
 * @dev Designed to be Drosera-compliant:
 *      - collect() may read on-chain state
 *      - shouldRespond() / shouldAlert() MUST be pure
 */
contract MultiDexLiquidityTrap is ITrap {
    /* -------------------------------------------------------------------------- */
    /*                                Custom Owner                                */
    /* -------------------------------------------------------------------------- */

    address public owner;

    modifier onlyOwner() {
        require(msg.sender == owner, "NOT_OWNER");
        _;
    }

    /* -------------------------------------------------------------------------- */
    /*                               Trap Constants                               */
    /* -------------------------------------------------------------------------- */

    uint256 public constant MAX_POOLS = 8;

    uint256 public constant DROP_THRESHOLD_PCT = 40;
    uint256 public constant COMPENSATION_THRESHOLD_PCT = 50;
    uint256 public constant MIN_TOTAL_LIQUIDITY = 1;
    uint256 public constant MIN_CONFIRM_BLOCKS = 2;

    /* -------------------------------------------------------------------------- */
    /*                               Trap Storage                                 */
    /* -------------------------------------------------------------------------- */

    address[] public pools; // pools[0] = primary pool

    /* -------------------------------------------------------------------------- */
    /*                                   Events                                   */
    /* -------------------------------------------------------------------------- */

    event PoolsUpdated(address[] pools);

    /* -------------------------------------------------------------------------- */
    /*                                Constructor                                 */
    /* -------------------------------------------------------------------------- */

    constructor() {
        owner = address(0);
    }

    function setOwner(address newOwner) external {
        require(owner == address(0), "OWNER_ALREADY_SET");
        require(newOwner != address(0), "ZERO_OWNER");
        owner = newOwner;
    }

    /* -------------------------------------------------------------------------- */
    /*                                  COLLECT                                   */
    /* -------------------------------------------------------------------------- */

    function collect() external view override returns (bytes memory) {
        uint256 length = pools.length;

        uint256[] memory perPool = new uint256[](length);
        for (uint256 i = 0; i < length; i++) {
            perPool[i] = _getPoolLiquidityApprox(pools[i]);
        }

        return abi.encode(
            uint64(block.timestamp),
            uint256(block.number),
            pools,
            perPool
        );
    }

    /* -------------------------------------------------------------------------- */
    /*                               SHOULD RESPOND                               */
    /* -------------------------------------------------------------------------- */

    function shouldRespond(bytes[] calldata data)
        external
        pure
        override
        returns (bool, bytes memory)
    {
        return _evaluate(data);
    }

    /* -------------------------------------------------------------------------- */
    /*                                SHOULD ALERT                                */
    /* -------------------------------------------------------------------------- */

    /**
     * @notice Used by Drosera Alerts (Slack, webhooks, UI)
     */
    function shouldAlert(bytes[] calldata data)
        external
        pure
        returns (bool, bytes memory)
    {
        return _evaluate(data);
    }

    /* -------------------------------------------------------------------------- */
    /*                         ALERT OUTPUT DECODER                                */
    /* -------------------------------------------------------------------------- */

    /**
     * @notice Decodes alert payload for Slack / webhook formatting
     */
    function decodeAlertOutput(bytes calldata data)
        public
        pure
        returns (
            address primaryPool,
            uint256 blockNumber,
            uint256 currTotal,
            uint256 currPrimary,
            uint256 dropPct,
            uint256 otherIncreasePct,
            uint64 timestamp
        )
    {
        return abi.decode(
            data,
            (address, uint256, uint256, uint256, uint256, uint256, uint64)
        );
    }

    /* -------------------------------------------------------------------------- */
    /*                         SHARED EVALUATION LOGIC                             */
    /* -------------------------------------------------------------------------- */

    function _evaluate(bytes[] calldata data)
        private
        pure
        returns (bool, bytes memory)
    {
        if (data.length < 2) return (false, "");

        (
            uint64 tsNew,
            uint256 blkNew,
            address[] memory poolsNew,
            uint256[] memory liqsNew
        ) = abi.decode(data[0], (uint64, uint256, address[], uint256[]));

        (
            ,
            uint256 blkPrev,
            ,
            uint256[] memory liqsPrev
        ) = abi.decode(data[1], (uint64, uint256, address[], uint256[]));

        if (liqsPrev.length == 0 || liqsNew.length != liqsPrev.length) {
            return (false, "");
        }

        uint256 prevTotal;
        uint256 currTotal;

        for (uint256 i = 0; i < liqsPrev.length; i++) {
            prevTotal += liqsPrev[i];
            currTotal += liqsNew[i];
        }

        if (prevTotal < MIN_TOTAL_LIQUIDITY) return (false, "");
        if (blkNew < blkPrev + MIN_CONFIRM_BLOCKS) return (false, "");

        uint256 prevPrimary = liqsPrev[0];
        uint256 currPrimary = liqsNew[0];

        if (prevPrimary == 0 || currPrimary >= prevPrimary) return (false, "");

        uint256 dropPct =
            ((prevPrimary - currPrimary) * 100) / prevPrimary;

        if (dropPct < DROP_THRESHOLD_PCT) return (false, "");

        uint256 prevOther = prevTotal - prevPrimary;
        uint256 currOther = currTotal - currPrimary;

        uint256 otherIncreasePct = 0;
        if (prevOther > 0 && currOther > prevOther) {
            otherIncreasePct =
                ((currOther - prevOther) * 100) / prevOther;
        }

        uint256 compensationPct =
            (otherIncreasePct * 100) / dropPct;

        if (compensationPct >= COMPENSATION_THRESHOLD_PCT) return (false, "");

        bytes memory payload = abi.encode(
            poolsNew[0],
            blkNew,
            currTotal,
            currPrimary,
            dropPct,
            otherIncreasePct,
            tsNew
        );

        return (true, payload);
    }

    /* -------------------------------------------------------------------------- */
    /*                              ADMIN FUNCTIONS                               */
    /* -------------------------------------------------------------------------- */

    function updatePools(address[] calldata _pools) external onlyOwner {
        require(_pools.length > 0 && _pools.length <= MAX_POOLS, "invalid pools");
        pools = _pools;
        emit PoolsUpdated(_pools);
    }

    /* -------------------------------------------------------------------------- */
    /*                         INTERNAL LIQUIDITY HELPERS                          */
    /* -------------------------------------------------------------------------- */

    function _getPoolLiquidityApprox(address pool)
        internal
        view
        returns (uint256)
    {
        try IUniswapV2Pair(pool).getReserves()
            returns (uint112 r0, uint112 r1, uint32)
        {
            return uint256(r0) + uint256(r1);
        } catch {}

        try IUniswapV3Pool(pool).liquidity()
            returns (uint128 L)
        {
            return uint256(L);
        } catch {}

        return 0;
    }
}
