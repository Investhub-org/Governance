// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { VmSafe } from "forge-std/Vm.sol";
import { LifecycleSim } from "./lifecycle/LifecycleSim.sol";

/// @notice Local simulation of one company. This script never broadcasts.
///
///   forge script script/SimulateLifecycle.s.sol
///   anvil --gas-limit 8000000000
///   SIM_HOLDERS=32 forge script script/SimulateLifecycle.s.sol --rpc-url http://127.0.0.1:8545
///   SIM_FORK=true BASE_RPC_URL=https://mainnet.base.org forge script script/SimulateLifecycle.s.sol
///
/// Do not pass `--broadcast`. `SIM_HOLDERS` defaults to 5000. `SIM_FORK=true` selects a Base fork
/// and requires `BASE_RPC_URL`. A fork is still only a simulation.
contract SimulateLifecycle is LifecycleSim {
    bool public IS_SCRIPT = true;

    function run() external {
        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume)) {
            revert("SimulateLifecycle does not broadcast");
        }
        if (vm.envOr("SIM_FORK", false)) {
            string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
            if (bytes(rpc).length == 0) revert("SIM_FORK requires BASE_RPC_URL");
            vm.createSelectFork(rpc);
        }
        simulate(vm.envOr("SIM_HOLDERS", uint256(5000)));
    }
}
