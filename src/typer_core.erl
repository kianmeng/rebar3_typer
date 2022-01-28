%%% @doc An Erlang/OTP application that shows type information
%%%      for Erlang modules to the user.  Additionally, it can
%%%      annotate the code of files with such type information.
%%%      This module is basically a carbon-copy of Erlang/OTP's typer,
%%%      but built in a way that it can be executed not as a script.
-module(typer_core).

-hank([{unnecessary_function_arguments, [swallow_output]}]).

-elvis([{elvis_style,
         atom_naming_convention,
         #{regex => "^([a-z][a-z0-9]*(_*|[A-Z])?)*$"}},
        {elvis_style, no_debug_call, disable},
        {elvis_style, nesting_level, #{level => 5}}]).

-export([run/1]).

-type printer(Return) :: fun((io:format(), [term()]) -> Return).
-type io() ::
    #{debug := printer(_),
      info := printer(_),
      warn := printer(_),
      abort := printer(no_return())}.
-type mode() :: show | show_exported | annotate | annotate_inc_files | annotate_in_place.
-type opts() ::
    #{mode := mode(),
      show_succ => boolean(),
      no_spec => boolean(),
      edoc => boolean(),
      plt => file:filename(),
      trusted => [file:filename()],
      files => [file:filename()],
      files_r => [file:filename_all()],
      macros => [{atom(), term()}],
      includes => [file:filename_all()],
      io => io()}.

-export_type([opts/0]).

-record(analysis,
        {mode :: mode() | undefined,
         macros = [] :: [{atom(), term()}],
         includes = [] :: [file:filename()],
         codeserver = dialyzer_codeserver:new() :: dialyzer_codeserver:codeserver(),
         callgraph = dialyzer_callgraph:new() :: dialyzer_callgraph:callgraph(),
         files = [] :: [file:filename()],   % absolute names
         plt = none :: none | file:filename(),
         no_spec = false :: boolean(),
         show_succ = false :: boolean(),
         %% For choosing between specs or edoc @spec comments
         edoc = false :: boolean(),
         %% Files in 'fms' are compilable with option 'to_pp'; we keep them
         %% as {FileName, ModuleName} in case the ModuleName is different
         fms = [] :: [{file:filename(), module()}],
         ex_func = map_dict_new() :: map_dict(),
         record = map_dict_new() :: map_dict(),
         func = map_dict_new() :: map_dict(),
         inc_func = map_dict_new() :: map_dict(),
         trust_plt = dialyzer_plt:new() :: dialyzer_plt:plt(),
         io = default_io() :: io()}).

-type analysis() :: #analysis{}.

-record(args,
        {files = [] :: [file:filename()],
         files_r = [] :: [file:filename()],
         trusted = [] :: [file:filename()]}).

-type args() :: #args{}.

-spec run(opts()) -> ok.
run(Opts) ->
    _ = io:setopts(standard_error, [{encoding, unicode}]),
    _ = io:setopts([{encoding, unicode}]),
    {Args, Analysis} = process_cl_args(Opts),
    msg(debug, "Opts: ~p\nArgs: ~p\nAnalysis: ~p", [Opts, Args, Analysis], Analysis),
    Timer = dialyzer_timing:init(false),
    TrustedFiles = filter_fd(Args#args.trusted, [], fun is_erl_file/1, Analysis),
    Analysis2 = extract(Analysis, TrustedFiles),
    AllFiles = get_all_files(Args, Analysis2),
    Analysis3 = Analysis2#analysis{files = AllFiles},
    Analysis4 = collect_info(Analysis3),
    TypeInfo = get_type_info(Analysis4),
    dialyzer_timing:stop(Timer),
    show_or_annotate(TypeInfo),
    ok.

-spec extract(analysis(), [file:filename()]) -> analysis().
extract(#analysis{macros = Macros,
                  includes = Includes,
                  trust_plt = TrustPLT} =
            Analysis,
        TrustedFiles) ->
    msg(debug, "Extracting trusted typer info...", [], Analysis),
    Ds = [{d, Name, Value} || {Name, Value} <- Macros],
    CodeServer = dialyzer_codeserver:new(),
    Fun = fun(File, CS) ->
             %% We include one more dir; the one above the one we are trusting
             %% E.g, for /home/tests/typer_ann/test.ann.erl, we should include
             %% /home/tests/ rather than /home/tests/typer_ann/
             AllIncludes =
                 [filename:dirname(
                      filename:dirname(File))
                  | Includes],
             Is = [{i, Dir} || Dir <- AllIncludes],
             CompOpts = dialyzer_utils:src_compiler_opts() ++ Is ++ Ds,
             case dialyzer_utils:get_core_from_src(File, CompOpts) of
                 {ok, Core} ->
                     case dialyzer_utils:get_record_and_type_info(Core) of
                         {ok, RecDict} ->
                             Mod = list_to_atom(filename:basename(File, ".erl")),
                             case dialyzer_utils:get_spec_info(Mod, Core, RecDict) of
                                 {ok, SpecDict, CbDict} ->
                                     CS1 = dialyzer_codeserver:store_temp_records(Mod, RecDict, CS),
                                     dialyzer_codeserver:store_temp_contracts(Mod,
                                                                              SpecDict,
                                                                              CbDict,
                                                                              CS1);
                                 {error, Reason} ->
                                     compile_error([Reason], Analysis)
                             end;
                         {error, Reason} ->
                             compile_error([Reason], Analysis)
                     end;
                 {error, Reason} ->
                     compile_error(Reason, Analysis)
             end
          end,
    CodeServer1 = lists:foldl(Fun, CodeServer, TrustedFiles),
    %% Process remote types
    NewCodeServer =
        try
            CodeServer2 =
                dialyzer_utils:merge_types(CodeServer1,
                                           TrustPLT), % XXX change to the PLT?
            NewExpTypes = dialyzer_codeserver:get_temp_exported_types(CodeServer1),
            case sets:size(NewExpTypes) of
                0 ->
                    ok
            end,
            CodeServer3 = dialyzer_codeserver:finalize_exported_types(NewExpTypes, CodeServer2),
            CodeServer4 = dialyzer_utils:process_record_remote_types(CodeServer3),
            dialyzer_contracts:process_contract_remote_types(CodeServer4)
        catch
            _:{error, ErrorMsg} ->
                compile_error(ErrorMsg, Analysis)
        end,
    %% Create TrustPLT
    ContractsDict = dialyzer_codeserver:get_contracts(NewCodeServer),
    Contracts =
        orddict:from_list(
            dict:to_list(ContractsDict)),
    NewTrustPLT = dialyzer_plt:insert_contract_list(TrustPLT, Contracts),
    Analysis#analysis{trust_plt = NewTrustPLT}.

%%--------------------------------------------------------------------

-spec get_type_info(analysis()) -> analysis().
get_type_info(#analysis{callgraph = CallGraph,
                        trust_plt = TrustPLT,
                        codeserver = CodeServer} =
                  Analysis) ->
    StrippedCallGraph = remove_external(CallGraph, TrustPLT, Analysis),
    msg(debug, "Analyizing callgraph...", [], Analysis),
    try
        NewPlt = dialyzer_succ_typings:analyze_callgraph(StrippedCallGraph, TrustPLT, CodeServer),
        Analysis#analysis{callgraph = StrippedCallGraph, trust_plt = NewPlt}
    catch
        error:What:Stacktrace ->
            fatal_error(io_lib:format("Analysis failed with message: ~tp", [{What, Stacktrace}]),
                        Analysis);
        _:{dialyzer_succ_typing_error, Msg} ->
            fatal_error(io_lib:format("Analysis failed with message: ~ts", [Msg]), Analysis)
    end.

-spec remove_external(dialyzer_callgraph:callgraph(), dialyzer_plt:plt(), analysis()) ->
                         dialyzer_callgraph:callgraph().
remove_external(CallGraph, PLT, Analysis) ->
    {StrippedCG0, Ext} = dialyzer_callgraph:remove_external(CallGraph),
    case get_external(Ext, PLT) of
        [] ->
            ok;
        Externals ->
            msg(warn, " Unknown functions: ~tp", [lists:usort(Externals)], Analysis),
            ExtTypes = rcv_ext_types(),
            case ExtTypes of
                [] ->
                    ok;
                _ ->
                    msg(warn, " Unknown types: ~tp", [ExtTypes], Analysis)
            end
    end,
    StrippedCG0.

-spec get_external([{mfa(), mfa()}], dialyzer_plt:plt()) -> [mfa()].
get_external(Exts, Plt) ->
    Fun = fun({_From, To = {M, F, A}}, Acc) ->
             case dialyzer_plt:contains_mfa(Plt, To) of
                 false ->
                     case erl_bif_types:is_known(M, F, A) of
                         true ->
                             Acc;
                         false ->
                             [To | Acc]
                     end;
                 true ->
                     Acc
             end
          end,
    lists:foldl(Fun, [], Exts).

%%--------------------------------------------------------------------
%% Showing type information or annotating files with such information.
%%--------------------------------------------------------------------

-define(TYPER_ANN_DIR, "typer_ann").

-type line() :: non_neg_integer().
-type fa() :: {atom(), arity()}.
-type func_info() :: {line(), atom(), arity()}.

-record(info,
        {records = maps:new() :: erl_types:type_table(),
         functions = [] :: [func_info()],
         types = map_dict_new() :: map_dict(),
         edoc = false :: boolean()}).
-record(inc, {map = map_dict_new() :: map_dict(), filter = [] :: [file:filename()]}).

-type inc() :: #inc{}.

-spec show_or_annotate(analysis()) -> ok.
show_or_annotate(#analysis{mode = Mode, fms = Files} = Analysis) ->
    case Mode of
        show ->
            show(Analysis);
        show_exported ->
            show(Analysis);
        Mode when Mode =:= annotate orelse Mode =:= annotate_in_place ->
            Fun = fun({File, Module}) ->
                     Info = get_final_info(File, Module, Analysis),
                     write_typed_file(File, Info, Analysis)
                  end,
            lists:foreach(Fun, Files);
        annotate_inc_files ->
            IncInfo = write_and_collect_inc_info(Analysis),
            write_inc_files(IncInfo, Analysis)
    end.

write_and_collect_inc_info(Analysis) ->
    Fun = fun({File, Module}, Inc) ->
             Info = get_final_info(File, Module, Analysis),
             write_typed_file(File, Info, Analysis),
             IncFuns = get_functions(File, Analysis),
             collect_imported_functions(IncFuns, Info#info.types, Inc, Analysis)
          end,
    NewInc = lists:foldl(Fun, #inc{}, Analysis#analysis.fms),
    clean_inc(NewInc).

write_inc_files(Inc, Analysis) ->
    Fun = fun(File) ->
             Val = map_dict_lookup(File, Inc#inc.map),
             %% Val is function with its type info
             %% in form [{{Line,F,A},Type}]
             Functions = [Key || {Key, _} <- Val],
             Val1 = [{{F, A}, Type} || {{_Line, F, A}, Type} <- Val],
             Info =
                 #info{types = map_dict_from_list(Val1),
                       records = maps:new(),
                       %% Note we need to sort functions here!
                       functions = lists:keysort(1, Functions)},
             msg(debug, "Types ~tp", [Info#info.types], Analysis),
             msg(debug, "Functions ~tp", [Info#info.functions], Analysis),
             msg(debug, "Records ~tp", [Info#info.records], Analysis),
             write_typed_file(File, Info, Analysis)
          end,
    lists:foreach(Fun, dict:fetch_keys(Inc#inc.map)).

show(Analysis) ->
    Fun = fun({File, Module}) ->
             Info = get_final_info(File, Module, Analysis),
             show_type_info(File, Info, Analysis)
          end,
    lists:foreach(Fun, Analysis#analysis.fms).

get_final_info(File, Module, Analysis) ->
    Records = get_records(File, Analysis),
    Types = get_types(Module, Analysis, Records),
    Functions = get_functions(File, Analysis),
    Edoc = Analysis#analysis.edoc,
    #info{records = Records,
          functions = Functions,
          types = Types,
          edoc = Edoc}.

collect_imported_functions(Functions, Types, Inc, Analysis) ->
    %% Coming from other sourses, including:
    %% FIXME: How to deal with yecc-generated file????
    %%     --.yrl (yecc-generated file)???
    %%     -- yeccpre.hrl (yecc-generated file)???
    %%     -- other cases
    Fun = fun({File, _} = Obj, I) ->
             case is_yecc_gen(File, I) of
                 {true, NewI} ->
                     NewI;
                 {false, NewI} ->
                     check_imported_functions(Obj, NewI, Types, Analysis)
             end
          end,
    lists:foldl(Fun, Inc, Functions).

-spec is_yecc_gen(file:filename(), inc()) -> {boolean(), inc()}.
is_yecc_gen(File, #inc{filter = Fs} = Inc) ->
    case lists:member(File, Fs) of
        true ->
            {true, Inc};
        false ->
            case filename:extension(File) of
                ".yrl" ->
                    Rootname = filename:rootname(File, ".yrl"),
                    Obj = Rootname ++ ".erl",
                    case lists:member(Obj, Fs) of
                        true ->
                            {true, Inc};
                        false ->
                            NewInc = Inc#inc{filter = [Obj | Fs]},
                            {true, NewInc}
                    end;
                _ ->
                    case filename:basename(File) of
                        "yeccpre.hrl" ->
                            {true, Inc};
                        _ ->
                            {false, Inc}
                    end
            end
    end.

check_imported_functions({File, {Line, F, A}}, Inc, Types, Analysis) ->
    IncMap = Inc#inc.map,
    FA = {F, A},
    Type = get_type_info(FA, Types, Analysis),
    case map_dict_lookup(File, IncMap) of
        none -> %% File is not added. Add it
            Obj = {File, [{FA, {Line, Type}}]},
            NewMap = map_dict_insert(Obj, IncMap),
            Inc#inc{map = NewMap};
        Val -> %% File is already in. Check.
            case lists:keyfind(FA, 1, Val) of
                false ->
                    %% Function is not in; add it
                    Obj = {File, Val ++ [{FA, {Line, Type}}]},
                    NewMap = map_dict_insert(Obj, IncMap),
                    Inc#inc{map = NewMap};
                Type ->
                    %% Function is in and with same type
                    Inc;
                _ ->
                    %% Function is in but with diff type
                    inc_warning(FA, File, Analysis),
                    Elem = lists:keydelete(FA, 1, Val),
                    NewMap =
                        case Elem of
                            [] ->
                                map_dict_remove(File, IncMap);
                            _ ->
                                map_dict_insert({File, Elem}, IncMap)
                        end,
                    Inc#inc{map = NewMap}
            end
    end.

inc_warning({F, A}, File, Analysis) ->
    msg(warn,
        "      ***Warning: Skip function ~tp/~p "
        "in file ~tp because of inconsistent type",
        [F, A, File],
        Analysis).

clean_inc(Inc) ->
    Inc1 = remove_yecc_generated_file(Inc),
    normalize_obj(Inc1).

remove_yecc_generated_file(#inc{filter = Filter} = Inc) ->
    Fun = fun(Key, #inc{map = Map} = I) -> I#inc{map = map_dict_remove(Key, Map)} end,
    lists:foldl(Fun, Inc, Filter).

normalize_obj(TmpInc) ->
    Fun = fun(Key, Val, Inc) ->
             NewVal = [{{Line, F, A}, Type} || {{F, A}, {Line, Type}} <- Val],
             map_dict_insert({Key, NewVal}, Inc)
          end,
    TmpInc#inc{map = map_dict_fold(Fun, map_dict_new(), TmpInc#inc.map)}.

get_records(File, Analysis) ->
    map_dict_lookup(File, Analysis#analysis.record).

get_types(Module, Analysis, Records) ->
    TypeInfoPlt = Analysis#analysis.trust_plt,
    TypeInfo =
        case dialyzer_plt:lookup_module(TypeInfoPlt, Module) of
            none ->
                [];
            {value, List} ->
                List
        end,
    CodeServer = Analysis#analysis.codeserver,
    TypeInfoList =
        case Analysis#analysis.show_succ of
            true ->
                [convert_type_info(I) || I <- TypeInfo];
            false ->
                [get_type(I, CodeServer, Records, Analysis) || I <- TypeInfo]
        end,
    map_dict_from_list(TypeInfoList).

convert_type_info({{_M, F, A}, Range, Arg}) ->
    {{F, A}, {Range, Arg}}.

get_type({{M, F, A} = MFA, Range, Arg}, CodeServer, Records, Analysis) ->
    case dialyzer_codeserver:lookup_mfa_contract(MFA, CodeServer) of
        error ->
            {{F, A}, {Range, Arg}};
        {ok, {_FileLine, Contract, _Xtra}} ->
            Sig = erl_types:t_fun(Arg, Range),
            case dialyzer_contracts:check_contract(Contract, Sig) of
                ok ->
                    {{F, A}, {contract, Contract}};
                {range_warnings, _} ->
                    {{F, A}, {contract, Contract}};
                {error, {overlapping_contract, []}} ->
                    {{F, A}, {contract, Contract}};
                {error, invalid_contract} ->
                    CString = dialyzer_contracts:contract_to_string(Contract),
                    SigString = dialyzer_utils:format_sig(Sig, Records),
                    Msg = io_lib:format("Error in contract of function ~w:~tw/~w\n"
                                        "\t The contract is: "
                                        ++ CString
                                        ++ "\n"
                                        ++ "\t but the inferred signature is: ~ts",
                                        [M, F, A, SigString]),
                    fatal_error(Msg, Analysis);
                {error, ErrorStr}
                    when is_list(ErrorStr) -> % ErrorStr is a string()
                    Msg = io_lib:format("Error in contract of function ~w:~tw/~w: ~ts",
                                        [M, F, A, ErrorStr]),
                    fatal_error(Msg, Analysis)
            end
    end.

get_functions(File, Analysis) ->
    case Analysis#analysis.mode of
        show ->
            Funcs = map_dict_lookup(File, Analysis#analysis.func),
            IncFuncs = map_dict_lookup(File, Analysis#analysis.inc_func),
            remove_module_info(Funcs) ++ normalize_inc_funcs(IncFuncs);
        show_exported ->
            ExFuncs = map_dict_lookup(File, Analysis#analysis.ex_func),
            remove_module_info(ExFuncs);
        Mode when Mode =:= annotate orelse Mode =:= annotate_in_place ->
            Funcs = map_dict_lookup(File, Analysis#analysis.func),
            remove_module_info(Funcs);
        annotate_inc_files ->
            map_dict_lookup(File, Analysis#analysis.inc_func)
    end.

normalize_inc_funcs(Functions) ->
    [FunInfo || {_FileName, FunInfo} <- Functions].

-spec remove_module_info([func_info()]) -> [func_info()].
remove_module_info(FunInfoList) ->
    F = fun ({_, module_info, 0}) ->
                false;
            ({_, module_info, 1}) ->
                false;
            ({Line, F, A}) when is_integer(Line), is_atom(F), is_integer(A) ->
                true
        end,
    lists:filter(F, FunInfoList).

write_typed_file(File, Info, #analysis{mode = Mode} = Analysis) ->
    msg(info, "      Processing file: ~tp", [File], Analysis),
    Dir = filename:dirname(File),
    RootName =
        filename:basename(
            filename:rootname(File)),
    Ext = filename:extension(File),
    case Mode of
        annotate_in_place ->
            write_typed_file(File, Info, File, Analysis);
        _ ->
            TyperAnnDir = filename:join(Dir, ?TYPER_ANN_DIR),
            TmpNewFilename = lists:concat([RootName, ".ann", Ext]),
            NewFileName = filename:join(TyperAnnDir, TmpNewFilename),
            case file:make_dir(TyperAnnDir) of
                {error, Reason} ->
                    case Reason of
                        eexist -> %% TypEr dir exists; remove old typer files if they exist
                            delete_file(NewFileName, Analysis),
                            write_typed_file(File, Info, NewFileName, Analysis);
                        enospc ->
                            Msg = io_lib:format("Not enough space in ~tp", [Dir]),
                            fatal_error(Msg, Analysis);
                        eacces ->
                            Msg = io_lib:format("No write permission in ~tp", [Dir]),
                            fatal_error(Msg, Analysis);
                        _ ->
                            Msg = io_lib:format("Unhandled error ~ts when writing ~tp",
                                                [Reason, Dir]),
                            fatal_error(Msg, Analysis)
                    end;
                ok -> %% Typer dir does NOT exist
                    write_typed_file(File, Info, NewFileName, Analysis)
            end
    end.

-spec delete_file(file:filename_all(), analysis()) -> ok.
delete_file(File, Analysis) ->
    case file:delete(File) of
        ok ->
            ok;
        {error, enoent} ->
            ok;
        {error, _} ->
            Msg = io_lib:format("Error in deleting file ~ts", [File]),
            fatal_error(Msg, Analysis)
    end.

write_typed_file(File, Info, NewFileName, #analysis{mode = Mode} = Analysis) ->
    {ok, Binary} = file:read_file(File),
    case Mode of
        annotate_in_place ->
            delete_file(NewFileName, Analysis);
        _ ->
            ok
    end,
    Chars = unicode:characters_to_list(Binary),
    write_typed_file(Chars, NewFileName, Info, 1, [], Analysis),
    msg(info, "             Saved as: ~tp", [NewFileName], Analysis).

write_typed_file(Chars, File, #info{functions = []}, _LNo, _Acc, _Analysis) ->
    ok = file:write_file(File, unicode:characters_to_binary(Chars), [append]);
write_typed_file([Ch | Chs] = Chars, File, Info, LineNo, Acc, Analysis) ->
    [{Line, F, A} | RestFuncs] = Info#info.functions,
    case Line of
        1 -> %% This will happen only for inc files
            ok = raw_write(F, A, Info, File, [], Analysis),
            NewInfo = Info#info{functions = RestFuncs},
            NewAcc = [],
            write_typed_file(Chars, File, NewInfo, Line, NewAcc, Analysis);
        _ ->
            case Ch of
                10 ->
                    NewLineNo = LineNo + 1,
                    {NewInfo, NewAcc} =
                        case NewLineNo of
                            Line ->
                                ok = raw_write(F, A, Info, File, [Ch | Acc], Analysis),
                                {Info#info{functions = RestFuncs}, []};
                            _ ->
                                {Info, [Ch | Acc]}
                        end,
                    write_typed_file(Chs, File, NewInfo, NewLineNo, NewAcc, Analysis);
                _ ->
                    write_typed_file(Chs, File, Info, LineNo, [Ch | Acc], Analysis)
            end
    end.

raw_write(F, A, Info, File, Content, Analysis) ->
    TypeInfo = get_type_string(F, A, Info, file, Analysis),
    ContentList = lists:reverse(Content) ++ TypeInfo ++ "\n",
    ContentBin = unicode:characters_to_binary(ContentList),
    file:write_file(File, ContentBin, [append]).

get_type_string(F, A, Info, Mode, Analysis) ->
    Type = get_type_info({F, A}, Info#info.types, Analysis),
    TypeStr =
        case Type of
            {contract, C} ->
                dialyzer_contracts:contract_to_string(C);
            {RetType, ArgType} ->
                Sig = erl_types:t_fun(ArgType, RetType),
                dialyzer_utils:format_sig(Sig, Info#info.records)
        end,
    case Info#info.edoc of
        false ->
            case {Mode, Type} of
                {file, {contract, _}} ->
                    "";
                _ ->
                    Prefix = lists:concat(["-spec ", erl_types:atom_to_string(F)]),
                    lists:concat([Prefix, TypeStr, "."])
            end;
        true ->
            Prefix = lists:concat(["%% @spec ", F]),
            lists:concat([Prefix, TypeStr, "."])
    end.

show_type_info(File, Info, Analysis) ->
    msg(info, "\n%% File: ~tp", [File], Analysis),
    OutputString = lists:concat(["~.", length(File) + 8, "c"]),
    msg(info, [$%, $%, $\s | OutputString], [$-], Analysis),
    Fun = fun({_LineNo, F, A}) ->
             TypeInfo = get_type_string(F, A, Info, show, Analysis),
             msg(info, "~ts", [TypeInfo], Analysis)
          end,
    lists:foreach(Fun, Info#info.functions).

get_type_info(Func, Types, Analysis) ->
    case map_dict_lookup(Func, Types) of
        none ->
            %% Note: Typeinfo of any function should exist in
            %% the result offered by dialyzer, otherwise there
            %% *must* be something wrong with the analysis
            Msg = io_lib:format("No type info for function: ~tp", [Func]),
            fatal_error(Msg, Analysis);
        {contract, _Fun} = C ->
            C;
        {_RetType, _ArgType} = RA ->
            RA
    end.

%%--------------------------------------------------------------------
%% Processing of command-line options and arguments.
%%--------------------------------------------------------------------
-spec process_cl_args(opts()) -> {args(), analysis()}.
process_cl_args(Opts) ->
    analyze_args(maps:to_list(Opts), #args{}, #analysis{}).

analyze_args([], Args, Analysis) ->
    {Args, Analysis};
analyze_args([Result | Rest], Args, Analysis) ->
    {NewArgs, NewAnalysis} = analyze_result(Result, Args, Analysis),
    analyze_args(Rest, NewArgs, NewAnalysis).

%% Get information about files that the user trusts and wants to analyze
analyze_result({files, Val}, Args, Analysis) ->
    NewVal = Args#args.files ++ Val,
    {Args#args{files = NewVal}, Analysis};
analyze_result({files_r, Val}, Args, Analysis) ->
    NewVal = Args#args.files_r ++ Val,
    {Args#args{files_r = NewVal}, Analysis};
analyze_result({trusted, Val}, Args, Analysis) ->
    NewVal = Args#args.trusted ++ Val,
    {Args#args{trusted = NewVal}, Analysis};
analyze_result({edoc, Value}, Args, Analysis) ->
    {Args, Analysis#analysis{edoc = Value}};
%% Get useful information for actual analysis
analyze_result({io, Val}, Args, Analysis) ->
    {Args, Analysis#analysis{io = Val}};
analyze_result({mode, Mode}, Args, Analysis) ->
    {Args, Analysis#analysis{mode = Mode}};
analyze_result({macros, Macros}, Args, Analysis) ->
    {Args, Analysis#analysis{macros = Macros}};
analyze_result({includes, Includes}, Args, Analysis) ->
    {Args, Analysis#analysis{includes = Includes}};
analyze_result({plt, Plt}, Args, Analysis) ->
    {Args, Analysis#analysis{plt = Plt}};
analyze_result({show_succ, Value}, Args, Analysis) ->
    {Args, Analysis#analysis{show_succ = Value}};
analyze_result({no_spec, Value}, Args, Analysis) ->
    {Args, Analysis#analysis{no_spec = Value}}.

%%--------------------------------------------------------------------
%% File processing.
%%--------------------------------------------------------------------

-spec get_all_files(args(), analysis()) -> [file:filename(), ...].
get_all_files(#args{files = Fs, files_r = Ds}, Analysis) ->
    case filter_fd(Fs, Ds, fun test_erl_file_exclude_ann/1, Analysis) of
        [] ->
            fatal_error("no file(s) to analyze", Analysis);
        AllFiles ->
            AllFiles
    end.

-spec test_erl_file_exclude_ann(file:filename()) -> boolean().
test_erl_file_exclude_ann(File) ->
    case is_erl_file(File) of
        true -> %% Exclude files ending with ".ann.erl"
            case re:run(File, "[\.]ann[\.]erl$", [unicode]) of
                {match, _} ->
                    false;
                nomatch ->
                    true
            end;
        false ->
            false
    end.

-spec is_erl_file(file:filename()) -> boolean().
is_erl_file(File) ->
    filename:extension(File) =:= ".erl".

-type test_file_fun() :: fun((file:filename()) -> boolean()).

-spec filter_fd([file:filename()], [file:filename()], test_file_fun(), analysis()) ->
                   [file:filename()].
filter_fd(FileDir, DirR, Fun, Analysis) ->
    AllFile1 = process_file_and_dir(FileDir, Fun, Analysis),
    AllFile2 = process_dir_rec(DirR, Fun, Analysis),
    remove_dup(AllFile1 ++ AllFile2).

-spec process_file_and_dir([file:filename()], test_file_fun(), analysis()) ->
                              [file:filename()].
process_file_and_dir(FileDir, TestFun, Analysis) ->
    Fun = fun(Elem, Acc) ->
             case filelib:is_regular(Elem) of
                 true ->
                     process_file(Elem, TestFun, Acc);
                 false ->
                     check_dir(Elem, false, Acc, TestFun, Analysis)
             end
          end,
    lists:foldl(Fun, [], FileDir).

-spec process_dir_rec([file:filename()], test_file_fun(), analysis()) ->
                         [file:filename()].
process_dir_rec(Dirs, TestFun, Analysis) ->
    Fun = fun(Dir, Acc) -> check_dir(Dir, true, Acc, TestFun, Analysis) end,
    lists:foldl(Fun, [], Dirs).

-spec check_dir(file:filename(),
                boolean(),
                [file:filename()],
                test_file_fun(),
                analysis()) ->
                   [file:filename()].
check_dir(Dir, Recursive, Acc, Fun, Analysis) ->
    case file:list_dir(Dir) of
        {ok, Files} ->
            {TmpDirs, TmpFiles} = split_dirs_and_files(Files, Dir),
            case Recursive of
                false ->
                    FinalFiles = process_file_and_dir(TmpFiles, Fun, Analysis),
                    Acc ++ FinalFiles;
                true ->
                    TmpAcc1 = process_file_and_dir(TmpFiles, Fun, Analysis),
                    TmpAcc2 = process_dir_rec(TmpDirs, Fun, Analysis),
                    Acc ++ TmpAcc1 ++ TmpAcc2
            end;
        {error, eacces} ->
            fatal_error("no access permission to dir \"" ++ Dir ++ "\"", Analysis);
        {error, enoent} ->
            fatal_error("cannot access " ++ Dir ++ ": No such file or directory", Analysis);
        {error, _Reason} ->
            fatal_error("error involving a use of file:list_dir/1", Analysis)
    end.

%% Same order as the input list
-spec process_file(file:filename(), test_file_fun(), [file:filename()]) ->
                      [file:filename()].
process_file(File, TestFun, Acc) ->
    case TestFun(File) of
        true ->
            Acc ++ [File];
        false ->
            Acc
    end.

%% Same order as the input list
-spec split_dirs_and_files([file:filename()], file:filename()) ->
                              {[file:filename()], [file:filename()]}.
split_dirs_and_files(Elems, Dir) ->
    TestFun =
        fun(Elem, {DirAcc, FileAcc}) ->
           File = filename:join(Dir, Elem),
           case filelib:is_regular(File) of
               false ->
                   {[File | DirAcc], FileAcc};
               true ->
                   {DirAcc, [File | FileAcc]}
           end
        end,
    {Dirs, Files} = lists:foldl(TestFun, {[], []}, Elems),
    {lists:reverse(Dirs), lists:reverse(Files)}.

%% Removes duplicate filenames but keeps the order of the input list
-spec remove_dup([file:filename()]) -> [file:filename()].
remove_dup(Files) ->
    TestDup =
        fun(File, Acc) ->
           case lists:member(File, Acc) of
               true ->
                   Acc;
               false ->
                   [File | Acc]
           end
        end,
    lists:reverse(
        lists:foldl(TestDup, [], Files)).

%%--------------------------------------------------------------------
%% Collect information.
%%--------------------------------------------------------------------

-type inc_file_info() :: {file:filename(), func_info()}.

-record(tmpAcc,
        {file :: file:filename(),
         module :: atom(),
         funcAcc = [] :: [func_info()],
         incFuncAcc = [] :: [inc_file_info()],
         dialyzerObj = [] :: [{mfa(), {_, _}}]}).

-spec collect_info(analysis()) -> analysis().
collect_info(Analysis) ->
    NewPlt =
        try get_dialyzer_plt(Analysis) of
            DialyzerPlt ->
                dialyzer_plt:merge_plts([Analysis#analysis.trust_plt, DialyzerPlt])
        catch
            _:{dialyzer_error, _Reason} ->
                fatal_error("Dialyzer's PLT is missing or is not up-to-date; please (re)create it",
                            Analysis)
        end,
    NewAnalysis =
        lists:foldl(fun collect_one_file_info/2,
                    Analysis#analysis{trust_plt = NewPlt},
                    Analysis#analysis.files),
    %% Process Remote Types
    TmpCServer = NewAnalysis#analysis.codeserver,
    NewCServer =
        try
            TmpCServer1 = dialyzer_utils:merge_types(TmpCServer, NewPlt),
            NewExpTypes = dialyzer_codeserver:get_temp_exported_types(TmpCServer),
            OldExpTypes = dialyzer_plt:get_exported_types(NewPlt),
            MergedExpTypes = sets:union(NewExpTypes, OldExpTypes),
            TmpCServer2 = dialyzer_codeserver:finalize_exported_types(MergedExpTypes, TmpCServer1),
            TmpCServer3 = dialyzer_utils:process_record_remote_types(TmpCServer2),
            dialyzer_contracts:process_contract_remote_types(TmpCServer3)
        catch
            _:{error, ErrorMsg} ->
                fatal_error(ErrorMsg, Analysis)
        end,
    NewAnalysis#analysis{codeserver = NewCServer}.

collect_one_file_info(File, Analysis) ->
    Ds = [{d, Name, Val} || {Name, Val} <- Analysis#analysis.macros],
    %% Current directory should also be included in "Includes".
    Includes = [filename:dirname(File) | Analysis#analysis.includes],
    Is = [{i, Dir} || Dir <- Includes],
    Options = dialyzer_utils:src_compiler_opts() ++ Is ++ Ds,
    case dialyzer_utils:get_core_from_src(File, Options) of
        {error, Reason} ->
            msg(debug, "File=~tp\n,Options=~p\n,Error=~p", [File, Options, Reason], Analysis),
            compile_error(Reason, Analysis);
        {ok, Core} ->
            case dialyzer_utils:get_record_and_type_info(Core) of
                {error, Reason} ->
                    compile_error([Reason], Analysis);
                {ok, Records} ->
                    Mod = cerl:concrete(
                              cerl:module_name(Core)),
                    case dialyzer_utils:get_spec_info(Mod, Core, Records) of
                        {error, Reason} ->
                            compile_error([Reason], Analysis);
                        {ok, SpecInfo, CbInfo} ->
                            ExpTypes = get_exported_types_from_core(Core),
                            analyze_core_tree(Core,
                                              Records,
                                              SpecInfo,
                                              CbInfo,
                                              ExpTypes,
                                              Analysis,
                                              File)
                    end
            end
    end.

analyze_core_tree(Core, Records, SpecInfo, CbInfo, ExpTypes, Analysis, File) ->
    Module =
        cerl:concrete(
            cerl:module_name(Core)),
    TmpTree = cerl:from_records(Core),
    CS1 = Analysis#analysis.codeserver,
    NextLabel = dialyzer_codeserver:get_next_core_label(CS1),
    {Tree, NewLabel} = cerl_trees:label(TmpTree, NextLabel),
    CS2 = dialyzer_codeserver:insert(Module, Tree, CS1),
    CS3 = dialyzer_codeserver:set_next_core_label(NewLabel, CS2),
    CS4 = dialyzer_codeserver:store_temp_records(Module, Records, CS3),
    CS5 = case Analysis#analysis.no_spec of
              true ->
                  CS4;
              false ->
                  dialyzer_codeserver:store_temp_contracts(Module, SpecInfo, CbInfo, CS4)
          end,
    OldExpTypes = dialyzer_codeserver:get_temp_exported_types(CS5),
    MergedExpTypes = sets:union(ExpTypes, OldExpTypes),
    CS6 = dialyzer_codeserver:insert_temp_exported_types(MergedExpTypes, CS5),
    ExFuncs = [{0, F, A} || {_, _, {F, A}} <- cerl:module_exports(Tree)],
    CG = Analysis#analysis.callgraph,
    {V, E} = dialyzer_callgraph:scan_core_tree(Tree, CG),
    dialyzer_callgraph:add_edges(E, V, CG),
    Fun = fun analyze_one_function/2,
    AllDefs = cerl:module_defs(Tree),
    Acc = lists:foldl(Fun, #tmpAcc{file = File, module = Module}, AllDefs),
    ExportedFuncMap = map_dict_insert({File, ExFuncs}, Analysis#analysis.ex_func),
    %% we must sort all functions in the file which
    %% originate from this file by *numerical order* of lineNo
    SortedFunctions = lists:keysort(1, Acc#tmpAcc.funcAcc),
    FuncMap = map_dict_insert({File, SortedFunctions}, Analysis#analysis.func),
    %% we do not need to sort functions which are imported from included files
    IncFuncMap = map_dict_insert({File, Acc#tmpAcc.incFuncAcc}, Analysis#analysis.inc_func),
    FMs = Analysis#analysis.fms ++ [{File, Module}],
    RecordMap = map_dict_insert({File, Records}, Analysis#analysis.record),
    Analysis#analysis{fms = FMs,
                      callgraph = CG,
                      codeserver = CS6,
                      ex_func = ExportedFuncMap,
                      inc_func = IncFuncMap,
                      record = RecordMap,
                      func = FuncMap}.

analyze_one_function({Var, FunBody} = Function, Acc) ->
    F = cerl:fname_id(Var),
    A = cerl:fname_arity(Var),
    TmpDialyzerObj = {{Acc#tmpAcc.module, F, A}, Function},
    NewDialyzerObj = Acc#tmpAcc.dialyzerObj ++ [TmpDialyzerObj],
    Anno = cerl:get_ann(FunBody),
    LineNo = get_line(Anno),
    FileName = get_file(Anno),
    BaseName = filename:basename(FileName),
    FuncInfo = {LineNo, F, A},
    OriginalName = Acc#tmpAcc.file,
    {FuncAcc, IncFuncAcc} =
        case FileName =:= OriginalName orelse BaseName =:= OriginalName of
            true -> %% Coming from original file
                {Acc#tmpAcc.funcAcc ++ [FuncInfo], Acc#tmpAcc.incFuncAcc};
            false ->
                %% Coming from other sourses, including:
                %%     -- .yrl (yecc-generated file)
                %%     -- yeccpre.hrl (yecc-generated file)
                %%     -- other cases
                {Acc#tmpAcc.funcAcc, Acc#tmpAcc.incFuncAcc ++ [{FileName, FuncInfo}]}
        end,
    Acc#tmpAcc{funcAcc = FuncAcc,
               incFuncAcc = IncFuncAcc,
               dialyzerObj = NewDialyzerObj}.

get_line([Line | _]) when is_integer(Line) ->
    Line;
get_line([{Line, _Column} | _Tail]) when is_integer(Line) ->
    Line;
get_line([_ | Tail]) ->
    get_line(Tail);
get_line([]) ->
    -1.

get_file([{file, File} | _]) ->
    File;
get_file([_ | T]) ->
    get_file(T);
get_file([]) ->
    "no_file". % should not happen

-spec get_dialyzer_plt(analysis()) -> dialyzer_plt:plt().
get_dialyzer_plt(#analysis{plt = PltFile0}) ->
    PltFile =
        case PltFile0 =:= none of
            true ->
                dialyzer_plt:get_default_plt();
            false ->
                PltFile0
        end,
    dialyzer_plt:from_file(PltFile).

%% Exported Types

get_exported_types_from_core(Core) ->
    Attrs = cerl:module_attrs(Core),
    ExpTypes1 =
        [cerl:concrete(L2)
         || {L1, L2} <- Attrs,
            cerl:is_literal(L1),
            cerl:is_literal(L2),
            cerl:concrete(L1) =:= export_type],
    ExpTypes2 = lists:flatten(ExpTypes1),
    M = cerl:atom_val(
            cerl:module_name(Core)),
    sets:from_list([{M, F, A} || {F, A} <- ExpTypes2]).

%%--------------------------------------------------------------------
%% Utilities for error reporting.
%%--------------------------------------------------------------------

-spec default_io() -> io().
default_io() ->
    #{debug => fun swallow_output/2,
      info => fun format/2,
      warn => fun format_on_stderr/2,
      abort => fun format_and_halt/2}.

-spec fatal_error(string(), analysis()) -> no_return().
fatal_error(Slogan, Analysis) ->
    msg(abort, "typer: ~ts", [Slogan], Analysis).

-spec compile_error([string()], analysis()) -> no_return().
compile_error(Reason, Analysis) ->
    JoinedString = lists:flatten([X ++ "\n" || X <- Reason]),
    Msg = "Analysis failed with error report:\n" ++ JoinedString,
    fatal_error(Msg, Analysis).

-spec msg(debug | info | warn | abort, io:format(), [term()], analysis()) -> _.
msg(Level, Format, Data, #analysis{io = Io}) ->
    Printer = maps:get(Level, Io, fun swallow_output/2),
    Printer(Format, Data).

-spec format(io:format(), [term()]) -> ok.
format(Format, Data) ->
    io:format(Format ++ "\n", Data).

-spec swallow_output(io:format(), [term()]) -> ok.
swallow_output(_Format, _Data) ->
    ok.

-spec format_on_stderr(io:format(), [term()]) -> ok.
format_on_stderr(Format, Data) ->
    io:format(standard_error, Format ++ "\n", Data).

-spec format_and_halt(io:format(), [term()]) -> no_return().
format_and_halt(Format, Data) ->
    format_on_stderr(Format, Data),
    erlang:halt(1).

%%--------------------------------------------------------------------
%% Handle messages.
%%--------------------------------------------------------------------

rcv_ext_types() ->
    Self = self(),
    Self ! {Self, done},
    rcv_ext_types(Self, []).

rcv_ext_types(Self, ExtTypes) ->
    receive
        {Self, ext_types, ExtType} ->
            rcv_ext_types(Self, [ExtType | ExtTypes]);
        {Self, done} ->
            lists:usort(ExtTypes)
    end.

%%--------------------------------------------------------------------
%% A convenient abstraction of a Key-Value mapping data structure
%% specialized for the uses in this module
%%--------------------------------------------------------------------

-type map_dict() :: dict:dict().

-spec map_dict_new() -> map_dict().
map_dict_new() ->
    dict:new().

-spec map_dict_insert({term(), term()}, map_dict()) -> map_dict().
map_dict_insert(Object, Map) ->
    {Key, Value} = Object,
    dict:store(Key, Value, Map).

-spec map_dict_lookup(term(), map_dict()) -> term().
map_dict_lookup(Key, Map) ->
    try
        dict:fetch(Key, Map)
    catch
        error:_ ->
            none
    end.

-spec map_dict_from_list([{fa(), term()}]) -> map_dict().
map_dict_from_list(List) ->
    dict:from_list(List).

-spec map_dict_remove(term(), map_dict()) -> map_dict().
map_dict_remove(Key, Dict) ->
    dict:erase(Key, Dict).

-spec map_dict_fold(fun((term(), term(), term()) -> map_dict()),
                    map_dict(),
                    map_dict()) ->
                       map_dict().
map_dict_fold(Fun, Acc0, Dict) ->
    dict:fold(Fun, Acc0, Dict).
