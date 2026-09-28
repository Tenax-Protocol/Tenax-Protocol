// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CreatorVesting} from "../src/distribution/CreatorVesting.sol";
import {EmissionSchedule, IL1Block} from "../src/distribution/EmissionSchedule.sol";
import {MerkleAirdrop} from "../src/distribution/MerkleAirdrop.sol";
import {SeasonRewards} from "../src/distribution/SeasonRewards.sol";
import {IBurnableERC20, VotingEscrow} from "../src/escrow/VotingEscrow.sol";
import {ForecastRegistry} from "../src/forecast/ForecastRegistry.sol";
import {IAggregatorV3, OracleAdapter} from "../src/forecast/OracleAdapter.sol";
import {TenaxGovernor} from "../src/governance/TenaxGovernor.sol";
import {TenaxTimelock} from "../src/governance/TenaxTimelock.sol";
import {LaunchFeeHook} from "../src/hooks/LaunchFeeHook.sol";
import {IWETH} from "../src/interfaces/IWETH.sol";
import {PoolLauncher} from "../src/launch/PoolLauncher.sol";
import {LiquidityVault} from "../src/liquidity/LiquidityVault.sol";
import {FeeDistributor} from "../src/revenue/FeeDistributor.sol";
import {IEthDepositor, RevenueRouter} from "../src/revenue/RevenueRouter.sol";
import {Treasury} from "../src/revenue/Treasury.sol";
import {TenaxToken} from "../src/token/TenaxToken.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Script, console} from "forge-std/Script.sol";

/// @title Deploy
/// @notice Deploys and launches the whole protocol (implementation plan, section 4): governance, token, escrow,
/// forecasting, distribution, revenue, the launch hook, and the pool with its single-sided position, in that order.
/// @dev Chain addresses and launch inputs come from the environment, with Base mainnet defaults for the external
/// contracts. `deploy` runs the same steps without broadcasting, for tests.
contract Deploy is Script {
    struct Config {
        address safe; // guardian of governance
        address creator; // beneficiary of the creator vesting
        IWETH weth;
        IPoolManager poolManager;
        IPositionManager positionManager;
        IAggregatorV3 btcFeed;
        IAggregatorV3 ethFeed;
        IAggregatorV3 sequencerFeed;
        uint64 staleness; // heartbeat plus 10%
        uint256 sequencerGrace;
        uint256 genesis; // opening time of round 0, a UTC midnight after the launch
        uint256[] initialThresholds; // X per asset, from the last year of prices
        uint256[] initialBaseRates; // b per asset, from the last year of prices
        bytes32 airdropRoot;
    }

    struct Deployment {
        TenaxToken token;
        TenaxTimelock timelock;
        TenaxGovernor governor;
        VotingEscrow escrow;
        OracleAdapter oracle;
        ForecastRegistry registry;
        EmissionSchedule schedule;
        Treasury treasury;
        SeasonRewards seasonRewards;
        FeeDistributor feeDistributor;
        RevenueRouter router;
        LiquidityVault vault;
        MerkleAirdrop airdrop;
        CreatorVesting creatorVesting;
        PoolLauncher launcher;
        LaunchFeeHook hook;
        PoolKey poolKey;
        uint256 positionId;
    }

    uint256 internal constant FORECASTER_EMISSIONS = 35_000_000e18;
    uint256 internal constant TREASURY_RESERVE = 20_000_000e18;
    uint256 internal constant INITIAL_LIQUIDITY = 20_000_000e18;
    uint256 internal constant CREATOR = 15_000_000e18;
    uint256 internal constant AIRDROP = 10_000_000e18;

    uint256 internal constant TIMELOCK_DELAY = 2 days;
    uint256 internal constant SUBMISSION_WINDOW = 30 minutes;
    uint256 internal constant REVEAL_WINDOW = 48 hours;

    /// @notice Launch price of 1e-6 ETH per TENAX (1e6 TENAX per ETH, tick 138,162) aligned down to the spacing.
    int24 internal constant LAUNCH_TICK = 138_120;
    int24 internal constant TICK_SPACING = 60;

    uint160 internal constant HOOK_FLAGS =
        uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);

    address internal constant L1_BLOCK = 0x4200000000000000000000000000000000000015;

    function run() external returns (Deployment memory d) {
        Config memory config = configFromEnv();
        vm.startBroadcast();
        d = deploy(config, msg.sender);
        vm.stopBroadcast();
        _log(d);
    }

    function configFromEnv() public view returns (Config memory c) {
        c.safe = vm.envAddress("SAFE");
        c.creator = vm.envAddress("CREATOR");
        c.weth = IWETH(vm.envOr("WETH", address(0x4200000000000000000000000000000000000006)));
        c.poolManager = IPoolManager(vm.envOr("POOL_MANAGER", address(0x498581fF718922c3f8e6A244956aF099B2652b2b)));
        c.positionManager =
            IPositionManager(vm.envOr("POSITION_MANAGER", address(0x7C5f5A4bBd8fD63184577525326123B519429bDc)));
        c.btcFeed = IAggregatorV3(vm.envOr("BTC_USD_FEED", address(0x32F587986D3fb47601157c19615d568BeD0BCabc)));
        c.ethFeed = IAggregatorV3(vm.envOr("ETH_USD_FEED", address(0xa4250cE1aA15Ff4cb5E5a8655293b65694e436Ed)));
        c.sequencerFeed = IAggregatorV3(vm.envOr("SEQUENCER_FEED", address(0xBCF85224fc0756B9Fa45aA7892530B47e10b6433)));
        c.staleness = uint64(vm.envOr("STALENESS", uint256(1320)));
        c.sequencerGrace = vm.envOr("SEQUENCER_GRACE", uint256(1 hours));
        c.genesis = vm.envUint("GENESIS");
        c.initialThresholds = vm.envUint("INITIAL_THRESHOLDS", ",");
        c.initialBaseRates = vm.envUint("INITIAL_BASE_RATES", ",");
        c.airdropRoot = vm.envBytes32("AIRDROP_ROOT");
    }

    /// @notice Every deployment step. `deployer` is the account that sends them and receives the supply.
    function deploy(Config memory c, address deployer) public returns (Deployment memory d) {
        // 1. Timelock, with the deployer as temporary admin.
        address[] memory none = new address[](0);
        address[] memory anyone = new address[](1);
        d.timelock = new TenaxTimelock(TIMELOCK_DELAY, none, anyone, deployer);

        // 2-3. Token and every protocol contract.
        d.token = new TenaxToken(deployer);
        IBurnableERC20 burnable = IBurnableERC20(address(d.token));
        d.escrow = new VotingEscrow(burnable);
        _deployForecasting(c, d);
        d.schedule = new EmissionSchedule(IL1Block(L1_BLOCK).number());
        d.treasury = new Treasury(burnable, c.weth, d.escrow, address(d.timelock));
        d.seasonRewards = new SeasonRewards(d.token, c.weth, d.escrow, d.registry, d.schedule, d.treasury);
        d.feeDistributor = new FeeDistributor(c.weth, d.escrow);
        d.router = new RevenueRouter(
            c.weth,
            IEthDepositor(address(d.seasonRewards)),
            IEthDepositor(address(d.feeDistributor)),
            address(d.treasury),
            address(d.timelock)
        );
        d.vault = new LiquidityVault(c.positionManager, burnable, c.weth, d.router);
        d.airdrop = new MerkleAirdrop(burnable, d.escrow, c.airdropRoot, deployer);
        d.creatorVesting = new CreatorVesting(c.creator, uint64(block.timestamp));
        d.governor = new TenaxGovernor(IVotes(address(d.escrow)), d.timelock, c.safe);

        // 4. Distributors and keeper tasks.
        address[] memory distributors = new address[](3);
        distributors[0] = address(d.seasonRewards);
        distributors[1] = address(d.airdrop);
        distributors[2] = address(d.treasury);
        d.escrow.initializeDistributors(distributors);
        d.treasury.initialize(d.seasonRewards, _keeperTasks(d));

        // 5. Allocations; the initial liquidity goes to the launcher.
        d.launcher = new PoolLauncher(c.poolManager, c.positionManager, d.token);
        d.token.transfer(address(d.seasonRewards), FORECASTER_EMISSIONS);
        d.token.transfer(address(d.treasury), TREASURY_RESERVE);
        d.token.transfer(address(d.launcher), INITIAL_LIQUIDITY);
        d.token.transfer(address(d.creatorVesting), CREATOR);
        d.token.transfer(address(d.airdrop), AIRDROP);

        // 6. Timelock roles: the governor proposes and cancels, the Safe cancels, anyone executes.
        d.timelock.grantRole(d.timelock.PROPOSER_ROLE(), address(d.governor));
        d.timelock.grantRole(d.timelock.CANCELLER_ROLE(), address(d.governor));
        d.timelock.grantRole(d.timelock.CANCELLER_ROLE(), c.safe);
        d.timelock.renounceRole(d.timelock.DEFAULT_ADMIN_ROLE(), deployer);

        // 7. The hook, at an address whose low bits grant exactly its permissions.
        d.hook = _deployHook(c.poolManager, address(d.launcher), address(d.token));

        // 8. Pool and position in one transaction, then the vault and the treasury learn about them.
        d.poolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(d.token)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(d.hook))
        });
        d.positionId = d.launcher.launch(d.poolKey, LAUNCH_TICK, address(d.vault));
        d.vault.initialize(d.positionId);
        d.treasury.initializeMarket(c.poolManager, d.poolKey, d.hook);

        // 9. Airdrop claims open only now that the official pool exists.
        d.airdrop.open();
    }

    function _deployForecasting(Config memory c, Deployment memory d) internal {
        IAggregatorV3[] memory feeds = new IAggregatorV3[](2);
        feeds[0] = c.btcFeed;
        feeds[1] = c.ethFeed;
        uint64[] memory tolerances = new uint64[](2);
        tolerances[0] = c.staleness;
        tolerances[1] = c.staleness;
        d.oracle = new OracleAdapter(feeds, tolerances, c.sequencerFeed, c.sequencerGrace);
        d.registry = new ForecastRegistry(
            IVotes(address(d.escrow)),
            d.oracle,
            address(d.timelock),
            c.genesis,
            SUBMISSION_WINDOW,
            REVEAL_WINDOW,
            c.initialThresholds,
            c.initialBaseRates
        );
    }

    /// @dev Paid keeper tasks: each can only succeed a bounded number of times, or at most once a day.
    function _keeperTasks(Deployment memory d) internal pure returns (Treasury.Task[] memory tasks) {
        tasks = new Treasury.Task[](8);
        tasks[0] = Treasury.Task(address(d.registry), ForecastRegistry.resolveRound.selector, 0);
        tasks[1] = Treasury.Task(address(d.registry), ForecastRegistry.voidExpiredRound.selector, 0);
        tasks[2] = Treasury.Task(address(d.registry), ForecastRegistry.finalizeRound.selector, 0);
        tasks[3] = Treasury.Task(address(d.seasonRewards), SeasonRewards.register.selector, 0);
        tasks[4] = Treasury.Task(address(d.seasonRewards), SeasonRewards.closeSeason.selector, 0);
        tasks[5] = Treasury.Task(address(d.vault), LiquidityVault.collectFees.selector, 1 days);
        tasks[6] = Treasury.Task(address(d.treasury), Treasury.buyback.selector, 1 days);
        tasks[7] = Treasury.Task(address(d.router), RevenueRouter.distribute.selector, 1 days);
    }

    /// @dev Mines a salt for the standard CREATE2 factory and deploys the hook through it.
    function _deployHook(IPoolManager poolManager, address launcher, address token)
        internal
        returns (LaunchFeeHook hook)
    {
        bytes memory initCode =
            abi.encodePacked(type(LaunchFeeHook).creationCode, abi.encode(poolManager, launcher, token));
        bytes32 initCodeHash = keccak256(initCode);
        bytes32 salt;
        address predicted;
        for (uint256 i; i < 1_000_000; ++i) {
            salt = bytes32(i);
            predicted = vm.computeCreate2Address(salt, initCodeHash, CREATE2_FACTORY);
            if (uint160(predicted) & Hooks.ALL_HOOK_MASK == HOOK_FLAGS && predicted.code.length == 0) break;
        }
        (bool ok, bytes memory deployed) = CREATE2_FACTORY.call(abi.encodePacked(salt, initCode));
        require(ok && address(bytes20(deployed)) == predicted, "hook deployment failed");
        hook = LaunchFeeHook(predicted);
    }

    function _log(Deployment memory d) internal pure {
        console.log("TenaxToken", address(d.token));
        console.log("VotingEscrow", address(d.escrow));
        console.log("OracleAdapter", address(d.oracle));
        console.log("ForecastRegistry", address(d.registry));
        console.log("EmissionSchedule", address(d.schedule));
        console.log("Treasury", address(d.treasury));
        console.log("SeasonRewards", address(d.seasonRewards));
        console.log("FeeDistributor", address(d.feeDistributor));
        console.log("RevenueRouter", address(d.router));
        console.log("LiquidityVault", address(d.vault));
        console.log("MerkleAirdrop", address(d.airdrop));
        console.log("CreatorVesting", address(d.creatorVesting));
        console.log("TenaxTimelock", address(d.timelock));
        console.log("TenaxGovernor", address(d.governor));
        console.log("PoolLauncher", address(d.launcher));
        console.log("LaunchFeeHook", address(d.hook));
        console.log("Position id", d.positionId);
    }
}
