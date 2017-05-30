open Core
open Async

open Figgie

module Room_choice = struct
  type t =
    | First_available
    | Named of Lobby.Room.Id.t
    [@@deriving sexp]

  let param =
    let open Command.Param in
    flag "-room"
      (optional_with_default First_available
        (Arg_type.create (fun s -> Named (Lobby.Room.Id.of_string s))))
      ~doc:"ID room to join on startup, defaults to first available"
end

type t =
  { username : Username.t
  ; conn : Rpc.Connection.t
  ; updates : Protocol.Game_update.t Pipe.Reader.t
  ; new_order_id : unit -> Market.Order.Id.t
  }

let username t = t.username
let conn     t = t.conn
let updates  t = t.updates

let new_order_id t = t.new_order_id ()

let try_set_ready t =
  Rpc.Rpc.dispatch_exn Protocol.Is_ready.rpc (conn t) true
  |> Deferred.ignore

let join_any_room ~conn ~username =
  let%bind lobby_updates =
    match%map
      Rpc.Pipe_rpc.dispatch Protocol.Get_lobby_updates.rpc conn ()
      >>| ok_exn
    with
    | Error `Not_logged_in -> assert false
    | Ok (lobby_updates, _metadata) -> lobby_updates
  in
  let can_join room =
    not (Lobby.Room.is_full room) || Lobby.Room.has_player room ~username
  in
  let try_to_join id =
    match%map
      Rpc.Pipe_rpc.dispatch Protocol.Join_room.rpc conn id
      >>| ok_exn
    with
    | Ok (updates, _pipe_metadata) ->
      Pipe.close_read lobby_updates;
      `Finished (id, updates)
    | Error (`Already_in_a_room | `Not_logged_in) -> assert false
    | Error `No_such_room -> `Repeat ()
  in
  Deferred.repeat_until_finished ()
    (fun () ->
      let%bind update =
        match%map Pipe.read lobby_updates with
        | `Eof -> failwith "Server hung up on us"
        | `Ok update -> update
      in
      match update with
      | Lobby_snapshot lobby ->
        begin match
            List.find (Map.to_alist lobby.rooms) ~f:(fun (_id, room) ->
                can_join room)
          with
          | Some (id, room) ->
            Log.Global.sexp ~level:`Debug [%message
              "doesn't look full, joining"
                (id : Lobby.Room.Id.t) (room : Lobby.Room.t)
            ];
            try_to_join id
          | None ->
            Log.Global.sexp ~level:`Debug [%message
              "couldn't see an empty room, waiting"
            ];
            return (`Repeat ())
        end
      | Lobby_update (New_empty_room { room_id }) ->
        try_to_join room_id
      | Lobby_update (Lobby_update _ | Room_closed _ | Room_update _)
      | Chat _ -> return (`Repeat ())
    )

let start_playing ~conn ~username ~(room_choice : Room_choice.t) =
  let%bind () =
    match%map Rpc.Rpc.dispatch_exn Protocol.Login.rpc conn username with
    | Error (`Already_logged_in | `Invalid_username) -> assert false
    | Ok () -> ()
  in
  let%bind (_room_id, updates) =
    match room_choice with
    | First_available ->
      join_any_room ~conn ~username
    | Named id ->
      let%map (updates, _metadata) =
        Rpc.Pipe_rpc.dispatch_exn Protocol.Join_room.rpc conn id
      in
      (id, updates)
  in
  match%map
    Rpc.Rpc.dispatch_exn Protocol.Start_playing.rpc conn Sit_anywhere
  with
  | Error (`Not_logged_in | `Not_in_a_room) -> assert false
  | Error ((`Game_already_started | `Seat_occupied) as error) ->
    raise_s [%message
      "Joined a room that didn't want new players"
        (error : Protocol.Start_playing.error)
    ]
  | Error `You're_already_playing
  | Ok (_ : Lobby.Room.Seat.t) -> updates

let run ~server ~config ~username ~room_choice ~f =
  Rpc.Connection.with_client
    ~host:(Host_and_port.host server)
    ~port:(Host_and_port.port server)
    (fun conn ->
      let%bind updates = start_playing ~conn ~username ~room_choice in
      let new_order_id =
        let r = ref Market.Order.Id.zero in
        fun () ->
          let id = !r in
          r := Market.Order.Id.next id;
          id
      in
      f { username; conn; updates; new_order_id } ~config)
  >>| Or_error.of_exn_result

let make_command ~summary ~config_param ~username_stem ~f =
  let open Command.Let_syntax in
  Command.async_or_error'
    ~summary
    [%map_open
      let server =
        flag "-server" (required (Arg_type.create Host_and_port.of_string))
          ~doc:"HOST:PORT where to connect"
      and log_level =
        flag "-log-level" (optional_with_default `Info Log.Level.arg)
          ~doc:"L Debug, Info, or Error"
      and which =
        flag "-which" (optional int)
          ~doc:"N modulate username"
      and config = config_param
      and room_choice = Room_choice.param
      in
      fun () ->
        let username =
          username_stem ^ Option.value_map which ~default:"" ~f:Int.to_string
          |> Username.of_string
        in
        Log.Global.set_level log_level;
        Log.Global.sexp ~level:`Debug [%message
          "started"
            (username : Username.t)
        ];
        run ~server ~config ~username ~room_choice ~f
    ]
