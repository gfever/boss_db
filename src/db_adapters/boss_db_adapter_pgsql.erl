-module(boss_db_adapter_pgsql).
-behaviour(boss_db_adapter).
-export([init/1, terminate/1, start/1, stop/0, find/2, find/7]).
-export([count/3, counter/2, incr/3, delete/2, save_record/2]).
-export([push/2, pop/2, dump/1, execute/2, execute/3, transaction/2]).

start(_) ->
    ok.

stop() ->
    ok.

init(Options) ->
    DBHost = proplists:get_value(db_host, Options, "localhost"),
    DBPort = proplists:get_value(db_port, Options, 5432),
    DBUsername = proplists:get_value(db_username, Options, "guest"),
    DBPassword = proplists:get_value(db_password, Options, ""),
    DBDatabase = proplists:get_value(db_database, Options, "test"),
    pgsql:connect(DBHost, DBUsername, DBPassword, 
        [{port, DBPort}, {database, DBDatabase}]).

terminate(Conn) ->
    pgsql:close(Conn).

find(Conn, Id) when is_list(Id) ->
    {Type, TableName, IdColumn, TableId} = boss_sql_lib:infer_type_from_id(Id),
    Res = pgsql:equery(Conn, ["SELECT * FROM ", TableName, " WHERE ", IdColumn, " = $1"], [TableId]),
    case Res of
        {ok, _Columns, []} ->
            undefined;
        {ok, Columns, [Record]} ->
            case boss_record_lib:ensure_loaded(Type) of
                true -> activate_record(Record, Columns, Type);
                false -> {error, {module_not_loaded, Type}}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

find(Conn, Type, Conditions, Max, Skip, Sort, SortOrder) when is_atom(Type), is_list(Conditions), 
                                                              is_integer(Max) orelse Max =:= all, is_integer(Skip), 
                                                              is_atom(Sort), is_atom(SortOrder) ->
    case boss_record_lib:ensure_loaded(Type) of
        true ->
            Query = build_select_query(Type, Conditions, Max, Skip, Sort, SortOrder),
            Res = pgsql:equery(Conn, Query, []),
            case Res of
                {ok, Columns, ResultRows} ->
                    FilteredRows = case {Max, Skip} of
                        {all, Skip} when Skip > 0 ->
                            lists:nthtail(Skip, ResultRows);
                        _ ->
                            ResultRows
                    end,
                    lists:map(fun(Row) ->
                                activate_record(Row, Columns, Type)
                        end, FilteredRows);
                {error, Reason} ->
                    {error, Reason}
            end;
        false -> {error, {module_not_loaded, Type}}
    end.

count(Conn, Type, Conditions) ->
    ConditionClause = build_conditions(Type, Conditions),
    TableName = type_to_table_name(Type),
    {ok, _, [{Count}]} = pgsql:equery(Conn, 
        ["SELECT COUNT(*) AS count FROM ", TableName, " WHERE ", ConditionClause]),
    Count.

counter(Conn, Id) when is_list(Id) ->
    Res = pgsql:equery(Conn, "SELECT value FROM counters WHERE name = $1", [Id]),
    case Res of
        {ok, _, [{Value}]} -> Value;
        {error, _Reason} -> 0
    end.

incr(Conn, Id, Count) ->
    Res = pgsql:equery(Conn, "UPDATE counters SET value = value + $1 WHERE name = $2 RETURNING value", 
        [Count, Id]),
    case Res of
        {ok, _, _, [{Value}]} -> Value;
        {error, _Reason} -> 
            Res1 = pgsql:equery(Conn, "INSERT INTO counters (name, value) VALUES ($1, $2) RETURNING value", 
                [Id, Count]),
            case Res1 of
                {ok, _, _, [{Value}]} -> Value;
                {error, Reason} -> {error, Reason}
            end
    end.

delete(Conn, Id) when is_list(Id) ->
    {_, TableName, IdColumn, TableId} = boss_sql_lib:infer_type_from_id(Id),
    Res = pgsql:equery(Conn, ["DELETE FROM ", TableName, " WHERE ", IdColumn, " = $1"], [TableId]),
    case Res of
        {ok, _Count} -> 
            pgsql:equery(Conn, "DELETE FROM counters WHERE name = $1", [Id]),
            ok;
        {error, Reason} -> {error, Reason}
    end.

save_record(Conn, Record) when is_tuple(Record) ->
    case Record:id() of
        id ->
            Record1 = maybe_populate_id_value(Record),
            Type = element(1, Record1),
            Query = build_insert_query(Record1),
            Res = pgsql:equery(Conn, Query, []),
            case Res of
                {ok, _, _, [{Id}]} ->
                    {ok, Record1:set(id, lists:concat([Type, "-", id_value_to_string(Id)]))};
                {error, Reason} -> {error, Reason}
            end;
        Defined when is_list(Defined) ->
            Query = build_update_query(Record),
            Res = pgsql:equery(Conn, Query, []),
            case Res of
                {ok, _} -> {ok, Record};
                {error, Reason} -> {error, Reason}
            end
    end.


push(Conn, Depth) ->
    case Depth of 0 -> pgsql:squery(Conn, "BEGIN"); _ -> ok end,
    pgsql:squery(Conn, "SAVEPOINT savepoint"++integer_to_list(Depth)).

pop(Conn, Depth) ->
    pgsql:squery(Conn, "ROLLBACK TO SAVEPOINT savepoint"++integer_to_list(Depth - 1)).

dump(_Conn) -> "".

execute(Conn, Commands) ->
    pgsql:squery(Conn, Commands).

execute(Conn, Commands, Params) ->
    pgsql:equery(Conn, Commands, Params).

transaction(Conn, TransactionFun) ->
    case pgsql:with_transaction(Conn, fun(_C) -> TransactionFun() end) of
        {rollback, Reason} -> {aborted, Reason};
        Other -> {atomic, Other}
    end.

% internal

id_value_to_string(Id) when is_atom(Id) -> atom_to_list(Id);
id_value_to_string(Id) when is_integer(Id) -> integer_to_list(Id);
id_value_to_string(Id) when is_binary(Id) -> binary_to_list(Id);
id_value_to_string(Id) -> Id.

maybe_populate_id_value(Record) ->
    case boss_sql_lib:keytype(Record) of 
        uuid -> Record:set(id, uuid:to_string(uuid:uuid4()));
        _ -> Record
end.

type_to_table_name(Type) when is_atom(Type) ->
    type_to_table_name(atom_to_list(Type));
type_to_table_name(Type) when is_list(Type) ->
    inflector:pluralize(Type).

integer_to_id(Val, KeyString) ->
    ModelName = string:substr(KeyString, 1, string:len(KeyString) - string:len("_id")),
    ModelName ++ "-" ++ id_value_to_string(Val).

activate_record(Record, Metadata, Type) ->
    AttributeTypes = boss_record_lib:attribute_types(Type),
    AttributeColumns = boss_record_lib:attribute_columns(Type),
    apply(Type, new, lists:map(fun
                (id) ->
                    DBColumn = proplists:get_value('id', AttributeColumns),
                    Index = keyindex(list_to_binary(DBColumn), 2, Metadata),
                    atom_to_list(Type) ++ "-" ++ id_value_to_string(element(Index, Record));
                (Key) ->
                    DBColumn = proplists:get_value(Key, AttributeColumns),
                    Index = keyindex(list_to_binary(DBColumn), 2, Metadata),
                    AttrType = proplists:get_value(Key, AttributeTypes),
                    case element(Index, Record) of
                        undefined -> undefined;
                        null -> undefined;
                        Val -> 
                            case boss_sql_lib:is_foreign_key(Key) of
                                true -> integer_to_id(Val, DBColumn);
                                false -> boss_record_lib:convert_value_to_type(Val, AttrType)
                            end
                    end
            end, boss_record_lib:attribute_names(Type))).

keyindex(Key, N, TupleList) ->
    keyindex(Key, N, TupleList, 1).

keyindex(Key, _N, [], _Index) ->
    throw({error, "Expected attribute '" ++ binary_to_list(Key) ++ "' was not found in Postgres query results. Synchronise your model and data'"});
keyindex(Key, N, [Tuple|Rest], Index) ->
    case element(N, Tuple) of
        Key -> Index;
        _ -> keyindex(Key, N, Rest, Index + 1)
    end.

sort_order_sql(descending) ->
    "DESC";
sort_order_sql(ascending) ->
    "ASC".

build_insert_query(Record) ->
    Type = element(1, Record),
    TableName = type_to_table_name(Type),
    AttributeColumns = Record:attribute_columns(),
    {Attributes, Values} = lists:foldl(fun
            ({_, undefined}, Acc) -> Acc;
            ({'id', V}, {Attrs, Vals}) -> 
                DBColumn = proplists:get_value('id', AttributeColumns),
                {_, _, _, TableId} = boss_sql_lib:infer_type_from_id(V),
                {[DBColumn|Attrs], [pack_value(TableId)|Vals]};
            ({A, V}, {Attrs, Vals}) ->
                DBColumn = proplists:get_value(A, AttributeColumns),
                Value = case boss_sql_lib:is_foreign_key(A) of
                    true ->
                        {_, _, _, ForeignId} = boss_sql_lib:infer_type_from_id(V),
                        ForeignId;
                    false ->
                        V
                end,
                {[DBColumn|Attrs], [pack_value(Value)|Vals]}
        end, {[], []}, Record:attributes()),
    ["INSERT INTO ", TableName, " (", 
        string:join(Attributes, ", "),
        ") values (",
        string:join(Values, ", "),
        ")",
        " RETURNING id"
    ].

build_update_query(Record) ->
    {_, TableName, IdColumn, Id} = boss_sql_lib:infer_type_from_id(Record:id()),
    AttributeColumns = Record:attribute_columns(),
    Updates = lists:foldl(fun
            ({id, _}, Acc) -> Acc;
            ({A, V}, Acc) -> 
                DBColumn = proplists:get_value(A, AttributeColumns),
                Value = case {boss_sql_lib:is_foreign_key(A), V =/= undefined} of
                    {true, true} ->
                        {_, _, _, ForeignId} = boss_sql_lib:infer_type_from_id(V),
                        ForeignId;
                    _ ->
                        V
                end,
                [DBColumn ++ " = " ++ pack_value(Value)|Acc]
        end, [], Record:attributes()),
    ["UPDATE ", TableName, " SET ", string:join(Updates, ", "),
        " WHERE ", IdColumn, " = ", pack_value(Id)].

build_select_query(Type, Conditions, Max, Skip, Sort, SortOrder) ->
    TableName = type_to_table_name(Type),
    ["SELECT * FROM ", TableName, 
        " WHERE ", build_conditions(Type, Conditions),
        " ORDER BY ", atom_to_list(Sort), " ", sort_order_sql(SortOrder),
        case Max of all -> ""; _ -> [" LIMIT ", integer_to_list(Max),
                    " OFFSET ", integer_to_list(Skip)] end
    ].

build_conditions(Type, Conditions) ->
    AttributeColumns = boss_record_lib:attribute_columns(Type),
    Conditions2 = lists:map(fun
            ({'id' = Key, Op, Value}) ->
                Key2 = proplists:get_value(Key, AttributeColumns, Key),
                boss_sql_lib:convert_id_condition_to_use_table_ids({Key2, Op, Value});
            ({Key, Op, Value}) ->
                Key2 = proplists:get_value(Key, AttributeColumns, Key),
                case boss_sql_lib:is_foreign_key(Key) of
                    true -> boss_sql_lib:convert_id_condition_to_use_table_ids({Key2, Op, Value});
                    false -> {Key2, Op, Value}
                end
        end, Conditions),
    build_conditions1(Conditions2, [" TRUE"]).

build_conditions1([], Acc) ->
    Acc;

build_conditions1([{Key, 'equals', Value}|Rest], Acc) when Value == undefined ->
    build_conditions1(Rest, add_cond(Acc, Key, "is", pack_value(Value)));
build_conditions1([{Key, 'equals', Value}|Rest], Acc) ->
    build_conditions1(Rest, add_cond(Acc, Key, "=", pack_value(Value)));
build_conditions1([{Key, 'not_equals', Value}|Rest], Acc) when Value == undefined ->
    build_conditions1(Rest, add_cond(Acc, Key, "is not", pack_value(Value)));
build_conditions1([{Key, 'not_equals', Value}|Rest], Acc) ->
    build_conditions1(Rest, add_cond(Acc, Key, "!=", pack_value(Value)));
build_conditions1([{Key, 'in', Value}|Rest], Acc) when is_list(Value) ->
    PackedValues = pack_set(Value),
    build_conditions1(Rest, add_cond(Acc, Key, "IN", PackedValues));
build_conditions1([{Key, 'not_in', Value}|Rest], Acc) when is_list(Value) ->
    PackedValues = pack_set(Value),
    build_conditions1(Rest, add_cond(Acc, Key, "NOT IN", PackedValues));
build_conditions1([{Key, 'in', {Min, Max}}|Rest], Acc) when Max >= Min ->
    PackedValues = pack_range(Min, Max),
    build_conditions1(Rest, add_cond(Acc, Key, "BETWEEN", PackedValues));
build_conditions1([{Key, 'not_in', {Min, Max}}|Rest], Acc) when Max >= Min ->
    PackedValues = pack_range(Min, Max),
    build_conditions1(Rest, add_cond(Acc, Key, "NOT BETWEEN", PackedValues));
build_conditions1([{Key, 'gt', Value}|Rest], Acc) ->
    build_conditions1(Rest, add_cond(Acc, Key, ">", pack_value(Value)));
build_conditions1([{Key, 'lt', Value}|Rest], Acc) ->
    build_conditions1(Rest, add_cond(Acc, Key, "<", pack_value(Value)));
build_conditions1([{Key, 'ge', Value}|Rest], Acc) ->
    build_conditions1(Rest, add_cond(Acc, Key, ">=", pack_value(Value)));
build_conditions1([{Key, 'le', Value}|Rest], Acc) ->
    build_conditions1(Rest, add_cond(Acc, Key, "<=", pack_value(Value)));
build_conditions1([{Key, 'matches', "*"++Value}|Rest], Acc) ->
    build_conditions1(Rest, add_cond(Acc, Key, "~*", pack_value(Value)));
build_conditions1([{Key, 'not_matches', "*"++Value}|Rest], Acc) ->
    build_conditions1(Rest, add_cond(Acc, Key, "!~*", pack_value(Value)));
build_conditions1([{Key, 'matches', Value}|Rest], Acc) ->
    build_conditions1(Rest, add_cond(Acc, Key, "~", pack_value(Value)));
build_conditions1([{Key, 'not_matches', Value}|Rest], Acc) ->
    build_conditions1(Rest, add_cond(Acc, Key, "!~", pack_value(Value)));
build_conditions1([{Key, 'contains', Value}|Rest], Acc) ->
    build_conditions1(Rest, add_cond(Acc, pack_tsvector(Key), "@@", pack_tsquery([Value], "&")));
build_conditions1([{Key, 'not_contains', Value}|Rest], Acc) ->
    build_conditions1(Rest, add_cond(Acc, pack_tsvector(Key), "@@", pack_tsquery_not([Value], "&")));
build_conditions1([{Key, 'contains_all', Values}|Rest], Acc) when is_list(Values) ->
    build_conditions1(Rest, add_cond(Acc, pack_tsvector(Key), "@@", pack_tsquery(Values, "&")));
build_conditions1([{Key, 'not_contains_all', Values}|Rest], Acc) when is_list(Values) ->
    build_conditions1(Rest, add_cond(Acc, pack_tsvector(Key), "@@", pack_tsquery_not(Values, "&")));
build_conditions1([{Key, 'contains_any', Values}|Rest], Acc) when is_list(Values) ->
    build_conditions1(Rest, add_cond(Acc, pack_tsvector(Key), "@@", pack_tsquery(Values, "|")));
build_conditions1([{Key, 'contains_none', Values}|Rest], Acc) when is_list(Values) ->
    build_conditions1(Rest, add_cond(Acc, pack_tsvector(Key), "@@", pack_tsquery_not(Values, "|"))).

add_cond(Acc, Key, Op, PackedVal) ->
    [lists:concat([Key, " ", Op, " ", PackedVal, " AND "])|Acc].

pack_tsvector(Key) ->
    atom_to_list(Key) ++ "::tsvector".

pack_tsquery(Values, Op) ->
    "'" ++ string:join(lists:map(fun escape_sql/1, Values), " "++Op++" ") ++ "'::tsquery".

pack_tsquery_not(Values, Op) ->
    "'!(" ++ string:join(lists:map(fun escape_sql/1, Values), " "++Op++" ") ++ ")'::tsquery".

pack_set(Values) ->
    "(" ++ string:join(lists:map(fun pack_value/1, Values), ", ") ++ ")".

pack_range(Min, Max) ->
    pack_value(Min) ++ " AND " ++ pack_value(Max).

escape_sql(Value) ->
    escape_sql1(Value, []).

escape_sql1([], Acc) ->
    lists:reverse(Acc);
escape_sql1([$'|Rest], Acc) ->
    escape_sql1(Rest, [$', $'|Acc]);
escape_sql1([C|Rest], Acc) ->
    escape_sql1(Rest, [C|Acc]).

pack_datetime({Date, {Y, M, S}}) when is_float(S) ->
    pack_datetime({Date, {Y, M, erlang:round(S)}});
pack_datetime(DateTime) ->
    "TIMESTAMP '" ++ erlydtl_filters:date(DateTime, "c") ++ "'".

pack_now(Now) -> pack_datetime(calendar:now_to_datetime(Now)).

pack_value(undefined) ->
    "null";
pack_value(V) when is_binary(V) ->
    pack_value(binary_to_list(V));
pack_value(V) when is_list(V) ->
    "'" ++ escape_sql(V) ++ "'";
pack_value({MegaSec, Sec, MicroSec}) when is_integer(MegaSec) andalso is_integer(Sec) andalso is_integer(MicroSec) ->
    pack_now({MegaSec, Sec, MicroSec});
pack_value({{_, _, _}, {_, _, _}} = Val) ->
    pack_datetime(Val);
pack_value(Val) when is_integer(Val) ->
    integer_to_list(Val);
pack_value(Val) when is_float(Val) ->
    float_to_list(Val);
pack_value(true) ->
    "TRUE";
pack_value(false) ->
    "FALSE".
