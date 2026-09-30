// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import { PoolRegistry } from "../src/PoolRegistry.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { ChainAddresses } from "./ChainAddresses.sol";

/// @title DeployPoolRegistryScript
/// @notice Deploy PoolRegistry and register existing AvengeHook pools
contract DeployPoolRegistry is Script {
    using ChainAddresses for uint256;
    using PoolIdLibrary for PoolKey;

    // AvengeHook address (already deployed)
    address constant AVENGE_HOOK = 0xf53c43858D62a1765480508f3bE7481e883380A8;
    
    // Pool configurations from previous deployment
    struct PoolConfig {
        string name;
        string description;
        uint24 fee;
        int24 tickSpacing;
        uint256 targetPrice;
        bytes32 expectedPoolId;
    }

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYMENT_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("=== PoolRegistry Deployment ===");
        console.log("Chain ID:", block.chainid);
        console.log("Deployer:", deployer);
        console.log("AvengeHook:", AVENGE_HOOK);
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Deploy PoolRegistry
        PoolRegistry registry = new PoolRegistry(AVENGE_HOOK, deployer);
        console.log("PoolRegistry deployed at:", address(registry));
        
        // Register existing pools
        _registerExistingPools(registry);
        
        vm.stopBroadcast();
        
        console.log("=== Deployment Complete ===");
        console.log("PoolRegistry:", address(registry));
        console.log("Registered pools: 2");
        
        // Verify registrations
        _verifyRegistrations(registry);
    }

    /// @notice Register the existing AvengeHook pools
    function _registerExistingPools(PoolRegistry registry) internal {
        console.log("=== Registering Existing Pools ===");
        
        // Get contract addresses
        address usdc = ChainAddresses.getUSDC(block.chainid);
        
        // Pool configurations
        PoolConfig[2] memory configs = [
            PoolConfig({
                name: "pool1",
                description: "ETH/USDC dynamic fee pool (~2500 USDC/ETH)",
                fee: 8388608,
                tickSpacing: 30,
                targetPrice: 2500,
                expectedPoolId: 0x5771f78e1245220ba528309807e28c9bad50849292b2a694ffba8958196c9c4b
            }),
            PoolConfig({
                name: "pool2", 
                description: "ETH/USDC dynamic fee pool (~2600 USDC/ETH)",
                fee: 8388608,
                tickSpacing: 120,
                targetPrice: 2600,
                expectedPoolId: 0x19bfceedc254ba74b1eed66e2d88551be735cca9c219a2627fb643fa83bb6d43
            })
        ];
        
        // Register each pool
        for (uint256 i = 0; i < configs.length; i++) {
            PoolConfig memory config = configs[i];
            
            // Create PoolKey
            PoolKey memory poolKey = PoolKey({
                currency0: Currency.wrap(address(0)), // ETH
                currency1: Currency.wrap(usdc), // USDC
                fee: config.fee,
                tickSpacing: config.tickSpacing,
                hooks: IHooks(AVENGE_HOOK)
            });
            
            // Verify PoolId matches expected
            PoolId poolId = poolKey.toId();
            bytes32 computedId = PoolId.unwrap(poolId);
            
            console.log("Registering", config.name);
            console.log("  Expected PoolId:", vm.toString(config.expectedPoolId));
            console.log("  Computed PoolId:", vm.toString(computedId));
            console.log("  PoolIds match:", computedId == config.expectedPoolId);
            
            require(computedId == config.expectedPoolId, "PoolId mismatch");
            
            // Register the pool
            registry.registerPool(
                config.name,
                poolKey,
                config.description,
                config.targetPrice
            );
            
            console.log("  Successfully registered", config.name);
        }
    }

    /// @notice Verify pool registrations
    function _verifyRegistrations(PoolRegistry registry) internal view {
        console.log("=== Verification ===");
        
        string[] memory poolNames = registry.getAllPoolNames();
        console.log("Total registered pools:", poolNames.length);
        
        for (uint256 i = 0; i < poolNames.length; i++) {
            string memory name = poolNames[i];
            console.log("Pool:", name);
            
            PoolRegistry.PoolInfo memory info = registry.getPool(name);
            console.log("  Description:", info.description);
            console.log("  Target Price:", info.targetPrice);
            console.log("  Is Active:", info.isActive);
            console.log("  PoolId:", vm.toString(PoolId.unwrap(info.poolId)));
            console.log("  Fee:", info.poolKey.fee);
            console.log("  Tick Spacing:", info.poolKey.tickSpacing);
        }
    }

    /// @notice Get PoolKey for a specific pool (helper function)
    function getPoolKey(string memory poolName) external view returns (PoolKey memory) {
        // This would be called after deployment to get PoolKeys
        // For now, we'll create them manually based on known configurations
        
        address usdc = ChainAddresses.getUSDC(block.chainid);
        
        if (keccak256(bytes(poolName)) == keccak256(bytes("pool1"))) {
            return PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(usdc),
                fee: 8388608,
                tickSpacing: 30,
                hooks: IHooks(AVENGE_HOOK)
            });
        } else if (keccak256(bytes(poolName)) == keccak256(bytes("pool2"))) {
            return PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(usdc),
                fee: 8388608,
                tickSpacing: 120,
                hooks: IHooks(AVENGE_HOOK)
            });
        } else {
            revert("Unknown pool name");
        }
    }

    /// @notice Helper to display pool information
    function displayPoolInfo() external view {
        console.log("=== AvengeHook Pool Information ===");
        console.log("AvengeHook Address:", AVENGE_HOOK);
        console.log("Chain:", ChainAddresses.getChainName(block.chainid));
        console.log("");
        
        console.log("Pool 1 (dynamic fee):");
        console.log("  PoolId: 0x5771f78e1245220ba528309807e28c9bad50849292b2a694ffba8958196c9c4b");
        console.log("  Target Price: ~2500 USDC/ETH");
        console.log("  Fee: 8388608 (dynamic), base 500 (0.05%)");
        console.log("  Tick Spacing: 30");
        console.log("");
        
        console.log("Pool 2 (dynamic fee):");
        console.log("  PoolId: 0x19bfceedc254ba74b1eed66e2d88551be735cca9c219a2627fb643fa83bb6d43");
        console.log("  Target Price: ~2600 USDC/ETH");
        console.log("  Fee: 8388608 (dynamic), base 500 (0.05%)");
        console.log("  Tick Spacing: 120");
    }
} 