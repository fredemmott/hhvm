(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the "hack" directory of this source tree.
 *
 *)

type decl_kind =
  | Class_no_local_cache
  | Class
  | Class_find_unsafe
  | Class_mem
  | Fun
  | GConst
  | Record_def
  | Typedef

type subdecl_kind =
  (* Shallow *)
  | Shallow_decl
  | Abstract
  | Final
  | Const
  | Kind
  | Is_xhp
  | Name
  | Pos
  | Tparams
  | Where_constraints
  | Enum_type
  | Sealed_whitelist
  | Decl_errors
  (* Lazy *)
  | Construct
  | Need_init
  | Get_ancestor of string
  | Has_ancestor of string
  | Requires_ancestor of string
  | Extends of string
  | Get_const of string
  | Has_const of string
  | Get_typeconst of string
  | Has_typeconst of string
  | Get_prop of string
  | Has_prop of string
  | Get_sprop of string
  | Has_sprop of string
  | Get_method of string
  | Has_method of string
  | Get_smethod of string
  | Has_smethod of string
  (* Eager *)
  | Members_fully_known
  | All_ancestor_req_names
  | All_extends_ancestors
  | All_ancestors
  | All_ancestor_names
  | All_ancestor_reqs
  | Is_disposable
  | Get_pu_enum of string
  | Consts
  | Typeconsts
  | Pu_enums
  | Props
  | SProps
  | Methods
  | SMethods
  | All_inherited_methods
  | All_inherited_smethods
  (* Misc *)
  | Deferred_init_members

val count_decl : string -> decl_kind -> (unit -> 'a) -> 'a

val count_subdecl : subdecl_kind -> (unit -> 'a) -> 'a
