//! Keyless on-chain Pyth price reader.
//!
//! Reads `getPriceUnsafe(bytes32)` directly from the deployed Pyth store over
//! the standard JSON-RPC endpoint (HTTP or WebSocket) — no off-chain price
//! API, no auth headers. Designed to be held by the bot's MEV listener task:
//! the reader is cheap (single `eth_call`) and fully async.

use crate::pyth::{price_ids, PythOracle};
use ethers::middleware::Middleware;
use ethers::types::{Address, H256, U256};
use eyre::Result;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

/// Raw Pyth price struct exactly as returned by the contract.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RawPrice {
    /// Price mantissa (apply `10^expo` for the real value).
    pub price: i64,
    /// Confidence interval on the mantissa (same scale as `price`).
    pub conf: u64,
    /// Decimal exponent, almost always negative (e.g. `-8`).
    pub expo: i32,
    /// Unix seconds when Pyth last signed this feed.
    pub publish_time: u64,
}

impl RawPrice {
    /// Human-readable price: `price * 10^expo` as f64.
    pub fn to_f64(&self) -> f64 {
        (self.price as f64) * 10f64.powi(self.expo)
    }

    /// Human-readable confidence: `conf * 10^expo` as f64.
    pub fn conf_f64(&self) -> f64 {
        (self.conf as f64) * 10f64.powi(self.expo)
    }

    /// Fixed-point price scaled to `10^target_exp` (default 1e8 for LP math).
    /// Integer-only — no float drift. Errors on negative mantissas (a rate
    /// feed like funding rates cannot be represented as unsigned).
    pub fn to_scaled_u256(&self, target_exp: i32) -> Result<U256> {
        if self.price < 0 {
            eyre::bail!("negative price mantissa {} cannot be U256", self.price);
        }
        let mantissa = U256::from(self.price as u64);
        // fixed = price * 10^expo * 10^(-target_exp) => shift = expo - target_exp
        let scale = self.expo - target_exp;
        if scale >= 0 {
            Ok(mantissa * U256::from(10u64).pow(U256::from(scale as u32)))
        } else {
            Ok(mantissa / U256::from(10u64).pow(U256::from((-scale) as u32)))
        }
    }

    /// Price at 1e8 precision — the hook's on-chain convention.
    pub fn to_u1e8(&self) -> Result<U256> {
        self.to_scaled_u256(-8)
    }

    /// Age of the price in seconds (negative if publishTime is in the future,
    /// e.g. small clock skew — treated as 0 by callers via `age_secs().max(0)`).
    pub fn age_secs(&self) -> i64 {
        now_unix() as i64 - self.publish_time as i64
    }

    /// Freshness check against the hook's staleness window.
    pub fn is_fresh(&self, max_age_secs: u64) -> bool {
        let age = self.age_secs().max(0) as u64;
        age <= max_age_secs
    }
}

/// Current unix timestamp in seconds.
fn now_unix() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Convert a feed id to the raw 32-byte array form.
fn h256_to_id(id: H256) -> [u8; 32] {
    let mut out = [0u8; 32];
    out.copy_from_slice(id.as_bytes());
    out
}

/// Generic async reader over any ethers middleware (Http or Ws provider).
///
/// Hold one instance in the MEV loop and call `fetch_pyth_price` whenever a
/// fresh oracle reading is needed; each call is a single `eth_call`.
pub struct PythReader<M: Middleware + 'static> {
    contract: PythOracle<M>,
}

impl<M: Middleware + 'static> PythReader<M> {
    pub fn new(provider: Arc<M>, pyth_address: Address) -> Self {
        Self {
            contract: PythOracle::new(pyth_address, provider),
        }
    }

    /// Core keyless read: `getPriceUnsafe(feed_id)` over the RPC connection.
    pub async fn fetch_pyth_price(&self, feed_id: [u8; 32]) -> Result<RawPrice> {
        let (price, conf, expo, publish_time) =
            self.contract.get_price_unsafe(feed_id).call().await?;

        Ok(RawPrice {
            price,
            conf,
            expo,
            publish_time: publish_time.as_u64(),
        })
    }
}

/// Connect with auto-detection from the URL scheme: `ws://` / `wss://` get a
/// WebSocket provider, everything else falls back to HTTP.
pub async fn connect(rpc_url: &str) -> Result<PythProvider> {
    if rpc_url.starts_with("ws://") || rpc_url.starts_with("wss://") {
        let ws = ethers::providers::Provider::<ethers::providers::Ws>::connect(rpc_url).await?;
        Ok(PythProvider::Ws(Arc::new(ws)))
    } else {
        let http = ethers::providers::Provider::<ethers::providers::Http>::try_from(rpc_url)?;
        Ok(PythProvider::Http(Arc::new(http)))
    }
}

/// Runtime-selected provider so the URL scheme can be decided after config load.
pub enum PythProvider {
    Http(Arc<ethers::providers::Provider<ethers::providers::Http>>),
    Ws(Arc<ethers::providers::Provider<ethers::providers::Ws>>),
}

impl PythProvider {
    pub fn kind(&self) -> &'static str {
        match self {
            PythProvider::Http(_) => "HTTP",
            PythProvider::Ws(_) => "WebSocket",
        }
    }

    /// Build a reader bound to this provider.
    pub fn reader(&self, pyth_address: Address) -> PythReaderEither {
        match self {
            PythProvider::Http(p) => {
                PythReaderEither::Http(PythReader::new(p.clone(), pyth_address))
            }
            PythProvider::Ws(p) => PythReaderEither::Ws(PythReader::new(p.clone(), pyth_address)),
        }
    }
}

/// Either-halves of `PythReader` so callers don't need generics.
pub enum PythReaderEither {
    Http(PythReader<ethers::providers::Provider<ethers::providers::Http>>),
    Ws(PythReader<ethers::providers::Provider<ethers::providers::Ws>>),
}

impl PythReaderEither {
    pub async fn fetch_pyth_price(&self, feed_id: [u8; 32]) -> Result<RawPrice> {
        match self {
            PythReaderEither::Http(r) => r.fetch_pyth_price(feed_id).await,
            PythReaderEither::Ws(r) => r.fetch_pyth_price(feed_id).await,
        }
    }

    pub async fn eth_usd(&self) -> Result<RawPrice> {
        self.fetch_pyth_price(h256_to_id(price_ids::eth_usd()))
            .await
    }

    pub async fn usdc_usd(&self) -> Result<RawPrice> {
        self.fetch_pyth_price(h256_to_id(price_ids::usdc_usd()))
            .await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> RawPrice {
        RawPrice {
            price: 269807261965,
            conf: 33738035,
            expo: -8,
            publish_time: 1_790_327_338,
        }
    }

    #[test]
    fn f64_math_negative_expo() {
        let p = sample();
        assert!((p.to_f64() - 2698.07261965).abs() < 1e-9);
        assert!((p.conf_f64() - 0.33738035).abs() < 1e-9);
    }

    #[test]
    fn f64_math_mixed_expos() {
        let p = RawPrice {
            price: 12345,
            conf: 10,
            expo: -3,
            publish_time: 0,
        };
        assert!((p.to_f64() - 12.345).abs() < 1e-12);
        let p = RawPrice {
            price: 99,
            conf: 1,
            expo: 0,
            publish_time: 0,
        };
        assert!((p.to_f64() - 99.0).abs() < 1e-12);
        let p = RawPrice {
            price: 5,
            conf: 0,
            expo: -1,
            publish_time: 0,
        };
        assert!((p.to_f64() - 0.5).abs() < 1e-12);
    }

    #[test]
    fn scaled_u256_1e8() {
        // 2698.07261965 at 1e8 = 269_807_261_965 — mantissa already 1e8.
        assert_eq!(sample().to_u1e8().unwrap(), U256::from(269_807_261_965u64));
        // expo -6 needs *100 to reach 1e8.
        let p = RawPrice {
            price: 999_999,
            conf: 1,
            expo: -6,
            publish_time: 0,
        };
        assert_eq!(p.to_u1e8().unwrap(), U256::from(99_999_900u64));
        // expo -10: mantissa 1e11 represents 10.0 → 1e9 at 1e8.
        let p = RawPrice {
            price: 100_000_000_000,
            conf: 1,
            expo: -10,
            publish_time: 0,
        };
        assert_eq!(p.to_u1e8().unwrap(), U256::from(1_000_000_000u64));
        // Down-scaling past zero floors to 0 (no underflow/panic).
        let p = RawPrice {
            price: 50,
            conf: 1,
            expo: -12,
            publish_time: 0,
        };
        assert_eq!(p.to_u1e8().unwrap(), U256::zero());
    }

    #[test]
    fn negative_mantissa_rejected_for_u256() {
        let p = RawPrice {
            price: -100,
            conf: 1,
            expo: -8,
            publish_time: 0,
        };
        assert!(p.to_u1e8().is_err());
    }

    #[test]
    fn freshness_window() {
        let now = now_unix();
        let fresh = RawPrice {
            price: 1,
            conf: 1,
            expo: -8,
            publish_time: now - 30,
        };
        let stale = RawPrice {
            price: 1,
            conf: 1,
            expo: -8,
            publish_time: now - 120,
        };
        assert!(fresh.is_fresh(60));
        assert!(!stale.is_fresh(60));
        // Future publishTime (clock skew) counts as fresh.
        let future = RawPrice {
            price: 1,
            conf: 1,
            expo: -8,
            publish_time: now + 10,
        };
        assert!(future.is_fresh(60));
    }

    #[test]
    fn feed_id_conversion_is_stable() {
        let id = h256_to_id(price_ids::eth_usd());
        assert_eq!(
            hex::encode(id),
            "ff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace"
        );
        let id = h256_to_id(price_ids::usdc_usd());
        assert_eq!(
            hex::encode(id),
            "eaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a"
        );
    }
}
