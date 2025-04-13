# @version ^0.3.7

# Chainlink Aggregator V3 Interface
interface AggregatorV3Interface:
    def latestRoundData() -> (uint80, int256, uint256, uint256, uint80): view

# 1inch AggregationRouterV5 Interface (simplified for Vyper)
interface OneInchRouter:
    def swap(
        executor: address,
        desc: SwapDescription,
        permit: bytes,
        data: bytes
    ) -> (uint256, uint256): nonpayable

# ERC-20 Interface for wstETH transfers
interface ERC20:
    def transfer(to: address, amount: uint256) -> bool: nonpayable

# Struct for 1inch swap description
struct SwapDescription:
    srcToken: address
    dstToken: address
    srcReceiver: address
    dstReceiver: address
    amount: uint256
    minReturnAmount: uint256
    flags: uint256

# Struct for NFT data
struct DepositData:
    wsteth_amount: uint256
    price_usd: uint256

# Struct for deposit info return
struct DepositInfo:
    token_id: uint256
    owner: address
    wsteth_amount: uint256
    price_usd: uint256

# Mainnet addresses
PRICE_FEED_ETH_USD: constant(address) = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419  # Chainlink ETH/USD
PRICE_FEED_WSTETH_ETH: constant(address) = 0x524299aCeDB6d4A39b6b8D6E229dE7f644f12122  # Chainlink wstETH/ETH
INCH_ROUTER: constant(address) = 0x1111111254EEB25477B68fb85Ed929f73A960582  # 1inch AggregationRouterV5
WSTETH: constant(address) = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0  # Lido wstETH

# Minimum and maximum deposit amounts (in wei)
MIN_DEPOSIT: constant(uint256) = 100000000000000000  # 0.1 ETH
MAX_DEPOSIT: constant(uint256) = 100000000000000000000  # 100 ETH

# Basis points denominator
BPS_DENOMINATOR: constant(uint256) = 10000  # 100% = 10000 bps

# Slippage constraints
MIN_SLIPPAGE_BPS: constant(uint256) = 10  # 0.1%
MAX_SLIPPAGE_BPS: constant(uint256) = 500  # 5%

# Tip constraints
MAX_TIP_BPS: constant(uint256) = 500  # 5%

# Oracle staleness threshold (15 minutes = 900 seconds)
MAX_ORACLE_AGE: constant(uint256) = 900  # 15 minutes

# Maximum tokens per batch emergency withdrawal
MAX_BATCH_SIZE: constant(uint256) = 50

# Maximum deposits returned by get_all_deposits
MAX_DEPOSITS_RETURN: constant(uint256) = 100

# Multi-sig governance address
admin: immutable(address)

# NFT state
token_counter: uint256
token_data: public(HashMap[uint256, DepositData])
owners: HashMap[uint256, address]
balances: HashMap[address, uint256]
owned_tokens: HashMap[address, uint256[MAX_BATCH_SIZE]]  # Limited index for enumeration
owned_tokens_index: HashMap[address, HashMap[uint256, uint256]]  # tokenId -> index
approvals: HashMap[uint256, address]

# Events for ERC-721
event Transfer:
    from_addr: indexed(address)
    to_addr: indexed(address)
    tokenId: indexed(uint256)

event Approval:
    owner: indexed(address)
    approved: indexed(address)
    tokenId: indexed(uint256)

# Events for deposits
event Deposit:
    sender: indexed(address)
    tokenId: indexed(uint256)
    eth_amount: uint256
    wsteth_amount: uint256
    price_usd: uint256
    slippage_bps: uint256
    tip_bps: uint256
    tip_amount: uint256

# Event for withdrawals
event Withdraw:
    sender: indexed(address)
    tokenId: indexed(uint256)
    eth_amount: uint256
    wsteth_amount: uint256
    slippage_bps: uint256

# Event for emergency withdrawals
event EmergencyWithdraw:
    depositor: indexed(address)
    tokenId: indexed(uint256)
    wsteth_amount: uint256
    initiated_by: indexed(address)

@external
@view
def get_all_deposits() -> DynArray[DepositInfo, MAX_DEPOSITS_RETURN]:
    """
    Returns a list of all active deposits (NFTs) with their data.
    @return An array of DepositInfo structs (token_id, owner, wsteth_amount, price_usd).
    """
    deposits: DynArray[DepositInfo, MAX_DEPOSITS_RETURN] = []
    for token_id in range(MAX_DEPOSITS_RETURN):
        if token_id >= self.token_counter:
            break
        if self.token_data[token_id].wsteth_amount == 0:
            continue
        deposits.append(DepositInfo({
            token_id: token_id,
            owner: self.owners[token_id],
            wsteth_amount: self.token_data[token_id].wsteth_amount,
            price_usd: self.token_data[token_id].price_usd
        }))
    return deposits

@external
def __init__(admin_addr: address):
    admin = admin_addr
    self.token_counter = 0

@external
@payable
def deposit(price_usd: uint256, slippage_bps: uint256, tip_bps: uint256):
    """
    Swaps ETH to wstETH via 1inch, mints an NFT with deposit data, only if no existing balance.
    @param price_usd The price (in USD, scaled by 10**8) for withdrawal condition.
    @param slippage_bps Slippage tolerance in basis points (e.g., 100 = 1%).
    @param tip_bps Tip in basis points (e.g., 100 = 1%) to send to admin, optional.
    """
    assert msg.value >= MIN_DEPOSIT, "Deposit below minimum"
    assert msg.value <= MAX_DEPOSIT, "Deposit above maximum"
    assert price_usd > 0, "Price must be greater than 0"
    assert slippage_bps >= MIN_SLIPPAGE_BPS, "Slippage too low"
    assert slippage_bps <= MAX_SLIPPAGE_BPS, "Slippage too high"
    assert tip_bps <= MAX_TIP_BPS, "Tip too high"
    assert self.balances[msg.sender] == 0, "Existing deposit must be withdrawn first"

    # Calculate and send tip
    tip_amount: uint256 = (msg.value * tip_bps) / BPS_DENOMINATOR
    swap_amount: uint256 = msg.value - tip_amount
    assert swap_amount > 0, "Swap amount too low"

    if tip_amount > 0:
        send(admin, tip_amount)

    # Check wstETH/ETH oracle for slippage
    oracle_wsteth: AggregatorV3Interface = AggregatorV3Interface(PRICE_FEED_WSTETH_ETH)
    (round_id_w, answer_w, started_at_w, updated_at_w, answered_in_round_w) = oracle_wsteth.latestRoundData()
    assert answer_w > 0, "Invalid wstETH/ETH price"
    assert block.timestamp <= updated_at_w + MAX_ORACLE_AGE, "wstETH/ETH oracle too old"
    wsteth_per_eth: uint256 = convert(answer_w, uint256)  # wstETH per ETH, scaled by 10**18

    # Estimate minimum wstETH output
    min_wsteth_out: uint256 = (swap_amount * wsteth_per_eth) / 10**18
    min_wsteth_out = min_wsteth_out * (BPS_DENOMINATOR - slippage_bps) / BPS_DENOMINATOR

    # Swap ETH to wstETH via 1inch
    router: OneInchRouter = OneInchRouter(INCH_ROUTER)
    desc: SwapDescription = SwapDescription({
        srcToken: empty(address),  # ETH
        dstToken: WSTETH,
        srcReceiver: self,
        dstReceiver: self,
        amount: swap_amount,
        minReturnAmount: min_wsteth_out,
        flags: 0  # Default flags
    })
    (return_amount, spent_amount) = router.swap(empty(address), desc, b"", b"")
    wsteth_received: uint256 = return_amount

    # Mint NFT
    token_id: uint256 = self.token_counter
    self.token_counter += 1
    self.owners[token_id] = msg.sender
    self.balances[msg.sender] += 1
    self.token_data[token_id] = DepositData({wsteth_amount: wsteth_received, price_usd: price_usd})

    # Update owned tokens
    index: uint256 = self.balances[msg.sender] - 1
    self.owned_tokens[msg.sender][index] = token_id
    self.owned_tokens_index[msg.sender][token_id] = index

    log Transfer(empty(address), msg.sender, token_id)
    log Deposit(msg.sender, token_id, msg.value, wsteth_received, price_usd, slippage_bps, tip_bps, tip_amount)

@external
def withdraw(token_id: uint256):
    """
    Burns the specified NFT and swaps wstETH to ETH if price exceeds NFT's price_usd.
    @param token_id The NFT representing the deposit.
    """
    assert self.owners[token_id] == msg.sender, "Not owner"
    assert self.token_data[token_id].wsteth_amount > 0, "Invalid token"

    # Check ETH/USD oracle
    oracle_eth: AggregatorV3Interface = AggregatorV3Interface(PRICE_FEED_ETH_USD)
    (round_id_e, answer_e, started_at_e, updated_at_e, answered_in_round_e) = oracle_eth.latestRoundData()
    assert answer_e > 0, "Invalid ETH/USD price"
    assert block.timestamp <= updated_at_e + MAX_ORACLE_AGE, "ETH/USD oracle too old"
    current_price: uint256 = convert(answer_e, uint256)
    assert current_price > self.token_data[token_id].price_usd, "Oracle price too low"

    slippage_bps: uint256 = 100
    self._withdraw_with_slippage(token_id, slippage_bps)

@external
def withdraw_with_slippage(token_id: uint256, slippage_bps: uint256):
    """
    Burns the specified NFT and swaps wstETH to ETH with user-specified slippage.
    @param token_id The NFT representing the deposit.
    @param slippage_bps Slippage tolerance in basis points (e.g., 100 = 1%).
    """
    assert self.owners[token_id] == msg.sender, "Not owner"
    assert self.token_data[token_id].wsteth_amount > 0, "Invalid token"
    assert slippage_bps >= MIN_SLIPPAGE_BPS, "Slippage too low"
    assert slippage_bps <= MAX_SLIPPAGE_BPS, "Slippage too high"

    # Check ETH/USD oracle
    oracle_eth: AggregatorV3Interface = AggregatorV3Interface(PRICE_FEED_ETH_USD)
    (round_id_e, answer_e, started_at_e, updated_at_e, answered_in_round_e) = oracle_eth.latestRoundData()
    assert answer_e > 0, "Invalid ETH/USD price"
    assert block.timestamp <= updated_at_e + MAX_ORACLE_AGE, "ETH/USD oracle too old"
    current_price: uint256 = convert(answer_e, uint256)
    assert current_price > self.token_data[token_id].price_usd, "Oracle price too low"

    self._withdraw_with_slippage(token_id, slippage_bps)

@internal
def _withdraw_with_slippage(token_id: uint256, slippage_bps: uint256):
    """
    Internal function to burn NFT and swap wstETH to ETH.
    """
    owner: address = self.owners[token_id]
    wsteth_amount: uint256 = self.token_data[token_id].wsteth_amount

    # Burn NFT
    self._burn(token_id)

    # Check wstETH/ETH oracle
    oracle_wsteth: AggregatorV3Interface = AggregatorV3Interface(PRICE_FEED_WSTETH_ETH)
    (round_id_w, answer_w, started_at_w, updated_at_w, answered_in_round_w) = oracle_wsteth.latestRoundData()
    assert answer_w > 0, "Invalid wstETH/ETH price"
    assert block.timestamp <= updated_at_w + MAX_ORACLE_AGE, "wstETH/ETH oracle too old"
    wsteth_per_eth: uint256 = convert(answer_w, uint256)

    # Estimate minimum ETH output
    eth_per_wsteth: uint256 = (10**36) / wsteth_per_eth
    min_eth_out: uint256 = (wsteth_amount * eth_per_wsteth) / 10**18
    min_eth_out = min_eth_out * (BPS_DENOMINATOR - slippage_bps) / BPS_DENOMINATOR

    # Approve 1inch router to spend wstETH
    raw_call(
        WSTETH,
        method_id("approve(address,uint256)", bytes[4]) +
        convert(INCH_ROUTER, bytes32) +
        convert(wsteth_amount, bytes32),
        is_delegate_call=False
    )

    # Swap wstETH to ETH via 1inch
    router: OneInchRouter = OneInchRouter(INCH_ROUTER)
    desc: SwapDescription = SwapDescription({
        srcToken: WSTETH,
        dstToken: empty(address),  # ETH
        srcReceiver: self,
        dstReceiver: owner,
        amount: wsteth_amount,
        minReturnAmount: min_eth_out,
        flags: 0  # Default flags
    })
    (return_amount, spent_amount) = router.swap(empty(address), desc, b"", b"")
    eth_received: uint256 = return_amount

    log Withdraw(owner, token_id, eth_received, wsteth_amount, slippage_bps)

@external
def emergency_withdraw(token_id: uint256):
    """
    Allows admin to burn an NFT and return wstETH to its owner.
    @param token_id The NFT to withdraw.
    """
    assert msg.sender == admin, "Only admin can call"
    assert self.token_data[token_id].wsteth_amount > 0, "Invalid token"

    owner: address = self.owners[token_id]
    wsteth_amount: uint256 = self.token_data[token_id].wsteth_amount

    # Burn NFT
    self._burn(token_id)

    # Transfer wstETH
    ERC20(WSTETH).transfer(owner, wsteth_amount)
    log EmergencyWithdraw(owner, token_id, wsteth_amount, msg.sender)

@external
def emergency_withdraw_batch(token_ids: uint256[MAX_BATCH_SIZE]):
    """
    Allows admin to burn multiple NFTs and return wstETH to owners.
    @param token_ids Array of NFT token IDs (up to MAX_BATCH_SIZE).
    """
    assert msg.sender == admin, "Only admin can call"

    for i in range(MAX_BATCH_SIZE):
        token_id: uint256 = token_ids[i]
        if token_id == 0 and i > 0:  # Allow 0 as terminator
            break
        if self.token_data[token_id].wsteth_amount == 0:
            continue
        owner: address = self.owners[token_id]
        wsteth_amount: uint256 = self.token_data[token_id].wsteth_amount
        self._burn(token_id)
        ERC20(WSTETH).transfer(owner, wsteth_amount)
        log EmergencyWithdraw(owner, token_id, wsteth_amount, msg.sender)

@internal
def _burn(token_id: uint256):
    """
    Burns an NFT, clearing its state.
    """
    owner: address = self.owners[token_id]
    assert owner != empty(address), "Token does not exist"

    # Clear approvals
    self.approvals[token_id] = empty(address)

    # Update owned tokens
    index: uint256 = self.owned_tokens_index[owner][token_id]
    last_index: uint256 = self.balances[owner] - 1
    if index != last_index:
        last_token_id: uint256 = self.owned_tokens[owner][last_index]
        self.owned_tokens[owner][index] = last_token_id
        self.owned_tokens_index[owner][last_token_id] = index
    self.owned_tokens[owner][last_index] = 0
    self.owned_tokens_index[owner][token_id] = 0

    # Clear state
    self.balances[owner] -= 1
    self.owners[token_id] = empty(address)
    self.token_data[token_id] = DepositData({wsteth_amount: 0, price_usd: 0})

    log Transfer(owner, empty(address), token_id)

@external
def transferFrom(from_addr: address, to_addr: address, token_id: uint256):
    """
    Transfers an NFT from one address to another.
    @param from_addr The current owner.
    @param to_addr The new owner.
    @param token_id The NFT to transfer.
    """
    assert self.owners[token_id] == from_addr, "Not owner"
    assert to_addr != empty(address), "Invalid recipient"
    assert msg.sender == from_addr or msg.sender == self.approvals[token_id], "Not authorized"

    # Clear approval
    self.approvals[token_id] = empty(address)

    # Update ownership
    self.owners[token_id] = to_addr
    self.balances[from_addr] -= 1
    self.balances[to_addr] += 1

    # Update owned tokens
    index: uint256 = self.owned_tokens_index[from_addr][token_id]
    last_index: uint256 = self.balances[from_addr]
    if index != last_index:
        last_token_id: uint256 = self.owned_tokens[from_addr][last_index]
        self.owned_tokens[from_addr][index] = last_token_id
        self.owned_tokens_index[from_addr][last_token_id] = index
    self.owned_tokens[from_addr][last_index] = 0
    self.owned_tokens_index[from_addr][token_id] = 0

    new_index: uint256 = self.balances[to_addr] - 1
    self.owned_tokens[to_addr][new_index] = token_id
    self.owned_tokens_index[to_addr][token_id] = new_index

    log Transfer(from_addr, to_addr, token_id)

@external
def approve(approved: address, token_id: uint256):
    """
    Approves an address to transfer an NFT.
    @param approved The address to approve.
    @param token_id The NFT to approve.
    """
    assert self.owners[token_id] == msg.sender, "Not owner"
    self.approvals[token_id] = approved
    log Approval(msg.sender, approved, token_id)

@external
@view
def ownerOf(token_id: uint256) -> address:
    """
    Returns the owner of an NFT.
    @param token_id The NFT to query.
    @return The owner's address.
    """
    owner: address = self.owners[token_id]
    assert owner != empty(address), "Token does not exist"
    return owner

@external
@view
def balanceOf(owner: address) -> uint256:
    """
    Returns the number of NFTs owned by an address.
    @param owner The address to query.
    @return The number of NFTs.
    """
    assert owner != empty(address), "Invalid address"
    return self.balances[owner]

@external
@view
def tokenOfOwnerByIndex(owner: address, index: uint256) -> uint256:
    """
    Returns the tokenId at a given index for an owner.
    @param owner The address to query.
    @param index The index to query.
    @return The tokenId.
    """
    assert index < self.balances[owner], "Index out of bounds"
    return self.owned_tokens[owner][index]

@external
@view
def get_deposit_data(token_id: uint256) -> DepositData:
    """
    Returns the deposit data for an NFT.
    @param token_id The NFT to query.
    @return The deposit data (wsteth_amount, price_usd).
    """
    assert self.token_data[token_id].wsteth_amount > 0, "Invalid token"
    return self.token_data[token_id]

@external
@view
def get_latest_oracle_price() -> uint256:
    """
    Returns the latest ETH/USD price from the Chainlink oracle.
    @return The price scaled by 10**8.
    """
    oracle: AggregatorV3Interface = AggregatorV3Interface(PRICE_FEED_ETH_USD)
    (round_id, answer, started_at, updated_at, answered_in_round) = oracle.latestRoundData()
    assert answer > 0, "Invalid ETH/USD price"
    assert block.timestamp <= updated_at + MAX_ORACLE_AGE, "ETH/USD oracle too old"
    return convert(answer, uint256)

@external
@payable
def __default__():
    """
    Fallback to receive ETH from 1inch swaps.
    """
    pass