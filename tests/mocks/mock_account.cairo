// Mock account for testing signed order signature verification.
// Always returns VALIDATED for is_valid_signature, enabling fill_signed_order
// tests without real ECDSA keys.

#[starknet::contract(account)]
pub mod MockAccount {
    use openzeppelin_interfaces::account::accounts::{ISRC6, ISRC6_ID};
    use openzeppelin_introspection::src5::SRC5Component;
    use starknet::VALIDATED;
    use starknet::account::Call;

    component!(path: SRC5Component, storage: src5, event: SRC5Event);
    #[abi(embed_v0)]
    impl SRC5Impl = SRC5Component::SRC5Impl<ContractState>;
    impl SRC5InternalImpl = SRC5Component::InternalImpl<ContractState>;

    #[storage]
    struct Storage {
        #[substorage(v0)]
        src5: SRC5Component::Storage,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        SRC5Event: SRC5Component::Event,
    }

    #[constructor]
    fn constructor(ref self: ContractState) {
        self.src5.register_interface(ISRC6_ID);
    }

    #[abi(embed_v0)]
    impl ISRC6Impl of ISRC6<ContractState> {
        fn __execute__(self: @ContractState, calls: Array<Call>) {}
        fn __validate__(self: @ContractState, calls: Array<Call>) -> felt252 {
            VALIDATED
        }
        fn is_valid_signature(self: @ContractState, hash: felt252, signature: Array<felt252>) -> felt252 {
            VALIDATED
        }
    }
}
