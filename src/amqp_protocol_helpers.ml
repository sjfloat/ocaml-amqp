(** Internal *)
open Async.Std
open Amqp_protocol
open Amqp_io

type 'a post_handler = ('a -> unit) option

let bit_string v length =
  let rec loop acc v = function
    | 0 -> acc
    | n -> loop ((if v land 1 = 1 then "1" else "0") :: acc) (v lsr 1) (n-1)
  in
  String.concat "" (loop [] v length)

let update_property_flag v word flags =
  word ((v lsl (16 - flags)) land 0xffff)

let read_property_flag word flags =
  let word = (word land 0xffff) lsr (16 - flags) in

  (* Reverse the bits *)
  let rec rev v word = function
    | 0 -> v
    | n ->
      rev ((v lsl 1) lor (word land 0x1)) (word lsr 1) (n - 1)
  in
  rev 0 word flags

let rec list_create f = function
  | 0 -> []
  | n -> f () :: list_create f (n - 1)

let write_method (message_id, spec, _make, apply) =
  let write = Spec.write spec in
  fun channel msg ->
    apply (write (Output.create ())) msg
    |> Amqp_framing.write_method channel message_id

let read_method (message_id, spec, make, _apply) =
  let read = Spec.read spec in
  let read ~once (handler: 'a -> unit) channel : unit =
    let handler data =
      let req = read make data in
      handler req;
      if (once) then
        Amqp_framing.deregister_method_handler channel message_id;
    in
    Amqp_framing.register_method_handler channel message_id handler;
  in
  (message_id, read)

let write_method_content (message_id, spec, _make, apply) ((c_method, _), c_spec, _c_make, c_apply) =
  let write = Spec.write spec in
  let c_write = Content.write c_spec in
  let property_bits = Content.length c_spec in
  assert (property_bits <= 15);

  fun channel (meth, content, data) ->
    apply (write (Output.create ())) meth |> Amqp_framing.write_method channel message_id;
    let output = Output.create () in
    let property_flags = ref 0 in
    let property_word = Output.short_ref output in
    c_apply (c_write property_flags output) content;
    update_property_flag !property_flags property_word property_bits;

    (* Now send the data. *)
    Amqp_framing.write_content channel c_method output data

let read_method_content (message_id, spec, make, _apply) ((c_method, _), c_spec, c_make, _c_apply) =
  let read = Spec.read spec in
  let c_read = Content.read c_spec in
  let flags = Content.length c_spec in

  let read ~once (handler: 'a -> unit) channel : unit =
    let c_handler req (content, data) =
      let property_flags = read_property_flag (Input.short content) flags in
      let header = c_read c_make property_flags content in
      let message = (req, (header, data)) in
      handler message;
      Amqp_framing.deregister_content_handler channel c_method
    in
    let handler data =
      let req = read make data in
      if (once) then
        Amqp_framing.deregister_method_handler channel message_id;
      Amqp_framing.register_content_handler channel c_method (c_handler req);
    in
    Amqp_framing.register_method_handler channel message_id handler
  in
  (message_id, read)

let request0 req =
  fun channel msg ->
    req channel msg;
    return ()

let reply0 (_, read) ?(once=true) channel =
  let var = Ivar.create () in
  read ~once (Ivar.fill var) channel;
  Ivar.read var

let request1 write (_, read) channel msg =
  write channel msg;
  (* Actually have a pattern for this *)
  let var = Ivar.create () in
  read ~once:true (Ivar.fill var) channel;
  Ivar.read var

let reply1 (_, read) write ?(once=true) channel handler =
  let var = Ivar.create () in
  read ~once (Ivar.fill var) channel;
  Ivar.read var >>= handler >>= fun msg ->
  write channel msg;
  return ()

let request2 req (mid1, rep1) id1 (mid2, rep2) id2 channel message =
  let var = Ivar.create () in
  let handler id mid msg =
    Ivar.fill var (id msg);
    Amqp_framing.deregister_method_handler channel mid
  in
  req channel message;
  rep1 ~once:true (handler id1 mid2) channel;
  rep2 ~once:true (handler id2 mid1) channel;
  Ivar.read var
