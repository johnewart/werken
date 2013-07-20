-module(werken_client).
-compile([{parse_transform, lager_transform}]).
-include("records.hrl").

%% API
-export([submit_job/3, get_status/1, submit_job_bg/3, submit_job_high/3,
submit_job_high_bg/3, submit_job_low/3, submit_job_low_bg/3, submit_job_sched/8,
submit_job_epoch/4, option_req/1]).

-export([generate_records_and_insert_job/7]).

%% API
submit_job(FunctionName, UniqueId, Data) ->
  submit_job(FunctionName, UniqueId, Data, normal, false).

submit_job_high(FunctionName, UniqueId, Data) ->
  submit_job(FunctionName, UniqueId, Data, high, false).

submit_job_low(FunctionName, UniqueId, Data) ->
  submit_job(FunctionName, UniqueId, Data, low, false).

submit_job_bg(FunctionName, UniqueId, Data) ->
  submit_job(FunctionName, UniqueId, Data, normal, true).

submit_job_high_bg(FunctionName, UniqueId, Data) ->
  submit_job(FunctionName, UniqueId, Data, high, true).

submit_job_low_bg(FunctionName, UniqueId, Data) ->
  submit_job(FunctionName, UniqueId, Data, low, true).

submit_job_sched(FunctionName, UniqueId, Minute, Hour, DayOfMonth, Month, DayOfWeek, Data) ->
  Time = werken_utils:date_to_milliseconds(Minute, Hour, DayOfMonth, Month, DayOfWeek),
  submit_job(FunctionName, UniqueId, Data, normal, true, Time).

submit_job_epoch(FunctionName, UniqueId, Epoch, Data) ->
  Time = werken_utils:epoch_to_milliseconds(Epoch),
  submit_job(FunctionName, UniqueId, Data, normal, true, Time).

get_status(JobHandle) ->
  case werken_storage_job:get_job_status(JobHandle) of
    [] ->
      KnownStatus = 0,
      RunningStatus = 0,
      Numerator = 0,
      Denominator = 0;
    #job_status{numerator=Numerator, denominator=Denominator} ->
      KnownStatus = 1,
      RunningStatus = case werken_storage_job:is_job_running({job_handle, JobHandle}) of
                        true -> 1;
                        _ -> 0
                      end
  end,
  {binary, ["STATUS_RES", JobHandle, KnownStatus, RunningStatus, Numerator, Denominator]}.

option_req(Option) when is_list(Option) ->
  case Option of
    "exceptions" ->
      set_exceptions_for_client(self()),
      {binary, ["OPTION_RES", "exceptions"]};
    _ ->
      InterpolatedString = io_lib:format("~p is not a valid option. Valid options are: exceptions", [Option]),
      {binary, ["ERROR", "ENOOPTION", InterpolatedString]}
  end.

% private
set_exceptions_for_client(Pid) when is_pid(Pid) ->
  case werken_client_storage:get_client(Pid) of
    [] -> {error, no_client};
    [Client] -> set_exceptions_for_client(Client)
  end;

set_exceptions_for_client(Client) ->
  NewClient = Client#client{exceptions = true},
  werken_client_storage:add_client(NewClient),
  ok.

submit_job(FunctionName, UniqueId, Data, Priority, Bg) ->
  F = fun(JobId, ClientPid) -> apply(?MODULE, generate_records_and_insert_job, [FunctionName, UniqueId, Data, Priority, Bg, JobId, ClientPid]) end,
  submit_job(F).

submit_job(FunctionName, UniqueId, Data, Priority, Bg, Time) ->
  F = fun(JobId, ClientPid) -> timer:apply_after(Time, ?MODULE, generate_records_and_insert_job, [FunctionName, UniqueId, Data, Priority, Bg, JobId, ClientPid]) end,
  submit_job(F).

submit_job(Func) when is_function(Func) ->
  JobId = werken_utils:generate_job_id(),
  ClientPid = self(),
  spawn(fun() -> Func(JobId, ClientPid) end),
  job_created_packet(JobId).

job_created_packet(JobId) ->
  {binary, ["JOB_CREATED", JobId]}.

generate_records_and_insert_job(FunctionName, UniqueId, Data, Priority, Bg, JobId, ClientPid) ->
  Job = #job{job_id = JobId,
             data = Data,
             submitted_at = erlang:now(),
             unique_id = UniqueId,
             client_pid = ClientPid,
             bg = Bg},
  JobFunction = #job_function{job_id = JobId,
                              priority = Priority,
                              available = true,
                              function_name = FunctionName},
  Client = #client{pid = ClientPid,
                   function_name = FunctionName,
                   data = Data},
  werken_storage_client:add_client(Client),
  werken_storage_job:add_job(Job),
  werken_storage_job:add_job(JobFunction),
  spawn(fun() -> assign_or_wakeup_workers_for_job(JobFunction) end),
  ok.

assign_or_wakeup_workers_for_job(JobFunction) ->
  lager:debug("JobFunction = ~p", [JobFunction]),
  Pids = werken_storage_worker:get_worker_pids_for_function_name(JobFunction#job_function.function_name),
  lager:debug("Pids = ~p", [Pids]),
  case check_eligibility_for_direct_assignment(Pids) of
    Pid when is_pid(Pid) ->
      Packet = werken_worker:job_assign_packet_for_job_function("JOB_ASSIGN", JobFunction),
      Func = fun() -> {binary, Packet} end,
      gen_server:call(Pid, {process_packet, Func});
    _ ->
      wakeup_workers(Pids)
  end.

check_eligibility_for_direct_assignment([]) ->
  lager:debug("no more to check for eligibility. gonna just wake em up"),
  not_found;

check_eligibility_for_direct_assignment([Pid|Rest]) ->
  lager:debug("Pid = ~p, Rest = ~p", [Pid, Rest]),
  Record = werken_storage_worker:get_worker(Pid),
  lager:debug("Record = ~p", [Record]),
  case Record#worker.direct_assignment of
    true ->
      Pid;
    _ ->
      check_eligibility_for_direct_assignment(Rest)
  end.

wakeup_workers([]) ->
  lager:debug("all out of workers. bye bye"),
  ok;

wakeup_workers([Pid|Rest]) ->
  lager:debug("Pid = ~p, Rest = ~p", [Pid, Rest]),
  Record = werken_storage_worker:get_worker_status(Pid),
  lager:debug("Record = ~p", [Record]),
  case Record#worker_status.status of
    asleep ->
      gen_server:call(Pid, wakeup_worker),
      werken_storage_worker:update_worker_status(Pid, awake);
    _ ->
      ok
  end,
  wakeup_workers(Rest).
