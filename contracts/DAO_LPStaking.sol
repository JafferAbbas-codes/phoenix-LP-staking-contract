
pragma solidity ^0.7.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";



contract TokenGeyser is Ownable {
    using SafeMath for uint256;

    event Staked(address indexed user, uint256 amount, uint256 total, uint256 initialTimestamp, uint256 campaignTimestamp);
    event Unstaked(address indexed user, uint256 amount, uint256 initialTimestamp, uint256 endingTimestamp, uint256 total);
    event CampaginAdded(uint256 startingTime , uint256 endingTime);
    event TokensClaimed(address indexed user, uint256 timestamp, uint256 rewardAmount);

    IERC20 _stakingPool;
    IERC20 _distributionPool;

    struct Stake {
        uint256 stakingAmount;
        uint256 phnxReserve;
        uint256 timestampSec;
        uint256 k;
        uint256 campaignEndTimeStamp;
    }

    struct Total{
        uint256 totalStakedAmount;
    }

    struct Campaigns{
        uint256 InitiationTimeStamp;
        uint256 EndingTimeStamp;
    }

    // Caches aggregated values from the User->Stake[] map to save computation.
    // If lastAccountingTimestampSec is 0, there's no entry for that user.


    // The collection of stakes for each user. Ordered by timestamp, earliest to latest.
    mapping(address => Stake[]) private _userStakes;
    mapping(address => Total) private _userTotal;
    Campaigns[] public campaignList;

    //
    // Locked/Unlocked Accounting state
    //
    /**
     * @param stakingToken The token users deposit as stake.
     * @param distributionToken The token users receive as they unstake.
     */
    constructor(IERC20 stakingToken, IERC20 distributionToken)  {
        require(stakingToken!=IERC20(address(0)) && distributionToken!=IERC20(address(0)));
        _stakingPool = stakingToken;
        _distributionPool = distributionToken;
    }

    /**
     * @return The token users deposit as stake.
     */
    function getStakingToken() public view returns (IERC20) {
        return _stakingPool;
    }

    /**
     * @return The token users receive as they unstake.
     */
    function getRewardToken() public view returns (IERC20) {
        return _distributionPool;
    }

    /**
     * @dev Transfers amount of deposit tokens from the user.
     * @param amount Number of deposit tokens to stake.
     */
    function stake(uint256 amount) external {
        _stakeFor(msg.sender, msg.sender, amount);
    }

    /**
     * @dev Transfers amount of deposit tokens from the caller on behalf of user.
     * @param user User address who gains credit for this stake operation.
     * @param amount Number of deposit tokens to stake.
     */
    function stakeFor(address user, uint256 amount) external onlyOwner {
        _stakeFor(msg.sender, user, amount);
    }

    /**
     * @dev Private implementation of staking methods.
     * @param staker User address who deposits tokens to stake.
     * @param beneficiary User address who gains credit for this stake operation.
     * @param amount Number of deposit tokens to stake.
     */
    function _stakeFor(address staker, address beneficiary, uint256 amount) private {
        require(amount > 0, "TokenGeyser: stake amount is zero");
        require(beneficiary != address(0), "TokenGeyser: beneficiary is zero address");
        require(campaignList.length > 0,"There are no campaigns");
        require(_stakingPool.balanceOf(staker) >= amount,"TokenGeyser: beneficiary does have enough tokens to stake");
        require(_stakingPool.allowance(staker,address(this)) >= amount,"TokenGeyser:Allowance not given to Contract");
        
        (,uint256 phnxReserve,) = getStakingToken().getReserves();
        uint256 phnxStaked = (amount * phnxReserve)/getStakingToken().totalSupply();
        
        uint256 k;
        uint256 campaignEnd = campaignList[campaignList.length-1].EndingTimeStamp;
        require(block.timestamp <= campaignEnd,"Staking can only be done during a campaign");
        
        if(phnxStaked >= 125000000000000000000000){
        k = 7;
        
        Stake memory newStake = Stake(amount,phnxStaked, block.timestamp , k,campaignEnd);
        _userStakes[beneficiary].push(newStake);
        }
        
        else{
        k = 15;
        Stake memory newStake = Stake(amount,phnxStaked, block.timestamp , k,campaignEnd);
        _userStakes[beneficiary].push(newStake);
        }

        _userTotal[beneficiary].totalStakedAmount = _userTotal[beneficiary].totalStakedAmount.add(amount);

        // 2. Global Accounting
        // Already set in updateAccounting()
        // _lastAccountingTimestampSec = block.timestamp;

        // interactions
        require(_stakingPool.transferFrom(staker, address(this), amount),
            "TokenGeyser: transfer into staking pool failed");

        emit Staked(beneficiary, amount, totalStakedFor(beneficiary), block.timestamp, campaignList[campaignList.length-1].InitiationTimeStamp);
        
    }

    /**
     * @dev Unstakes a certain amount of previously deposited tokens. User also receives their
     * alotted number of distribution tokens.
     * @param amount Number of deposit tokens to unstake / withdraw.
     */
    function unstake(uint256 amount )  external {
        _unstake(amount);
    }

    /**
     * @param amount Number of deposit tokens to unstake / withdraw.
     * @return The total number of distribution tokens that would be rewarded.
     */
    function unstakeQuery(uint256 amount) external returns (uint256) {
        return _unstake(amount);
    }

    /**
     * @dev Unstakes a certain amount of previously deposited tokens. User also receives their
     * alotted number of distribution tokens.
     * @param amount Number of deposit tokens to unstake / withdraw.
     * @return The total number of distribution tokens rewarded.
     */
    function _unstake(uint256 amount ) internal returns (uint256) {
        require(amount > 0, "TokenGeyser: unstake amount is zero");
        uint256 timeStamp;
        uint256 origAmount = amount;
        Total storage totals = _userTotal[msg.sender];
        require(amount <= totals.totalStakedAmount ,"Unstaking amount greater then amount staked");
        Stake[] storage accountStakes = _userStakes[msg.sender];
        
        // Redeem from most recent stake and go backwards in time.
        uint256 rewardAmount = 0;
        while (amount > 0) {
            Stake storage lastStake = accountStakes[accountStakes.length - 1];
            uint256 campaignEnd = campaignList[campaignList.length-1].EndingTimeStamp;

            if(block.timestamp > campaignEnd){
                timeStamp = campaignEnd;
            }
            else{
                timeStamp = block.timestamp;
            }
            uint256 stakeTimeSec = timeStamp.sub(lastStake.timestampSec);

            if (lastStake.stakingAmount <= amount) {
                // fully redeem a past stake
               rewardAmount = rewardAmount.add(computeNewReward(lastStake.stakingAmount,lastStake.phnxReserve,lastStake.k,lastStake.stakingAmount , stakeTimeSec));
                amount = amount.sub(lastStake.stakingAmount);
                accountStakes.pop();

                emit TokensClaimed(msg.sender, lastStake.timestampSec, rewardAmount);
                emit Unstaked(msg.sender, lastStake.stakingAmount, lastStake.timestampSec, block.timestamp, totalStakedFor(msg.sender));
            } else {
                // partially redeem a past stake
                rewardAmount = rewardAmount.add(computeNewReward(lastStake.stakingAmount,lastStake.phnxReserve,lastStake.k,amount,stakeTimeSec));
                lastStake.phnxReserve = lastStake.phnxReserve.sub(lastStake.phnxReserve.mul(amount).div(lastStake.stakingAmount));
                lastStake.stakingAmount = lastStake.stakingAmount.sub(amount);

                emit TokensClaimed(msg.sender, lastStake.timestampSec, rewardAmount);
                emit Unstaked(msg.sender, amount, lastStake.timestampSec, block.timestamp, totalStakedFor(msg.sender));
               
                amount = 0;
            }
        }
        totals.totalStakedAmount = totals.totalStakedAmount.sub(origAmount);
        
        require(totaldistributionToken() > rewardAmount,"Insufficient Reward");
        // interactions
        require(_stakingPool.transfer(msg.sender, origAmount),
            "TokenGeyser: transfer out of staking pool failed");
        require(_distributionPool.transfer(msg.sender, rewardAmount),
            "TokenGeyser: transfer out of unlocked pool failed");

        

        return rewardAmount;
    }

    /**
     * @dev Applies an additional time-bonus to a distribution amount. This is necessary to
     *      encourage long-term deposits instead of constant unstake/restakes.
     *      The bonus-multiplier is the result of a linear function that starts at startBonus and
     *      ends at 100% over bonusPeriodSec, then stays at 100% thereafter.
     * @param stakingAmount The staking amount present in the stake being processed.
     * @param phnxReserve The phnx reserve the staked liquidity contains.
     * @param k The value of k set for the staker.
     * @param amount Amount we are unstaking from the Stake.
     * @param stakeTimeSec Length of time for which the tokens were staked. Needed to calculate
     *                     the time-bonus.
     * @return Updated amount of distribution tokens to award.
     */
    function computeNewReward(uint256 stakingAmount,uint256 phnxReserve,uint256 k, uint256 amount, uint256 stakeTimeSec) 
    public pure returns (uint256) {
        
        uint256 phnxRatio = phnxReserve.mul(amount).div(stakingAmount);

        uint256 multiplier;

        if(stakeTimeSec < (uint256(86400).mul(30))){
            multiplier = 1;
        }
        else if(stakeTimeSec >= uint256(86400).mul(30) && stakeTimeSec<uint256(86400).mul(60)){
            multiplier = 2;
        }
        else{
            multiplier = 3;
        }
        
        uint256 newRewardTokens = phnxRatio.mul(k).div(100);
        newRewardTokens = newRewardTokens.div(uint256(86400*30)).mul(stakeTimeSec).mul(multiplier);

        return (newRewardTokens);
    }

    function addCampaign(uint256 durationInDays) external onlyOwner {
        if (campaignList.length > 0) {
            uint256 campaignEnd = campaignList[campaignList.length-1].EndingTimeStamp;
            require(campaignEnd < block.timestamp,"Cannot add campaign during a campaign");
        }

        uint256 endingTimeStamp = block.timestamp.add(86400).mul(durationInDays);
        Campaigns memory campaign = Campaigns(block.timestamp,endingTimeStamp); 
        campaignList.push(campaign);

        emit CampaginAdded(block.timestamp,endingTimeStamp);
    }

    function endCampaign() external onlyOwner{
        require(campaignList.length > 0,"There are not campaigns added");
        Campaigns storage currentCampaign = campaignList[campaignList.length-1];
        require(block.timestamp < currentCampaign.EndingTimeStamp,"No onging Campaign to End");
        currentCampaign.EndingTimeStamp = block.timestamp;

        emit CampaginAdded(currentCampaign.InitiationTimeStamp,block.timestamp);
    }


    function totalStaked() public view  returns (uint256) {
        return _stakingPool.balanceOf(address(this));
    }

    function totalStakedFor(address user) public view  returns (uint256) {
        return _userTotal[user].totalStakedAmount;
    }

    function totaldistributionToken() public view  returns (uint256) {
        return _distributionPool.balanceOf(address(this));
    }

    /**
     * @dev Note that this application has a staking token as well as a distribution token, which
     * may be different. This function is required by EIP-900.
     * @return The deposit token used for staking.
     */
    function token() external view  returns (address) {
        return address(getStakingToken());
    }

    function RescueRewardFunds() public onlyOwner{
        _distributionPool.transfer(msg.sender,totalStaked());
    }
}