pragma solidity ^0.4.23;

/**
 * @title MultiSign
 * @dev Allows multiple parties to agree on transactions before execution.
 * @author Stefan George - <stefan.george@consensys.net>
 */

contract MultiSign {

    uint public MAX_OWNER_COUNT = 50;

    event Confirmation(address indexed sender, uint indexed transactionId);//确认
    event Revocation(address indexed sender, uint indexed transactionId);//撤销
    event Submission(uint indexed transactionId);//提交
    event Execution(uint indexed transactionId);//执行
    event ExecutionFailure(uint indexed transactionId); //执行失败
    event Deposit(address indexed sender, uint value);//存款
    event OwnerAddition(address indexed owner);//超管之外
    event OwnerRemoval(address indexed owner);//所有者删除
    event RequirementChange(uint required);//需求变更

    mapping (uint => Transaction) public transactions;//事务列表
    mapping (uint => mapping(address => bool)) public confirmations;//确认数量
    mapping (address => bool) public isOwner;//是否超管
    address[] public owners;//超管数组
    uint public required;//需求
    uint public transactionCount; //事务序号

    ERC20 public token;

    struct Transaction {
        address destination; //是谁
        uint value; //要批多少币
        bytes data; //备注
        bool executed; //执行是否成功，true为成功
    }
//0x61626300000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000100
//0x6162630000000000000000000000000000000000000000000000000000000000
//0x0000000000000000000000000000000000000000000000000000000000000100
//16进制，用4位来表示一个字符，8个字符即4个字节
    modifier onlyWallet() {
        require(msg.sender == address(this));
        _;
    }

    modifier ownerNotExists(address owner) {
        require(!isOwner[owner]);
        _;
    }

    modifier ownerExists(address owner) {
        require(isOwner[owner]);
        _;
    }

    modifier transactionExists(uint transactionId) {
        require(transactions[transactionId].destination != 0);
        _;
    }

    modifier confirmed(uint transactionId, address owner) {
        require(confirmations[transactionId][owner]);
        _;
    }

    modifier notConfirmed(uint transactionId, address owner) {
        require(!confirmations[transactionId][owner]);
        _;
    }

    modifier notExecuted(uint transactionId) {
        require(!transactions[transactionId].executed);
        _;
    }

    modifier notNull(address _address) {
        require(_address != address(0));
        _;
    }

    modifier validRequirement(uint ownerCount, uint _required) {
        require(ownerCount > 0 && ownerCount <= MAX_OWNER_COUNT && _required > 0 && _required <= ownerCount);
        _;
    }

    /**
     * @dev Fallback function allows to deposit ether.
     */
    function() public payable {
        require(msg.value > 0);
        emit Deposit(msg.sender, msg.value);
    }

    /**
     * @dev Contract constructor sets initial owners and required number of confirmations.
     * @param _owners List of initial owners.
     * @param _required Number of required confirmations.
     */
    constructor(address[] _owners, uint _required, ERC20 _token) public validRequirement(_owners.length, _required)
    {
        for (uint i=0; i<_owners.length; i++) {  
            require(!isOwner[_owners[i]] && _owners[i] != address(0));             
            isOwner[_owners[i]] = true;
        }
        owners = _owners;
        required = _required;
        token = _token;
    }

    /** 
     * 增加超管
     * @dev Allows to add a new owner. Transaction has to be sent by wallet.
     * @param owner Address of new owner.
     */
    function addOwner(address owner) public onlyWallet ownerNotExists(owner) notNull(owner) validRequirement(owners.length + 1, required)
    {
        isOwner[owner] = true;
        owners.push(owner);
        emit OwnerAddition(owner);
    }

    /** 
     * 移除超管
     * @dev Allows to remove an owner. Transaction has to be sent by wallet.
     * @param owner Address of owner.
     */
    function removeOwner(address owner) public onlyWallet ownerExists(owner)
    {
        isOwner[owner] = false;
        for (uint i=0; i<owners.length - 1; i++) {
            if (owners[i] == owner) {
                owners[i] = owners[owners.length - 1];
                break;
            }
        }            
        owners.length -= 1; //通过-1的方式，将最后一个元素删除
        if (required > owners.length) {
            changeRequirement(owners.length);
        }            
        emit OwnerRemoval(owner);
    }

    /** 
     * 替换超管
     * @dev Allows to replace an owner with a new owner. Transaction has to be sent by wallet.
     * @param owner Address of owner to be replaced.
     * @param newOwner Address of new owner.
     */
    function replaceOwner(address owner, address newOwner) public onlyWallet ownerExists(owner) ownerNotExists(newOwner)
    {
        for(uint i=0; i<owners.length; i++) {
            if (owners[i] == owner) {
                owners[i] = newOwner;
                break;
            }
        }            
        isOwner[owner] = false;
        isOwner[newOwner] = true;
        emit OwnerRemoval(owner);
        emit OwnerAddition(newOwner);
    }

    /** 
     * 更新确认数
     * @dev Allows to change the number of required confirmations. Transaction has to be sent by wallet.
     * @param _required Number of required confirmations.
     */
    function changeRequirement(uint _required) public onlyWallet validRequirement(owners.length, _required)
    {
        required = _required;
        emit RequirementChange(_required);
    }

    /** 
     * 提交一个待审批的事务
     * @dev Allows an owner to submit and confirm a transaction.
     * @param destination Transaction target address.
     * @param value Transaction ether value.
     * @param data Transaction data payload.
     * @return Returns transaction ID.
     */
    function submitTransaction(address destination, uint value, bytes data) public returns (uint transactionId)
    {
        transactionId = addTransaction(destination, value, data);
        confirmTransaction(transactionId);
    }

    /** 
     * 在当前超管没有审批的情况下，进入并确认审批通过
     * @dev Allows an owner to confirm a transaction.
     * @param transactionId Transaction ID.
     */
    function confirmTransaction(uint transactionId) public ownerExists(msg.sender) transactionExists(transactionId) notConfirmed(transactionId, msg.sender)
    {
        confirmations[transactionId][msg.sender] = true;
        emit Confirmation(msg.sender, transactionId);
        executeTransaction(transactionId);
    }

    /** 
     * 后悔了，撤销确认
     * @dev Allows an owner to revoke a confirmation for a transaction.
     * @param transactionId Transaction ID.
     */
    function revokeConfirmation(uint transactionId) public ownerExists(msg.sender) confirmed(transactionId, msg.sender) notExecuted(transactionId)
    {
        confirmations[transactionId][msg.sender] = false;
        emit Revocation(msg.sender, transactionId);
    }

    /** 
     * 审批通过后，执行操作
     * @dev Allows anyone to execute a confirmed transaction.
     * @param transactionId Transaction ID.
     */
    function executeTransaction(uint transactionId) public notExecuted(transactionId)
    {
        if (isConfirmed(transactionId)) {
            Transaction storage tx = transactions[transactionId];
            tx.executed = true; //批准执行，记录一个状态true
            if (tx.destination.call.value(tx.value)(tx.data)) {
                //TODO 执行成功
            } else {
                emit ExecutionFailure(transactionId); //执行失败，记录到日志
                tx.executed = false;
            }
        }
    }

    /** 
     * 检查是否已经达到目标确认数量
     * @dev Returns the confirmation status of a transaction.
     * @param transactionId Transaction ID.
     * @return Confirmation status.
     */
    function isConfirmed(uint transactionId) public view returns (bool)
    {
        uint count = 0;
        for (uint i=0; i<owners.length; i++) {
            if (confirmations[transactionId][owners[i]]) {
                count += 1;
            }                
            if (count == required) {
                return true;
            }                
        }
    }

    /** 
     * 添加一个事务
     * @dev Adds a new transaction to the transaction mapping, if transaction does not exist yet.
     * @param destination Transaction target address.
     * @param value Transaction ether value.
     * @param data Transaction data payload.
     * @return Returns transaction ID.
     */
    function addTransaction(address destination, uint value, bytes data) internal notNull(destination) returns (uint transactionId)
    {
        transactionId = transactionCount;
        transactions[transactionId] = Transaction({
            destination: destination,
            value: value,
            data: data,
            executed: false
        });
        transactionCount += 1;
        emit Submission(transactionId);
    }

    /** 
     * 获取一个事务当前的确认数
     * Web3 call functions
     * @dev Returns number of confirmations of a transaction.
     * @param transactionId Transaction ID.
     * @return Number of confirmations.
     */
    function getConfirmationCount(uint transactionId) public view returns (uint count)
    {
        for (uint i=0; i<owners.length; i++) {
            if (confirmations[transactionId][owners[i]]) {
                count += 1;
            }
        }            
                
    }

    /** 
     * 获取事务数量（审批中的和已执行了的）
     * @dev Returns total number of transactions after filers are applied.
     * @param pending Include pending transactions.
     * @param executed Include executed transactions.
     * @return Total number of transactions after filters are applied.
     */
    function getTransactionCount(bool pending, bool executed) public view returns (uint count)
    {
        for (uint i=0; i<transactionCount; i++) {
            if (pending && !transactions[i].executed || executed && transactions[i].executed) {
                count += 1;
            }
        }           
                
    }

    /** 
     * 获取超管列表
     * @dev Returns list of owners.
     * @return List of owner addresses.
     */
    function getOwners() public view returns (address[])
    {
        return owners;
    }

    /** 
     * 获取一个事务当前的已确认名单
     * @dev Returns array with owner addresses, which confirmed transaction.
     * @param transactionId Transaction ID.
     * @return Returns array of owner addresses.
     */
    function getConfirmations(uint transactionId) public view returns (address[] _confirmations)
    {
        address[] memory confirmationsTemp = new address[](owners.length);
        uint count = 0;
        uint i;
        for (i=0; i<owners.length; i++) {
            if (confirmations[transactionId][owners[i]]) {
                confirmationsTemp[count] = owners[i]; //记录那些已经确认的名单
                count += 1;
            }
        }            
        _confirmations = new address[](count);
        for (i=0; i<count; i++) {
            _confirmations[i] = confirmationsTemp[i];
        }

    }

    
    /** 
     * 获取事务ID列表
     * @dev Returns list of transaction IDs in defined range.
     * @param from Index start position of transaction array.
     * @param to Index end position of transaction array.
     * @param pending Include pending transactions.
     * @param executed Include executed transactions.
     * @return Returns array of transaction IDs.
     */
    function getTransactionIds(uint from, uint to, bool pending, bool executed) public view returns (uint[] _transactionIds)
    {
        uint[] memory transactionIdsTemp = new uint[](transactionCount);
        uint count = 0;
        uint i;
        for (i=0; i<transactionCount; i++) {
            if (   pending && !transactions[i].executed
                || executed && transactions[i].executed)
            {
                transactionIdsTemp[count] = i;
                count += 1;
            }
        }            
        _transactionIds = new uint[](to - from);
        for (i=from; i<to; i++) {
            _transactionIds[i - from] = transactionIdsTemp[i];
        }
            
    }

}