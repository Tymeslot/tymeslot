defmodule TymeslotWeb.Components.Dashboard.Appointments.AppointmentDetailsTest do
  @moduledoc """
  Covers the body and actions shared by the overview's agenda modal and the
  calendar's booking modal: which calendar an appointment lives in, how its
  video call is named, how soon it is, and which actions it offers.
  """

  use TymeslotWeb.ConnCase, async: true

  @moduletag :dashboard
  @moduletag :components

  import Phoenix.LiveViewTest

  alias Tymeslot.Agenda.Entry
  alias TymeslotWeb.Components.Dashboard.Appointments.AppointmentDetails

  @now ~U[2026-02-05 14:00:00Z]

  defp entry(attrs \\ []) do
    struct!(
      %Entry{
        id: "event-1",
        source: :external,
        title: "Design sync",
        day: ~D[2026-02-05],
        start_at: ~U[2026-02-05 14:30:00Z],
        end_at: ~U[2026-02-05 15:15:00Z],
        all_day?: false
      },
      attrs
    )
  end

  defp details(entry, now \\ @now) do
    render_component(&AppointmentDetails.appointment_details/1,
      entry: entry,
      timezone: "Etc/UTC",
      time_format: "24h",
      now: now
    )
    |> Floki.parse_fragment!()
    |> Floki.text()
  end

  describe "the calendar line" do
    test "says a booking came through the booking page" do
      assert details(entry(source: :tymeslot)) =~ "Booked through your Tymeslot page"
    end

    test "names the synced calendar an event sits in" do
      assert details(entry(calendar: "Work Google")) =~ "Work Google"
    end

    test "falls back when the calendar has no name" do
      assert details(entry()) =~ "External calendar"
    end
  end

  describe "the video line" do
    test "names a recognised platform" do
      assert details(entry(join_url: "https://us02web.zoom.us/j/1")) =~ "Zoom"
      assert details(entry(join_url: "https://meet.google.com/abc")) =~ "Google Meet"
      assert details(entry(join_url: "https://teams.live.com/meet/1")) =~ "Microsoft Teams"
    end

    test "calls any other link a video call" do
      assert details(entry(join_url: "https://video.example.com/room")) =~ "Video call"
    end

    test "is absent without a link, and a link given as the location is not a place" do
      text = details(entry(location: "https://meet.google.com/abc"))

      refute text =~ "Video meeting"
      refute text =~ "Location"
    end
  end

  test "shows the time range with its duration, the attendee and their email" do
    text = details(entry(who: "Ada Lovelace", who_email: "ada@example.com"))

    assert text =~ "14:30 – 15:15"
    assert text =~ "45 min"
    assert text =~ "Ada Lovelace"
    assert text =~ "ada@example.com"
  end

  test "counts down before the start, says in progress while it runs, and nothing after" do
    assert details(entry()) =~ "in 30m"
    assert details(entry(), ~U[2026-02-05 14:45:00Z]) =~ "In progress"

    after_end = details(entry(), ~U[2026-02-05 16:00:00Z])
    refute after_end =~ "In progress"
    refute after_end =~ "in "
  end

  describe "appointment_actions/1" do
    defp actions(entry) do
      Floki.parse_fragment!(
        render_component(&AppointmentDetails.appointment_actions/1, entry: entry)
      )
    end

    test "offers Manage for a booking and Join when there is a call" do
      doc = actions(entry(source: :tymeslot, join_url: "https://zoom.us/j/1"))

      assert [_manage] = Floki.find(doc, ~s(a[href="/dashboard/meetings"]))
      assert [_join] = Floki.find(doc, ~s(a[href="https://zoom.us/j/1"]))
    end

    test "offers neither to a synced event without a call" do
      assert Floki.find(actions(entry()), "a") == []
      refute AppointmentDetails.actions?(entry())
      assert AppointmentDetails.actions?(entry(source: :tymeslot))
    end
  end
end
