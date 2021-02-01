(*
 * Copyright (c) 2015, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the "hack" directory of this source tree.
 *
 *)

open Hh_prelude
open Typing_defs
open Utils
module Env = Typing_env
module SN = Naming_special_names
module Cls = Decl_provider.Class

(*****************************************************************************)
(* Module checking the (co/contra)variance annotations (+/-).
 *
 * The algorithm works by tracking the variance of *uses* of a type parameter,
 * and checks that the variance *declaration* on that type parameter is
 * consistent with its uses.
 *
 * For every type parameter use, we keep a witness (a position in the source),
 * that tells us where the covariance (or contravariance) was deduced.
 * This way, when we find an error, we can point to the place that was
 * problematic (as usual).
 *)
(*****************************************************************************)

(* Type describing the kind of position we are dealing with.
 * Pos.t gives us the position in the source, it doesn't tell us the kind
 * of position we are dealing with. This type keeps track of that.
 *)
type position_descr =
  | Rtypedef
  | Rmember (* Instance variable  *)
  | Rtype_parameter (* The declaration site of a type-parameter *)
  | Rfun_parameter
  | Rfun_return
  | Rtype_argument of string (* The argument of a parametric class or
                              * typedef:
                              * A<T1, ..>, T1 is (Rtype_argument "A")
                              *)
  | Rconstraint_as
  | Rconstraint_eq
  | Rconstraint_super
  | Rwhere_as
  | Rwhere_super
  | Rwhere_eq
  | Rfun_inout_parameter

type position_variance =
  | Pcovariant
  | Pcontravariant
  | Pinvariant

type reason = Pos.t * position_descr * position_variance

(* The variance that we have inferred for a given use of a type-parameter. We keep
 * a stack of reasons that made us infer the variance of a position.
 * For example:
 * T appears in foo(...): (function(...): T)
 * T is inferred as covariant + a stack made of two elements:
 * -) The first one points to the position of T
 * -) The second one points to the position of (function(...): T)
 * We can, thanks to this stack, detail why we think something is covariant
 * in the error message.
 *)
type variance =
  (* The type parameter appeared in covariant position. *)
  | Vcovariant of reason list
  (* The type parameter appeared in contravariant position. *)
  | Vcontravariant of reason list
  (* The type parameter appeared in both covariant and contravariant position.
   * We keep a stack for each side: the left hand side is proof for covariance,
   * while the right hand side is proof for contravariance.
   *)
  | Vinvariant of reason list * reason list
  (* The type parameter is not used, or is a method type parameter.
   *)
  | Vboth

(** The set of type parameters which are bound at a given location,
    with their variances. *)
type environment = variance SMap.t

(*****************************************************************************)
(* Reason pretty-printing *)
(*****************************************************************************)

let variance_to_string = function
  | Pcovariant -> "covariant (+)"
  | Pcontravariant -> "contravariant (-)"
  | Pinvariant -> "invariant"

let variance_to_sign = function
  | Pcovariant -> "(+)"
  | Pcontravariant -> "(-)"
  | Pinvariant -> "(I)"

let reason_stack_to_string variance reason_stack =
  Printf.sprintf
    "This position is %s because it is the composition of %s\nThe rest of the error messages decomposes the inference of the variance.\nCheck out this link if you don't understand what this is about:\nhttp://en.wikipedia.org/wiki/Covariance_and_contravariance_(computer_science)"
    variance
    (List.fold_right
       reason_stack
       ~f:
         begin
           fun (_, _, pvariance) acc ->
           variance_to_sign pvariance ^ acc
         end
       ~init:"")

let reason_to_string ~sign (_, descr, variance) =
  ( if sign then
    variance_to_sign variance ^ " "
  else
    "" )
  ^
  match descr with
  | Rtypedef -> "Aliased types are covariant"
  | Rmember -> "A non private class member is always invariant"
  | Rtype_parameter ->
    "The type parameter was declared as " ^ variance_to_string variance
  | Rfun_parameter -> "Function parameters are contravariant"
  | Rfun_return -> "Function return types are covariant"
  | Rtype_argument name ->
    Printf.sprintf
      "This type parameter was declared as %s (cf '%s')"
      (variance_to_string variance)
      name
  | Rconstraint_super ->
    "`super` constraints on method type parameters are covariant"
  | Rconstraint_as ->
    "`as` constraints on method type parameters are contravariant"
  | Rconstraint_eq -> "`=` constraints on method type parameters are invariant"
  | Rwhere_as ->
    "`where _ as _` constraints are covariant on the left, contravariant on the right"
  | Rwhere_eq -> "`where _ = _` constraints are invariant on the left and right"
  | Rwhere_super ->
    "`where _ super _` constraints are contravariant on the left, covariant on the right"
  | Rfun_inout_parameter ->
    "Inout/ref function parameters are both covariant and contravariant"

let detailed_message variance pos stack =
  match stack with
  | [] -> []
  | [((p, _, _) as r)] -> [(p, reason_to_string ~sign:false r)]
  | _ ->
    (pos, reason_stack_to_string variance stack)
    :: List.map stack (fun ((p, _, _) as r) ->
           (p, reason_to_string ~sign:true r))

(*****************************************************************************)
(* Converts an annotation (+/-) to a type. *)
(*****************************************************************************)

let make_variance reason pos = function
  | Ast_defs.Covariant -> Vcovariant [(pos, reason, Pcovariant)]
  | Ast_defs.Contravariant -> Vcontravariant [(pos, reason, Pcontravariant)]
  | Ast_defs.Invariant ->
    Vinvariant ([(pos, reason, Pinvariant)], [(pos, reason, Pinvariant)])

(*****************************************************************************)
(* Used when we want to compose with the variance coming from another class.
 * Let's assume: A<-T>
 * public function foo(A<T> $x): void;
 * A<T> is in contravariant position so we process -A<T>.
 * because A is annotated with a minus: we deduce --T (which becomes T).
 *)
(*****************************************************************************)

let compose (pos, param_descr) from to_ =
  (* We don't really care how we deduced the variance that we are composing
   * with (_stack_to). That's because the decomposition could be in a different
   * file and would be too hard to follow anyway.
   * Let's consider the following return type: A<T>.
   * Turns out A is declared as A<-T>.
   * It's not a good idea for us to point to what made us deduce that the
   * position was contravariant (the declaration side). Because the user will
   * wonder where it comes from.
   * It's better to point to the return type (more precisely, point to the T
   * in the return type) and explain that this position is contravariant.
   * Later on, the user can go and check the definition of A for herself.
   *)
  match (from, to_) with
  | (Vcovariant stack_from, Vcovariant _stack_to) ->
    let reason = (pos, param_descr, Pcovariant) in
    Vcovariant (reason :: stack_from)
  | (Vcontravariant stack_from, Vcontravariant _stack_to) ->
    let reason = (pos, param_descr, Pcontravariant) in
    Vcovariant (reason :: stack_from)
  | (Vcovariant stack_from, Vcontravariant _stack_to) ->
    let reason = (pos, param_descr, Pcontravariant) in
    Vcontravariant (reason :: stack_from)
  | (Vcontravariant stack_from, Vcovariant _stack_to) ->
    let reason = (pos, param_descr, Pcovariant) in
    Vcontravariant (reason :: stack_from)
  | ((Vinvariant _ as x), _) -> x
  | (_, Vinvariant (_co, _contra)) ->
    let reason = (pos, param_descr, Pinvariant) in
    Vinvariant ([reason], [reason])
  | (Vboth, x)
  | (x, Vboth) ->
    x

(*****************************************************************************)
(* Used for the arguments of function. *)
(*****************************************************************************)

let flip reason = function
  | Vcovariant stack -> Vcontravariant (reason :: stack)
  | Vcontravariant stack -> Vcovariant (reason :: stack)
  | Vinvariant _ as x -> x
  | Vboth -> Vboth

(*****************************************************************************)
(* Given a type parameter, returns the declared variance. *)
(*****************************************************************************)

let get_tparam_variance env name =
  match SMap.find_opt name env with
  | None -> Vboth
  | Some x -> x

(*****************************************************************************)
(* Given a type parameter, returns the variance declared. *)
(*****************************************************************************)

let make_tparam_variance t =
  make_variance Rtype_parameter (fst t.tp_name) t.tp_variance

let make_ast_tparam_variance : Nast.tparam -> variance =
 (fun t -> make_variance Rtype_parameter (fst t.Aast.tp_name) t.Aast.tp_variance)

(******************************************************************************)
(* Checks that a 'this' type is correctly used at a given contravariant       *)
(* position in a final class.                                                 *)
(******************************************************************************)
let check_final_this_pos_variance env_variance rpos class_ty =
  if Cls.final class_ty then
    List.iter (Cls.tparams class_ty) (fun t ->
        match (env_variance, t.tp_variance) with
        | (Vcontravariant _, (Ast_defs.Covariant | Ast_defs.Contravariant)) ->
          Errors.contravariant_this
            rpos
            (Utils.strip_ns (Cls.name class_ty))
            (snd t.tp_name)
        | _ -> ())

(*****************************************************************************)
(* Returns the list of type parameter variance for a given class.
 *
 * N.B.: this function works both with classes and typedefs.
 *)
(*****************************************************************************)

let get_class_variance tenv (pos, class_name) =
  match class_name with
  | name when String.equal name SN.Classes.cAwaitable ->
    [Vcovariant [(pos, Rtype_argument (Utils.strip_ns name), Pcovariant)]]
  | _ ->
    let tparams =
      match Env.get_class_or_typedef tenv class_name with
      | Some (Env.TypedefResult { td_tparams; _ }) -> td_tparams
      | Some (Env.ClassResult cls) -> Cls.tparams cls
      | None -> []
    in

    List.map tparams make_tparam_variance

let rec get_typarams tenv root env (ty : decl_ty) =
  let empty = (SMap.empty, SMap.empty) in
  let union (pos1, neg1) (pos2, neg2) =
    ( SMap.union ~combine:(fun _ x y -> Some (x @ y)) pos1 pos2,
      SMap.union ~combine:(fun _ x y -> Some (x @ y)) neg1 neg2 )
  in
  let flip (pos, neg) = (neg, pos) in
  let single id pos = (SMap.singleton id [pos], SMap.empty) in
  let get_typarams_union acc ty = union acc (get_typarams tenv root env ty) in
  match get_node ty with
  | Tgeneric (id, _tyargs) ->
    (* TODO(T69551141) handle type arguments *)
    (* If it's in the environment then it's not a generic method parameter *)
    if Option.is_some (SMap.find_opt id env) then
      empty
    else
      single id (get_reason ty)
  | Tnonnull
  | Tdynamic
  | Tprim _
  | Tany _
  | Terr
  | Tthis
  | Tmixed
  | Tvar _ ->
    empty
  | Toption ty
  | Tlike ty
  | Taccess (ty, _) ->
    get_typarams tenv root env ty
  | Tunion tyl
  | Tintersection tyl
  | Ttuple tyl ->
    List.fold_left tyl ~init:empty ~f:get_typarams_union
  | Tshape (_, m) ->
    Nast.ShapeMap.fold
      (fun _ { sft_ty; _ } res -> get_typarams_union res sft_ty)
      m
      empty
  | Tfun ft ->
    let get_typarams_param acc fp =
      let tp = get_typarams tenv root env fp.fp_type.et_type in
      let tp =
        match get_fp_mode fp with
        (* Parameters behave contravariantly *)
        | FPnormal -> flip tp
        (* Inout parameters behave both co- and contra-variantly *)
        | FPinout -> union tp (flip tp)
      in
      union acc tp
    in
    let get_typarams_arity acc arity =
      match arity with
      | Fstandard -> acc
      | Fvariadic fp -> get_typarams_param acc fp
    in
    let params =
      List.fold_left
        ft.ft_params
        ~init:(get_typarams_arity empty ft.ft_arity)
        ~f:get_typarams_param
    in
    let ret = get_typarams tenv root env ft.ft_ret.et_type in
    let get_typarams_constraint acc (ck, ty) =
      union
        acc
        (match ck with
        | Ast_defs.Constraint_as -> get_typarams tenv root env ty
        | Ast_defs.Constraint_eq ->
          let tp = get_typarams tenv root env ty in
          union (flip tp) tp
        | Ast_defs.Constraint_super -> flip (get_typarams tenv root env ty))
    in
    let get_typarams_tparam acc tp =
      List.fold_left tp.tp_constraints ~init:acc ~f:get_typarams_constraint
    in
    let bounds =
      List.fold_left ft.ft_tparams ~init:empty ~f:get_typarams_tparam
    in
    let get_typarams_where_constraint acc (ty1, ck, ty2) =
      union
        acc
        (match ck with
        | Ast_defs.Constraint_super ->
          union
            (flip (get_typarams tenv root env ty1))
            (get_typarams tenv root env ty2)
        | Ast_defs.Constraint_as ->
          union
            (get_typarams tenv root env ty1)
            (flip (get_typarams tenv root env ty2))
        | Ast_defs.Constraint_eq ->
          let tp =
            union
              (get_typarams tenv root env ty1)
              (get_typarams tenv root env ty2)
          in
          union tp (flip tp))
    in
    let constrs =
      List.fold_left
        ft.ft_where_constraints
        ~init:empty
        ~f:get_typarams_where_constraint
    in

    (* Result so far: bounds, constraints, return, parameters *)
    let result = union bounds (union constrs (union ret params)) in

    (* Get the lower bounds of a type parameter, including where constraints
     * of the form `where t as T` or `where T super t`
     *)
    let get_lower_bounds tp =
      let name = snd tp.tp_name in
      List.filter_map
        ~f:(fun (ck, ty) ->
          match ck with
          | Ast_defs.Constraint_super
          | Ast_defs.Constraint_eq ->
            Some ty
          | _ -> None)
        tp.tp_constraints
      @ List.filter_map
          ~f:(fun (ty1, ck, ty2) ->
            match ck with
            | Ast_defs.Constraint_as
            | Ast_defs.Constraint_eq
              when is_generic_equal_to name ty2 ->
              Some ty1
            | Ast_defs.Constraint_super
            | Ast_defs.Constraint_eq
              when is_generic_equal_to name ty1 ->
              Some ty2
            | _ -> None)
          ft.ft_where_constraints
    in

    (* Get the upper bounds of a type parameter, including where constraints
     * of the form `where T as t` or `where t super T`
     *)
    let get_upper_bounds tp =
      let name = snd tp.tp_name in
      List.filter_map
        ~f:(fun (ck, ty) ->
          match ck with
          | Ast_defs.Constraint_as
          | Ast_defs.Constraint_eq ->
            Some ty
          | _ -> None)
        tp.tp_constraints
      @ List.filter_map
          ~f:(fun (ty1, ck, ty2) ->
            match ck with
            | Ast_defs.Constraint_as
            | Ast_defs.Constraint_eq
              when is_generic_equal_to name ty1 ->
              Some ty2
            | Ast_defs.Constraint_super
            | Ast_defs.Constraint_eq
              when is_generic_equal_to name ty2 ->
              Some ty1
            | _ -> None)
          ft.ft_where_constraints
    in

    (* If a type parameter appears covariantly, then treat its lower bounds as covariant *)
    let propagate_covariant_to_lower_bounds tp =
      let tyl = get_lower_bounds tp in
      List.fold_left tyl ~init:empty ~f:get_typarams_union
    in

    (* If a type parameter appears contravariantly, then treat its upper bounds as contravariant *)
    let propagate_contravariant_to_upper_bounds tp =
      let tyl = get_upper_bounds tp in
      flip (List.fold_left tyl ~init:empty ~f:get_typarams_union)
    in

    (* Given a type parameter, propagate its variance (co and/or contra) to lower and upper bounds
     * as appropriate. See Typing_env.set_tyvar_appears_covariantly_and_propagate etc for an
     * analagous calculation for type variables.
     *)
    let propagate_typarams_tparam acc tp =
      let acc =
        if SMap.mem (snd tp.tp_name) (fst result) then
          union acc (propagate_covariant_to_lower_bounds tp)
        else
          acc
      in
      let acc =
        if SMap.mem (snd tp.tp_name) (snd result) then
          union acc (propagate_contravariant_to_upper_bounds tp)
        else
          acc
      in
      acc
    in
    List.fold_left ft.ft_tparams ~init:result ~f:propagate_typarams_tparam
  | Tapply (pos_name, tyl) ->
    let rec get_typarams_variance_list acc variancel tyl =
      match (variancel, tyl) with
      | (variance :: variancel, ty :: tyl) ->
        let param = get_typarams tenv root env ty in
        let param =
          match variance with
          | Vcovariant _ -> param
          | Vcontravariant _ -> flip param
          | _ -> union param (flip param)
        in
        get_typarams_variance_list (union acc param) variancel tyl
      | _ -> acc
    in
    let variancel = get_class_variance tenv pos_name in
    get_typarams_variance_list empty variancel tyl
  | Tdarray (ty1, ty2) ->
    union (get_typarams tenv root env ty1) (get_typarams tenv root env ty2)
  | Tvarray ty -> get_typarams tenv root env ty
  | Tvarray_or_darray (ty1, ty2) ->
    union (get_typarams tenv root env ty1) (get_typarams tenv root env ty2)

let generic_ env variance name _targs =
  (* TODO(T69931993) Once we support variance for HK generics, we have to update this.
     For now, having type arguments implies tha the declared must be invariant *)
  let declared_variance = get_tparam_variance env name in
  match (declared_variance, variance) with
  (* Happens if type parameter isn't from class *)
  | (Vboth, _)
  | (_, Vboth) ->
    ()
  | (Vinvariant _, _)
  | (Vcovariant _, Vcovariant _)
  | (Vcontravariant _, Vcontravariant _) ->
    ()
  | (Vcovariant stack1, (Vcontravariant stack2 | Vinvariant (_, stack2))) ->
    let (pos1, _, _) = List.hd_exn stack1 in
    let (pos2, _, _) = List.hd_exn stack2 in
    let emsg = detailed_message "contravariant (-)" pos2 stack2 in
    Errors.declared_covariant pos1 pos2 emsg
  | (Vcontravariant stack1, (Vcovariant stack2 | Vinvariant (stack2, _))) ->
    let (pos1, _, _) = List.hd_exn stack1 in
    let (pos2, _, _) = List.hd_exn stack2 in
    let emsg = detailed_message "covariant (+)" pos2 stack2 in
    Errors.declared_contravariant pos1 pos2 emsg

let rec fun_arity tenv root variance env arity =
  match arity with
  | Fstandard -> ()
  | Fvariadic fp -> fun_param tenv root variance env fp

and fun_param tenv root variance env ({ fp_type = { et_type = ty; _ }; _ } as fp)
    =
  let pos = get_pos ty in
  match get_fp_mode fp with
  | FPnormal ->
    let reason = (pos, Rfun_parameter, Pcontravariant) in
    let variance = flip reason variance in
    type_ tenv root variance env ty
  | FPinout ->
    let variance = make_variance Rfun_inout_parameter pos Ast_defs.Invariant in
    type_ tenv root variance env ty

and fun_tparam tenv root env t =
  List.iter t.tp_constraints ~f:(constraint_ tenv root env)

and fun_where_constraint tenv root env (ty1, ck, ty2) =
  let pos1 = get_pos ty1 in
  let pos2 = get_pos ty2 in
  match ck with
  | Ast_defs.Constraint_super ->
    let var1 = Vcontravariant [(pos1, Rwhere_super, Pcontravariant)] in
    let var2 = Vcovariant [(pos2, Rwhere_super, Pcovariant)] in
    type_ tenv root var1 env ty1;
    type_ tenv root var2 env ty2
  | Ast_defs.Constraint_eq ->
    let reason1 = [(pos1, Rwhere_eq, Pinvariant)] in
    let reason2 = [(pos2, Rwhere_eq, Pinvariant)] in
    let var = Vinvariant (reason1, reason2) in
    type_ tenv root var env ty1;
    type_ tenv root var env ty2
  | Ast_defs.Constraint_as ->
    let var1 = Vcovariant [(pos1, Rwhere_as, Pcovariant)] in
    let var2 = Vcontravariant [(pos2, Rwhere_as, Pcontravariant)] in
    type_ tenv root var1 env ty1;
    type_ tenv root var2 env ty2

and fun_ret tenv root variance env ty =
  let pos = get_pos ty in
  let reason_covariant = (pos, Rfun_return, Pcovariant) in
  let variance =
    match variance with
    | Vcovariant stack -> Vcovariant (reason_covariant :: stack)
    | Vcontravariant stack -> Vcontravariant (reason_covariant :: stack)
    | variance -> variance
  in
  type_ tenv root variance env ty

and type_list tenv root variance env tyl =
  List.iter tyl ~f:(type_ tenv root variance env)

and type_ tenv root variance env ty =
  let (reason, ty) = deref ty in
  match ty with
  | Tany _
  | Tmixed
  | Tnonnull
  | Terr
  | Tdynamic
  | Tvar _ ->
    ()
  | Tdarray (ty1, ty2)
  | Tvarray_or_darray (ty1, ty2) ->
    type_ tenv root variance env ty1;
    type_ tenv root variance env ty2
  | Tvarray ty -> type_ tenv root variance env ty
  | Tthis ->
    (* Check that 'this' isn't being improperly referenced in a contravariant
     * position.
     *)
    Option.value_map
      root
      ~default:()
      ~f:(check_final_this_pos_variance variance (Reason.to_pos reason))
  (* With the exception of the above check, `this` constraints are bivariant
   * (otherwise any class that used the `this` type would not be able to use
   * covariant type params).
   *)
  | Tgeneric (name, targs) ->
    let pos = Reason.to_pos reason in
    (* This section makes the position more precise.
     * Say we find a return type that is a tuple (int, int, T).
     * The whole tuple is in covariant position, and so the position
     * is going to include the entire tuple.
     * That can make things pretty unreadable when the type is long.
     * Here we replace the position with the exact position of the generic
     * that was problematic.
     *)
    let variance =
      match variance with
      | Vcovariant ((pos', x, y) :: rest) when not (Pos.equal pos pos') ->
        Vcovariant ((pos, x, y) :: rest)
      | Vcontravariant ((pos', x, y) :: rest) when not (Pos.equal pos pos') ->
        Vcontravariant ((pos, x, y) :: rest)
      | x -> x
    in
    generic_ env variance name targs
  | Toption ty -> type_ tenv root variance env ty
  | Tlike ty -> type_ tenv root variance env ty
  | Tprim _ -> ()
  | Tfun ft ->
    let env =
      List.fold_left
        ft.ft_tparams
        ~f:
          begin
            fun env t ->
            SMap.remove (snd t.tp_name) env
          end
        ~init:env
    in
    List.iter ft.ft_params ~f:(fun_param tenv root variance env);
    fun_arity tenv root variance env ft.ft_arity;
    List.iter ft.ft_tparams ~f:(fun_tparam tenv root env);
    List.iter ft.ft_where_constraints ~f:(fun_where_constraint tenv root env);
    fun_ret tenv root variance env ft.ft_ret.et_type
  | Tapply (_, []) -> ()
  | Tapply (((_, name) as pos_name), tyl) ->
    let variancel = get_class_variance tenv pos_name in
    iter2_shortest
      begin
        fun tparam_variance ty ->
        let pos = get_pos ty in
        let reason = Rtype_argument (Utils.strip_ns name) in
        let variance = compose (pos, reason) variance tparam_variance in
        type_ tenv root variance env ty
      end
      variancel
      tyl
  | Ttuple tyl
  | Tunion tyl
  | Tintersection tyl ->
    type_list tenv root variance env tyl
  | Taccess (ty, _) -> type_ tenv root variance env ty
  | Tshape (_, ty_map) ->
    Nast.ShapeMap.iter
      begin
        fun _ { sft_ty; _ } ->
        type_ tenv root variance env sft_ty
      end
      ty_map

(* `as` constraints on method type parameters must be contravariant
 * and `super` constraints on method type parameters are covariant. To
 * see why, suppose that we allow the wrong variance:
 *
 *   class Foo<+T> {
 *     public function bar<Tu as T>(Tu $x) {}
 *   }
 *
 * Let A and B be classes, with B a subtype of A. Then
 *
 *   function f(Foo<A> $x) {
 *     $x->(new A());
 *   }
 *
 * typechecks. However, covariance means that we could call `f()` with an
 * instance of B. However, B::bar would expect its argument $x to be a subtype
 * of B, but we would be passing an instance of A to it, which should be a type
 * error. In other words, `as` constraints are upper type bounds, and since
 * subtypes must have more relaxed constraints than their supertypes, `as`
 * constraints must be contravariant. (Reversing this argument shows that
 * `super` constraints must be covariant.)
 *
 * The preceding discussion might lead one to think that the constraints should
 * have the same variance as the class parameter types, i.e. that `as`
 * constraints used in the return type should be covariant. In particular,
 * suppose
 *
 *   class Foo<-T> {
 *     public function bar<Tu as T>(Tu $x): Tu { ... }
 *     public function baz<Tu as T>(): Tu { ... }
 *   }
 *
 *   class A {}
 *   class B extends A {
 *     public function qux() {}
 *   }
 *
 *   function f(Foo<B> $x) {
 *     $x->baz()->qux();
 *   }
 *
 * Now `f($x)` could be a runtime error if `$x` was an instance of Foo<A>, and
 * it seems like we should enforce covariance on Tu. However, the real problem
 * is that constraints apply to _instantiation_, not usage. As far as Hack
 * knows, $x->bar() could be of any type, since we have not provided any clues
 * about how `Tu` should be instantiated. In fact `$x->bar()->whatever()`
 * succeeds as well, because `Tu` is of type Tany -- though in an ideal world
 * we would make it Tmixed in order to ensure soundness. Also, the signature
 * of `baz()` doesn't entirely make sense -- why constrain Tu if it it's only
 * getting used in one place?
 *
 * Thus, if one wants type safety, how `$x` _should_ be used is
 *
 *   function f(Foo<B> $x) {
 *     $x->bar(new B()))->qux();
 *   }
 *
 * Thus we can see that, if `$x` is used correctly (or if we enforced correct
 * use by returning Tmixed for uninstantiated type variables), we would always
 * know the exact type of Tu, and Tu can be validly used in both co- and
 * contravariant positions.
 *
 * Remark: This is far more intuitive if you think about how Vector::concat is
 * typed with its `Tu super T` type in both the parameter and return type
 * positions. Uninstantiated `super` types are less likely to cause confusion,
 * however -- you can't imagine doing very much with a returned value that is
 * some (unspecified) supertype of a class.
 *)
and constraint_ tenv root env (ck, ty) =
  let pos = get_pos ty in
  let var =
    match ck with
    | Ast_defs.Constraint_as ->
      Vcontravariant [(pos, Rconstraint_as, Pcontravariant)]
    | Ast_defs.Constraint_eq ->
      let reasons = [(pos, Rconstraint_eq, Pinvariant)] in
      Vinvariant (reasons, reasons)
    | Ast_defs.Constraint_super ->
      Vcovariant [(pos, Rconstraint_super, Pcovariant)]
  in
  type_ tenv root var env ty

let hint :
    Typing_env_types.env ->
    Cls.t option ->
    variance ->
    environment ->
    Aast_defs.hint ->
    unit =
 fun tenv root variance env h ->
  let rec hint variance (pos, h) =
    let open Aast_defs in
    match h with
    | Habstr (name, targs) ->
      (* This section makes the position more precise.
       * Say we find a return type that is a tuple (int, int, T).
       * The whole tuple is in covariant position, and so the position
       * is going to include the entire tuple.
       * That can make things pretty unreadable when the type is long.
       * Here we replace the position with the exact position of the generic
       * that was problematic. *)
      let variance =
        match variance with
        | Vcovariant ((pos', x, y) :: rest) when not (Pos.equal pos pos') ->
          Vcovariant ((pos, x, y) :: rest)
        | Vcontravariant ((pos', x, y) :: rest) when not (Pos.equal pos pos') ->
          Vcontravariant ((pos, x, y) :: rest)
        | x -> x
      in
      generic_ env variance name targs
    | Hany
    | Herr
    | Hmixed
    | Hnonnull
    | Hdynamic
    | Hnothing
    | Hvar _
    | Hfun_context _
    | Hprim _ ->
      ()
    | Hvarray h -> hint variance h
    | Hdarray (hk, hv) ->
      hint variance hk;
      hint variance hv
    | Hvarray_or_darray (hk, hv) ->
      Option.iter hk ~f:(hint variance);
      hint variance hv
    | Hthis ->
      (* Check that 'this' isn't being improperly referenced in a contravariant
       * position.
       * With the exception of that check, `this` constraints are bivariant
       * (otherwise any class that used the `this` type would not be able to use
       * covariant type params). *)
      Option.value_map
        root
        ~default:()
        ~f:(check_final_this_pos_variance variance pos)
    | Hoption h
    | Hlike h
    | Hsoft h
    | Haccess (h, _) ->
      hint variance h
    | Hunion tyl
    | Hintersection tyl
    | Htuple tyl ->
      hint_list variance tyl
    | Hshape { nsi_allows_unknown_fields = _; nsi_field_map } ->
      List.iter
        nsi_field_map
        ~f:(fun { sfi_hint; sfi_optional = _; sfi_name = _ } ->
          hint variance sfi_hint)
    | Hfun hfun ->
      let {
        hf_param_tys;
        hf_param_kinds;
        hf_variadic_ty;
        hf_return_ty;
        hf_reactive_kind = _;
        hf_param_mutability = _;
        hf_ctxs = _;
        hf_is_mutable_return = _;
      } =
        hfun
      in
      List.iter2_exn hf_param_kinds hf_param_tys ~f:(fun_param variance);
      fun_arity variance hf_variadic_ty;
      fun_ret variance hf_return_ty
    | Happly (_, []) -> ()
    | Happly (name, hl) ->
      let variancel = get_class_variance tenv name in
      iter2_shortest
        begin
          fun tparam_variance h ->
          let pos = Ast_defs.get_pos h in
          let reason =
            Rtype_argument (Utils.strip_ns @@ Ast_defs.get_id name)
          in
          let variance = compose (pos, reason) variance tparam_variance in
          hint variance h
        end
        variancel
        hl
  and hint_list variance tyl = List.iter tyl ~f:(hint variance)
  and fun_param variance inout h =
    let pos = Ast_defs.get_pos h in
    match inout with
    | None ->
      let reason = (pos, Rfun_parameter, Pcontravariant) in
      let variance = flip reason variance in
      hint variance h
    | Some Ast_defs.Pinout ->
      let variance =
        make_variance Rfun_inout_parameter pos Ast_defs.Invariant
      in
      hint variance h
  and fun_ret variance h =
    let pos = Ast_defs.get_pos h in
    let reason_covariant = (pos, Rfun_return, Pcovariant) in
    let variance =
      match variance with
      | Vcovariant stack -> Vcovariant (reason_covariant :: stack)
      | Vcontravariant stack -> Vcontravariant (reason_covariant :: stack)
      | variance -> variance
    in
    hint variance h
  and fun_arity variance h = Option.iter h ~f:(fun_param variance None) in
  hint variance h

let class_property class_type tenv root static env (_member_name, member) =
  if phys_equal static `Static then
    if
      (* Check whether the type of a static property (class variable) contains
       * any generic type parameters. Outside of traits, this is illegal as static
       * properties are shared across all generic instantiations.
       * Although not strictly speaking a variance check, it fits here because
       * it concerns the presence of generic type parameters in types.
       *)
      Ast_defs.(equal_class_kind (Cls.kind class_type) Ctrait)
    then
      ()
    else
      let (lazy ty) = member.ce_type in
      let var_type_pos = get_pos ty in
      let class_pos = Cls.pos class_type in
      match Typing_generic.is_generic ty with
      | None -> ()
      | Some (generic_pos, _generic_name) ->
        Errors.static_property_type_generic_param
          ~class_pos
          ~var_type_pos
          ~generic_pos
  else
    match member.ce_visibility with
    | Vprivate _ -> ()
    | _ ->
      let (lazy ty) = member.ce_type in
      let pos = get_pos ty in
      let variance = make_variance Rmember pos Ast_defs.Invariant in
      type_ tenv root variance env ty

let class_method tenv root static env (_method_name, method_) =
  match method_.ce_visibility with
  | Vprivate _ -> ()
  | _ ->
    (* Final methods can't be overridden, so it's ok to use covariant
       and contravariant type parameters in any position in the type *)
    if get_ce_final method_ && phys_equal static `Static then
      ()
    else
      let (lazy ty) = method_.ce_type in
      type_ tenv root (Vcovariant []) env ty

(*****************************************************************************)
(* The entry point (for classes). *)
(*****************************************************************************)

(* impl is the list of `implements`, `extends`, and `use` types *)
let class_def tenv class_type impl =
  let root = Some class_type in
  let tparams = Cls.tparams class_type in
  let env =
    List.fold_left tparams ~init:SMap.empty ~f:(fun env tp ->
        SMap.add (snd tp.tp_name) (make_tparam_variance tp) env)
  in
  List.iter impl ~f:(type_ tenv root Vboth env);
  Cls.props class_type
  |> List.iter ~f:(class_property class_type tenv root `Instance env);
  Cls.sprops class_type
  |> List.iter ~f:(class_property class_type tenv root `Static env);
  Cls.methods class_type |> List.iter ~f:(class_method tenv root `Instance env);

  (* We need to apply the same restrictions to non-final static members because
     they can be invoked through classname instances *)
  if not (Cls.final class_type) then
    Cls.smethods class_type |> List.iter ~f:(class_method tenv root `Static env)

(*****************************************************************************)
(* The entry point (for typedefs). *)
(*****************************************************************************)
let typedef : Typing_env_types.env -> Nast.typedef -> unit =
 fun tenv typedef ->
  let {
    Aast.t_tparams;
    t_kind;
    t_annotation = _;
    t_name = _;
    t_constraint = _;
    t_user_attributes = _;
    t_mode = _;
    t_vis = _;
    t_namespace = _;
    t_span = _;
    t_emit_id = _;
  } =
    typedef
  in
  let root = None in
  let env =
    List.fold t_tparams ~init:SMap.empty ~f:(fun env tp ->
        SMap.add (snd tp.Aast.tp_name) (make_ast_tparam_variance tp) env)
  in
  let reason_covariant = [(Ast_defs.get_pos t_kind, Rtypedef, Pcovariant)] in
  hint tenv root (Vcovariant reason_covariant) env t_kind
