%%% @doc One HTTPS request to a TSO open-data endpoint, and what came back.
%%%
%%% Returns the response VERBATIM together with the two times the sensor can know
%%% first-hand: when it asked and when the answer landed. Both are kept because
%%% upstream latency is free to record now and impossible to reconstruct later.
%%%
%%% A non-200 is NOT an error here. It is an observation of a different kind, and
%%% it is returned so that it can be archived. A gap in the tape must be
%%% distinguishable from an outage at the source, and both from our own crash;
%%% swallowing the 503 erases exactly the evidence that tells them apart. This
%%% matters more than it sounds: feeds die *because* of the event of interest,
%%% and an archive that drops errors encodes "nothing happened" precisely when
%%% everything did.
-module(fetch_dataset).

-export([fetch/1, url/1]).

-define(FETCH_TIMEOUT, 20000).
-define(CONNECT_TIMEOUT, 10000).
-define(UA, "hecate-grid/0.1 (+https://codeberg.org/hecate-services/hecate-grid)").

%% @doc Fetch a source's most-recent rows. `{ok, Map}' for any completed HTTP
%% exchange (including 4xx/5xx); `{error, Reason}' only when nothing came back at
%% all, which is the one case there is genuinely nothing to archive.
-spec fetch(map()) -> {ok, map()} | {error, term()}.
fetch(Source) ->
    Url = url(Source),
    RequestAt = erlang:system_time(millisecond),
    got(request(Url), Url, RequestAt).

%% @doc The request URL, recorded on the fact so a record can be re-fetched, and
%% so a change of endpoint is visible in the tape rather than silent.
%%
%% Most-recent-N rather than a time window on purpose: no date arithmetic, no
%% timezone or DST trap, and no dependence on the source's filter dialect. The
%% overlap between consecutive polls is the point, not a cost — a missed poll is
%% recovered by the next one.
%% The time field is per DATASET, not universal. Most Elia datasets order by
%% `datetime', but the imbalance-forecast ones (ods136, ods147) have no such
%% field and answer HTTP 400 to a query that assumes it. Hardcoding one name
%% silently reduced two of the seven sources to a stream of archived 400s.
-spec url(map()) -> binary().
url(#{base_url := Base, dataset := Dataset} = S) ->
    Limit = integer_to_binary(maps:get(limit, S, 100)),
    Order = maps:get(order_by, S, <<"datetime">>),
    <<Base/binary, "/", Dataset/binary,
      "/records?limit=", Limit/binary, "&order_by=", Order/binary, "%20desc">>.

%% --- Internal ---

request(Url) ->
    Request = {binary_to_list(Url), [{"User-Agent", ?UA}]},
    HTTPOpts = [{timeout, ?FETCH_TIMEOUT},
                {connect_timeout, ?CONNECT_TIMEOUT},
                {ssl, ssl_opts()}],
    catch httpc:request(get, Request, HTTPOpts, [{body_format, binary}]).

got({ok, {{_V, Status, _R}, Headers, Body}}, Url, RequestAt) ->
    {ok, #{endpoint     => Url,
           request_at   => RequestAt,
           response_at  => erlang:system_time(millisecond),
           status       => Status,
           content_type => content_type(Headers),
           payload      => Body}};
got({error, Reason}, _Url, _RequestAt) ->
    {error, Reason};
got(Other, _Url, _RequestAt) ->
    {error, Other}.

content_type(Headers) ->
    header(lists:keyfind("content-type", 1, Headers)).

header({_K, V}) -> unicode:characters_to_binary(V);
header(false)   -> <<"application/octet-stream">>.

%% Verify the source's TLS chain against the system trust store — pure OTP, no
%% Big-Tech SDK. A source with a bad chain simply fails its fetch, which is the
%% correct outcome for a feed that cannot prove it is the feed.
ssl_opts() ->
    [{verify, verify_peer},
     {cacerts, public_key:cacerts_get()},
     {depth, 5},
     {customize_hostname_check,
      [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}].
