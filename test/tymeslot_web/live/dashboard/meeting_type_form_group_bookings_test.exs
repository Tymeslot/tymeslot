defmodule TymeslotWeb.Dashboard.MeetingTypeFormGroupBookingsTest do
  @moduledoc """
  LiveView coverage for the meeting-type form's Group bookings section —
  the user journey where an organiser lets multiple people book the same
  slot and sets the participant limit.

  Edit mode auto-saves every change. A new type is created from its Details
  tab first, so group bookings are set up once it exists. Group bookings and
  payments are mutually exclusive (covered in the dedicated describe below).
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :meeting_types
  @moduletag :live

  import Phoenix.LiveViewTest
  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.MeetingTypes

  setup :setup_dashboard_user

  describe "Editing: auto-save" do
    test "toggling group bookings on persists the default limit and the input persists changes",
         %{conn: conn, user: user} do
      meeting_type = insert_type(user, name: "Team Demo")

      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

      view
      |> element("button[phx-click='edit_type'][phx-value-id='#{meeting_type.id}']")
      |> render_click()

      view
      |> element("input[phx-click='toggle_group_bookings']")
      |> render_click()

      assert render(view) =~ "Participant limit"

      updated = reload_type(user, meeting_type.id)
      assert updated.max_participants == 10

      view
      |> element("input[phx-change='change_max_participants']")
      |> render_change(%{"meeting_type" => %{"max_participants_input" => "25"}})

      assert reload_type(user, meeting_type.id).max_participants == 25
    end

    test "toggling group bookings off reverts the limit to 1", %{conn: conn, user: user} do
      meeting_type = insert_type(user, max_participants: 8)

      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

      view
      |> element("button[phx-click='edit_type'][phx-value-id='#{meeting_type.id}']")
      |> render_click()

      # Stored group type pre-fills the toggle on and the input with 8.
      assert has_element?(view, "input[phx-click='toggle_group_bookings'][checked]")
      assert render(view) =~ ~s(value="8")

      view
      |> element("input[phx-click='toggle_group_bookings']")
      |> render_click()

      assert reload_type(user, meeting_type.id).max_participants == 1
    end

    test "turning group bookings off and on again keeps the limit", %{conn: conn, user: user} do
      meeting_type = insert_type(user)

      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

      view
      |> element("button[phx-click='edit_type'][phx-value-id='#{meeting_type.id}']")
      |> render_click()

      toggle = element(view, "input[phx-click='toggle_group_bookings']")
      render_click(toggle)

      view
      |> element("input[phx-change='change_max_participants']")
      |> render_change(%{"meeting_type" => %{"max_participants_input" => "3"}})

      assert reload_type(user, meeting_type.id).max_participants == 3

      render_click(toggle)
      assert reload_type(user, meeting_type.id).max_participants == 1

      render_click(toggle)

      assert has_element?(view, "input[name='meeting_type[max_participants_input]'][value='3']")
      assert reload_type(user, meeting_type.id).max_participants == 3
    end

    test "an invalid limit is not reported as saved, even after another field saves",
         %{conn: conn, user: user} do
      meeting_type = insert_type(user, max_participants: 4)

      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

      view
      |> element("button[phx-click='edit_type'][phx-value-id='#{meeting_type.id}']")
      |> render_click()

      view
      |> element("input[phx-change='change_max_participants']")
      |> render_change(%{"meeting_type" => %{"max_participants_input" => "1500"}})

      refute render(view) =~ "All changes saved"
      assert render(view) =~ "Unsaved changes"

      view
      |> element("input[name='meeting_type[name]']")
      |> render_change(%{"meeting_type" => %{"name" => "Renamed Workshop"}})

      assert reload_type(user, meeting_type.id).name == "Renamed Workshop"
      html = render(view)
      refute html =~ "All changes saved"
      assert html =~ "Participant limit cannot exceed 999"
    end

    test "a limit above 999 shows an inline error and does not persist",
         %{conn: conn, user: user} do
      meeting_type = insert_type(user)

      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

      view
      |> element("button[phx-click='edit_type'][phx-value-id='#{meeting_type.id}']")
      |> render_click()

      view
      |> element("input[phx-click='toggle_group_bookings']")
      |> render_click()

      view
      |> element("input[phx-change='change_max_participants']")
      |> render_change(%{"meeting_type" => %{"max_participants_input" => "1500"}})

      assert render(view) =~ "Participant limit cannot exceed 999"
      assert reload_type(user, meeting_type.id).max_participants == 10
    end

    test "an invalid limit left pending does not un-group the type on a later autosave",
         %{conn: conn, user: user} do
      meeting_type = insert_type(user, max_participants: 10)

      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

      view
      |> element("button[phx-click='edit_type'][phx-value-id='#{meeting_type.id}']")
      |> render_click()

      # "1" is a valid *solo* value but not a valid *group* value — the
      # inline validator correctly rejects it and leaves the raw value in
      # the input for display.
      view
      |> element("input[phx-change='change_max_participants']")
      |> render_change(%{"meeting_type" => %{"max_participants_input" => "1"}})

      assert render(view) =~ "Participant limit must be at least 2"
      assert reload_type(user, meeting_type.id).max_participants == 10

      # Editing an unrelated field triggers auto-save. Before the fix, this
      # persisted the pending "1" as a valid *solo* value (1 is inside the
      # wide 1..999 range) and silently un-grouped the type.
      view
      |> element("input[name='meeting_type[name]']")
      |> render_change(%{"meeting_type" => %{"name" => "Renamed Workshop"}})

      assert reload_type(user, meeting_type.id).max_participants == 10
    end
  end

  describe "Creating" do
    test "a new type offers group bookings once it is created and its location is fixed",
         %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")
      view |> element("button", "Add Meeting Type") |> render_click()

      # Only Details renders until the type exists.
      refute has_element?(view, "input[phx-click='toggle_group_bookings']")

      view
      |> form("form[phx-submit='create_meeting_type']", %{
        "meeting_type" => %{"name" => "Group Workshop", "duration" => "60"}
      })
      |> render_submit()

      assert render(view) =~ "Meeting type created"
      hold_at_fixed_location(view)

      view
      |> element("input[phx-click='toggle_group_bookings']")
      |> render_click()

      view
      |> element("input[phx-change='change_max_participants']")
      |> render_change(%{"meeting_type" => %{"max_participants_input" => "12"}})

      created =
        Enum.find(
          MeetingTypes.get_all_meeting_types(user.id),
          &(&1.name == "Group Workshop")
        )

      assert created.max_participants == 12
    end
  end

  describe "Mutual exclusion with payments" do
    setup %{user: user} do
      # Force the Core default checker so the runtime feature flag drives
      # access regardless of any SaaS overlay, then restore afterwards.
      previous_checker = Application.get_env(:tymeslot, :feature_access_checker)
      previous_flag = Application.get_env(:tymeslot, :meeting_payments_enabled)

      Application.put_env(
        :tymeslot,
        :feature_access_checker,
        Tymeslot.Features.DefaultAccessChecker
      )

      Application.put_env(:tymeslot, :meeting_payments_enabled, true)
      insert(:connect_account, user: user, charges_enabled: true, default_currency: "usd")

      on_exit(fn ->
        restore_env(:feature_access_checker, previous_checker)
        restore_env(:meeting_payments_enabled, previous_flag)
      end)

      :ok
    end

    test "requiring payment disables the group toggle and blocks the event",
         %{conn: conn, user: user} do
      meeting_type = insert_type(user)
      view = edit(conn, meeting_type)

      view
      |> element("input[phx-click='toggle_payment_required']")
      |> render_click()

      assert has_element?(view, "input[phx-click='toggle_group_bookings'][disabled]")
      assert render(view) =~ "Turn off payments to enable group bookings."

      # A stale/forged click must not flip the toggle server-side. The
      # control is disabled, so we drive the component event directly
      # (mirroring the pattern in payments_settings_test.exs) rather than
      # clicking the disabled DOM element, which LiveViewTest itself refuses.
      view
      |> with_target("#meeting-type-form-wrapper-meeting-type-form-edit-#{meeting_type.id}")
      |> render_click("toggle_group_bookings", %{})

      refute render(view) =~ "Participant limit"
    end

    test "enabling group bookings disables the payments toggle and blocks the event",
         %{conn: conn, user: user} do
      meeting_type = insert_type(user)
      view = edit(conn, meeting_type)

      view
      |> element("input[phx-click='toggle_group_bookings']")
      |> render_click()

      assert has_element?(view, "input[phx-click='toggle_payment_required'][disabled]")
      assert render(view) =~ "Turn off group bookings to require payment."

      # A stale/forged click must not flip the toggle server-side. The
      # control is disabled, so we drive the component event directly
      # (mirroring the pattern in payments_settings_test.exs) rather than
      # clicking the disabled DOM element, which LiveViewTest itself refuses.
      view
      |> with_target("#meeting-type-form-wrapper-meeting-type-form-edit-#{meeting_type.id}")
      |> render_click("toggle_payment_required", %{})

      refute render(view) =~ "Price (USD)"
    end
  end

  describe "Losing charge capability while payment is required" do
    setup %{user: user} do
      previous_checker = Application.get_env(:tymeslot, :feature_access_checker)
      previous_flag = Application.get_env(:tymeslot, :meeting_payments_enabled)

      Application.put_env(
        :tymeslot,
        :feature_access_checker,
        Tymeslot.Features.DefaultAccessChecker
      )

      Application.put_env(:tymeslot, :meeting_payments_enabled, true)
      # No charge-ready Connect account: the host has lost (or never
      # finished setting up) charge capability, so the payments toggle
      # itself renders disabled and is unreachable from the UI.
      insert_type(user, payment_required: true, price_cents: 1000)

      on_exit(fn ->
        restore_env(:feature_access_checker, previous_checker)
        restore_env(:meeting_payments_enabled, previous_flag)
      end)

      :ok
    end

    test "the group bookings toggle stays reachable and clears payment_required",
         %{conn: conn, user: user} do
      meeting_type = Enum.find(MeetingTypes.get_all_meeting_types(user.id), & &1.payment_required)

      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

      view
      |> element("button[phx-click='edit_type'][phx-value-id='#{meeting_type.id}']")
      |> render_click()

      # The payments toggle is unreachable (charges not enabled), so unlike
      # the normal mutual-exclusion case the group toggle must not be
      # disabled too — otherwise there would be no way out.
      refute has_element?(view, "input[phx-click='toggle_group_bookings'][disabled]")

      view
      |> element("input[phx-click='toggle_group_bookings']")
      |> render_click()

      assert render(view) =~ "Participant limit"

      updated = reload_type(user, meeting_type.id)
      refute updated.payment_required
      assert updated.max_participants == 10
    end
  end

  # A group type's location is fixed in advance, which the "address arranged
  # after booking" default is not: one venue is.
  defp insert_type(user, attrs \\ []) do
    venue = insert(:venue, user: user)
    insert(:meeting_type, [user: user, locations: [in_person_location([venue])]] ++ attrs)
  end

  defp edit(conn, meeting_type) do
    {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

    view
    |> element("button[phx-click='edit_type'][phx-value-id='#{meeting_type.id}']")
    |> render_click()

    view
  end

  # A new type starts on an in-person location with no venue, which a group
  # type cannot offer; turn it into a written one.
  defp hold_at_fixed_location(view) do
    view
    |> element("[data-testid='location-row'] button[phx-click='edit_location']")
    |> render_click()

    view
    |> form("#location-editor-form", %{"location" => %{"kind" => "custom"}})
    |> render_change()

    view
    |> form("#location-editor-form", %{
      "location" => %{"kind" => "custom", "label" => "Main hall"}
    })
    |> render_submit()

    refute has_element?(view, "#location-editor-form")
    view
  end

  defp reload_type(user, id) do
    Enum.find(MeetingTypes.get_all_meeting_types(user.id), &(&1.id == id))
  end

  defp restore_env(key, nil), do: Application.delete_env(:tymeslot, key)
  defp restore_env(key, value), do: Application.put_env(:tymeslot, key, value)
end
