defmodule Tymeslot.Notifications.Email.PollEmails do
  @moduledoc """
  Handles poll-related email actions: invitations, participants' voting links
  and receipts, deadline reminders to unvoted participants, news of added
  times and of a cancelled poll, and for the host pick-a-time nudges and
  updates on new votes.

  Every email to a participant carries their personal `?p=` link, read from
  the participant here rather than from the job args.
  """

  require Logger

  alias Tymeslot.Auth
  alias Tymeslot.Clock
  alias Tymeslot.Emails.Delivery
  alias Tymeslot.Emails.EmailScheduler.PollScheduler
  alias Tymeslot.Emails.Templates.PollCancelled
  alias Tymeslot.Emails.Templates.PollDeadlineReminder
  alias Tymeslot.Emails.Templates.PollHostNudge
  alias Tymeslot.Emails.Templates.PollInvitation
  alias Tymeslot.Emails.Templates.PollNewTimes
  alias Tymeslot.Emails.Templates.PollParticipantLink
  alias Tymeslot.Emails.Templates.PollVoteDigest
  alias Tymeslot.Emails.Templates.PollVoteReceipt
  alias Tymeslot.Polls.PollParticipantQueries
  alias Tymeslot.Polls.PollParticipantSchema
  alias Tymeslot.Polls.PollQueries
  alias Tymeslot.Polls.PollSchema
  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.Utils.UrlBuilder
  alias Tymeslot.Workers.DeliveryClaims

  # The poll is gone or closed, or its host has no public page to link to.
  @no_username "host has no username"
  @poll_gone "poll not found"
  @poll_closed "poll not open"
  # Scheduled for a deadline the host has since moved or removed.
  @stale_deadline "poll deadline changed"
  # An unconfirmed participant pruned before their email went out.
  @participant_gone "poll participant not found"
  # The host's account was deleted before the cancellation went out.
  @host_gone "poll host not found"
  # The host's account is about to be deleted.
  @host_leaving "host account pending deletion"

  # How long a vote is left to settle before an update to the host may report
  # it. A vote is stamped before its transaction commits, so an update that
  # read the poll in between would otherwise mark it as told without having
  # seen it. A minute is far beyond any vote's transaction; a newer vote waits
  # for the next update.
  @vote_settle_seconds 60

  # The cutoff an update to the host marks as told, kept on its job
  # (`DeliveryClaims.remember/3`) so that a rerun marks the same one.
  @digest_cutoff "vote_digest:cutoff"
  @nudge_cutoff "host_nudge:cutoff"

  @doc """
  Whether `reason`, from a discard this module returned, is an expected end
  of the email job rather than a fault
  (see `Tymeslot.Infrastructure.ExpectedJobOutcome`).
  """
  @spec expected_discard?(term()) :: boolean()
  def expected_discard?(reason),
    do:
      reason in [
        @no_username,
        @poll_gone,
        @poll_closed,
        @participant_gone,
        @host_gone,
        @host_leaving,
        @stale_deadline
      ]

  @doc "Emails a participant their personal voting link."
  @spec handle_participant_link(%{String.t() => term()}) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_participant_link(%{"participant_id" => participant_id}) do
    with_participant(participant_id, "poll participant link", &PollParticipantLink.render/3)
  end

  @doc "Emails an invitee their invitation with their personal voting link."
  @spec handle_invitation(%{String.t() => term()}) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_invitation(%{"participant_id" => participant_id}) do
    with_participant(participant_id, "poll invitation", &PollInvitation.render/3)
  end

  @doc "Emails a newly confirmed participant the receipt for their responses."
  @spec handle_vote_receipt(%{String.t() => term()}) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_vote_receipt(%{"participant_id" => participant_id}) do
    with_participant(participant_id, "poll vote receipt", &PollVoteReceipt.render/3)
  end

  # Loads the participant with their poll, and renders and sends `render`'s
  # email with their personal link while the poll is open and its host has a
  # public page to link to.
  defp with_participant(participant_id, action, render) do
    case PollParticipantQueries.get_with_poll(participant_id) do
      nil ->
        Logger.info("Skipping poll email — participant no longer exists",
          email_action: action,
          participant_id: participant_id
        )

        {:discard, @participant_gone}

      %{poll: %{status: :open} = poll} = participant ->
        deliver_to_participant(poll, participant, action, render)

      %{poll: poll} ->
        Logger.info("Skipping poll email — poll is not open",
          email_action: action,
          poll_id: poll.id,
          status: poll.status
        )

        {:discard, @poll_closed}
    end
  end

  defp deliver_to_participant(poll, participant, action, render) do
    case host_username(poll) do
      nil ->
        Logger.warning("Skipping poll email — host has no username",
          email_action: action,
          poll_id: poll.id
        )

        {:discard, @no_username}

      username ->
        poll
        |> render.(participant, personal_url(poll, username, participant))
        |> Delivery.deliver()
        |> delivery_outcome()
    end
  end

  defp delivery_outcome({:ok, _result}), do: :ok
  defp delivery_outcome({:error, reason}), do: {:error, reason}

  @spec handle_deadline_reminders(%{String.t() => term()}, DeliveryClaims.job_id()) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_deadline_reminders(%{"poll_id" => poll_id} = args, job_id) do
    with_current_deadline(poll_id, args, "poll deadline reminders", fn poll ->
      # Without a host username the public voting page has no working URL, so the
      # reminder's call-to-action would be broken. Discard rather than sending a
      # dead link to every participant.
      case host_username(poll) do
        nil ->
          Logger.warning("Skipping poll deadline reminders — host has no username",
            poll_id: poll_id
          )

          {:discard, @no_username}

        username ->
          deliver_deadline_reminders(poll, username, job_id)
      end
    end)
  end

  # Each reminder carries the participant's own link: voting is only possible
  # through it, so the bare poll link would only let them ask for it again.
  defp deliver_deadline_reminders(poll, username, job_id) do
    poll.id
    |> PollParticipantQueries.list_unvoted_for_poll()
    |> Enum.each(fn participant ->
      DeliveryClaims.once(job_id, "participant:#{participant.id}", fn ->
        poll
        |> PollDeadlineReminder.render(participant, personal_url(poll, username, participant))
        |> Delivery.deliver()
      end)
    end)

    :ok
  end

  @spec handle_host_nudge(%{String.t() => term()}, DeliveryClaims.job_id()) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_host_nudge(%{"poll_id" => poll_id, "variant" => variant} = args, job_id) do
    cutoff = host_update_cutoff(job_id, @nudge_cutoff)

    with_current_deadline(poll_id, args, "poll host nudge", fn poll ->
      with_host_staying(poll, "poll host nudge", fn ->
        delivered =
          DeliveryClaims.once(job_id, "host", fn ->
            poll
            |> PollHostNudge.render(variant_atom(variant), results_url())
            |> Delivery.deliver()
            |> delivery_outcome()
          end)

        # Once sent, the nudge counts as the host's update on the votes it
        # carried: a pending update then has nothing new to tell. A nudge that
        # failed told the host nothing, so nothing is marked and the job retries.
        with :ok <- delivered, do: mark_host_updated(poll, cutoff)
      end)
    end)
  end

  @doc """
  Emails the host an update naming who voted or changed their responses since
  their last one, with the standings. Sends nothing when the host has turned
  updates off since the job was scheduled, or when nothing is new, e.g.
  because a nudge carried the same standings in the meantime.

  The update covers the votes cast before a cutoff a minute before the job
  first ran, kept on the job so that a rerun covers the same ones. Votes cast
  after it are left to the next update, which this one schedules.
  """
  @spec handle_vote_digest(%{String.t() => term()}, DeliveryClaims.job_id()) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_vote_digest(%{"poll_id" => poll_id}, job_id) do
    # Taken before the poll is read, so nothing the read missed is marked told.
    cutoff = host_update_cutoff(job_id, @digest_cutoff)

    with_open_poll(poll_id, "poll vote digest", fn poll ->
      with_host_staying(poll, "poll vote digest", fn -> send_vote_digest(poll, cutoff, job_id) end)
    end)
  end

  defp send_vote_digest(%PollSchema{notify_on_vote: false}, _cutoff, _job_id), do: :ok

  defp send_vote_digest(poll, cutoff, job_id) do
    {voters, settling} = voters_since_update(poll, cutoff)

    with :ok <- deliver_vote_digest(poll, voters, cutoff, job_id) do
      # A vote cast while this update was waiting joined it rather than
      # scheduling its own, so one this update leaves out needs the next.
      if settling == [], do: :ok, else: PollScheduler.schedule_vote_digest(poll)
    end
  end

  defp deliver_vote_digest(_poll, [], _cutoff, _job_id), do: :ok

  defp deliver_vote_digest(poll, voters, cutoff, job_id) do
    delivered =
      DeliveryClaims.once(job_id, "host", fn ->
        poll
        |> PollVoteDigest.render(voters, results_url())
        |> Delivery.deliver()
        |> delivery_outcome()
      end)

    with :ok <- delivered, do: mark_host_updated(poll, cutoff)
  end

  @doc """
  Tells everyone who has already voted which times the host added, with their
  link to answer them. Whoever has not voted yet sees the new times when they
  open their link, so they are not emailed.
  """
  @spec handle_new_times(%{String.t() => term()}, DeliveryClaims.job_id()) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_new_times(%{"poll_id" => poll_id, "slot_ids" => slot_ids}, job_id) do
    with_open_poll(poll_id, "poll new times", fn poll ->
      case {host_username(poll), Enum.filter(poll.time_slots, &(&1.id in slot_ids))} do
        {_username, []} ->
          :ok

        {nil, _slots} ->
          {:discard, @no_username}

        {username, slots} ->
          poll.participants
          |> Enum.filter(& &1.voted_at)
          |> Enum.each(fn participant ->
            DeliveryClaims.once(job_id, "participant:#{participant.id}", fn ->
              poll
              |> PollNewTimes.render(
                participant,
                slots,
                personal_url(poll, username, participant)
              )
              |> Delivery.deliver()
            end)
          end)
      end
    end)
  end

  @doc """
  Tells every participant of a cancelled poll that it will not go ahead.

  Sent from what the job carries (`PollScheduler.schedule_cancellation/1`),
  so it goes out even when the host deleted the poll straight after
  cancelling it. A job queued before jobs carried that reads the poll
  instead, and is discarded once the poll is gone.
  """
  @spec handle_cancelled(%{String.t() => term()}, DeliveryClaims.job_id()) ::
          :ok | {:discard, String.t()}
  def handle_cancelled(
        %{"recipients" => recipients, "user_id" => user_id, "title" => title} = args,
        job_id
      ) do
    case Auth.get_user_with_profile(user_id) do
      {:ok, host} ->
        poll = %PollSchema{id: args["poll_id"], title: title, user: host}
        Enum.each(recipients, &deliver_cancellation(poll, recipient(&1), job_id))

      {:error, :not_found} ->
        Logger.info("Skipping poll cancellation emails: the host no longer exists",
          poll_id: args["poll_id"]
        )

        {:discard, @host_gone}
    end
  end

  def handle_cancelled(%{"poll_id" => poll_id}, job_id) do
    case PollQueries.get_with_host(poll_id) do
      %{status: :cancelled} = poll ->
        Enum.each(poll.participants, &deliver_cancellation(poll, &1, job_id))

      # Deleted straight after it was cancelled, before this ran.
      nil ->
        Logger.info("Skipping poll cancellation emails: the poll no longer exists",
          poll_id: poll_id
        )

        {:discard, @poll_gone}

      # A poll that is not cancelled has nothing to announce.
      _poll ->
        {:discard, @poll_closed}
    end
  end

  defp deliver_cancellation(poll, participant, job_id) do
    DeliveryClaims.once(job_id, "participant:#{participant.id}", fn ->
      poll |> PollCancelled.render(participant) |> Delivery.deliver()
    end)
  end

  defp recipient(args) do
    %PollParticipantSchema{
      id: args["id"],
      name: args["name"],
      email: args["email"],
      locale: args["locale"]
    }
  end

  # Who voted since the host's last update and before `cutoff`, in the order
  # they voted, and apart from them whoever voted since and at or after
  # `cutoff`: too recently for this update.
  defp voters_since_update(poll, cutoff) do
    poll.participants
    |> Enum.filter(&voted_since?(&1, poll.vote_digest_sent_at))
    |> Enum.sort_by(& &1.voted_at, DateTime)
    |> Enum.split_with(&DateTime.before?(&1.voted_at, cutoff))
  end

  defp voted_since?(%{voted_at: nil}, _since), do: false
  defp voted_since?(_participant, nil), do: true
  defp voted_since?(%{voted_at: voted_at}, since), do: not DateTime.before?(voted_at, since)

  # Whole seconds, as `voted_at` is stored, and a settle minute back. A job
  # discarded after this leaves only its remembered cutoff, pruned with the job.
  defp host_update_cutoff(job_id, name) do
    now =
      Clock.utc_now()
      |> DateTime.truncate(:second)
      |> DateTime.add(-@vote_settle_seconds, :second)

    {:ok, cutoff, _offset} =
      job_id
      |> DeliveryClaims.remember(name, DateTime.to_iso8601(now))
      |> DateTime.from_iso8601()

    cutoff
  end

  # Never moves back (the query's condition): a rerun's kept cutoff, or a
  # nudge's, can be earlier than an update that has gone out since.
  defp mark_host_updated(poll, cutoff), do: PollQueries.mark_vote_digest_sent(poll.id, cutoff)

  # Like `with_open_poll/3`, and a job scheduled for a deadline the poll no
  # longer has is discarded. Jobs from before deadlines were carried, and the
  # all-voted nudge, have none to compare.
  defp with_current_deadline(poll_id, args, action, fun) do
    with_open_poll(poll_id, action, fn poll ->
      case {args["deadline_at"], poll.deadline_at} do
        {nil, _current} ->
          fun.(poll)

        {scheduled_for, %DateTime{} = current} ->
          if scheduled_for == PollScheduler.deadline_arg(current),
            do: fun.(poll),
            else: stale(poll_id, action)

        {_scheduled_for, nil} ->
          stale(poll_id, action)
      end
    end)
  end

  defp stale(poll_id, action) do
    Logger.info("Skipping poll email — scheduled for a deadline that has changed",
      email_action: action,
      poll_id: poll_id
    )

    {:discard, @stale_deadline}
  end

  # A host whose account is about to be deleted is told nothing more about
  # their polls (`Tymeslot.Auth.deletion_pending?/1`; the poll's user is
  # preloaded, so this costs no query).
  defp with_host_staying(poll, action, fun) do
    if Auth.deletion_pending?(poll.user) do
      Logger.info("Skipping poll email: host account pending deletion",
        email_action: action,
        poll_id: poll.id
      )

      {:discard, @host_leaving}
    else
      fun.()
    end
  end

  # Fetches the poll with its host preloaded and runs `fun` only while the poll is
  # still open. A missing or already-decided poll discards the job rather than
  # retrying forever.
  defp with_open_poll(poll_id, action, fun) do
    case PollQueries.get_with_host(poll_id) do
      nil ->
        Logger.warning("Attempted to send poll email for non-existent poll",
          email_action: action,
          poll_id: poll_id
        )

        {:discard, @poll_gone}

      %{status: :open} = poll ->
        fun.(poll)

      poll ->
        Logger.info("Skipping poll email — poll is not open",
          email_action: action,
          poll_id: poll_id,
          status: poll.status
        )

        {:discard, @poll_closed}
    end
  end

  defp personal_url(poll, username, participant) do
    UrlBuilder.build_url("/#{username}/poll/#{poll.token}?p=#{participant.token}")
  end

  defp results_url, do: UrlBuilder.build_url("/dashboard/polls")

  defp host_username(%{user: %{profile: %ProfileSchema{username: username}}})
       when is_binary(username),
       do: username

  defp host_username(_poll), do: nil

  defp variant_atom("all_voted"), do: :all_voted
  defp variant_atom("deadline_passed"), do: :deadline_passed
end
