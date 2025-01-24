// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Test } from "forge-std/Test.sol";
import { Deployers } from "@v4-core-test/utils/Deployers.sol";
import { PoolManager } from "@v4-core/PoolManager.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { UniswapV4Initializer, DopplerDeployer } from "src/UniswapV4Initializer.sol";
import { Airlock, ModuleState, CreateParams } from "src/Airlock.sol";
import { TokenFactory } from "src/TokenFactory.sol";
import { GovernanceFactory } from "src/GovernanceFactory.sol";
import { UniswapV2Migrator, IUniswapV2Factory, IUniswapV2Router02 } from "src/UniswapV2Migrator.sol";
import { ITokenFactory } from "src/interfaces/ITokenFactory.sol";
import {
    WETH_UNICHAIN_SEPOLIA,
    UNISWAP_V4_POOL_MANAGER_UNICHAIN_SEPOLIA,
    UNISWAP_V4_ROUTER_UNICHAIN_SEPOLIA,
    UNISWAP_V2_FACTORY_UNICHAIN_SEPOLIA,
    UNISWAP_V2_ROUTER_UNICHAIN_SEPOLIA
} from "test/shared/Addresses.sol";
import { mineV4, MineV4Params } from "test/shared/AirlockMiner.sol";

import { IERC20 } from "forge-std/interfaces/IERC20.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { PoolSwapTest } from "@v4-core/test/PoolSwapTest.sol";
import { Currency, CurrencyLibrary } from "@v4-core/types/Currency.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { Doppler, LOWER_SLUG_SALT } from "src/Doppler.sol";
import { MockERC20 } from "solmate/src/test/utils/mocks/MockERC20.sol";
import "forge-std/console2.sol";

uint256 constant DEFAULT_NUM_TOKENS_TO_SELL = 100_000e18;
uint256 constant DEFAULT_MINIMUM_PROCEEDS = 100e18;
uint256 constant DEFAULT_MAXIMUM_PROCEEDS = 10_000e18;
uint256 constant DEFAULT_STARTING_TIME = 0 days;
uint256 constant DEFAULT_ENDING_TIME = 2 days;
int24 constant DEFAULT_GAMMA = 800;
uint256 constant DEFAULT_EPOCH_LENGTH = 400 seconds;

// default to feeless case for now
uint24 constant DEFAULT_FEE = 0;
int24 constant DEFAULT_TICK_SPACING = 8;
uint256 constant DEFAULT_NUM_PD_SLUGS = 3;

int24 constant DEFAULT_START_TICK = 1600;
int24 constant DEFAULT_END_TICK = 171_200;

address constant TOKEN_A = address(0x8888);
address constant TOKEN_B = address(0x9999);

uint160 constant SQRT_RATIO_2_1 = 112_045_541_949_572_279_837_463_876_454;

struct DopplerConfig {
    uint256 numTokensToSell;
    uint256 minimumProceeds;
    uint256 maximumProceeds;
    uint256 startingTime;
    uint256 endingTime;
    int24 gamma;
    uint256 epochLength;
    uint24 fee;
    int24 tickSpacing;
    uint256 numPDSlugs;
}

contract LastSlugFeeTest is Test, Deployers {
    UniswapV4Initializer public initializer;
    DopplerDeployer public deployer;
    Airlock public airlock;
    TokenFactory public tokenFactory;
    GovernanceFactory public governanceFactory;
    UniswapV2Migrator public migrator;

    MockERC20 numeraireToken = MockERC20(address(0xaa)); // to be etched in setUp

    IUniswapV2Factory public uniswapV2Factory = IUniswapV2Factory(UNISWAP_V2_FACTORY_UNICHAIN_SEPOLIA);
    IUniswapV2Router02 public uniswapV2Router = IUniswapV2Router02(UNISWAP_V2_ROUTER_UNICHAIN_SEPOLIA);

    function setUp() public {
        vm.createSelectFork(vm.envString("UNICHAIN_SEPOLIA_RPC_URL"), 9_434_599);
        manager = new PoolManager(address(this));
        airlock = new Airlock(address(this));
        deployer = new DopplerDeployer(manager);
        initializer = new UniswapV4Initializer(address(airlock), manager, deployer);
        tokenFactory = new TokenFactory(address(airlock));
        governanceFactory = new GovernanceFactory(address(airlock));
        migrator = new UniswapV2Migrator(address(airlock), uniswapV2Factory, uniswapV2Router);

        address[] memory modules = new address[](4);
        modules[0] = address(tokenFactory);
        modules[1] = address(governanceFactory);
        modules[2] = address(initializer);
        modules[3] = address(migrator);

        ModuleState[] memory states = new ModuleState[](4);
        states[0] = ModuleState.TokenFactory;
        states[1] = ModuleState.GovernanceFactory;
        states[2] = ModuleState.PoolInitializer;
        states[3] = ModuleState.LiquidityMigrator;
        airlock.setModuleState(modules, states);

        // etch the numeraire token to a low address so its currency0
        MockERC20 _mock = new MockERC20("TEST", "TEST", 18);
        vm.etch(address(numeraireToken), address(_mock).code);
        numeraireToken.mint(address(this), 10_000e18);
    }

    function _existingTest() public returns (address, address) {
        DopplerConfig memory config = DopplerConfig({
            numTokensToSell: DEFAULT_NUM_TOKENS_TO_SELL,
            minimumProceeds: DEFAULT_MINIMUM_PROCEEDS,
            maximumProceeds: DEFAULT_MAXIMUM_PROCEEDS,
            startingTime: block.timestamp + DEFAULT_STARTING_TIME,
            endingTime: block.timestamp + DEFAULT_ENDING_TIME,
            gamma: DEFAULT_GAMMA,
            epochLength: DEFAULT_EPOCH_LENGTH,
            fee: DEFAULT_FEE,
            tickSpacing: DEFAULT_TICK_SPACING,
            numPDSlugs: DEFAULT_NUM_PD_SLUGS
        });

        address numeraire = address(numeraireToken);

        bytes memory tokenFactoryData =
            abi.encode("Best Token", "BEST", 1e18, 365 days, new address[](0), new uint256[](0));
        bytes memory governanceFactoryData = abi.encode("Best Token");

        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(DEFAULT_START_TICK);

        bytes memory poolInitializerData = abi.encode(
            sqrtPrice,
            config.minimumProceeds,
            config.maximumProceeds,
            config.startingTime,
            config.endingTime,
            DEFAULT_START_TICK,
            DEFAULT_END_TICK,
            config.epochLength,
            config.gamma,
            false, // isToken0 will always be false using native token
            config.numPDSlugs
        );

        (bytes32 salt, address hook, address token) = mineV4(
            MineV4Params(
                address(airlock),
                address(manager),
                config.numTokensToSell,
                config.numTokensToSell,
                numeraire,
                ITokenFactory(address(tokenFactory)),
                tokenFactoryData,
                initializer,
                poolInitializerData
            )
        );

        deal(address(this), 100_000_000 ether);

        (address asset, address pool,,,) = airlock.create(
            CreateParams(
                config.numTokensToSell,
                config.numTokensToSell,
                numeraire,
                tokenFactory,
                tokenFactoryData,
                governanceFactory,
                governanceFactoryData,
                initializer,
                poolInitializerData,
                migrator,
                "",
                address(this),
                salt
            )
        );

        assertEq(pool, hook, "Wrong pool");
        assertEq(asset, token, "Wrong asset");
        return (asset, hook);
    }

    function test_migrate_v4_native() public {
        (address asset, address hook) = _existingTest();
        Doppler doppler = Doppler(payable(hook));
        currency1 = Currency.wrap(asset);

        swapRouter = new PoolSwapTest(manager);
        numeraireToken.approve(address(swapRouter), type(uint256).max);
        IERC20(asset).approve(address(swapRouter), type(uint256).max);

        key = PoolKey({
            currency0: Currency.wrap(address(numeraireToken)),
            currency1: currency1,
            fee: 3000, // hard coded in V4Initializer
            tickSpacing: 8, // hard coded in V4Initializer
            hooks: IHooks(hook)
        });

        // swap to generate fees
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({ zeroForOne: true, amountSpecified: -0.1e18, sqrtPriceLimitX96: MIN_PRICE_LIMIT }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            ZERO_BYTES
        );

        swapRouter.swap(
            key,
            IPoolManager.SwapParams({ zeroForOne: false, amountSpecified: -0.01e18, sqrtPriceLimitX96: MAX_PRICE_LIMIT }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            ZERO_BYTES
        );

        swapRouter.swap(
            key,
            IPoolManager.SwapParams({ zeroForOne: true, amountSpecified: -0.1e18, sqrtPriceLimitX96: MIN_PRICE_LIMIT }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            ZERO_BYTES
        );

        // mock out an early exit to test migration
        _mockEarlyExit(doppler);

        uint256 airlockBalanceNumeraireBefore = numeraireToken.balanceOf(address(airlock));
        uint256 airlockBalanceAssetBefore = IERC20(asset).balanceOf(address(airlock));
        assertEq(airlockBalanceNumeraireBefore, 0, "numeraire balance before migrate");
        assertEq(airlockBalanceAssetBefore, 0, "asset balance before migrate");

        airlock.migrate(asset);

        uint256 airlockBalanceNumeraireAfter = numeraireToken.balanceOf(address(airlock));
        uint256 airlockBalanceAssetAfter = IERC20(asset).balanceOf(address(airlock));
        assertEq(airlockBalanceNumeraireAfter, 0, "numeraire balance after migrate");
        assertEq(airlockBalanceAssetAfter, 0, "asset balance after migrate");
    }

    function _mockEarlyExit(
        Doppler doppler
    ) internal {
        // storage slot of earlyExit variable
        // via `forge inspect Doppler storage`
        bytes32 EARLY_EXIT_SLOT = bytes32(uint256(0));

        vm.record();
        doppler.earlyExit();
        (bytes32[] memory reads,) = vm.accesses(address(doppler));
        assertEq(reads.length, 1, "wrong reads");
        assertEq(reads[0], EARLY_EXIT_SLOT, "wrong slot");

        // need to offset the boolean (0x01) by 1 byte since `insufficientProceeds`
        // and `earlyExit` share slot0
        vm.store(address(doppler), EARLY_EXIT_SLOT, bytes32(uint256(0x0100)));

        assertTrue(doppler.earlyExit(), "early exit should be true");
    }
}
