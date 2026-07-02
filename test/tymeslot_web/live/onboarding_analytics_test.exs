defmodule TymeslotWeb.OnboardingAnalyticsTest do
  @moduledoc """
  Verifies the onboarding funnel emits anonymous `onboarding_step_completed`
  analytics events on the reliable (non-redirecting) success paths, and that
  the payloads never carry user-identifying props.
  """

  use TymeslotWeb.LiveCase, async: false
  @moduletag :onboarding

  import Mox
  import TymeslotWeb.OnboardingTestHelpers

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    {:ok, conn: setup_onboarding_session(tags.conn)}
  end

  describe "onboarding analytics events" do
    test "advancing from the welcome step pushes an anonymous step-completed event",
         %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)

      view |> element("button[phx-click='next_step']") |> render_click()

      assert_push_event view, "ts:analytics", %{
        name: "onboarding_step_completed",
        props: %{step: "welcome"}
      }
    end

    test "skipping the calendar step pushes a skipped step-completed event", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)

      # welcome -> profile
      view |> element("button[phx-click='next_step']") |> render_click()

      # fill the profile form and advance to connect_calendar
      view
      |> form("form#profile-form", %{
        "full_name" => "Test User",
        "username" => "testuser#{System.unique_integer([:positive])}"
      })
      |> render_change()

      view |> element("button[phx-click='next_step']") |> render_click()

      # skip the calendar step: select "Not right now", Continue, then confirm
      # the nudge modal — the skipped event fires only once the user confirms.
      view |> element(~s{button[phx-value-option="skip"]}) |> render_click()
      view |> element("button[phx-click='next_step']") |> render_click()
      render_click(view, "confirm_skip_calendar")

      assert_push_event view, "ts:analytics", %{
        name: "onboarding_step_completed",
        props: %{step: "connect_calendar", skipped: true}
      }
    end

    test "step events never carry user-identifying props", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)

      view |> element("button[phx-click='next_step']") |> render_click()

      assert_push_event view, "ts:analytics", %{props: props}
      refute Map.has_key?(props, :user_id)
      refute Map.has_key?(props, :username)
      refute Map.has_key?(props, :email)
    end
  end
end
