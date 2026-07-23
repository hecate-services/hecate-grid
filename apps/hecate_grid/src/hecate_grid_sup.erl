%%% @doc Top supervisor for hecate_grid.
%%%
%%% One child: the dataset sensor. It owns its own poll loop, its own sequence
%%% counters, and its own publishing. There is no central "manager" and no shared
%%% fetch layer — a second sensor family (weather, water) is a second repo, not a
%%% branch in here.
-module(hecate_grid_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{strategy => one_for_one, intensity => 5, period => 10},
    {ok, {SupFlags, [worker(sense_grid_datasets)]}}.

worker(Module) ->
    #{id => Module,
      start => {Module, start_link, []},
      restart => permanent,
      shutdown => 5000,
      type => worker,
      modules => [Module]}.
