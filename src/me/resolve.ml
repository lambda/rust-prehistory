(* 
 * This module does the first (environment-sensitive) set of semantic lowerings:
 *
 *   - resolves lvals and types
 *   - lays out frames
 *   - performs type inference and checking
 * 
 * By the end of this pass, you should not need to do any further name-based lookups.
 *)

open Semant;;
open Common;;



(* 
type local =
    {
      local_slot: (Ast.slot ref) identified;
      local_vreg: (int option) ref;
      local_aliased: bool ref;
      local_layout: layout;
    }

and heavy_frame =
    { 
      heavy_frame_layout: layout;
      heavy_frame_arg_slots: ((ident * local) list) ref;
      (* FIXME: should these turn into anonymous lvals? *)
      heavy_frame_out_slot: (local option) ref;
    }

and light_frame = 
    {
      light_frame_layout: layout;
      light_frame_locals: (slot_key, local) Hashtbl.t;
      light_frame_items: (ident, (layout * mod_item)) Hashtbl.t;  
    }

and frame = 
    FRAME_heavy of heavy_frame
  | FRAME_light of light_frame

(* 
 * An lval can resolve to:
 * 
 *   - A local slot that you access through memory operations because it's big, or 
 *     because it is aliased.
 * 
 *   - A module item that you access indirectly through a pointer or some memory structure.
 * 
 *   - A purely local slot that is register sized.
 *)
      
and resolved_path = 
    RES_pr of abi_pseudo_reg
  | RES_member of (layout * resolved_path)
  | RES_deref of resolved_path
  | RES_idx of (resolved_path * resolved_path)
  | RES_vreg of ((int option) ref)

and resolved_target = 
    RES_slot of local
  | RES_item of mod_item

and lval_resolved = 
    {
      res_path: (resolved_path option) ref;
      res_target: (resolved_target option) ref;
    }
*) 

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

type slots_table = (Ast.slot_key,node_id) Hashtbl.t
type items_table = (Ast.ident,node_id) Hashtbl.t
type block_slots_table = (node_id,slots_table) Hashtbl.t
type block_items_table = (node_id,items_table) Hashtbl.t

type scope = 
    SCOPE_block of node_id
  | SCOPE_mod_item of Ast.mod_item
  | SCOPE_mod_type_item of Ast.mod_type_item

type ctxt = 
	{ ctxt_sess: Session.sess;
      ctxt_block_slots: block_slots_table;
      ctxt_block_items: block_items_table;
      ctxt_all_slots: (node_id,Ast.slot) Hashtbl.t;
      ctxt_all_items: (node_id,Ast.mod_item') Hashtbl.t;
      ctxt_lval_to_referent: (node_id,node_id) Hashtbl.t;
      ctxt_slot_aliased: (node_id,unit) Hashtbl.t;
      ctxt_slot_vregs: (node_id,(int ref)) Hashtbl.t;
      ctxt_slot_layouts: (node_id,layout) Hashtbl.t;
      ctxt_frame_layouts: (node_id,layout) Hashtbl.t;
	  ctxt_abi: Abi.abi }
;;

let	new_ctxt sess abi = 
  { ctxt_sess = sess;
    ctxt_block_slots = Hashtbl.create 0;
    ctxt_block_items = Hashtbl.create 0;
    ctxt_all_slots = Hashtbl.create 0;
    ctxt_all_items = Hashtbl.create 0;
    ctxt_lval_to_referent = Hashtbl.create 0;
    ctxt_slot_aliased = Hashtbl.create 0;
    ctxt_slot_vregs = Hashtbl.create 0;
    ctxt_slot_layouts = Hashtbl.create 0;
    ctxt_frame_layouts = Hashtbl.create 0;
	ctxt_abi = abi }
;;

let log cx = Session.log "resolve" 
  cx.ctxt_sess.Session.sess_log_resolve
  cx.ctxt_sess.Session.sess_log_out
;;


let pass_logging_visitor 
    (cx:ctxt)
    (pass:int) 
    (inner:Walk.visitor) 
    : Walk.visitor = 
  let logger = log cx "pass %d: %s" pass in
    (Walk.mod_item_logging_visitor logger inner)
;;


let block_scope_forming_visitor 
    (cx:ctxt)
    (inner:Walk.visitor)
    : Walk.visitor = 
  let visit_block_pre b = 
    if not (Hashtbl.mem cx.ctxt_block_items b.id)
    then Hashtbl.add cx.ctxt_block_items b.id (Hashtbl.create 0);
    if not (Hashtbl.mem cx.ctxt_block_slots b.id)
    then Hashtbl.add cx.ctxt_block_slots b.id (Hashtbl.create 0);
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
                    "duplicate declaration of temp #%d in block" tmp
                else 
                  log cx "found decl of temp #%d in block" tmp
              in
              let check_and_log_key id key = 
                match key with 
                    Ast.KEY_ident i -> check_and_log_ident id i
                  | Ast.KEY_temp t -> check_and_log_tmp id t 
              in
                match d with 
                    Ast.DECL_mod_item (ident, item) -> 
                      check_and_log_ident item.id ident;
                      Hashtbl.add items ident item.id
                  | Ast.DECL_slot (key, sid) -> 
                      check_and_log_key sid.id key;
                      Hashtbl.add slots key sid.id
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
    Hashtbl.add cx.ctxt_all_items i.id i.node;
    log cx "collected item #%d" i.id;
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
                  | _ -> None
              end
                (* FIXME: handle looking up types inside mod type scopes. *)
          | _ -> None            
      in
        log cx "looking up type with ident '%s'" ident;
        match stk_search scopes check_scope with 
            None -> err (Some s.id) "unresolved identifier '%s'" ident
          | Some t -> (log cx "resolved to type %s" (Ast.string_of_ty t); t)
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
        | Ast.TY_rec trec -> Ast.TY_rec (htab_map trec (fun n s -> (n, resolve_slot s)))
            
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
      Hashtbl.add cx.ctxt_all_slots slot.id slot.node;
      log cx "collected resolved slot #%d with type %s" slot.id 
        (match slot.node.Ast.slot_ty with 
             None -> "??"
           | Some t -> (Ast.string_of_ty t));
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
        | Some id -> (log cx "resolved to node id #%d" id; id)
  in
  let lookup_slot_by_temp id temp =  
    log cx "looking up temp slot #%d" temp;
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
          None -> err (Some id) "unresolved temp node #%d" temp
        | Some id -> (log cx "resolved to node id #%d" id; id)
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
              Hashtbl.add cx.ctxt_lval_to_referent nb.id slot_id
    in
      lookup_lval lv;
      inner.Walk.visit_lval_pre lv
  in
    { inner with 
        Walk.visit_lval_pre = visit_lval_pre }
;;


let auto_inference_visitor
    (cx:ctxt)
    (progress:bool ref)
    (inner:Walk.visitor)
    : Walk.visitor = 
  let check_ty_eq (t1:Ast.ty) (t2:Ast.ty) : unit = 
    if not (t1 = t2)
    then err None "mismatched types: %s vs. %s "
      (Ast.string_of_ty t1) (Ast.string_of_ty t2)
  in
  let unify_ty (tyo:Ast.ty option) (ty:Ast.ty) : Ast.ty option = 
    match tyo with 
        None -> Some ty
      | Some t -> (check_ty_eq t ty; Some t)
  in
  let unify_slot (tyo:Ast.ty option) (id:node_id) (s:Ast.slot) : Ast.ty option = 
    match (tyo, s.Ast.slot_ty) with 
        (None, None) -> None
      | (Some t, None) -> 
          log cx "setting type of slot #%d to %s" id (Ast.string_of_ty t);
          Hashtbl.replace cx.ctxt_all_slots id { s with Ast.slot_ty = (Some t) };
          progress := true;
          Some t
      | (tyo, Some t) -> unify_ty tyo t
  in
  let unify_lval (tyo:Ast.ty option) (lval:Ast.lval) : Ast.ty option = 
    match lval with 
        Ast.LVAL_base nb -> 
          let referent = Hashtbl.find cx.ctxt_lval_to_referent nb.id in
            begin
              match htab_search cx.ctxt_all_slots referent with 
                  Some s -> unify_slot tyo referent s
                | None ->
                    unify_ty tyo 
                      (ty_of_mod_item 
                         { node = (Hashtbl.find cx.ctxt_all_items referent);
                           id = referent })
            end
      | _ -> (* FIXME: full-name unification? Oh, that'll be complex... *) None
  in
  let unify_lit (tyo:Ast.ty option) (lit:Ast.lit) : Ast.ty option = 
    match lit with 
      | Ast.LIT_nil -> unify_ty tyo Ast.TY_nil
      | Ast.LIT_bool _ -> unify_ty tyo Ast.TY_bool 
      | Ast.LIT_mach (m, _) -> unify_ty tyo (Ast.TY_mach m)
      | Ast.LIT_int _ -> unify_ty tyo Ast.TY_int
      | Ast.LIT_char _ -> unify_ty tyo Ast.TY_char
      | Ast.LIT_str _ -> unify_ty tyo Ast.TY_str
      | Ast.LIT_custom _ -> tyo
  in    
  let unify_atom (tyo:Ast.ty option) (atom:Ast.atom) : Ast.ty option = 
    match atom with 
        Ast.ATOM_literal lit -> unify_lit tyo lit.node
      | Ast.ATOM_lval lval -> unify_lval tyo lval
  in    
  let unify_expr (tyo:Ast.ty option) (expr:Ast.expr) : Ast.ty option = 
    match expr with 
        Ast.EXPR_binary (op, a, b) -> 
          begin
            match op with 
                Ast.BINOP_eq | Ast.BINOP_ne
              | Ast.BINOP_lt | Ast.BINOP_le
              | Ast.BINOP_gt | Ast.BINOP_ge -> 
                  begin
                    ignore (unify_atom (unify_atom None a) b);
                    ignore (unify_atom (unify_atom None b) a);
                    unify_ty tyo Ast.TY_bool
                  end
              | _ -> 
                  begin
                    ignore (unify_atom (unify_atom tyo a) b);
                    unify_atom (unify_atom tyo b) a
                  end
          end
      | Ast.EXPR_unary (_, atom) -> unify_atom tyo atom
      | Ast.EXPR_atom atom -> unify_atom tyo atom
      | _ -> err None "unhandled expression type in expr_ty"
  in
  let visit_stmt_pre (s:Ast.stmt) = 
    begin
      match s.node with 
          Ast.STMT_copy (lval,expr) -> 
            ignore (unify_lval (unify_expr None expr) lval);
            ignore (unify_expr (unify_lval None lval) expr);
        | Ast.STMT_call (dst,fn,args) -> 
            begin
              match unify_lval None fn with 
                  None -> ()
                | Some (Ast.TY_fn (tsig, _)) -> 
                    begin
                      ignore (unify_lval tsig.Ast.sig_output_slot.Ast.slot_ty dst);
                      let islots = tsig.Ast.sig_input_slots in 
                        if Array.length islots != Array.length args 
                        then err (Some s.id) "argument count mismatch";
                        for i = 0 to (Array.length islots) - 1
                        do
                          ignore (unify_atom islots.(i).Ast.slot_ty args.(i));
                        done
                    end
                | _ -> err (Some s.id) "STMT_call fn resolved to non-function type"
            end
        | Ast.STMT_if i -> 
            ignore (unify_atom (Some Ast.TY_bool) i.Ast.if_test)
        | Ast.STMT_while w -> 
            let (_, atom) = w.Ast.while_lval in 
              ignore (unify_atom (Some Ast.TY_bool) atom)
        | _ -> () (* FIXME: plenty more to handle here. *)
    end;
    inner.Walk.visit_stmt_pre s
  in
    { inner with
        Walk.visit_stmt_pre = visit_stmt_pre }
;;


let infer_autos (cx:ctxt) (items:Ast.mod_items) : unit = 
    let auto_queue = Queue.create () in
    let enqueue_auto_slot id slot = 
      match slot.Ast.slot_ty with 
          None -> 
            log cx "enqueueing auto slot #%d" id; 
            Queue.add id auto_queue
        | _ -> ()
    in
    let progress = ref true in 
    let auto_pass = ref 0 in 
      Hashtbl.iter enqueue_auto_slot cx.ctxt_all_slots;
      while not (Queue.is_empty auto_queue) do
        if not (!progress) 
        then err None "auto inference pass wedged";
        let tmpq = Queue.copy auto_queue in 
          log cx "auto inference pass %d on %d remaining auto slots" 
            (!auto_pass)
            (Queue.length auto_queue);    
          Queue.clear auto_queue;
          progress := false;
          Walk.walk_mod_items 
            (Walk.mod_item_logging_visitor 
               (log cx "auto inference pass %d: %s" (!auto_pass))
               (auto_inference_visitor cx progress Walk.empty_visitor)) 
            items;
          Queue.iter 
            (fun id -> enqueue_auto_slot id 
               (Hashtbl.find cx.ctxt_all_slots id)) 
            tmpq;
          incr auto_pass;
      done
;;  


let alias_analysis_visitor
    (cx:ctxt)
    (inner:Walk.visitor)
    : Walk.visitor = 
  let alias lval = 
    match lval with 
        Ast.LVAL_base nb -> 
          let referent = Hashtbl.find cx.ctxt_lval_to_referent nb.id in
            if Hashtbl.mem cx.ctxt_all_slots referent
            then 
              begin
                log cx "noting slot #%d as aliased" referent;
                Hashtbl.replace cx.ctxt_slot_aliased referent ()
              end
      | _ -> err None "unhandled form of lval in alias analysis"
  in
  let visit_stmt_pre s =    
    begin
      match s.node with 
          (* 
           * FIXME: must expand this analysis to cover alias-forming arg slots, when 
           * they are supported. 
           *)
          Ast.STMT_call (dst, _, _) -> alias dst
        | _ -> () (* FIXME: plenty more to handle here. *)
    end;
    inner.Walk.visit_stmt_pre s
  in
    { inner with Walk.visit_stmt_pre = visit_stmt_pre }
;;

let layout_visitor
    (cx:ctxt)
    (inner:Walk.visitor)
    : Walk.visitor = 
  (* 
   *   - Frames look, broadly, like this (growing downward):
   * 
   *     +----------------------------+ <-- Rewind tail calls to here. If varargs are supported,
   *     |caller args                 |     must use memmove or similar "overlap-permitting" move,
   *     |...                         |     if supporting tail-calling. 
   *     |...                         |
   *     +----------------------------+ <-- fp + abi_frame_base_sz + abi_implicit_args_sz
   *     |caller non-reg ABI operands |
   *     |possibly empty, if fastcall |
   *     |  - process pointer?        |
   *     |  - runtime pointer?        |
   *     |  - yield pc or delta?      |
   *     |  - yield slot addr?        |
   *     |  - ret slot addr?          |
   *     +----------------------------+ <-- fp + abi_frame_base_sz
   *     |return pc pushed by machine |
   *     |plus any callee-save stuff  |
   *     +----------------------------+ <-- fp
   *     |frame-allocated stuff       |
   *     |determined in resolve       |
   *     |...                         |
   *     |...                         |
   *     |...                         |
   *     +----------------------------+ <-- fp - framesz
   *     |spills determined in ra     |
   *     |...                         |
   *     |...                         |
   *     +----------------------------+ <-- fp - (framesz + spillsz)
   * 
   *   - Divide slots into two classes:
   * 
   *     #1 Those that are never aliased and fit in a word, so are
   *        vreg-allocated
   * 
   *     #2 All others
   * 
   *   - Lay out the frame in post-order, given what we now know wrt
   *     the slot types and aliasing:
   * 
   *     - Non-aliased, word-fitting slots consume no frame space
   *       *yet*; they are given a generic value that indicates "try a
   *       vreg". The register allocator may spill them later, if it
   *       needs to, but that's not our concern.
   * 
   *     - Aliased / too-big slots are frame-allocated, need to be
   *       laid out in the frame at fixed offsets, so need to be
   *       assigned Common.layout values.  (Is this true of aliased
   *       word-fitting? Can we not runtime-calculate the position of
   *       a spill slot? Meh.)
   * 
   *   - The frame size is the maximum of all the block sizes contained
   *     within it. 
   * 
   *)

  let string_of_layout (ly:layout) : string = 
    Printf.sprintf "sz=%Ld, off=%Ld, align=%Ld" 
      ly.layout_size ly.layout_offset ly.layout_align
  in
  let layout_slot_ids (offset:int64) (slots:node_id array) : layout = 
    let layout_slot_id id = 
      if Hashtbl.mem cx.ctxt_slot_layouts id
      then Hashtbl.find cx.ctxt_slot_layouts id
      else 
        let slot = Hashtbl.find cx.ctxt_all_slots id in
        let layout = layout_slot cx.ctxt_abi 0L slot in 
          log cx "forming layout for slot #%d: %s" id (string_of_layout layout);
          Hashtbl.add cx.ctxt_slot_layouts id layout;
          layout
    in
    let layouts = Array.map layout_slot_id slots in
    let group_layout = pack offset layouts in
      for i = 0 to (Array.length layouts) - 1 do
        log cx "packed slot #%d layout to: %s" slots.(i) (string_of_layout layouts.(i))
      done;
      group_layout
  in
    
  let layout_fn (id:node_id) (fn:Ast.fn) : layout = 
    let offset = 
      Int64.add 
        cx.ctxt_abi.Abi.abi_frame_base_sz 
        cx.ctxt_abi.Abi.abi_implicit_args_sz 
    in
    let layout = layout_slot_ids offset (Array.map (fun (sid,_) -> sid.id) fn.Ast.fn_input_slots) in
      log cx "fn #%d total layout: %s" id (string_of_layout layout);
      layout
  in
  let layout_prog (id:node_id) (prog:Ast.prog) : layout = 
    { layout_offset = 0L;
      layout_size = 0L;
      layout_align = 0L }
  in
  let frame_layouts = Stack.create () in 
  let visit_mod_item_pre n p i = 
    begin
      match i.node with 
          Ast.MOD_ITEM_fn fd ->
            let layout = layout_fn i.id fd.Ast.decl_item in
              Stack.push layout frame_layouts
        | Ast.MOD_ITEM_prog pd ->
            let layout = layout_prog i.id pd.Ast.decl_item in
              Stack.push layout frame_layouts
        | _ -> ()
    end;
    inner.Walk.visit_mod_item_pre n p i
  in
  let visit_mod_item_post n p i = 
    inner.Walk.visit_mod_item_post n p i;
    begin
      match i.node with 
          Ast.MOD_ITEM_fn fd ->
            ignore (Stack.pop frame_layouts)
        | Ast.MOD_ITEM_prog pd ->
            ignore (Stack.pop frame_layouts)
        | _ -> ()
    end;
  in
    { inner with 
        Walk.visit_mod_item_pre = visit_mod_item_pre;
        Walk.visit_mod_item_post = visit_mod_item_post }    
;;


let resolve_crate 
    (sess:Session.sess) 
    (abi:Abi.abi) 
    (items:Ast.mod_items) 
    : unit = 
  let cx = new_ctxt sess abi in 
  let (scopes:scope Stack.t) = Stack.create () in 
  let passnum = ref 0 in
  let run_pass p = 
    Walk.walk_mod_items 
      (pass_logging_visitor cx (!passnum) p) 
      items;
    incr passnum
  in
  let visitors = 
    [|
      [|
        (block_scope_forming_visitor cx 
           (decl_stmt_collecting_visitor cx 
              (all_item_collecting_visitor cx
                 Walk.empty_visitor)));
        (scope_stack_managing_visitor scopes 
           (slot_resolving_visitor cx scopes 
              (lval_base_resolving_visitor cx scopes             
                 Walk.empty_visitor)));
        (alias_analysis_visitor cx
         Walk.empty_visitor);
      |];
      [|
        (layout_visitor cx
           Walk.empty_visitor)
      |];
    |]
  in
    Array.iter run_pass visitors.(0);
    infer_autos cx items;
    Array.iter run_pass visitors.(1);
;;
            

(*
 **************************************************************************
 * Previous resolve pass below this line
 *************************************************************************
 *)

(*

type ctxt = 
	{ ctxt_frame_scopes: Ast.frame list;
	  ctxt_type_scopes: Ast.mod_type_items list;
	  ctxt_id: node_id option;
	  ctxt_sess: Session.sess;
	  ctxt_made_progress: bool ref;
	  ctxt_contains_autos: bool ref;
	  ctxt_contains_un_laid_out_frames: bool ref;
	  ctxt_contains_unresolved_types: bool ref;
	  ctxt_abi: Abi.abi }
;;

let	new_ctxt sess abi = 
  { ctxt_frame_scopes = []; 
	ctxt_type_scopes = [];
	ctxt_id = None;
	ctxt_sess = sess;
	ctxt_made_progress = ref true;
    ctxt_contains_autos = ref false;
    ctxt_contains_un_laid_out_frames = ref false;
    ctxt_contains_unresolved_types = ref false;
	ctxt_abi = abi }
;;




let join_array sep arr = 
  let s = ref "" in
	for i = 0 to Array.length arr do
	  if i = 0
	  then s := arr.(i)
	  else s := (!s) ^ sep ^ arr.(i)
	done;
	(!s)
;;

let string_of_key k = 
  match k with 
      Ast.KEY_temp i -> "<temp#" ^ (string_of_int i) ^ ">"
    | Ast.KEY_ident i -> i
;;

let rec string_of_name_component comp = 
  match comp with 
	  Ast.COMP_ident id -> id
	| Ast.COMP_app (id, tys) -> 
		id ^ "[" ^ (join_array "," (Array.map string_of_ty tys)) ^ "]"
	| Ast.COMP_idx i -> 
		"{" ^ (string_of_int i) ^ "}"

and string_of_name name = 
  match name with 
	  Ast.NAME_base (Ast.BASE_ident id) -> id
	| Ast.NAME_base (Ast.BASE_temp n) -> "<temp#" ^ (string_of_int n) ^ ">"
	| Ast.NAME_base (Ast.BASE_app (id, tys)) -> 
		id ^ "[" ^ (join_array "," (Array.map string_of_ty tys)) ^ "]"
	| Ast.NAME_ext (n, c) -> 
		(string_of_name n) ^ "." ^ (string_of_name_component c)

and string_of_ty ty = 
  (* FIXME: possibly flesh this out, though it's just diagnostic. *)
  match ty with 
      Ast.TY_any -> "any"
    | Ast.TY_nil -> "nil"
    | Ast.TY_bool -> "bool"
    | Ast.TY_mach _ -> "mach"
    | Ast.TY_int -> "int"
    | Ast.TY_char -> "char"
    | Ast.TY_str -> "str"

    | Ast.TY_tup _ -> "tup"
    | Ast.TY_vec _ -> "vec"
    | Ast.TY_rec _ -> "rec"

    | Ast.TY_tag _ -> "tag"
    | Ast.TY_iso _ -> "iso"
    | Ast.TY_idx _ -> "idx"

    | Ast.TY_fn _ -> "fn"
    | Ast.TY_chan _ -> "chan"
    | Ast.TY_port _ -> "port"
        
    | Ast.TY_mod _ -> "mod"
    | Ast.TY_prog _ -> "prog"

    | Ast.TY_opaque _ -> "opaque"
    | Ast.TY_named name -> "named:" ^ (string_of_name name)
    | Ast.TY_type -> "ty"
      
    | Ast.TY_constrained _ -> "constrained"
    | Ast.TY_lim _ -> "lim"
;;

let rec size_of_ty cx t = 
  match t with 
	  Ast.TY_nil -> 0L
	| Ast.TY_bool -> 1L
	| Ast.TY_mach (_, n) -> Int64.of_int (n / 8)
	| Ast.TY_int -> cx.ctxt_abi.Abi.abi_ptr_sz
	| Ast.TY_char -> 4L
	| Ast.TY_str -> cx.ctxt_abi.Abi.abi_ptr_sz
	| Ast.TY_tup tys -> (Array.fold_left (fun n ty -> Int64.add n (slot_size cx ty)) 0L tys)
	| _ -> raise (err cx "unhandled type in size_of_ty")

and slot_size cx s = 
  match s with 
	  Ast.SLOT_exterior _ -> cx.ctxt_abi.Abi.abi_ptr_sz
	| Ast.SLOT_read_alias _ -> cx.ctxt_abi.Abi.abi_ptr_sz
	| Ast.SLOT_write_alias _ -> cx.ctxt_abi.Abi.abi_ptr_sz
	| Ast.SLOT_interior t -> size_of_ty cx t
	| Ast.SLOT_auto -> raise Auto_slot
;;

let slot_type cx s = 
  match s with 
	  Ast.SLOT_exterior t -> Some t
	| Ast.SLOT_read_alias t -> Some t
	| Ast.SLOT_write_alias t -> Some t
	| Ast.SLOT_interior t -> Some t
	| Ast.SLOT_auto -> None
;;

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
			Hashtbl.add htab ident { node = item'; 
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
  let add n i = Hashtbl.add ty_items n (mod_type_item_of_mod_item i) in
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

and lval_type cx lval =
  match !(lval.Ast.lval_res.Ast.res_target) with 
      Some (Ast.RES_slot local) -> slot_type cx !(local.Ast.local_slot.node)
    | Some (Ast.RES_item item) -> Some (type_of_mod_item cx item)
| _ -> None

and atom_type cx atom = 
  let concretize tyo = 
    match tyo with 
        Some (Ast.TY_named _) -> None
      | Some t -> Some t
      | None -> None
  in
    match atom with 
        Ast.ATOM_lval lv -> concretize (lval_type cx lv)
      | Ast.ATOM_literal lit -> 
		  (match lit.node with 
			   Ast.LIT_nil -> Some Ast.TY_nil
		     | Ast.LIT_bool _ -> Some Ast.TY_bool
		     | Ast.LIT_unsigned (n, _) -> Some (Ast.TY_mach (Ast.TY_unsigned, n))
		     | Ast.LIT_signed (n, _) -> Some (Ast.TY_mach (Ast.TY_signed, n))
		     | Ast.LIT_ieee_bfp _ -> Some (Ast.TY_mach (Ast.TY_ieee_bfp, 64))
		     | Ast.LIT_ieee_dfp _ -> Some (Ast.TY_mach (Ast.TY_ieee_dfp, 128))
		     | Ast.LIT_int _ -> Some Ast.TY_int
		     | Ast.LIT_char _ -> Some Ast.TY_char
		     | Ast.LIT_str _ -> Some Ast.TY_str
		     | Ast.LIT_custom _ -> None)

and expr_type cx expr = 
    match expr with 
	    Ast.EXPR_atom atom -> atom_type cx atom
		    
	  (* FIXME: check appropriateness of applying op to type *)
	  | Ast.EXPR_binary (op, a, b) -> 
		  (match (atom_type cx a, atom_type cx b) with 
			   (Some t1, Some t2) -> 
			     if t1 = t2 
			     then 
                   match op with 
                       Ast.BINOP_eq | Ast.BINOP_ne
                     | Ast.BINOP_lt | Ast.BINOP_le
                     | Ast.BINOP_gt | Ast.BINOP_ge -> Some Ast.TY_bool
                     | _ -> Some t1
			     else raise (err cx ("mismatched binary expression types in expr_type: "
                                     ^ (string_of_ty t1) ^ " vs. " ^ (string_of_ty t2)))
		     | _ -> (cx.ctxt_contains_unresolved_types := true; None))
            
	  | Ast.EXPR_unary (_, atom) -> atom_type cx atom
	  | _ -> raise (err cx "unhandled expression type in expr_type")

and lval_fn_result_type cx fn =
  let rec f ty = 
    match ty with 
        Ast.TY_fn f -> 
          let slot = f.Ast.fn_sig.Ast.sig_output_slot in
            slot_type cx slot
      | Ast.TY_lim t -> f t
      | _ -> raise (err cx "non-function type in function context")
  in
    match lval_type cx fn with 
        Some t -> 
          let ft = f t in
          let s = (match ft with None -> "<none>" | Some t -> string_of_ty t) in
            log cx "function return type: %s" s;
            ft
      | _ -> None

and lval_fn_arg_type cx fn i = 
  let badcount = "argument-count mismatch in lval_fn_arg_type" in
  let rec f ty = 
    match ty with 
        Ast.TY_fn f -> 
          let slot = f.Ast.fn_sig.Ast.sig_input_slot in
            (match slot_type cx slot with
                 None -> None
               | Some (Ast.TY_tup tup) -> 
                   (if i >= 0 or i < Array.length tup
                    then slot_type cx tup.(i)
                    else raise (err cx badcount))
               | Some t -> 
                   (if i = 0 
                    then Some t
                    else raise (err cx badcount)))
      | _ -> raise (err cx "non-function type in lval_fn_arg_type")
  in
    match lval_type cx fn with 
        Some ty -> f ty
      | _ -> None

and layout_frame_inner
    (cx:ctxt)
    (heavy:bool)
    (frame_off:int64)
    (frame_sz:int64)
    (frame_layout:layout)
    (slots:(Ast.slot_key * Ast.local) array)
    : unit = 
      log cx "beginning%s frame layout for %Ld byte frame @ %Ld (done: %b)" 
        (if heavy then " heavy" else " light") frame_sz frame_off frame_layout.layout_done;
      let off = ref 0L in 
	    frame_layout.layout_size <- frame_sz;
        frame_layout.layout_offset <- frame_off;
	    for i = 0 to (Array.length slots) - 1 do          
		  let (key, local) = slots.(i) in
          let layout = local.Ast.local_layout in 
            log cx "laying out slot %d (%s)" i (string_of_key key);
		    let sz = slot_size cx (!(local.Ast.local_slot.node)) in
              log cx "  == %Ld bytes @ %Ld" sz (!off);
              layout.layout_size <- sz;
              layout.layout_offset <- (!off);
              layout.layout_done <- true;
              off := Int64.add (!off) sz
        done;
        if not frame_layout.layout_done 
        then 
          begin
            log cx "setting layout_done <- true";
            frame_layout.layout_done <- true;
            cx.ctxt_made_progress := true
          end
        else
          log cx "layout was already done"
  

and layout_frame 
	(cx:ctxt) 
	(frame:Ast.frame) 
	: unit = 
  try 
    let slots_sz slots = 
      Array.fold_left 
        (fun x (_,local) -> 
           Int64.add x (slot_size cx (!(local.Ast.local_slot.node)))) 
        0L slots
    in
      match frame with 
          Ast.FRAME_light lf -> 
            begin
              let _ = 
                Hashtbl.iter 
                  (fun k local -> resolve_slot_ref cx None local.Ast.local_slot) 
                  lf.Ast.light_frame_locals
              in
              let slots = 
                Array.of_list 
	              (Sort.list 
                     (fun (a, _) (b, _) -> a < b)
                     (List.filter 
                        (fun (k,local) -> not (should_use_vreg cx local))
                        (htab_pairs lf.Ast.light_frame_locals)))
              in
              let sz = slots_sz slots in 
              let offset = 
                match cx.ctxt_frame_scopes with 
                    [] -> 0L
                  | x::_ -> 
                      begin 
                        match x with 
                            Ast.FRAME_heavy hf -> 0L
                          | Ast.FRAME_light lf ->                               
                              let layout = lf.Ast.light_frame_layout in                            
                                if layout.layout_done
                                then (Int64.sub layout.layout_offset sz)
                                else raise Un_laid_out_frame
                      end
              in
                layout_frame_inner cx false offset sz lf.Ast.light_frame_layout slots
            end
        | Ast.FRAME_heavy hf -> 
            let offset = 
              Int64.add 
                cx.ctxt_abi.Abi.abi_frame_base_sz 
                cx.ctxt_abi.Abi.abi_implicit_args_sz 
            in
            let _ = 
              List.iter 
                (fun (_,local) -> resolve_slot_ref cx None local.Ast.local_slot) 
                (!(hf.Ast.heavy_frame_arg_slots))
            in
            let slots = 
              Array.of_list (List.map 
                               (fun (k,v) -> (Ast.KEY_ident k, v))
                               (!(hf.Ast.heavy_frame_arg_slots)))
            in
              layout_frame_inner cx true offset (slots_sz slots) hf.Ast.heavy_frame_layout slots
  with 
	  Auto_slot -> 
        log cx "hit auto slot";
		cx.ctxt_contains_autos := true
          
    | Un_laid_out_frame -> 
        log cx "hit un-laid-out frame";
        cx.ctxt_contains_un_laid_out_frames := true
          
and extend_ctxt_by_frame 
	(cx:ctxt)
	(items:(Ast.ident * Ast.mod_item) array)
	: ctxt = 
  (* 
   * FIXME: frames for type parameters (which is what these are) are
   * totally broken and need reworking into a sane part of the ABI.
   *)
  log cx "extending ctxt by frame";
  let items' = Hashtbl.create (Array.length items) in
	for i = 0 to (Array.length items) - 1
	do
	  let (ident, item) = items.(i) in 
		Hashtbl.add items' ident (new_layout(), item)
	done;
    let light = { Ast.light_frame_layout = new_layout();
		          Ast.light_frame_locals = Hashtbl.create 0;
		          Ast.light_frame_items = items'; }
    in
    let frame = Ast.FRAME_light light in        
      light.Ast.light_frame_layout.layout_done <- true;
	  { cx with ctxt_frame_scopes = (frame :: cx.ctxt_frame_scopes) }
        
        
and resolve_mod_items cx items = 
  let cx = extend_ctxt_by_frame cx (linearize_items_for_frame items) in
	Hashtbl.iter (resolve_mod_item cx) items

		  
and resolve_mod_item cx id item =
  log cx "resolving mod item %s" id;
  let id = item.id in
	match item.node with 
		Ast.MOD_ITEM_mod md ->
		  let cx = param_ctxt cx md.Ast.decl_params id in
			resolve_mod_items cx md.Ast.decl_item
			  
	  | Ast.MOD_ITEM_prog pd -> 
		  let cx = param_ctxt cx pd.Ast.decl_params id in
			resolve_prog cx pd.Ast.decl_item

	  | Ast.MOD_ITEM_fn fn -> 
		  let cx = param_ctxt cx fn.Ast.decl_params id in
			resolve_fn id cx fn.Ast.decl_item

	  | _ -> ()

and new_local (slot:(Ast.slot ref) identified) = 
  { Ast.local_layout = new_layout();
    Ast.local_slot = slot;
    Ast.local_aliased = ref false;
    Ast.local_vreg = ref None; }

and resolve_fn id cx fn = 
  let cx = 
	{ cx with ctxt_frame_scopes = 
		(Ast.FRAME_heavy fn.Ast.fn_frame) :: cx.ctxt_frame_scopes } 
  in
	resolve_block cx fn.Ast.fn_body;
    layout_frame cx (Ast.FRAME_heavy fn.Ast.fn_frame);
    (* FIXME: ret/put slots are a mess. Clean up. *)
    let outslot = 
      resolve_slot cx None fn.Ast.fn_ty.Ast.fn_sig.Ast.sig_output_slot        
    in
    let outslotr = { node=ref outslot; id=id} in
    let outlocal = new_local outslotr in 
    let outlayout = outlocal.Ast.local_layout in 
      outlayout.layout_size <- slot_size cx outslot;
      outlayout.layout_offset <-  cx.ctxt_abi.Abi.abi_frame_base_sz;
      fn.Ast.fn_frame.Ast.heavy_frame_out_slot := Some outlocal
              
		    
and resolve_prog cx prog = 
  let items = prog.Ast.prog_mod in
  let cx = extend_ctxt_by_frame cx (linearize_items_for_frame items) in
	Hashtbl.iter (resolve_mod_item cx) items;
	resolve_init cx prog.Ast.prog_init;
  	resolve_block_option cx prog.Ast.prog_main;
  	resolve_block_option cx prog.Ast.prog_fini;


and resolve_init cx init = 
  ()


and resolve_block cx (block:Ast.block) = 
  let cx' = 
	{ cx with ctxt_frame_scopes = 
		(Ast.FRAME_light block.node.Ast.block_frame) :: cx.ctxt_frame_scopes } 
  in
    log cx "resolving block with %d items, %d slots"
	  (Hashtbl.length block.node.Ast.block_frame.Ast.light_frame_items)
	  (Hashtbl.length block.node.Ast.block_frame.Ast.light_frame_locals);
	Array.iter (resolve_stmt cx') block.node.Ast.block_stmts;
	layout_frame cx (Ast.FRAME_light block.node.Ast.block_frame)

and resolve_slot 
    (cx:ctxt) 
    (tyo:Ast.ty option) 
    (slot:Ast.slot) 
    : Ast.slot = 
  let resolve_and_check_type ty = 
    let ty = resolve_ty cx ty in
      match tyo with 
          None -> ty
        | Some t -> 
            if ty = t
            then ty
            else raise (err cx ("mismatched types in resolve_slot: slot is " 
                                ^ (string_of_ty ty) 
                                ^ " constraint implies " 
                                ^ (string_of_ty t)))
  in
    match slot with 
	  Ast.SLOT_exterior ty -> 
        Ast.SLOT_exterior (resolve_and_check_type ty)
	| Ast.SLOT_interior ty -> 
        Ast.SLOT_interior (resolve_and_check_type ty)
	| Ast.SLOT_read_alias ty -> 
        Ast.SLOT_read_alias (resolve_and_check_type ty)
	| Ast.SLOT_write_alias ty -> 
        Ast.SLOT_write_alias (resolve_and_check_type ty)
	| Ast.SLOT_auto -> 
        (match tyo with 
             None -> Ast.SLOT_auto
           | Some t -> Ast.SLOT_interior t)

and resolve_slot_ref 
    (cx:ctxt) 
    (tyo:Ast.ty option) 
    (slotr:(Ast.slot ref) identified) 
    : unit = 
  let slot = !(slotr.node) in
  let newslot = resolve_slot cx tyo slot in
    if slot = newslot
    then ()
    else (log cx "----- made progress ----";
          cx.ctxt_made_progress := true;
          slotr.node := newslot)
  
and resolve_ty 
    (cx:ctxt)
    (t:Ast.ty)
    : Ast.ty = 
  match t with 
	  Ast.TY_any | Ast.TY_nil | Ast.TY_bool 
    | Ast.TY_mach _ | Ast.TY_int | Ast.TY_char
	| Ast.TY_str | Ast.TY_opaque _ -> t

	| Ast.TY_tup tt ->
        Ast.TY_tup (Array.map (resolve_slot cx None) tt)
	| Ast.TY_vec t -> 
        Ast.TY_vec (resolve_ty cx t)
	| Ast.TY_rec tr ->
        let newt = Hashtbl.create (Hashtbl.length tr) in
          (Hashtbl.iter (fun k s -> Hashtbl.add newt k (resolve_slot cx None s)) tr;
           Ast.TY_rec newt)
	| Ast.TY_chan t -> 
        Ast.TY_chan (resolve_ty cx t)
	| Ast.TY_port t -> 
        Ast.TY_port (resolve_ty cx t)
		  
	| Ast.TY_named nm ->
		let
			(cx, defn) = lookup_type cx nm
		in
		  resolve_ty cx defn

	(* 
	   | Ast.TY_fn tfn -> ()
	   | Ast.TY_tag of ty_tag
	   | Ast.TY_iso of ty_iso
	   | Ast.TY_idx of int
	   
	   | Ast.TY_constrained (t, cstrs)
	   | Ast.TY_mod items -> ()
	   | Ast.TY_prog tp -> ()
	   | Ast.TY_lim t -> ()
	*)

	| _ -> raise (err cx "unhandled type in resolve_ty")
		
		
and resolve_expr cx expr = 
  match expr with 
	  Ast.EXPR_binary (_, a, b) -> 
		resolve_atom cx None a;
		resolve_atom cx None b
	| Ast.EXPR_unary (_, e) -> 
		resolve_atom cx None e
	| Ast.EXPR_atom atom -> 
		resolve_atom cx None atom
	| Ast.EXPR_rec htab -> 
		Hashtbl.iter (fun _ lv -> resolve_atom cx None lv) htab
	| Ast.EXPR_vec v -> 
		Array.iter (resolve_atom cx None) v
	| Ast.EXPR_tup v -> 
		Array.iter (resolve_atom cx None) v
		  

and resolve_atom cx tyo atom = 
  match atom with 
      Ast.ATOM_literal _ -> ()
    | Ast.ATOM_lval lv -> resolve_lval cx tyo lv


and resolve_lval cx tyo lval = 
  let bind_to_slot pathopt local = 
    lval.Ast.lval_res.Ast.res_path := pathopt;
    lval.Ast.lval_res.Ast.res_target := Some (Ast.RES_slot local);
    resolve_slot_ref cx tyo local.Ast.local_slot
  in
  let bind_to_item pathopt item = 
    lval.Ast.lval_res.Ast.res_path := pathopt;
    lval.Ast.lval_res.Ast.res_target := Some (Ast.RES_item item)
  in
    match !(lval.Ast.lval_res.Ast.res_path) with 
        Some pth -> 
          begin 
            match !(lval.Ast.lval_res.Ast.res_target) with
                Some (Ast.RES_slot local) -> resolve_slot_ref cx tyo local.Ast.local_slot
              | Some (Ast.RES_item _) -> ()
              | None -> raise (err cx "lval path resolved but no target?")
          end
      | None -> 
          begin
	        match lval.Ast.lval_src.node with 
	          | Ast.LVAL_base base -> 
                  let _ = 
                    begin
                      match !(lval.Ast.lval_res.Ast.res_target) with 
                          None -> log cx "first-pass resolving lval: %s" (string_of_base cx base)
                        | Some _ -> log cx "Nth-pass resolving lval: %s" (string_of_base cx base)
                    end
                  in
		          let (_, binding) = lookup_base cx base in
                    log cx "resolved lval: %s" (string_of_base cx base);
                    begin
			          match binding with 
				          BINDING_item (pathopt, item) -> bind_to_item pathopt item
			            | BINDING_slot (pathopt, local) -> bind_to_slot pathopt local
			            | BINDING_type_item _ -> 
				            raise (err cx ("lval '" ^ (string_of_base cx base) ^ "' resolved to a type name"))
                    end
	          | _ -> raise (err cx ("unhandled lval form in resolve_lval"))
          end

and resolve_block_option cx (blockopt:Ast.block option) = 
  match blockopt with 
	  None -> ()
	| Some s -> resolve_block cx s


and resolve_expr_option cx expropt = 
  match expropt with 
	  None -> ()
	| Some e -> resolve_expr cx e

and resolve_lval_option cx lopt = 
  match lopt with 
	  None -> ()
	| Some lv -> resolve_lval cx None lv

and resolve_atom_option cx aopt = 
  match aopt with 
	  None -> ()
	| Some atom -> resolve_atom cx None atom

and resolve_stmts cx stmts = 
  Array.iter (resolve_stmt cx) stmts
		
and resolve_stmt cx stmt = 
  let cx = { cx with ctxt_id = Some stmt.id } in
  match stmt.node with 
	  Ast.STMT_log a -> 
		  resolve_atom cx None a

	| Ast.STMT_while w -> 
		let (stmts, atom) = w.Ast.while_lval in
		  resolve_atom cx (Some Ast.TY_bool) atom;
		  resolve_stmts cx stmts;
		  resolve_block cx w.Ast.while_body

	| Ast.STMT_do_while w -> 
		let (stmts, atom) = w.Ast.while_lval in
		  resolve_atom cx (Some Ast.TY_bool) atom;
		  resolve_stmts cx stmts;
		  resolve_block cx w.Ast.while_body

	| Ast.STMT_foreach f -> 
		(* FIXME: foreaches are a bit wrong at the moment. *)
		let (fn, args) = f.Ast.foreach_call in
		  resolve_lval cx None fn;
		  Array.iter (resolve_lval cx None) args;
		  let cx' = 
			{ cx with ctxt_frame_scopes = 
				(Ast.FRAME_light f.Ast.foreach_frame) :: cx.ctxt_frame_scopes } 
		  in
			layout_frame cx (Ast.FRAME_light f.Ast.foreach_frame);
			resolve_block cx' f.Ast.foreach_body;
			()
			  
	| Ast.STMT_for f -> 
		resolve_stmt cx f.Ast.for_init;
		let cx' = 
		  { cx with ctxt_frame_scopes =
			  (Ast.FRAME_light f.Ast.for_frame) :: cx.ctxt_frame_scopes }
		in
		let (stmts, atom) = f.Ast.for_test in
		  layout_frame cx (Ast.FRAME_light f.Ast.for_frame);
		  resolve_stmts cx' stmts;
		  resolve_atom cx' (Some Ast.TY_bool) atom;
		  resolve_stmt cx' f.Ast.for_step;
		  resolve_stmt cx' f.Ast.for_body;

	| Ast.STMT_if i -> 
		resolve_atom cx (Some Ast.TY_bool) i.Ast.if_test;
		resolve_block cx i.Ast.if_then;
		resolve_block_option cx i.Ast.if_else

	| Ast.STMT_try t -> 
		resolve_block cx t.Ast.try_body;
		resolve_block_option cx t.Ast.try_fail;
		resolve_block_option cx t.Ast.try_fini
		
	| Ast.STMT_put (_, lo) -> 
		resolve_atom_option cx lo

	| Ast.STMT_ret (_, lo) -> 
		resolve_atom_option cx lo

	| Ast.STMT_block b -> 
		resolve_block cx b

	| Ast.STMT_decl d -> 
		(match d with 
			 Ast.DECL_mod_item (id, item) -> 
			   resolve_mod_item cx id item
				 
		   | Ast.DECL_slot (key, slot) -> 
			   resolve_slot_ref cx None slot)
			
	| Ast.STMT_copy (lval, expr) -> 
		resolve_expr cx expr;
		resolve_lval cx (expr_type cx expr) lval;
		  
	| Ast.STMT_call (dst, fn, args) -> 
		resolve_lval cx None fn;
		Array.iteri (fun i -> resolve_atom cx (lval_fn_arg_type cx fn i)) args;
		resolve_lval cx (lval_fn_result_type cx fn) dst

	(* 
	   | Ast.STMT_alt_tag of stmt_alt_tag
	   | Ast.STMT_alt_type of stmt_alt_type
	   | Ast.STMT_alt_port of stmt_alt_port
	   | Ast.STMT_prove of (constrs)
	   | Ast.STMT_check of (constrs)
	   | Ast.STMT_checkif of (constrs * stmt)
	   | Ast.STMT_send _ -> ()
	   | Ast.STMT_recv _ -> ()
	   | Ast.STMT_use (ty, ident, lval) 
	*)
	| _ -> ()

let resolve_crate 
    (sess:Session.sess) 
    (abi:Abi.abi) 
    (items:Ast.mod_items) 
    : unit = 
  try 
    let cx = new_ctxt sess abi in
	  while !(cx.ctxt_made_progress) do
        log cx "";
        log cx "=== fresh resolution pass ===";
        cx.ctxt_contains_autos := false;
        cx.ctxt_contains_unresolved_types := false;
        cx.ctxt_contains_un_laid_out_frames := false;
        cx.ctxt_made_progress := false;
	    resolve_mod_items cx items;
	  done;
      if !(cx.ctxt_contains_autos) or
        !(cx.ctxt_contains_unresolved_types) or
        !(cx.ctxt_contains_un_laid_out_frames)
      then 
        raise (err cx "progress ceased, but crate incomplete")
      else ()
  with 
	  Semant_err (ido, str) -> 
        begin
          let spano = match ido with 
              None -> None
            | Some id -> (Session.get_span sess id)
          in            
		  match spano with 
			  None -> 
                Session.fail sess "Resolve error: %s\n%!" str
		    | Some span -> 			  
			    Session.fail sess "%s:E:Resolve error: %s\n%!" 
                  (Session.string_of_span span) str
        end
;;
*)

(* 
 * Local Variables:
 * fill-column: 70; 
 * indent-tabs-mode: nil
 * compile-command: "make -k -C .. 2>&1 | sed -e 's/\\/x\\//x:\\//g'"; 
 * End:
 *)
