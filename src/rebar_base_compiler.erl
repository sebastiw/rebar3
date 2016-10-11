%% -*- erlang-indent-level: 4;indent-tabs-mode: nil -*-
%% ex: ts=4 sw=4 et
%% -------------------------------------------------------------------
%%
%% rebar: Erlang Build Tools
%%
%% Copyright (c) 2009 Dave Smith (dizzyd@dizzyd.com)
%%
%% Permission is hereby granted, free of charge, to any person obtaining a copy
%% of this software and associated documentation files (the "Software"), to deal
%% in the Software without restriction, including without limitation the rights
%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%% copies of the Software, and to permit persons to whom the Software is
%% furnished to do so, subject to the following conditions:
%%
%% The above copyright notice and this permission notice shall be included in
%% all copies or substantial portions of the Software.
%%
%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
%% THE SOFTWARE.
%% -------------------------------------------------------------------
-module(rebar_base_compiler).

-include("rebar.hrl").

-export([run/4,
         run/7,
         run/8,
         ok_tuple/2,
         error_tuple/4,
         format_error_source/2]).

%% Internal
-export([
         distributed_compile_each/4
        ]).

-define(DEFAULT_COMPILER_SOURCE_FORMAT, relative).
-define(DEFAULT_PARALLEL_NUM_FILES, 40).

%% ===================================================================
%% Public API
%% ===================================================================

run(Config, FirstFiles, RestFiles, CompileFn) ->
    Parallel = rebar_opts:get(Config, parallel, false),

    %% Compile the first files in sequence
    compile_each(FirstFiles, Config, CompileFn),
    compile_wrapper(RestFiles, Config, CompileFn, Parallel).

run(Config, FirstFiles, SourceDir, SourceExt, TargetDir, TargetExt,
    Compile3Fn) ->
    run(Config, FirstFiles, SourceDir, SourceExt, TargetDir, TargetExt,
        Compile3Fn, [check_last_mod]).

run(Config, FirstFiles, SourceDir, SourceExt, TargetDir, TargetExt,
    Compile3Fn, Opts) ->
    %% Convert simple extension to proper regex
    SourceExtRe = "^[^._].*\\" ++ SourceExt ++ [$$],

    Recursive = proplists:get_value(recursive, Opts, true),
    %% Find all possible source files
    FoundFiles = rebar_utils:find_files(SourceDir, SourceExtRe, Recursive),
    %% Remove first files from found files
    RestFiles = [Source || Source <- FoundFiles,
                           not lists:member(Source, FirstFiles)],

    %% Check opts for flag indicating that compile should check lastmod
    CheckLastMod = proplists:get_bool(check_last_mod, Opts),

    run(Config, FirstFiles, RestFiles,
        fun(S, C) ->
                Target = target_file(S, SourceDir, SourceExt,
                                     TargetDir, TargetExt),
                simple_compile_wrapper(S, Target, Compile3Fn, C, CheckLastMod)
        end).

ok_tuple(Source, Ws) ->
    {ok, format_warnings(Source, Ws)}.

error_tuple(Source, Es, Ws, Opts) ->
    {error, format_errors(Source, Es),
     format_warnings(Source, Ws, Opts)}.

format_error_source(Path, Opts) ->
    Type = case rebar_opts:get(Opts, compiler_source_format,
                               ?DEFAULT_COMPILER_SOURCE_FORMAT) of
        V when V == absolute; V == relative; V == build ->
            V;
        Other ->
            ?WARN("Invalid argument ~p for compiler_source_format - "
                  "assuming ~s~n", [Other, ?DEFAULT_COMPILER_SOURCE_FORMAT]),
            ?DEFAULT_COMPILER_SOURCE_FORMAT
    end,
    case Type of
        absolute -> resolve_linked_source(Path);
        build -> Path;
        relative ->
            Cwd = rebar_dir:get_cwd(),
            rebar_dir:make_relative_path(resolve_linked_source(Path), Cwd)
    end.

resolve_linked_source(Src) ->
    {Dir, Base} = rebar_file_utils:split_dirname(Src),
    filename:join(rebar_file_utils:resolve_link(Dir), Base).

%% ===================================================================
%% Internal functions
%% ===================================================================

simple_compile_wrapper(Source, Target, Compile3Fn, Config, false) ->
    Compile3Fn(Source, Target, Config);
simple_compile_wrapper(Source, Target, Compile3Fn, Config, true) ->
    case filelib:last_modified(Target) < filelib:last_modified(Source) of
        true ->
            Compile3Fn(Source, Target, Config);
        false ->
            skipped
    end.

target_file(SourceFile, SourceDir, SourceExt, TargetDir, TargetExt) ->
    BaseFile = remove_common_path(SourceFile, SourceDir),
    filename:join([TargetDir, filename:basename(BaseFile, SourceExt) ++ TargetExt]).

remove_common_path(Fname, Path) ->
    remove_common_path1(filename:split(Fname), filename:split(Path)).

remove_common_path1([Part | RestFilename], [Part | RestPath]) ->
    remove_common_path1(RestFilename, RestPath);
remove_common_path1(FilenameParts, _) ->
    filename:join(FilenameParts).

compile_wrapper(Sources, Config, CompileFn, false) ->
    %% Sequential compiling, default.
    compile_each(Sources, Config, CompileFn);
compile_wrapper(Sources, Config, CompileFn, SplitAt) when is_integer(SplitAt),
                                                          SplitAt > 0 ->
    %% Split into chunks of a user specifiedd length.
    Pids = distribute_compile_jobs(Sources, Config, CompileFn, SplitAt),
    collect_compile_jobs(Pids);
compile_wrapper(Sources, Config, CompileFn, Parallel) when Parallel == 0 ->
    %% Split into chunks of equal sizes for the schedulers.
    SplitAt = length(Sources) / erlang:system_info(schedulers),
    Pids = distribute_compile_jobs(Sources, Config, CompileFn, SplitAt),
    collect_compile_jobs(Pids);
compile_wrapper(Sources, Config, CompileFn, Parallel) when Parallel == true ->
    %% Split into chunks of some standard size.
    Pids = distribute_compile_jobs(Sources, Config, CompileFn, ?DEFAULT_PARALLEL_NUM_FILES),
    collect_compile_jobs(Pids).

compile_each([], _Config, _CompileFn) ->
    ok;
compile_each([Source | Rest], Config, CompileFn) ->
    case CompileFn(Source, Config) of
        ok ->
            ?DEBUG("~sCompiled ~s", [rebar_utils:indent(1), filename:basename(Source)]);
        {ok, Warnings} ->
            report(Warnings),
            ?DEBUG("~sCompiled ~s", [rebar_utils:indent(1), filename:basename(Source)]);
        skipped ->
            ?DEBUG("~sSkipped ~s", [rebar_utils:indent(1), filename:basename(Source)]);
        Error ->
            NewSource = format_error_source(Source, Config),
            ?ERROR("Compiling ~s failed", [NewSource]),
            maybe_report(Error),
            ?DEBUG("Compilation failed: ~p", [Error]),
            ?FAIL
    end,
    compile_each(Rest, Config, CompileFn).

distributed_compile_each(Parent, Sources, Config, CompileFn) ->
    case catch compile_each(Sources, Config, CompileFn) of
        rebar_abort ->
            Parent ! {rebar_abort, self()};
        _ ->
            Parent ! {compiled, self()}
    end.

distribute_compile_jobs(Sources, Config, CompileFn, SplitAt) ->
    Chunks = split_into_chunks(Sources, SplitAt),
    [spawn_link(?MODULE, distributed_compile_each,
                [self(), Chunk, Config, CompileFn]) || Chunk <- Chunks].
collect_compile_jobs([]) ->
    ok;
collect_compile_jobs(Pids) ->
    receive
        {rebar_abort, _Pid} ->
            ?FAIL;
        {compiled, Pid} ->
            collect_compile_jobs(Pids -- [Pid])
    end.

split_into_chunks(Sources, SplitAt) ->
    {_, Chunks} = lists:foldl(
                    fun (S, {NumFiles, [Chunk|Acc]}) when NumFiles == SplitAt ->
                            {1, [[S], Chunk|Acc]};
                        (S, {NumFiles, [Chunk|Acc]}) ->
                            {NumFiles+1, [[S|Chunk]|Acc]}
                    end, {0, [[]]}, Sources),
    Chunks.

format_errors(Source, Errors) ->
    format_errors(Source, "", Errors).

format_warnings(Source, Warnings) ->
    format_warnings(Source, Warnings, []).

format_warnings(Source, Warnings, Opts) ->
    %% `Opts' can be passed in both as a list or a dictionary depending
    %% on whether the first call to rebar_erlc_compiler was done with
    %% the type `rebar_dict()' or `rebar_state:t()'.
    LookupFn = if is_list(Opts) -> fun lists:member/2
                ; true          -> fun dict:is_key/2
               end,
    Prefix = case LookupFn(warnings_as_errors, Opts) of
                 true -> "";
                 false -> "Warning: "
             end,
    format_errors(Source, Prefix, Warnings).

maybe_report({{error, {error, _Es, _Ws}=ErrorsAndWarnings}, {source, _}}) ->
    maybe_report(ErrorsAndWarnings);
maybe_report([{error, E}, {source, S}]) ->
    report(["unexpected error compiling " ++ S, io_lib:fwrite("~n~p", [E])]);
maybe_report({error, Es, Ws}) ->
    report(Es),
    report(Ws);
maybe_report(_) ->
    ok.

report(Messages) ->
    lists:foreach(fun(Msg) -> io:format("~s~n", [Msg]) end, Messages).

format_errors(_MainSource, Extra, Errors) ->
    [begin
         [format_error(Source, Extra, Desc) || Desc <- Descs]
     end
     || {Source, Descs} <- Errors].

format_error(Source, Extra, {{Line, Column}, Mod, Desc}) ->
    ErrorDesc = Mod:format_error(Desc),
    ?FMT("~s:~w:~w: ~s~s~n", [Source, Line, Column, Extra, ErrorDesc]);
format_error(Source, Extra, {Line, Mod, Desc}) ->
    ErrorDesc = Mod:format_error(Desc),
    ?FMT("~s:~w: ~s~s~n", [Source, Line, Extra, ErrorDesc]);
format_error(Source, Extra, {Mod, Desc}) ->
    ErrorDesc = Mod:format_error(Desc),
    ?FMT("~s: ~s~s~n", [Source, Extra, ErrorDesc]).
