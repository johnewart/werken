-module(werken_storage_job).
-compile([{parse_transform, lager_transform}]).
-export([add_job/1, get_job/1, delete_job/1, all_jobs/0, get_job_function_for_job/1, get_job_for_job_function/1, add_job_status/1, get_job_status/1, mark_job_as_running/1, is_job_running/1, job_exists/1, job_exists/2, add_job_client/1, get_client_pids_for_job/1, mark_job_as_available_for_worker_id/1]).

-include("records.hrl").
-include_lib("stdlib/include/ms_transform.hrl").

all_jobs() ->
  ets:tab2list(job_functions).

job_exists(Job) ->
  MatchSpec = ets:fun2ms(fun(J = #job{unique_id=UI}) when UI == Job#job.unique_id -> J end),
  case ets:select(jobs, MatchSpec) of
    [] -> false;
    [MatchingJob] -> MatchingJob
  end.

job_exists(JobId, ClientPid) ->
  case ets:match_object(job_clients, {JobId, ClientPid}) of
    [] -> false;
    [JobClient] -> JobClient
  end.

add_job_client(JobClient) ->
  ets:insert(job_clients, JobClient).

get_client_pids_for_job(Job) ->
  JobClients = ets:lookup(job_clients, Job#job.job_id),
  lists:map(fun(JC) -> JC#job_client.client_pid end, JobClients).

add_job(Job=#job{}) ->
  case ets:insert_new(jobs, Job) of
    false -> duplicate_job;
    _ -> ok
  end;

add_job(JobFunction=#job_function{}) ->
  MatchSpec = ets:fun2ms(fun(J = #job_function{job_id=JI, function_name=FN}) when JI == JobFunction#job_function.job_id andalso FN == JobFunction#job_function.function_name -> J end),
  case ets:select(job_functions, MatchSpec) of
    [] ->
      ok;
    [JF] ->
      ets:delete_object(job_functions, JF)
  end,
  ets:insert(job_functions, JobFunction),
  ok.

add_job_status(JobStatus=#job_status{}) ->
  ets:insert(job_statuses, JobStatus),
  ok.

get_job_status(JobHandle) ->
  case ets:lookup(job_statuses, JobHandle) of
    [] -> [];
    [JobStatus] -> JobStatus
  end.

get_job_function_for_job(Job) ->
  MatchSpec = ets:fun2ms(fun(J = #job_function{job_id=JI}) when JI == Job#job.job_id -> J end),
  case ets:select(job_functions, MatchSpec) of
    [] -> error;
    [JobFunction] -> JobFunction
  end.

get_job_for_job_function(JobFunction) ->
  MatchSpec = ets:fun2ms(fun(J = #job{job_id=JI}) when JI == JobFunction#job_function.job_id -> J end),
  case ets:select(jobs, MatchSpec) of
    [] -> error;
    [Job] -> Job
  end.

get_job(Pid) when is_pid(Pid) ->
  case ets:lookup(worker_functions, Pid) of
    [] -> [];
    Workers ->
      FunctionNames = lists:map(fun(W) -> W#worker_function.function_name end, Workers),
      get_job(FunctionNames, [high, normal, low])
  end;

get_job(JobHandle) when is_binary(JobHandle) ->
  NewJobHandle = binary_to_list(JobHandle),
  get_job(NewJobHandle);

get_job(JobHandle) ->
  case ets:lookup(jobs, JobHandle) of
    [] -> [];
    [Job] -> Job
  end.

get_job(_, []) ->
  [];

get_job(FunctionNames, [Priority|OtherPriorities]) ->
  case get_job(FunctionNames, Priority) of
    [] ->
      get_job(FunctionNames, OtherPriorities);
    Job ->
      Job
  end;

get_job([], Priority) when is_atom(Priority) ->
  [];

get_job([FunctionName|OtherFunctionNames], Priority) when is_atom(Priority) ->
  MatchSpec = ets:fun2ms(fun(J = #job_function{function_name=F, priority=P, available=true}) when F == FunctionName andalso P == Priority -> J end),
  case ets:select(job_functions, MatchSpec) of
    [] ->
      get_job(OtherFunctionNames, Priority);
    JobFunctions ->
      JobFunction = hd(JobFunctions),
      mark_job_as_running(JobFunction)
  end.

delete_job(JobHandle) ->
  MS1 = ets:fun2ms(fun(#job_function{job_id=J}) when J == JobHandle -> true end),
  MS2 = ets:fun2ms(fun(#job_worker{job_id=J}) when J == JobHandle -> true end),
  ets:select_delete(job_functions, MS1),
  ets:select_delete(job_workers, MS2),
  ets:delete(jobs, JobHandle),
  ok.

mark_job_as_running(JobFunction) ->
  NewJobFunction = JobFunction#job_function{available = false},
  add_job(NewJobFunction),
  WorkerId = werken_storage_worker:get_worker_id_for_pid(self()),
  case WorkerId of
    error -> error;
    _ ->
      JobWorker = #job_worker{worker_id = WorkerId, job_id = JobFunction#job_function.job_id},
      ets:insert(job_workers, JobWorker)
  end,
  NewJobFunction.

mark_job_as_available_for_worker_id(WorkerId) ->
  JobWorker = ets:lookup(job_workers, WorkerId),
  case JobWorker of
    [] -> ok;
    [JW] ->
      Job = get_job(JW#job_worker.job_id),
      JobFunction = get_job_function_for_job(Job),
      NewJobFunction = JobFunction#job_function{available = true},
      add_job(NewJobFunction),
      ets:delete(job_workers, WorkerId)
  end,
  ok.

is_job_running({job_handle, JobHandle}) ->
  Job = get_job(JobHandle),
  is_job_running({job, Job});

is_job_running({function_name, FunctionName}) ->
  case ets:lookup(job_functions, FunctionName) of
    [] -> false;
    JobFunctions -> lists:any(fun(JF) -> is_job_running({job_function, JF}) end, JobFunctions)
  end;

is_job_running({job, Job}) ->
  JobFunction = get_job_function_for_job(Job),
  is_job_running({job_function, JobFunction});

is_job_running({job_function, JobFunction}) ->
  case JobFunction#job_function.available of
    false -> true;
    _ -> false
  end.
