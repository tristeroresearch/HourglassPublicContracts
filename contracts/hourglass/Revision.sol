// SPDX-License-Identifier: MIT
pragma solidity >=0.8.17;

// This line imports the NonblockingLzApp contract from LayerZero's solidity-examples Github repo.
import "../lzApp/NonblockingLzApp.sol";
import "../interfaces/IMultichain.sol";
import "../util/IERC20_.sol";
import "./ReentrancyGuard.sol";

// This contract is inheritting from the NonblockingLzApp contract.
contract Spoke is NonblockingLzApp, Multi, ReentrancyGuard {

  //Orderbook (chain_id,source_token,destination_token)
  mapping(uint => mapping (address => mapping( address => Pair ))) internal book;

  //PUBLIC Variables
  uint16                    public lzc;
  mapping (uint16 => address)      public spokes;
  address public dao_address;

  //Variables used inside the contract
  Settings public settings;
  uint                      constant MAXBPS  = 1e4;


  //Constructor
  constructor (address _lzEndpoint, uint16 _lzc) NonblockingLzApp(_lzEndpoint) { 
    lzc = _lzc;
    dao_address=msg.sender;

    settings=Settings({
        epochspan: 240,
        MARGIN_BPS: 10,
        max_epochs: 5,
        MINGAS: 1e7 gwei,
        max_orders: 20,
        gasForDestinationLzReceive: 700000,
        lambda: 30
    });
  }

  //events
  event OrderPlaced(address indexed sell_token, address indexed buy_token, uint lz_cid, address sender, uint amount, uint index, bool is_maker);
  event MakerDefaulted(address indexed sell_token, address indexed buy_token, uint lz_cid, address sender, uint amount, uint index);
  event MakerPulled(address indexed sell_token, address indexed buy_token,  uint lz_cid, address sender, uint amount, uint index);
  event OrderRefunded(address indexed sell_token, address indexed buy_token, uint lz_cid, address sender, uint amount, uint index);
  event Resolved(address indexed sell_token, address indexed buy_token, uint lz_cid, uint epoch);
  event OrderPaidOut(address indexed sell_token, address indexed buy_token, uint lz_cid, address receiver, uint amount, uint index, bool is_maker);

  // Function to update all variables
function updateSettings(
    uint _epochspan,
    uint _MARGIN_BPS,
    uint _max_epochs,
    uint _MINGAS,
    uint _max_orders,
    uint _gasForDestinationLzReceive,
    uint _lambda
) public onlyOwner {
    settings = Settings({
        epochspan: _epochspan,
        MARGIN_BPS: _MARGIN_BPS,
        max_epochs: _max_epochs,
        MINGAS: _MINGAS,
        max_orders: _max_orders,
        gasForDestinationLzReceive: _gasForDestinationLzReceive,
        lambda: _lambda
    });
}
  function placeTaker(address sell_token, address buy_token, uint lz_cid, uint96 _quantity) public payable nonReentrant {
    /*
    Public function for users to place Taker orders
    */

      uint8 decimal = decimals(sell_token)-2;
      uint96 magnitude = uint96(10**decimal);
      
      require(transferFrom(sell_token, msg.sender, _quantity), "!transfer");
      require(_quantity >= magnitude, "!minOrder");
      require(spokes[uint16(lz_cid)]!=address(0), "!VoidDestChain"); //Issue 3.5
      require(msg.value >= estimate_gas(uint16(lz_cid)), "!gasCost");

      Pair storage selected_pair=book[lz_cid][sell_token][buy_token];

      if (selected_pair.decimal==0) {
          selected_pair.decimal=decimal;
      }

      uint96 cents=(_quantity/magnitude);

      Order memory newOrder = Order({
          sender: msg.sender,
          amount: cents, //cents
          prev:selected_pair.index.taker_tail,
          next:uint24(selected_pair.taker_orders.length)+1,
          epoch: selected_pair.epoch,
          balance: 0
          });

      //update the tail
      selected_pair.index.taker_tail=uint24(selected_pair.taker_orders.length);
      
      //require taker orders to be resolved
      require((selected_pair.index.taker_tail-selected_pair.index.taker_head) < settings.max_orders, "!takerStack");

      //push the new order
      selected_pair.taker_orders.push(newOrder);
      emit OrderPlaced(sell_token,buy_token,lz_cid,msg.sender,(_quantity/magnitude),selected_pair.index.taker_tail, false);
  }

  //1.2 -- placeMaker
  function placeMaker(address sell_token, address buy_token, uint lz_cid, uint96 _quantity) public payable nonReentrant {
      uint8 decimal = decimals(sell_token)-2;
      uint96 magnitude = uint96(10**decimal);

      require(transferFrom(sell_token, msg.sender, (_quantity*settings.MARGIN_BPS) / MAXBPS), "!transfer");
      require(_quantity >= magnitude, "!minOrder"); //Issue 3.11
      require(spokes[uint16(lz_cid)]!=address(0), "!VoidDestChain"); //Issue 3.5      
      require(msg.value >= estimate_gas(uint16(lz_cid)), "!gasCost");

      Pair storage selected_pair=book[lz_cid][sell_token][buy_token];
      if (selected_pair.decimal==0) {
          selected_pair.decimal=decimal;
      }

      uint24 maker_tail=selected_pair.index.maker_tail;

      Order memory newOrder = Order({
          sender: msg.sender,
          amount: (_quantity/magnitude),
          prev:maker_tail,
          next:uint24(selected_pair.maker_orders.length)+1,
          epoch: selected_pair.epoch,
          balance: 0
        });

      selected_pair.index.maker_tail=uint24(selected_pair.maker_orders.length);
      
      //push the new order
      selected_pair.maker_orders.push(newOrder);

      //increment the maker count
      require(selected_pair.mkr_count < settings.max_orders, "!makerStack");

      selected_pair.mkr_count++;

      selected_pair.sums.maker_tracking+=(_quantity/magnitude);

      emit OrderPlaced(sell_token,buy_token,lz_cid,msg.sender,(_quantity/magnitude),selected_pair.index.maker_tail,true);
  }



  //1.3 -- deleteMaker
  function delink(address sell_token, address buy_token, uint lz_cid, uint order_index) internal {
    /*
    This function removes orders from the linked list (either takers or makers). It does so by delinking the order associated with the passed order_index.
    For example if there are three orders in the linked list with order_index 0,1,2. To delink the order with index 1, we set the next of 0 to 2 and the prev of 2 to 0.
    In this way, the order will never be reached when traversing through the linked list. 
    */
    uint24 start;
    uint24 end;
    Order[] storage orders;

    Pair storage selected_pair=book[lz_cid][sell_token][buy_token];

    //load maker orders
    orders=selected_pair.maker_orders;
    start=selected_pair.index.maker_head;
    end=selected_pair.index.maker_tail;
    selected_pair.sums.maker_tracking-=orders[order_index].amount;

    //decrement the maker count
    selected_pair.mkr_count-=1;


    //Possibility 1 The order is the very first order in the linked list
    if (order_index==start) {
        //advance the head
        selected_pair.index.maker_head=orders[order_index].next;

    }

    //Possibility 2 The order is the very last order in the linked list
    else if (order_index==end){

        orders[orders[order_index].prev].next=orders[order_index].next;
        //regress the tail
        selected_pair.index.maker_tail=orders[order_index].prev;

    }

    //Possibility 3 (The most common) The order is somewhere in the middle of the linked list. We simply delink it and do not need to adjust the head or tail of the list. 
    else {

        orders[orders[order_index].prev].next=orders[order_index].next;
        orders[orders[order_index].next].prev=orders[order_index].prev;

    }
    
    orders[order_index].amount=0;

  }

  function delete_maker(address sell_token, address buy_token, uint lz_cid, uint maker_index) internal {
      delink(sell_token, buy_token, lz_cid, maker_index);
  }


  //Section 2 View Functions.  

  //2.0
  function getOrders(address sell_token, address buy_token, uint lz_cid, bool isMaker) internal view returns (OrderEndpoint[] memory outputs) {
    Pair storage selected_pair=book[lz_cid][sell_token][buy_token];
    uint24 start;
    uint end;
    Order[] storage orders;

    if (isMaker) {
        start=selected_pair.index.maker_head;
        end=selected_pair.index.maker_tail;
        orders=selected_pair.maker_orders;

    }
    else {
        start=selected_pair.index.taker_head;
        orders=selected_pair.taker_orders;
        end=orders.length;
    }

    outputs = new OrderEndpoint[](orders.length);

    uint i=0;
    while(start<=end && start<(orders.length)) {
      Order memory this_order=orders[start];

      OrderEndpoint memory newOrder = OrderEndpoint({
        index:start,
        sender: this_order.sender,
        amount: this_order.amount,
        prev:this_order.prev,
        next:this_order.next,
        epoch: this_order.epoch,
        balance: this_order.balance
      });

      outputs[i]=newOrder;

      start = this_order.next;
      i++;
    }
    assembly { mstore(outputs, i)}

  }

  function getTakers(address sell_token, address buy_token, uint lz_cid) public view returns (OrderEndpoint[] memory active_takers) {
    active_takers=getOrders(sell_token, buy_token, lz_cid, false);
  }

  //2.2
  function getMakers(address sell_token, address buy_token, uint lz_cid) public view returns (OrderEndpoint[] memory active_makers) {
    active_makers=getOrders(sell_token, buy_token, lz_cid, true);
  }

  //2.5
  function canResolve(address sell_token, address buy_token, uint lz_cid) public view returns(bool) {
      Pair storage selected_pair=book[lz_cid][sell_token][buy_token];
      return (!selected_pair.isAwaiting && (block.timestamp-selected_pair.index.timestamp)>=settings.epochspan); //change epoch off by 1
  }
  
  //2.6
  function getEpoch(address sell_token, address buy_token, uint lz_cid) public view returns(uint epoch_result){
      Pair storage selected_pair=book[lz_cid][sell_token][buy_token];
      epoch_result=selected_pair.epoch;
  }
  //2.7
  function getFee(address sell_token, address buy_token, uint lz_cid) public view returns(uint fee)  {
      Pair storage selected_pair=book[lz_cid][sell_token][buy_token];
      return selected_pair.fee;
    }
    
  function send_taker_sum(address sell_token, address buy_token, uint lz_cid) internal returns(uint96 taker_sum) {

    /*
      The function iterates through the taker orders of the selected pair stored in the instance and sums them. 

      This function processes all orders up to epoch N which have yet to be paid. 
      
      If a taker order is "too" old we will cancel and refund it here.
      
      Returns:
          taker_sum (uint96): The net quantity of taker demanded on this spoke.
    */


    Pair storage selected_pair=book[lz_cid][sell_token][buy_token];
    Order[] storage taker_orders=selected_pair.taker_orders;
    uint24 current_epoch=selected_pair.epoch;

    uint24 current_index=selected_pair.index.taker_head;
    uint24 canceled_index=0;
    bool was_canceled=false;

    while (current_index < taker_orders.length) {
        Order memory temp_order = taker_orders[current_index];
        if (temp_order.epoch+settings.max_epochs < current_epoch) {
            //If this if condition hits...the order is too old. We will refund it.

            canceled_index=current_index;

            transfer(sell_token, temp_order.sender, temp_order.amount*(10**selected_pair.decimal));
            emit OrderRefunded(sell_token, buy_token, lz_cid, temp_order.sender, temp_order.amount, current_index);
            //advance the current index
            current_index=temp_order.next;
            was_canceled=true;

        }
        else{
            taker_sum += temp_order.amount;
            current_index=temp_order.next;
        }

    }

    //If we did cancel any taker orders get them out of the list by advancing the taker_head;
    if (was_canceled) {
        selected_pair.index.taker_head= taker_orders[canceled_index].next;

        selected_pair.index.taker_sent=canceled_index;
        selected_pair.index.taker_capital=taker_orders[canceled_index].amount;
        selected_pair.index.taker_amount=taker_orders[canceled_index].amount;
    }

    return taker_sum;
  }

  //3.2 
  function get_demands(uint96 taker_sum, uint96 maker_sum, uint96 contra_taker_sum, uint96 contra_maker_sum, uint96 quant_default) public pure returns (uint96 taker_demand, uint96 maker_demand){
        /*.
        A utility function to determine demands given thTis spokes's taker_sum and maker_sum with the contra_spoke's taker_sum and maker_sum.

        Returns:
            uint96 taker_demand: The amount requested by the taker
            uint96 maker_demand The amount requested by the maker

        */


        //Case 1 - When there is more demand on this spoke. (This spoke's takers takers match with contra-makers).
        if (taker_sum > contra_taker_sum){

          taker_sum -= contra_taker_sum;
          
          taker_demand = contra_maker_sum > taker_sum 
              ? contra_taker_sum + (taker_sum - quant_default)
              : contra_taker_sum + (contra_maker_sum - quant_default);

          maker_demand=0;
        }
        
        //Case 2 - When there is more demand on the contra spoke. (This spoke's makers match with contra-takers) 
        else {
          contra_taker_sum -= taker_sum;
          
          taker_demand=taker_sum;
          
          maker_demand = maker_sum > contra_taker_sum  
              ? contra_taker_sum 
              : maker_sum;
        }
  }

    //3.3

    function send_orders(address sell_token, address buy_token, uint lz_cid, uint96 quant_default) internal returns(Payout[] memory orders_to_send, uint96 quantity_default) {
        /*
        The function figures out what orders to send to the other spoke for payout.

        It compares the four sums. This spokes's taker_sum and maker_sum against the contra_spoke's taker_sum and maker_sum to answer the following.
        1) Which of our takers should be sent to be paid out?
        2) Which if any of our makers needs to fund? 
        
        ERC-20 funds are pulled from the makers. If a maker doesn't fund, the order is delinked from the list.

        The end results are arranged in a list.

        Returns:
            orders ([]]): A list of orders which will be sent to the opposite spoke, 
            uint96 quantity_default The total amount that makers should have funded for but did not;
        */

        //Initalize the orders to send
        orders_to_send = new Payout[](100);


        //Load the pair and taker orders
        Pair storage selected_pair=book[lz_cid][sell_token][buy_token];
        Order[] storage taker_orders=selected_pair.taker_orders;
        Order[] storage maker_orders=selected_pair.maker_orders;
        
        //Set the local variables these are items that we use to iterate through the linked lists
        LocalVariables memory quantities = LocalVariables(0, 0, 0, 0, 0, 0);
        quantities.i=selected_pair.index.taker_head;
        quantities.i2=selected_pair.index.maker_head;
        (quantities.taker_demand, quantities.maker_demand) = get_demands(selected_pair.sums.taker_sum, selected_pair.sums.maker_sum, selected_pair.sums.contra_taker_sum, selected_pair.sums.contra_maker_sum, quant_default);
        
        uint96 order_amount;
        address order_sender;
        uint24 order_next;

        //match Takers
        while (quantities.taker_demand>0) {
        //load order
        order_amount = taker_orders[quantities.i].amount < quantities.taker_demand ? taker_orders[quantities.i].amount : quantities.taker_demand;
        order_sender=taker_orders[quantities.i].sender;
        order_next=taker_orders[quantities.i].next;
        
        //append order
        Payout memory newPayout = Payout({
                sender: order_sender,
                amount: order_amount,
                index: quantities.i,
                maker: false
        });

        orders_to_send[quantities.index]=newPayout;
        quantities.index+=1;
        

        //End Conditions
        if (quantities.taker_demand==order_amount){
            selected_pair.index.taker_capital=order_amount;
            selected_pair.index.taker_sent=quantities.i;
            selected_pair.index.taker_amount=taker_orders[quantities.i].amount;


            if (order_amount==taker_orders[quantities.i].amount){
                quantities.i=order_next;
            }
            else {
                taker_orders[quantities.i].amount-=order_amount;
            }
            quantities.taker_demand=0;
        }
        
        else{
            quantities.i=order_next;
            quantities.taker_demand-=order_amount;
        }
        }

        //match Makers
        while (quantities.maker_demand>0) {
        //load order
        order_amount = maker_orders[quantities.i2].amount < quantities.maker_demand ? maker_orders[quantities.i2].amount : quantities.maker_demand;
        order_sender=maker_orders[quantities.i2].sender;
        order_next=maker_orders[quantities.i2].next;
        
        //Pull the maker order
        bool status=transferFrom(sell_token, order_sender, apply_fee(order_amount,selected_pair.decimal,selected_pair.fee));
        
        //THE MAKER DID FUND
        if (status) { // maker funds

            emit MakerPulled(sell_token, buy_token, lz_cid, order_sender, order_amount, quantities.i2);

            //append order
            Payout memory newPayout = Payout({
                sender: order_sender,
                amount: order_amount,
                index: quantities.i2,
                maker: true
            });
            
            orders_to_send[quantities.index]=newPayout;
            quantities.index++;

            //Add it to cummulative balance
            maker_orders[quantities.i2].balance += order_amount;
            
        }
        
        //THE MAKER DID NOT FUND
        else {
            emit MakerDefaulted(sell_token, buy_token, lz_cid, order_sender, order_amount, quantities.i2);
            order_sender=sell_token;
            transfer(order_sender, dao_address, (maker_orders[quantities.i2].amount*(10**selected_pair.decimal)*settings.MARGIN_BPS) / MAXBPS);


            quantity_default += order_amount;


            delete_maker(sell_token, buy_token, lz_cid, quantities.i2);

            //Transfer out the seized collateral
            maker_orders[quantities.i2].amount=0;


        }
        quantities.maker_demand -= order_amount;
        quantities.i2 = order_next;

        }

        selected_pair.index.taker_head=quantities.i; // SENT TAKER INDEX
        
        order_next=quantities.index;
        assembly { mstore(orders_to_send, order_next)}
    }



    
    //3.4

    function payout_orders(address sell_token, address buy_token, uint16 lz_cid, Payout[] memory orders, uint96 quant_default) internal {
        /*.
        A simple function to payout orders recived as part of the layer-zero payload. 
        */
        Pair storage selected_pair=book[lz_cid][sell_token][buy_token];

        uint order_len = orders.length;
        uint transferAmount;
        for (uint i = 1; i <= order_len; i++) {
            Payout memory order = orders[order_len - i];
            if (quant_default == 0) {
                transferAmount = order.maker ? order.amount * (10**selected_pair.decimal) : apply_fee(order.amount, selected_pair.decimal, selected_pair.fee);
                transfer(sell_token, order.sender, transferAmount);
                emit OrderPaidOut(sell_token, buy_token, lz_cid, order.sender, order.amount, order.index, order.maker);
            }

            else if (quant_default > order.amount) {
                    quant_default -= order.amount;
            } 
            
            else { // order.amount >= quant_default > 0
                transferAmount = order.maker ? (order.amount-quant_default) * (10**selected_pair.decimal) : apply_fee((order.amount-quant_default), selected_pair.decimal, selected_pair.fee);
                transfer(sell_token, order.sender, transferAmount);
                emit OrderPaidOut(sell_token, buy_token, lz_cid, order.sender, (order.amount-quant_default),order.index,order.maker);
                quant_default = 0;
            }
        }
    }



    //3.5
    function roll_taker_orders(address sell_token, address buy_token, uint lz_cid, uint96 quant_default) internal {
        /*
        
        This function is used when this spoke's taker orders were sent to be distributed at the opposite spoke, but some or all opposite spoke's makers failed to fund.

        Starting at the point where we left off after sending orders to the contra-spoke, the function moves backwards in the taker_order list. If needed, it splits the last order by placing a new taker order.

        */

        Pair storage selected_pair=book[lz_cid][sell_token][buy_token];
        Order[] storage taker_orders=selected_pair.taker_orders;
        uint24 current_epoch=selected_pair.epoch;

        uint24 i = selected_pair.index.taker_sent;
        uint24 i2=i;
        uint24 last_index=i;

        bool isSplit;

        Order storage order=taker_orders[i2];
        uint96 sent_capital=selected_pair.index.taker_capital;

        uint96 new_order_amount = 0;
        uint96 qd = quant_default;
        bool roll;



        if (qd>0) {
        if (sent_capital != selected_pair.index.taker_amount) {

            if (qd>sent_capital){
            i=taker_orders[i].prev;
            last_index=i;
            }

            new_order_amount = (qd < sent_capital) ? quant_default : sent_capital;
            qd -= new_order_amount;

            

            order=taker_orders[i];
            isSplit=true;
        }

        while (qd>order.amount){

            roll=true;
            order.epoch=current_epoch;
            qd-=order.amount;

            //go to the prior order
            i=taker_orders[i].prev;
            order=taker_orders[i];

        }

        if (qd>0){
            roll=true;
            order.amount=qd;
            order.epoch=current_epoch;
            qd=0;
        }
        }

        //If the orders need to be rolled, it does so below
        if (roll && taker_orders[last_index].next != taker_orders.length) {

            //set the head
            if (i2==last_index) {
            selected_pair.index.taker_head=taker_orders[i2].next;
            }
            else {
            selected_pair.index.taker_head=i2;
            }


            taker_orders[selected_pair.index.taker_tail].next=i;
            taker_orders[i].prev=selected_pair.index.taker_tail;

            taker_orders[last_index].next=uint24(taker_orders.length);

            //set the head and the tail
            selected_pair.index.taker_tail=last_index;
        }
        else {
        selected_pair.index.taker_head=i;
        }

    
        //If an extra split order is required, it does so below
        if (isSplit) {
        Order memory newOrder = Order({
            sender:  taker_orders[i2].sender,
            amount: new_order_amount,
            prev: selected_pair.index.taker_tail,
            next:uint24(selected_pair.taker_orders.length)+1,
            epoch: selected_pair.epoch,
            balance: 0
        });

        //update the tail
        selected_pair.index.taker_tail=uint24(selected_pair.taker_orders.length);

        //push the new order
        selected_pair.taker_orders.push(newOrder);
        }
    }
    
    

    function resolve_epoch(address sell_token, address buy_token, uint lz_cid) internal {

        /*
        Core matching logic. Orders are matched; the layer-zero payload is generated; and the state of the pair (sums, epoch, taker_order list) is updated in preperation of the next epoch.   
        */
        
        Pair storage selected_pair=book[lz_cid][sell_token][buy_token];
        uint24 current_epoch=selected_pair.epoch;

        //(N-1) Step 1
        (Payout[] memory orders_to_send, uint96 quantity_default) = send_orders(sell_token, buy_token, lz_cid, 0);
        
        //N Step 2
        uint96 taker_sum=send_taker_sum(sell_token, buy_token, lz_cid);
        uint96 maker_sum=selected_pair.sums.maker_tracking;

        // Create and store things in the payload
        Payload memory newPayload = Payload({
            source: sell_token,
            destination: buy_token,
            lz_cid: uint16(lzc),
            taker_sum: taker_sum,
            maker_sum: maker_sum,
            orders: orders_to_send,
            default_quantity: quantity_default,
            epoch: uint24(current_epoch), 
            fee: selected_pair.fee
        });

        //Update the epoch
        selected_pair.epoch+=1;

        //Update the sums
        selected_pair.sums.taker_sum=taker_sum;
        selected_pair.sums.maker_sum=maker_sum;

        //Update the reneged makers
        selected_pair.sums.maker_default_quantity=quantity_default;
        
        //uint16 version = 1;
        bytes memory adapterParams = abi.encodePacked(uint16(1), settings.gasForDestinationLzReceive);

        _lzSend(uint16(lz_cid), abi.encode(newPayload), payable(this), address(0x0), adapterParams, address(this).balance);

        emit Resolved(sell_token, buy_token, lz_cid, current_epoch);

    }



    //SECTION 5 -- LAYER-ZERO FUNCTIONS

    // This function is called to send the data string to the destination.
    // It's payable, so that we can use our native gas token to pay for gas fees.
    function send(address sell_token, address buy_token, uint lz_cid) public nonReentrant {
        /*
        Function callable my anyone who wants to resolve orders on a given pair. Control conditions are used to make sure that nessecary information from the contra-spoke are received. 
        */

        //load the pair
        Pair storage selected_pair=book[lz_cid][sell_token][buy_token];
        
        //Require conditions: 1) The pair on this spoke isn't waiting for an inbound layer zero message; 2) Enough time has passed since the last recieved message at this spoke. 
        require(!selected_pair.isAwaiting, "!await lz inbound msg");
        require (block.timestamp - uint(selected_pair.index.timestamp) >= settings.epochspan, "!await timestamp");
        require(address(this).balance >= 2*settings.MINGAS,  "!gasLimit send");

        //RESOLVE THE PAIR
        resolve_epoch(sell_token, buy_token, lz_cid);

        //lopck the contract
        selected_pair.isAwaiting=true;

    }

    // This function is called when data is received. It overrides the equivalent function in the parent contract.
    // This function is called when data is received. It overrides the equivalent function in the parent contract.
    function _nonblockingLzReceive(uint16, bytes memory, uint64, bytes memory _payload) internal override {
        /*
        Logic to recieve the payload.
        */

        // The LayerZero _payload (message) is decoded
        Payload memory payload  = abi.decode(_payload, (Payload));
        

        //get our variables
        uint16 lz_cid=payload.lz_cid;
        address sell_token=payload.destination;
        address buy_token=payload.source; 
        
        //load the pair
        Pair storage selected_pair=book[lz_cid][sell_token][buy_token];
        
        require(selected_pair.fee == payload.fee, "!fees");

        //set timestamp
        selected_pair.index.timestamp=uint96(block.timestamp);

        uint96 qd=payload.default_quantity;


        //**IF NEEDED: BOUNCE BACK A LZ MESSAGE
        if (!selected_pair.isAwaiting) {
            //RESOLVE THE PAIR
            require(address(this).balance >= settings.MINGAS, "!gasLimit bounce");
            resolve_epoch(sell_token, buy_token, lz_cid);
        }

        //Payout the orders
        payout_orders(sell_token, buy_token, lz_cid, payload.orders, selected_pair.sums.maker_default_quantity);
        
        if (qd>0) {
            roll_taker_orders(sell_token, buy_token, lz_cid, qd);
        }

        //Store new sums
        selected_pair.sums.contra_taker_sum=payload.taker_sum;
        selected_pair.sums.contra_maker_sum=payload.maker_sum;

        //unlock the contract
        selected_pair.isAwaiting=false;

    }
    //SECION 5: Utility Functions
    function setspoke(address _contraspoke, uint16 contra_cid) public onlyOwner {
        /* This function allows the contract owner to designate another contract address to trust.
        It can only be called by the owner due to the "onlyOwner" modifier.
        NOTE: In standard LayerZero contract's, this is done through SetTrustedRemote.
        */
        require(contra_cid!=lzc);
        trustedRemoteLookup[contra_cid] = abi.encodePacked(_contraspoke, address(this));
        spokes[contra_cid]=_contraspoke;
    }

    //TransferFunctions
    function transferFrom (address tkn, address from, uint amt) internal returns (bool s)
    { 
        (s,) = tkn.call(abi.encodeWithSelector(IERC20_.transferFrom.selector, from, address(this), amt)); 
    }

    function transfer (address tkn, address to, uint amt) internal returns (bool s)
    { 
    (s,) = tkn.call(abi.encodeWithSelector(IERC20_.transfer.selector, to, amt));
    require(s, "!internal transfer");
    }
    function setDaoAddress(address new_address) public onlyOwner {
        dao_address=new_address;
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
    

    function estimate_gas(uint16 lz_cid) public view returns(uint) {
        bytes memory _adapterParams = abi.encodePacked(uint16(1), settings.gasForDestinationLzReceive);
        bytes memory _testPayload = abi.encodePacked(lzc);
        (uint nativeFee, ) = lzEndpoint.estimateFees(lz_cid, address(this), _testPayload, false, _adapterParams);
        return (nativeFee*settings.lambda)/100;
    }

    function set_fee(address sell_token, address buy_token, uint lz_cid, uint _fee) public onlyOwner {
      Pair storage selected_pair=book[lz_cid][sell_token][buy_token];
      selected_pair.fee=_fee;
    }

    //Allows owner to claim gas (Used for testing)
    function cash () public onlyOwner { ( bool s, ) = msg.sender.call{value:address(this).balance}(""); }

    receive() external payable {}


}
