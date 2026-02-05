// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "forge-std/Script.sol";
import {Snapr} from "../src/snapr.sol";

contract DeploySnapr is Script {
    function run() external {
        // Load private key from env
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");

        // === Base Sepolia addresses ===
        address AAVE_POOL = vm.envAddress("AAVE_POOL");
        address PERMIT2 = vm.envAddress("PERMIT2");

        console2.log("AAVE_POOL:", AAVE_POOL);
        console2.log("PERMIT2:", PERMIT2);

        vm.startBroadcast(deployerPk);

        Snapr snapr = new Snapr(AAVE_POOL, PERMIT2);

        vm.stopBroadcast();

        console2.log("Snapr deployed at:", address(snapr));
    }
}
