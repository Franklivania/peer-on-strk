use starknet::{ContractAddress, get_contract_address, get_block_timestamp};
use snforge_std::{
    declare, ContractClassTrait, DeclareResultTrait, DeclareResult, start_cheat_caller_address,
    stop_cheat_caller_address, start_cheat_block_timestamp, spy_events, EventSpyAssertionsTrait
};

use peer_protocol::interfaces::ipeer_protocol::{
    IPeerProtocolDispatcher, IPeerProtocolDispatcherTrait
};
use peer_protocol::peer_protocol::PeerProtocol;

use peer_protocol::interfaces::ierc20::{IERC20Dispatcher, IERC20DispatcherTrait};

use peer_protocol::peer_protocol::ProposalType;

use core::num::traits::Zero;

const ONE_E18: u256 = 1000000000000000000_u256;
const ONE_E8: u256 = 1000000000_u256;
const COLLATERAL_RATIO_NUMERATOR: u256 = 13_u256;
const COLLATERAL_RATIO_DENOMINATOR: u256 = 10_u256;

fn deploy_token(name: ByteArray) -> ContractAddress {
    let contract = declare("MockToken").unwrap().contract_class();

    let mut constructor_calldata = ArrayTrait::new();
    name.serialize(ref constructor_calldata);

    let (contract_address, _) = contract.deploy(@constructor_calldata).unwrap();

    contract_address
}

fn deploy_spok() -> ContractAddress {
    let contract = declare("SPOKNFT").unwrap().contract_class();
    let mut constructor_calldata = ArrayTrait::new();
    let (contract_address, _) = contract.deploy(@constructor_calldata).unwrap();
    contract_address
}

fn deploy_peer_protocol() -> ContractAddress {
    let owner: ContractAddress = starknet::contract_address_const::<0x123626789>();
    let protocol_fee_address: ContractAddress = starknet::contract_address_const::<0x129996789>();
    let spok_nft: ContractAddress = deploy_spok();
    let pragma_address_main: ContractAddress = starknet::contract_address_const::<
        0x2a85bd616f912537c50a49a4076db02c00b29b2cdc8a197ce92ed1837fa875b
    >(); // mainnet

    let mut constructor_calldata = ArrayTrait::new();
    constructor_calldata.append(owner.into());
    constructor_calldata.append(protocol_fee_address.into());
    constructor_calldata.append(spok_nft.into());
    constructor_calldata.append(pragma_address_main.into());

    let contract = declare("PeerProtocol").unwrap().contract_class();
    let (contract_address, _) = contract.deploy(@constructor_calldata).unwrap();

    contract_address
}

#[test]
#[should_panic(expected: "token not supported")]
fn test_deposit_should_panic_for_unsupported_token() {
    let token_address = deploy_token("MockToken");
    let peer_protocol_address = deploy_peer_protocol();

    let token = IERC20Dispatcher { contract_address: token_address };
    let caller: ContractAddress = starknet::contract_address_const::<0x122226789>();
    let mint_amount: u256 = 1000 * ONE_E18;

    let peer_protocol = IPeerProtocolDispatcher { contract_address: peer_protocol_address };

    token.mint(caller, mint_amount);

    // Approving peer_protocol contract to spend mock_token
    start_cheat_caller_address(token_address, caller);
    token.approve(peer_protocol_address, mint_amount);
    stop_cheat_caller_address(token_address);

    // Prank caller to deposit into peer protocol
    start_cheat_caller_address(peer_protocol_address, caller);
    let deposit_amount: u256 = 100 * ONE_E18;
    peer_protocol.deposit(token_address, deposit_amount);
    stop_cheat_caller_address(peer_protocol_address);
}

#[test]
fn test_deposit() {
    let token_address = deploy_token("MockToken");
    let peer_protocol_address = deploy_peer_protocol();

    let token = IERC20Dispatcher { contract_address: token_address };

    let caller: ContractAddress = starknet::contract_address_const::<0x122226789>();
    let mint_amount: u256 = 1000 * ONE_E18;

    let peer_protocol = IPeerProtocolDispatcher { contract_address: peer_protocol_address };

    let owner: ContractAddress = starknet::contract_address_const::<0x123626789>();

    // Prank owner to add supported token in peer protocol
    start_cheat_caller_address(peer_protocol_address, owner);
    peer_protocol.add_supported_token(token_address, 0);
    stop_cheat_caller_address(peer_protocol_address);

    token.mint(caller, mint_amount);

    // Approving peer_protocol contract to spend mock_token
    start_cheat_caller_address(token_address, caller);
    token.approve(peer_protocol_address, mint_amount);
    stop_cheat_caller_address(token_address);

    // Prank caller to deposit into peer protocol
    start_cheat_caller_address(peer_protocol_address, caller);
    let deposit_amount: u256 = 100 * ONE_E18;
    let mut spy = spy_events();

    peer_protocol.deposit(token_address, deposit_amount);

    // testing peer_protocol contract balance increase
    assert!(token.balance_of(peer_protocol_address) == deposit_amount, "deposit failed");

    // testing emitted event
    let expected_event = PeerProtocol::Event::DepositSuccessful(
        PeerProtocol::DepositSuccessful {
            user: caller, token: token_address, amount: deposit_amount
        }
    );

    spy.assert_emitted(@array![(peer_protocol_address, expected_event)]);

    stop_cheat_caller_address(peer_protocol_address);
}

#[test]
fn test_withdraw() {
    let token_address = deploy_token("MockToken");
    let peer_protocol_address = deploy_peer_protocol();

    let token = IERC20Dispatcher { contract_address: token_address };
    let peer_protocol = IPeerProtocolDispatcher { contract_address: peer_protocol_address };

    let owner: ContractAddress = starknet::contract_address_const::<0x123626789>();
    let caller: ContractAddress = starknet::contract_address_const::<0x122226789>();

    let mint_amount: u256 = 1000 * ONE_E18;
    let deposit_amount: u256 = 100 * ONE_E18;
    let withdraw_amount: u256 = 50 * ONE_E18;

    start_cheat_caller_address(peer_protocol_address, owner);
    peer_protocol.add_supported_token(token_address, 0);
    stop_cheat_caller_address(peer_protocol_address);

    // Mint tokens
    token.mint(caller, mint_amount);

    start_cheat_caller_address(token_address, caller);
    token.approve(peer_protocol_address, mint_amount);
    stop_cheat_caller_address(token_address);

    start_cheat_caller_address(peer_protocol_address, caller);
    peer_protocol.deposit(token_address, deposit_amount);

    let mut spy = spy_events();
    peer_protocol.withdraw(token_address, withdraw_amount);
    assert!(
        token.balance_of(peer_protocol_address) == deposit_amount - withdraw_amount,
        "incorrect protocol balance after withdrawal"
    );
    assert!(
        token.balance_of(caller) == mint_amount - deposit_amount + withdraw_amount,
        "incorrect user balance after withdrawal"
    );
    let expected_event = PeerProtocol::Event::WithdrawalSuccessful(
        PeerProtocol::WithdrawalSuccessful {
            user: caller, token: token_address, amount: withdraw_amount
        }
    );
    spy.assert_emitted(@array![(peer_protocol_address, expected_event)]);

    stop_cheat_caller_address(peer_protocol_address);
}

#[test]
fn test_get_user_assets() {
    let token1_address = deploy_token("MockToken1");
    let token2_address = deploy_token("MockToken2");
    let peer_protocol_address = deploy_peer_protocol();

    let token1 = IERC20Dispatcher { contract_address: token1_address };
    let token2 = IERC20Dispatcher { contract_address: token2_address };

    let caller: ContractAddress = starknet::contract_address_const::<0x122226789>();
    let mint_amount: u256 = 10000 * ONE_E18;

    let peer_protocol = IPeerProtocolDispatcher { contract_address: peer_protocol_address };

    let owner: ContractAddress = starknet::contract_address_const::<0x123626789>();

    // Prank owner to add supported token in peer protocol
    start_cheat_caller_address(peer_protocol_address, owner);
    peer_protocol.add_supported_token(token1_address, 0);
    peer_protocol.add_supported_token(token2_address, 0);
    stop_cheat_caller_address(peer_protocol_address);

    token1.mint(caller, mint_amount);
    token2.mint(caller, mint_amount);

    // Approving peer_protocol contract to spend mock_token
    start_cheat_caller_address(token1_address, caller);
    token1.approve(peer_protocol_address, mint_amount);
    stop_cheat_caller_address(token1_address);

    start_cheat_caller_address(token2_address, caller);
    token2.approve(peer_protocol_address, mint_amount);
    stop_cheat_caller_address(token2_address);

    // Prank caller to deposit into peer protocol
    start_cheat_caller_address(peer_protocol_address, caller);
    let deposit_amount1: u256 = 1000 * ONE_E18;
    let deposit_amount2: u256 = 100 * ONE_E18;

    peer_protocol.deposit(token1_address, deposit_amount1);
    peer_protocol.deposit(token2_address, deposit_amount2);

    let user_assets = peer_protocol.get_user_assets(caller);

    assert!(
        *user_assets.at(0).available_balance == deposit_amount1, "wrong asset available_balance 1"
    );
    assert!(*user_assets.at(0).token_address == token1_address, "wrong asset token1");

    assert!(
        *user_assets.at(1).available_balance == deposit_amount2, "wrong asset available_balance 2"
    );
    assert!(*user_assets.at(1).token_address == token2_address, "wrong asset token2");

    stop_cheat_caller_address(peer_protocol_address);
}

#[test]
fn test_get_user_deposits() {
    // Deploy contracts
    let token1_address = deploy_token("MockToken1");
    let token2_address = deploy_token("MockToken2");
    // add another supported token without balance
    let token3_address = deploy_token("MockToken3");
    let peer_protocol_address = deploy_peer_protocol();

    // Setup dispatchers
    let token1 = IERC20Dispatcher { contract_address: token1_address };
    let token2 = IERC20Dispatcher { contract_address: token2_address };
    let peer_protocol = IPeerProtocolDispatcher { contract_address: peer_protocol_address };

    // Setup addresses
    let owner: ContractAddress = starknet::contract_address_const::<0x123626789>();
    let user: ContractAddress = starknet::contract_address_const::<0x122226789>();

    // Define amounts
    let mint_amount: u256 = 1000 * ONE_E18;
    let deposit_amount1: u256 = 100 * ONE_E18;
    let deposit_amount2: u256 = 200 * ONE_E18;

    // Add supported tokens
    start_cheat_caller_address(peer_protocol_address, owner);
    peer_protocol.add_supported_token(token1_address, 0);
    peer_protocol.add_supported_token(token2_address, 0);
    peer_protocol.add_supported_token(token3_address, 0);
    stop_cheat_caller_address(peer_protocol_address);

    // Mint tokens to user
    token1.mint(user, mint_amount);
    token2.mint(user, mint_amount);

    // Approve spending
    start_cheat_caller_address(token1_address, user);
    token1.approve(peer_protocol_address, mint_amount);
    stop_cheat_caller_address(token1_address);

    start_cheat_caller_address(token2_address, user);
    token2.approve(peer_protocol_address, mint_amount);
    stop_cheat_caller_address(token2_address);

    // Make deposits
    start_cheat_caller_address(peer_protocol_address, user);
    peer_protocol.deposit(token1_address, deposit_amount1);
    peer_protocol.deposit(token2_address, deposit_amount2);

    // Get and verify user deposits
    let user_deposits = peer_protocol.get_user_deposits(user);

    assert!(user_deposits.len() == 2, "incorrect number of deposits");

    // Verify deposit amounts for each token
    let deposit1 = user_deposits.at(0);
    let deposit2 = user_deposits.at(1);

    assert!(
        *deposit1.token == token1_address && *deposit1.amount == deposit_amount1,
        "incorrect deposit1"
    );
    assert!(
        *deposit2.token == token2_address && *deposit2.amount == deposit_amount2,
        "incorrect deposit2"
    );
    assert!(deposit1.token != deposit2.token, "duplicate tokens in result");

    stop_cheat_caller_address(peer_protocol_address);

    // Test for random user
    let random_user: ContractAddress = starknet::contract_address_const::<0x987654321>();
    let random_user_deposits = peer_protocol.get_user_deposits(random_user);
    assert!(random_user_deposits.len() == 0, "random user should have no deposits");
}

#[test]
#[should_panic(expected: "invalid user address")]
fn test_get_user_deposits_with_zero_address() {
    // Deploy contracts
    let peer_protocol_address = deploy_peer_protocol();
    let peer_protocol = IPeerProtocolDispatcher { contract_address: peer_protocol_address };

    // Test with zero address - should panic
    let zero_address: ContractAddress = starknet::contract_address_const::<0>();
    peer_protocol.get_user_deposits(zero_address);
}

#[test]
#[fork(url: "https://starknet-mainnet.blastapi.io/138dbf54-8751-4a78-a709-07ee952e5d15/rpc/v0_7", block_tag: latest)]
fn test_create_borrow_proposal() {
    // Setup
    let token_address = deploy_token("MockToken");
    let collateral_token_address = deploy_token("MockToken1");
    let peer_protocol_address = deploy_peer_protocol();

    let collateral_token = IERC20Dispatcher { contract_address: collateral_token_address };
    let peer_protocol = IPeerProtocolDispatcher { contract_address: peer_protocol_address };

    let owner: ContractAddress = starknet::contract_address_const::<0x123626789>();
    let borrower: ContractAddress = starknet::contract_address_const::<0x122226789>();

    let mint_amount: u256 = 1000 * ONE_E18;
    let borrow_amount: u256 = 500 * ONE_E18; // Borrow amount in dollars
    let interest_rate: u64 = 5;
    let duration: u64 = 10;

    // Mock token price (e.g., $100 per token)
    let token_price = 100 * ONE_E8; // $100 in 8 decimal places

    // Add supported tokens
    start_cheat_caller_address(peer_protocol_address, owner);
    peer_protocol.add_supported_token(token_address, 'STRK/USD');
    peer_protocol.add_supported_token(collateral_token_address, 'STRK/USD');
    stop_cheat_caller_address(peer_protocol_address);

    // Mint collateral tokens to borrower
    collateral_token.mint(borrower, mint_amount);

    // Approve collateral token
    start_cheat_caller_address(collateral_token_address, borrower);
    collateral_token.approve(peer_protocol_address, mint_amount);
    stop_cheat_caller_address(collateral_token_address);

    // Borrower deposits collateral
    start_cheat_caller_address(peer_protocol_address, borrower);
    peer_protocol.deposit(collateral_token_address, mint_amount);
    stop_cheat_caller_address(peer_protocol_address);

    // Calculate required collateral value
    let token_amount = (borrow_amount / token_price) * ONE_E18; // Amount of tokens to borrow
    let required_collateral_value = ((borrow_amount / token_price) * COLLATERAL_RATIO_NUMERATOR) / COLLATERAL_RATIO_DENOMINATOR;

    // Borrower creates a borrow proposal
    start_cheat_caller_address(peer_protocol_address, borrower);
    let mut spy = spy_events();

    peer_protocol.create_borrow_proposal(
        token_address,
        collateral_token_address,
        borrow_amount, // Borrow amount in dollars
        interest_rate,
        duration,
    );

    // Check emitted event
    let created_at = starknet::get_block_timestamp();
    let expected_event = PeerProtocol::Event::ProposalCreated(
        PeerProtocol::ProposalCreated {
            proposal_type: ProposalType::BORROWING,
            borrower,
            token: token_address,
            amount: borrow_amount,
            interest_rate,
            duration,
            created_at,
        }
    );

    spy.assert_emitted(@array![(peer_protocol_address, expected_event)]);

    stop_cheat_caller_address(peer_protocol_address);
}

#[test]
#[fork(url: "https://starknet-mainnet.blastapi.io/138dbf54-8751-4a78-a709-07ee952e5d15/rpc/v0_7", block_tag: latest)]
fn test_create_lending_proposal() {
    // Setup
    let token_address = deploy_token("MockToken");
    let collateral_token_address = deploy_token("MockToken1");
    let peer_protocol_address = deploy_peer_protocol();

    let lending_token = IERC20Dispatcher { contract_address: token_address };
    let peer_protocol = IPeerProtocolDispatcher { contract_address: peer_protocol_address };

    let owner: ContractAddress = starknet::contract_address_const::<0x123626789>();
    let lender: ContractAddress = starknet::contract_address_const::<0x122226789>();

    let mint_amount: u256 = 1000 * ONE_E18;
    let lending_amount: u256 = 500 * ONE_E18; // Lending amount in dollars
    let interest_rate: u64 = 5;
    let duration: u64 = 10;

    // Set token price (mock the token price)
    let token_price = 100; // $100 per token

    // Add supported tokens
    start_cheat_caller_address(peer_protocol_address, owner);
    peer_protocol.add_supported_token(token_address, 'STRK/USD');
    peer_protocol.add_supported_token(collateral_token_address, 'STRK/USD');
    stop_cheat_caller_address(peer_protocol_address);

    // Mint lending tokens to lender
    lending_token.mint(lender, mint_amount);
    assert!(lending_token.balance_of(lender) == mint_amount, "mint failed");

    // Approve contract to spend lending token
    start_cheat_caller_address(token_address, lender);
    lending_token.approve(peer_protocol_address, mint_amount);
    stop_cheat_caller_address(token_address);


    // Calculate token amount and required collateral value
    let token_amount = lending_amount;
    let required_collateral_value = (lending_amount * COLLATERAL_RATIO_NUMERATOR) / COLLATERAL_RATIO_DENOMINATOR;

    // Lender deposits tokens into Peer Protocol
    start_cheat_caller_address(peer_protocol_address, lender);
    peer_protocol.deposit(token_address, token_amount);
    stop_cheat_caller_address(peer_protocol_address);
    assert!(lending_token.balance_of(lender) == mint_amount - token_amount, "deposit failed");
    assert!(
        lending_token.balance_of(peer_protocol_address) == token_amount, "wrong contract balance"
    );

    // Create lending proposal
    start_cheat_caller_address(peer_protocol_address, lender);
    let mut spy = spy_events();

    peer_protocol.create_lending_proposal(
        token_address,
        collateral_token_address,
        lending_amount, // Lending amount in dollars
        interest_rate,
        duration,
    );

    // Check emitted event
    let created_at = starknet::get_block_timestamp();
    let expected_event = PeerProtocol::Event::LendingProposalCreated(
        PeerProtocol::LendingProposalCreated {
            proposal_type: ProposalType::LENDING,
            lender,
            token: token_address,
            amount: lending_amount,
            interest_rate,
            duration,
            created_at,
        }
    );
    spy.assert_emitted(@array![(peer_protocol_address, expected_event)]);

    stop_cheat_caller_address(peer_protocol_address);
}

#[test]
#[fork(url: "https://starknet-mainnet.blastapi.io/138dbf54-8751-4a78-a709-07ee952e5d15/rpc/v0_7", block_tag: latest)]
fn test_cancel_proposal() {
    // Setup
    let token_address = deploy_token("MockToken");
    let collateral_token_address = deploy_token("MockToken1");
    let peer_protocol_address = deploy_peer_protocol();

    let lending_token = IERC20Dispatcher { contract_address: token_address };
    let peer_protocol = IPeerProtocolDispatcher { contract_address: peer_protocol_address };

    let owner: ContractAddress = starknet::contract_address_const::<0x123626789>();
    let lender: ContractAddress = starknet::contract_address_const::<0x122226789>();

    let mint_amount: u256 = 1000 * ONE_E18;
    let lending_amount: u256 = 500 * ONE_E18;
    let interest_rate: u64 = 5;
    let duration: u64 = 10;

    // Add supported tokens
    start_cheat_caller_address(peer_protocol_address, owner);
    peer_protocol.add_supported_token(token_address, 'STRK/USD');
    peer_protocol.add_supported_token(collateral_token_address, 'STRK/USD');
    stop_cheat_caller_address(peer_protocol_address);

    lending_token.mint(lender, mint_amount);
    assert!(lending_token.balance_of(lender) == mint_amount, "mint failed");

    // Approve contract to spend lending token : Needs to be done before deposits
    start_cheat_caller_address(token_address, lender);
    lending_token.approve(peer_protocol_address, mint_amount);
    stop_cheat_caller_address(token_address);

    // Lender Deposit Token into Peer Protocol
    start_cheat_caller_address(peer_protocol_address, lender);
    peer_protocol.deposit(token_address, lending_amount);
    stop_cheat_caller_address(peer_protocol_address);
    assert!(lending_token.balance_of(lender) == mint_amount - lending_amount, "deposit failed");
    assert!(
        lending_token.balance_of(peer_protocol_address) == lending_amount, "wrong contract balance"
    );

    // Create lending proposal
    start_cheat_caller_address(peer_protocol_address, lender);

    peer_protocol
        .create_lending_proposal(
            token_address,
            collateral_token_address,
            lending_amount,
            interest_rate,
            duration
        );

    let lending_proposals = peer_protocol.get_lending_proposal_details();
    let lender_locked_funds = peer_protocol.get_locked_funds(lender, token_address);
    assert!(lending_proposals.len() == 1, "wrong number of lending proposals");
    assert!(*lending_proposals.at(0).is_cancelled == false, "Wrong value for is_cancelled");
    assert!(lender_locked_funds == lending_amount, "Wrong locked fund value");

    // Cancel Proposal
    let proposal_id = *lending_proposals.at(0).id;
    peer_protocol.cancel_proposal(proposal_id);

    let updated_lending_proposal = peer_protocol.get_lending_proposal_details();
    let updated_locked_funds = peer_protocol.get_locked_funds(lender, token_address);
    assert!(*updated_lending_proposal.at(0).is_cancelled == true, "Cancellation failed");
    assert!(updated_locked_funds == 0, "locked amount invalid");

    stop_cheat_caller_address(peer_protocol_address);
}

#[test]
#[fork(url: "https://starknet-mainnet.blastapi.io/138dbf54-8751-4a78-a709-07ee952e5d15/rpc/v0_7", block_tag: latest)]
fn test_get_borrow_proposal_details() {
    let token_address = deploy_token("MockToken");
    let collateral_token_address = deploy_token("MockToken1");
    let peer_protocol_address = deploy_peer_protocol();

    let collateral_token = IERC20Dispatcher { contract_address: collateral_token_address };
    let peer_protocol = IPeerProtocolDispatcher { contract_address: peer_protocol_address };

    let owner: ContractAddress = starknet::contract_address_const::<0x123626789>();
    let borrower: ContractAddress = starknet::contract_address_const::<0x122226789>();

    let mint_amount: u256 = 1000 * ONE_E18;
    let borrow_amount: u256 = 500 * ONE_E18;
    let interest_rate: u64 = 5;
    let duration: u64 = 10;

    // Add supported tokens to peer protocol contract
    start_cheat_caller_address(peer_protocol_address, owner);
    peer_protocol.add_supported_token(token_address, 'STRK/USD');
    peer_protocol.add_supported_token(collateral_token_address, 'STRK/USD');
    stop_cheat_caller_address(peer_protocol_address);

    // Mint collateral token to borrower
    collateral_token.mint(borrower, mint_amount);

    // Approve peer protocol contract to spend collateral token
    start_cheat_caller_address(collateral_token_address, borrower);
    collateral_token.approve(peer_protocol_address, mint_amount);
    stop_cheat_caller_address(collateral_token_address);

    // Deposit collateral token into peer protocol before creating borrow proposal
    start_cheat_caller_address(peer_protocol_address, borrower);
    peer_protocol.deposit(collateral_token_address, mint_amount);
    stop_cheat_caller_address(peer_protocol_address);

    // Create multiple borrow proposals
    start_cheat_caller_address(peer_protocol_address, borrower);
    peer_protocol
        .create_borrow_proposal(
            token_address,
            collateral_token_address,
            borrow_amount,
            interest_rate,
            duration
        );

    // Create another borrow proposal with different parameters
    let another_borrow_amount = 250 * ONE_E18;
    let another_interest_rate: u64 = 3;
    let another_duration: u64 = 7;
    peer_protocol
        .create_borrow_proposal(
            token_address,
            collateral_token_address,
            another_borrow_amount,
            another_interest_rate,
            another_duration
        );
    stop_cheat_caller_address(peer_protocol_address);

    // Retrieve borrow proposals
    let borrow_proposals = peer_protocol.get_borrow_proposal_details();

    // Assertions
    assert!(borrow_proposals.len() == 2, "Incorrect number of borrow proposals");
    assert!(*borrow_proposals.at(0).borrower == borrower, "Wrong borrower");
    assert!(*borrow_proposals.at(1).borrower == borrower, "Wrong borrower");
    assert!(*borrow_proposals.at(0).amount == borrow_amount, "Wrong borrow amount1");
    assert!(*borrow_proposals.at(1).amount == another_borrow_amount, "Wrong borrow amount2");
}


#[test]
#[fork(url: "https://starknet-mainnet.blastapi.io/138dbf54-8751-4a78-a709-07ee952e5d15/rpc/v0_7", block_tag: latest)]
fn test_create_counter_proposal() {
    // Setup
    let token_address = deploy_token("MockToken");
    let collateral_token_address = deploy_token("MockToken1");
    let peer_protocol_address = deploy_peer_protocol();

    let lending_token = IERC20Dispatcher { contract_address: token_address };
    let collateral_token = IERC20Dispatcher { contract_address: collateral_token_address };
    let peer_protocol = IPeerProtocolDispatcher { contract_address: peer_protocol_address };

    let owner: ContractAddress = starknet::contract_address_const::<0x123626789>();
    let lender: ContractAddress = starknet::contract_address_const::<0x122226789>();
    let borrower: ContractAddress = starknet::contract_address_const::<0x122226737>();

    let mint_amount: u256 = 1000 * ONE_E18;
    let lending_amount: u256 = 500 * ONE_E18;
    let required_collateral_value: u256 = 300 * ONE_E18;
    let interest_rate: u64 = 5;
    let duration: u64 = 10;

    // Add supported tokens
    start_cheat_caller_address(peer_protocol_address, owner);
    peer_protocol.add_supported_token(token_address, 'STRK/USD');
    peer_protocol.add_supported_token(collateral_token_address, 'STRK/USD');
    stop_cheat_caller_address(peer_protocol_address);

    lending_token.mint(lender, mint_amount);
    assert!(lending_token.balance_of(lender) == mint_amount, "mint failed");

    // Approve contract to spend lending token : Needs to be done before deposits
    start_cheat_caller_address(token_address, lender);
    lending_token.approve(peer_protocol_address, mint_amount);
    stop_cheat_caller_address(token_address);

    // Lender Deposit Token into Peer Protocol
    start_cheat_caller_address(peer_protocol_address, lender);
    peer_protocol.deposit(token_address, lending_amount);
    stop_cheat_caller_address(peer_protocol_address);
    assert!(lending_token.balance_of(lender) == mint_amount - lending_amount, "deposit failed");
    assert!(
        lending_token.balance_of(peer_protocol_address) == lending_amount, "wrong contract balance"
    );

    // Create lending proposal
    start_cheat_caller_address(peer_protocol_address, lender);
    let mut spy = spy_events();

    let proposal_id = peer_protocol
        .create_lending_proposal(
            token_address,
            collateral_token_address,
            lending_amount,
            interest_rate,
            duration
        );

    stop_cheat_caller_address(peer_protocol_address);

    // Mint collateral token to borrower.
    collateral_token.mint(borrower, mint_amount);

    // Approve contract to spend collateral token : Needs to be done before deposits
    start_cheat_caller_address(collateral_token_address, borrower);
    collateral_token.approve(peer_protocol_address, mint_amount);
    stop_cheat_caller_address(collateral_token_address);

    // Borrower Deposit Collateral token before they can create counter proposal
    start_cheat_caller_address(peer_protocol_address, borrower);
    peer_protocol.deposit(collateral_token_address, mint_amount);
    stop_cheat_caller_address(peer_protocol_address);
    assert!(collateral_token.balance_of(borrower) == 0, "borrower deposit failed");
    assert!(
        collateral_token.balance_of(peer_protocol_address) == mint_amount,
        "wrong collateral balance"
    );

    // borrower creates counter proposal
    start_cheat_caller_address(peer_protocol_address, borrower);

    let counter_amount: u256 = 250 * ONE_E18;
    let counter_required_collateral_value: u256 = 200 * ONE_E18;
    let counter_interest_rate: u64 = 3;
    let counter_duration: u64 = 8;

    peer_protocol
        .create_counter_proposal(
            proposal_id,
            counter_amount,
            counter_required_collateral_value,
            counter_interest_rate,
            counter_duration
        );

    // Check emitted event
    let created_at = starknet::get_block_timestamp();
    let expected_event = PeerProtocol::Event::ProposalCountered(
        PeerProtocol::ProposalCountered {
            proposal_id,
            creator: borrower,
            amount: counter_amount,
            interest_rate: counter_interest_rate,
            duration: counter_duration,
            created_at,
        }
    );
    spy.assert_emitted(@array![(peer_protocol_address, expected_event)]);
}


#[test]
#[fork(url: "https://starknet-mainnet.blastapi.io/138dbf54-8751-4a78-a709-07ee952e5d15/rpc/v0_7", block_tag: latest)]
fn test_get_counter_proposals() {
    // Setup
    let token_address = deploy_token("MockToken");
    let collateral_token_address = deploy_token("MockToken1");
    let peer_protocol_address = deploy_peer_protocol();

    let lending_token = IERC20Dispatcher { contract_address: token_address };
    let collateral_token = IERC20Dispatcher { contract_address: collateral_token_address };
    let peer_protocol = IPeerProtocolDispatcher { contract_address: peer_protocol_address };

    let owner: ContractAddress = starknet::contract_address_const::<0x123626789>();
    let lender: ContractAddress = starknet::contract_address_const::<0x122226789>();
    let borrower1: ContractAddress = starknet::contract_address_const::<0x122226737>();
    let borrower2: ContractAddress = starknet::contract_address_const::<0x122225637>();

    let mint_amount: u256 = 1000 * ONE_E18;
    let lending_amount: u256 = 500 * ONE_E18;
    let required_collateral_value: u256 = 300 * ONE_E18;
    let interest_rate: u64 = 5;
    let duration: u64 = 10;

    // Add supported tokens
    start_cheat_caller_address(peer_protocol_address, owner);
    peer_protocol.add_supported_token(token_address, 'STRK/USD');
    peer_protocol.add_supported_token(collateral_token_address, 'STRK/USD');
    stop_cheat_caller_address(peer_protocol_address);

    lending_token.mint(lender, mint_amount);
    assert!(lending_token.balance_of(lender) == mint_amount, "mint failed");

    // Approve contract to spend lending token : Needs to be done before deposits
    start_cheat_caller_address(token_address, lender);
    lending_token.approve(peer_protocol_address, mint_amount);
    stop_cheat_caller_address(token_address);

    // Lender Deposit Token into Peer Protocol
    start_cheat_caller_address(peer_protocol_address, lender);
    peer_protocol.deposit(token_address, lending_amount);
    stop_cheat_caller_address(peer_protocol_address);
    assert!(lending_token.balance_of(lender) == mint_amount - lending_amount, "deposit failed");
    assert!(
        lending_token.balance_of(peer_protocol_address) == lending_amount, "wrong contract balance"
    );

    // Create lending proposal
    start_cheat_caller_address(peer_protocol_address, lender);

    let proposal_id = peer_protocol
        .create_lending_proposal(
            token_address,
            collateral_token_address,
            lending_amount,
            interest_rate,
            duration
        );

    stop_cheat_caller_address(peer_protocol_address);

    // Mint collateral token to borrower.
    collateral_token.mint(borrower1, mint_amount);
    collateral_token.mint(borrower2, mint_amount);

    // Borrower1 Approve contract to spend collateral token : Needs to be done before deposits
    start_cheat_caller_address(collateral_token_address, borrower1);
    collateral_token.approve(peer_protocol_address, mint_amount);
    stop_cheat_caller_address(collateral_token_address);

    // Borrower1 Deposit Collateral token before they can create counter proposal
    start_cheat_caller_address(peer_protocol_address, borrower1);
    peer_protocol.deposit(collateral_token_address, mint_amount);
    stop_cheat_caller_address(peer_protocol_address);
    assert!(collateral_token.balance_of(borrower1) == 0, "borrower deposit failed");
    assert!(
        collateral_token.balance_of(peer_protocol_address) == mint_amount,
        "wrong collateral balance"
    );

    // Borrower2 Approve contract to spend collateral token : Needs to be done before deposits
    start_cheat_caller_address(collateral_token_address, borrower2);
    collateral_token.approve(peer_protocol_address, mint_amount);
    stop_cheat_caller_address(collateral_token_address);

    // Borrower2 Deposit Collateral token before they can create counter proposal
    start_cheat_caller_address(peer_protocol_address, borrower2);
    peer_protocol.deposit(collateral_token_address, mint_amount);
    stop_cheat_caller_address(peer_protocol_address);
    assert!(collateral_token.balance_of(borrower2) == 0, "borrower deposit failed");
    assert!(
        collateral_token.balance_of(peer_protocol_address) == mint_amount * 2,
        "wrong collateral balance"
    );

    // borrower1 creates counter proposal
    start_cheat_caller_address(peer_protocol_address, borrower1);

    let counter_amount: u256 = 250 * ONE_E18;
    let counter_required_collateral_value: u256 = 200 * ONE_E18;
    let counter_interest_rate: u64 = 3;
    let counter_duration: u64 = 8;

    peer_protocol
        .create_counter_proposal(
            proposal_id,
            counter_amount,
            counter_required_collateral_value,
            counter_interest_rate,
            counter_duration
        );

    stop_cheat_caller_address(peer_protocol_address);

    // borrower2 creates counter proposal
    start_cheat_caller_address(peer_protocol_address, borrower2);

    let counter_amount_2: u256 = 400 * ONE_E18;
    let counter_required_collateral_value_2: u256 = 300 * ONE_E18;
    let counter_interest_rate_2: u64 = 7;
    let counter_duration_2: u64 = 30;

    peer_protocol
        .create_counter_proposal(
            proposal_id,
            counter_amount_2,
            counter_required_collateral_value_2,
            counter_interest_rate_2,
            counter_duration_2
        );

    stop_cheat_caller_address(peer_protocol_address);

    // Retrieve counter proposals
    let counter_proposals = peer_protocol.get_counter_proposals(proposal_id);

    // Assertions
    assert!(counter_proposals.len() == 2, "Incorrect number counter of proposals");
}

#[test]
#[should_panic(expected: "Token not supported")]
fn test_create_borrow_proposal_should_panic_for_unsupported_token() {
    let token_address = deploy_token("MockToken");
    let collateral_token_address = deploy_token("MockToken1");
    let peer_protocol_address = deploy_peer_protocol();

    let token = IERC20Dispatcher { contract_address: token_address };
    let collateral_token = IERC20Dispatcher { contract_address: collateral_token_address };
    let peer_protocol = IPeerProtocolDispatcher { contract_address: peer_protocol_address };

    let owner: ContractAddress = starknet::contract_address_const::<0x123626789>();
    let borrower: ContractAddress = starknet::contract_address_const::<0x122226789>();

    let mint_amount: u256 = 1000 * ONE_E18;
    let borrow_amount: u256 = 500 * ONE_E18;
    let interest_rate: u64 = 5;
    let duration: u64 = 10;
    let required_collateral_value: u256 = 300 * ONE_E18;
    // Add supported token
    start_cheat_caller_address(peer_protocol_address, owner);
    peer_protocol.add_supported_token(token_address, 0);
    peer_protocol.add_supported_token(collateral_token_address, 0);
    stop_cheat_caller_address(peer_protocol_address);

    token.mint(borrower, mint_amount);
    collateral_token.mint(borrower, mint_amount);

    // Approve the peer_protocol contract to spend tokens
    start_cheat_caller_address(token_address, borrower);
    token.approve(peer_protocol_address, mint_amount);
    stop_cheat_caller_address(token_address);

    // Approve the peer_protocol contract to spend collateral tokens
    start_cheat_caller_address(collateral_token_address, borrower);
    collateral_token.approve(peer_protocol_address, mint_amount);
    stop_cheat_caller_address(collateral_token_address);

    // Simulate using an unsupported token address
    let unsupported_token_address: ContractAddress = starknet::contract_address_const::<
        0x0
    >(); // Invalid token address

    start_cheat_caller_address(peer_protocol_address, borrower);

    peer_protocol
        .create_borrow_proposal(
            unsupported_token_address,
            collateral_token_address,
            borrow_amount,
            interest_rate,
            duration
        );

    stop_cheat_caller_address(peer_protocol_address);
}

#[test]
#[fork(url: "https://starknet-mainnet.blastapi.io/138dbf54-8751-4a78-a709-07ee952e5d15/rpc/v0_7", block_tag: latest)]
fn test_get_lending_proposal_details() {
    // Setup
    let token_address = deploy_token("MockToken");
    let collateral_token_address = deploy_token("MockToken1");
    let peer_protocol_address = deploy_peer_protocol();

    let lending_token = IERC20Dispatcher { contract_address: token_address };
    let peer_protocol = IPeerProtocolDispatcher { contract_address: peer_protocol_address };

    let owner: ContractAddress = starknet::contract_address_const::<0x123626789>();
    let lender: ContractAddress = starknet::contract_address_const::<0x122226789>();

    let mint_amount: u256 = 1000 * ONE_E18;
    let lending_amount: u256 = 500 * ONE_E18;
    let required_collateral_value: u256 = 300 * ONE_E18;
    let interest_rate: u64 = 5;
    let duration: u64 = 10;

    // Add supported tokens
    start_cheat_caller_address(peer_protocol_address, owner);
    peer_protocol.add_supported_token(token_address, 'STRK/USD');
    peer_protocol.add_supported_token(collateral_token_address, 'STRK/USD');
    stop_cheat_caller_address(peer_protocol_address);

    lending_token.mint(lender, mint_amount);
    assert!(lending_token.balance_of(lender) == mint_amount, "mint failed");

    // Approve contract to spend lending token : Needs to be done before deposits
    start_cheat_caller_address(token_address, lender);
    lending_token.approve(peer_protocol_address, mint_amount);
    stop_cheat_caller_address(token_address);

    // Lender Deposit Token into Peer Protocol
    start_cheat_caller_address(peer_protocol_address, lender);
    peer_protocol.deposit(token_address, mint_amount);
    stop_cheat_caller_address(peer_protocol_address);
    assert!(lending_token.balance_of(lender) == 0, "deposit failed");
    assert!(
        lending_token.balance_of(peer_protocol_address) == mint_amount, "wrong contract balance"
    );

    // Create lending proposal
    start_cheat_caller_address(peer_protocol_address, lender);

    peer_protocol
        .create_lending_proposal(
            token_address,
            collateral_token_address,
            lending_amount,
            interest_rate,
            duration
        );

    // Create another lending proposal with different parameters
    let another_lending_amount: u256 = 250 * ONE_E18;
    let another_interest_rate: u64 = 3;
    let another_duration: u64 = 7;
    peer_protocol
        .create_lending_proposal(
            token_address,
            collateral_token_address,
            another_lending_amount,
            another_interest_rate,
            another_duration
        );

    let lending_proposals = peer_protocol.get_lending_proposal_details();

    assert!(lending_proposals.len() == 2, "Incorrect number of lending proposals");
    assert!(*lending_proposals.at(0).lender == lender, "Wrong lender");
    assert!(*lending_proposals.at(1).lender == lender, "Wrong lender");
    assert!(*lending_proposals.at(0).amount == lending_amount, "Wrong lending amount1");
    assert!(*lending_proposals.at(1).amount == another_lending_amount, "Wrong lending amount2");
}

#[test]
#[fork(url: "https://starknet-mainnet.blastapi.io/138dbf54-8751-4a78-a709-07ee952e5d15/rpc/v0_7", block_tag: latest)]
fn test_repay_proposal() {
    let token_address = deploy_token("MockToken");
    let collateral_token_address = deploy_token("MockToken1");
    let peer_protocol_address = deploy_peer_protocol();

    let token = IERC20Dispatcher { contract_address: token_address };
    let collateral_token = IERC20Dispatcher { contract_address: collateral_token_address };
    let peer_protocol = IPeerProtocolDispatcher { contract_address: peer_protocol_address };

    let owner = starknet::contract_address_const::<0x123626789>();
    let borrower = starknet::contract_address_const::<0x122226789>();
    let lender = starknet::contract_address_const::<0x123336789>();

    let mint_amount: u256 = 1000 * ONE_E18;
    let borrow_amount: u256 = 500 * ONE_E18;
    let interest_rate: u64 = 5;
    let duration: u64 = 10;
    let required_collateral_value = 300 * ONE_E18;
    let collateral_value_with_ratio = (required_collateral_value * COLLATERAL_RATIO_NUMERATOR)
        / COLLATERAL_RATIO_DENOMINATOR;

    // Add supported token
    start_cheat_caller_address(peer_protocol_address, owner);
    peer_protocol.add_supported_token(token_address, 'STRK/USD');
    peer_protocol.add_supported_token(collateral_token_address, 'STRK/USD');
    stop_cheat_caller_address(peer_protocol_address);

    token.mint(borrower, mint_amount);
    collateral_token.mint(borrower, mint_amount);
    token.mint(lender, borrow_amount);

    // Approve token
    start_cheat_caller_address(token_address, borrower);
    token.approve(peer_protocol_address, mint_amount);
    stop_cheat_caller_address(token_address);

    // Approve collateral token
    start_cheat_caller_address(collateral_token_address, borrower);
    collateral_token.approve(peer_protocol_address, mint_amount);
    stop_cheat_caller_address(collateral_token_address);

    // Borrower Deposit collateral
    start_cheat_caller_address(peer_protocol_address, borrower);
    peer_protocol.deposit(collateral_token_address, collateral_value_with_ratio);
    stop_cheat_caller_address(peer_protocol_address);

    // Borrower creates a borrow proposal
    start_cheat_caller_address(peer_protocol_address, borrower);
    let proposal_id = peer_protocol
        .create_borrow_proposal(
            token_address,
            collateral_token_address,
            borrow_amount,
            interest_rate,
            duration
        );
    stop_cheat_caller_address(peer_protocol_address);

    // Lender deposits token
    start_cheat_caller_address(token_address, lender);
    token.approve(peer_protocol_address, borrow_amount);
    stop_cheat_caller_address(token_address);

    start_cheat_caller_address(peer_protocol_address, lender);
    peer_protocol.deposit(token_address, borrow_amount);
    stop_cheat_caller_address(peer_protocol_address);

    // Lender accepts the borrow proposal
    start_cheat_caller_address(peer_protocol_address, lender);
    peer_protocol.accept_proposal(proposal_id);
    stop_cheat_caller_address(peer_protocol_address);

    let balance_before_repay = token.balance_of(borrower);

    // Borrower repays loan
    start_cheat_caller_address(peer_protocol_address, borrower);
    start_cheat_block_timestamp(peer_protocol_address, get_block_timestamp() + duration * 86400);
    let mut spy = spy_events();
    peer_protocol.repay_proposal(proposal_id);
    stop_cheat_caller_address(peer_protocol_address);

    // Get lender assets
    let user_assets = peer_protocol.get_user_assets(lender);
    let interest_earned = *user_assets[0].interest_earned;
    let fee_amount = (borrow_amount * PeerProtocol::PROTOCOL_FEE_PERCENTAGE) / 100;
    let net_amount = borrow_amount - fee_amount;
    let repaid_amount = net_amount + interest_earned;

    // Check borrower balance after repayment
    let balance_after_repay = token.balance_of(borrower);
    assert_eq!(balance_after_repay, balance_before_repay - repaid_amount);

    // Check emitted event
    let expected_event = PeerProtocol::Event::ProposalRepaid(
        PeerProtocol::ProposalRepaid {
            proposal_type: ProposalType::BORROWING,
            repaid_by: borrower,
            token: token_address,
            amount: repaid_amount
        }
    );
    spy.assert_emitted(@array![(peer_protocol_address, expected_event)]);
}

#[test]
fn test_deploy_liquidity_pool() {
    // Setup
    let token_address = deploy_token("MockToken");
    let collateral_token_address = deploy_token("MockToken1");
    let peer_protocol_address = deploy_peer_protocol();

    let peer_protocol = IPeerProtocolDispatcher { contract_address: peer_protocol_address };

    let owner: ContractAddress = starknet::contract_address_const::<0x123626789>();

    //add supported token
    start_cheat_caller_address(peer_protocol_address, owner);
    peer_protocol.add_supported_token(token_address, 0);
    peer_protocol.add_supported_token(collateral_token_address, 0);
    stop_cheat_caller_address(peer_protocol_address);

    // deploy pool token
    start_cheat_caller_address(peer_protocol_address, owner);
    peer_protocol.deploy_liquidity_pool(token_address);
    stop_cheat_caller_address(peer_protocol_address);

    // get pool data and check
    let pool_data = peer_protocol.get_liquidity_pool_data(token_address);
    assert!(pool_data.pool_token != Zero::zero(), "Pool token address is zero");
    assert!(pool_data.is_active, "Pool is not deployed")
}

#[test]
#[fork(url: "https://starknet-mainnet.blastapi.io/138dbf54-8751-4a78-a709-07ee952e5d15/rpc/v0_7", block_tag: latest)]
fn test_get_token_price_success() {
    let peer_protocol_address = deploy_peer_protocol();
    let peer_protocol = IPeerProtocolDispatcher { contract_address: peer_protocol_address };

    let strk_token = starknet::contract_address_const::<'STARK_TOKEN'>();
    let owner: ContractAddress = starknet::contract_address_const::<0x123626789>();
    let asset_id = 'STRK/USD';

    start_cheat_caller_address(peer_protocol_address, owner);
    peer_protocol.add_supported_token(strk_token, asset_id);

    let token_price = peer_protocol.get_token_price(strk_token);
    println!("STRK price: {} USD", token_price);
    assert_ge!(token_price, 0);
}
