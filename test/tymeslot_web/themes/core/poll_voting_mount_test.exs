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
  import Tymeslot.BookingTestHelpers, only: [seed_booking_account: 3]

  alias Tymeslot.HTTPClientMock
  alias Tymeslot.Polls
  alias Tymeslot.Polls.PollParticipantSchema
  alias Tymeslot.Repo
  alias TymeslotWeb.ThemeTestMatrix

  setup :verify_on_exit!

  defp poll_path(username, token), do: "/#{username}/poll/#{token}"

  describe "mount for a booking-ready host" do
    for theme <- ThemeTestMatrix.all() do
      test "renders the poll title in the #{theme.slug} theme", %{conn: conn} do
        %{user: user, profile: profile} =
          seed_booking_account(unquote(theme.id), "host-#{unquote(theme.slug)}", "Etc/UTC")

        poll = insert(:poll, user: user, title: "Roadmap sync")
        insert(:poll_time_slot, poll: poll)

        {:ok, _view, html} = live(conn, poll_path(profile.username, poll.token))

        assert html =~ "Roadmap sync"
        assert html =~ "poll-voting"
      end

      test "states the poll's timezone once in the #{theme.slug} theme", %{conn: conn} do
        %{user: user, profile: profile} =
          seed_booking_account(unquote(theme.id), "tz-host-#{unquote(theme.slug)}", "Etc/UTC")

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

      test "never shows a voter's address in the #{theme.slug} theme", %{conn: conn} do
        %{user: user, profile: profile} =
          seed_booking_account(unquote(theme.id), "noaddr-#{unquote(theme.slug)}", "Etc/UTC")

        poll = insert(:poll, user: user)
        insert(:poll_time_slot, poll: poll)
        invitee = insert(:poll_participant, poll: poll, name: nil, email: "ada@example.com")

        {:ok, personal, _html} =
          live(conn, poll_path(profile.username, poll.token) <> "?p=#{invitee.token}")

        refute render(personal) =~ "ada@example.com"

        assert has_element?(
                 personal,
                 "[data-testid='poll-participant-name']",
                 "voting with your personal link"
               )

        {:ok, shared, _html} = live(conn, poll_path(profile.username, poll.token))

        html =
          shared
          |> form("form[data-testid='poll-register-form']", %{
            "name" => "Grace Hopper",
            "email" => "grace@example.com"
          })
          |> render_submit()

        assert has_element?(shared, "[data-testid='poll-link-sent']")
        refute html =~ "grace@example.com"
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
      refute html =~ "theme-error-title"
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

    test "a name the rules refuse on a first vote is named in the message", %{
      conn: conn,
      poll: poll,
      slot: slot,
      profile: profile
    } do
      invitee = insert(:poll_participant, poll: poll, name: nil, email: "ada@example.com")

      {:ok, view, _html} =
        live(conn, poll_path(profile.username, poll.token) <> "?p=#{invitee.token}")

      html =
        view
        |> form("form[data-testid='poll-vote-form']", %{
          "name" => "A",
          "votes" => %{slot.id => "yes"}
        })
        |> render_submit()

      assert html =~ "Name is too short (minimum 2 characters)"
      refute html =~ "Please enter your name"
      assert Repo.get!(PollParticipantSchema, invitee.id).voted_at == nil
    end

    test "a missing name on a first vote asks for one", %{
      conn: conn,
      poll: poll,
      slot: slot,
      profile: profile
    } do
      invitee = insert(:poll_participant, poll: poll, name: nil, email: "ada@example.com")

      {:ok, view, _html} =
        live(conn, poll_path(profile.username, poll.token) <> "?p=#{invitee.token}")

      html = render_submit(view, "cast_votes", %{"name" => "", "votes" => %{slot.id => "yes"}})

      assert html =~ "Please enter your name, then save your responses again."
    end

    test "a link request with a refused name or address says which and why", %{view: view} do
      html =
        render_submit(view, "register_participant", %{
          "name" => "A",
          "email" => "ada@example.com"
        })

      assert html =~ "Name is too short (minimum 2 characters)"

      html =
        render_submit(view, "register_participant", %{
          "name" => "Ada Lovelace",
          "email" => "not-an-address"
        })

      assert html =~ "Email format is invalid"

      html =
        render_submit(view, "register_participant", %{
          "name" => "",
          "email" => "ada@example.com"
        })

      assert html =~ "Please enter your name."

      html =
        render_submit(view, "register_participant", %{
          "name" => "Ada Lovelace",
          "email" => ""
        })

      assert html =~ "Please enter your email address."
    end

    test "a voter whose link died while the page was open is sent back to the request form", %{
      conn: conn,
      poll: poll,
      slot: slot,
      profile: profile
    } do
      grace = insert(:poll_participant, poll: poll, name: "Grace")

      {:ok, view, _html} =
        live(conn, poll_path(profile.username, poll.token) <> "?p=#{grace.token}")

      # Deleted directly, so no broadcast reloads the page first.
      Repo.delete!(Repo.get!(PollParticipantSchema, grace.id))

      html =
        view
        |> form("form[data-testid='poll-vote-form']", %{"votes" => %{slot.id => "yes"}})
        |> render_submit()

      assert html =~ "no longer valid"
      assert has_element?(view, "form[data-testid='poll-register-form']")
      refute has_element?(view, "form[data-testid='poll-vote-form']")
    end

    test "asking for a link creates an unconfirmed participant and never shows the link", %{
      view: view,
      poll: poll
    } do
      html =
        view
        |> form("form[data-testid='poll-register-form']", %{
          "name" => "Ada Lovelace",
          "email" => "ada@example.com"
        })
        |> render_submit()

      participant = Repo.get_by!(PollParticipantSchema, poll_id: poll.id)
      assert participant.email == "ada@example.com"
      assert participant.confirmed_at == nil

      refute html =~ participant.token
      assert has_element?(view, "[data-testid='poll-link-sent']", "the address you entered")
      refute html =~ "ada@example.com"
      refute has_element?(view, "form[data-testid='poll-vote-form']")
    end

    test "an address already on the poll is told so and gets nobody's link", %{
      view: view,
      poll: poll
    } do
      ada = insert(:poll_participant, poll: poll, name: "Ada Lovelace", email: "ada@example.com")

      html =
        view
        |> form("form[data-testid='poll-register-form']", %{
          "name" => "Mallory",
          "email" => "ada@example.com"
        })
        |> render_submit()

      refute html =~ ada.token
      refute html =~ "Ada Lovelace"
      refute html =~ "ada@example.com"

      assert has_element?(
               view,
               "[data-testid='poll-link-sent']",
               "sent its voting link again"
             )

      refute has_element?(view, "form[data-testid='poll-vote-form']")
    end

    test "a known address whose link went out minutes ago is told to check that inbox", %{
      view: view,
      poll: poll
    } do
      insert(:poll_participant,
        poll: poll,
        name: "Ada Lovelace",
        email: "ada@example.com",
        confirmed_at: nil,
        link_sent_at: DateTime.utc_now(:second)
      )

      view
      |> form("form[data-testid='poll-register-form']", %{
        "name" => "Ada Lovelace",
        "email" => "ada@example.com"
      })
      |> render_submit()

      assert has_element?(view, "[data-testid='poll-link-sent']", "sent a few minutes ago")
    end

    test "a visitor giving someone else's address cannot change that person's responses", %{
      view: view,
      poll: poll,
      slot: slot
    } do
      ada = insert(:poll_participant, poll: poll, name: "Ada Lovelace", email: "ada@example.com")
      insert(:poll_vote, participant: ada, time_slot: slot, response: :yes)

      view
      |> form("form[data-testid='poll-register-form']", %{
        "name" => "Mallory",
        "email" => "ada@example.com"
      })
      |> render_submit()

      html = render_submit(view, "cast_votes", %{"votes" => %{slot.id => "no"}})

      assert html =~ "personal voting link"

      ada = PollParticipantSchema |> Repo.get!(ada.id) |> Repo.preload(:votes)
      assert [%{response: :yes}] = ada.votes
      assert ada.name == "Ada Lovelace"
    end

    test "the emailed link opens the vote form, and saving through it confirms the participant",
         %{
           conn: conn,
           poll: poll,
           slot: slot,
           profile: profile
         } do
      pending =
        insert(:poll_participant,
          poll: poll,
          name: "Grace",
          confirmed_at: nil,
          link_sent_at: DateTime.utc_now(:second)
        )

      {:ok, view, _html} =
        live(conn, poll_path(profile.username, poll.token) <> "?p=#{pending.token}")

      assert has_element?(view, "[data-testid='poll-participant-name']", "Grace")
      assert has_element?(view, "[data-testid='poll-link-notice']", "confirm your email address")

      html =
        view
        |> form("form[data-testid='poll-vote-form']", %{"votes" => %{slot.id => "yes"}})
        |> render_submit()

      {:ok, reloaded} = Polls.get_poll_for_voting(poll.token)
      assert Polls.tallies(reloaded)[slot.id].yes == 1
      assert %DateTime{} = Repo.get!(PollParticipantSchema, pending.id).confirmed_at

      assert html =~ "poll-tally--yes"
      assert html =~ "your responses count now"
      assert has_element?(view, "[data-testid='poll-link-notice']", "your personal link")
    end

    test "someone invited without a name is asked for it with their first responses", %{
      conn: conn,
      poll: poll,
      slot: slot,
      profile: profile
    } do
      invitee = insert(:poll_participant, poll: poll, name: nil, email: "ada@example.com")

      {:ok, view, _html} =
        live(conn, poll_path(profile.username, poll.token) <> "?p=#{invitee.token}")

      assert has_element?(
               view,
               "[data-testid='poll-participant-name']",
               "voting with your personal link"
             )

      refute render(view) =~ "ada@example.com"
      assert has_element?(view, "[data-testid='poll-voter-name']")

      view
      |> form("form[data-testid='poll-vote-form']", %{
        "name" => "Ada Lovelace",
        "votes" => %{slot.id => "yes"}
      })
      |> render_submit()

      assert Repo.get!(PollParticipantSchema, invitee.id).name == "Ada Lovelace"
      assert has_element?(view, "[data-testid='poll-participant-name']", "Ada Lovelace")
      refute has_element?(view, "[data-testid='poll-voter-name']")
    end

    test "marks a time added after someone voted as new to them, and only to them", %{
      conn: conn,
      poll: poll,
      slot: slot,
      profile: profile
    } do
      added =
        insert(:poll_time_slot,
          poll: poll,
          start_time: DateTime.add(slot.start_time, 1, :day),
          end_time: DateTime.add(slot.end_time, 1, :day)
        )

      voted = insert(:poll_participant, poll: poll, voted_at: DateTime.utc_now(:second))
      insert(:poll_vote, participant: voted, time_slot: slot, response: :yes)
      not_yet = insert(:poll_participant, poll: poll)

      {:ok, view, _html} =
        live(conn, poll_path(profile.username, poll.token) <> "?p=#{voted.token}")

      assert [_one] =
               view
               |> render()
               |> Floki.parse_document!()
               |> Floki.find("[data-testid='poll-slot-new']")

      assert has_element?(view, "input[data-testid='vote-#{added.id}-yes']")

      {:ok, fresh, _html} =
        live(conn, poll_path(profile.username, poll.token) <> "?p=#{not_yet.token}")

      refute has_element?(fresh, "[data-testid='poll-slot-new']")
    end

    test "an unconfirmed link past its lifetime opens the request form instead", %{
      conn: conn,
      poll: poll,
      profile: profile
    } do
      expired =
        insert(:poll_participant,
          poll: poll,
          confirmed_at: nil,
          inserted_at: DateTime.add(DateTime.utc_now(), -3, :day),
          link_sent_at: DateTime.add(DateTime.utc_now(), -3, :day)
        )

      {:ok, view, _html} =
        live(conn, poll_path(profile.username, poll.token) <> "?p=#{expired.token}")

      assert has_element?(view, "form[data-testid='poll-register-form']")
      refute has_element?(view, "form[data-testid='poll-vote-form']")
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

    test "a bot sending a non-text address to the honeypot gets the fake success, not a crash",
         %{view: view, poll: poll} do
      render_submit(view, "register_participant", %{
        "name" => "Bot",
        "email" => %{"nested" => "value"},
        "website" => "http://spam.example"
      })

      assert has_element?(view, "[data-testid='poll-link-sent']")
      assert participant_count(poll) == 0
    end

    test "a non-text address outside the honeypot is refused with a message, not a crash", %{
      view: view,
      poll: poll
    } do
      html =
        render_submit(view, "register_participant", %{
          "name" => "Ada Lovelace",
          "email" => %{"nested" => "value"}
        })

      assert html =~ "Please check your name and email"
      assert participant_count(poll) == 0
    end
  end

  describe "invite-only polls" do
    for theme <- ThemeTestMatrix.all() do
      test "the bare link says it is by invitation and offers no form in the #{theme.slug} theme",
           %{conn: conn} do
        %{user: user, profile: profile} =
          seed_booking_account(unquote(theme.id), "invite-#{unquote(theme.slug)}", "Etc/UTC")

        poll = insert(:poll, user: user, title: "Board meeting", invite_only: true)
        insert(:poll_time_slot, poll: poll)

        {:ok, view, _html} = live(conn, poll_path(profile.username, poll.token))

        assert has_element?(view, "[data-testid='poll-title']", "Board meeting")
        assert has_element?(view, "[data-testid='poll-invite-only']", "by invitation only")
        refute has_element?(view, "form[data-testid='poll-register-form']")
        refute has_element?(view, "[data-testid='poll-slot-grid']")
      end
    end

    setup %{conn: conn} do
      %{user: user, profile: profile} = seed_booking_account("1", "invite-only-host", "Etc/UTC")
      poll = insert(:poll, user: user, invite_only: true)
      slot = insert(:poll_time_slot, poll: poll)
      %{conn: conn, poll: poll, slot: slot, profile: profile}
    end

    test "an invitee's personal link opens the vote form and saves", ctx do
      now = DateTime.utc_now(:second)

      invitee =
        insert(:poll_participant,
          poll: ctx.poll,
          name: "Grace",
          confirmed_at: now,
          invited_at: now
        )

      {:ok, view, _html} =
        live(ctx.conn, poll_path(ctx.profile.username, ctx.poll.token) <> "?p=#{invitee.token}")

      refute has_element?(view, "[data-testid='poll-invite-only']")

      view
      |> form("form[data-testid='poll-vote-form']", %{"votes" => %{ctx.slot.id => "yes"}})
      |> render_submit()

      assert %DateTime{} = Repo.get!(PollParticipantSchema, invitee.id).voted_at
    end

    test "a crafted link request is refused and writes nothing", ctx do
      {:ok, view, _html} = live(ctx.conn, poll_path(ctx.profile.username, ctx.poll.token))

      html =
        render_hook(view, "register_participant", %{
          "name" => "Mallory",
          "email" => "mallory@example.com"
        })

      # The refusal's flash wording is pinned in `poll_voting_test.exs`; here
      # the point is that the page stays as it was and nothing is written.
      assert html =~ "by invitation only"

      refute Repo.get_by(PollParticipantSchema,
               poll_id: ctx.poll.id,
               email: "mallory@example.com"
             )
    end

    test "a page left open loses its form when the host makes the poll invite-only", ctx do
      open = insert(:poll, user: ctx.poll.user, invite_only: false)
      insert(:poll_time_slot, poll: open)

      {:ok, view, _html} = live(ctx.conn, poll_path(ctx.profile.username, open.token))
      assert has_element?(view, "form[data-testid='poll-register-form']")

      {:ok, _poll} = Polls.update_details(open.id, open.user_id, %{"invite_only" => true})

      assert render(view) =~ "by invitation only"
      refute has_element?(view, "form[data-testid='poll-register-form']")
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
