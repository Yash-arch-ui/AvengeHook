use ethers::{
    contract::abigen,
    types::{Address, Bytes, U256},
};
use eyre::Result;
use std::sync::Arc;

abigen!(
    PythOracle,
    r#"
    [
        {
            "inputs": [
                {"internalType": "bytes32", "name": "id", "type": "bytes32"}
            ],
            "name": "getPriceUnsafe",
            "outputs": [
                {"internalType": "int64", "name": "price", "type": "int64"},
                {"internalType": "uint64", "name": "conf", "type": "uint64"},
                {"internalType": "int32", "name": "expo", "type": "int32"},
                {"internalType": "uint256", "name": "publishTime", "type": "uint256"}
            ],
            "stateMutability": "view",
            "type": "function"
        },
        {
            "inputs": [],
            "name": "getValidTimePeriod",
            "outputs": [
                {"internalType": "uint256", "name": "", "type": "uint256"}
            ],
            "stateMutability": "view",
            "type": "function"
        },
        {
            "inputs": [
                {"internalType": "bytes[]", "name": "updateData", "type": "bytes[]"}
            ],
            "name": "getUpdateFee",
            "outputs": [
                {"internalType": "uint256", "name": "", "type": "uint256"}
            ],
            "stateMutability": "view",
            "type": "function"
        }
    ]
    "#
);

/// Well-known Pyth price feed IDs.
pub mod price_ids {
    use ethers::types::H256;

    pub fn eth_usd() -> H256 {
        H256::from_slice(&hex::decode(
            "ff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace",
        )
        .unwrap())
    }

    pub fn usdc_usd() -> H256 {
        H256::from_slice(&hex::decode(
            "eaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a",
        )
        .unwrap())
    }

    pub fn btc_usd() -> H256 {
        H256::from_slice(&hex::decode(
            "e62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43",
        )
        .unwrap())
    }
}

/// Normalized price with confidence from Pyth.
#[derive(Debug, Clone)]
pub struct PythPrice {
    pub price: U256,
    pub confidence: U256,
    pub valid: bool,
    pub publish_time: U256,
}

type PythProvider = ethers::providers::Provider<ethers::providers::Http>;

/// Fetch and normalize Pyth prices off-chain.
pub struct PythClient {
    contract: PythOracle<PythProvider>,
}

impl PythClient {
    pub fn new(pyth_address: Address, rpc_url: &str) -> Result<Self> {
        let provider = PythProvider::try_from(rpc_url)?;
        let client = Arc::new(provider);
        Ok(Self {
            contract: PythOracle::new(pyth_address, client),
        })
    }

    /// Get a price from Pyth and normalize it to 1e8 format.
    pub async fn get_price(&self, feed_id: ethers::types::H256) -> Result<PythPrice> {
        let (price_raw, conf_raw, expo, publish_time) =
            self.contract.get_price_unsafe(feed_id.into()).call().await?;

        let price = normalize_value(price_raw as u128, expo);
        let confidence = normalize_value(conf_raw as u128, expo);

        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)?
            .as_secs();
        let valid = price_raw > 0 && now.saturating_sub(publish_time.as_u64()) < 60;

        Ok(PythPrice {
            price,
            confidence,
            valid,
            publish_time,
        })
    }

    pub async fn get_eth_price(&self) -> Result<PythPrice> {
        self.get_price(price_ids::eth_usd()).await
    }

    pub async fn get_usdc_price(&self) -> Result<PythPrice> {
        self.get_price(price_ids::usdc_usd()).await
    }

    pub async fn get_btc_price(&self) -> Result<PythPrice> {
        self.get_price(price_ids::btc_usd()).await
    }

    /// Get the update fee required by Pyth.
    pub async fn get_update_fee(&self, update_data: Vec<Bytes>) -> Result<U256> {
        Ok(self.contract.get_update_fee(update_data).call().await?)
    }
}

/// Normalize a raw Pyth value with exponent to 1e8 precision.
fn normalize_value(value: u128, expo: i32) -> U256 {
    if value == 0 {
        return U256::zero();
    }

    let val = U256::from(value);
    let target_exp = -8i32;

    if expo == target_exp {
        return val;
    }

    if expo > target_exp {
        let shift = (expo + 8) as u32;
        val * U256::from(10u128).pow(U256::from(shift))
    } else {
        let shift = (-8 - expo) as u32;
        val / U256::from(10u128).pow(U256::from(shift))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_normalize_same_exp() {
        let result = normalize_value(2000_00000000u128, -8);
        assert_eq!(result, U256::from(2000_00000000u128));
    }

    #[test]
    fn test_normalize_positive_exp() {
        // value=2000, expo=-1 means raw=2000*10^-1=200.0
        // normalize to 1e8: 200 * 1e8 = 20_000_000_000
        let result = normalize_value(2000, -1);
        assert_eq!(result, U256::from(20_000_000_000u128));
    }

    #[test]
    fn test_normalize_very_negative_exp() {
        // value=200000000, expo=-10 means raw=200_000_000*10^-10=0.02
        // normalize to 1e8: 0.02 * 1e8 = 2_000_000
        let result = normalize_value(200000000, -10);
        assert_eq!(result, U256::from(2_000_000u128));
    }

    #[test]
    fn test_normalize_zero() {
        let result = normalize_value(0, -8);
        assert_eq!(result, U256::zero());
    }
}
