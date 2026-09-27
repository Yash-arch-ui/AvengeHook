//! Keeper: pull fresh signed Pyth payloads from Hermes and replay them into
//! the on-chain Pyth store so `getPriceUnsafe` stays inside the hook's
//! `stalenessThreshold`.
//!
//! Flow per poll:
//!   1. `GET hermes …/v2/updates/price/latest?ids[]=ETH&ids[]=USDC` (Bearer key)
//!   2. decode `binary.data[0]` — a signed `PNAU` attestation
//!   3. skip if it is not newer than what the store already holds
//!   4. `getUpdateFee` → `updatePriceFeeds(bytes[])` with the fee attached

use crate::config::Config;
use crate::pyth::PythOracle;
use ethers::{
    middleware::{Middleware, SignerMiddleware},
    providers::{Http, Provider},
    signers::{LocalWallet, Signer},
    types::{Bytes, H256, U256},
};
use eyre::{bail, Result, WrapErr};
use serde::Deserialize;
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

/// Hermes latest-price endpoint (authenticated with `PYTH_API_KEY`).
const HERMES_LATEST: &str = "https://hermes.pyth.network/v2/updates/price/latest";

/// The two feeds the hook consumes.
const ETH_USD_ID: &str = "0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace";
const USDC_USD_ID: &str = "0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a";

/// Explicit gas for `updatePriceFeeds` (payload sizes vary; 500k is ample).
const UPDATE_GAS: u64 = 500_000;

// ============ Hermes response shape ============

#[derive(Debug, Deserialize)]
pub struct HermesResponse {
    pub binary: BinaryPayload,
    pub parsed: Vec<ParsedFeed>,
}

#[derive(Debug, Deserialize)]
pub struct BinaryPayload {
    pub data: Vec<String>,
}

#[derive(Debug, Deserialize)]
pub struct ParsedFeed {
    pub id: String,
    pub price: FeedValue,
}

#[derive(Debug, Deserialize)]
pub struct FeedValue {
    #[allow(dead_code)]
    pub price: String,
    #[allow(dead_code)]
    pub conf: String,
    pub expo: i32,
    pub publish_time: u64,
}

impl FeedValue {
    /// Human-readable price (integer string × 10^expo).
    pub fn as_f64(&self) -> Option<f64> {
        self.price
            .parse::<f64>()
            .ok()
            .map(|p| p * 10f64.powi(self.expo))
    }
}

/// Decode a Hermes `latest` response into
/// `(signed PNAU payload bytes, newest publish_time across the feeds)`.
pub fn extract_update(json: &str) -> Result<(Vec<u8>, u64)> {
    let resp: HermesResponse =
        serde_json::from_str(json).wrap_err("hermes response is not valid JSON")?;
    let hex_payload = resp
        .binary
        .data
        .first()
        .ok_or_else(|| eyre::eyre!("hermes response carries no binary payload"))?;
    let raw =
        hex::decode(hex_payload.trim_start_matches("0x")).wrap_err("binary payload is not hex")?;
    if raw.len() < 8 || &raw[..4] != b"PNAU" {
        bail!(
            "payload is not a PNAU attestation (magic {:?})",
            String::from_utf8_lossy(&raw[..raw.len().min(4)])
        );
    }
    let newest = resp
        .parsed
        .iter()
        .map(|f| f.price.publish_time)
        .max()
        .unwrap_or(0);
    Ok((raw, newest))
}

fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

// ============ Keeper loop ============

/// What one poll did.
pub struct PollOutcome {
    /// How old the payload is right now, in seconds.
    pub age_secs: u64,
    /// ETH / USDC prices carried by the payload (for logging).
    pub eth_price: Option<f64>,
    pub usdc_price: Option<f64>,
    /// `None` when the store already holds data at least this new.
    pub tx: Option<(H256, U256)>,
}

type KeeperContract = PythOracle<SignerMiddleware<Provider<Http>, LocalWallet>>;

/// Fetch the latest Hermes payload and (if newer than the store) publish it.
pub async fn poll_once(
    http: &reqwest::Client,
    api_key: &str,
    contract: &KeeperContract,
) -> Result<PollOutcome> {
    let resp = http
        .get(HERMES_LATEST)
        .query(&[("ids[]", ETH_USD_ID), ("ids[]", USDC_USD_ID)])
        .bearer_auth(api_key)
        .send()
        .await
        .wrap_err("hermes request failed")?;
    let status = resp.status();
    let body = resp.text().await.wrap_err("hermes body read failed")?;
    if !status.is_success() {
        let snippet: String = body.chars().take(160).collect();
        bail!("hermes HTTP {status}: {snippet}");
    }

    let (payload, newest) = extract_update(&body)?;

    // Prices for logging (parse before any on-chain work).
    let parsed: HermesResponse = serde_json::from_str(&body)?;
    let eth_price = parsed
        .parsed
        .iter()
        .find(|f| {
            f.id.eq_ignore_ascii_case(&ETH_USD_ID.trim_start_matches("0x"))
        })
        .and_then(|f| f.price.as_f64());
    let usdc_price = parsed
        .parsed
        .iter()
        .find(|f| {
            f.id.eq_ignore_ascii_case(&USDC_USD_ID.trim_start_matches("0x"))
        })
        .and_then(|f| f.price.as_f64());

    // Compare against what the store already holds.
    let eth = contract
        .get_price_unsafe(crate::pyth::price_ids::eth_usd().into())
        .call()
        .await
        .wrap_err("read ETH publishTime from store")?;
    let usdc = contract
        .get_price_unsafe(crate::pyth::price_ids::usdc_usd().into())
        .call()
        .await
        .wrap_err("read USDC publishTime from store")?;
    let stored_max = eth.3.max(usdc.3).as_u64();

    let age = now_secs().saturating_sub(newest);
    if newest <= stored_max {
        return Ok(PollOutcome {
            age_secs: age,
            eth_price,
            usdc_price,
            tx: None,
        });
    }

    // Publish: fee first, then the update with the fee attached.
    let bytes = Bytes::from(payload);
    let fee = contract
        .get_update_fee(vec![bytes.clone()])
        .call()
        .await
        .wrap_err("getUpdateFee reverted")?;
    let call = contract
        .update_price_feeds(vec![bytes])
        .value(fee)
        .gas(UPDATE_GAS);
    let pending = call.send().await.wrap_err("updatePriceFeeds send failed")?;
    let tx_hash = pending.tx_hash();
    let receipt = pending
        .await?
        .ok_or_else(|| eyre::eyre!("no receipt for {tx_hash:?}"))?;
    if receipt.status != Some(1.into()) {
        bail!("updatePriceFeeds reverted: {tx_hash:?}");
    }

    Ok(PollOutcome {
        age_secs: age,
        eth_price,
        usdc_price,
        tx: Some((tx_hash, fee)),
    })
}

/// Run the keeper loop.
///
/// * `interval_secs` — pause between polls (default 5)
/// * `max_polls` — stop after N polls (`None` = run forever)
pub async fn run(interval_secs: u64, max_polls: Option<u64>) -> Result<()> {
    let cfg = Config::load()?;
    let api_key = std::env::var("PYTH_API_KEY")
        .wrap_err("Set PYTH_API_KEY in .env (free Pyth Terminal key, pythdata.app)")?;
    let pk = std::env::var("DEPLOYMENT_KEY")
        .wrap_err("Set DEPLOYMENT_KEY in .env (keeper publishes updates)")?;

    let provider = Provider::<Http>::try_from(cfg.rpc_url.as_str())?;
    let chain_id = provider.get_chainid().await?.as_u64();
    let wallet = pk.parse::<LocalWallet>()?.with_chain_id(chain_id);
    let client = Arc::new(SignerMiddleware::new(provider, wallet));
    let contract = PythOracle::new(cfg.pyth_address, client);

    let http = reqwest::Client::builder()
        .timeout(Duration::from_secs(10))
        .build()?;

    println!(
        "keeper: Hermes → Pyth store {:#x} every {interval_secs}s (poll limit: {})",
        cfg.pyth_address,
        max_polls
            .map(|n| n.to_string())
            .unwrap_or_else(|| "∞".into())
    );

    let mut polls: u64 = 0;
    loop {
        polls += 1;
        match poll_once(&http, &api_key, &contract).await {
            Ok(outcome) => {
                let prices = match (outcome.eth_price, outcome.usdc_price) {
                    (Some(e), Some(u)) => format!("ETH={e:.2} USDC={u:.6} "),
                    _ => String::new(),
                };
                match outcome.tx {
                    Some((tx, fee)) => println!(
                        "[{polls}] {prices}age={}s → {tx:#x} fee={fee} wei",
                        outcome.age_secs
                    ),
                    None => println!(
                        "[{polls}] {prices}age={}s → store already current, skipped",
                        outcome.age_secs
                    ),
                }
            }
            Err(e) => eprintln!("[{polls}] keeper error: {e:#}"),
        }

        if let Some(max) = max_polls {
            if polls >= max {
                break;
            }
        }
        tokio::time::sleep(Duration::from_secs(interval_secs)).await;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    const FIXTURE: &str = include_str!("../fixtures/hermes_latest.json");

    #[test]
    fn extract_update_decodes_pnau_payload() {
        let (payload, newest) = extract_update(FIXTURE).expect("fixture must decode");
        assert_eq!(&payload[..4], b"PNAU");
        assert_eq!(payload.len(), 959);
        assert_eq!(newest, 1790524222);
    }

    #[test]
    fn extract_update_reads_both_feed_prices() {
        let resp: HermesResponse = serde_json::from_str(FIXTURE).unwrap();
        assert_eq!(resp.parsed.len(), 2);
        let eth = resp
            .parsed
            .iter()
            .find(|f| f.id.starts_with("ff61"))
            .expect("ETH feed present");
        let price = eth.price.as_f64().expect("price parses");
        assert!(
            (2000.0..5000.0).contains(&price),
            "ETH price {price} in range"
        );
        assert_eq!(eth.price.publish_time, 1790524222);
    }

    #[test]
    fn extract_update_rejects_non_pnau_payload() {
        let bad = r#"{"binary":{"data":["deadbeef"]},"parsed":[]}"#;
        let err = extract_update(bad).expect_err("must reject non-PNAU");
        assert!(err.to_string().contains("PNAU"), "got: {err}");
    }

    #[test]
    fn extract_update_rejects_bad_json() {
        assert!(extract_update("not json").is_err());
        assert!(extract_update(r#"{"binary":{"data":[]},"parsed":[]}"#).is_err());
    }
}
