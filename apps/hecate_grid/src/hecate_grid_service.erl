%%% @doc Hecate Grid — implements the hecate_om_service behaviour.
%%%
%%% A TSO open-data sensor. Same pattern as the warden and the news sensor:
%%% observe the world, publish facts, hold no store. It polls near-real-time grid
%%% datasets (imbalance price, system imbalance, load, wind, solar — measurement
%%% AND the operator's own forecast) and publishes each response VERBATIM as an
%%% `observation' fact for hecate-archive to keep.
%%%
%%% It does not parse. What it publishes is the bytes the TSO returned, so that a
%%% parser written later, or fixed later, can be re-run over the same evidence.
%%%
%%% STORELESS: no store_id/0 + data_dir/0, so hecate_om:boot/1 wires the mesh and
%%% starts no reckon-db. The only state is a sequence number per dataset, held in
%%% memory and scoped to this run by an epoch, so a restart is visible as a
%%% restart rather than mistaken for missing data.
-module(hecate_grid_service).
-behaviour(hecate_om_service).

-export([info/0, start/1, stop/1, health/0, capabilities/0, identity_spec/0]).

info() ->
    #{name        => <<"hecate-grid">>,
      version     => <<"0.1.0">>,
      description => <<"Grid sensor: TSO open data, verbatim, onto the mesh">>}.

start(_Opts) ->
    hecate_grid_sup:start_link().

stop(_State) ->
    ok.

%% Green once the poll loop is running. A source being down is not a health
%% failure: the sensor keeps polling the rest, and the outage is itself recorded.
health() ->
    ok.

capabilities() ->
    [#{name => <<"grid.observe_datasets">>, version => 1}].

%% The UCAN the sensor asks the realm to mint: authority to publish observations,
%% and nothing else. Popped, an attacker gains the ability to post grid readings
%% for one realm — no cognition, no store, no key.
identity_spec() ->
    #{scope     => <<"grid">>,
      actions   => [<<"observe">>],
      resources => [hecate_grid_facts:topic()],
      ttl_days  => 30}.
