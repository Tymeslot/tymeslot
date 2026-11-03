defmodule TymeslotWeb.OnboardingAnalyticsTest do
  @moduledoc """
  The setup wizard's funnel, as analytics sees it: every step entry pushes
  `onboarding_step_viewed`, every step left forward `onboarding_step_completed`,
  the calendar reveal reports how its read went (`calendar_reveal_loaded`),
  each keep action on the live step pushes `booking_link_kept` with its
  method, and "Try booking yourself" pushes `guest_preview_opened`. No
  payload carries anything that identifies the host, nor the name they type
  for the first person they send their link to.
  """

  use TymeslotWeb.LiveCase, async: false
  @moduletag :onboarding

  import Ecto.Query
  import Mox
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory
  import TymeslotWeb.OnboardingTestHelpers

  alias Tymeslot.CalendarMock
  alias Tymeslot.ConfigTestHelpers
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Repo

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    {:ok, conn: setup_onboarding_session(tags.conn)}
  end

  # Every analytics payload pushed to the view so far, in order.
  defp analytics_pushed(view) do
    _html = render(view)
    drain_analytics([])
  end

  defp drain_analytics(acc) do
    receive do
      {_ref, {:push_event, "ts:analytics", payload}} -> drain_analytics([payload | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # A host with a bookable calendar and a profile, so the calendar step
  # reads their week as soon as it is shown.
  defp reveal_host(conn) do
    user = insert(:user, onboarding_completed_at: nil)
    insert(:profile, user: user, username: "reveal#{System.unique_integer([:positive])}")
    insert(:calendar_integration, user: user)
    log_in_user(conn, user)
  end

  describe "step views" do
    test "viewing a step pushes onboarding_step_viewed", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)

      # Landing on the wizard is a view of the step it resumes at.
      assert_push_event view, "ts:analytics", %{
        name: "onboarding_step_viewed",
        props: %{step: "profile"}
      }

      navigate_to_calendar_step(view)

      assert_push_event view, "ts:analytics", %{
        name: "onboarding_step_viewed",
        props: %{step: "connect_calendar"}
      }

      # Going back is a view of the step returned to.
      view |> element("button[phx-click='previous_step']") |> render_click()

      assert_push_event view, "ts:analytics", %{
        name: "onboarding_step_viewed",
        props: %{step: "profile"}
      }
    end

    test "resuming at a step by its address pushes its view", %{conn: conn} do
      {conn, user} = onboarding_conn(conn)
      insert(:profile, user: user, username: "resume#{System.unique_integer([:positive])}")
      insert(:calendar_integration, user: user)

      {:ok, view, _html} = live(conn, "/onboarding/meeting")

      assert_push_event view, "ts:analytics", %{
        name: "onboarding_step_viewed",
        props: %{step: "meeting"}
      }
    end

    test "every step of the walk to the live step is viewed once", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding_with_calendar(conn)
      navigate_to_ready_step(view)

      viewed =
        for %{name: "onboarding_step_viewed", props: %{step: step}} <- analytics_pushed(view),
            do: step

      assert viewed == ~w(profile connect_calendar meeting choose_theme ready)
    end
  end

  describe "calendar reveal" do
    test "a read that answers pushes calendar_reveal_loaded ok", %{conn: conn} do
      stub_free_calendar()
      {:ok, view, _html} = live(reveal_host(conn), "/onboarding/connect_calendar")
      render_async(view)

      assert_push_event view, "ts:analytics", %{
        name: "calendar_reveal_loaded",
        props: %{result: "ok"}
      }
    end

    test "a failed reveal pushes calendar_reveal_loaded failed", %{conn: conn} do
      stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, _from, _to ->
        {:error, :timeout}
      end)

      {:ok, view, _html} = live(reveal_host(conn), "/onboarding/connect_calendar")
      render_async(view)

      assert_push_event view, "ts:analytics", %{
        name: "calendar_reveal_loaded",
        props: %{result: "failed"}
      }
    end

    test "a read outlasting the timer reports slow, and nothing when it lands", %{conn: conn} do
      ConfigTestHelpers.setup_config(:tymeslot, :onboarding_week_slow_after_ms, 0)

      test_pid = self()

      stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, _from, _to ->
        send(test_pid, {:reading, self()})

        receive do
          :answer -> {:ok, []}
        end
      end)

      {:ok, view, _html} = live(reveal_host(conn), "/onboarding/connect_calendar")
      assert_receive {:reading, reader}

      assert_push_event view, "ts:analytics", %{
        name: "calendar_reveal_loaded",
        props: %{result: "slow"}
      }

      send(reader, :answer)
      render_async(view)

      assert has_element?(view, ~s([data-week-state="ready"]))
      refute Enum.any?(analytics_pushed(view), &(&1.name == "calendar_reveal_loaded"))
    end
  end

  describe "step completions" do
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
      {:ok, view, _html, user} = setup_onboarding_with_calendar(conn)
      navigate_to_ready_step(view)
      %{view: view, user: user}
    end

    test "records that the host saw the live variant", %{view: view} do
      assert_push_event view, "ts:analytics", %{
        name: "share_step_viewed",
        props: %{page_live: true}
      }

      refute has_element?(view, "#onboarding-page-offline-warning")
    end

    for {selector, method} <- [
          {"#onboarding-keep-copy", "copy"},
          {"#onboarding-keep-signature", "signature"},
          {"#onboarding-keep-email", "email_me"},
          {"#onboarding-copy-message", "first_person"}
        ] do
      test "a keep by #{method} pushes booking_link_kept with the method", %{view: view} do
        view |> element(unquote(selector)) |> render_click()

        assert_push_event view, "ts:analytics", %{
          name: "booking_link_kept",
          props: %{method: unquote(method)}
        }

        # A keep is not a share from the dashboard.
        refute Enum.any?(analytics_pushed(view), &(&1.name == "booking_link_shared"))
      end
    end

    test "a keep by the phone handoff pushes booking_link_kept phone", %{view: view} do
      send(view.pid, {:onboarding, :preview_opened})

      assert_push_event view, "ts:analytics", %{
        name: "booking_link_kept",
        props: %{method: "phone"}
      }
    end

    test "a method the step does not offer is dropped", %{view: view} do
      render_hook(view, "keep_link", %{"method" => "user@example.com"})

      refute_push_event view, "ts:analytics", %{name: "booking_link_kept"}
    end

    test "trying the page on a desktop pushes guest_preview_opened", %{view: view} do
      view |> element("#onboarding-try-booking") |> render_click()

      assert_push_event view, "ts:analytics", %{name: "guest_preview_opened", props: props}
      assert props == %{}
    end

    test "trying the page on a phone pushes guest_preview_opened and expands it",
         %{view: view} do
      refute has_element?(view, "#onboarding-stage-preview-iframe")

      view |> element("#onboarding-try-booking-phone") |> render_click()

      assert_push_event view, "ts:analytics", %{name: "guest_preview_opened"}
      assert has_element?(view, "#onboarding-stage-preview-iframe")
    end

    test "props carry no PII", %{view: view, user: user} do
      name = "Ada Lovelace"
      render_hook(view, "first_person_name", %{"name" => name})
      view |> element("#onboarding-copy-message") |> render_click()
      view |> element("#onboarding-try-booking") |> render_click()

      pushed = analytics_pushed(view)
      assert Enum.any?(pushed, &(&1.name == "booking_link_kept"))

      user = Repo.reload!(user)
      identifying = [name, "Ada", "Lovelace", user.email, to_string(user.id)]

      leaks =
        for %{name: event, props: props} <- pushed,
            {key, value} <- props,
            text = to_string(value),
            Enum.any?(identifying, &String.contains?(text, &1)),
            do: {event, key}

      assert leaks == []
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
      %{view: view, user: user}
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

      for id <- ~w(send-link keep-email keep-copy keep-signature keep-phone) do
        assert has_element?(view, "button#onboarding-#{id}[disabled]")
      end

      # Finishing stays possible: the host can connect a calendar later.
      assert has_element?(view, "#onboarding-finish[phx-click='next_step']", "Go to dashboard")
      refute has_element?(view, "#onboarding-finish[aria-disabled]")
    end

    test "finishing without a keep completes onboarding", %{view: view, user: user} do
      view |> element("#onboarding-finish") |> render_click()

      assert_redirect(view, "/dashboard")
      assert %DateTime{} = Repo.reload!(user).onboarding_completed_at
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

      assert [_copy_button] = Floki.find(doc, "button#onboarding-keep-copy")
      assert Floki.find(doc, "#onboarding-page-offline-warning") == []
      refute Floki.text(doc) =~ "only goes live once a calendar is connected"

      {:ok, view, _html} = live(conn, "/onboarding/ready")
      assert has_element?(view, "button#onboarding-keep-copy:not([disabled])")
      refute has_element?(view, "#onboarding-page-offline-warning")
    end

    # The calendar provider sends a host who left the share step back here,
    # with the flag in the return path.
    test "connecting from the share step leads straight back to it, now live",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/onboarding/connect_calendar?return=share")

      view |> element("button[phx-click='next_step']") |> render_click()

      assert has_element?(view, ".onboarding-step-title", "You're live")
      assert has_element?(view, "button#onboarding-keep-email:not([disabled])")

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

      assert has_element?(view, "button#onboarding-keep-email:not([disabled])")
      refute_push_event view, "ts:analytics", %{name: "share_step_viewed"}
    end
  end
end
