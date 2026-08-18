defmodule Tymeslot.Workers.ExpiredSessionCleanupWorkerTest do
  use Tymeslot.DataCase, async: true

  @moduletag :workers

  use Oban.Testing, repo: Tymeslot.Repo

  import Tymeslot.Factory

  alias Tymeslot.Auth.UserSessionSchema
  alias Tymeslot.Workers.ExpiredSessionCleanupWorker

  describe "perform/1" do
    test "cleans up expired sessions" do
      user = insert(:user)

      # Expired session (1 day ago)
      expired_at = DateTime.add(DateTime.utc_now(), -1, :day)
      expired_session = insert(:user_session, user: user, expires_at: expired_at)

      # Valid session (1 day in future)
      valid_at = DateTime.add(DateTime.utc_now(), 1, :day)
      valid_session = insert(:user_session, user: user, expires_at: valid_at)

      assert :ok = perform_job(ExpiredSessionCleanupWorker, %{})

      refute Repo.get_by(UserSessionSchema, token_hash: expired_session.token_hash)
      assert Repo.get_by(UserSessionSchema, token_hash: valid_session.token_hash)
    end

    test "handles empty database gracefully" do
      # No sessions exist
      assert :ok = perform_job(ExpiredSessionCleanupWorker, %{})
    end

    test "handles sessions at exact expiry boundary" do
      user = insert(:user)

      # Session that expires exactly now
      now = DateTime.utc_now()
      boundary_session = insert(:user_session, user: user, expires_at: now)

      assert :ok = perform_job(ExpiredSessionCleanupWorker, %{})

      # Boundary session should be cleaned (expired means <= now)
      refute Repo.get_by(UserSessionSchema, token_hash: boundary_session.token_hash)
    end

    test "accepts unknown job arguments (forward compatibility)" do
      # Job with extra fields from future version
      assert :ok = perform_job(ExpiredSessionCleanupWorker, %{"future_field" => "value"})
    end
  end
end
