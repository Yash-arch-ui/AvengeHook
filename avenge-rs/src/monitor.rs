use ethers::{
    providers::Middleware,
    types::{Address, Filter, H256, U256},
};
use eyre::Result;
use std::sync::Arc;
use std::time::Duration;

use crate::hook::{hook_contract, Provider};

// ============ Event Topic Hashes ============

fn arbitrage_captured_topic() -> H256 {
    H256::from_slice(
        &hex::decode("815f5204730edec69803e4e5f169e34a0d37eb4217f2d04b104edab0d2496989").unwrap(),
    )
}

fn parameters_updated_topic() -> H256 {
    H256::from_slice(
        &hex::decode("bca959adb5aa52aaea5a17838313a61bebf160bf6064e31593c79c8432c79fea").unwrap(),
    )
}

fn price_id_updated_topic() -> H256 {
    H256::from_slice(
        &hex::decode("614ad967403eca3c4a400b170d2fb8397a2eeffdad616ec761d3e492545f09e2").unwrap(),
    )
}

fn eth_withdrawn_topic() -> H256 {
    H256::from_slice(
        &hex::decode("e85193b00649d7c1275a569a5b49ce0a70d8c33fe2d4dfcb358670aa392e564a").unwrap(),
    )
}

fn erc20_withdrawn_topic() -> H256 {
    H256::from_slice(
        &hex::decode("7f7a3c8adc2282c3f39a78be1ad8844fb24545a77dd1e1179c41d11e8a6da302").unwrap(),
    )
}

fn donate_to_lps_topic() -> H256 {
    H256::from_slice(
        &hex::decode("b9dc18a4dbc9133971c8e3772c1e337989a9f11405f5ed603caf2ba59cad459b").unwrap(),
    )
}

// ============ Monitor ============

/// Monitor polls for ALL DetoxHook events every `interval` seconds.
pub async fn run_monitor(hook_address: Address, rpc_url: &str, interval_secs: u64) -> Result<()> {
    let provider = Provider::try_from(rpc_url)?;
    let client = Arc::new(provider);
    let contract = hook_contract(hook_address, rpc_url)?;

    println!("=== DetoxHook Monitor ===");
    println!("Watching hook: {:?}", hook_address);

    let (rho, staleness, lp_donate) = contract.get_parameters().call().await?;
    println!("Current rhoBps: {} ({}%)", rho, rho.as_u64() as f64 / 100.0);
    println!("Current stalenessThreshold: {}s", staleness);
    println!(
        "Current lpDonateBps: {} ({}%)",
        lp_donate,
        lp_donate.as_u64() as f64 / 100.0
    );

    let mut from_block = client.get_block_number().await?.as_u64();
    println!(
        "\nPolling every {}s from block {}...\n",
        interval_secs, from_block
    );

    loop {
        tokio::time::sleep(Duration::from_secs(interval_secs)).await;

        let to_block = match client.get_block_number().await {
            Ok(b) => b.as_u64(),
            Err(e) => {
                eprintln!("Failed to get block number: {}", e);
                continue;
            }
        };

        if to_block < from_block {
            continue;
        }

        let filter = Filter::new()
            .address(hook_address)
            .from_block(from_block)
            .to_block(to_block);

        let logs = match client.get_logs(&filter).await {
            Ok(l) => l,
            Err(e) => {
                eprintln!("Failed to fetch logs: {}", e);
                continue;
            }
        };

        for log in &logs {
            if log.topics.is_empty() {
                continue;
            }
            let topic0 = log.topics[0];
            let block = log.block_number.unwrap_or_default().as_u64();
            let tx = log.transaction_hash.unwrap_or_default();

            if topic0 == arbitrage_captured_topic() {
                print_arbitrage_captured(log, block, tx);
            } else if topic0 == parameters_updated_topic() {
                print_parameters_updated(log, block, tx);
            } else if topic0 == donate_to_lps_topic() {
                print_donate_to_lps(log, block, tx);
            } else if topic0 == price_id_updated_topic() {
                print_price_id_updated(log, block, tx);
            } else if topic0 == eth_withdrawn_topic() {
                print_eth_withdrawn(log, block, tx);
            } else if topic0 == erc20_withdrawn_topic() {
                print_erc20_withdrawn(log, block, tx);
            }
        }

        from_block = to_block + 1;
    }
}

// ============ One-shot Poll ============

/// One-shot poll: fetch events between two blocks.
pub async fn poll_events(
    hook_address: Address,
    rpc_url: &str,
    from_block: u64,
    to_block: u64,
) -> Result<Vec<ArbitrageEvent>> {
    let client = Provider::try_from(rpc_url)?;

    let filter = Filter::new()
        .address(hook_address)
        .from_block(from_block)
        .to_block(to_block);

    let logs = client.get_logs(&filter).await?;
    let mut events = Vec::new();

    for log in &logs {
        if log.topics.is_empty() {
            continue;
        }
        if log.topics[0] == arbitrage_captured_topic() {
            if let Some(evt) = parse_arbitrage_captured(log) {
                events.push(evt);
            }
        }
    }

    Ok(events)
}

// ============ Event Types ============

#[derive(Debug, Clone)]
pub struct ArbitrageEvent {
    pub pool_id: H256,
    pub currency: Address,
    pub hook_share: U256,
    pub arbitrage_opportunity: U256,
    pub zero_for_one: bool,
    pub block_number: u64,
    pub tx_hash: H256,
}

// ============ Parsers ============

fn parse_arbitrage_captured(log: &ethers::types::Log) -> Option<ArbitrageEvent> {
    if log.topics.len() < 3 || log.data.0.len() < 96 {
        return None;
    }

    Some(ArbitrageEvent {
        pool_id: H256::from(log.topics[1]),
        currency: Address::from_slice(&log.topics[2][12..]),
        hook_share: U256::from_big_endian(&log.data.0[0..32]),
        arbitrage_opportunity: U256::from_big_endian(&log.data.0[32..64]),
        zero_for_one: log.data.0[64] != 0,
        block_number: log.block_number.unwrap_or_default().as_u64(),
        tx_hash: log.transaction_hash.unwrap_or_default(),
    })
}

// ============ Printers ============

fn print_arbitrage_captured(log: &ethers::types::Log, block: u64, tx: H256) {
    if let Some(evt) = parse_arbitrage_captured(log) {
        println!("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
        println!("ARBITRAGE CAPTURED");
        println!("  Pool:        {:?}", evt.pool_id);
        println!("  Currency:    {:?}", evt.currency);
        println!("  Hook Share:  {} wei", evt.hook_share);
        println!("  Arb Opp:     {} wei", evt.arbitrage_opportunity);
        println!(
            "  Direction:   {}",
            if evt.zero_for_one { "0→1" } else { "1→0" }
        );
        println!("  Block:       {}", block);
        println!("  TX:          {:?}", tx);
        println!("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n");
    }
}

fn print_parameters_updated(log: &ethers::types::Log, block: u64, tx: H256) {
    if log.data.0.len() < 128 {
        return;
    }

    let old_rho = U256::from_big_endian(&log.data.0[0..32]);
    let new_rho = U256::from_big_endian(&log.data.0[32..64]);
    let old_stale = U256::from_big_endian(&log.data.0[64..96]);
    let new_stale = U256::from_big_endian(&log.data.0[96..128]);

    println!("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
    println!("PARAMETERS UPDATED");
    println!("  rhoBps:      {} → {}", old_rho, new_rho);
    println!("  staleness:   {}s → {}s", old_stale, new_stale);
    println!("  Block:       {}", block);
    println!("  TX:          {:?}", tx);
    println!("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n");
}

fn print_donate_to_lps(log: &ethers::types::Log, block: u64, tx: H256) {
    if log.topics.len() < 3 || log.data.0.len() < 64 {
        return;
    }

    let pool_id = H256::from(log.topics[1]);
    let currency = Address::from_slice(&log.topics[2][12..]);
    let amount = U256::from_big_endian(&log.data.0[0..32]);
    let hook_kept = U256::from_big_endian(&log.data.0[32..64]);

    println!("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
    println!("DONATED TO LPs");
    println!("  Pool:        {:?}", pool_id);
    println!("  Currency:    {:?}", currency);
    println!("  Donated:     {} wei", amount);
    println!("  Hook kept:   {} wei", hook_kept);
    println!("  Block:       {}", block);
    println!("  TX:          {:?}", tx);
    println!("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n");
}

fn print_price_id_updated(log: &ethers::types::Log, block: u64, tx: H256) {
    if log.topics.len() < 2 || log.data.0.len() < 64 {
        return;
    }

    let currency = Address::from_slice(&log.topics[1][12..]);
    let old_price_id = H256::from_slice(&log.data.0[0..32]);
    let new_price_id = H256::from_slice(&log.data.0[32..64]);

    println!("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
    println!("PRICE ID UPDATED");
    println!("  Currency:    {:?}", currency);
    println!("  Old:         {:?}", old_price_id);
    println!("  New:         {:?}", new_price_id);
    println!("  Block:       {}", block);
    println!("  TX:          {:?}", tx);
    println!("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n");
}

fn print_eth_withdrawn(log: &ethers::types::Log, block: u64, tx: H256) {
    if log.topics.len() < 3 || log.data.0.len() < 32 {
        return;
    }

    let pool_id = H256::from(log.topics[1]);
    let recipient = Address::from_slice(&log.topics[2][12..]);
    let amount = U256::from_big_endian(&log.data.0[0..32]);

    println!("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
    println!("ETH WITHDRAWN");
    println!("  Pool:        {:?}", pool_id);
    println!("  Amount:      {} wei", amount);
    println!("  Recipient:   {:?}", recipient);
    println!("  Block:       {}", block);
    println!("  TX:          {:?}", tx);
    println!("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n");
}

fn print_erc20_withdrawn(log: &ethers::types::Log, block: u64, tx: H256) {
    if log.topics.len() < 3 || log.data.0.len() < 64 {
        return;
    }

    let pool_id = H256::from(log.topics[1]);
    let currency = Address::from_slice(&log.topics[2][12..]);
    let amount = U256::from_big_endian(&log.data.0[0..32]);
    let recipient = Address::from_slice(&log.data.0[32..64]);

    println!("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
    println!("ERC20 WITHDRAWN");
    println!("  Pool:        {:?}", pool_id);
    println!("  Currency:    {:?}", currency);
    println!("  Amount:      {} wei", amount);
    println!("  Recipient:   {:?}", recipient);
    println!("  Block:       {}", block);
    println!("  TX:          {:?}", tx);
    println!("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n");
}
