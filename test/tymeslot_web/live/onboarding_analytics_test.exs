defmodule TymeslotWeb.OnboardingAnalyticsTest do
  @moduledoc """
  Verifies the onboarding funnel emits anonymous `onboarding_step_completed`
  analytics events on the reliable (non-redirecting) success paths, that each
  share action on the final step emits `booking_link_shared` with its channel,
  and that the payloads never carry user-identifying props.
  """

  use TymeslotWeb.LiveCase, async: false
  @moduletag :onboarding

  import Ecto.Query
  import Mox
  import Tymeslot.Factory
  import TymeslotWeb.OnboardingTestHelpers

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Repo

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    {:ok, conn: setup_onboarding_session(tags.conn)}
  end

  describe "onboarding analytics events" do
    test "saving the link pushes an anonymous step-completed event", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)

      navigate_to_calendar_step(view)

      assert_push_event view, "ts:analytics", %{
        name: "onboarding_step_completed",
        props: %{step: "profile"}
      }
    end

    test "each later step pushes its own step-completed event", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding_with_calendar(conn)

      navigate_to_ready_step(view)

      for step <- ~w(profile connect_calendar meeting choose_theme) do
        assert_push_event view, "ts:analytics", %{
          name: "onboarding_step_completed",
          props: %{step: ^step}
        }
      end
    end

    test "step events never carry user-identifying props", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)

      navigate_to_calendar_step(view)

      assert_push_event view, "ts:analytics", %{props: props}
      assert props == %{step: "profile"}
    end
  end

  describe "share step with a live booking page" do
    setup %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding_with_calendar(conn)
      navigate_to_ready_step(view)
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
      assert email =~ "%2Ftestuser"

      whatsapp = view |> element("a#onboarding-share-whatsapp") |> render()

      assert whatsapp =~
               ~s(href="https://wa.me/?text=You%20can%20book%20a%20time%20with%20me%20here%3A%20)

      assert whatsapp =~ ~s(rel="noopener noreferrer")
      assert whatsapp =~ ~s(target="_blank")

      linkedin = view |> element("a#onboarding-share-linkedin") |> render()
      assert linkedin =~ "https://www.linkedin.com/sharing/share-offsite/?url=http"
      assert linkedin =~ "%2Ftestuser"
      assert linkedin =~ ~s(rel="noopener noreferrer")
    end
  end

  # A calendar that stops being bookable during onboarding (removed, or
  # deactivated elsewhere) leaves the host on a share step whose page refuses
  # visitors.
  describe "share step after the calendar stopped being bookable" do
    setup %{conn: conn} do
      {:ok, view, _html, user} = setup_onboarding_with_calendar(conn)
      navigate_to_theme_step(view)

      Repo.update_all(
        from(c in CalendarIntegrationSchema, where: c.user_id == ^user.id),
        set: [is_active: false]
      )

      click_continue(view)
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

      assert has_element?(view, ".onboarding-step-title", "Your calendar")
      assert has_element?(view, ".onboarding-provider-cards")
    end
  end

  describe "share step opened directly by URL" do
    setup %{conn: conn} do
      {conn, user} = onboarding_conn(conn)
      insert(:profile, user: user, username: "ada#{System.unique_integer([:positive])}")
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

      assert has_element?(view, ".onboarding-step-title", "You're live")
      assert has_element?(view, "a#onboarding-share-email")

      assert_push_event view, "ts:analytics", %{
        name: "share_step_viewed",
        props: %{page_live: true, returned: true}
      }

      refute_push_event view, "ts:analytics", %{name: "onboarding_step_completed"}
    end

    # Before the calendar became required, a host who had skipped it was sent
    # back with `return=theme`. Such a host has seen neither the meeting nor
    # the theme step, so the flow simply continues.
    test "a return path from the old flow continues to the meeting step", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/onboarding/connect_calendar?return=theme")

      click_continue(view)

      assert has_element?(view, ".onboarding-step-title", "Your meeting")
    end

    test "connecting without coming from the share step continues as usual",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/onboarding/connect_calendar")

      view |> element("button[phx-click='next_step']") |> render_click()

      assert has_element?(view, ".onboarding-step-title", "Your meeting")

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
end
