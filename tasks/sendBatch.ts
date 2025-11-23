import { ContractTransaction } from 'ethers'
import { task, types } from 'hardhat/config'
import { HardhatRuntimeEnvironment } from 'hardhat/types'

import { createLogger } from '@layerzerolabs/io-devtools'
import { endpointIdToNetwork } from '@layerzerolabs/lz-definitions'

const logger = createLogger()

enum KnownErrors {
    ERROR_GETTING_DEPLOYMENT = 'ERROR_GETTING_DEPLOYMENT',
    ERROR_QUOTING_GAS_COST = 'ERROR_QUOTING_GAS_COST',
    ERROR_SENDING_TRANSACTION = 'ERROR_SENDING_TRANSACTION',
}

enum KnownOutputs {
    SENT_VIA_OAPP = 'SENT_VIA_OAPP',
    TX_HASH = 'TX_HASH',
    EXPLORER_LINK = 'EXPLORER_LINK',
}

task('lz:oapp:sendBatch', 'Sends a string cross‐chain to multiple destinations using MyOApp contract')
    .addParam('dstEids', 'Comma-separated destination endpoint IDs', undefined, types.string)
    .addParam('string', 'String to send', undefined, types.string)
    .addOptionalParam('options', 'Execution options (hex string)', '0x', types.string)
    .setAction(async (args: { dstEids: string; string: string; options?: string }, hre: HardhatRuntimeEnvironment) => {
        // Parse destination EIDs
        const dstEids = args.dstEids.split(',').map((id) => parseInt(id.trim()))
        const networks = dstEids.map((eid) => endpointIdToNetwork(eid) || `Unknown EID ${eid}`)

        logger.info(`Initiating batch string send from ${hre.network.name} to ${networks.join(', ')}`)
        logger.info(`String to send: "${args.string}"`)
        logger.info(`Destination EIDs: ${dstEids.join(', ')}`)

        const [signer] = await hre.ethers.getSigners()
        logger.info(`Using signer: ${signer.address}`)

        let myOAppContract
        let contractAddress: string
        try {
            const myOAppDeployment = await hre.deployments.get('MyOApp')
            contractAddress = myOAppDeployment.address
            myOAppContract = await hre.ethers.getContractAt('MyOApp', contractAddress, signer)
            logger.info(`MyOApp contract found at: ${contractAddress}`)
        } catch (error) {
            logger.error(`❌ ${KnownErrors.ERROR_GETTING_DEPLOYMENT}: Failed to get MyOApp deployment on network: ${hre.network.name}`)
            throw error
        }

        const options = args.options || '0x'
        logger.info(`Execution options: ${options}`)

        // 1️⃣ Quote the gas cost
        logger.info('Quoting gas cost for the batch send transaction...')
        let messagingFee
        try {
            // MyOApp.quote(uint32[] _dstEids, uint16 _msgType, string _message, bytes _extraSendOptions, bool _payInLzToken)
            // _msgType is constant SEND = 1
            messagingFee = await myOAppContract.quote(
                dstEids,
                1, // SEND
                args.string,
                options,
                false // payInLzToken
            )
            logger.info(`  Native fee: ${hre.ethers.utils.formatEther(messagingFee.nativeFee)} ETH`)
            logger.info(`  LZ token fee: ${messagingFee.lzTokenFee.toString()} LZ`)
        } catch (error) {
            logger.error(`❌ ${KnownErrors.ERROR_QUOTING_GAS_COST}: Failed to quote for destinations: ${dstEids.join(', ')}`)
            throw error
        }

        // 2️⃣ Send the string
        logger.info('Sending the batch transaction...')
        let tx: ContractTransaction
        try {
            // MyOApp.send(uint32[] _dstEids, uint16 _msgType, string _message, bytes _extraSendOptions)
            tx = await myOAppContract.send(dstEids, 1, args.string, options, {
                value: messagingFee.nativeFee,
            })
            logger.info(`  Transaction hash: ${tx.hash}`)
        } catch (error) {
            logger.error(`❌ ${KnownErrors.ERROR_SENDING_TRANSACTION}: Failed to send to destinations: ${dstEids.join(', ')}`)
            throw error
        }

        // 3️⃣ Wait for confirmation
        logger.info('Waiting for transaction confirmation...')
        const receipt = await tx.wait()
        logger.info(`  Gas used: ${receipt.gasUsed.toString()}`)
        logger.info(`  Block number: ${receipt.blockNumber}`)

        // 4️⃣ Success messaging
        logger.info(`✅ ${KnownOutputs.SENT_VIA_OAPP}: Successfully sent batch message "${args.string}"`)
        
        return {
            txHash: receipt.transactionHash,
            blockNumber: receipt.blockNumber,
            gasUsed: receipt.gasUsed.toString(),
        }
    })

