open Core
open Async

open Figgie

type t = {
  initial_sell_price : Market.Price.t;
  fade : Market.Price.t;
  size : Market.Size.t;
}

let config_param =
  let open Command.Let_syntax in
  [%map_open
    let initial_sell_price =
      flag "-at" (optional_with_default 6 int)
        ~doc:"P sell price"
    and fade =
      flag "-fade" (optional_with_default 1 int)
        ~doc:"F increase price after a sale"
    and size =
      flag "-size" (optional_with_default 1 int)
        ~doc:"S sell at most S at a time"
    in
    { initial_sell_price = Market.Price.of_int initial_sell_price
    ; fade = Market.Price.of_int fade
    ; size = Market.Size.of_int size
    }
  ]

let command =
  Bot.make_command
    ~summary:"Offer all your cards at a fixed price"
    ~config_param
    ~username_stem:"sellbot"
    ~f:(fun t ~config ->
      let username = Bot.username t in
      let sell_prices =
        Card.Hand.init ~f:(fun _suit -> ref config.initial_sell_price)
      in
      let reset_sell_prices () =
        Card.Hand.iter sell_prices ~f:(fun r ->
          r := config.initial_sell_price)
      in
      let hand = ref (Card.Hand.create_all Market.Size.zero) in
      let sell ~suit ~size =
        let size = Market.Size.min size (Card.Hand.get !hand ~suit) in
        if Market.Size.(equal zero) size
        then Deferred.unit
        else begin
          hand := Card.Hand.modify !hand ~suit
            ~f:(fun c -> Market.Size.O.(c - size));
          Rpc.Rpc.dispatch_exn Protocol.Order.rpc (Bot.conn t)
            { owner = username
            ; id = Bot.new_order_id t
            ; symbol = suit
            ; dir = Sell
            ; price = !(Card.Hand.get sell_prices ~suit)
            ; size
            }
          >>= function
          | Error _ | Ok `Ack -> Deferred.unit
        end
      in
      let handle_filled ~suit ~size =
        let price_to_sell_at = Card.Hand.get sell_prices ~suit in
        price_to_sell_at :=
          Market.O.(Price.(!price_to_sell_at + (size *$ config.fade)));
        sell ~suit ~size
      in
      let handle_my_filled_order ~suit (exec : Market.Exec.t) =
        let size =
          List.sum (module Market.Size)
            (Market.Exec.fills exec)
            ~f:(fun order -> order.size)
        in
        handle_filled ~suit ~size
      in
      let handle_exec (exec : Market.Exec.t) =
        let suit = ref None in
        let size =
          List.sum (module Market.Size)
            (Market.Exec.fills exec)
            ~f:(fun order ->
                suit := Some order.symbol;
                if Username.equal order.owner username
                then order.size
                else Market.Size.zero
              )
        in
        begin match !suit with
        | None -> Deferred.unit
        | Some suit -> handle_filled ~suit ~size
        end
      in
      let%bind () = Bot.try_set_ready t in
      Pipe.iter (Bot.updates t) ~f:(function
        | Broadcast (Round_over _) ->
          Bot.try_set_ready t
        | Broadcast (Exec exec) ->
          let order = exec.order in
          if Username.equal order.owner username
          then handle_my_filled_order ~suit:order.symbol exec
          else handle_exec exec
        | Hand new_hand ->
          hand := new_hand;
          Log.Global.sexp ~level:`Debug
            [%sexp (new_hand : Market.Size.t Card.Hand.t)];
          (* The correctness of the below relies on sellbot never asking
             for a Hand update, only receiving them at the beginning of
             a new round. *)
          reset_sell_prices ();
          Deferred.List.iter ~how:`Parallel Card.Suit.all ~f:(fun suit ->
            let size =
              Market.Size.min
                config.size
                (Card.Hand.get new_hand ~suit)
            in
            sell ~suit ~size)
        | _ -> Deferred.unit))
