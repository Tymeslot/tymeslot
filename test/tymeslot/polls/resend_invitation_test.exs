defmodule Tymeslot.Polls.ResendInvitationTest do
  @moduledoc """
  `Polls.resend_invitation/3`: the host sends someone on an open poll their
  personal link again, as the invitation or as the voting-link email, once
  per resend window and within the poll email limits.
  """

  # async: false: several tests fill shared rate-limit buckets, which another
  # module's setup would otherwise clear mid-test.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :polls

  alias Ecto.Changeset
  alias Tymeslot.Polls
  alias Tymeslot.Polls.PollParticipantSchema
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Workers.EmailWorker

  setup do
    user = insert(:user)
    insert(:profile, user: user, username: "host#{System.unique_integer([:positive])}")
    insert(:calendar_integration, user: user, provider: "debug")
    poll = insert(:poll, user: user, deadline_at: from_now(3 * 24 * 60))
    %{user: user, poll: poll}
  end

  defp from_now(minutes), do: DateTime.add(DateTime.utc_now(:second), minutes * 60, :second)

  defp resend(ctx, participant_id),
    do: Polls.resend_invitation(ctx.poll.id, ctx.user.id, participant_id)

  defp jobs(action, participant) do
    all_enqueued(
      worker: EmailWorker,
      args: %{"action" => action, "participant_id" => participant.id}
    )
  end

  defp email_jobs(participant),
    do:
      jobs("send_poll_invitation", participant) ++ jobs("send_poll_participant_link", participant)

  defp fill(name, key),
    do: :ok = RateLimiter.consume(name, key, RateLimiter.remaining(name, key))

  defp link_sent_at(participant),
    do: Repo.get!(PollParticipantSchema, participant.id).link_sent_at

  describe "which email goes out" do
    test "an invitee who has not voted gets the invitation again", ctx do
      grace = insert(:poll_participant, poll: ctx.poll)

      assert Polls.resend_invitation(ctx.poll.id, ctx.user.id, grace.id) == :ok

      assert [_invitation] = jobs("send_poll_invitation", grace)
      assert jobs("send_poll_participant_link", grace) == []
      assert DateTime.compare(link_sent_at(grace), from_now(-1)) == :gt
    end

    test "an invitee who has voted gets the voting link, to change their answers", ctx do
      grace = insert(:poll_participant, poll: ctx.poll, voted_at: from_now(-60))

      assert resend(ctx, grace.id) == :ok

      assert [_link] = jobs("send_poll_participant_link", grace)
      assert jobs("send_poll_invitation", grace) == []
    end

    test "someone who asked for their link and voted gets it again", ctx do
      ada = insert(:poll_participant, poll: ctx.poll, invited_at: nil, voted_at: from_now(-60))

      assert resend(ctx, ada.id) == :ok

      assert [_link] = jobs("send_poll_participant_link", ada)
    end

    test "an invite-only poll's invitee can be sent the invitation again", ctx do
      poll = insert(:poll, user: ctx.user, invite_only: true)
      grace = insert(:poll_participant, poll: poll)

      assert Polls.resend_invitation(poll.id, ctx.user.id, grace.id) == :ok
      assert [_invitation] = jobs("send_poll_invitation", grace)
    end
  end

  describe "the resend window" do
    test "a second resend moments later sends nothing more", ctx do
      grace = insert(:poll_participant, poll: ctx.poll)
      host_before = RateLimiter.remaining(:poll_host_invitations, ctx.user.id)
      recipient_before = RateLimiter.remaining(:poll_recipient_email, grace.email)

      assert resend(ctx, grace.id) == :ok
      assert resend(ctx, grace.id) == {:error, :sent_recently}

      assert [_one] = email_jobs(grace)

      # The window is claimed before the limits are charged, so the refused
      # second click costs nothing.
      assert RateLimiter.remaining(:poll_host_invitations, ctx.user.id) == host_before - 1
      assert RateLimiter.remaining(:poll_recipient_email, grace.email) == recipient_before - 1
    end

    test "an invitation that went out moments ago is not sent again", ctx do
      grace = insert(:poll_participant, poll: ctx.poll, link_sent_at: from_now(-2))

      assert resend(ctx, grace.id) == {:error, :sent_recently}
      assert email_jobs(grace) == []
    end

    test "once the window has passed the link goes out again", ctx do
      grace = insert(:poll_participant, poll: ctx.poll, link_sent_at: from_now(-11))

      assert resend(ctx, grace.id) == :ok
      assert [_invitation] = jobs("send_poll_invitation", grace)
    end
  end

  describe "the poll email limits" do
    test "a resend costs the address and the host one email each", ctx do
      grace = insert(:poll_participant, poll: ctx.poll)
      host_before = RateLimiter.remaining(:poll_host_invitations, ctx.user.id)
      grace_before = RateLimiter.remaining(:poll_recipient_email, grace.email)

      assert resend(ctx, grace.id) == :ok

      assert RateLimiter.remaining(:poll_host_invitations, ctx.user.id) == host_before - 1
      assert RateLimiter.remaining(:poll_recipient_email, grace.email) == grace_before - 1
    end

    test "an address that has had too many poll emails is sent nothing", ctx do
      sent_at = from_now(-11)
      grace = insert(:poll_participant, poll: ctx.poll, link_sent_at: sent_at)
      fill(:poll_recipient_email, grace.email)
      host_before = RateLimiter.remaining(:poll_host_invitations, ctx.user.id)

      assert resend(ctx, grace.id) == {:error, :recipient_rate_limited}

      assert email_jobs(grace) == []
      assert link_sent_at(grace) == sent_at
      assert RateLimiter.remaining(:poll_host_invitations, ctx.user.id) == host_before
    end

    test "a host past their invitation allowance sends nothing", ctx do
      sent_at = from_now(-11)
      grace = insert(:poll_participant, poll: ctx.poll, link_sent_at: sent_at)
      fill(:poll_host_invitations, ctx.user.id)
      grace_before = RateLimiter.remaining(:poll_recipient_email, grace.email)

      assert resend(ctx, grace.id) == {:error, :host_rate_limited}

      assert email_jobs(grace) == []
      assert link_sent_at(grace) == sent_at
      assert RateLimiter.remaining(:poll_recipient_email, grace.email) == grace_before
    end
  end

  describe "refusals" do
    test "an id that is not a UUID is nobody on the poll", ctx do
      assert resend(ctx, "not-a-uuid") == {:error, :not_found}
    end

    test "a participant of another poll is nobody on this one", ctx do
      other = insert(:poll_participant, poll: insert(:poll, user: ctx.user))

      assert resend(ctx, other.id) == {:error, :not_found}
      assert email_jobs(other) == []
    end

    test "a pending link request is not sent anything by the host", ctx do
      pending =
        insert(:poll_participant, poll: ctx.poll, confirmed_at: nil, link_sent_at: from_now(-30))

      assert resend(ctx, pending.id) == {:error, :not_found}
      assert email_jobs(pending) == []
    end

    test "another host's poll is not found", ctx do
      grace = insert(:poll_participant, poll: ctx.poll)
      other = insert(:user)
      insert(:calendar_integration, user: other, provider: "debug")

      assert Polls.resend_invitation(ctx.poll.id, other.id, grace.id) ==
               {:error, :not_found}

      assert email_jobs(grace) == []
    end

    test "a confirmed or cancelled poll sends nothing", ctx do
      grace = insert(:poll_participant, poll: ctx.poll)

      for status <- [:confirmed, :cancelled] do
        ctx.poll |> Changeset.change(status: status) |> Repo.update!()
        assert resend(ctx, grace.id) == {:error, :not_open}
      end

      assert email_jobs(grace) == []
    end

    test "a poll past its deadline sends nothing", ctx do
      grace = insert(:poll_participant, poll: ctx.poll)
      ctx.poll |> Changeset.change(deadline_at: from_now(-60)) |> Repo.update!()

      assert resend(ctx, grace.id) == {:error, :voting_closed}
      assert email_jobs(grace) == []
    end
  end
end
