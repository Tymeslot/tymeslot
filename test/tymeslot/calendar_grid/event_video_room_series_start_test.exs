defmodule Tymeslot.CalendarGrid.EventVideoRoomSeriesStartTest do
  @moduledoc """
  A Google or Outlook occurrence carries its series' rule but starts where it
  falls in the series, so a counted series' room is bounded from the series'
  first start, read from the stored rule, not from the occurrence's own.
  """

  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :video
  @moduletag :integration

  alias Tymeslot.CalendarGrid.EventVideoRoomQueries
  alias Tymeslot.CalendarGrid.EventVideoRooms
  alias Tymeslot.Integrations.Calendar.SeriesRuleQueries
  alias Tymeslot.Repo
  alias Tymeslot.Security.Encryption

  @rule "FREQ=WEEKLY;BYDAY=MO,WE;COUNT=3"

  setup do
    user = insert(:user)
    calendar = insert(:calendar_integration, user: user)

    talk =
      insert(:video_integration,
        user: user,
        provider: "nextcloud_talk",
        base_url: "https://counted.example.com",
        client_id_encrypted: Encryption.encrypt("organiser"),
        client_secret_encrypted: Encryption.encrypt("Abcde-Fghij-Klmno-Pqrst-Uvwxy"),
        provider_account_id: "https://counted.example.com||organiser"
      )

    {:ok, room} =
      EventVideoRoomQueries.insert(%{
        user_id: user.id,
        video_integration_id: talk.id,
        provider: "nextcloud_talk",
        calendar_integration_id: calendar.id,
        event_uid: "master-1",
        room_id: "cnt00001",
        lobby_opens_at: ~U[2026-10-05 09:00:00Z],
        ends_at: ~U[2026-10-05 10:00:00Z]
      })

    %{calendar: calendar, room: room}
  end

  # Three repetitions from Monday 5 October; the second Monday's own start
  # would put the bound a week later.
  test "a rescheduled occurrence bounds its series' room from the series' first start", %{
    calendar: calendar,
    room: room
  } do
    {:ok, _row} =
      SeriesRuleQueries.put(calendar.id, "master-1", %{
        rule: @rule,
        master_start: ~U[2026-10-05 09:00:00Z],
        fetched_at: DateTime.utc_now(:second)
      })

    assert :ok =
             EventVideoRooms.rescheduled(%{
               calendar_integration_id: calendar.id,
               uid: "master-1-occurrence-2",
               recurring_event_id: "master-1",
               all_day: false,
               start_at: ~U[2026-10-12 09:00:00Z],
               end_at: ~U[2026-10-12 10:00:00Z],
               recurrence_rule: @rule
             })

    assert Repo.reload!(room).ends_at == ~U[2026-11-17 10:00:00Z]
  end
end
