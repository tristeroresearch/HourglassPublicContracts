// SPDX-License-Identifier: UNLICENSED

pragma solidity >=0.4.22 <0.9.0;
import "./InterfaceSingleChain.sol";
import "./IERC20_.sol";
import "./ReentrancyGuard.sol";
import "../openzeppelin/contracts/access/Ownable.sol";

contract Spoke is Ownable, Single, ReentrancyGuard {
    
    Settings public settings;
    uint                      constant MAXBPS  = 1e4;

    mapping (address => mapping( address => Pair )) internal book;
    
    
    constructor () { 
        settings=Settings({
            epochspan: 240,
            MARGIN_BPS: 10,
            max_epochs: 5,
            max_orders: 20,
            gas: 1e6 gwei,
            lambda: 0
        });
    }


    //** PART 1 - Placing Orders **
    event OrderPlaced(address indexed sell_token, address indexed buy_token, address sender, uint amount, uint index, bool is_maker);
    event MakerDefaulted(address indexed sell_token, address indexed buy_token, address sender, uint amount, uint index);
    event MakerPulled(address indexed sell_token, address indexed buy_token,  address sender, uint amount, uint index);
    event OrderRefunded(address indexed sell_token, address indexed buy_token, address sender, uint amount, uint index);
    event Resolved(address indexed sell_token, address indexed buy_token, uint epoch);
    event OrderPaidOut(address indexed sell_token, address indexed buy_token, address receiver, uint amount, uint index, bool is_maker);
    
    function updateSettings(
        uint _epochspan,
        uint _MARGIN_BPS,
        uint _max_epochs,
        uint _max_orders,
        uint _gas,
        uint _lambda
    ) public onlyOwner {
        settings = Settings({
            epochspan: _epochspan,
            MARGIN_BPS: _MARGIN_BPS,
            max_epochs: _max_epochs,
            max_orders: _max_orders,
            gas: _gas,
            lambda: _lambda
        });
    }
    
    function set_fee(address sell_token, address buy_token, uint _fee) public onlyOwner {
      (address t0, address t1) = sell_token > buy_token ? (buy_token,sell_token) : (sell_token,buy_token);
      Pair storage selected_pair=book[t0][t1];
      selected_pair.fee=_fee;
    }

    //1.1 Add a a taker order
    function placeTaker(address sell_token, address buy_token, uint96 _quantity) public payable {
        require(sell_token != buy_token, "Assets can not be the same");
        require(msg.value >= estimate_gas(), "!gasCost");

        uint8 decimal = decimals(sell_token)-2;
        uint96 magnitude = uint96(10**decimal);
        uint96 cents=(_quantity/magnitude);

        require(transferFrom(sell_token, msg.sender, _quantity), "!transfer");
        require(_quantity >= magnitude, "!minOrder");
        
        (address t0, address t1) = sell_token > buy_token ? (buy_token,sell_token) : (sell_token,buy_token);
        Pair storage selected_pair=book[t0][t1];

        Order[] storage orders = sell_token == t0 ? selected_pair.tkrs0 : selected_pair.tkrs1; //access the book based on the pair
        uint24 taker_tail = sell_token == t0 ? selected_pair.index.tkr0_tail : selected_pair.index.tkr1_tail; //access the book based on the pair


        Order memory newOrder = Order({
            amount: cents,
            sender: msg.sender,
            prev:taker_tail,
            next:uint24(orders.length)+1,
            epoch: book[t0][t1].epoch,
            balance:0
        });

        if (selected_pair.decimals0==0){
            selected_pair.decimals0=decimals(t0)-2;
        }
        if (selected_pair.decimals1==0) {
            selected_pair.decimals1=decimals(t1)-2;
        }

        //update the taker tail and the taker_sum
        if (sell_token == t0) {
            selected_pair.index.tkr0_tail = uint24(orders.length);
            selected_pair.count.tkr0 ++;
            require(selected_pair.count.tkr0 < settings.max_orders, "Can not place that many orders per epoch");

        } 
        else {
            selected_pair.index.tkr1_tail = uint24(orders.length);
            selected_pair.count.tkr1 ++;
            require(selected_pair.count.tkr1 < settings.max_orders, "Can not place that many orders per epoch");

        }

        emit OrderPlaced(sell_token,buy_token, msg.sender, cents, orders.length, false);
        orders.push(newOrder);

    }


    //1.2 Add a a maker order
    function placeMaker(address sell_token, address buy_token, uint96 _quantity) public payable {
        require(sell_token != buy_token, "Assets can not be the same");
        require(msg.value >= estimate_gas(), "!gasCost");

        uint8 decimal = decimals(sell_token)-2;
        uint96 magnitude = uint96(10**decimal);
        uint96 cents=(_quantity/magnitude);

        require(transferFrom(sell_token, msg.sender, (_quantity*settings.MARGIN_BPS) / MAXBPS), "!transfer");
        require(_quantity >= magnitude, "!minOrder");

        (address t0, address t1) = sell_token > buy_token ? (buy_token,sell_token) : (sell_token,buy_token);
        Pair storage selected_pair=book[t0][t1];

        Order[] storage orders = sell_token == t0 ? selected_pair.mkrs0 : selected_pair.mkrs1; //access the book based on the pair
        uint24 maker_tail = sell_token == t0 ? selected_pair.index.mkr0_tail : selected_pair.index.mkr1_tail; //access the book based on the pair
        
        Order memory newOrder = Order({
            amount: cents,
            sender: msg.sender,
            prev:maker_tail,
            next:uint24(orders.length)+1,
            epoch: book[t0][t1].epoch,
            balance:0
        });

        //update the maker tail and the maker sum and the count
        if (sell_token == t0) {
            selected_pair.index.mkr0_tail = uint24(orders.length);
            selected_pair.sums.mkr0_tracking += _quantity/magnitude;
            selected_pair.count.mkr0++;
            require(selected_pair.count.mkr0 < settings.max_orders, "Can not place that many orders per epoch");

        } 
        else {
            selected_pair.index.mkr1_tail = uint24(orders.length);
            selected_pair.sums.mkr1_tracking += _quantity/magnitude;
            selected_pair.count.mkr1++;
            require(selected_pair.count.mkr1 < settings.max_orders, "Can not place that many orders per epoch");

        }
        

        if (selected_pair.decimals0==0){
            selected_pair.decimals0=decimals(t0)-2;
        }
        if (selected_pair.decimals1==0) {
            selected_pair.decimals1=decimals(t1)-2;
        }

        emit OrderPlaced(sell_token,buy_token,msg.sender, cents, orders.length, true);
        orders.push(newOrder);

    }

    //1.3 -- deleteMaker
    function delete_maker(address sell_token, address buy_token, uint maker_index) internal {
        (address t0, address t1) = sell_token > buy_token ? (buy_token,sell_token) : (sell_token,buy_token);
        Pair storage selected_pair=book[t0][t1];

        bool slot=(sell_token > buy_token);

        uint24 start = sell_token == t0 ? selected_pair.index.mkr0_head : selected_pair.index.mkr1_head; 
        uint24 end = sell_token == t0 ? selected_pair.index.mkr0_tail : selected_pair.index.mkr1_tail;
        Order[] storage maker_orders = sell_token == t0 ? selected_pair.mkrs0 : selected_pair.mkrs1;

        if (!slot) {
            selected_pair.sums.mkr0_tracking-=maker_orders[maker_index].amount;
            selected_pair.count.mkr0-=1;

        }

        else {
            selected_pair.sums.mkr1_tracking-=maker_orders[maker_index].amount;
            selected_pair.count.mkr1-=1;

        }

        if (maker_index == start) {
            //The maker order is the first in the list
            if (maker_index != end) {
                //Doubley special case. The order is the only maker in the list.
                maker_orders[maker_orders[maker_index].next].prev = maker_orders[maker_index].next;
            }
            //update the head
            if (sell_token == t0) {
                selected_pair.index.mkr0_head = maker_orders[maker_index].next;
            } else {
                selected_pair.index.mkr1_head = maker_orders[maker_index].next;
            }
        }
        else if (maker_index == end) {
            maker_orders[maker_orders[maker_index].prev].next = maker_orders[maker_index].next;
            //update the tail
            if (sell_token == t0) {
                selected_pair.index.mkr0_tail = maker_orders[maker_index].prev;
            } else {
                selected_pair.index.mkr1_head = maker_orders[maker_index].prev;
            }
        }
        else {
            maker_orders[maker_orders[maker_index].prev].next = maker_orders[maker_index].next;
            maker_orders[maker_orders[maker_index].next].prev = maker_orders[maker_index].prev;
        }

        maker_orders[maker_index].amount = 0;
    }


  //Section 2 View Functions. 

  //2.1
  function getTakers(address sell_token, address buy_token) public view returns (TakerEndpoint[] memory active_takers) {
    (address t0, address t1) = sell_token > buy_token ? (buy_token,sell_token) : (sell_token,buy_token);
    Pair storage selected_pair=book[t0][t1];  
    uint24 start = sell_token == t0 ? selected_pair.index.tkr0_head : selected_pair.index.tkr1_head; //access the book based on the pair
    Order[] storage takers = sell_token == t0 ? selected_pair.tkrs0 : selected_pair.tkrs1; //access the book based on the pair
    uint8 decimal;

    if (sell_token==t0) {
        decimal=selected_pair.decimals0;
    }

    if (sell_token==t1) {
        decimal=selected_pair.decimals1;
    }


    active_takers = new TakerEndpoint[](takers.length);

    uint i=0;
    while (start != takers.length) {

        Order memory this_order=takers[start];

        TakerEndpoint memory newOrder = TakerEndpoint({
          index:start,
          sender: this_order.sender,
          amount: this_order.amount,
          next:this_order.next,
          epoch: this_order.epoch
        });


        active_takers[i]=newOrder;

        start = this_order.next;
        i++;

    }

    assembly { mstore(active_takers, i)}

  }

  //2.2
  function getMakers(address sell_token, address buy_token) public view returns (MakerEndpoint[] memory active_makers) {
    (address t0, address t1) = sell_token > buy_token ? (buy_token,sell_token) : (sell_token,buy_token);
    Pair storage selected_pair=book[t0][t1];  


    uint24 start = sell_token == t0 ? selected_pair.index.mkr0_head : selected_pair.index.mkr1_head; //access the book based on the pair
    uint24 end = sell_token == t0 ? selected_pair.index.mkr0_tail : selected_pair.index.mkr1_tail; //access the book based on the pair

    Order[] storage makers = sell_token == t0 ? selected_pair.mkrs0 : selected_pair.mkrs1; //access the book based on the pair

    active_makers = new MakerEndpoint[](makers.length);

    uint i=0;

    
    uint8 decimal;

    if (sell_token==t0) {
        decimal=selected_pair.decimals0;
    }

    if (sell_token==t1) {
        decimal=selected_pair.decimals1;
    }


    while(start<=end && start<(makers.length)) {
      Order memory this_order=makers[start];

      MakerEndpoint memory newOrder = MakerEndpoint({
        index:start,
        sender: this_order.sender,
        amount: this_order.amount,
        prev:this_order.prev,
        next:this_order.next,
        balance:this_order.balance,
        epoch: this_order.epoch
      });

      active_makers[i]=newOrder;

      start = this_order.next;
      i++;
    }

    assembly { mstore(active_makers, i)}

  }

  //2.4
  function getAllOrders(address sell_token, address buy_token) public view returns(Order[] memory takers, Order[] memory makers){
    (address t0, address t1) = sell_token > buy_token ? (buy_token,sell_token) : (sell_token,buy_token);
    Pair storage selected_pair=book[t0][t1];
    takers = sell_token == t0 ? selected_pair.tkrs0 : selected_pair.tkrs1; //access the book based on the pair
    makers = sell_token == t0 ? selected_pair.mkrs0 : selected_pair.mkrs1; //access the book based on the pair
  }


  //2.5
  function CanResolve(address sell_token, address buy_token) public view returns(bool) {
    (address t0, address t1) = sell_token > buy_token ? (buy_token,sell_token) : (sell_token,buy_token);
    Pair storage selected_pair=book[t0][t1];
    
    return( block.timestamp - uint(selected_pair.index.timestamp) >= settings.epochspan );
  }

  //2.6
  function getEpoch(address sell_token, address buy_token) public view returns(uint epoch_result){
    (address t0, address t1) = sell_token > buy_token ? (buy_token,sell_token) : (sell_token,buy_token);
    Pair storage selected_pair=book[t0][t1];
    epoch_result=selected_pair.epoch;
  }

  //2.7a
  function getMakerIndex(address sell_token, address buy_token) public view returns(uint24,uint24,uint24,uint24){
    (address t0, address t1) = sell_token > buy_token ? (buy_token,sell_token) : (sell_token,buy_token);
    Pair storage selected_pair=book[t0][t1];

    return (selected_pair.index.mkr0_head,selected_pair.index.mkr0_tail,selected_pair.index.mkr1_head,selected_pair.index.mkr1_tail);
  }
  
  //2.7b
  function getTakerIndex(address sell_token, address buy_token) public view returns(uint24,uint24,uint24,uint24){
    (address t0, address t1) = sell_token > buy_token ? (buy_token,sell_token) : (sell_token,buy_token);
    Pair storage selected_pair=book[t0][t1];

    return (selected_pair.index.tkr0_head,selected_pair.index.tkr0_tail,selected_pair.index.tkr1_head,selected_pair.index.tkr1_tail);
  }
  //2.8
  function getSums(address sell_token, address buy_token) public view returns(uint96,uint96,uint96,uint96){
    (address t0, address t1) = sell_token > buy_token ? (buy_token,sell_token) : (sell_token,buy_token);
    Pair storage selected_pair=book[t0][t1];

    return (selected_pair.sums.tkr0_sum,selected_pair.sums.mkr0_sum,selected_pair.sums.tkr1_sum,selected_pair.sums.mkr1_sum);
  }

  //2.9
  function getFee(address sell_token, address buy_token) public view returns(uint fee)  {
    bool slot = (sell_token > buy_token);
    (address t0, address t1) = slot ? (buy_token,sell_token) : (sell_token,buy_token);
    Pair storage selected_pair=book[t0][t1];      
    return selected_pair.fee;
    }

  //SECTION 3: HELPER FUNCTIONS 

  //3,0 Get taker sum 
  function get_taker_sum(address sell_token, address buy_token) internal returns (uint96 taker0_sum, uint96 taker1_sum){
    bool slot = (sell_token > buy_token);
    (address t0, address t1) = slot ? (buy_token,sell_token) : (sell_token,buy_token);
    Pair storage selected_pair=book[t0][t1];

    uint24 current_epoch=selected_pair.epoch;
    uint24 canceled_index;
    bool was_canceled;
    //Taker 0 sum
    uint24 current_index=selected_pair.index.tkr0_head;
    Order[] storage orders=selected_pair.tkrs0;

    while (current_index < orders.length) {
        Order memory temp_order = orders[current_index];
        if (temp_order.epoch+settings.max_epochs < current_epoch) {
            //If this if condition hits...the order is too old. We will refund it.
            transfer(t0, temp_order.sender, temp_order.amount*10**(selected_pair.decimals0));
            emit OrderRefunded(t0, t1, temp_order.sender, temp_order.amount, current_index);

            //advance the current index
            current_index=temp_order.next;
            canceled_index=current_index;
            was_canceled=true;
        }
        else{
            taker0_sum += temp_order.amount;
            current_index= temp_order.next;
        }


    }

    if (was_canceled) {
        selected_pair.index.tkr0_head=canceled_index;
    }

    //Taker 1 sum
    current_index=selected_pair.index.tkr1_head;
    orders=selected_pair.tkrs1;
    canceled_index=0;
    was_canceled=false;

    while (current_index < orders.length) {
        Order memory temp_order = orders[current_index];

        if (temp_order.epoch+settings.max_epochs < current_epoch) {
            //If this if condition hits...the order is too old. We will refund it.
            transfer(t1, temp_order.sender, temp_order.amount*10**(selected_pair.decimals1));
            emit OrderRefunded(t1, t0, temp_order.sender, temp_order.amount, current_index);

            //advance the current index
            current_index=temp_order.next;
            canceled_index=current_index;
            was_canceled=true;

        }
        else{
            taker1_sum += temp_order.amount;
            current_index= temp_order.next;

        }

    }

    if (was_canceled) {
        selected_pair.index.tkr1_head=canceled_index;
    }


  }

  //3.1 Get demands
  function get_demands(uint96 tkr0_sum, uint96 mkr0_sum, uint96 tkr1_sum, uint96 mkr1_sum) public pure returns (uint96 tkr0_demand, uint96 mkr0_demand, uint96 tkr1_demand, uint96 mkr1_demand){
        //Case 1 - When there is more demand in the 0 slot. (Takers_1 are matched with Makers_0).
        if (tkr0_sum > tkr1_sum){
            tkr0_sum -= tkr1_sum; //remaning taker demand 

            tkr0_demand = mkr1_sum > tkr0_sum 
            ? tkr1_sum + tkr0_sum
            : tkr1_sum + mkr1_sum;

            tkr1_demand=tkr1_sum;

            mkr0_demand=0;
            
            mkr1_demand = mkr1_sum > tkr0_sum 
            ? tkr0_sum
            : mkr1_sum;

        }
        
        //Case 2 - When there is more demand in the 1 slot. (Takers_0 are matched with Makers_!) 
        else {
            tkr1_sum -= tkr0_sum; //remaning taker demand 

            tkr0_demand = tkr0_sum;

            tkr1_demand= mkr0_sum > tkr1_sum 
            ? tkr0_sum+tkr1_sum
            : tkr0_sum+mkr0_sum;

            mkr0_demand= mkr0_sum > tkr1_sum 
            ? tkr1_sum
            : mkr0_sum;

            mkr1_demand = 0;
        }
  }
  
  //3.2 payout taker orders
  function payout_takers(uint96 tkr0_demand, uint96 tkr1_demand, address sell_token, address buy_token) internal returns (uint24 tkr0_count, uint24 tkr1_count) {

    (address t0, address t1) = (sell_token > buy_token) ? (buy_token,sell_token) : (sell_token,buy_token);
    Pair storage selected_pair=book[t0][t1];

    //variables
    uint24 i;
    Order[] storage orders;
    Order storage this_order;


    //payout takers 0
    i=selected_pair.index.tkr0_head;
    orders=selected_pair.tkrs0;

    if (orders.length==i) {
        tkr0_count=0;
    }

    else {
        this_order=orders[i];

        while (tkr0_demand>=this_order.amount){
            transfer(t1,this_order.sender,apply_fee(this_order.amount, selected_pair.decimals1, selected_pair.fee));
            emit OrderPaidOut(t1, t0, this_order.sender, this_order.amount, i, false);

            tkr0_demand-=this_order.amount;
            i=this_order.next;
            if (i!= orders.length) {
                this_order=orders[i];
            }
            tkr0_count++;
        }

        if (tkr0_demand>0) {
            transfer(t1,this_order.sender,apply_fee(tkr0_demand, selected_pair.decimals1, selected_pair.fee));
            emit OrderPaidOut(t1, t0, this_order.sender, tkr0_demand, i, false);

            this_order.amount-=tkr0_demand;
            tkr0_demand=0;
        }

        selected_pair.index.tkr0_head=i;

    }





    //payout takers 1
    i=selected_pair.index.tkr1_head;
    orders=selected_pair.tkrs1;

    if (orders.length==i) {
        tkr1_count=0;
    }
    else {    
        this_order=orders[i];

        while (tkr1_demand>=this_order.amount){
            transfer(t0,this_order.sender,apply_fee(this_order.amount, selected_pair.decimals0, selected_pair.fee));
            emit OrderPaidOut(t0, t1, this_order.sender, this_order.amount, i, false);

            tkr1_demand-=this_order.amount;
            i=this_order.next;
            if (i!= orders.length) {
                this_order=orders[i];
            }            
            tkr1_count++;

        }

        if (tkr1_demand>0) {
            transfer(t0,this_order.sender,apply_fee(tkr1_demand, selected_pair.decimals0, selected_pair.fee));
            emit OrderPaidOut(t0, t1, this_order.sender, tkr1_demand, i, false);

            this_order.amount-=tkr1_demand;
            tkr1_demand=0;
        }

        selected_pair.index.tkr1_head=i;
    }


    return (tkr0_count, tkr1_count);
  }

  



  //3.3 payout makers orders
  function payout_makers(uint96 maker_demand, address sell_token, address buy_token, uint8 sell_decimals, uint8 buy_decimals) internal returns(uint96 quantity_default) {
    Pair storage selected_pair;
    if (sell_token < buy_token) {
        selected_pair=book[sell_token][buy_token];
    }
    else{
        selected_pair=book[buy_token][sell_token];
    }

    uint24 i;
    Order[] storage orders;


    uint96 order_amount;
    address order_sender;
    uint24 order_next;


    if (!(sell_token > buy_token)) {
        i=selected_pair.index.mkr0_head;
        orders=selected_pair.mkrs0;
    }

    else {
        i=selected_pair.index.mkr1_head;
        orders=selected_pair.mkrs1;
    }

    if (orders.length==i) {
        quantity_default=0;
        return 0;
    }


    //Payout orders
    while (maker_demand>0) {

      //load order
      order_amount = orders[i].amount < maker_demand ? orders[i].amount : maker_demand;
      order_sender=orders[i].sender;
      order_next=orders[i].next;

      //Pull the maker order
      bool status=transferFrom(sell_token, order_sender, apply_fee(order_amount,sell_decimals, selected_pair.fee));

      //THE MAKER DID FUND
      if (status) { // maker funds
        emit MakerPulled(sell_token, buy_token, order_sender, order_amount, i);

        transfer(buy_token,order_sender, order_amount*(10**buy_decimals));
        emit OrderPaidOut(buy_token, sell_token, order_sender, order_amount, i, true);


        //Add it to cummulative balance
        orders[i].balance += order_amount;
        
      }

      else {
        emit MakerDefaulted(sell_token, buy_token, order_sender, order_amount,i);

        transfer(sell_token, owner(), (orders[i].amount*(10**sell_decimals)*settings.MARGIN_BPS) / MAXBPS);

        quantity_default += order_amount;

        delete_maker(sell_token, buy_token, i);

        orders[i].amount=0;

      }

      maker_demand -= order_amount;
      i = order_next;
      
    }


  }

  //3.4 Roll takers
  function roll_taker_orders(uint96 quant_default, address sell_token, address buy_token) internal {
    bool slot = (sell_token > buy_token);

    (address t0, address t1) = slot ? (buy_token,sell_token) : (sell_token,buy_token);
    Pair storage selected_pair=book[t0][t1];

    

    uint24 i;
    uint24 i2;

    Order[] storage orders;

    bool isSplit;
    uint24 tail;
    uint24 last_index;

    if (!slot) {
        i=selected_pair.index.tkr0_head;
        orders=selected_pair.tkrs0;
        tail=selected_pair.index.tkr0_tail;
    }

    else {
        i=selected_pair.index.tkr1_head;
        orders=selected_pair.tkrs1;
        tail=selected_pair.index.tkr1_tail;
    }
    i2=i;
    


    while (i!=orders.length && quant_default >= orders[i].amount) {

        orders[i].epoch=selected_pair.epoch;
        quant_default-=orders[i].amount;
        last_index=i;
        i=orders[i].next;
    }

    if (quant_default>0) {
        isSplit=true;
        orders[i].amount-=quant_default;

    }

    //Roll the orders
    if (i2!=i && orders[last_index].next != orders.length) {


        //set the head 
        if (!slot) {
            selected_pair.index.tkr0_head=i;
        }
        else {
            selected_pair.index.tkr1_head=i;
        }

        orders[tail].next=i2;
        orders[i2].prev=tail;
        orders[last_index].next = uint24(orders.length);

        //set the tail 
        if (!slot) {
            selected_pair.index.tkr0_tail=last_index;
        }
        else {
            selected_pair.index.tkr1_tail=last_index;
        }

    }

    //If an extra split order is required, it does so below
    if (isSplit) {
      Order memory newOrder = Order({
          sender:  orders[i].sender,
          amount: quant_default,
          prev: tail,
          next:uint24(orders.length)+1,
          epoch: selected_pair.epoch,
          balance: 0
          });

        //update the tail and push the order
        if (!slot) {
            selected_pair.index.tkr0_tail=uint24(orders.length);
            selected_pair.tkrs0.push(newOrder);
            selected_pair.count.tkr0++;
        }
        else {
            selected_pair.index.tkr1_tail=uint24(orders.length);
            selected_pair.tkrs1.push(newOrder);
            selected_pair.count.tkr1++;
        }

    }
  }
  
  //SECTION 4

  function send(address sell_token, address buy_token) public nonReentrant {
    uint96 qd;
    uint24 tkr0_count;
    uint24 tkr1_count;
     
    //load pair
    (address t0, address t1) = (sell_token > buy_token) ? (buy_token,sell_token) : (sell_token,buy_token);
    Pair storage selected_pair=book[t0][t1];

    //require
    require (block.timestamp - uint(selected_pair.index.timestamp) > settings.epochspan, "you must wait more time before calling this method");

    //get demands
    (uint96 tkr0_demand, uint96 mkr0_demand, uint96 tkr1_demand, uint96 mkr1_demand) = get_demands(selected_pair.sums.tkr0_sum, selected_pair.sums.mkr0_sum, selected_pair.sums.tkr1_sum, selected_pair.sums.mkr1_sum);

    require (mkr0_demand==0 || mkr1_demand==0, "Can not both be non-zero");


    //Condition 1:  The maker 0 slot is pulled. In case of maker default, taker 1 is modified and/or rolled. 
    if (mkr0_demand!=0) {
        //payout makers
        qd=payout_makers(mkr0_demand, t0, t1, selected_pair.decimals0, selected_pair.decimals1);
        
        //payout takers
        tkr1_demand -= qd;
        (tkr0_count, tkr1_count)=payout_takers(tkr0_demand, tkr1_demand, t0, t1);
        
        //roll orders
        if (qd>0){
            roll_taker_orders(qd, t1, t0);
        }
    }

    //Condition 2:  The maker 1 slot is pulled
    else if (mkr1_demand!=0) {
        //payout makers
        qd=payout_makers(mkr1_demand, t1, t0, selected_pair.decimals1, selected_pair.decimals0);

        //payout takers
        tkr0_demand -= qd;
        (tkr0_count, tkr1_count)=payout_takers(tkr0_demand, tkr1_demand, t1, t0);
        
        
        

        //roll orders
        if (qd>0){
            roll_taker_orders(qd, t0, t1);
        }
    }

    //Condition 3: No maker orders
    else {
        payout_takers(tkr0_demand, tkr1_demand, t1, t0);
    }

    //get new taker sums
    (uint96 taker0_sum, uint96 taker1_sum) = get_taker_sum(sell_token,buy_token);

    //update the sums
    selected_pair.sums.tkr0_sum=taker0_sum;
    selected_pair.sums.tkr1_sum=taker1_sum;
    selected_pair.sums.mkr0_sum=selected_pair.sums.mkr0_tracking;
    selected_pair.sums.mkr1_sum=selected_pair.sums.mkr1_tracking;

    //update the count
    selected_pair.count.tkr0-=tkr0_count;
    selected_pair.count.tkr1-=tkr1_count;
    
    //emit resolved
    emit Resolved(t0,t1,selected_pair.epoch);

    //increment the epoch
    selected_pair.epoch++;

    //update the timestamp
    selected_pair.index.timestamp=uint96(block.timestamp);

  }

  function transferFrom (address tkn, address from, uint amt) internal returns (bool s)
    { (s,) = tkn.call(abi.encodeWithSelector(IERC20_.transferFrom.selector, from, address(this), amt)); }
  
  function transfer (address tkn, address to, uint amt) internal returns (bool s)
    { 
    (s,) = tkn.call(abi.encodeWithSelector(IERC20_.transfer.selector, to, amt));
    require(s, "!Smart Contract Transfer but no money");
    }

  function decimals (address tkn) public view returns(uint8) {
    IERC20_ token = IERC20_(tkn);
    return token.decimals();
    }

    function apply_fee(uint number, uint decimal, uint _fee) public pure returns (uint) {
        // Raise the number to the power of 10**decimals
        uint final_number=number*10**decimal;
        return ((final_number-_fee*(final_number/MAXBPS))/(10**decimal))*10**decimal;
    }
    function estimate_gas() public view returns(uint) {
        return (settings.lambda)/100*settings.gas;
    }
}
