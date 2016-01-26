-module(quickprng).
-author('mbranton@gmail.com').

-export([stream/0]).

%% Rate at which a new random key is mixed into the stream
-define(KEY_REFRESH, 1000000).

%% /dev/random is a special device and has blocking semantics
%% that stall the Erlang VM and could halt the PRNG if it isn't handled correctly.
queue_blocking_reader() ->
	Parent = self(),
	spawn(fun() ->
	Port = open_port("/dev/random", [binary, eof]),
	F = fun Loop(EPort) ->
				   receive
				   	   {EPort, {data, Data}} -> 
				   	   	   Parent ! {random, Data},
				   	   	   Loop(EPort);
				   	   {EPort, eof} -> Loop(EPort)
				   end
		  end,
		  F(Port)
	end).


%% This accumulates entropy for key reseeding
%% and preserves excess entropy for later use
acquire_entropy([]) ->  not_enough_entropy;
acquire_entropy(Storage) -> 
	acquire_entropy(Storage, <<>>, 0).

acquire_entropy(Storage, Data, Size) when Size > 32 ->
	Over = byte_size(Data) - 32,
	<<X:(Over)/binary, Rest/binary>> = Data,
	{ok, [X|Storage], Rest};
acquire_entropy([], _Data, _Size) -> not_enough_entropy;
acquire_entropy([H|T], Data, Size) -> 
	acquire_entropy(T, <<H/binary, Data/binary>>, Size+byte_size(H)).

entropy_pool() -> 
	register(entropy_pool,
			 spawn(fun() -> 
			 			   queue_blocking_reader(),
			 			   F = fun Loop(Storage) ->
			 			   receive
							   {random, Data} ->  Loop([Data|Storage]);
			 			   	   {get_entropy, Pid} ->
			 			   	   	   case acquire_entropy(Storage) of
									   {ok, NewStorage, Data} ->
									   	   Pid ! {entropy, Data},
									   	   Loop(NewStorage);
									   not_enough_entropy ->
									   	   Pid ! {entropy, blocking},
									   	   Loop(Storage)
								   end
			 			   end
			 	   end,
				   F([])
			 	   end)).

get_seed() ->  entropy_pool ! {get_entropy, self()}, 
			   receive 
				   {entropy, blocking} ->
				   	   %% There isn't enough entropy to fill this request
				   	   %% Mix in the timestamp as a pseudo random source
					   {A,B,C} = os:timestamp(),
					   <<(A+B+C):128>>;
			   	   {entropy, D} -> D
			   end.

stream() -> 
	entropy_pool(),
	timer:sleep(100),
	stream(get_seed(), get_seed(), 0).

stream(Bin, _Key, ?KEY_REFRESH) -> stream(Bin, get_seed(), 0);
stream(Bin, Key, C) -> 
	Next = crypto:hash(sha256, <<Bin/binary, Key/binary, C:128>>),
	file:write(standard_io, Next),
	stream(Next, Key, C+1).

