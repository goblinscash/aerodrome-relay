## Deploy Relay

Velodrome Relay deployment is completely trustless and there is no access control within any of the
contracts deployed. As such, any address can deploy the contracts and have them integrated within
the protocol without risk.

How is this done? The only access control needed in creating a Relay is in the ownership of a
(m)veNFT (Managed veNFT). The (m)veNFT is transferred to the Relay at creation where it permanently
resides.

### Environment setup

1. `cp .env.sample .env` and set the environment variables. `PRIVATE_KEY_DEPLOY` is the private key
   used in contract deployment.

2. `cp script/constants/TEMPLATE.json script/constants/{CONSTANTS_FILENAME}`. For example, if you
   have `CONSTANTS_FILENAME="Optimism.json"` within the .env you would create a file of
   `script/constants/Optimism.json`. Set the variables in the new constants file.

3. Run tests to ensure deployment state is configured correctly:

```ml
forge init
forge build
forge test
```

\*Note that this will create a `script/constants/output/{OUTPUT_FILENAME}` file with the contract
addresses created in testing. If you are using the same constants for multiple deployments (for
example, deploying in a local fork and then in prod), you can rename `OUTPUT_FILENAME` in the .env
to store the new contract addresses while using the same constants.

4. Ensure all deployments are set properly. In project directory terminal:

```
source .env
```

### Deployment

#### Base

```
forge script script/DeployBase.s.sol:Deploy --broadcast --slow --rpc-url bsc --verify -vvvv
forge script script/DeployAutoConverter.s.sol:DeployAutoConverter --broadcast --slow --rpc-url bsc --verify -vvvv
```

#### Tenderly

Foundry does not automatically verify contracts within Tenderly. To test with tenderly, you will
need to use hardhat. Specifically, you will need to modify `hardhat.config.ts` with your correct
`tenderly` object. If you are using Tenderly devnet, you will need to set `TENDERLY_DEVNET_TEMPLATE`
and `TENDERLY_DEVNET` in the .env. `TENDERLY_DEVNET_TEMPLATE` is the name of the devnet template you
are using. `TENDERLY_DEVNET` is the auto-generated key for the template when you select "Spawn
DevNet" within the template. It will look something like `d81265d8-1bad-457c-13da-0a51e815ae54`. For
more information on Tenderly devnets, see [here](https://docs.tenderly.co/devnets/intro-to-devnets).
For a forked environment instead of a devnet, you will need to set `TENDERLY_FORK_ID` in the .env.

```
npm install
npx hardhat compile
npx hardhat run script/hardhat/Deploy.ts --network devnet
npx hardhat run script/hardhat/DeployAutoConverter.ts --network devnet
```

Note that the output file is hardcoded within `Deploy.ts` to `Tenderly.json` and
`DeployAutoConverter.ts` to `TenderlyAutoConverter.json`.

For additional support with Tenderly deployment, see their
[docs](https://github.com/Tenderly/hardhat-tenderly/tree/master/packages/tenderly-hardhat).

#### Other chains

Note that if deploying to a chain other than Optimism, if you have a different .env variable name
used for `RPC_URL`, `SCAN_API_KEY` and `ETHERSCAN_VERIFIER_URL`, you will need to use the
corresponding chain name by also updating `foundry.toml`.


Relay deployment:

Use safe transaction builder and execute the following 3 transactions with proper arguments.

1) mTokenId = escrow.createManagedLockFor(address(owner));
2) escrow.approve(address(autoConverterFactory), mTokenId);
3) autoConverterFactory.createRelay(address(owner), mTokenId, "AutoConverter", abi.encode(address(token)))

Relay verification:

```
# autocompounder
forge verify-contract --rpc-url bsc --watch --constructor-args $(cast abi-encode "constructor(address,address,string,address,address,address)" "0xeA5BAB4AdCe8cfEf9BAFDca2cDdBBD0BFF169855" "0x7853A6D5f4c6797700F77f0c2Ed21C4C84D63ba1" "Autocompounder" "0x38a6c73B953D836eF862293b6B672bAf656E96c5" "0xa854ac5596bb765Fb368238fE1b119D35C05903a" "0x4D3c2f4d98a05B74628B73f8091c88a4027D19e8")  0x7327a84F535528BE1Ca24901476F91b8Ea953C06 src/autoCompounder/AutoCompounder.sol:AutoCompounder

# converter for tUSDT
forge verify-contract --rpc-url bsc --watch --constructor-args $(cast abi-encode "constructor(address,address,string,address,address,address,address)" "0xeA5BAB4AdCe8cfEf9BAFDca2cDdBBD0BFF169855" "0x7853A6D5f4c6797700F77f0c2Ed21C4C84D63ba1" "USDT Autoconverter" "0x38a6c73B953D836eF862293b6B672bAf656E96c5" "0xa44319D6232afEAa21A38b040Ca095110ad76d38" "0xa854ac5596bb765Fb368238fE1b119D35C05903a" "0x807B76a14d94821b56a0e05e8C1C6Fb077aE01F2") 0x6252e51678Eb8bbE3E2107882836F710F7777994 src/autoConverter/AutoConverter.sol:AutoConverter
```
