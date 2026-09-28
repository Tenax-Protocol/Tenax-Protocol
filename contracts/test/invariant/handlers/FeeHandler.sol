// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VotingEscrow} from "../../../src/escrow/VotingEscrow.sol";
import {FeeDistributor} from "../../../src/revenue/FeeDistributor.sol";
import {TenaxToken} from "../../../src/token/TenaxToken.sol";
import {MockWETH} from "../../mocks/MockWETH.sol";
import {Test} from "forge-std/Test.sol";

/// @dev Drives holders' locks and the fee distributor through random valid sequences while revenue arrives,
/// tracking every WETH deposited and claimed.
contract FeeHandler is Test {
    FeeDistributor public immutable distributor;
    VotingEscrow public immutable escrow;
    TenaxToken public immutable tenax;
    MockWETH public immutable weth;
    address public immutable router;

    address[] public actors;

    uint256 public ghostDeposited;
    uint256 public ghostClaimed;
    mapping(string operation => uint256 count) public executed;

    constructor(FeeDistributor distributor_, MockWETH weth_, address router_, address[] memory actors_) {
        distributor = distributor_;
        escrow = distributor_.escrow();
        tenax = TenaxToken(address(escrow.token()));
        weth = weth_;
        router = router_;
        actors = actors_;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    // --- operations ----------------------------------------------------------------

    function lock(uint256 seed, uint256 amount, uint256 duration) external {
        address actor = actors[seed % actors.length];
        (uint256 locked,, uint256 end) = escrow.locked(actor);
        uint256 now_ = vm.getBlockTimestamp();
        if (locked != 0 && end <= now_) {
            vm.prank(actor);
            escrow.withdraw();
            _record("withdraw");
            locked = 0;
        }
        uint256 balance = tenax.balanceOf(actor);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);
        vm.startPrank(actor);
        if (locked == 0) {
            escrow.createLock(amount, now_ + bound(duration, 2 weeks, 104 weeks));
            _record("createLock");
        } else if (duration % 2 == 0 && end + 1 weeks <= now_ + 104 weeks) {
            escrow.increaseUnlockTime(bound(duration, end + 1 weeks, now_ + 104 weeks));
            _record("extend");
        } else {
            escrow.increaseAmount(amount);
            _record("increaseAmount");
        }
        vm.stopPrank();
    }

    function deposit(uint256 amount) external {
        amount = bound(amount, 1, 10 ether);
        vm.prank(router);
        distributor.depositEth(amount);
        ghostDeposited += amount;
        _record("deposit");
    }

    function claim(uint256 seed, bool asEth) external {
        address actor = actors[seed % actors.length];
        uint256 paid;
        if (asEth) {
            uint256 before = actor.balance;
            vm.prank(actor);
            paid = distributor.claimAsEth();
            assertEq(actor.balance - before, paid);
        } else {
            uint256 before = weth.balanceOf(actor);
            paid = distributor.claim(actor);
            assertEq(weth.balanceOf(actor) - before, paid);
        }
        ghostClaimed += paid;
        _record("claim");
    }

    function checkpoint() external {
        distributor.checkpoint();
        _record("checkpoint");
    }

    function warp(uint256 seconds_) external {
        vm.warp(vm.getBlockTimestamp() + bound(seconds_, 1 hours, 20 days));
        escrow.checkpoint();
        _record("warp");
    }

    function _record(string memory operation) internal {
        ++executed[operation];
    }
}
