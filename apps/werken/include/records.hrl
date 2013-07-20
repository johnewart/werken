%%% record definitions

-record(worker_function, {pid, function_name, timeout}).
-record(worker_status, {pid, status}).
-record(worker, {pid, worker_id, direct_assignment}).
-record(client, {pid, function_name, data, client_id, result, exceptions}).
-record(job, {job_id, data, submitted_at, run_at, unique_id, client_pid, bg}).
-record(job_function, {function_name, job_id, priority, available}).
-record(job_status, {job_id, numerator, denominator}).

%% job
%% - we track the client_pid so when the job is finished, if it's a foreground job, we can notify the client of the result.
%% - the unique_id is submitted in the SUBMIT_JOB packet by the client
%% - the job_id is automatically assigned by the server
