// ILockerAccount — Token-bound account (TBA) interface for collateral locking.
// Implemented by LockerAccount (SNIP-14 compliant account with allowlist-based lockdown).

use crate::types::asset::Asset;
use starknet::ContractAddress;

#[starknet::interface]
pub trait ILockerAccount<TContractState> {
    /// Pull assets from the locker to the Stela contract.
    /// Only callable by the Stela contract.
    fn pull_assets(ref self: TContractState, assets: Array<Asset>);

    /// Unlock the locker, removing execution restrictions.
    /// Only callable by the Stela contract.
    fn unlock(ref self: TContractState);

    /// Add or remove a (target, selector) pair from the allowlist.
    /// When locked, only allowlisted (target, selector) pairs can be called.
    /// Only callable by the Stela contract.
    fn set_allowed_selector(
        ref self: TContractState, target: ContractAddress, selector: felt252, allowed: bool,
    );

    /// Check if the locker is currently unlocked.
    fn is_unlocked(self: @TContractState) -> bool;

    /// Check if a (target, selector) pair is in the allowlist.
    fn is_selector_allowed(
        self: @TContractState, target: ContractAddress, selector: felt252,
    ) -> bool;
}
