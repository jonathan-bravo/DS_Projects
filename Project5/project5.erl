% TEST query tweets by subscribed list
% TEST query tweets by mention
% TEST logoff
% TEST logon
% TODO update the help message and be a bit more descriptive
% TODO need to report performance of simulation? How?

-module(project5).

-export([
    start_host/0,
    start_user/2,
    user_node/2,
    host_server/2,
    user_auth_server/0,
    tweet_log_server/1
]).

user_auth_server() ->
    receive
        awake ->
            ets:new(twitter_users, [set, named_table, private]),
            io:fwrite("User Auth server started.~n");
        {request_user, From, UserName, Password, Reason} ->
            if
                Reason == "New User" ->
                    self() ! {register_user, UserName, Password, From};
                true ->
                    self() ! {login_request, UserName, Password, From}
            end;
        {register_user, UserName, Password, From} ->
            ExistingUser = ets:member(twitter_users, UserName),
            if 
                ExistingUser == false ->
                    ets:insert_new(twitter_users, {UserName, Password, online, From}),
                    From ! {online, UserName, Password};
                true ->
                    io:fwrite("That user already exists, please choose another~n")
            end;
        {login_request, UserName, Password, From} ->
            ExistingUser = ets:member(twitter_users, UserName),
            [{U, P, _, _}] = ets:match_object(twitter_users, {UserName, Password, offline, none}),
            if 
                ExistingUser == true ->
                    ets:update_element(twitter_users, UserName, {3, online}), % update user to be online
                    ets:update_element(twitter_users, UserName, {4, From}),
                    From ! {online, U, P};
                true ->
                    io:fwrite("Perhaps the username or password was incorrect~n")
            end;
        {log_off, UserName} ->
            ets:update_element(twitter_users, UserName, {3, offline}),
            ets:update_element(twitter_users, UserName, {4, none});
        {get_status, UserName, From, Reason, Message} ->
            [{_, _, Status, _}] = ets:lookup(twitter_users, UserName),
            From ! {status, UserName, Status, Reason, Message};
        {post_tweet_to_online_users, Id, UserName, Tweet} ->
            OnlineUsers = ets:match(twitter_users, {'_', '_', online, '$1'}),
            [Pid ! {print_tweet, Id, UserName, Tweet} || [Pid] <- OnlineUsers]
    end,
    user_auth_server().


search_tweets(_, _, Key, MatchList) when Key == '$end_of_table' ->
    MatchList;
search_tweets(Table, By, Key, MatchList) ->
    %io:fwrite("This is the key: ~p~n", [Key]), 
    NextKey = ets:next(Table, Key),
    %io:fwrite("This is the nextkey: ~p~n", [NextKey]),
    if
        NextKey =/= '$end_of_table' ->
            [{_, _, Tweet}] = ets:lookup(Table, NextKey),
            io:fwrite("This is the tweet: ~p~n", [Tweet]),
            Tag = string:find(Tweet, By),
            if
                Tag == By -> UpdatedMatchList = lists:append([Tweet], MatchList);
                true -> UpdatedMatchList = MatchList
            end;
        true ->
            UpdatedMatchList = MatchList,
            search_tweets(Table, By, NextKey, UpdatedMatchList)
    end,
    search_tweets(Table, By, NextKey, UpdatedMatchList).


get_subscriptions([], _, MatchList) ->
    MatchList;
get_subscriptions([H|T], Table, MatchList) -> % head|tail of sbscriptions
    {_, User} = H,
    SubbedTweets = ets:match(Table, {'_', User, '_'}),
    UpdatedMatchList = lists:append(SubbedTweets, MatchList),
    get_subscriptions(T, Table, UpdatedMatchList).


tweet_log_server(Id) ->
    receive
        awake ->
            ets:new(twitter_tweets, [set, named_table, private]),
            io:fwrite("Tweet Log server started.~n"),
            NewId = Id;
        {publish_tweet, UserName, Tweet} ->
            TweetLength = string:length(Tweet),
            if 
                TweetLength > 140 ->
                    io:fwrite("Tweet is too long, needs to be =< 140 char~n");
                true ->
                    ets:insert_new(twitter_tweets, {Id, UserName, Tweet}),
                    %io:fwrite("~p:~n\t~p: ~p~n", [UserName, Id, Tweet]),
                    twitter_host ! {post_tweet_to_online_users, Id, UserName, Tweet}
            end,
            NewId = Id + 1;
        {retweet, UserName, QueryId} ->
            [{_, PostUser, Tweet}] = ets:lookup(twitter_tweets, QueryId),
            Retweet = "Retweet from @" ++ PostUser ++ ": " ++ Tweet,
            ets:insert_new(twitter_tweets, {Id, UserName, Retweet}),
            twitter_host ! {post_tweet_to_online_users, Id, UserName, Retweet},
            NewId = Id + 1;
        {search_tweets, By, From} ->
            FirstKey = ets:first(twitter_tweets),
            [{_, _, Tweet}] = ets:lookup(twitter_tweets, FirstKey),
            Tag = string:find(Tweet, By),
            MatchList = search_tweets(twitter_tweets, By, FirstKey, []),
            if
                Tag == By -> UpdatedMatchList = lists:append([Tweet], MatchList);
                true -> UpdatedMatchList = MatchList
            end,
            From ! {print_search_results, UpdatedMatchList},
            NewId = Id;
        {search_subs, Subscriptions, From} ->
            MatchList = get_subscriptions(Subscriptions, twitter_table, []),
            From ! {print_search_results, MatchList},
            NewId = Id
    end,
    tweet_log_server(NewId).


host_server(UserServer, TweetServer) ->
    receive
        awake ->
            UserServer ! awake,
            TweetServer ! awake;
        {make_user, UserName, Password, From} ->
            io:fwrite("~p - Making user: ~p~n", [self(), UserName]),
            UserServer ! {request_user, From, UserName, Password, "New User"};
        {login, UserName, Password, From} ->
            UserServer ! {request_user, From, UserName, Password, "Login"};
        {write_tweet, UserName, Tweet} ->
            TweetServer ! {publish_tweet, UserName, Tweet};
        {retweet, UserName, QueryId} ->
            TweetServer ! {retweet, UserName, QueryId};
        {log_off, UserName} ->
            UserServer ! {log_off, UserName};
        {get_status, UserName, From, Reason, Message} ->
            UserServer ! {get_status, UserName, From, Reason, Message};
        {search_tweets, Message, From} ->
            TweetServer ! {search_tweets, Message, From};
        {search_subs, Message, From} ->
            TweetServer ! {search_subs, Message, From};
        {post_tweet_to_online_users, Id, UserName, Tweet} ->
            UserServer ! {post_tweet_to_online_users, Id, UserName, Tweet};
        ping ->
            io:fwrite("~p I'm here!~n", [self()])
    end,
    host_server(UserServer, TweetServer).


user_node(TableName, HostPid) ->
    receive
        awake ->
            ets:new(TableName, [set, named_table, private]);
        {new_user, UserName, Password} ->
            Hash = binary:decode_unsigned(crypto:hash(sha256,Password)),
            {twitter_host, HostPid} ! {make_user, UserName, Hash, self()};
        {login, UserName, Password} ->
            Hash = binary:decode_unsigned(crypto:hash(sha256,Password)),
            {twitter_host, HostPid} ! {login, UserName, Hash, self()};
        {online, UserName, Password} ->
            ets:insert_new(TableName, {user_info, UserName, Password});
        log_off ->
            [{_, UserName, _}] = ets:lookup(TableName, user_info),
            ets:delete(TableName, user_info),
            {twitter_host, HostPid} ! {log_off, UserName};
            %erlang:exit(self(), normal);
        {make_tweet, Tweet} ->
            [{_, UserName, _}] = ets:lookup(TableName, user_info),
            {twitter_host, HostPid} ! {get_status, UserName, self(), "Tweet", Tweet};
        {retweet, QueryId} ->
            [{_, UserName, _}] = ets:lookup(TableName, user_info),
            {twitter_host, HostPid} ! {get_status, UserName, self(), "Retweet", QueryId};
        {subscribe, SubscribeTo} -> % Need to figure out how to show tweets now...
            [{_, UserName, _}] = ets:lookup(TableName, user_info),
            {twitter_host, HostPid} ! {get_status, UserName, self(), "Subscribe", SubscribeTo};
        {search_tweets_by_tag, Tag} ->
            [{_, UserName, _}] = ets:lookup(TableName, user_info),
            {twitter_host, HostPid} ! {get_status, UserName, self(), "Search Tags", Tag};
        search_tweets_by_mention ->
            [{_, UserName, _}] = ets:lookup(TableName, user_info),
            Mention = "@" ++ UserName,
            {twitter_host, HostPid} ! {get_status, UserName, self(), "Search Mentions", Mention};
        search_tweets_by_subscription -> % not implemented yet...
            [{_, UserName, _}] = ets:lookup(TableName, user_info),
            Subscriptions = ets:lookup(TableName, subscribed),
            {twitter_host, HostPid} ! {get_status, UserName, self(), "Search Subscriptions", Subscriptions};
        {status, UserName, Status, Reason, Message} ->
            if
                Status == online ->
                    if
                        Reason == "Tweet" ->
                            {twitter_host, HostPid} ! {write_tweet, UserName, Message};
                        Reason == "Retweet" ->
                            {twitter_host, HostPid} ! {retweet, UserName, Message};
                        Reason == "Subscribe" ->
                            ets:insert_new(TableName, {subscribed, Message}),
                            io:fwrite("~p - Subscribed to: ~p~n", [self(), Message]);
                        Reason == "Search Tags" ->
                            {twitter_host, HostPid} ! {search_tweets, Message, self()};
                        Reason == "Search Mentions" ->
                            {twitter_host, HostPid} ! {search_tweets, Message, self()};
                        Reason == "Search Subscriptions" ->
                            {twitter_host, HostPid} ! {search_subs, Message, self()} % How to make list of subscribtions play nice with search tweet in tweet_server
                    end;
                true ->
                    io:fwrite("You need to log in first~n")
            end;
        {print_search_results, MatchList} ->
            io:fwrite("~p~n", [MatchList]);
        {print_tweet, Id, PostUserName, Tweet} ->
            [{_, UserName, _}] = ets:lookup(TableName, user_info),
            Mention = "@" ++ UserName,
            Tag = string:find(Tweet, Mention),
            Subscriptions = ets:lookup(TableName, subscribed),
            SubNames = [Sub || {_, Sub} <- Subscriptions],
            SubCheck = lists:member(PostUserName, SubNames),
            if
                PostUserName == UserName; SubCheck; Tag =/= nomatch ->
                    io:fwrite("~p - ~p:~n\t~p: ~p~n", [self(), PostUserName, Id, Tweet]);
                true ->
                    '_'
            end;
        help ->
            write_help(self())
    end,
    user_node(TableName, HostPid).


start_host() ->
    UserServer = spawn(?MODULE, user_auth_server, []),
    TweetServer = spawn(?MODULE, tweet_log_server, [0]),
    register(twitter_host,spawn(?MODULE, host_server, [UserServer, TweetServer])),
    twitter_host ! awake.


write_help(Pid) ->
    io:fwrite("
        Here is a list of commands you can use:~n
        \t~p ! {new_user, UserName, Password}.
        \t~p ! {login, UserName, Password}.
        \t~p ! log_off.
        \t~p ! {make_tweet, Tweet}.
        \t~p ! {retweet, QueryId}.
        \t~p ! {subscribe, SubscribeTo}.
        \t~p ! {search_tweets_by_tag, Tag}.
        \t~p ! search_tweets_by_mention.
        \t~p ! search_tweets_by_subscription.
        \t~p ! help.~n
    ",[Pid,Pid,Pid,Pid,Pid,Pid,Pid,Pid,Pid,Pid]).


start_user(TableName, HostPid) ->
    Pid = spawn(?MODULE, user_node, [TableName, HostPid]),
    Pid ! awake,
    Pid.