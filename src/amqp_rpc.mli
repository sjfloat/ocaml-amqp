(** Rpc client and server patterns *)
open Async.Std

(** Rpc Client pattern *)
module Client :
  sig
    type t

    (** Initialize a client with the [id] for tracing *)
    val init : id:string -> Amqp_connection.t -> t Deferred.t

    (** Make an rpc call to the exchange using the routing key.
        @param ttl is the message timeout.

        To call directly to a named queue, use
        [call t Exchange.default ~routing_key:"name_of_the_queue" ]
    *)
    val call :
      t ->
      ttl:int ->
      routing_key:string ->
      Amqp_exchange.t ->
      Amqp_spec.Basic.Content.t * string ->
      Amqp_message.message option Async.Std.Deferred.t

    (** Release resources *)
    val close : t -> unit Deferred.t
  end

(** Rpc Server pattern *)
module Server :
  sig
    type t

    (** Recommended arguement to add when declaring the rpc server queue.
        This will set the dead letter exhange to the header exchange to help
        clients to be notified if a request has timed out *)
    val queue_argument : Amqp_types.header

    (** Start an rpc server procucing replies for requests comming in
        on the given queue.
        @param async If true muliple request can be handled concurrently.
                     If false message are handled synchroniously (default)

        It is recommended to create the queue with the header_exchange as dead letter exhange.
        This will allow messages to be routed back the the sender at timeout. E.g:
        [ Queue.declare ~arguments:[Rpc.queue_argument] "rpcservice" ]
    *)
    val start :
      ?async:bool ->
      [< `Failed | `Ok ] Amqp_channel.t ->
      Amqp_queue.t ->
      (Amqp_message.message -> Amqp_message.message Deferred.t) -> t Deferred.t

    (** Stop the server *)
    val stop : t -> unit Deferred.t
  end
