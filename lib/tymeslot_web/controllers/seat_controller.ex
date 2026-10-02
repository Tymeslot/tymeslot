defmodule TymeslotWeb.SeatController do
  @moduledoc """
  Public, unauthenticated seat management for group-booking participants via
  the tokenised links in their confirmation email.

  Mirrors `TymeslotWeb.GuestRsvpController`: a GET confirmation landing page
  (no mutation, safe for link prefetchers) and a POST that performs the
  write. The reschedule action redirects into the public booking picker for
  the same meeting type, carrying the token as `reschedule_seat_token`.

  The GET and the POST answer a link that can no longer be used with the same
  page, decided by the same domain checks (`Meetings.fetch_cancellable_seat/1`
  and `Meetings.cancel_seat/1`): a seat already given up or moved, a meeting
  the host cancelled, a meeting under way, a meeting that is over. Only a
  cancellation made by this very request reports that anyone was told.

  A page about a seat is written in the language the participant booked in
  (`participant.locale`), since the link is theirs and arrives from an email
  written in it; a token that resolves to no seat keeps the request's.
  """

  use TymeslotWeb, :controller
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Locales
  alias Tymeslot.Meetings
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Profiles
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.Helpers.ClientIP

  # ---------------------------------------------------------------------------
  # GET — cancellation confirmation landing page (read-only)
  # ---------------------------------------------------------------------------

  @spec cancel_confirm(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def cancel_confirm(conn, %{"token" => token}) do
    with :ok <- rate_limit(conn),
         {:ok, %{participant: participant, meeting: meeting}} <-
           Meetings.fetch_cancellable_seat(token) do
      conn
      |> put_participant_locale(participant)
      |> seat_page(dgettext("booking_manage", "Cancel your spot"))
      |> render(:cancel_confirm,
        participant: participant,
        meeting: meeting,
        token: token,
        keep_path: booking_page_path(meeting)
      )
    else
      error -> render_error(conn, error)
    end
  end

  # ---------------------------------------------------------------------------
  # POST — cancel the seat, render the confirmation
  # ---------------------------------------------------------------------------

  @spec cancel_submit(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def cancel_submit(conn, %{"token" => token}) do
    with :ok <- rate_limit(conn),
         {:ok, %{participant: participant, meeting: meeting}} <-
           Meetings.fetch_cancellable_seat(token),
         {:ok, _outcome} <- Meetings.cancel_seat(token) do
      conn
      |> put_participant_locale(participant)
      |> seat_page(dgettext("booking_manage", "Spot cancelled"))
      |> render(:cancelled,
        participant: participant,
        meeting: meeting,
        booking_path: booking_page_path(meeting)
      )
    else
      error -> render_error(conn, error)
    end
  end

  # ---------------------------------------------------------------------------
  # GET — reschedule: bounce into the public booking picker
  # ---------------------------------------------------------------------------

  @spec reschedule(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def reschedule(conn, %{"token" => token}) do
    # A seat in a meeting under way or over cannot move any more than it can
    # be given up, so the link answers with the cancel link's pages for it.
    with :ok <- rate_limit(conn),
         {:ok, %{participant: participant, meeting: meeting}} <-
           Meetings.fetch_cancellable_seat(token) do
      case picker_path(meeting) do
        {:ok, path} ->
          redirect(conn, to: path <> "?" <> URI.encode_query(%{"reschedule_seat_token" => token}))

        :not_movable ->
          # The type stopped taking group bookings after this seat was
          # booked, or was deleted: its meetings keep their seats but take
          # no moves (`Tymeslot.Bookings.RescheduleSeat`), so the picker
          # could only fail on submit. Say so here, and offer the way that
          # still works.
          conn
          |> put_participant_locale(participant)
          |> seat_page(dgettext("booking_manage", "Spot cannot be moved"))
          |> render(:not_movable, token: token)

        {:error, :not_found} = error ->
          render_error(conn, error)
      end
    else
      error -> render_error(conn, error)
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp rate_limit(conn), do: RateLimiter.check_seat_manage_rate_limit(ClientIP.get(conn))

  # Only a supported locale is applied; a stored one the app has since
  # stopped offering leaves the request's own in place.
  defp put_participant_locale(conn, %{locale: locale}) do
    case Locales.acceptable(locale) do
      nil ->
        conn

      locale ->
        Gettext.put_locale(locale)
        assign(conn, :locale, locale)
    end
  end

  # These pages render without the app layout, so the browser tab takes its
  # name from `page_title` alone — without one every seat page reads
  # "Schedule a Meeting", which is not what the visitor is doing here.
  defp seat_page(conn, title) do
    conn
    |> assign(:page_title, title)
    |> put_layout(html: false)
  end

  # Somewhere to go that is not "close the tab": the host's booking page,
  # where the visitor can pick another time or simply see what they had.
  defp booking_page_path(%{organizer_user_id: user_id}) when is_integer(user_id) do
    case organizer_username(user_id) do
      {:ok, username} -> "/#{username}"
      :error -> nil
    end
  end

  defp booking_page_path(_meeting), do: nil

  # The public booking page for the seat's meeting type, or `:not_movable`
  # when that type was deleted or no longer takes group bookings.
  defp picker_path(%{organizer_user_id: user_id, meeting_type_id: meeting_type_id})
       when is_integer(user_id) do
    with {:ok, username} <- organizer_username(user_id),
         {:ok, meeting_type} <- group_type(meeting_type_id, user_id) do
      {:ok, "/#{username}/#{MeetingTypes.effective_slug(meeting_type)}"}
    else
      :not_movable -> :not_movable
      :error -> {:error, :not_found}
    end
  end

  defp picker_path(_meeting), do: {:error, :not_found}

  defp group_type(nil, _user_id), do: :not_movable

  defp group_type(meeting_type_id, user_id) do
    case MeetingTypes.get_meeting_type(meeting_type_id, user_id) do
      %{} = meeting_type ->
        if MeetingTypes.group_type?(meeting_type), do: {:ok, meeting_type}, else: :not_movable

      nil ->
        :not_movable
    end
  end

  defp organizer_username(user_id) do
    case Profiles.get_profile_by_user_id(user_id) do
      {:ok, %{username: username}} when is_binary(username) and username != "" -> {:ok, username}
      _missing -> :error
    end
  end

  defp render_error(conn, {:error, :rate_limited, _message}) do
    conn
    |> put_status(:too_many_requests)
    |> seat_page(dgettext("booking_manage", "Too many attempts"))
    |> render(:too_many_requests)
  end

  defp render_error(conn, {:error, :already_cancelled}) do
    conn
    |> put_status(:gone)
    |> seat_page(dgettext("booking_manage", "Spot already cancelled"))
    |> render(:already_cancelled)
  end

  defp render_error(conn, {:error, :meeting_cancelled}) do
    conn
    |> put_status(:gone)
    |> seat_page(dgettext("booking_manage", "Meeting cancelled"))
    |> render(:meeting_cancelled)
  end

  defp render_error(conn, {:error, reason})
       when reason in [:meeting_started, :meeting_past] or is_binary(reason) do
    conn
    |> put_status(:conflict)
    |> seat_page(dgettext("booking_manage", "Spot cannot be cancelled"))
    |> render(:not_allowed, reason: reason)
  end

  defp render_error(conn, _not_found) do
    conn
    |> put_status(:not_found)
    |> seat_page(dgettext("booking_manage", "Link no longer valid"))
    |> render(:invalid)
  end
end
