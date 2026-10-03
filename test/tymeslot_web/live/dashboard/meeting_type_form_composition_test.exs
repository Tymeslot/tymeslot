defmodule TymeslotWeb.Dashboard.MeetingTypeFormCompositionTest do
  @moduledoc """
  Composition tests for the meeting-type form's server-side validation
  seam: the point where the LiveComponent's UI state and the
  `MeetingTypes.update_meeting_type_from_form/3` validation chain meet.

  The existing coverage is:

    * `meeting_settings_test.exs` — happy-path create/edit/toggle/delete.
    * `meeting_type_form/validation_test.exs` — reminder validation
      unit tests (empty, negative, non-numeric, cap, unit whitelist).
    * `meeting_type_form/init_test.exs` — component initialisation.
    * `ScheduleSettingsComponent`'s `update_buffer_before_minutes` /
      `update_buffer_after_minutes` / `update_advance_booking_days`:
      exercised end-to-end in `availability/policy_card_test.exs`.

  What was missing: the **server wins when the UI state goes stale
  mid-flow**. Plan line 1856 calls this out for video integrations —
  the only scenario in Task 63's list that is both reachable through
  the UI and not already covered.

  Dropped from the plan with rationale:

    * `add_reminder` / `add_quick_reminder` / `remove_reminder` save
      persistence: covered by the auto-save tests in
      `meeting_settings_test.exs`. Cap + value rules pinned at the unit
      level in `validation_test.exs`.
    * `update_buffer_before_minutes` / `update_buffer_after_minutes` /
      `update_advance_booking_days`
      boundaries — already covered by `meeting_settings_test.exs`
      (preset + custom out-of-range cases).
    * `select_calendar_integration` → async refresh →
      `select_target_calendar` → save — requires stubbing the Google
      list-calendars round-trip through `start_async`, setting up
      the profile's primary calendar invariant, and carrying both
      selections through to persistence. The failure mode (one of
      three IDs missing) surfaces immediately in the happy-path
      `create_meeting_type_from_form` unit tests; a compostion test
      adds cost without new coverage.
    * `select_icon` / forged `meeting_type[icon]`: the form saves the
      icon from socket state, never from posted params, so a tampered
      icon cannot be injected from this test surface. The validation is pinned
      at the schema level (`MeetingTypeSchema.changeset/2`
      `validate_inclusion(:icon, @valid_icons)`) and the sanitiser
      layer (`Tymeslot.MeetingTypes.InputValidation`).
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :integration
  @moduletag :meeting_types
  @moduletag :live

  import Phoenix.LiveViewTest
  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Integrations.Video
  alias Tymeslot.MeetingTypes

  setup :setup_dashboard_user

  describe "auto-save: video integration deactivated mid-flow" do
    @tag :capture_log
    test "rejects the save when the selected video integration was turned off",
         %{conn: conn, user: user} do
      video =
        insert(:video_integration,
          user: user,
          provider: "mirotalk",
          name: "Team Room",
          is_active: true
        )

      meeting_type = insert(:meeting_type, user: user, name: "Strategy Call")

      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

      view
      |> element("[phx-click='edit_type'][phx-value-id='#{meeting_type.id}']")
      |> render_click()

      # Add a video location on the chosen integration. The editor's save
      # pushes the new list into the form component, which auto-saves it.
      view |> element("button[data-testid='add-location']") |> render_click()

      # Choosing the kind is what reveals the provider picker, so the change
      # has to land before the form carries a `video_integration_ids` at all.
      view
      |> form("#location-editor-form", %{"location" => %{"kind" => "video"}})
      |> render_change()

      view
      |> form("#location-editor-form", %{
        "location" => %{
          "kind" => "video",
          "label" => "Team Room",
          "video_integration_ids" => [to_string(video.id)]
        }
      })
      |> render_submit()

      # Organiser turns off the provider from another tab between the
      # click above and the change below.
      {:ok, _deactivated} =
        Video.update_integration(user.id, video.id, %{is_active: false})

      view
      |> element(~s|input[name="meeting_type[name]"]|)
      |> render_change(%{"meeting_type" => %{"name" => "Renamed Call"}})

      # The validation chain in `MeetingTypes.update_meeting_type_from_form/3`
      # must intercept `:invalid_video_integration`: the indicator reports
      # the failure and the rename never lands.
      assert has_element?(view, "[aria-live='polite']", "Couldn't save changes")
      assert MeetingTypes.get_meeting_type(meeting_type.id, user.id).name == "Strategy Call"
    end
  end
end
