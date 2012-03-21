%%%----------------------------------------------------------------------
%%% File    : errdb_store.erl
%%% Author  : Ery Lee <ery.lee@gmail.com>
%%% Purpose : File Storage 
%%% Created : 03 Apr. 2010
%%% License : http://www.opengoss.com
%%%
%%% Copyright (C) 2012, www.opengoss.com
%%%----------------------------------------------------------------------
-module(errdb_store).

-author('ery.lee@gmail.com').

-include_lib("elog/include/elog.hrl").

-import(lists, [concat/1, reverse/1]).

-import(extbif, [zeropad/1, timestamp/0, datetime/1,strfdate/1]).

-import(errdb_misc, [b2l/1, i2l/1, l2a/1, l2b/1]).

-export([start_link/2,
        insert/2]).

-behavior(gen_server).

-export([init/1, 
        handle_call/3, 
        priorities_call/3,
        handle_cast/2,
        handle_info/2,
        terminate/2,
        code_change/3]).

-define(SCHEMA, "CREATE TABLE metrics ("
				"node TEXT, object TEXT, "
				"timestamp INTEGER, "
				"metric INTEGER, value REAL);").

-define(INDEX, "CREATE INDEX node_time_idx on "
			   "metrics(node, object, timestamp);").

-define(PRAGMA, "pragma synchronous=normal;").

-define(ATTACH(File), ["attach '", File, "' as hourly;"]).

-define(IMPORT, "insert into metrics(node,object,timestamp,metric,value) "
				"select node,object,timestamp,metric,value from hourly.metrics").

%db0: hour db
%db1: today db
%db2: yesterday db
-record(state, {id, dir, db0, db1, db2}).

start_link(Id, Dir) ->
    gen_server2:start_link({local, sname(Id)}, ?MODULE, 
		[Id, Dir], [{spawn_opt, [{min_heap_size, 204800}]}]).

sname(Id) ->
    list_to_atom("errdb_store_" ++ integer_to_list(Id)).

insert(Pid, Records) ->
	gen_server2:cast(Pid, {insert, Records}).

init([Id, Dir]) ->
	{ok, DB0} = opendb(hourly, Id, Dir),
	{ok, DB1} = opendb(today, Id, Dir),
	{ok, DB2} = opendb(yesterday, Id, Dir),
	sched_next_hourly_commit(),
	sched_next_daily_commit(),
	{ok, #state{id = Id, dir = Dir, 
		db0=DB0, db1=DB1, db2=DB2}}.
	
opendb(hourly, Id, Dir) ->
	Name = list_to_atom("hourly" ++ zeropad(hour())),
	File = concat([Dir, "/", strfdate(today()), 
		"/", zeropad(hour()), "/", dbfile(Id)]),
	opendb(Name, File);

opendb(today, Id, Dir) ->
	Name = list_to_atom("today" ++ zeropad(Id)),
	File = concat([Dir, "/", strfdate(today()), "/", dbfile(Id)]),
	opendb(Name, File);

opendb(yesterday, Id, Dir) ->
	Name = list_to_atom("yesterday" ++ zeropad(Id)),
	File = concat([Dir, "/", strfdate(yesterday()), "/", dbfile(Id)]),
	opendb(Name, File).
	
opendb(Name, File) ->
	filelib:ensure_dir(File),
	{ok, DB} = sqlite3:open(Name, [{file, File}]),
	schema(DB, sqlite3:list_tables(DB)),
	{ok, DB}.

schema(DB, []) ->
	sqlite3:sql_exec(DB, ?PRAGMA),
	sqlite3:sql_exec(DB, ?SCHEMA),
	sqlite3:sql_exec(DB, ?INDEX);

schema(_DB, [metrics]) ->
	ok.

dbfile(Id) ->
	integer_to_list(Id) ++ ".db".
	
handle_call(_Req, _From, State) ->
    {reply, {error, badreq}, State}.

priorities_call(_, _From, _State) ->
    0.

handle_cast({insert, Records}, #state{db0= DB0} = State) ->
	sqlite3:write_many(DB0, metrics, Records),
	{noreply, State};

handle_cast(Msg, State) ->
    {stop, {error, {badmsg, Msg}}, State}.

handle_info({commit, hourly}, #state{id = Id, dir = Dir, db0 = DB0, db1 = DB1} = State) ->
	sched_next_hourly_commit(),
	File = sqlite3:file(DB0),
	spawn(fun() -> 
		sqlite3:sql_exec(DB1, ?ATTACH(File)),
		sqlite3:sql_exec(DB1, ?IMPORT)
	end),
	sqlite3:close(DB0),
	{ok, NewDB0} = opendb(hourly, Id, Dir),
	{noreply, State#state{db0 = NewDB0}};

handle_info({commit, daily}, #state{id = Id, dir = Dir, db1 = DB1, db2 = DB2} = State) ->
	sched_next_daily_commit(),
	sqlite3:close(DB2),
	{ok, NewDB1} = opendb(today, Id, Dir),
	{noreply, State#state{db1 = NewDB1, db2 = DB1}};
	
handle_info(Info, State) ->
    {stop, {error, {badinfo, Info}}, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

today() -> date().

hour() -> {H,_,_} = time(), H.

yesterday() -> {Date, _} = datetime(timestamp() - 86400), Date.

sched_next_hourly_commit() ->
	Ts1 = timestamp(),
    Ts2 = (Ts1 div 3600 + 1) * 3600,
	Diff = (Ts2 + 2 - Ts1) * 1000,
    erlang:send_after(Diff, self(), {commit, hourly}).

sched_next_daily_commit() ->
	Ts1 = timestamp(),
    Ts2 = (Ts1 div 86400 + 1) * 86400,
	Diff = (Ts2 + 60 - Ts1) * 1000,
    erlang:send_after(Diff, self(), {commit, daily}).

