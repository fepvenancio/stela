// StelaGenesis — ERC721 Genesis NFT Mint Contract
// 300 max supply, sequential IDs 1-300, ERC20 payment (STRK token).

#[starknet::contract]
pub mod StelaGenesis {
    use core::num::traits::Zero;
    use openzeppelin_access::ownable::OwnableComponent;
    use openzeppelin_interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use openzeppelin_introspection::src5::SRC5Component;
    use openzeppelin_security::pausable::PausableComponent;
    use openzeppelin_token::erc721::{ERC721Component, ERC721HooksEmptyImpl};
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use starknet::{ContractAddress, get_caller_address};

    /// Maximum number of NFTs that can be minted in a single batch transaction.
    const MAX_BATCH_SIZE: u256 = 5;

    /// Maximum number of NFTs a single wallet can hold from public minting.
    const MAX_PER_WALLET: u256 = 5;

    /// Number of NFTs reserved for treasury, minted on deployment.
    const TREASURY_RESERVE: u256 = 50;

    // Component declarations
    component!(path: ERC721Component, storage: erc721, event: ERC721Event);
    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);
    component!(path: SRC5Component, storage: src5, event: SRC5Event);
    component!(path: PausableComponent, storage: pausable, event: PausableEvent);

    // ERC721 Mixin — exposes standard ERC721 + ERC721Metadata + SRC5 functions externally
    #[abi(embed_v0)]
    impl ERC721MixinImpl = ERC721Component::ERC721MixinImpl<ContractState>;
    impl ERC721InternalImpl = ERC721Component::InternalImpl<ContractState>;

    // Ownable
    #[abi(embed_v0)]
    impl OwnableMixinImpl = OwnableComponent::OwnableMixinImpl<ContractState>;
    impl OwnableInternalImpl = OwnableComponent::InternalImpl<ContractState>;

    // Pausable
    impl PausableInternalImpl = PausableComponent::InternalImpl<ContractState>;

    // ============================================================
    //                          STORAGE
    // ============================================================

    #[storage]
    struct Storage {
        // OZ components
        #[substorage(v0)]
        erc721: ERC721Component::Storage,
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
        #[substorage(v0)]
        src5: SRC5Component::Storage,
        #[substorage(v0)]
        pausable: PausableComponent::Storage,
        // Mint state
        total_minted: u256,
        mint_price: u256,
        payment_token: ContractAddress,
        mint_recipient: ContractAddress,
        max_supply: u256,
        mint_enabled: bool,
    }

    // ============================================================
    //                          EVENTS
    // ============================================================

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        #[flat]
        ERC721Event: ERC721Component::Event,
        #[flat]
        OwnableEvent: OwnableComponent::Event,
        #[flat]
        SRC5Event: SRC5Component::Event,
        #[flat]
        PausableEvent: PausableComponent::Event,
        Minted: Minted,
    }

    #[derive(Drop, starknet::Event)]
    pub struct Minted {
        #[key]
        pub token_id: u256,
        #[key]
        pub minter: ContractAddress,
        pub price: u256,
    }

    // ============================================================
    //                        CONSTRUCTOR
    // ============================================================

    #[constructor]
    fn constructor(
        ref self: ContractState,
        owner: ContractAddress,
        payment_token: ContractAddress,
        mint_recipient: ContractAddress,
        treasury: ContractAddress,
        base_uri: ByteArray,
    ) {
        assert(!owner.is_zero(), 'GENESIS: invalid owner');
        assert(!payment_token.is_zero(), 'GENESIS: invalid token');
        assert(!mint_recipient.is_zero(), 'GENESIS: invalid recipient');
        assert(!treasury.is_zero(), 'GENESIS: invalid treasury');

        self.erc721.initializer("Stela Genesis", "SGEN", base_uri);
        self.ownable.initializer(owner);
        self.max_supply.write(300);
        self.mint_price.write(1_000_000_000_000_000_000_000); // 1,000 STRK (18 decimals)
        self.payment_token.write(payment_token);
        self.mint_recipient.write(mint_recipient);
        self.mint_enabled.write(false);
        self.total_minted.write(0);

        // Mint treasury reserve on deployment (50 NFTs, IDs 1-50)
        let mut i: u256 = 0;
        while i < TREASURY_RESERVE {
            self._mint_one(treasury, false);
            i += 1;
        };
    }

    // ============================================================
    //                    EXTERNAL FUNCTIONS
    // ============================================================

    #[abi(embed_v0)]
    impl StelaGenesisImpl of crate::interfaces::igenesis::IStelaGenesis<ContractState> {
        fn mint(ref self: ContractState) {
            self.pausable.assert_not_paused();
            assert(self.mint_enabled.read(), 'GENESIS: mint disabled');

            let caller = get_caller_address();
            let balance = self.erc721.balance_of(caller);
            assert(balance < MAX_PER_WALLET, 'GENESIS: wallet limit reached');
            self._mint_one(caller, true);
        }

        fn mint_batch(ref self: ContractState, quantity: u256) {
            self.pausable.assert_not_paused();
            assert(self.mint_enabled.read(), 'GENESIS: mint disabled');
            assert(quantity > 0, 'GENESIS: zero quantity');
            assert(quantity <= MAX_BATCH_SIZE, 'GENESIS: exceeds batch limit');

            let caller = get_caller_address();
            let balance = self.erc721.balance_of(caller);
            assert(balance + quantity <= MAX_PER_WALLET, 'GENESIS: wallet limit reached');
            let mut i: u256 = 0;
            while i < quantity {
                self._mint_one(caller, true);
                i += 1;
            };
        }

        // --- Views ---

        fn total_minted(self: @ContractState) -> u256 {
            self.total_minted.read()
        }

        fn max_supply(self: @ContractState) -> u256 {
            self.max_supply.read()
        }

        fn mint_price(self: @ContractState) -> u256 {
            self.mint_price.read()
        }

        fn mint_enabled(self: @ContractState) -> bool {
            self.mint_enabled.read()
        }

        fn payment_token(self: @ContractState) -> ContractAddress {
            self.payment_token.read()
        }

        fn mint_recipient(self: @ContractState) -> ContractAddress {
            self.mint_recipient.read()
        }

        fn max_per_wallet(self: @ContractState) -> u256 {
            MAX_PER_WALLET
        }

        // --- Admin (owner only) ---

        fn set_mint_price(ref self: ContractState, price: u256) {
            self.ownable.assert_only_owner();
            self.mint_price.write(price);
        }

        fn set_mint_enabled(ref self: ContractState, enabled: bool) {
            self.ownable.assert_only_owner();
            self.mint_enabled.write(enabled);
        }

        fn set_mint_recipient(ref self: ContractState, recipient: ContractAddress) {
            self.ownable.assert_only_owner();
            assert(!recipient.is_zero(), 'GENESIS: invalid recipient');
            self.mint_recipient.write(recipient);
        }

        fn set_base_uri(ref self: ContractState, base_uri: ByteArray) {
            self.ownable.assert_only_owner();
            self.erc721._set_base_uri(base_uri);
        }

        fn admin_mint(ref self: ContractState, to: ContractAddress, quantity: u256) {
            self.ownable.assert_only_owner();
            assert(!to.is_zero(), 'GENESIS: invalid address');
            assert(quantity > 0, 'GENESIS: zero quantity');
            let remaining = self.max_supply.read() - self.total_minted.read();
            assert(quantity <= remaining, 'GENESIS: exceeds remaining');

            let mut i: u256 = 0;
            while i < quantity {
                self._mint_one(to, false);
                i += 1;
            };
        }
    }

    // ============================================================
    //                    ADMIN: PAUSE / UNPAUSE
    // ============================================================

    #[external(v0)]
    fn pause(ref self: ContractState) {
        self.ownable.assert_only_owner();
        self.pausable.pause();
    }

    #[external(v0)]
    fn unpause(ref self: ContractState) {
        self.ownable.assert_only_owner();
        self.pausable.unpause();
    }

    // ============================================================
    //                    INTERNAL FUNCTIONS
    // ============================================================

    #[generate_trait]
    impl InternalImpl of InternalTrait {
        /// Mint a single token. If `collect_payment` is true, pulls ERC20 from the caller.
        fn _mint_one(ref self: ContractState, to: ContractAddress, collect_payment: bool) {
            let minted = self.total_minted.read();
            assert(minted < self.max_supply.read(), 'GENESIS: sold out');

            let token_id = minted + 1;
            let price = self.mint_price.read();

            if collect_payment && price > 0 {
                let caller = get_caller_address();
                let token = IERC20Dispatcher { contract_address: self.payment_token.read() };
                token.transfer_from(caller, self.mint_recipient.read(), price);
            }

            self.erc721.mint(to, token_id);
            self.total_minted.write(token_id);

            self.emit(Minted { token_id, minter: to, price: if collect_payment { price } else { 0 } });
        }
    }
}
