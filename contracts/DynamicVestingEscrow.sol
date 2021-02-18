// SPDX-License-Identifier: MIT

pragma solidity ^0.6.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract DynamicVestingEscrow is Ownable {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /**
    Paused: Vesting is paused. Claim(s) is/are blocked. Recipient can be Unpaused by the owner.
    UnPaused: Vesting is unpaused. Claim(s) is/are unblocked. The vesting resumes from the time it was paused (in case the recipient was paused).
    Terminated: Recipient is terminated, meaning vesting is stopped and claims are blocked forever. No way to go back. 
    */
    enum Status {Paused, UnPaused, Terminated}

    struct Recipient {
        uint256 startTime; // timestamp at which vesting period will start (should be in future)
        uint256 endTime; // timestamp at which vesting period will end (should be in future)
        uint256 cliffTime; // time duration after startTime before which the recipient cannot call claim
        uint256 lastPausedAt; // latest timestamp at which vesting was paused
        uint256 vestingPerSec; // constant number of tokens that will be vested per second.
        uint256 totalVestingAmount; // total amount that can be vested over the vesting period.
        uint256 totalClaimed; // total amount of tokens that have been claimed by the recipient.
        Status recipientVestingStatus; // current vesting status
    }

    mapping(address => Recipient) public recipients; // mapping from recipient address to Recipient struct
    address public constant token = 0x6B175474E89094C44Da98b954EedeAC495271d0F; // vesting token address
    // WARNING: The contract assumes that the token address is NOT malicious.

    uint256 public unallocatedSupply; // supply that has not been allocated, but added via addRecipients. This does not account the tokens that may be directly transferred to this contract.
    uint256 public totalClaimed; // total number of tokens that have been claimed.
    uint256 public totalTokenAdded; // total token added to this contract (allocated+unallocated) via  addRecipients.  This does not account the tokens that may be directly transferred to this contract.
    address public SAFE_ADDRESS; // an address where all the funds are sent in case any recipient or vesting escrow is terminated.
    bool public ESCROW_TERMINATED = false; // global switch to terminate the vesting escrow. See more info in terminateVestingEscrow()

    modifier escrowNotTerminated() {
        // escrow should not be in terminated state
        require(!ESCROW_TERMINATED, "escrowNotTerminated: escrow terminated");
        _;
    }

    modifier isNonZeroAddress(address recipient) {
        // recipient should be a 0 address
        require(recipient != address(0), "isNonZeroAddress: 0 address");
        _;
    }

    modifier recipientIsUnpaused(address recipient) {
        // recipient should be a 0 address
        require(recipient != address(0), "recipientIsUnpaused: 0 address");
        // recipient should be in UnPaused status
        require(
            recipients[recipient].recipientVestingStatus == Status.UnPaused,
            "recipientIsUnpaused: escrow terminated"
        );
        _;
    }

    modifier recipientIsNotTerminated(address recipient) {
        // recipient should be a 0 address
        require(recipient != address(0), "recipientIsNotTerminated: 0 address");
        // recipient should NOT be in Terminated status
        require(
            recipients[recipient].recipientVestingStatus != Status.Terminated,
            "recipientIsUnpaused: escrow terminated"
        );
        _;
    }

    constructor(address safeAddress) public {
        // SAFE_ADDRESS should not be 0 address
        require(
            SAFE_ADDRESS != address(0),
            "constructor: invalid SAFE_ADDRESS"
        );
        SAFE_ADDRESS = safeAddress;
    }

    // DANGER: Terminates the vesting escrow forever
    // All the tokens will be transferred to the SAFE_ADDRESS
    function terminateVestingEscrow() external onlyOwner escrowNotTerminated {
        // transfer all token balance to SAFE_ADDRESS
        // This will also include the any token balance that was directly transferred to this contract
        uint256 _bal = IERC20(token).balanceOf(address(this));
        if (_bal > 0) {
            // transfer the token balance to the SAFE_ADDRESS
            IERC20(token).safeTransfer(SAFE_ADDRESS, _bal);
        }

        // set termination flag as true
        ESCROW_TERMINATED = true;
    }

    // Updates the SAFE_ADDRESS
    // WARNING: It is assumed that the SAFE_ADDRESS is not malicious
    function updateSafeAddress(address safeAddress)
        external
        onlyOwner
        escrowNotTerminated
    {
        // Check if the safeAddress is not a 0 address
        require(
            SAFE_ADDRESS != address(0),
            "constructor: invalid SAFE_ADDRESS"
        );
        SAFE_ADDRESS = safeAddress;
    }

    // Add and fund new recipients
    // You need to approve tokens to this contract
    function addRecipients(
        address[] memory _recipients,
        uint256[] memory _amounts,
        uint256[] memory _startTimes,
        uint256[] memory _endTimes,
        uint256[] memory _cliffTimes,
        uint256 _totalAmount
    ) external onlyOwner escrowNotTerminated {
        // Every input should be of equal length (greater than 0)
        require(
            (_recipients.length == _amounts.length) &&
                (_amounts.length == _startTimes.length) &&
                (_startTimes.length == _endTimes.length) &&
                (_endTimes.length == _cliffTimes.length) &&
                (_recipients.length != 0),
            "addRecipients: invalid params"
        );

        // _totalAmount should be greater than 0
        require(_totalAmount > 0, "addRecipients: all zero amounts");

        // transfer funds from the msg.sender
        // Will fail if the allowance is less than _totalAmount
        IERC20(token).safeTransferFrom(msg.sender, address(this), _totalAmount);

        // add total amount transferred to totalTokenAdded
        totalTokenAdded.add(_totalAmount);

        // populate recipients mapping
        for (uint256 i = 0; i < _amounts.length; i++) {
            // break on the first the 0 address
            if (_recipients[i] == address(0)) {
                break;
            }
            // startTime should be in future
            require(
                _startTimes[i] >= block.timestamp,
                "addRecipients: startTime in past"
            );
            // endTime should be in future and greater than startTime
            require(
                _endTimes[i] > _startTimes[i],
                "addRecipients: endTime before startTime"
            );
            // cliffTime should be less than vesting duration
            require(
                _cliffTimes[i] < _endTimes[i].sub(_startTimes[i]),
                "addRecipients: cliffTime too long"
            );
            // amount should be greater than 0
            require(_amounts[i] > 0, "addRecipients: 0 vesting amount");
            // add recipient to the recipients mapping
            recipients[_recipients[i]] = Recipient(
                _startTimes[i],
                _endTimes[i],
                _cliffTimes[i],
                0,
                // vestingPerSec = totalVestingAmount/(endTimes-(startTime+cliffTime))
                _amounts[i].div(
                    _endTimes[i].sub(_startTimes[i].add(_cliffTimes[i]))
                ),
                _amounts[i],
                0,
                Status.UnPaused
            );
            // reduce _totalAmount
            // Will revert if the _totalAmount is less than sum of _amounts
            _totalAmount.sub(_amounts[i]);
        }
        // if any tokens are remaining, add them to unallocated supply
        unallocatedSupply.add(_totalAmount);
    }

    // pause recipient vesting
    function pauseRecipient(address recipient)
        external
        onlyOwner
        escrowNotTerminated
        isNonZeroAddress(recipient)
    {
        // current recipient status should be UnPaused
        require(
            recipients[recipient].recipientVestingStatus == Status.UnPaused,
            "pauseRecipient: cannot pause"
        );
        // set vesting status of the recipient as "Paused"
        recipients[recipient].recipientVestingStatus = Status.Paused;
        // set lastPausedAt timestamp
        recipients[recipient].lastPausedAt = block.timestamp;
    }

    // unPause recipient vesting
    function unPauseRecipient(address recipient)
        external
        onlyOwner
        escrowNotTerminated
        isNonZeroAddress(recipient)
    {
        // current recipient status should be Paused
        require(
            recipients[recipient].recipientVestingStatus == Status.Paused,
            "unPauseRecipient: cannot pause"
        );
        // set vesting status of the recipient as "UnPaused"
        recipients[recipient].recipientVestingStatus = Status.UnPaused;
        // calculate the time for which the recipient was paused for
        uint256 pausedFor = block.timestamp.sub(
            recipients[recipient].lastPausedAt
        );
        // extend the cliffTime by the pause duration
        recipients[recipient].cliffTime.add(pausedFor);
        // extend the endTime by the pause duration
        recipients[recipient].endTime.add(pausedFor);
    }

    // terminate recipient vesting
    function terminateRecipient(address recipient)
        external
        onlyOwner
        escrowNotTerminated
        isNonZeroAddress(recipient)
    {
        // current recipient status should NOT be Terminated
        require(
            recipients[recipient].recipientVestingStatus != Status.Terminated,
            "unPauseRecipient: cannot terminate"
        );
        // set vesting status of the recipient as "Terminated"
        recipients[recipient].recipientVestingStatus = Status.Terminated;
        // transfer all the tokens (unclaimed+unvested)=(totalTokensAllocated-claimed) to the SAFE_ADDRESS
        uint256 _bal = recipients[recipient].totalVestingAmount.sub(
            recipients[recipient].totalClaimed
        );
        IERC20(token).safeTransfer(SAFE_ADDRESS, _bal);
    }

    // claim tokens
    function claim(uint256 amount)
        external
        escrowNotTerminated
        recipientIsUnpaused(msg.sender)
    {
        // get recipient
        Recipient storage recipient = recipients[msg.sender];

        // recipient should be able to claim
        require(canClaim(msg.sender), "claim: recipient cannot claim");

        // max amount the user can claim right now
        uint256 claimableAmount = claimableAmountFor(msg.sender);

        // amount parameter should be less or equal to than claimable amount
        require(amount <= claimableAmount, "claim: cannot claim passed amount");

        // transfer the amount to the msg.sender (recipient)
        IERC20(token).safeTransfer(msg.sender, amount);

        // increase user specific totalClaimed
        recipient.totalClaimed.add(amount);

        // user's totalClaimed should not be greater than user's totalVestingAmount
        require(
            recipient.totalClaimed <= recipient.totalVestingAmount,
            "claim: cannot claim more than you deserve"
        );

        // increase global totalClaimed
        totalClaimed.add(amount);

        // totalAllocated amount = totalTokenAdded - unallocatedSupply
        // totalClaimed should not be greater than total totalAllocated
        require(
            totalClaimed <= (totalTokenAdded.sub(unallocatedSupply)),
            "claim: cannot claim more than allocated to escrow"
        );
    }

    // get total vested tokens
    // function totalVested() public view escrowNotTerminated {}

    // get total vested tokens of a recipient
    function totalVestedOf(address recipient)
        public
        view
        escrowNotTerminated
        recipientIsNotTerminated(recipient)
        returns (uint256)
    {
        // get recipient
        Recipient memory _recipient = recipients[recipient];

        // totalVested = totalClaimed + claimableAmountFor
        return _recipient.totalClaimed.add(claimableAmountFor(recipient));
    }

    function canClaim(address recipient)
        public
        view
        escrowNotTerminated
        isNonZeroAddress(recipient)
        returns (bool)
    {
        Recipient memory _recipients = recipients[recipient];

        // recipient status should be UnPaused
        if (_recipients.recipientVestingStatus != Status.UnPaused) {
            return false;
        }

        // recipient should have completed the cliffTime
        if (
            block.timestamp < (_recipients.startTime.add(_recipients.cliffTime))
        ) {
            return false;
        }
    }

    function claimStartTimeFor(address recipient)
        public
        view
        escrowNotTerminated
        recipientIsUnpaused(recipient)
        returns (uint256)
    {
        return
            recipients[recipient].startTime.add(
                recipients[recipient].cliffTime
            );
    }

    // tokens that can be claimed right now by a recipient
    function claimableAmountFor(address recipient)
        public
        view
        escrowNotTerminated
        recipientIsUnpaused(recipient)
        returns (uint256)
    {
        // get recipient
        Recipient memory _recipient = recipients[recipient];

        // claimable = totalVestingAmount - (totalClaimed + locked)
        return
            _recipient.totalVestingAmount.sub(
                _recipient.totalClaimed.add(totalLockedOf(recipient))
            );
    }

    // get total locked tokens
    // function totalLocked() public view escrowNotTerminated {}

    // get total locked tokens of a recipient
    function totalLockedOf(address recipient)
        public
        view
        escrowNotTerminated
        recipientIsNotTerminated(recipient)
        returns (uint256)
    {
        // get recipient
        Recipient memory _recipient = recipients[recipient];

        // We know that vestingPerSec is constant for a recipient for entirety of their vesting period
        // locked = vestingPerSec*(endTime-block.timestamp)
        return
            _recipient.vestingPerSec.mul(
                _recipient.endTime.sub(block.timestamp)
            );
    }

    // Allows owner to rescue the ERC20 assets (other than token) in case of any emergency
    // WARNING: It is assumed that the asset address is NOT a malicious address
    function inCaseAssetGetStuck(address asset, address to) external onlyOwner {
        // asset address should not be a 0 address
        require(asset != address(0), "inCaseAssetGetStuck: 0 address");
        // asset address should not be the token address
        require(asset != token, "inCaseAssetGetStuck: cannot withdraw token");
        // to address should not a 0 address
        require(to != address(0), "inCaseAssetGetStuck: 0 address");
        // transfer all the balance of the asset this contract hold to the "to" address
        uint256 _bal = IERC20(asset).balanceOf(asset);
        IERC20(asset).safeTransfer(SAFE_ADDRESS, _bal);
    }
}
