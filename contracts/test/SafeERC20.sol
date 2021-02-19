pragma solidity ^0.6.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Test Token with Governance.
contract TEST is ERC20("Test Token", "TEST") {
    function mint(address _to, uint256 _amount) public {
        _mint(_to, _amount);
    }
}
