defmodule TymeslotWeb.Dashboard.MeetingTypeFormCompositionTest do
  @moduledoc """
  Composition tests for the meeting-type form's server-side validation
  seam — the point where the LiveComponent's UI state, the submitted
  form params, and the `MeetingTypes.create_meeting_type_from_form/3`
  validation chain meet.

  The existing coverage is:

    * `meeting_settings_test.exs` — happy-path create/edit/toggle/delete.
    * `meeting_type_form/validation_test.exs` — reminder validation
      unit tests (empty, negative, non-numeric, cap, unit whitelist).
    * `meeting_type_form/init_test.exs` — component initialisation.
    * `scheduling_settings_component`'s `update_buffer_minutes` /
      `update_advance_booking_days` — exercised end-to-end in
      `meeting_settings_test.exs:209–251`.

  What was missing: the **server wins when the UI state goes stale
  mid-flow**. Plan line 1856 calls this out for video integrations —
  the only scenario in Task 63's list that is both reachable through
  the UI and not already covered.

  Dropped from the plan with rationale:

    * `add_reminder` / `add_quick_reminder` / `remove_reminder` save
      persistence — covered end-to-end by the happy-path create test
      in `meeting_settings_test.exs:42` which round-trips through the
      form's hidden `reminder_config` inputs. Cap + value rules pinned
      at the unit level in `validation_test.exs`.
    * `update_buffer_minutes` / `update_advance_booking_days`
      boundaries — already covered by `meeting_settings_test.exs`
      (preset + custom out-of-range cases).
    * `toggle_meeting_mode` invalid mode — the handler stores any
      mode string into socket state; the only downstream effect is
      `allow_video` derivation, exercised by the video-integration
      test below.
    * `select_calendar_integration` → async refresh →
      `select_target_calendar` → save — requires stubbing the Google
      list-calendars round-trip through `start_async`, setting up
      the profile's primary calendar invariant, and carrying both
      selections through to persistence. The failure mode (one of
      three IDs missing) surfaces immediately in the happy-path
      `create_meeting_type_from_form` unit tests; a compostion test
      adds cost without new coverage.
    * `select_icon` / forged `meeting_type[icon]` — Phoenix's
      `render_submit/1` enforces that hidden inputs match the
      server-rendered values, so a client-side tampered icon cannot
      be injected from this test surface. The validation is pinned
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

  describe "save_meeting_type — video integration deactivated mid-flow" do
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

      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

      view |> element("button", "Add Meeting Type") |> render_click()
      assert render(view) =~ "Create Meeting Type"

      # Remove the default reminder — Phoenix's re-encoder mangles the
      # hidden `reminder_config[][value]/[][unit]` inputs. The create
      # test in `meeting_settings_test.exs` uses the same workaround.
      view |> element("button[aria-label='Remove reminder']") |> render_click()

      # Switch to video mode so the hidden `meeting_type[meeting_mode]`
      # input renders as "video" for the subsequent submit.
      view
      |> element("button[phx-click*='toggle_meeting_mode'][phx-click*='video']")
      |> render_click()

      # Pick the video integration. The click fires
      # `select_video_integration` on the form component, which sets
      # `selected_video_integration_id` in the socket so the hidden
      # input will render with the integration's id.
      view
      |> element("button[phx-click*='select_video_integration'][phx-click*='#{video.id}']")
      |> render_click()

      # Organiser turns off the provider from another tab between the
      # click above and the save below.
      {:ok, _deactivated} =
        Video.update_integration(user.id, video.id, %{is_active: false})

      view
      |> form("form[phx-submit='save_meeting_type']", %{
        "meeting_type" => %{"name" => "Strategy Call", "duration" => "45"}
      })
      |> render_submit()

      html = render(view)

      # The validation chain in `MeetingTypes.create_meeting_type_from_form/3`
      # must intercept and surface `:invalid_video_integration`. The
      # happy-path confirmation must NOT show, and no row may land.
      refute html =~ "Meeting type created"

      # Default meeting types are auto-provisioned on first visit, so
      # the list is never empty; instead assert the specific name we
      # tried to save never landed.
      types = MeetingTypes.get_all_meeting_types(user.id)
      refute Enum.any?(types, &(&1.name == "Strategy Call"))
    end
  end
end
