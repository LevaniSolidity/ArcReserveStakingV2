// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract ArcReserveStakingV2 is Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    IERC20 public immutable stakingToken;
    IERC20 public immutable rewardsToken;

    uint256 public rewardsDuration;
    uint256 public periodFinish;
    uint256 public rewardRate;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;

    mapping(address => bool) public approvedStakers;
    bool public stakeForOpen;

    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;

    error ZeroAddress();
    error ZeroAmount();
    error InvalidDuration();
    error RewardTooSmall();
    error RewardRateTooHigh();
    error InsufficientBalance();
    error RewardPeriodNotFinished();
    error CannotRecoverCoreToken();
    error SameTokenNotAllowed();
    error UnsupportedToken();
    error NotApprovedStaker();

    event Staked(address indexed user, uint256 amount);
    event StakedFor(address indexed staker, address indexed beneficiary, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event EmergencyWithdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardNotified(uint256 reward, uint256 rewardRate, uint256 periodFinish);
    event RewardsDurationUpdated(uint256 newDuration);
    event Recovered(address indexed token, uint256 amount);
    event ApprovedStakerSet(address indexed staker, bool approved);
    event StakeForOpenSet(bool open);

    constructor(
        address stakingToken_,
        address rewardsToken_,
        uint256 rewardsDuration_,
        address initialOwner_
    ) Ownable(initialOwner_) {
        if (stakingToken_ == address(0) || rewardsToken_ == address(0) || initialOwner_ == address(0)) revert ZeroAddress();
        if (stakingToken_ == rewardsToken_) revert SameTokenNotAllowed();
        if (rewardsDuration_ == 0) revert InvalidDuration();

        stakingToken = IERC20(stakingToken_);
        rewardsToken = IERC20(rewardsToken_);
        rewardsDuration = rewardsDuration_;
        lastUpdateTime = block.timestamp;
    }

    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();

        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    function rewardPerToken() public view returns (uint256) {
        if (_totalSupply == 0) return rewardPerTokenStored;
        return rewardPerTokenStored + ((lastTimeRewardApplicable() - lastUpdateTime) * rewardRate * 1e18) / _totalSupply;
    }

    function earned(address account) public view returns (uint256) {
        return ((_balances[account] * (rewardPerToken() - userRewardPerTokenPaid[account])) / 1e18) + rewards[account];
    }

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function rewardTokenBalance() external view returns (uint256) {
        return rewardsToken.balanceOf(address(this));
    }

    function stakingTokenBalance() external view returns (uint256) {
        return stakingToken.balanceOf(address(this));
    }

    function remainingRewardTime() external view returns (uint256) {
        if (block.timestamp >= periodFinish) return 0;
        return periodFinish - block.timestamp;
    }

    function rewardForDuration() external view returns (uint256) {
        return rewardRate * rewardsDuration;
    }

    function stake(uint256 amount) external nonReentrant whenNotPaused updateReward(msg.sender) {
        if (amount == 0) revert ZeroAmount();

        uint256 beforeBal = stakingToken.balanceOf(address(this));
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = stakingToken.balanceOf(address(this)) - beforeBal;
        if (received != amount) revert UnsupportedToken();

        _totalSupply += amount;
        _balances[msg.sender] += amount;

        emit Staked(msg.sender, amount);
    }

    function stakeFor(address beneficiary, uint256 amount) external nonReentrant whenNotPaused updateReward(beneficiary) {
        if (beneficiary == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (!stakeForOpen && !approvedStakers[msg.sender]) revert NotApprovedStaker();

        uint256 beforeBal = stakingToken.balanceOf(address(this));
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = stakingToken.balanceOf(address(this)) - beforeBal;
        if (received != amount) revert UnsupportedToken();

        _totalSupply += amount;
        _balances[beneficiary] += amount;

        emit StakedFor(msg.sender, beneficiary, amount);
        emit Staked(beneficiary, amount);
    }

    function withdraw(uint256 amount) external nonReentrant whenNotPaused updateReward(msg.sender) {
        _withdraw(msg.sender, amount);
    }

    function emergencyWithdraw() external nonReentrant {
        uint256 bal = _balances[msg.sender];
        if (bal == 0) revert ZeroAmount();

        _balances[msg.sender] = 0;
        _totalSupply -= bal;

        rewards[msg.sender] = 0;
        userRewardPerTokenPaid[msg.sender] = rewardPerTokenStored;

        stakingToken.safeTransfer(msg.sender, bal);

        emit EmergencyWithdrawn(msg.sender, bal);
    }

    function getReward() external nonReentrant updateReward(msg.sender) {
        _getReward(msg.sender);
    }

    function exit() external nonReentrant whenNotPaused updateReward(msg.sender) {
        uint256 bal = _balances[msg.sender];
        if (bal != 0) {
            _balances[msg.sender] = 0;
            _totalSupply -= bal;
            stakingToken.safeTransfer(msg.sender, bal);
            emit Withdrawn(msg.sender, bal);
        }

        uint256 reward = rewards[msg.sender];
        if (reward != 0) {
            rewards[msg.sender] = 0;
            rewardsToken.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    function notifyRewardAmount(uint256 reward) external onlyOwner nonReentrant updateReward(address(0)) {
        if (reward == 0) revert ZeroAmount();

        rewardsToken.safeTransferFrom(msg.sender, address(this), reward);

        if (block.timestamp >= periodFinish) {
            rewardRate = reward / rewardsDuration;
        } else {
            uint256 remaining = periodFinish - block.timestamp;
            uint256 leftover = remaining * rewardRate;
            rewardRate = (reward + leftover) / rewardsDuration;
        }

        if (rewardRate == 0) revert RewardTooSmall();

        uint256 balance = rewardsToken.balanceOf(address(this));
        if (rewardRate > balance / rewardsDuration) revert RewardRateTooHigh();

        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + rewardsDuration;

        emit RewardNotified(reward, rewardRate, periodFinish);
    }

    function setRewardsDuration(uint256 newDuration) external onlyOwner {
        if (newDuration == 0) revert InvalidDuration();
        if (block.timestamp < periodFinish) revert RewardPeriodNotFinished();

        rewardsDuration = newDuration;
        emit RewardsDurationUpdated(newDuration);
    }

    function setApprovedStaker(address staker, bool approved) external onlyOwner {
        if (staker == address(0)) revert ZeroAddress();
        approvedStakers[staker] = approved;
        emit ApprovedStakerSet(staker, approved);
    }

    function setStakeForOpen(bool open) external onlyOwner {
        stakeForOpen = open;
        emit StakeForOpenSet(open);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function recoverERC20(address token, uint256 amount) external onlyOwner nonReentrant {
        if (token == address(0)) revert ZeroAddress();
        if (token == address(stakingToken) || token == address(rewardsToken)) revert CannotRecoverCoreToken();
        IERC20(token).safeTransfer(owner(), amount);
        emit Recovered(token, amount);
    }

    function _withdraw(address account, uint256 amount) internal {
        if (amount == 0) revert ZeroAmount();

        uint256 bal = _balances[account];
        if (bal < amount) revert InsufficientBalance();

        _balances[account] = bal - amount;
        _totalSupply -= amount;

        stakingToken.safeTransfer(account, amount);

        emit Withdrawn(account, amount);
    }

    function _getReward(address account) internal {
        uint256 reward = rewards[account];
        if (reward != 0) {
            rewards[account] = 0;
            rewardsToken.safeTransfer(account, reward);
            emit RewardPaid(account, reward);
        }
    }
}
