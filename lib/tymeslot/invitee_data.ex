defmodule Tymeslot.InviteeData do
  @moduledoc """
  Erasure and retention of the personal data invitees give a host: the
  people who book a meeting, take a group seat, are added as a guest, or
  answer a poll.

  Two paths remove it, and both anonymise rather than delete, so a host's
  meeting history and statistics (time, meeting type, status, how the booking
  was found) survive:

    * `erase/1` and `erase_for_host/2` act on one person's request, found by
      email. `erase/1` is the operator's path across every host, run from a
      release shell; `erase_for_host/2` keeps to one host's meetings and polls.
    * `anonymise_expired/1` is the retention purge, run daily by
      `Tymeslot.Workers.DataRetentionWorker` with `invitee_data_days` (two
      years by default). It clears every meeting that ended before the window,
      with its seats, guests and booking payments, and the participants of
      every poll whose last proposed time did.

  An erasure removes only that person's own entries. The guests a booker
  added are people in their own right and are left as they are, until their
  meeting ages out or they ask themselves.

  Upcoming bookings are refused rather than erased: a confirmed meeting with
  its invitee's address removed could no longer be cancelled, moved or
  reminded about. Cancel them first, then erase.

  Booking payments keep their amounts for the statutory period
  (`Tymeslot.MeetingPayments.DataRetention`); only the attendee's name and
  email are cleared.
  """

  require Logger

  alias Tymeslot.Clock
  alias Tymeslot.InviteeData.InviteeDataQueries, as: Queries
  alias Tymeslot.Repo

  @batch_size 500

  @type counts :: %{
          meetings: non_neg_integer(),
          participants: non_neg_integer(),
          guests: non_neg_integer(),
          poll_participants: non_neg_integer(),
          booking_payments: non_neg_integer(),
          deliveries: non_neg_integer()
        }

  @type erase_error :: :invalid_email | {:upcoming_meetings, [String.t()]}

  @doc """
  Erases everything held under `email` for every host. For an operator
  answering an erasure request, from a release shell.
  """
  @spec erase(String.t()) :: {:ok, counts()} | {:error, erase_error()}
  def erase(email), do: do_erase(email, :all)

  @doc """
  Erases everything `email` gave the host `host_user_id`, and nothing they
  gave anyone else.
  """
  @spec erase_for_host(integer(), String.t()) :: {:ok, counts()} | {:error, erase_error()}
  def erase_for_host(host_user_id, email) when is_integer(host_user_id),
    do: do_erase(email, host_user_id)

  @doc """
  Anonymises the invitee data of meetings and polls that ended more than
  `days` days ago. Returns `{anonymised_count, nil}`, the shape
  `DataRetentionWorker` expects; a window that is not a positive number of
  days anonymises nothing.
  """
  @spec anonymise_expired(integer()) :: {non_neg_integer(), nil}
  def anonymise_expired(days) when is_integer(days) and days > 0 do
    now = DateTime.truncate(Clock.utc_now(), :second)
    cutoff = DateTime.add(now, -days, :day)

    meetings =
      drain(
        fn -> Queries.meeting_ids_ended_before(cutoff, @batch_size) end,
        &expire_meetings(&1, now)
      )

    poll_participants =
      drain(
        fn -> Queries.poll_participant_ids_ended_before(cutoff, @batch_size) end,
        &(&1 |> Queries.scrub_poll_participants(now) |> elem(0))
      )

    {meetings + poll_participants, nil}
  end

  def anonymise_expired(_days), do: {0, nil}

  defp do_erase(email, scope) when is_binary(email) do
    case email |> String.trim() |> String.downcase() do
      "" -> {:error, :invalid_email}
      normalised -> erase_normalised(normalised, scope)
    end
  end

  defp do_erase(_email, _scope), do: {:error, :invalid_email}

  defp erase_normalised(email, scope) do
    now = DateTime.truncate(Clock.utc_now(), :second)

    result =
      Repo.transaction(fn ->
        case Queries.upcoming_meeting_uids(email, scope, now) do
          [] -> erase_rows(email, scope, now)
          uids -> Repo.rollback({:upcoming_meetings, uids})
        end
      end)

    log_erasure(result, scope)
    result
  end

  defp erase_rows(email, scope, now) do
    meeting_ids = Queries.meeting_ids_for_attendee(email, scope)
    participants = Queries.participant_rows_for_email(email, scope)
    guests = Queries.guest_rows_for_email(email, scope)
    poll_participant_ids = Queries.poll_participant_ids_for_email(email, scope)

    touched_meetings =
      Enum.uniq(
        meeting_ids ++ Enum.map(participants, &elem(&1, 1)) ++ Enum.map(guests, &elem(&1, 1))
      )

    %{
      meetings: count(Queries.scrub_meetings(meeting_ids, now)),
      participants:
        count(Queries.scrub_participants({:ids, Enum.map(participants, &elem(&1, 0))}, now)),
      guests: count(Queries.scrub_guests({:ids, Enum.map(guests, &elem(&1, 0))}, now)),
      poll_participants: count(Queries.scrub_poll_participants(poll_participant_ids, now)),
      booking_payments: count(Queries.scrub_booking_payments({:email, email, scope}, now)),
      deliveries: Queries.delete_deliveries(touched_meetings)
    }
  end

  defp expire_meetings(meeting_ids, now) do
    {:ok, count} =
      Repo.transaction(fn ->
        Queries.scrub_participants({:meetings, meeting_ids}, now)
        Queries.scrub_guests({:meetings, meeting_ids}, now)
        Queries.scrub_booking_payments({:meetings, meeting_ids}, now)
        Queries.delete_deliveries(meeting_ids)
        count(Queries.scrub_meetings(meeting_ids, now, erased_at: now))
      end)

    count
  end

  # Runs `fetch` and `process` until `fetch` returns a short batch. Each
  # processed batch drops out of what `fetch` selects, so this terminates.
  defp drain(fetch, process, total \\ 0) do
    case fetch.() do
      [] ->
        total

      ids when length(ids) < @batch_size ->
        total + process.(ids)

      ids ->
        drain(fetch, process, total + process.(ids))
    end
  end

  defp count({count, _rows}), do: count

  defp log_erasure({:ok, counts}, scope),
    do:
      Logger.info(
        "Erased invitee data",
        Keyword.merge(Map.to_list(counts), host_user_id: host(scope))
      )

  defp log_erasure({:error, {:upcoming_meetings, uids}}, scope),
    do:
      Logger.info("Refused to erase invitee data with upcoming meetings",
        host_user_id: host(scope),
        upcoming_count: length(uids)
      )

  defp host(:all), do: nil
  defp host(host_user_id), do: host_user_id
end
