defmodule TymeslotWeb.Dashboard.OnboardingChecklistTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :components
  @moduletag :onboarding

  import Phoenix.LiveViewTest

  alias TymeslotWeb.Dashboard.OnboardingChecklist

  @no_integrations %{has_meeting_types: true, has_calendar: false, has_video: false}
  @all_integrations %{has_meeting_types: true, has_calendar: true, has_video: true}

  defp user(attrs \\ %{}) do
    Map.merge(%{dashboard_setup_done_items: [], dashboard_setup_dismissed_at: nil}, attrs)
  end

  defp profile(attrs \\ %{}) do
    Map.merge(%{username: "alice", user_id: 1}, attrs)
  end

  describe "visible?/2" do
    test "is visible while a setup item is outstanding and the widget is open" do
      assert OnboardingChecklist.visible?(user(), @no_integrations)
    end

    test "is hidden once the host has dismissed the widget" do
      refute OnboardingChecklist.visible?(
               user(%{dashboard_setup_dismissed_at: DateTime.utc_now(:second)}),
               @no_integrations
             )
    end

    test "is hidden once every item is done (auto-completed or ticked by hand)" do
      done = user(%{dashboard_setup_done_items: ~w(theme meeting_types share)})
      refute OnboardingChecklist.visible?(done, @all_integrations)
    end
  end

  describe "toggleable_item?/1" do
    test "allows manual recommendations but never deterministic provider items" do
      assert OnboardingChecklist.toggleable_item?("theme")
      assert OnboardingChecklist.toggleable_item?("share")
      assert OnboardingChecklist.toggleable_item?("meeting_types")

      # Connecting a calendar/video provider is deterministic — not hand-tickable.
      refute OnboardingChecklist.toggleable_item?("calendar")
      refute OnboardingChecklist.toggleable_item?("video")
      refute OnboardingChecklist.toggleable_item?("bogus")
    end
  end

  describe "onboarding_checklist/1" do
    test "renders every item with a uniform, fixed-width call-to-action and controls" do
      html =
        render_component(&OnboardingChecklist.onboarding_checklist/1,
          integration_status: @no_integrations,
          current_user: user(),
          profile: profile()
        )

      assert html =~ "Finish setting up"
      assert html =~ "0/5"

      # Every item present.
      assert html =~ "Connect a calendar"
      assert html =~ "Add a video provider"
      assert html =~ "Customise your theme"
      assert html =~ "Review your meeting types"
      assert html =~ "Share your booking page"

      # CTAs share one fixed width so they line up.
      assert html =~ "w-32"

      # Manual recommendations get a checkbox tick; the global dismiss is present.
      assert html =~ ~s(phx-click="onboarding:toggle")
      assert html =~ ~s(role="checkbox")
      assert html =~ ~s(phx-value-id="theme")
      assert html =~ ~s(phx-click="onboarding:dismiss")

      # Deterministic provider items are NOT hand-tickable.
      refute html =~ ~s(phx-value-id="calendar")
      refute html =~ ~s(phx-value-id="video")
    end

    test "auto-completes an item backed by real state and drops its call-to-action" do
      html =
        render_component(&OnboardingChecklist.onboarding_checklist/1,
          integration_status: %{@no_integrations | has_calendar: true},
          current_user: user(),
          profile: profile()
        )

      assert html =~ "1/5"
      # The connected-calendar item shows as done and no longer links out.
      refute html =~ ~s(href="/dashboard/integrations?tab=calendars")
      # A manual item is still actionable.
      assert html =~ ~s(href="/dashboard/integrations?tab=video")
    end

    test "greys out an item the host ticked off by hand" do
      html =
        render_component(&OnboardingChecklist.onboarding_checklist/1,
          integration_status: @no_integrations,
          current_user: user(%{dashboard_setup_done_items: ["theme"]}),
          profile: profile()
        )

      assert html =~ "1/5"
      # Ticked item no longer links to the theme page (it greys out)...
      refute html =~ ~s(href="/dashboard/theme")
      # ...while an untouched item still does.
      assert html =~ ~s(href="/dashboard/meeting-settings")
    end

    test "share item copies the public booking link when the page is live" do
      html =
        render_component(&OnboardingChecklist.onboarding_checklist/1,
          # username set + a connected calendar → booking page is shareable.
          integration_status: @all_integrations,
          current_user: user(),
          profile: profile(%{username: "alice"})
        )

      assert html =~ ~s(phx-hook="CopyOnClick")
      assert html =~ ~s(data-copy-text=)
      assert html =~ "/alice"
      assert html =~ "Copy link"
      # It copies rather than routing to the embed page.
      refute html =~ ~s(href="/dashboard/embed")
    end

    test "share item is greyed out with the sidebar's tooltip when prerequisites are unmet" do
      html =
        render_component(&OnboardingChecklist.onboarding_checklist/1,
          # No connected calendar → same gate the dashboard sidebar uses.
          integration_status: @no_integrations,
          current_user: user(),
          profile: profile(%{username: "alice"})
        )

      refute html =~ ~s(phx-hook="CopyOnClick")
      assert html =~ "Connect a calendar in Calendar settings to enable this feature"
    end
  end
end
