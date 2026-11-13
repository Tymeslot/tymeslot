defmodule Tymeslot.Notifications.Email.SeriesEmails do
  @moduledoc """
  The email jobs of a booking series: its one confirmation, sent once every
  session's video room is ready (`Tymeslot.Workers.SeriesAnnouncementWorker`
  queues it), and the cancellation of several of its sessions at once.

  Each job writes to the booker and the organiser, claiming each send on the
  job (`Tymeslot.Workers.DeliveryClaims`), so a retry sends only what has
  not gone out.
  """

  require Logger

  alias Tymeslot.BookingSeries.Notifications
  alias Tymeslot.BookingSeries.SeriesQueries
  alias Tymeslot.Emails.SeriesBuilder
  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.MeetingPayments
  alias Tymeslot.Notifications.Email.DeliveryOutcome
  alias Tymeslot.Workers.DeliveryClaims

  @series_gone "Series not found"
  @series_cancelled "Series cancelled"
  @nothing_live "No session of the series is still booked"
  @nothing_cancelled "None of the sessions is cancelled"

  @doc """
  Whether `reason`, from a discard this module returned, is an expected end
  of the email job rather than a fault.
  """
  @spec expected_discard?(term()) :: boolean()
  def expected_discard?(reason),
    do: reason in [@series_gone, @series_cancelled, @nothing_live, @nothing_cancelled]

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
    case MeetingPayments.payment_for_series(series.id) do
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
          apply(email_service, send_fun, [role, email, details])
        end)
      end

    DeliveryOutcome.from_results(label, [series_id: details.series.id], results)
  end
end
