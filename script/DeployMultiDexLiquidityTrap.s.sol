// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/MultiDexLiquidityTrap.sol";

contract DeployMultiDexLiquidityTrap is Script {
    function run() external {
        vm.startBroadcast();

        // Deploy the trap — constructor is EMPTY
        MultiDexLiquidityTrap trap = new MultiDexLiquidityTrap();

        console.log("Deployed MultiDexLiquidityTrap at:", address(trap));

        vm.stopBroadcast();
    }
}

