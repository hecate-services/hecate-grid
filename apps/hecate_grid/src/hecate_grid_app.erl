%%% @doc hecate_grid OTP application entry.
%%%
%%% Producer-only: hecate_om:boot/1 connects the mesh and registers the service's
%%% capabilities + /health, then calls start/1. No store_id/0 or data_dir/0, so
%%% NO reckon-db is started — this sensor holds nothing.
-module(hecate_grid_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    hecate_om:boot(hecate_grid_service).

stop(_State) ->
    ok.
