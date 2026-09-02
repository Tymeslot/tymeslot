defmodule TymeslotWeb.Dashboard.MeetingTypeFormGroupBookingsTest do
  @moduledoc """
  LiveView coverage for the meeting-type form's Group bookings section —
  the user journey where an organiser lets multiple people book the same
  slot and sets the participant limit.

  Edit mode auto-saves every change; create mode serialises the toggle and
  limit through hidden inputs. Group bookings and payments are mutually
  exclusive (covered in the dedicated describe below).
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
      meeting_type = insert(:meeting_type, user: user, name: "Team Demo")

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
      meeting_type = insert(:meeting_type, user: user, max_participants: 8)

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

    test "a limit above 999 shows an inline error and does not persist",
         %{conn: conn, user: user} do
      meeting_type = insert(:meeting_type, user: user)

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
      meeting_type = insert(:meeting_type, user: user, max_participants: 10)

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
    test "the hidden fields persist the limit on submit", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")
      view |> element("button", "Add Meeting Type") |> render_click()

      # Remove the default reminder so the hidden reminder inputs do not
      # break Plug.Conn.Query re-encoding on submit (same workaround the
      # payments create test uses).
      view |> element("button[aria-label='Remove reminder']") |> render_click()

      view
      |> element("input[phx-click='toggle_group_bookings']")
      |> render_click()

      view
      |> element("input[phx-change='change_max_participants']")
      |> render_change(%{"meeting_type" => %{"max_participants_input" => "12"}})

      view
      |> form("form[phx-submit='save_meeting_type']", %{
        "meeting_type" => %{
          "name" => "Group Workshop",
          "duration" => "60"
        }
      })
      |> render_submit()

      assert render(view) =~ "Meeting type created"

      created =
        Enum.find(
          MeetingTypes.get_all_meeting_types(user.id),
          &(&1.name == "Group Workshop")
        )

      assert created.max_participants == 12
    end

    test "an invalid pending limit disables the submit button", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")
      view |> element("button", "Add Meeting Type") |> render_click()

      view
      |> element("input[phx-click='toggle_group_bookings']")
      |> render_click()

      refute has_element?(view, "button[type='submit'][disabled]")

      view
      |> element("input[phx-change='change_max_participants']")
      |> render_change(%{"meeting_type" => %{"max_participants_input" => "1"}})

      assert render(view) =~ "Participant limit must be at least 2"
      assert has_element?(view, "button[type='submit'][disabled]")
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

    test "requiring payment disables the group toggle and blocks the event", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")
      view |> element("button", "Add Meeting Type") |> render_click()

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
      |> with_target("#meeting-type-form-wrapper-meeting-type-form-new")
      |> render_click("toggle_group_bookings", %{})

      refute render(view) =~ "Participant limit"
    end

    test "enabling group bookings disables the payments toggle and blocks the event",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")
      view |> element("button", "Add Meeting Type") |> render_click()

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
      |> with_target("#meeting-type-form-wrapper-meeting-type-form-new")
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
      insert(:meeting_type, user: user, payment_required: true, price_cents: 1000)

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

  defp reload_type(user, id) do
    Enum.find(MeetingTypes.get_all_meeting_types(user.id), &(&1.id == id))
  end

  defp restore_env(key, nil), do: Application.delete_env(:tymeslot, key)
  defp restore_env(key, value), do: Application.put_env(:tymeslot, key, value)
end
