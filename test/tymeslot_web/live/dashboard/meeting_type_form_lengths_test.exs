defmodule TymeslotWeb.Dashboard.MeetingTypeFormLengthsTest do
  @moduledoc """
  Round-trips the further durations of a meeting type through the real form:
  the "+" adds a column, the trash icon removes it, a changed value persists,
  and the total stays within the per-type maximum.

  Both write paths are covered, because they are genuinely different code.
  Editing persists through autosave, which serialises the socket's assigns;
  creating persists through the submit, which reads the posted params. A field
  wired into only one of them fails silently in the other — `Validation`
  ignores params it does not know — so the create path has a test of its own.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :meeting_types
  @moduletag :live

  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.MeetingTypes
  alias Tymeslot.Validation.Constraints

  setup :setup_dashboard_user

  defp open_edit_form(view, meeting_type) do
    view
    |> element("[phx-click='edit_type'][phx-value-id='#{meeting_type.id}']")
    |> render_click()
  end

  defp stored(meeting_type, user),
    do: MeetingTypes.get_meeting_type(meeting_type.id, user.id).extra_lengths_minutes

  test "the + adds a further duration and saves it", %{conn: conn, user: user} do
    meeting_type = insert(:meeting_type, user: user, duration_minutes: 30)

    {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")
    open_edit_form(view, meeting_type)

    view |> element("[data-testid='add-length']") |> render_click()

    assert has_element?(view, "[data-testid='extra-length']")
    # The new column starts with the next common length above the longest one.
    assert stored(meeting_type, user) == [45]
  end

  test "changing a further duration saves the new value", %{conn: conn, user: user} do
    meeting_type =
      insert(:meeting_type, user: user, duration_minutes: 30, extra_lengths_minutes: [60, 90])

    {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")
    open_edit_form(view, meeting_type)

    view
    |> element(~s|input[name="meeting_type[extra_lengths][1]"]|)
    |> render_change(%{"meeting_type" => %{"extra_lengths" => %{"1" => "120"}}})

    assert stored(meeting_type, user) == [60, 120]
  end

  test "the trash icon removes that column only", %{conn: conn, user: user} do
    meeting_type =
      insert(:meeting_type, user: user, duration_minutes: 30, extra_lengths_minutes: [60, 90])

    {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")
    open_edit_form(view, meeting_type)

    view
    |> element("[data-testid='remove-length'][phx-value-index='0']")
    |> render_click()

    assert stored(meeting_type, user) == [90]
  end

  test "a repeated duration is refused and not saved", %{conn: conn, user: user} do
    meeting_type =
      insert(:meeting_type, user: user, duration_minutes: 30, extra_lengths_minutes: [60])

    {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")
    open_edit_form(view, meeting_type)

    view
    |> element(~s|input[name="meeting_type[extra_lengths][0]"]|)
    |> render_change(%{"meeting_type" => %{"extra_lengths" => %{"0" => "30"}}})

    assert has_element?(view, "[data-testid='extra-lengths-error']")
    assert stored(meeting_type, user) == [60]
  end

  test "a new meeting type is created with the further durations it was given", %{
    conn: conn,
    user: user
  } do
    {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

    view |> element("button", "Add Meeting Type") |> render_click()

    # The default reminder's hidden inputs cannot be re-encoded by
    # Phoenix.LiveViewTest on submit; removing it first is what the other
    # create-path tests do.
    view |> element("button[aria-label='Remove reminder']") |> render_click()

    view |> element("[data-testid='add-length']") |> render_click()

    view
    |> form("form[phx-submit='save_meeting_type']", %{
      "meeting_type" => %{
        "name" => "Consultation",
        "duration" => "30",
        "extra_lengths" => %{"0" => "90"}
      }
    })
    |> render_submit()

    created =
      user.id
      |> MeetingTypes.get_all_meeting_types()
      |> Enum.find(&(&1.name == "Consultation"))

    assert created.name == "Consultation"
    assert created.duration_minutes == 30
    assert created.extra_lengths_minutes == [90]
  end

  test "no + is offered once the maximum is reached", %{conn: conn, user: user} do
    extras =
      Enum.take([15, 45, 60, 90, 120, 150, 180], Constraints.max_lengths_per_meeting_type() - 1)

    meeting_type =
      insert(:meeting_type, user: user, duration_minutes: 30, extra_lengths_minutes: extras)

    {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")
    open_edit_form(view, meeting_type)

    refute has_element?(view, "[data-testid='add-length']")
  end
end
