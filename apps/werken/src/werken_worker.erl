-module(werken_worker).
-include("records.hrl").

%% API
-export([can_do/1, cant_do/1, reset_abilities/0, pre_sleep/0, grab_job/0,
work_status/3, work_complete/2, work_fail/1, set_client_id/0, set_client_id/1,
can_do_timeout/2, all_yours/0, work_exception/2, work_data/2,
work_warning/2, grab_job_uniq/0]).

can_do(FunctionName) ->
  WorkerFunction = #worker_function{pid = self(), function_name = FunctionName},
  WorkerStatus = #worker_status{pid = self(), status = awake},
  werken_storage_worker:add_worker(WorkerFunction),
  werken_storage_worker:add_worker(WorkerStatus),
  io:format("HI THERE~n"),
  case werken_storage_worker:get_worker_id_for_pid(self()) of
    [] -> set_client_id();
    _ -> ok
  end,
  ok.

cant_do(FunctionName) ->
  werken_storage_worker:remove_function_from_worker(FunctionName, self()),
  ok.

reset_abilities() ->
  werken_storage_worker:remove_function_from_worker(all, self()),
  ok.

pre_sleep() ->
  WorkerStatus = #worker_status{pid = self(), status = asleep},
  werken_storage_worker:add_worker(WorkerStatus),
  ok.

grab_job() ->
  case gen_server:call(werken_coordinator, {get_job, self()}) of
    {ok, []} ->
      {binary, ["NO_JOB"]};
    {ok, Job} ->
      {binary, ["JOB_ASSIGN", Job#job.job_id, Job#job.function_name, Job#job.data]}
  end.

work_status(JobHandle, Numerator, Denominator) ->
  forward_packet_to_client("WORK_STATUS", [JobHandle, Numerator, Denominator]),
  ok.

work_complete(JobHandle, Data) ->
  io:format("inside werken_worker, work_complete function. JobHandle = ~p, Data = ~p~n", [JobHandle, Data]),
  forward_packet_to_client("WORK_COMPLETE", [JobHandle, Data]),
  gen_server:call(werken_coordinator, {delete_job, JobHandle}),
  ok.

work_fail(JobHandle) ->
  forward_packet_to_client("WORK_FAIL", [JobHandle]),
  ok.

set_client_id() ->
  Id = werken_utils:generate_worker_id(),
  io:format("Id ~p~n", [Id]),
  set_client_id(Id).

set_client_id(ClientId) ->
  Worker = #worker{pid = self(), worker_id = ClientId},
  io:format("Worker ~p~n", [Worker]),
  werken_storage_worker:add_worker(Worker),
  ok.

can_do_timeout(_FunctionName, _Timeout) ->
  ok.

all_yours() ->
  ok.

work_exception(JobHandle, Data) ->
  forward_packet_to_client("WORK_EXCEPTION", [JobHandle, Data]),
  ok.

work_data(JobHandle, Data) ->
  forward_packet_to_client("WORK_DATA", [JobHandle, Data]),
  ok.

work_warning(JobHandle, Data) ->
  forward_packet_to_client("WORK_WARNING", [JobHandle, Data]),
  ok.

grab_job_uniq() ->
  ok.

% private functions
notify_clients_if_necessary(Job, Packet) ->
  io:format("notify_clients_if_necessary. Job = ~p, Packet = ~p~n", [Job, Packet]),
  case Job#job.bg of
    false ->
      Pid = Job#job.client_pid,
      Func = fun() -> {binary, Packet} end,
      gen_server:cast(Pid, {process_packet, Func});
      % gen_server:cast(werken_coordinator, {respond_to_client, Job#job.client_pid, Packet});
    _ -> ok
  end.

forward_packet_to_client(Name, Args) ->
  io:format("forward_packet_to_client. Name = ~p, Args = ~p~n", [Name, Args]),
  JobHandle = hd(Args),
  Job = werken_storage_job:get_job(JobHandle),
  io:format("forward_packet_to_client. JobHandle = ~p, Job = ~p~n", [JobHandle, Job]),
  notify_clients_if_necessary(Job, [Name|Args]).
