open Lwt.Infix

module YB = Yojson.Basic

let api_prefix = "/api/v1"

let hash_paths = [
  `MD5, "md5" ;
  `SHA1, "sha1" ;
  `SHA224, "sha224" ;
  `SHA256, "sha256" ;
  `SHA384, "sha384" ;
  `SHA512, "sha512" ;
  ]

let jsend_success data =
  let l = match data with
    | `Null -> []
    | d -> ["data", d]
  in
  `Assoc (("status", `String "success") :: l)

let jsend_failure data =
  let l = match data with
    | `Null -> []
    | d -> ["data", d]
  in
  `Assoc (("status", `String "failure") :: l)

let jsend_error msg =
  `Assoc [
    ("status", `String "error");
    ("message", `String msg)
  ]

let jsend = function
  | Keyring.Ok json -> jsend_success json
  | Keyring.Error json -> jsend_failure json


module Main (C:V1_LWT.CONSOLE) (FS:V1_LWT.KV_RO) (H:Cohttp_lwt.Server) = struct

  (* Apply the [Webmachine.Make] functor to the Lwt_unix-based IO module
   * exported by cohttp. For added convenience, include the [Rd] module
   * as well so you don't have to go reaching into multiple modules to
   * access request-related information. *)
  module Wm = struct
    module Rd = Webmachine.Rd
    include Webmachine.Make(H.IO)
  end

  (** A resource for querying all the keys in the database via GET and creating
      a new key via POST. Check the [Location] header of a successful POST
      response for the URI of the key. *)
  class keys keyring = object(self)
    inherit [Cohttp_lwt_body.t] Wm.resource

    method private to_json rd =
      Keyring.get_all keyring
      >|= List.map (fun (id, key) -> `Assoc [
          ("location", `String (api_prefix ^ "/keys/" ^ id));
          ("key", Keyring.json_of_pub key)
        ])
      >>= fun json_l ->
        let json_s = jsend_success (`List json_l) |> YB.pretty_to_string in
        Wm.continue (`String json_s) rd

    method allowed_methods rd =
      Wm.continue [`GET; `HEAD; `POST] rd

    method content_types_provided rd =
      Wm.continue [
        "application/json", self#to_json
      ] rd

    method content_types_accepted rd =
      Wm.continue [] rd

    method process_post rd =
      try
        Cohttp_lwt_body.to_string rd.Wm.Rd.req_body >>= fun body ->
        let key = YB.from_string body in
        Keyring.add keyring key
        >>= function
          | Keyring.Ok new_id ->
            let rd' = Wm.Rd.redirect (api_prefix ^ "/keys/" ^ new_id) rd in
            let resp_body =
              `String (jsend_success `Null |> YB.pretty_to_string) in
            Wm.continue true { rd' with Wm.Rd.resp_body }
          | Keyring.Error json ->
            let resp_body =
              `String (jsend_failure json |> YB.pretty_to_string) in
            Wm.continue true { rd with Wm.Rd.resp_body }
      with
        | e ->
          let json = Printexc.to_string e |> jsend_error in
          let resp_body = `String (YB.pretty_to_string json) in
          Wm.continue false { rd with Wm.Rd.resp_body }
  end

  (** A resource for querying an individual key in the database by id via GET,
      modifying an key via PUT, and deleting an key via DELETE. *)
  class key keyring = object(self)
    inherit [Cohttp_lwt_body.t] Wm.resource

    method private of_json rd =
      begin try
        Cohttp_lwt_body.to_string rd.Wm.Rd.req_body
        >>= fun body ->
          let key = YB.from_string body in
          Keyring.put keyring (self#id rd) key
        >|= function
          | Keyring.Ok true -> jsend_success `Null
          | Keyring.Ok false -> assert false (* can't happen, because of resource_exists *)
          | Keyring.Error json -> jsend_failure json
      with
        | e -> Lwt.return (Printexc.to_string e |> jsend_error)
      end
      >>= fun jsend ->
      let resp_body =
        `String (YB.pretty_to_string jsend)
      in
      Wm.continue true { rd with Wm.Rd.resp_body }

    method private to_json rd =
      Keyring.get keyring (self#id rd)
      >>= function
        | None     -> assert false
        | Some key -> let json = Keyring.json_of_pub key in
          let json_s = jsend_success json |> YB.pretty_to_string in
          Wm.continue (`String json_s) rd

    method private to_pem rd =
      Keyring.get keyring (self#id rd)
      >>= function
        | None     -> assert false
        | Some key -> let pem = Keyring.pem_of_pub key in
          Wm.continue (`String pem) rd

    method allowed_methods rd =
      Wm.continue [`GET; `HEAD; `PUT; `DELETE] rd

    method resource_exists rd =
      Keyring.get keyring (self#id rd)
      >>= function
        | None   -> Wm.continue false rd
        | Some _ -> Wm.continue true rd

    method content_types_provided rd =
      Wm.continue [
        "application/json", self#to_json;
        "application/x-pem-file", self#to_pem
      ] rd

    method content_types_accepted rd =
      Wm.continue [
        "application/json", self#of_json
      ] rd

    method delete_resource rd =
      Keyring.del keyring (self#id rd)
      >>= fun deleted ->
        let resp_body =
          if deleted
            then `String (jsend_success `Null |> YB.pretty_to_string)
            else assert false (* can't happen, because of resource_exists *)
        in
        Wm.continue deleted { rd with Wm.Rd.resp_body }

    method private id rd =
      Wm.Rd.lookup_path_info_exn "id" rd
  end

  (** A resource for querying an individual key in the database by id via GET,
      modifying an key via PUT, and deleting an key via DELETE. *)
  class pem_key keyring = object(self)
    inherit [Cohttp_lwt_body.t] Wm.resource

    method private to_pem rd =
      Keyring.get keyring (self#id rd)
      >>= function
        | None            -> assert false
        | Some key -> let pem = Keyring.pem_of_pub key in
          Wm.continue (`String pem) rd


    method allowed_methods rd =
      Wm.continue [`GET] rd

    method resource_exists rd =
      Keyring.get keyring (self#id rd)
      >>= function
        | None   -> Wm.continue false rd
        | Some _ -> Wm.continue true rd

    method content_types_provided rd =
      Wm.continue [
        "application/x-pem-file", self#to_pem
      ] rd

    method content_types_accepted rd =
      Wm.continue [] rd

    method private id rd =
      Wm.Rd.lookup_path_info_exn "id" rd
  end

  (** A resource for executing actions on keys via POST. Parameters for the
      actions are sent in a JSON body, and the result is returned with a JSON
      body as well. *)
  class key_actions keyring = object(self)
    inherit [Cohttp_lwt_body.t] Wm.resource

    method allowed_methods rd =
      Wm.continue [`POST] rd

    method content_types_provided rd =
      Wm.continue [
        "application/json", Wm.continue (`Empty);
      ] rd

    method content_types_accepted rd =
      Wm.continue [] rd

    method resource_exists rd =
      Keyring.get keyring (self#id rd)
      >>= function
      | None   -> Wm.continue false rd
      | Some _ ->
      try
        let _ = self#action_dispatch_exn rd in
        Wm.continue true rd
      with _ -> Wm.continue false rd

    method process_post rd =
      begin try
        Cohttp_lwt_body.to_string rd.Wm.Rd.req_body
        >>= fun body ->
        let data = YB.from_string body in
        self#action_dispatch_exn rd ~data
        >|= jsend
      with
        | e -> Lwt.return (Printexc.to_string e |> jsend_error)
      end
      >>= fun jsend ->
      let resp_body = `String (YB.pretty_to_string jsend) in
      Wm.continue true { rd with Wm.Rd.resp_body }

    method private action_dispatch_exn rd =
      let id = self#id rd in
      let action = self#action rd in
      let padding = self#padding rd in
      let hash_type = self#hash_type rd in
      match (action, padding, hash_type) with
        | ("decrypt", None,         None)
          -> Keyring.decrypt keyring ~id ~padding:Keyring.Padding.None
        | ("decrypt", Some "pkcs1", None)
          -> Keyring.decrypt keyring ~id ~padding:Keyring.Padding.PKCS1
        | ("sign",    Some "pkcs1", None)
          -> Keyring.sign keyring ~id ~padding:Keyring.Padding.PKCS1
        | ("decrypt", Some "oaep",  Some (#Nocrypto.Hash.hash as h))
          -> Keyring.decrypt keyring ~id ~padding:(Keyring.Padding.OAEP h)
        | ("sign",    Some "pss",   Some (#Nocrypto.Hash.hash as h))
          -> Keyring.sign keyring ~id ~padding:(Keyring.Padding.PSS h)
        | _, _, Some #Nocrypto.Hash.hash
        | _, _, Some `Invalid
        | _, _, None
          -> assert false

    method private id rd = Wm.Rd.lookup_path_info_exn "id" rd

    method private action rd = Wm.Rd.lookup_path_info_exn "action" rd

    method private padding rd =
      try Some (Wm.Rd.lookup_path_info_exn "padding" rd)
      with _ -> None

    method private hash_type rd =
      try
        let hash_type_str = Wm.Rd.lookup_path_info_exn "hash_type" rd in
        try Some (List.find (fun (_, x) -> x = hash_type_str) hash_paths |> fst)
        with Not_found -> Some `Invalid
      with _ -> None

  end

  (** A resource for querying system config *)
  class status = object(self)
    inherit [Cohttp_lwt_body.t] Wm.resource

    method private to_json rd =
      Wm.continue (`String "{\"status\":\"ok\"}") rd

    method allowed_methods rd =
      Wm.continue [`GET] rd

    method content_types_provided rd =
      Wm.continue [
        "application/json", self#to_json
      ] rd

    method content_types_accepted rd =
      Wm.continue [] rd
  end

  let start c fs http =
    (* listen on port 8080 *)
    let port = 8080 in
    (* create the database *)
    let keyring = Keyring.create () in
    (* the route table *)
    let routes = [
      (api_prefix ^ "/keys", fun () -> new keys keyring) ;
      (api_prefix ^ "/keys/:id", fun () -> new key keyring) ;
      (api_prefix ^ "/keys/:id/public", fun () -> new key keyring) ;
      (api_prefix ^ "/keys/:id/public.pem", fun () -> new pem_key keyring) ;
      (api_prefix ^ "/keys/:id/actions/:action",
        fun () -> new key_actions keyring) ;
      (api_prefix ^ "/keys/:id/actions/:padding/:action",
        fun () -> new key_actions keyring) ;
      (api_prefix ^ "/keys/:id/actions/:padding/:hash_type/:action",
        fun () -> new key_actions keyring) ;
      (api_prefix ^ "/system/status", fun () -> new status) ;
    ] in
    let callback conn_id request body =
      let open Cohttp in
      (* Perform route dispatch. If [None] is returned, then the URI path did not
       * match any of the route patterns. In this case the server should return a
       * 404 [`Not_found]. *)
      Wm.dispatch' routes ~body ~request
      >|= begin function
        | None        -> (`Not_found, Header.init (), `String "Not found", [])
        | Some result -> result
      end
      >>= fun (status, headers, body, path) ->
        (* If you'd like to see the path that the request took through the
         * decision diagram, then run this example with the [DEBUG_PATH]
         * environment variable set. This should suffice:
         *
         *  [$ DEBUG_PATH= ./crud_lwt.native]
         *
         *)
        let path =
          match Sys.getenv "DEBUG_PATH" with
          | _ -> Printf.sprintf " - %s" (String.concat ", " path)
          | exception Not_found   -> ""
        in
        let debug_out =
          match Sys.getenv "DEBUG" with
          | _ ->
            let resp_body = match body with
              | `Empty | `String _ | `Strings _ as x -> Body.to_string x
              | `Stream _ -> "__STREAM__"
            in
            Printf.sprintf "\nResponse header:\n%sResponse body:\n%s\n----------------------------------------\n"
            (Header.to_string headers) resp_body
          | exception Not_found   -> ""
        in
        Printf.eprintf "%d - %s %s%s%s\n"
          (Code.code_of_status status)
          (Code.string_of_method (Request.meth request))
          (Uri.path (Request.uri request))
          path debug_out;
        (* Finally, send the response to the client *)
        H.respond ~headers ~body ~status ()
    in
    (* create the server and handle requests with the function defined above *)
    let conn_closed (_,conn_id) =
      let cid = Cohttp.Connection.to_string conn_id in
      C.log c (Printf.sprintf "conn %s closed" cid)
    in
    http (`TCP port) (H.make ~conn_closed ~callback ())
end
