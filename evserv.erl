%% Event server
-module(evserv).
-compile(export_all).

-record(state, {events,    %% list of #event{} records
                clients}). %% list of Pids
-record(event, {name="",
                description="",
                pid,
                timeout={{1970,1,1},{0,0,0}},
				num_of_reminds = 0,
				remind_dates=[]}).

%%% User Interface


start() ->
	io:format("evserv start~n"),
    register(?MODULE, Pid=spawn(?MODULE, init, [])),
    Pid.

start_link() ->
	io:format("evserv start_link~n"),
    register(?MODULE, Pid=spawn_link(?MODULE, init, [])),
    Pid.

terminate() ->
	io:format("evserv terminate~n"),
    ?MODULE ! shutdown.

init() ->
	io:format("evserv init~n"),
    %% Loading events from a static file could be done here.
    %% You would need to pass an argument to init (maybe change the functions
    %% start/0 and start_link/0 to start/1 and start_link/1) telling where the
    %% resource to find the events is. Then load it from here.
    %% Another option is to just pass the event straight to the server
    %% through this function.
    loop(#state{events=orddict:new(),
                clients=orddict:new()}).

subscribe(Pid) ->
	io:format("evserv subscribe~n"),
    Ref = erlang:monitor(process, whereis(?MODULE)),
    ?MODULE ! {self(), Ref, {subscribe, Pid}},
    receive
        {Ref, ok} ->
			io:format("evserv subscribe receive ok~n"),
            {ok, Ref};
        {'DOWN', Ref, process, _Pid, Reason} ->
			io:format("evserv subscribe receive down~n"),
            {error, Reason}
    after 5000 ->
		io:format("evserv subscribe after~n"),
        {error, timeout}
    end.
%%add wywołuje error jako treść messga
add_event(Name, Description, TimeOut, Num_of_reminds, Remind_dates) ->
	X = lists:foldl(fun(_, Sum) -> 1 + Sum end, 0, Remind_dates),
	if 	X == Num_of_reminds ->
		Z = reminder_before_event(Remind_dates, TimeOut),
		if Z == true ->
			io:format("evserv add_event~n"),
			Ref = make_ref(),
			?MODULE ! {self(), Ref, {add, Name, Description, TimeOut, Num_of_reminds, Remind_dates}},
			receive
				{Ref, Msg} -> 
				io:format("evserv add_event receive ~n"),
				Msg
			after 5000 ->
				io:format("evserv add_event after~n"),
				{error, timeout}
			end;
			Z == false ->
			io:format("Co najmniej jedno przypomnienie ustawione jest po wydarzeniu. ~n"),
			false
		end;
		X =/= Num_of_reminds ->
		io:format("Liczba przypomnień nie zgadza się z zadeklarowaną wartością.~n"),
		false
	end.
 %% add event 2 rozróżnia wiadomości, czy to error czy nie, i przy errorze wywołuje funkcję error
add_event2(Name, Description, TimeOut) ->
	io:format("evserv add_event2~n"),
    Ref = make_ref(),
    ?MODULE ! {self(), Ref, {add, Name, Description, TimeOut}},
    receive
        {Ref, {error, Reason}} -> 
		io:format("evserv add_event2 receive error~n"),
		erlang:error(Reason);
        {Ref, Msg} -> 
		io:format("evserv add_event2 receive message~n"),
		Msg
    after 5000 ->
		io:format("evserv add_event2 after~n"),
        {error, timeout}
    end.

cancel(Name) ->
	io:format("evserv cancel~n"),
    Ref = make_ref(),
    ?MODULE ! {self(), Ref, {cancel, Name}},
    receive
        {Ref, ok} -> 
		io:format("evserv cancel receive ok~n"),
		ok
    after 5000 ->
		io:format("evserv cancel after~n"),
        {error, timeout}
    end.

listen(Delay) ->
	io:format("evserv listen~n"),
    receive
        M = {done, _Name, _Description} ->
			io:format("evserv listen receive done~n"),
            [M | listen(0)];
		X = {reminder, _Name, _Description} ->
			io:format("evserv listen receive reminder ~n"),
			[X|listen(0)]
    after Delay*1000 ->
		io:format("evserv listen after~n"),
        []
    end.
	
%%% The Server itself

loop(S=#state{}) ->
	io:format("evserv loop~n"),

    receive
        {Pid, MsgRef, {subscribe, Client}} ->
			io:format("evserv loop receive subscribe~n"),
            Ref = erlang:monitor(process, Client),
			%% Ref jest kluczem pod którym zapisywana jest wartosć Client w NewClients
            NewClients = orddict:store(Ref, Client, S#state.clients),
			%% Żeby dostać pid aktualnego klienta, musimy zrobić find(Ref,NewClients)
			X = orddict:size(NewClients),
            io:fwrite("wartos ~p~n",[X]),
			Pid ! {MsgRef, ok},
            loop(S#state{clients=NewClients});
        {Pid, MsgRef, {add, Name, Description, TimeOut, Num_of_reminds, Remind_dates}} ->
			io:format("evserv loop receive add~n"),
            case (valid_datetime(TimeOut) and valid_reminders(Remind_dates)) of
                true ->
					io:format("evserv loop receive add true~n"),
                    EventPid = event:start_link(Name, TimeOut, Num_of_reminds, Remind_dates),
                    NewEvents = orddict:store(Name,
                                              #event{name=Name,
                                                     description=Description,
                                                     pid=EventPid,
                                                     timeout=TimeOut,
													 num_of_reminds = Num_of_reminds,
													 remind_dates = Remind_dates},
                                              S#state.events),
                    Pid ! {MsgRef, ok},
                    loop(S#state{events=NewEvents});
                false ->
					io:format("evserv loop receive add false~n"),
                    Pid ! {MsgRef, {error, bad_timeout}},
                    loop(S)
            end;
        {Pid, MsgRef, {cancel, Name}} ->
			io:format("evserv loop receive cancel~n"),
            Events = case orddict:find(Name, S#state.events) of
                         {ok, E} ->
							io:format("evserv loop receive cancel case ok~n"),
                             event:cancel(E#event.pid),
                             orddict:erase(Name, S#state.events);
                         error ->
							io:format("evserv loop receive cancel error~n"),
                             S#state.events
                     end,
            Pid ! {MsgRef, ok},
            loop(S#state{events=Events});
        {reminder, Name} ->
			io:format("evserv loop receive reminder~n"),
            case orddict:find(Name, S#state.events) of
                {ok, E} ->
				io:format("evserv loop receive reminder case ok~n"),
                    send_to_clients({reminder, E#event.name, E#event.description},
                                    S#state.clients),
                    loop(S);
                error ->
					io:format("evserv loop receive reminder error~n"),
                    %% This may happen if we cancel an event and
                    %% it fires at the same time
                    loop(S)
            end;
		{done, Name} ->
			io:format("evserv loop receive done~n"),
            case orddict:find(Name, S#state.events) of
                {ok, E} ->
				io:format("evserv loop receive done case ok~n"),
                    send_to_clients({done, E#event.name, E#event.description},
                                    S#state.clients),
                    NewEvents = orddict:erase(Name, S#state.events),
                    loop(S#state{events=NewEvents});
                error ->
					io:format("evserv loop receive done error~n"),
                    %% This may happen if we cancel an event and
                    %% it fires at the same time
                    loop(S)
            end;
        shutdown ->
			io:format("evserv loop receive shutdown~n"),
            exit(shutdown);
        {'DOWN', Ref, process, _Pid, _Reason} ->
			io:format("evserv loop receive down~n"),
            loop(S#state{clients=orddict:erase(Ref, S#state.clients)});
        code_change ->
			io:format("evserv loop receive code_change~n"),
            ?MODULE:loop(S);
        {Pid, debug} -> %% used as a hack to let me do some unit testing
            io:format("evserv loop receive debug~n"),
			Pid ! S,
            loop(S);
        Unknown ->
            io:format("Unknown message: ~p~n",[Unknown]),
            loop(S)
    end.



%%% Internal Functions
send_to_clients(Msg, ClientDict) ->
	io:format("evserv send to clients~n"),
    orddict:map(fun(_Ref, Pid) -> Pid ! Msg end, ClientDict).

valid_reminders([H|T]) ->
	case valid_datetime(H) of
	true -> valid_reminders(T);
	false -> false
	end;
valid_reminders([]) -> true;
valid_reminders(_) ->
	false.

valid_datetime({Date,Time}) ->
	io:format("evserv valid_datetime~n"),

    try
        calendar:valid_date(Date) andalso valid_time(Time)
    catch
        error:function_clause -> %% not in {{Y,M,D},{H,Min,S}} format
            false
    end;		
valid_datetime(_) ->
    false.

reminder_before_event(Remind_dates, DateTime) ->
	X = lists:max(Remind_dates),
	ToGo = calendar:datetime_to_gregorian_seconds(DateTime) -
           calendar:datetime_to_gregorian_seconds(X),
	if 	ToGo > 0 -> false;
        ToGo =< 0 -> true
    end.
	

%% calendar has valid_date, but nothing for days.
%% This function is based on its interface.
%% Ugly, but ugh.
valid_time({H,M,S}) -> 
	io:format("evserv valid time~n"),
valid_time(H,M,S).
valid_time(H,M,S) when H >= 0, H < 24,
                       M >= 0, M < 60,
                       S >= 0, S < 60 -> true;
valid_time(_,_,_) -> false.
