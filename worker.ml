(* server which computes best splits on behalf of clients *)

let port = 60_287
(* if we can't bind to this port, we concluded that another instance
   of this server is running on the same host; only one such instance
   may run on each host, so we refuse to start another on another
   port *)

let create () =
  LP_tcp.Server.create port

(* serialize and send outgoing message *)
let send t peer m =
  let s = Proto_b.string_of_from_worker m in
  LP_tcp.Server.send t peer (Some s)

(* deserialize (parse) incoming message *)
let recv srv =
  lwt peer, event = LP_tcp.Server.recv srv in
  let event =
    match event with
      | `Connect -> `Connect
      | `Disconnect -> `Disconnect
      | `Message s -> `Message (Proto_b.to_worker_of_string s)
  in
  Lwt.return (peer, event)

let is_sleeping thr =
  match Lwt.state thr with
    | Lwt.Sleep
    | Lwt.Return _ -> false
    | Lwt.Fail _ -> assert false

let nchoose_fold f threads x0 =
  lwt results = Lwt.nchoose threads in
  let sleeping_threads = List.filter is_sleeping threads in
  let rec loop x threads_accu = function
    | [] -> Lwt.return (x, List.flatten threads_accu)
    | h :: t ->
      lwt x, threads = f x h in
      loop x (threads :: threads_accu) t
  in
  loop x0 [sleeping_threads] results

module Working = struct
  type t = {
    task_id : Proto_t.task_id;
    y_feature_id : Proto_t.feature_id;
    fold_feature_id : Proto_t.feature_id option;
    dog : Dog_io.RA.t;
    best_split : D_best_split.t;
    feature_map : Feat_map.t;
    sampler : Sampler.t;
    fold_set : bool array;
  }
end

module Copying = struct
  type t = {
    task_id : Proto_t.task_id;
    feature_map : Feat_map.t
  }
end

type state = [
  | `Available
  (* worker is free to do work for any master that cares for its services *)

  | `Copying of Copying.t
  (* worker is the destination of a set of features, which are
     necessary to set up a task *)

  | `Working of Working.t
  (* worker has successfully setup the task; that means
     it has at least the target (y) feature, and the fold
     feature (if one is required) *)
]

type t = {
  srv : LP_tcp.Server.t;
  worker_id : string;
  user : string;
  state : state;
}


let rec service t threads =
  lwt t, threads = nchoose_fold react threads t in
  service t threads

and react t = function
  | peer, `Connect -> Lwt.return (t, [recv t.srv])
  | peer, `Disconnect -> Lwt.return (t, [recv t.srv])
  | peer, `Message msg -> react_msg t peer msg

and react_msg t peer = function
  | `Id ->
    let ack_id = `AckId { Proto_b.worker_id = t.worker_id; user = t.user } in
    lwt () = send t.srv peer ack_id in
    Lwt.return (t, [recv t.srv])
  | `BestSplit task_id -> best_split t peer task_id
  | _ -> assert false

and best_split t peer task_id =
  lwt result =
    match t.state with
      | `Working working -> (
          let open Working in
          if task_id = working.task_id then
            let result =
              match working.best_split with
                | `Logistic (splitter, best_split) ->
                  best_split working.feature_map splitter

                | `Square (splitter, best_split) ->
                  best_split working.feature_map splitter
            in
            let split_opt =
              match result with
                | Some (_,_, split) -> Some split
                | None -> None
            in
            Lwt.return (`Ok split_opt)

          else
            Lwt.return (`Busy working.task_id)
        )
      | `Copying c -> Lwt.return (`Busy c.Copying.task_id)
      | `Available -> Lwt.return `Available
  in
  lwt () = send t.srv peer (`AckBestSplit result) in
  Lwt.return (t, [recv t.srv])



let worker detach : unit =
  (* igore SIGPIPE's *)
  Sys.set_signal Sys.sigpipe Sys.Signal_ignore;

  (* create the working directory [$HOME/.dawg] if one does not
     already exist *)
  let home = Unix.getenv "HOME" in
  let dot_dawg = Filename.concat home ".dawg" in
  Utils.mkdir_else_exit dot_dawg;

  (* read the existing worker id (stored in [$HOME/.dawg/worker-id])
     or create a random worker id, and write it to that path *)
  let worker_id =
    let worker_id_path = Filename.concat dot_dawg "worker-id" in
    if Sys.file_exists worker_id_path then
      Utils.bi_read_from_file Proto_b.read_worker_id worker_id_path
    else
      (* create the worker id *)
      let worker_id = "asdfasdfasdf" in
      Utils.bi_write_to_file Proto_b.write_worker_id worker_id_path worker_id;
      worker_id
  in

  let srv =
    try
      create ()
    with Unix.Unix_error( _, "bind", _) ->
      (* TODO: connect to the process, to get its id and user *)
      Printf.printf "another process already has port %d bound\n%!" port;
      exit 1
  in

  let threads = [recv srv]  in
  let t = {
    srv;
    worker_id;
    user = Unix.getlogin ();
    state = `Available

  } in
  Lwt_main.run (service t threads)

open Cmdliner

let commands =
  let worker_cmd =
    let doc = "start the EigenDog worker server" in
    let detach =
      let doc = "detach from the terminal" in
      Arg.(value & opt (some bool) (Some true) &
           info ["d";"detach"] ~docv:"BOOL" ~doc)
    in

    Term.( pure worker $ detach ), Term.info "worker" ~doc
  in
  [worker_cmd]