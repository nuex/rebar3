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
-module(rebar_otp_app).

-export([compile/2,
         format_error/1,
         clean/2]).

-include("rebar.hrl").
-include_lib("providers/include/providers.hrl").

%% ===================================================================
%% Public API
%% ===================================================================

compile(State, App) ->
    %% If we get an .app.src file, it needs to be pre-processed and
    %% written out as a ebin/*.app file. That resulting file will then
    %% be validated as usual.
    Dir = ec_cnv:to_list(rebar_app_info:dir(App)),
    {State2, App1} = case rebar_app_info:app_file_src(App) of
                          undefined ->
                              {State, App};
                          AppFileSrc ->
                              {State1, File} = preprocess(State, Dir, AppFileSrc),
                              {State1, rebar_app_info:app_file(App, File)}
                      end,

    %% Load the app file and validate it.
    validate_app(State2, App1).


format_error({file_read, File, Reason}) ->
    io_lib:format("Failed to read ~s for processing: ~p", [File, Reason]);
format_error({invalid_name, File, AppName}) ->
    io_lib:format("Invalid ~s: name of application (~p) must match filename.", [File, AppName]).

clean(_State, File) ->
    %% If the app file is a .app.src, delete the generated .app file
    case rebar_app_utils:is_app_src(File) of
        true ->
            case file:delete(rebar_app_utils:app_src_to_app(File)) of
                ok ->
                    ok;
                {error, enoent} ->
                    %% The file not existing is OK, we can ignore the error.
                    ok;
                Other ->
                    Other
            end;
        false ->
            ok
    end.

%% ===================================================================
%% Internal functions
%% ===================================================================

validate_app(State, App) ->
    AppFile = rebar_app_info:app_file(App),
    case rebar_app_utils:load_app_file(State, AppFile) of
        {ok, State1, AppName, AppData} ->
            case validate_name(AppName, AppFile) of
                ok ->
                    validate_app_modules(State1, App, AppData);
                Error ->
                    Error
            end;
        {error, Reason} ->
            ?PRV_ERROR({file_read, AppFile, Reason})
    end.

validate_app_modules(State, App, AppData) ->
    %% In general, the list of modules is an important thing to validate
    %% for compliance with OTP guidelines and upgrade procedures.
    %% However, some people prefer not to validate this list.
    AppVsn = proplists:get_value(vsn, AppData),
    case rebar_state:get(State, validate_app_modules, true) of
        true ->
            case rebar_app_discover:validate_application_info(App, AppData) of
                true ->
                    {ok, rebar_app_info:original_vsn(App, AppVsn)};
                Error ->
                    Error
            end;
        false ->
            {ok, rebar_app_info:original_vsn(App, AppVsn)}
    end.

preprocess(State, Dir, AppSrcFile) ->
    case rebar_app_utils:load_app_file(State, AppSrcFile) of
        {ok, State1, AppName, AppData} ->
            %% Look for a configuration file with vars we want to
            %% substitute. Note that we include the list of modules available in
            %% ebin/ and update the app data accordingly.
            AppVars = load_app_vars(State1) ++ [{modules, ebin_modules(Dir)}],
            A1 = apply_app_vars(AppVars, AppData),

            %% AppSrcFile may contain instructions for generating a vsn number
            {State2, Vsn} = rebar_app_utils:app_vsn(State1, AppSrcFile),
            A2 = lists:keystore(vsn, 1, A1, {vsn, Vsn}),

            %% systools:make_relup/4 fails with {missing_param, registered}
            %% without a 'registered' value.
            A3 = ensure_registered(A2),

            %% Build the final spec as a string
            Spec = io_lib:format("~p.\n", [{application, AppName, A3}]),

            %% Setup file .app filename and write new contents
            AppFile = rebar_app_utils:app_src_to_app(AppSrcFile),
            ok = rebar_file_utils:write_file_if_contents_differ(AppFile, Spec),

            %% Make certain that the ebin/ directory is available
            %% on the code path
            true = code:add_path(filename:absname(filename:dirname(AppFile))),

            {State2, AppFile};
        {error, Reason} ->
            ?PRV_ERROR({file_read, AppSrcFile, Reason})
    end.

load_app_vars(State) ->
    case rebar_state:get(State, app_vars_file, undefined) of
        undefined ->
            ?DEBUG("No app_vars_file defined.", []),
            [];
        Filename ->
            ?INFO("Loading app vars from ~p", [Filename]),
            {ok, Vars} = file:consult(Filename),
            Vars
    end.

apply_app_vars([], AppData) ->
    AppData;
apply_app_vars([{Key, Value} | Rest], AppData) ->
    AppData2 = lists:keystore(Key, 1, AppData, {Key, Value}),
    apply_app_vars(Rest, AppData2).

validate_name(AppName, File) ->
    %% Convert the .app file name to an atom -- check it against the
    %% identifier within the file
    ExpApp = list_to_atom(filename:basename(File, ".app")),
    case ExpApp == AppName of
        true ->
            ok;
        false ->
            ?PRV_ERROR({invalid_name, File, AppName})
    end.

ebin_modules(Dir) ->
    lists:sort([rebar_utils:beam_to_mod(N) ||
                   N <- rebar_utils:beams(filename:join(Dir, "ebin"))]).

ensure_registered(AppData) ->
    case lists:keyfind(registered, 1, AppData) of
        false ->
            [{registered, []} | AppData];
        {registered, _} ->
            %% We could further check whether the value is a list of atoms.
            AppData
    end.
