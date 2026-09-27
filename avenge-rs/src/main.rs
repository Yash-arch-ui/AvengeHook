mod config;
mod deploy;
mod hook;
mod keeper;
mod monitor;
mod pyth;
mod pyth_live;
use ethers::types::{Address, H256, I256, U256};
use eyre::Result;

#[tokio::main]
async fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    let command = args.get(1).map(|s| s.as_str()).unwrap_or("help");

    match command {
        "monitor" => cmd_monitor().await,
        "prices" => cmd_prices().await,
        "live-prices" => cmd_live_prices().await,
        "keeper" => cmd_keeper().await,
        "state" => cmd_state().await,
        "params" => cmd_params().await,
        "oracle" => cmd_oracle().await,
        "permissions" => cmd_permissions().await,
        "simulate" => cmd_simulate().await,
        "update-params" => cmd_update_params().await,
        "set-price-id" => cmd_set_price_id().await,
        "withdraw" => cmd_withdraw().await,
        "deploy" => cmd_deploy(),
        "deploy-local" => cmd_deploy_local(),
        "test" => cmd_test(),
        "help" | "--help" | "-h" => {
            print_help();
            Ok(())
        }
        _ => {
            eprintln!("Unknown command: {}", command);
            print_help();
            std::process::exit(1);
        }
    }
}

fn print_help() {
    println!(
        r#"detox-rs — DetoxHook monitor and manager

Usage: detox-rs <COMMAND>

Commands:
  monitor          Watch for all DetoxHook events (real-time)
  prices           Fetch current Pyth oracle prices
  live-prices      Keyless on-chain Pyth reader (RPC HTTP/WS, no API keys)
  keeper [interval_secs] [max_polls]
                 Replay fresh Hermes payloads into the Pyth store
                 (default every 5s; needs PYTH_API_KEY + DEPLOYMENT_KEY)
  state            Read on-chain hook state (owner, params, accumulated tokens)
  params           Show current hook parameters
  oracle           Get oracle prices with confidence from the hook contract
  permissions      Show hook permission flags
  simulate [amount] [zeroForOne]
                 Quote calculateArbitrageOpportunity for a swap (default 1.0 token0)
  update-params    Update rhoBps and staleness (owner only)
  set-price-id     Set Pyth price ID for a currency (owner only)
  withdraw         Withdraw accumulated ETH or ERC20 (owner only)
  deploy           Deploy DetoxHook via Forge (requires DEPLOYMENT_KEY)
  deploy-local     Deploy to local Anvil for testing
  test             Run Forge test suite
  help             Show this message

Environment variables (set in .env):
  RPC_URL          Ethereum RPC endpoint (HTTP or WSS)
  HOOK_ADDRESS     DetoxHook contract address
  PYTH_ADDRESS     Pyth oracle address
  PYTH_API_KEY     Hermes API key for `keeper` (free trial at pythdata.app)
  CHAIN_ID         Chain ID (default: 421614 = Arbitrum Sepolia)
  FORGE_DIR        Path to Foundry project (auto-detected if unset)
  POOL_ID          Pool ID for state reads (default: ETH/USDC 0.30% / tickSpacing 60)
  USDC_ADDRESS     USDC token used by state/oracle/simulate
  DEPLOYMENT_KEY   Private key for deployment (owner commands only)
"#
    );
}

// ============ Read Commands ============

async fn cmd_monitor() -> Result<()> {
    let cfg = config::Config::load()?;
    monitor::run_monitor(cfg.hook_address, &cfg.rpc_url, 2).await
}

async fn cmd_keeper() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    let interval: u64 = args.get(2).and_then(|a| a.parse().ok()).unwrap_or(5);
    let max_polls: Option<u64> = args.get(3).and_then(|a| a.parse().ok());
    keeper::run(interval, max_polls).await
}

async fn cmd_prices() -> Result<()> {
    let cfg = config::Config::load()?;

    if cfg.pyth_address == Address::zero() {
        eyre::bail!("PYTH_ADDRESS not set in .env");
    }

    let client = pyth::PythClient::new(cfg.pyth_address, &cfg.rpc_url)?;

    println!("=== Pyth Oracle Prices ===\n");

    match client.get_eth_price().await {
        Ok(p) => {
            let price_f = p.price.as_u64() as f64 / 1e8;
            let conf_f = p.confidence.as_u64() as f64 / 1e8;
            println!(
                "ETH/USD:  ${:.2} ± ${:.2}  (valid: {}, published: {})",
                price_f, conf_f, p.valid, p.publish_time
            );
        }
        Err(e) => println!("ETH/USD:  Error — {}", e),
    }

    match client.get_usdc_price().await {
        Ok(p) => {
            let price_f = p.price.as_u64() as f64 / 1e8;
            let conf_f = p.confidence.as_u64() as f64 / 1e8;
            println!(
                "USDC/USD: ${:.6} ± ${:.6}  (valid: {}, published: {})",
                price_f, conf_f, p.valid, p.publish_time
            );
        }
        Err(e) => println!("USDC/USD: Error — {}", e),
    }

    match client.get_btc_price().await {
        Ok(p) => {
            let price_f = p.price.as_u64() as f64 / 1e8;
            let conf_f = p.confidence.as_u64() as f64 / 1e8;
            println!(
                "BTC/USD:  ${:.2} ± ${:.2}  (valid: {}, published: {})",
                price_f, conf_f, p.valid, p.publish_time
            );
        }
        Err(e) => println!("BTC/USD:  Error — {}", e),
    }

    Ok(())
}

/// Keyless on-chain Pyth price loop: reads `getPriceUnsafe` straight over the
/// RPC endpoint (HTTP or WS auto-detected from RPC_URL). No Hermes, no API keys.
/// Prints both feeds plus freshness against the hook's configured staleness.
async fn cmd_live_prices() -> Result<()> {
    use std::time::Duration;

    let cfg = config::Config::load()?;
    let provider = pyth_live::connect(&cfg.rpc_url).await?;
    let reader = provider.reader(cfg.pyth_address);

    // Freshness window comes from the live hook itself (rho/staleness params)
    let (_, staleness, _) = hook::get_parameters(cfg.hook_address, &cfg.rpc_url).await?;
    let max_age = staleness.as_u64();

    let interval_ms: u64 = std::env::var("LIVE_PRICES_INTERVAL_MS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(2_000);
    let max_ticks: u64 = std::env::var("LIVE_PRICES_TICKS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(u64::MAX);

    println!(
        "=== On-Chain Pyth Prices (keyless, {} RPC) ===\n  pyth: {:?}  staleness: {}s  interval: {}ms\n",
        provider.kind(),
        cfg.pyth_address,
        max_age,
        interval_ms
    );
    println!(
        "{:<8} {:>14} {:>22} {:>10} {:>8} {:>10} {:>7} {:>9}",
        "feed", "price", "price@1e8 (LP units)", "conf", "expo", "age_s", "fresh", "rpc_ms"
    );

    let mut tick: u64 = 0;
    loop {
        let t0 = std::time::Instant::now();
        let (eth, usdc) = tokio::join!(reader.eth_usd(), reader.usdc_usd());
        let (eth, usdc) = (eth?, usdc?);
        let rpc_ms = t0.elapsed().as_millis();

        for (name, p) in [("ETH/USD", &eth), ("USDC/USD", &usdc)] {
            println!(
                "{:<8} {:>14.6} {:>22} {:>10.6} {:>8} {:>10} {:>7} {:>9}",
                name,
                p.to_f64(),
                p.to_u1e8()?,
                p.conf_f64(),
                p.expo,
                p.age_secs().max(0),
                p.is_fresh(max_age),
                rpc_ms
            );
        }
        println!();

        tick += 1;
        if tick >= max_ticks {
            return Ok(());
        }
        tokio::time::sleep(Duration::from_millis(interval_ms)).await;
    }
}

async fn cmd_state() -> Result<()> {
    let cfg = config::Config::load()?;

    println!("=== DetoxHook State ===\n");
    println!("Hook address: {:?}", cfg.hook_address);

    let owner = hook::get_owner(cfg.hook_address, &cfg.rpc_url).await?;
    println!("Owner:        {:?}", owner);

    let pyth = hook::get_pyth_oracle(cfg.hook_address, &cfg.rpc_url).await?;
    println!("Pyth oracle:  {:?}", pyth);

    let (rho, staleness, lp_donate) = hook::get_parameters(cfg.hook_address, &cfg.rpc_url).await?;
    println!("rhoBps:       {} ({}%)", rho, rho.as_u64() as f64 / 100.0);
    println!("staleness:    {}s", staleness);
    println!(
        "lpDonateBps:  {} ({}%)",
        lp_donate,
        lp_donate.as_u64() as f64 / 100.0
    );

    // Per-pool accumulators (POOL_ID env, defaults to the ETH/USDC 0.05% pool)
    let pool_id = cfg.pool_id;
    let eth_addr = Address::zero();
    let acc_eth =
        hook::get_accumulated_tokens(cfg.hook_address, &cfg.rpc_url, pool_id, eth_addr).await?;
    println!("Pool ID:         0x{}", hex::encode(pool_id));
    println!("Accumulated ETH: {} wei", acc_eth);

    let acc_usdc =
        hook::get_accumulated_tokens(cfg.hook_address, &cfg.rpc_url, pool_id, cfg.usdc_address)
            .await?;
    println!(
        "Accumulated USDC ({}): {} raw units",
        cfg.usdc_address, acc_usdc
    );

    // Check price IDs
    let eth_price_id = hook::get_pyth_price_id(cfg.hook_address, &cfg.rpc_url, eth_addr).await?;
    println!("ETH price ID: 0x{}", hex::encode(eth_price_id));

    let usdc_price_id =
        hook::get_pyth_price_id(cfg.hook_address, &cfg.rpc_url, cfg.usdc_address).await?;
    println!("USDC price ID: 0x{}", hex::encode(usdc_price_id));

    Ok(())
}

async fn cmd_params() -> Result<()> {
    let cfg = config::Config::load()?;
    let (rho, staleness, lp_donate) = hook::get_parameters(cfg.hook_address, &cfg.rpc_url).await?;

    println!("rhoBps:          {}", rho);
    println!("stalenessThreshold: {}s", staleness);
    println!(
        "lpDonateBps:     {} ({}%)",
        lp_donate,
        lp_donate.as_u64() as f64 / 100.0
    );

    Ok(())
}

async fn cmd_oracle() -> Result<()> {
    let cfg = config::Config::load()?;

    println!("=== Hook Oracle Prices ===\n");

    // Prices come from the hook's own Pyth views, so PYTH_ADDRESS is not needed here
    let eth_addr = Address::zero();
    let usdc = cfg.usdc_address;

    // ETH
    match hook::get_oracle_price_with_confidence(cfg.hook_address, &cfg.rpc_url, eth_addr).await {
        Ok((price, conf, valid, publish_time)) => {
            let price_f = price.as_u64() as f64 / 1e8;
            let conf_f = conf.as_u64() as f64 / 1e8;
            println!(
                "ETH/USD:  ${:.2} ± ${:.2}  (valid: {}, publishTime: {})",
                price_f, conf_f, valid, publish_time
            );
        }
        Err(e) => println!("ETH/USD:  Error — {}", e),
    }

    // USDC
    match hook::get_oracle_price_with_confidence(cfg.hook_address, &cfg.rpc_url, usdc).await {
        Ok((price, conf, valid, publish_time)) => {
            let price_f = price.as_u64() as f64 / 1e8;
            let conf_f = conf.as_u64() as f64 / 1e8;
            println!(
                "USDC/USD: ${:.6} ± ${:.6}  (valid: {}, publishTime: {})",
                price_f, conf_f, valid, publish_time
            );
        }
        Err(e) => println!("USDC/USD: Error — {}", e),
    }

    Ok(())
}

async fn cmd_permissions() -> Result<()> {
    let cfg = config::Config::load()?;
    let perms = hook::get_hook_permissions(cfg.hook_address, &cfg.rpc_url).await?;

    println!("=== Hook Permissions ===\n");
    println!("beforeInitialize:              {}", perms.before_initialize);
    println!("afterInitialize:               {}", perms.after_initialize);
    println!(
        "beforeAddLiquidity:            {}",
        perms.before_add_liquidity
    );
    println!(
        "beforeRemoveLiquidity:         {}",
        perms.before_remove_liquidity
    );
    println!(
        "afterAddLiquidity:             {}",
        perms.after_add_liquidity
    );
    println!(
        "afterRemoveLiquidity:          {}",
        perms.after_remove_liquidity
    );
    println!("beforeSwap:                    {}", perms.before_swap);
    println!("afterSwap:                     {}", perms.after_swap);
    println!("beforeDonate:                  {}", perms.before_donate);
    println!("afterDonate:                   {}", perms.after_donate);
    println!(
        "beforeSwapReturnDelta:         {}",
        perms.before_swap_return_delta
    );
    println!(
        "afterSwapReturnDelta:          {}",
        perms.after_swap_return_delta
    );
    println!(
        "afterAddLiquidityReturnDelta:  {}",
        perms.after_add_liquidity_return_delta
    );
    println!(
        "afterRemoveLiquidityReturnDelta: {}",
        perms.after_remove_liquidity_return_delta
    );

    Ok(())
}

async fn cmd_simulate() -> Result<()> {
    let cfg = config::Config::load()?;
    let args: Vec<String> = std::env::args().collect();

    println!("=== Simulate Swap on DetoxHook ===\n");

    // Read hook state
    let (rho, staleness, lp_donate) = hook::get_parameters(cfg.hook_address, &cfg.rpc_url).await?;
    println!("rhoBps: {} ({}%)", rho, rho.as_u64() as f64 / 100.0);
    println!("staleness: {}s", staleness);
    println!(
        "lpDonateBps: {} ({}%)",
        lp_donate,
        lp_donate.as_u64() as f64 / 100.0
    );

    // Read oracle prices
    let eth_addr = Address::zero();
    let usdc = cfg.usdc_address;

    println!("\n--- Oracle Prices ---");
    let (eth_price, eth_conf, eth_valid, _) =
        hook::get_oracle_price_with_confidence(cfg.hook_address, &cfg.rpc_url, eth_addr).await?;
    println!(
        "ETH: ${:.2} ± ${:.2} (valid: {})",
        eth_price.as_u64() as f64 / 1e8,
        eth_conf.as_u64() as f64 / 1e8,
        eth_valid
    );

    let (usdc_price, usdc_conf, usdc_valid, _) =
        hook::get_oracle_price_with_confidence(cfg.hook_address, &cfg.rpc_url, usdc).await?;
    println!(
        "USDC: ${:.6} ± ${:.6} (valid: {})",
        usdc_price.as_u64() as f64 / 1e8,
        usdc_conf.as_u64() as f64 / 1e8,
        usdc_valid
    );

    if eth_valid && usdc_valid && usdc_price > U256::zero() {
        // Compute implied market price: ETH/USDC
        let market_price = eth_price * U256::from(10u128).pow(U256::from(8)) / usdc_price;
        println!("\n--- Derived ---");
        println!(
            "Implied ETH/USDC: ${:.2}",
            market_price.as_u64() as f64 / 1e8
        );

        let conf_ratio = if eth_price > U256::zero() {
            eth_conf * U256::from(10000) / eth_price
        } else {
            U256::zero()
        };
        println!("ETH confidence ratio: {} bps", conf_ratio);
        println!(
            "Confidence band: ${:.2} – ${:.2}",
            (eth_price - eth_conf).as_u64() as f64 / 1e8,
            (eth_price + eth_conf).as_u64() as f64 / 1e8
        );
    }

    // --- On-chain simulation -------------------------------------------------
    // Usage: detox-rs simulate [amountIn] [zeroForOne]
    //   amountIn   : input amount in whole tokens (default 1.0)
    //   zeroForOne : true = sell currency0, false = sell currency1
    let amount_in: f64 = args.get(2).and_then(|a| a.parse().ok()).unwrap_or(1.0);
    let zero_for_one = args
        .get(3)
        .map(|a| matches!(a.as_str(), "true" | "1" | "yes"))
        .unwrap_or(true);

    let currency0 = env_address("CURRENCY0", Address::zero())?;
    let currency1 = env_address("CURRENCY1", cfg.usdc_address)?;
    // Defaults match the live ETH/USDC Pool 1 (POOL_ID=0x5771f78e...):
    // dynamic fee 8388608, tickSpacing 30
    let fee: u32 = std::env::var("POOL_FEE")
        .unwrap_or_else(|_| "8388608".into())
        .parse()?;
    let tick_spacing: i32 = std::env::var("TICK_SPACING")
        .unwrap_or_else(|_| "30".into())
        .parse()?;
    let decimals0: u32 = std::env::var("CURRENCY0_DECIMALS")
        .unwrap_or_else(|_| "18".into())
        .parse()?;
    let decimals1: u32 = std::env::var("CURRENCY1_DECIMALS")
        .unwrap_or_else(|_| "6".into())
        .parse()?;

    let (input_currency, input_decimals) = if zero_for_one {
        (currency0, decimals0)
    } else {
        (currency1, decimals1)
    };
    let amount_raw = U256::from_dec_str(&format!(
        "{:.0}",
        amount_in * 10f64.powi(input_decimals as i32)
    ))?;
    let amount_specified =
        -I256::try_from(amount_raw).map_err(|_| eyre::eyre!("amount is too large for int256"))?;

    let sqrt_price_limit_x96 = if zero_for_one {
        U256::from(4295128740u64) // TickMath.MIN_SQRT_PRICE + 1
    } else {
        U256::from_dec_str("1461446703485210103287273052203988822378723970341")?
        // MAX_SQRT_PRICE - 1
    };

    let key = hook::PoolKey {
        currency_0: currency0,
        currency_1: currency1,
        fee,
        tick_spacing,
        hooks: cfg.hook_address,
    };
    let params = hook::SwapParams {
        zero_for_one,
        amount_specified,
        sqrt_price_limit_x96,
    };

    let (arbitrage_opp, hook_share, should_interfere, outside_band) =
        hook::calculate_arbitrage_opportunity(cfg.hook_address, &cfg.rpc_url, key, params).await?;

    let input_symbol = if zero_for_one { "token0" } else { "token1" };
    println!("\n--- calculateArbitrageOpportunity(poolKey, swapParams) ---");
    println!(
        "pool:                fee={} tickSpacing={} hooks={:?}",
        fee, tick_spacing, cfg.hook_address
    );
    println!(
        "swap:                zeroForOne={} amountSpecified={} ({} {})",
        zero_for_one, amount_specified, amount_in, input_symbol
    );
    println!("input currency:      {:?}", input_currency);
    println!(
        "arbitrageOpp:        {} (input currency units)",
        arbitrage_opp
    );
    println!(
        "hookShare:           {} (rhoBps={} -> {:.2}% of opportunity)",
        hook_share,
        rho,
        rho.as_u64() as f64 / 100.0
    );
    println!("shouldInterfere:     {}", should_interfere);
    println!("outsideConfBand:     {}", outside_band);
    println!(
        "hint:                {} {} in {} raw units",
        input_symbol, amount_in, amount_raw
    );

    Ok(())
}

// ============ Owner Write Commands ============

async fn cmd_update_params() -> Result<()> {
    let cfg = config::Config::load()?;
    let private_key = std::env::var("DEPLOYMENT_KEY").expect("Set DEPLOYMENT_KEY in .env");

    let args: Vec<String> = std::env::args().collect();
    if args.len() < 4 {
        eprintln!("Usage: detox-rs update-params <rhoBps> <stalenessThreshold>");
        eprintln!("  rhoBps:  hook share in basis points (0-10000)");
        eprintln!("  staleness: oracle staleness limit in seconds");
        std::process::exit(1);
    }

    let rho_bps: u64 = args[2].parse()?;
    let staleness: u64 = args[3].parse()?;

    println!(
        "Updating parameters: rhoBps={}, staleness={}s",
        rho_bps, staleness
    );
    let receipt = hook::update_parameters(
        cfg.hook_address,
        &cfg.rpc_url,
        &private_key,
        U256::from(rho_bps),
        U256::from(staleness),
    )
    .await?;

    println!("TX: {:?}", receipt.transaction_hash);
    println!("Gas used: {:?}", receipt.gas_used);
    Ok(())
}

async fn cmd_set_price_id() -> Result<()> {
    let cfg = config::Config::load()?;
    let private_key = std::env::var("DEPLOYMENT_KEY").expect("Set DEPLOYMENT_KEY in .env");

    let args: Vec<String> = std::env::args().collect();
    if args.len() < 4 {
        eprintln!("Usage: detox-rs set-price-id <currency> <priceIdHex>");
        eprintln!("  currency:   token address (use 0x0000...0000 for ETH)");
        eprintln!("  priceIdHex: Pyth price ID as hex (0x...)");
        std::process::exit(1);
    }

    let currency: Address = args[2].parse()?;
    let price_id_bytes = hex::decode(args[3].trim_start_matches("0x"))?;
    if price_id_bytes.len() != 32 {
        eprintln!("Price ID must be 32 bytes");
        std::process::exit(1);
    }
    let price_id = H256::from_slice(&price_id_bytes);

    println!("Setting price ID for {:?}: {:?}", currency, price_id);
    let receipt = hook::set_price_id(
        cfg.hook_address,
        &cfg.rpc_url,
        &private_key,
        currency,
        price_id,
    )
    .await?;

    println!("TX: {:?}", receipt.transaction_hash);
    println!("Gas used: {:?}", receipt.gas_used);
    Ok(())
}

async fn cmd_withdraw() -> Result<()> {
    let cfg = config::Config::load()?;
    let private_key = std::env::var("DEPLOYMENT_KEY").expect("Set DEPLOYMENT_KEY in .env");

    let args: Vec<String> = std::env::args().collect();
    if args.len() < 5 {
        eprintln!("Usage: detox-rs withdraw <poolIdHex> <currency> <amount> <recipient>");
        eprintln!("  poolIdHex:  pool ID as hex (0x...)");
        eprintln!("  currency:   token address (use 0x0000...0000 for ETH)");
        eprintln!("  amount:     amount in wei");
        eprintln!("  recipient:  address to receive funds");
        std::process::exit(1);
    }

    let pool_id_bytes = hex::decode(args[2].trim_start_matches("0x"))?;
    if pool_id_bytes.len() != 32 {
        eprintln!("Pool ID must be 32 bytes");
        std::process::exit(1);
    }
    let mut pool_id = [0u8; 32];
    pool_id.copy_from_slice(&pool_id_bytes);

    let currency: Address = args[3].parse()?;
    let amount: U256 = args[4].parse()?;
    let recipient: Address = args[5].parse()?;

    println!(
        "Withdrawing {} from pool {:?} to {:?}",
        amount, pool_id, recipient
    );

    let receipt = if currency == Address::zero() {
        hook::withdraw_accumulated_eth(
            cfg.hook_address,
            &cfg.rpc_url,
            &private_key,
            pool_id,
            amount,
            recipient,
        )
        .await?
    } else {
        hook::withdraw_accumulated_erc20(
            cfg.hook_address,
            &cfg.rpc_url,
            &private_key,
            pool_id,
            currency,
            amount,
            recipient,
        )
        .await?
    };

    println!("TX: {:?}", receipt.transaction_hash);
    println!("Gas used: {:?}", receipt.gas_used);
    Ok(())
}

// ============ Deploy Commands ============

fn cmd_deploy() -> Result<()> {
    let cfg = config::Config::load()?;
    let private_key = std::env::var("DEPLOYMENT_KEY").expect("Set DEPLOYMENT_KEY in .env");
    let result = deploy::deploy_hook(&cfg.forge_dir, &cfg.rpc_url, &private_key, cfg.chain_id)?;
    println!("Hook deployed at: {:?}", result.hook_address);
    Ok(())
}

fn cmd_deploy_local() -> Result<()> {
    let cfg = config::Config::load()?;
    let result = deploy::deploy_local(&cfg.forge_dir)?;
    println!("Hook deployed at: {:?}", result.hook_address);
    Ok(())
}

fn cmd_test() -> Result<()> {
    let cfg = config::Config::load()?;
    let success = deploy::run_tests(&cfg.forge_dir)?;
    if !success {
        std::process::exit(1);
    }
    Ok(())
}

/// Read an optional address from the environment, falling back to `default`.
fn env_address(var: &str, default: Address) -> Result<Address> {
    match std::env::var(var) {
        Ok(v) if !v.trim().is_empty() => Ok(v.trim().parse()?),
        _ => Ok(default),
    }
}
