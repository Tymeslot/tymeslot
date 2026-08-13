defmodule TymeslotWeb.Dashboard.CalendarGrid.CrossIntegrationOverlapTest do
  @moduledoc """
  Two real events on different calendars at the same time are marked in the
  organiser's own grid.

  Busy-block mirrors are hidden from that grid (`mirror_hiding_test.exs`), so a
  clash between two connected accounts arrives with nothing to distinguish it
  from an ordinary pair of side-by-side events — precisely the collision the
  synchronisation feature exists to prevent, rendered invisibly.

  Asserted through the LiveView rather than against the layout helper, which
  `helpers/overlap_layout_test.exs` already covers. What only the rendered grid
  can show is that the marker reaches the event element **alongside** its
  resolved colour rather than instead of it: colour is how an organiser tells
  which calendar an event belongs to, and a marker that repainted the event
  would delete the very signal that makes the clash worth noticing. Every
  assertion below therefore checks the colour class and the marker class on the
  same element.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :integration
  @moduletag :calendar
  @moduletag :live

  import Phoenix.LiveViewTest
  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Profiles
  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers.OverlapLayout

  # The dashed outline, not the `ring-*` family. The event block already carries
  # `focus:ring-2 focus:ring-turquoise-400`, so a ring-based marker would both
  # be indistinguishable from the focus ring under a substring assertion and
  # fight it for the same CSS property at render time.
  @marker_class "outline-dashed"

  setup :setup_dashboard_user

  setup %{user: user, profile: profile} do
    # Pinned to UTC so a UTC event time and the day column it lands in cannot
    # drift apart: the factory default is Europe/Tallinn, where an event near
    # either end of the day belongs to the neighbouring local date.
    {:ok, profile} = Profiles.update_timezone(profile, "Etc/UTC")

    work = insert(:calendar_integration, user: user, is_active: true, name: "Work")
    personal = insert(:calendar_integration, user: user, is_active: true, name: "Personal")

    {:ok, profile: profile, work: work, personal: personal}
  end

  defp at(time), do: DateTime.new!(Date.utc_today(), time, "Etc/UTC")

  defp insert_event(integration, summary, from, to) do
    insert(:provider_calendar_event,
      calendar_integration: integration,
      summary: summary,
      start_at: at(from),
      end_at: at(to)
    )
  end

  # The class list of the grid element rendering the event with this title.
  # Scoped to `[id^='event-']`, the timed-grid event blocks, so a match cannot
  # come from the agenda list or a month chip rendering the same title.
  defp event_classes(html, summary) do
    html
    |> Floki.parse_document!()
    |> Floki.find("[id^='event-']")
    |> Enum.filter(&(Floki.text(&1) =~ summary))
    |> Floki.attribute("class")
    |> Enum.join(" ")
  end

  defp colour_class(classes) do
    classes
    |> String.split(~r/\s+/, trim: true)
    |> Enum.find(&String.starts_with?(&1, "bg-calendar-"))
  end

  describe "events overlapping across two calendars" do
    test "both are marked, and both keep the colour of the calendar they sit on", %{
      conn: conn,
      work: work,
      personal: personal
    } do
      insert_event(work, "Sprint review", ~T[10:00:00], ~T[11:00:00])
      insert_event(personal, "Dentist", ~T[10:30:00], ~T[11:30:00])

      {:ok, _view, html} = live(conn, ~p"/dashboard/calendar")

      review = event_classes(html, "Sprint review")
      dentist = event_classes(html, "Dentist")

      assert review =~ @marker_class
      assert dentist =~ @marker_class

      # The marker composes with the colour rather than replacing it. Both
      # events must still carry a calendar colour, and the two must differ —
      # that difference is what tells the organiser the clash spans two
      # calendars rather than being a double booking inside one.
      assert colour_class(review) =~ ~r/^bg-calendar-/
      assert colour_class(dentist) =~ ~r/^bg-calendar-/
      refute colour_class(review) == colour_class(dentist)
    end

    test "the marker never touches the colour the event would have had alone", %{
      conn: conn,
      work: work,
      personal: personal
    } do
      # The same event, rendered twice: once with no clash and once against a
      # partner on the other calendar. Comparing the two renders to each other
      # pins that the marker added a class and changed nothing else about the
      # colour, without hard-coding which rotation slot "Work" happened to draw.
      insert_event(work, "Sprint review", ~T[10:00:00], ~T[11:00:00])

      {:ok, _view, alone_html} = live(conn, ~p"/dashboard/calendar")
      alone = event_classes(alone_html, "Sprint review")

      refute alone =~ @marker_class
      colour_alone = colour_class(alone)
      assert colour_alone =~ ~r/^bg-calendar-/

      insert_event(personal, "Dentist", ~T[10:30:00], ~T[11:30:00])

      {:ok, _view, clash_html} = live(conn, ~p"/dashboard/calendar")
      clashing = event_classes(clash_html, "Sprint review")

      assert clashing =~ @marker_class
      assert colour_class(clashing) == colour_alone
    end

    test "the marker is announced to a screen reader", %{
      conn: conn,
      work: work,
      personal: personal
    } do
      insert_event(work, "Sprint review", ~T[10:00:00], ~T[11:00:00])
      insert_event(personal, "Dentist", ~T[10:30:00], ~T[11:30:00])

      {:ok, _view, html} = live(conn, ~p"/dashboard/calendar")

      labels =
        html
        |> Floki.parse_document!()
        |> Floki.find("[id^='event-']")
        |> Enum.filter(&(Floki.text(&1) =~ "Sprint review"))
        |> Floki.attribute("aria-label")

      # A ring is invisible to a screen reader, so the same fact is carried in
      # the label the event already exposes rather than in a second element.
      assert Enum.any?(labels, &(&1 =~ "another calendar"))
    end
  end

  describe "events that do not clash across calendars" do
    test "two overlapping events on the same calendar are not marked", %{
      conn: conn,
      work: work
    } do
      # A double booking inside one calendar is the organiser's own doing and
      # already visible as two side-by-side blocks in one colour. Marking it
      # would spend the marker on the case the feature is not about.
      insert_event(work, "Sprint review", ~T[10:00:00], ~T[11:00:00])
      insert_event(work, "1:1 with Ada", ~T[10:30:00], ~T[11:30:00])

      {:ok, _view, html} = live(conn, ~p"/dashboard/calendar")

      review = event_classes(html, "Sprint review")
      one_on_one = event_classes(html, "1:1 with Ada")

      refute review =~ @marker_class
      refute one_on_one =~ @marker_class
      # Both sit on the same calendar, so both must keep the same colour: the
      # pair reads as one calendar's own double booking, which is what leaving
      # it unmarked is saying.
      assert colour_class(review) =~ ~r/^bg-calendar-/
      assert colour_class(one_on_one) == colour_class(review)
    end

    test "events on different calendars at different times are not marked", %{
      conn: conn,
      work: work,
      personal: personal
    } do
      insert_event(work, "Sprint review", ~T[10:00:00], ~T[11:00:00])
      insert_event(personal, "Dentist", ~T[14:00:00], ~T[15:00:00])

      {:ok, _view, html} = live(conn, ~p"/dashboard/calendar")

      refute event_classes(html, "Sprint review") =~ @marker_class
      refute event_classes(html, "Dentist") =~ @marker_class
    end

    test "back-to-back events on different calendars are not marked", %{
      conn: conn,
      work: work,
      personal: personal
    } do
      # One ends exactly where the next begins. The layout already treats this
      # as non-overlapping (a shared boundary reuses the column), and the
      # marker has to agree — an organiser whose calendars are simply full
      # would otherwise see every consecutive pair flagged as a clash.
      insert_event(work, "Sprint review", ~T[10:00:00], ~T[11:00:00])
      insert_event(personal, "Dentist", ~T[11:00:00], ~T[12:00:00])

      {:ok, _view, html} = live(conn, ~p"/dashboard/calendar")

      refute event_classes(html, "Sprint review") =~ @marker_class
      refute event_classes(html, "Dentist") =~ @marker_class
    end
  end

  describe "three overlapping events spanning two calendars" do
    test "the pair that clashes across calendars is marked and the rest is not", %{
      conn: conn,
      work: work,
      personal: personal
    } do
      # "Overlaps something" is not the question the marker answers. All three
      # events below sit in one overlap cluster, so `total_cols` is 3 for every
      # one of them, but "Standup" ends before the cross-calendar partner
      # begins and must stay unmarked. A marker keyed on the column count alone
      # would flag it.
      insert_event(work, "Standup", ~T[09:00:00], ~T[09:30:00])
      insert_event(work, "Sprint review", ~T[09:15:00], ~T[11:00:00])
      insert_event(personal, "Dentist", ~T[10:00:00], ~T[11:30:00])

      {:ok, _view, html} = live(conn, ~p"/dashboard/calendar")

      refute event_classes(html, "Standup") =~ @marker_class
      assert event_classes(html, "Sprint review") =~ @marker_class
      assert event_classes(html, "Dentist") =~ @marker_class
    end
  end

  describe "cross_integration_overlap_ids/1" do
    # The unit-level counterpart to the renders above: the layout helper is
    # where the pairing is decided, and these cases are cheaper to state here
    # than as four more LiveView mounts.
    defp ev(id, integration_id, from, to) do
      %{
        id: id,
        calendar_integration_id: integration_id,
        start_at: DateTime.new!(~D[2026-03-12], from, "Etc/UTC"),
        end_at: DateTime.new!(~D[2026-03-12], to, "Etc/UTC")
      }
    end

    test "returns both events of a cross-integration overlap" do
      events = [ev(1, 10, ~T[09:00:00], ~T[10:00:00]), ev(2, 20, ~T[09:30:00], ~T[10:30:00])]

      assert OverlapLayout.cross_integration_overlap_ids(events) == MapSet.new([1, 2])
    end

    test "returns nothing when both events share an integration" do
      events = [ev(1, 10, ~T[09:00:00], ~T[10:00:00]), ev(2, 10, ~T[09:30:00], ~T[10:30:00])]

      assert OverlapLayout.cross_integration_overlap_ids(events) == MapSet.new()
    end

    test "a shared boundary is not an overlap" do
      events = [ev(1, 10, ~T[09:00:00], ~T[10:00:00]), ev(2, 20, ~T[10:00:00], ~T[11:00:00])]

      assert OverlapLayout.cross_integration_overlap_ids(events) == MapSet.new()
    end

    test "an event fully containing a shorter one on another calendar marks both" do
      events = [ev(1, 10, ~T[09:00:00], ~T[17:00:00]), ev(2, 20, ~T[12:00:00], ~T[12:30:00])]

      assert OverlapLayout.cross_integration_overlap_ids(events) == MapSet.new([1, 2])
    end

    test "an event overlapping only same-calendar neighbours is left out" do
      events = [
        ev(1, 10, ~T[09:00:00], ~T[09:30:00]),
        ev(2, 10, ~T[09:15:00], ~T[11:00:00]),
        ev(3, 20, ~T[10:00:00], ~T[11:30:00])
      ]

      assert OverlapLayout.cross_integration_overlap_ids(events) == MapSet.new([2, 3])
    end

    test "an empty day has nothing to mark" do
      assert OverlapLayout.cross_integration_overlap_ids([]) == MapSet.new()
    end
  end
end
