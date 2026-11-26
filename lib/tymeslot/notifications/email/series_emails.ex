defmodule Tymeslot.Notifications.Email.SeriesEmails do
  @moduledoc """
  The email jobs of a booking series: its one confirmation, sent once every
  session's video room is ready (`Tymeslot.Workers.SeriesAnnouncementWorker`
  queues it), the cancellation of several of its sessions at once, and for a
  series held for approval its one request, the host's one reminder of it,
  and, when it is declined or expires, the booker's answer.

  Each job but the answer writes to the booker and the organiser, claiming
  each send on the job (`Tymeslot.Workers.DeliveryClaims`), so a retry sends
  only what has not gone out.
  """

  require Logger

  alias Tymeslot.Bookings.MeetingLinks
  alias Tymeslot.BookingSeries.Approval, as: SeriesApproval
  alias Tymeslot.BookingSeries.Notifications
  alias Tymeslot.BookingSeries.SeriesQueries
  alias Tymeslot.Emails.SeriesBuilder
  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.MeetingPayments.BookingPayments
  alias Tymeslot.Meetings.Approval
  alias Tymeslot.Meetings.ApprovalToken
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Notifications.Email.DeliveryOutcome
  alias Tymeslot.Workers.DeliveryClaims

  @series_gone "Series not found"
  @series_cancelled "Series cancelled"
  @nothing_live "No session of the series is still booked"
  @nothing_cancelled "None of the sessions is cancelled"
  @nothing_held "No session of the series is awaiting approval"
  @outcome_changed "No session of the series is released that way"

  @doc """
  Whether `reason`, from a discard this module returned, is an expected end
  of the email job rather than a fault.
  """
  @spec expected_discard?(term()) :: boolean()
  def expected_discard?(reason),
    do:
      reason in [
        @series_gone,
        @series_cancelled,
        @nothing_live,
        @nothing_cancelled,
        @nothing_held,
        @outcome_changed
      ]

  @doc """
  The series' confirmation to its booker and organiser, listing every
  session of the series in its place ("Session 2 of 4"), a session already
  cancelled by the time it runs marked so rather than left out, so the
  count in the subject is the count in the list. A paid series shows the
  total it was paid. Discarded when the series
  was cancelled, or none of its sessions is still booked.
  """
  @spec handle_series_confirmation(%{String.t() => term()}, DeliveryClaims.job_id()) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_series_confirmation(%{"series_id" => series_id}, job_id) do
    with_series(series_id, fn series ->
      occurrences = SeriesQueries.list_occurrences(series)

      with :ok <- not_cancelled(series),
           {[_first | _rest], gone} <- Enum.split_with(occurrences, &Notifications.live?/1) do
        details =
          SeriesBuilder.build(series, occurrences,
            cancelled: Enum.map(gone, & &1.id),
            currency: paid_currency(series)
          )

        send_both("series_confirmation", details, :send_series_confirmation, job_id)
      else
        {[], _gone} -> {:discard, @nothing_live}
        {:discard, _reason} = discard -> discard
      end
    end)
  end

  @doc """
  The cancellation of the sessions `occurrence_ids` names (meeting ids, or
  seat ids on a group type), to the booker and the organiser, worded for
  whoever cancelled them (`cancelled_by`). Only the named sessions that are
  cancelled are listed.
  """
  @spec handle_series_cancellation(%{String.t() => term()}, DeliveryClaims.job_id()) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_series_cancellation(
        %{"series_id" => series_id, "occurrence_ids" => ids, "cancelled_by" => cancelled_by},
        job_id
      ) do
    with_series(series_id, fn series ->
      case Notifications.cancelled_occurrences(series, ids) do
        [] ->
          {:discard, @nothing_cancelled}

        cancelled ->
          details =
            series
            |> SeriesBuilder.build(cancelled)
            |> Map.put(:cancelled_by, cancelled_by(cancelled_by))

          send_both("series_cancellation", details, :send_series_cancellation, job_id)
      end
    end)
  end

  @doc """
  The request of a series held for approval: to the organiser, with every
  session, the deadline and the approve and decline links, and to the
  booker, acknowledging it. The links are the first session's: answering it
  answers the series (`Tymeslot.BookingSeries.Approval`). Discarded when no
  session is still awaiting approval, as a request answered (or withdrawn)
  before the job ran must not be presented as open.
  """
  @spec handle_series_request(%{String.t() => term()}, DeliveryClaims.job_id()) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_series_request(%{"series_id" => series_id}, job_id) do
    with_series(series_id, fn series ->
      case Enum.filter(SeriesQueries.list_meetings(series), &MeetingState.awaiting_approval?/1) do
        [] ->
          {:discard, @nothing_held}

        held ->
          details = request_details(series, held)
          send_both("series_request", details, :send_series_request, job_id)
      end
    end)
  end

  @doc """
  Reminds the organiser, once, of a series request they have not answered
  halfway to its deadline: the request again, framed as a reminder. Sent
  only while the series is still an open request
  (`Tymeslot.BookingSeries.Approval.series_request?/1`); answered,
  withdrawn, or no longer held as one, it is discarded.
  """
  @spec handle_series_request_nudge(%{String.t() => term()}, DeliveryClaims.job_id()) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_series_request_nudge(%{"series_id" => series_id}, job_id) do
    with_series(series_id, fn series ->
      held = Enum.filter(SeriesQueries.list_meetings(series), &MeetingState.awaiting_approval?/1)

      if held != [] and SeriesApproval.series_request?(hd(held)) do
        details =
          series |> request_details(held) |> Map.put(:nudge, true) |> recipient_copy(:organizer)

        email_service = Config.email_service_module()

        sent =
          DeliveryClaims.once(job_id, "series_request_nudge:organizer", fn ->
            email_service.send_series_request(:organizer, details.organizer_email, details)
          end)

        DeliveryOutcome.from_results("series_request_nudge", [series_id: series.id], [sent])
      else
        {:discard, @nothing_held}
      end
    end)
  end

  defp request_details(series, [first | _rest] = held) do
    series
    |> SeriesBuilder.build(held)
    |> Map.merge(%{
      approval_urls: MeetingLinks.approval_urls(ApprovalToken.sign(first)),
      approval_deadline_at: first.approval_deadline_at,
      attendee_message: first.attendee_message
    })
  end

  @doc """
  Tells the booker their series request was declined (`"declined"`, with
  the host's reason when they gave one) or expired (`"expired"`), listing
  the sessions it held. Guarded on the sessions' status matching the
  variant, as `BookingApprovalEmails` guards a single request's.
  """
  @spec handle_series_request_outcome(%{String.t() => term()}) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_series_request_outcome(%{"series_id" => series_id, "variant" => variant})
      when variant in ["declined", "expired"] do
    variant = String.to_existing_atom(variant)

    with_series(series_id, fn series ->
      case Enum.filter(SeriesQueries.list_meetings(series), &released_as?(&1, variant)) do
        [] ->
          {:discard, @outcome_changed}

        [first | _rest] = released ->
          details =
            series
            |> SeriesBuilder.build(released)
            |> Map.put(:decline_reason, first.decline_reason)

          sent =
            Config.email_service_module().send_series_request_outcome(
              variant,
              details.attendee_email,
              details
            )

          DeliveryOutcome.from_results("series_request_outcome", [series_id: series.id], [sent])
      end
    end)
  end

  defp released_as?(meeting, :declined), do: Approval.declined?(meeting)
  defp released_as?(meeting, :expired), do: MeetingState.expired?(meeting)

  defp with_series(series_id, fun) do
    case SeriesQueries.get(series_id) do
      {:ok, series} ->
        fun.(series)

      {:error, :not_found} ->
        Logger.warning("Series not found, discarding its email", series_id: series_id)
        {:discard, @series_gone}
    end
  end

  # A paid series shows the total it was paid, in the currency its one
  # payment took.
  defp paid_currency(series) do
    case BookingPayments.payment_for_series(series.id) do
      %{paid_at: %DateTime{}, currency: currency} -> currency
      _unpaid_or_free -> nil
    end
  end

  defp not_cancelled(%{cancelled_at: nil}), do: :ok
  defp not_cancelled(_series), do: {:discard, @series_cancelled}

  defp cancelled_by("organizer"), do: :organizer
  defp cancelled_by(_attendee), do: :attendee

  defp send_both(label, details, send_fun, job_id) do
    email_service = Config.email_service_module()

    results =
      for {role, email} <- [attendee: details.attendee_email, organizer: details.organizer_email] do
        DeliveryClaims.once(job_id, "#{label}:#{role}", fn ->
          apply(email_service, send_fun, [role, email, recipient_copy(details, role)])
        end)
      end

    DeliveryOutcome.from_results(label, [series_id: details.series.id], results)
  end

  # The payload is built for the booker, in their language; the organiser
  # reads their own wording, as in a single booking's emails.
  defp recipient_copy(details, :organizer), do: SeriesBuilder.organizer_copy(details)
  defp recipient_copy(details, :attendee), do: details
end
