defmodule TymeslotWeb.Dashboard.BookingsManagement.SeriesActions do
  @moduledoc """
  A booked series on the bookings dashboard: the modal listing every session
  of it ("View series" on a session's card), and cancelling every session
  still to come from there, with the refund the host chooses for a paid
  series.

  Every event the component receives under the `series:` prefix lands in
  `handle_event/4`, so the component only routes them. The series is found
  through `Tymeslot.BookingSeries.get_for_organizer/2`, which checks the
  signed-in host owns it; an id from the client is never loaded on its own.
  What the cancellation does, and what it refunds, is
  `Tymeslot.BookingSeries.cancel_remaining/2`'s; this module maps its
  outcome to a flash and to the list, which `reload` redraws: the sessions
  it cancelled are on the page as ordinary cards, and redrawing the page
  re-inserts every one of them.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  require Logger

  alias Tymeslot.BookingSeries
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.Hooks.ModalHook
  alias TymeslotWeb.Live.Shared.Flash
  alias TymeslotWeb.Live.Shared.RateLimit

  import TymeslotWeb.Components.PaymentHelpers, only: [format_amount: 2]

  @type socket :: Phoenix.LiveView.Socket.t()
  @typep reload :: (socket() -> socket())

  @series_modal {:show_series_modal, :series_modal_data}
  @cancel_modal {:show_cancel_series_modal, :cancel_series_modal_data}

  # Refusals of the host's refund choice, shown beside it for another try.
  @form_errors [
    :acknowledgement_required,
    :exceeds_remaining,
    :invalid_amount,
    :not_paid,
    :outside_refund_window,
    :under_dispute
  ]

  @doc "The series modal and its cancel confirmation, closed."
  @spec mount(socket()) :: socket()
  def mount(socket),
    do: ModalHook.mount_modal(socket, [{@series_modal, false}, {@cancel_modal, false}])

  @doc """
  Handles a `series:` event: `series:show` (with the series id as
  `"series"`), `series:hide`, `series:ask_cancel`, `series:hide_cancel` and
  `series:confirm_cancel` (the refund form).
  """
  @spec handle_event(String.t(), map(), socket(), reload()) :: {:noreply, socket()}
  def handle_event("series:show", params, socket, _reload), do: {:noreply, show(socket, params)}

  def handle_event("series:hide", _params, socket, _reload),
    do: {:noreply, ModalHook.hide_modal(socket, @series_modal)}

  # The confirmation replaces the series modal rather than stacking on it:
  # two dialogs open at once would each close on a click in the other.
  def handle_event("series:ask_cancel", _params, socket, _reload) do
    ModalHook.with_modal_data(socket, @series_modal, fn overview ->
      {:noreply,
       socket
       |> ModalHook.hide_modal(@series_modal)
       |> ModalHook.show_modal(@cancel_modal, %{
         overview: overview,
         form: blank_form(),
         error: %{}
       })}
    end)
  end

  def handle_event("series:hide_cancel", _params, socket, _reload),
    do: {:noreply, ModalHook.hide_modal(socket, @cancel_modal)}

  def handle_event("series:confirm_cancel", params, socket, reload) do
    user_id = socket.assigns.current_user.id

    RateLimit.with_rate_limit(RateLimiter.check(:dashboard_cancel, user_id), socket, fn ->
      ModalHook.with_modal_data(socket, @cancel_modal, fn data ->
        {:noreply, confirm(socket, data, params, reload)}
      end)
    end)
  end

  def handle_event(_unknown, _params, socket, _reload), do: {:noreply, socket}

  defp show(socket, params) do
    case BookingSeries.get_for_organizer(params["series"], socket.assigns.current_user.id) do
      {:ok, series} ->
        ModalHook.show_modal(socket, @series_modal, BookingSeries.organizer_overview(series))

      {:error, :not_found} ->
        Flash.error(dgettext("dashboard_booking_series", "That series could not be found."))
        socket
    end
  end

  defp confirm(socket, %{overview: overview} = data, params, reload) do
    form = refund_form(params)

    case BookingSeries.resolve_refund_choice(overview.payment, params) do
      {:ok, refund} -> cancel(socket, data, refund, form, reload)
      {:error, reason} -> refuse(socket, data, form, reason)
    end
  end

  defp cancel(socket, %{overview: overview} = data, refund, form, reload) do
    result =
      BookingSeries.cancel_remaining(overview.series,
        caller: :organizer,
        acting_user: socket.assigns.current_user,
        refund: refund
      )

    case result do
      {:ok, %{cancelled: cancelled, refund: outcome}} ->
        Flash.info(cancelled_message(length(cancelled), outcome, overview.payment))
        close(socket, reload)

      {:error, reason} when reason in @form_errors ->
        refuse(socket, data, form, reason)

      {:error, :nothing_to_cancel} ->
        Flash.info(
          dgettext("dashboard_booking_series", "No session of this series is left to cancel.")
        )

        close(socket, reload)

      {:error, :not_found} ->
        Flash.error(dgettext("dashboard_booking_series", "That series could not be found."))
        close(socket, reload)

      {:error, reason} ->
        Logger.error("Failed to cancel a series from the dashboard",
          series_id: overview.series.id,
          reason: LogFormat.reason(reason)
        )

        Flash.error(
          dgettext(
            "dashboard_booking_series",
            "The sessions could not be cancelled. Please try again."
          )
        )

        socket
    end
  end

  defp refuse(socket, data, form, reason) do
    ModalHook.show_modal(socket, @cancel_modal, %{data | form: form, error: form_error(reason)})
  end

  defp close(socket, reload) do
    socket
    |> ModalHook.hide_modal(@cancel_modal)
    |> reload.()
  end

  # Kept on a refusal: the choice lives in the browser until submit, and a
  # re-render without it would snap the radio back to the full refund.
  defp refund_form(params) do
    choice = params["cancel_refund_choice"]
    amount = params["cancel_refund_amount"]

    %{
      choice: if(choice in ["partial", "none"], do: choice, else: "full"),
      amount: if(is_binary(amount), do: amount, else: ""),
      acknowledged: params["cancel_refund_no_refund_ack"] == "true"
    }
  end

  defp blank_form, do: %{choice: "full", amount: "", acknowledged: false}

  defp form_error(:acknowledgement_required),
    do: %{
      acknowledgement:
        dgettext(
          "dashboard_booking_series",
          "Tick the acknowledgement to cancel without refunding the attendee."
        )
    }

  defp form_error(:exceeds_remaining),
    do: %{
      amount:
        dgettext(
          "dashboard_booking_series",
          "Refund amount exceeds the remaining refundable balance."
        )
    }

  defp form_error(:invalid_amount),
    do: %{amount: dgettext("dashboard_booking_series", "Enter a valid partial refund amount.")}

  defp form_error(:outside_refund_window),
    do: %{
      amount:
        dgettext(
          "dashboard_booking_series",
          "No refund can be made: the payment is older than the 60-day refund window. You can refund it from Stripe."
        )
    }

  defp form_error(:under_dispute),
    do: %{
      amount:
        dgettext(
          "dashboard_booking_series",
          "No refund can be made: the payment is under dispute. Settle the dispute in Stripe first."
        )
    }

  defp form_error(:not_paid),
    do: %{
      amount:
        dgettext("dashboard_booking_series", "No refund can be made: the series was not paid.")
    }

  defp cancelled_message(count, :none, _payment) do
    dngettext(
      "dashboard_booking_series",
      "%{count} session cancelled. The attendee has been told.",
      "%{count} sessions cancelled. The attendee has been told.",
      count
    )
  end

  # A series request is withdrawn whole and refunded in full, in the
  # background.
  defp cancelled_message(count, {:refunded, cents}, payment) do
    dngettext(
      "dashboard_booking_series",
      "%{count} session cancelled. Refund of %{amount} is being processed.",
      "%{count} sessions cancelled. Refund of %{amount} is being processed.",
      count,
      amount: format_amount(cents, payment_currency(payment))
    )
  end

  # The refund is made in the background; a failure is emailed to the host
  # (`Refunds.FailureNotice`).
  defp cancelled_message(count, {:scheduled, cents}, payment) do
    dngettext(
      "dashboard_booking_series",
      "%{count} session cancelled. Refund of %{amount} is being processed. We'll email you if it fails.",
      "%{count} sessions cancelled. Refund of %{amount} is being processed. We'll email you if it fails.",
      count,
      amount: format_amount(cents, payment_currency(payment))
    )
  end

  defp cancelled_message(count, {:not_refunded, :outside_refund_window}, _payment) do
    dngettext(
      "dashboard_booking_series",
      "%{count} session cancelled without a refund: the payment is older than the 60-day refund window. You can refund it from Stripe.",
      "%{count} sessions cancelled without a refund: the payment is older than the 60-day refund window. You can refund it from Stripe.",
      count
    )
  end

  defp cancelled_message(count, {:not_refunded, :under_dispute}, _payment) do
    dngettext(
      "dashboard_booking_series",
      "%{count} session cancelled without a refund: the payment is under dispute. Settle the dispute in Stripe first.",
      "%{count} sessions cancelled without a refund: the payment is under dispute. Settle the dispute in Stripe first.",
      count
    )
  end

  defp cancelled_message(count, {:not_refunded, :not_paid}, _payment) do
    dngettext(
      "dashboard_booking_series",
      "%{count} session cancelled without a refund: the series was not paid.",
      "%{count} sessions cancelled without a refund: the series was not paid.",
      count
    )
  end

  defp payment_currency(%{currency: currency}), do: currency
  defp payment_currency(_none), do: nil
end
