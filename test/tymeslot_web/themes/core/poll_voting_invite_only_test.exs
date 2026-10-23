defmodule TymeslotWeb.Themes.Core.PollVotingInviteOnlyTest do
  @moduledoc """
  LiveView tests for the public poll voting page of an invite-only poll,
  mounted through the theme dispatcher at `/:username/poll/:token`.
  """
  use TymeslotWeb.LiveCase, async: false
  @moduletag :utils
  @moduletag :polls

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Tymeslot.Factory
  import Tymeslot.BookingTestHelpers, only: [seed_booking_account: 3]

  alias Ecto.Changeset
  alias Tymeslot.Polls
  alias Tymeslot.Polls.PollParticipantSchema
  alias Tymeslot.Repo
  alias TymeslotWeb.ThemeTestMatrix

  defp poll_path(username, token), do: "/#{username}/poll/#{token}"

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

    test "after the deadline the bare link shows no tallies", ctx do
      past = DateTime.add(DateTime.utc_now(:second), -1, :hour)
      ctx.poll |> Changeset.change(deadline_at: past) |> Repo.update!()

      {:ok, view, _html} = live(ctx.conn, poll_path(ctx.profile.username, ctx.poll.token))

      assert has_element?(view, "[data-testid='poll-invite-only']")
      refute has_element?(view, "[data-testid='poll-voting-ended']")
      refute has_element?(view, "[data-testid='poll-slot']")
    end

    test "after the deadline the bare link says voting has closed, not how to vote", ctx do
      past = DateTime.add(DateTime.utc_now(:second), -1, :hour)
      ctx.poll |> Changeset.change(deadline_at: past) |> Repo.update!()

      {:ok, view, _html} = live(ctx.conn, poll_path(ctx.profile.username, ctx.poll.token))

      assert has_element?(view, "[data-testid='poll-invite-only']", "voting has closed")
      refute has_element?(view, "[data-testid='poll-invite-only']", "to vote")
      refute has_element?(view, "[data-testid='poll-deadline']")
    end

    test "before the deadline the bare link says when voting closes", ctx do
      future = DateTime.add(DateTime.utc_now(:second), 2, :day)
      ctx.poll |> Changeset.change(deadline_at: future) |> Repo.update!()

      {:ok, view, _html} = live(ctx.conn, poll_path(ctx.profile.username, ctx.poll.token))

      assert has_element?(view, "[data-testid='poll-deadline']", "Voting closes")
      assert has_element?(view, "[data-testid='poll-invite-only']", "personal link")
    end

    test "after the deadline a confirmed invitee still sees the final responses", ctx do
      now = DateTime.utc_now(:second)

      ctx.poll
      |> Changeset.change(deadline_at: DateTime.add(now, -1, :hour))
      |> Repo.update!()

      invitee =
        insert(:poll_participant,
          poll: ctx.poll,
          name: "Grace",
          confirmed_at: now,
          invited_at: now
        )

      {:ok, view, _html} =
        live(ctx.conn, poll_path(ctx.profile.username, ctx.poll.token) <> "?p=#{invitee.token}")

      assert has_element?(view, "[data-testid='poll-voting-ended']")
      assert has_element?(view, "[data-testid='poll-slot']")
    end

    test "after the deadline an open poll still shows the final responses", %{conn: conn} do
      %{user: user, profile: profile} = seed_booking_account("1", "open-ended-host", "Etc/UTC")
      past = DateTime.add(DateTime.utc_now(:second), -1, :hour)
      poll = insert(:poll, user: user, invite_only: false, deadline_at: past)
      insert(:poll_time_slot, poll: poll)

      {:ok, view, _html} = live(conn, poll_path(profile.username, poll.token))

      assert has_element?(view, "[data-testid='poll-voting-ended']")
      assert has_element?(view, "[data-testid='poll-slot']")
      refute has_element?(view, "[data-testid='poll-invite-only']")
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

    test "an unconfirmed participant's link shows the notice and no vote form", ctx do
      pending =
        insert(:poll_participant,
          poll: ctx.poll,
          name: "Mallory",
          confirmed_at: nil,
          link_sent_at: DateTime.utc_now(:second)
        )

      {:ok, view, _html} =
        live(ctx.conn, poll_path(ctx.profile.username, ctx.poll.token) <> "?p=#{pending.token}")

      assert has_element?(view, "[data-testid='poll-invite-only']")
      refute has_element?(view, "form[data-testid='poll-vote-form']")
    end

    test "a link request refused after the poll turned invite-only switches the view", ctx do
      open = insert(:poll, user: ctx.poll.user, invite_only: false)
      insert(:poll_time_slot, poll: open)

      {:ok, view, _html} = live(ctx.conn, poll_path(ctx.profile.username, open.token))

      # Updated directly, so no broadcast reloads the page first.
      Repo.update_all(from(p in Tymeslot.Polls.PollSchema, where: p.id == ^open.id),
        set: [invite_only: true]
      )

      html =
        render_submit(view, "register_participant", %{
          "name" => "Mallory",
          "email" => "mallory@example.com"
        })

      assert html =~ "by invitation only"
      assert has_element?(view, "[data-testid='poll-invite-only']")
      refute has_element?(view, "form[data-testid='poll-register-form']")
    end

    test "a vote refused after the poll turned invite-only switches the view", ctx do
      open = insert(:poll, user: ctx.poll.user, invite_only: false)
      slot = insert(:poll_time_slot, poll: open)

      pending =
        insert(:poll_participant,
          poll: open,
          name: "Mallory",
          confirmed_at: nil,
          link_sent_at: DateTime.utc_now(:second)
        )

      {:ok, view, _html} =
        live(ctx.conn, poll_path(ctx.profile.username, open.token) <> "?p=#{pending.token}")

      assert has_element?(view, "form[data-testid='poll-vote-form']")

      Repo.update_all(from(p in Tymeslot.Polls.PollSchema, where: p.id == ^open.id),
        set: [invite_only: true]
      )

      view
      |> form("form[data-testid='poll-vote-form']", %{"votes" => %{slot.id => "yes"}})
      |> render_submit()

      assert has_element?(view, "[data-testid='poll-invite-only']")
      refute has_element?(view, "form[data-testid='poll-vote-form']")
    end

    test "a page that asked for a link asks afresh after invite-only and back to open", ctx do
      open = insert(:poll, user: ctx.poll.user, invite_only: false)
      insert(:poll_time_slot, poll: open)

      {:ok, view, _html} = live(ctx.conn, poll_path(ctx.profile.username, open.token))

      view
      |> form("form[data-testid='poll-register-form']", %{
        "name" => "Ada Lovelace",
        "email" => "ada@example.com"
      })
      |> render_submit()

      assert has_element?(view, "[data-testid='poll-link-sent']")

      {:ok, _poll} = Polls.update_details(open.id, open.user_id, %{"invite_only" => true})
      assert has_element?(view, "[data-testid='poll-invite-only']")

      {:ok, _poll} = Polls.update_details(open.id, open.user_id, %{"invite_only" => false})

      refute has_element?(view, "[data-testid='poll-link-sent']")
      assert has_element?(view, "form[data-testid='poll-register-form']")
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
end
