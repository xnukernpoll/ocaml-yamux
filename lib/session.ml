open Lwt.Infix
open Util



let src = Logs.Src.create "muxer" ~doc:"Yamux Multiplexer"
module Log = (val Logs.src_log src : Logs.LOG)





module ID = struct
  let is_server id =
    (id mod 2) = 0

  let is_client id =
    is_server id <> true

  let is_session id =
    id = 0l
end 



module Muxer (F: Mirage_flow_lwt.S) = struct

  open Stream
  open Packet
  open Header



  module Flow = Flow_ext(F)
 

  
  type t = {

    lock: Lwt_mutex.t;
    flow: Flow.flow; 
    streams: (int32, Stream.Entry.t) Hashtbl.t;
  
    next_id: int32;
    config: Config.t;
    
    pending_streams: (int32, Stream.Entry.t Lwt.u) Hashtbl.t;
    pending_pings: (int32, unit Lwt.u) Hashtbl.t;
  }

  


  let create conn config =
    let open Config in
    

    let flow = Flow.create conn in  
    let streams = Hashtbl.create config.max_streams in

    let pending_pings = Hashtbl.create 1000 in
    let pending_streams = Hashtbl.create config.max_streams in
    let lock = Lwt_mutex.create () in
    let next_id = 1l in 


    {
      streams; pending_streams;
      pending_pings; lock; next_id;
      flow; config 
    }

  
    
    
  let send_packet t frame = 
    let buf = Packet.encode frame in
    Lwt_mutex.lock t.lock >>= fun () ->
    Flow.write t.flow buf >|= fun res ->

    Lwt_mutex.unlock t.lock;
    res




  let on_ping t frame =
    let open Header in 
    let header  = Packet.header frame in

    if header.flag = ACK then
      let nonce = header.len in 
      let pings = t.pending_pings in
      PromiseMap.wake_up pings nonce ();
      Ok () |> Lwt.return 


    else
      let packet = {frame with header = Header.ack header} in
      send_packet t packet




  let valid_remote t sid =
    let id = Int32.to_int sid in 
    if (Config.is_server t.config) then
      ID.is_client id
    else
      ID.is_server id

  
  

  let on_window_update t frame =
    let open Entry in
    let open Option.Infix in

    let flag = Packet.flag frame in
    let id = Packet.id frame in


    
    
    match flag with

    | RST ->
      let _ =
        Hashtbl.find_opt t.streams id >>> fun entry ->
        Entry.update_state entry Closed;
        PromiseMap.delete t.streams id;
      in

      Lwt.return ( Ok () )

  
    | FIN ->

      let _ =
        Hashtbl.find_opt t.streams id >>> fun entry ->
        Entry.update_state entry RecvClosed;
      in
     
      Lwt.return ( Ok () )

  
    | SYN when Hashtbl.mem t.streams id ->

      let _ =
        Log.debug (fun fmt ->
            fmt "Protocol Error, stream %ld already exists" id
        )
      in


      send_packet t (Packet.GoAway.protocol_error)

    | SYN when (Hashtbl.length t.streams >= (Config.max_streams t.config) ) ->

      let max = Config.max_streams t.config in
      let _ = Log.debug ( fun fmt ->
          fmt "Protocol Error: maximum number of streams %d reached" max
      ) in
      send_packet t (Packet.GoAway.protocol_error)
 
    | _ ->
      let window = Config.recv_window t.config in
      let credit = Packet.WindowUpdate.credit frame in
      let s = Entry.make window credit in

      Hashtbl.add t.streams id s;
      Ok () |> Lwt.return 

      
   

      
   
    
  
  
      
  
end 



