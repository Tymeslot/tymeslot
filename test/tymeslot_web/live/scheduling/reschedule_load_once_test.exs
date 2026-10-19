defmodule TymeslotWeb.Live.Scheduling.RescheduleLoadOnceTest do
  @moduledoc """
  A reschedule page loads the booking it is moving once each time it applies
  its URL: once for the static render, once for the connected mount and the
  `handle_params` that follows it, and once more for each later patch. The
  steps it goes through on the way to the form, and the fetches of the times
  it offers (which leave the booking out of the host's limits and calendar),
  read what it loaded.

  Counted at the query itself, the lookup by the booking's uid (which names
  the uid first, unlike a count that leaves the booking out), in whichever
  process makes it.
  """
  # The query handler is global, so a concurrent test would add its own reads.
  use TymeslotWeb.LiveCase, async: false

  @moduletag :scheduling
  @moduletag :bookings
  @moduletag :live
  @moduletag :integration

  import Mox
  import Tymeslot.BookingTestHelpers

  alias Tymeslot.RescheduleTestSetup

  setup :verify_on_exit!

  setup tags do
    context = RescheduleTestSetup.reschedule_journey(tags)
    uid = context[:meeting].uid

    parent = self()
    ref = make_ref()
    handler_id = "reschedule-load-#{inspect(ref)}"

    :telemetry.attach(
      handler_id,
      [:tymeslot, :repo, :query],
      fn _event, _measurements, %{source: source, params: params}, _config ->
        if source == "meetings" and match?([^uid | _], params),
          do: send(parent, {:booking_load, ref})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    Keyword.merge(context, ref: ref)
  end

  test "each render of the page loads the booking once", %{
    conn: conn,
    profile: profile,
    meeting: meeting,
    ref: ref
  } do
    {:ok, _view, _html} = live(conn, page_path(profile, meeting))

    assert loads(ref) == 2
  end

  @tag :capture_log
  test "the steps and the times offered on the way to the form read the booking the page loaded",
       %{
         conn: conn,
         profile: profile,
         meeting_type: meeting_type,
         meeting: meeting,
         ref: ref
       } do
    view =
      navigate_to_booking_form(conn, profile, meeting_type, reschedule_meeting_uid: meeting.uid)

    assert render(view) =~ ~s(value="Test Attendee")
    assert loads(ref) == 2
  end

  test "applying the URL again loads the booking afresh", %{
    conn: conn,
    profile: profile,
    meeting: meeting,
    ref: ref
  } do
    path = page_path(profile, meeting)
    {:ok, view, _html} = live(conn, path)
    _mounted = loads(ref)

    render_patch(view, path)

    assert loads(ref) == 1
  end

  defp page_path(profile, meeting),
    do: "/#{profile.username}?timezone=UTC&reschedule_meeting_uid=#{meeting.uid}"

  defp loads(ref, count \\ 0) do
    receive do
      {:booking_load, ^ref} -> loads(ref, count + 1)
    after
      0 -> count
    end
  end
end
