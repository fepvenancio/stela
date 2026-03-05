// FeeVault — Multi-token fee distribution contract for Genesis NFT holders.
// Uses cumulative sum (MasterChef-style) pattern for gas-efficient claims.
// Each ERC20 has an independent cumulative counter. All 500 NFTs have equal weight.

#[starknet::contract]
pub mod FeeVault {
    use core::num::traits::Zero;
    use openzeppelin_access::ownable::OwnableComponent;
    use openzeppelin_interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use openzeppelin_interfaces::erc721::{IERC721Dispatcher, IERC721DispatcherTrait};
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };
    use starknet::{ContractAddress, get_caller_address, get_contract_address};

    // Ownable component
    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);

    #[abi(embed_v0)]
    impl OwnableMixinImpl = OwnableComponent::OwnableMixinImpl<ContractState>;
    impl OwnableInternalImpl = OwnableComponent::InternalImpl<ContractState>;

    // ============================================================
    //                          STORAGE
    // ============================================================

    #[storage]
    struct Storage {
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
        // The Genesis NFT contract (for ownership checks)
        genesis_nft: ContractAddress,
        // Total NFT supply (fixed at 500, stored for flexibility)
        total_nfts: u256,
        // List of registered fee tokens (for enumeration during claim)
        fee_tokens: Map<u32, ContractAddress>,
        fee_token_count: u32,
        is_fee_token: Map<ContractAddress, bool>,
        // Cumulative fee per NFT for each token
        cumulative_per_nft: Map<ContractAddress, u256>,
        // Last claimed cumulative value per NFT per token
        claimed_per_nft: Map<(ContractAddress, u256), u256>,
        // Dust accumulator: remainder from integer division (deposit_amount % total_nfts)
        dust: Map<ContractAddress, u256>,
        // The authorized Stela contract that can call deposit()
        stela_contract: ContractAddress,
    }

    // ============================================================
    //                          EVENTS
    // ============================================================

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        #[flat]
        OwnableEvent: OwnableComponent::Event,
        Deposited: Deposited,
        Claimed: Claimed,
        TokenRegistered: TokenRegistered,
    }

    #[derive(Drop, starknet::Event)]
    pub struct Deposited {
        #[key]
        pub token: ContractAddress,
        pub amount: u256,
        pub per_nft: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct Claimed {
        #[key]
        pub token_id: u256,
        #[key]
        pub token: ContractAddress,
        pub amount: u256,
        pub recipient: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct TokenRegistered {
        #[key]
        pub token: ContractAddress,
        pub index: u32,
    }

    // ============================================================
    //                          ERRORS
    // ============================================================

    pub mod Errors {
        pub const INVALID_ADDRESS: felt252 = 'VAULT: invalid address';
        pub const ZERO_NFTS: felt252 = 'VAULT: zero nfts';
        pub const ZERO_AMOUNT: felt252 = 'VAULT: zero amount';
        pub const NOT_OWNER: felt252 = 'VAULT: not owner';
        pub const TOKEN_REGISTERED: felt252 = 'VAULT: token registered';
        pub const NOT_GENESIS: felt252 = 'VAULT: not genesis contract';
        pub const UNAUTHORIZED: felt252 = 'VAULT: unauthorized caller';
        pub const INVALID_TOKEN: felt252 = 'VAULT: token not registered';
    }

    // ============================================================
    //                        CONSTRUCTOR
    // ============================================================

    #[constructor]
    fn constructor(
        ref self: ContractState,
        owner: ContractAddress,
        genesis_nft: ContractAddress,
        total_nfts: u256,
        stela_contract: ContractAddress,
    ) {
        self.ownable.initializer(owner);
        assert(!genesis_nft.is_zero(), Errors::INVALID_ADDRESS);
        assert(!stela_contract.is_zero(), Errors::INVALID_ADDRESS);
        assert(total_nfts > 0, Errors::ZERO_NFTS);
        self.genesis_nft.write(genesis_nft);
        self.total_nfts.write(total_nfts);
        self.stela_contract.write(stela_contract);
        self.fee_token_count.write(0);
    }

    // ============================================================
    //                     EXTERNAL FUNCTIONS
    // ============================================================

    #[abi(embed_v0)]
    impl FeeVaultImpl of crate::interfaces::ifee_vault::IFeeVault<ContractState> {
        fn deposit(ref self: ContractState, token: ContractAddress, amount: u256) {
            // Only the Stela contract can deposit fees
            let caller = get_caller_address();
            assert(caller == self.stela_contract.read(), Errors::UNAUTHORIZED);

            assert(amount > 0, Errors::ZERO_AMOUNT);

            let total_nfts = self.total_nfts.read();

            // Token must be pre-registered by owner
            assert(self.is_fee_token.read(token), Errors::INVALID_TOKEN);

            // Pull tokens from caller
            let erc20 = IERC20Dispatcher { contract_address: token };
            erc20.transfer_from(get_caller_address(), get_contract_address(), amount);

            // Add any accumulated dust from previous deposits
            let prev_dust = self.dust.read(token);
            let total = amount + prev_dust;

            // Calculate per-NFT share and new dust
            let per_nft = total / total_nfts;
            let new_dust = total % total_nfts;

            // Update cumulative counter
            if per_nft > 0 {
                let current = self.cumulative_per_nft.read(token);
                self.cumulative_per_nft.write(token, current + per_nft);
            }

            // Store remaining dust
            self.dust.write(token, new_dust);

            self.emit(Deposited { token, amount, per_nft });
        }

        fn claim(ref self: ContractState, token_id: u256) {
            let owner = self._assert_nft_owner(token_id);

            let count = self.fee_token_count.read();
            let mut i: u32 = 0;
            while i < count {
                let token = self.fee_tokens.read(i);
                self._claim_single(token_id, token, owner);
                i += 1;
            };
        }

        fn claim_token(ref self: ContractState, token_id: u256, token: ContractAddress) {
            let owner = self._assert_nft_owner(token_id);
            self._claim_single(token_id, token, owner);
        }

        fn claim_batch(ref self: ContractState, token_ids: Array<u256>) {
            let caller = get_caller_address();
            let nft = IERC721Dispatcher { contract_address: self.genesis_nft.read() };
            let count = self.fee_token_count.read();

            let mut t: u32 = 0;
            while t < token_ids.len() {
                let token_id = *token_ids.at(t);
                let owner = nft.owner_of(token_id);
                assert(caller == owner, Errors::NOT_OWNER);

                let mut i: u32 = 0;
                while i < count {
                    let token = self.fee_tokens.read(i);
                    self._claim_single(token_id, token, owner);
                    i += 1;
                };
                t += 1;
            };
        }

        // --- Views ---

        fn claimable(self: @ContractState, token_id: u256, token: ContractAddress) -> u256 {
            let cumulative = self.cumulative_per_nft.read(token);
            let claimed = self.claimed_per_nft.read((token, token_id));
            cumulative - claimed
        }

        fn claimable_all(
            self: @ContractState, token_id: u256,
        ) -> (Array<ContractAddress>, Array<u256>) {
            let count = self.fee_token_count.read();
            let mut tokens: Array<ContractAddress> = array![];
            let mut amounts: Array<u256> = array![];

            let mut i: u32 = 0;
            while i < count {
                let token = self.fee_tokens.read(i);
                let cumulative = self.cumulative_per_nft.read(token);
                let claimed = self.claimed_per_nft.read((token, token_id));
                tokens.append(token);
                amounts.append(cumulative - claimed);
                i += 1;
            };

            (tokens, amounts)
        }

        fn cumulative_per_nft(self: @ContractState, token: ContractAddress) -> u256 {
            self.cumulative_per_nft.read(token)
        }

        fn get_fee_tokens(self: @ContractState) -> Array<ContractAddress> {
            let count = self.fee_token_count.read();
            let mut tokens: Array<ContractAddress> = array![];
            let mut i: u32 = 0;
            while i < count {
                tokens.append(self.fee_tokens.read(i));
                i += 1;
            };
            tokens
        }

        fn get_genesis_nft(self: @ContractState) -> ContractAddress {
            self.genesis_nft.read()
        }

        // --- Admin ---

        fn register_token(ref self: ContractState, token: ContractAddress) {
            self.ownable.assert_only_owner();
            assert(!self.is_fee_token.read(token), Errors::TOKEN_REGISTERED);
            self._register_token(token);
        }

        fn set_genesis_nft(ref self: ContractState, genesis_nft: ContractAddress) {
            self.ownable.assert_only_owner();
            assert(!genesis_nft.is_zero(), Errors::INVALID_ADDRESS);
            self.genesis_nft.write(genesis_nft);
        }

        fn set_stela_contract(ref self: ContractState, stela_contract: ContractAddress) {
            self.ownable.assert_only_owner();
            self.stela_contract.write(stela_contract);
        }

        fn get_stela_contract(self: @ContractState) -> ContractAddress {
            self.stela_contract.read()
        }

        fn snapshot_new_nft(ref self: ContractState, token_id: u256) {
            // Only the Genesis NFT contract can call this
            assert(get_caller_address() == self.genesis_nft.read(), Errors::NOT_GENESIS);

            // Set claimed checkpoint to current cumulative for all registered tokens
            // so this NFT only earns fees deposited after this point
            let count = self.fee_token_count.read();
            let mut i: u32 = 0;
            while i < count {
                let token = self.fee_tokens.read(i);
                let cumulative = self.cumulative_per_nft.read(token);
                self.claimed_per_nft.write((token, token_id), cumulative);
                i += 1;
            };
        }
    }

    // ============================================================
    //                     INTERNAL FUNCTIONS
    // ============================================================

    #[generate_trait]
    impl InternalImpl of InternalTrait {
        /// Verify caller owns the given NFT, returning the owner address.
        fn _assert_nft_owner(self: @ContractState, token_id: u256) -> ContractAddress {
            let nft = IERC721Dispatcher { contract_address: self.genesis_nft.read() };
            let owner = nft.owner_of(token_id);
            assert(get_caller_address() == owner, Errors::NOT_OWNER);
            owner
        }

        /// Claim a single token for a single NFT. Checks-effects-interactions pattern.
        fn _claim_single(
            ref self: ContractState,
            token_id: u256,
            token: ContractAddress,
            recipient: ContractAddress,
        ) {
            let cumulative = self.cumulative_per_nft.read(token);
            let claimed = self.claimed_per_nft.read((token, token_id));
            let claimable = cumulative - claimed;

            if claimable > 0 {
                // Effects: update claimed checkpoint before transfer
                self.claimed_per_nft.write((token, token_id), cumulative);

                // Interactions: transfer tokens to NFT owner
                let erc20 = IERC20Dispatcher { contract_address: token };
                erc20.transfer(recipient, claimable);

                self.emit(Claimed { token_id, token, amount: claimable, recipient });
            }
        }

        /// Register a new fee token for enumeration.
        fn _register_token(ref self: ContractState, token: ContractAddress) {
            let index = self.fee_token_count.read();
            self.fee_tokens.write(index, token);
            self.fee_token_count.write(index + 1);
            self.is_fee_token.write(token, true);
            self.emit(TokenRegistered { token, index });
        }
    }
}
