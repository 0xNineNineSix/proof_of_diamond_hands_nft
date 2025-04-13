from web3 import Web3
import json
import os
import subprocess
from dotenv import load_dotenv

load_dotenv()

w3 = Web3(Web3.HTTPProvider(os.environ.get('TESTNET_URL')))
if not w3.is_connected():
    raise Exception("Failed to connect to Ethereum node")

private_key = os.environ.get('PRIVATE_KEY')
account = w3.eth.account.from_key(private_key)
w3.eth.default_account = account.address

admin_address = account.address

contract_path = 'contracts/eth_vault.vy'
with open(contract_path, 'r') as f:
    bytecode = subprocess.check_output(['vyper', contract_path]).decode().strip()

abi_path = 'scripts/eth_vault.json'
with open(abi_path, 'w') as f:
    subprocess.run(['vyper', '-f', 'abi', contract_path], stdout=f)

with open(abi_path, 'r') as f:
    abi = json.load(f)

contract = w3.eth.contract(abi=abi, bytecode=bytecode)
tx_hash = contract.constructor(admin_address).transact({'gas': 5000000})
tx_receipt = w3.eth.wait_for_transaction_receipt(tx_hash)
print(f"Contract deployed at: {tx_receipt.contractAddress}")

with open('scripts/contract_address.txt', 'w') as f:
    f.write(tx_receipt.contractAddress)