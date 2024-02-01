%%%----------------------------------------------------------------------
%%% File     : mod_s3_upload.erl
%%% Author   : Roman Hargrave <roman@hargrave.info>
%%% Purpose  : An XEP-0363 Implementation using S3-compatible storage
%%% Created  : 24 Aug 2022 by Roman Hargrave <roman@hargrave.info>
%%%
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License along
%%% with this program; if not, write to the Free Software Foundation, Inc.,
%%% 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
%%%----------------------------------------------------------------------

-module(mod_s3_upload).
-author('roman@hargrave.info').

-behaviour(gen_mod).
-behaviour(gen_server).

-protocol({xep, 363, '1.1.0'}).

-include("logger.hrl").
-include("translate.hrl").
-include("aws.hrl").

-include_lib("xmpp/include/xmpp.hrl").

% gen_mod callbacks
-export([start/2,
         stop/1,
         reload/3,
         depends/2,
         mod_opt_type/1,
         mod_options/1,
         mod_doc/0]).

% gen_server callbacks
-export([init/1,
         handle_info/2,
         handle_call/3,
         handle_cast/2]).

-import(gen_mod, [get_opt/2]).

-import(crypto, [strong_rand_bytes/1]).

%%-----------------------------------------------------------------------
%% gen_mod callbacks and related machinery
%%-----------------------------------------------------------------------

-spec start(
        ServerHost :: binary(),
        Opts :: gen_mod:opts()
       ) ->
          Result :: {ok, pid()} | {error, term()}.
%
start(ServerHost, Opts) ->
    gen_mod:start_child(?MODULE, ServerHost, Opts).

-spec stop(
        ServerHost :: binary()
       ) ->
          Result :: any().
%
stop(ServerHost) ->
    gen_mod:stop_child(?MODULE, ServerHost).

-spec reload(
        ServerHost :: binary(),
        NewOpts :: gen_mod:opts(),
        OldOpts :: gen_mod:opts()
       ) ->
          Result :: ok.
%
reload(ServerHost, NewOpts, _OldOpts) ->
    ServerRef = gen_mod:get_module_proc(ServerHost, ?MODULE),
    % cast a message to the server with the new options
    gen_server:cast(ServerRef, {reload,
                                ServerHost,
                                build_service_params(ServerHost, NewOpts)}).

%%------------------------------------------------------------------------
%% Options
%%------------------------------------------------------------------------

-spec mod_opt_type(
        OptionName :: atom()
       ) ->
          OptionType :: econf:validator().
%
mod_opt_type(access_key_id) ->
    econf:binary();
mod_opt_type(access_key_secret) ->
    econf:binary();
mod_opt_type(region) ->
    econf:binary();
mod_opt_type(bucket_url) ->
    econf:url([http, https]);
mod_opt_type(download_url) ->
    econf:binary();
mod_opt_type(max_size) ->
    econf:pos_int(infinity);
mod_opt_type(set_public) ->
    econf:bool();
mod_opt_type(put_ttl) ->
    econf:pos_int(infinity);
mod_opt_type(service_name) ->
    econf:binary();
mod_opt_type(hosts) ->
    econf:hosts();
mod_opt_type(access) ->
    econf:acl().

-spec mod_options(
        Host :: binary()
       ) ->
          Options :: [{atom(), term()} | atom()].
%
mod_options(Host) ->
    [{access_key_id, undefined},
     {access_key_secret, undefined},
     {region, undefined},
     {bucket_url, undefined},
     {download_url, undefined},
     {max_size, 1073741824},
     {set_public, true},
     {put_ttl, 600},
     {service_name, <<"S3 Upload">>},
     {hosts, [<<"upload.", Host/binary>>]},
     {access, local}].

-spec mod_doc() ->
          Doc :: #{desc => binary() | [binary()],
                   opts => [{atom(), #{value := binary(), desc := binary()}}]}.
%
mod_doc() ->
    #{desc =>
          [?T("This module implements XEP-0363 using an S3 bucket "
              "instead of an internal web server. This simplifies "
              "clustered deployments by removing the need to maintain "
              "shared storage, and is in many cases less expensive "
              "byte-for-byte than block storage. It is mutually "
              "incompatible with mod_http_upload.")],
      opts =>
          [{access_key_id,
            #{value => ?T("AccessKeyId"),
              desc => ?T("AWS Access Key ID.")}},
           {access_key_secret,
            #{value => ?T("AccessKeySecret"),
              desc => ?T("AWS Access Key Secret.")}},
           {region,
            #{value => ?T("Region"),
              desc => ?T("AWS Region")}},
           {bucket_url,
            #{value => ?T("BucketUrl"),
              desc => ?T("S3 Bucket URL.")}},
           {download_url,
            #{value => ?T("DownloadUrl"),
              desc => ?T("Host for GET/Download requests.")}},
           {max_size,
            #{value => ?T("MaxSize"),
              desc => ?T("Maximum file size, in bytes. 0 is unlimited.")}},
           {set_public,
            #{value => ?T("SetPublic"),
              desc => ?T("Set x-amz-acl to public-read.")}},
           {put_ttl,
            #{value => ?T("PutTtl"),
              desc => ?T("How long the PUT URL will be valid for.")}},
           {service_name,
            #{value => ?T("ServiceName"),
              desc => ?T("Name given in discovery requests.")}},
           {hosts, % named for consistency with other modules
            #{value => ?T("ServiceJids"),
              desc => ?T("JIDs used when communicating with the service")}},
           {access,
            #{value => ?T("UploadAccess"),
              desc => ?T("Access rule for JIDs that may request new URLs")}}]}.

depends(_Host, _Opts) ->
    [].

%%------------------------------------------------------------------------
%% gen_server callbacks.
%%------------------------------------------------------------------------

-record(params,
        {service_name :: binary(), % name given for the service in discovery.
         service_jids :: [binary()], % stanzas destined for these JIDs will be routed to the service.
         max_size     :: integer() | infinity, % maximum upload size. sort of the honor system in this case.
         bucket_url   :: binary(), % S3 bucket URL or subdomain
         download_url :: binary() | undefined,
         set_public   :: boolean(), % set the public-read ACL on the object?
         ttl          :: integer(), % TTL of the signed PUT URL
         server_host  :: binary(), % XMPP vhost the service belongs to
         auth         :: #aws_auth{},
         access       :: atom()}).

-spec init(
        Params :: list()
       ) ->
          Result :: {ok, #params{}}.
%
init([ServerHost, Opts]) ->
    Params = build_service_params(ServerHost, Opts),
    update_routes(ServerHost, [], Params#params.service_jids),
    {ok, Params}.

-spec handle_info(
        Message :: any(),
        State :: #params{}
       ) ->
          Result :: {noreply, #params{}}.
% receive non-standard (gen_server) messages
handle_info({route, #iq{lang = Lang} = Packet}, Opts) ->
    try xmpp:decode_els(Packet) of
        IQ ->
            ejabberd_router:route(handle_iq(IQ, Opts)),
            {noreply, Opts}
    catch _:{xmpp_codec, Why} ->
            Message = xmpp:io_format_error(Why),
            Error   = xmpp:err_bad_request(Message, Lang),
            ejabberd_router:route_error(Packet, Error),
            {noreply, Opts}
    end;
handle_info(Request, Opts) ->
    ?WARNING_MSG("Unexpected info: ~p", [Request]),
    {noreply, Opts}.

-spec handle_call(
        Request:: any(),
        Sender :: gen_server:from(),
        State :: #params{}
       ) ->
          Result :: {noreply, #params{}}.
% respond to $gen_call messages
handle_call(Request, Sender, Opts) ->
    ?WARNING_MSG("Unexpected call from ~p: ~p", [Sender, Request]),
    {noreply, Opts}.

-spec handle_cast(
        Request :: any(),
        State :: #params{}
       ) ->
          Result :: {noreply, #params{}}.
% receive $gen_cast messages
handle_cast({reload, ServerHost, NewOpts}, OldOpts) ->
    update_routes(ServerHost,
                  OldOpts#params.service_jids,
                  NewOpts#params.service_jids),
    {noreply, NewOpts};
handle_cast(Request, Opts) ->
    ?WARNING_MSG("Unexpected cast: ~p", [Request]),
    {noreply, Opts}.

%%------------------------------------------------------------------------
%% Internal Stanza Processing
%%-----------------------------------------------------------------------

-spec update_routes(
        ServerHost :: binary(),
        OldJIDs :: [binary()],
        NewJIDs :: [binary()]
       ) ->
          Result :: _.
% maintain routing rules for JIDs owned by this service.
update_routes(ServerHost, OldJIDs, NewJIDs) ->
    lists:foreach(fun (Domain) ->
                          ejabberd_router:register_route(Domain, ServerHost)
                  end, NewJIDs),
    lists:foreach(fun ejabberd_router:unregister_route/1, OldJIDs -- NewJIDs).


-spec handle_iq(
        IQ :: iq(),
        Params :: gen_mod:opts()
       ) ->
          Response :: iq().
% Handle discovery requests. Produces a document such as depicted in
% XEP-0363 v1.1.0 Ex. 4.
handle_iq(#iq{type    = get,
              lang    = Lang,
              to      = HostJID,
              sub_els = [#disco_info{}]} = IQ,
          #params{max_size = MaxSize, service_name = ServiceName}) ->
    Host = jid:encode(HostJID),
    % collect additional discovery entries, if any.
    Advice = ejabberd_hooks:run_fold(disco_info, Host, [],
                                     [Host, ?MODULE, <<"">>, Lang]),
    % if a maximum size was specified, append xdata with the limit
    XData = case MaxSize of
               infinity ->
                   Advice;
               _ ->
                   [#xdata{type = result,
                           fields = http_upload:encode(
                                      [{'max-file-size', MaxSize}],
                                      ?NS_HTTP_UPLOAD_0,
                                      Lang
                                     )}
                   | Advice]
            end,
    % build disco iq
    Query = #disco_info{identities = [#identity{category = <<"store">>,
                                                type = <<"file">>,
                                                name = translate:translate(Lang, ServiceName)}],
                        features = [?NS_HTTP_UPLOAD_0],
                        xdata = XData},
    xmpp:make_iq_result(IQ, Query); % this swaps parties for us
% handle slot request with FileSize > MaxSize
handle_iq(#iq{type = get,
              from = From,
              lang = Lang,
              sub_els = [#upload_request_0{size = FileSize,
                                           filename = Filename}]} = IQ,
          #params{max_size = MaxSize}) when FileSize > MaxSize ->
    ?WARNING_MSG("~ts tried to upload an oversize file (~ts, ~B bytes)",
                 [jid:encode(From), Filename, FileSize]),
    ErrorMessage = {?T("File larger than ~B bytes"), [MaxSize]},
    Error = xmpp:err_not_acceptable(ErrorMessage, Lang),
    Els = [#upload_file_too_large{'max-file-size' = MaxSize,
                                  xmlns = ?NS_HTTP_UPLOAD_0}
          | xmpp:get_els(Error)],
    xmpp:make_error(IQ, xmpp:set_els(Error, Els));
% Handle slot request
handle_iq(#iq{type    = get,
              from    = Requester,
              lang    = Lang,
              sub_els = [#upload_request_0{filename = Filename,
                                           size     = FileSize} = UploadRequest]} = IQ,
          #params{server_host = ServerHost,
                  access      = Access} = Params) ->
    case acl:match_rule(ServerHost, Access, Requester) of
        allow ->
            ?INFO_MSG("Generating S3 Object URL Pair for ~ts to upload file ~ts (~B bytes)",
                      [jid:encode(Requester), Filename, FileSize]),
            {PutURL, GetURL} = put_get_url(Params, UploadRequest, Filename, Requester),
            xmpp:make_iq_result(IQ, #upload_slot_0{get = GetURL,
                                                   put = PutURL,
                                                   xmlns = ?NS_HTTP_UPLOAD_0});
        deny ->
            ?INFO_MSG("Denied upload request from ~ts for file ~ts (~B bytes)",
                      [jid:encode(Requester), Filename, FileSize]),
            xmpp:make_error(IQ, xmpp:err_forbidden(?T("Access denied"), Lang))
    end;
% handle unexpected IQ
handle_iq(IQ, _Params) ->
    xmpp:make_error(IQ, xmpp:err_bad_request()).

%%------------------------------------------------------------------------
%% Internal Helpers
%%------------------------------------------------------------------------

-spec expanded_jids(
        ServiceHost :: binary(),
        JIDs :: [binary()]
       ) ->
          ExpandedJIDs :: [binary()].
% expand @HOST@ in JIDs
expanded_jids(ServerHost, JIDs) ->
    lists:map(fun (JID) ->
                      misc:expand_keyword(<<"@HOST@">>, JID, ServerHost)
              end, JIDs).

-spec build_service_params(
        ServerHost :: binary(),
        Opts :: gen_mod:opts()
       ) ->
          Params :: #params{}.
% create a service params record from module config
build_service_params(ServerHost, Opts) ->
    Auth = #aws_auth{access_key_id = get_opt(access_key_id, Opts),
                     access_key    = get_opt(access_key_secret, Opts),
                     region        = get_opt(region, Opts)},
    #params{service_name = get_opt(service_name, Opts),
            service_jids = expanded_jids(ServerHost, get_opt(hosts, Opts)),
            max_size     = get_opt(max_size, Opts),
            bucket_url   = get_opt(bucket_url, Opts),
            download_url = get_opt(download_url, Opts),
            set_public   = get_opt(set_public, Opts),
            ttl          = get_opt(put_ttl, Opts),
            server_host  = ServerHost,
            auth         = Auth,
            access       = get_opt(access, Opts)}.


-spec put_get_url(
        Params :: #params{},
        UploadRequest :: #upload_request_0{},
        Filename :: binary(),
        JID :: jid()
       ) ->
          {binary(), binary()}.
% produce a list of {put_url, get_url}, where put_url is signed and
% get_url may use the optional download_url override
put_get_url(#params{bucket_url = BucketURL,
                    download_url = undefined} = Params,
            UploadRequest,
            Filename,
            JID) ->
    put_get_url(Params#params{download_url = BucketURL}, UploadRequest, Filename, JID);
put_get_url(#params{bucket_url = BucketURL,
                    download_url = DownloadURL,
                    auth = Auth,
                    ttl = TTL} = Params,
            UploadRequest,
            Filename,
            JID) ->
    ObjectName = object_name(Filename, JID),
    UnsignedPutURL = decorated_put_url(UploadRequest, Params, BucketURL, ObjectName),
    {aws_util:signed_url(Auth, put, ?AWS_SERVICE_S3, UnsignedPutURL, [], calendar:universal_time(), TTL),
     object_url(DownloadURL, ObjectName)}.

-spec url_service_parameters(
        Params :: #params{}
       ) ->
          ServiceParameters :: [{binary(), binary() | true}].
% additional URL parameters from module config
url_service_parameters(#params{set_public = true}) ->
    [{<<"X-Amz-Acl">>, <<"public-read">>}];
url_service_parameters(_) ->
    [].

-spec upload_parameters(
        UploadRequest :: #upload_request_0{},
        Params :: #params{}
       ) ->
          UploadParameters :: [{binary(), binary() | true}].
% headers to be included with the PUT request
upload_parameters(#upload_request_0{size           = FileSize,
                                    'content-type' = ContentType},
                  ServiceParams) ->
    [{<<"Content-Type">>,   <<ContentType/binary>>},
     {<<"Content-Length">>, erlang:integer_to_binary(FileSize)}
    | url_service_parameters(ServiceParams)].

-spec decorated_put_url(
        UploadRequest :: #upload_request_0{},
        Params :: #params{},
        BucketURL :: binary(),
        ObjectName :: binary()
       ) ->
          PutURL :: binary().
% attach additional query parameters (to the PUT URL), specifically canned ACL.
decorated_put_url(UploadRequest, ServiceParams, BucketURL, ObjectName) ->
    UriMap = uri_string:parse(uri_string:resolve(ObjectName, BucketURL)),
    QueryList = case UriMap of
                    #{query := QueryString} ->
                        uri_string:dissect_query(QueryString);
                    _ ->
                        []
                end,
    Params = upload_parameters(UploadRequest, ServiceParams),
    WithOpts = uri_string:compose_query(Params ++ QueryList),
    uri_string:recompose(UriMap#{query => WithOpts}).

-spec object_url(
        BucketURL :: binary(),
        Filename :: binary()
       ) ->
          ObjectURL :: binary().
% generate a unique random object URL for the given filename
object_url(BucketURL, ObjectName) ->
    uri_string:resolve(ObjectName, BucketURL).

-spec object_name(
        Filename :: binary(),
        JID :: jid()
       ) ->
          ObjectName :: binary().
% generate a unique random object name for the given filename
object_name(Filename, #jid{luser = User, lserver = Server}) ->
    UserStr = str:sha(<<User/binary, $@, Server/binary>>),
    RandStr = p1_rand:get_alphanum_string(20),
    FileStr = uri_string:quote(Filename),
    str:format("~s/~s/~s", [UserStr, RandStr, FileStr]).
