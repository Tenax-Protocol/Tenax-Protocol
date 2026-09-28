// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MerkleAirdrop} from "../../../src/distribution/MerkleAirdrop.sol";
import {SeasonRewards} from "../../../src/distribution/SeasonRewards.sol";
import {VotingEscrow} from "../../../src/escrow/VotingEscrow.sol";
import {TenaxToken} from "../../../src/token/TenaxToken.sol";
import {MockL1Block} from "../../mocks/MockL1Block.sol";
import {MockSeasonRegistry} from "../../mocks/MockSeasonRegistry.sol";
import {MockWETH} from "../../mocks/MockWETH.sol";
import {MerkleHelper} from "../../utils/MerkleHelper.sol";
import {Test} from "forge-std/Test.sol";

/// @dev Drives season rewards and the airdrop through random valid sequences over many seasons, sharing one
/// vote escrow, and tracks everything paid, delivered, burned and withdrawn. Actors never lock on their own, so
/// every TENAX they hold must have come out of an expired lock.
contract DistributionHandler is Test {
    uint256 internal constant GENESIS = 1_799_971_200;
    uint256 internal constant SEASON = 30 days;

    SeasonRewards public immutable rewards;
    MerkleAirdrop public immutable airdrop;
    VotingEscrow public immutable escrow;
    TenaxToken public immutable tenax;
    MockWETH public immutable weth;
    MockSeasonRegistry public immutable registry;
    MockL1Block public immutable l1;
    address public immutable depositor;

    address[] public actors;
    uint256[] public airdropAmounts;
    bytes32[] internal _leaves;

    uint256 public ghostDeposited;
    uint256 public ghostEthPaid;
    uint256 public ghostRewardsDelivered;
    uint256 public ghostAirdropDelivered;
    uint256 public ghostAirdropBurned;
    bool public ghostShortLock;
    mapping(uint256 season => uint256 amount) public ghostSeasonTenaxPaid;
    mapping(uint256 season => uint256 amount) public ghostSeasonEthPaid;
    mapping(address actor => uint256 amount) public ghostWithdrawn;
    mapping(string operation => uint256 count) public executed;

    constructor(
        SeasonRewards rewards_,
        MerkleAirdrop airdrop_,
        MockSeasonRegistry registry_,
        MockL1Block l1_,
        MockWETH weth_,
        address depositor_,
        address[] memory actors_,
        uint256[] memory airdropAmounts_
    ) {
        rewards = rewards_;
        airdrop = airdrop_;
        escrow = rewards_.escrow();
        tenax = TenaxToken(address(rewards_.token()));
        weth = weth_;
        registry = registry_;
        l1 = l1_;
        depositor = depositor_;
        actors = actors_;
        airdropAmounts = airdropAmounts_;
        for (uint256 i; i < actors_.length; ++i) {
            _leaves.push(MerkleHelper.leaf(actors_[i], airdropAmounts_[i]));
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    // --- operations ----------------------------------------------------------------

    function depositEth(uint256 amount) external {
        amount = bound(amount, 1, 10 ether);
        vm.prank(depositor);
        rewards.depositEth(amount);
        ghostDeposited += amount;
        _record("depositEth");
    }

    /// @dev Sets an actor's contribution for the running season, which the mock reports as final at registration.
    function score(uint256 seed, uint256 contribution) external {
        address actor = actors[seed % actors.length];
        registry.setContribution(actor, rewards.currentSeason(), uint128(bound(contribution, 0, 5e9)));
        _record("score");
    }

    /// @dev Registers every actor with a contribution for the season whose registration is open, fast-forwarding
    /// to the next registration period when none is.
    function register(uint256 seed) external {
        (uint256 season, bool open) = _registrationSeason();
        if (!open) {
            uint256 now_ = vm.getBlockTimestamp();
            season = now_ < rewards.registrationStart(0) ? 0 : season + 1;
            _advance(rewards.registrationStart(season) - now_);
        }
        seed %= actors.length;
        for (uint256 i; i < actors.length; ++i) {
            address actor = actors[(seed + i) % actors.length];
            if (registry.contributionOf(actor, season) == 0) continue;
            if (rewards.registrationOf(season, actor).contribution != 0) continue;
            rewards.register(actor, season);
            _record("register");
        }
    }

    function closeSeason() external {
        uint256 season = rewards.nextSeasonToClose();
        if (vm.getBlockTimestamp() < rewards.registrationStart(season) + rewards.REGISTRATION_PERIOD()) return;
        rewards.closeSeason(season);
        _record("closeSeason");
    }

    function claim(uint256 seed, uint256 seasonSeed, bool asEth) external {
        uint256 closed = rewards.nextSeasonToClose();
        if (closed == 0) return;
        seed %= actors.length;
        seasonSeed %= closed;
        for (uint256 j; j < closed; ++j) {
            uint256 season = (seasonSeed + j) % closed;
            for (uint256 i; i < actors.length; ++i) {
                address actor = actors[(seed + i) % actors.length];
                SeasonRewards.Registration memory r = rewards.registrationOf(season, actor);
                if (r.contribution == 0 || r.claimed) continue;
                _claimReward(actor, season, asEth);
                return;
            }
        }
    }

    function claimAirdrop(uint256 seed, uint256 choice) external {
        if (vm.getBlockTimestamp() >= airdrop.claimDeadline()) return;
        seed %= actors.length;
        for (uint256 i; i < actors.length; ++i) {
            uint256 index = (seed + i) % actors.length;
            address actor = actors[index];
            if (airdrop.claimed(actor)) continue;
            _withdrawIfExpired(actor);
            uint256 duration = choice % 3 == 0 ? 26 weeks : choice % 3 == 1 ? 52 weeks : 104 weeks;
            uint256 maxAmount = airdropAmounts[index];
            (uint256 before,,) = escrow.locked(actor);
            bytes32[] memory proof = MerkleHelper.proof(_leaves, index);
            vm.prank(actor);
            airdrop.claim(maxAmount, duration, proof);
            (uint256 amount,, uint256 end) = escrow.locked(actor);
            ghostAirdropDelivered += amount - before;
            ghostAirdropBurned += maxAmount - (amount - before);
            if (end < (vm.getBlockTimestamp() + duration) / 1 weeks * 1 weeks) ghostShortLock = true;
            _record("claimAirdrop");
            return;
        }
    }

    function burnUnclaimed() external {
        if (vm.getBlockTimestamp() < airdrop.claimDeadline()) return;
        ghostAirdropBurned += tenax.balanceOf(address(airdrop));
        airdrop.burnUnclaimed();
        _record("burnUnclaimed");
    }

    /// @dev Moves time forward, with L1 blocks following at 12 seconds each.
    function warp(uint256 seconds_) external {
        _advance(bound(seconds_, 1 hours, 20 days));
        _record("warp");
    }

    // --- helpers -------------------------------------------------------------------

    function _claimReward(address actor, uint256 season, bool asEth) internal {
        _withdrawIfExpired(actor);
        (uint256 tenaxAmount, uint256 ethAmount) = rewards.claimable(season, actor);
        uint256 ethBefore = asEth ? actor.balance : weth.balanceOf(actor);
        (uint256 before,,) = escrow.locked(actor);

        vm.prank(actor);
        if (asEth) rewards.claimAsEth(season);
        else rewards.claim(season);

        (uint256 amount,, uint256 end) = escrow.locked(actor);
        assertEq(amount - before, tenaxAmount, "reward locked");
        assertEq((asEth ? actor.balance : weth.balanceOf(actor)) - ethBefore, ethAmount, "eth paid");
        if (tenaxAmount != 0 && end < (vm.getBlockTimestamp() + 52 weeks) / 1 weeks * 1 weeks) ghostShortLock = true;
        ghostRewardsDelivered += tenaxAmount;
        ghostSeasonTenaxPaid[season] += tenaxAmount;
        ghostSeasonEthPaid[season] += ethAmount;
        ghostEthPaid += ethAmount;
        _record("claim");
    }

    /// @dev An expired lock blocks new deliveries; its owner withdraws it first, which is the only way TENAX
    /// becomes liquid.
    function _withdrawIfExpired(address actor) internal {
        (uint256 amount,, uint256 end) = escrow.locked(actor);
        if (amount == 0 || end > vm.getBlockTimestamp()) return;
        vm.prank(actor);
        escrow.withdraw();
        ghostWithdrawn[actor] += amount;
        _record("withdraw");
    }

    function _advance(uint256 seconds_) internal {
        vm.warp(vm.getBlockTimestamp() + seconds_);
        l1.setNumber(uint64(l1.number() + seconds_ / 12));
        escrow.checkpoint(); // keeps the escrow history within its per-call week limit over long runs
    }

    function _registrationSeason() internal view returns (uint256 season, bool open) {
        uint256 firstOpening = rewards.registrationStart(0);
        uint256 now_ = vm.getBlockTimestamp();
        if (now_ < firstOpening) return (0, false);
        season = (now_ - firstOpening) / SEASON;
        open = now_ < rewards.registrationStart(season) + rewards.REGISTRATION_PERIOD();
    }

    function _record(string memory operation) internal {
        ++executed[operation];
    }
}
