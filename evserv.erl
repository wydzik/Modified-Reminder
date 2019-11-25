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
    register(?MODULE, Pid=spawn(?MODULE, init, [])),
    Pid.

start_link() ->

    register(?MODULE, Pid=spawn_link(?MODULE, init, [])),
    Pid.

terminate() ->
    ?MODULE ! shutdown.

init() ->
    %% Loading events from a static file could be done here.
    %% You would need to pass an argument to init (maybe change the functions
    %% start/0 and start_link/0 to start/1 and start_link/1) telling where the
    %% resource to find the events is. Then load it from here.
    %% Another option is to just pass the event straight to the server
    %% through this function.
    loop(#state{events=orddict:new(),
                clients=orddict:new()}).

subscribe(Pid) ->
    Ref = erlang:monitor(process, whereis(?MODULE)),
    ?MODULE ! {self(), Ref, {subscribe, Pid}},
    receive
        {Ref, ok} ->
            {ok, Ref};
			
        {'DOWN', Ref, process, _Pid, Reason} ->
            {error, Reason}
    after 5000 ->
        {error, timeout}
    end.
	
add_event(Name,Description,TimeOut)->add_event(Name,Description,TimeOut,0,[]).
%%add wywołuje error jako treść messga, to była jego różnica względem  add2 
%%bo on sprawdzał czy dostał error w messageu, czy nie i jeżeli to był error,
%%to wywołuje funkcję error. A add event nie rozróżnia wiadomości.
add_event(Name, Description, TimeOut, Num_of_reminds, Remind_dates) ->
	X = lists:foldl(fun(_, Sum) -> 1 + Sum end, 0, Remind_dates),
	if 	X == Num_of_reminds ->
		if Num_of_reminds == 0 ->	
			Ref = make_ref(),
			?MODULE ! {self(), Ref, {add, Name, Description, TimeOut, Num_of_reminds, [TimeOut]}},
			receive
				{Ref, Msg} -> 
				Msg
			after 5000 ->
				{error, timeout}
			end;
		   Num_of_reminds =/= 0 ->
			Z = reminder_before_event(Remind_dates, TimeOut),
			if Z == true ->
				Ref = make_ref(),
				?MODULE ! {self(), Ref, {add, Name, Description, TimeOut, Num_of_reminds, Remind_dates}},
				receive
					{Ref, Msg} -> 
					Msg
				after 5000 ->
					{error, timeout}
				end;
			   Z == false ->
				io:format("At least one reminder is set after the event. ~n"),
				false
			end
		end;	
		X =/= Num_of_reminds ->
		io:format("Number of reminders is different than declared value.~n"),
		false
	end.

cancel(Name) ->
    Ref = make_ref(),
    ?MODULE ! {self(), Ref, {cancel, Name}},
    receive
        {Ref, ok} -> 
		io:format("Event canceled succesfully.~n"),
		ok
    after 5000 ->
        {error, timeout}
    end.

listen(Delay) ->
    receive
        M = {done, _Name, _Description} ->
			io:format("The following event is now taking place: ~n"),
            [M | listen(0)];
		X = {reminder, _Name, _Description, _TimeOut} ->
			io:format("Recieved reminder about upcoming event: ~n"),
			[X|listen(0)]
    after Delay*1000 ->
        []
    end.
	
%%% The Server itself
loop(S=#state{}) ->
    receive
        {Pid, MsgRef, {subscribe, Client}} ->
            Ref = erlang:monitor(process, Client),
			%% Ref jest kluczem pod którym zapisywana jest wartosć Client w NewClients
			%% Żeby dostać pid aktualnego klienta, musimy zrobić find(Ref,NewClients)
            NewClients = orddict:store(Ref, Client, S#state.clients),
			Pid ! {MsgRef, ok},
            loop(S#state{clients=NewClients});
			
        {Pid, MsgRef, {add, Name, Description, TimeOut, Num_of_reminds, Remind_dates}} ->
            case (valid_datetime(TimeOut) and valid_reminders(Remind_dates)) of
                true ->
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
                    Pid ! {MsgRef, {error, bad_timeout}},
                    loop(S)
            end;
			
        {Pid, MsgRef, {cancel, Name}} ->
            Events = case orddict:find(Name, S#state.events) of
                         {ok, E} ->
                             event:cancel(E#event.pid),
                             orddict:erase(Name, S#state.events);
                         error ->
                             S#state.events
                     end,
            Pid ! {MsgRef, ok},
            loop(S#state{events=Events});
			
        {reminder, Name} ->
            case orddict:find(Name, S#state.events) of
                {ok, E} ->
                    send_to_clients({reminder, E#event.name, E#event.description, E#event.timeout},
                                    S#state.clients),
                    loop(S);
                error ->
                    %% This may happen if we cancel an event and it fires at the same time
                    loop(S)
            end;
			
		{done, Name} ->
            case orddict:find(Name, S#state.events) of
                {ok, E} ->
                    send_to_clients({done, E#event.name, E#event.description},
                                    S#state.clients),
                    NewEvents = orddict:erase(Name, S#state.events),
                    loop(S#state{events=NewEvents});
                error ->
                    %% This may happen if we cancel an event and it fires at the same time
                    loop(S)
            end;
			
        shutdown ->
            exit(shutdown);
			
        {'DOWN', Ref, process, _Pid, _Reason} ->
            loop(S#state{clients=orddict:erase(Ref, S#state.clients)});
        
		code_change ->
            ?MODULE:loop(S);
        
		{Pid, debug} -> %% used as a hack to let me do some unit testing
			Pid ! S,
            loop(S);
			
        Unknown ->
            io:format("Unknown message: ~p~n",[Unknown]),
            loop(S)
    end.

%%% Internal Functions
send_to_clients(Msg, ClientDict) ->
    orddict:map(fun(_Ref, Pid) -> Pid ! Msg end, ClientDict).

valid_reminders([H|T]) ->
	case valid_datetime(H) of
	true -> valid_reminders(T);
	false -> false
	end;
valid_reminders([]) -> true;
valid_reminders(_) -> false.

valid_datetime({Date,Time}) ->
    try
        calendar:valid_date(Date) andalso valid_time(Time)
    catch
        error:function_clause -> %% not in {{Y,M,D},{H,Min,S}} format
            false
    end;		
valid_datetime(_) ->
    false.

%% checks if reminders are set before the time of event
reminder_before_event(Remind_dates, DateTime) ->
	X = lists:max(Remind_dates),
	ToGo = calendar:datetime_to_gregorian_seconds(DateTime) -
           calendar:datetime_to_gregorian_seconds(X),
	if 	ToGo < 0 -> false;
        ToGo >= 0 -> true
    end.
	

%% calendar has valid_date, but nothing for days.
%% This function is based on its interface.
%% Ugly, but ugh.
valid_time({H,M,S}) -> 
valid_time(H,M,S).
valid_time(H,M,S) when H >= 0, H < 24,
                       M >= 0, M < 60,
                       S >= 0, S < 60 -> true;
valid_time(_,_,_) -> false.
