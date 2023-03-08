module token_bridge_relayer::transfer {
    use sui::sui::SUI;
    use sui::coin::{Self, Coin};
    use sui::transfer::{Self};
    use sui::tx_context::{Self, TxContext};

    use token_bridge::normalized_amount::{from_raw, to_raw};
    use token_bridge::state::{State as TokenBridgeState, coin_decimals};
    use token_bridge::transfer_tokens_with_payload::{transfer_tokens_with_payload};
    use token_bridge::complete_transfer_with_payload::{
        complete_transfer_with_payload
    };
    use token_bridge::transfer_with_payload::{payload, sender};

    use wormhole::external_address::{
        left_pad as make_external,
        to_address
    };
    use wormhole::state::{State as WormholeState};

    use token_bridge_relayer::bytes32::{Self};
    use token_bridge_relayer::message::{Self};
    use token_bridge_relayer::state::{Self, State};

    // Errors.
    const E_INVALID_TARGET_RECIPIENT: u64 = 0;
    const E_UNREGISTERED_FOREIGN_CONTRACT: u64 = 1;
    const E_INSUFFICIENT_AMOUNT: u64 = 2;

    /// Transfers specified coins to any registered Hello Token contract by
    /// invoking the `transfer_tokens_with_payload` method on the Wormhole
    /// Token Bridge contract. `transfer_tokens_with_payload` allows the caller
    /// to send an arbitrary message payload along with a token transfer. In
    /// this case, the arbitrary message includes the transfer recipient's
    /// target-chain wallet address.
    public entry fun send_tokens_with_payload<C>(
        t_state: &State,
        wormhole_state: &mut WormholeState,
        token_bridge_state: &mut TokenBridgeState,
        coins: Coin<C>,
        wormhole_fee: Coin<SUI>,
        target_chain: u16,
        batch_id: u32,
        target_recipient: vector<u8>,
        ctx: &mut TxContext
    ) {
        // Confirm that the target chain has a registered contract.
        assert!(
            state::contract_registered(t_state, target_chain),
            E_UNREGISTERED_FOREIGN_CONTRACT
        );
        let foreign_contract =
            state::foreign_contract_address(t_state, target_chain);

        // When we create the message, `target_recipient` cannot be the zero
        // address.
        let msg = message::from_bytes(target_recipient);

        // Fetch the token decimals from the token bridge,
        // and cache the token amount.
        let decimals = coin_decimals<C>(token_bridge_state);
        let amount_received = coin::value(&coins);

        // Compute the truncated token amount.
        let transformed_amount = to_raw(
            from_raw(
                amount_received,
                decimals
            ),
            decimals
        );
        assert!(transformed_amount > 0, E_INSUFFICIENT_AMOUNT);

        // Split the coins object and send dust back to the user if
        // the `transformed_amount` is less the original amount.
        let coins_to_transfer;
        if (transformed_amount < amount_received){
            coins_to_transfer = coin::split(&mut coins, transformed_amount, ctx);

            // Return the original object with the dust.
            transfer::transfer(coins, tx_context::sender(ctx))
        } else {
            coins_to_transfer = coins;
        };

        // Finally transfer tokens via Token Bridge.
        transfer_tokens_with_payload(
            state::emitter_cap(t_state),
            wormhole_state,
            token_bridge_state,
            coins_to_transfer,
            wormhole_fee,
            target_chain,
            make_external(&bytes32::data(foreign_contract)),
            batch_id,
            message::encode(&msg)
        );
    }

    /// Consumes `transfer_with_payload` Wormhole message from a registered
    /// foreign contract. Sends the transferred tokens to the recipient encoded
    /// in the additional payload, and pays the relayer a fee if the user is
    /// not self redeeming the transfer.
    public entry fun redeem_transfer_with_payload<C>(
        t_state: &State,
        wormhole_state: &mut WormholeState,
        token_bridge_state: &mut TokenBridgeState,
        vaa: vector<u8>,
        ctx: &mut TxContext
     ) {
        // Complete the transfer on the Token Bridge. This call returns the
        // coin object for the amount transferred via the Token Bridge. It
        // also returns the chain ID of the message sender.
        let (coins, transfer_payload, emitter_chain_id) =
            complete_transfer_with_payload<C>(
                token_bridge_state,
                state::emitter_cap(t_state),
                wormhole_state,
                vaa,
                ctx
            );

        // Confirm that the emitter is a registered contract.
        assert!(
            *state::foreign_contract_address(
                t_state,
                emitter_chain_id
            ) == bytes32::from_external_address(
                &sender(&transfer_payload)
            ),
            E_UNREGISTERED_FOREIGN_CONTRACT
        );

        // Parse the additional payload.
        let msg = message::decode(payload(&transfer_payload));

        // Parse the recipient field.
        let recipient = to_address(
            &make_external(&bytes32::data(message::recipient(&msg)))
        );

        // Calculate the relayer fee.
        let relayer_fee = 0; /*state::compute_relayer_fee(
            t_state,
            coin::value(&coins)
        );*/

        // If the relayer fee is nonzero and the user is not self redeeming,
        // split the coins object and transfer the relayer fee to the signer.
        if (relayer_fee > 0 && recipient != tx_context::sender(ctx)) {
            let coins_for_relayer = coin::split(&mut coins, relayer_fee, ctx);

            // Send the caller the relayer fee.
            transfer::transfer(coins_for_relayer, tx_context::sender(ctx));
        };

        // Send the coins to the target recipient.
        transfer::transfer(coins, recipient);
    }
}

// #[test_only]
// module token_bridge_relayer::transfer_tests {
//     use std::vector::{Self};

//     use sui::sui::SUI;
//     use sui::test_scenario::{Self};
//     use sui::coin::{Self, Coin, CoinMetadata};
//     use sui::object::{Self};
//     use sui::transfer::{Self as native_transfer};
//     use sui::tx_context::{TxContext};

//     use token_bridge_relayer::owner::{Self, OwnerCap};
//     use token_bridge_relayer::transfer::{Self};
//     use token_bridge_relayer::state::{State};
//     use token_bridge_relayer::init_tests::{set_up, people};

//     use wormhole::state::{
//         Self as wormhole_state_module,
//         State as WormholeState
//     };

//     use token_bridge::state::{State as BridgeState, deposit_test_only};
//     use token_bridge::attest_token::{Self};

//     // Example coins.
//     use example_coins::coin_8::{Self};
//     use example_coins::coin_9::{Self};

//     // Updating these constants will alter the results of the tests.
//     const TEST_TOKEN_8_SUPPLY: u64 = 42069;
//     const TEST_INSUFFICIENT_TOKEN_9_SUPPLY: u64 = 1;
//     const TEST_SUI_SUPPLY: u64 = 69420;
//     const TEST_RELAYER_FEE: u64 = 42069; // 4.2069%
//     const TEST_RELAYER_FEE_PRECISION: u64 = 1000000;
//     const TEST_TOKEN_9_SUPPLY: u64 = 12345678910111;
//     const TEST_TOKEN_9_EXPECTED_DUST: u64 = 1;

//     // `transfer_with_payload` VAA #1.
//     const REDEEM_ONE_TRANSFER_VAA: vector<u8> = x"010000000001004a74c709640a12a959f848feece876c91a145ba2cec17ee742d7abc7de10b10b1ceba838814ebd431a73a07cabe788d78b9dcf9d25a553d64fe8b324db60bf9e0063ec0bd800000000000200000000000000000000000000000000000000000000000000000000000000450000000000000000010300000000000000000000000000000000000000000000000000000000000000450000000000000000000000000000000000000000000000000000000000000001001500000000000000000000000000000000000000000000000000000000000000030015000000000000000000000000000000000000000000000000000000000000005901000000000000000000000000000000000000000000000000000000000000beef";
//     const REDEEM_ONE_AMOUNT: u64 = 69;
//     const REDEEM_ONE_RELAYER_FEE: u64 = 2;

//     // `transfer_with_payload` VAA #2.
//     const REDEEM_TWO_TRANSFER_VAA: vector<u8> = x"010000000001002e6c00b81c59b5c5d0760ed95092cf681a2f10ee0c6e285ef4af5cbc835c3716560231184fefb535e0c6dd2f37542ede6f84d727cc70e580cb4fe515e50198700163ecf6db00000000000200000000000000000000000000000000000000000000000000000000000000450000000000000000010300000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000001001500000000000000000000000000000000000000000000000000000000000000030015000000000000000000000000000000000000000000000000000000000000005901000000000000000000000000000000000000000000000000000000000000beef";
//     const REDEEM_TWO_AMOUNT: u64 = 1;

//     // `transfer_with_payload` VAA #3.
//     const REDEEM_THREE_TRANSFER_VAA: vector<u8> = x"010000000001006122c3abc84325a7f8454e168bee3e56a2926d1f61e5d45a8dc732b9f56fbd061722b7f14a90b91001960d987344b763906b19cc7be56a1ece1637e8ff1d68c00163ed0b1f000000000002000000000000000000000000000000000000000000000000000000000000004500000000000000000103000000000000000000000000000000000000000000000000fffffffffffffffe0000000000000000000000000000000000000000000000000000000000000001001500000000000000000000000000000000000000000000000000000000000000030015000000000000000000000000000000000000000000000000000000000000005901000000000000000000000000000000000000000000000000000000000000beef";
//     const REDEEM_THREE_AMOUNT: u64 = 18446744073709551614;
//     const REDEEM_THREE_RELAYER_FEE: u64 = 776036076436887126;

//     #[test]
//     /// This test transfers tokens with an additional payload using example coin 8
//     /// (which has 8 decimals).
//     public fun send_tokens_with_payload_coin_8() {
//         let (creator, _) = people();
//         let (my_scenario, _) = set_up(creator);
//         let scenario = &mut my_scenario;

//         // Create target contract variables.
//         let target_chain: u16 = 69;
//         let target_contract =
//             x"0000000000000000000000000000000000000000000000000000000000000069";

//         // Fetch state objects.
//         let token_bridge_relayer_state =
//             test_scenario::take_shared<State>(scenario);
//         let bridge_state =
//             test_scenario::take_shared<BridgeState>(scenario);
//         let wormhole_state =
//             test_scenario::take_shared<WormholeState>(scenario);

//         // Mint token 8, fetch the metadata and store the object ID for later.
//         let (test_coin, test_metadata) = mint_coin_8(
//             TEST_TOKEN_8_SUPPLY,
//             test_scenario::ctx(scenario)
//         );
//         test_scenario::next_tx(scenario, creator);

//         // Mint SUI token amount based on the wormhole fee.
//         let sui_coin = mint_sui(
//             wormhole_state_module::get_message_fee(&wormhole_state),
//             test_scenario::ctx(scenario)
//         );
//         test_scenario::next_tx(scenario, creator);

//         // Register the target contract.
//         {
//             let owner_cap =
//                 test_scenario::take_from_sender<OwnerCap>(scenario);

//             owner::register_foreign_contract(
//                 &owner_cap,
//                 &mut token_bridge_relayer_state,
//                 target_chain,
//                 target_contract
//             );

//             // Bye bye.
//             test_scenario::return_to_sender<OwnerCap>(scenario, owner_cap);

//             // Proceed.
//             test_scenario::next_tx(scenario, creator);
//         };

//         // Attest the token.
//         {
//             let fee_coin = mint_sui(
//                 wormhole_state_module::get_message_fee(&wormhole_state),
//                 test_scenario::ctx(scenario)
//             );

//             attest_token::attest_token(
//                 &mut bridge_state,
//                 &mut wormhole_state,
//                 &test_metadata,
//                 fee_coin,
//                 0, // batch ID
//                 test_scenario::ctx(scenario)
//             );

//             // Proceed.
//             test_scenario::next_tx(scenario, creator);
//         };

//         // Send a test transfer.
//         transfer::send_tokens_with_payload(
//             &token_bridge_relayer_state,
//             &mut wormhole_state,
//             &mut bridge_state,
//             test_coin,
//             sui_coin,
//             69,
//             0,
//             x"000000000000000000000000beFA429d57cD18b7F8A4d91A2da9AB4AF05d0FBe",
//             test_scenario::ctx(scenario)
//         );

//         // Return the goods.
//         test_scenario::return_shared<State>(token_bridge_relayer_state);
//         test_scenario::return_shared<BridgeState>(bridge_state);
//         test_scenario::return_shared<WormholeState>(wormhole_state);
//         native_transfer::transfer(test_metadata, @0x0);

//         // Done.
//         test_scenario::end(my_scenario);
//     }

//     #[test]
//     /// This test transfers tokens with an additional payload using example coin 9
//     /// (which has 9 decimals).
//     public fun send_tokens_with_payload_coin_9() {
//         let (creator, _) = people();
//         let (my_scenario, _) = set_up(creator);
//         let scenario = &mut my_scenario;

//         // Create target contract variables.
//         let target_chain: u16 = 69;
//         let target_contract =
//             x"0000000000000000000000000000000000000000000000000000000000000069";

//         // Fetch state objects.
//         let token_bridge_relayer_state =
//             test_scenario::take_shared<State>(scenario);
//         let bridge_state =
//             test_scenario::take_shared<BridgeState>(scenario);
//         let wormhole_state =
//             test_scenario::take_shared<WormholeState>(scenario);

//         // Mint token 9, fetch the metadata and store the object ID for later.
//         let (test_coin, test_metadata) = mint_coin_9(
//             TEST_TOKEN_9_SUPPLY,
//             test_scenario::ctx(scenario)
//         );
//         test_scenario::next_tx(scenario, creator);

//         // Store test coin ID for later use.
//         let test_coin_id = object::id(&test_coin);

//         // Mint SUI token amount based on the wormhole fee.
//         let sui_coin = mint_sui(
//             wormhole_state_module::get_message_fee(&wormhole_state),
//             test_scenario::ctx(scenario)
//         );
//         test_scenario::next_tx(scenario, creator);

//         // Register the target contract.
//         {
//             let owner_cap =
//                 test_scenario::take_from_sender<OwnerCap>(scenario);

//             owner::register_foreign_contract(
//                 &owner_cap,
//                 &mut token_bridge_relayer_state,
//                 target_chain,
//                 target_contract
//             );

//             // Proceed.
//             test_scenario::next_tx(scenario, creator);

//             // Bye bye.
//             test_scenario::return_to_sender<OwnerCap>(scenario, owner_cap);
//         };

//         // Attest the token.
//         {
//             let fee_coin = mint_sui(
//                 wormhole_state_module::get_message_fee(&wormhole_state),
//                 test_scenario::ctx(scenario)
//             );

//             attest_token::attest_token(
//                 &mut bridge_state,
//                 &mut wormhole_state,
//                 &test_metadata,
//                 fee_coin,
//                 0, // batch ID
//                 test_scenario::ctx(scenario)
//             );

//             // Proceed.
//             test_scenario::next_tx(scenario, creator);
//         };

//         // Send a test transfer. Since the Token Bridge truncates transfer
//         // amounts for tokens with greater than 9 decimals, we should expect
//         // to receive a coin object representing the dust sent to the signer.
//         {
//             transfer::send_tokens_with_payload(
//                 &token_bridge_relayer_state,
//                 &mut wormhole_state,
//                 &mut bridge_state,
//                 test_coin,
//                 sui_coin,
//                 69,
//                 0,
//                 x"000000000000000000000000beFA429d57cD18b7F8A4d91A2da9AB4AF05d0FBe",
//                 test_scenario::ctx(scenario)
//             );

//             // Proceed.
//             test_scenario::next_tx(scenario, creator);

//             // Fetch the dust coin object.
//             let dust_object =
//                 test_scenario::take_from_sender_by_id<Coin<coin_9::COIN_9>>(
//                     scenario,
//                     test_coin_id
//                 );

//             // Confirm that the value of the token is non-zero.
//             assert!(coin::value(&dust_object) == TEST_TOKEN_9_EXPECTED_DUST, 0);

//             // Bye bye.
//             test_scenario::return_to_sender(scenario, dust_object);
//         };

//         // Return the goods.
//         test_scenario::return_shared<State>(token_bridge_relayer_state);
//         test_scenario::return_shared<BridgeState>(bridge_state);
//         test_scenario::return_shared<WormholeState>(wormhole_state);
//         native_transfer::transfer(test_metadata, @0x0);

//         // Done.
//         test_scenario::end(my_scenario);
//     }

//     #[test]
//     #[expected_failure(abort_code = 2, location=transfer)]
//     /// This test confirms that the Hello Token contract will revert if the
//     /// amount is not large enough to transfer through the Token Bridge.
//     public fun cannot_send_tokens_with_payload_coin_9_insufficient_amount() {
//         let (creator, _) = people();
//         let (my_scenario, _) = set_up(creator);
//         let scenario = &mut my_scenario;

//         // Create target contract variables.
//         let target_chain: u16 = 69;
//         let target_contract =
//             x"0000000000000000000000000000000000000000000000000000000000000069";

//         // Fetch state objects.
//         let token_bridge_relayer_state =
//             test_scenario::take_shared<State>(scenario);
//         let bridge_state =
//             test_scenario::take_shared<BridgeState>(scenario);
//         let wormhole_state =
//             test_scenario::take_shared<WormholeState>(scenario);

//         // Mint token 9, fetch the metadata and store the object ID for later.
//         let (test_coin, test_metadata) = mint_coin_9(
//             TEST_INSUFFICIENT_TOKEN_9_SUPPLY,
//             test_scenario::ctx(scenario)
//         );
//         test_scenario::next_tx(scenario, creator);

//         // Mint SUI token amount based on the wormhole fee.
//         let sui_coin = mint_sui(
//             wormhole_state_module::get_message_fee(&wormhole_state),
//             test_scenario::ctx(scenario)
//         );
//         test_scenario::next_tx(scenario, creator);

//         // Register the target contract.
//         {
//             let owner_cap =
//                 test_scenario::take_from_sender<OwnerCap>(scenario);

//             owner::register_foreign_contract(
//                 &owner_cap,
//                 &mut token_bridge_relayer_state,
//                 target_chain,
//                 target_contract
//             );

//             // Bye bye.
//             test_scenario::return_to_sender<OwnerCap>(scenario, owner_cap);

//             // Proceed.
//             test_scenario::next_tx(scenario, creator);
//         };

//         // Attest the token.
//         {
//             let fee_coin = mint_sui(
//                 wormhole_state_module::get_message_fee(&wormhole_state),
//                 test_scenario::ctx(scenario)
//             );

//             attest_token::attest_token(
//                 &mut bridge_state,
//                 &mut wormhole_state,
//                 &test_metadata,
//                 fee_coin,
//                 0, // batch ID
//                 test_scenario::ctx(scenario)
//             );

//             // Proceed.
//             test_scenario::next_tx(scenario, creator);
//         };

//         // Send a test transfer.
//         transfer::send_tokens_with_payload(
//             &token_bridge_relayer_state,
//             &mut wormhole_state,
//             &mut bridge_state,
//             test_coin,
//             sui_coin,
//             69,
//             0,
//             x"000000000000000000000000beFA429d57cD18b7F8A4d91A2da9AB4AF05d0FBe",
//             test_scenario::ctx(scenario)
//         );

//         // Return the goods.
//         test_scenario::return_shared<State>(token_bridge_relayer_state);
//         test_scenario::return_shared<BridgeState>(bridge_state);
//         test_scenario::return_shared<WormholeState>(wormhole_state);
//         native_transfer::transfer(test_metadata, @0x0);

//         // Done.
//         test_scenario::end(my_scenario);
//     }

//     #[test]
//     #[expected_failure(abort_code = 1, location=transfer)]
//     /// This test confirms that the Hello Token contract will revert
//     /// if the specified target chain is not registered.
//     public fun cannot_send_tokens_with_payload_contract_not_registered() {
//         let (creator, _) = people();
//         let (my_scenario, _) = set_up(creator);
//         let scenario = &mut my_scenario;

//         // Mint token 8 and fetch the metadata.
//         let (test_coin, test_metadata) = mint_coin_8(
//             TEST_TOKEN_8_SUPPLY,
//             test_scenario::ctx(scenario)
//         );
//         test_scenario::next_tx(scenario, creator);

//         // Mint SUI token.
//         let sui_coin = mint_sui(TEST_SUI_SUPPLY, test_scenario::ctx(scenario));
//         test_scenario::next_tx(scenario, creator);

//         // Fetch state objects.
//         let token_bridge_relayer_state =
//             test_scenario::take_shared<State>(scenario);
//         let bridge_state =
//             test_scenario::take_shared<BridgeState>(scenario);
//         let wormhole_state =
//             test_scenario::take_shared<WormholeState>(scenario);

//         // Send a test transfer.
//         transfer::send_tokens_with_payload(
//             &token_bridge_relayer_state,
//             &mut wormhole_state,
//             &mut bridge_state,
//             test_coin,
//             sui_coin,
//             69, // Unregistered chain ID.
//             0,
//             x"000000000000000000000000beFA429d57cD18b7F8A4d91A2da9AB4AF05d0FBe", // Unregistered contract.
//             test_scenario::ctx(scenario)
//         );

//         // Return the goods.
//         test_scenario::return_shared<State>(token_bridge_relayer_state);
//         test_scenario::return_shared<BridgeState>(bridge_state);
//         test_scenario::return_shared<WormholeState>(wormhole_state);
//         native_transfer::transfer(test_metadata, @0x0);

//         // Done.
//         test_scenario::end(my_scenario);
//     }

//     #[test]
//     /// This test confirms that the Hello Token contract correctly
//     /// redeems token transfers and does not pay a relayer fee
//     /// since the redeeming wallet is the encoded recipient.
//     public fun redeem_transfer_with_payload_self_redemption() {
//         let (creator, _) = people();
//         let (my_scenario, _) = set_up(creator);
//         let scenario = &mut my_scenario;

//         // Fetch state objects.
//         let token_bridge_relayer_state =
//             test_scenario::take_shared<State>(scenario);
//         let bridge_state =
//             test_scenario::take_shared<BridgeState>(scenario);
//         let wormhole_state =
//             test_scenario::take_shared<WormholeState>(scenario);

//         // Attest the token.
//         {
//             // Mint coin 8, fetch the metadata and store the object ID for later.
//             let (test_coin, test_metadata) = mint_coin_8(
//                 TEST_TOKEN_8_SUPPLY,
//                 test_scenario::ctx(scenario)
//             );
//             test_scenario::next_tx(scenario, creator);

//             // Mint sui to pay the wormhole fee for attesting the token.
//             let fee_coin = mint_sui(
//                 wormhole_state_module::get_message_fee(&wormhole_state),
//                 test_scenario::ctx(scenario)
//             );

//             // Attest!
//             attest_token::attest_token(
//                 &mut bridge_state,
//                 &mut wormhole_state,
//                 &test_metadata,
//                 fee_coin,
//                 0, // batch ID
//                 test_scenario::ctx(scenario)
//             );

//             // Deposit tokens into the bridge.
//             deposit_test_only(&mut bridge_state, test_coin);

//             // Transfer coin_8 metadata to zero address.
//             native_transfer::transfer(test_metadata, @0x0);

//             // Proceed.
//             test_scenario::next_tx(scenario, creator);
//         };

//         // Register the target contract.
//         {
//             let owner_cap =
//                 test_scenario::take_from_sender<OwnerCap>(scenario);

//             owner::register_foreign_contract(
//                 &owner_cap,
//                 &mut token_bridge_relayer_state,
//                 2,
//                 x"0000000000000000000000000000000000000000000000000000000000000059"
//             );

//             // Bye bye.
//             test_scenario::return_to_sender<OwnerCap>(scenario, owner_cap);

//             // Proceed.
//             test_scenario::next_tx(scenario, creator);
//         };

//         // Complete the transfer.
//         transfer::redeem_transfer_with_payload<coin_8::COIN_8>(
//             &token_bridge_relayer_state,
//             &mut wormhole_state,
//             &mut bridge_state,
//             REDEEM_ONE_TRANSFER_VAA,
//             test_scenario::ctx(scenario)
//         );

//         // Proceed.
//         let effects = test_scenario::next_tx(scenario, creator);

//         // Store created object IDs.
//         let created_ids = test_scenario::created(&effects);
//         assert!(vector::length(&created_ids) == 1, 0);

//         // Balance check the recipient.
//         {
//             let token_object =
//                 test_scenario::take_from_sender<Coin<coin_8::COIN_8>>(scenario);

//             // Validate the object's value.
//             assert!(coin::value(&token_object) == REDEEM_ONE_AMOUNT, 0);

//             // Bye bye.
//             test_scenario::return_to_sender(scenario, token_object);
//         };

//         // Return the goods.
//         test_scenario::return_shared<State>(token_bridge_relayer_state);
//         test_scenario::return_shared<BridgeState>(bridge_state);
//         test_scenario::return_shared<WormholeState>(wormhole_state);

//         // Done.
//         test_scenario::end(my_scenario);
//     }

//     #[test]
//     /// This test confirms that the Hello Token contract correctly
//     /// redeems token transfers and pays a relayer fee to the caller
//     /// for redeeming the transaction.
//     public fun redeem_transfer_with_payload_with_relayer() {
//         let (creator, relayer) = people();
//         let (my_scenario, _) = set_up(creator);
//         let scenario = &mut my_scenario;

//         // Fetch state objects.
//         let token_bridge_relayer_state =
//             test_scenario::take_shared<State>(scenario);
//         let bridge_state =
//             test_scenario::take_shared<BridgeState>(scenario);
//         let wormhole_state =
//             test_scenario::take_shared<WormholeState>(scenario);

//         // Attest the token.
//         {
//             // Mint coin 8, fetch the metadata and store the object ID for later.
//             let (test_coin, test_metadata) = mint_coin_8(
//                 TEST_TOKEN_8_SUPPLY,
//                 test_scenario::ctx(scenario)
//             );
//             test_scenario::next_tx(scenario, creator);

//             // Mint sui to pay the wormhole fee for attesting the token.
//             let fee_coin = mint_sui(
//                 wormhole_state_module::get_message_fee(&wormhole_state),
//                 test_scenario::ctx(scenario)
//             );

//             // Attest!
//             attest_token::attest_token(
//                 &mut bridge_state,
//                 &mut wormhole_state,
//                 &test_metadata,
//                 fee_coin,
//                 0, // batch ID
//                 test_scenario::ctx(scenario)
//             );

//             // Deposit tokens into the bridge.
//             deposit_test_only(&mut bridge_state, test_coin);

//             // Transfer coin_8 metadata to zero address.
//             native_transfer::transfer(test_metadata, @0x0);
//         };

//         // Register the target contract.
//         {
//             let owner_cap =
//                 test_scenario::take_from_sender<OwnerCap>(scenario);

//             owner::register_foreign_contract(
//                 &owner_cap,
//                 &mut token_bridge_relayer_state,
//                 2,
//                 x"0000000000000000000000000000000000000000000000000000000000000059"
//             );

//             // Bye bye.
//             test_scenario::return_to_sender<OwnerCap>(scenario, owner_cap);

//             // Proceed.
//             test_scenario::next_tx(scenario, creator);
//         };

//         // Proceed, and change sender to the relayer.
//         test_scenario::next_tx(scenario, relayer);

//         // Complete the transfer.
//         transfer::redeem_transfer_with_payload<coin_8::COIN_8>(
//             &token_bridge_relayer_state,
//             &mut wormhole_state,
//             &mut bridge_state,
//             REDEEM_ONE_TRANSFER_VAA,
//             test_scenario::ctx(scenario)
//         );

//         // Proceed.
//         let effects = test_scenario::next_tx(scenario, relayer);

//         // Store created object IDs.
//         let created_ids = test_scenario::created(&effects);
//         assert!(vector::length(&created_ids) == 2, 0);

//         // Balance check the relayer.
//         {
//             // Fetch the relayer fee object by id.
//             let relayer_fee_obj =
//                 test_scenario::take_from_sender_by_id<Coin<coin_8::COIN_8>>(
//                     scenario,
//                     *vector::borrow(&created_ids, 0)
//                 );

//             // Validate the relayer fee object's value.
//             assert!(coin::value(&relayer_fee_obj) == REDEEM_ONE_RELAYER_FEE, 0);

//             // Bye bye.
//             test_scenario::return_to_sender(scenario, relayer_fee_obj);
//         };

//         // Balance check the recipient.
//         {
//             // Proceed with the test and change context back to creator,
//             // who is also the recipient in this test.
//             test_scenario::next_tx(scenario, creator);

//             // Fetch the transferred object by id.
//             let transferred_coin_obj =
//                 test_scenario::take_from_sender_by_id<Coin<coin_8::COIN_8>>(
//                     scenario,
//                     *vector::borrow(&created_ids, 1)
//                 );

//             // Validate the relayer fee object's value.
//             let expected_amount = REDEEM_ONE_AMOUNT - REDEEM_ONE_RELAYER_FEE;
//             assert!(coin::value(&transferred_coin_obj) == expected_amount, 0);

//             // Bye bye.
//             test_scenario::return_to_sender(scenario, transferred_coin_obj);
//         };

//         // Return the goods.
//         test_scenario::return_shared<State>(token_bridge_relayer_state);
//         test_scenario::return_shared<BridgeState>(bridge_state);
//         test_scenario::return_shared<WormholeState>(wormhole_state);

//         // Done.
//         test_scenario::end(my_scenario);
//     }

//     #[test]
//     /// This test confirms that the Hello Token contract correctly
//     /// redeems token transfers for the minimum amount. The contract
//     /// should not pay any relayer fees since the amount is so small
//     /// and the relayer fee calculation rounds down to zero.
//     public fun redeem_transfer_with_payload_with_relayer_minimum_amount() {
//         let (creator, relayer) = people();
//         let (my_scenario, _) = set_up(creator);
//         let scenario = &mut my_scenario;

//         // Fetch state objects.
//         let token_bridge_relayer_state =
//             test_scenario::take_shared<State>(scenario);
//         let bridge_state =
//             test_scenario::take_shared<BridgeState>(scenario);
//         let wormhole_state =
//             test_scenario::take_shared<WormholeState>(scenario);

//         // Attest the token.
//         {
//             // Mint coin 8, fetch the metadata and store the object ID for later.
//             let (test_coin, test_metadata) = mint_coin_8(
//                 TEST_TOKEN_8_SUPPLY,
//                 test_scenario::ctx(scenario)
//             );
//             test_scenario::next_tx(scenario, creator);

//             // Mint sui to pay the wormhole fee for attesting the token.
//             let fee_coin = mint_sui(
//                 wormhole_state_module::get_message_fee(&wormhole_state),
//                 test_scenario::ctx(scenario)
//             );

//             // Attest!
//             attest_token::attest_token(
//                 &mut bridge_state,
//                 &mut wormhole_state,
//                 &test_metadata,
//                 fee_coin,
//                 0, // batch ID
//                 test_scenario::ctx(scenario)
//             );

//             // Deposit tokens into the bridge.
//             deposit_test_only(&mut bridge_state, test_coin);

//             // Transfer coin_8 metadata to zero address.
//             native_transfer::transfer(test_metadata, @0x0);
//         };

//         // Register the target contract.
//         {
//             let owner_cap =
//                 test_scenario::take_from_sender<OwnerCap>(scenario);

//             owner::register_foreign_contract(
//                 &owner_cap,
//                 &mut token_bridge_relayer_state,
//                 2,
//                 x"0000000000000000000000000000000000000000000000000000000000000059"
//             );

//             // Bye bye.
//             test_scenario::return_to_sender<OwnerCap>(scenario, owner_cap);

//             // Proceed.
//             test_scenario::next_tx(scenario, creator);
//         };

//         // Proceed, and change sender to the relayer.
//         test_scenario::next_tx(scenario, relayer);

//         // Complete the transfer.
//         transfer::redeem_transfer_with_payload<coin_8::COIN_8>(
//             &token_bridge_relayer_state,
//             &mut wormhole_state,
//             &mut bridge_state,
//             REDEEM_TWO_TRANSFER_VAA,
//             test_scenario::ctx(scenario)
//         );

//         // Proceed.
//         let effects = test_scenario::next_tx(scenario, relayer);

//         // Store created object IDs. Only one object should've been created,
//         // since the relayer fee amount is too small and is rounded to zero.
//         let created_ids = test_scenario::created(&effects);
//         assert!(vector::length(&created_ids) == 1, 0);

//         // Balance check the recipient.
//         {
//             // Proceed with the test and change context back to creator,
//             // who is also the recipient in this test.
//             test_scenario::next_tx(scenario, creator);

//             // Fetch the transferred object by id.
//             let transferred_coin_obj =
//                 test_scenario::take_from_sender_by_id<Coin<coin_8::COIN_8>>(
//                     scenario,
//                     *vector::borrow(&created_ids, 0)
//                 );

//             // Validate the relayer fee object's value.
//             assert!(coin::value(&transferred_coin_obj) == REDEEM_TWO_AMOUNT, 0);

//             // Bye bye.
//             test_scenario::return_to_sender(scenario, transferred_coin_obj);
//         };

//         // Return the goods.
//         test_scenario::return_shared<State>(token_bridge_relayer_state);
//         test_scenario::return_shared<BridgeState>(bridge_state);
//         test_scenario::return_shared<WormholeState>(wormhole_state);

//         // Done.
//         test_scenario::end(my_scenario);
//     }

//     #[test]
//     /// This test confirms that the Hello Token contract correctly handles
//     /// transfers for the maximum amount (type(uint64).max) when the caller
//     /// is the encoded recipient.
//     public fun redeem_transfer_with_payload_self_redemption_maximum_amount() {
//         let (creator, _) = people();
//         let (my_scenario, _) = set_up(creator);
//         let scenario = &mut my_scenario;

//         // Fetch state objects.
//         let token_bridge_relayer_state =
//             test_scenario::take_shared<State>(scenario);
//         let bridge_state =
//             test_scenario::take_shared<BridgeState>(scenario);
//         let wormhole_state =
//             test_scenario::take_shared<WormholeState>(scenario);

//         // Attest the token.
//         {
//             // Mint coin 8, fetch the metadata and store the object ID for later.
//             let (test_coin, test_metadata) = mint_coin_8(
//                 REDEEM_THREE_AMOUNT,
//                 test_scenario::ctx(scenario)
//             );
//             test_scenario::next_tx(scenario, creator);

//             // Mint sui to pay the wormhole fee for attesting the token.
//             let fee_coin = mint_sui(
//                 wormhole_state_module::get_message_fee(&wormhole_state),
//                 test_scenario::ctx(scenario)
//             );

//             // Attest!
//             attest_token::attest_token(
//                 &mut bridge_state,
//                 &mut wormhole_state,
//                 &test_metadata,
//                 fee_coin,
//                 0, // batch ID
//                 test_scenario::ctx(scenario)
//             );

//             // Deposit tokens into the bridge.
//             deposit_test_only(&mut bridge_state, test_coin);

//             // Transfer coin_8 metadata to zero address.
//             native_transfer::transfer(test_metadata, @0x0);

//             // Proceed.
//             test_scenario::next_tx(scenario, creator);
//         };

//         // Register the target contract.
//         {
//             let owner_cap =
//                 test_scenario::take_from_sender<OwnerCap>(scenario);

//             owner::register_foreign_contract(
//                 &owner_cap,
//                 &mut token_bridge_relayer_state,
//                 2,
//                 x"0000000000000000000000000000000000000000000000000000000000000059"
//             );

//             // Bye bye.
//             test_scenario::return_to_sender<OwnerCap>(scenario, owner_cap);

//             // Proceed.
//             test_scenario::next_tx(scenario, creator);
//         };

//         // Complete the transfer.
//         transfer::redeem_transfer_with_payload<coin_8::COIN_8>(
//             &token_bridge_relayer_state,
//             &mut wormhole_state,
//             &mut bridge_state,
//             REDEEM_THREE_TRANSFER_VAA,
//             test_scenario::ctx(scenario)
//         );

//         // Proceed.
//         let effects = test_scenario::next_tx(scenario, creator);

//         // Store created object IDs.
//         let created_ids = test_scenario::created(&effects);
//         assert!(vector::length(&created_ids) == 1, 0);

//         // Balance check the recipient.
//         {
//             let token_object =
//                 test_scenario::take_from_sender<Coin<coin_8::COIN_8>>(scenario);

//             // Validate the object's value.
//             assert!(coin::value(&token_object) == REDEEM_THREE_AMOUNT, 0);

//             // Bye bye.
//             test_scenario::return_to_sender(scenario, token_object);
//         };

//         // Return the goods.
//         test_scenario::return_shared<State>(token_bridge_relayer_state);
//         test_scenario::return_shared<BridgeState>(bridge_state);
//         test_scenario::return_shared<WormholeState>(wormhole_state);

//         // Done.
//         test_scenario::end(my_scenario);
//     }

//     #[test]
//     /// This test confirms that the Hello Token contract correctly handles
//     /// transfers for the maximum amount (type(uint64).max) when the caller
//     /// is not the encoded recipient. The contract should correctly pay the
//     /// caller the expected relayer fee.
//     public fun redeem_transfer_with_payload_with_relayer_maximum_amount() {
//         let (creator, relayer) = people();
//         let (my_scenario, _) = set_up(creator);
//         let scenario = &mut my_scenario;

//         // Fetch state objects.
//         let token_bridge_relayer_state =
//             test_scenario::take_shared<State>(scenario);
//         let bridge_state =
//             test_scenario::take_shared<BridgeState>(scenario);
//         let wormhole_state =
//             test_scenario::take_shared<WormholeState>(scenario);

//         // Attest the token.
//         {
//             // Mint coin 8, fetch the metadata and store the object ID for later.
//             let (test_coin, test_metadata) = mint_coin_8(
//                 REDEEM_THREE_AMOUNT,
//                 test_scenario::ctx(scenario)
//             );
//             test_scenario::next_tx(scenario, creator);

//             // Mint sui to pay the wormhole fee for attesting the token.
//             let fee_coin = mint_sui(
//                 wormhole_state_module::get_message_fee(&wormhole_state),
//                 test_scenario::ctx(scenario)
//             );

//             // Attest!
//             attest_token::attest_token(
//                 &mut bridge_state,
//                 &mut wormhole_state,
//                 &test_metadata,
//                 fee_coin,
//                 0, // batch ID
//                 test_scenario::ctx(scenario)
//             );

//             // Deposit tokens into the bridge.
//             deposit_test_only(&mut bridge_state, test_coin);

//             // Transfer coin_8 metadata to zero address.
//             native_transfer::transfer(test_metadata, @0x0);
//         };

//         // Register the target contract.
//         {
//             let owner_cap =
//                 test_scenario::take_from_sender<OwnerCap>(scenario);

//             owner::register_foreign_contract(
//                 &owner_cap,
//                 &mut token_bridge_relayer_state,
//                 2,
//                 x"0000000000000000000000000000000000000000000000000000000000000059"
//             );

//             // Bye bye.
//             test_scenario::return_to_sender<OwnerCap>(scenario, owner_cap);

//             // Proceed.
//             test_scenario::next_tx(scenario, creator);
//         };

//         // Proceed, and change sender to the relayer.
//         test_scenario::next_tx(scenario, relayer);

//         // Complete the transfer.
//         transfer::redeem_transfer_with_payload<coin_8::COIN_8>(
//             &token_bridge_relayer_state,
//             &mut wormhole_state,
//             &mut bridge_state,
//             REDEEM_THREE_TRANSFER_VAA,
//             test_scenario::ctx(scenario)
//         );

//         // Proceed.
//         let effects = test_scenario::next_tx(scenario, relayer);

//         // Store created object IDs.
//         let created_ids = test_scenario::created(&effects);
//         assert!(vector::length(&created_ids) == 2, 0);

//         // Balance check the relayer.
//         {
//             // Fetch the relayer fee object by id.
//             let relayer_fee_obj =
//                 test_scenario::take_from_sender_by_id<Coin<coin_8::COIN_8>>(
//                     scenario,
//                     *vector::borrow(&created_ids, 0)
//                 );

//             // Validate the relayer fee object's value.
//             assert!(coin::value(&relayer_fee_obj) == REDEEM_THREE_RELAYER_FEE, 0);

//             // Bye bye.
//             test_scenario::return_to_sender(scenario, relayer_fee_obj);
//         };

//         // Balance check the recipient.
//         {
//             // Proceed with the test and change context back to creator,
//             // who is also the recipient in this test.
//             test_scenario::next_tx(scenario, creator);

//             // Fetch the transferred object by id.
//             let transferred_coin_obj =
//                 test_scenario::take_from_sender_by_id<Coin<coin_8::COIN_8>>(
//                     scenario,
//                     *vector::borrow(&created_ids, 1)
//                 );

//             // Validate the relayer fee object's value.
//             let expected_amount = REDEEM_THREE_AMOUNT - REDEEM_THREE_RELAYER_FEE;
//             assert!(coin::value(&transferred_coin_obj) == expected_amount, 0);

//             // Bye bye.
//             test_scenario::return_to_sender(scenario, transferred_coin_obj);
//         };

//         // Return the goods.
//         test_scenario::return_shared<State>(token_bridge_relayer_state);
//         test_scenario::return_shared<BridgeState>(bridge_state);
//         test_scenario::return_shared<WormholeState>(wormhole_state);

//         // Done.
//         test_scenario::end(my_scenario);
//     }

//     #[test]
//     #[expected_failure(abort_code = 1, location=transfer)]
//     /// This test confirms that the Hello Token contract will revert
//     /// if the sender of the transfer message is not the registered
//     /// contract for the specified chain ID.
//     public fun cannot_redeem_transfer_with_payload_unknown_sender() {
//         let (creator, _) = people();
//         let (my_scenario, _) = set_up(creator);
//         let scenario = &mut my_scenario;

//         // Fetch state objects.
//         let token_bridge_relayer_state =
//             test_scenario::take_shared<State>(scenario);
//         let bridge_state =
//             test_scenario::take_shared<BridgeState>(scenario);
//         let wormhole_state =
//             test_scenario::take_shared<WormholeState>(scenario);

//         // Attest the token.
//         {
//             // Mint coin 8, fetch the metadata and store the object ID for later.
//             let (test_coin, test_metadata) = mint_coin_8(
//                 REDEEM_THREE_AMOUNT,
//                 test_scenario::ctx(scenario)
//             );
//             test_scenario::next_tx(scenario, creator);

//             // Mint sui to pay the wormhole fee for attesting the token.
//             let fee_coin = mint_sui(
//                 wormhole_state_module::get_message_fee(&wormhole_state),
//                 test_scenario::ctx(scenario)
//             );

//             // Attest!
//             attest_token::attest_token(
//                 &mut bridge_state,
//                 &mut wormhole_state,
//                 &test_metadata,
//                 fee_coin,
//                 0, // batch ID
//                 test_scenario::ctx(scenario)
//             );

//             // Deposit tokens into the bridge.
//             deposit_test_only(&mut bridge_state, test_coin);

//             // Transfer coin_8 metadata to zero address.
//             native_transfer::transfer(test_metadata, @0x0);

//             // Proceed.
//             test_scenario::next_tx(scenario, creator);
//         };

//         // Register the wrong target contract to test the unkown sender path.
//         {
//             let owner_cap =
//                 test_scenario::take_from_sender<OwnerCap>(scenario);

//             owner::register_foreign_contract(
//                 &owner_cap,
//                 &mut token_bridge_relayer_state,
//                 2,
//                 x"690000000000000000000000000000000000000000000000000000000000beef"
//             );

//             // Bye bye.
//             test_scenario::return_to_sender<OwnerCap>(scenario, owner_cap);

//             // Proceed.
//             test_scenario::next_tx(scenario, creator);
//         };

//         // This call should fail.
//         transfer::redeem_transfer_with_payload<coin_8::COIN_8>(
//             &token_bridge_relayer_state,
//             &mut wormhole_state,
//             &mut bridge_state,
//             REDEEM_ONE_TRANSFER_VAA,
//             test_scenario::ctx(scenario)
//         );

//         // Proceed.
//         test_scenario::next_tx(scenario, creator);

//         // Return the goods.
//         test_scenario::return_shared<State>(token_bridge_relayer_state);
//         test_scenario::return_shared<BridgeState>(bridge_state);
//         test_scenario::return_shared<WormholeState>(wormhole_state);

//         // Done.
//         test_scenario::end(my_scenario);
//     }

//     #[test]
//     #[expected_failure(abort_code = token_bridge_relayer::foreign_contracts::E_CONTRACT_DOES_NOT_EXIST)]
//     /// This test confirms that the Hello Token contract will revert
//     /// if the sender of the transfer message is from a chain that does
//     /// not have a registered contract.
//     public fun cannot_redeem_transfer_with_payload_foreign_contract_does_not_exist() {
//         let (creator, _) = people();
//         let (my_scenario, _) = set_up(creator);
//         let scenario = &mut my_scenario;

//         // Fetch state objects.
//         let token_bridge_relayer_state =
//             test_scenario::take_shared<State>(scenario);
//         let bridge_state =
//             test_scenario::take_shared<BridgeState>(scenario);
//         let wormhole_state =
//             test_scenario::take_shared<WormholeState>(scenario);

//         // Attest the token.
//         {
//             // Mint coin 8, fetch the metadata and store the object ID for later.
//             let (test_coin, test_metadata) = mint_coin_8(
//                 TEST_TOKEN_8_SUPPLY,
//                 test_scenario::ctx(scenario)
//             );
//             test_scenario::next_tx(scenario, creator);

//             // Mint sui to pay the wormhole fee for attesting the token.
//             let fee_coin = mint_sui(
//                 wormhole_state_module::get_message_fee(&wormhole_state),
//                 test_scenario::ctx(scenario)
//             );

//             // Attest!
//             attest_token::attest_token(
//                 &mut bridge_state,
//                 &mut wormhole_state,
//                 &test_metadata,
//                 fee_coin,
//                 0, // batch ID
//                 test_scenario::ctx(scenario)
//             );

//             // Deposit tokens into the bridge.
//             deposit_test_only(&mut bridge_state, test_coin);

//             // Transfer coin_8 metadata to zero address.
//             native_transfer::transfer(test_metadata, @0x0);

//             // Proceed.
//             test_scenario::next_tx(scenario, creator);
//         };

//         // NOTE: explicitly does not register a foreign contract

//         // This call should fail.
//         transfer::redeem_transfer_with_payload<coin_8::COIN_8>(
//             &token_bridge_relayer_state,
//             &mut wormhole_state,
//             &mut bridge_state,
//             REDEEM_ONE_TRANSFER_VAA,
//             test_scenario::ctx(scenario)
//         );

//         // Proceed.
//         test_scenario::next_tx(scenario, creator);

//         // Return the goods.
//         test_scenario::return_shared<State>(token_bridge_relayer_state);
//         test_scenario::return_shared<BridgeState>(bridge_state);
//         test_scenario::return_shared<WormholeState>(wormhole_state);

//         // Done.
//         test_scenario::end(my_scenario);
//     }

//     /// Utilities.

//     public fun mint_coin_8(
//         amount: u64,
//         ctx: &mut TxContext
//     ): (Coin<coin_8::COIN_8>, CoinMetadata<coin_8::COIN_8>) {
//         // Initialize token 8.
//         let (treasury_cap, metadata) = coin_8::create_coin_test_only(ctx);

//         // Mint tokens.
//         let test_coin = coin::mint(
//             &mut treasury_cap,
//             amount,
//             ctx
//         );

//         // Balance check the new coin object.
//         assert!(coin::value(&test_coin) == amount, 0);

//         // Bye bye.
//         native_transfer::transfer(treasury_cap, @0x0);

//         // Return.
//         (test_coin, metadata)
//     }

//     public fun mint_coin_9(
//         amount: u64,
//         ctx: &mut TxContext
//     ): (Coin<coin_9::COIN_9>, CoinMetadata<coin_9::COIN_9>) {
//         // Initialize token 8.
//         let (treasury_cap, metadata) = coin_9::create_coin_test_only(ctx);

//         // Mint tokens.
//         let test_coin = coin::mint(
//             &mut treasury_cap,
//             amount,
//             ctx
//         );

//         // Balance check the new coin object.
//         assert!(coin::value(&test_coin) == amount, 0);

//         // Bye bye.
//         native_transfer::transfer(treasury_cap, @0x0);

//         // Return.
//         (test_coin, metadata)
//     }

//     public fun mint_sui(amount: u64, ctx: &mut TxContext): Coin<SUI> {
//         // Mint SUI tokens.
//         let sui_coin = sui::coin::mint_for_testing<SUI>(
//             amount,
//             ctx
//         );
//         assert!(coin::value(&sui_coin) == amount, 0);

//         sui_coin
//     }
// }
