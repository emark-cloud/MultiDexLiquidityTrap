// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ITrap} from "./interfaces/ITrap.sol";

interface IUniswapV2Pair {
    function getReserves() external view returns (uint112 r0, uint112 r1, uint32 ts);
}

interface IUniswapV3Pool {
    function liquidity() external view returns (uint128);
}

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
    /*                               Trap Variables                               */
    /* -------------------------------------------------------------------------- */

    uint256 public constant MAX_POOLS = 8;

    address[] public pools; // pools[0] = primary pool
    uint256 public minTotalLiquidity;

    uint16 public dropThresholdPct = 40;  // % drop in primary
    uint16 public imbalancePct = 20;
    uint16 public confirmBlocks = 2;

    /* -------------------------------------------------------------------------- */
    /*                                   Events                                   */
    /* -------------------------------------------------------------------------- */

    event PoolsUpdated(address[] pools);
    event ParametersUpdated(uint16 dropPct, uint16 imbalancePct, uint16 confirmBlocks);
    event MinTotalLiquidityUpdated(uint256 minTotalLiquidity);

    event MultiDexLiquidityAlert(
        address indexed primaryPool,
        uint256 indexed blockNumber,
        uint256 currTotal,
        uint256 currPrimary,
        uint256 dropPct,
        uint256 otherIncreasePct,
        uint64 timestamp,
        address triggeredBy
    );

    /* -------------------------------------------------------------------------- */
    /*                                Constructor                                 */
    /* -------------------------------------------------------------------------- */

    constructor() {
        // Drosera deploys using address(0) → so we assign owner AFTER deployment.
        // Whoever calls setOwner() first becomes the owner.
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
        if (blk_new < blk_prev + confirmBlocks) return (false, "");

        uint256 length = liqs_prev.length;

        uint256 prevTotal = 0;
        uint256 currTotal = 0;

        for (uint256 i = 0; i < length; i++) {
            prevTotal += liqs_prev[i];
            currTotal += liqs_new[i];
        }

        if (prevTotal < minTotalLiquidity) return (false, "");

        uint256 prevPrimary = liqs_prev[0];
        uint256 currPrimary = liqs_new[0];

        if (prevPrimary == 0) return (false, "");

        uint256 dropPct = currPrimary < prevPrimary
            ? ((prevPrimary - currPrimary) * 100) / prevPrimary
            : 0;

        if (dropPct < dropThresholdPct) return (false, "");

        uint256 prevOther = prevTotal - prevPrimary;
        uint256 currOther = currTotal - currPrimary;

        uint256 otherIncreasePct = (prevOther > 0 && currOther > prevOther)
            ? ((currOther - prevOther) * 100) / prevOther
            : 0;

        uint256 compensationPct = dropPct > 0
            ? (otherIncreasePct * 100) / dropPct
            : 0;

        if (compensationPct >= 50) return (false, "");

        bytes memory payload = abi.encode(
            pools_new[0],
            blk_new,
            currTotal,
            currPrimary,
            dropPct,
            otherIncreasePct,
            ts_new
        );

        emit MultiDexLiquidityAlert(
            pools_new[0],
            blk_new,
            currTotal,
            currPrimary,
            dropPct,
            otherIncreasePct,
            ts_new,
            msg.sender
        );

        return (true, payload);
    }

    /* -------------------------------------------------------------------------- */
    /*                              ADMIN FUNCTIONS                                */
    /* -------------------------------------------------------------------------- */

    function updatePools(address[] calldata _pools) external onlyOwner {
        require(_pools.length > 0 && _pools.length <= MAX_POOLS, "invalid pools");
        pools = _pools;
        emit PoolsUpdated(_pools);
    }

    function updateParameters(uint16 _drop, uint16 _imbalance, uint16 _confirm)
        external
        onlyOwner
    {
        dropThresholdPct = _drop;
        imbalancePct = _imbalance;
        confirmBlocks = _confirm;
        emit ParametersUpdated(_drop, _imbalance, _confirm);
    }

    function updateMinTotalLiquidity(uint256 _min) external onlyOwner {
        minTotalLiquidity = _min;
        emit MinTotalLiquidityUpdated(_min);
    }

    /* -------------------------------------------------------------------------- */
    /*                         INTERNAL LIQUIDITY HELPERS                          */
    /* -------------------------------------------------------------------------- */

    function _getPoolLiquidityApprox(address pool)
        internal
        view
        returns (uint256)
    {
        // Uniswap V2 style: getReserves()
        try IUniswapV2Pair(pool).getReserves() returns (uint112 r0, uint112 r1, uint32) {
            return uint256(r0) + uint256(r1);
        } catch {}

        // Uniswap V3: liquidity()
        try IUniswapV3Pool(pool).liquidity() returns (uint128 L) {
            return uint256(L);
        } catch {}

        return 0;
    }
}

