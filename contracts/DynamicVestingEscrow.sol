// SPDX-License-Identifier: MIT

pragma solidity ^0.6.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/Math.sol";
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
        uint256 cliffDuration; // time duration after startTime before which the recipient cannot call claim
        uint256 lastPausedAt; // latest timestamp at which vesting was paused
        uint256 vestingPerSec; // constant number of tokens that will be vested per second.
        uint256 totalVestingAmount; // total amount that can be vested over the vesting period.
        uint256 totalClaimed; // total amount of tokens that have been claimed by the recipient.
        Status recipientVestingStatus; // current vesting status
    }

    mapping(address => Recipient) public recipients; // mapping from recipient address to Recipient struct
    mapping(address => bool) public lockedTokensSeizedFor; // in case of escrow termination, a mapping to keep track of which
    address public constant token = 0x6B175474E89094C44Da98b954EedeAC495271d0F; // vesting token address
    // WARNING: The contract assumes that the token address is NOT malicious.

    uint256 public dust; // total amount of token that is sitting as dust in this contract (unallocatedSupply)
    uint256 public totalClaimed; // total number of tokens that have been claimed.
    uint256 public totalAllocatedSupply; // total token allocated to the recipients via addRecipients.
    uint256 public ESCROW_TERMINATED_AT; // timestamp at which escow terminated.
    address public SAFE_ADDRESS; // an address where all the funds are sent in case any recipient or vesting escrow is terminated.
    bool public ALLOW_PAST_START_TIME = false; // a flag that allows decides if past startTime is allowed for any recipient.
    bool public ESCROW_TERMINATED = false; // global switch to terminate the vesting escrow. See more info in terminateVestingEscrow()

    modifier escrowNotTerminated() {
        // escrow should NOT be in terminated state
        require(!ESCROW_TERMINATED, "escrowNotTerminated: escrow terminated");
        _;
    }

    modifier isNonZeroAddress(address recipient) {
        // recipient should NOT be a 0 address
        require(recipient != address(0), "isNonZeroAddress: 0 address");
        _;
    }

    modifier recipientIsUnpaused(address recipient) {
        // recipient should NOT be a 0 address
        require(recipient != address(0), "recipientIsUnpaused: 0 address");
        // recipient should be in UnPaused status
        require(
            recipients[recipient].recipientVestingStatus == Status.UnPaused,
            "recipientIsUnpaused: escrow terminated"
        );
        _;
    }

    modifier recipientIsNotTerminated(address recipient) {
        // recipient should NOT be a 0 address
        require(recipient != address(0), "recipientIsNotTerminated: 0 address");
        // recipient should NOT be in Terminated status
        require(
            recipients[recipient].recipientVestingStatus != Status.Terminated,
            "recipientIsNotTerminated: recipient terminated"
        );
        _;
    }

    constructor(address safeAddress) public {
        // SAFE_ADDRESS should NOT be 0 address
        require(
            SAFE_ADDRESS != address(0),
            "constructor: invalid SAFE_ADDRESS"
        );
        SAFE_ADDRESS = safeAddress;
    }

    // DANGER: Terminates the vesting escrow forever
    // All the vesting states will be freezed, recipients can still claim their vested tokens
    function terminateVestingEscrow() external onlyOwner escrowNotTerminated {
        // set termination variables
        ESCROW_TERMINATED = true;
        ESCROW_TERMINATED_AT = block.timestamp;
    }

    // Updates the SAFE_ADDRESS
    // WARNING: It is assumed that the SAFE_ADDRESS is NOT malicious
    function updateSafeAddress(address safeAddress)
        external
        onlyOwner
        escrowNotTerminated
    {
        // Check if the safeAddress is NOT a 0 address
        require(
            SAFE_ADDRESS != address(0),
            "updateSafeAddress: invalid SAFE_ADDRESS"
        );
        SAFE_ADDRESS = safeAddress;
    }

    // Add and fund new recipients
    // NOTE: Owner needs to approve tokens to this contract
    function addRecipients(
        address[] calldata _recipients,
        uint256[] calldata _amounts,
        uint256[] calldata _startTimes,
        uint256[] calldata _endTimes,
        uint256[] calldata _cliffDurations,
        uint256 _totalAmount
    ) external onlyOwner escrowNotTerminated {
        // Every input should be of equal length (greater than 0)
        require(
            (_recipients.length == _amounts.length) &&
                (_amounts.length == _startTimes.length) &&
                (_startTimes.length == _endTimes.length) &&
                (_endTimes.length == _cliffDurations.length) &&
                (_recipients.length != 0),
            "addRecipients: invalid params"
        );

        // _totalAmount should be greater than 0
        require(
            _totalAmount > 0,
            "addRecipients: zero totalAmount not allowed"
        );

        // transfer funds from the msg.sender
        // Will fail if the allowance is less than _totalAmount
        IERC20(token).safeTransferFrom(msg.sender, address(this), _totalAmount);

        // register _totalAmount before allocation
        uint256 _before = _totalAmount;

        // populate recipients mapping
        for (uint256 i = 0; i < _amounts.length; i++) {
            // recipient should NOT be a 0 address
            require(_recipients[i] != address(0), "addRecipients: 0 address");
            // if past startTime is NOT allowed, then the startTime should be in future
            require(
                ALLOW_PAST_START_TIME || (_startTimes[i] >= block.timestamp),
                "addRecipients: invalid startTime"
            );
            // endTime should be greater than startTime
            require(
                _endTimes[i] > _startTimes[i],
                "addRecipients: endTime before startTime"
            );
            // cliffDuration should be less than vesting duration
            require(
                _cliffDurations[i] < _endTimes[i].sub(_startTimes[i]),
                "addRecipients: cliffDuration too long"
            );
            // amount should be greater than 0
            require(_amounts[i] > 0, "addRecipients: 0 vesting amount");
            // add recipient to the recipients mapping
            recipients[_recipients[i]] = Recipient(
                _startTimes[i],
                _endTimes[i],
                _cliffDurations[i],
                0,
                // vestingPerSec = totalVestingAmount/(endTimes-(startTime+cliffDuration))
                _amounts[i].div(
                    _endTimes[i].sub(_startTimes[i].add(_cliffDurations[i]))
                ),
                _amounts[i],
                0,
                Status.UnPaused
            );
            // reduce _totalAmount
            // Will revert if the _totalAmount is less than sum of _amounts
            _totalAmount.sub(_amounts[i]);
        }
        // add the allocated token amount to totalAllocatedSupply
        totalAllocatedSupply.add(_before.sub(_totalAmount));
        // register remaining _totalAmount as dust
        dust.add(_totalAmount);
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
        // set vesting status of the recipient as Paused
        recipients[recipient].recipientVestingStatus = Status.Paused;
        // set lastPausedAt timestamp
        recipients[recipient].lastPausedAt = block.timestamp;
    }

    // unPause recipient vesting
    function unPauseRecipient(address recipient)
        external
        onlyOwner
        isNonZeroAddress(recipient)
    {
        // current recipient status should be Paused
        require(
            recipients[recipient].recipientVestingStatus == Status.Paused,
            "unPauseRecipient: cannot unpause"
        );
        // set vesting status of the recipient as "UnPaused"
        recipients[recipient].recipientVestingStatus = Status.UnPaused;
        // calculate the time for which the recipient was paused for
        uint256 pausedFor = block.timestamp.sub(
            recipients[recipient].lastPausedAt
        );
        // extend the cliffDuration by the pause duration
        recipients[recipient].cliffDuration.add(pausedFor);
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
        // transfer unclaimed tokens to the recipient
        _claimFor(claimableAmountFor(recipient), recipient);
        // transfer locked tokens to the SAFE_ADDRESS
        uint256 _bal = recipients[recipient].totalVestingAmount.sub(
            recipients[recipient].totalClaimed
        );
        IERC20(token).safeTransfer(SAFE_ADDRESS, _bal);
    }

    // claim tokens
    function claim(uint256 amount) external recipientIsUnpaused(msg.sender) {
        _claimFor(amount, msg.sender);
    }

    // claim tokens
    function _claimFor(uint256 _amount, address _recipient) internal {
        // get recipient
        Recipient storage recipient = recipients[_recipient];

        // recipient should be able to claim
        require(canClaim(_recipient), "claim: recipient cannot claim");

        // max amount the user can claim right now
        uint256 claimableAmount = claimableAmountFor(_recipient);

        // amount parameter should be less or equal to than claimable amount
        require(
            _amount <= claimableAmount,
            "claim: cannot claim passed amount"
        );

        // increase user specific totalClaimed
        recipient.totalClaimed.add(_amount);

        // user's totalClaimed should NOT be greater than user's totalVestingAmount
        require(
            recipient.totalClaimed <= recipient.totalVestingAmount,
            "claim: cannot claim more than you deserve"
        );

        // increase global totalClaimed
        totalClaimed.add(_amount);

        // totalClaimed should NOT be greater than total totalAllocatedSupply
        require(
            totalClaimed <= totalAllocatedSupply,
            "claim: cannot claim more than allocated to escrow"
        );

        // transfer the amount to the _recipient
        IERC20(token).safeTransfer(_recipient, _amount);
    }

    // get total vested tokens
    // only pass array of non-terminated recipient
    function batchTotalVestedOf(address[] calldata _recipients)
        public
        view
        returns (uint256 totalAmount)
    {
        for (uint256 i = 0; i < _recipients.length; i++) {
            totalAmount.add(totalVestedOf(_recipients[i]));
        }
    }

    // get total vested tokens of a recipient
    function totalVestedOf(address recipient)
        public
        view
        recipientIsNotTerminated(recipient)
        returns (uint256)
    {
        // get recipient
        Recipient memory _recipient = recipients[recipient];

        // totalVested = totalClaimed + claimableAmountFor
        return _recipient.totalClaimed.add(claimableAmountFor(recipient));
    }

    // Can a recipient claim right now
    function canClaim(address recipient)
        public
        view
        isNonZeroAddress(recipient)
        returns (bool)
    {
        Recipient memory _recipients = recipients[recipient];

        // recipient status should be UnPaused
        if (_recipients.recipientVestingStatus != Status.UnPaused) {
            return false;
        }

        // recipient should have completed the cliffDuration
        if (
            block.timestamp <
            (_recipients.startTime.add(_recipients.cliffDuration))
        ) {
            return false;
        }

        return true;
    }

    // Time at which the recipient can start claiming tokens
    function claimStartTimeFor(address recipient)
        public
        view
        escrowNotTerminated
        recipientIsUnpaused(recipient)
        returns (uint256)
    {
        return
            recipients[recipient].startTime.add(
                recipients[recipient].cliffDuration
            );
    }

    // Tokens that can be claimed right now by a recipient
    function claimableAmountFor(address recipient)
        public
        view
        recipientIsNotTerminated(recipient)
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
    // only pass array of non-terminated recipient
    function batchTotalLockedOf(address[] calldata _recipients)
        public
        view
        returns (uint256 totalAmount)
    {
        for (uint256 i = 0; i < _recipients.length; i++) {
            totalAmount.add(totalLockedOf(_recipients[i]));
        }
    }

    // get total locked tokens of a recipient
    function totalLockedOf(address recipient)
        public
        view
        recipientIsNotTerminated(recipient)
        returns (uint256)
    {
        // get recipient
        Recipient memory _recipient = recipients[recipient];

        // We know that vestingPerSec is constant for a recipient for entirety of their vesting period
        // locked = vestingPerSec*(endTime-max(lastPausedAt, startTime+cliffDuration))
        if (_recipient.recipientVestingStatus == Status.Paused) {
            if (_recipient.lastPausedAt >= _recipient.endTime) {
                return 0;
            }
            return
                _recipient.vestingPerSec.mul(
                    _recipient.endTime.sub(
                        Math.max(
                            _recipient.lastPausedAt,
                            _recipient.startTime.add(_recipient.cliffDuration)
                        )
                    )
                );
        }

        // Nothing is locked if the recipient passed the endTime
        if (block.timestamp >= _recipient.endTime) {
            return 0;
        }

        // in case escrow is terminated, locked amount stays the constant
        if (ESCROW_TERMINATED) {
            return
                _recipient.vestingPerSec.mul(
                    _recipient.endTime.sub(
                        Math.max(
                            ESCROW_TERMINATED_AT,
                            _recipient.startTime.add(_recipient.cliffDuration)
                        )
                    )
                );
        }

        // We know that vestingPerSec is constant for a recipient for entirety of their vesting period
        // locked = vestingPerSec*(endTime-max(block.timestamp, startTime+cliffDuration))
        if (_recipient.recipientVestingStatus == Status.UnPaused) {
            return
                _recipient.vestingPerSec.mul(
                    _recipient.endTime.sub(
                        Math.max(
                            block.timestamp,
                            _recipient.startTime.add(_recipient.cliffDuration)
                        )
                    )
                );
        }
    }

    // Allows owner to rescue the ERC20 assets (other than token) in case of any emergency
    // WARNING: It is assumed that the asset address is NOT a malicious address
    function inCaseAssetGetStuck(address asset, address to) external onlyOwner {
        // asset address should NOT be a 0 address
        require(asset != address(0), "inCaseAssetGetStuck: 0 address");
        // asset address should NOT be the token address
        require(asset != token, "inCaseAssetGetStuck: cannot withdraw token");
        // to address should NOT a 0 address
        require(to != address(0), "inCaseAssetGetStuck: 0 address");
        // transfer all the balance of the asset this contract hold to the "to" address
        uint256 _bal = IERC20(asset).balanceOf(asset);
        IERC20(asset).safeTransfer(SAFE_ADDRESS, _bal);
    }

    // Transfers the dust to the SAFE_ADDRESS
    function transferDust() external onlyOwner {
        // precaution for reentrancy attack
        uint256 _dust = dust;
        dust = 0;
        IERC20(token).safeTransfer(SAFE_ADDRESS, _dust);
    }

    // Transfers the locked (non-vested) tokens of the passed recipients to the SAFE_ADDRESS
    // Only pass array of non-terminated recipient
    function seizeLockedTokens(address[] calldata _recipients)
        external
        onlyOwner
        returns (uint256 totalSeized)
    {
        // only seize if escrow is terminated
        require(ESCROW_TERMINATED, "seizeLockedTokens: escrow not terminated");
        // get the total tokens to be seized
        for (uint256 i = 0; i < _recipients.length; i++) {
            // only seize tokens from the recipients which have not been seized before
            if (!lockedTokensSeizedFor[_recipients[i]]) {
                totalSeized.add(totalLockedOf(_recipients[i]));
                lockedTokensSeizedFor[_recipients[i]] = true;
            }
        }
        // transfer the totalSeized amount to the SAFE_ADDRESS
        IERC20(token).safeTransfer(SAFE_ADDRESS, totalSeized);
    }
}
