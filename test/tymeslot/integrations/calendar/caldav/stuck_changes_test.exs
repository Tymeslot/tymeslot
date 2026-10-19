defmodule Tymeslot.Integrations.Calendar.CalDAV.StuckChangesTest do
  @moduledoc """
  A change the CalDAV server keeps refusing stops being replayed after
  `OfflineQueue`'s attempt cap. The owner is told how many such changes a
  calendar has and what the server last said, and can put them back in the
  queue; an outage alone never reaches the cap, so it never raises the
  notice.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  import Tymeslot.ConfigTestHelpers

  @moduletag :integrations
  @moduletag :calendar

  alias Ecto.Changeset
  alias Plug.Conn
  alias Req.Test, as: ReqTest
  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Calendar.CalDAV.OfflineQueue
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Workers.SyncCalDavCalendarWorker

  @client %{
    base_url: "https://caldav.example.com",
    username: "user",
    password: "pass",
    calendar_paths: ["/cal/"],
    provider: :caldav
  }

  @cap 10

  setup do
    with_config(:tymeslot, :http_client_module, Tymeslot.Infrastructure.HTTPClient)
    RateLimiter.clear_all()

    user = insert(:user)
    integration = insert(:calendar_integration, user: user, provider: "caldav")
    row = queued_change(integration)

    %{user: user, integration: integration, row: row}
  end

  defp queued_change(integration, attrs \\ []) do
    insert(
      :provider_calendar_event,
      Keyword.merge(
        [
          calendar_integration: integration,
          uid: "edited-uid",
          provider: "caldav",
          provider_calendar_id: "/cal/",
          provider_event_id: "/cal/edited-uid.ics",
          summary: "Edited here",
          start_at: ~U[2026-11-02 10:00:00.000000Z],
          end_at: ~U[2026-11-02 11:00:00.000000Z],
          etag: "\"cached-etag\"",
          sync_state: "locally_modified"
        ],
        attrs
      )
    )
  end

  defp server_answers(status),
    do: ReqTest.stub(:tymeslot_http, &Conn.send_resp(&1, status, ""))

  defp flush_times(integration, times),
    do: for(_cycle <- 1..times, do: OfflineQueue.flush(integration, @client))

  defp stuck_at_cap(row), do: Repo.update!(Changeset.change(row, sync_attempts: @cap))

  defp exhaust_refresh_budget(user_id) do
    fn -> RateLimiter.check(:calendar_refresh, user_id) end
    |> Stream.repeatedly()
    |> Enum.find(&match?({:error, :rate_limited, _message}, &1))
  end

  describe "stuck_changes/1" do
    test "reports a change the server refused up to the cap, with what it last said", %{
      user: user,
      integration: integration
    } do
      server_answers(403)

      flush_times(integration, @cap - 1)
      assert Calendar.stuck_changes(user.id) == %{}

      flush_times(integration, 1)
      id = integration.id

      assert %{^id => %{count: 1, last_error: error}} = Calendar.stuck_changes(user.id)
      assert is_binary(error) and error != ""
    end

    test "does not report a change held back only by an outage", %{
      user: user,
      integration: integration
    } do
      server_answers(503)

      flush_times(integration, @cap + 5)

      assert Calendar.stuck_changes(user.id) == %{}
    end

    test "does not report another user's stuck changes", %{row: row} do
      stuck_at_cap(row)

      assert Calendar.stuck_changes(insert(:user).id) == %{}
    end
  end

  describe "retry_stuck_changes/2" do
    setup %{row: row}, do: %{row: stuck_at_cap(row)}

    test "puts the owner's stuck change back in the queue and asks for a full sync", %{
      user: user,
      integration: integration,
      row: row
    } do
      assert {:ok, 1} = Calendar.retry_stuck_changes(user.id, integration.id)

      assert Repo.reload!(row).sync_attempts == 0
      assert Calendar.stuck_changes(user.id) == %{}

      assert [%{args: %{"force_full_fetch" => true}}] =
               all_enqueued(worker: SyncCalDavCalendarWorker)
    end

    test "the next flush replays the retried change", %{
      user: user,
      integration: integration,
      row: row
    } do
      {:ok, 1} = Calendar.retry_stuck_changes(user.id, integration.id)
      server_answers(204)

      flush_times(integration, 1)

      assert Repo.reload!(row).sync_state == "synced"
    end

    test "refuses another user's integration and leaves the change stuck", %{
      integration: integration,
      row: row
    } do
      assert {:error, :not_found} =
               Calendar.retry_stuck_changes(insert(:user).id, integration.id)

      assert Repo.reload!(row).sync_attempts == @cap
      assert all_enqueued(worker: SyncCalDavCalendarWorker) == []
    end

    test "refuses once the refresh budget is spent, without resetting the change", %{
      user: user,
      integration: integration,
      row: row
    } do
      assert {:error, :rate_limited, _message} = exhaust_refresh_budget(user.id)

      assert {:error, {:rate_limited, _message}} =
               Calendar.retry_stuck_changes(user.id, integration.id)

      assert Repo.reload!(row).sync_attempts == @cap
      assert all_enqueued(worker: SyncCalDavCalendarWorker) == []
    end
  end
end
