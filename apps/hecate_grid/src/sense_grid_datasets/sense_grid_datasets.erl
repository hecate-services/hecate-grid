%%% @doc The grid sensor: poll each TSO dataset, publish what came back, keep
%%% nothing.
%%%
%%% On a heartbeat it fetches the most-recent rows of every configured dataset
%%% and publishes each response verbatim as an `observation' fact. It parses
%%% nothing and remembers nothing except a sequence number per dataset, which
%%% exists so the archive can see a hole rather than guess at one.
%%%
%%% Deliberately overlapping: each poll asks for more rows than one interval's
%%% worth, so a missed poll is recovered by the next one. The tape therefore
%%% contains duplicate ROWS across consecutive records, and that is correct.
%%% De-duplication by event time is the replay parser's job, at a point where it
%%% can be re-done; dropping the overlap here would be interpretation, and it
%%% could not be undone.
%%%
%%% The FIRST poll waits for the mesh. hecate_om connects asynchronously, so a
%%% poll fired at boot would publish into a dark mesh (a no-op) while consuming
%%% sequence numbers, manufacturing a gap out of our own impatience.
%%%
%%% A source being down never stops the others: each fetch is isolated, and a
%%% non-200 is published rather than swallowed.
-module(sense_grid_datasets).
-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(DEFAULT_POLL_MS, 60000).
-define(READY_RETRY_MS, 5000).
%% The scheduler's resolution. Each source carries its own interval, so this only
%% has to be finer than the shortest one.
-define(TICK_MS, 5000).

-record(st, {sources = []   :: [map()],
             epoch          :: integer(),
             due     = #{}  :: #{binary() => integer()},
             seq     = #{}  :: #{binary() => non_neg_integer()},
             first   = true :: boolean()}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    _ = application:ensure_all_started(inets),
    _ = application:ensure_all_started(ssl),
    Sources = [S || S <- sources(), maps:get(dataset, S, <<>>) =/= <<>>],
    Epoch = erlang:system_time(millisecond),
    warn_unattributable(hecate_grid_facts:ref()),
    logger:info("[grid] sensor up: ~b dataset(s), epoch ~b -> ~ts",
                [length(Sources), Epoch, hecate_grid_facts:topic()]),
    self() ! tick,
    {ok, #st{sources = Sources, epoch = Epoch}}.

handle_call(_Req, _From, St) -> {reply, {error, unknown_call}, St}.
handle_cast(_Msg, St)        -> {noreply, St}.

handle_info(tick, #st{first = true} = St) ->
    first_tick(mesh_ready(), St);
handle_info(tick, St) ->
    {noreply, tick(St)};
handle_info(_Info, St) ->
    {noreply, St}.

terminate(_Reason, _St) -> ok.

%% --- poll loop ---
%%
%% Each source carries its OWN interval. A quarter-hourly dataset polled every
%% minute is fifteen identical answers and fourteen wasted requests, and the
%% waste is not only ours: it lands on a public open-data service that costs
%% nothing to use and can be lost by being abused.

first_tick(false, St) ->
    erlang:send_after(?READY_RETRY_MS, self(), tick),
    {noreply, St};
first_tick(true, St) ->
    {noreply, tick(St)}.

tick(St) ->
    Now = erlang:system_time(millisecond),
    Due = [S || S <- St#st.sources, due(S, Now, St)],
    St2 = lists:foldl(fun(S, A) -> poll_source(S, Now, A) end, St, Due),
    erlang:send_after(?TICK_MS, self(), tick),
    St2#st{first = false}.

due(Source, Now, St) ->
    maps:get(maps:get(dataset, Source), St#st.due, 0) =< Now.

poll_source(Source, Now, St) ->
    St2 = observed(fetch_dataset:fetch(Source), Source, St),
    Next = Now + source_poll_ms(Source),
    St2#st{due = maps:put(maps:get(dataset, Source), Next, St2#st.due)}.

observed({ok, Obs}, Source, St) ->
    Dataset = maps:get(dataset, Source),
    Seq = maps:get(Dataset, St#st.seq, 0),
    _ = hecate_grid_facts:observation(
          Obs#{source  => maps:get(source, Source),
               dataset => Dataset,
               epoch   => St#st.epoch,
               seq     => Seq}),
    log_status(maps:get(status, Obs), Source, byte_size(maps:get(payload, Obs))),
    St#st{seq = maps:put(Dataset, Seq + 1, St#st.seq)};
%% Nothing came back at all, so there is nothing to archive. The sequence does
%% NOT advance: a poll that never reached the source is our silence, not a
%% missing fact, and claiming a gap here would be a false report about the mesh.
observed({error, Reason}, Source, St) ->
    logger:notice("[grid] ~ts/~ts unreachable: ~p",
                  [maps:get(source, Source, <<"?">>),
                   maps:get(dataset, Source, <<"?">>), Reason]),
    St.

log_status(200, Source, Bytes) ->
    logger:debug("[grid] ~ts/~ts ~b bytes",
                 [maps:get(source, Source), maps:get(dataset, Source), Bytes]);
log_status(Status, Source, _Bytes) ->
    logger:notice("[grid] ~ts/~ts returned HTTP ~b (archived as-is)",
                  [maps:get(source, Source), maps:get(dataset, Source), Status]).

%% A tape whose records cannot be attributed to a build is a tape whose bugs
%% cannot be bounded to an interval. Loud, once, at boot.
warn_unattributable(<<"unset">>) ->
    logger:warning("[grid] HECATE_SENSOR_REF is unset: records will not be "
                   "attributable to a build");
warn_unattributable(_Ref) ->
    ok.

mesh_ready() ->
    ready(catch {hecate_om:macula_client(), hecate_om_identity:realm()}).

ready({{ok, _Pool}, {ok, _Realm}}) -> true;
ready(_NotYet)                     -> false.

%% --- config ---

sources() ->
    from_env(os:getenv("HECATE_GRID_SOURCES")).

from_env(S) when is_list(S), S =/= "" ->
    [to_source(string:split(Spec, "|", all))
     || Spec <- string:split(S, ",", all), Spec =/= ""];
from_env(_Unset) ->
    application:get_env(hecate_grid, sources, []).

%% Spec: "source|dataset|base_url|limit|poll_ms|order_by".
to_source([Src, Ds, Base, Limit, Poll, Order]) ->
    (to_source([Src, Ds, Base, Limit, Poll]))#{order_by => bin(Order)};
to_source([Src, Ds, Base, Limit, Poll]) ->
    (to_source([Src, Ds, Base, Limit]))#{poll_ms => parse_int(Poll, poll_ms())};
to_source([Src, Ds, Base, Limit]) ->
    #{source => bin(Src), dataset => bin(Ds), base_url => bin(Base),
      limit => limit(string:to_integer(Limit))};
to_source([Src, Ds, Base]) ->
    #{source => bin(Src), dataset => bin(Ds), base_url => bin(Base), limit => 10};
to_source(_Bad) ->
    #{source => <<"?">>, dataset => <<>>, base_url => <<>>, limit => 10}.

%% The Elia records endpoint caps limit at 100, and asking for more is a 400.
limit({I, _Rest}) when is_integer(I), I > 0, I =< 100 -> I;
limit(_NotInt)                                        -> 10.

bin(S) -> unicode:characters_to_binary(string:trim(S)).

%% A source's own interval, falling back to the global default.
source_poll_ms(Source) ->
    maps:get(poll_ms, Source, poll_ms()).

poll_ms() ->
    parse_int(os:getenv("HECATE_GRID_POLL_MS"),
              application:get_env(hecate_grid, poll_ms, ?DEFAULT_POLL_MS)).

parse_int(S, Fallback) when is_list(S), S =/= "" ->
    to_int(string:to_integer(S), Fallback);
parse_int(_Unset, Fallback) ->
    Fallback.

to_int({I, _Rest}, _Fallback) when is_integer(I), I > 0 -> I;
to_int(_NotInt, Fallback)                               -> Fallback.
