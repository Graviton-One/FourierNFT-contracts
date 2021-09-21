pragma solidity >=0.8.7;

// import "https://github.com/OpenZeppelin/openzeppelin-contracts/contracts/access/Ownable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/access/Ownable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC721/presets/ERC721PresetMinterPauserAutoId.sol";

interface ISubscriberBytes {
    function attachValue(bytes calldata value) external;
}

library QueueLib {
    struct Queue {
        bytes32 first;
        bytes32 last;
        mapping(bytes32 => bytes32) nextElement;
        mapping(bytes32 => bytes32) prevElement;
    }

    function drop(Queue storage queue, bytes32 rqHash) public {
        bytes32 prevElement = queue.prevElement[rqHash];
        bytes32 nextElement = queue.nextElement[rqHash];

        if (prevElement != bytes32(0)) {
            queue.nextElement[prevElement] = nextElement;
        } else {
            queue.first = nextElement;
        }

        if (nextElement != bytes32(0)) {
            queue.prevElement[nextElement] = prevElement;
        } else {
            queue.last = prevElement;
        }
    }

    // function next(Queue storage queue, bytes32 startRqHash) public view returns(bytes32) {
    //     if (startRqHash == 0x000)
    //         return queue.first;
    //     else {
    //         return queue.nextElement[startRqHash];
    //     }
    // }

    function push(Queue storage queue, bytes32 elementHash) public {
        if (queue.first == 0x000) {
            queue.first = elementHash;
            queue.last = elementHash;
        } else {
            queue.nextElement[queue.last] = elementHash;
            queue.prevElement[elementHash] = queue.last;
            queue.nextElement[elementHash] = bytes32(0);
            queue.last = elementHash;
        }
    }
}


contract NFTToken is ERC721PresetMinterPauserAutoId, Ownable {
    constructor(
        string memory name,
        string memory symbol,
        string memory baseTokenURI
    ) ERC721PresetMinterPauserAutoId(name, symbol, baseTokenURI) public {
        
    }

    function addMinter(address minter) external {
        require(hasRole(MINTER_ROLE, _msgSender()), "ERC20PresetMinterPauser: must have minter role to add minter");
        _setupRole(MINTER_ROLE, minter);
    }
}

contract IBPort is ISubscriberBytes, Ownable {
    enum RequestStatus {
        None,
        New,
        Rejected,
        Success,
        Returned
    }

    struct UnwrapRequest {
        address homeAddress;
        bytes32 foreignAddress;
        uint amount;
    }

    event RequestCreated(uint, address, bytes32, uint256);

    address public nebula;
    NFTToken public tokenAddress;

    mapping(uint => RequestStatus) public swapStatus;
    mapping(uint => UnwrapRequest) public unwrapRequests;
    QueueLib.Queue public requestsQueue;

    constructor(address _nebula, address _nftAddress) public {
        nebula = _nebula;
        tokenAddress = NFTToken(_nftAddress);
    }

    function deserializeUint(bytes memory b, uint startPos, uint len) internal pure returns (uint) {
        uint v = 0;
        for (uint p = startPos; p < startPos + len; p++) {
            v = v * 256 + uint(uint8(b[p]));
        }
        return v;
    }

    function deserializeAddress(bytes memory b, uint startPos) internal pure returns (address) {
        return address(uint160(deserializeUint(b, startPos, 20)));
    }

    function deserializeStatus(bytes memory b, uint pos) internal pure returns (RequestStatus) {
        uint d = uint(uint8(b[pos]));
        if (d == 0) return RequestStatus.None;
        if (d == 1) return RequestStatus.New;
        if (d == 2) return RequestStatus.Rejected;
        if (d == 3) return RequestStatus.Success;
        if (d == 4) return RequestStatus.Returned;
        revert("invalid status");
    }

    function attachValue(bytes calldata value) override external {
        require(msg.sender == nebula, "access denied");
        for (uint pos = 0; pos < value.length; ) {
            bytes1 action = value[pos]; pos++;

            if (action == bytes1("m")) {
                uint swapId = deserializeUint(value, pos, 32); pos += 32;
                uint amount = deserializeUint(value, pos, 32); pos += 32;
                address receiver = deserializeAddress(value, pos); pos += 20;
                mint(swapId, amount, receiver);
                continue;
            }

            if (action == bytes1("c")) {
                uint swapId = deserializeUint(value, pos, 32); pos += 32;
                RequestStatus newStatus = deserializeStatus(value, pos); pos += 1;
                changeStatus(swapId, newStatus);
                continue;
            }
            revert("invalid data");
        }
    }

    function mint(uint swapId, uint amount, address receiver) internal {
        require(swapStatus[swapId] == RequestStatus.None, "invalid request status");
        tokenAddress.mint(receiver);
        swapStatus[swapId] = RequestStatus.Success;
    }

    function changeStatus(uint swapId, RequestStatus newStatus) internal {
        require(swapStatus[swapId] == RequestStatus.New, "invalid request status");
        swapStatus[swapId] = newStatus;
        QueueLib.drop(requestsQueue, bytes32(swapId));
    }

    function createTransferUnwrapRequest(uint256 tokenId, bytes32 receiver) public {
        uint id = uint(keccak256(abi.encodePacked(msg.sender, receiver, block.number, tokenId)));
        unwrapRequests[id] = UnwrapRequest(msg.sender, receiver, tokenId);
        swapStatus[id] = RequestStatus.New;
        
        tokenAddress.transferFrom(msg.sender, address(this), tokenId);

        QueueLib.push(requestsQueue, bytes32(id));
        emit RequestCreated(id, msg.sender, receiver, tokenId);
    }

    function nextRq(uint rqId) public view returns (uint) {
        return uint(requestsQueue.nextElement[bytes32(rqId)]);
    }
    
    function prevRq(uint rqId) public view returns (uint) {
        return uint(requestsQueue.prevElement[bytes32(rqId)]);
    }

    function transferTokenOwnership(address newOwner) external virtual onlyOwner {
        tokenAddress.transferOwnership(newOwner);
    }
}