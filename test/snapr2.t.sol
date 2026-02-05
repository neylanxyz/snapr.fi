// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "forge-std/Test.sol";
import "../src/snapr.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";


address constant AAVE_POOL_BASE_SEPOLIA =
    0x8bAB6d1b75f19e9eD9fCe8b9BD338844fF79aE27;


address constant PERMIT2 =
    0x000000000022D473030F116dDEE9F6B43aC78BA3;


address constant USDC =
    0xba50Cd2A20f6DA35D788639E581bca8d0B5d4D5f;

contract SnaprAaveIntegrationTest is Test {
    Snapr snapr;

    address user;
    uint256 userPk;

    function setUp() public {
        // Fork Base Sepolia
        vm.createSelectFork(vm.rpcUrl("base_sepolia"));

        (user, userPk) = makeAddrAndKey("user");

        snapr = new Snapr(AAVE_POOL_BASE_SEPOLIA, PERMIT2);

        // Give user 10 USDC
        deal(USDC, user, 10_000_000);

        // Permit2 needs one-time approval
        vm.prank(user);
        IERC20(USDC).approve(PERMIT2, type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                            REAL AAVE TEST
    //////////////////////////////////////////////////////////////*/

    function testDepositIntoRealAavePool() public {
        uint256 amount = 1_000_000; // 1 USDC

        Snapr.Action[] memory actions = new Snapr.Action[](1);
        actions[0] = snapr.buildDepositAction(USDC, amount);

        vm.startPrank(user);

        // Normal ERC20 approval + transfer
        IERC20(USDC).approve(address(snapr), amount);
        IERC20(USDC).transfer(address(snapr), amount);

        snapr.execute(actions);

        vm.stopPrank();

        // User balance reduced
        assertEq(IERC20(USDC).balanceOf(user), 9_000_000);

        // Snapr should never hold funds
        assertEq(IERC20(USDC).balanceOf(address(snapr)), 0);
    }

    function testDepositIntoRealAavePoolWithPermit2() public {
        uint256 amount = 1_000_000;

        Snapr.Action[] memory actions = new Snapr.Action[](1);
        actions[0] = snapr.buildDepositAction(USDC, amount);

        IPermit2.PermitTransferFrom memory permit = IPermit2.PermitTransferFrom({
            permitted: IPermit2.TokenPermissions({
                token: USDC,
                amount: amount
            }),
            nonce: 0,
            deadline: block.timestamp + 1 hours
        });

        bytes memory sig = _signPermit(permit, userPk);

        vm.prank(user);
        snapr.executeWithPermit2(actions, permit, sig);

        assertEq(IERC20(USDC).balanceOf(user), 9_000_000);
        assertEq(IERC20(USDC).balanceOf(address(snapr)), 0);
    }

    /*//////////////////////////////////////////////////////////////
                        PERMIT2 SIGNING
    //////////////////////////////////////////////////////////////*/

    function _signPermit(
        IPermit2.PermitTransferFrom memory permit,
        uint256 pk
    ) internal view returns (bytes memory) {
        bytes32 domainSeparator = IPermit2(PERMIT2).DOMAIN_SEPARATOR();

        bytes32 tokenPermissionsHash = keccak256(
            abi.encode(
                keccak256(
                    "TokenPermissions(address token,uint256 amount)"
                ),
                permit.permitted.token,
                permit.permitted.amount
            )
        );

        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "PermitTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline)"
                    "TokenPermissions(address token,uint256 amount)"
                ),
                tokenPermissionsHash,
                address(snapr),
                permit.nonce,
                permit.deadline
            )
        );

        bytes32 digest =
            keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }
}
