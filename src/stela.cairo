// Stela Protocol — Core Contract
// P2P inscriptions protocol for trustless lending, borrowing, and OTC swaps.

#[starknet::contract]
pub mod StelaProtocol {
    use core::hash::{HashStateExTrait, HashStateTrait};
    use core::num::traits::Zero;
    use core::poseidon::PoseidonTrait;
    use openzeppelin_access::ownable::OwnableComponent;
    use openzeppelin_interfaces::accounts::{ISRC6Dispatcher, ISRC6DispatcherTrait};
    use openzeppelin_interfaces::erc1155::{IERC1155Dispatcher, IERC1155DispatcherTrait};
    use openzeppelin_utils::cryptography::nonces::NoncesComponent;
    use openzeppelin_utils::cryptography::snip12::{OffchainMessageHash, StructHash};
    use crate::snip12::{InscriptionOrder, LendOffer, hash_assets};
    use crate::types::signed_order::SignedOrder;

    // Token dispatchers from openzeppelin_interfaces
    use openzeppelin_interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use openzeppelin_interfaces::erc721::{IERC721Dispatcher, IERC721DispatcherTrait};
    use openzeppelin_introspection::src5::SRC5Component;
    use openzeppelin_security::pausable::PausableComponent;
    use openzeppelin_security::reentrancyguard::ReentrancyGuardComponent;

    // OpenZeppelin components
    use openzeppelin_token::erc1155::{ERC1155Component, ERC1155HooksEmptyImpl};
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess, StoragePointerWriteAccess,
    };
    use starknet::{ContractAddress, get_block_timestamp, get_caller_address, get_contract_address};
    use crate::errors::Errors;
    use crate::interfaces::ierc721_mintable::{IERC721MintableDispatcher, IERC721MintableDispatcherTrait};
    use crate::interfaces::ilocker::{ILockerAccountDispatcher, ILockerAccountDispatcherTrait};
    use crate::interfaces::iregistry::{IRegistryDispatcher, IRegistryDispatcherTrait};
    use crate::types::inscription::{InscriptionParams, StoredInscription};

    // Local imports
    use crate::types::asset::{Asset, AssetType};
    use crate::utils::share_math::{MAX_BPS, calculate_fee_shares, convert_to_shares, scale_by_percentage};

    /// Maximum number of assets per type (debt, interest, collateral) in a single inscription.
    const MAX_ASSETS: u32 = 10;

    // Fee constants (in BPS)
    const SETTLE_FEE_BPS: u256 = 20;          // Total fee on settle/lending (5 relayer + 15 treasury)
    const SWAP_FEE_BPS: u256 = 10;             // Total fee on swap/duration=0 (5 relayer + 5 treasury)
    const REDEEM_FEE_BPS: u256 = 10;           // Total fee on redeem (10 treasury)
    const RELAYER_BPS: u256 = 5;               // Relayer portion (never discounted)
    const SETTLE_TREASURY_BASE: u256 = 15;     // Treasury base on settle (lending)
    const SWAP_TREASURY_BASE: u256 = 5;        // Treasury base on swap (duration=0)
    const REDEEM_TREASURY_BASE: u256 = 10;     // Treasury base on redeem
    const SETTLE_TREASURY_FLOOR: u256 = 10;    // Minimum treasury on settle after discount
    const SWAP_TREASURY_FLOOR: u256 = 3;       // Minimum treasury on swap after discount
    const REDEEM_TREASURY_FLOOR: u256 = 5;     // Minimum treasury on redeem after discount

    // Discount constants
    const BASE_NFT_DISCOUNT_PCT: u256 = 15;    // 15% discount for holding any Genesis NFT
    const VOLUME_TIER_DISCOUNT_PCT: u256 = 5;  // 5% per volume tier
    const MULTI_NFT_DISCOUNT_PCT: u256 = 2;    // 2% per additional NFT held
    const MAX_DISCOUNT_PCT: u256 = 50;          // Maximum 50% total discount

    // Volume tier thresholds (in wei, 18 decimals)
    // $10K, $25K, $50K, $100K, $250K, $500K, $1M
    const TIER_1: u256 = 10_000_000_000_000_000_000_000;
    const TIER_2: u256 = 25_000_000_000_000_000_000_000;
    const TIER_3: u256 = 50_000_000_000_000_000_000_000;
    const TIER_4: u256 = 100_000_000_000_000_000_000_000;
    const TIER_5: u256 = 250_000_000_000_000_000_000_000;
    const TIER_6: u256 = 500_000_000_000_000_000_000_000;
    const TIER_7: u256 = 1_000_000_000_000_000_000_000_000;

    // Component declarations
    component!(path: ERC1155Component, storage: erc1155, event: ERC1155Event);
    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);
    component!(path: SRC5Component, storage: src5, event: SRC5Event);
    component!(path: ReentrancyGuardComponent, storage: reentrancy_guard, event: ReentrancyGuardEvent);
    component!(path: PausableComponent, storage: pausable, event: PausableEvent);
    component!(path: NoncesComponent, storage: nonces, event: NoncesEvent);

    // ERC1155 Mixin — exposes standard ERC1155 functions externally
    #[abi(embed_v0)]
    impl ERC1155MixinImpl = ERC1155Component::ERC1155MixinImpl<ContractState>;
    impl ERC1155InternalImpl = ERC1155Component::InternalImpl<ContractState>;

    // Ownable
    #[abi(embed_v0)]
    impl OwnableMixinImpl = OwnableComponent::OwnableMixinImpl<ContractState>;
    impl OwnableInternalImpl = OwnableComponent::InternalImpl<ContractState>;

    // ReentrancyGuard
    impl ReentrancyGuardInternalImpl = ReentrancyGuardComponent::InternalImpl<ContractState>;

    // Pausable
    impl PausableImpl = PausableComponent::PausableImpl<ContractState>;
    impl PausableInternalImpl = PausableComponent::InternalImpl<ContractState>;

    // Nonces
    impl NoncesInternalImpl = NoncesComponent::InternalImpl<ContractState>;

    // ============================================================
    //                          STORAGE
    // ============================================================

    #[storage]
    struct Storage {
        // Component storage
        #[substorage(v0)]
        erc1155: ERC1155Component::Storage,
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
        #[substorage(v0)]
        src5: SRC5Component::Storage,
        #[substorage(v0)]
        reentrancy_guard: ReentrancyGuardComponent::Storage,
        #[substorage(v0)]
        pausable: PausableComponent::Storage,
        #[substorage(v0)]
        nonces: NoncesComponent::Storage,
        // Protocol storage
        inscriptions: Map<u256, StoredInscription>,
        // Asset storage (flattened arrays indexed by inscription_id and index)
        inscription_debt_assets: Map<(u256, u32), Asset>,
        inscription_interest_assets: Map<(u256, u32), Asset>,
        inscription_collateral_assets: Map<(u256, u32), Asset>,
        // Per-inscription balance tracking (prevents cross-inscription drainage)
        // Keyed by (inscription_id, asset_index) → actual amount held
        inscription_debt_balance: Map<(u256, u32), u256>,
        inscription_interest_balance: Map<(u256, u32), u256>,
        inscription_collateral_balance: Map<(u256, u32), u256>,
        // Locker storage
        lockers: Map<u256, ContractAddress>,
        is_locker: Map<ContractAddress, bool>,
        // Share tracking
        total_supply: Map<u256, u256>,
        // Protocol config
        inscription_fee: u256,
        treasury: ContractAddress,
        // External contracts
        inscriptions_nft: ContractAddress,
        registry: ContractAddress,
        implementation_hash: felt252,
        // Relayer fee (in BPS, separate from inscription_fee)
        relayer_fee: u256,
        // Signed order storage (matching engine)
        signed_orders: Map<felt252, bool>,
        cancelled_orders: Map<felt252, bool>,
        filled_amounts: Map<felt252, u256>,
        maker_min_nonce: Map<ContractAddress, felt252>,
        // Genesis NFT contract (for fee discount balance checks)
        genesis_contract: ContractAddress,
        // Per-address cumulative settled volume (for discount tiers)
        volume_settled: Map<ContractAddress, u256>,
        // Emergency pauser (survives ownership renouncement)
        pauser: ContractAddress,
    }

    // ============================================================
    //                          EVENTS
    // ============================================================

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        #[flat]
        ERC1155Event: ERC1155Component::Event,
        #[flat]
        OwnableEvent: OwnableComponent::Event,
        #[flat]
        SRC5Event: SRC5Component::Event,
        #[flat]
        ReentrancyGuardEvent: ReentrancyGuardComponent::Event,
        #[flat]
        PausableEvent: PausableComponent::Event,
        #[flat]
        NoncesEvent: NoncesComponent::Event,
        InscriptionCreated: InscriptionCreated,
        InscriptionSigned: InscriptionSigned,
        InscriptionCancelled: InscriptionCancelled,
        InscriptionRepaid: InscriptionRepaid,
        InscriptionLiquidated: InscriptionLiquidated,
        SharesRedeemed: SharesRedeemed,
        OrderSettled: OrderSettled,
        OrderFilled: OrderFilled,
        OrderCancelled: OrderCancelled,
        OrdersBulkCancelled: OrdersBulkCancelled,
    }

    #[derive(Drop, starknet::Event)]
    pub struct InscriptionCreated {
        #[key]
        pub inscription_id: u256,
        #[key]
        pub creator: ContractAddress,
        pub is_borrow: bool,
    }

    #[derive(Drop, starknet::Event)]
    pub struct InscriptionSigned {
        #[key]
        pub inscription_id: u256,
        #[key]
        pub borrower: ContractAddress,
        #[key]
        pub lender: ContractAddress,
        pub issued_debt_percentage: u256,
        pub shares_minted: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct InscriptionCancelled {
        #[key]
        pub inscription_id: u256,
        pub creator: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct InscriptionRepaid {
        #[key]
        pub inscription_id: u256,
        pub repayer: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct InscriptionLiquidated {
        #[key]
        pub inscription_id: u256,
        pub liquidator: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct SharesRedeemed {
        #[key]
        pub inscription_id: u256,
        #[key]
        pub redeemer: ContractAddress,
        pub shares: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct OrderSettled {
        #[key]
        pub inscription_id: u256,
        #[key]
        pub borrower: ContractAddress,
        #[key]
        pub lender: ContractAddress,
        pub relayer: ContractAddress,
        pub relayer_fee_amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct OrderFilled {
        #[key]
        pub inscription_id: u256,
        #[key]
        pub order_hash: felt252,
        #[key]
        pub taker: ContractAddress,
        pub fill_bps: u256,
        pub total_filled_bps: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct OrderCancelled {
        #[key]
        pub order_hash: felt252,
        pub maker: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct OrdersBulkCancelled {
        #[key]
        pub maker: ContractAddress,
        pub new_min_nonce: felt252,
    }

    // SNIP-12 domain metadata (used by OffchainMessageHash)
    impl StelaSNIP12Metadata of openzeppelin_utils::cryptography::snip12::SNIP12Metadata {
        fn name() -> felt252 {
            'Stela'
        }
        fn version() -> felt252 {
            'v1'
        }
    }

    // ============================================================
    //                        CONSTRUCTOR
    // ============================================================

    /// Initialize the Stela protocol.
    /// Sets up ERC1155 (shares), Ownable, and protocol config.
    /// Default inscription fee is 10 BPS (0.1%). Treasury defaults to owner.
    #[constructor]
    fn constructor(
        ref self: ContractState,
        owner: ContractAddress,
        inscriptions_nft: ContractAddress,
        registry: ContractAddress,
        implementation_hash: felt252,
        pauser: ContractAddress,
    ) {
        // Validate non-zero addresses and implementation hash
        assert(!owner.is_zero(), Errors::INVALID_ADDRESS);
        assert(!inscriptions_nft.is_zero(), Errors::INVALID_ADDRESS);
        assert(!registry.is_zero(), Errors::INVALID_ADDRESS);
        assert(implementation_hash != 0, Errors::ZERO_IMPL_HASH);
        assert(!pauser.is_zero(), Errors::INVALID_ADDRESS);

        // Initialize ERC1155 with empty base URI
        self.erc1155.initializer("");
        // Initialize Ownable
        self.ownable.initializer(owner);
        // Set protocol config
        self.inscription_fee.write(10); // Default 10 BPS (0.1%)
        // Treasury defaults to owner/deployer — can be changed via set_treasury
        self.treasury.write(owner);
        self.inscriptions_nft.write(inscriptions_nft);
        self.registry.write(registry);
        self.implementation_hash.write(implementation_hash);
        // Emergency pauser — survives ownership renouncement
        self.pauser.write(pauser);
    }

    // ============================================================
    //                    EXTERNAL FUNCTIONS
    // ============================================================

    #[abi(embed_v0)]
    impl StelaProtocolImpl of crate::interfaces::istela::IStelaProtocol<ContractState> {
        /// Create a new inscription. Returns the inscription ID.
        fn create_inscription(ref self: ContractState, params: InscriptionParams) -> u256 {
            self.pausable.assert_not_paused();

            let caller = get_caller_address();
            let timestamp = get_block_timestamp();

            // Validate params
            assert(params.debt_assets.len() > 0, Errors::ZERO_DEBT_ASSETS);
            assert(params.collateral_assets.len() > 0, Errors::ZERO_COLLATERAL);
            assert(params.deadline > timestamp, Errors::INSCRIPTION_EXPIRED);

            // Validate asset array lengths don't exceed cap
            assert(params.debt_assets.len() <= MAX_ASSETS, Errors::TOO_MANY_ASSETS);
            assert(params.collateral_assets.len() <= MAX_ASSETS, Errors::TOO_MANY_ASSETS);
            assert(params.interest_assets.len() <= MAX_ASSETS, Errors::TOO_MANY_ASSETS);

            // Validate individual asset values
            self._validate_assets(params.debt_assets.span());
            self._validate_assets(params.collateral_assets.span());
            self._validate_assets(params.interest_assets.span());

            // ERC721 cannot be used as debt or interest — NFTs aren't fungible
            // and can't be scaled by percentage for partial fills or pro-rata redemption
            self._validate_no_nfts(params.debt_assets.span());
            self._validate_no_nfts(params.interest_assets.span());

            // H2: ERC721 collateral cannot be used with multi-lender inscriptions
            // because NFTs are indivisible and can't be split pro-rata among lenders.
            // This same validation exists in settle() for off-chain order path.
            if params.multi_lender {
                self._validate_no_nfts(params.collateral_assets.span());
            }

            // Determine borrower and lender based on who creates
            let zero_address: ContractAddress = Zero::zero();
            let (borrower, lender) = if params.is_borrow {
                (caller, zero_address)
            } else {
                (zero_address, caller)
            };

            // Compute inscription ID
            let inscription_id = self
                ._compute_inscription_id(
                    borrower, lender, params.duration, params.deadline, timestamp, params.debt_assets.span(),
                );

            // Check inscription doesn't already exist
            let existing = self.inscriptions.read(inscription_id);
            if params.is_borrow {
                assert(existing.borrower.is_zero(), Errors::INSCRIPTION_EXISTS);
            } else {
                assert(existing.lender.is_zero(), Errors::INSCRIPTION_EXISTS);
            }

            // Store the inscription
            let stored = StoredInscription {
                borrower,
                lender,
                duration: params.duration,
                deadline: params.deadline,
                signed_at: 0, // Set when first signed
                issued_debt_percentage: 0,
                is_repaid: false,
                liquidated: false,
                multi_lender: params.multi_lender,
                debt_asset_count: params.debt_assets.len(),
                interest_asset_count: params.interest_assets.len(),
                collateral_asset_count: params.collateral_assets.len(),
            };
            self.inscriptions.write(inscription_id, stored);

            // Store assets in indexed maps
            self._store_debt_assets(inscription_id, params.debt_assets.span());
            self._store_interest_assets(inscription_id, params.interest_assets.span());
            self._store_collateral_assets(inscription_id, params.collateral_assets.span());

            // Emit event
            self.emit(InscriptionCreated { inscription_id, creator: caller, is_borrow: params.is_borrow });

            inscription_id
        }

        /// Cancel an unfilled inscription. Only callable by the creator.
        fn cancel_inscription(ref self: ContractState, inscription_id: u256) {
            let caller = get_caller_address();

            // Load inscription
            let inscription = self.inscriptions.read(inscription_id);

            // Validate inscription exists
            assert(!inscription.borrower.is_zero() || !inscription.lender.is_zero(), Errors::INVALID_INSCRIPTION);

            // Validate caller is the creator
            let creator = if !inscription.borrower.is_zero() {
                inscription.borrower
            } else {
                inscription.lender
            };
            assert(caller == creator, Errors::NOT_CREATOR);

            // Validate inscription hasn't been filled
            assert(inscription.issued_debt_percentage == 0, Errors::NOT_CANCELLABLE);

            // Clear asset storage maps
            self._clear_assets(inscription_id, inscription.debt_asset_count, inscription.interest_asset_count, inscription.collateral_asset_count);

            // Clear the inscription (set to default/zero)
            let zero_address: ContractAddress = Zero::zero();
            let cleared = StoredInscription {
                borrower: zero_address,
                lender: zero_address,
                duration: 0,
                deadline: 0,
                signed_at: 0,
                issued_debt_percentage: 0,
                is_repaid: false,
                liquidated: false,
                multi_lender: false,
                debt_asset_count: 0,
                interest_asset_count: 0,
                collateral_asset_count: 0,
            };
            self.inscriptions.write(inscription_id, cleared);

            // Emit event
            self.emit(InscriptionCancelled { inscription_id, creator: caller });
        }

        /// Fill/sign an existing inscription by providing debt capital as lender (or collateral as borrower).
        /// Single-lender: always fills 100%, ignores issued_debt_percentage.
        /// Multi-lender: fills the specified percentage; multiple lenders can partially fill.
        /// On first fill: mints NFT to borrower, creates TBA locker, sets signed_at.
        /// For instant swaps (duration=0): collateral goes directly to contract, marked liquidated.
        fn sign_inscription(ref self: ContractState, inscription_id: u256, issued_debt_percentage: u256) {
            self.pausable.assert_not_paused();
            self.reentrancy_guard.start();

            let caller = get_caller_address();
            self._fill_inscription(inscription_id, issued_debt_percentage, caller);

            self.reentrancy_guard.end();
        }

        /// Repay an active inscription. Only callable by the borrower.
        fn repay(ref self: ContractState, inscription_id: u256) {
            self.pausable.assert_not_paused();
            self.reentrancy_guard.start();

            let caller = get_caller_address();
            let timestamp = get_block_timestamp();

            // Load inscription
            let mut inscription = self.inscriptions.read(inscription_id);

            // Validate inscription is active
            assert(!inscription.is_repaid, Errors::ALREADY_REPAID);
            assert(!inscription.liquidated, Errors::ALREADY_LIQUIDATED);

            // Validate inscription has been signed
            assert(inscription.signed_at > 0, Errors::INVALID_INSCRIPTION);

            // Only borrower can repay
            assert(caller == inscription.borrower, Errors::UNAUTHORIZED);

            // M2: Validate timing — repayment window is [signed_at, signed_at + duration] INCLUSIVE.
            let due_to = inscription.signed_at + inscription.duration;
            assert(timestamp >= inscription.signed_at, Errors::REPAY_TOO_EARLY);
            assert(timestamp <= due_to, Errors::REPAY_WINDOW_CLOSED);

            // FIX: Pull repayment proportional to issued_debt_percentage, and track balances
            self
                ._pull_repayment(
                    caller,
                    inscription_id,
                    inscription.debt_asset_count,
                    inscription.interest_asset_count,
                    inscription.issued_debt_percentage,
                );

            // Mark as repaid
            inscription.is_repaid = true;
            self.inscriptions.write(inscription_id, inscription);

            // Unlock collateral (release back to borrower)
            let locker = self.lockers.read(inscription_id);
            if !locker.is_zero() {
                let locker_dispatcher = ILockerAccountDispatcher { contract_address: locker };
                locker_dispatcher.unlock();
            }

            // Emit event
            self.emit(InscriptionRepaid { inscription_id, repayer: caller });

            self.reentrancy_guard.end();
        }

        /// Liquidate an expired, unrepaid inscription.
        fn liquidate(ref self: ContractState, inscription_id: u256) {
            self.pausable.assert_not_paused();
            self.reentrancy_guard.start();

            let caller = get_caller_address();
            let timestamp = get_block_timestamp();

            // Load inscription
            let mut inscription = self.inscriptions.read(inscription_id);

            // Validate inscription can be liquidated
            assert(!inscription.is_repaid, Errors::ALREADY_REPAID);
            assert(!inscription.liquidated, Errors::ALREADY_LIQUIDATED);

            // Validate inscription has been signed
            assert(inscription.signed_at > 0, Errors::INVALID_INSCRIPTION);

            // Validate timelock expired (signed_at + duration has passed)
            let due_to = inscription.signed_at + inscription.duration;
            assert(timestamp > due_to, Errors::NOT_YET_LIQUIDATABLE);

            // Mark as liquidated
            inscription.liquidated = true;
            self.inscriptions.write(inscription_id, inscription);

            // FIX: Pull collateral from locker and track balances
            let locker = self.lockers.read(inscription_id);
            if !locker.is_zero() {
                self
                    ._pull_collateral_from_locker(
                        locker, inscription_id, inscription.collateral_asset_count, inscription.issued_debt_percentage,
                    );
                // Unlock locker so borrower can recover excess collateral from partial fills
                let locker_dispatcher = ILockerAccountDispatcher { contract_address: locker };
                locker_dispatcher.unlock();
            }

            // Emit event
            self.emit(InscriptionLiquidated { inscription_id, liquidator: caller });

            self.reentrancy_guard.end();
        }

        /// Redeem shares for underlying assets.
        fn redeem(ref self: ContractState, inscription_id: u256, shares: u256) {
            self.pausable.assert_not_paused();
            self.reentrancy_guard.start();

            let caller = get_caller_address();

            // Load inscription
            let inscription = self.inscriptions.read(inscription_id);

            // Validate inscription is redeemable (repaid OR liquidated)
            assert(inscription.is_repaid || inscription.liquidated, Errors::NOT_REDEEMABLE);

            // Validate caller has shares
            let caller_balance = self.erc1155.balance_of(caller, inscription_id);
            assert(shares > 0 && shares <= caller_balance, Errors::ZERO_SHARES);

            // Pro-rata share of tracked balances: amount = tracked_balance * shares / total_supply
            let total_supply = self.total_supply.read(inscription_id);

            // H1 FIX: Guard against division by zero when total_supply == 0.
            if total_supply == 0 {
                self.reentrancy_guard.end();
                return;
            }

            // Burn shares
            self.erc1155.burn(caller, inscription_id, shares);

            // Update total supply
            self.total_supply.write(inscription_id, total_supply - shares);

            // Transfer assets using tracked per-inscription balances (pro-rata by shares)
            if inscription.is_repaid {
                // Repaid: lenders get debt + interest
                self._redeem_debt_assets(caller, inscription_id, inscription.debt_asset_count, shares, total_supply);
                self
                    ._redeem_interest_assets(
                        caller, inscription_id, inscription.interest_asset_count, shares, total_supply,
                    );
            } else {
                // Liquidated: lenders get collateral
                self
                    ._redeem_collateral_assets(
                        caller, inscription_id, inscription.collateral_asset_count, shares, total_supply,
                    );
            }

            // Emit event
            self.emit(SharesRedeemed { inscription_id, redeemer: caller, shares });

            self.reentrancy_guard.end();
        }

        // --- View functions ---

        /// Get inscription details by ID. Returns a zero-initialized struct if not found.
        fn get_inscription(self: @ContractState, inscription_id: u256) -> StoredInscription {
            self.inscriptions.read(inscription_id)
        }

        /// Get the locker (TBA) address for an inscription. Returns zero address if no locker.
        fn get_locker(self: @ContractState, inscription_id: u256) -> ContractAddress {
            self.lockers.read(inscription_id)
        }

        /// Preview the number of ERC1155 shares that would be minted for a given debt percentage.
        fn convert_to_shares(self: @ContractState, inscription_id: u256, issued_debt_percentage: u256) -> u256 {
            let inscription = self.inscriptions.read(inscription_id);
            let total_supply = self.total_supply.read(inscription_id);
            convert_to_shares(issued_debt_percentage, total_supply, inscription.issued_debt_percentage)
        }

        /// Get the protocol fee in BPS applied to lender shares on each sign/settle.
        fn get_inscription_fee(self: @ContractState) -> u256 {
            self.inscription_fee.read()
        }

        /// Get the treasury address that receives protocol fee shares.
        fn get_treasury(self: @ContractState) -> ContractAddress {
            self.treasury.read()
        }

        /// Check if the protocol is currently paused.
        fn is_paused(self: @ContractState) -> bool {
            self.pausable.is_paused()
        }

        /// Returns true if the order has been registered on-chain (first fill completed).
        fn is_order_registered(self: @ContractState, order_hash: felt252) -> bool {
            self.signed_orders.read(order_hash)
        }

        /// Returns true if the order has been cancelled.
        fn is_order_cancelled(self: @ContractState, order_hash: felt252) -> bool {
            self.cancelled_orders.read(order_hash)
        }

        /// Returns the current filled BPS for a signed order.
        fn get_filled_bps(self: @ContractState, order_hash: felt252) -> u256 {
            self.filled_amounts.read(order_hash)
        }

        /// Returns the minimum valid nonce for a maker (orders with nonce < this are invalid).
        fn get_maker_min_nonce(self: @ContractState, maker: ContractAddress) -> felt252 {
            self.maker_min_nonce.read(maker)
        }

        /// Get the Genesis NFT contract address. Zero address means discounts are disabled.
        fn get_genesis_contract(self: @ContractState) -> ContractAddress {
            self.genesis_contract.read()
        }

        /// Get the cumulative settled volume for an address.
        fn get_volume_settled(self: @ContractState, user: ContractAddress) -> u256 {
            self.volume_settled.read(user)
        }

        // --- Admin functions (all require owner) ---

        /// Set the protocol fee in BPS (e.g. 10 = 0.1%). Must not exceed MAX_BPS.
        fn set_inscription_fee(ref self: ContractState, fee: u256) {
            self.ownable.assert_only_owner();
            assert(fee <= MAX_BPS, Errors::FEE_TOO_HIGH);
            self.inscription_fee.write(fee);
        }

        /// Set the treasury address that receives protocol fee shares. Must be non-zero.
        fn set_treasury(ref self: ContractState, treasury: ContractAddress) {
            self.ownable.assert_only_owner();
            assert(!treasury.is_zero(), Errors::INVALID_ADDRESS);
            self.treasury.write(treasury);
        }

        /// Set the SNIP-14 registry address used to deploy locker TBAs. Must be non-zero.
        fn set_registry(ref self: ContractState, registry: ContractAddress) {
            self.ownable.assert_only_owner();
            assert(!registry.is_zero(), Errors::INVALID_ADDRESS);
            self.registry.write(registry);
        }

        /// Set the inscriptions NFT contract address. Must be non-zero.
        fn set_inscriptions_nft(ref self: ContractState, inscriptions_nft: ContractAddress) {
            self.ownable.assert_only_owner();
            assert(!inscriptions_nft.is_zero(), Errors::INVALID_ADDRESS);
            self.inscriptions_nft.write(inscriptions_nft);
        }

        /// Settle an off-chain signed order, creating and filling an inscription atomically.
        /// Verifies SNIP-12 signatures for both borrower and lender, consumes nonces,
        /// and deducts a relayer fee from the lender's debt transfer to the caller.
        fn settle(
            ref self: ContractState,
            order: InscriptionOrder,
            debt_assets: Array<Asset>,
            interest_assets: Array<Asset>,
            collateral_assets: Array<Asset>,
            borrower_sig: Array<felt252>,
            offer: LendOffer,
            lender_sig: Array<felt252>,
        ) {
            self.pausable.assert_not_paused();
            self.reentrancy_guard.start();

            let caller = get_caller_address();
            let timestamp = get_block_timestamp();

            // 1. Check order.deadline hasn't passed
            assert(timestamp <= order.deadline, Errors::ORDER_EXPIRED);

            // 2. Verify asset hashes match the order
            assert(hash_assets(debt_assets.span()) == order.debt_hash, Errors::INVALID_ORDER);
            assert(hash_assets(interest_assets.span()) == order.interest_hash, Errors::INVALID_ORDER);
            assert(hash_assets(collateral_assets.span()) == order.collateral_hash, Errors::INVALID_ORDER);

            // Verify asset counts match
            assert(debt_assets.len() == order.debt_count, Errors::INVALID_ORDER);
            assert(interest_assets.len() == order.interest_count, Errors::INVALID_ORDER);
            assert(collateral_assets.len() == order.collateral_count, Errors::INVALID_ORDER);

            // Validate asset array lengths don't exceed cap
            assert(debt_assets.len() > 0, Errors::ZERO_DEBT_ASSETS);
            assert(collateral_assets.len() > 0, Errors::ZERO_COLLATERAL);
            assert(debt_assets.len() <= MAX_ASSETS, Errors::TOO_MANY_ASSETS);
            assert(collateral_assets.len() <= MAX_ASSETS, Errors::TOO_MANY_ASSETS);
            assert(interest_assets.len() <= MAX_ASSETS, Errors::TOO_MANY_ASSETS);

            // Validate individual asset values
            self._validate_assets(debt_assets.span());
            self._validate_assets(collateral_assets.span());
            self._validate_assets(interest_assets.span());

            // ERC721 cannot be used as debt or interest
            self._validate_no_nfts(debt_assets.span());
            self._validate_no_nfts(interest_assets.span());

            // H2: ERC721 collateral cannot be used with multi-lender inscriptions
            if order.multi_lender {
                self._validate_no_nfts(collateral_assets.span());
            }

            // Verify offer references this order
            let order_msg_hash = order.get_message_hash(order.borrower);
            assert(offer.order_hash == order_msg_hash, Errors::INVALID_ORDER);

            // 3. Verify borrower signature via ISRC6
            let borrower_account = ISRC6Dispatcher { contract_address: order.borrower };
            let borrower_valid = borrower_account.is_valid_signature(order_msg_hash, borrower_sig);
            assert(borrower_valid == starknet::VALIDATED, Errors::INVALID_SIGNATURE);

            // 4. Verify lender signature via ISRC6
            let lender_msg_hash = offer.get_message_hash(offer.lender);
            let lender_account = ISRC6Dispatcher { contract_address: offer.lender };
            let lender_valid = lender_account.is_valid_signature(lender_msg_hash, lender_sig);
            assert(lender_valid == starknet::VALIDATED, Errors::INVALID_SIGNATURE);

            // 5. Consume nonces
            self.nonces.use_checked_nonce(order.borrower, order.nonce);
            self.nonces.use_checked_nonce(offer.lender, offer.nonce);

            // 6. Create inscription
            let borrower = order.borrower;
            let lender = offer.lender;

            // Prevent self-settlement (borrower == lender)
            assert(borrower != lender, Errors::SELF_TRADE_NOT_ALLOWED);

            let is_swap = order.duration == 0;

            // Compute inscription ID
            let inscription_id = self
                ._compute_inscription_id(
                    borrower, lender, order.duration, order.deadline, timestamp, debt_assets.span(),
                );

            // Check inscription doesn't already exist (C3)
            let existing = self.inscriptions.read(inscription_id);
            assert(existing.borrower.is_zero() && existing.lender.is_zero(), Errors::INSCRIPTION_EXISTS);

            // Determine actual debt percentage
            let actual_percentage = if order.multi_lender {
                assert(offer.issued_debt_percentage > 0, Errors::ZERO_SHARES);
                assert(offer.issued_debt_percentage <= MAX_BPS, Errors::EXCEEDS_MAX_BPS);
                offer.issued_debt_percentage
            } else {
                MAX_BPS
            };

            // Store inscription
            let stored = StoredInscription {
                borrower,
                lender,
                duration: order.duration,
                deadline: order.deadline,
                signed_at: timestamp,
                issued_debt_percentage: actual_percentage,
                is_repaid: false,
                liquidated: is_swap, // Instant swap: mark as liquidated for immediate redemption
                multi_lender: order.multi_lender,
                debt_asset_count: debt_assets.len(),
                interest_asset_count: interest_assets.len(),
                collateral_asset_count: collateral_assets.len(),
            };
            self.inscriptions.write(inscription_id, stored);

            // Store assets
            self._store_debt_assets(inscription_id, debt_assets.span());
            self._store_interest_assets(inscription_id, interest_assets.span());
            self._store_collateral_assets(inscription_id, collateral_assets.span());

            // Mint inscription NFT to borrower
            let nft_contract = self.inscriptions_nft.read();
            let nft = IERC721MintableDispatcher { contract_address: nft_contract };
            nft.mint(borrower, inscription_id);

            if is_swap {
                // Instant swap: transfer collateral directly to contract (no locker)
                self
                    ._collect_collateral_for_swap(
                        borrower, inscription_id, collateral_assets.len(), actual_percentage, true,
                    );
            } else {
                // Standard loan: create TBA locker and lock collateral
                let registry_contract = self.registry.read();
                let registry = IRegistryDispatcher { contract_address: registry_contract };
                let locker_addr = registry
                    .create_account(self.implementation_hash.read(), nft_contract, inscription_id);
                assert(!locker_addr.is_zero(), Errors::INVALID_ADDRESS);
                self.lockers.write(inscription_id, locker_addr);
                self.is_locker.write(locker_addr, true);

                self
                    ._lock_collateral(
                        borrower, locker_addr, inscription_id, collateral_assets.len(), actual_percentage, true,
                    );
            }

            // Calculate shares
            let shares = convert_to_shares(actual_percentage, 0, 0);

            // Calculate and mint fee shares
            let fee_shares = calculate_fee_shares(shares, self.inscription_fee.read());
            let total_new_shares = shares + fee_shares;

            // Standard settlement: mint ERC1155 shares to lender
            self.erc1155.update(Zero::zero(), lender, array![inscription_id].span(), array![shares].span());

            // Mint fee shares to treasury
            if fee_shares > 0 {
                let treasury = self.treasury.read();
                self
                    .erc1155
                    .update(Zero::zero(), treasury, array![inscription_id].span(), array![fee_shares].span());
            }

            // Update total supply
            self.total_supply.write(inscription_id, total_new_shares);

            // Issue debt with fee (uses discount model)
            let total_relayer_fee = self
                ._issue_debt_with_fee(
                    lender, borrower, caller, inscription_id, debt_assets.len(), actual_percentage, order.duration,
                );

            // Track volume for the lender (for discount tiers)
            self._track_volume(lender, inscription_id, debt_assets.len(), actual_percentage);

            // Emit events
            self.emit(InscriptionCreated { inscription_id, creator: borrower, is_borrow: true });
            self
                .emit(
                    InscriptionSigned {
                        inscription_id,
                        borrower,
                        lender,
                        issued_debt_percentage: actual_percentage,
                        shares_minted: shares,
                    },
                );
            self
                .emit(
                    OrderSettled {
                        inscription_id, borrower, lender, relayer: caller, relayer_fee_amount: total_relayer_fee,
                    },
                );

            self.reentrancy_guard.end();
        }

        // --- Signed order matching engine ---

        /// Fill a signed order. On first fill, verifies the maker's SNIP-12 signature and
        /// registers the order on-chain. Subsequent fills skip signature verification.
        fn fill_signed_order(
            ref self: ContractState, order: SignedOrder, signature: Array<felt252>, fill_bps: u256,
        ) {
            self.pausable.assert_not_paused();
            self.reentrancy_guard.start();

            let caller = get_caller_address();
            let timestamp = get_block_timestamp();

            // 1. Self-trade prevention
            assert(caller != order.maker, Errors::SELF_TRADE_NOT_ALLOWED);

            // 2. Private taker check
            let zero_address: ContractAddress = Zero::zero();
            if order.allowed_taker != zero_address {
                assert(caller == order.allowed_taker, Errors::UNAUTHORIZED_TAKER);
            }

            // 3. Deadline check
            assert(timestamp <= order.deadline, Errors::ORDER_EXPIRED);

            // 4. Compute order hash for storage lookups
            let order_hash = order.hash_struct();

            // 5. Nonce check (bulk invalidation)
            let min_nonce = self.maker_min_nonce.read(order.maker);
            let nonce_u256: u256 = order.nonce.into();
            let min_nonce_u256: u256 = min_nonce.into();
            assert(nonce_u256 >= min_nonce_u256, Errors::INVALID_NONCE);

            // 6. Cancelled check
            assert(!self.cancelled_orders.read(order_hash), Errors::ORDER_CANCELLED);

            // 7. Min fill check
            if order.min_fill_bps > 0 {
                assert(fill_bps >= order.min_fill_bps, Errors::MIN_FILL_NOT_MET);
            }

            // 8. Overfill check
            let current_filled = self.filled_amounts.read(order_hash);
            assert(current_filled + fill_bps <= order.bps, Errors::OVERFILL);

            // 9/10. First fill: verify signature and register. Subsequent: check registered.
            let is_registered = self.signed_orders.read(order_hash);
            if !is_registered {
                // First fill: verify ISRC6 signature
                let msg_hash = order.get_message_hash(order.maker);
                let maker_account = ISRC6Dispatcher { contract_address: order.maker };
                let sig_valid = maker_account.is_valid_signature(msg_hash, signature);
                assert(sig_valid == starknet::VALIDATED, Errors::INVALID_SIGNATURE);

                // Register order on-chain
                self.signed_orders.write(order_hash, true);
            } else {
                // Already registered -- no signature needed
                assert(is_registered, Errors::ORDER_NOT_REGISTERED);
            }

            // 11. Call the shared fill logic to do the actual inscription fill
            self._fill_inscription(order.inscription_id, fill_bps, caller);

            // 12. Update filled amounts
            self.filled_amounts.write(order_hash, current_filled + fill_bps);

            // 13. Emit OrderFilled event
            self
                .emit(
                    OrderFilled {
                        inscription_id: order.inscription_id,
                        order_hash,
                        taker: caller,
                        fill_bps,
                        total_filled_bps: current_filled + fill_bps,
                    },
                );

            self.reentrancy_guard.end();
        }

        /// Cancel a specific signed order. Only callable by the maker.
        fn cancel_order(ref self: ContractState, order: SignedOrder) {
            let caller = get_caller_address();
            assert(caller == order.maker, Errors::UNAUTHORIZED);

            let order_hash = order.hash_struct();
            self.cancelled_orders.write(order_hash, true);

            self.emit(OrderCancelled { order_hash, maker: caller });
        }

        /// Cancel all orders with nonce strictly less than `min_nonce`.
        fn cancel_orders_by_nonce(ref self: ContractState, min_nonce: felt252) {
            let caller = get_caller_address();
            let current_min = self.maker_min_nonce.read(caller);
            let min_nonce_u256: u256 = min_nonce.into();
            let current_min_u256: u256 = current_min.into();
            assert(min_nonce_u256 > current_min_u256, Errors::INVALID_NONCE);
            self.maker_min_nonce.write(caller, min_nonce);

            self.emit(OrdersBulkCancelled { maker: caller, new_min_nonce: min_nonce });
        }

        /// Get the current nonce for an address.
        fn nonces(self: @ContractState, owner: ContractAddress) -> felt252 {
            self.nonces.Nonces_nonces.read(owner)
        }

        /// Get the relayer fee in BPS.
        fn get_relayer_fee(self: @ContractState) -> u256 {
            self.relayer_fee.read()
        }

        /// Set the relayer fee in BPS. Only owner.
        fn set_relayer_fee(ref self: ContractState, fee: u256) {
            self.ownable.assert_only_owner();
            assert(fee <= MAX_BPS, Errors::FEE_TOO_HIGH);
            self.relayer_fee.write(fee);
        }

        /// Set the locker implementation class hash. Only owner.
        fn set_implementation_hash(ref self: ContractState, implementation_hash: felt252) {
            self.ownable.assert_only_owner();
            assert(implementation_hash != 0, Errors::ZERO_IMPL_HASH);
            self.implementation_hash.write(implementation_hash);
        }

        /// Set the Genesis NFT contract address for fee discount checks. Only owner.
        fn set_genesis_contract(ref self: ContractState, genesis_contract: ContractAddress) {
            self.ownable.assert_only_owner();
            self.genesis_contract.write(genesis_contract);
        }

        /// Pause the protocol. Only pauser.
        fn pause(ref self: ContractState) {
            assert(get_caller_address() == self.pauser.read(), Errors::UNAUTHORIZED);
            self.pausable.pause();
        }

        /// Unpause the protocol. Only pauser.
        fn unpause(ref self: ContractState) {
            assert(get_caller_address() == self.pauser.read(), Errors::UNAUTHORIZED);
            self.pausable.unpause();
        }

        /// Get the emergency pauser address.
        fn get_pauser(self: @ContractState) -> ContractAddress {
            self.pauser.read()
        }

        /// Add or remove an allowed selector on a specific locker TBA.
        fn set_locker_allowed_selector(
            ref self: ContractState, locker: ContractAddress, selector: felt252, allowed: bool,
        ) {
            self.ownable.assert_only_owner();
            assert(self.is_locker.read(locker), Errors::INVALID_ADDRESS);
            let locker_dispatcher = ILockerAccountDispatcher { contract_address: locker };
            locker_dispatcher.set_allowed_selector(selector, allowed);
        }
    }

    // ============================================================
    //                   INTERNAL FUNCTIONS
    // ============================================================

    #[generate_trait]
    impl InternalImpl of InternalTrait {
        /// Core inscription fill logic shared by sign_inscription and fill_signed_order.
        fn _fill_inscription(
            ref self: ContractState, inscription_id: u256, issued_debt_percentage: u256, filler: ContractAddress,
        ) {
            let timestamp = get_block_timestamp();

            // Load inscription
            let mut inscription = self.inscriptions.read(inscription_id);

            // Validate inscription exists
            assert(
                !inscription.borrower.is_zero() || !inscription.lender.is_zero(), Errors::INVALID_INSCRIPTION,
            );

            // Validate not expired
            assert(timestamp <= inscription.deadline, Errors::INSCRIPTION_EXPIRED);

            // Validate inscription is not already settled
            assert(!inscription.is_repaid, Errors::ALREADY_REPAID);
            assert(!inscription.liquidated, Errors::ALREADY_LIQUIDATED);

            // Determine actual debt percentage to use
            let actual_percentage = if inscription.multi_lender {
                assert(issued_debt_percentage > 0, Errors::ZERO_SHARES);
                assert(
                    inscription.issued_debt_percentage + issued_debt_percentage <= MAX_BPS, Errors::EXCEEDS_MAX_BPS,
                );
                issued_debt_percentage
            } else {
                // Single lender takes 100% -- prevent double-sign (C1 fix)
                assert(inscription.issued_debt_percentage == 0, Errors::ALREADY_SIGNED);
                MAX_BPS
            };

            // Determine borrower and lender
            let (borrower, lender) = if !inscription.borrower.is_zero() {
                (inscription.borrower, filler)
            } else {
                (filler, inscription.lender)
            };

            // Prevent self-lending
            assert(borrower != lender, Errors::SELF_TRADE_NOT_ALLOWED);

            // Track whether this is the first fill
            let is_first_fill = inscription.issued_debt_percentage == 0;

            // Check if this is an instant swap (duration = 0)
            let is_swap = inscription.duration == 0;

            // Track locker address (set on first fill, read from storage on subsequent)
            let mut locker_addr: ContractAddress = Zero::zero();

            // On first fill: set borrower/lender, mint NFT, create TBA, set signed_at
            if is_first_fill {
                inscription.signed_at = timestamp;
                inscription.borrower = borrower;
                inscription.lender = lender;

                // Mint inscription NFT to borrower
                let nft_contract = self.inscriptions_nft.read();
                let nft = IERC721MintableDispatcher { contract_address: nft_contract };
                nft.mint(borrower, inscription_id);

                // Create TBA via registry (not needed for instant swaps)
                if !is_swap {
                    let registry_contract = self.registry.read();
                    let registry = IRegistryDispatcher { contract_address: registry_contract };
                    locker_addr = registry
                        .create_account(self.implementation_hash.read(), nft_contract, inscription_id);
                    assert(!locker_addr.is_zero(), Errors::INVALID_ADDRESS);

                    self.lockers.write(inscription_id, locker_addr);
                    self.is_locker.write(locker_addr, true);
                }
            } else {
                locker_addr = self.lockers.read(inscription_id);
            }

            // Calculate shares
            let current_supply = self.total_supply.read(inscription_id);
            let shares = convert_to_shares(
                actual_percentage, current_supply, inscription.issued_debt_percentage,
            );

            // Calculate and mint fee shares
            let fee_shares = calculate_fee_shares(shares, self.inscription_fee.read());
            let total_new_shares = shares + fee_shares;

            // Mint lender shares
            self
                .erc1155
                .update(Zero::zero(), lender, array![inscription_id].span(), array![shares].span());

            // Mint fee shares to treasury
            if fee_shares > 0 {
                let treasury = self.treasury.read();
                self
                    .erc1155
                    .update(
                        Zero::zero(), treasury, array![inscription_id].span(), array![fee_shares].span(),
                    );
            }

            // Update total supply
            self.total_supply.write(inscription_id, current_supply + total_new_shares);

            if is_swap {
                // Instant swap: transfer collateral directly to contract (no locker)
                self
                    ._collect_collateral_for_swap(
                        borrower,
                        inscription_id,
                        inscription.collateral_asset_count,
                        actual_percentage,
                        is_first_fill,
                    );
                // Mark as liquidated immediately
                inscription.liquidated = true;
            } else {
                // Standard loan: lock collateral to locker TBA
                if !locker_addr.is_zero() {
                    self
                        ._lock_collateral(
                            borrower,
                            locker_addr,
                            inscription_id,
                            inscription.collateral_asset_count,
                            actual_percentage,
                            is_first_fill,
                        );
                }
            }

            // Update inscription state
            inscription.issued_debt_percentage = inscription.issued_debt_percentage + actual_percentage;
            self.inscriptions.write(inscription_id, inscription);

            // Issue debt from lender to borrower (proportional)
            self
                ._issue_debt(
                    lender, borrower, inscription_id, inscription.debt_asset_count, actual_percentage,
                );

            // Emit event
            self
                .emit(
                    InscriptionSigned {
                        inscription_id,
                        borrower,
                        lender,
                        issued_debt_percentage: actual_percentage,
                        shares_minted: shares,
                    },
                );
        }

        /// Validate that each asset has a non-zero contract address
        /// and that fungible assets (ERC20/ERC4626/ERC1155) have value > 0.
        fn _validate_assets(self: @ContractState, assets: Span<Asset>) {
            let mut i: u32 = 0;
            let len = assets.len();
            while i < len {
                let asset = *assets.at(i);
                assert(!asset.asset.is_zero(), Errors::INVALID_ADDRESS);
                match asset.asset_type {
                    AssetType::ERC721 => {}, // NFTs use token_id, value can be 0
                    _ => { assert(asset.value > 0, Errors::ZERO_ASSET_VALUE); },
                }
                i += 1;
            };
        }

        /// Validate that no assets in the array are ERC721 or ERC1155.
        fn _validate_no_nfts(self: @ContractState, assets: Span<Asset>) {
            let mut i: u32 = 0;
            let len = assets.len();
            while i < len {
                let asset = *assets.at(i);
                match asset.asset_type {
                    AssetType::ERC721 => { assert(false, Errors::NFT_NOT_FUNGIBLE); },
                    AssetType::ERC1155 => { assert(false, Errors::NFT_NOT_FUNGIBLE); },
                    _ => {},
                }
                i += 1;
            };
        }

        /// Compute a unique inscription ID using Poseidon hash.
        fn _compute_inscription_id(
            self: @ContractState,
            borrower: ContractAddress,
            lender: ContractAddress,
            duration: u64,
            deadline: u64,
            timestamp: u64,
            debt_assets: Span<Asset>,
        ) -> u256 {
            let mut hash_state = PoseidonTrait::new()
                .update_with(borrower)
                .update_with(lender)
                .update_with(duration)
                .update_with(deadline)
                .update_with(timestamp);

            let mut i: u32 = 0;
            let len = debt_assets.len();
            while i < len {
                let asset = *debt_assets.at(i);
                hash_state = hash_state.update_with(asset.asset).update_with(asset.value).update_with(asset.token_id);
                i += 1;
            }

            hash_state.finalize().into()
        }

        /// Store debt assets in indexed storage.
        fn _store_debt_assets(ref self: ContractState, inscription_id: u256, assets: Span<Asset>) {
            let mut i: u32 = 0;
            let len = assets.len();
            while i < len {
                self.inscription_debt_assets.write((inscription_id, i), *assets.at(i));
                i += 1;
            };
        }

        /// Store interest assets in indexed storage.
        fn _store_interest_assets(ref self: ContractState, inscription_id: u256, assets: Span<Asset>) {
            let mut i: u32 = 0;
            let len = assets.len();
            while i < len {
                self.inscription_interest_assets.write((inscription_id, i), *assets.at(i));
                i += 1;
            };
        }

        /// Store collateral assets in indexed storage.
        fn _store_collateral_assets(ref self: ContractState, inscription_id: u256, assets: Span<Asset>) {
            let mut i: u32 = 0;
            let len = assets.len();
            while i < len {
                self.inscription_collateral_assets.write((inscription_id, i), *assets.at(i));
                i += 1;
            };
        }

        /// Clear all asset storage maps for a cancelled inscription (H2).
        fn _clear_assets(
            ref self: ContractState,
            inscription_id: u256,
            debt_count: u32,
            interest_count: u32,
            collateral_count: u32,
        ) {
            let zero_asset = Asset {
                asset: Zero::zero(), asset_type: AssetType::ERC20, value: 0, token_id: 0,
            };
            let mut i: u32 = 0;
            while i < debt_count {
                self.inscription_debt_assets.write((inscription_id, i), zero_asset);
                i += 1;
            };
            let mut j: u32 = 0;
            while j < interest_count {
                self.inscription_interest_assets.write((inscription_id, j), zero_asset);
                j += 1;
            };
            let mut k: u32 = 0;
            while k < collateral_count {
                self.inscription_collateral_assets.write((inscription_id, k), zero_asset);
                k += 1;
            };
        }

        /// Collect collateral directly to the Stela contract for instant swaps (duration=0).
        fn _collect_collateral_for_swap(
            ref self: ContractState,
            from: ContractAddress,
            inscription_id: u256,
            collateral_count: u32,
            percentage: u256,
            is_first_fill: bool,
        ) {
            let this_contract = get_contract_address();
            let mut i: u32 = 0;
            while i < collateral_count {
                let asset = self.inscription_collateral_assets.read((inscription_id, i));

                let should_transfer = match asset.asset_type {
                    AssetType::ERC721 => is_first_fill,
                    _ => true,
                };

                if should_transfer {
                    let track_amount = match asset.asset_type {
                        AssetType::ERC721 => {
                            let erc721 = IERC721Dispatcher { contract_address: asset.asset };
                            erc721.transfer_from(from, this_contract, asset.token_id);
                            1_u256
                        },
                        AssetType::ERC1155 => {
                            let amount = scale_by_percentage(asset.value, percentage);
                            let erc1155 = IERC1155Dispatcher { contract_address: asset.asset };
                            erc1155.safe_transfer_from(from, this_contract, asset.token_id, amount, array![].span());
                            amount
                        },
                        _ => {
                            let amount = scale_by_percentage(asset.value, percentage);
                            let erc20 = IERC20Dispatcher { contract_address: asset.asset };
                            erc20.transfer_from(from, this_contract, amount);
                            amount
                        },
                    };

                    let current = self.inscription_collateral_balance.read((inscription_id, i));
                    self.inscription_collateral_balance.write((inscription_id, i), current + track_amount);
                }

                i += 1;
            };
        }

        /// Lock collateral from borrower to locker TBA.
        fn _lock_collateral(
            ref self: ContractState,
            from: ContractAddress,
            locker: ContractAddress,
            inscription_id: u256,
            collateral_count: u32,
            percentage: u256,
            is_first_fill: bool,
        ) {
            let mut i: u32 = 0;
            while i < collateral_count {
                let asset = self.inscription_collateral_assets.read((inscription_id, i));

                let should_transfer = match asset.asset_type {
                    AssetType::ERC721 => is_first_fill,
                    _ => true,
                };

                if should_transfer {
                    self._process_payment(asset, from, locker, percentage);
                }

                i += 1;
            };
        }

        /// Issue debt from lender to borrower.
        fn _issue_debt(
            ref self: ContractState,
            from: ContractAddress,
            to: ContractAddress,
            inscription_id: u256,
            debt_count: u32,
            percentage: u256,
        ) {
            let mut i: u32 = 0;
            while i < debt_count {
                let asset = self.inscription_debt_assets.read((inscription_id, i));
                self._process_payment(asset, from, to, percentage);
                i += 1;
            };
        }

        /// Calculate the discount percentage for a user based on Genesis NFT holdings and volume.
        /// Returns the discount percentage (0-50).
        fn _calculate_discount(self: @ContractState, user: ContractAddress) -> u256 {
            let genesis_addr = self.genesis_contract.read();
            if genesis_addr.is_zero() {
                return 0;
            }

            // Check NFT balance via ERC721.balance_of
            let genesis_nft = IERC721Dispatcher { contract_address: genesis_addr };
            let nft_balance = genesis_nft.balance_of(user);

            if nft_balance == 0 {
                return 0;
            }

            // Base discount: 15% for holding any NFT
            let mut discount = BASE_NFT_DISCOUNT_PCT;

            // Volume bonus: 5% per tier (7 tiers)
            let volume = self.volume_settled.read(user);
            if volume >= TIER_7 {
                discount = discount + VOLUME_TIER_DISCOUNT_PCT * 7;
            } else if volume >= TIER_6 {
                discount = discount + VOLUME_TIER_DISCOUNT_PCT * 6;
            } else if volume >= TIER_5 {
                discount = discount + VOLUME_TIER_DISCOUNT_PCT * 5;
            } else if volume >= TIER_4 {
                discount = discount + VOLUME_TIER_DISCOUNT_PCT * 4;
            } else if volume >= TIER_3 {
                discount = discount + VOLUME_TIER_DISCOUNT_PCT * 3;
            } else if volume >= TIER_2 {
                discount = discount + VOLUME_TIER_DISCOUNT_PCT * 2;
            } else if volume >= TIER_1 {
                discount = discount + VOLUME_TIER_DISCOUNT_PCT;
            }

            // Multi-NFT bonus: 2% per additional NFT held (beyond the first)
            if nft_balance > 1 {
                discount = discount + MULTI_NFT_DISCOUNT_PCT * (nft_balance - 1);
            }

            // Hard cap at 50%
            if discount > MAX_DISCOUNT_PCT {
                MAX_DISCOUNT_PCT
            } else {
                discount
            }
        }

        /// Issue debt from lender to borrower with fee deduction.
        /// Fee model: RELAYER_BPS (5) to relayer + discounted treasury BPS to treasury.
        /// Treasury fees are transferred directly (no FeeVault). Returns total relayer fee.
        /// NOTE: Fee truncation — (value * bps) / MAX_BPS truncates to zero for amounts < 10000 wei.
        /// For very small settlements the relayer receives nothing. Not exploitable (no incentive
        /// to settle dust amounts at gas cost), but practical minimum is ~10000 wei per debt asset.
        fn _issue_debt_with_fee(
            ref self: ContractState,
            from: ContractAddress,
            to: ContractAddress,
            relayer: ContractAddress,
            inscription_id: u256,
            debt_count: u32,
            percentage: u256,
            duration: u64,
        ) -> u256 {
            let treasury = self.treasury.read();
            let genesis_addr = self.genesis_contract.read();
            // Fee model only active when genesis_contract is configured
            let has_fee_model = !genesis_addr.is_zero() && !treasury.is_zero();

            // Use swap fee constants for duration==0, lending fee constants otherwise
            let is_swap = duration == 0;
            let base_treasury_bps = if is_swap { SWAP_TREASURY_BASE } else { SETTLE_TREASURY_BASE };
            let floor_treasury_bps = if is_swap { SWAP_TREASURY_FLOOR } else { SETTLE_TREASURY_FLOOR };

            // Calculate discounted treasury BPS for settle
            let treasury_bps = if has_fee_model {
                let discount_pct = self._calculate_discount(from);
                let discounted = base_treasury_bps - (base_treasury_bps * discount_pct / 100);
                if discounted < floor_treasury_bps {
                    floor_treasury_bps
                } else {
                    discounted
                }
            } else {
                0
            };

            let mut total_fee: u256 = 0;
            let mut i: u32 = 0;
            while i < debt_count {
                let asset = self.inscription_debt_assets.read((inscription_id, i));
                let total_amount = scale_by_percentage(asset.value, percentage);

                let erc20 = IERC20Dispatcher { contract_address: asset.asset };

                // Relayer fee (never discounted)
                let relayer_amount = (total_amount * RELAYER_BPS) / MAX_BPS;
                // Treasury fee (discounted)
                let treasury_amount = if has_fee_model {
                    (total_amount * treasury_bps) / MAX_BPS
                } else {
                    0
                };
                let total_fee_amount = relayer_amount + treasury_amount;
                let net_amount = total_amount - total_fee_amount;

                // Transfer net amount: lender -> borrower
                if net_amount > 0 {
                    erc20.transfer_from(from, to, net_amount);
                }

                // Transfer relayer fee: lender -> relayer
                if relayer_amount > 0 {
                    erc20.transfer_from(from, relayer, relayer_amount);
                    total_fee = total_fee + relayer_amount;
                }

                // Transfer treasury fee: lender -> treasury (simple transfer)
                if treasury_amount > 0 {
                    erc20.transfer_from(from, treasury, treasury_amount);
                }

                i += 1;
            };
            total_fee
        }

        /// Track cumulative settled volume for an address.
        /// Only called from settle() to prevent gaming.
        fn _track_volume(
            ref self: ContractState,
            user: ContractAddress,
            inscription_id: u256,
            debt_count: u32,
            percentage: u256,
        ) {
            let mut total_value: u256 = 0;
            let mut i: u32 = 0;
            while i < debt_count {
                let asset = self.inscription_debt_assets.read((inscription_id, i));
                let amount = scale_by_percentage(asset.value, percentage);
                total_value = total_value + amount;
                i += 1;
            };

            if total_value > 0 {
                let current = self.volume_settled.read(user);
                self.volume_settled.write(user, current + total_value);
            }
        }

        /// Pull repayment (debt + interest) from caller to this contract.
        fn _pull_repayment(
            ref self: ContractState,
            from: ContractAddress,
            inscription_id: u256,
            debt_count: u32,
            interest_count: u32,
            issued_percentage: u256,
        ) {
            let this_contract = get_contract_address();

            // Pull debt — proportional to how much was actually issued
            let mut i: u32 = 0;
            while i < debt_count {
                let asset = self.inscription_debt_assets.read((inscription_id, i));
                let amount = scale_by_percentage(asset.value, issued_percentage);
                self._process_payment(asset, from, this_contract, issued_percentage);

                let current = self.inscription_debt_balance.read((inscription_id, i));
                self.inscription_debt_balance.write((inscription_id, i), current + amount);

                i += 1;
            }

            // Pull interest — proportional to how much was actually issued
            let mut j: u32 = 0;
            while j < interest_count {
                let asset = self.inscription_interest_assets.read((inscription_id, j));
                let amount = scale_by_percentage(asset.value, issued_percentage);
                self._process_payment(asset, from, this_contract, issued_percentage);

                let current = self.inscription_interest_balance.read((inscription_id, j));
                self.inscription_interest_balance.write((inscription_id, j), current + amount);

                j += 1;
            };
        }

        /// Pull collateral from locker to this contract.
        fn _pull_collateral_from_locker(
            ref self: ContractState,
            locker: ContractAddress,
            inscription_id: u256,
            collateral_count: u32,
            issued_debt_percentage: u256,
        ) {
            let mut assets: Array<Asset> = array![];
            let mut i: u32 = 0;
            while i < collateral_count {
                let asset = self.inscription_collateral_assets.read((inscription_id, i));

                let (pull_asset, track_amount) = match asset.asset_type {
                    AssetType::ERC721 => {
                        (asset, 1_u256)
                    },
                    _ => {
                        let scaled_value = scale_by_percentage(asset.value, issued_debt_percentage);
                        let scaled_asset = Asset {
                            asset: asset.asset,
                            asset_type: asset.asset_type,
                            value: scaled_value,
                            token_id: asset.token_id,
                        };
                        (scaled_asset, scaled_value)
                    },
                };
                assets.append(pull_asset);

                let current = self.inscription_collateral_balance.read((inscription_id, i));
                self.inscription_collateral_balance.write((inscription_id, i), current + track_amount);

                i += 1;
            }

            let locker_dispatcher = ILockerAccountDispatcher { contract_address: locker };
            locker_dispatcher.pull_assets(assets);
        }

        /// Apply redeem fee to an ERC20/ERC4626 amount.
        /// Uses discount model: treasury gets REDEEM_TREASURY_BASE BPS minus discount, with floor.
        /// Returns net amount after fee.
        fn _apply_redeem_fee(
            ref self: ContractState,
            asset_address: ContractAddress,
            gross_amount: u256,
            redeemer: ContractAddress,
        ) -> u256 {
            // Redeem fee only applies when genesis_contract is configured (fee model active)
            let genesis_addr = self.genesis_contract.read();
            if genesis_addr.is_zero() || gross_amount == 0 {
                return gross_amount;
            }

            let treasury = self.treasury.read();
            if treasury.is_zero() {
                return gross_amount;
            }

            // Calculate discounted redeem treasury BPS
            let discount_pct = self._calculate_discount(redeemer);
            let treasury_bps = {
                let discounted = REDEEM_TREASURY_BASE - (REDEEM_TREASURY_BASE * discount_pct / 100);
                if discounted < REDEEM_TREASURY_FLOOR {
                    REDEEM_TREASURY_FLOOR
                } else {
                    discounted
                }
            };

            let fee_amount = (gross_amount * treasury_bps) / MAX_BPS;
            let net_amount = gross_amount - fee_amount;

            // Transfer fee directly to treasury
            if fee_amount > 0 {
                let erc20 = IERC20Dispatcher { contract_address: asset_address };
                erc20.transfer(treasury, fee_amount);
            }

            net_amount
        }

        /// Redeem debt assets using tracked per-inscription balances.
        fn _redeem_debt_assets(
            ref self: ContractState,
            to: ContractAddress,
            inscription_id: u256,
            debt_count: u32,
            shares: u256,
            total_supply: u256,
        ) {
            let mut i: u32 = 0;
            while i < debt_count {
                let asset = self.inscription_debt_assets.read((inscription_id, i));
                let tracked_balance = self.inscription_debt_balance.read((inscription_id, i));
                let amount = tracked_balance * shares / total_supply;

                if amount > 0 {
                    self.inscription_debt_balance.write((inscription_id, i), tracked_balance - amount);

                    // Apply redeem fee (discounted based on redeemer's NFT holdings)
                    let net_amount = self._apply_redeem_fee(asset.asset, amount, to);

                    if net_amount > 0 {
                        let erc20 = IERC20Dispatcher { contract_address: asset.asset };
                        erc20.transfer(to, net_amount);
                    }
                }

                i += 1;
            };
        }

        /// Redeem interest assets using tracked per-inscription balances.
        fn _redeem_interest_assets(
            ref self: ContractState,
            to: ContractAddress,
            inscription_id: u256,
            interest_count: u32,
            shares: u256,
            total_supply: u256,
        ) {
            let mut i: u32 = 0;
            while i < interest_count {
                let asset = self.inscription_interest_assets.read((inscription_id, i));
                let tracked_balance = self.inscription_interest_balance.read((inscription_id, i));
                let amount = tracked_balance * shares / total_supply;

                if amount > 0 {
                    self.inscription_interest_balance.write((inscription_id, i), tracked_balance - amount);

                    // Apply redeem fee
                    let net_amount = self._apply_redeem_fee(asset.asset, amount, to);

                    if net_amount > 0 {
                        let erc20 = IERC20Dispatcher { contract_address: asset.asset };
                        erc20.transfer(to, net_amount);
                    }
                }

                i += 1;
            };
        }

        /// Redeem collateral assets using tracked per-inscription balances.
        fn _redeem_collateral_assets(
            ref self: ContractState,
            to: ContractAddress,
            inscription_id: u256,
            collateral_count: u32,
            shares: u256,
            total_supply: u256,
        ) {
            let this_contract = get_contract_address();
            let mut i: u32 = 0;
            while i < collateral_count {
                let asset = self.inscription_collateral_assets.read((inscription_id, i));
                let tracked_balance = self.inscription_collateral_balance.read((inscription_id, i));

                match asset.asset_type {
                    AssetType::ERC721 => {
                        // NFTs can't be split — only full redemption. No fee for ERC721.
                        if tracked_balance > 0 {
                            self.inscription_collateral_balance.write((inscription_id, i), 0);
                            let erc721 = IERC721Dispatcher { contract_address: asset.asset };
                            erc721.transfer_from(this_contract, to, asset.token_id);
                        }
                    },
                    _ => {
                        let amount = tracked_balance * shares / total_supply;
                        if amount > 0 {
                            self.inscription_collateral_balance.write((inscription_id, i), tracked_balance - amount);

                            match asset.asset_type {
                                AssetType::ERC1155 => {
                                    // No redeem fee for ERC1155
                                    let erc1155 = IERC1155Dispatcher { contract_address: asset.asset };
                                    erc1155
                                        .safe_transfer_from(this_contract, to, asset.token_id, amount, array![].span());
                                },
                                _ => {
                                    // ERC20 and ERC4626: apply redeem fee
                                    let net_amount = self._apply_redeem_fee(asset.asset, amount, to);
                                    if net_amount > 0 {
                                        let erc20 = IERC20Dispatcher { contract_address: asset.asset };
                                        erc20.transfer(to, net_amount);
                                    }
                                },
                            }
                        }
                    },
                }

                i += 1;
            };
        }

        /// Process a single asset payment based on asset type.
        /// Skips ERC20/ERC4626 transfers when scaled amount is zero to prevent reverts.
        fn _process_payment(
            ref self: ContractState, asset: Asset, from: ContractAddress, to: ContractAddress, percentage: u256,
        ) {
            match asset.asset_type {
                AssetType::ERC721 => {
                    let erc721 = IERC721Dispatcher { contract_address: asset.asset };
                    erc721.transfer_from(from, to, asset.token_id);
                },
                AssetType::ERC1155 => {
                    let amount = scale_by_percentage(asset.value, percentage);
                    if amount > 0 {
                        let erc1155 = IERC1155Dispatcher { contract_address: asset.asset };
                        erc1155.safe_transfer_from(from, to, asset.token_id, amount, array![].span());
                    }
                },
                _ => {
                    let amount = scale_by_percentage(asset.value, percentage);
                    if amount > 0 {
                        let erc20 = IERC20Dispatcher { contract_address: asset.asset };
                        if from == get_contract_address() {
                            erc20.transfer(to, amount);
                        } else {
                            erc20.transfer_from(from, to, amount);
                        }
                    }
                },
            }
        }
    }
}
