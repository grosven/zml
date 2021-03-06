-module(zml).

% Main function
-export([compile/1, compile/2]).

% Utilities for special handlers:
-export([search_for_file/2, tmp_filename/0, tmp_filename/1, pull_in_file/2,
    new_tag/3, new_tag/4, get_tag/2, replace_tag/3]).

-define(DIR_TMP, ".tmp").
-define(DIR_JS,  "js").
-define(DIR_CSS, "css").
-define(DIR_IMG, "img").
-define(DIR_DYN, "dynamic").

compile(InFile) ->
  {ok, CWD} = file:get_cwd(),
  compile(InFile, CWD).

compile(InFile, SpecialDir) ->
  AST = zml_hand_parser:parse(zml_tokenizer:tokenize_file(InFile)),
  SourceFName = filename:absname(InFile),
  StagingDir = set_up_staging(),
  AST2 = run_specialized_handlers(AST, SourceFName, StagingDir, SpecialDir),
  Out = translate_ast_item(AST2, []),
  io:format("~s", [Out]),
  %ok = file:write_file(filename:join([StagingDir, "output.html"]), Out),
  StagingDir.

set_up_staging() ->
  {ok, CurrDir} = file:get_cwd(),
  BaseDir = tmp_filename(),
  DirMain = filename:join([CurrDir, BaseDir]),
  DirTmp =  filename:join([DirMain, ?DIR_TMP]),
  DirJS =   filename:join([DirMain, ?DIR_JS]),
  DirCSS =  filename:join([DirMain, ?DIR_CSS]),
  DirImg =  filename:join([DirMain, ?DIR_IMG]),
  DirDyn =  filename:join([DirMain, ?DIR_DYN]),
  file:make_dir(DirMain),
  file:make_dir(DirTmp),
  file:make_dir(DirJS),
  file:make_dir(DirCSS),
  file:make_dir(DirImg),
  file:make_dir(DirDyn),
  {DirMain, DirTmp, DirJS, DirCSS, DirImg, DirDyn}.


run_specialized_handlers(AST, SourceFN, StagingDir, SpecialDir) ->
  run_spec_handler_inner(AST, SourceFN, StagingDir, SpecialDir, AST).

run_spec_handler_inner([], _, _, _, NewAST) ->
  NewAST;
run_spec_handler_inner([{{Name,ID}, special, Attr, Children} | T],
    FSource, DStage, DSpec, FullAST) ->
  HandlerName = list_to_atom("zml_special_" ++ string:to_lower(Name)),
  case code:ensure_loaded(HandlerName) of
    {module, _} ->
      great;
    _ ->
      HandlerSource = filename:join([DSpec, HandlerName]),
      case code:load_abs(HandlerSource) of
        {module, _} ->
          whew;
        {error, What} ->
          erlang:error([
                "'",What,"' When trying to load handler for ",
                Name," special tag types."])
      end
  end,
  NewAST = HandlerName:run_handler(ID, Attr, Children, FullAST, FSource,
    DStage),
  run_spec_handler_inner(T, FSource, DStage, DSpec, NewAST);
run_spec_handler_inner([_H|T],FSource,DStage,DSpec,FullAST) ->
  run_spec_handler_inner(T, FSource, DStage, DSpec, FullAST).


translate_ast_item([], Acc) ->
  lists:reverse(Acc);
translate_ast_item([[$< | _] = String | [Next | _] = T], Acc)
when is_list(Next) ->
  translate_ast_item(T, [String | Acc]);
translate_ast_item([String | [Next | _] = T], Acc)
when is_list(String) and is_list(Next) ->
  translate_ast_item(T, [" " | [String | Acc]]);
translate_ast_item([String | T], Acc) when is_list(String) ->
  translate_ast_item(T, [String | Acc]);
% In case a special one still remains, remove ID and pretend it's normal
translate_ast_item([{{Name,_ID},Type,Attributes,Children} | T], Acc) ->
  translate_ast_item([{Name, Type, Attributes, Children} | T], Acc);
translate_ast_item([{Code,code,[],Children} | T], Acc) ->
  ToAppend = ["!!CODE!!",
    string:join(Code, " "),
    "!!",
    translate_ast_item(Children, []),
    "!!END!!"],
  translate_ast_item(T, [ToAppend | Acc]);
translate_ast_item([{Name,_Type,Attributes,[]} | T], Acc) ->
  ToAppend = ["<", Name,
    translate_attributes(Attributes), "/>"],
  translate_ast_item(T, [ToAppend | Acc]);
translate_ast_item([{Name,_Type,Attributes,Children} | T], Acc) ->
  ToAppend = [
    "<", Name,
    translate_attributes(Attributes), ">",
    translate_ast_item(Children, []),
    "</", Name, ">"],
  translate_ast_item(T, [ToAppend | Acc]).

translate_attributes([]) ->
  "";
translate_attributes(Atts) when is_tuple(Atts) ->
  lists:foldl(fun out_attr/2, [], dict:to_list(Atts));
translate_attributes(Atts) ->
  lists:foldl(fun out_attr/2, [], Atts).
out_attr({Name, Values}, Acc) ->
  [" ", Name, "=\"", string:join(Values, " "), "\"" | Acc].


%% -------------------- Utilities for special handlers -----------------------

search_for_file(File, Path) ->
  Res = os:cmd("find '" ++ Path ++ "' -name '" ++ File ++ "'"),
  string:tokens(Res, "\n").

tmp_filename() ->
  tmp_filename(".tmp_").
tmp_filename(Pref) ->
  Pref ++ integer_to_list(erlang:phash2(make_ref())).

% Tries to copy a file to the destination.  Tries loading it with curl if a
% normal file copy doesn't seem to work.  Returns ok or {error, Reason}
pull_in_file(Name, DestDirAndName) ->
  TryCurl =
    case string:str(Name, "://") of
      0 ->
        case file:copy(Name, DestDirAndName) of
          {ok, _} -> false;
          {error, _} -> "file://" ++ Name
        end;
      _ -> Name
    end,

  case TryCurl of
    false -> ok;
    _ ->
      Res = string:strip(os:cmd("curl -sS -o '" ++ DestDirAndName ++ "' '"
          ++ TryCurl ++ "'")),
      case Res of
        [] -> ok;
        Error -> {error, Error}
      end
  end.

new_tag(Name, AttrList, Children) when is_list(AttrList) ->
  new_tag(Name, dict:from_list(AttrList), Children);
new_tag(Name, Attr, Children) when is_atom(Name) ->
  new_tag(atom_to_list(Name), normal, Attr, Children);
new_tag(Name, Attr, Children) when is_tuple(Name) ->
  new_tag(Name, special, Attr, Children).

new_tag(Name, Type, Attr, Children) when is_atom(Name) ->
  new_tag(atom_to_list(Name), Type, Attr, Children);
new_tag(Name, Type, Attr, Children) ->
  {Name, Type, Attr, Children}.


%% Recursively replaces any tags with existing Name with the new attributes and
%% children specified. Search is the search path as a list of tag names, such as:
%% [{"html", ID}, "body", "table"] to find the table tag within the body tag
%% within the special html tag with the given ID.  No mechanism yet for
%% wildcard IDs, wildcard tagnames, looking at attributes, or "lookahead" at
%% children.
replace_tag(AST, Search, NewTag) ->
  replace_tag(AST, lists:reverse(Search), NewTag, [], []).
replace_tag([], _, _, _, Acc) ->
  lists:reverse(Acc);
replace_tag([H|T], Search, NewTag, CurrPath, Acc) when is_list(H) ->
  replace_tag(T, Search, NewTag, CurrPath, [H | Acc]);
replace_tag([{Name,Tp,Att,Children} | T], Search, NewTag, CurrPath, Acc) ->
  EqPath = lists:sublist([Name | CurrPath], length(Search)),
  case EqPath == Search of
    true ->
      % We won't recurse into new children, because that would inevitably lead
      % to infinite recursion if someone tried to take advantage of it.
      replace_tag(T, Search, NewTag, CurrPath, [NewTag | Acc]);
    false ->
      NewChildren = replace_tag(Children,Search,NewTag, [Name | CurrPath],[]),
      replace_tag(T, Search, NewTag, CurrPath,
        [{Name,Tp,Att,NewChildren} | Acc])
  end.

%% Similar to replace_tag, only is stops when it finds it and returns it
%% instead of returning a rebuilt full AST.
get_tag(AST, Search) ->
  get_tag(AST, lists:reverse(Search), []).
get_tag([], _, _) ->
  undefined;
get_tag([H|T], Search, CurrPath) when is_list(H) ->
  get_tag(T, Search, CurrPath);
get_tag([{Name,_,_,Children} = Tag | T], Search, CurrPath) ->
  EqPath = lists:sublist([Name | CurrPath], length(Search)),
  case EqPath == Search of
    true ->
      Tag;
    false ->
      case get_tag(Children, Search, [Name | CurrPath]) of
        undefined ->
          get_tag(T, Search, CurrPath);
        FoundTag ->
          FoundTag
      end
  end.

