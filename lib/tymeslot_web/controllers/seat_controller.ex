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

  alias Tymeslot.Meetings
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Profiles
  alias Tymeslot.Security.RateLimiter

  # ---------------------------------------------------------------------------
  # GET — cancellation confirmation landing page (read-only)
  # ---------------------------------------------------------------------------

  @spec cancel_confirm(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def cancel_confirm(conn, %{"token" => token}) do
    with :ok <- rate_limit(conn),
         {:ok, participant, meeting} <- load_live_seat(token) do
      conn
      |> put_layout(html: false)
      |> render(:cancel_confirm, participant: participant, meeting: meeting, token: token)
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
      |> put_layout(html: false)
      |> render(:cancelled, participant: participant, meeting: meeting)
    else
      {:error, :rate_limited} ->
        render_error(conn, :too_many_requests)

      {:error, :already_cancelled} ->
        # Idempotent UX: re-posting a dead link shows the cancelled page.
        show_already_cancelled(conn, token)

      {:error, reason} when is_binary(reason) ->
        # Policy refusals (e.g. too close to start time) render a dedicated page.
        conn
        |> put_layout(html: false)
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
         {:ok, _participant, meeting} <- load_live_seat(token),
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

  defp load_live_seat(token) do
    with {:ok, participant, meeting} <- load_seat(token),
         nil <- participant.cancelled_at,
         false <- meeting.status == "cancelled" do
      {:ok, participant, meeting}
    else
      {:error, reason} -> {:error, reason}
      _cancelled -> {:error, :not_found}
    end
  end

  defp show_already_cancelled(conn, token) do
    case load_seat(token) do
      {:ok, participant, meeting} ->
        conn
        |> put_layout(html: false)
        |> render(:cancelled, participant: participant, meeting: meeting)

      _other ->
        render_error(conn, :not_found)
    end
  end

  defp picker_path(%{organizer_user_id: user_id, meeting_type_id: meeting_type_id})
       when is_integer(user_id) do
    with {:ok, %{username: username}} when is_binary(username) and username != "" <-
           Profiles.get_profile_by_user_id(user_id),
         %{} = meeting_type <- MeetingTypes.get_meeting_type(meeting_type_id, user_id) do
      {:ok, "/#{username}/#{meeting_type_identifier(meeting_type)}"}
    else
      _missing -> {:error, :not_found}
    end
  end

  defp picker_path(_meeting), do: {:error, :not_found}

  # The booking picker route accepts either a custom slug or the legacy
  # duration-based identifier ("30min") — mirrors
  # `ThemeFlow.resolve_meeting_type_for_duration/2`, which resolves the same
  # fallback the other way round.
  defp meeting_type_identifier(%{slug: slug}) when is_binary(slug) and slug != "", do: slug
  defp meeting_type_identifier(%{duration_minutes: duration}), do: "#{duration}min"

  defp render_error(conn, http_status) do
    template =
      case http_status do
        :too_many_requests -> :too_many_requests
        _other -> :invalid
      end

    conn
    |> put_status(http_status)
    |> put_layout(html: false)
    |> render(template)
  end
end
