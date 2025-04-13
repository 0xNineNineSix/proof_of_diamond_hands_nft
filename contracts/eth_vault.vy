# @version ^0.3.7

# Chainlink Aggregator V3 Interface
interface AggregatorV3Interface:
    def latestRoundData() -> (uint80, int256, uint256, uint256, uint80): view

# Uniswap V3 Swap Router Interface
interface UniswapV3Router:
    def exactInputSingle(params: ExactInputSingleParams) -> uint256: nonpayable

# ERC-20 Interface for wstETH transfers
interface ERC20:
    def transfer(to: address, amount: uint256) -> bool: nonpayable

# Struct for Uniswap V3 exactInputSingle parameters
struct ExactInputSingleParams:
    tokenIn: address
    tokenOut: address
    fee: uint24
    recipient: address
    deadline: uint256
    amountIn: uint256
    amountOutMinimum: uint256
    sqrtPriceLimitX96: uint160

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
UNISWAP_ROUTER: constant(address) = 0xE592427A0AEce92De3Edee1F18E0157C05861564  # Uniswap V3 SwapRouter
WSTETH: constant(address) = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0  # Lido wstETH

# Minimum and maximum deposit amounts (in wei)
MIN_DEPOSIT: constant(uint256) = 100000000000000000  # 0.1 ETH
MAX_DEPOSIT: constant(uint256) = 100000000000000000000  # 100 ETH

# Uniswap V3 pool fee (0.01% for ETH/wstETH pair)
UNISWAP_FEE: constant(uint24) = 100

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
    Swaps ETH to wstETH, mints an NFT with deposit data, only if no existing balance.
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

    # Swap ETH to wstETH
    router: UniswapV3Router = UniswapV3Router(UNISWAP_ROUTER)
    params: ExactInputSingleParams = ExactInputSingleParams({
        tokenIn: empty(address),
        tokenOut: WSTETH,
        fee: UNISWAP_FEE,
        recipient: self,
        deadline: block.timestamp + 15,
        amountIn: swap_amount,
        amountOutMinimum: min_wsteth_out,
        sqrtPriceLimitX96: 0
    })
    wsteth_received: uint256 = router.exactInputSingle(params)

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