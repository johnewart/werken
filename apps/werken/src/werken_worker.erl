-module(werken_worker).
-compile([{parse_transform, lager_transform}]).
-include("records.hrl").

%% API
-export([can_do/1, cant_do/1, reset_abilities/0, pre_sleep/0, grab_job/0,
work_status/3, work_complete/2, work_fail/1, set_client_id/0, set_client_id/1,
can_do_timeout/2, all_yours/0, work_exception/2, work_data/2,
work_warning/2, grab_job_uniq/0, job_assign_packet_for_job_function/2, check_job_progress/2]).

can_do(FunctionName) ->
  WorkerFunction = #worker_function{pid = self(), function_name = FunctionName},
  can_do_common(WorkerFunction).

can_do_timeout(FunctionName, Timeout) ->
  WorkerFunction = #worker_function{pid = self(), function_name = FunctionName, timeout = Timeout},
  can_do_common(WorkerFunction).

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
  lookup_job_for_me("JOB_ASSIGN").

grab_job_uniq() ->
  lookup_job_for_me("JOB_ASSIGN_UNIQ").

work_status(JobHandle, Numerator, Denominator) ->
  JobStatus = #job_status{job_id = JobHandle, numerator = Numerator, denominator = Denominator},
  werken_storage_job:add_job_status(JobStatus),
  forward_packet_to_client("WORK_STATUS", [JobHandle, Numerator, Denominator]),
  ok.

work_complete(JobHandle, Data) ->
  forward_packet_to_client("WORK_COMPLETE", [JobHandle, Data]),
  werken_storage_job:delete_job(JobHandle),
  ok.

work_fail(JobHandle) ->
  forward_packet_to_client("WORK_FAIL", [JobHandle]),
  werken_storage_job:delete_job(JobHandle),
  ok.

set_client_id() ->
  Id = werken_utils:generate_worker_id(),
  set_client_id(Id).

set_client_id(ClientId) ->
  Worker = #worker{pid = self(), worker_id = ClientId},
  werken_storage_worker:add_worker(Worker),
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

job_assign_packet_for_job_function(PacketName, JobFunction) ->
  Job = werken_storage_job:get_job_for_job_function(JobFunction),
  werken_storage_job:mark_job_as_running(JobFunction),
  maybe_start_timer_for_job(JobFunction),
  job_assign_packet(PacketName, Job, JobFunction).

check_job_progress(JobFunction, _WorkerFunction) ->
  Job = werken_storage_job:get_job_for_job_function(JobFunction),
  case Job of
    error -> ok;
    _ -> work_fail(Job#job.job_id)
  end.

% private functions
can_do_common(WorkerFunction) ->
  WorkerStatus = #worker_status{pid = self(), status = awake},
  werken_storage_worker:add_worker(WorkerFunction),
  werken_storage_worker:add_worker(WorkerStatus),
  case werken_storage_worker:get_worker_id_for_pid(self()) of
    error -> set_client_id();
    _ -> ok
  end,
  ok.

lookup_job_for_me(PacketName) ->
  case werken_storage_job:get_job(self()) of
    [] ->
      {binary, ["NO_JOB"]};
    JobFunction ->
      job_assign_packet_for_job_function(PacketName, JobFunction)
  end.

maybe_start_timer_for_job(JobFunction) ->
  case werken_storage_worker:get_worker_function(self(), JobFunction) of
    {error, no_worker_function} -> ok;
    WorkerFunction ->
      case string:to_integer(WorkerFunction#worker_function.timeout) of
        {error, _} -> ok;
        {Timeout, _} ->
          Seconds = Timeout * 1000,
          timer:apply_after(Seconds, ?MODULE, check_job_progress, [JobFunction, WorkerFunction])
      end
  end.

job_assign_packet("JOB_ASSIGN", Job, JobFunction) ->
  {binary, ["JOB_ASSIGN", JobFunction#job_function.job_id, JobFunction#job_function.function_name, Job#job.data]};

job_assign_packet("JOB_ASSIGN_UNIQ", Job, JobFunction) ->
  {binary, ["JOB_ASSIGN_UNIQ", JobFunction#job_function.job_id, JobFunction#job_function.function_name, Job#job.unique_id, Job#job.data]}.

notify_clients_if_necessary(Job = #job{bg = false}, Packet = ["WORK_EXCEPTION"|_Args]) ->
  Pids = werken_storage_job:get_client_pids_for_job(Job),
  process_client_notifications(Pids, Packet, true);

notify_clients_if_necessary(Job = #job{bg = false}, Packet) ->
  Pids = werken_storage_job:get_client_pids_for_job(Job),
  process_client_notifications(Pids, Packet, false);

notify_clients_if_necessary(_Job, _Packet) ->
  ok.

forward_packet_to_client(Name, Args) ->
  JobHandle = hd(Args),
  Job = werken_storage_job:get_job(JobHandle),
  notify_clients_if_necessary(Job, [Name|Args]).

process_client_notifications([], _, _) ->
  ok;

process_client_notifications([Pid|Rest], Packet, false) ->
  send_packet(Pid, Packet),
  process_client_notifications(Rest, Packet, false);

process_client_notifications([Pid|Rest], Packet, true) ->
  Client = werken_storage_client:get_client(Pid),
  case Client#client.exceptions of
    true -> % this gets set with an OPTION_REQ request from the client
      send_packet(Pid, Packet);
    _ -> ok
  end,
  process_client_notifications(Rest, Packet, true).

send_packet(Pid, Packet) ->
  Func = fun() -> {binary, Packet} end,
  gen_server:call(Pid, {process_packet, Func}).
