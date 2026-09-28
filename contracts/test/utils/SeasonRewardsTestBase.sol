// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {EmissionSchedule} from "../../src/distribution/EmissionSchedule.sol";
import {SeasonRewards} from "../../src/distribution/SeasonRewards.sol";
import {IBurnableERC20, VotingEscrow} from "../../src/escrow/VotingEscrow.sol";
import {IWETH} from "../../src/interfaces/IWETH.sol";
import {TenaxToken} from "../../src/token/TenaxToken.sol";
import {MockL1Block} from "../mocks/MockL1Block.sol";
import {MockSeasonTreasury} from "../mocks/MockSeasonTreasury.sol";
import {MockWETH} from "../mocks/MockWETH.sol";
import {ForecastTestBase} from "./ForecastTestBase.sol";

/// @dev Forecasting setup plus the real token, vote escrow, emission schedule and season rewards, with helpers to
/// play whole seasons of BTC rounds.
abstract contract SeasonRewardsTestBase is ForecastTestBase {
    struct Player {
        address account;
        bool skilled; // forecasts the outcome exactly; otherwise forecasts the opposite
        uint256 from; // first round played
        uint256 to; // first round not played
    }

    uint256 internal constant L1_START = 21_000_000;
    uint256 internal constant EPOCH = 2_628_000;
    uint256 internal constant BUCKET = 35_000_000e18;

    TenaxToken internal tenax;
    VotingEscrow internal escrow;
    EmissionSchedule internal schedule;
    MockL1Block internal l1;
    MockWETH internal weth;
    MockSeasonTreasury internal seasonTreasury;
    SeasonRewards internal rewards;

    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");
    address internal depositor = makeAddr("depositor");

    function setUp() public virtual override {
        super.setUp();
        votes.setVotes(carol, 5000e18);
        votes.setVotes(dave, 5000e18);

        l1 = new MockL1Block().install(vm, uint64(L1_START));
        tenax = new TenaxToken(address(this));
        escrow = new VotingEscrow(IBurnableERC20(address(tenax)));
        schedule = new EmissionSchedule(L1_START);
        weth = new MockWETH();
        seasonTreasury = new MockSeasonTreasury();
        rewards = new SeasonRewards(tenax, IWETH(address(weth)), escrow, registry, schedule, seasonTreasury);

        address[] memory distributors = new address[](1);
        distributors[0] = address(rewards);
        escrow.initializeDistributors(distributors);
        tenax.transfer(address(rewards), BUCKET);

        vm.deal(depositor, 1000 ether);
        vm.startPrank(depositor);
        weth.deposit{value: 1000 ether}();
        weth.approve(address(rewards), type(uint256).max);
        vm.stopPrank();
    }

    // --- seasons -----------------------------------------------------------------

    function _outcome(uint256 round) internal pure returns (bool) {
        return round % 3 == 0;
    }

    function _forecast(bool skilled, uint256 round) internal pure returns (uint256) {
        return skilled == _outcome(round) ? 10_000 : 0;
    }

    function _plays(Player memory p, uint256 round) internal pure returns (bool) {
        return round >= p.from && round < p.to;
    }

    /// @dev Plays BTC rounds `first..last`, moving time forward only. Each round's commitments happen at its
    /// opening; the previous round is revealed at its resolve time, before the keeper resolves it, so the last
    /// reveal of each player stays pending in the registry until something settles it.
    function _play(Player[] memory players, uint256 first, uint256 last) internal {
        for (uint256 round = first; round <= last + 1; ++round) {
            if (round <= last) {
                vm.warp(_openTime(round));
                for (uint256 i; i < players.length; ++i) {
                    if (_plays(players[i], round)) {
                        _commit(players[i].account, BTC, round, _forecast(players[i].skilled, round));
                    }
                }
            }
            if (round > first) {
                uint256 previous = round - 1;
                vm.warp(_resolveTime(previous));
                for (uint256 i; i < players.length; ++i) {
                    if (_plays(players[i], previous)) {
                        _reveal(players[i].account, BTC, previous, _forecast(players[i].skilled, previous));
                    }
                }
                _resolveWith(BTC, previous, 100_000e8, _outcome(previous) ? int256(105_000e8) : int256(100_500e8));
            }
        }
    }

    /// @dev Moves to the opening of `season`'s registration and voids every ETH round still pending up to it.
    function _openRegistration(uint256 season) internal {
        vm.warp(rewards.registrationStart(season));
        _voidPending(ETH, rewards.lastRoundOf(season));
    }

    function _voidPending(uint256 asset, uint256 lastRound) internal {
        for (uint256 round = registry.assetState(asset).nextRoundToResolve; round <= lastRound; ++round) {
            registry.voidExpiredRound(asset, round);
        }
    }

    function _closeTime(uint256 season) internal view returns (uint256) {
        return rewards.registrationStart(season) + rewards.REGISTRATION_PERIOD();
    }

    function _register(address participant, uint256 season) internal {
        vm.prank(keeper);
        rewards.register(participant, season);
    }

    function _deposit(uint256 amount) internal {
        vm.prank(depositor);
        rewards.depositEth(amount);
    }

    function _players2(Player memory a, Player memory b) internal pure returns (Player[] memory players) {
        players = new Player[](2);
        players[0] = a;
        players[1] = b;
    }
}
