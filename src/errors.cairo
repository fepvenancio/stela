// Stela protocol error messages

pub mod Errors {
    pub const INVALID_INSCRIPTION: felt252 = 'STELA: invalid inscription';
    pub const INSCRIPTION_EXISTS: felt252 = 'STELA: inscription exists';
    pub const INSCRIPTION_EXPIRED: felt252 = 'STELA: inscription expired';
    pub const ALREADY_REPAID: felt252 = 'STELA: already repaid';
    pub const ALREADY_LIQUIDATED: felt252 = 'STELA: already liquidated';
    pub const NOT_YET_LIQUIDATABLE: felt252 = 'STELA: not yet liquidatable';
    pub const REPAY_TOO_EARLY: felt252 = 'STELA: repay too early';
    pub const EXCEEDS_MAX_BPS: felt252 = 'STELA: exceeds max bps';
    pub const NOT_REDEEMABLE: felt252 = 'STELA: not redeemable';
    pub const ZERO_SHARES: felt252 = 'STELA: zero shares';
    pub const UNAUTHORIZED: felt252 = 'STELA: unauthorized';
    pub const FORBIDDEN_SELECTOR: felt252 = 'STELA: forbidden selector';
    pub const ZERO_DEBT_ASSETS: felt252 = 'STELA: zero debt assets';
    pub const ZERO_COLLATERAL: felt252 = 'STELA: zero collateral';
    pub const NOT_CANCELLABLE: felt252 = 'STELA: not cancellable';
    pub const NOT_CREATOR: felt252 = 'STELA: not creator';
    pub const REPAY_WINDOW_CLOSED: felt252 = 'STELA: repay window closed';
    pub const NFT_ALREADY_LOCKED: felt252 = 'STELA: nft already locked';
    pub const ALREADY_SIGNED: felt252 = 'STELA: already signed';
    pub const INVALID_ADDRESS: felt252 = 'STELA: invalid address';
    pub const FEE_TOO_HIGH: felt252 = 'STELA: fee too high';
    pub const ZERO_ASSET_VALUE: felt252 = 'STELA: zero asset value';
    pub const ZERO_IMPL_HASH: felt252 = 'STELA: zero impl hash';
    pub const NFT_NOT_FUNGIBLE: felt252 = 'STELA: nft not fungible';
    pub const TOO_MANY_ASSETS: felt252 = 'STELA: too many assets';
    pub const INVALID_SIGNATURE: felt252 = 'STELA: invalid signature';
    pub const INVALID_NONCE: felt252 = 'STELA: invalid nonce';
    pub const ORDER_EXPIRED: felt252 = 'STELA: order expired';
    pub const INVALID_ORDER: felt252 = 'STELA: invalid order';
    pub const NFT_MULTI_LENDER: felt252 = 'STELA: nft no multi lender';
    pub const PAUSED: felt252 = 'STELA: paused';
}
