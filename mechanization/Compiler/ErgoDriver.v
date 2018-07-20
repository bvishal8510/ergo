(*
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *)

(** Compilation paths *)

Require Import String.
Require Import List.

Require Import ErgoSpec.Backend.ForeignErgo.
Require Import ErgoSpec.Backend.ErgoBackend.
Require Import ErgoSpec.Common.Utils.ENames.
Require Import ErgoSpec.Common.Utils.EResult.
Require Import ErgoSpec.Common.Utils.EAstUtil.
Require Import ErgoSpec.Common.CTO.CTO.
Require Import ErgoSpec.Common.Types.ErgoType.
Require Import ErgoSpec.Ergo.Lang.Ergo.
Require Import ErgoSpec.Ergo.Lang.ErgoExpand.
Require Import ErgoSpec.ErgoC.Lang.ErgoC.
Require Import ErgoSpec.ErgoC.Lang.ErgoCEvalContext.
Require Import ErgoSpec.ErgoC.Lang.ErgoCEval.
Require Import ErgoSpec.Translation.CTOtoErgo.
Require Import ErgoSpec.Translation.ErgoNameResolve.
Require Import ErgoSpec.Translation.ErgotoErgoC.
Require Import ErgoSpec.Translation.ErgoCompContext.
Require Import ErgoSpec.Translation.ErgoCInline.
Require Import ErgoSpec.Translation.ErgoCtoErgoNNRC.
Require Import ErgoSpec.Translation.ErgoNNRCtoJavaScript.
Require Import ErgoSpec.Translation.ErgoNNRCtoJavaScriptCicero.
Require Import ErgoSpec.Translation.ErgoNNRCtoJava.

Section ErgoDriver.

  Section Compiler.
    (* Initialize compilation context *)
    Definition compilation_context_from_inputs
               (ctos:list lrcto_package)
               (mls:list lrergo_module) : eresult compilation_context :=
      let ictos := map InputCTO ctos in
      let imls := map InputErgo mls in
      let ctxt := init_namespace_ctxt in
      elift (fun resolved_mods : list laergo_module * namespace_ctxt =>
               let (_,ns_ctxt) := resolved_mods in
               init_compilation_context ns_ctxt)
            (resolve_ergo_inputs ctxt (ictos ++ imls)).

    Definition compilation_context_from_inputs_for_cicero
               (ctos:list lrcto_package)
               (mls:list lrergo_module) : eresult compilation_context :=
      let ctxt := init_namespace_ctxt in
      let rctos := resolve_cto_packages ctxt ctos in
      let rmods := eolift (fun rctos => resolve_ergo_modules (snd rctos) mls) rctos in
      elift (fun resolved_mods : list laergo_module * namespace_ctxt =>
               let (_,ns_ctxt) := resolved_mods in
               init_compilation_context ns_ctxt)
            rmods.

    (* Ergo -> ErgoC *)
    Definition ergo_module_to_ergoc
               (ctxt:compilation_context)
               (lm:lrergo_module) : eresult (ergoc_module * compilation_context) :=
      let ns_ctxt := namespace_ctxt_of_compilation_context ctxt in
      let am := resolve_ergo_module ns_ctxt lm in
      eolift (fun amc =>
                let ctxt := compilation_context_update_namespace ctxt (snd amc) in
                let p := expand_ergo_module (fst amc) in
                let pc :=
                    eolift (fun p =>
                              elift
                                (fun pc => (pc, ctxt))
                                (ergo_module_to_calculus p)) p
                in
                eolift (fun xy => ergoc_inline_module (snd xy) (fst xy)) pc)
             am.

    (* ErgoDecl -> ErgoCDecl *)
    Definition ergo_declaration_to_ergoc
               (ctxt:compilation_context)
               (ld:lrergo_declaration) : eresult (option ergoc_declaration * compilation_context) :=
      let ns_ctxt := namespace_ctxt_of_compilation_context ctxt in
      let am := resolve_ergo_declaration ns_ctxt ld in
      eolift (fun amc =>
                let ctxt := compilation_context_update_namespace ctxt (snd amc) in
                elift
                  (fun d => (d, ctxt))
                  (declaration_to_calculus (fst amc)))
             am.

    Definition ergo_declaration_to_ergoc_inlined
               (sctxt : compilation_context)
               (decl : lrergo_declaration)
      : eresult (option ergoc_declaration * compilation_context) :=
      eolift
        (fun xy =>
           match fst xy with
           | None => esuccess (None, snd xy)
           | Some decl' =>
             let sctxt' := snd xy in
             elift
               (fun xy => (Some (fst xy), snd xy))
               (ergoc_inline_declaration sctxt' decl')
           end)
      (ergo_declaration_to_ergoc sctxt decl).

    Definition ergo_module_to_javascript
               (ctxt:compilation_context)
               (p:lrergo_module) : eresult ErgoCodeGen.javascript :=
      let pc := ergo_module_to_ergoc ctxt p in
      let pn := eolift (fun xy => ergoc_module_to_nnrc (fst xy)) pc in
      elift nnrc_module_to_javascript_top pn.

    Definition ergo_module_to_javascript_top
               (ctos:list lrcto_package)
               (mls:list lrergo_module)
               (p:lrergo_module) : eresult ErgoCodeGen.javascript :=
      let ctxt := compilation_context_from_inputs ctos mls in
      eolift (fun ctxt => ergo_module_to_javascript ctxt p) ctxt.

    Definition ergo_module_to_java
               (ctxt:compilation_context)
               (p:lrergo_module) : eresult ErgoCodeGen.java :=
      let pc := ergo_module_to_ergoc ctxt p in
      let pn := eolift (fun xy => ergoc_module_to_nnrc (fst xy)) pc in
      elift nnrc_module_to_java_top pn.

    Definition ergo_module_to_java_top
               (ctos:list lrcto_package)
               (mls:list lrergo_module)
               (p:lrergo_module) : eresult ErgoCodeGen.java :=
      let ctxt := compilation_context_from_inputs ctos mls in
      eolift (fun ctxt => ergo_module_to_java ctxt p) ctxt.

    Definition ergo_module_to_javascript_cicero_top
               (ctos:list cto_package)
               (mls:list lrergo_module)
               (p:lrergo_module) : eresult ErgoCodeGen.javascript :=
      let ctxt := compilation_context_from_inputs_for_cicero ctos mls in
      let p :=
          eolift (fun am =>
                    let ns_ctxt := namespace_ctxt_of_compilation_context am in
                    resolve_ergo_module ns_ctxt p) ctxt
      in
      eolift
        (fun p =>
           let ctxt :=
               elift (fun ct => compilation_context_update_namespace ct (snd p)) ctxt
           in
           let p := expand_ergo_module (fst p) in
           let ec := eolift lookup_single_contract p in
           eolift
             (fun c : local_name * ergo_contract =>
                let contract_name := (fst c) in 
                let sigs := lookup_contract_signatures (snd c) in
                let pc := eolift ergo_module_to_calculus p in
                let pc :=
                    eolift (fun ct =>
                              eolift (fun p => ergoc_inline_module ct p) pc) ctxt
                in
                let pn := eolift (fun xy => ergoc_module_to_nnrc (fst xy)) pc in
                elift (ergoc_module_to_javascript_cicero contract_name (snd c).(contract_state) sigs) pn)
             ec)
        p.

  End Compiler.

  Section Interpreter.
    Record repl_context :=
      mkREPLCtxt {
          repl_context_eval_ctxt : eval_context;
          repl_context_comp_ctxt : compilation_context
        }.
    
    Definition init_repl_context
               (ctos : list lrcto_package)
               (mls : list lrergo_module) : eresult repl_context :=
      elift (mkREPLCtxt ErgoCEvalContext.empty_eval_context)
            (eolift (set_namespace_in_compilation_context
                       "org.accordproject.ergotop"%string)
                    (compilation_context_from_inputs ctos mls)).

    Definition update_repl_ctxt_comp_ctxt
               (rctxt: repl_context)
               (sctxt: compilation_context) : repl_context :=
      mkREPLCtxt rctxt.(repl_context_eval_ctxt) sctxt.
    
    Definition update_repl_ctxt_eval_ctxt
               (rctxt: repl_context)
               (dctxt: eval_context) : repl_context :=
      mkREPLCtxt dctxt rctxt.(repl_context_comp_ctxt).
    
    Definition lift_repl_ctxt
               (orig_ctxt : repl_context)
               (result : eresult (option ergo_data * repl_context))
               : repl_context
      :=
        elift_both
          (fun s => snd s) (* in case of success, second part of result is the new context *)
          (fun e => orig_ctxt)  (* in case of failure, ignore the failure and return the original context *)
          result.

    Definition unpack_output
               (out : ergo_data)
      : option (ergo_data * list ergo_data * ergo_data) :=
      match out with
      | (dleft (drec (("response"%string, response)
                        ::("state"%string, state)
                        ::("emit"%string, dcoll emits)
                        ::nil))) =>
        Some (response, emits, state)
      | _ => None
      end.

    Definition ergo_eval_decl_via_calculus
               (ctxt : repl_context)
               (decl : lrergo_declaration)
      : eresult (option ergo_data * repl_context) :=
      match ergo_declaration_to_ergoc_inlined ctxt.(repl_context_comp_ctxt) decl with
      | Failure _ _ f => efailure f
      | Success _ _ (None, sctxt') => esuccess (None, update_repl_ctxt_comp_ctxt ctxt sctxt')
      | Success _ _ (Some decl', sctxt') =>
        match ergoc_eval_decl ctxt.(repl_context_eval_ctxt) decl' with
        | Failure _ _ f => efailure f
        | Success _ _ (dctxt', None) => esuccess (None, mkREPLCtxt dctxt' sctxt')
        | Success _ _ (dctxt', Some out) =>
          match unpack_output out with
          | None => esuccess (Some out, mkREPLCtxt dctxt' sctxt')
          | Some (_, _, state) =>
            esuccess (
                Some out,
                mkREPLCtxt
                  (eval_context_update_local_env dctxt' "state"%string state)
                  sctxt'
              )
          end
        end
      end.

    Definition string_of_response (response : ergo_data) : string :=
      (fmt_grn "Response. ") ++ (ErgoData.data_to_json_string fmt_dq response) ++ fmt_nl.

    Definition string_of_emits (emits : list ergo_data) : string :=
      (fold_left
         (fun old new => ((fmt_mag "Emit. ") ++ new ++ fmt_nl ++ old)%string)
         (map (ErgoData.data_to_json_string fmt_dq) emits) ""%string).

    Definition string_of_state (ctxt : eval_context) (state : ergo_data)
    : string :=
      let jsonify := ErgoData.data_to_json_string fmt_dq in
      let old_st := lookup String.string_dec (ctxt.(eval_context_local_env)) "state"%string in
      let new_st := state in
      match old_st with
      | None => (fmt_blu "State. ") ++ (jsonify state)
      | Some state' =>
        if Data.data_eq_dec state state' then
          ""%string
        else
          (fmt_blu "State. ") ++ (jsonify state) ++ fmt_nl
      end.

    (* XXX May be nice to replace by a format that aligns with Ergo notations instead of JSON and move to an earlier module e.g., Common/Utils/EData *)
    Definition string_of_result (ctxt : eval_context) (result : option ergo_data)
      : string :=
      match result with
      | None => ""
      | Some (dright msg) =>
        fmt_red ("Error. "%string) ++ (ErgoData.data_to_json_string fmt_dq msg) ++ fmt_nl
      | Some out =>
        match unpack_output out with
        | Some (response, emits, state) =>
            (string_of_emits emits) ++ (string_of_response response) ++ (string_of_state ctxt state)
        | None => (ErgoData.data_to_json_string fmt_dq out) ++ fmt_nl
        end
(* Note: this was previously powered by QCert's dataToString d, and I kind of
   liked that better anyway, so we might transition back at some point. The
   problem was that QCert treated arrays as bags and sorted them before
   printing (!!!). *)
      end.

    Definition ergo_string_of_result
               (rctxt : repl_context)
               (result : eresult (option ergo_data * repl_context))
      : string :=
      elift_both
        (string_of_result rctxt.(repl_context_eval_ctxt))
        (fun e => string_of_error e ++ fmt_nl)%string
        (elift (fun x => fst x) result).

    Definition ergo_repl_eval_decl
               (rctxt : repl_context)
               (decl : lrergo_declaration)
      : string * repl_context :=
      let result := ergo_eval_decl_via_calculus rctxt decl in
      let out := ergo_string_of_result rctxt result in
      (out, lift_repl_ctxt rctxt result).

  End Interpreter.

End ErgoDriver.

