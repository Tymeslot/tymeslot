defmodule Tymeslot.Workers.SyncLinkWriteBackMovesTest do
  @moduledoc """
  Moved occurrences reaching the payload from the job that carries them.

  They cannot be read at write time — the cache holds one row per series and the
  moved instance is collapsed into it before this job runs — so they travel on
  the job, and JSONB round-trips them to string keys and ISO 8601 strings on the
  way. A worker that dropped them, or a renderer that read only the atom-keyed
  shape detection produces, would write the placeholder back at the time the
  occurrence left: the exact state the correction exists to undo, reported as a
  success.

  So this drives `perform_job/2` rather than the modules underneath it. The
  shape it asserts against is the one an Oban job actually holds.
  """
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :workers
  @moduletag :sync_links

  import Mox
  import Tymeslot.Factory
  import Tymeslot.SyncLinkTestHelpers

  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Workers.SyncLinkWriteBackWorker

  setup :verify_on_exit!

  setup do
    RateLimiter.clear_all()
    linked_pair()
  end

  defp cached_event(source, attrs) do
    defaults = [
      calendar_integration: source,
      summary: "Weekly standup",
      provider: source.provider,
      provider_event_id: "source-pid-1",
      all_day: false,
      start_at: ~U[2026-12-15 09:00:00Z],
      end_at: ~U[2026-12-15 09:30:00Z]
    ]

    insert(:provider_calendar_event, Keyword.merge(defaults, attrs))
  end

  defp args(link, source_uid, operation) do
    %{
      "sync_link_id" => link.id,
      "source_uid" => source_uid,
      "operation" => operation
    }
  end

  describe "perform/1 with moves on the job" do
    # The moves cannot be read at write time — the cache holds one row per series
    # and the moved instance is collapsed into it before this job runs — so they
    # travel on the job and have to reach the engine from there. A worker that
    # dropped them would write the placeholder back at the time the occurrence
    # left, which is the state the correction exists to undo.
    test "moves carried on the job reach the payload", %{source: source, link: link} do
      cached_event(
        source,
        [uid: "series-uid", timezone: "Europe/Tallinn"] ++ google_series_markers()
      )

      expect(GoogleCalendarAPIMock, :get_event, fn _integration, _calendar_id, _event_id ->
        {:ok, google_series_master()}
      end)

      test_pid = self()

      expect(Tymeslot.CalendarMock, :create_event, fn event_data, _context ->
        send(test_pid, {:payload, event_data})
        {:ok, %{uid: "target-pid-1"}}
      end)

      args =
        link
        |> args("series-uid", "upsert")
        |> Map.put("moved", [
          %{"original_start" => "2026-08-14T14:00:00Z", "new_start" => "2026-08-14T22:00:00Z"}
        ])

      assert :ok == perform_job(SyncLinkWriteBackWorker, args)

      assert_received {:payload, payload}

      assert "EXDATE;TZID=Europe/Tallinn:20260814T170000" in payload.recurrence_exception_lines
      assert "RDATE;TZID=Europe/Tallinn:20260815T010000" in payload.recurrence_exception_lines
    end
  end
end
