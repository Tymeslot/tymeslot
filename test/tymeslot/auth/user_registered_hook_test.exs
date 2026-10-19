defmodule Tymeslot.Auth.UserRegisteredHookTest do
  @moduledoc """
  The durable registration hook. Whatever a hook records from a sign-up (the
  terms acceptance, for one) runs from a retried Oban job enqueued when the
  account is created, rather than from a PubSub message that a restarting
  subscriber can miss.
  """

  # async: false: the hook is global Application env.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :auth
  @moduletag :workers

  import Tymeslot.AdminAlertsCaptureHelpers

  alias Tymeslot.Auth
  alias Tymeslot.Auth.OAuth.TransactionalUserCreation
  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Repo
  alias Tymeslot.Workers.UserRegisteredHookWorker
  alias TymeslotWeb.Helpers.ClientIP

  defmodule RecordingHook do
    @spec on_user_registered(pos_integer(), map()) :: :ok
    def on_user_registered(user_id, metadata) do
      send(
        Application.fetch_env!(:tymeslot, :registration_hook_test_pid),
        {:hook, user_id, metadata}
      )

      :ok
    end
  end

  defmodule FailingHook do
    @spec on_user_registered(pos_integer(), map()) :: {:error, term()}
    def on_user_registered(_user_id, _metadata), do: {:error, :database_unavailable}
  end

  defmodule RaisingHook do
    @spec on_user_registered(pos_integer(), map()) :: no_return()
    def on_user_registered(_user_id, _metadata),
      do: raise(DBConnection.ConnectionError, "connection not available")
  end

  defmodule ExitingHook do
    @spec on_user_registered(pos_integer(), map()) :: no_return()
    def on_user_registered(_user_id, _metadata),
      do: exit({:timeout, {GenServer, :call, [:registration_store, :record, 5000]}})
  end

  setup do
    original = Application.get_env(:tymeslot, :user_registered_hook)
    Application.put_env(:tymeslot, :registration_hook_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:tymeslot, :registration_hook_test_pid)

      if original,
        do: Application.put_env(:tymeslot, :user_registered_hook, original),
        else: Application.delete_env(:tymeslot, :user_registered_hook)
    end)

    :ok
  end

  defp register(email \\ "hooked#{System.unique_integer([:positive])}@example.com") do
    params = %{
      "email" => email,
      "password" => "ValidPassword123!",
      "password_confirmation" => "ValidPassword123!",
      "name" => "Hooked User",
      "terms_accepted" => "true"
    }

    opts = Keyword.put(ClientIP.request_opts(%Plug.Conn{}), :user_agent, "HookTest/1.0")
    {:ok, user, _session} = Auth.register_user(params, opts)
    user
  end

  test "a sign-up enqueues the hook, which receives the sign-up's metadata" do
    Application.put_env(:tymeslot, :user_registered_hook, RecordingHook)

    user = register()

    assert [job] = all_enqueued(worker: UserRegisteredHookWorker)
    assert job.args["user_id"] == user.id

    assert :ok = perform_job(UserRegisteredHookWorker, job.args)

    user_id = user.id
    assert_received {:hook, ^user_id, metadata}
    assert metadata["terms_accepted"] == true
    assert metadata["user_agent"] == "HookTest/1.0"
    assert metadata["source"] == "signup"
  end

  test "a hook failure is returned so Oban retries the job" do
    Application.put_env(:tymeslot, :user_registered_hook, FailingHook)

    assert {:error, :database_unavailable} =
             perform_job(UserRegisteredHookWorker, %{"user_id" => 1, "metadata" => %{}})
  end

  test "without a hook, a sign-up enqueues nothing" do
    Application.delete_env(:tymeslot, :user_registered_hook)

    register()

    assert all_enqueued(worker: UserRegisteredHookWorker) == []
  end

  # The hook's job commits with the account. Enqueued after the commit, a
  # failed or raising enqueue left an account whose terms acceptance would
  # never be recorded (and, raising, one that never got its profile or its
  # verification email).
  describe "the hook job commits with the account" do
    setup do
      Application.put_env(:tymeslot, :user_registered_hook, RecordingHook)

      # Make any insert of the hook's job fail at the database. The DDL is
      # rolled back with the test's sandbox transaction.
      Repo.query!("""
      ALTER TABLE oban_jobs ADD CONSTRAINT test_refuse_registration_hook
      CHECK (worker <> 'Tymeslot.Workers.UserRegisteredHookWorker')
      """)

      :ok
    end

    test "a sign-up whose hook job cannot be enqueued creates no account" do
      email = "unhooked#{System.unique_integer([:positive])}@example.com"

      assert_raise Ecto.ConstraintError, fn -> register(email) end

      refute Repo.get_by(UserSchema, email: email)
    end

    test "an OAuth sign-up whose hook job cannot be enqueued creates no account" do
      auth_params = %{
        "email" => "unhooked-oauth@example.com",
        "github_user_id" => "hook-#{System.unique_integer([:positive])}",
        "provider" => "github",
        "is_verified" => true
      }

      assert_raise Ecto.ConstraintError, fn ->
        TransactionalUserCreation.find_or_create_oauth_user(:github, auth_params, %{}, %{})
      end

      refute Repo.get_by(UserSchema, email: "unhooked-oauth@example.com")
    end
  end

  describe "a hook that keeps failing" do
    setup :capture_admin_alerts

    test "alerts once Oban stops retrying" do
      Application.put_env(:tymeslot, :user_registered_hook, FailingHook)

      assert {:error, :database_unavailable} =
               perform_job(UserRegisteredHookWorker, %{"user_id" => 42, "metadata" => %{}},
                 attempt: 10
               )

      assert_receive {:send_alert, :user_registered_hook_failed, %{user_id: 42}}
    end

    test "does not alert while retries remain" do
      Application.put_env(:tymeslot, :user_registered_hook, FailingHook)

      assert {:error, :database_unavailable} =
               perform_job(UserRegisteredHookWorker, %{"user_id" => 42, "metadata" => %{}},
                 attempt: 9
               )

      refute_received {:send_alert, :user_registered_hook_failed, _payload}
    end

    test "alerts when the hook raises on the final attempt, and still raises" do
      Application.put_env(:tymeslot, :user_registered_hook, RaisingHook)

      assert_raise DBConnection.ConnectionError, fn ->
        perform_job(UserRegisteredHookWorker, %{"user_id" => 42, "metadata" => %{}}, attempt: 10)
      end

      assert_receive {:send_alert, :user_registered_hook_failed, %{user_id: 42}}
    end

    # Oban reports an exit from `perform/1` as a crash, so the job still
    # fails and is retried; the alert is what the exit used to skip.
    test "alerts when the hook exits on the final attempt, and still fails the job" do
      Application.put_env(:tymeslot, :user_registered_hook, ExitingHook)

      assert_raise Oban.CrashError, ~r/time out/, fn ->
        perform_job(UserRegisteredHookWorker, %{"user_id" => 42, "metadata" => %{}}, attempt: 10)
      end

      assert_receive {:send_alert, :user_registered_hook_failed, %{user_id: 42}}
    end

    test "does not alert on a raise while retries remain" do
      Application.put_env(:tymeslot, :user_registered_hook, RaisingHook)

      assert_raise DBConnection.ConnectionError, fn ->
        perform_job(UserRegisteredHookWorker, %{"user_id" => 42, "metadata" => %{}}, attempt: 9)
      end

      refute_received {:send_alert, :user_registered_hook_failed, _payload}
    end
  end
end
