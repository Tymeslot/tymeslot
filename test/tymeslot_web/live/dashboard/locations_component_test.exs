defmodule TymeslotWeb.Dashboard.Locations.LocationsComponentTest do
  @moduledoc """
  The Locations page: the organiser's saved in-person locations, added,
  edited, reordered and deleted from the dashboard. Driven through the real
  dashboard LiveView and read back through `Tymeslot.Venues`.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :meeting_types
  @moduletag :live

  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.MeetingTypes
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Venues

  setup :setup_dashboard_user

  defp open(conn) do
    {:ok, view, _html} = live(conn, ~p"/dashboard/locations")
    view
  end

  # Saving and deleting flash through the parent LiveView; draining its
  # mailbox makes the reload they trigger observable.
  defp drain(view), do: :sys.get_state(view.pid)

  describe "with no saved locations" do
    test "explains the page and offers to add one", %{conn: conn} do
      view = open(conn)

      assert has_element?(view, "[data-testid='locations-empty']", "No saved locations yet")

      view |> element("[data-testid='add-venue']") |> render_click()

      assert has_element?(view, "#venue-form")
    end
  end

  describe "adding a location" do
    test "saves it and lists it", %{conn: conn, user: user} do
      view = open(conn)
      view |> element("[data-testid='add-venue']") |> render_click()

      view
      |> form("#venue-form", %{
        "venue" => %{"name" => "Berlin office", "description" => "Friedrichstrasse 1\n3rd floor"}
      })
      |> render_submit()

      drain(view)

      assert [venue] = Venues.list_venues(user.id)
      assert venue.name == "Berlin office"
      assert venue.description == "Friedrichstrasse 1\n3rd floor"
      assert has_element?(view, "[data-testid='venue-card']", "Berlin office")
      refute has_element?(view, "#venue-form")
    end

    test "keeps the form open with the error for a name already used", %{conn: conn, user: user} do
      insert(:venue, user: user, name: "Studio")
      view = open(conn)
      view |> element("[data-testid='add-venue']") |> render_click()

      html = view |> form("#venue-form", %{"venue" => %{"name" => "Studio"}}) |> render_submit()

      assert html =~ "has already been taken"
      assert has_element?(view, "#venue-form")
      assert [_only] = Venues.list_venues(user.id)
    end
  end

  describe "validating a location" do
    test "shows a blank name as an error while the form stays open", %{conn: conn} do
      view = open(conn)
      view |> element("[data-testid='add-venue']") |> render_click()

      # The name is marked required for assistive technology, so the form
      # must turn off the browser's own check or it would hide this error.
      assert has_element?(view, "#venue-form[novalidate] input[name='venue[name]'][required]")

      view |> form("#venue-form", %{"venue" => %{"name" => ""}}) |> render_change()

      assert has_element?(view, "#venue-form", "can't be blank")
    end
  end

  describe "editing a location" do
    test "saves the new name and address", %{conn: conn, user: user} do
      venue = insert(:venue, user: user, name: "Studio", description: "Old Street 1")
      view = open(conn)

      view |> element("[phx-click='edit_venue'][phx-value-id='#{venue.id}']") |> render_click()

      assert has_element?(view, "#venue-form input[value='Studio']")

      view
      |> form("#venue-form", %{
        "venue" => %{"name" => "The studio", "description" => "New Street 2"}
      })
      |> render_submit()

      drain(view)

      assert {:ok, %{name: "The studio", description: "New Street 2"}} =
               Venues.get_venue(user.id, venue.id)

      assert has_element?(view, "[data-testid='venue-card']", "The studio")
    end

    test "does not open for a location that is not the organiser's", %{conn: conn} do
      foreign = insert(:venue, name: "Somebody else's office")
      view = open(conn)

      view
      |> with_target("[data-testid='locations-page']")
      |> render_click("edit_venue", %{"id" => to_string(foreign.id)})

      refute has_element?(view, "#venue-form")
    end

    test "closes the form when the location was deleted meanwhile, say in another tab",
         %{conn: conn, user: user} do
      venue = insert(:venue, user: user, name: "Studio")
      view = open(conn)

      view |> element("[phx-click='edit_venue'][phx-value-id='#{venue.id}']") |> render_click()
      {:ok, _deleted} = Venues.delete_venue(venue)

      view
      |> form("#venue-form", %{"venue" => %{"name" => "The studio"}})
      |> render_submit()

      drain(view)

      assert Process.alive?(view.pid)
      refute has_element?(view, "#venue-form")
      refute has_element?(view, "[data-testid='venue-card']")
      assert Venues.list_venues(user.id) == []
    end
  end

  describe "the list" do
    test "shows only the organiser's own locations, with how many meeting types use each",
         %{conn: conn, user: user} do
      used = insert(:venue, user: user, name: "Berlin office")
      insert(:venue, user: user, name: "Munich office")
      insert(:venue, name: "Somebody else's office")

      insert(:meeting_type,
        user: user,
        name: "Consultation",
        locations: [in_person_location([used])]
      )

      view = open(conn)

      assert has_element?(
               view,
               "[data-venue-id='#{used.id}'] [data-testid='venue-usage']",
               "Used by 1 meeting type"
             )

      assert has_element?(view, "[data-testid='venue-card']", "Munich office")
      assert has_element?(view, "[data-testid='venue-card']", "Not used by any meeting type yet")
      refute has_element?(view, "[data-testid='venue-card']", "Somebody else's office")
    end
  end

  describe "reordering locations" do
    test "dragging saves the new order, which the page then shows", %{conn: conn, user: user} do
      berlin = insert(:venue, user: user, name: "Berlin office", position: 0)
      munich = insert(:venue, user: user, name: "Munich office", position: 1)
      hamburg = insert(:venue, user: user, name: "Hamburg office", position: 2)
      view = open(conn)

      view
      |> element("[data-testid='locations-list']")
      |> render_hook("reorder", %{"ids" => [hamburg.id, berlin.id, munich.id]})

      drain(view)

      assert ["Hamburg office", "Berlin office", "Munich office"] =
               user.id |> Venues.list_venues() |> Enum.map(& &1.name)

      shown =
        view
        |> render()
        |> Floki.parse_document!()
        |> Floki.attribute("[data-testid='venue-card']", "data-venue-id")

      assert shown == Enum.map([hamburg, berlin, munich], &to_string(&1.id))
    end

    test "an id that is not the organiser's changes nothing of theirs or anyone's",
         %{conn: conn, user: user} do
      berlin = insert(:venue, user: user, name: "Berlin office", position: 0)
      munich = insert(:venue, user: user, name: "Munich office", position: 1)
      foreign = insert(:venue, name: "Somebody else's office", position: 3)
      view = open(conn)

      view
      |> element("[data-testid='locations-list']")
      |> render_hook("reorder", %{"ids" => [foreign.id, berlin.id, munich.id]})

      drain(view)

      assert ["Berlin office", "Munich office"] =
               user.id |> Venues.list_venues() |> Enum.map(& &1.name)

      assert [%{position: 3}] = Venues.list_venues(foreign.user_id)
    end
  end

  describe "deleting a location" do
    test "asks first, then removes one no meeting type offers", %{conn: conn, user: user} do
      venue = insert(:venue, user: user, name: "Studio")
      view = open(conn)

      view |> element("[phx-click='delete_venue'][phx-value-id='#{venue.id}']") |> render_click()

      assert has_element?(view, "#delete-venue-modal", "Delete Studio?")
      refute has_element?(view, "[data-testid='venue-in-use']")

      view |> element("[data-testid='confirm-delete-venue']") |> render_click()
      drain(view)

      assert {:error, :not_found} = Venues.get_venue(user.id, venue.id)
      refute has_element?(view, "[data-testid='venue-card']")
      refute has_element?(view, "#delete-venue-modal")
    end

    test "cancelling keeps the location", %{conn: conn, user: user} do
      venue = insert(:venue, user: user, name: "Studio")
      view = open(conn)

      view |> element("[phx-click='delete_venue'][phx-value-id='#{venue.id}']") |> render_click()
      view |> element("#delete-venue-modal [phx-click='close_delete_venue']") |> render_click()

      refute has_element?(view, "#delete-venue-modal")
      assert {:ok, _still_there} = Venues.get_venue(user.id, venue.id)
    end

    test "warns before deleting one a meeting type offers, and deleting it removes it from that meeting type",
         %{conn: conn, user: user} do
      venue = insert(:venue, user: user, name: "Studio")
      other = insert(:venue, user: user, name: "Berlin office")

      only_here =
        insert(:meeting_type,
          user: user,
          name: "Consultation",
          locations: [in_person_location([venue])]
        )

      also_elsewhere =
        insert(:meeting_type,
          user: user,
          name: "Workshop",
          locations: [in_person_location([venue, other])]
        )

      view = open(conn)

      view |> element("[phx-click='delete_venue'][phx-value-id='#{venue.id}']") |> render_click()

      assert has_element?(view, "[data-testid='venue-in-use']", "Consultation")
      assert has_element?(view, "[data-testid='venue-in-use']", "Workshop")
      assert has_element?(view, "[data-testid='venue-left-without']", "Consultation")
      refute has_element?(view, "[data-testid='venue-left-without']", "Workshop")
      assert {:ok, _still_there} = Venues.get_venue(user.id, venue.id)

      view |> element("[data-testid='confirm-delete-venue']") |> render_click()
      drain(view)

      assert {:error, :not_found} = Venues.get_venue(user.id, venue.id)
      assert [%{name: "Berlin office"}] = Venues.list_venues(user.id)

      assert [%{venue_ids: []}] =
               MeetingTypes.get_meeting_type(only_here.id, user.id).locations

      assert [%{venue_ids: [other_id]}] =
               MeetingTypes.get_meeting_type(also_elsewhere.id, user.id).locations

      assert other_id == other.id
    end

    test "does not open for a location that is not the organiser's", %{conn: conn} do
      foreign = insert(:venue, name: "Somebody else's office")
      view = open(conn)

      view
      |> with_target("[data-testid='locations-page']")
      |> render_click("delete_venue", %{"id" => to_string(foreign.id)})

      refute has_element?(view, "#delete-venue-modal")
      assert {:ok, _untouched} = Venues.get_venue(foreign.user_id, foreign.id)
    end
  end

  describe "the meeting-type write limit" do
    # Spends the organiser's meeting-type write allowance, returning the
    # message the next refused write flashes.
    defp exhaust_write_limit(user) do
      Enum.find_value(
        Stream.repeatedly(fn -> RateLimiter.check_meeting_type_write_rate_limit(user.id) end),
        fn
          {:error, :rate_limited, message} -> message
          :ok -> nil
        end
      )
    end

    test "refuses a reorder and rebuilds the list in the saved order",
         %{conn: conn, user: user} do
      berlin = insert(:venue, user: user, name: "Berlin office", position: 0)
      munich = insert(:venue, user: user, name: "Munich office", position: 1)
      view = open(conn)
      before = list_id(view)
      message = exhaust_write_limit(user)

      view
      |> element("[data-testid='locations-list']")
      |> render_hook("reorder", %{"ids" => [munich.id, berlin.id]})

      drain(view)

      assert has_element?(view, "#app-flash-group-error", message)

      assert ["Berlin office", "Munich office"] =
               user.id |> Venues.list_venues() |> Enum.map(& &1.name)

      # The browser has already moved the dragged card, and only a list with
      # a new id is rebuilt from the server's order rather than patched.
      refute list_id(view) == before

      shown =
        view
        |> render()
        |> Floki.parse_document!()
        |> Floki.attribute("[data-testid='venue-card']", "data-venue-id")

      assert shown == Enum.map([berlin, munich], &to_string(&1.id))
    end

    defp list_id(view) do
      view
      |> render()
      |> Floki.parse_document!()
      |> Floki.attribute("[data-testid='locations-list']", "id")
      |> List.first()
    end

    test "refuses saving a location, keeping the form open", %{conn: conn, user: user} do
      view = open(conn)
      view |> element("[data-testid='add-venue']") |> render_click()
      message = exhaust_write_limit(user)

      view
      |> form("#venue-form", %{"venue" => %{"name" => "Berlin office"}})
      |> render_submit()

      drain(view)

      assert Venues.list_venues(user.id) == []
      assert has_element?(view, "#venue-form")
      assert has_element?(view, "#app-flash-group-error", message)
    end

    test "refuses deleting a location, keeping it", %{conn: conn, user: user} do
      venue = insert(:venue, user: user, name: "Studio")
      view = open(conn)
      view |> element("[phx-click='delete_venue'][phx-value-id='#{venue.id}']") |> render_click()
      message = exhaust_write_limit(user)

      view |> element("[data-testid='confirm-delete-venue']") |> render_click()
      drain(view)

      assert [%{id: id}] = Venues.list_venues(user.id)
      assert id == venue.id
      assert has_element?(view, "#app-flash-group-error", message)
    end
  end

  describe "the sidebar" do
    test "links to the page from the scheduling group", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

      assert has_element?(view, "a[href='/dashboard/locations']", "Locations")
    end
  end
end
