// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IAavePool {
    function deposit(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;

    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf)
        external;
}

interface IPermit2 {
    struct TokenPermissions {
        address token;
        uint256 amount;
    }

    struct PermitTransferFrom {
        TokenPermissions permitted;
        uint256 nonce;
        uint256 deadline;
    }

    struct SignatureTransferDetails {
        address to;
        uint256 requestedAmount;
    }

    function permitTransferFrom(
        PermitTransferFrom calldata permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes calldata signature
    ) external;

    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

contract Snapr is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error InvalidAction();

    enum ActionType {
        AAVE_DEPOSIT,
        AAVE_BORROW
    }

    struct Action {
        ActionType actionType;
        bytes data;
    }

    IAavePool public immutable aavePool;
    IPermit2 public immutable permit2;

    constructor(address _aavePool, address _permit2) {
        aavePool = IAavePool(_aavePool);
        permit2 = IPermit2(_permit2);
    }

    /*//////////////////////////////////////////////////////////////
                            EXECUTION
    //////////////////////////////////////////////////////////////*/

    function execute(Action[] calldata actions) external nonReentrant {
        for (uint256 i = 0; i < actions.length; i++) {
            _execute(actions[i]);
        }
    }

    function executeWithPermit2(
        Action[] calldata actions,
        IPermit2.PermitTransferFrom calldata permit,
        bytes calldata signature
    ) external nonReentrant {
        // Pull tokens once
        permit2.permitTransferFrom(
            permit,
            IPermit2.SignatureTransferDetails({to: address(this), requestedAmount: permit.permitted.amount}),
            msg.sender,
            signature
        );

        for (uint256 i = 0; i < actions.length; i++) {
            _execute(actions[i]);
        }
    }

    function _execute(Action calldata action) internal {
        if (action.actionType == ActionType.AAVE_DEPOSIT) {
            _handleAaveDeposit(action.data);
        } else if (action.actionType == ActionType.AAVE_BORROW) {
            _handleAaveBorrow(action.data);
        } else {
            revert InvalidAction();
        }
    }

    /*//////////////////////////////////////////////////////////////
                        AAVE HANDLERS
    //////////////////////////////////////////////////////////////*/

    // data = abi.encode(asset, amount)
    function _handleAaveDeposit(bytes calldata data) internal {
        (address asset, uint256 amount) = abi.decode(data, (address, uint256));

        IERC20(asset).forceApprove(address(aavePool), amount);

        aavePool.deposit(asset, amount, msg.sender, 0);
    }

    // data = abi.encode(asset, amount, interestRateMode)
    function _handleAaveBorrow(bytes calldata data) internal {
        (address asset, uint256 amount, uint256 interestRateMode) = abi.decode(data, (address, uint256, uint256));

        aavePool.borrow(asset, amount, interestRateMode, 0, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                        ACTION BUILDERS
    //////////////////////////////////////////////////////////////*/

    function buildDepositAction(address asset, uint256 amount) external pure returns (Action memory) {
        return Action({actionType: ActionType.AAVE_DEPOSIT, data: abi.encode(asset, amount)});
    }

    function buildBorrowAction(address asset, uint256 amount, uint256 interestRateMode)
        external
        pure
        returns (Action memory)
    {
        return Action({actionType: ActionType.AAVE_BORROW, data: abi.encode(asset, amount, interestRateMode)});
    }
}
