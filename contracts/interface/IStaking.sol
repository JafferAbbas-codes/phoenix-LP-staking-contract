pragma solidity ^0.7.0;

abstract contract IStaking {


    function stake(uint256 amount, bytes calldata data) virtual external;
    function stakeFor(address user, uint256 amount, bytes calldata data) virtual external;
    function unstake(uint256 amount, bytes calldata data) virtual external;
    function totalStaked() public view virtual returns (uint256);
    function token() external view virtual returns (address);

    /**
     * @return False. This application does not support staking history.
     */
    function supportsHistory() external pure returns (bool) {
        return false;
    }
}