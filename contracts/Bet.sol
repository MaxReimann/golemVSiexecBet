

pragma solidity ^0.4.0;
import "github.com/oraclize/ethereum-api/oraclizeAPI.sol";

// oraclize contract to retrieve cmc ranks. Not included in main to not exceed maximum gas costs
contract CMCRank is usingOraclize {
    bytes32 private golemQueryId = -1;
    bytes32 private rlcQueryId  = -1;
    
    uint public rlcRank = 0;
    uint public golemRank = 0;
    
    event Log(string text);
    
    // Jan 1st, 2019
    //uint public bettingOutcomeDate = 1546300800;
    
    // 03. Feb 2018. just for testing purposes. TODO: use real date for mainnet contract
    uint public bettingOutcomeDate = 1517692944;
    

    // gets called by oraclize, containing the marketcap rank as a string and either the id of the golem or the iexec rank query
    function __callback(bytes32 _myid, string _result) public {
        require (msg.sender == oraclize_cbAddress());
        Log(_result);
        if (_myid == rlcQueryId) {
            rlcRank = parseInt(_result);
        } else if (_myid == golemQueryId) {
            golemRank = parseInt(_result);
        } else {
            Log("Received Unkown oraclize query id");
        }
    }
    
    function update() public payable {
        // can only update, when outcome date has been reached
        require(block.timestamp >= bettingOutcomeDate);
                
        if (oraclize_getPrice("URL") > this.balance) {
            Log("Oraclize query was NOT sent, please add some ETH to cover for the query fee");
        } else {
            Log("Oraclize query was sent, standing by for the answer..");
            
            rlcQueryId = oraclize_query("URL","json(http://api.coinmarketcap.com/v1/ticker/RLC/).0.rank");
            golemQueryId = oraclize_query("URL","json(http://api.coinmarketcap.com/v1/ticker/golem/).0.rank");
        }
    }
}


contract GolemIExecBet {
    
    // April 1st, 2018
    uint public bettingClosedDate = 1522540800;

    enum BetStatus { REQUESTED, ACCEPTED, CANCELED, COMPLETED }
    enum Pick { IEXEC, GOLEM } 
    enum GlobalStatus { RUNNING, IEXECWINS, GOLEMWINS, STOPPED }

    struct Bet {
        uint amount;
        BetStatus state;
        Pick requestorPick; // pick of winning project
        address requestor;
        address acceptor;
        bool requestorWantsCancel;
        bool acceptorWantsCancel;
        // using bytes32 here, to prevent any weirdness with arbitrary length strings & gascosts
        bytes32 requestorName; 
        bytes32 acceptorName;
    }
    
    mapping (address => Bet) private addressToBet;
    address[] private requestorAddresses;
    
    // The total amount held in escrow in this contract
    uint public totalBetSum = 0;
    
    // The current state of the bets
    GlobalStatus public globalStatus = GlobalStatus.RUNNING;
    
    // contract owner
    address public owner;
    
    // reference to cmc oracle contract
    CMCRank public cmcRankContract;
    

    
    event BetRequestEvent(uint amount, Pick pickedProject, address sender);
    event BetAcceptedEvent(address requestor, address acceptor, Pick requestorPick, uint amount);
    event BetCanceledEvent(address requestor, address acceptor);
    event BetCancelRequest(address sender);
    event Log(string text);
    
    modifier onlyOwner() {
        if (msg.sender != owner) throw;
        _;
    }

    function GolemIExecBet(address _cmcRankContract) payable {
        Log("GolemIExecBet Contract created.");
        owner = msg.sender;
        cmcRankContract = CMCRank(_cmcRankContract);
    }
    
    function placeBetRequest(uint pickedProject, bytes32 requestorName) public payable {
        // only the projects are allowed as input
        require(pickedProject == 0 || pickedProject == 1);
        
        // Betting phase must still be running & accepting new bets
        require(globalStatus == GlobalStatus.RUNNING);
        require(block.timestamp <= bettingClosedDate);
        
        require(msg.value >= 1 finney); // minimum betting amount = 0.001 eth
        
        // one address can only participate in one bet. reject second requests. 
        // the only time the requestor address is 0x0 is when the struct has not been initialized yet.
        require(addressToBet[msg.sender].requestor == 0x0);
        
        Pick pickEnum;
        if (pickedProject == 0) {
            pickEnum = Pick.IEXEC; 
        } else {
            pickEnum = Pick.GOLEM;
        }

        Bet memory b = Bet(/*amount*/ msg.value, /*BetStatus*/ BetStatus.REQUESTED, /* Pick*/ pickEnum, /*requestor*/ msg.sender, 
                            /*acceptor*/ 0x0, /*requestorWantsCancel*/ false, /*acceptorWantsCancel*/ false,
                            /*requestorName*/ requestorName, /*acceptorName*/ "");
        
        addressToBet[msg.sender] = b;
        requestorAddresses.push(msg.sender);
        totalBetSum +=  msg.value;
        BetRequestEvent(b.amount, b.requestorPick, msg.sender);
    }
    
    function acceptBet(address requestorToMatch, bytes32 acceptorName) public payable {
        // Betting phase must still be running & accepting new bets
        require(globalStatus == GlobalStatus.RUNNING);
        require(block.timestamp <= bettingClosedDate);
        
        // requestor bet hast to exist
        require(addressToBet[requestorToMatch].requestor != 0x0);
        
        // must be in REQUESTED state
        require(addressToBet[requestorToMatch].state == BetStatus.REQUESTED);
        
        // acceptor can't already be in a bet
        // the only time the requestor address is 0x0 is when the struct has not been initialized yet.
        require(addressToBet[msg.sender].requestor == 0x0);
        
        // The bet amount needs to be exactly matched
        require(addressToBet[requestorToMatch].amount == msg.value);
        
        Bet memory b = addressToBet[requestorToMatch];
        b.amount += msg.value;
        b.acceptor = msg.sender;
        b.state = BetStatus.ACCEPTED;
        b.acceptorName = acceptorName;
        
        addressToBet[requestorToMatch] = b;
        // map to both requestor and acceptor for easier lookup
        addressToBet[msg.sender] = addressToBet[requestorToMatch];
        
        totalBetSum += msg.value;
        BetAcceptedEvent(b.requestor, b.acceptor, b.requestorPick, b.amount);
    }
    
    
    // Try to cancel a bet & refund players. If both persons have already agreed to the bet, they must both cancel to annul the bet.
    function cancelBet() public {
        // Bet outcomes must not yet have been decided yet
        require(globalStatus == GlobalStatus.RUNNING);
        
        //bet has to exist
        require(addressToBet[msg.sender].requestor != 0x0);
        
        Bet memory b = addressToBet[msg.sender];
        
        // must be in REQUESTED or ACCEPTED state
        require(b.state == BetStatus.REQUESTED || b.state == BetStatus.ACCEPTED);
        
        bool senderIsRequestor = msg.sender == b.requestor;
        
        if (b.state == BetStatus.REQUESTED) {
            msg.sender.transfer(b.amount);

            // Completly null struct, to enable a new bet request to be made. In the ACCEPTED case, this is not possible.
            addressToBet[msg.sender] = Bet(/*amount*/ 0, /*BetStatus*/ BetStatus.REQUESTED, /* Pick*/ Pick.IEXEC, /*requestor*/ 0x0, 
                            /*acceptor*/ 0x0, /*requestorWantsCancel*/ false, /*acceptorWantsCancel*/ false,
                            /*requestorName*/ 0, /*acceptorName*/ 0);
            
            BetCanceledEvent(msg.sender, 0x0);
        } else if ((!senderIsRequestor && b.requestorWantsCancel) || (senderIsRequestor && b.acceptorWantsCancel)) {
            uint amountPerPerson = b.amount / 2;
            
            b.acceptor.transfer(amountPerPerson);
            b.requestor.transfer(amountPerPerson);
            
            addressToBet[msg.sender].state = BetStatus.CANCELED;
            
            BetCanceledEvent(b.requestor, b.acceptor);
        } else {
            if (senderIsRequestor) {
                addressToBet[msg.sender].requestorWantsCancel = true;
            } else {
                addressToBet[msg.sender].acceptorWantsCancel = true;
            }
            
            BetCancelRequest(msg.sender);
        }
    }
    

    function withdrawWinnings() public {
        // Outcomes must have been decided
        require(globalStatus == GlobalStatus.IEXECWINS || globalStatus == GlobalStatus.GOLEMWINS);
        
        Bet memory b = addressToBet[msg.sender];
        
        //bet has to exist
        require(b.requestor != 0x0);
        
        // must be in REQUESTED or ACCEPTED state
        require(b.state == BetStatus.REQUESTED || b.state == BetStatus.ACCEPTED);
        
        // In Accepted state, check if the callee has actually won the bet
        // In requested state, no further checks have to be done, just pay back the requestor
        if (b.state == BetStatus.ACCEPTED) {
            bool requestorWins = (b.requestorPick == Pick.IEXEC && globalStatus == GlobalStatus.IEXECWINS) ||  (b.requestorPick == Pick.GOLEM && globalStatus == GlobalStatus.GOLEMWINS);
        
            require((requestorWins && msg.sender == b.requestor ) || (!requestorWins && msg.sender == b.acceptor));
        }
        
        msg.sender.transfer(b.amount);
        addressToBet[msg.sender].state = BetStatus.COMPLETED;
        totalBetSum -= b.amount;
    }
    
    function getNumBets() public constant returns(uint) {
        return requestorAddresses.length;
    }
    
    function getBet(address betParticipant) public constant returns (uint, BetStatus, Pick, address, address, bool, bool, bytes32, bytes32) {
        Bet memory b = addressToBet[betParticipant];
        return (b.amount, b.state, b.requestorPick, b.requestor, b.acceptor, b.requestorWantsCancel, b.acceptorWantsCancel, b.requestorName, b.acceptorName);
    }
    
    function getBetByIndex(uint betIndex) public constant returns (uint, BetStatus, Pick, address, address, bool, bool, bytes32, bytes32) {
        address addr = requestorAddresses[betIndex];
        Bet memory b = addressToBet[addr];
        return (b.amount, b.state, b.requestorPick, b.requestor, b.acceptor, b.requestorWantsCancel, b.acceptorWantsCancel, b.requestorName, b.acceptorName);
    }
    
    function update() {
        if (cmcRankContract.rlcRank() > 0 && cmcRankContract.golemRank() > 0) {
            if (cmcRankContract.rlcRank() < cmcRankContract.golemRank()) {
                globalStatus = GlobalStatus.IEXECWINS;
            } else {
                globalStatus = GlobalStatus.GOLEMWINS;
            }
        }
    }
    
    // emergency stop, if something goes terribly wrong, the contract owner can set the status to stopped. 
    // any address participating can then be refunded with the refund() method.
    function emergencyStop() public onlyOwner {
        globalStatus = GlobalStatus.STOPPED;
    }
    
    // Can be called by anybody to refund bets, if the emergencyStop has been activated
    function refund(address betToRefund) public {
        require(globalStatus == GlobalStatus.STOPPED);
        
        Bet memory b = addressToBet[betToRefund];
        
        // bet has to exist
        require(b.requestor != 0x0);
        // cant be canceled or completed
        require(b.state == BetStatus.REQUESTED || b.state == BetStatus.ACCEPTED);
        
                
        if (b.acceptor == 0x0) {
            b.requestor.transfer(b.amount);
            addressToBet[betToRefund].state = BetStatus.CANCELED;
            BetCanceledEvent(betToRefund, 0x0);
        } else {
            uint amountPerPerson = b.amount / 2;
            
            b.acceptor.transfer(amountPerPerson);
            b.requestor.transfer(amountPerPerson);
            
            addressToBet[betToRefund].state = BetStatus.CANCELED;
            
            BetCanceledEvent(b.requestor, b.acceptor);
        } 
    }
  
}
