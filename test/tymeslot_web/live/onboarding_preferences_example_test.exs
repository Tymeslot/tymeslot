defmodule TymeslotWeb.OnboardingPreferencesExampleTest do
  @moduledoc """
  The worked-example sentence on each scheduling-preference step reflects the
  value the organiser has chosen, updating live as they click presets — so the
  explanation stays accurate rather than quoting a fixed 15-min / 2-week / 3-hour
  example regardless of the actual setting.
  """

  use TymeslotWeb.LiveCase, async: false
  @moduletag :onboarding

  import Phoenix.LiveViewTest
  import TymeslotWeb.OnboardingTestHelpers

  setup tags do
    {:ok, conn: setup_onboarding_session(tags.conn)}
  end

  describe "buffer time example" do
    test "reflects the chosen buffer and the computed next start time", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)
      view = navigate_to_scheduling_steps(view)

      html = view |> element("button[phx-value-buffer_minutes='60']") |> render_click()
      assert html =~ "ends at 02:00 PM"
      assert html =~ "your buffer is 60 min"
      assert html =~ "starts at 03:00 PM"

      html = view |> element("button[phx-value-buffer_minutes='30']") |> render_click()
      assert html =~ "your buffer is 30 min"
      assert html =~ "starts at 02:30 PM"
    end

    test "uses a no-buffer phrasing for zero", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)
      view = navigate_to_scheduling_steps(view)

      html = view |> element("button[phx-value-buffer_minutes='0']") |> render_click()
      assert html =~ "as soon as a meeting ends"
      refute html =~ "your buffer is 0 min"
    end
  end

  describe "booking window example" do
    test "reflects the chosen window", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)
      view = navigate_to_booking_window_step(view)

      html = view |> element("button[phx-value-advance_booking_days='30']") |> render_click()
      assert html =~ "up to 1 month ahead"

      html = view |> element("button[phx-value-advance_booking_days='90']") |> render_click()
      assert html =~ "up to 3 months ahead"
    end
  end

  describe "minimum notice example" do
    test "reflects the chosen notice", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)
      view = navigate_to_minimum_notice_step(view)

      html = view |> element("button[phx-value-min_advance_hours='24']") |> render_click()
      assert html =~ "With 1 day of notice"

      html = view |> element("button[phx-value-min_advance_hours='0']") |> render_click()
      assert html =~ "no minimum notice"
    end
  end
end
