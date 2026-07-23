%%% @doc The observation fact: what the sensor saw, exactly as it saw it.
%%%
%%% The payload is the upstream response BYTE FOR BYTE. The sensor does not
%%% parse it, does not scale it, does not pick fields out of it. Two reasons, and
%%% they point the same way:
%%%
%%%   Correctness — an ingest that is wrong produces a record that is wrong AND
%%%   internally consistent, and no later analysis can find the error. Keep the
%%%   bytes and a parser bug is a re-run, not a retraction.
%%%
%%%   Lightness — a sensor that does not parse is cheaper than one that does. The
%%%   correct choice and the light choice are the same choice here.
%%%
%%% NO EVENT TIME on the envelope. When each row happened is inside the payload,
%%% and extracting it is interpretation. The envelope carries only what the
%%% sensor itself can know first-hand: when it asked, and when the answer landed.
%%%
%%% `epoch' + `seq' are how a hole becomes visible. `seq' is monotonic per
%%% dataset within one run of the sensor; `epoch' is the run. A restart begins a
%%% new epoch rather than resetting a counter, so the archive can tell "the
%%% sensor restarted" (no claim about what happened across the boundary) from
%%% "facts went missing" (a real, countable gap). This is what lets the sensor
%%% keep no store: a persisted counter would be a store, and a counter that reset
%%% silently would be a lie.
-module(hecate_grid_facts).

-export([topic/0, observation/1, ref/0]).

-define(DEFAULT_TOPIC, <<"archive/observations">>).
-define(REPORTER, <<"hecate-grid">>).

%% @doc The topic the archive collects on.
-spec topic() -> binary().
topic() ->
    bin(os:getenv("HECATE_GRID_TOPIC"),
        application:get_env(hecate_grid, topic, ?DEFAULT_TOPIC)).

%% @doc The sensor's build identity, stamped on every record.
%%
%% The capture harness is a runner: it can be wrong, and when it is, the damage
%% must be bounded to a known interval rather than smeared anonymously across the
%% tape. CI sets ${HECATE_SENSOR_REF} to the commit sha.
-spec ref() -> binary().
ref() ->
    bin(os:getenv("HECATE_SENSOR_REF"), <<"unset">>).

%% @doc Publish one observation. `O' carries source, dataset, seq, epoch,
%% endpoint, request_at, response_at, status, content_type and the verbatim
%% payload.
-spec observation(map()) -> ok.
observation(O) when is_map(O) ->
    Payload = maps:get(payload, O, <<>>),
    Fact = O#{type           => observation,
              schema_v       => 1,
              payload_sha256 => binary:encode_hex(crypto:hash(sha256, Payload), lowercase),
              sensor_ref     => ref(),
              from           => ?REPORTER},
    publish(topic(), Fact).

%% --- Internal ---

%% The lookup itself is caught, not just its result: the mesh subsystem may be
%% absent entirely, and a publish that can crash its caller would take the poll
%% loop down with it.
publish(Topic, Fact) ->
    emit(catch {hecate_om:macula_client(), hecate_om_identity:realm()}, Topic, Fact).

emit({{ok, Pool}, {ok, Realm}}, Topic, Fact) ->
    catch macula:publish(Pool, Realm, Topic, Fact),
    ok;
emit(_DarkOrNoRealm, _Topic, _Fact) ->
    ok.

bin(S, _Fallback) when is_list(S), S =/= "" -> unicode:characters_to_binary(S);
bin(_Unset, Fallback)                       -> Fallback.
