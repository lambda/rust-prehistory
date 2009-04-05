(* Translation *)

open Semant;;
open Common;;

let log cx = Session.log "trans"
  cx.ctxt_sess.Session.sess_log_trans
  cx.ctxt_sess.Session.sess_log_out
;;

let marker = Il.Imm (Asm.IMM 0xdeadbeefL);;
let imm_true = Il.Imm (Asm.IMM 1L);;
let imm_false = Il.Imm (Asm.IMM 0L);;
let badlab = Il.Label (-1);;

let trans_visitor
    (cx:ctxt)
    (inner:Walk.visitor)
    : Walk.visitor =
  let path = Stack.create () in
  let block_layouts = Stack.create () in
  let file = ref None in

  let emitters = Stack.create () in
  let push_new_emitter _ =
    Stack.push
      (Il.new_emitter
         cx.ctxt_abi.Abi.abi_prealloc_quad
         cx.ctxt_abi.Abi.abi_is_2addr_machine)
      emitters
  in
  let pop_emitter _ = ignore (Stack.pop emitters) in
  let emitter _ = Stack.top emitters in
  let emit op dst lhs rhs = Il.emit (emitter()) op dst lhs rhs in
  let mark _ : int = (emitter()).Il.emit_pc in
  let patch (i:int) : unit =
    (emitter()).Il.emit_quads.(i)
    <- { (emitter()).Il.emit_quads.(i)
         with Il.quad_lhs = Il.Label (mark ()) };
    (* Insert a dead quad to ensure there's an otherwise-unused patch target here. *)
    emit Il.DEAD Il.Nil Il.Nil Il.Nil
  in

  let epilogue_jumps = Stack.create() in


  let lval_to_referent (id:node_id) : node_id =
    if Hashtbl.mem cx.ctxt_lval_to_referent id
    then Hashtbl.find cx.ctxt_lval_to_referent id
    else err (Some id) "Unresolved lval"
  in

  let lval_to_slot (id:node_id) : Ast.slot =
    let referent = lval_to_referent id in
      if Hashtbl.mem cx.ctxt_all_slots referent
      then Hashtbl.find cx.ctxt_all_slots referent
      else err (Some referent) "Unknown slot"
  in

  let get_block_layout (id:node_id) : layout =
    if Hashtbl.mem cx.ctxt_block_layouts id
    then Hashtbl.find cx.ctxt_block_layouts id
    else err (Some id) "Unknown block layout"
  in

  let get_fn_fixup (id:node_id) : fixup =
    if Hashtbl.mem cx.ctxt_fn_fixups id
    then Hashtbl.find cx.ctxt_fn_fixups id
    else err (Some id) "Fn without fixup"
  in

  let get_prog_fixup (id:node_id) : fixup =
    if Hashtbl.mem cx.ctxt_prog_fixups id
    then Hashtbl.find cx.ctxt_prog_fixups id
    else err (Some id) "Prog without fixup"
  in

  let get_framesz (id:node_id) : int64 =
    if Hashtbl.mem cx.ctxt_frame_sizes id
    then Hashtbl.find cx.ctxt_frame_sizes id
    else err (Some id) "Missing framesz"
  in

  let path_name (_:unit) : string =
    String.concat "." (stk_elts_from_bot path)
  in

  let layout_rec (atab:Ast.ty_rec) : ((Ast.ident * (Ast.slot * layout)) array) =
    let layouts = Array.map (fun (_,slot) -> layout_slot cx.ctxt_abi 0L slot) atab in
      begin
        ignore (pack 0L layouts);
        assert ((Array.length layouts) = (Array.length atab));
        Array.mapi (fun i layout ->
                      let (ident, slot) = atab.(i) in
                        (ident, (slot, layout))) layouts
      end
  in

  let layout_tup (tup:Ast.ty_tup) : (layout array) =
    let layouts = Array.map (layout_slot cx.ctxt_abi 0L) tup in
      ignore (pack 0L layouts);
      layouts
  in

  let force_to_reg operand =
    match operand with
        Il.Reg r -> r
      | Il.Imm _ | Il.Mem _ ->
          let tmp = (Il.next_vreg (emitter())) in
            emit Il.UMOV (Il.Reg tmp) operand Il.Nil;
            tmp
      | _ -> err None "unhandled operand type in force_to_reg"
  in

  let rec trans_lval_full
      (lv:Ast.lval)
      (pcrel_ok:bool)
      (imm_ok:bool)
      : (Il.operand * Ast.slot * node_id) =

    let return_fixup fix =
      if pcrel_ok
      then Il.Pcrel fix
      else
        let imm = (Il.Imm (Asm.M_POS fix)) in
          if imm_ok
          then imm
          else Il.Reg (force_to_reg imm)
    in

      match lv with
          Ast.LVAL_ext (base, comp) ->
            begin
              let (base_operand, base_slot, base_id) = trans_lval_full base false true in
              (* Most of the errors in this block shouldn't make it past typechecking. *)
              let bad _ = err (Some base_id) "bad lval extension in trans_lval_full" in
              let (base_reg, base_off) =
                match base_operand with
                    Il.Mem (_, Some r, off) -> (r,off)
                  | _ -> err (Some base_id) "lval-ext of non-mem operand in trans_lval_full"
              in
              let (operand, slot) =
                match comp with
                    (Ast.COMP_named (Ast.COMP_ident id)) ->
                      begin
                        match base_slot.Ast.slot_ty with
                            Some (Ast.TY_rec entries) ->
                              let layouts = layout_rec entries in
                                begin
                                  match atab_search layouts id with
                                      None -> bad ()
                                    | Some (slot, layout) ->
                                        (Il.Mem (Il.M32, (Some base_reg),
                                                 Asm.ADD (base_off, Asm.IMM layout.layout_offset)),
                                         slot)
                                end
                          | _ -> bad ()
                      end

                  | (Ast.COMP_named (Ast.COMP_idx i)) ->
                      begin
                        match base_slot.Ast.slot_ty with
                            Some (Ast.TY_tup entries) ->
                              let layouts = layout_tup entries in
                                if i < 0 || i >= Array.length layouts
                                then bad ()
                                else
                                  (Il.Mem (Il.M32, (Some base_reg),
                                           Asm.ADD (base_off, Asm.IMM layouts.(i).layout_offset)),
                                   entries.(i))
                          | _ -> bad ()
                      end
                  | _ -> err None "unhandled form of lval_ext in trans_lval_full"
              in
                (operand, slot, base_id)
            end

        | Ast.LVAL_base nb ->
            let referent = lval_to_referent nb.id in
              begin
                match htab_search cx.ctxt_all_items referent with
                  Some item ->
                    begin
                      let ty = ty_of_mod_item { node=item; id=referent; } in
                      let slot = { Ast.slot_mode = Ast.MODE_read_alias;
                                   Ast.slot_ty = Some ty }
                      in
                        match item with
                            Ast.MOD_ITEM_fn _ ->
                              (return_fixup (get_fn_fixup referent), slot, nb.id)
                          | Ast.MOD_ITEM_prog _ ->
                              (return_fixup (get_prog_fixup referent), slot, nb.id)
                          | _ ->
                              err (Some nb.id)
                                "unhandled item type in trans_lval_full, item #%d"
                                (int_of_node referent)
                    end
                  | None ->
                    begin
                      let slot = lval_to_slot nb.id in
                      match htab_search cx.ctxt_slot_vregs referent with
                          Some vr ->
                            begin
                              let vreg =
                                match !vr with
                                    None ->
                                      begin
                                        let v = (Il.next_vreg_num (emitter())) in
                                          vr := Some v;
                                          v
                                      end
                                  | Some v -> v
                              in
                                (Il.Reg (Il.Vreg vreg), slot, nb.id)
                            end
                        | None ->
                            begin
                              match htab_search cx.ctxt_slot_layouts referent with
                                  None -> err (Some nb.id) "slot assigned to neither vreg nor layout"
                                | Some layout ->
                                    let operand =
                                      Il.Mem (Il.M32,
                                              (Some cx.ctxt_abi.Abi.abi_fp_reg),
                                              Asm.IMM layout.layout_offset)
                                    in
                                      (operand, slot, nb.id)
                            end
                    end
            end
  in

  let trans_lval (lv:Ast.lval) : (Il.operand * Ast.slot * node_id) =
    trans_lval_full lv false false
  in

  let rec atom_type (at:Ast.atom) : Ast.ty =
    match at with
        Ast.ATOM_literal {node=(Ast.LIT_str _); id=_} -> Ast.TY_str
      | Ast.ATOM_literal {node=(Ast.LIT_int _); id=_} -> Ast.TY_int
      | Ast.ATOM_literal {node=(Ast.LIT_bool _); id=_} -> Ast.TY_bool
      | Ast.ATOM_literal {node=(Ast.LIT_char _); id=_} -> Ast.TY_char
      | Ast.ATOM_literal {node=(Ast.LIT_nil); id=_} -> Ast.TY_nil
      | Ast.ATOM_literal _ -> err None "unhandled form of literal in atom_type"
      | Ast.ATOM_lval (Ast.LVAL_base nb) ->
          let slot = lval_to_slot nb.id in
            begin
              match slot.Ast.slot_ty with
                  None -> err (Some nb.id) "name refers to untyped slot, in atom_type"
                | Some t -> t
            end
      | Ast.ATOM_lval (Ast.LVAL_ext (base, comp)) ->
          let base_ty = atom_type (Ast.ATOM_lval base) in
          let need_ty topt =
            match topt with
                None -> err None "missing type in lval-ext"
              | Some s -> s
          in
            match (base_ty, comp) with
                (Ast.TY_rec elts, Ast.COMP_named (Ast.COMP_ident id)) ->
                  begin
                    match atab_search elts id with
                        Some slot -> need_ty slot.Ast.slot_ty
                      | None -> err None "unknown record-member '%s'" id
                  end

              | (Ast.TY_tup elts, Ast.COMP_named (Ast.COMP_idx i)) ->
                  if 0 <= i && i < (Array.length elts)
                  then need_ty elts.(i).Ast.slot_ty
                  else err None "out-of-range tuple index %d" i

              | (_,_) -> err None "unhandled form of lval-ext"
  in

  let trans_atom (atom:Ast.atom) : Il.operand =
    match atom with
        Ast.ATOM_lval lv ->
          let (operand, _, _) = trans_lval lv in
            operand

      | Ast.ATOM_literal lit ->
          begin
            match lit.node with
                Ast.LIT_nil ->
                  Il.Nil

              | Ast.LIT_bool false ->
                  Il.Imm (Asm.IMM 0L)

              | Ast.LIT_bool true ->
                  Il.Imm (Asm.IMM 1L)

              | Ast.LIT_char c ->
                  Il.Imm (Asm.IMM (Int64.of_int (Char.code c)))

              | Ast.LIT_int (bi, s) ->
                  Il.Imm (Asm.IMM (Int64.of_int (Big_int.int_of_big_int bi)))

              | Ast.LIT_str s ->
                  let strfix = new_fixup "string fixup" in
                  let str = Asm.DEF (strfix, Asm.ZSTRING s) in
                    cx.ctxt_data_items <- str :: cx.ctxt_data_items;
                    (Il.Imm (Asm.M_POS strfix))

              | _ -> marker
          end
  in

  let trans_expr (expr:Ast.expr) : Il.operand =

    match expr with

        Ast.EXPR_binary (binop, a, b) ->
          let lhs = trans_atom a in
          let rhs = trans_atom b in
          let dst = Il.Reg (Il.next_vreg (emitter())) in
          let arith op =
            emit op dst lhs rhs;
            dst
          in
          let rela cjmp =
            emit Il.CMP Il.Nil lhs rhs;
            emit Il.UMOV dst imm_true Il.Nil;
            let j = mark () in
              emit cjmp Il.Nil badlab Il.Nil;
              emit Il.UMOV dst imm_false Il.Nil;
              patch j;
              dst
          in
            begin
              match binop with
                  Ast.BINOP_or -> arith Il.OR
                | Ast.BINOP_and -> arith Il.AND

                | Ast.BINOP_lsl -> arith Il.LSL
                | Ast.BINOP_lsr -> arith Il.LSR
                | Ast.BINOP_asr -> arith Il.ASR

                | Ast.BINOP_add -> arith Il.ADD
                | Ast.BINOP_sub -> arith Il.SUB

                (* FIXME: switch on type of operands, IMUL/IDIV/IMOD etc. *)
                | Ast.BINOP_mul -> arith Il.UMUL
                | Ast.BINOP_div -> arith Il.UDIV
                | Ast.BINOP_mod -> arith Il.UMOD

                | Ast.BINOP_eq -> rela Il.JE
                | Ast.BINOP_ne -> rela Il.JNE
                | Ast.BINOP_lt -> rela Il.JL
                | Ast.BINOP_le -> rela Il.JLE
                | Ast.BINOP_ge -> rela Il.JGE
                | Ast.BINOP_gt -> rela Il.JG

                | _ -> err None "Unhandled binop of expr in trans_expr"
            end

      | Ast.EXPR_unary (unop, a) ->
          let src = trans_atom a in
          let dst = Il.Reg (Il.next_vreg (emitter())) in
          let op = match unop with
              Ast.UNOP_not -> Il.NOT
            | Ast.UNOP_neg -> Il.NEG
          in
            emit op dst src Il.Nil;
            dst

      | Ast.EXPR_atom a ->
          trans_atom a
  in

  let trans_1_arg_kern_fn (a:Ast.atom) (fn:int64) : unit =
    let v = trans_atom a in
    let dst = Il.Reg (Il.next_vreg (emitter())) in
    let pp = cx.ctxt_abi.Abi.abi_pp_operand in
    let sp = (Il.Reg cx.ctxt_abi.Abi.abi_sp_reg) in
      cx.ctxt_abi.Abi.abi_emit_proc_state_change (emitter()) Abi.STATE_calling_c;
      emit (Il.CPUSH Il.M32) Il.Nil v Il.Nil;
      emit (Il.CPUSH Il.M32) Il.Nil (Il.Imm (Asm.IMM fn)) Il.Nil;
      emit (Il.CPUSH Il.M32) Il.Nil pp Il.Nil;
      emit Il.CCALL dst (Il.Pcrel cx.ctxt_proc_to_c_fixup) Il.Nil;
      emit Il.ADD sp sp (Il.Imm (Asm.IMM 12L));
      ()
  in

  let trans_log_int (a:Ast.atom) : unit = trans_1_arg_kern_fn a 0L in
  let trans_log_str (a:Ast.atom) : unit = trans_1_arg_kern_fn a 1L in
  let trans_spawn (a:Ast.atom) : unit = trans_1_arg_kern_fn a 2L in

  let lea (dst:Il.operand) (src:Il.operand) : unit =
    match src with
        Il.Mem _ -> emit Il.LEA dst src Il.Nil
      | _ -> err None "LEA on non-memory operand"
  in

  let rec trans_block (block:Ast.block) : unit =
    Stack.push (get_block_layout block.id) block_layouts;
    Array.iter trans_stmt block.node;
    ignore (Stack.pop block_layouts)


  and trans_copy_full
      (dst:Il.operand) (dst_slot:Ast.slot) (dst_id:node_id)
      (src:Il.operand) (src_slot:Ast.slot) (src_id:node_id)
      : unit =
    assert (src_slot.Ast.slot_ty = dst_slot.Ast.slot_ty);
    match (dst, dst_slot.Ast.slot_ty,
           src, src_slot.Ast.slot_ty) with
        (Il.Mem (_, (Some dst_reg), dst_off), Some (Ast.TY_rec dst_slots),
         Il.Mem (_, (Some src_reg), src_off), Some (Ast.TY_rec src_slots)) ->
          let layouts = layout_rec src_slots in
            for i = 0 to (Array.length layouts) - 1
            do
              let (_, (_, layout)) = layouts.(i) in
              let off = Asm.IMM layout.layout_offset in
              let sub_src = Il.Mem (Il.M32, (Some src_reg), (Asm.ADD (off, src_off))) in
              let sub_dst = Il.Mem (Il.M32, (Some dst_reg), (Asm.ADD (off, dst_off))) in
              let (_, sub_src_slot) = src_slots.(i) in
              let (_, sub_dst_slot) = dst_slots.(i) in
              trans_copy_full
                sub_dst sub_dst_slot dst_id
                sub_src sub_src_slot src_id
            done

      | _ ->
          emit Il.UMOV dst src Il.Nil


  and trans_copy
      (dst:Ast.lval)
      (src:Ast.expr) : unit =
    match src with
        (Ast.EXPR_binary _) | (Ast.EXPR_unary _)
      | (Ast.EXPR_atom (Ast.ATOM_literal _)) ->
          (* Translations of both these expr types yield vregs, so copy
           * is just MOV into the lval. *)
          let (dst_operand, _, _) = trans_lval dst in
          let src_operand = trans_expr src in
            emit Il.UMOV dst_operand src_operand Il.Nil

      | Ast.EXPR_atom (Ast.ATOM_lval src_lval) ->
          (* Possibly-large structure copying *)
          let (dst_operand, dst_slot, dst_id) = trans_lval dst in
          let (src_operand, src_slot, src_id) = trans_lval src_lval in
            trans_copy_full
              dst_operand dst_slot dst_id
              src_operand src_slot src_id


  and trans_stmt (stmt:Ast.stmt) : unit =
    (* Helper to localize errors by stmt, at minimum. *)
    try
      trans_stmt_full stmt
    with
        Semant_err (None, msg) -> raise (Semant_err ((Some stmt.id), msg))


  and trans_stmt_full (stmt:Ast.stmt) : unit =
    match stmt.node with

        Ast.STMT_log a ->
          begin
            match atom_type a with
                Ast.TY_str -> trans_log_str a
              | Ast.TY_int -> trans_log_int a
              | _ -> err (Some stmt.id) "unimplemented logging type"
          end

      | Ast.STMT_spawn a -> trans_spawn a

      | Ast.STMT_copy (lv_dst, e_src) ->
          trans_copy lv_dst e_src

      | Ast.STMT_init_rec ((Ast.LVAL_base nb_dst), atab) ->
          let (dst_base, _, _) = trans_lval (Ast.LVAL_base nb_dst) in
          let slot = lval_to_slot nb_dst.id in
          let slots = match slot.Ast.slot_ty with
              Some (Ast.TY_rec slots) -> slots
            | Some _ -> err (Some stmt.id) "translating init of incorrectly-typed rec slot"
            | None -> err (Some stmt.id) "translating init of untyped rec slot"
          in
            (* 
             * This is still a totally incorrect translation. Only does
             * one-level (non-recursive) copying of records, only initializes
             * name-base lvals, ignores component types, etc. etc.
             *)
            begin
              match dst_base with
                  Il.Mem (Il.M32, reg, (Asm.IMM off)) ->
                    let layouts = layout_rec slots in
                      begin
                        assert ((Array.length layouts) = (Array.length atab));
                        Array.iteri
                          (fun i (_, v) ->
                             let (_, (_, layout)) = layouts.(i) in
                             let src = trans_atom v in
                             let off' = Asm.ADD (Asm.IMM off, Asm.IMM layout.layout_offset) in
                             let dst = Il.Mem (Il.M32, reg, off') in
                               emit Il.UMOV dst src Il.Nil)
                          atab
                      end
                | _ -> err (Some stmt.id) "translating init of non-memory record operand"
            end

      | Ast.STMT_block block ->
          trans_block block

      | Ast.STMT_while sw ->
          let back_jmp_target = mark () in
          let (head_stmts, head_atom) = sw.Ast.while_lval in
            Array.iter trans_stmt head_stmts;
            let v = trans_atom head_atom in
              emit Il.CMP Il.Nil v imm_false;
              let fwd_jmp_quad = mark () in
                emit Il.JE Il.Nil badlab Il.Nil;
                trans_block sw.Ast.while_body;
                emit Il.JMP Il.Nil (Il.Label back_jmp_target) Il.Nil;
                patch fwd_jmp_quad

      | Ast.STMT_if si ->
          let v = trans_atom si.Ast.if_test in
            emit Il.CMP Il.Nil v imm_true;
            let skip_thn_clause_jmp = mark () in
              emit Il.JNE Il.Nil badlab Il.Nil;
              trans_block si.Ast.if_then;
              begin
                match si.Ast.if_else with
                    None -> patch skip_thn_clause_jmp
                  | Some els ->
                      let skip_els_clause_jmp = mark () in
                        emit Il.JMP Il.Nil badlab Il.Nil;
                        patch skip_thn_clause_jmp;
                        trans_block els;
                        patch skip_els_clause_jmp
              end

      | Ast.STMT_call (dst, flv, args) ->
          let abi = cx.ctxt_abi in
          let vr = Il.Reg (Il.next_vreg (emitter())) in
          let sp = Il.Reg (abi.Abi.abi_sp_reg) in
          let (outmem, _, _) = trans_lval dst in
          let outptr = Il.Reg (Il.next_vreg (emitter())) in
          let (fv, _, _) = (trans_lval_full flv abi.Abi.abi_has_pcrel_jumps abi.Abi.abi_has_imm_jumps) in
            lea outptr outmem;
            (* FIXME: factor out call protocol into ABI bits. *)
            for i = (Array.length args) - 1 downto 0 do
              emit (Il.CPUSH Il.M32) Il.Nil (trans_atom args.(i)) Il.Nil
            done;
            (* Emit arg1: the process pointer. *)
            emit (Il.CPUSH Il.M32) Il.Nil (abi.Abi.abi_pp_operand) Il.Nil;
            (* Emit arg0: the output slot. *)
            emit (Il.CPUSH Il.M32) Il.Nil outptr Il.Nil;
            emit Il.CCALL vr fv Il.Nil;
            emit Il.ADD sp sp
              (Il.Imm (Asm.IMM (Int64.of_int (4 * (2 + (Array.length args))))));


      | Ast.STMT_ret (proto_opt, atom_opt) ->
          begin
          match proto_opt with
              None ->
                begin
                  begin
                    match atom_opt with
                        None -> ()
                      | Some at ->
                          let outmem =
                            Il.Mem (Il.M32, (Some cx.ctxt_abi.Abi.abi_fp_reg),
                                    (Asm.IMM (cx.ctxt_abi.Abi.abi_frame_base_sz)))
                          in
                          let outptr_reg = Il.next_vreg (emitter()) in
                          let deref_outptr = Il.Mem (Il.M32, (Some outptr_reg), Asm.IMM 0L) in
                            emit Il.UMOV (Il.Reg outptr_reg) outmem Il.Nil;
                            emit Il.UMOV deref_outptr (trans_atom at) Il.Nil
                  end;
                  Stack.push (mark()) (Stack.top epilogue_jumps);
                end;
                emit Il.JMP Il.Nil badlab Il.Nil
            | Some _ -> ()
          end

      | Ast.STMT_decl _ -> ()

      | _ -> err (Some stmt.id) "unhandled form of statement in trans_stmt"
  in

  let capture_emitted_quads (node:node_id) : unit =
    let e = emitter() in
    let n_vregs = e.Il.emit_next_vreg in
    let quads = e.Il.emit_quads in
    let name = path_name () in
    let f = match !file with
        None -> err (Some node) "Missing file scope when capturing quads."
      | Some f -> f
    in
    let file_list =
      begin
        if not (Hashtbl.mem cx.ctxt_texts f)
        then htab_put cx.ctxt_texts f (ref []);
        Hashtbl.find cx.ctxt_texts f
      end
    in
      begin
        log cx "emitted quads for %s:" name;
        for i = 0 to (Array.length quads) - 1
        do
          log cx "[%6d]\t%s" i (Il.string_of_quad cx.ctxt_abi.Abi.abi_str_of_hardreg quads.(i));
        done;
        let text = { text_node = node;
                     text_quads = quads;
                     text_n_vregs = n_vregs }
        in
          file_list := text :: (!file_list)
      end
  in

  let trans_fn (fnid:node_id) (fn:Ast.fn) : unit =
    let framesz = get_framesz fnid in
    let spill_fixup = Hashtbl.find cx.ctxt_spill_fixups fnid in
    Stack.push (Stack.create()) epilogue_jumps;
      push_new_emitter ();
      cx.ctxt_abi.Abi.abi_emit_fn_prologue (emitter()) framesz spill_fixup;
      trans_block fn.Ast.fn_body;
      Stack.iter patch (Stack.pop epilogue_jumps);
      cx.ctxt_abi.Abi.abi_emit_fn_epilogue (emitter());
      capture_emitted_quads fnid;
      pop_emitter ()
  in

  let trans_prog_block (progid:node_id) (b:Ast.block) (ncomp:string) : fixup =
    let _ = Stack.push ncomp path in
    let fix = new_fixup (path_name ()) in
    let framesz = Hashtbl.find cx.ctxt_frame_sizes progid in
    let spill_fixup = Hashtbl.find cx.ctxt_spill_fixups progid in
      push_new_emitter ();
      let dst = Il.Reg (Il.next_vreg (emitter())) in
        Il.emit_full (emitter()) (Some fix) Il.DEAD Il.Nil Il.Nil Il.Nil;
        cx.ctxt_abi.Abi.abi_emit_main_prologue (emitter()) b framesz spill_fixup;
        trans_block b;
        cx.ctxt_abi.Abi.abi_emit_proc_state_change (emitter()) Abi.STATE_exiting;
        cx.ctxt_abi.Abi.abi_emit_main_epilogue (emitter()) b;
        emit Il.CCALL dst (Il.Pcrel cx.ctxt_proc_to_c_fixup) Il.Nil;
        capture_emitted_quads progid;
        pop_emitter ();
        ignore (Stack.pop path);
        fix
  in

  let trans_prog (progid:node_id) (p:Ast.prog) : unit =
    let _ = log cx "translating program: %s" (path_name()) in
    let init =
      (* FIXME: translate the init part as well. *)
      Asm.IMM 0L
    in
    let main =
      match p.Ast.prog_main with
          None -> Asm.IMM 0L
        | Some main -> Asm.M_POS (trans_prog_block progid main "main")
    in
    let fini =
      match p.Ast.prog_fini with
          None -> Asm.IMM 0L
        | Some fini -> Asm.M_POS (trans_prog_block progid fini "fini")
    in
    let prog =
      let fixup = get_prog_fixup progid in
      (* FIXME: extract prog layout from ABI. *)
      Asm.DEF (fixup,
               Asm.SEQ [| Asm.WORD (TY_u32, init);
                          Asm.WORD (TY_u32, main);
                          Asm.WORD (TY_u32, fini) |])
    in
      cx.ctxt_data_items <- prog :: cx.ctxt_data_items
  in

  let rec trans_mod_item
      (item:Ast.mod_item)
      : unit =
    begin
      match item.node with
          Ast.MOD_ITEM_fn f -> trans_fn item.id f.Ast.decl_item
        | Ast.MOD_ITEM_prog p -> trans_prog item.id p.Ast.decl_item
        | _ -> ()
    end
  in

  let visit_mod_item_pre n p i =
    if Hashtbl.mem cx.ctxt_item_files i.id
    then begin
      match !file with
          None -> file := Some i.id
        | Some _ -> err (Some i.id) "Existing source file on file-scope entry."
    end;
    Stack.push n path;
    trans_mod_item i;
    inner.Walk.visit_mod_item_pre n p i
  in
  let visit_mod_item_post n p i =
    inner.Walk.visit_mod_item_post n p i;
    ignore (Stack.pop path);
    if Hashtbl.mem cx.ctxt_item_files i.id
    then begin
      match !file with
          None -> err (Some i.id) "Missing source file on file-scope exit."
        | Some _ -> file := None
    end;
  in
    { inner with
        Walk.visit_mod_item_pre = visit_mod_item_pre;
        Walk.visit_mod_item_post = visit_mod_item_post
    }
;;


let fixup_assigning_visitor
    (cx:ctxt)
    (inner:Walk.visitor)
    : Walk.visitor =

  let path = Stack.create () in

  let path_name (_:unit) : string =
    String.concat "." (stk_elts_from_bot path)
  in

  let visit_mod_item_pre n p i =
    Stack.push n path;
    begin
      if Hashtbl.mem cx.ctxt_item_files i.id
      then
        htab_put cx.ctxt_file_fixups i.id (new_fixup (path_name()))
      else
        match i.node with
            Ast.MOD_ITEM_fn _ ->
              htab_put cx.ctxt_fn_fixups i.id (new_fixup (path_name()))
          | Ast.MOD_ITEM_prog _ ->
              let path = path_name() in
              let fixup =
                if path = cx.ctxt_main_name
                then cx.ctxt_main_prog
                else (new_fixup path)
              in
                (log cx "defining '%s' to mod item '%s'" fixup.fixup_name (path_name());
               htab_put cx.ctxt_prog_fixups i.id fixup)
          | _ -> ()
    end;
    inner.Walk.visit_mod_item_pre n p i
  in

  let visit_mod_item_post n p i =
    inner.Walk.visit_mod_item_post n p i;
    ignore (Stack.pop path)
  in
  { inner with
        Walk.visit_mod_item_pre = visit_mod_item_pre;
        Walk.visit_mod_item_post = visit_mod_item_post;
    }

let emit_c_to_proc_glue cx =
  let e = Il.new_emitter
    cx.ctxt_abi.Abi.abi_prealloc_quad
    cx.ctxt_abi.Abi.abi_is_2addr_machine
  in
    cx.ctxt_abi.Abi.abi_c_to_proc e cx.ctxt_c_to_proc_fixup;
    if e.Il.emit_next_vreg != 0
    then err None "c-to-proc glue uses nonzero vregs"
    else cx.ctxt_anon_text_quads <-
      (e.Il.emit_quads) :: cx.ctxt_anon_text_quads
;;


let emit_proc_to_c_glue cx =
  let e = Il.new_emitter
    cx.ctxt_abi.Abi.abi_prealloc_quad
    cx.ctxt_abi.Abi.abi_is_2addr_machine
  in
    cx.ctxt_abi.Abi.abi_proc_to_c e cx.ctxt_proc_to_c_fixup;
    if e.Il.emit_next_vreg != 0
    then err None "proc-to-c glue uses nonzero vregs"
    else cx.ctxt_anon_text_quads <-
      (e.Il.emit_quads) :: cx.ctxt_anon_text_quads
;;

let trans_crate
    (cx:ctxt)
    (items:Ast.mod_items)
    : (file_grouped_texts * Asm.item list * fixup) =
  let passes =
    [|
      (fixup_assigning_visitor cx
         Walk.empty_visitor);
      (trans_visitor cx
         Walk.empty_visitor)
    |];
  in
    log cx "translating crate with main program %s" cx.ctxt_main_name;
    run_passes cx passes (log cx "%s") items;
    emit_c_to_proc_glue cx;
    emit_proc_to_c_glue cx;
    (cx.ctxt_texts, cx.ctxt_data_items, cx.ctxt_main_prog)
;;


(*
 * Local Variables:
 * fill-column: 70;
 * indent-tabs-mode: nil
 * compile-command: "make -k -C .. 2>&1 | sed -e 's/\\/x\\//x:\\//g'";
 * End:
 *)