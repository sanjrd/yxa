-module(pstnproxy).
-export([start/2]).

start(normal, Args) ->
    Pid = spawn(sipserver, start, [fun init/0, fun request/6,
				   fun response/6, [user, numbers], false]),
    {ok, Pid}.

init() ->
    true.

localhostname(Hostname) ->
    util:casegrep(Hostname, sipserver:get_env(myhostnames)).

pstngateway(Hostname) ->
    util:casegrep(Hostname, sipserver:get_env(pstngatewaynames)).

routeRequestToPSTN(FromIP, ToHost) ->
    case pstngateway(FromIP) of
	true ->
	    logger:log(debug, "Routing: Source IP ~s is PSTN gateway, route to SIP proxy", [FromIP]),
	    false;		
	_ ->
	    case localhostname(ToHost) of
		true ->
		    logger:log(debug, "Routing: Source IP ~s is not PSTN gateway and ~p is me, route to PSTN gateway", [FromIP, ToHost]),
		    true;
		_ ->
		    case pstngateway(ToHost) of
			true ->
			    logger:log(debug, "Routing: Destination (~p) is PSTN gateway", [ToHost]),
			    true;
			_ ->
			    logger:log(debug, "Routing: Denied request from ~s to ~s - not my problem", [FromIP, ToHost]),
			    nomatch
		    end
	    end
    end.

request(Method, URI, Header, Body, Socket, FromIP) ->
    {User, Pass, Host, Port, Parameters} = URI,
    LogStr = sipserver:make_logstr({request, Method, URI, Header, Body}, FromIP),
    case routeRequestToPSTN(FromIP, Host) of
	true ->
	    logger:log(normal, "~s -> PSTN gateway", [LogStr]),
	    case Method of
		"INVITE" ->
		    toPSTNrequest(Method, URI, Header, Body, Socket);
		"ACK" ->
		    toPSTNrequest(Method, URI, Header, Body, Socket);
		"PRACK" ->
		    toPSTNrequest(Method, URI, Header, Body, Socket);
		"CANCEL" ->
		    toPSTNrequest(Method, URI, Header, Body, Socket);
		"BYE" ->
		    toPSTNrequest(Method, URI, Header, Body, Socket);
		_ ->
		    siprequest:send_result(Header, Socket, "", 501, "Not Implemented")
	    end;
	false ->
	    logger:log(normal, "~s -> SIP server", [LogStr]),
	    toSIPrequest(Method, URI, Header, Body, Socket);
	_ ->
	    logger:log(normal, "~s -> 403 Forbidden", [LogStr]),
	    siprequest:send_result(Header, Socket, "", 403, "Forbidden")
    end.

toSIPrequest(Method, URI, Header, Body, Socket) ->
    {User, Pass, Host, Port, Parameters} = URI,
    {_, FromURI} = sipheader:to(keylist:fetch("From", Header)),
    Newlocation = case localhostname(Host) of
	true ->
	    logger:log(debug, "Performing ENUM lookup on ~p", [User]),
	    case local:lookupenum(User) of
		{relay, Loc} ->
		    Loc;
		_ ->
		    Proxy = sipserver:get_env(sipproxy, none),
		    case Proxy of
			none ->
			    % No ENUM and no SIP-proxy configured, return failure so
			    % that the PBX on the other side of the gateway can try
			    % PSTN or something
			    siprequest:send_result(Header, Socket, "", 503, "Service Unavailable"),
			    none;
			_ ->
			    {User, none, Proxy, none, []}
		    end
	    end;
	_ ->
	    URI
    end,
    case Newlocation of
	none ->
	    none;
	_ ->
	    Newheaders = case sipserver:get_env(record_route, true) of
		true -> siprequest:add_record_route(Header);
	        false -> Header
	    end,
	    {_, _, DstHost, _, _} = Newlocation,
	    Newheaders2 = add_caller_identity_for_sip(Newheaders, FromURI, DstHost),
	    siprequest:send_proxy_request(Newheaders2, Socket, {Method, Newlocation, Body, []})
    end.

toPSTNrequest(Method, URI, Header, Body, Socket) ->
    {Phone, _, _, _, _} = URI,
    PSTNgateway = lists:nth(1, sipserver:get_env(pstngatewaynames)),
    Newlocation = {Phone, none, PSTNgateway, none, []},
    {_, FromURI} = sipheader:to(keylist:fetch("From", Header)),
    Fromphone = local:sipuser(FromURI),
    Classdefs = sipserver:get_env(classdefs, [{"", unknown}]),
    Newheaders = case sipserver:get_env(record_route, true) of
	true -> siprequest:add_record_route(Header);
        false -> Header
    end,
    Newheaders2 = add_caller_identity_for_pstn(Newheaders, FromURI, PSTNgateway),
    sipauth:check_and_send_auth(Header, Newheaders2, Socket, Fromphone, Phone,
				{siprequest, send_proxy_request},
				{Method, Newlocation, Body, []},
				Method, Classdefs).

response(Status, Reason, Header, Body, Socket, FromIP) ->
    LogStr = sipserver:make_logstr({response, Status, Reason, Header, Body}, FromIP),
    logger:log(normal, "Response to ~s: ~p ~s", [LogStr, Status, Reason]),
    siprequest:send_proxy_response(Socket, Status, Reason, Header, Body).

add_caller_identity_for_pstn(Headers, URI, Gateway) ->
    NewHeaders1 = case sipserver:get_env(remote_party_id, false) of
	true ->
	    case local:get_remote_party_number(local:sipuser(URI), URI, Gateway) of
		none ->
		    Headers;
		RPI ->
		    RemotePartyId = RPI ++ ";party=calling",
		    logger:log(debug, "Remote-Party-Id: ~s", [RemotePartyId]),
		    NewHeaders2 = keylist:delete("Remote-Party-Id", Headers),
		    keylist:set("Remote-Party-Id", [RemotePartyId], NewHeaders2)
	    end;
	_ ->
	    Headers
    end.

add_caller_identity_for_sip(Headers, URI, Gateway) ->
    {User, _, _, _, _} = URI,
    NewHeaders1 = case sipserver:get_env(remote_party_id, false) of
	true ->
	    case local:get_remote_party_name(User, URI, Gateway) of
		none ->
		    Headers;
		RPI ->
		    RemotePartyId = RPI ++ ";party=calling",
		    logger:log(debug, "Remote-Party-Id: ~s", [RemotePartyId]),
		    NewHeaders2 = keylist:delete("Remote-Party-Id", Headers),
		    keylist:set("Remote-Party-Id", [RemotePartyId], NewHeaders2)
	    end;
	_ ->
	    Headers
    end.
