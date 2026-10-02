defmodule TymeslotWeb.Themes.Core.PollVotingMountTest do
  @moduledoc """
  LiveView tests for the public poll voting page mounted through the theme
  dispatcher at `/:username/poll/:token`.
  """
  use TymeslotWeb.LiveCase, async: false
  @moduletag :utils
  @moduletag :polls

  import Ecto.Query
  import Mox, only: [verify_on_exit!: 1]
  import Phoenix.LiveViewTest
  import Tymeslot.ConfigTestHelpers, only: [setup_config: 3]
  import Tymeslot.Factory
  import Tymeslot.ThemeBookingFlowHelpers, only: [seed_booking_account: 3]

  alias Tymeslot.HTTPClientMock
  alias Tymeslot.Polls
  alias Tymeslot.Polls.PollParticipantSchema
  alias Tymeslot.Repo

  setup :verify_on_exit!

  defp poll_path(username, token), do: "/#{username}/poll/#{token}"

  describe "mount for a booking-ready host" do
    for {theme_id, theme_name} <- [{"1", "quill"}, {"2", "rhythm"}] do
      test "renders the poll title in the #{theme_name} theme", %{conn: conn} do
        %{user: user, profile: profile} =
          seed_booking_account(unquote(theme_id), "host-#{unquote(theme_name)}", "Etc/UTC")

        poll = insert(:poll, user: user, title: "Roadmap sync")
        insert(:poll_time_slot, poll: poll)

        {:ok, _view, html} = live(conn, poll_path(profile.username, poll.token))

        assert html =~ "Roadmap sync"
        assert html =~ "poll-voting"
      end

      test "states the poll's timezone once in the #{theme_name} theme", %{conn: conn} do
        %{user: user, profile: profile} =
          seed_booking_account(unquote(theme_id), "tz-host-#{unquote(theme_name)}", "Etc/UTC")

        poll = insert(:poll, user: user, timezone: "Europe/Berlin")
        insert(:poll_time_slot, poll: poll, start_time: ~U[2026-06-15 08:00:00Z])

        {:ok, view, _html} = live(conn, poll_path(profile.username, poll.token))
        html = render(view)

        # Slot rows carry a compact date with no zone on it, so this line is
        # the only thing telling a voter which clock the times are on.
        assert html =~ "Times shown in Europe/Berlin"

        # 08:00 UTC in June is 10:00 in Berlin (CEST). The row names the
        # weekday and drops the year the long format would carry.
        assert html =~ "Monday 15 June, 10:00"
        refute html =~ "15 June 2026"
      end
    end
  end

  describe "not-found handling" do
    test "an unknown token redirects to / without crashing", %{conn: conn} do
      %{profile: profile} = seed_booking_account("1", "unknown-token-host", "Etc/UTC")

      assert {:error, {:redirect, %{to: "/"}}} =
               live(conn, poll_path(profile.username, "does-not-exist"))
    end

    test "a poll belonging to a different host cannot be replayed under this host", %{conn: conn} do
      %{profile: viewer} = seed_booking_account("1", "viewer-host", "Etc/UTC")
      %{user: other_user} = seed_booking_account("2", "owner-host", "Etc/UTC")

      other_poll = insert(:poll, user: other_user)
      insert(:poll_time_slot, poll: other_poll)

      # The token is real, but it belongs to owner-host, not viewer-host.
      assert {:error, {:redirect, %{to: "/"}}} =
               live(conn, poll_path(viewer.username, other_poll.token))
    end
  end

  describe "readiness gate" do
    test "a host with no active calendar shows the readiness error", %{conn: conn} do
      user = insert(:user)
      profile = insert(:profile, user: user, username: "no-calendar-host", booking_theme: "1")
      poll = insert(:poll, user: user)
      insert(:poll_time_slot, poll: poll)

      {:ok, view, html} = live(conn, poll_path(profile.username, poll.token))

      assert html =~ "connected a calendar"

      # The notice belongs to the theme, in the host's own branding, not to the
      # dispatcher's last-resort crash card.
      assert has_element?(view, "[data-testid='readiness-notice']")
      refute html =~ "theme-error-retry-button"
    end
  end

  describe "registration and voting" do
    setup %{conn: conn} do
      %{user: user, profile: profile} = seed_booking_account("1", "vote-host", "Etc/UTC")
      poll = insert(:poll, user: user, title: "Pick a time")
      slot = insert(:poll_time_slot, poll: poll)

      {:ok, view, _html} = live(conn, poll_path(profile.username, poll.token))
      %{view: view, poll: poll, slot: slot, profile: profile}
    end

    test "registering creates a participant and patches the URL with ?p=", %{
      view: view,
      poll: poll,
      profile: profile
    } do
      view
      |> form("form[data-testid='poll-register-form']", %{
        "name" => "Ada Lovelace",
        "email" => "ada@example.com"
      })
      |> render_submit()

      participant = Repo.get_by!(PollParticipantSchema, poll_id: poll.id)
      assert participant.email == "ada@example.com"

      assert_patched(view, poll_path(profile.username, poll.token) <> "?p=#{participant.token}")
      assert has_element?(view, "[data-testid='poll-participant-name']", "Ada Lovelace")
    end

    test "the patched ?p= URL is a live route that resumes the participant", %{
      conn: conn,
      view: view,
      poll: poll,
      profile: profile
    } do
      view
      |> form("form[data-testid='poll-register-form']", %{
        "name" => "Ada Lovelace",
        "email" => "ada@example.com"
      })
      |> render_submit()

      participant = Repo.get_by!(PollParticipantSchema, poll_id: poll.id)
      resume_url = poll_path(profile.username, poll.token) <> "?p=#{participant.token}"

      # The page patches to a path it builds itself. Only `/:username/poll/:token`
      # reaches this LiveView: a username-less `/poll/<token>` lands on a
      # different live_session, which `push_patch/2` refuses and crashes on, so
      # this asserts the built path both patches and mounts.
      {:ok, resumed, _html} = live(conn, resume_url)
      assert has_element?(resumed, "[data-testid='poll-participant-name']", "Ada Lovelace")
    end

    test "casting votes persists responses and re-renders the tallies", %{
      view: view,
      poll: poll,
      slot: slot
    } do
      view
      |> form("form[data-testid='poll-register-form']", %{
        "name" => "Grace",
        "email" => "grace@example.com"
      })
      |> render_submit()

      html =
        view
        |> form("form[data-testid='poll-vote-form']", %{"votes" => %{slot.id => "yes"}})
        |> render_submit()

      {:ok, reloaded} = Polls.get_poll_for_voting(poll.token)
      assert Polls.tallies(reloaded)[slot.id].yes == 1

      assert html =~ "poll-tally--yes"
    end

    test "a bot filling the honeypot is silently rejected", %{view: view, poll: poll} do
      view
      |> form("form[data-testid='poll-register-form']", %{
        "name" => "Bot",
        "email" => "bot@example.com",
        "website" => "http://spam.example"
      })
      |> render_submit()

      assert Repo.aggregate(
               from(p in PollParticipantSchema, where: p.poll_id == ^poll.id),
               :count
             ) == 0
    end
  end

  describe "registration bot checks" do
    setup %{conn: conn} do
      enable_booking_recaptcha()

      %{user: user, profile: profile} = seed_booking_account("1", "guarded-host", "Etc/UTC")
      poll = insert(:poll, user: user, title: "Guarded poll")
      insert(:poll_time_slot, poll: poll)

      {:ok, view, _html} = live(conn, poll_path(profile.username, poll.token))
      %{view: view, poll: poll}
    end

    test "registration goes through when siteverify cannot be reached", %{view: view, poll: poll} do
      stub_siteverify({:error, %Req.TransportError{reason: :timeout}})

      register_with_token(view, "some-token")

      assert participant_count(poll) == 1
    end

    test "registration goes through when siteverify answers with a 5xx", %{view: view, poll: poll} do
      stub_siteverify({:ok, %Req.Response{status: 503, body: ""}})

      register_with_token(view, "RECAPTCHA_SCRIPT_BLOCKED")

      assert participant_count(poll) == 1
    end

    test "a token Google refuses still blocks registration", %{view: view, poll: poll} do
      google_rejects_tokens()

      html = register_with_token(view, "forged-token")

      assert html =~ "Security verification failed"
      assert participant_count(poll) == 0
    end

    test "the script-blocked marker is refused while Google answers", %{view: view, poll: poll} do
      google_rejects_tokens()

      html = register_with_token(view, "RECAPTCHA_SCRIPT_BLOCKED")

      assert html =~ "Security verification is currently unavailable"
      assert participant_count(poll) == 0
    end

    test "a whitespace-only honeypot is caught without asking Google", %{view: view, poll: poll} do
      Mox.expect(HTTPClientMock, :post, 0, fn _url, _body, _headers, _opts -> :unused end)

      render_submit(view, "register_participant", %{
        "name" => "Bot",
        "email" => "bot@example.com",
        "website" => " ",
        "g-recaptcha-response" => "some-token"
      })

      assert participant_count(poll) == 0
    end

    test "the honeypot is rendered hidden from sight and from assistive technology", %{
      view: view
    } do
      assert has_element?(
               view,
               "form[data-testid='poll-register-form'] div.sr-only[aria-hidden='true'] input#poll-website[name='website'][tabindex='-1']"
             )
    end
  end

  # The RecaptchaV3 hook fills the hidden token input, which the form helper
  # cannot set, so the event is sent the way the hook submits it.
  defp register_with_token(view, token) do
    render_submit(view, "register_participant", %{
      "name" => "Ada Lovelace",
      "email" => "ada@example.com",
      "g-recaptcha-response" => token
    })
  end

  defp participant_count(poll) do
    Repo.aggregate(from(p in PollParticipantSchema, where: p.poll_id == ^poll.id), :count)
  end

  defp google_rejects_tokens do
    body = Jason.encode!(%{"success" => false, "error-codes" => ["invalid-input-response"]})
    stub_siteverify({:ok, %Req.Response{status: 200, body: body}})
  end

  defp stub_siteverify(response) do
    Mox.stub(HTTPClientMock, :post, fn _url, _body, _headers, _opts -> response end)
  end

  defp enable_booking_recaptcha do
    setup_config(:tymeslot, :recaptcha,
      booking_enabled: true,
      booking_min_score: 0.3,
      booking_action: "booking_form",
      expected_hostnames: []
    )

    for {name, value} <- [
          {"RECAPTCHA_SITE_KEY", "test_site_key"},
          {"RECAPTCHA_SECRET_KEY", "test_secret_key"}
        ] do
      original = System.get_env(name)
      System.put_env(name, value)

      on_exit(fn ->
        if original, do: System.put_env(name, original), else: System.delete_env(name)
      end)
    end
  end

  describe "closed polls" do
    test "a confirmed poll shows the scheduled time", %{conn: conn} do
      %{user: user, profile: profile} = seed_booking_account("1", "confirmed-host", "Etc/UTC")

      meeting = insert(:meeting, organizer_user: user)

      poll =
        insert(:poll,
          user: user,
          status: :confirmed,
          confirmed_meeting: meeting,
          confirmed_at: DateTime.utc_now(:second)
        )

      insert(:poll_time_slot, poll: poll)

      {:ok, _view, html} = live(conn, poll_path(profile.username, poll.token))

      assert html =~ "poll-confirmed"
      assert html =~ "Scheduled for"
    end

    test "a cancelled poll shows the closed message", %{conn: conn} do
      %{user: user, profile: profile} = seed_booking_account("2", "cancelled-host", "Etc/UTC")

      poll = insert(:poll, user: user, status: :cancelled)
      insert(:poll_time_slot, poll: poll)

      {:ok, _view, html} = live(conn, poll_path(profile.username, poll.token))

      assert html =~ "poll-cancelled"
      assert html =~ "cancelled"
    end
  end
end
