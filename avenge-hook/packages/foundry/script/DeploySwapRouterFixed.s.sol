// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {SwapRouterFixed} from "../src/SwapRouterFixed.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

/// @title DeploySwapRouterFixed
/// @notice Deploy a fixed SwapRouter with proper TickMath price limits
contract DeploySwapRouterFixed is Script {
    
    // Arbitrum Sepolia addresses (properly checksummed)
    address constant POOL_SWAP_TEST = 0x9A8ca723F5dcCb7926D00B71deC55c2fEa1F50f7;
    address constant ETH_ADDRESS = 0x0000000000000000000000000000000000000000;
    address constant USDC_ADDRESS = 0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d;
    address constant AVENGE_HOOK = 0xf53c43858D62a1765480508f3bE7481e883380A8;
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYMENT_KEY");
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Create pool key for ETH/USDC with 0.05% fee
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(ETH_ADDRESS),
            currency1: Currency.wrap(USDC_ADDRESS),
            fee: 500,  // 0.05%
            tickSpacing: 10,
            hooks: IHooks(AVENGE_HOOK)
        });
        
        console.log("Deploying SwapRouterFixed...");
        console.log("PoolSwapTest:", POOL_SWAP_TEST);
        console.log("ETH Address:", ETH_ADDRESS);
        console.log("USDC Address:", USDC_ADDRESS);
        console.log("AvengeHook:", AVENGE_HOOK);
        console.log("Fee:", poolKey.fee);
        console.log("TickSpacing:", poolKey.tickSpacing);
        
        // Deploy the fixed SwapRouter
        SwapRouterFixed swapRouterFixed = new SwapRouterFixed(
            POOL_SWAP_TEST,
            poolKey
        );
        
        console.log("SwapRouterFixed deployed at:", address(swapRouterFixed));
        
        // Verify the configuration
        PoolKey memory deployedPoolKey = swapRouterFixed.getPoolConfiguration();
        console.log("Verified pool configuration:");
        console.log("  Currency0:", Currency.unwrap(deployedPoolKey.currency0));
        console.log("  Currency1:", Currency.unwrap(deployedPoolKey.currency1));
        console.log("  Fee:", deployedPoolKey.fee);
        console.log("  TickSpacing:", deployedPoolKey.tickSpacing);
        console.log("  Hooks:", address(deployedPoolKey.hooks));
        
        vm.stopBroadcast();
        
        console.log("\n=== Deployment Summary ===");
        console.log("SwapRouterFixed:", address(swapRouterFixed));
        console.log("Network: Arbitrum Sepolia");
        console.log("Fixed: Uses TickMath.MIN_SQRT_PRICE + 1 and TickMath.MAX_SQRT_PRICE - 1");
        console.log("\nTo use the fixed router, update your frontend to use this address:");
        console.log(address(swapRouterFixed));
    }
} 