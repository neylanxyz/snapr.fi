// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {Snapr} from "../src/Snapr.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract SnaprTest is Test {
    Snapr public snapr;
    
    // Sepolia addresses
    address constant AAVE_POOL = 0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    address constant POOL_SWAP_TEST = 0x9B6b46e2c869aa39918Db7f52f5557FE577B6eEe;
    
    address constant WBTC = address(0x835EF3b3D6fB94B98bf0A3F5390668e4B83731c5);
    address constant USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    
    address alice;
    address bob;
    
    function setUp() public {
        vm.createSelectFork(vm.envString("SEPOLIA_RPC_URL"));
        
        snapr = new Snapr(AAVE_POOL, PERMIT2, POOL_MANAGER, POOL_SWAP_TEST);
        alice = address(0x2ac3E10D60278b0782005Db71fA3599eee2b4A91);//makeAddr("alice");
        bob = address(0x8167E23F7e36432458F5fCD052071530a04dafb2);
        
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        
        
        //deal(address(USDC), alice, 1_000 ether);
    }

    function test_Deploy() public view {
        assertEq(address(snapr.AAVE_POOL()), AAVE_POOL);
        assertEq(address(snapr.PERMIT2()), PERMIT2);
        assertEq(address(snapr.UNISWAP_POOL_MANAGER()), POOL_MANAGER);
        assertEq(address(snapr.UNISWAP_SWAP_ROUTER()), POOL_SWAP_TEST);
        console.log("Snapr deployed successfully!");
    }

    function test_BuildSwapAction() public view {
        PoolKey memory poolKey = getPoolKey();
        
        Snapr.Action memory action = snapr.buildSwapAction(
            poolKey,
            true,
            1 ether,
            0.0001 ether
        );
        
        assertEq(uint8(action.actionType), uint8(Snapr.ActionType.UNISWAP_SWAP));
        console.log("Swap action built successfully!");
    }

    function test_BuildDepositAction() public view {
        Snapr.Action memory action = snapr.buildDepositAction(WBTC, 1 ether);
        
        assertEq(uint8(action.actionType), uint8(Snapr.ActionType.AAVE_DEPOSIT));
        console.log("Deposit action built successfully!");
    }

    /**
     * @notice Teste de swap real (requer que você tenha tokens)
     */
    function test_SwapUniForWeth() public {
        vm.startPrank(bob);

        // Verificar se alice tem UNI
        uint256 uniBalance = IERC20(WBTC).balanceOf(bob);
        console.log(uniBalance);
        if (uniBalance == 0) {
            console.log("Bob has no WBTC tokens, skipping swap test");
            vm.stopPrank();
            return;
        }
        
        console.log("Bob USDC balance:", uniBalance);
        
        uint256 amountIn = uniBalance / 10; // Use 10% do saldo
        if (amountIn == 0) amountIn = uniBalance;
        
        PoolKey memory poolKey = getPoolKey();
        
        // Criar ação de swap
        Snapr.Action[] memory actions = new Snapr.Action[](1);
        actions[0] = snapr.buildSwapAction(
            poolKey,
            true,              // UNI -> WETH
            amountIn,
            0                  // Aceitar qualquer output para teste
        );
        
        // Aprovar
        IERC20(USDC).approve(address(snapr), amountIn);

        // Saldos antes
        uint256 wbtcBefore = IERC20(WBTC).balanceOf(bob);
        uint256 usdcBefore = IERC20(USDC).balanceOf(bob);
        
        console.log("Before swap:");
        console.log("  USDC:", usdcBefore);
        console.log("  WBTC:", wbtcBefore);

        // Executar swap
        snapr.execute(actions);

        
        
        // Saldos depois
        uint256 wbtcAfter = IERC20(WBTC).balanceOf(bob);
        uint256 usdcAfter = IERC20(USDC).balanceOf(bob);
        
        console.log("After swap:");
        console.log("  UNI:", usdcAfter);
        console.log("  WETH:", wbtcAfter);
        
        console.log("Changes:");
        console.log("  UNI spent:", usdcBefore - usdcAfter);
        console.log("  WETH received:", wbtcAfter - wbtcBefore);
        
        // Verificações
        assertEq(usdcBefore - usdcAfter, amountIn, "Should spend exact UNI amount");
        assertGt(wbtcAfter, wbtcBefore, "Should receive WETH");
        
        console.log("Swap executed successfully!");
        
        vm.stopPrank();
    }

    /**
     * @notice Teste de múltiplas ações
     */
    function test_MultipleActions() public {
        vm.startPrank(alice);
        
        uint256 usdcBalance = IERC20(USDC).balanceOf(alice);
        console.log(usdcBalance);
        if (usdcBalance < 2 ether) {
            console.log("Insufficient USDC for multi-action test");
            vm.stopPrank();
            return;
        }
        
        PoolKey memory poolKey = getPoolKey();
        
        // Criar duas ações de swap
        Snapr.Action[] memory actions = new Snapr.Action[](2);
        
        actions[0] = snapr.buildSwapAction(poolKey, true, 1 ether, 0);
        actions[1] = snapr.buildSwapAction(poolKey, true, 1 ether, 0);
        
        IERC20(USDC).approve(address(snapr), 2 ether);
        
        uint256 wbtcBefore = IERC20(WBTC).balanceOf(alice);
        
        snapr.execute(actions);
        
        uint256 wbtcAfter = IERC20(WBTC).balanceOf(alice);
        
        assertGt(wbtcAfter, wbtcBefore, "Should receive WETH from both swaps");
        
        console.log("Multiple actions executed successfully!");
        
        vm.stopPrank();
    }

    /**
     * @notice Helper para criar PoolKey
     */
    function getPoolKey() internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(USDC),   // UNI (menor)
            currency1: Currency.wrap(WBTC),  // WETH (maior)
            fee: 100,                        // 0.01%
            tickSpacing: 1,
            hooks: IHooks(address(0))
        });
    }
}
