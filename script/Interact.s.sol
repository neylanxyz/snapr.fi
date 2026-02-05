// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "forge-std/Script.sol";
import "../src/snapr.sol";

contract InteractSnapr is Script {
    function run() external {
        Snapr snapr = Snapr(vm.envAddress("CONTRACT_ADDRESS"));

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        uint256 amount = 1_000_000; // 1 USDC
        if (IERC20(vm.envAddress("USDC_ADDRESS")).balanceOf(address(snapr)) < amount) {
            IERC20(vm.envAddress("USDC_ADDRESS")).transfer(address(snapr), amount);
        }

        Snapr.Action[] memory actions = new Snapr.Action[](1);
        actions[0] = snapr.buildDepositAction(vm.envAddress("USDC_ADDRESS"), 1000000);

        snapr.execute(actions);

        vm.stopBroadcast();
    }
}
