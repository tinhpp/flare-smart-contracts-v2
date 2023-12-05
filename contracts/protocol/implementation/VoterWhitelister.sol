// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import "flare-smart-contracts/contracts/userInterfaces/IPChainStakeMirror.sol";
import "../interface/IWNat.sol";
import "./EntityManager.sol";
import "./Finalisation.sol";
import "../../governance/implementation/AddressUpdatable.sol";
import "../../governance/implementation/Governed.sol";

/**
 * Only addresses registered in this contract can vote.
 */
contract VoterWhitelister is Governed, AddressUpdatable {

    uint256 internal constant UINT16_MAX = type(uint16).max;
    uint256 internal constant UINT256_MAX = type(uint256).max;

    struct VoterInfo {
        address voter; // entity
        address signingAddress;
        address ftsoAddress;
        uint256 weight;
    }

    struct VoterWithNormalisedWeight {
        address voter; // entity
        uint16 weight;
    }

    struct VoterData {
        uint256 weight;
        uint256 wNatWeight;
        bytes20[] nodeIds;
        uint256[] nodeWeights;
    }

    /// Maximum number of voters in the whitelist.
    uint256 public maxVoters;

    /// In case of providing bad votes (e.g. ftso collusion), the voter can be chilled for a few reward epochs.
    /// A voter can whitelist again from a returned reward epoch onwards.
    mapping(address => uint256) public chilledUntilRewardEpoch;

    // mapping: rewardEpoch => list of whitelisted voters for each reward epoch
    mapping(uint256 => VoterInfo[]) internal whitelist;

    // mapping: rewardEpoch => mapping: signing address => voter with normalised weight
    mapping(uint256 => mapping(address => VoterWithNormalisedWeight)) internal epochSigningAddressToVoter;
    mapping(uint256 => mapping(address => address)) internal epochVoterToSigningAddress;

    // Addresses of the external contracts.
    Finalisation public finalisation;
    EntityManager public entityManager;
    IPChainStakeMirror public pChainStakeMirror;
    IWNat public wNat;

    event VoterChilled(address voter, uint256 untilRewardEpoch);
    event VoterRemoved(address voter, uint256 rewardEpoch);
    event VoterWhitelisted(
        address voter,
        uint256 rewardEpoch,
        address signingAddress,
        address ftsoAddress,
        uint256 weight,
        uint256 wNatWeight,
        bytes20[] nodeIds,
        uint256[] nodeWeights
    );

    /// Only Finalisation contract can call this method.
    modifier onlyFinalisation {
        require (msg.sender == address(finalisation), "only finalisation");
        _;
    }

    constructor(
        IGovernanceSettings _governanceSettings,
        address _governance,
        address _addressUpdater,
        uint256 _maxVoters
    )
        Governed(_governanceSettings, _governance) AddressUpdatable(_addressUpdater)
    {
        maxVoters = _maxVoters;
    }

    /**
     * Request to whitelist voter
     */
    function requestWhitelisting(address _voter) external {
        address signingAddress = entityManager.getSigningAddress(_voter);
        require (signingAddress == msg.sender, "invalid signing address for voter");
        uint256 untilRewardEpoch = chilledUntilRewardEpoch[_voter];
        uint256 nextRewardEpoch = finalisation.getCurrentRewardEpoch() + 1;
        require(untilRewardEpoch == 0 || untilRewardEpoch <= nextRewardEpoch, "voter chilled");
        bool success = _requestWhitelistingVoter(_voter, signingAddress, nextRewardEpoch);
        require(success, "vote power too low");
    }

    /**
     * @dev Only governance can call this method.
     */
    function chillVoter(
        address _voter,
        uint256 _noOfRewardEpochs
    )
        external onlyGovernance
        returns(
            uint256 _untilRewardEpoch
        )
    {
        uint256 currentRewardEpoch = finalisation.getCurrentRewardEpoch();
        _untilRewardEpoch = currentRewardEpoch + _noOfRewardEpochs;
        chilledUntilRewardEpoch[_voter] = _untilRewardEpoch;
        emit VoterChilled(_voter, _untilRewardEpoch);
    }

    /**
     * Sets the max number of voters.
     * @dev Only governance can call this method.
     */
    function setMaxVoters(
        uint256 _maxVoters
    )
        external onlyGovernance
    {
        maxVoters = _maxVoters;
    }

    /**
     * Creates signing policy snaphot and returns the list of whitelisted signing addresses and normalised weights for a given reward epoch
     */
    function createSigningPolicySnapshot(uint256 _rewardEpoch)
        external onlyFinalisation
        returns (
            address[] memory _signingAddresses,
            uint16[] memory _normalisedWeights
        )
    {
        VoterInfo[] storage voters = whitelist[_rewardEpoch];
        uint256 length = voters.length;
        assert(length > 0);
        _signingAddresses = new address[](length);
        _normalisedWeights = new uint16[](length);
        uint256[] memory weights = new uint256[](length);
        uint256 weightsSum = 0;
        for (uint256 i = 0; i < length; i++) {
            VoterInfo storage voter = voters[i];
            _signingAddresses[i] = voter.signingAddress;
            weights[i] = voter.weight;
            weightsSum += weights[i];
        }

        // normalisation of weights
        for (uint256 i = 0; i < length; i++) {
            _normalisedWeights[i] = uint16(weights[i] * UINT16_MAX / weightsSum); // weights[i] <= weightsSum
            address voter = voters[i].voter;
            epochVoterToSigningAddress[_rewardEpoch][_signingAddresses[i]] = voter;
            epochSigningAddressToVoter[_rewardEpoch][_signingAddresses[i]] =
                VoterWithNormalisedWeight(voter, _normalisedWeights[i]);
        }
    }

    /**
     * Returns the list of whitelisted voters for a given reward epoch
     */
    function getWhitelistedVoters(uint256 _rewardEpoch) external view returns (VoterInfo[] memory) {
        return whitelist[_rewardEpoch];
    }

    /**
     * Returns the list of whitelisted ftso addresses for a given reward epoch
     */
    function getWhitelistedFtsoAddresses(uint256 _rewardEpoch) external view returns (address[] memory _ftsoAddresses) {
        VoterInfo[] storage voters = whitelist[_rewardEpoch];
        uint256 length = voters.length;
        _ftsoAddresses = new address[](length);
        for (uint256 i = 0; i < length; i++) {
            _ftsoAddresses[i] = voters[i].ftsoAddress;
        }
    }

    /**
     * Returns the list of whitelisted signing addresses for a given reward epoch
     */
    function getWhitelistedSigningAddresses(uint256 _rewardEpoch) external view returns (address[] memory _signingAddresses) {
        VoterInfo[] storage voters = whitelist[_rewardEpoch];
        uint256 length = voters.length;
        _signingAddresses = new address[](length);
        for (uint256 i = 0; i < length; i++) {
            _signingAddresses[i] = voters[i].signingAddress;
        }
    }

    /**
     * Returns the number of whitelisted voters for a given reward epoch
     */
    function getNumberOfWhitelistedVoters(uint256 _rewardEpoch) external view returns (uint256) {
        return whitelist[_rewardEpoch].length;
    }

    /**
     * Returns voter's address and normalised weight for a given reward epoch and signing address
     */
    function getVoterWithNormalisedWeight(
        uint256 _rewardEpoch,
        address _signingAddress
    )
        external view
        returns (
            address _voter,
            uint16 _normalisedWeight
        )
    {
        VoterWithNormalisedWeight storage data = epochSigningAddressToVoter[_rewardEpoch][_signingAddress];
        _voter = data.voter;
        _normalisedWeight = data.weight;
    }

    /**
     * Returns voter's signing address
     */
    function getVoterSigningAddress(
        uint256 _rewardEpoch,
        address _voter
    )
        external view
        returns (
            address _signingAddress
        )
    {
        return epochVoterToSigningAddress[_rewardEpoch][_voter];
    }

    /**
     * @inheritdoc AddressUpdatable
     */
    function _updateContractAddresses(
        bytes32[] memory _contractNameHashes,
        address[] memory _contractAddresses
    )
        internal override
    {
        finalisation = Finalisation(_getContractAddress(_contractNameHashes, _contractAddresses, "Finalisation"));
        entityManager = EntityManager(_getContractAddress(_contractNameHashes, _contractAddresses, "EntityManager"));
        pChainStakeMirror = IPChainStakeMirror(_getContractAddress(_contractNameHashes, _contractAddresses, "PChainStakeMirror"));
        wNat = IWNat(_getContractAddress(_contractNameHashes, _contractAddresses, "WNat"));
    }

    /**
     * Request to whitelist `_voter` account - implementation.
     */
    function _requestWhitelistingVoter(
        address _voter,
        address _signingAddress,
        uint256 _rewardEpoch
    )
        internal returns(bool)
    {

        (uint256 votePowerBlock, bool enabled) = finalisation.getVoterRegistrationData(_rewardEpoch);
        require (votePowerBlock != 0, "vote power block zero");
        require (enabled, "voter registration phase ended");
        VoterData memory voterData = _getVoterData(_voter, votePowerBlock);
        require (voterData.weight > 0, "voter weight zero");

        VoterInfo[] storage addressesForRewardEpoch = whitelist[_rewardEpoch];
        uint256 length = addressesForRewardEpoch.length;

        bool isListFull = length >= maxVoters; // length > maxVoters could happen if maxVoters value was reduced
        uint256 minIndex = 0;
        uint256 minIndexWeight = UINT256_MAX;

        // check if it contains _voter and find minimum to kick out (if needed)
        for (uint256 i = 0; i < length; i++) {
            VoterInfo storage voter = addressesForRewardEpoch[i];
            if (voter.voter == _voter) {
                // _voter is already whitelisted, return
                return true;
            } else if (isListFull && minIndexWeight > voter.weight) { // TODO optimize reading?
                minIndexWeight = voter.weight;
                minIndex = i;
            }
        }

        if (isListFull && minIndexWeight >= voterData.weight) {
            // _voter has the lowest weight among all
            return false;
        }

        address ftsoAddress = entityManager.getFtsoAddress(_voter);
        if (isListFull) {
            // kick the minIndex out and replace it with _voter
            address removedVoter = addressesForRewardEpoch[minIndex].voter;
            addressesForRewardEpoch[minIndex] = VoterInfo(_voter, _signingAddress, ftsoAddress, voterData.weight);
            emit VoterRemoved(removedVoter, _rewardEpoch);
        } else {
            // we can just add a new one
            addressesForRewardEpoch.push(VoterInfo(_voter, _signingAddress, ftsoAddress, voterData.weight));
        }

        emit VoterWhitelisted(
            _voter,
            _rewardEpoch,
            _signingAddress,
            ftsoAddress,
            voterData.weight,
            voterData.wNatWeight,
            voterData.nodeIds,
            voterData.nodeWeights
        );

        return true;
    }

    function _getVoterData(
        address _voter,
        uint256 _votePowerBlock
    )
        private view
        returns (VoterData memory _data)
    {
        _data.nodeIds = entityManager.getNodeIdsOfAt(_voter, _votePowerBlock);
        uint256 length = _data.nodeIds.length;
        _data.nodeWeights = new uint256[](length);
        uint256[] memory votePowers = pChainStakeMirror.batchVotePowerOfAt(_data.nodeIds, _votePowerBlock);
        for (uint256 i = 0; i < length; i++) {
            _data.nodeWeights[i] = votePowers[i];
            _data.weight += votePowers[i];
        }

        uint256 totalStakeVotePower = pChainStakeMirror.totalVotePowerAt(_votePowerBlock); // TODO cap?

        _data.wNatWeight = wNat.votePowerOfAt(_voter, _votePowerBlock);

        // staking is required to get additinal WNat weight
        if (_data.weight > 0) {
            uint256 totalWNatVotePower = wNat.totalVotePowerAt(_votePowerBlock); // TODO cap?
            _data.weight += _data.wNatWeight / 4; // TODO final factor and cap?
        }
    }
}