defmodule TymeslotWeb.SeatController do
  @moduledoc """
  Public, unauthenticated seat management for group-booking participants via
  the tokenised links in their confirmation email.

  Mirrors `TymeslotWeb.GuestRsvpController`: a GET confirmation landing page
  (no mutation, safe for link prefetchers) and a POST that performs the
  write. The reschedule action redirects into the public booking picker for
  the same meeting type, carrying the token as `reschedule_seat_token`.
  """

  use TymeslotWeb, :controller
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Meetings
  alias Tymeslot.MeetingTypes
  alias Tymeslot.MeetingTypes.Slugs
  alias Tymeslot.Profiles
  alias Tymeslot.Security.RateLimiter

  # ---------------------------------------------------------------------------
  # GET — cancellation confirmation landing page (read-only)
  # ---------------------------------------------------------------------------

  @spec cancel_confirm(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def cancel_confirm(conn, %{"token" => token}) do
    with :ok <- rate_limit(conn),
         {:ok, %{participant: participant, meeting: meeting}} <- Meetings.fetch_live_seat(token) do
      conn
      |> seat_page(dgettext("booking", "Cancel your spot"))
      |> render(:cancel_confirm,
        participant: participant,
        meeting: meeting,
        token: token,
        keep_path: booking_page_path(meeting)
      )
    else
      {:error, :rate_limited} -> render_error(conn, :too_many_requests)
      _other -> render_error(conn, :not_found)
    end
  end

  # ---------------------------------------------------------------------------
  # POST — cancel the seat, render the confirmation
  # ---------------------------------------------------------------------------

  @spec cancel_submit(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def cancel_submit(conn, %{"token" => token}) do
    with :ok <- rate_limit(conn),
         {:ok, participant, meeting} <- load_seat(token),
         {:ok, _outcome} <- Meetings.cancel_seat(token) do
      conn
      |> seat_page(dgettext("booking", "Spot cancelled"))
      |> render(:cancelled,
        participant: participant,
        meeting: meeting,
        booking_path: booking_page_path(meeting)
      )
    else
      {:error, :rate_limited} ->
        render_error(conn, :too_many_requests)

      {:error, :already_cancelled} ->
        # Idempotent UX: re-posting a dead link shows the cancelled page.
        show_already_cancelled(conn, token)

      {:error, reason} when is_binary(reason) ->
        # Policy refusals (e.g. too close to start time) render a dedicated page.
        conn
        |> seat_page(dgettext("booking", "Spot cannot be cancelled"))
        |> render(:not_allowed)

      _other ->
        render_error(conn, :not_found)
    end
  end

  # ---------------------------------------------------------------------------
  # GET — reschedule: bounce into the public booking picker
  # ---------------------------------------------------------------------------

  @spec reschedule(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def reschedule(conn, %{"token" => token}) do
    with :ok <- rate_limit(conn),
         {:ok, %{meeting: meeting}} <- Meetings.fetch_live_seat(token),
         {:ok, path} <- picker_path(meeting) do
      redirect(conn, to: path <> "?" <> URI.encode_query(%{"reschedule_seat_token" => token}))
    else
      {:error, :rate_limited} -> render_error(conn, :too_many_requests)
      _other -> render_error(conn, :not_found)
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp rate_limit(conn) do
    ip = conn.remote_ip |> :inet_parse.ntoa() |> to_string()
    RateLimiter.check_rate_limit("seat_manage:" <> ip, 60, 60_000)
  end

  defp load_seat(token) do
    with {:ok, participant} <- Meetings.get_participant_by_token(token),
         {:ok, meeting} <- Meetings.get_meeting(participant.meeting_id) do
      {:ok, participant, meeting}
    end
  end

  defp show_already_cancelled(conn, token) do
    case load_seat(token) do
      {:ok, participant, meeting} ->
        conn
        |> seat_page(dgettext("booking", "Spot cancelled"))
        |> render(:cancelled,
          participant: participant,
          meeting: meeting,
          booking_path: booking_page_path(meeting)
        )

      _other ->
        render_error(conn, :not_found)
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
    case Profiles.get_profile_by_user_id(user_id) do
      {:ok, %{username: username}} when is_binary(username) and username != "" -> "/#{username}"
      _missing -> nil
    end
  end

  defp booking_page_path(_meeting), do: nil

  defp picker_path(%{organizer_user_id: user_id, meeting_type_id: meeting_type_id})
       when is_integer(user_id) do
    with {:ok, %{username: username}} when is_binary(username) and username != "" <-
           Profiles.get_profile_by_user_id(user_id),
         %{} = meeting_type <- MeetingTypes.get_meeting_type(meeting_type_id, user_id) do
      {:ok, "/#{username}/#{Slugs.effective_slug(meeting_type)}"}
    else
      _missing -> {:error, :not_found}
    end
  end

  defp picker_path(_meeting), do: {:error, :not_found}

  defp render_error(conn, :too_many_requests) do
    conn
    |> put_status(:too_many_requests)
    |> seat_page(dgettext("booking", "Too many attempts"))
    |> render(:too_many_requests)
  end

  defp render_error(conn, http_status) do
    conn
    |> put_status(http_status)
    |> seat_page(dgettext("booking", "Link no longer valid"))
    |> render(:invalid)
  end
end
