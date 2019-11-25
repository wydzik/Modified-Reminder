-module(event).
-export([start/2, start_link/4, cancel/1]).
-export([init/5, loop/1]).
-record(state, {server,
                name="",
                to_go={{1970,1,1},{0,0,0}},
				num_of_reminds = 0,
				remind_dates = []}).

%%% Public interface
start(EventName, DateTime) ->
    spawn(?MODULE, init, [self(), EventName, DateTime]).

start_link(EventName, DateTime, Num_of_reminds, Remind_dates) ->
    spawn_link(?MODULE, init, [self(), EventName, DateTime, Num_of_reminds, Remind_dates]).


cancel(Pid) ->
    %% Monitor in case the process is already dead
    Ref = erlang:monitor(process, Pid),
    Pid ! {self(), Ref, cancel},
    receive
        {Ref, ok} ->
            erlang:demonitor(Ref, [flush]),
            ok;
        {'DOWN', Ref, process, Pid, _Reason} ->
            ok
    end.


%%% Event's innards
init(Server, EventName, DateTime, Num_of_reminds, Remind_dates) ->
	loop(#state{server=Server,
                name=EventName,
                to_go= DateTime,
				num_of_reminds = Num_of_reminds,
				remind_dates = reminders_time_to_go(Remind_dates)}).

%% Loop uses a list for times in order to go around the ~49 days limit on timeouts.
loop(S = #state{server=Server, to_go = DateTime, num_of_reminds = Num_of_reminds, remind_dates = [[H|T]|Next_reminder]}) ->
	if Num_of_reminds > 0 ->
		receive	
        {Server, Ref, cancel} ->
            Server ! {Ref, ok}
			
		after H*1000 ->
		
			if T =:= [] ->
				Server ! {reminder, S#state.name},
				loop(S#state{num_of_reminds = Num_of_reminds - 1, remind_dates = Next_reminder});
			   
			   T =/= [] ->
				loop(S#state{ remind_dates = [[T]|Next_reminder]})
			end
		end;
		
	   Num_of_reminds == 0 ->
		loop(S#state{num_of_reminds = -1, remind_dates = [time_to_go(DateTime)]});
	
	   Num_of_reminds == -1 ->
		receive
			{Server, Ref, cancel} ->
				Server ! {Ref, ok}
				
		after H*1000 ->
		
			if T =:= [] ->
				Server ! {done, S#state.name};
				
			   T =/= [] ->
				loop(S#state{remind_dates=T})
			end
		end
	end.

reminders_time_to_go([]) -> [];
reminders_time_to_go(Remind_dates) ->
	reminders_time_to_go(Remind_dates,0).
reminders_time_to_go([],_)-> [[0,0],0];
reminders_time_to_go([H|T],X) ->
	if 	X == 0 -> 
		Now = calendar:local_time(),
		ToGo = calendar:datetime_to_gregorian_seconds(H) -
				calendar:datetime_to_gregorian_seconds(Now),
		Secs = if ToGo > 0  -> ToGo;
				ToGo =< 0 -> 0
				end,
		[normalize(Secs)|reminders_time_to_go(T,H)];
		X =/= 0 ->
		Now = X,
		ToGo = calendar:datetime_to_gregorian_seconds(H) -
				calendar:datetime_to_gregorian_seconds(Now),
		Secs = if ToGo > 0  -> ToGo;
				ToGo =< 0 -> 0
				end,
		[normalize(Secs)|reminders_time_to_go(T,H)]
	end.


%%% private functions
time_to_go(TimeOut={{_,_,_}, {_,_,_}}) ->
	Now = calendar:local_time(),
    ToGo = calendar:datetime_to_gregorian_seconds(TimeOut) -
           calendar:datetime_to_gregorian_seconds(Now),
    Secs = if ToGo > 0  -> ToGo;
              ToGo =< 0 -> 0
           end,
    normalize(Secs).

%% Because Erlang is limited to about 49 days (49*24*60*60*1000) in
%% milliseconds, the following function is used
normalize(N) ->
    Limit = 49*24*60*60,
    [N rem Limit | lists:duplicate(N div Limit, Limit)].
