defmodule TymeslotWeb.Dashboard.PollsAccessTest do
  @moduledoc """
  Who can vote on a poll: the create form's default and the host's explicit
  choice, the editor's switch to invited people only, and how the results
  panel names it.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :polls
  @moduletag :live

  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Polls
  alias Tymeslot.Polls.PollParticipantSchema
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks

  defp setup_host(_context) do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    profile = insert(:profile, user: user, username: "host#{System.unique_integer([:positive])}")
    insert(:calendar_integration, user: user, provider: "debug")
    {:ok, conn: log_in(build_conn(), user), user: user, profile: profile}
  end

  defp log_in(conn, user) do
    conn |> init_test_session(%{}) |> fetch_session() |> log_in_user(user)
  end

  describe "Who can vote" do
    setup :setup_host

    defp open_create_form(view) do
      view |> element("button", "New poll") |> render_click()
      view |> element("button", "Add time") |> render_click()
      view
    end

    defp create_params(extra) do
      date = Date.utc_today() |> Date.add(7) |> Date.to_iso8601()

      Map.merge(
        %{
          "title" => "Launch planning",
          "duration" => "30",
          "timezone" => "Europe/Tallinn",
          "slots" => %{"0" => "#{date}T09:00"}
        },
        extra
      )
    end

    test "a new poll is open to anyone with the link while nobody is invited", %{
      conn: conn,
      user: user
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
      open_create_form(view)

      assert has_element?(view, "input[name='poll[access]'][value='anyone'][checked]")

      view
      |> form("form[phx-submit='create_poll']", %{"poll" => create_params(%{})})
      |> render_submit()

      assert [%{invite_only: false}] = Polls.list_polls(user.id)
    end

    test "inviting people with a new poll presets it to invited people only", %{
      conn: conn,
      user: user
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
      open_create_form(view)
      params = create_params(%{"invitees" => "grace@example.com"})

      view |> form("form[phx-submit='create_poll']", %{"poll" => params}) |> render_change()

      assert has_element?(view, "input[name='poll[access]'][value='invited'][checked]")

      view |> form("form[phx-submit='create_poll']", %{"poll" => params}) |> render_submit()

      assert [%{invite_only: true}] = Polls.list_polls(user.id)
    end

    test "the host can keep a poll with invitees open to anyone", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
      open_create_form(view)
      params = create_params(%{"invitees" => "grace@example.com"})

      view |> form("form[phx-submit='create_poll']", %{"poll" => params}) |> render_change()

      view
      |> form("form[phx-submit='create_poll']", %{"poll" => Map.put(params, "access", "anyone")})
      |> render_change(%{"_target" => ["poll", "access"]})

      assert has_element?(view, "input[name='poll[access]'][value='anyone'][checked]")

      view
      |> form("form[phx-submit='create_poll']", %{"poll" => Map.put(params, "access", "anyone")})
      |> render_submit()

      assert [%{invite_only: false}] = Polls.list_polls(user.id)
    end

    test "submitting invitees without a preceding change still creates an invite-only poll", %{
      conn: conn,
      user: user
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
      open_create_form(view)
      params = create_params(%{"invitees" => "grace@example.com"})

      view |> form("form[phx-submit='create_poll']", %{"poll" => params}) |> render_submit()

      assert [%{invite_only: true}] = Polls.list_polls(user.id)
    end

    test "a change still carrying the old radio value while the host types invitees is not a choice",
         %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
      open_create_form(view)

      # The first keystroke flips the default to invited, but the next change
      # left the browser before the radio re-rendered, so it still says anyone.
      first = create_params(%{"invitees" => "g", "access" => "anyone"})
      typed = create_params(%{"invitees" => "grace@example.com", "access" => "anyone"})

      view
      |> form("form[phx-submit='create_poll']", %{"poll" => first})
      |> render_change(%{"_target" => ["poll", "invitees"]})

      view
      |> form("form[phx-submit='create_poll']", %{"poll" => typed})
      |> render_change(%{"_target" => ["poll", "invitees"]})

      assert has_element?(view, "input[name='poll[access]'][value='invited'][checked]")

      view
      |> form("form[phx-submit='create_poll']", %{"poll" => Map.put(typed, "access", "invited")})
      |> render_submit()

      assert [%{invite_only: true}] = Polls.list_polls(user.id)
    end

    test "clearing the invitees flips an unchosen preset back to anyone", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
      open_create_form(view)
      params = create_params(%{"invitees" => "grace@example.com"})

      view |> form("form[phx-submit='create_poll']", %{"poll" => params}) |> render_change()
      assert has_element?(view, "input[name='poll[access]'][value='invited'][checked]")

      view
      |> form("form[phx-submit='create_poll']", %{"poll" => Map.put(params, "invitees", "")})
      |> render_change()

      assert has_element?(view, "input[name='poll[access]'][value='anyone'][checked]")
    end

    test "clearing the invitees keeps an explicit choice", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
      open_create_form(view)
      params = create_params(%{"invitees" => "grace@example.com", "access" => "invited"})

      view
      |> form("form[phx-submit='create_poll']", %{"poll" => params})
      |> render_change(%{"_target" => ["poll", "access"]})

      view
      |> form("form[phx-submit='create_poll']", %{"poll" => Map.put(params, "invitees", "")})
      |> render_change()

      assert has_element?(view, "input[name='poll[access]'][value='invited'][checked]")
    end

    test "the withdraw hint counts requests that arrive while the editor is open", %{
      conn: conn,
      user: user
    } do
      TestMocks.setup_calendar_mocks(events: [])
      poll = insert(:poll, user: user, status: :open, meeting_type_id: nil, invite_only: false)
      insert(:poll_time_slot, poll: poll)

      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")

      view
      |> element("button[phx-click='select_poll'][phx-value-id='#{poll.id}']")
      |> render_click()

      view |> element("[data-testid='poll-edit-details']") |> render_click()

      # Inserted after the editor opened; nothing broadcasts a link request.
      insert(:poll_participant,
        poll: poll,
        confirmed_at: nil,
        link_sent_at: DateTime.utc_now(:second)
      )

      view
      |> form("[data-testid='poll-details-form']", poll: %{title: poll.title, access: "invited"})
      |> render_change()

      assert has_element?(view, "[data-testid='poll-access-hint']", "1 person")
    end

    test "choosing invited people with nobody invited says nobody can vote yet", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
      open_create_form(view)

      view
      |> form("form[phx-submit='create_poll']", %{
        "poll" => create_params(%{"access" => "invited"})
      })
      |> render_change(%{"_target" => ["poll", "access"]})

      assert has_element?(view, "[data-testid='poll-access-hint']", "Nobody can vote")
    end

    test "switching an open poll to invited people only withdraws pending requests", %{
      conn: conn,
      user: user
    } do
      TestMocks.setup_calendar_mocks(events: [])
      poll = insert(:poll, user: user, status: :open, meeting_type_id: nil, invite_only: false)
      insert(:poll_time_slot, poll: poll)
      now = DateTime.utc_now(:second)
      pending = insert(:poll_participant, poll: poll, confirmed_at: nil, link_sent_at: now)
      voter = insert(:poll_participant, poll: poll, confirmed_at: now, voted_at: now)

      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")

      view
      |> element("button[phx-click='select_poll'][phx-value-id='#{poll.id}']")
      |> render_click()

      view |> element("[data-testid='poll-edit-details']") |> render_click()

      view
      |> form("[data-testid='poll-details-form']", poll: %{title: poll.title, access: "invited"})
      |> render_change()

      assert has_element?(view, "[data-testid='poll-access-hint']", "1 person")

      view
      |> form("[data-testid='poll-details-form']", poll: %{title: poll.title, access: "invited"})
      |> render_submit()

      assert {:ok, %{invite_only: true}} = Polls.get_poll_for_host(poll.id, user.id)
      assert Repo.get(PollParticipantSchema, pending.id) == nil
      assert Repo.get(PollParticipantSchema, voter.id)
      assert has_element?(view, "[data-testid='poll-access-mode']", "Only invited people")
    end

    test "the results panel names who can vote", %{conn: conn, user: user} do
      TestMocks.setup_calendar_mocks(events: [])
      poll = insert(:poll, user: user, status: :open, meeting_type_id: nil, invite_only: false)
      insert(:poll_time_slot, poll: poll)

      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")

      view
      |> element("button[phx-click='select_poll'][phx-value-id='#{poll.id}']")
      |> render_click()

      assert has_element?(view, "[data-testid='poll-access-mode']", "Anyone with the link")
    end
  end
end
