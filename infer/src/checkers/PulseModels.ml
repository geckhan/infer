(*
 * Copyright (c) 2018-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)
open! IStd
open Result.Monad_infix
module L = Logging

type exec_fun =
     Location.t
  -> ret:Var.t * Typ.t
  -> actuals:HilExp.t list
  -> PulseDomain.t
  -> PulseDomain.t PulseDomain.access_result

type model = exec_fun

module Misc = struct
  let early_exit : model = fun _ ~ret:_ ~actuals:_ _ -> Ok PulseDomain.initial
end

module C = struct
  let free : model =
   fun location ~ret:_ ~actuals astate ->
    match actuals with
    | [AccessExpression deleted_access] ->
        PulseDomain.invalidate (CFree (deleted_access, location)) location deleted_access astate
    | _ ->
        Ok astate


  let variable_initialization : model =
   fun location ~ret:_ ~actuals astate ->
    match actuals with
    | [AccessExpression (AddressOf access_expr)] ->
        PulseDomain.havoc location access_expr astate
    | _ ->
        L.die InternalError
          "The frontend is not supposed to produce __variable_initialization(e) where e is not of \
           the form `&exp`. Got [%a]."
          (Pp.seq ~sep:", " HilExp.pp) actuals
end

module Cplusplus = struct
  let delete : model =
   fun location ~ret:_ ~actuals astate ->
    PulseDomain.read_all location (List.concat_map actuals ~f:HilExp.get_access_exprs) astate
    >>= fun astate ->
    match actuals with
    | [AccessExpression deleted_access] ->
        PulseDomain.invalidate
          (CppDelete (deleted_access, location))
          location deleted_access astate
    | _ ->
        Ok astate


  let operator_call : model =
   fun location ~ret:(ret_var, _) ~actuals astate ->
    PulseDomain.read_all location (List.concat_map actuals ~f:HilExp.get_access_exprs) astate
    >>= fun astate ->
    ( match actuals with
    | AccessExpression lambda :: _ ->
        PulseDomain.read location HilExp.AccessExpression.(dereference (dereference lambda)) astate
        >>= fun (astate, address) ->
        PulseDomain.Closures.check_captured_addresses location lambda address astate
    | _ ->
        Ok astate )
    >>| PulseDomain.havoc_var ret_var


  let placement_new : model =
   fun location ~ret:(ret_var, _) ~actuals astate ->
    let read_all args astate =
      PulseDomain.read_all location (List.concat_map args ~f:HilExp.get_access_exprs) astate
    in
    match List.rev actuals with
    | HilExp.AccessExpression expr :: other_actuals ->
        PulseDomain.read location expr astate
        >>= fun (astate, address) ->
        Ok (PulseDomain.write_var ret_var address astate) >>= read_all other_actuals
    | _ :: other_actuals ->
        read_all other_actuals astate >>| PulseDomain.havoc_var ret_var
    | _ ->
        Ok (PulseDomain.havoc_var ret_var astate)
end

module StdVector = struct
  let internal_array =
    Typ.Fieldname.Clang.from_class_name
      (Typ.CStruct (QualifiedCppName.of_list ["std"; "vector"]))
      "__internal_array"


  let to_internal_array vector = HilExp.AccessExpression.field_offset vector internal_array

  let deref_internal_array vector =
    HilExp.AccessExpression.(dereference (to_internal_array vector))


  let element_of_internal_array vector index =
    HilExp.AccessExpression.array_offset (deref_internal_array vector) Typ.void index


  let reallocate_internal_array vector vector_f location astate =
    let array_address = to_internal_array vector in
    let array = deref_internal_array vector in
    let invalidation = PulseInvalidation.StdVector (vector_f, vector, location) in
    PulseDomain.invalidate_array_elements invalidation location array astate
    >>= PulseDomain.invalidate invalidation location array
    >>= PulseDomain.havoc location array_address


  let invalidate_references invalidation : model =
   fun location ~ret:_ ~actuals astate ->
    match actuals with
    | AccessExpression vector :: _ ->
        reallocate_internal_array vector invalidation location astate
    | _ ->
        Ok astate


  let at : model =
   fun location ~ret ~actuals astate ->
    match actuals with
    | [AccessExpression vector_access_expr; index_exp] ->
        PulseDomain.read location
          (element_of_internal_array vector_access_expr (Some index_exp))
          astate
        >>= fun (astate, loc) ->
        PulseDomain.write location (HilExp.AccessExpression.base ret) loc astate
    | _ ->
        Ok (PulseDomain.havoc_var (fst ret) astate)


  let reserve : model =
   fun location ~ret:_ ~actuals astate ->
    match actuals with
    | [AccessExpression vector; _value] ->
        reallocate_internal_array vector Reserve location astate
        >>= PulseDomain.StdVector.mark_reserved location vector
    | _ ->
        Ok astate


  let push_back : model =
   fun location ~ret:_ ~actuals astate ->
    match actuals with
    | [AccessExpression vector; _value] ->
        PulseDomain.StdVector.is_reserved location vector astate
        >>= fun (astate, is_reserved) ->
        if is_reserved then
          (* assume that any call to [push_back] is ok after one called [reserve] on the same vector
             (a perfect analysis would also make sure we don't exceed the reserved size) *)
          Ok astate
        else
          (* simulate a re-allocation of the underlying array every time an element is added *)
          reallocate_internal_array vector PushBack location astate
    | _ ->
        Ok astate
end

module ProcNameDispatcher = struct
  let dispatch : (unit, model) ProcnameDispatcher.ProcName.dispatcher =
    let open ProcnameDispatcher.ProcName in
    make_dispatcher
      [ -"std" &:: "function" &:: "operator()" &--> Cplusplus.operator_call
      ; -"std" &:: "vector" &:: "assign" &--> StdVector.invalidate_references Assign
      ; -"std" &:: "vector" &:: "clear" &--> StdVector.invalidate_references Clear
      ; -"std" &:: "vector" &:: "emplace" &--> StdVector.invalidate_references Emplace
      ; -"std" &:: "vector" &:: "emplace_back" &--> StdVector.invalidate_references EmplaceBack
      ; -"std" &:: "vector" &:: "insert" &--> StdVector.invalidate_references Insert
      ; -"std" &:: "vector" &:: "operator[]" &--> StdVector.at
      ; -"std" &:: "vector" &:: "push_back" &--> StdVector.push_back
      ; -"std" &:: "vector" &:: "reserve" &--> StdVector.reserve
      ; -"std" &:: "vector" &:: "shrink_to_fit" &--> StdVector.invalidate_references ShrinkToFit ]
end

let builtins_dispatcher =
  let builtins =
    [ (BuiltinDecl.__delete, Cplusplus.delete)
    ; (BuiltinDecl.__placement_new, Cplusplus.placement_new)
    ; (BuiltinDecl.__variable_initialization, C.variable_initialization)
    ; (BuiltinDecl.abort, Misc.early_exit)
    ; (BuiltinDecl.exit, Misc.early_exit)
    ; (BuiltinDecl.free, C.free)
    ; (BuiltinDecl.objc_cpp_throw, Misc.early_exit) ]
  in
  let builtins_map =
    Hashtbl.create
      ( module struct
        include Typ.Procname

        let hash = Caml.Hashtbl.hash

        let sexp_of_t _ = assert false
      end )
  in
  List.iter builtins ~f:(fun (builtin, model) ->
      let open PolyVariantEqual in
      assert (Hashtbl.add builtins_map ~key:builtin ~data:model = `Ok) ) ;
  fun proc_name -> Hashtbl.find builtins_map proc_name


let dispatch proc_name flags =
  match builtins_dispatcher proc_name with
  | Some _ as result ->
      result
  | None -> (
    match ProcNameDispatcher.dispatch () proc_name with
    | Some _ as result ->
        result
    | None ->
        if flags.CallFlags.cf_noreturn then Some Misc.early_exit else None )
