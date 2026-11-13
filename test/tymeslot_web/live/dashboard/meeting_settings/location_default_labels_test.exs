defmodule TymeslotWeb.Dashboard.MeetingSettings.LocationDefaultLabelsTest do
  @moduledoc """
  A location's default label ("In person") with the dashboard in another
  language: the editor shows it in the organiser's language, and saving it
  stores the English default rather than the organiser's wording of it.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :integration
  @moduletag :meeting_types
  @moduletag :live

  import Phoenix.LiveViewTest
  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.MeetingTypes
  alias Tymeslot.MeetingTypes.LocationOption
  alias Tymeslot.Repo

  setup :setup_dashboard_user

  setup %{user: user} do
    user |> Changeset.change(locale: "de") |> Repo.update!()
    :ok
  end

  defp open_editor(%{conn: conn, user: user}, locations) do
    meeting_type =
      insert(:meeting_type,
        user: user,
        name: "Consultation",
        duration_minutes: 30,
        locations: locations
      )

    {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

    view
    |> element("[phx-click='edit_type'][phx-value-id='#{meeting_type.id}']")
    |> render_click()

    view |> element("[phx-click='switch_tab'][phx-value-tab='location']") |> render_click()

    {view, meeting_type}
  end

  # The editor saves through `send_update`, delivered after the event
  # round-trip returns; draining the mailbox makes the auto-save observable.
  defp reload(view, meeting_type, user) do
    _drain = :sys.get_state(view.pid)
    MeetingTypes.get_meeting_type(meeting_type.id, user.id)
  end

  defp office,
    do: %LocationOption{id: "loc-office", kind: :in_person, label: "Our office", position: 0}

  # A type with no stored list shows its derived location, named in the
  # host's language; saving it untouched must not store that German name
  # as the host's own text.
  test "is stored as the English default when saved untouched", %{user: user} = ctx do
    {view, meeting_type} = open_editor(ctx, [])

    view
    |> element("[phx-click='edit_location'][phx-value-id='legacy-in-person']")
    |> render_click()

    assert has_element?(view, "#location_label[value='Vor Ort']")

    view
    |> form("#location-editor-form", %{
      "location" => %{"kind" => "in_person", "label" => "Vor Ort"}
    })
    |> render_submit()

    assert [%{id: "legacy-in-person", kind: :in_person, label: "In person"}] =
             reload(view, meeting_type, user).locations
  end

  test "is stored as the English default when the kind fills it in", %{user: user} = ctx do
    {view, meeting_type} = open_editor(ctx, [office()])

    view |> element("button[data-testid='add-location']") |> render_click()

    view
    |> form("#location-editor-form", %{"location" => %{"kind" => "phone"}})
    |> render_change()

    assert has_element?(view, "#location_label[value='Telefonanruf']")

    view
    |> form("#location-editor-form", %{"location" => %{"kind" => "phone", "details" => "+44"}})
    |> render_submit()

    assert [%{label: "Our office"}, %{kind: :phone, label: "Phone call"}] =
             reload(view, meeting_type, user).locations
  end

  test "a stored English default reads in the host's language", ctx do
    {view, _type} =
      open_editor(ctx, [%{office() | label: "In person"}])

    view
    |> element("[phx-click='edit_location'][phx-value-id='loc-office']")
    |> render_click()

    assert has_element?(view, "#location_label[value='Vor Ort']")
  end
end
