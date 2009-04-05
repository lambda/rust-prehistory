open Semant;;
open Common;;

(*
 * Resolution passes:
 *
 *   - build multiple 'scope' hashtables mapping slot_key -> node_id
 *   - build single 'type inference' hashtable mapping node_id -> slot
 *
 *   (note: not every slot is identified; only those that are declared
 *    in statements and/or can participate in local type inference.
 *    Those in function signatures are not, f.e. Also no type values
 *    are identified, though module items are. )
 *
 *
 *)

type scope =
    SCOPE_block of node_id
  | SCOPE_mod_item of Ast.mod_item
  | SCOPE_mod_type_item of Ast.mod_type_item


let log cx = Session.log "resolve"
  cx.ctxt_sess.Session.sess_log_resolve
  cx.ctxt_sess.Session.sess_log_out
;;


let block_scope_forming_visitor
    (cx:ctxt)
    (inner:Walk.visitor)
    : Walk.visitor =
  let visit_block_pre b =
    if not (Hashtbl.mem cx.ctxt_block_items b.id)
    then htab_put cx.ctxt_block_items b.id (Hashtbl.create 0);
    if not (Hashtbl.mem cx.ctxt_block_slots b.id)
    then htab_put cx.ctxt_block_slots b.id (Hashtbl.create 0);
    inner.Walk.visit_block_pre b
  in
    { inner with Walk.visit_block_pre = visit_block_pre }
;;


let decl_stmt_collecting_visitor
    (cx:ctxt)
    (inner:Walk.visitor)
    : Walk.visitor =
  let block_ids = Stack.create () in
  let visit_block_pre (b:Ast.block) =
    Stack.push b.id block_ids;
    inner.Walk.visit_block_pre b
  in
  let visit_block_post (b:Ast.block) =
    inner.Walk.visit_block_post b;
    ignore (Stack.pop block_ids)
  in
  let visit_stmt_pre stmt =
    begin
      match stmt.node with
          Ast.STMT_decl d ->
            begin
              let bid = Stack.top block_ids in
              let items = Hashtbl.find cx.ctxt_block_items bid in
              let slots = Hashtbl.find cx.ctxt_block_slots bid in
              let check_and_log_ident id ident =
                if Hashtbl.mem items ident ||
                  Hashtbl.mem slots (Ast.KEY_ident ident)
                then
                  err (Some id)
                    "duplicate declaration '%s' in block" ident
                else
                  log cx "found decl of '%s' in block" ident
              in
              let check_and_log_tmp id tmp =
                if Hashtbl.mem slots (Ast.KEY_temp tmp)
                then
                  err (Some id)
                    "duplicate declaration of temp #%d in block" (int_of_temp tmp)
                else
                  log cx "found decl of temp #%d in block" (int_of_temp tmp)
              in
              let check_and_log_key id key =
                match key with
                    Ast.KEY_ident i -> check_and_log_ident id i
                  | Ast.KEY_temp t -> check_and_log_tmp id t
              in
                match d with
                    Ast.DECL_mod_item (ident, item) ->
                      check_and_log_ident item.id ident;
                      htab_put items ident item.id
                  | Ast.DECL_slot (key, sid) ->
                      check_and_log_key sid.id key;
                      htab_put slots key sid.id
            end
        | _ -> ()
    end;
    inner.Walk.visit_stmt_pre stmt
  in
    { inner with
        Walk.visit_block_pre = visit_block_pre;
        Walk.visit_block_post = visit_block_post;
        Walk.visit_stmt_pre = visit_stmt_pre }
;;


let scope_stack_managing_visitor
    (scopes:scope Stack.t)
    (inner:Walk.visitor)
    : Walk.visitor =
  let visit_block_pre b =
    Stack.push (SCOPE_block b.id) scopes;
    inner.Walk.visit_block_pre b
  in
  let visit_block_post b =
    inner.Walk.visit_block_post b;
    ignore (Stack.pop scopes)
  in
  let visit_mod_item_pre n p i =
    Stack.push (SCOPE_mod_item i) scopes;
    inner.Walk.visit_mod_item_pre n p i
  in
  let visit_mod_item_post n p i =
    inner.Walk.visit_mod_item_post n p i;
    ignore (Stack.pop scopes)
  in
  let visit_mod_type_item_pre n p i =
    Stack.push (SCOPE_mod_type_item i) scopes;
    inner.Walk.visit_mod_type_item_pre n p i
  in
  let visit_mod_type_item_post n p i =
    inner.Walk.visit_mod_type_item_post n p i;
    ignore (Stack.pop scopes)
  in
    { inner with
        Walk.visit_block_pre = visit_block_pre;
        Walk.visit_block_post = visit_block_post;
        Walk.visit_mod_item_pre = visit_mod_item_pre;
        Walk.visit_mod_item_post = visit_mod_item_post;
        Walk.visit_mod_type_item_pre = visit_mod_type_item_pre;
        Walk.visit_mod_type_item_post = visit_mod_type_item_post; }
;;


let all_item_collecting_visitor
    (cx:ctxt)
    (inner:Walk.visitor)
    : Walk.visitor =
  let visit_mod_item_pre n p i =
    htab_put cx.ctxt_all_items i.id i.node;
    log cx "collected item #%d" (int_of_node i.id);
    inner.Walk.visit_mod_item_pre n p i
  in
    { inner with
        Walk.visit_mod_item_pre = visit_mod_item_pre }
;;


let slot_resolving_visitor
    (cx:ctxt)
    (scopes:scope Stack.t)
    (inner:Walk.visitor)
    : Walk.visitor =

  let resolve_slot_identified (s:Ast.slot identified) : (Ast.slot identified) =
    let lookup_type_by_ident ident =
      let check_item (i:Ast.mod_item') : Ast.ty =
        match i with
            (Ast.MOD_ITEM_opaque_type td) -> td.Ast.decl_item
          | (Ast.MOD_ITEM_public_type td) -> td.Ast.decl_item
          | _ -> err (Some s.id) "identifier '%s' resolves to non-type" ident
      in
      let check_item_option (iopt:Ast.mod_item option) : Ast.ty option =
        match iopt with
            Some i -> Some (check_item i.node)
          | _ -> None
      in
      let check_scope (scope:scope) : Ast.ty option =
        match scope with
            SCOPE_block block_id ->
              let block_items = Hashtbl.find cx.ctxt_block_items block_id in
              if Hashtbl.mem block_items ident
              then
                Some (check_item
                        (Hashtbl.find cx.ctxt_all_items
                           (Hashtbl.find block_items ident)))
              else None

          | SCOPE_mod_item item ->
              begin
                match item.node with
                  | Ast.MOD_ITEM_mod m ->
                      check_item_option (htab_search m.Ast.decl_item ident)
                  | Ast.MOD_ITEM_prog p ->
                      check_item_option (htab_search p.Ast.decl_item.Ast.prog_mod ident)
                  | _ -> None
              end
                (* FIXME: handle looking up types inside mod type scopes. *)
          | _ -> None
      in
        log cx "looking up type with ident '%s'" ident;
        match stk_search scopes check_scope with
            None -> err (Some s.id) "unresolved identifier '%s'" ident
          | Some t -> (log cx "resolved to type %s" (Ast.fmt_to_str Ast.fmt_ty t); t)
    in

    let rec resolve_slot (slot:Ast.slot) : Ast.slot =
      { slot with
          Ast.slot_ty = (match slot.Ast.slot_ty with
                             None -> None
                           | Some t -> Some (resolve_ty t)) }

    and resolve_ty (t:Ast.ty) : Ast.ty =
      match t with
          Ast.TY_any | Ast.TY_nil | Ast.TY_bool | Ast.TY_mach _
        | Ast.TY_int | Ast.TY_char | Ast.TY_str | Ast.TY_type
        | Ast.TY_idx _ | Ast.TY_opaque _ -> t

        | Ast.TY_tup tys -> Ast.TY_tup (Array.map resolve_slot tys)
        | Ast.TY_rec trec -> Ast.TY_rec (Array.map (fun (n, s) -> (n, resolve_slot s)) trec)

        | Ast.TY_tag ttag -> Ast.TY_tag (htab_map ttag (fun i s -> (i, resolve_ty t)))
        | Ast.TY_iso tiso ->
            Ast.TY_iso
              { tiso with
                  Ast.iso_group =
                  Array.map (fun ttag -> htab_map ttag
                               (fun i s -> (i, resolve_ty t)))
                    tiso.Ast.iso_group }

        | Ast.TY_vec ty -> Ast.TY_vec (resolve_ty ty)
        | Ast.TY_chan ty -> Ast.TY_chan (resolve_ty ty)
        | Ast.TY_port ty -> Ast.TY_port (resolve_ty ty)
        | Ast.TY_lim ty -> Ast.TY_lim (resolve_ty ty)

        | Ast.TY_constrained (ty, constrs) ->
            Ast.TY_constrained ((resolve_ty ty),constrs)

        | Ast.TY_fn (tsig,taux) ->
            Ast.TY_fn
              ({ Ast.sig_input_slots = Array.map resolve_slot tsig.Ast.sig_input_slots;
                 Ast.sig_output_slot = resolve_slot tsig.Ast.sig_output_slot }, taux)

        | Ast.TY_pred slots -> Ast.TY_pred (Array.map resolve_slot slots)

        | Ast.TY_named (Ast.NAME_base (Ast.BASE_ident ident)) ->
            resolve_ty (lookup_type_by_ident ident)

        | Ast.TY_named _ -> err (Some s.id) "unhandled form of type name"
        | Ast.TY_prog tprog -> err (Some s.id) "unhandled resolution of prog types"
        | Ast.TY_mod tmod -> err (Some s.id) "unhandled resolution of mod types"

    in
      { s with node = resolve_slot s.node }
  in

  let visit_slot_identified_pre slot =
    let slot = resolve_slot_identified slot in
      htab_put cx.ctxt_all_slots slot.id slot.node;
      log cx "collected resolved slot #%d with type %s" (int_of_node slot.id)
        (match slot.node.Ast.slot_ty with
             None -> "??"
           | Some t -> (Ast.fmt_to_str Ast.fmt_ty t));
      inner.Walk.visit_slot_identified_pre slot
  in
    { inner with
        Walk.visit_slot_identified_pre = visit_slot_identified_pre }
;;


let lval_base_resolving_visitor
    (cx:ctxt)
    (scopes:scope Stack.t)
    (inner:Walk.visitor)
    : Walk.visitor =
  let lookup_slot_by_ident id ident =
    log cx "looking up slot or item with ident '%s'" ident;
    let key = Ast.KEY_ident ident in
    let check_scope scope =
      match scope with
          SCOPE_block block_id ->
            let block_slots = Hashtbl.find cx.ctxt_block_slots block_id in
            let block_items = Hashtbl.find cx.ctxt_block_items block_id in
              if Hashtbl.mem block_slots key
              then Some (Hashtbl.find block_slots key)
              else
                if Hashtbl.mem block_items ident
                then Some (Hashtbl.find block_items ident)
                else None
        | SCOPE_mod_item item ->
            begin
              match item.node with
                  Ast.MOD_ITEM_fn f ->
                    arr_search
                      f.Ast.decl_item.Ast.fn_input_slots
                      (fun _ (sloti,ident') ->
                         if ident = ident' then Some sloti.id else None)

                | Ast.MOD_ITEM_mod m ->
                    if Hashtbl.mem m.Ast.decl_item ident
                    then Some (Hashtbl.find m.Ast.decl_item ident).id
                    else None

                | Ast.MOD_ITEM_prog p ->
                    if Hashtbl.mem p.Ast.decl_item.Ast.prog_mod ident
                    then Some (Hashtbl.find p.Ast.decl_item.Ast.prog_mod ident).id
                    else None

                | _ -> None
            end
        | _ -> None

    in
      match stk_search scopes check_scope with
          None -> err (Some id) "unresolved identifier '%s'" ident
        | Some id -> (log cx "resolved to node id #%d" (int_of_node id); id)
  in
  let lookup_slot_by_temp id temp =
    log cx "looking up temp slot #%d" (int_of_temp temp);
    let key = Ast.KEY_temp temp in
    let check_scope scope =
      match scope with
          SCOPE_block block_id ->
            let block_slots = Hashtbl.find cx.ctxt_block_slots block_id in
              if Hashtbl.mem block_slots key
              then Some (Hashtbl.find block_slots key)
              else None
        | _ -> None
    in
      match stk_search scopes check_scope with
          None -> err (Some id) "unresolved temp node #%d" (int_of_temp temp)
        | Some id -> (log cx "resolved to node id #%d" (int_of_node id); id)
  in
  let lookup_slot_by_name_base id nb =
    match nb with
        Ast.BASE_ident ident -> lookup_slot_by_ident id ident
      | Ast.BASE_temp temp -> lookup_slot_by_temp id temp
      | Ast.BASE_app _ -> err (Some id) "unhandled name base case BASE_app"
  in

  let visit_lval_pre lv =
    let rec lookup_lval lv =
      match lv with
          Ast.LVAL_ext (base, _) -> lookup_lval base
        | Ast.LVAL_base nb ->
            let slot_id = lookup_slot_by_name_base nb.id nb.node in
              log cx "resolved lval #%d to slot #%d" (int_of_node nb.id) (int_of_node slot_id);
              htab_put cx.ctxt_lval_to_referent nb.id slot_id
    in
      lookup_lval lv;
      inner.Walk.visit_lval_pre lv
  in
    { inner with
        Walk.visit_lval_pre = visit_lval_pre }
;;


let process_crate
    (cx:ctxt)
    (items:Ast.mod_items)
    : unit =
  let (scopes:scope Stack.t) = Stack.create () in
  let passes =
    [|
      (block_scope_forming_visitor cx
         (decl_stmt_collecting_visitor cx
            (all_item_collecting_visitor cx
               Walk.empty_visitor)));
      (scope_stack_managing_visitor scopes
         (slot_resolving_visitor cx scopes
            (lval_base_resolving_visitor cx scopes
               Walk.empty_visitor)));
    |]
  in
    run_passes cx passes (log cx "%s") items
;;

(* ***********************************
   some resudual code that did type-parameter binding, earlier
   

(*
 * 'binding' is mostly just to permit returning a single ocaml type
 * from a scope-based lookup; scopes (and the things found in them)
 * have two separate flavours, those formed from modules and those
 * formed from module *types*. The latter can nest in the former,
 * but not vice-versa.
 *
 * All lookup functions should therefore consult the possibly-empty
 * nested type-scope before looking in
 * the enclosing frame scope list.
 *)

type binding =
    BINDING_item of ((Ast.resolved_path option) * Ast.mod_item)
  | BINDING_slot of ((Ast.resolved_path option) * Ast.local)
  | BINDING_type_item of Ast.mod_type_item


(*
 * Extend a context with bindings for the type parameters of a
 * module item or module-type item, given actual arguments.
 *)
let apply_ctxt_generic
    (cx:ctxt)
    (extend:ctxt -> ((Ast.ident,('a identified)) Hashtbl.t) -> 'b)
    (ctor:Ast.ty Ast.decl -> 'a)
    (params:((Ast.ty_limit * Ast.ident) array))
    (args:Ast.ty array)
    (id:int) =
  let nparams = Array.length params in
  let nargs = Array.length args in
    if nargs != nparams
    then raise (err cx "mismatched number of type parameters and arguments")
    else
      if nparams = 0
      then cx
      else
        let htab = Hashtbl.create nparams in
        let addty i (lim, ident) =
          let ty =
            match (args.(i), lim) with
                (Ast.TY_lim _, Ast.UNLIMITED) ->
                  raise (err cx "passing limited type where unlimited required")
              | (Ast.TY_lim t, Ast.LIMITED) -> Ast.TY_lim t
              | (t, Ast.LIMITED) -> Ast.TY_lim t
              | (t, Ast.UNLIMITED) -> t
          in
          let item' = (ctor { Ast.decl_params = [| |];
                              Ast.decl_item = ty })
          in
            htab_put htab ident { node = item';
                                     id = id }
        in
          Array.iteri addty params;
          extend cx htab


let rec extend_ctxt_by_mod_ty
    (cx:ctxt)
    (tyitems:Ast.mod_type_items)
    : ctxt =
  let scopes = tyitems :: cx.ctxt_type_scopes in
    { cx with ctxt_type_scopes = scopes }

(*
 * Extend a context with bindings for the type parameters of a
 * module item, mapping each to a new anonymous type.
 *)
and param_ctxt cx params id =
  let nparams = Array.length params in
    if nparams = 0
    then cx
    else
      let bind (lim, ident) =
        let nonce = next_ty_nonce () in
        let item' = (Ast.MOD_ITEM_public_type
                       { Ast.decl_params = [| |];
                         Ast.decl_item = (match lim with
                                              Ast.LIMITED -> (Ast.TY_lim (Ast.TY_opaque nonce))
                                            | Ast.UNLIMITED -> (Ast.TY_opaque nonce))})
        in
          (ident, { node = item'; id = id })
      in
        extend_ctxt_by_frame cx (Array.map bind params)

and linearize_items_for_frame
    (items:(Ast.ident,Ast.mod_item) Hashtbl.t)
    : ((Ast.ident * Ast.mod_item) array) =
    let get_named_slot name item sz = ((name, item) :: sz) in
    let named_items = Hashtbl.fold get_named_slot items [] in
      (Array.of_list
         (Sort.list
            (fun (a, _) (b, _) -> a < b) named_items))

and apply_ctxt cx params args id =
  apply_ctxt_generic cx
    (fun cx items -> extend_ctxt_by_frame cx (linearize_items_for_frame items))
    (fun x -> Ast.MOD_ITEM_public_type x)
    params args id


and apply_ctxt_ty cx params args id =
  apply_ctxt_generic cx
    extend_ctxt_by_mod_ty
    (fun x -> Ast.MOD_TYPE_ITEM_public_type x)
    params args id


and should_use_vreg (cx:ctxt) (local:Ast.local) : bool =
  let slotr = local.Ast.local_slot in
  let sz = slot_size cx (!(slotr.node)) in
    (Int64.compare sz cx.ctxt_abi.Abi.abi_ptr_sz > 0 ||
       (!(local.Ast.local_aliased)))

and lookup_ident
    (cx:ctxt)
    (fp:Ast.resolved_path)
    (ident:Ast.ident)
    : (ctxt * binding) =
  match cx.ctxt_type_scopes with
      (x::xs) ->
        if Hashtbl.mem x ident
        then
          let tyitem = Hashtbl.find x ident in
            ({ cx with ctxt_id = Some tyitem.id },
             BINDING_type_item tyitem)
        else
          lookup_ident
            { cx with ctxt_type_scopes = xs } fp ident
    | [] ->
        begin
          match cx.ctxt_frame_scopes with
              [] -> raise (err cx ("unknown identifier: '" ^ ident ^ "'"))
            | (x::xs) ->
                let local_opt =
                  match x with
                      Ast.FRAME_heavy hf ->
                        let args = !(hf.Ast.heavy_frame_arg_slots) in
                          if List.exists (fun (k,_) -> k = ident) args
                          then Some (List.assoc ident args)
                          else None
                    | Ast.FRAME_light lf ->
                        let tab = lf.Ast.light_frame_locals in
                          if Hashtbl.mem tab (Ast.KEY_ident ident)
                          then Some (Hashtbl.find tab (Ast.KEY_ident ident))
                          else None
                in
                  match local_opt with
                      Some local ->
                        let layout = local.Ast.local_layout in
                        let slotr = local.Ast.local_slot in
                        let pathopt =
                          try
                            match x with
                                Ast.FRAME_light _ ->
                                  if should_use_vreg cx local
                                  then Some (Ast.RES_member (layout, (Ast.RES_deref fp)))
                                  else Some (Ast.RES_vreg local.Ast.local_vreg)
                              | Ast.FRAME_heavy hf ->
                                  Some (Ast.RES_member
                                          (layout,
                                           (Ast.RES_member (hf.Ast.heavy_frame_layout,
                                                            (Ast.RES_deref fp)))))
                          with
                              Auto_slot ->
                                begin
                                  cx.ctxt_contains_autos := true;
                                  None
                                end
                        in
                          ({cx with ctxt_id = Some slotr.id},
                           BINDING_slot (pathopt, local))
                    | None ->
                        begin
                          match x with
                              Ast.FRAME_heavy _ ->
                                lookup_ident
                                  { cx with ctxt_frame_scopes = xs }
                                  (Ast.RES_deref fp) ident
                            | Ast.FRAME_light lf ->
                                let tab = lf.Ast.light_frame_items in
                                  if Hashtbl.mem tab ident
                                  then
                                    let (layout, item) = Hashtbl.find tab ident in
                                    let pathopt = Some (Ast.RES_member (layout, (Ast.RES_deref fp))) in
                                      ({cx with ctxt_id = Some item.id},
                                       BINDING_item (pathopt, item))
                                  else
                                    lookup_ident
                                      { cx with ctxt_frame_scopes = xs } fp ident
                        end
        end


and lookup_temp (cx:ctxt)
    (fp:Ast.resolved_path)
    (temp:Ast.nonce)
    : (ctxt * binding) =
  match cx.ctxt_frame_scopes with
      [] -> raise (err cx ("unknown temporary: '" ^ (string_of_int temp) ^ "'"))
    | (x::xs) ->
        begin
          match x with
              Ast.FRAME_light lf ->
                let tab = lf.Ast.light_frame_locals in
                  if Hashtbl.mem tab (Ast.KEY_temp temp)
                  then
                    let local = Hashtbl.find tab (Ast.KEY_temp temp) in
                    let layout = local.Ast.local_layout in
                    let slotr = local.Ast.local_slot in
                    let pathopt =
                      try
                        if should_use_vreg cx local
                        then Some (Ast.RES_member (layout, (Ast.RES_deref fp)))
                        else Some (Ast.RES_vreg local.Ast.local_vreg)
                      with
                          Auto_slot ->
                            begin
                              cx.ctxt_contains_autos := true;
                              None
                            end
                    in
                      log cx "found temporary temp %d" temp;
                      ({ cx with ctxt_id = Some slotr.id },
                       BINDING_slot (pathopt, local))
                  else
                    lookup_temp { cx with ctxt_frame_scopes = xs } fp temp
            | _ ->
                lookup_temp
                  { cx with ctxt_frame_scopes = xs } (Ast.RES_deref fp) temp
        end

and lookup_base cx base =
  match base with
      (Ast.BASE_ident id) -> lookup_ident cx (Ast.RES_pr FP) id
    | (Ast.BASE_temp t) -> lookup_temp cx (Ast.RES_pr FP) t
    | _ -> raise (err cx "unhandled name base variant in lookup_base")


and string_of_base cx base =
  match base with
      Ast.BASE_ident id -> id
    | Ast.BASE_temp t -> ("temp#" ^ (string_of_int t))
    | _ -> raise (err cx "unhandled name base variant in string_of_base")


and mod_type_of_mod m =
  let ty_items = Hashtbl.create 4 in
  let add n i = htab_put ty_items n (mod_type_item_of_mod_item i) in
    Hashtbl.iter add m;
    ty_items

and prog_type_of_prog prog =
  let init_ty = (match prog.Ast.prog_init with
                     None -> None
                   | Some init -> Some init.Ast.init_sig)
  in
    { Ast.prog_mod_ty = mod_type_of_mod prog.Ast.prog_mod;
      Ast.prog_init_ty = init_ty; }


and mod_type_item_of_mod_item item =
  let decl params item =
    { Ast.decl_params = params;
      Ast.decl_item = item }
  in
  let ty =
    match item.node with
        Ast.MOD_ITEM_opaque_type td ->
          (match (td.Ast.decl_params, td.Ast.decl_item) with
               (params, Ast.TY_lim _) ->
                 Ast.MOD_TYPE_ITEM_opaque_type
                   (decl params Ast.LIMITED)
             | (params, _) ->
                 Ast.MOD_TYPE_ITEM_opaque_type
                   (decl params Ast.UNLIMITED))
      | Ast.MOD_ITEM_public_type td ->
          Ast.MOD_TYPE_ITEM_public_type td
      | Ast.MOD_ITEM_pred pd ->
          Ast.MOD_TYPE_ITEM_pred
            (decl pd.Ast.decl_params pd.Ast.decl_item.Ast.pred_ty)
      | Ast.MOD_ITEM_mod md ->
            Ast.MOD_TYPE_ITEM_mod
              (decl md.Ast.decl_params (mod_type_of_mod md.Ast.decl_item))
      | Ast.MOD_ITEM_fn fd ->
          Ast.MOD_TYPE_ITEM_fn
            (decl fd.Ast.decl_params fd.Ast.decl_item.Ast.fn_ty)
      | Ast.MOD_ITEM_prog pd ->
          let prog_ty = prog_type_of_prog pd.Ast.decl_item in
            Ast.MOD_TYPE_ITEM_prog (decl pd.Ast.decl_params prog_ty)
  in
    { id = item.id;
      node = ty }


and type_component_of_type_item cx tyitem comp =
  match comp with
      Ast.COMP_ident id ->
        (match tyitem.node with
             Ast.MOD_TYPE_ITEM_mod md ->
               let params = md.Ast.decl_params in
               let tyitems = md.Ast.decl_item in
                 if Hashtbl.mem tyitems id
                 then
                   let cx = param_ctxt cx params tyitem.id in
                   let cx = extend_ctxt_by_mod_ty cx tyitems in
                   let ty_item = (Hashtbl.find tyitems id) in
                     (cx, ty_item)
                 else raise (err cx ("unknown component of module type: '" ^ id ^ "'"))
           | _ -> raise (err cx ("looking up type in non-module type item: '" ^ id ^ "'")))
    | Ast.COMP_app (id, tys) ->
        raise (Invalid_argument
                 ("Semant.type_component_of_type_item lookup_type_in_item_by_component: " ^
                    "unimplemented parametric types when looking up '" ^ id ^ "'"))
    | Ast.COMP_idx i ->
        raise (err cx ("illegal index component in type name: .{" ^ (string_of_int i) ^ "}"))


and apply_args_to_item cx item args =
  let app params =
    apply_ctxt cx params args item.id
  in
    match item.node with
        Ast.MOD_ITEM_opaque_type td ->
          let cx = app td.Ast.decl_params in
            (cx, Ast.MOD_ITEM_opaque_type { td with Ast.decl_params = [| |] })

      | Ast.MOD_ITEM_public_type td ->
          let cx = app td.Ast.decl_params in
            (cx, Ast.MOD_ITEM_public_type { td with Ast.decl_params = [| |] })

      | Ast.MOD_ITEM_pred pd ->
          let cx = app pd.Ast.decl_params in
            (cx, Ast.MOD_ITEM_pred { pd with Ast.decl_params = [| |] })

      | Ast.MOD_ITEM_mod md ->
          let cx = app md.Ast.decl_params in
            (cx, Ast.MOD_ITEM_mod { md with Ast.decl_params = [| |] })

      | Ast.MOD_ITEM_fn fd ->
          let cx = app fd.Ast.decl_params in
            (cx, Ast.MOD_ITEM_fn { fd with Ast.decl_params = [| |] })

      | Ast.MOD_ITEM_prog pd ->
          let cx = app pd.Ast.decl_params in
            (cx, Ast.MOD_ITEM_prog { pd with Ast.decl_params = [| |] })


and apply_args_to_type_item cx tyitem args =
  let app params =
    apply_ctxt_ty cx params args tyitem.id
  in
    match tyitem.node with
        Ast.MOD_TYPE_ITEM_opaque_type td ->
          let cx = app td.Ast.decl_params in
            (cx, Ast.MOD_TYPE_ITEM_opaque_type { td with Ast.decl_params = [| |] })

      | Ast.MOD_TYPE_ITEM_public_type td ->
          let cx = app td.Ast.decl_params in
            (cx, Ast.MOD_TYPE_ITEM_public_type { td with Ast.decl_params = [| |] })

    | Ast.MOD_TYPE_ITEM_pred pd ->
        let cx = app pd.Ast.decl_params in
          (cx, Ast.MOD_TYPE_ITEM_pred { pd with Ast.decl_params = [| |] })

    | Ast.MOD_TYPE_ITEM_mod md ->
        let cx = app md.Ast.decl_params in
          (cx, Ast.MOD_TYPE_ITEM_mod { md with Ast.decl_params = [| |] })

    | Ast.MOD_TYPE_ITEM_fn fd ->
        let cx = app fd.Ast.decl_params in
          (cx, Ast.MOD_TYPE_ITEM_fn { fd with Ast.decl_params = [| |] })

    | Ast.MOD_TYPE_ITEM_prog pd ->
        let cx = app pd.Ast.decl_params in
          (cx, Ast.MOD_TYPE_ITEM_prog { pd with Ast.decl_params = [| |] })


and lookup cx
    (basefn : ctxt -> (ctxt * binding) -> (ctxt * 'a))
    (extfn : ctxt -> (ctxt * 'a) -> Ast.name_component -> (ctxt * 'a))
    name =
  match name with
      Ast.NAME_base (Ast.BASE_ident id) -> basefn cx (lookup_ident cx (Ast.RES_pr FP) id)
    | Ast.NAME_base (Ast.BASE_app (id, args)) ->
        let (cx, binding) = lookup_ident cx (Ast.RES_pr FP) id in
          (match binding with
               BINDING_item (i, bi) ->
                 let ((cx':ctxt), item) = apply_args_to_item cx bi args in
                   basefn cx (cx', BINDING_item (i, {bi with node = item}))
             | BINDING_type_item bti ->
                 let ((cx':ctxt), tyitem) = apply_args_to_type_item cx bti args in
                   basefn cx (cx', BINDING_type_item {bti with node = tyitem})
             | BINDING_slot _ ->
                 raise (err cx "applying types to slot"))
    | Ast.NAME_base (Ast.BASE_temp temp) ->
        basefn cx (lookup_temp cx (Ast.RES_pr FP) temp)
    | Ast.NAME_ext (base, comp) ->
        let base' = lookup cx basefn extfn base in
          extfn cx base' comp


and lookup_type_item cx name =
  let basefn cx (cx', binding) =
    match binding with
        BINDING_item (_, item) -> (cx', mod_type_item_of_mod_item item)
      | BINDING_type_item tyitem -> (cx', tyitem)
      | _ -> raise (err cx "unhandled case in Semant.lookup_type")
  in
  let extfn cx (cx', tyitem) comp =
    type_component_of_type_item cx' tyitem comp
  in
    lookup cx basefn extfn name



and lookup_type cx name =
  let parametric =
    err cx "Semant.lookup_type found parametric binding, concrete type required"
  in
  let (cx', tyitem) = lookup_type_item cx name in
    match tyitem.node with
        Ast.MOD_TYPE_ITEM_opaque_type td ->
          if Array.length td.Ast.decl_params != 0
          then raise parametric
          else
            let opaque = Ast.TY_opaque (next_ty_nonce ()) in
              (match td.Ast.decl_item with
                   Ast.LIMITED -> (cx', Ast.TY_lim opaque)
                 | Ast.UNLIMITED -> (cx', opaque))
      | Ast.MOD_TYPE_ITEM_public_type td ->
          if Array.length td.Ast.decl_params != 0
          then raise parametric
          else (cx', td.Ast.decl_item)

      | _ -> raise (err cx ((string_of_name name) ^ " names a non-type item"))
*)

(*
 * Local Variables:
 * fill-column: 70;
 * indent-tabs-mode: nil
 * compile-command: "make -k -C .. 2>&1 | sed -e 's/\\/x\\//x:\\//g'";
 * End:
 *)