(**
 * Copyright (c) 2016, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the "hack" directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *
*)

module Syntax = Full_fidelity_positioned_syntax
module EditableTrivia = Full_fidelity_editable_trivia
module SourceText = Full_fidelity_source_text
module SyntaxTree = Full_fidelity_syntax_tree.WithSyntax(Syntax)
module ParserErrors = Full_fidelity_parser_errors.WithSyntax(Syntax)
module SyntaxError = Full_fidelity_syntax_error
module TestUtils = Full_fidelity_test_utils
module TriviaKind = Full_fidelity_trivia_kind

open Hh_core
open Ocaml_overrides
open OUnit

let test_files_dir = "./hphp/hack/test/full_fidelity/cases"

type test_case = {
  (** Source files is loaded from <name>.php in the <cwd>/<test_files_dir>/ *)
  name: string;
  source: string;
  expected: string;
  test_function: string -> string;
  value_mapper: string -> string;
}

let ident str = str

let write_file name contents =
  let path = Filename.concat test_files_dir name in
  let oc = open_out path in
  Printf.fprintf oc "%s" contents;
  close_out oc

let write_expectation_to_file name expected =
  write_file (name ^ ".out") expected

let cat_file name =
  let path = Filename.concat test_files_dir name in
  let raw = Sys_utils.cat path in
  (** cat adds an extra newline at the end. *)
  if (String.length raw > 0) &&
     (String.get raw (String.length raw - 1)) == '\n' then
    String.sub raw 0 (String.length raw - 1)
  else
    raw

(** Create a test_case by reading input from <cwd>/<test_files_dir>/name.php
 * and name.exp *)
let make_test_case_from_files ?(value_mapper=ident) name test_function =
  let source = cat_file (name ^ ".php") in
  let expected = cat_file (name ^ ".exp") in
  {
    name = name;
    source = source;
    expected = expected;
    test_function = test_function;
    value_mapper;
  }

let remove_whitespace text =
  let length = String.length text in
  let buffer = Buffer.create length in
  let rec aux i =
    if i = length then
      Buffer.contents buffer
    else
      let ch = String.get text i in
      match ch with
      | ' ' | '\n' | '\r' | '\t' -> aux (i + 1)
      | _ -> begin Buffer.add_char buffer ch; aux (i + 1) end in
  aux 0

let test_minimal source =
  let file_path = Relative_path.(create Dummy "<test_minimal>") in
  let source_text = SourceText.make file_path source in
  let syntax_tree = CallOrder.verify source_text in
  TestUtils.to_formatted_sexp_string (SyntaxTree.root syntax_tree)

let test_trivia source =
  let file_path = Relative_path.(create Dummy "<test_trivia>") in
  let source_text = SourceText.make file_path source in
  let syntax_tree = CallOrder.verify source_text in
  let editable = SyntaxTransforms.editable_from_positioned syntax_tree in
  let (no_trivia_tree, trivia) = TestUtils.rewrite_editable_tree_no_trivia editable in
  let pretty_no_trivia = Full_fidelity_pretty_printer.pretty_print no_trivia_tree in
  let formatted_trivia = List.map trivia
      (fun t ->
        Printf.sprintf "%s: (%s)"
          (TriviaKind.to_string @@ EditableTrivia.kind t)
          (EditableTrivia.text t)
      ) in
  Printf.sprintf "%s\n%s" (String.trim pretty_no_trivia) (String.concat "\n" formatted_trivia)

let test_mode source =
  let file_path = Relative_path.(create Dummy "<test_mode>") in
  let source_text = SourceText.make file_path source in
  let lang', _org_mode, mode' =
    let lang, mode = Full_fidelity_parser.get_language_and_mode source_text in
    let lang =
      match lang with
      | FileInfo.PhpFile -> "php"
      | FileInfo.HhFile -> "hh"
    in
    let mode' =
      match mode with
      | Some FileInfo.Mstrict -> "strict"
      | Some FileInfo.Mdecl -> "decl"
      | Some FileInfo.Mpartial
      | None
      | _
        -> ""
    in
    lang, mode, mode'
  in
  let syntax_tree = CallOrder.verify source_text in
  let lang = SyntaxTree.language syntax_tree in
  let mode = SyntaxTree.mode syntax_tree in
  let () = assert (lang = lang' && mode = mode') in
  let is_strict = SyntaxTree.is_strict syntax_tree in
  let is_hack = SyntaxTree.is_hack syntax_tree in
  let is_php = SyntaxTree.is_php syntax_tree in
  Printf.sprintf "Lang:%sMode:%sStrict:%bHack:%bPhp:%b"
    lang mode is_strict is_hack is_php

let test_errors source =
  let file_path = Relative_path.(create Dummy "<test_errors>") in
  let source_text = SourceText.make file_path source in
  let offset_to_position = SourceText.offset_to_position source_text in
  let syntax_tree = CallOrder.verify source_text in
  let error_env = ParserErrors.make_env syntax_tree
    ~disallow_elvis_space:true
  in
  let errors = ParserErrors.parse_errors error_env in
  let mapper err = SyntaxError.to_positioned_string err offset_to_position in
  let errors = List.map errors ~f:mapper in
  Printf.sprintf "%s" (String.concat "\n" errors)

let trivia_tests =
  [make_test_case_from_files "test_trivia" test_trivia]

let minimal_tests =
  let mapper testname =
    make_test_case_from_files
      ~value_mapper:remove_whitespace testname test_minimal in
  List.map
    [
      "test_simple";
      (*  TODO: This test is temporarily disabled because
          $a ? $b : $c = $d
          does not parse in the FF parser as it did in the original Hack parser,
          due to a precedence issue. Re-enable this test once we either fix that,
          or decide to take the breaking change.
          "test_conditional"; *)
      "test_statements";
      "test_for_statements";
      "test_try_statement";
      "test_list_precedence";
      "test_list_expression";
      "test_foreach_statements";
      "test_types_type_const";
      "test_function_call";
      "test_array_expression";
      "test_varray_darray_expressions";
      "test_varray_darray_types";
      "test_attribute_spec";
      "test_array_key_value_precedence";
      "test_enum";
      "test_class_with_attributes";
      "test_class_with_qualified_name";
      "test_namespace";
      "test_empty_class";
      "test_class_method_declaration";
      "test_constructor_destructor";
      "test_trait";
      "test_type_const";
      "test_class_const";
      "test_type_alias";
      "test_indirection";
      "test_eval_deref";
      "test_global_constant";
      "test_closure_type";
      "test_inclusion_directive";
      "test_awaitable_creation";
      "test_literals";
      "test_variadic_type_hint";
      "test_tuple_type_keyword";
      "test_trailing_commas";
      "context/test_extra_error_trivia";
      "test_funcall_with_type_arguments";
      "test_nested_namespace_declarations";
      "test_xhp_attributes";
      "test_xhp_require";
      "test_spaces_preserved_in_string_containing_expression";
      "test_inout_params";
      "test_degenerate_ternary";
    ] ~f:mapper

let error_tests =
  let mapper testname =
    make_test_case_from_files testname test_errors in
  List.map
  [
    "test_default_param_errors";
    "test_alias_errors";
    "test_method_modifier_errors";
    "test_errors_not_strict";
    "test_errors_strict";
    "test_no_errors_strict";
    "test_statement_errors";
    "test_expression_errors";
    "test_errors_method";
    "test_declaration_errors";
    "test_errors_class";
    "test_errors_array_type";
    "test_errors_variadic_param";
    "test_errors_variadic_param_default";
    "test_errors_statements";
    "test_implements_errors";
    "test_object_creation_errors";
    "test_classish_inside_function_errors";
    "test_list_expression_errors";
    "test_interface_method_errors";
    "test_abstract_classish_errors";
    "test_abstract_methodish_errors";
    "test_async_errors";
    "test_visibility_modifier_errors";
    "test_legal_php";
    "context/test_missing_name_in_expression";
    "context/test_nested_function_lite";
    "context/test_nested_function";
    "context/test_method_decl_extra_token";
    "context/test_recovery_to_classish1";
    "context/test_recovery_to_classish2";
    "context/test_recovery_to_classish3";
    "context/test_single_extra_token_recovery";
    "context/test_missing_foreach_value";
    "test_namespace_error_recovery";
    "test_correct_code1";
    "test_misspelling_recovery";
    "test_misspelling_recovery2";
    "test_group_use_errors";
    "test_abstract_initializers";
    "test_mixed_bracketed_unbracketed_namespaces1";
    "test_mixed_bracketed_unbracketed_namespaces2";
    "test_var_phpism";
    "test_var_phpism2";
    "test_var_phpism3";
    "test_xhp_attribute_enum_errors";
    "test_shapes";
    "test_abstract_final_errors";
    "test_content_before_header";
    "test_valid_php_no_markup_errors";
    "test_question_mark_end_tag_errors";
    "test_php_blocks_errors";
    "test_inout_params_errors";
    "test_variadic_ref_decorators";
    "test_lambda_variadic_errors";
    "test_lambda_no_typehints_errors";
    "test_is_expression_errors";
    "test_as_expression_errors";
  ] ~f:mapper

let test_data = minimal_tests @ trivia_tests @ error_tests @
                [
                  {
                    name = "test_mode_1";
                    source = "<?hh   ";
                    expected = "Lang:hhMode:Strict:falseHack:truePhp:false";
                    test_function = test_mode;
                    value_mapper = ident;
                  };
                  {
                    name = "test_mode_2";
                    source = "";
                    expected = "Lang:phpMode:Strict:falseHack:falsePhp:true";
                    test_function = test_mode;
                    value_mapper = ident;
                  };
                  {
                    name = "test_mode_3";
                    source = "<?hh // strict ";
                    expected = "Lang:hhMode:strictStrict:trueHack:truePhp:false";
                    test_function = test_mode;
                    value_mapper = ident;
                  };
                  {
                    name = "test_mode_4";
                    source = "<?php // strict "; (* Not strict! *)
                    expected = "Lang:phpMode:strictStrict:falseHack:falsePhp:true";
                    test_function = test_mode;
                    value_mapper = ident;
                  };
                  {
                    name = "test_mode_5";
                    source = "<?hh/";
                    expected = "Lang:hhMode:Strict:falseHack:truePhp:false";
                    test_function = test_mode;
                    value_mapper = ident;
                  };
                  {
                    name = "test_mode_6";
                    source = "<?hh//";
                    expected = "Lang:hhMode:Strict:falseHack:truePhp:false";
                    test_function = test_mode;
                    value_mapper = ident;
                  }
                ]

let driver test () =
  let actual = test.test_function test.source in
  try
    let expected = test.value_mapper test.expected in
    let actual = test.value_mapper actual in
    assert_equal expected actual
  with
    e ->
      write_expectation_to_file test.name actual;
      raise e

let run_test test =
  test.name >:: (driver test)

let run_tests tests =
  Printf.printf "%s" (Sys.getcwd());
  List.map tests ~f:run_test

let test_suite =
  "Full_fidelity_suite" >::: (run_tests test_data)

let main () =
  Printexc.record_backtrace true;
  run_test_tt_main test_suite

let _ = main ()
