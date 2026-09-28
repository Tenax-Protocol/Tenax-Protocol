// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {EmissionSchedule} from "../../src/distribution/EmissionSchedule.sol";
import {MerkleAirdrop} from "../../src/distribution/MerkleAirdrop.sol";
import {IWETH, SeasonRewards} from "../../src/distribution/SeasonRewards.sol";
import {IBurnableERC20, VotingEscrow} from "../../src/escrow/VotingEscrow.sol";
import {ForecastRegistry} from "../../src/forecast/ForecastRegistry.sol";
import {TenaxToken} from "../../src/token/TenaxToken.sol";
import {MockL1Block} from "../mocks/MockL1Block.sol";
import {MockSeasonRegistry} from "../mocks/MockSeasonRegistry.sol";
import {MockWETH} from "../mocks/MockWETH.sol";
import {MerkleHelper} from "../utils/MerkleHelper.sol";
import {DistributionHandler} from "./handlers/DistributionHandler.sol";
import {Test, console} from "forge-std/Test.sol";

/// forge-config: default.invariant.depth = 200
/// forge-config: default.invariant.runs = 64
/// forge-config: ci.invariant.depth = 300
/// forge-config: ci.invariant.runs = 128
contract DistributionInvariantTest is Test {
    uint256 internal constant GENESIS = 1_799_971_200;
    uint256 internal constant L1_START = 21_000_000;
    uint256 internal constant EMISSION_BUCKET = 35_000_000e18;
    uint256 internal constant AIRDROP_BUCKET = 10_000_000e18;

    TenaxToken internal tenax;
    VotingEscrow internal escrow;
    EmissionSchedule internal schedule;
    MockWETH internal weth;
    MockSeasonRegistry internal registry;
    SeasonRewards internal rewards;
    MerkleAirdrop internal airdrop;
    DistributionHandler internal handler;

    function setUp() public {
        vm.warp(GENESIS);
        MockL1Block l1 = new MockL1Block().install(vm, uint64(L1_START));
        tenax = new TenaxToken(address(this));
        escrow = new VotingEscrow(IBurnableERC20(address(tenax)));
        schedule = new EmissionSchedule(L1_START);
        weth = new MockWETH();
        registry = new MockSeasonRegistry(GENESIS);
        registry.setNextRoundToResolve(type(uint256).max);
        rewards = new SeasonRewards(tenax, IWETH(address(weth)), escrow, ForecastRegistry(address(registry)), schedule);

        address[] memory actors = new address[](8);
        uint256[] memory amounts = new uint256[](8);
        bytes32[] memory leaves = new bytes32[](8);
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = makeAddr(string.concat("actor-", vm.toString(i)));
            amounts[i] = (i + 1) * 250_000e18;
            leaves[i] = MerkleHelper.leaf(actors[i], amounts[i]);
        }
        address launcher = makeAddr("launcher");
        airdrop = new MerkleAirdrop(IBurnableERC20(address(tenax)), escrow, MerkleHelper.root(leaves), launcher);

        address[] memory distributors = new address[](2);
        distributors[0] = address(rewards);
        distributors[1] = address(airdrop);
        escrow.initializeDistributors(distributors);
        tenax.transfer(address(rewards), EMISSION_BUCKET);
        tenax.transfer(address(airdrop), AIRDROP_BUCKET);
        vm.prank(launcher);
        airdrop.open();

        address depositor = makeAddr("depositor");
        vm.deal(depositor, 1_000_000 ether);
        vm.startPrank(depositor);
        weth.deposit{value: 1_000_000 ether}();
        weth.approve(address(rewards), type(uint256).max);
        vm.stopPrank();

        handler = new DistributionHandler(rewards, airdrop, registry, l1, weth, depositor, actors, amounts);
        targetContract(address(handler));
    }

    // --- emissions ---------------------------------------------------------------

    /// @dev Whitepaper invariant: cumulative emission never exceeds the schedule nor the 35M bucket.
    function invariant_emissionNeverExceedsTheSchedule() public view {
        assertLe(rewards.emissionsAssigned(), schedule.emitted());
        assertLe(schedule.emitted(), EMISSION_BUCKET);
        assertLe(handler.ghostRewardsDelivered(), rewards.emissionsAssigned());
    }

    /// @dev Every assigned emission is either in a closed season's budget or carried to the next one.
    function invariant_assignedEmissionIsConserved() public view {
        uint256 sum = rewards.tenaxCarry();
        for (uint256 s; s < rewards.nextSeasonToClose(); ++s) {
            sum += rewards.seasonInfo(s).tenaxBudget;
        }
        assertEq(sum, rewards.emissionsAssigned());
    }

    function invariant_revenueIsConserved() public view {
        uint256 sum = rewards.ethCarry();
        uint256 closed = rewards.nextSeasonToClose();
        for (uint256 s; s < closed; ++s) {
            sum += rewards.seasonInfo(s).ethBudget;
        }
        for (uint256 s = closed; s <= rewards.currentSeason(); ++s) {
            sum += rewards.ethReceived(s);
        }
        assertEq(sum, handler.ghostDeposited());
        assertEq(weth.balanceOf(address(rewards)), handler.ghostDeposited() - handler.ghostEthPaid());
    }

    /// @dev Whitepaper invariant: season distributions never pay more than their budget.
    function invariant_seasonsNeverPayMoreThanTheirBudget() public view {
        for (uint256 s; s < rewards.nextSeasonToClose(); ++s) {
            SeasonRewards.Season memory season = rewards.seasonInfo(s);
            assertLe(handler.ghostSeasonTenaxPaid(s), season.tenaxBudget);
            assertLe(handler.ghostSeasonEthPaid(s), season.ethBudget);
        }
        assertEq(tenax.balanceOf(address(rewards)), EMISSION_BUCKET - handler.ghostRewardsDelivered());
    }

    // --- airdrop -----------------------------------------------------------------

    /// @dev Whitepaper invariant: airdrop deliveries plus burned leftovers never exceed 10M.
    function invariant_airdropNeverExceedsItsBucket() public view {
        assertEq(
            tenax.balanceOf(address(airdrop)) + handler.ghostAirdropDelivered() + handler.ghostAirdropBurned(),
            AIRDROP_BUCKET
        );
        assertEq(tenax.totalSupply(), tenax.INITIAL_SUPPLY() - handler.ghostAirdropBurned());
    }

    // --- nothing is liquid -------------------------------------------------------

    /// @dev Whitepaper invariant: no emission or airdrop token is ever liquid. Every delivery is a granted lock
    /// of at least the required duration, and actors only hold TENAX they withdrew from expired locks.
    function invariant_nothingIsDeliveredLiquid() public view {
        assertFalse(handler.ghostShortLock());
        uint256 locked;
        uint256 withdrawn;
        for (uint256 i; i < handler.actorCount(); ++i) {
            address actor = handler.actors(i);
            (uint256 amount, uint256 granted,) = escrow.locked(actor);
            assertEq(granted, amount, "every locked token was delivered");
            assertEq(tenax.balanceOf(actor), handler.ghostWithdrawn(actor), "only expired locks are liquid");
            locked += amount;
            withdrawn += handler.ghostWithdrawn(actor);
        }
        assertEq(locked + withdrawn, handler.ghostRewardsDelivered() + handler.ghostAirdropDelivered());
        assertEq(escrow.supply(), locked);
    }

    function afterInvariant() external view {
        string[9] memory operations = [
            "depositEth",
            "score",
            "register",
            "closeSeason",
            "claim",
            "claimAirdrop",
            "burnUnclaimed",
            "withdraw",
            "warp"
        ];
        for (uint256 i; i < operations.length; ++i) {
            console.log(operations[i], handler.executed(operations[i]));
        }
        console.log("seasons closed", rewards.nextSeasonToClose());
    }
}
