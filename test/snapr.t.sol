// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "forge-std/Test.sol";
import "../src/snapr.sol";

interface IERC20Metadata {
    function decimals() external view returns (uint8);
}

/// @notice Mock Aave pool so execute tests don't depend on live Aave config.
contract MockAavePool {
    function deposit(
        address asset,
        uint256 amount,
        address,
        uint16
    ) external {
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
    }

    function borrow(
        address,
        uint256,
        uint256,
        uint16,
        address
    ) external pure {
        revert("mock");
    }
}

/// @notice Same ABI layout as Snapr.Action so we can encode actionType=2 without enum panic.
struct RawAction {
    uint8 actionType;
    bytes data;
}

contract SnaprTest is Test {
    Snapr snapr;
    MockAavePool mockPool;

    // ===== Base Sepolia addresses =====
    /// @dev Uniswap canonical Permit2 (same address on all EVM chains via CREATE2).
    address constant PERMIT2 =
        0x000000000022D473030F116dDEE9F6B43aC78BA3;

    address constant USDC =
        0xba50Cd2A20f6DA35D788639E581bca8d0B5d4D5f;

    address user;
    uint256 userPk;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("base_sepolia"));

        (user, userPk) = makeAddrAndKey("user");

        mockPool = new MockAavePool();
        snapr = new Snapr(address(mockPool), PERMIT2);

        deal(USDC, user, 10_000_000); // 10 USDC (6 decimals)

        // Permit2 requires one-time token approval
        vm.prank(user);
        IERC20(USDC).approve(PERMIT2, type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                        ACTION BUILDER TESTS
    //////////////////////////////////////////////////////////////*/

    function testBuildDepositAction() public view {
        address asset = USDC;
        uint256 amount = 1_000_000;

        Snapr.Action memory action = snapr.buildDepositAction(asset, amount);

        assertEq(uint256(action.actionType), uint256(Snapr.ActionType.AAVE_DEPOSIT));

        (address decodedAsset, uint256 decodedAmount) =
            abi.decode(action.data, (address, uint256));
        assertEq(decodedAsset, asset);
        assertEq(decodedAmount, amount);
    }

    function testBuildBorrowAction() public view {
        address asset = USDC;
        uint256 amount = 500_000;
        uint256 interestRateMode = 2; // variable

        Snapr.Action memory action =
            snapr.buildBorrowAction(asset, amount, interestRateMode);

        assertEq(uint256(action.actionType), uint256(Snapr.ActionType.AAVE_BORROW));

        (
            address decodedAsset,
            uint256 decodedAmount,
            uint256 decodedMode
        ) = abi.decode(action.data, (address, uint256, uint256));
        assertEq(decodedAsset, asset);
        assertEq(decodedAmount, amount);
        assertEq(decodedMode, interestRateMode);
    }

    /*//////////////////////////////////////////////////////////////
                        EXECUTE (APPROVE + TRANSFER) TESTS
    //////////////////////////////////////////////////////////////*/

    function testExecuteDeposit() public {
        uint256 amount = 1_000_000;

        Snapr.Action[] memory actions = new Snapr.Action[](1);
        actions[0] = snapr.buildDepositAction(USDC, amount);

        vm.startPrank(user);
        IERC20(USDC).approve(address(snapr), amount);
        IERC20(USDC).transfer(address(snapr), amount);
        snapr.execute(actions);
        vm.stopPrank();

        assertEq(IERC20(USDC).balanceOf(user), 10_000_000 - amount);
        assertEq(IERC20(USDC).balanceOf(address(snapr)), 0);
    }

    function testExecuteMultipleDeposits() public {
        uint256 amount1 = 1_000_000;
        uint256 amount2 = 2_000_000;
        uint256 total = amount1 + amount2;

        Snapr.Action[] memory actions = new Snapr.Action[](2);
        actions[0] = snapr.buildDepositAction(USDC, amount1);
        actions[1] = snapr.buildDepositAction(USDC, amount2);

        vm.startPrank(user);
        IERC20(USDC).approve(address(snapr), total);
        IERC20(USDC).transfer(address(snapr), total);
        snapr.execute(actions);
        vm.stopPrank();

        assertEq(IERC20(USDC).balanceOf(user), 10_000_000 - total);
        assertEq(IERC20(USDC).balanceOf(address(snapr)), 0);
    }

    /*//////////////////////////////////////////////////////////////
                        EXECUTE WITH PERMIT2 TESTS
    //////////////////////////////////////////////////////////////*/

    function testDepositWithPermit2() public {
        uint256 amount = 1_000_000;

        Snapr.Action[] memory actions = new Snapr.Action[](1);
        actions[0] = snapr.buildDepositAction(USDC, amount);

        IPermit2.PermitTransferFrom memory permit =
            IPermit2.PermitTransferFrom({
                permitted: IPermit2.TokenPermissions({
                    token: USDC,
                    amount: amount
                }),
                nonce: 0,
                deadline: block.timestamp + 1 hours
            });

        bytes memory sig = _signPermit(permit, userPk);

        vm.startPrank(user);
        snapr.executeWithPermit2(actions, permit, sig);
        vm.stopPrank();

        assertEq(IERC20(USDC).balanceOf(user), 10_000_000 - amount);
        assertEq(IERC20(USDC).balanceOf(address(snapr)), 0);
    }

    function testDepositWithPermit2RevertsWhenWrongSignature() public {
        uint256 amount = 1_000_000;

        Snapr.Action[] memory actions = new Snapr.Action[](1);
        actions[0] = snapr.buildDepositAction(USDC, amount);

        IPermit2.PermitTransferFrom memory permit =
            IPermit2.PermitTransferFrom({
                permitted: IPermit2.TokenPermissions({
                    token: USDC,
                    amount: amount
                }),
                nonce: 0,
                deadline: block.timestamp + 1 hours
            });

        bytes memory wrongSig = abi.encodePacked(bytes32(0), bytes32(0), uint8(27));

        vm.startPrank(user);
        vm.expectRevert();
        snapr.executeWithPermit2(actions, permit, wrongSig);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                        REVERT TESTS
    //////////////////////////////////////////////////////////////*/

    function testRevertWhenInvalidAction() public {
        // ActionType has AAVE_DEPOSIT=0, AAVE_BORROW=1. We pass actionType=2 via raw ABI
        // so we don't hit Solidity's enum conversion panic. Encode as (uint8, bytes)[] to match Action[].
        RawAction[] memory rawActions = new RawAction[](1);
        rawActions[0] = RawAction({ actionType: 2, data: "" });
        bytes memory calldataPayload =
            abi.encodePacked(Snapr.execute.selector, abi.encode(rawActions));

        vm.prank(user);
        vm.expectRevert(Snapr.InvalidAction.selector);
        (bool success,) = address(snapr).call(calldataPayload);
        assertFalse(success);
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

        // Permit2's signed struct includes "spender" (msg.sender when permitTransferFrom is called = Snapr).
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "PermitTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline)"
                    "TokenPermissions(address token,uint256 amount)"
                ),
                tokenPermissionsHash,
                address(snapr), // spender
                permit.nonce,
                permit.deadline
            )
        );

        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                domainSeparator,
                structHash
            )
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }
}
