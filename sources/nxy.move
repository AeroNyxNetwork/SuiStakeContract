module contract::nxy {
    // Import necessary modules
    use sui::object::{Self, ID, UID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use std::vector;
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::balance::{Self, Balance};
    use sui::pay;
    use sui::clock::{Self, Clock};
    use sui::event;
    use sui::table::{Self, Table};
    use std::string::{Self, String};

    // Define constants
    const UNSTAKE_ALREADY_UNSTAKE: u64 = 1;
    const UNSTAKE_NOT_ENOUGH: u64 = 2;
    const WITHDRAW_ERROR: u64 = 3;

    // Struct to represent a stake item
    struct SuiStakeItem has key, store {
        id: UID,
        amount: u64,
        unstake_time: u64,
    }

    // Struct to represent the stake status
    struct SuiStakeStatus has key {
        id: UID,
        stake_all: Balance<SUI>,
        unstake_all: u64,
        owner: address,
        bind: Table<address, String>,
    }

    // Event when a new object is created
    struct CreateEvent has drop, copy {
        obj_id: ID,
    }

    // Event when an object is deleted
    struct DeleteEvent has drop, copy {
        obj_id: ID,
    }

    // Event when a binding occurs
    struct BindEvent has drop, copy {
        sui_addr: address,
        nxy_addr: String,
    }

    // Initialize the contract
    fun init(ctx: &mut TxContext) {
        transfer::share_object(SuiStakeStatus {
            id: object::new(ctx),
            stake_all: balance::zero(),
            unstake_all: 0,
            owner: tx_context::sender(ctx),
            bind: table::new<address, String>(ctx),
        });
    }

    // Merge a vector of coins into a single coin
    fun merge_coins<T>(cs: vector<Coin<T>>, ctx: &mut TxContext): Coin<T> {
        if (vector::length(&cs) == 0) {
            let c = coin::zero<T>(ctx);
            vector::destroy_empty(cs);
            c
        } else {
            let c = vector::pop_back(&mut cs);
            pay::join_vec(&mut c, cs);
            c
        }
    }

    // Transfer or destroy a coin with a value of zero
    fun transfer_or_destroy_zero<X>(c: Coin<X>, addr: address) {
        if (coin::value(&c) > 0) {
            transfer::public_transfer(c, addr);
        } else {
            coin::destroy_zero(c);
        }
    }

    // Stake SUI tokens
    public entry fun stake(
        coin_list: vector<Coin<SUI>>,
        status: &mut SuiStakeStatus,
        in_amount: u64,
        ctx: &mut TxContext,
    ) {
        let bx = coin::into_balance(merge_coins(coin_list, ctx));
        assert!(balance::value(&bx) >= in_amount, 1);
        let in_balance = balance::split(&mut bx, in_amount);
        transfer_or_destroy_zero(coin::from_balance(bx, ctx), tx_context::sender(ctx));
        balance::join(
            &mut status.stake_all,
            in_balance,
        );
        let item = SuiStakeItem {
            id: object::new(ctx),
            amount: in_amount,
            unstake_time: 0,
        };
        event::emit(CreateEvent {
            obj_id: object::uid_to_inner(&item.id),
        });

        transfer::transfer(item, tx_context::sender(ctx));
    }

    // Unstake SUI tokens
    entry fun unstake(stake_items: vector<SuiStakeItem>, amount: u64, status: &mut SuiStakeStatus, clock: &Clock, ctx: &mut TxContext) {
        let all_amount = 0;
        while (!vector::is_empty(&mut stake_items)) {
            let stake_item = vector::pop_back(&mut stake_items);
            assert!(stake_item.unstake_time == 0, UNSTAKE_ALREADY_UNSTAKE);
            all_amount = all_amount + stake_item.amount;
            let SuiStakeItem { id: id, amount: _, unstake_time: _ } = stake_item;
            event::emit(DeleteEvent {
                obj_id: object::uid_to_inner(&id),
            });
            object::delete(id);
        };
        assert!(all_amount >= amount, UNSTAKE_NOT_ENOUGH);
        vector::destroy_empty(stake_items);

        let item = SuiStakeItem {
            id: object::new(ctx),
            amount: amount,
            unstake_time: clock::timestamp_ms(clock),
        };
        event::emit(CreateEvent {
            obj_id: object::uid_to_inner(&item.id),
        });
        transfer::transfer(item, tx_context::sender(ctx));
        if (all_amount - amount != 0) {
            let item = SuiStakeItem {
                id: object::new(ctx),
                amount: all_amount - amount,
                unstake_time: 0,
            };
            event::emit(CreateEvent {
                obj_id: object::uid_to_inner(&item.id),
            });
            transfer::transfer(item, tx_context::sender(ctx));
        };

        status.unstake_all = status.unstake_all + amount;
    }

    // Cancel unstaking
    entry fun cancel_unstake(stake_items: vector<SuiStakeItem>, status: &mut SuiStakeStatus, ctx: &mut TxContext) {
        let all_amount = 0;
        let unstake_all = 0;
        while (!vector::is_empty(&mut stake_items)) {
            let stake_item = vector::pop_back(&mut stake_items);
            all_amount = all_amount + stake_item.amount;
            if (stake_item.unstake_time != 0) {
                unstake_all = unstake_all + stake_item.amount;
            };
            let SuiStakeItem { id: id, amount: _, unstake_time: _ } = stake_item;
            event::emit(DeleteEvent {
                obj_id: object::uid_to_inner(&id),
            });
            object::delete(id);
        };
        vector::destroy_empty(stake_items);

        if (all_amount != 0) {
            let item = SuiStakeItem {
                id: object::new(ctx),
                amount: all_amount,
                unstake_time: 0,
            };
            event::emit(CreateEvent {
                obj_id: object::uid_to_inner(&item.id),
            });
            transfer::transfer(item, tx_context::sender(ctx));
        };
        status.unstake_all = status.unstake_all - unstake_all;
    }

    // Set a new admin address
    entry fun set_admin(new_address: address, status: &mut SuiStakeStatus, ctx: &mut TxContext) {
        if (tx_context::sender(ctx) == status.owner) {
            status.owner = new_address;
        }
    }

    // Withdraw SUI tokens from staked items
    entry fun withdraw(stake_items: vector<SuiStakeItem>, status: &mut SuiStakeStatus, clock: &Clock, ctx: &mut TxContext) {
        let all_amount = 0;
        while (!vector::is_empty(&mut stake_items)) {
            let stake_item = vector::pop_back(&mut stake_items);
            assert!(stake_item.unstake_time != 0 && clock::timestamp_ms(clock) - stake_item.unstake_time > 1000 * 60, WITHDRAW_ERROR);
            all_amount = all_amount + stake_item.amount;
            let SuiStakeItem { id: id, amount: _, unstake_time: _ } = stake_item;
            event::emit(DeleteEvent {
                obj_id: object::uid_to_inner(&id),
            });
            object::delete(id);
        };
        vector::destroy_empty(stake_items);

        assert!(balance::value(&status.stake_all) >= all_amount, WITHDRAW_ERROR);
        let in_balance = balance::split(&mut status.stake_all, all_amount);
        transfer_or_destroy_zero(coin::from_balance(in_balance, ctx), tx_context::sender(ctx));
        status.unstake_all = status.unstake_all - all_amount;
    }

    // Bind NXY address to the contract
    entry fun bindNxy(nxy_addr: String, status: &mut SuiStakeStatus, ctx: &mut TxContext) {
        if (table::contains(&status.bind, tx_context::sender(ctx))) {
            table::remove(&mut status.bind, tx_context::sender(ctx));
        };
        table::add(&mut status.bind, tx_context::sender(ctx), nxy_addr);
        event::emit(BindEvent {
            sui_addr: tx_context::sender(ctx),
            nxy_addr: nxy_addr,
        });
    }

    // Get the number of NXY addresses bound to the contract
    public fun GetBindNxy(user_addr: address, status: &mut SuiStakeStatus): u64 {
        table::length(&mut status.bind)
    }
}
