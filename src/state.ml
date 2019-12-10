let ( <.> ) f g = fun x -> f (g x)

type ('a, 'err) t =
  | Read of { buffer : bytes
            ; off : int
            ; len : int
            ; k : int -> ('a, 'err) t }
  | Write of { buffer : string
             ; off : int
             ; len : int
             ; k : int -> ('a, 'err) t }
  | Return of 'a
  | Error of 'err

module Context = struct
  type t =
    { encoder : Encoder.encoder
    ; decoder : Decoder.decoder }
  type encoder = Encoder.encoder
  type decoder = Decoder.decoder
  
  let make () =
    { encoder= Encoder.encoder ()
    ; decoder= Decoder.decoder () }

  let encoder { encoder; _ } = encoder
  let decoder { decoder; _ } = decoder
end

module type S = sig
  type 'a send
  type 'a recv

  type error
  type encoder
  type decoder

  val encode : encoder -> 'a send -> 'a -> (unit, error) t
  val decode : decoder -> 'a recv -> ('a, error) t
end

module type C = sig
  type t
  type encoder
  type decoder

  val encoder : t -> encoder
  val decoder : t -> decoder
end

module Scheduler
    (Context : C)
    (Value : S with type encoder = Context.encoder and type decoder = Context.decoder)
= struct
  let rec go ~f m len = match m len with
    | Return v -> f v
    | Read { k; off; len; buffer; } ->
      Read { k= go ~f k; off; len; buffer; }
    | Write { k; off; len; buffer; } ->
      Write { k= go ~f k; off; len; buffer; }
    | Error _ as err -> err

  let bind
    : ('a, 'err) t -> f:('a -> ('b, 'err) t) -> ('b, 'err) t
    = fun m ~f -> match m with
    | Return v -> f v
    | Error _ as err -> err
    | Read { k; off; len; buffer; } ->
      Read { k= go ~f k; off; len; buffer; }
    | Write { k; off; len; buffer; } ->
      Write { k= go ~f k; off; len; buffer; }

  let ( let* ) m f = bind m ~f
  let ( >>= ) m f = bind m ~f

  let encode
    : type a. Context.t -> a Value.send -> a -> (Context.t -> ('b, Value.error) t) -> ('b, Value.error) t
    = fun ctx w v k ->
      let rec go = function
        | Return () -> k ctx
        | Write { k; buffer; off; len; } ->
          Write { k= go <.> k; buffer; off; len; }
        | Read { k; buffer; off; len; } ->
          Read { k= go <.> k; buffer; off; len; }
        | Error _ as err -> err in
      go (Value.encode (Context.encoder ctx) w v)

  let send : type a. Context.t -> a Value.send -> a -> (unit, Value.error) t
    = fun ctx w x -> encode ctx w x (fun _ctx -> Return ())

  let decode
    : type a. Context.t -> a Value.recv -> (Context.t -> a -> ('b, Value.error) t) -> ('b, Value.error) t
    = fun ctx w k ->
      let rec go : (a, 'err) t -> ('b, Value.error) t = function
        | Read { k; buffer; off; len; } ->
          Read { k= go <.> k; buffer; off; len; }
        | Write { k; buffer; off; len; } ->
          Write { k= go <.> k; buffer; off; len; }
        | Return v -> k ctx v
        | Error _ as err -> err in
      go (Value.decode (Context.decoder ctx) w)

  let recv : type a. Context.t -> a Value.recv -> (a, Value.error) t
    = fun ctx w -> decode ctx w (fun _ctx v -> Return v)

  let return v = Return v
  let fail error = Error error
  let error_msgf fmt = Fmt.kstrf (fun err -> Error (`Msg err)) fmt
end
