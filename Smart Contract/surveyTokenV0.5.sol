pragma solidity >=0.4.22; // Use v0.6.12 for success

/**
 * Import statements for integration of interfaces and other implementations
 **/

import "@openzeppelin/contracts/token/ERC20/ERC20.sol"; // ERC20 interface by openzeppelin, use v3.x or else it will clash with provable
import "./provableAPI.sol";

contract SurveyToken is ERC20, usingProvable {
    string private _name = "2020-survey-trust";
    string private _symbol = "2020-SRV-TRST";
    uint8 private _decimals = 0;
    uint256 private _totalsupply = 1000;


    enum ContractState { CREATED, ACTIVE, EXPIRED, PAYOUT, FINISHED }  // The different states the contract might be in chronological order

    address private owner; // The address of the owner of the contract
    ContractState private currentState;

    uint32[] private answersList; // A list containing all the answers

    address[] private raffleParticipants; // List of all the participants of the raffle
    address[] private raffleWinners; // The addresses of the winners of the raffle
    mapping(address => uint256) private raffleWinnerMap;    // Map of winner addresses to their prices
    mapping(address => address) private raffleWinnerMainnetMap; // Mapping from current net addresses to mainnet addresses of raffle winners for later payout // Only needed, if not on mainnet
    

    uint32 private randomNumber; // The random number for the raffle. Will be determined after the survey is done.
    bool private randomNumberDrawn = false;
    uint256 private randomNumberQueryTimestamp = 0;   // Holds the timestamp, when a RN was queried from provable. 

    uint256[] private prices; // Amount of ETH in Gwei for the prices, starting with 1st (1st, 2nd, 3rd, …)

    uint256 private timestampEndOfSurvey; // Holds the timestamp when the survey will be over (in seconds after Epoch)
    uint256 private durationCollectionPeriod;   // Holds the duration of the collection period
    uint256 private timestampEndOfCollection;
    /**
     * Timestamp with Timestamp of end of survey + amount of time (in SECONDS) for the winners to claim their price after they have been drawn;
     * Should be at least 2 Weeks (= 1209600 Seconds)
     * After that period the contract may be destroyed by the owner and the prices expire.
     * This destruction is optional though, since the owner can decide to leave the contract.
     **/
    
    uint256 minDurationActiveSeconds = 30;        // Minimum duration a survey has to be active before expiring
    uint256 maxDurationActiveSeconds = 31536000;    // Maximum duration a survey may be active before expiring, ~1 year = 31536000s
    uint256 minDurationPayoutSeconds = 30;        // Minimum payout phase duration a survey is in before anything can be deleted/ ETH can be transferred back, should be > 1 week usually
    uint256 oracleWaitPeriodSeconds = 7200;       // Time to wait for a callback from the oracle before enabling the fallback randomness source


    constructor() public ERC20(_name, _symbol) {
        _mint(msg.sender, _totalsupply); // Get the initial Supply into the contract: Amount of tokens that exist in total
        _setupDecimals(_decimals); // Tokens are integers
        owner = msg.sender; // The creator of the contract is also the owner
        currentState = ContractState.CREATED;   // We start in this state
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
        require(msg.data.length == 0); // We fail on wrong calls to other functions
        // 'address(this).balance' gets updated automatically
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
     * @param pricesInGwei: The prices that are payed to the winners; Starting with the highest one (1. Price, 2nd price, ...)
     * The balance of the contract MUST be > than the sum of all prices and some headroom for gas, otherwise this function will revert
     * price expires
     **/
    function startSurvey(
        uint256 surveyDurationSeconds,
        uint256 payoutPeriodSeconds,
        uint256[] memory pricesInGwei
    ) public onlyOwner{
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
        durationCollectionPeriod = payoutPeriodSeconds; // Note down this value

        uint256 totalPrices;
        for (uint256 i = 0; i < pricesInGwei.length; i++) {
            add(totalPrices, pricesInGwei[i]); // Update the total
            prices.push(pricesInGwei[i]); // Add to our list
        }
        require(
            address(this).balance > totalPrices,
            "The contract does not have enough funds for giving out the prices."
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
        if (msg.sender == owner) return true;
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
        answersList.push(hash); // Add the hash to the list

        increaseAllowance(msg.sender, 1); // Make transferFrom possible
        transferFrom(msg.sender, owner, 1); // Remove one token and add it back to the owners account

        raffleParticipants.push(msg.sender); // Participate last, in case anything else fails
    }




    // ------ ------ ------ ------ ------ ------  //
    // ------ Expired State Functions ---- ------ //
    // ------ ------ ------ ------ ------ ------  //
    
    /**
     * Issues generation of a random number. May be recalled, if Provable fails within 10 minutes, to use backup RNG (with lower security guarantee) for the contract not getting stuck in the expired STATE
     **/ 
    function prepareRandomNumber() external onlyExpiredSurvey{
        require(!randomNumberDrawn, "There is already a random number");
        if(randomNumberQueryTimestamp == 0){
            provable_query("WolframAlpha", "random number between 1 and 10001");
            randomNumberQueryTimestamp = block.timestamp;
        }else{ 
            // NOTE: This case is only invoked as a last resort to unstuck the contract, if Provable fails for some reason. The security of the random number is not guaranteed with this fallback, but since this part should never be called, it will be used anyway.
            require(block.timestamp > randomNumberQueryTimestamp + oracleWaitPeriodSeconds, "We wait some time for the oracle to provide a random number, before using the fallback RNG.");
            uint256 bhash = uint256(blockhash(block.number-1) ^ blockhash(block.number-2) ^ blockhash(block.number-3)); // Using the XOR of the last three blockhashes
            randomNumber = uint32(bhash%10000); // Map down to uint32
            randomNumberDrawn = true;
        }
    }

    // After the random number has been prepared, the winners get drawn and the payout state is set
    // ONLY WORKS, if prepareRandomNumber() has been called before!
    // Previously called 'finishSurvey()'
    function preparePayout() external onlyExpiredSurvey{        
        require(randomNumberDrawn, "First, a random number has to be drawn");
        
        run_raffle();   // Draw all the winners
        timestampEndOfCollection = add(timestampEndOfSurvey, durationCollectionPeriod); // Calculate the timestamp relative to the end of the active period starting from now
        currentState = ContractState.PAYOUT; // Survey is not active anymore
    }

    /**
     * Callback for the oracle calldata
     **/
    function __callback(bytes32 myid, string memory result) public override {
        if (msg.sender != provable_cbAddress()) revert("Address not from provable");
        randomNumber = uint32(stringToUint(result));  
        randomNumberDrawn = true;
        // FEATURE: Use verification here to verify integrity of the RN
    }

    /**
     * Returns the random number that was drawn
     **/
    function get_random_number()
        external
        view
        returns (uint256)
    {
        return randomNumber;
    }

    function run_raffle()
        private
        onlyExpiredSurvey
    {
        if(raffleParticipants.length == 0) return; // No participants -> No winners
        uint winner_count = prices.length;
        if(winner_count == 0) return;
        for (uint i = 0; i < winner_count; i++) {
            uint256 winner_number =
                (randomNumber + i) % raffleParticipants.length; // Generate the index of the winner
            raffleWinners.push(raffleParticipants[winner_number]);
            raffleWinnerMap[raffleParticipants[winner_number]] = prices[i];
        }
    }

    

    

    // ------ ------ ------ ------ ------ ------ ------ //
    // ------ PAYOUT STATE FUNCTIONS --------   ----- //
    // ------ ------ ------ ------ ------ ------ ------ //
    
    
    /**
     * Returns the array with all the winners
     **/
    function get_winners()
        external
        view
        onlyPayoutSurvey
        returns (address[] memory)
    {
        return raffleWinners;
    }
    

    /**
     * Returns if the caller is a winner
     **/
    function didIWin() public view onlyPayoutSurvey returns (bool) {
        return (raffleWinnerMap[msg.sender] > 0);
    }
    
    // Call this to claim your price. Sticking to the Solidity Withdrawal pattern
    function claimPrice(address mainNetAddress) onlyPayoutSurvey external{
        uint256 amount = raffleWinnerMap[msg.sender];
        require(amount > 0, "You do not have any payout left"); // You have to be a winner to claim a price
        raffleWinnerMap[msg.sender] = 0; // Reset balance to 0 before sending
        
        raffleWinnerMainnetMap[msg.sender] = mainNetAddress;
    }

    // Returns the associated mainnet address to a testnet address
    function getWinnerData(address testnetAddress) view external onlyPayoutSurvey returns (address, uint256){
        return (raffleWinnerMainnetMap[testnetAddress], raffleWinnerMap[testnetAddress]);
    }
    
    // ------- Getting answers ----  //
    
     /**
     * Returns all given answerHashes
     * @return A list of all answerHashes
     **/
    function get_answer_list() external view onlyPayoutSurvey returns (uint32[] memory) {
        require(currentState >= ContractState.PAYOUT); // Answers can only be fetched, if the survey results have been determined!
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
        delete answersList;
        delete raffleWinners;
        delete raffleParticipants;
        delete prices;
        selfdestruct(msg.sender); // Gets back all ETH and destroys the contract completely
    }   
    
    // Return all ETH of this contract to the owners account without deleting any of the data
    function getBackRemainingEth() onlyOwner onlyFinishedSurvey external{
       msg.sender.transfer(address(this).balance);
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

     /**
     * Helper function for String concatenation, adapted from https://ethereum.stackexchange.com/questions/729/how-to-concatenate-strings-in-solidity
     **/
    function append(string memory a, string memory b)
        internal
        pure
        returns (string memory)
    {
        return string(abi.encodePacked(a, b));
    }
    
    /**
     * Helper function, taken and modified from https://ethereum.stackexchange.com/questions/10932/how-to-convert-string-to-int
     * @param s The string to convert
     * @return uint version of the stringToUint
     **/
    function stringToUint(string memory s) internal pure returns (uint256) {
        bytes memory b = bytes(s);
        uint256 result = 0;
        for (uint256 i = 0; i < b.length; i++) {
            // c = b[i] was not needed
            if (b[i] >= 0x30 && b[i] <= 0x39) {
                result = result * 10 + (uint8(b[i]) - 48); // bytes and int are not compatible with the operator -.
            }
        }
        return result;
    }
}
