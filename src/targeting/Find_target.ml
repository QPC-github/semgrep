module In = Input_to_core_t
module Resp = Output_from_core_t

(*************************************************************************)
(* Prelude *)
(*************************************************************************)
(*
   Find and filter targets.

   Performance: The step that collects global targets is a one-time operation
   that can be relatively expensive (O(number of files)).
   The second step is done for each pair (rule, target) and can
   become problematic since the number of such pairs is O(number of targets
   * number of rules). This is why we cache the results of this step.
   This allows reducing the number of rules to the number of different
   languages and patterns used by the rules.
 *)

(*
   Handles all file include/exclude logic for semgrep

   Assumes file system does not change during it's existence to cache
   files for a given language etc. If file system changes (i.e. git checkout),
   create a new TargetManager object

   If respect_git_ignore is true then will only consider files that are
   tracked or (untracked but not ignored) by git

   If git_baseline_commit is true then will only consider files that have
   changed since that commit

   If allow_unknown_extensions is set then targets with extensions that are
   not understood by semgrep will always be returned by get_files. Else will discard
   targets with unknown extensions

   TargetManager not to be confused with https://jobs.target.com/search-jobs/store%20manager

   Translated from target_manager.py
*)

(*************************************************************************)
(* Types *)
(*************************************************************************)

type conf = {
  exclude : string list;
  include_ : string list;
  max_target_bytes : int;
  respect_git_ignore : bool;
  (* TODO? use, and better parsing of the string? a Git.version type? *)
  baseline_commit : string option;
  (* TODO: use *)
  scan_unknown_extensions : bool;
}
[@@deriving show]

type baseline_handler = TODO
type file_ignore = TODO
type path = string

(*
   Some rules will use 'include' (required_path_patterns) and 'exclude'
   (excluded_path_patterns) to select targets that don't have an extension
   such as 'Dockerfile'. We expect most rules written for a language
   to use the same combination of include/exclude. This allows caching
   across the many rules that target the same language.
*)
type target_cache_key = {
  path : path;
  lang : Xlang.t;
  required_path_patterns : string list;
  excluded_path_patterns : string list;
}

type target_cache = (target_cache_key, bool) Hashtbl.t

(*************************************************************************)
(* Helpers *)
(*************************************************************************)

let deduplicate_list l =
  let tbl = Hashtbl.create 1000 in
  List.filter
    (fun x ->
      if Hashtbl.mem tbl x then false
      else (
        Hashtbl.add tbl x ();
        true))
    l

(*************************************************************************)
(* Entry points *)
(*************************************************************************)

let sort_targets_by_decreasing_size targets =
  targets
  |> Common.map (fun target -> (target, Common2.filesize target.In.path))
  |> List.sort (fun (_, (a : int)) (_, b) -> compare b a)
  |> Common.map fst

let sort_files_by_decreasing_size files =
  files
  |> Common.map (fun file -> (file, Common2.filesize file))
  |> List.sort (fun (_, (a : int)) (_, b) -> compare b a)
  |> Common.map fst

(*
   Filter files can make suitable targets, independently from specific
   rules or languages.

   'sort_by_decr_size' should always be true but we keep it as an option
   for compatibility with the legacy implementation 'files_of_dirs_or_files'.

   '?lang' is a legacy option that shouldn't be used in
   the language-independent 'select_global_targets'.
*)
let global_filter ~opt_lang ~sort_by_decr_size paths =
  let paths, skipped1 = Skip_target.exclude_files_in_skip_lists paths in
  let paths, skipped2 =
    match opt_lang with
    | None -> (paths, [])
    | Some lang -> Guess_lang.inspect_files lang paths
  in
  let paths, skipped3 = Skip_target.exclude_big_files paths in
  let paths, skipped4 = Skip_target.exclude_minified_files paths in
  let skipped = Common.flatten [ skipped1; skipped2; skipped3; skipped4 ] in
  let sorted_paths =
    if sort_by_decr_size then sort_files_by_decreasing_size paths else paths
  in
  let sorted_skipped =
    List.sort
      (fun (a : Resp.skipped_target) b -> String.compare a.path b.path)
      skipped
  in
  (sorted_paths, sorted_skipped)

let select_global_targets ?(includes = []) ?(excludes = []) ~max_target_bytes
    ~respect_git_ignore ?(baseline_handler : baseline_handler option)
    ?(file_ignore : file_ignore option) paths =
  let paths =
    List.concat_map (List_files.list_regular_files ~keep_root:true) paths
    |> deduplicate_list
  in
  let paths, skipped_paths =
    global_filter ~opt_lang:None ~sort_by_decr_size:true paths
  in
  (* !!!TODO!!! *)
  ignore includes;
  ignore excludes;
  ignore max_target_bytes (* from the semgrep CLI, not semgrep-core *);
  ignore respect_git_ignore;
  ignore baseline_handler;
  ignore file_ignore;
  (paths, skipped_paths)

(* TODO: can merge with select_global_targets *)
let get_targets conf target_roots =
  select_global_targets ~includes:conf.include_ ~excludes:conf.exclude
    ~max_target_bytes:conf.max_target_bytes
    ~respect_git_ignore:conf.respect_git_ignore target_roots

(*************************************************************************)
(* TODO *)
(*************************************************************************)

let create_cache () = Hashtbl.create 1000

let match_glob_pattern ~pat path =
  (* TODO *)
  ignore pat;
  ignore path;
  true

let match_a_required_path_pattern required_path_patterns path =
  match required_path_patterns with
  | [] -> (* <grimacing face emoji> *) true
  | pats -> List.exists (fun pat -> match_glob_pattern ~pat path) pats

let match_all_excluded_path_patterns excluded_path_patterns path =
  List.for_all (fun pat -> match_glob_pattern ~pat path) excluded_path_patterns

let match_language (xlang : Xlang.t) path =
  match xlang with
  | L (lang, langs) ->
      (* ok if the file appears to be in one of rule's languages *)
      List.exists
        (fun lang -> Guess_lang.inspect_file_p lang path)
        (lang :: langs)
  | LRegex
  | LGeneric ->
      true

let filter_target_for_lang ~cache ~lang ~required_path_patterns
    ~excluded_path_patterns path =
  let key : target_cache_key =
    { path; lang; required_path_patterns; excluded_path_patterns }
  in
  match Hashtbl.find_opt cache key with
  | Some res -> res
  | None ->
      let res =
        match_a_required_path_pattern required_path_patterns path
        && match_all_excluded_path_patterns excluded_path_patterns path
        && match_language lang path
      in
      Hashtbl.replace cache key res;
      res

let filter_target_for_rule cache (rule : Rule.t) (path : path) =
  let required_path_patterns, excluded_path_patterns =
    match rule.paths with
    | Some { include_; exclude } -> (include_, exclude)
    | None -> ([], [])
  in
  filter_target_for_lang ~cache ~lang:rule.languages ~required_path_patterns
    ~excluded_path_patterns path

let filter_targets_for_rule cache rule files =
  List.filter (filter_target_for_rule cache rule) files

(*************************************************************************)
(* Legacy *)
(*************************************************************************)

(* Legacy semgrep-core implementation, used when receiving targets from
   the Python wrapper. *)
let files_of_dirs_or_files ?(keep_root_files = true)
    ?(sort_by_decr_size = false) opt_lang roots =
  let explicit_targets, paths =
    if keep_root_files then
      roots
      |> List.partition (fun path ->
             Sys.file_exists path && not (Sys.is_directory path))
    else (roots, [])
  in
  let paths = Common.files_of_dir_or_files_no_vcs_nofilter paths in
  let paths, skipped = global_filter ~opt_lang ~sort_by_decr_size paths in
  let paths = explicit_targets @ paths in
  let sorted_paths =
    if sort_by_decr_size then sort_files_by_decreasing_size paths
    else List.sort String.compare paths
  in
  let sorted_skipped =
    List.sort
      (fun (a : Resp.skipped_target) b -> String.compare a.path b.path)
      skipped
  in
  (sorted_paths, sorted_skipped)
