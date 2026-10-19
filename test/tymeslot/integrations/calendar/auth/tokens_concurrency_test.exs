defmodule Tymeslot.Integrations.Calendar.TokensConcurrencyTest do
  @moduledoc """
  Concurrency tests for OAuth token refresh operations.

  A refresh is held open by a refresh function that waits for `:proceed`,
  and a contender is known to be queued on the lock once the lock reports
  refusing it (`watch_contention/1`), so no test depends on timing.
  """

  # async: false to avoid ETS table issues if not careful
  use Tymeslot.DataCase, async: false
  @moduletag :integrations

  import Mox
  import Tymeslot.Factory
  alias Ecto.Changeset
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.TokenRefreshJob
  alias Tymeslot.Integrations.Calendar.Tokens
  alias Tymeslot.Integrations.Shared.Lock
  alias Tymeslot.Repo

  setup :set_mox_global
  setup :verify_on_exit!

  defp expired_google_integration do
    insert(:calendar_integration,
      user: insert(:user),
      provider: "google",
      access_token: "old",
      token_expires_at: DateTime.add(DateTime.utc_now(), -3600)
    )
  end

  defp refreshed(access),
    do: {:ok, {access, "new-refresh", DateTime.add(DateTime.utc_now(), 3600)}}

  describe "refresh_oauth_token concurrency" do
    # The second caller waits for the lock rather than giving up, then finds
    # the first caller's tokens on the row and does not refresh again.
    test "a second refresh waits for the first and reuses its tokens" do
      integration = expired_google_integration()
      test_pid = self()

      expect(GoogleCalendarAPIMock, :refresh_token, 1, fn _int ->
        send(test_pid, {:refresh_started, self()})
        receive do: (:proceed -> :ok)
        refreshed("new_access")
      end)

      first = Task.async(fn -> Tokens.refresh_oauth_token(integration) end)
      assert_receive {:refresh_started, refresher}, 2_000

      watch_contention(Tokens.refresh_lock_key(integration.id))
      second = Task.async(fn -> Tokens.refresh_oauth_token(integration) end)
      assert_receive :contended, 2_000
      send(refresher, :proceed)

      assert {:ok, %{access_token: "new_access"}} = Task.await(first)
      assert {:ok, %{access_token: "new_access"}} = Task.await(second)
    end

    test "takes over a lock whose holder has died" do
      integration = expired_google_integration()

      {dead_pid, ref} = spawn_monitor(fn -> :ok end)
      assert_receive {:DOWN, ^ref, :process, ^dead_pid, _reason}

      old_now = System.monotonic_time(:millisecond) - 3_600_000
      Lock.put_lock(Tokens.refresh_lock_key(integration.id), old_now, dead_pid)

      expect(GoogleCalendarAPIMock, :refresh_token, 1, fn _int -> refreshed("recovered") end)

      assert {:ok, %{access_token: "recovered"}} = Tokens.refresh_oauth_token(integration)
    end

    test "double-checks expiry after acquiring lock to avoid redundant refresh" do
      integration = expired_google_integration()

      expect(GoogleCalendarAPIMock, :refresh_token, 1, fn _int -> refreshed("new") end)

      assert {:ok, _updated} = Tokens.refresh_oauth_token(integration)

      # The same stale copy again: the re-read under the lock finds the new
      # token, and the single expectation fails the test on a second request.
      assert {:ok, %{access_token: "new"}} = Tokens.refresh_oauth_token(integration)
    end
  end

  # The hourly refresh job and a provider API call that finds its token
  # expired must not refresh the same integration at once: each would POST
  # the same refresh token, and with a provider that rotates refresh tokens
  # the later write could persist the older one.
  describe "the refresh job and the API-call refresh" do
    setup do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          access_token: "old",
          token_expires_at: DateTime.add(DateTime.utc_now(), -3600)
        )

      {:ok, integration: integration}
    end

    # The required guarantee: the scheduled job and an API call that both
    # find one expired token issue exactly one token request between them.
    test "issue exactly one token request between them", %{integration: integration} do
      test_pid = self()

      api_refresh = fn _integration ->
        send(test_pid, {:token_request, :api, self()})
        receive do: (:proceed -> :ok)
        refreshed("api-access")
      end

      stub(GoogleCalendarAPIMock, :refresh_token, fn _integration ->
        send(test_pid, {:token_request, :job, self()})
        refreshed("job-access")
      end)

      api_call =
        Task.async(fn -> Tokens.with_access_token(integration, api_refresh, &{:ok, &1}) end)

      assert_receive {:token_request, :api, api_pid}, 2_000

      watch_contention(Tokens.refresh_lock_key(integration.id))

      job =
        Task.async(fn ->
          TokenRefreshJob.perform(%Oban.Job{args: %{"integration_id" => integration.id}})
        end)

      # The job has read the expired row and is queued on the lock the API
      # refresh holds.
      assert_receive :contended, 2_000
      send(api_pid, :proceed)

      assert {:ok, "api-access"} = Task.await(api_call, 5_000)
      assert :ok = Task.await(job, 5_000)
      refute_received {:token_request, :job, _pid}

      stored =
        CalendarIntegrationSchema.decrypt_oauth_tokens(
          Repo.get!(CalendarIntegrationSchema, integration.id)
        )

      assert stored.access_token == "api-access"
    end

    # Deleted after the job read it but before the refresh lock was free: the
    # job must neither retry nor write a failure to a row that is gone.
    test "a job whose integration is deleted while it waits for the lock discards",
         %{integration: integration} do
      test_pid = self()
      key = Tokens.refresh_lock_key(integration.id)

      holder =
        spawn(fn ->
          Lock.with_lock(key, fn ->
            send(test_pid, :lock_held)
            receive do: (:release -> :ok)
          end)
        end)

      assert_receive :lock_held
      watch_contention(key)

      job =
        Task.async(fn ->
          TokenRefreshJob.perform(%Oban.Job{args: %{"integration_id" => integration.id}})
        end)

      assert_receive :contended, 2_000
      Repo.delete!(integration)
      send(holder, :release)

      assert {:discard, "Integration not found"} = Task.await(job, 5_000)
    end

    test "an API-call refresh writes its tokens before releasing the lock",
         %{integration: integration} do
      test_pid = self()
      handler_id = {__MODULE__, :persist_under_lock}
      key = Tokens.refresh_lock_key(integration.id)

      :telemetry.attach(
        handler_id,
        [:tymeslot, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if String.starts_with?(metadata.query, ~s(UPDATE "calendar_integrations")) and
               integration.id in metadata.params do
            # Any release this process cast before the write is handled
            # before this call returns, so the table shows the lock as the
            # write saw it.
            _state = :sys.get_state(Lock)

            send(
              test_pid,
              {:written_under_lock, :ets.lookup(:integration_operation_locks, key) != []}
            )
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      refresh = fn _integration ->
        {:ok, {"api-access", "api-refresh", DateTime.add(DateTime.utc_now(), 3600)}}
      end

      assert {:ok, "api-access"} =
               Tokens.with_access_token(integration, refresh, &{:ok, &1})

      assert_receive {:written_under_lock, true}
    end

    test "an API-call refresh clears a stale sync error", %{integration: integration} do
      integration = set_sync_state(integration, sync_error: "Token refresh failed")

      refresh = fn _integration ->
        {:ok, {"api-access", "api-refresh", DateTime.add(DateTime.utc_now(), 3600)}}
      end

      assert {:ok, "api-access"} =
               Tokens.with_access_token(integration, refresh, &{:ok, &1})

      assert Repo.get!(CalendarIntegrationSchema, integration.id).sync_error == nil
    end

    test "an API-call refresh keeps the reason an integration needs reconnecting",
         %{integration: integration} do
      integration =
        set_sync_state(integration, sync_error: "Booking calendar deleted", needs_reauth: true)

      refresh = fn _integration ->
        {:ok, {"api-access", "api-refresh", DateTime.add(DateTime.utc_now(), 3600)}}
      end

      assert {:ok, "api-access"} =
               Tokens.with_access_token(integration, refresh, &{:ok, &1})

      assert Repo.get!(CalendarIntegrationSchema, integration.id).sync_error ==
               "Booking calendar deleted"
    end

    # A long sync job holds the struct it started with; the flag can be raised
    # while it runs. The refresh must judge the row it re-read under the lock.
    test "an API-call refresh from a copy older than the reconnect flag keeps its reason",
         %{integration: integration} do
      stale_copy = set_sync_state(integration, sync_error: "Token refresh failed")
      set_sync_state(stale_copy, sync_error: "Booking calendar deleted", needs_reauth: true)

      refresh = fn _integration ->
        {:ok, {"api-access", "api-refresh", DateTime.add(DateTime.utc_now(), 3600)}}
      end

      assert {:ok, "api-access"} =
               Tokens.with_access_token(stale_copy, refresh, &{:ok, &1})

      assert %{sync_error: "Booking calendar deleted", needs_reauth: true} =
               Repo.get!(CalendarIntegrationSchema, integration.id)
    end
  end

  # Sends `:contended` to the test process each time the lock refuses `key`.
  defp watch_contention(key) do
    test_pid = self()
    handler_id = {__MODULE__, :contention, make_ref()}

    :telemetry.attach(
      handler_id,
      [:tymeslot, :lock, :acquire, :timeout],
      fn
        _event, _measurements, %{key: ^key}, _config -> send(test_pid, :contended)
        _event, _measurements, _metadata, _config -> :ok
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp set_sync_state(integration, changes) do
    integration
    |> Changeset.change(changes)
    |> Repo.update!()
  end
end
