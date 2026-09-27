use ethers::types::Address;
use std::env;

/// All configuration for detox-rs, loaded from environment variables.
pub struct Config {
    /// RPC endpoint (HTTP or WebSocket)
    pub rpc_url: String,
    /// DetoxHook contract address
    pub hook_address: Address,
    /// Pyth oracle address (for off-chain price checks)
    pub pyth_address: Address,
    /// Chain ID
    pub chain_id: u64,
    /// Path to the Foundry project directory (where foundry.toml lives)
    pub forge_dir: String,
    /// Pool ID (bytes32) of the monitored pool — used for per-pool accumulator reads
    pub pool_id: [u8; 32],
    /// USDC token address (currency1 of the default ETH/USDC pool)
    pub usdc_address: Address,
}

/// Decode a 0x-prefixed hex string into a fixed 32-byte value.
fn parse_bytes32(raw: &str) -> eyre::Result<[u8; 32]> {
    let hex_str = raw.trim().trim_start_matches("0x");
    let bytes = hex::decode(hex_str)?;
    if bytes.len() != 32 {
        eyre::bail!("expected 32 bytes for bytes32 value, got {}", bytes.len());
    }
    let mut out = [0u8; 32];
    out.copy_from_slice(&bytes);
    Ok(out)
}

impl Config {
    /// Load config from .env file and environment variables.
    pub fn load() -> eyre::Result<Self> {
        dotenv::dotenv().ok();

        let rpc_url = env::var("RPC_URL").expect("Set RPC_URL in .env");
        let hook_address: Address = env::var("HOOK_ADDRESS")
            .expect("Set HOOK_ADDRESS in .env")
            .parse()?;
        // Defaults to Pyth's Wormhole Store on Arbitrum Sepolia (the default chain)
        let pyth_address: Address = env::var("PYTH_ADDRESS")
            .unwrap_or_else(|_| "0x4374e5a8b9C22271E9EB878A2AA31DE97DF15DAF".into())
            .parse()?;
        let chain_id: u64 = env::var("CHAIN_ID")
            .unwrap_or_else(|_| "421614".into())
            .parse()?;

        // Default pool: live ETH/USDC Pool 1 — dynamic fee 8388608, tickSpacing 30
        let pool_id = parse_bytes32(&env::var("POOL_ID").unwrap_or_else(|_| {
            "0x5771f78e1245220ba528309807e28c9bad50849292b2a694ffba8958196c9c4b".into()
        }))?;

        let usdc_address: Address = env::var("USDC_ADDRESS")
            .unwrap_or_else(|_| "0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d".into())
            .parse()?;

        // FORGE_DIR: where the Foundry project lives (detox-hook/packages/foundry)
        // Try env var first, then look for detox-hook/packages/foundry relative to cwd
        let forge_dir = env::var("FORGE_DIR").unwrap_or_else(|_| {
            let cwd = std::env::current_dir().unwrap_or_default();
            // Check common locations
            let candidates = [
                cwd.join("detox-hook/packages/foundry"),
                cwd.join("../detox-hook/packages/foundry"),
                cwd.join("../../detox-hook/packages/foundry"),
            ];
            for c in &candidates {
                if c.join("foundry.toml").exists() {
                    return c.to_string_lossy().to_string();
                }
            }
            eprintln!("WARNING: FORGE_DIR not set and detox-hook/packages/foundry not found");
            eprintln!("  Set FORGE_DIR in .env or run from the workspace root");
            "packages/foundry".to_string()
        });

        Ok(Self {
            rpc_url,
            hook_address,
            pyth_address,
            chain_id,
            forge_dir,
            pool_id,
            usdc_address,
        })
    }
}
