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
}

impl Config {
    /// Load config from .env file and environment variables.
    pub fn load() -> eyre::Result<Self> {
        dotenv::dotenv().ok();

        let rpc_url = env::var("RPC_URL").expect("Set RPC_URL in .env");
        let hook_address: Address = env::var("HOOK_ADDRESS")
            .expect("Set HOOK_ADDRESS in .env")
            .parse()?;
        let pyth_address: Address = env::var("PYTH_ADDRESS")
            .unwrap_or_else(|_| "0x0000000000000000000000000000000000000000".into())
            .parse()?;
        let chain_id: u64 = env::var("CHAIN_ID")
            .unwrap_or_else(|_| "421614".into())
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
        })
    }
}
