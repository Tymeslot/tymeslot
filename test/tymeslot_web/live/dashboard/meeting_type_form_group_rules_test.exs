defmodule TymeslotWeb.Dashboard.MeetingTypeFormGroupRulesTest do
  @moduledoc """
  What the meeting-type form refuses around group bookings, and how it says
  so: approval and group bookings exclude each other, a group type's
  location is fixed in advance, and group bookings can sit behind a plan.

  Each control that would break a rule renders disabled with the reason; the
  tests also drive the refused event directly, since a stale or forged event
  must not get past the server-side guard either.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :meeting_types
  @moduletag :live

  import Phoenix.LiveViewTest
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Ecto.UUID
  alias Tymeslot.MeetingTypes

  setup :setup_dashboard_user

  defp edit(conn, meeting_type) do
    {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

    view
    |> element("button[phx-click='edit_type'][phx-value-id='#{meeting_type.id}']")
    |> render_click()

    view
  end

  defp form_wrapper(meeting_type),
    do: "#meeting-type-form-wrapper-meeting-type-form-edit-#{meeting_type.id}"

  defp at_venue(user) do
    venue = insert(:venue, user: user, name: "Main Hall")
    [in_person_location([venue])]
  end

  defp edit_location(conn, meeting_type) do
    view = edit(conn, meeting_type)

    view
    |> element("[data-testid='location-row'] button[phx-click='edit_location']")
    |> render_click()

    view
  end

  defp location_params(location, overrides) do
    %{
      "location" =>
        Map.merge(
          %{
            "id" => location.id,
            "kind" => "in_person",
            "label" => "In person",
            "position" => "0"
          },
          overrides
        )
    }
  end

  defp reload(meeting_type),
    do: MeetingTypes.get_meeting_type(meeting_type.id, meeting_type.user_id)

  describe "approval and group bookings" do
    test "requiring approval disables the group toggle and refuses the event",
         %{conn: conn, user: user} do
      meeting_type =
        insert(:meeting_type, user: user, requires_approval: true, locations: at_venue(user))

      view = edit(conn, meeting_type)

      assert has_element?(view, "input[phx-click='toggle_group_bookings'][disabled]")
      assert render(view) =~ "Turn off approval to enable group bookings."

      view
      |> with_target(form_wrapper(meeting_type))
      |> render_click("toggle_group_bookings", %{})

      assert reload(meeting_type).max_participants == 1
      refute render(view) =~ "Participant limit"
    end

    test "group bookings disable the approval toggle and refuse the event",
         %{conn: conn, user: user} do
      meeting_type =
        insert(:meeting_type, user: user, max_participants: 5, locations: at_venue(user))

      view = edit(conn, meeting_type)

      assert has_element?(view, "[data-testid='requires-approval-toggle'][disabled]")
      assert render(view) =~ "Turn off group bookings to require approval."

      view
      |> with_target(form_wrapper(meeting_type))
      |> render_click("toggle_requires_approval", %{})

      refute reload(meeting_type).requires_approval
    end

    test "turning approval off makes group bookings available again",
         %{conn: conn, user: user} do
      meeting_type =
        insert(:meeting_type, user: user, requires_approval: true, locations: at_venue(user))

      view = edit(conn, meeting_type)

      view |> element("[data-testid='requires-approval-toggle']") |> render_click()
      view |> element("input[phx-click='toggle_group_bookings']") |> render_click()

      assert %{requires_approval: false, max_participants: 10} = reload(meeting_type)
    end
  end

  describe "a group type's location" do
    test "two locations disable the group toggle with what to change, and refuse the event",
         %{conn: conn, user: user} do
      [office] = at_venue(user)

      phone = %{
        office
        | id: UUID.generate(),
          kind: "phone",
          label: "Phone",
          venue_ids: [],
          details: "+44 20 7946 0000",
          position: 1
      }

      meeting_type = insert(:meeting_type, user: user, locations: [office, phone])
      view = edit(conn, meeting_type)

      assert has_element?(view, "input[phx-click='toggle_group_bookings'][disabled]")
      assert render(view) =~ "Group bookings need exactly one location"

      view
      |> with_target(form_wrapper(meeting_type))
      |> render_click("toggle_group_bookings", %{})

      assert reload(meeting_type).max_participants == 1
    end

    test "an address arranged after booking disables the group toggle",
         %{conn: conn, user: user} do
      meeting_type = insert(:meeting_type, user: user, locations: [in_person_location()])
      view = edit(conn, meeting_type)

      assert has_element?(view, "input[phx-click='toggle_group_bookings'][disabled]")
      assert render(view) =~ "Group bookings need the address up front."
    end

    test "a group type offers no second location, and refuses one added anyway",
         %{conn: conn, user: user} do
      meeting_type =
        insert(:meeting_type, user: user, max_participants: 5, locations: at_venue(user))

      view = edit(conn, meeting_type)

      refute has_element?(view, "[data-testid='add-location']")
      assert render(view) =~ "Group bookings use one location, fixed in advance"

      view
      |> with_target("#locations-section-meeting-type-form-edit-#{meeting_type.id}")
      |> render_click("add_location", %{})

      refute has_element?(view, "#location-editor-form")
    end

    test "a group type's location cannot be edited into a choice of venues",
         %{conn: conn, user: user} do
      [location] = locations = at_venue(user)
      second = insert(:venue, user: user, name: "Annex")
      meeting_type = insert(:meeting_type, user: user, max_participants: 5, locations: locations)
      view = edit(conn, meeting_type)

      view
      |> element("[data-testid='location-row'] button[phx-click='edit_location']")
      |> render_click()

      view
      |> element("#location-editor-form")
      |> render_submit(%{
        "location" => %{
          "id" => location.id,
          "kind" => "in_person",
          "label" => "In person",
          "position" => "0",
          "venue_ids" => ["", to_string(hd(location.venue_ids)), to_string(second.id)]
        }
      })

      assert view |> element("[data-testid='group-location-error']") |> render() =~
               "Group bookings meet in one place. Keep just one saved location."

      assert reload(meeting_type).locations |> hd() |> Map.get(:venue_ids) == location.venue_ids
    end

    test "a refusal goes once the location would pass, without another save",
         %{conn: conn, user: user} do
      [location] = locations = at_venue(user)
      [venue_id] = location.venue_ids
      second = insert(:venue, user: user, name: "Annex")
      meeting_type = insert(:meeting_type, user: user, max_participants: 5, locations: locations)
      view = edit_location(conn, meeting_type)

      two_venues =
        location_params(location, %{"venue_ids" => ["", "#{venue_id}", "#{second.id}"]})

      view |> element("#location-editor-form") |> render_submit(two_venues)
      assert has_element?(view, "[data-testid='group-location-error']")

      view
      |> element("#location-editor-form")
      |> render_change(location_params(location, %{"venue_ids" => ["", "#{second.id}"]}))

      refute has_element?(view, "[data-testid='group-location-error']")
    end

    test "a refusal is reworded when the location breaks a different rule",
         %{conn: conn, user: user} do
      [location] = locations = at_venue(user)
      meeting_type = insert(:meeting_type, user: user, max_participants: 5, locations: locations)
      view = edit_location(conn, meeting_type)

      view
      |> element("#location-editor-form")
      |> render_submit(
        location_params(location, %{"kind" => "phone", "collect_from_guest" => "true"})
      )

      assert view |> element("[data-testid='group-location-error']") |> render() =~
               "Turn this off and publish a number for them to call instead."

      view
      |> element("#location-editor-form")
      |> render_change(location_params(location, %{"kind" => "in_person", "venue_ids" => [""]}))

      error = view |> element("[data-testid='group-location-error']") |> render()
      assert error =~ "Group bookings need the address up front. Choose one saved location."
      refute error =~ "Edit the location"
    end

    test "the venue picker offers a single choice and says why",
         %{conn: conn, user: user} do
      locations = at_venue(user)
      insert(:venue, user: user, name: "Annex")
      meeting_type = insert(:meeting_type, user: user, max_participants: 5, locations: locations)
      view = edit_location(conn, meeting_type)

      assert has_element?(view, "#location_venue_ids input[type='radio']")
      refute has_element?(view, "#location_venue_ids input[type='checkbox']")
      assert render(view) =~ "Pick one. Group bookings meet in one place."
      refute render(view) =~ "Pick one or more."
    end
  end

  describe "when group bookings are not on the plan" do
    defmodule DenyGroupBookingsChecker do
      @behaviour Tymeslot.Features.CheckerBehaviour
      @impl Tymeslot.Features.CheckerBehaviour
      def check_access(_user_id, :group_bookings_allowed), do: {:error, :insufficient_plan}
      def check_access(_user_id, _feature), do: :ok
    end

    setup do
      assigns = Application.get_env(:tymeslot, :feature_assigns, [])

      setup_config(:tymeslot,
        feature_access_checker: DenyGroupBookingsChecker,
        feature_assigns: Keyword.put(assigns, :group_bookings_allowed, false)
      )
    end

    test "a one-to-one type shows the locked section and refuses the event",
         %{conn: conn, user: user} do
      meeting_type = insert(:meeting_type, user: user, locations: at_venue(user))
      view = edit(conn, meeting_type)

      assert has_element?(view, "[data-testid='group-bookings-locked']")
      refute has_element?(view, "input[phx-click='toggle_group_bookings']")

      view
      |> with_target(form_wrapper(meeting_type))
      |> render_click("toggle_group_bookings", %{})

      assert reload(meeting_type).max_participants == 1
    end

    test "an existing group type can still be saved, but not raised",
         %{conn: conn, user: user} do
      meeting_type =
        insert(:meeting_type, user: user, max_participants: 4, locations: at_venue(user))

      view = edit(conn, meeting_type)

      refute has_element?(view, "[data-testid='group-bookings-locked']")

      view
      |> element("input[name='meeting_type[name]']")
      |> render_change(%{"meeting_type" => %{"name" => "Renamed Workshop"}})

      assert %{name: "Renamed Workshop", max_participants: 4} = reload(meeting_type)

      view
      |> element("input[phx-change='change_max_participants']")
      |> render_change(%{"meeting_type" => %{"max_participants_input" => "6"}})

      assert render(view) =~ "Group bookings are not included in your current plan."
      assert reload(meeting_type).max_participants == 4
    end

    test "Core's own default leaves the section unlocked", %{conn: conn, user: user} do
      setup_config(:tymeslot,
        feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
        feature_assigns:
          Keyword.put(
            Application.get_env(:tymeslot, :feature_assigns),
            :group_bookings_allowed,
            true
          )
      )

      meeting_type = insert(:meeting_type, user: user, locations: at_venue(user))
      view = edit(conn, meeting_type)

      refute has_element?(view, "[data-testid='group-bookings-locked']")
      view |> element("input[phx-click='toggle_group_bookings']") |> render_click()

      assert reload(meeting_type).max_participants == 10
    end
  end

  describe "creating after a failed save" do
    test "a refused create does not block the next one", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")
      view |> element("button", "Add Meeting Type") |> render_click()

      view
      |> form("form[phx-submit='create_meeting_type']", %{
        "meeting_type" => %{"name" => "", "duration" => "30"}
      })
      |> render_submit()

      refute Enum.any?(MeetingTypes.get_all_meeting_types(user.id), &(&1.name == "Office Hours"))
      assert has_element?(view, "button[type='submit']:not([disabled])", "Create meeting type")

      view
      |> form("form[phx-submit='create_meeting_type']", %{
        "meeting_type" => %{"name" => "Office Hours", "duration" => "30"}
      })
      |> render_submit()

      assert render(view) =~ "Meeting type created"
      assert Enum.any?(MeetingTypes.get_all_meeting_types(user.id), &(&1.name == "Office Hours"))
    end
  end
end
