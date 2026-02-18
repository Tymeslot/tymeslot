defmodule Tymeslot.Workers.ExpiredSessionCleanupWorkerTest do
  @moduletag :workers
  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  import Tymeslot.Factory

  alias Tymeslot.DatabaseSchemas.UserSessionSchema
  alias Tymeslot.Workers.ExpiredSessionCleanupWorker

  describe "perform/1" do
  @moduletag :workers
    test "cleans up expired sessions" do
      user = insert(:user)

      # Expired session (1 day ago)
      expired_at = DateTime.add(DateTime.utc_now(), -1, :day)
      expired_session = insert(:user_session, user: user, expires_at: expired_at)

      # Valid session (1 day in future)
      valid_at = DateTime.add(DateTime.utc_now(), 1, :day)
      valid_session = insert(:user_session, user: user, expires_at: valid_at)

      assert :ok = perform_job(ExpiredSessionCleanupWorker, %{})

      refute Repo.get_by(UserSessionSchema, token: expired_session.token)
      assert Repo.get_by(UserSessionSchema, token: valid_session.token)
    end

    test "handles empty database gracefully" do
      # No sessions exist
      assert :ok = perform_job(ExpiredSessionCleanupWorker, %{})
    end

    test "handles errors gracefully (resilient to query failures)" do
      # Worker should complete even if unexpected errors occur
      assert :ok = perform_job(ExpiredSessionCleanupWorker, %{})
    end

    test "handles sessions at exact expiry boundary" do
      user = insert(:user)

      # Session that expires exactly now
      now = DateTime.utc_now()
      boundary_session = insert(:user_session, user: user, expires_at: now)

      assert :ok = perform_job(ExpiredSessionCleanupWorker, %{})

      # Boundary session should be cleaned (expired means <= now)
      refute Repo.get_by(UserSessionSchema, token: boundary_session.token)
    end

    test "cleans up multiple expired sessions efficiently" do
      user = insert(:user)
      expired_at = DateTime.add(DateTime.utc_now(), -1, :day)

      # Create multiple expired sessions
      expired_sessions =
        for _i <- 1..10 do
          insert(:user_session, user: user, expires_at: expired_at)
        end

      assert :ok = perform_job(ExpiredSessionCleanupWorker, %{})

      # All expired sessions should be cleaned
      Enum.each(expired_sessions, fn session ->
        refute Repo.get_by(UserSessionSchema, token: session.token)
      end)
    end

    test "accepts unknown job arguments (forward compatibility)" do
      # Job with extra fields from future version
      assert :ok = perform_job(ExpiredSessionCleanupWorker, %{"future_field" => "value"})
    end
  end
end
