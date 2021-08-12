//SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8;

/**
 * Import statements for integration of interfaces and other implementations
 **/

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";             // ERC20 interface by openzeppelin
import "@chainlink/contracts/src/v0.8/dev/VRFConsumerBase.sol";     // Chainlinks Verifiable Randomness


contract SurveyToken is ERC20, VRFConsumerBase {
    string private _name;                                       // Title of the survey              (-> Set in constructor)
    string private _symbol;                                     // Representation of the token      (-> Set in constructor)
    uint8 private _decimals = 0;                                // Tokens are integers              Overload the value in OpenZeppelin
    uint256 private _totalsupply = 5000;                        // Up to 5000 pending particpants at a time, constant


    enum ContractState {                                        // The different states the contract might be in chronological order
        CREATED,                                                    // Survey was created, sharing tokens possible, answering not yet allowed
        ACTIVE,                                                     // Survey active: Answering, Participation in lottery, Token Transfers
        EXPIRED,                                                    // Survey timed out: Call prepareRandomNumber and runLottery
        PAYOUT,                                                     // Winners may claim their prizes
        FINISHED }                                                  // Winners may still claim prizes, contract can be deleted (optionally)
    ContractState private currentState;                         // Current state of the survey

    address private owner;                                      // The address of the owner of the contract (the survey's creator)
    uint32[] private answersList;                               // A list containing all the answers

    address[] private raffleParticipants;                       // List of all the participants in the raffle
    address[] private raffleWinners;                            // The addresses of the winners of the raffle
    
    // Oracle configuration: Depending on network -> Set via Constructor
    address private coordinatorAddress;     // Chainlink VRF Coordinator address
    address private linkTokenAddress;       // LINK token address
    bytes32 internal keyHash ;              // ChainLink Key Hash
    uint256 internal fee;  // Fee in LINK (18 decimals: e.g. 1 LINK = 1 * 10**18 )

    uint256 private randomNumber;                       // The random number for the raffle. Will be determined after the survey is done.
    bool private randomNumberDrawn = false;             // Holds, if a RN is already drawn
    bytes32 randomNumberRequestId;                      // The ID of the request we make to ChainLink
    uint256 private randomNumberQueryTimestamp = 0;     // Holds the timestamp, when a RN was queried from the oracle

    uint256[] private prizes;                          // Amount of ETH in Gwei for the prizes, starting with 1st (1st, 2nd, 3rd, …)

    uint256 private timestampEndOfSurvey;               // Holds the timestamp when the survey will be over (in seconds after Epoch)
    uint256 private durationCollectionPeriod;           // Holds the duration of the collection period
    uint256 private timestampEndOfCollection;           // Holds the timestamp when the survey payout is over (in seconds after Epoch)
    /**
     * Timestamp with Timestamp of end of survey + amount of time (in SECONDS) for the winners to claim their prize after they have been drawn;
     * Should be at least 2 Weeks (= 1209600 Seconds)
     * After that period the contract may be destroyed by the owner and the prizes expire.
     * This destruction is optional though, since the owner can decide to leave the contract.
     **/
    
    // NOTE: Current values are for testing only, will be increased for real deployment
    uint256 minDurationActiveSeconds = 30;          // Minimum duration a survey has to be active before expiring
    uint256 maxDurationActiveSeconds = 31536000;    // Maximum duration a survey may be active before expiring, ~1 year = 31536000s
    uint256 minDurationPayoutSeconds = 30;          // Minimum payout phase duration a surv˚ey is in before anything can be deleted/ ETH can be transferred back, should be > 1 week usually
    uint256 oracleWaitPeriodSeconds = 30;         // Time to wait for a callback from the oracle before enabling the fallback randomness source

    constructor(string memory _tokenName, string memory _tokenSymbol, address _coordinatorAddress, address _linkTokenAddress, bytes32 _keyHash, uint256 _fee) 
        ERC20(
            _tokenName,
            _tokenSymbol
        )
        VRFConsumerBase(
            _coordinatorAddress, // VRF Coordinator
            _linkTokenAddress  // LINK Token
        )
        {
        coordinatorAddress = _coordinatorAddress;
        linkTokenAddress = _linkTokenAddress;
        keyHash = _keyHash;
        fee = _fee;
        _symbol = _tokenSymbol;
        _name = _tokenName;
        _mint(msg.sender, _totalsupply);            // Get the initial Supply into the contract: Amount of tokens that exist in total
        owner = msg.sender;                         // The creator of the contract (and the survey) is also the owner
        currentState = ContractState.CREATED;       // We start in this state
    }
    

    // ------ ------ ------ ------ ------ ------
    // ------ Access modifiers definitions -----
    // ------ ------ ------ ------ ------ ------

    // Only the owner of the contract has access
    modifier onlyOwner() {
        require(msg.sender == owner, "Only the owner of this contract may invoke this function.");
        _;
    }

    // Only accounts with at least one token have access
    modifier onlyWithToken() {
        require(balanceOf(msg.sender) > 0);
        _;
    }
    
    modifier onlyActiveSurvey() {
        require(currentState == ContractState.ACTIVE , "The survey is not active.");
        require(block.timestamp <= timestampEndOfSurvey, "Survey is not active anymore.");
        _;
    }
    
    modifier onlyExpiredSurvey(){
        require(block.timestamp > timestampEndOfSurvey, "The survey is still active.");
        require(currentState > ContractState.CREATED, "The survey was not yet created.");
        require(currentState <= ContractState.EXPIRED, "The survey is not in the active or expired state."); // Only ACTIVE or EXPIRED are allowed
        currentState = ContractState.EXPIRED; // Update the state again
        _;
    }
    
    modifier onlyPayoutSurvey(){
        require(currentState >= ContractState.PAYOUT, "The survey is not ready to payout, yet.");
        _;
    }
    
    modifier onlyFinishedSurvey() {
        require(timestampEndOfCollection < block.timestamp, "The collection period is not over, yet.");
        require(currentState >= ContractState.PAYOUT, "The survey state is still too low.");
        currentState = ContractState.FINISHED;
        _;
    }


    // ------ ------ ------ ------ ------ ------ //
    // ------ Fallback-function ----- //
    // ------ ------ ------ ------ ------ ------ //

    /**
     * This function gets called when no other function matches (-> Will fail in this case) or when paying in some ETH
     */
    fallback () external payable {
        revert(); // We do not allow calls that do not match any function
    }

    /**
    *   This function is called when no data is supplied in the call. It is used to add ETH to this contract.
    */
    receive () external payable {
        // 'address(this).balance' gets updated automatically with the sent ETH
    }
    
    
    
    // ------ ------ ------ ------ ------ ------ ----- ----- //
    // ------ Checking the current state of the contract --- //
    // ------ ------ ------ ------ ------ ------ ----- ----- // 


    /**
        Returns the current state of the survey
    */
    function getSurveyState() external view returns (ContractState){
        return currentState;
    }

    /**
        Overrides the value in OpenZeppelin, which would be 18 by default
    */
    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }
    

    // ------ ------ ------ ------ ------ ------ //
    // ------ Starting the survey ----- //
    // ------ ------ ------ ------ ------ ------ //

    /**
     * This function checks if all prerequisites of the survey are fulfilled and starts the
     * survey.
     * CAUTION: Starting a survey cannot be reverted and leads to drawing a winner after the set timeframe has passed
     *          The contract cannot be reused after it has been started and completed, therefore only start if everything is set and ready!
     * @param surveyDurationSeconds: Duration of the survey in SECONDS (!!)
     * @param payoutPeriodSeconds: Duration of the collection/ payout period in SECONDS (!!)
     * @param prizesInGwei: The prizes that are payed to the winners; Starting with the highest one (1. prize, 2nd prize, ...)
     * The balance of the contract MUST be > than the sum of all prizes and some headroom for gas, otherwise this function will revert
     * prize expires
     **/
    function startSurvey(uint256 surveyDurationSeconds, uint256 payoutPeriodSeconds, uint256[] memory prizesInGwei) public onlyOwner{
        require(currentState == ContractState.CREATED, "The survey has already been started");

        require(
            surveyDurationSeconds > minDurationActiveSeconds,
            "Duration must be longer than the set minimum duration"
        );
        require(
            surveyDurationSeconds < maxDurationActiveSeconds,
            "Duration must not be longer than set maximum duration."
        ); 
        timestampEndOfSurvey = add(block.timestamp, surveyDurationSeconds); // Adding with safeMath here, even though we checked the input previously
        
        require(
            payoutPeriodSeconds > minDurationPayoutSeconds,
            "Payout period must be at least the set minimum duration"
        );
        require(LINK.balanceOf(address(this)) >= fee, "Not enough LINK"); // You have to add some chainLink to start
        durationCollectionPeriod = payoutPeriodSeconds; // Note down this value

        uint256 totalPrizes;
        for (uint256 i = 0; i < prizesInGwei.length; i++) {
            add(totalPrizes, prizesInGwei[i]); // Update the total
            prizes.push(prizesInGwei[i]); // Add to our list
        }
        require(
            address(this).balance > (totalPrizes * 10**9),  // Conversion from Wei to Gwei
            "The contract does not have enough funds for giving out the prizes."
        );
        currentState = ContractState.ACTIVE;
    }


    // ------ ------ ------ ------ ------ ------ //
    // ------ ACTIVE STATE FUNCTIONS ---- ----- //
    // ------ ------ ------ ------ ------ ------ //

    /**
     * Allows to autheticate a user for starting a SurveyToken
     * @return true on token possession, false otherwise
     **/

    function auth_user() public view onlyActiveSurvey returns (bool) {
        if (balanceOf(msg.sender) > 0) {
            return true;
        }
        if (msg.sender == owner) return true;       // The owner can be authenticated by default
        return false;
    }

    /**
     * Adds the answer to the array of answers and removes one token, adds participation to raffle
     * @param hash: Hash value of the answers given by the participant
     **/
    function add_answer_hash(uint32 hash)
        public
        onlyWithToken
        onlyActiveSurvey
    {
        require(msg.sender != owner, "The owner cannot participate");
        answersList.push(hash); // Add the hash to the list

        increaseAllowance(msg.sender, 1); // Make transferFrom possible
        transferFrom(msg.sender, owner, 1); // Remove one token and add it back to the owners account

        raffleParticipants.push(msg.sender); // Participate last, in case anything else fails
    }

    /*
    * Sends tokens from the user's account to the addresses from the parameter
    * Maximum of 100 transfers at a time
    **/
    function distributeTokens(address[] memory receivers) public{
        require(receivers.length <= 100, "Only leq than 100 transfers at a time.");
        increaseAllowance(msg.sender, receivers.length); // Make transferFrom possible
        for(uint32 i = 0; i < receivers.length; i++){
            transferFrom(msg.sender, receivers[i], 1); // Send one token each
        }
    }


    // ------ ------ ------ ------ ------ ------  //
    // ------ Expired State Functions ---- ------ //
    // ------ ------ ------ ------ ------ ------  //
    
    /**
     * Issues generation of a random number. May be recalled, if the oracle fails within 10 minutes, to use backup RNG (with lower security guarantee) for the contract not getting stuck in the expired STATE
     **/ 
    function prepareRandomNumber() external onlyExpiredSurvey{
        require(!randomNumberDrawn, "There is already a random number");
        if(randomNumberQueryTimestamp == 0){
            require(LINK.balanceOf(address(this)) >= fee, "Not enough LINK - transfer some linkl to this contract for the fee");
            randomNumberQueryTimestamp = block.timestamp;
            randomNumberRequestId = requestRandomness(keyHash, fee, uint256(blockhash(block.number-1))); // Use ChainLink to request randomness; Using the last blockhash as user defined seed. 
        }else{ 
            // NOTE: This case is only invoked as a last resort to unstuck the contract, if the oracle fails. 
            require(block.timestamp > add(randomNumberQueryTimestamp, oracleWaitPeriodSeconds), "We wait some time for the oracle to provide a random number, before using the fallback RNG.");
            randomNumber = uint256(blockhash(block.number-1) ^ blockhash(block.number-2) ^ blockhash(block.number-3)); // Using the XOR of the last three blockhashes
            randomNumberDrawn = true;
        }
    }

    /**
     * Callback function used by VRF Coordinator to add the random number
     * Only accepted from ChainLink Coordinator to prevent others introducing wrong random numbers
     */
    function fulfillRandomness(bytes32 requestId, uint256 randomness) internal override {
        require(msg.sender == coordinatorAddress && randomNumberRequestId == requestId, "Randomness not accepted"); // We add this to guarantee the sender of the RN corresponds to the real oracle
        randomNumber = randomness;
        randomNumberDrawn = true;
    }

    // After the random number has been prepared, the winners get drawn and the payout state is set
    // ONLY WORKS, if prepareRandomNumber() has been called before!
    // Previously called 'finishSurvey()'
    function preparePayout() external onlyExpiredSurvey{        
        require(randomNumberDrawn, "First, a random number has to be drawn");

        if(raffleParticipants.length == 0) return; // No participants -> No winners
        uint winner_count = prizes.length;
        if(winner_count == 0) return;
        for (uint i = 0; i < winner_count; i++) {
            uint256 winner_number =
                (randomNumber + i) % raffleParticipants.length; // Generate the index of the winner; Do NOT use SafeMath here, otherwise the contract could get stuck in this extremely (!!) unlikely edge case:
                                                                //  randomNumber + winner_count > MAXVALUE(uint256) if the randomNumber is too large
            raffleWinners.push(raffleParticipants[winner_number]);
        }
        
        timestampEndOfCollection = add(timestampEndOfSurvey, durationCollectionPeriod); // Calculate the timestamp relative to the end of the active period starting from now
        currentState = ContractState.PAYOUT; // Survey is not active anymore
    }

    /**
     * Returns the random number that was drawn
     **/
    function get_random_number() external view returns (uint256){
        return randomNumber;
    }


    // ------ ------ ------ ------ ------ ------ ------ //
    // ------ PAYOUT STATE FUNCTIONS --------   ----- //
    // ------ ------ ------ ------ ------ ------ ------ //
    
    /**
     * Returns the array with all the winners
     **/
    function get_winners() external view onlyPayoutSurvey returns (address[] memory){
        return raffleWinners;
    }
    
    /**
     * Returns if the caller is a winner
     **/
    function didIWin() public view onlyPayoutSurvey returns (bool) {
        for(uint i = 0; i < raffleWinners.length; i++){
            if(raffleWinners[i] == msg.sender) return true;
        }
        return false;
    }

    /**
    * Allows the winner to claim the prize associated with its address
    * Does not pay attention to gas needs of a calling contract, as only external parties are able to withdraw funds (as only those should be able to participate in a survey)
    */
    function claimPrize() external onlyPayoutSurvey {
        bool prizeWon = false;  // Only set to true, if one or more prizes were won
        for(uint i = 0; i < raffleWinners.length; i++){
            if(raffleWinners[i] == msg.sender){
                //require(i < prizes.length, "Length mismatch"); // Should never happen, only through programmatical error
                uint prizeGwei = prizes[i];
                if(prizeGwei <= 0){ // We do not bother if there is no prize left
                    continue;
                }
                prizes[i] = 0; // Reset the prize before transfer
                (payable(msg.sender)).transfer(prizeGwei * 1000000000); // Send the prize in Wei
                prizeWon = true;
            }
        }
        // If there was no transfer, we revert. Otherwise, the transfers are allowed
        if(!prizeWon){
            revert("There is no prize to claim for you");
        }
    }
    
    /**
     * Returns all given answerHashes
     * @return A list of all answerHashes
     **/
    function get_answer_list() external view returns (uint32[] memory) {
        return answersList;
    }

    /**
     * Allows to get the total count of answers
     * @return Total count of answers
     **/
    function get_answer_count() external view returns (uint256) {
        return answersList.length;
    }
    
    
    // ------ ------ ------ ------ ------ ------ ------ //
    // ------ FINISHED STATE FUNCTIONS --------   ----- //
    // ------ ------ ------ ------ ------ ------ ------ //
    
    // Frees memory on the blockchain to get back some gas; COMPLETELY DESTROYS THE CONTRACT
    // WARNING: Data can not be retrieved via the respective functions anymore, after calling this function 
    // WARNING: Data is not deleted for good, just not included in newer blocks anymore. You cannot delete data from a blockchain by design.
    function cleanup() onlyOwner onlyFinishedSurvey external {
        address payable creator = payable(msg.sender);
        selfdestruct(creator); // Gets back all ETH and destroys the contract completely
    }   
    
    // Return all ETH of this contract to the owners account without deleting any of the data
    function getBackRemainingEth() onlyOwner onlyFinishedSurvey external{
        address payable creator = payable(msg.sender);
        creator.transfer(address(this).balance);
    }


    // ------ ------ ------ ------ ------ ------ ------ //
    // ------ Helper functions (pure functions)   ----- //
    // ------ ------ ------ ------ ------ ------ ------ //

    /** From OpenZeppelin SafeMath
     * @dev Returns the addition of two unsigned integers, reverting on
     * overflow.
     *
     * Counterpart to Solidity's `+` operator.
     *
     * Requirements:
     * - Addition cannot overflow.
     */
    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 c = a + b;
        require(c >= a, "SafeMath: addition overflow");
        return c;
    }
}
