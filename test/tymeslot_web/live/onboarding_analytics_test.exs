defmodule TymeslotWeb.OnboardingAnalyticsTest do
  @moduledoc """
  Verifies the onboarding funnel emits anonymous `onboarding_step_completed`
  analytics events on the reliable (non-redirecting) success paths, that each
  share action on the final step emits `booking_link_shared` with its channel,
  and that the payloads never carry user-identifying props.
  """

  use TymeslotWeb.LiveCase, async: false
  @moduletag :onboarding

  import Mox
  import Tymeslot.Factory
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

  describe "share step with a live booking page" do
    setup %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding_with_calendar(conn)
      view |> goto_choose_theme() |> advance_to_share_step()
      %{view: view}
    end

    test "records that the host saw the live variant", %{view: view} do
      assert_push_event view, "ts:analytics", %{
        name: "share_step_viewed",
        props: %{page_live: true}
      }

      refute has_element?(view, "#onboarding-page-offline-warning")
    end

    for {selector, channel} <- [
          {"button#onboarding-copy-booking-url", "copy"},
          {"a#onboarding-share-email", "email"},
          {"a#onboarding-share-whatsapp", "whatsapp"},
          {"a#onboarding-share-linkedin", "linkedin"}
        ] do
      test "the #{channel} action pushes a share event with its channel", %{view: view} do
        view |> element(unquote(selector)) |> render_click()

        assert_push_event view, "ts:analytics", %{
          name: "booking_link_shared",
          props: %{channel: unquote(channel)}
        }
      end
    end

    test "a channel the step does not offer is dropped", %{view: view} do
      render_click(view, "share_booking_link", %{"channel" => "user@example.com"})

      refute_push_event view, "ts:analytics", %{name: "booking_link_shared"}
    end

    test "share links carry the booking URL and open safely", %{view: view} do
      email = view |> element("a#onboarding-share-email") |> render()
      assert email =~ ~s(href="mailto:?subject=Book%20a%20time%20with%20me&amp;body=)
      assert email =~ "%2Fada"

      whatsapp = view |> element("a#onboarding-share-whatsapp") |> render()

      assert whatsapp =~
               ~s(href="https://wa.me/?text=You%20can%20book%20a%20time%20with%20me%20here%3A%20)

      assert whatsapp =~ ~s(rel="noopener noreferrer")
      assert whatsapp =~ ~s(target="_blank")

      linkedin = view |> element("a#onboarding-share-linkedin") |> render()
      assert linkedin =~ "https://www.linkedin.com/sharing/share-offsite/?url=http"
      assert linkedin =~ "%2Fada"
      assert linkedin =~ ~s(rel="noopener noreferrer")
    end
  end

  describe "share step without a connected calendar" do
    setup %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)
      view |> navigate_to_scheduling_steps() |> advance_to_share_step()
      %{view: view}
    end

    test "records that the host saw the offline variant", %{view: view} do
      assert_push_event view, "ts:analytics", %{
        name: "share_step_viewed",
        props: %{page_live: false}
      }
    end

    test "warns that the page is not live and greys out every share action", %{view: view} do
      assert has_element?(
               view,
               "#onboarding-page-offline-warning",
               "Your booking page isn't live yet"
             )

      assert has_element?(
               view,
               ".onboarding-step-description",
               "Your link is ready, but the page only goes live once a calendar is connected."
             )

      assert has_element?(view, "button#onboarding-copy-booking-url[disabled]")

      for channel <- ~w(email whatsapp linkedin) do
        assert has_element?(view, "button#onboarding-share-#{channel}[disabled]")
        refute has_element?(view, "a#onboarding-share-#{channel}")
      end

      # Finishing stays possible: the host can connect a calendar later.
      assert has_element?(view, "button[phx-click='next_step']", "Go to dashboard")
    end

    test "the warning takes the host back to the calendar step", %{view: view} do
      view |> element("#onboarding-return-to-calendar") |> render_click()

      assert has_element?(view, ".onboarding-step-title", "Connect your calendar")
      assert has_element?(view, ".onboarding-provider-cards")
    end

    test "skipping again from there leads straight back to the share step", %{view: view} do
      assert_push_event view, "ts:analytics", %{
        name: "onboarding_step_completed",
        props: %{step: "connect_calendar"}
      }

      assert_push_event view, "ts:analytics", %{
        name: "share_step_viewed",
        props: %{returned: false}
      }

      view |> element("#onboarding-return-to-calendar") |> render_click()
      view |> element(~s{button[phx-value-option="skip"]}) |> render_click()
      view |> element("button[phx-click='next_step']") |> render_click()
      render_click(view, "confirm_skip_calendar")

      assert has_element?(view, ".onboarding-step-title", "Share your booking page")
      assert has_element?(view, "#onboarding-page-offline-warning")

      assert_push_event view, "ts:analytics", %{
        name: "share_step_viewed",
        props: %{page_live: false, returned: true}
      }

      # The host already completed the calendar step once.
      refute_push_event view, "ts:analytics", %{
        name: "onboarding_step_completed",
        props: %{step: "connect_calendar"}
      }
    end
  end

  describe "share step opened directly by URL" do
    setup %{conn: conn} do
      {conn, user} = onboarding_conn(conn)
      insert(:calendar_integration, user: user)
      %{conn: conn}
    end

    # The disconnected render cannot tell yet whether the page is live, so it
    # must not show the offline variant that a live page then snaps away from.
    test "a live page never first renders as offline", %{conn: conn} do
      doc = conn |> get("/onboarding/ready") |> html_response(200) |> Floki.parse_document!()

      assert [_copy_button] = Floki.find(doc, "button#onboarding-copy-booking-url")
      assert Floki.find(doc, "#onboarding-page-offline-warning") == []
      refute Floki.text(doc) =~ "only goes live once a calendar is connected"

      {:ok, view, _html} = live(conn, "/onboarding/ready")
      assert has_element?(view, "button#onboarding-copy-booking-url:not([disabled])")
      refute has_element?(view, "#onboarding-page-offline-warning")
    end

    # The calendar provider sends a host who left the share step back here,
    # with the flag in the return path.
    test "connecting from the share step leads straight back to it, now live",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/onboarding/connect_calendar?return=share")

      view |> element("button[phx-click='next_step']") |> render_click()

      assert has_element?(view, ".onboarding-step-title", "Share your booking page")
      assert has_element?(view, "a#onboarding-share-email")

      assert_push_event view, "ts:analytics", %{
        name: "share_step_viewed",
        props: %{page_live: true, returned: true}
      }

      refute_push_event view, "ts:analytics", %{name: "onboarding_step_completed"}
    end

    # A host who skipped the calendar never saw the theme step, which only a
    # host with a calendar is shown.
    test "connecting from the share step, having skipped the calendar, shows the theme step first",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/onboarding/connect_calendar?return=theme")

      view |> element("button[phx-click='next_step']") |> render_click()
      assert has_element?(view, ".onboarding-step-title", "Choose your theme")

      view |> element("button[phx-click='next_step']") |> render_click()
      assert has_element?(view, ".onboarding-step-title", "Share your booking page")

      assert_push_event view, "ts:analytics", %{
        name: "share_step_viewed",
        props: %{returned: true}
      }
    end

    test "connecting without coming from the share step continues as usual",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/onboarding/connect_calendar")

      view |> element("button[phx-click='next_step']") |> render_click()

      refute has_element?(view, ".onboarding-step-title", "Share your booking page")

      assert_push_event view, "ts:analytics", %{
        name: "onboarding_step_completed",
        props: %{step: "connect_calendar"}
      }
    end

    test "reloading the step does not count another view", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/onboarding/ready")

      assert has_element?(view, "a#onboarding-share-email")
      refute_push_event view, "ts:analytics", %{name: "share_step_viewed"}
    end
  end

  # Clicks Continue until the share step, so each describe can reach it from
  # wherever its own setup leaves the wizard.
  defp advance_to_share_step(view, attempts_left \\ 6) do
    cond do
      has_element?(view, ".onboarding-step-title", "Share your booking page") ->
        view

      attempts_left == 0 ->
        flunk("never reached the share step")

      true ->
        view |> element("button[phx-click='next_step']") |> render_click()
        advance_to_share_step(view, attempts_left - 1)
    end
  end
end
