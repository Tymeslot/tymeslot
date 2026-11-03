defmodule TymeslotWeb.Live.Scheduling.OfferedTimesClosedLinkTest do
  @moduledoc """
  The direct link of a one-to-one type offering fixed dates. With no offered
  time a booker can pick, the type is off the booking page, and its link
  leads there too, saying why, instead of opening on a calendar with no day
  to pick. A reschedule of a booking on the type still opens.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :scheduling
  @moduletag :bookings
  @moduletag :live

  alias Ecto.Changeset
  alias Tymeslot.MeetingTypes.OfferedTimes
  alias Tymeslot.Repo
  alias Tymeslot.RescheduleTestSetup

  setup tags do
    context = RescheduleTestSetup.reschedule_journey(tags)

    meeting_type =
      context[:meeting_type]
      |> Changeset.change(fixed_dates: true, max_participants: 1)
      |> Repo.update!()

    Keyword.put(context, :meeting_type, meeting_type)
  end

  @tag :capture_log
  test "with no time to book, the link leads to the booking page, saying so", %{
    conn: conn,
    profile: profile
  } do
    assert {:error, {:redirect, %{to: to, flash: flash}}} =
             live(conn, "/#{profile.username}/quick-chat?timezone=UTC")

    assert to == "/#{profile.username}"
    assert flash["info"] == "This meeting type has no times open for booking right now."
  end

  @tag :capture_log
  test "with a time to book, the link opens on it", %{
    conn: conn,
    profile: profile,
    user: user,
    meeting_type: meeting_type,
    original_start: original_start
  } do
    {:ok, _offered} =
      OfferedTimes.add(meeting_type, user.id, DateTime.add(original_start, 1, :day))

    assert {:ok, _view, _html} = live(conn, "/#{profile.username}/quick-chat?timezone=UTC")
  end

  @tag :capture_log
  test "a reschedule of a booking on the type still opens", %{
    conn: conn,
    profile: profile,
    meeting: meeting
  } do
    assert {:ok, _view, _html} =
             live(
               conn,
               "/#{profile.username}/quick-chat?timezone=UTC&reschedule_meeting_uid=#{meeting.uid}"
             )
  end
end
