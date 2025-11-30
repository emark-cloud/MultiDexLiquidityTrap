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
 *      - shouldRespond() MUST be pure and only use the provided data
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

    // Thresholds are constants so shouldRespond() can remain pure
    uint256 public constant DROP_THRESHOLD_PCT = 40;          // minimum % drop in primary liquidity
    uint256 public constant COMPENSATION_THRESHOLD_PCT = 50;  // required % compensation from other pools
    uint256 public constant MIN_TOTAL_LIQUIDITY = 1;          // minimal total liquidity to consider
    uint256 public constant MIN_CONFIRM_BLOCKS = 2;           // minimal block gap between snapshots

    /* -------------------------------------------------------------------------- */
    /*                               Trap Storage                                 */
    /* -------------------------------------------------------------------------- */

    // Used by collect() only. shouldRespond() uses only encoded snapshots.
    address[] public pools; // pools[0] is treated as the primary pool in snapshots

    /* -------------------------------------------------------------------------- */
    /*                                   Events                                   */
    /* -------------------------------------------------------------------------- */

    event PoolsUpdated(address[] pools);

    /* -------------------------------------------------------------------------- */
    /*                                Constructor                                 */
    /* -------------------------------------------------------------------------- */

    constructor() {
        // Drosera deploys using a special environment; we cannot rely on msg.sender here.
        // We allow the real owner to claim ownership once via setOwner().
        owner = address(0);
    }

    /**
     * @notice One-time owner setup. First caller sets the owner.
     */
    function setOwner(address newOwner) external {
        require(owner == address(0), "OWNER_ALREADY_SET");
        require(newOwner != address(0), "ZERO_OWNER");
        owner = newOwner;
    }

    /* -------------------------------------------------------------------------- */
    /*                                  COLLECT                                   */
    /* -------------------------------------------------------------------------- */

    /**
     * @notice Snapshot current liquidity across configured pools.
     * @dev Returns ABI-encoded:
     *      (uint64 timestamp, uint256 blockNumber, address[] pools, uint256[] perPoolLiquidity)
     */
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

    /**
     * @notice Decide whether to trigger a response based on two snapshots.
     * @dev MUST be pure for Drosera. It only uses the provided `data` argument.
     *
     *      Expects:
     *      - data[0] = newest snapshot
     *      - data[1] = previous snapshot
     *
     *      Each snapshot is encoded as:
     *      (uint64 timestamp, uint256 blockNumber, address[] pools, uint256[] perPoolLiquidity)
     *
     *      The logic:
     *      - Compute drop % in primary pool (index 0)
     *      - Compute total liquidity before/after
     *      - Compute how much "other pools" (non-primary) increased
     *      - If primary drop >= DROP_THRESHOLD_PCT and other pools do NOT compensate
     *        at least COMPENSATION_THRESHOLD_PCT of that drop, we trigger.
     */
    function shouldRespond(bytes[] calldata data)
        external
        pure
        override
        returns (bool, bytes memory)
    {
        if (data.length < 2) return (false, "");

        (
            uint64 ts_new,
            uint256 blk_new,
            address[] memory pools_new,
            uint256[] memory liqs_new
        ) = abi.decode(data[0], (uint64, uint256, address[], uint256[]));

        (
            ,
            uint256 blk_prev,
            address[] memory pools_prev,
            uint256[] memory liqs_prev
        ) = abi.decode(data[1], (uint64, uint256, address[], uint256[]));

        if (pools_new.length == 0 || pools_prev.length == 0) return (false, "");
        if (pools_new.length != pools_prev.length) return (false, "");
        if (liqs_new.length != liqs_prev.length) return (false, "");

        uint256 length = liqs_prev.length;

        uint256 prevTotal = 0;
        uint256 currTotal = 0;

        for (uint256 i = 0; i < length; i++) {
            prevTotal += liqs_prev[i];
            currTotal += liqs_new[i];
        }

        if (prevTotal < MIN_TOTAL_LIQUIDITY) return (false, "");
        if (blk_new < blk_prev + MIN_CONFIRM_BLOCKS) return (false, "");

        uint256 prevPrimary = liqs_prev[0];
        uint256 currPrimary = liqs_new[0];

        if (prevPrimary == 0) return (false, "");

        uint256 dropPct = 0;
        if (currPrimary < prevPrimary) {
            dropPct = ((prevPrimary - currPrimary) * 100) / prevPrimary;
        } else {
            // primary liquidity didn't drop → no suspicious migration
            return (false, "");
        }

        if (dropPct < DROP_THRESHOLD_PCT) return (false, "");

        uint256 prevOther = prevTotal - prevPrimary;
        uint256 currOther = currTotal - currPrimary;

        uint256 otherIncreasePct = 0;
        if (prevOther > 0 && currOther > prevOther) {
            otherIncreasePct = ((currOther - prevOther) * 100) / prevOther;
        }

        // How much of the primary drop was compensated by other pools?
        uint256 compensationPct = dropPct > 0
            ? (otherIncreasePct * 100) / dropPct
            : 0;

        // If other pools compensated ≥ threshold, consider it benign migration.
        if (compensationPct >= COMPENSATION_THRESHOLD_PCT) return (false, "");

        // Otherwise, treat as suspicious liquidity disappearance.
        bytes memory payload = abi.encode(
            pools_new[0],    // primary pool
            blk_new,         // block
            currTotal,       // total current liquidity
            currPrimary,     // current primary liquidity
            dropPct,         // primary drop %
            otherIncreasePct,// other pools increase %
            ts_new           // timestamp
        );

        return (true, payload);
    }

    /* -------------------------------------------------------------------------- */
    /*                              ADMIN FUNCTIONS                               */
    /* -------------------------------------------------------------------------- */

    /**
     * @notice Configure which pools are monitored.
     * @dev Only callable by the owner after ownership is set.
     */
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
        // Try Uniswap V2-style pair
        try IUniswapV2Pair(pool).getReserves() returns (uint112 r0, uint112 r1, uint32) {
            return uint256(r0) + uint256(r1);
        } catch {}

        // Try Uniswap V3-style pool
        try IUniswapV3Pool(pool).liquidity() returns (uint128 L) {
            return uint256(L);
        } catch {}

        // If both calls fail, treat liquidity as 0
        return 0;
    }
}
