defmodule Tymeslot.Workers.EmailWorkerHandlers.PollEmails do
  @moduledoc """
  Handles poll-related email actions: deadline reminders to unvoted participants
  and pick-a-time nudges to the host.
  """

  require Logger

  alias Tymeslot.Emails.Delivery
  alias Tymeslot.Emails.Templates.PollDeadlineReminder
  alias Tymeslot.Emails.Templates.PollHostNudge
  alias Tymeslot.Polls.PollParticipantQueries
  alias Tymeslot.Polls.PollQueries
  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.Utils.UrlBuilder

  @spec handle_deadline_reminders(%{String.t() => term()}) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_deadline_reminders(%{"poll_id" => poll_id}) do
    with_open_poll(poll_id, "poll deadline reminders", fn poll ->
      # Without a host username the public voting page has no working URL, so the
      # reminder's call-to-action would be broken. Discard rather than sending a
      # dead link to every participant.
      case host_username(poll) do
        nil ->
          Logger.warning("Skipping poll deadline reminders — host has no username",
            poll_id: poll_id
          )

          {:discard, "host has no username"}

        username ->
          deliver_deadline_reminders(poll, username)
      end
    end)
  end

  defp deliver_deadline_reminders(poll, username) do
    voting_url = voting_url(poll, username)

    poll.id
    |> PollParticipantQueries.list_unvoted_for_poll()
    |> Enum.each(fn participant ->
      poll
      |> PollDeadlineReminder.render(participant, voting_url)
      |> Delivery.deliver()
    end)

    :ok
  end

  @spec handle_host_nudge(%{String.t() => term()}) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_host_nudge(%{"poll_id" => poll_id, "variant" => variant}) do
    with_open_poll(poll_id, "poll host nudge", fn poll ->
      poll
      |> PollHostNudge.render(variant_atom(variant), results_url())
      |> Delivery.deliver()

      :ok
    end)
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

        {:discard, "poll not found"}

      %{status: :open} = poll ->
        fun.(poll)

      poll ->
        Logger.info("Skipping poll email — poll is not open",
          email_action: action,
          poll_id: poll_id,
          status: poll.status
        )

        {:discard, "poll not open"}
    end
  end

  defp voting_url(poll, username) do
    UrlBuilder.build_url("/#{username}/poll/#{poll.token}")
  end

  defp results_url, do: UrlBuilder.build_url("/dashboard/polls")

  defp host_username(%{user: %{profile: %ProfileSchema{username: username}}})
       when is_binary(username),
       do: username

  defp host_username(_poll), do: nil

  defp variant_atom("all_voted"), do: :all_voted
  defp variant_atom("deadline_passed"), do: :deadline_passed
end
