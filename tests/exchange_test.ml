open Async.Std
open Amqp

let log fmt = printf (fmt ^^ "\n%!")

let test =
  Connection.connect ~id:"fugmann" "localhost" >>= fun connection ->
  log "Connection started";
  Connection.open_channel ~id:"test" Channel.no_confirm connection >>= fun channel ->
  log "Channel opened";
  Exchange.declare channel ~auto_delete:true Exchange.Direct "test" >>= fun exchange1 ->
  log "Exchange declared";
  Exchange.declare channel ~auto_delete:true Exchange.Direct "test" >>= fun exchange2 ->
  log "Exchange declared";
  Exchange.bind channel exchange1 exchange2 ~routing_key:"test.exchange" >>= fun () ->
  log "Exchange Bind";
  Exchange.unbind channel exchange1 exchange2 ~routing_key:"test.exchange" >>= fun () ->
  log "Exchange Unbind";
  Exchange.delete channel exchange1 >>= fun () ->
  log "Exchange deleted";
  Exchange.delete channel exchange2 >>= fun () ->
  log "Exchange deleted";
  Channel.close channel >>| fun () ->
  log "Channel closed";
  Shutdown.shutdown 0

let _ =
  Scheduler.go ()
