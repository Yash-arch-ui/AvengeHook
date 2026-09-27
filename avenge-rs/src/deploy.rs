use ethers::types::Address;
use eyre::Result;
use std::process::Command;

/// Deploy AvengeHook by calling the Foundry script.
pub fn deploy_hook(
    forge_dir: &str,
    rpc_url: &str,
    private_key: &str,
    chain_id: u64,
) -> Result<DeployResult> {
    println!("=== Deploying AvengeHook via Forge ===");
    println!("Chain ID: {}", chain_id);
    println!("RPC: {}", rpc_url);
    println!("Forge dir: {}", forge_dir);

    let output = Command::new("forge")
        .args([
            "script",
            "script/DeployAvengeHook.s.sol:DeployAvengeHook",
            "--rpc-url",
            rpc_url,
            "--private-key",
            private_key,
            "--broadcast",
            "-vvv",
        ])
        .current_dir(forge_dir)
        .output()?;

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);

    if !output.status.success() {
        eprintln!("Forge script failed:\n{}", stderr);
        eyre::bail!("Deployment failed");
    }

    println!("Forge output:\n{}", stdout);

    let hook_address = parse_deployed_address(&stdout).unwrap_or_else(|| {
        eprintln!("Could not parse hook address from output");
        Address::zero()
    });

    println!("\n=== Deployment Complete ===");
    println!("Hook address: {:?}", hook_address);

    Ok(DeployResult {
        hook_address,
        stdout: stdout.to_string(),
    })
}

/// Deploy using a local Anvil instance (for testing).
pub fn deploy_local(forge_dir: &str) -> Result<DeployResult> {
    println!("=== Deploying to local Anvil ===");

    let output = Command::new("forge")
        .args([
            "script",
            "script/DeployAvengeHook.s.sol:DeployAvengeHook",
            "--rpc-url",
            "http://127.0.0.1:8545",
            "--broadcast",
            "-vvv",
        ])
        .current_dir(forge_dir)
        .output()?;

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);

    if !output.status.success() {
        eprintln!("Forge script failed:\n{}", stderr);
        eyre::bail!("Local deployment failed");
    }

    println!("Forge output:\n{}", stdout);

    let hook_address = parse_deployed_address(&stdout).unwrap_or_else(|| Address::zero());

    Ok(DeployResult {
        hook_address,
        stdout: stdout.to_string(),
    })
}

/// Run the Forge test suite.
pub fn run_tests(forge_dir: &str) -> Result<bool> {
    println!("=== Running AvengeHook Tests ===");

    let output = Command::new("forge")
        .args(["test", "-vvv"])
        .current_dir(forge_dir)
        .output()?;

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);

    println!("{}", stdout);
    if !stderr.is_empty() {
        eprintln!("{}", stderr);
    }

    Ok(output.status.success())
}

#[derive(Debug)]
pub struct DeployResult {
    pub hook_address: Address,
    pub stdout: String,
}

/// Try to parse a hook address from forge output.
fn parse_deployed_address(output: &str) -> Option<Address> {
    for line in output.lines() {
        if line.contains("deployed at:") || line.contains("AvengeHook deployed at:") {
            let parts: Vec<&str> = line.split("0x").collect();
            if parts.len() > 1 {
                let hex_str = parts
                    .last()?
                    .trim()
                    .trim_end_matches(|c: char| !c.is_ascii_hexdigit());
                if let Ok(bytes) = hex::decode(hex_str) {
                    if bytes.len() == 20 {
                        return Some(Address::from_slice(&bytes));
                    }
                }
            }
        }
    }
    None
}
