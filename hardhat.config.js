require("dotenv").config();
require("@nomiclabs/hardhat-waffle");

// This is basically overriding the compiler to the one on 
// |compilerPath|. This is required because hardhat seems
// unable to find the 0.5.X for macos with an M1 chip (but 
// I _think_ it might work for the regular x86_64 chip). 
// 
// The fallback to solcjs (emscripten-wasm32) doesn't work
// because there is no 0.5.17 version available for it on
// https://binaries.soliditylang.org/emscripten-wasm32/list.json
//
// For M1 macs, you can use homewbrew (brew install solidity@5) 
// to install the version 0.5.X.
const os = require('os');
const { TASK_COMPILE_SOLIDITY_GET_SOLC_BUILD } = require("hardhat/builtin-tasks/task-names");
subtask(TASK_COMPILE_SOLIDITY_GET_SOLC_BUILD, async (args, hre, runSuper) => {
  if (args.solcVersion === "0.5.17" && os.platform == "darwin" && os.arch == "arm64") {
    const compilerPath = "/opt/homebrew/bin/solc";

    return {
      compilerPath,
      isSolcJs: false,
      version: args.solcVersion,
      longVersion: "0.5.17+commit.d19bba13.Darwin.appleclang"
    }
  }
  return runSuper();
})

/**
 * @type import('hardhat/config').HardhatUserConfig
 */
module.exports = {
  defaultNetwork: "hardhat",
  solidity: {
    version: "0.5.17",
    settings: {
      optimizer: {
        enabled: true
      }
    }
  },
  networks: {
    testnet: {
      url: "https://cronos-testnet-3.crypto.org:8545",
      accounts: [`0x${process.env.DEPLOY_TESTNET_PRIVATE_KEY}`],
    },
    mainnet: {
      url: "https://evm-cronos.crypto.org",
      accounts: [`0x${process.env.DEPLOY_MAINNET_PRIVATE_KEY}`],
    }
  }
};
