defmodule TymeslotWeb.Themes.Core.SeriesManagement do
  @moduledoc """
  The attendee's series page (`/:username/series/:series_uid`) for the
  scheduling dispatcher: loading the series behind the uid, and its events.

  The page lists every session (`Tymeslot.BookingSeries.attendee_overview/2`)
  and offers one action for the whole series, behind a confirmation step:
  "Cancel all remaining sessions", or, while the series is still an open
  approval request, "Withdraw request". Both are the one domain call
  `Tymeslot.BookingSeries.cancel_remaining/2`, which withdraws an open
  request whole and cancels the remaining sessions otherwise, and both are
  rate-limited as a single meeting's cancellation is.

  Events: `manage_series_confirm` (with `action`, `cancel_all` or
  `withdraw`) opens the confirmation, `manage_series_back` closes it (and
  sets `:series_refocus`, so the button that opened it takes the focus
  back), `manage_series_cancel_all` and `manage_series_withdraw` act.

  The series uid is the page's bearer, as a meeting's uid is for its
  cancel page: the series is looked up by it alone, then held to the
  organiser the URL names, so it is never drawn under another host's page.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [put_flash: 3, redirect: 2]

  require Logger

  alias Tymeslot.Bookings.MeetingLinks
  alias Tymeslot.BookingSeries
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.Helpers.ClientIP
  alias TymeslotWeb.Live.Shared.RateLimit

  @confirmations %{"cancel_all" => :cancel_all, "withdraw" => :withdraw}

  @doc """
  Loads the series `series_uid` names for the organiser `profile`.

  `{:ok, series}`; `{:redirect, path}` when the series belongs to another
  organiser whose current page is elsewhere (the link was handed out under
  a username its host has since given up and someone else claimed); and
  `{:error, :not_found}` otherwise.
  """
  @spec load(String.t() | nil, map()) ::
          {:ok, Tymeslot.BookingSeries.SeriesSchema.t()}
          | {:redirect, String.t()}
          | {:error, :not_found}
  def load(series_uid, %{user_id: user_id, username: username}) do
    case BookingSeries.get_for_attendee(series_uid) do
      {:ok, %{organizer_user_id: ^user_id} = series} -> {:ok, series}
      {:ok, _another_hosts} -> elsewhere(series_uid, username)
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  defp elsewhere(series_uid, username) do
    case MeetingLinks.current_series_path(series_uid) do
      {:ok, path} ->
        if String.starts_with?(path, "/#{username}/"),
          do: {:error, :not_found},
          else: {:redirect, path}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc "What a visitor is told when the series link leads nowhere."
  @spec not_found_message() :: String.t()
  def not_found_message,
    do:
      dgettext("booking_series", "This series could not be found. Check the link in your email.")

  @doc """
  Assigns the page's view of `series` (its sessions, read again) and closes
  any confirmation step.
  """
  @spec assign_series(Phoenix.LiveView.Socket.t(), Tymeslot.BookingSeries.SeriesSchema.t()) ::
          Phoenix.LiveView.Socket.t()
  def assign_series(socket, series) do
    overview = BookingSeries.attendee_overview(series, socket.assigns[:organizer_profile])

    assign(socket,
      series: overview.series,
      series_uid: overview.series.uid,
      series_sessions: overview.sessions,
      series_upcoming: overview.upcoming,
      series_held: overview.held_for_approval,
      series_open_request: overview.open_request,
      series_paid: overview.paid,
      series_timezone: overview.series.attendee_timezone || "Etc/UTC",
      series_confirm: nil,
      series_refocus: false
    )
  end

  @doc "Handles the series page's events (see the module docs)."
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event(event, params, %{assigns: %{live_action: :series}} = socket),
    do: series_event(event, params, socket)

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp series_event("manage_series_confirm", %{"action" => action}, socket) do
    case Map.fetch(@confirmations, action) do
      {:ok, confirm} ->
        {:noreply,
         assign(socket, series_confirm: offered(socket, confirm), series_refocus: false)}

      :error ->
        {:noreply, socket}
    end
  end

  defp series_event("manage_series_back", _params, socket),
    do: {:noreply, assign(socket, series_confirm: nil, series_refocus: true)}

  defp series_event(
         "manage_series_cancel_all",
         _params,
         %{assigns: %{series_confirm: :cancel_all}} = socket
       ),
       do: cancel_remaining(socket, :cancelled)

  defp series_event(
         "manage_series_withdraw",
         _params,
         %{assigns: %{series_confirm: :withdraw}} = socket
       ),
       do: cancel_remaining(socket, :withdrawn)

  defp series_event(_event, _params, socket), do: {:noreply, socket}

  # An open request is withdrawn whole; otherwise the remaining sessions
  # are cancelled. A withdrawal is only ever a withdrawal: a host who
  # answered meanwhile leaves the series as they left it, and the page says
  # so with the sessions as they now stand.
  defp cancel_remaining(socket, outcome) do
    with_rate_limit(socket, fn ->
      socket.assigns.series
      |> BookingSeries.cancel_remaining(caller: :attendee, expect: expected(outcome))
      |> settle(socket, outcome)
    end)
  end

  defp expected(:withdrawn), do: :withdraw
  defp expected(:cancelled), do: nil

  # Only what the page offers can be confirmed.
  defp offered(%{assigns: %{series_open_request: true}}, :withdraw), do: :withdraw

  defp offered(%{assigns: %{series_open_request: false, series_upcoming: count}}, :cancel_all)
       when count > 0,
       do: :cancel_all

  defp offered(_socket, _confirm), do: nil

  defp with_rate_limit(socket, action) do
    RateLimit.with_rate_limit(
      RateLimiter.check(:meeting_cancel, ClientIP.get(socket)),
      socket,
      action,
      flash: :socket
    )
  end

  # The page reads the series again whatever happened, so it shows how the
  # sessions stand now.
  defp settle({:ok, _result}, socket, outcome) do
    {:noreply,
     socket
     |> assign_series(socket.assigns.series)
     |> put_flash(:info, done_message(outcome))}
  end

  defp settle({:error, :not_awaiting_approval}, socket, :withdrawn) do
    {:noreply,
     socket
     |> assign_series(socket.assigns.series)
     |> put_flash(
       :info,
       dgettext(
         "booking_series",
         "The host answered your request in the meantime, so nothing was withdrawn. The list shows where each session now stands."
       )
     )}
  end

  defp settle({:error, reason}, socket, outcome) do
    Logger.warning("Attendee series action failed",
      series_id: socket.assigns.series.id,
      action: outcome,
      reason: LogFormat.reason(reason)
    )

    {:noreply,
     socket
     |> assign_series(socket.assigns.series)
     |> put_flash(:error, error_message(reason))}
  end

  defp done_message(:cancelled),
    do: dgettext("booking_series", "Your remaining sessions are cancelled. We've emailed you.")

  defp done_message(:withdrawn),
    do: dgettext("booking_series", "Your request is withdrawn. We've emailed you.")

  # Someone else (the host, or this booker in another tab) got there first.
  defp error_message(reason) when reason in [:nothing_to_cancel, :not_awaiting_approval],
    do:
      dgettext(
        "booking_series",
        "Nothing was left to cancel. The list shows where each session stands."
      )

  defp error_message(_reason),
    do: dgettext("booking_series", "The sessions could not be cancelled. Please try again.")

  @doc """
  The redirect for a series link that leads nowhere, as a meeting link's:
  to the booking page of the host `profile` the link names, with the reason.
  """
  @spec not_found_redirect(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def not_found_redirect(socket, %{username: username}) do
    socket
    |> put_flash(:error, not_found_message())
    |> redirect(to: "/" <> username)
  end
end
