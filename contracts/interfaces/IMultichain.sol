// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.4.22 <0.9.0;

interface Multi  {
  //0.0 Settings
  struct Settings {
    uint epochspan;
    uint MARGIN_BPS;
    uint max_epochs;
    uint MINGAS;
    uint max_orders;
    uint gasForDestinationLzReceive;
    uint lambda;
  }
  
  //1.1 Stardard Orders Struct. If you place a trade on the platform this is how your trade is stored.
  struct Order {
    address sender;
    uint96 amount;
    uint24 prev;
    uint24 next;
    uint24 epoch;
    uint96 balance;
  }

  //1.2 Compact Order Struct for sending layer-zero messages. These order types are stored in memory and paid out on reciept.
  struct Payout {
    address sender;
    uint96 amount;
    uint24 index;
    bool maker;
   }

  //1.3 Payload is the data struct. used for transmitting messages cross-chain
  struct Payload {
    address source;
    address destination; 
    uint16 lz_cid;

    uint96 taker_sum;
    uint96 maker_sum;

    Payout[] orders;

    uint96 default_quantity;
    uint24 epoch;
    uint fee;
  }

  //1.4 Keeps track of important variables on a pair by pair basis. 
  struct Pair {
    address             source;
    address             destination;
    uint16              lz_cid;

    Order[] taker_orders; //taker order on this spoke
    Order[]  maker_orders; //contra-takers (orders recived from the other spoke)
    
    Index               index;
    Sums                sums;

    uint24              epoch;
    bool              isAwaiting;
    uint24              mkr_count;
    uint8               decimal;
    uint                fee;                
  }

  //1.5 Struct to hold indcies for iterating through maker and taker orders
  struct Index {
    uint24 taker_head;
    uint24 taker_tail;

    uint24 maker_head;
    uint24 maker_tail;

    uint96 taker_capital;
    uint96 taker_amount;
    uint24 taker_sent;

    uint96 timestamp;
  }

  //1.6 Struct to hold sums both for this chain's spoke and "contra" sums from spoke's on other chains.
  struct Sums {
      uint96 taker_sum;
      uint96 maker_sum;
      
      uint96 maker_tracking;
      uint96 maker_default_quantity;

      uint96 contra_taker_sum;
      uint96 contra_maker_sum;
    }

  //1.7 Used to serve orders to front-end users and analytics. Includes the "Index" of the order within the array as well as it's position in the linked list. 
  struct OrderEndpoint {
    uint24 index;
    address sender;
    uint96 amount;
    uint24 prev;
    uint24 next;
    uint24 epoch;
    uint96 balance;
  }
  
  //1.8 Local Variables
  struct LocalVariables {
    uint96 taker_demand;
    uint96 maker_demand;
    uint24 i;
    uint24 j;
    uint24 i2;
    uint24 index;
  }

}
