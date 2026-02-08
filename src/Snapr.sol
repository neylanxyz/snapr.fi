// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

interface IAavePool {
    function deposit(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
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
    using CurrencyLibrary for Currency;

    error InvalidAction();
    error InsufficientSwapOutput();

    enum ActionType {
        AAVE_DEPOSIT,
        UNISWAP_SWAP
    }

    struct Action {
        ActionType actionType;
        bytes data;
    }

    IAavePool public immutable AAVE_POOL;
    IPermit2 public immutable PERMIT2;
    PoolSwapTest public immutable UNISWAP_SWAP_ROUTER;
    IPoolManager public immutable UNISWAP_POOL_MANAGER;

    constructor(
        address _AAVE_POOL, 
        address _PERMIT2,
        address _UNISWAP_POOL_MANAGER,
        address _UNISWAP_SWAP_ROUTER
    ) {
        AAVE_POOL = IAavePool(_AAVE_POOL);
        PERMIT2 = IPermit2(_PERMIT2);
        UNISWAP_POOL_MANAGER = IPoolManager(_UNISWAP_POOL_MANAGER);
        UNISWAP_SWAP_ROUTER = PoolSwapTest(_UNISWAP_SWAP_ROUTER);
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
        PERMIT2.permitTransferFrom(
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
        } else if (action.actionType == ActionType.UNISWAP_SWAP) {
            _handleUniswapSwap(action.data);
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

        IERC20(asset).forceApprove(address(AAVE_POOL), amount);

        AAVE_POOL.deposit(asset, amount, msg.sender, 0);
    }

    /*//////////////////////////////////////////////////////////////
                        UNISWAP V4 HANDLERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Executa um swap no Uniswap V4
     * @dev data = abi.encode(poolKey, zeroForOne, amountIn, minAmountOut)
     * @param data Dados encodados do swap:
     *   - poolKey: PoolKey identificando o pool V4
     *   - zeroForOne: true se swap currency0 -> currency1, false para o contrário
     *   - amountIn: Quantidade exata de tokens para swap
     *   - minAmountOut: Quantidade mínima aceitável de output (slippage protection)
     */
    function _handleUniswapSwap(bytes calldata data) internal {
        (PoolKey memory poolKey, bool zeroForOne, uint256 amountIn, uint256 minAmountOut) = 
            abi.decode(data, (PoolKey, bool, uint256, uint256));

        Currency inputCurrency = zeroForOne ? poolKey.currency0 : poolKey.currency1;
        Currency outputCurrency = zeroForOne ? poolKey.currency1 : poolKey.currency0;

        // Aprovar o swap router
        IERC20(Currency.unwrap(inputCurrency)).forceApprove(
            address(UNISWAP_SWAP_ROUTER),
            amountIn
        );

        // Executar o swap
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: int256(amountIn),
            sqrtPriceLimitX96: zeroForOne 
                ? 4295128740  // MIN_SQRT_PRICE + 1
                : 1461446703485210103287273052203988822378723970341  // MAX_SQRT_PRICE - 1
        });

        UNISWAP_SWAP_ROUTER.swap(
            poolKey, 
            params, 
            PoolSwapTest.TestSettings(false, false), 
            ""
        );

        // Verificar output recebido
        uint256 amountOut = outputCurrency.balanceOf(address(this));
        
        if (amountOut < minAmountOut) {
            revert InsufficientSwapOutput();
        }

        // Transferir tokens de output para o usuário
        IERC20(Currency.unwrap(outputCurrency)).safeTransfer(msg.sender, amountOut);
    }

    /*//////////////////////////////////////////////////////////////
                        ACTION BUILDERS
    //////////////////////////////////////////////////////////////*/

    function buildDepositAction(address asset, uint256 amount) external pure returns (Action memory) {
        return Action({actionType: ActionType.AAVE_DEPOSIT, data: abi.encode(asset, amount)});
    }

    /**
     * @notice Constrói uma ação de swap para Uniswap V4
     * @param poolKey PoolKey do pool V4 a ser usado
     * @param zeroForOne true para swap currency0 -> currency1, false para currency1 -> currency0
     * @param amountIn Quantidade exata de tokens para trocar
     * @param minAmountOut Quantidade mínima aceitável de output (proteção contra slippage)
     * @return Action estruturada para ser usada em execute()
     */
    function buildSwapAction(
        PoolKey calldata poolKey,
        bool zeroForOne,
        uint256 amountIn,
        uint256 minAmountOut
    ) external pure returns (Action memory) {
        return Action({
            actionType: ActionType.UNISWAP_SWAP,
            data: abi.encode(poolKey, zeroForOne, amountIn, minAmountOut)
        });
    }
}
