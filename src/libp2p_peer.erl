%% @copyright Helium Systems, Inc.
%%
%% @doc A peeer record represents the current state of a peer on the libp2p network.
%%
%% This is a test
-module(libp2p_peer).

-include("pb/libp2p_peer_pb.hrl").

-type nat_type() :: libp2p_peer_pb:nat_type().
-type peer_map() :: #{ pubkey => libp2p_crypto:pubkey_bin(),
                       listen_addrs => [string()],
                       connected => [binary()],
                       nat_type => nat_type(),
                       network_id => binary(),
                       signed_metadata => #{binary() => binary()}
                     }.
-type peer() :: #libp2p_signed_peer_pb{}.
-type metadata() :: [{string(), binary()}].
-export_type([peer/0, peer_map/0, nat_type/0]).

-export([from_map/2, encode/1, decode/1, encode_list/1, decode_list/1, verify/1,
         pubkey_bin/1, listen_addrs/1, connected_peers/1, nat_type/1, timestamp/1,
         supersedes/2, is_stale/2, is_similar/2, network_id/1, network_id_allowable/2]).
%% signed metadata
-export([signed_metadata/1, signed_metadata_get/3]).
%% metadata (unsigned!)
-export([metadata/1, metadata_set/2, metadata_put/3, metadata_get/3]).
%% blacklist (unsigned!)
-export([blacklist/1, is_blacklisted/2,
         blacklist_set/2, blacklist_add/2,
         cleared_listen_addrs/1]).

%% @doc Create a signed peer from a given map of fields.
-spec from_map(peer_map(), fun((binary()) -> binary())) -> {ok, peer()} | {error, term()}.
from_map(Map, SigFun) ->
    Timestamp = case maps:get(timestamp, Map, no_entry) of
                    no_entry -> erlang:system_time(millisecond);
                    V -> V
                end,
    Peer = #libp2p_peer_pb{pubkey=maps:get(pubkey, Map),
                           listen_addrs=[multiaddr:new(L) || L <- maps:get(listen_addrs, Map)],
                           connected = maps:get(connected, Map),
                           nat_type=maps:get(nat_type, Map),
                           network_id=maps:get(network_id, Map, <<>>),
                           timestamp=Timestamp,
                           signed_metadata=encode_map(maps:get(signed_metadata, Map, #{}))
                          },
    sign_peer(Peer, SigFun).

%% @doc Gets the public key for the given peer.
-spec pubkey_bin(peer()) -> libp2p_crypto:pubkey_bin().
pubkey_bin(#libp2p_signed_peer_pb{peer=#libp2p_peer_pb{pubkey=PubKeyBin}}) ->
    PubKeyBin.

%% @doc Gets the list of peer multiaddrs that the given peer is
%% listening on.
-spec listen_addrs(peer()) -> [string()].
listen_addrs(#libp2p_signed_peer_pb{peer=#libp2p_peer_pb{listen_addrs=Addrs}}) ->
    [multiaddr:to_string(A) || A <- Addrs].

%% @doc Gets the list of peer crypto addresses that the given peer was last
%% known to be connected to.
-spec connected_peers(peer()) -> [libp2p_crypto:pubkey_bin()].
connected_peers(#libp2p_signed_peer_pb{peer=#libp2p_peer_pb{connected=Conns}}) ->
    Conns.

%% @doc Gets the NAT type of the given peer.
-spec nat_type(peer()) -> nat_type().
nat_type(#libp2p_signed_peer_pb{peer=#libp2p_peer_pb{nat_type=NatType}}) ->
    NatType.

%% @doc Gets the timestamp of the given peer.
-spec timestamp(peer()) -> integer().
timestamp(#libp2p_signed_peer_pb{peer=#libp2p_peer_pb{timestamp=Timestamp}}) ->
    Timestamp.

%% @doc Gets the signed metadata of the given peer
-spec signed_metadata(peer()) -> map().
signed_metadata(#libp2p_signed_peer_pb{peer=#libp2p_peer_pb{signed_metadata=undefined}}) ->
    #{};
signed_metadata(#libp2p_signed_peer_pb{peer=#libp2p_peer_pb{signed_metadata=MD}}) ->
    lists:foldl(fun({K, #libp2p_metadata_value_pb{value = {_Type, V}}}, Acc) ->
                     maps:put(list_to_binary(K), V, Acc)
             end, #{}, MD).

%% @doc Gets a key from the signed metadata of the given peer
-spec signed_metadata_get(peer(), any(), any()) -> any().
signed_metadata_get(Peer, Key, Default) ->
    maps:get(Key, signed_metadata(Peer), Default).

%% @doc Gets the metadata map from the given peer. The metadata for a
%% peer is `NOT' part of the signed peer since it can be read and
%% updated by anyone to annotate the given peer with extra information
-spec metadata(peer()) -> metadata().
metadata(#libp2p_signed_peer_pb{metadata=Metadata}) ->
    Metadata.

%% @doc Replaces the full metadata for a given peer
-spec metadata_set(peer(), metadata()) -> peer().
metadata_set(Peer=#libp2p_signed_peer_pb{}, Metadata) when is_list(Metadata) ->
    Peer#libp2p_signed_peer_pb{metadata=Metadata}.

%% @doc Updates the metadata for a given peer with the given key/value
%% pair. The `Key' is expected to be a string, while `Value' is
%% expected to be a binary.
-spec metadata_put(peer(), string(), binary()) -> peer().
metadata_put(Peer=#libp2p_signed_peer_pb{}, Key, Value) when is_list(Key), is_binary(Value) ->
    Metadata = lists:keystore(Key, 1, metadata(Peer), {Key, Value}),
    metadata_set(Peer, Metadata).

%% @doc Gets the value for a stored `Key' in metadata. If not found,
%% the `Default' is returned.
-spec metadata_get(peer(), Key::string(), Default::binary()) -> binary().
metadata_get(Peer=#libp2p_signed_peer_pb{}, Key, Default) ->
    case lists:keyfind(Key, 1, metadata(Peer)) of
        false -> Default;
        {_, Value} -> Value
    end.

%% @doc Returns whether a given `Target' is more recent than `Other'
-spec supersedes(Target::peer(), Other::peer()) -> boolean().
supersedes(#libp2p_signed_peer_pb{peer=#libp2p_peer_pb{timestamp=ThisTimestamp}},
           #libp2p_signed_peer_pb{peer=#libp2p_peer_pb{timestamp=OtherTimestamp}}) ->
    ThisTimestamp > OtherTimestamp.

%% @doc Returns whether a given `Target' is mostly equal to an `Other'
%% peer. Similarity means equality for all fields, except for the
%% timestamp of the peers.
-spec is_similar(Target::peer(), Other::peer()) -> boolean().
is_similar(Target=#libp2p_signed_peer_pb{peer=#libp2p_peer_pb{timestamp=TargetTimestamp}},
           Other=#libp2p_signed_peer_pb{peer=#libp2p_peer_pb{timestamp=OtherTimestamp}}) ->
    %% if the set difference is greater than a quarter the old set
    %% size, or it has been three minutes since the original was
    %% published, we're no longer similar
    TSet = sets:from_list(connected_peers(Target)),
    OSet = sets:from_list(connected_peers(Other)),
    TSize = sets:size(TSet),
    OSize = sets:size(OSet),
    Intersection = sets:intersection(TSet, OSet),
    IntSize = sets:size(Intersection),
    ConnDiffPct = application:get_env(libp2p, similarity_conn_pct, 0.3333),
    ConnPeersSimilar = (OSize == TSize andalso OSize == 0) orelse
        (IntSize > (OSize * ConnDiffPct) andalso TSize < (OSize * 2)),

    TimeDiffMinutes = application:get_env(libp2p, similarity_time_diff_mins, 6),
    TimestampSimilar = TargetTimestamp < (OtherTimestamp + timer:minutes(TimeDiffMinutes)),

    pubkey_bin(Target) == pubkey_bin(Other)
        andalso nat_type(Target) == nat_type(Other)
        andalso network_id(Target) == network_id(Other)
        andalso sets:from_list(listen_addrs(Target)) == sets:from_list(listen_addrs(Other))
        andalso ConnPeersSimilar
        andalso TimestampSimilar.

%% @doc Returns the declared network id for the peer, if any
-spec network_id(peer()) -> binary() | undefined.
network_id(#libp2p_signed_peer_pb{peer=#libp2p_peer_pb{network_id = <<>>}}) ->
    undefined;
network_id(#libp2p_signed_peer_pb{peer=#libp2p_peer_pb{network_id=ID}}) ->
    ID.

network_id_allowable(Peer, MyNetworkID) ->
    network_id(Peer) == MyNetworkID
    orelse libp2p_peer:network_id(Peer) == undefined
    orelse MyNetworkID == undefined.

%% @doc Returns whether a given peer is stale relative to a given
%% stale delta time in milliseconds.
-spec is_stale(peer(), integer()) -> boolean().
is_stale(#libp2p_signed_peer_pb{peer=#libp2p_peer_pb{timestamp=Timestamp}}, StaleMS) ->
    Now = erlang:system_time(millisecond),
    (Timestamp + StaleMS) < Now.

%% @doc Gets the blacklist for this peer. This is a metadata based
%% feature that enables listen addresses to be blacklisted so they
%% will not be connected to until that address is removed from the
%% blacklist.
-spec blacklist(peer()) -> [string()].
blacklist(#libp2p_signed_peer_pb{metadata=Metadata}) ->
    case lists:keyfind("blacklist", 1, Metadata) of
        false -> [];
        {_, Bin} -> binary_to_term(Bin)
    end.

%% @doc Returns whether a given listen address is blacklisted. Note
%% that a blacklisted address may not actually appear in the
%% listen_addrs for this peer.
-spec is_blacklisted(peer(), string()) -> boolean().
is_blacklisted(Peer=#libp2p_signed_peer_pb{}, ListenAddr) ->
   lists:member(ListenAddr, blacklist(Peer)).

%% @doc Sets the blacklist for a given peer. Note that currently no
%% validation is done against the existing listen addresses stored in
%% the peer. Blacklisting an address that the peer is not listening to
%% will have no effect anyway.
-spec blacklist_set(peer(), [string()]) -> peer().
blacklist_set(Peer=#libp2p_signed_peer_pb{}, BlackList) when is_list(BlackList) ->
    metadata_put(Peer, "blacklist", term_to_binary(BlackList)).

%% @doc Add a given listen address to the blacklist for the given
%% peer.
blacklist_add(Peer=#libp2p_signed_peer_pb{}, ListenAddr) ->
    BlackList = blacklist(Peer),
    NewBlackList = case lists:member(ListenAddr, BlackList) of
                       true -> BlackList;
                       false ->
                           [ListenAddr | BlackList]
                   end,
    blacklist_set(Peer, NewBlackList).

%% @doc Returns the listen addrs for this peer filtered using the
%% blacklist for the peer, if one is present. This is just a
%% convenience function to clear the listen adddresses for a peer
%% with the blacklist stored in metadata.
-spec cleared_listen_addrs(peer()) -> [string()].
cleared_listen_addrs(Peer=#libp2p_signed_peer_pb{}) ->
    sets:to_list(sets:subtract(sets:from_list(listen_addrs(Peer)),
                               sets:from_list(blacklist(Peer)))).


%% @doc Encodes the given peer into its binary form.
-spec encode(peer()) -> binary().
encode(Msg=#libp2p_signed_peer_pb{}) ->
    libp2p_peer_pb:encode_msg(Msg).

%% @doc Encodes a given list of peer into a binary form. Since
%% encoding lists is primarily used for gossipping peers around, this
%% strips metadata from the peers as part of encoding.
-spec encode_list([peer()]) -> binary().
encode_list(List) ->
    StrippedList = [metadata_set(P, []) || P <- List],
    libp2p_peer_pb:encode_msg(#libp2p_peer_list_pb{peers=StrippedList}).

%% @doc Decodes a given binary into a list of peers.
-spec decode_list(binary()) -> {ok, [peer()]} | {error, term()}.
decode_list(Bin) ->
    List = libp2p_peer_pb:decode_msg(Bin, libp2p_peer_list_pb),
    {ok, List#libp2p_peer_list_pb.peers}.

%% @doc Decodes a given binary into a peer. Note that a decoded peer
%% may not verify, so ensure to call `verify' before actually using
%% peer content
-spec decode(binary()) -> {ok, peer()} | {error, term()}.
decode(Bin) ->
    {ok, libp2p_peer_pb:decode_msg(Bin, libp2p_signed_peer_pb)}.

%% @doc Cryptographically verifies a given peer and it's
%% associations. Returns true if the given peer can be verified, false
%% otherwise.
-spec verify(peer()) -> boolean().
verify(Msg=#libp2p_signed_peer_pb{peer=Peer0=#libp2p_peer_pb{signed_metadata=MD}, signature=Signature}) ->
    Peer = Peer0#libp2p_peer_pb{signed_metadata=lists:usort(MD)},
    EncodedPeer = libp2p_peer_pb:encode_msg(Peer),
    PubKey = libp2p_crypto:bin_to_pubkey(pubkey_bin(Msg)),
    libp2p_crypto:verify(EncodedPeer, Signature, PubKey).

%%
%% Internal
%%

-spec sign_peer(#libp2p_peer_pb{}, libp2p_crypto:sig_fun()) -> {ok, peer()} | {error, term()}.
sign_peer(Peer0 = #libp2p_peer_pb{signed_metadata=MD}, SigFun) ->
    Peer = Peer0#libp2p_peer_pb{signed_metadata=lists:usort(MD)},
    EncodedPeer = libp2p_peer_pb:encode_msg(Peer),
    case SigFun(EncodedPeer) of
        {error, Error} ->
            {error, Error};
        Signature ->
            {ok, #libp2p_signed_peer_pb{peer=Peer, signature=Signature}}
    end.

encode_map(Map) ->
    lists:sort(maps:fold(fun(K, V, Acc) when is_binary(K), is_integer(V) ->
                                 [{binary_to_list(K), #libp2p_metadata_value_pb{value = {int, V}}}|Acc];
                            (K, V, Acc) when is_binary(K), is_float(V) ->
                                 [{binary_to_list(K), #libp2p_metadata_value_pb{value = {flt, V}}}|Acc];
                            (K, V, Acc) when is_binary(K), is_binary(V) ->
                                 [{binary_to_list(K), #libp2p_metadata_value_pb{value = {bin, V}}}|Acc];
                            (K, V, Acc) when is_binary(K), (V == true orelse V == false) ->
                                 [{binary_to_list(K), #libp2p_metadata_value_pb{value = {boolean, V}}}|Acc];
                            (K, V, Acc) when is_binary(K) ->
                                 lager:warning("invalid metadata value ~p for key ~p, must be integer, float or binary", [V, K]),
                                 Acc;
                            (K, V, Acc) ->
                                 lager:warning("invalid metadata key ~p with value ~p, keys must be binaries", [K, V]),
                                 Acc
                         end, [], Map)).
