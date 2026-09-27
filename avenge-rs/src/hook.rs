use ethers::{
    contract::abigen,
    providers::Middleware,
    signers::Signer,
    types::{Address, H256, U256},
};
use eyre::Result;
use std::sync::Arc;

abigen!(
    DetoxHook,
    r#"
    [
        {"inputs":[],"name":"rhoBps","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"view","type":"function"},
        {"inputs":[],"name":"stalenessThreshold","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"view","type":"function"},
        {"inputs":[],"name":"owner","outputs":[{"internalType":"address","name":"","type":"address"}],"stateMutability":"view","type":"function"},
        {"inputs":[],"name":"pythOracle","outputs":[{"internalType":"address","name":"","type":"address"}],"stateMutability":"view","type":"function"},
        {"inputs":[],"name":"getParameters","outputs":[{"internalType":"uint256","name":"","type":"uint256"},{"internalType":"uint256","name":"","type":"uint256"},{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"view","type":"function"},
        {"inputs":[{"internalType":"bytes32","name":"poolId","type":"bytes32"},{"internalType":"address","name":"currency","type":"address"}],"name":"getAccumulatedTokens","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"view","type":"function"},
        {"inputs":[{"internalType":"address","name":"currency","type":"address"}],"name":"getOraclePrice","outputs":[{"internalType":"uint256","name":"price","type":"uint256"},{"internalType":"bool","name":"valid","type":"bool"},{"internalType":"uint256","name":"publishTime","type":"uint256"}],"stateMutability":"view","type":"function"},
        {"inputs":[{"internalType":"address","name":"currency","type":"address"}],"name":"getOraclePriceWithConfidence","outputs":[{"internalType":"uint256","name":"price","type":"uint256"},{"internalType":"uint256","name":"confidence","type":"uint256"},{"internalType":"bool","name":"valid","type":"bool"},{"internalType":"uint256","name":"publishTime","type":"uint256"}],"stateMutability":"view","type":"function"},
        {"inputs":[{"internalType":"uint256","name":"_rhoBps","type":"uint256"},{"internalType":"uint256","name":"_stalenessThreshold","type":"uint256"}],"name":"updateParameters","outputs":[],"stateMutability":"nonpayable","type":"function"},
        {"inputs":[{"internalType":"address","name":"currency","type":"address"},{"internalType":"bytes32","name":"priceId","type":"bytes32"}],"name":"setPriceId","outputs":[],"stateMutability":"nonpayable","type":"function"},
        {"inputs":[{"internalType":"bytes32","name":"poolId","type":"bytes32"},{"internalType":"uint256","name":"amount","type":"uint256"},{"internalType":"address payable","name":"recipient","type":"address"}],"name":"withdrawAccumulatedETH","outputs":[],"stateMutability":"nonpayable","type":"function"},
        {"inputs":[{"internalType":"bytes32","name":"poolId","type":"bytes32"},{"internalType":"address","name":"currency","type":"address"},{"internalType":"uint256","name":"amount","type":"uint256"},{"internalType":"address","name":"recipient","type":"address"}],"name":"withdrawAccumulatedERC20","outputs":[],"stateMutability":"nonpayable","type":"function"},
        {"inputs":[{"internalType":"address","name":"currency","type":"address"}],"name":"pythPriceIds","outputs":[{"internalType":"bytes32","name":"","type":"bytes32"}],"stateMutability":"view","type":"function"},
        {"inputs":[{"components":[{"internalType":"Currency","name":"currency0","type":"address"},{"internalType":"Currency","name":"currency1","type":"address"},{"internalType":"uint24","name":"fee","type":"uint24"},{"internalType":"int24","name":"tickSpacing","type":"int24"},{"internalType":"contract IHooks","name":"hooks","type":"address"}],"internalType":"struct PoolKey","name":"key","type":"tuple"},{"components":[{"internalType":"bool","name":"zeroForOne","type":"bool"},{"internalType":"int256","name":"amountSpecified","type":"int256"},{"internalType":"uint160","name":"sqrtPriceLimitX96","type":"uint160"}],"internalType":"struct SwapParams","name":"params","type":"tuple"}],"name":"calculateArbitrageOpportunity","outputs":[{"internalType":"uint256","name":"arbitrageOpp","type":"uint256"},{"internalType":"uint256","name":"hookShare","type":"uint256"},{"internalType":"bool","name":"shouldInterfere","type":"bool"},{"internalType":"bool","name":"isOutsideConfidenceBand","type":"bool"}],"stateMutability":"view","type":"function"},
        {"inputs":[],"name":"getHookPermissions","outputs":[{"components":[{"internalType":"bool","name":"beforeInitialize","type":"bool"},{"internalType":"bool","name":"afterInitialize","type":"bool"},{"internalType":"bool","name":"beforeAddLiquidity","type":"bool"},{"internalType":"bool","name":"beforeRemoveLiquidity","type":"bool"},{"internalType":"bool","name":"afterAddLiquidity","type":"bool"},{"internalType":"bool","name":"afterRemoveLiquidity","type":"bool"},{"internalType":"bool","name":"beforeSwap","type":"bool"},{"internalType":"bool","name":"afterSwap","type":"bool"},{"internalType":"bool","name":"beforeDonate","type":"bool"},{"internalType":"bool","name":"afterDonate","type":"bool"},{"internalType":"bool","name":"beforeSwapReturnDelta","type":"bool"},{"internalType":"bool","name":"afterSwapReturnDelta","type":"bool"},{"internalType":"bool","name":"afterAddLiquidityReturnDelta","type":"bool"},{"internalType":"bool","name":"afterRemoveLiquidityReturnDelta","type":"bool"}],"internalType":"struct Hooks.Permissions","name":"","type":"tuple"}],"stateMutability":"pure","type":"function"},
        {"anonymous":false,"inputs":[{"indexed":true,"internalType":"bytes32","name":"poolId","type":"bytes32"},{"indexed":true,"internalType":"address","name":"currency","type":"address"},{"indexed":false,"internalType":"uint256","name":"hookShare","type":"uint256"},{"indexed":false,"internalType":"uint256","name":"arbitrageOpportunity","type":"uint256"},{"indexed":false,"internalType":"bool","name":"zeroForOne","type":"bool"}],"name":"ArbitrageCaptured","type":"event"},
        {"anonymous":false,"inputs":[{"indexed":false,"internalType":"uint256","name":"oldRhoBps","type":"uint256"},{"indexed":false,"internalType":"uint256","name":"newRhoBps","type":"uint256"},{"indexed":false,"internalType":"uint256","name":"oldStaleness","type":"uint256"},{"indexed":false,"internalType":"uint256","name":"newStaleness","type":"uint256"}],"name":"ParametersUpdated","type":"event"},
        {"anonymous":false,"inputs":[{"indexed":true,"internalType":"address","name":"currency","type":"address"},{"indexed":false,"internalType":"bytes32","name":"oldPriceId","type":"bytes32"},{"indexed":false,"internalType":"bytes32","name":"newPriceId","type":"bytes32"}],"name":"PriceIdUpdated","type":"event"},
        {"anonymous":false,"inputs":[{"indexed":true,"internalType":"bytes32","name":"poolId","type":"bytes32"},{"indexed":false,"internalType":"uint256","name":"amount","type":"uint256"},{"indexed":true,"internalType":"address","name":"recipient","type":"address"}],"name":"ETHWithdrawn","type":"event"},
        {"anonymous":false,"inputs":[{"indexed":true,"internalType":"bytes32","name":"poolId","type":"bytes32"},{"indexed":true,"internalType":"address","name":"currency","type":"address"},{"indexed":false,"internalType":"uint256","name":"amount","type":"uint256"},{"indexed":false,"internalType":"address","name":"recipient","type":"address"}],"name":"ERC20Withdrawn","type":"event"},
        {"anonymous":false,"inputs":[{"indexed":true,"internalType":"bytes32","name":"poolId","type":"bytes32"},{"indexed":true,"internalType":"address","name":"currency","type":"address"},{"indexed":false,"internalType":"uint256","name":"amount","type":"uint256"},{"indexed":false,"internalType":"uint256","name":"hookKept","type":"uint256"}],"name":"DonateToLPs","type":"event"}
    ]
    "#
);

/// Type alias for the concrete provider we use everywhere.
pub type Provider = ethers::providers::Provider<ethers::providers::Http>;

/// Create a DetoxHook contract instance.
pub fn hook_contract(address: Address, rpc_url: &str) -> Result<DetoxHook<Provider>> {
    let provider = Provider::try_from(rpc_url)?;
    let client = Arc::new(provider);
    Ok(DetoxHook::new(address, client))
}

// ============ View Functions ============

/// Read on-chain parameters (rhoBps, stalenessThreshold, lpDonateBps).
///
/// Deployments built before `lpDonateBps` was added return only two words; those are padded
/// with the contract's `LP_DONATE_BPS` constant (8000 = 80%) so the CLI still works against
/// the live hook.
pub async fn get_parameters(address: Address, rpc_url: &str) -> Result<(U256, U256, U256)> {
    let contract = hook_contract(address, rpc_url)?;
    if let Ok(v) = contract.get_parameters().call().await {
        return Ok(v);
    }

    // Raw eth_call: the ABI-crafted method would decode against the current 3-word signature.
    let provider = Provider::try_from(rpc_url)?;
    let tx = ethers::types::TransactionRequest::new()
        .to(address)
        .data([0xa5, 0xea, 0x11, 0xda]); // getParameters()
    let raw = provider.call(&tx.into(), None).await?;
    let data = raw.as_ref();
    eyre::ensure!(
        data.len() >= 64,
        "unexpected getParameters() return ({} bytes)",
        data.len()
    );
    let word = |i: usize| U256::from_big_endian(&data[i * 32..i * 32 + 32]);
    let lp_donate = if data.len() >= 96 {
        word(2)
    } else {
        U256::from(8000u64)
    };
    Ok((word(0), word(1), lp_donate))
}

/// Get the hook owner address.
pub async fn get_owner(address: Address, rpc_url: &str) -> Result<Address> {
    let contract = hook_contract(address, rpc_url)?;
    Ok(contract.owner().call().await?)
}

/// Get the Pyth oracle address.
pub async fn get_pyth_oracle(address: Address, rpc_url: &str) -> Result<Address> {
    let contract = hook_contract(address, rpc_url)?;
    Ok(contract.pyth_oracle().call().await?)
}

/// Get accumulated tokens for a pool + currency.
pub async fn get_accumulated_tokens(
    address: Address,
    rpc_url: &str,
    pool_id: [u8; 32],
    currency: Address,
) -> Result<U256> {
    let contract = hook_contract(address, rpc_url)?;
    Ok(contract.get_accumulated_tokens(pool_id.into(), currency).call().await?)
}

/// Get oracle price for a currency (price, valid, publishTime).
pub async fn get_oracle_price(
    address: Address,
    rpc_url: &str,
    currency: Address,
) -> Result<(U256, bool, U256)> {
    let contract = hook_contract(address, rpc_url)?;
    Ok(contract.get_oracle_price(currency).call().await?)
}

/// Get oracle price with confidence for a currency (price, confidence, valid, publishTime).
pub async fn get_oracle_price_with_confidence(
    address: Address,
    rpc_url: &str,
    currency: Address,
) -> Result<(U256, U256, bool, U256)> {
    let contract = hook_contract(address, rpc_url)?;
    Ok(contract.get_oracle_price_with_confidence(currency).call().await?)
}

/// Get the Pyth price ID for a currency.
pub async fn get_pyth_price_id(
    address: Address,
    rpc_url: &str,
    currency: Address,
) -> Result<[u8; 32]> {
    let contract = hook_contract(address, rpc_url)?;
    Ok(contract.pyth_price_ids(currency).call().await?)
}

/// Get hook permissions.
pub async fn get_hook_permissions(
    address: Address,
    rpc_url: &str,
) -> Result<Permissions> {
    let contract = hook_contract(address, rpc_url)?;
    Ok(contract.get_hook_permissions().call().await?)
}

/// Read `calculateArbitrageOpportunity(poolKey, swapParams)` on-chain.
///
/// Returns `(arbitrageOpp, hookShare, shouldInterfere, isOutsideConfidenceBand)` where
/// `arbitrageOpp` and `hookShare` are denominated in the swap's input currency.
pub async fn calculate_arbitrage_opportunity(
    address: Address,
    rpc_url: &str,
    key: PoolKey,
    params: SwapParams,
) -> Result<(U256, U256, bool, bool)> {
    let contract = hook_contract(address, rpc_url)?;
    contract
        .calculate_arbitrage_opportunity(key, params)
        .call()
        .await
        .map_err(|e| {
            eyre::eyre!(
                "{e} (calculateArbitrageOpportunity reverted or is missing on {:?}; \
                 the deployed hook may predate the current source - redeploy)",
                address
            )
        })
}

// ============ Owner Functions ============

/// Update hook parameters (owner only).
pub async fn update_parameters(
    address: Address,
    rpc_url: &str,
    private_key: &str,
    rho_bps: U256,
    staleness_threshold: U256,
) -> Result<ethers::types::TransactionReceipt> {
    let provider = Provider::try_from(rpc_url)?;
    let chain_id = provider.get_chainid().await?.as_u64();
    let client = Arc::new(provider);
    let wallet = private_key
        .parse::<ethers::signers::LocalWallet>()?
        .with_chain_id(chain_id);
    let client = ethers::middleware::SignerMiddleware::new(client, wallet);
    let client = Arc::new(client);
    let contract = DetoxHook::new(address, client);
    let tx = contract.update_parameters(rho_bps, staleness_threshold).send().await?.await?;
    Ok(tx.ok_or_else(|| eyre::eyre!("Transaction failed"))?)
}

/// Set price ID for a currency (owner only).
pub async fn set_price_id(
    address: Address,
    rpc_url: &str,
    private_key: &str,
    currency: Address,
    price_id: H256,
) -> Result<ethers::types::TransactionReceipt> {
    let provider = Provider::try_from(rpc_url)?;
    let chain_id = provider.get_chainid().await?.as_u64();
    let client = Arc::new(provider);
    let wallet = private_key
        .parse::<ethers::signers::LocalWallet>()?
        .with_chain_id(chain_id);
    let client = ethers::middleware::SignerMiddleware::new(client, wallet);
    let client = Arc::new(client);
    let contract = DetoxHook::new(address, client);
    let tx = contract.set_price_id(currency, price_id.into()).send().await?.await?;
    Ok(tx.ok_or_else(|| eyre::eyre!("Transaction failed"))?)
}

/// Withdraw accumulated ETH (owner only).
pub async fn withdraw_accumulated_eth(
    address: Address,
    rpc_url: &str,
    private_key: &str,
    pool_id: [u8; 32],
    amount: U256,
    recipient: Address,
) -> Result<ethers::types::TransactionReceipt> {
    let provider = Provider::try_from(rpc_url)?;
    let chain_id = provider.get_chainid().await?.as_u64();
    let client = Arc::new(provider);
    let wallet = private_key
        .parse::<ethers::signers::LocalWallet>()?
        .with_chain_id(chain_id);
    let client = ethers::middleware::SignerMiddleware::new(client, wallet);
    let client = Arc::new(client);
    let contract = DetoxHook::new(address, client);
    let tx = contract
        .withdraw_accumulated_eth(pool_id.into(), amount, recipient)
        .send()
        .await?
        .await?;
    Ok(tx.ok_or_else(|| eyre::eyre!("Transaction failed"))?)
}

/// Withdraw accumulated ERC20 tokens (owner only).
pub async fn withdraw_accumulated_erc20(
    address: Address,
    rpc_url: &str,
    private_key: &str,
    pool_id: [u8; 32],
    currency: Address,
    amount: U256,
    recipient: Address,
) -> Result<ethers::types::TransactionReceipt> {
    let provider = Provider::try_from(rpc_url)?;
    let chain_id = provider.get_chainid().await?.as_u64();
    let client = Arc::new(provider);
    let wallet = private_key
        .parse::<ethers::signers::LocalWallet>()?
        .with_chain_id(chain_id);
    let client = ethers::middleware::SignerMiddleware::new(client, wallet);
    let client = Arc::new(client);
    let contract = DetoxHook::new(address, client);
    let tx = contract
        .withdraw_accumulated_erc20(pool_id.into(), currency, amount, recipient)
        .send()
        .await?
        .await?;
    Ok(tx.ok_or_else(|| eyre::eyre!("Transaction failed"))?)
}
