defmodule TymeslotWeb.Dashboard.PollsHostInputTest do
  @moduledoc """
  What the poll dashboard does with a host's profile and with parameters the
  forms never send: the host's timezone in the picker, translated editor
  errors, and forged events that must be ignored rather than crash the page.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :polls
  @moduletag :live

  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Polls
  alias Tymeslot.TestMocks

  setup %{conn: conn} do
    TestMocks.setup_calendar_mocks(events: [])

    Mox.stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _id, _from, _to ->
      {:ok, []}
    end)

    Gettext.put_locale(TymeslotWeb.Gettext, "en")
    %{conn: conn}
  end

  defp host(attrs \\ [], profile_attrs \\ []) do
    user = insert(:user, [onboarding_completed_at: DateTime.utc_now()] ++ attrs)
    profile = insert(:profile, [user: user] ++ profile_attrs)
    %{user: user, profile: profile}
  end

  defp log_in(conn, user) do
    conn |> init_test_session(%{}) |> fetch_session() |> log_in_user(user)
  end

  defp select_poll(view, poll) do
    view
    |> element("button[phx-click='select_poll'][phx-value-id='#{poll.id}']")
    |> render_click()
  end

  describe "timezone picker" do
    test "offers and keeps a host's zone that the list does not carry", %{conn: conn} do
      %{user: user} = host([], timezone: "America/Detroit")

      {:ok, view, _html} = live(log_in(conn, user), ~p"/dashboard/polls")
      view |> element("button", "New poll") |> render_click()

      assert has_element?(
               view,
               "select[name='poll[timezone]'] option[selected][value='America/Detroit']"
             )

      view |> element("button", "Add time") |> render_click()

      date = Date.utc_today() |> Date.add(7) |> Date.to_iso8601()

      view
      |> form("form[phx-submit='create_poll']", %{
        "poll" => %{
          "title" => "Detroit sync",
          "duration" => "30",
          "slots" => %{"0" => "#{date}T09:00"}
        }
      })
      |> render_submit()

      assert [%{timezone: "America/Detroit"}] = Polls.list_polls(user.id)
    end
  end

  describe "create form errors" do
    test "a deadline that has passed is refused on the deadline field", %{conn: conn} do
      %{user: user} = host([], timezone: "Etc/UTC")

      {:ok, view, _html} = live(log_in(conn, user), ~p"/dashboard/polls")
      view |> element("button", "New poll") |> render_click()
      view |> element("button", "Add time") |> render_click()

      date = Date.utc_today() |> Date.add(7) |> Date.to_iso8601()
      yesterday = Date.utc_today() |> Date.add(-1) |> Date.to_iso8601()

      html =
        view
        |> form("form[phx-submit='create_poll']", %{
          "poll" => %{
            "title" => "Late poll",
            "duration" => "30",
            "timezone" => "Etc/UTC",
            "deadline" => "#{yesterday}T09:00",
            "slots" => %{"0" => "#{date}T09:00"}
          }
        })
        |> render_submit()

      assert html =~ "The deadline must be in the future"
      assert has_element?(view, "input[name='poll[deadline]'][aria-invalid='true']")
      assert Polls.list_polls(user.id) == []
    end
  end

  describe "editor errors" do
    test "are shown in the host's language", %{conn: conn} do
      %{user: user} = host(locale: "de")
      poll = insert(:poll, user: user, status: :open, meeting_type_id: nil)
      insert(:poll_time_slot, poll: poll)

      {:ok, view, _html} = live(log_in(conn, user), ~p"/dashboard/polls")
      select_poll(view, poll)
      view |> element("[data-testid='poll-edit-details']") |> render_click()

      view
      |> form("[data-testid='poll-details-form']", %{"poll" => %{"title" => ""}})
      |> render_submit()

      assert has_element?(view, "[data-testid='poll-details-form']", "darf nicht leer sein")
      refute has_element?(view, "[data-testid='poll-details-form']", "can't be blank")
    end
  end

  describe "forged events" do
    test "an unknown poll id is ignored", %{conn: conn} do
      %{user: user} = host()
      poll = insert(:poll, user: user, status: :open, meeting_type_id: nil)

      {:ok, view, _html} = live(log_in(conn, user), ~p"/dashboard/polls")

      view
      |> element("button[phx-click='select_poll'][phx-value-id='#{poll.id}']")
      |> render_click(%{"id" => "not-a-uuid"})

      assert has_element?(view, "button[phx-click='select_poll']")
    end

    test "a slot id that is not a UUID is refused and the poll stays open", %{
      conn: conn
    } do
      %{user: user} = host()
      poll = insert(:poll, user: user, status: :open, meeting_type_id: nil)
      slot = insert(:poll_time_slot, poll: poll)
      insert(:poll_participant, poll: poll)

      {:ok, view, _html} = live(log_in(conn, user), ~p"/dashboard/polls")
      select_poll(view, poll)

      view
      |> element("button[phx-click='request_confirm_slot'][phx-value-slot='#{slot.id}']")
      |> render_click(%{"slot" => "not-a-uuid"})

      refute has_element?(view, "#confirm-slot-modal")

      view
      |> element("button[phx-click='request_confirm_slot'][phx-value-slot='#{slot.id}']")
      |> render_click()

      view
      |> element("#confirm-slot-modal [data-testid='confirm-slot']")
      |> render_click(%{"slot" => "not-a-uuid"})

      assert has_element?(
               view,
               "button[phx-click='request_confirm_slot'][phx-value-slot='#{slot.id}']"
             )

      assert {:ok, %{status: :open}} = Polls.get_poll_for_host(poll.id, user.id)
    end

    test "a non-numeric slot key is ignored by the create form", %{conn: conn} do
      %{user: user} = host()

      {:ok, view, _html} = live(log_in(conn, user), ~p"/dashboard/polls")
      view |> element("button", "New poll") |> render_click()
      view |> element("button", "Add time") |> render_click()

      view
      |> element("button[phx-click='remove_slot']")
      |> render_click(%{"key" => "oops"})

      assert has_element?(view, "input[name='poll[slots][0]']")
    end

    test "a non-numeric new-time key is ignored by the editor", %{conn: conn} do
      %{user: user} = host()
      poll = insert(:poll, user: user, status: :open, meeting_type_id: nil)
      insert(:poll_time_slot, poll: poll)

      {:ok, view, _html} = live(log_in(conn, user), ~p"/dashboard/polls")
      select_poll(view, poll)
      view |> element("[data-testid='poll-edit-details']") |> render_click()
      view |> element("[data-testid='poll-new-times'] button", "Add time") |> render_click()

      view
      |> element("[data-testid='poll-new-times'] button[phx-click='remove_time']")
      |> render_click(%{"key" => "oops"})

      assert has_element?(view, "input[name='poll[new_times][0]']")
    end
  end
end
