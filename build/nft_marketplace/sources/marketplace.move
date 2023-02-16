module marketplace_addr::marketplace {
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::timestamp;
    use aptos_framework::account;
    use aptos_framework::account::SignerCapability;
    use aptos_framework::guid;

    use std::signer;
    use std::option::{Self, Option, some};
    use std::string::{String};
    use aptos_std::event::{Self, EventHandle};
    use aptos_std::table::{Self, Table};
    // use aptos_std::debug::{print};

    use aptos_token::token::{Self, Token, TokenId};

    const ERROR_INVALID_BUYER: u64 = 0;
    const ERROR_INSUFFICIENT_BID: u64 = 1;
    const ERROR_AUCTION_INACTIVE: u64 = 2;
    const ERROR_AUCTION_NOT_COMPLETE: u64 = 3;
    const ERROR_NOT_CLAIMABLE: u64 = 4;
    const ERROR_CLAIM_COINS_FIRST: u64 = 5;
    const ERROR_ALREADY_CLAIMED: u64 = 6;
    const ERROR_INVALID_OWNER: u64 = 7;
    const ERROR_MARKET_ALREADY_INITIALIZED: u64 = 8;
    const ERROR_ITEM_NOT_AUCTION: u64 = 9;
    const ERROR_NOT_AUTHORIZED: u64 = 10;
    const ERROR_ITEM_AUCTION: u64 = 9;

    struct TokenCap has key {
        cap: SignerCapability,
    }

    struct MarketData has key {
        owner_cut: u64,
        owner: address,
    }

    struct ListEvent has drop, store {
        seller: address,
        starting_price: u64,
        id: TokenId,
        duration: u64,
        timestamp: u64,
        listing_id: u64,
        is_auction: bool,

        royalty_payee: address,
        royalty_numerator: u64,
        royalty_denominator: u64
    }

    struct DelistEvent has drop, store {
        id: TokenId,
        timestamp: u64,
        listing_id: u64,
        seller: address,
    }

    struct BuyEvent has drop, store {
        id: TokenId,
        amount: u64,
        timestamp: u64,
        listing_id: u64,
        seller_address: address,
        buyer_address: address
    }

    struct ChangePriceEvent has drop, store {
        id: TokenId,
        amount: u64,
        listing_id: u64,
        timestamp: u64,
        seller_address: address,
    }

    struct ListedItem has store {
        seller: address,
        starting_price: u64,
        token: Option<Token>,
        duration: u64,
        started_at: u64,
        highest_bidder: Option<address>,
        highest_price: u64,
        listing_id: u64,
        is_auction: bool,
    }

    struct BidEvent has store, drop {
        id: TokenId,
        listing_id: u64,
        timestamp: u64,
        bid: u64,
        bidder_address: address
    }

    struct ClaimTokenEvent has store, drop {
        id: TokenId,
        auction_id: u64,
        timestamp: u64,
        bidder_address: address
    }

    struct ClaimCoinsEvent has store, drop {
        id: TokenId,
        auction_id: u64,
        timestamp: u64,
        owner_token: address
    }

    struct ListedItemsData has key {
        listed_items: Table<TokenId, ListedItem>,
        listing_events: EventHandle<ListEvent>,
        buying_events: EventHandle<BuyEvent>,
        delisting_events: EventHandle<DelistEvent>,
        changing_price_events: EventHandle<ChangePriceEvent>,
        bid_events: EventHandle<BidEvent>,
        claim_token_events: EventHandle<ClaimTokenEvent>,
        claim_coins_events: EventHandle<ClaimCoinsEvent>,
    }

    struct CoinEscrow<phantom CoinType> has key {
        locked_coins: Table<TokenId, Coin<CoinType>>,
    }

    struct TokenEscrowOffer has key {
        locked_tokens: Table<TokenId, Token>
    }

    public entry fun init_market(sender: &signer, owner_cut: u64) {
        let sender_addr = signer::address_of(sender);
        let (market_signer, market_cap) = account::create_resource_account(sender, x"01");
        let market_signer_address = signer::address_of(&market_signer);

        assert!(sender_addr == @marketplace_addr, ERROR_INVALID_OWNER);

        if(!exists<TokenCap>(@marketplace_addr)){
            move_to(sender, TokenCap {
                cap: market_cap
            })
        };

        if (!exists<MarketData>(market_signer_address)){
            move_to(&market_signer, MarketData {
                owner_cut: owner_cut,
                owner: sender_addr,
            })
        };

        if (!exists<ListedItemsData>(market_signer_address)) {
            move_to(&market_signer, ListedItemsData {
                listed_items:table::new<TokenId, ListedItem>(),
                listing_events: account::new_event_handle<ListEvent>(&market_signer),
                buying_events: account::new_event_handle<BuyEvent>(&market_signer),
                delisting_events: account::new_event_handle<DelistEvent>(&market_signer),
                changing_price_events: account::new_event_handle<ChangePriceEvent>(&market_signer),
                bid_events: account::new_event_handle<BidEvent>(&market_signer),
                claim_token_events: account::new_event_handle<ClaimTokenEvent>(&market_signer),
                claim_coins_events: account::new_event_handle<ClaimCoinsEvent>(&market_signer)
            });
        };
    }

    public entry fun create_listing_script(
        sender: &signer,
        creator: address,
        collection_name: String,
        token_name: String,
        property_version: u64,
        price: u64,
        duration: u64, 
        started_at: u64, 
        is_auction: bool,
    ) acquires ListedItemsData, TokenCap {
        let token_id = token::create_token_id_raw(creator, collection_name, token_name, property_version);
        create_listing(
            sender, 
            token_id, 
            price, 
            duration, 
            started_at, 
            is_auction
        );
    }

    fun create_listing(
        sender: &signer, 
        token_id: TokenId,
        starting_price: u64, 
        duration: u64, 
        started_at: u64, 
        is_auction: bool,
    ) acquires ListedItemsData, TokenCap {
        let sender_addr = signer::address_of(sender);
        let market_cap = &borrow_global<TokenCap>(@marketplace_addr).cap;
        let market_signer = &account::create_signer_with_capability(market_cap);
        let market_signer_address = signer::address_of(market_signer);

        let token = token::withdraw_token(sender, token_id, 1);
        let listed_items_data = borrow_global_mut<ListedItemsData>(market_signer_address);
        let listed_items = &mut listed_items_data.listed_items;

        let royalty = token::get_royalty(token_id);
        let royalty_payee = token::get_royalty_payee(&royalty);
        let royalty_numerator = token::get_royalty_numerator(&royalty);
        let royalty_denominator = token::get_royalty_denominator(&royalty);
    
        let guid = account::create_guid(market_signer);
        let listing_id = guid::creation_num(&guid);

        event::emit_event<ListEvent>(
            &mut listed_items_data.listing_events,
            ListEvent { 
                id: token_id,
                starting_price,
                seller: sender_addr,
                duration,
                timestamp: timestamp::now_seconds(),
                listing_id,
                is_auction,

                royalty_payee,
                royalty_numerator,
                royalty_denominator 
            },
        );

        table::add(listed_items, token_id, ListedItem {
            seller: sender_addr,
            starting_price,
            token: some(token),
            duration,
            started_at,
            highest_bidder: option::none(),
            highest_price: 0,
            listing_id,
            is_auction,
        })
    }

    public entry fun bid_scipt(
        sender: &signer, 
        creator: address,
        collection_name: String,
        token_name: String,
        property_version: u64, 
        price: u64
    ) acquires CoinEscrow, ListedItemsData, TokenCap {
        let token_id = token::create_token_id_raw(creator, collection_name, token_name, property_version);
        bid<AptosCoin>(sender, token_id, price);
    }

    fun bid<CoinType>(
        sender: &signer, 
        token_id: TokenId,
        price: u64
    ) acquires CoinEscrow, ListedItemsData, TokenCap {
        let sender_addr = signer::address_of(sender);
        let market_cap = &borrow_global<TokenCap>(@marketplace_addr).cap;
        let market_signer = &account::create_signer_with_capability(market_cap);
        let market_signer_address = signer::address_of(market_signer);

        let listed_items_data = borrow_global_mut<ListedItemsData>(market_signer_address);
        let listed_items = &mut listed_items_data.listed_items;
        let listed_item = table::borrow_mut(listed_items, token_id);
        let seller = listed_item.seller;

        assert!(sender_addr != seller, ERROR_INVALID_BUYER);
        assert!(is_auction_active(listed_item.started_at, listed_item.duration), ERROR_AUCTION_INACTIVE);
        assert!(price > listed_item.highest_price, ERROR_INSUFFICIENT_BID);
        assert!(listed_item.is_auction == true, ERROR_ITEM_NOT_AUCTION);

        if (!exists<CoinEscrow<CoinType>>(sender_addr)) {
            move_to(sender, CoinEscrow {
                locked_coins: table::new<TokenId, Coin<CoinType>>()
            });
        };

        if (listed_item.highest_bidder != option::none()) {
            let bidder = option::extract(&mut listed_item.highest_bidder);
            let current_bidder_locked_coins = &mut borrow_global_mut<CoinEscrow<CoinType>>(bidder).locked_coins;
            let coins = table::remove(current_bidder_locked_coins, token_id);
            coin::deposit<CoinType>(bidder, coins);
        };

        event::emit_event<BidEvent>(
            &mut listed_items_data.bid_events,
            BidEvent { 
                id: token_id, 
                listing_id: listed_item.listing_id,
                bid: price,
                timestamp: timestamp::now_seconds(),
                bidder_address: sender_addr 
            },
        );

        let locked_coins = &mut borrow_global_mut<CoinEscrow<CoinType>>(sender_addr).locked_coins;
        let coins = coin::withdraw<CoinType>(sender, price);
        table::add(locked_coins, token_id, coins);

        listed_item.highest_bidder = some(sender_addr);
        listed_item.highest_price = price;
    }


    public entry fun cancel_listing_script(
        sender: &signer,
        creator: address,
        collection_name: String,
        token_name: String,
        property_version: u64,
    ) acquires ListedItemsData, TokenCap {
        let token_id = token::create_token_id_raw(creator, collection_name, token_name, property_version);
        cancel_listing(sender, token_id);
    }

    fun cancel_listing(
        sender: &signer, 
        token_id: TokenId
    ) acquires ListedItemsData, TokenCap {
        let sender_addr = signer::address_of(sender);
        let market_cap = &borrow_global<TokenCap>(@marketplace_addr).cap;
        let market_signer = &account::create_signer_with_capability(market_cap);
        let market_signer_address = signer::address_of(market_signer);

        let listed_items_data = borrow_global_mut<ListedItemsData>(market_signer_address);
        let listed_items = &mut listed_items_data.listed_items;
        let listed_item = table::borrow_mut(listed_items, token_id);

        assert!(listed_item.seller == sender_addr, ERROR_NOT_AUTHORIZED);

        event::emit_event<DelistEvent>(
            &mut listed_items_data.delisting_events,
            DelistEvent { 
                id: token_id, 
                listing_id: listed_item.listing_id,
                timestamp: timestamp::now_seconds(),
                seller: sender_addr 
            },
        );

        let token = option::extract(&mut listed_item.token);
        token::deposit_token(sender, token);

        let ListedItem {
            seller: _,
            starting_price: _,
            token,
            duration: _,
            started_at: _,
            highest_bidder: _,
            highest_price: _,
            listing_id: _,
            is_auction: _, 
        } = table::remove(listed_items, token_id);
        option::destroy_none(token);
    }

    public entry fun purchase_nft_script(
        sender: &signer, 
        creator: address,
        collection_name: String,
        token_name: String,
        property_version: u64, 
    ) acquires ListedItemsData, MarketData, CoinEscrow, TokenCap {
        let token_id = token::create_token_id_raw(creator, collection_name, token_name, property_version);
        purchase_nft<AptosCoin>(sender, token_id);
    }
    
    fun purchase_nft<CoinType>(
        sender: &signer, 
        token_id: TokenId
    ) acquires ListedItemsData, MarketData, CoinEscrow, TokenCap {
        let sender_addr = signer::address_of(sender);

        let market_cap = &borrow_global<TokenCap>(@marketplace_addr).cap;
        let market_signer = &account::create_signer_with_capability(market_cap);
        let market_signer_address = signer::address_of(market_signer);
        let market_data = borrow_global<MarketData>(market_signer_address);

        let listed_items_data = borrow_global_mut<ListedItemsData>(market_signer_address);
        let listed_items = &mut listed_items_data.listed_items;
        let listed_item = table::borrow_mut(listed_items, token_id);

        // if (!exists<CoinEscrow<CoinType>>(sender_addr)) {
        //     move_to(sender, CoinEscrow {
        //         locked_coins: table::new<TokenId, Coin<CoinType>>()
        //     });
        // };

        assert!(listed_item.is_auction == true, ERROR_ITEM_NOT_AUCTION);
        assert!(is_auction_complete(listed_item.started_at, listed_item.duration), ERROR_AUCTION_NOT_COMPLETE);
        assert!(sender_addr == option::extract(&mut listed_item.highest_bidder), ERROR_NOT_CLAIMABLE);

        event::emit_event<ClaimTokenEvent>(
            &mut listed_items_data.claim_token_events,
            ClaimTokenEvent { 
                id: token_id,
                auction_id: listed_item.listing_id,
                timestamp: timestamp::now_seconds(),
                bidder_address: sender_addr 
            },
        );

        let token = option::extract(&mut listed_item.token);
        token::deposit_token(sender, token);

        let royalty = token::get_royalty(token_id);
        let royalty_payee = token::get_royalty_payee(&royalty);
        let royalty_numerator = token::get_royalty_numerator(&royalty);
        let royalty_denominator = token::get_royalty_denominator(&royalty);

        // the auction item can be removed from the auctiondata of the seller once the token and coins are claimed
        let locked_coins = &mut borrow_global_mut<CoinEscrow<CoinType>>(sender_addr).locked_coins;
        // deposit the locked coins to the seller's sender if they have not claimed yet
        
        assert!(table::contains(locked_coins, token_id) == true, ERROR_NOT_CLAIMABLE);
        event::emit_event<ClaimCoinsEvent>(
            &mut listed_items_data.claim_coins_events,
            ClaimCoinsEvent { 
                id: token_id, 
                auction_id: listed_item.listing_id,
                timestamp: timestamp::now_seconds(),
                owner_token: listed_item.seller 
            },
        );

        let coins = table::remove(locked_coins, token_id);
        let amount = coin::value(&coins);
        let fee = market_data.owner_cut * amount / 10000;
        let royalty_fee = amount * royalty_numerator / royalty_denominator;

        if (fee > 0) {
            coin::deposit(market_data.owner, coin::extract(&mut coins, fee));
        };
        
        if (royalty_fee > 0) {
            coin::deposit(royalty_payee, coin::extract(&mut coins, royalty_fee));
        };

        let seller = listed_item.seller;
        coin::deposit<CoinType>(seller, coins);

        // remove aution data when token has been claimed
        let ListedItem { 
            seller: _,
            starting_price: _,
            token,
            duration: _,
            started_at: _,
            highest_bidder: _,
            highest_price: _,
            listing_id: _,
            is_auction: _, 
        } = table::remove(listed_items, token_id);
        option::destroy_none(token);
    }

    public entry fun buy_nft_script(
        sender: &signer, 
        creator: address,
        collection_name: String,
        token_name: String,
        property_version: u64, 
    ) acquires ListedItemsData, TokenCap, MarketData {
        let token_id = token::create_token_id_raw(creator, collection_name, token_name, property_version);
        buy_nft<AptosCoin>(sender, token_id);
    }

    fun buy_nft<CoinType>(
        sender: &signer, 
        token_id: TokenId
    ) acquires ListedItemsData, TokenCap, MarketData {
        let sender_addr = signer::address_of(sender);

        let market_cap = &borrow_global<TokenCap>(@marketplace_addr).cap;
        let market_signer = &account::create_signer_with_capability(market_cap);
        let market_signer_address = signer::address_of(market_signer);
        let market_data = borrow_global_mut<MarketData>(market_signer_address);

        let listed_items_data = borrow_global_mut<ListedItemsData>(market_signer_address);
        let listed_items = &mut listed_items_data.listed_items;
        let listed_item = table::borrow_mut(listed_items, token_id);
        let seller = listed_item.seller;

        assert!(sender_addr != seller, ERROR_INVALID_BUYER);
        assert!(listed_item.is_auction == false, ERROR_ITEM_AUCTION);

        let royalty = token::get_royalty(token_id);
        let royalty_payee = token::get_royalty_payee(&royalty);
        let royalty_numerator = token::get_royalty_numerator(&royalty);
        let royalty_denominator = token::get_royalty_denominator(&royalty);

        let _fee_royalty: u64 = 0;

        if (royalty_denominator == 0){
            _fee_royalty = 0;
        } else {
            _fee_royalty = royalty_numerator * listed_item.starting_price / royalty_denominator;
        };

        let fee_listing = listed_item.starting_price * market_data.owner_cut / 10000;
        let sub_amount = listed_item.starting_price - fee_listing - _fee_royalty;

        if (_fee_royalty > 0) {
            coin::transfer<CoinType>(sender, royalty_payee, _fee_royalty);
        };

        if (fee_listing > 0) {
            coin::transfer<CoinType>(sender, market_data.owner, fee_listing);
        };

        coin::transfer<CoinType>(sender, seller, sub_amount);

        let token = option::extract(&mut listed_item.token);
        token::deposit_token(sender, token);

        event::emit_event<BuyEvent>(
            &mut listed_items_data.buying_events,
            BuyEvent { 
                id: token_id, 
                listing_id: listed_item.listing_id,
                seller_address: listed_item.seller,
                timestamp: timestamp::now_seconds(),
                buyer_address: sender_addr ,
                amount: sub_amount
            },
        );

        let ListedItem {
            seller: _,
            starting_price: _,
            token,
            duration: _,
            started_at: _,
            highest_bidder: _,
            highest_price: _,
            listing_id: _,
            is_auction: _, 
        } = table::remove(listed_items, token_id);
        option::destroy_none(token);
    }

    public entry fun set_price_script(
        sender: &signer, 
        creator: address,
        collection_name: String,
        token_name: String,
        property_version: u64, 
        price: u64
    ) acquires ListedItemsData, TokenCap {
        let token_id = token::create_token_id_raw(creator, collection_name, token_name, property_version);
        set_price(sender, token_id, price);
    }

    fun set_price(
        sender: &signer, 
        token_id: TokenId,
        price: u64
    ) acquires ListedItemsData, TokenCap {
        let sender_addr = signer::address_of(sender);
        let market_cap = &borrow_global<TokenCap>(@marketplace_addr).cap;
        let market_signer = &account::create_signer_with_capability(market_cap);
        let market_signer_address = signer::address_of(market_signer);

        let listed_items_data = borrow_global_mut<ListedItemsData>(market_signer_address);
        let listed_items = &mut listed_items_data.listed_items;

        assert!(table::contains(listed_items, token_id), ERROR_ALREADY_CLAIMED);

        let listed_item = table::borrow_mut(listed_items, token_id);
        assert!(listed_item.is_auction == false, ERROR_ITEM_AUCTION);
        assert!(sender_addr == listed_item.seller, ERROR_NOT_AUTHORIZED);

        listed_item.starting_price = price;

        event::emit_event(&mut listed_items_data.changing_price_events, ChangePriceEvent {
            id: token_id,
            listing_id: listed_item.listing_id,
            amount: price,
            timestamp: timestamp::now_seconds(),
            seller_address: sender_addr
        })
    } 

    fun is_auction_active(started_at: u64, duration: u64): bool {
        let current_time = timestamp::now_seconds();
        current_time <= started_at + duration && current_time >= started_at
    }

    fun is_auction_complete(started_at: u64, duration: u64): bool {
        let current_time = timestamp::now_seconds();
        current_time > started_at + duration
    }

    fun get_market_signer_address(market_addr: address) : address acquires TokenCap {
        let market_cap = &borrow_global<TokenCap>(market_addr).cap;
        let market_signer = &account::create_signer_with_capability(market_cap);
        let market_signer_address = signer::address_of(market_signer);

        market_signer_address
    }

    #[test(market = @marketplace_addr)]
    public fun test_initial_market(market: &signer) acquires MarketData, TokenCap {
        // create amount
        account::create_account_for_test(signer::address_of(market));
        init_market(market, 10);

        let market_addr = signer::address_of(market);
        let market_signer_address = get_market_signer_address(market_addr);
        let market_data = borrow_global_mut<MarketData>(market_signer_address);

        assert!(market_data.owner == market_addr, 0);
        assert!(market_data.owner_cut == 10, 0);
    }

    #[test(aptos_framework = @0x1, market = @marketplace_addr, seller = @0xAE)]
    public fun test_cancel_list_token(market: &signer, aptos_framework: &signer, seller: &signer) acquires ListedItemsData, TokenCap {
        // set timestamp
        timestamp::set_time_has_started_for_testing(aptos_framework);
        // create amount
        account::create_account_for_test(signer::address_of(aptos_framework));
        account::create_account_for_test(signer::address_of(market));
        account::create_account_for_test(signer::address_of(seller));

        // initial market
        init_market(market, 10);

        let market_addr = signer::address_of(market);

        let token_id = token::create_collection_and_token(
            seller,
            2,
            2,
            2,
            // vector<String>[],
            // vector<vector<u8>>[],
            // vector<String>[],
            // vector<bool>[false, false, false],
            // vector<bool>[false, false, false, false, false],
        );
        
        create_listing(
            seller, 
            token_id,
            1, 
            0, 
            0, 
            true
        );

        cancel_listing(
            seller, 
            token_id,
        );

        let market_signer_address = get_market_signer_address(market_addr);
        let listed_items_data = borrow_global_mut<ListedItemsData>(market_signer_address);
        let listed_items = &mut listed_items_data.listed_items;

        assert!(!table::contains(listed_items, token_id), 0);
    }

    #[test(aptos_framework = @0x1, market = @marketplace_addr, seller = @0xAF, buyer = @0xAE)]
    public fun test_buy_token(market: &signer, aptos_framework: &signer, seller: &signer, buyer: &signer) acquires ListedItemsData, TokenCap, MarketData {
        // set timestamp
        timestamp::set_time_has_started_for_testing(aptos_framework);
        // create amount
        account::create_account_for_test(signer::address_of(aptos_framework));
        account::create_account_for_test(signer::address_of(market));
        account::create_account_for_test(signer::address_of(seller));
        account::create_account_for_test(signer::address_of(buyer));

        // initial market
        init_market(market, 200);

        let market_addr = signer::address_of(market);

        let token_id = token::create_collection_and_token(
            seller,
            2,
            2,
            2,
            // vector<String>[],
            // vector<vector<u8>>[],
            // vector<String>[],
            // vector<bool>[false, false, false],
            // vector<bool>[false, false, false, false, false],
        );
        
        create_listing(
            seller, 
            token_id,
            300, 
            0, 
            0, 
            false
        );

        let market_signer_address = get_market_signer_address(market_addr);
        let listed_items_data = borrow_global_mut<ListedItemsData>(market_signer_address);
        let listed_items = &mut listed_items_data.listed_items;
        
        assert!(table::contains(listed_items, token_id), 0);

        coin::create_fake_money(aptos_framework, buyer, 300);
        coin::transfer<coin::FakeMoney>(aptos_framework, signer::address_of(buyer), 300);

        assert!(coin::balance<coin::FakeMoney>(signer::address_of(buyer)) == 300, 1);

        coin::register<coin::FakeMoney>(seller);
        coin::register<coin::FakeMoney>(market);

        buy_nft<coin::FakeMoney>(buyer, token_id);

        assert!(coin::balance<coin::FakeMoney>(signer::address_of(market)) == 6, 1);
        assert!(coin::balance<coin::FakeMoney>(signer::address_of(seller)) == 294, 1);
        assert!(coin::balance<coin::FakeMoney>(signer::address_of(buyer)) == 0, 1);
    }


    #[test(aptos_framework = @0x1, market = @marketplace_addr, seller = @0xAE)]
    public fun test_change_token_price(market: &signer, aptos_framework: &signer, seller: &signer) acquires ListedItemsData, TokenCap {

        // set timestamp
        timestamp::set_time_has_started_for_testing(aptos_framework);
        // create amount
        account::create_account_for_test(signer::address_of(aptos_framework));
        account::create_account_for_test(signer::address_of(market));
        account::create_account_for_test(signer::address_of(seller));

        // initial market
        init_market(market, 200);

        let token_id = token::create_collection_and_token(
            seller,
            2,
            2,
            2,
        );

        create_listing(
            seller, 
            token_id,
            300, 
            0, 
            0, 
            false
        );
        set_price(seller, token_id, 200);

        let market_addr = signer::address_of(market);
        let market_signer_address = get_market_signer_address(market_addr);
        let listed_items_data = borrow_global_mut<ListedItemsData>(market_signer_address);
        let listed_items = &mut listed_items_data.listed_items;
        let listed_item = table::borrow_mut(listed_items, token_id);

        assert!(listed_item.starting_price == 200, 0);
    }

    #[test(aptos_framework = @0x1, market = @marketplace_addr, seller = @0xAF, bidder1 = @0xAE)]
    public fun test_bid(market: &signer, aptos_framework: &signer, seller: &signer, bidder1: &signer) acquires CoinEscrow, ListedItemsData, TokenCap {
        // set timestamp
        timestamp::set_time_has_started_for_testing(aptos_framework);
        // create amount
        account::create_account_for_test(signer::address_of(aptos_framework));
        account::create_account_for_test(signer::address_of(market));
        account::create_account_for_test(signer::address_of(seller));
        account::create_account_for_test(signer::address_of(bidder1));
        // account::create_account_for_test(signer::address_of(bidder2));

        // initial market
        init_market(market, 200);

        let token_id = token::create_collection_and_token(
            seller,
            2,
            2,
            2,
            // vector<String>[],
            // vector<vector<u8>>[],
            // vector<String>[],
            // vector<bool>[false, false, false],
            // vector<bool>[false, false, false, false, false],
        );

        create_listing(
            seller, 
            token_id,
            100, 
            0, 
            0, 
            true
        );

        coin::create_fake_money(aptos_framework, bidder1, 600);
        coin::transfer<coin::FakeMoney>(aptos_framework, signer::address_of(bidder1), 300);

        bid<coin::FakeMoney>(bidder1, token_id, 200);

        let market_addr = signer::address_of(market);
        let market_signer_address = get_market_signer_address(market_addr);
        let auction_data = borrow_global_mut<ListedItemsData>(market_signer_address);
        let auction_items = &mut auction_data.listed_items;
        let auction_item = table::borrow_mut(auction_items, token_id);

        assert!(auction_item.highest_price == 200, 0);
    }

    #[test(aptos_framework = @0x1, market = @marketplace_addr, seller = @0xAF, bidder1 = @0xAE, bidder2 = @0xAD)]
    public fun test_claim_auction_token(market: &signer, aptos_framework: &signer, seller: &signer, bidder1: &signer, bidder2: &signer) acquires CoinEscrow, ListedItemsData, TokenCap, MarketData {
        // set timestamp
        timestamp::set_time_has_started_for_testing(aptos_framework);
        // create amount
        account::create_account_for_test(signer::address_of(aptos_framework));
        account::create_account_for_test(signer::address_of(market));
        account::create_account_for_test(signer::address_of(seller));
        account::create_account_for_test(signer::address_of(bidder1));
        account::create_account_for_test(signer::address_of(bidder2));

        // initial market
        init_market(market, 200);

        let token_id = token::create_collection_and_token(
            seller,
            2,
            2,
            2,
            // vector<String>[],
            // vector<vector<u8>>[],
            // vector<String>[],
            // vector<bool>[false, false, false],
            // vector<bool>[false, false, false, false, false],
        );

        // initial auction
        create_listing(
            seller, 
            token_id,
            100, 
            0, 
            0, 
            true
        );

        coin::register<coin::FakeMoney>(seller);

        coin::create_fake_money(aptos_framework, bidder1, 600);
        coin::transfer<coin::FakeMoney>(aptos_framework, signer::address_of(bidder1), 300);

        coin::register<coin::FakeMoney>(bidder2);
        coin::register<coin::FakeMoney>(market);

        coin::transfer<coin::FakeMoney>(aptos_framework, signer::address_of(bidder2), 300);

        bid<coin::FakeMoney>(bidder1, token_id, 200);
        bid<coin::FakeMoney>(bidder2, token_id, 250);

        timestamp::update_global_time_for_test(130000*1000);

        purchase_nft<coin::FakeMoney>(bidder2, token_id);

        assert!(coin::balance<coin::FakeMoney>(signer::address_of(market)) == 5, 1);
        assert!(coin::balance<coin::FakeMoney>(signer::address_of(seller)) == 245, 1);
    }
}