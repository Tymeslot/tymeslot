defmodule Tymeslot.Notifications.Email.PollEmails do
  @moduledoc """
  Handles poll-related email actions: invitations, participants' voting links
  and receipts, deadline reminders to unvoted participants, and for the host
  pick-a-time nudges and updates on new votes.

  Every email to a participant carries their personal `?p=` link, read from
  the participant here rather than from the job args.
  """

  require Logger

  alias Tymeslot.Emails.Delivery
  alias Tymeslot.Emails.Templates.PollDeadlineReminder
  alias Tymeslot.Emails.Templates.PollHostNudge
  alias Tymeslot.Emails.Templates.PollInvitation
  alias Tymeslot.Emails.Templates.PollParticipantLink
  alias Tymeslot.Emails.Templates.PollVoteDigest
  alias Tymeslot.Emails.Templates.PollVoteReceipt
  alias Tymeslot.Polls.PollParticipantQueries
  alias Tymeslot.Polls.PollQueries
  alias Tymeslot.Polls.PollSchema
  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.Utils.UrlBuilder
  alias Tymeslot.Workers.DeliveryClaims

  # The poll is gone or closed, or its host has no public page to link to.
  @no_username "host has no username"
  @poll_gone "poll not found"
  @poll_closed "poll not open"
  # An unconfirmed participant pruned before their email went out.
  @participant_gone "poll participant not found"

  @doc """
  Whether `reason`, from a discard this module returned, is an expected end
  of the email job rather than a fault
  (see `Tymeslot.Infrastructure.ExpectedJobOutcome`).
  """
  @spec expected_discard?(term()) :: boolean()
  def expected_discard?(reason),
    do: reason in [@no_username, @poll_gone, @poll_closed, @participant_gone]

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
  def handle_deadline_reminders(%{"poll_id" => poll_id}, job_id) do
    with_open_poll(poll_id, "poll deadline reminders", fn poll ->
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
  def handle_host_nudge(%{"poll_id" => poll_id, "variant" => variant}, job_id) do
    with_open_poll(poll_id, "poll host nudge", fn poll ->
      DeliveryClaims.once(job_id, "host", fn ->
        poll
        |> PollHostNudge.render(variant_atom(variant), results_url())
        |> Delivery.deliver()
      end)

      # The nudge carries the standings, so it counts as the host's update on
      # new votes: a pending one then has nothing new to tell.
      mark_host_updated(poll, DateTime.utc_now())
    end)
  end

  @doc """
  Emails the host an update naming who voted or changed their responses since
  their last one, with the standings. Sends nothing when the host has turned
  updates off since the job was scheduled, or when nothing is new, e.g.
  because a nudge carried the same standings in the meantime.
  """
  @spec handle_vote_digest(%{String.t() => term()}, DeliveryClaims.job_id()) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_vote_digest(%{"poll_id" => poll_id}, job_id) do
    with_open_poll(poll_id, "poll vote digest", fn poll ->
      cutoff = DateTime.utc_now()

      case {poll.notify_on_vote, voted_since_update(poll, cutoff)} do
        {false, _voters} ->
          :ok

        {true, []} ->
          :ok

        {true, voters} ->
          delivered =
            DeliveryClaims.once(job_id, "host", fn ->
              poll
              |> PollVoteDigest.render(voters, results_url())
              |> Delivery.deliver()
              |> delivery_outcome()
            end)

          with :ok <- delivered, do: mark_host_updated(poll, cutoff)
      end
    end)
  end

  # Who voted after the host's last update and up to `cutoff`, in the order
  # they voted. Votes after `cutoff` scheduled the next update.
  defp voted_since_update(poll, cutoff) do
    since = poll.vote_digest_sent_at

    poll.participants
    |> Enum.filter(fn participant ->
      participant.voted_at != nil and
        (since == nil or DateTime.compare(participant.voted_at, since) == :gt) and
        DateTime.compare(participant.voted_at, cutoff) != :gt
    end)
    |> Enum.sort_by(& &1.voted_at, DateTime)
  end

  defp mark_host_updated(poll, at) do
    case PollQueries.update(PollSchema.vote_digest_sent_changeset(poll, at)) do
      {:ok, _poll} -> :ok
      {:error, changeset} -> {:error, changeset}
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
