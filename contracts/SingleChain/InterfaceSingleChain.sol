// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.4.22 <0.9.0;

interface Single{
  //0.0 Settings
  struct Settings {
    uint epochspan;
    uint MARGIN_BPS;
    uint max_epochs;
    uint max_orders;
    uint gas;
    uint lambda;
  }
  
  //1.1 Taker Orders do not persist
  struct Order {
  address sender;
  uint96 amount;
  uint24 prev;
  uint24 next;
  uint24 epoch;
  uint96 balance; //balance
  }

  //1.3
  struct Pair {
    address             source;
    address             destination;

    Order[]   tkrs0; //taker order in slot 0
    Order[]   tkrs1;
    Order[]   mkrs0; 
    Order[]   mkrs1; //maker order in slot 1 (slot 0 has address < address for slot 1 and vice versa)

    uint24              epoch;
    Index               index;
    Sums                sums;
    Count               count;
    
    mapping(uint => uint24[]) mkr0_cancelations;
    mapping(uint24 => bool) tracking0_cancelations;

    mapping(uint => uint24[]) mkr1_cancelations;
    mapping(uint24 => bool) tracking1_cancelations;

    uint8 decimals0;
    uint8 decimals1;
    uint fee;
  }

  //1.5.a
  struct Index {
    uint24 tkr0_head;
    uint24 tkr1_head;
    uint24 mkr0_head;
    uint24 mkr1_head;

    uint24 tkr0_tail;
    uint24 tkr1_tail;
    uint24 mkr0_tail;
    uint24 mkr1_tail;

    uint96 timestamp;
  }

  //1.5.b
  struct Sums {
    uint96 tkr0_sum;
    uint96 tkr1_sum;

    uint96 mkr0_tracking;
    uint96 mkr1_tracking;

    uint96 mkr0_sum;
    uint96 mkr1_sum;

  }

  //1.5.c
  struct Count {

    uint24 tkr0;
    uint24 tkr1;
    uint24 mkr0;
    uint24 mkr1;

  }

  //1.6
  struct TakerEndpoint {
    uint24 index;
    address sender;
    uint96 amount;
    uint24 next;
    uint24 epoch;
  }

  //1.7
  struct MakerEndpoint {
    uint24 index;
    address sender;
    uint96 amount;
    uint24 prev;
    uint24 next;
    uint96 balance;
    uint24 epoch;
  }




}
