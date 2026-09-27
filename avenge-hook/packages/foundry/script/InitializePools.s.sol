// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { Currency, CurrencyLibrary } from "@uniswap/v4-core/src/types/Currency.sol";
import { BalanceDelta } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { FullMath } from "@uniswap/v4-core/src/libraries/FullMath.sol";
import { IERC20Minimal } from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import { PoolModifyLiquidityTest } from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import { ModifyLiquidityParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { ChainAddresses } from "./ChainAddresses.sol";
import { AvengeHook } from "../src/AvengeHook.sol";
import { LPFeeLibrary } from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

/// @title InitializePoolsScript
/// @notice Script to initialize ETH/USDC pools and add initial liquidity
contract InitializePools is Script {
    using ChainAddresses for uint256;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // Pool configuration
    // Dynamic-fee pools: the key's fee must be DYNAMIC_FEE_FLAG or PoolManager ignores the
    // hook's beforeSwap fee override (LPFeeLibrary.isDynamicFee). Base fees are set below.
    uint24 constant FEE_TIER_1 = LPFeeLibrary.DYNAMIC_FEE_FLAG;
    uint24 constant FEE_TIER_2 = LPFeeLibrary.DYNAMIC_FEE_FLAG;
    uint24 constant BASE_FEE_1 = 500; // 0.05% base LP fee (pips, 1e6 = 100%) — matches live
    uint24 constant BASE_FEE_2 = 500;  // 0.05% base LP fee (pips)
    int24 constant TICK_SPACING_1 = 30; // Matches live Pool 1
    int24 constant TICK_SPACING_2 = 120; // Matches live Pool 2
    
    // Price configuration (sqrt price X96 format)
    uint160 constant SQRT_PRICE_2500 = 3961408125713216879677197; // sqrt(2500e-12) * 2^96 — 2500 USDC/ETH (18/6 decimals)
    uint160 constant SQRT_PRICE_2600 = 4039859466863342510789667; // sqrt(2600e-12) * 2^96 — 2600 USDC/ETH
    
    // Liquidity amounts
    uint256 constant LIQUIDITY_USDC_AMOUNT = 1e6; // 1 USDC
    
    // Contract instances
    IPoolManager public poolManager;
    IERC20Minimal public usdc;
    PoolModifyLiquidityTest public modifyLiquidityRouter;
    address public deployer;
    address public hookAddress;
    AvengeHook public hook;

    // Events
    event PoolInitialized(PoolId indexed poolId, PoolKey poolKey, uint160 sqrtPriceX96);
    event LiquidityAdded(PoolId indexed poolId, uint256 usdcAmount, uint256 ethAmount);

    /// @notice Main function to initialize pools
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYMENT_KEY");
        deployer = vm.addr(deployerPrivateKey);
        
        console.log("=== Pool Initialization Script ===");
        console.log("Chain ID:", block.chainid);
        console.log("Deployer:", deployer);
        
        // Get hook address from user input
        hookAddress = vm.envAddress("HOOK_ADDRESS");
        console.log("Hook Address:", hookAddress);
        
        vm.startBroadcast(deployerPrivateKey);
        
        _initializeContracts();
        _checkBalances();
        _initializePools();
        _addLiquidity();
        
        vm.stopBroadcast();
        
        console.log("=== Pool Initialization Complete ===");
    }

    /// @notice Initialize contract instances
    function _initializeContracts() internal {
        console.log("=== Initializing Contracts ===");
        
        poolManager = IPoolManager(ChainAddresses.getPoolManager(block.chainid));
        usdc = IERC20Minimal(ChainAddresses.getUSDC(block.chainid));
        modifyLiquidityRouter = PoolModifyLiquidityTest(ChainAddresses.getPoolModifyLiquidityTest(block.chainid));
        hook = AvengeHook(payable(hookAddress));
        
        console.log("Pool Manager:", address(poolManager));
        console.log("Hook:", hookAddress);
        console.log("USDC Token:", address(usdc));
        console.log("Modify Liquidity Router:", address(modifyLiquidityRouter));
    }

    /// @notice Check deployer balances
    function _checkBalances() internal view {
        console.log("=== Balance Check ===");
        
        uint256 ethBalance = deployer.balance;
        uint256 usdcBalance = usdc.balanceOf(deployer);
        
        console.log("ETH Balance:", ethBalance);
        console.log("USDC Balance:", usdcBalance);
        
        require(ethBalance >= 0.01 ether, "Insufficient ETH balance");
        require(usdcBalance >= 2e6, "Insufficient USDC balance (need at least 2 USDC)");
        
        console.log("[PASS] Sufficient balances for pool operations");
    }

    /// @notice Initialize both pools
    function _initializePools() internal {
        console.log("=== Initializing Pools ===");
        
        // Create pool keys
        PoolKey memory poolKey1 = _createPoolKey(FEE_TIER_1, TICK_SPACING_1);
        PoolKey memory poolKey2 = _createPoolKey(FEE_TIER_2, TICK_SPACING_2);
        
        // Initialize pools
        _initializePool(poolKey1, SQRT_PRICE_2500, BASE_FEE_1, "Pool 1 (dynamic fee, base 0.05%, 2500 USDC/ETH, ts 30)");
        _initializePool(poolKey2, SQRT_PRICE_2600, BASE_FEE_2, "Pool 2 (dynamic fee, base 0.05%, 2600 USDC/ETH, ts 120)");
    }

    /// @notice Create a pool key
    function _createPoolKey(uint24 fee, int24 tickSpacing) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)), // ETH
            currency1: Currency.wrap(address(usdc)), // USDC
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hookAddress)
        });
    }

    /// @notice Initialize a single pool
    function _initializePool(PoolKey memory poolKey, uint160 sqrtPriceX96, uint24 baseFee, string memory description) internal {
        console.log("Initializing", description);
        
        try poolManager.initialize(poolKey, sqrtPriceX96) returns (int24 tick) {
            PoolId poolId = poolKey.toId();
            console.log("Pool initialized successfully");
            console.log("Pool ID:", vm.toString(PoolId.unwrap(poolId)));
            console.log("Initial tick:", tick);
            
            emit PoolInitialized(poolId, poolKey, sqrtPriceX96);
        } catch Error(string memory reason) {
            console.log("Pool initialization failed:", reason);
            console.log("Pool may already exist - continuing...");
        } catch {
            console.log("Pool initialization failed with unknown error");
            console.log("Pool may already exist - continuing...");
        }
        _setBaseFee(poolKey, baseFee, description);
    }
    
    /// @notice Dynamic-fee pools start with an LP fee of 0; apply the hook's base fee after init
    function _setBaseFee(PoolKey memory poolKey, uint24 baseFee, string memory description) internal {
        try hook.setDynamicLPFee(poolKey, baseFee) {
            console.log("  Base LP fee set to", baseFee, "pips for", description);
        } catch (bytes memory err) {
            console.log("  [WARN] Base LP fee NOT set - pool would charge 0% LP fee:", description);
            console.logBytes(err);
        }
    }

    /// @notice Add liquidity to both pools
    function _addLiquidity() internal {
        console.log("=== Adding Liquidity ===");
        
        // Create pool keys
        PoolKey memory poolKey1 = _createPoolKey(FEE_TIER_1, TICK_SPACING_1);
        PoolKey memory poolKey2 = _createPoolKey(FEE_TIER_2, TICK_SPACING_2);
        
        // Calculate ETH amounts for each pool
        uint256 ethAmount1 = _calculateEthAmount(2500); // For 2500 USDC/ETH pool
        uint256 ethAmount2 = _calculateEthAmount(2600); // For 2600 USDC/ETH pool
        
        console.log("ETH amount for Pool 1:", ethAmount1);
        console.log("ETH amount for Pool 2:", ethAmount2);
        
        // Add liquidity to both pools
        _addLiquidityToPool(poolKey1, ethAmount1, "Pool 1");
        _addLiquidityToPool(poolKey2, ethAmount2, "Pool 2");
    }

    /// @notice Calculate ETH amount needed for 1 USDC at given price
    function _calculateEthAmount(uint256 usdcPerEth) internal pure returns (uint256) {
        // For 1 USDC, we need: 1 USDC / (USDC per ETH) = ETH amount
        // 1e6 (1 USDC) / (usdcPerEth * 1e6) * 1e18 = ETH in wei
        return (LIQUIDITY_USDC_AMOUNT * 1e18) / (usdcPerEth * 1e6);
    }

    /// @notice Add liquidity to a specific pool
    function _addLiquidityToPool(PoolKey memory poolKey, uint256 ethAmount, string memory poolName) internal {
        console.log("Adding liquidity to", poolName);
        
        try modifyLiquidityRouter.modifyLiquidity{value: ethAmount}(
            poolKey,
            ModifyLiquidityParams({
                tickLower: -600,
                tickUpper: 600,
                liquidityDelta: int256(LIQUIDITY_USDC_AMOUNT),
                salt: bytes32(0)
            }),
            ""
        ) returns (BalanceDelta delta) {
            PoolId poolId = poolKey.toId();
            console.log("Liquidity added successfully to", poolName);
            console.log("Balance delta amount0:", delta.amount0());
            console.log("Balance delta amount1:", delta.amount1());
            
            emit LiquidityAdded(poolId, LIQUIDITY_USDC_AMOUNT, ethAmount);
        } catch Error(string memory reason) {
            console.log("Liquidity addition failed for", poolName, ":", reason);
            console.log("Continuing with script...");
        } catch {
            console.log("Liquidity addition failed for", poolName, "with unknown error");
            console.log("Continuing with script...");
        }
    }

    /// @notice Get pool information for verification
    function getPoolInfo(PoolKey memory poolKey) external view returns (PoolId poolId, bool exists) {
        poolId = poolKey.toId();
        // Check if pool exists by checking if it has been initialized
        // We can do this by checking if the pool has any liquidity or state
        exists = true; // For now, assume pool exists if we can create the ID
    }
} 