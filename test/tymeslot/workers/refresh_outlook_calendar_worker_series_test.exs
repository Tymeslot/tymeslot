defmodule Tymeslot.Workers.RefreshOutlookCalendarWorkerSeriesTest do
  @moduledoc """
  The Outlook delta sweep over a series the cache holds as its master's own
  row, as the grid caches a series it created, once its occurrences arrive.
  Split from `RefreshOutlookCalendarWorkerTest` for size.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :workers
  @moduletag :calendar

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Workers.RefreshOutlookCalendarWorker

  setup :set_mox_global
  setup :verify_on_exit!

  defp outlook_integration(attrs) do
    defaults = [
      provider: "outlook",
      is_active: true,
      access_token_encrypted: Encryption.encrypt("test-access-token"),
      refresh_token_encrypted: Encryption.encrypt("test-refresh-token"),
      token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
      # A delta link bootstrapped an hour ago: young enough to be used.
      last_full_sync_at: DateTime.add(DateTime.utc_now(:second), -3600, :second)
    ]

    insert(:calendar_integration, Keyword.merge(defaults, attrs))
  end

  describe "perform/1 when a series cached as its master arrives as occurrences" do
    # A series the grid created with a video was cached as its master row,
    # the one place the video is recorded; the sync never writes a row's
    # video, so the occurrences replacing that row must be given it.
    test "gives the occurrences the master row's video before dropping the row" do
      integration =
        outlook_integration(
          graph_delta_link:
            "https://graph.microsoft.com/v1.0/me/calendarView/delta?$deltatoken=old"
        )

      video = insert(:video_integration, user: integration.user, provider: "mirotalk")
      link = "https://video.example.com/join/weekly"

      insert(:provider_calendar_event,
        calendar_integration: integration,
        provider: "outlook",
        uid: "040000008200E00074C5B7101A82E008",
        provider_event_id: "master-1",
        recurrence_rule: "FREQ=WEEKLY;BYDAY=MO",
        video_link: link,
        video_integration_id: video.id
      )

      occurrence = fn id, day ->
        %{
          "id" => id,
          "iCalUId" => "040000008200E00074C5B7101A82E008-#{id}",
          "type" => "occurrence",
          "seriesMasterId" => "master-1",
          "subject" => "Weekly",
          "isAllDay" => false,
          "start" => %{"dateTime" => "2026-11-#{day}T08:00:00.0000000", "timeZone" => "UTC"},
          "end" => %{"dateTime" => "2026-11-#{day}T09:00:00.0000000", "timeZone" => "UTC"}
        }
      end

      delta_response_body =
        Jason.encode!(%{
          "value" => [occurrence.("occ-1", "02"), occurrence.("occ-2", "09")],
          "@odata.deltaLink" =>
            "https://graph.microsoft.com/v1.0/me/calendarView/delta?$deltatoken=fresh"
        })

      expect(Tymeslot.HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        {:ok, %{status: 200, body: delta_response_body}}
      end)

      # The series' rule is read from its master, which this test leaves out.
      stub(OutlookCalendarAPIMock, :get_series_master, fn _integration, _master_id ->
        {:error, :not_found, "Not found"}
      end)

      assert :ok =
               perform_job(RefreshOutlookCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      assert ProviderCalendarEventQueries.get_by_uid(
               integration.id,
               "040000008200E00074C5B7101A82E008"
             ) == {:error, :not_found}

      for id <- ["occ-1", "occ-2"] do
        assert {:ok, row} =
                 ProviderCalendarEventQueries.get_by_uid(
                   integration.id,
                   "040000008200E00074C5B7101A82E008-#{id}"
                 )

        assert {row.video_integration_id, row.video_link} == {video.id, link}
      end
    end
  end
end
