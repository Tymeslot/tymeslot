defmodule TymeslotWeb.Dashboard.MeetingSettingsAutosaveRateLimitLiveTest do
  @moduledoc """
  Tests that the meeting type editor correctly handles autosave rate-limit
  exhaustion at the UI level. Runs with `async: false` because rate-limit state
  lives in a shared ETS table that other tests clear in their setup.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :meeting_types
  @moduletag :live
  @moduletag :security

  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.MeetingTypes
  alias Tymeslot.Security.RateLimiter

  setup do
    RateLimiter.clear_all()
    :ok
  end

  setup :setup_dashboard_user

  describe "Autosave rate-limit feedback" do
    test "shows throttled indicator and does not persist when the autosave bucket is exhausted",
         %{conn: conn, user: user} do
      meeting_type = insert(:meeting_type, user: user, duration_minutes: 30, name: "Rate Me")

      # Pre-exhaust the autosave rate-limit bucket for this user outside the
      # LiveView. The bucket is keyed "meeting_type_autosave:#{user_id}" with a
      # limit of 600 per 30 minutes (1 800 000 ms).
      for _i <- 1..600 do
        assert :ok = RateLimiter.check_meeting_type_autosave_rate_limit(user.id)
      end

      # The 601st call must be denied — confirming the bucket is exhausted.
      assert {:error, :rate_limited, _message} =
               RateLimiter.check_meeting_type_autosave_rate_limit(user.id)

      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

      view
      |> element("[phx-click='edit_type'][phx-value-id='#{meeting_type.id}']")
      |> render_click()

      # Trigger a change that would normally persist (valid duration change).
      html =
        view
        |> element(~s|input[name="meeting_type[duration]"]|)
        |> render_change(%{"meeting_type" => %{"duration" => "45"}})

      # The new value must NOT have been written to the database.
      assert MeetingTypes.get_meeting_type(meeting_type.id, user.id).duration_minutes == 30

      # The editor must show the throttled indicator copy.
      assert html =~ "Too many changes - saving shortly…"
    end
  end
end
