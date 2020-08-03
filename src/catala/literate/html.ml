(* This file is part of the Catala compiler, a specification language for tax and social benefits
   computation rules. Copyright (C) 2020 Inria, contributor: Denis Merigoux
   <denis.merigoux@inria.fr>

   Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except
   in compliance with the License. You may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software distributed under the License
   is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express
   or implied. See the License for the specific language governing permissions and limitations under
   the License. *)

(** This modules weaves the source code and the legislative text together into a document that law
    professionals can understand. *)

module A = Ast
module P = Printf
module R = Re.Pcre
module C = Cli

let pre_html (s : string) = s

let wrap_html (code : string) (source_files : string list) (custom_pygments : string option)
    (language : Cli.language_option) : string =
  let language = C.reduce_lang language in
  let pygments = match custom_pygments with Some p -> p | None -> "pygmentize" in
  let css_file = Filename.temp_file "catala_css_pygments" "" in
  let pygments_args = [| "-f"; "html"; "-S"; "colorful"; "-a"; ".catala-code" |] in
  let cmd =
    Printf.sprintf "%s %s > %s" pygments (String.concat " " (Array.to_list pygments_args)) css_file
  in
  let return_code = Sys.command cmd in
  if return_code <> 0 then
    Errors.weaving_error
      (Printf.sprintf "pygmentize command \"%s\" returned with error code %d" cmd return_code);
  let oc = open_in css_file in
  let css_as_string = really_input_string oc (in_channel_length oc) in
  close_in oc;
  Printf.sprintf
    "<head>\n\
     <style>\n\
     %s\n\
     </style>\n\
     <meta http-equiv='Content-Type' content='text/html; charset=utf-8'/>\n\
     </head>\n\
     <h1>%s<br />\n\
     <small>%s Catala version %s</small>\n\
     </h1>\n\
     <p>\n\
     %s\n\
     </p>\n\
     <ul>\n\
     %s\n\
     </ul>\n\
     %s"
    css_as_string
    ( match language with
    | `Fr -> "Implémentation de texte législatif"
    | `En -> "Legislative text implementation" )
    (match language with `Fr -> "Document généré par" | `En -> "Document generated by")
    ( match Build_info.V1.version () with
    | None -> "n/a"
    | Some v -> Build_info.V1.Version.to_string v )
    ( match language with
    | `Fr -> "Fichiers sources tissés dans ce document"
    | `En -> "Source files weaved in this document" )
    (String.concat "\n"
       (List.map
          (fun filename ->
            let mtime = (Unix.stat filename).Unix.st_mtime in
            let ltime = Unix.localtime mtime in
            let ftime =
              Printf.sprintf "%d-%02d-%02d, %d:%02d" (1900 + ltime.Unix.tm_year)
                (ltime.Unix.tm_mon + 1) ltime.Unix.tm_mday ltime.Unix.tm_hour ltime.Unix.tm_min
            in
            Printf.sprintf "<li><tt>%s</tt>, %s %s</li>"
              (pre_html (Filename.basename filename))
              (match language with `Fr -> "dernière modification le" | `En -> "last modification")
              ftime)
          source_files))
    code

let pygmentize_code (c : string Pos.marked) (language : C.reduced_lang_option)
    (custom_pygments : string option) : string =
  C.debug_print (Printf.sprintf "Pygmenting the code chunk %s" (Pos.to_string (Pos.get_position c)));
  let temp_file_in = Filename.temp_file "catala_html_pygments" "in" in
  let temp_file_out = Filename.temp_file "catala_html_pygments" "out" in
  let oc = open_out temp_file_in in
  Printf.fprintf oc "%s" (Pos.unmark c);
  close_out oc;
  let pygments = match custom_pygments with Some p -> p | None -> "pygmentize" in
  let pygments_lexer = match language with `Fr -> "catala_fr" | `En -> "catala_en" in
  let pygments_args =
    [|
      "-l";
      pygments_lexer;
      "-f";
      "html";
      "-O";
      "style=colorful,anchorlinenos=True,lineanchors=\""
      ^ Pos.get_file (Pos.get_position c)
      ^ "\",linenos=table,linenostart="
      ^ string_of_int (Pos.get_start_line (Pos.get_position c));
      "-o";
      temp_file_out;
      temp_file_in;
    |]
  in
  let cmd = Printf.sprintf "%s %s" pygments (String.concat " " (Array.to_list pygments_args)) in
  let return_code = Sys.command cmd in
  if return_code <> 0 then
    Errors.weaving_error
      (Printf.sprintf "pygmentize command \"%s\" returned with error code %d" cmd return_code);
  let oc = open_in temp_file_out in
  let output = really_input_string oc (in_channel_length oc) in
  close_in oc;
  output

type program_state = InsideArticle | OutsideArticle

let program_item_to_html (i : A.program_item) (custom_pygments : string option)
    (language : C.reduced_lang_option) (state : program_state) : string * program_state =
  let closing_div =
    (* First we terminate the div of the previous article if need be *)
    match (i, state) with
    | (A.LawHeading _ | A.LawArticle _), InsideArticle -> "<!-- Closing article div -->\n</div>\n\n"
    | _ -> ""
  in
  let new_state =
    match (i, state) with
    | A.LawArticle _, _ -> InsideArticle
    | A.LawHeading _, InsideArticle -> OutsideArticle
    | _ -> state
  in
  (* Then we print the actual item *)
  let item_string =
    match i with
    | A.LawHeading (title, precedence) ->
        let h_number = precedence + 2 in
        P.sprintf "<h%d class='law-heading'>%s</h%d>" h_number (pre_html title) h_number
    | A.LawText t -> "<p class='law-text'>" ^ pre_html t ^ "</p>"
    | A.LawArticle a ->
        P.sprintf
          "<div class='article-container'>\n\n<div class='article-title'><a href='%s'>%s</a></div>"
          ( match (a.law_article_id, language) with
          | Some id, `Fr ->
              let ltime = Unix.localtime (Unix.time ()) in
              P.sprintf "https://beta.legifrance.gouv.fr/codes/id/%s/%d-%02d-%02d" id
                (1900 + ltime.Unix.tm_year) (ltime.Unix.tm_mon + 1) ltime.Unix.tm_mday
          | _ -> "#" )
          (pre_html (Pos.unmark a.law_article_name))
    | A.CodeBlock (_, c) | A.MetadataBlock (_, c) ->
        let date = "\\d\\d/\\d\\d/\\d\\d\\d\\d" in
        let syms = R.regexp (date ^ "|!=|<=|>=|--|->|\\*|\\/") in
        let syms_subst = function
          | "!=" -> "≠"
          | "<=" -> "≤"
          | ">=" -> "≥"
          | "--" -> "—"
          | "->" -> "→"
          | "*" -> "×"
          | "/" -> "÷"
          | s -> s
        in
        let pprinted_c = R.substitute ~rex:syms ~subst:syms_subst (Pos.unmark c) in
        let formatted_original_code =
          P.sprintf "<div class='code-wrapper'>\n<div class='filename'>%s</div>\n%s\n</div>"
            (Pos.get_file (Pos.get_position c))
            (pygmentize_code
               (Pos.same_pos_as ("/*" ^ pprinted_c ^ "*/") c)
               language custom_pygments)
        in
        formatted_original_code
    | A.LawInclude _ -> ""
  in
  (closing_div ^ item_string, new_state)

let ast_to_html (program : A.program) (custom_pygments : string option)
    (language : C.reduced_lang_option) : string =
  let i_s, _ =
    List.fold_left
      (fun (acc, state) i ->
        let i_s, new_state = program_item_to_html i custom_pygments language state in
        (i_s :: acc, new_state))
      ([], OutsideArticle) program.program_items
  in
  String.concat "\n\n" (List.rev i_s)
