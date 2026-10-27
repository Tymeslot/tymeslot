defmodule Tymeslot.Test.JobRefusal do
  @moduledoc """
  Makes inserting a job for one worker fail as a database error would, for
  the rest of the test. The trigger is created in the test's sandbox
  transaction, so it is rolled back with it and no other connection ever
  sees it; a LiveView or task sharing the test's connection does.

  For `async: false` modules only, and once per test: the trigger and its
  function have fixed names, and creating the trigger holds a
  `SHARE ROW EXCLUSIVE` lock on `oban_jobs` until the test ends, which
  makes any other connection inserting a job wait for it.
  """

  alias Tymeslot.Repo

  @doc "Refuses every insert of a job for `worker` with a database error."
  @spec refuse_jobs(module()) :: :ok
  def refuse_jobs(worker) when is_atom(worker) do
    name = inspect(worker)

    Repo.query!("""
    CREATE FUNCTION refuse_test_jobs() RETURNS trigger AS $$
    BEGIN
      IF NEW.worker = '#{name}' THEN
        RAISE EXCEPTION 'jobs for #{name} refused by the test';
      END IF;
      RETURN NEW;
    END
    $$ LANGUAGE plpgsql
    """)

    Repo.query!("""
    CREATE TRIGGER refuse_test_jobs BEFORE INSERT ON oban_jobs
    FOR EACH ROW EXECUTE FUNCTION refuse_test_jobs()
    """)

    :ok
  end
end
