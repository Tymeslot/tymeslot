defmodule TymeslotWeb.GuestRsvpController do
  @moduledoc """
  Public, unauthenticated endpoint for a meeting guest to respond to their
  invitation via the tokenised link in their confirmation email.

  Two-step flow to prevent email link-prefetchers from auto-triggering RSVPs:

    * `GET /guest/:token/:response` — looks up the guest and renders a
      confirmation landing page with a POST form button. No mutation.
    * `POST /guest/:token/:response` — performs the RSVP write, broadcasts to
      the organiser's dashboard, and renders the success page.
  """

  use TymeslotWeb, :controller

  alias Phoenix.PubSub
  alias Tymeslot.Bookings.Policy
  alias Tymeslot.Meetings
  alias Tymeslot.Security.RateLimiter

  @responses %{"accept" => "accepted", "decline" => "declined"}

  # ---------------------------------------------------------------------------
  # GET — confirmation landing page (read-only)
  # ---------------------------------------------------------------------------

  @spec confirm(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def confirm(conn, %{"token" => token, "response" => response})
      when is_map_key(@responses, response) do
    ip = conn.remote_ip |> :inet_parse.ntoa() |> to_string()
    status = Map.fetch!(@responses, response)

    with :ok <- RateLimiter.check_rate_limit("guest_rsvp:" <> ip, 60, 60_000),
         {:ok, guest} <- Meetings.get_guest_by_token(token),
         {:ok, meeting} <- Meetings.get_meeting(guest.meeting_id) do
      conn
      |> put_layout(html: false)
      |> render(:confirm,
        guest: guest,
        meeting: meeting,
        status: status,
        token: token,
        response: response
      )
    else
      {:error, :rate_limited} ->
        render_error(conn, :too_many_requests)

      _other ->
        render_error(conn, :not_found)
    end
  end

  def confirm(conn, _params), do: render_error(conn, :not_found)

  # ---------------------------------------------------------------------------
  # POST — write the RSVP, broadcast, render success
  # ---------------------------------------------------------------------------

  @spec submit(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def submit(conn, %{"token" => token, "response" => response})
      when is_map_key(@responses, response) do
    ip = conn.remote_ip |> :inet_parse.ntoa() |> to_string()
    status = Map.fetch!(@responses, response)

    with :ok <- RateLimiter.check_rate_limit("guest_rsvp:" <> ip, 60, 60_000),
         {:ok, guest} <- Meetings.record_guest_rsvp(token, status),
         {:ok, meeting} <- Meetings.get_meeting(guest.meeting_id) do
      broadcast_rsvp(meeting)

      toggle_url = toggle_rsvp_url(token, guest.status)
      toggle_label = toggle_rsvp_label(guest.status)

      conn
      |> put_layout(html: false)
      |> render(:confirmation,
        guest: guest,
        meeting: meeting,
        status: status,
        toggle_url: toggle_url,
        toggle_label: toggle_label
      )
    else
      {:error, :rate_limited} ->
        render_error(conn, :too_many_requests)

      _other ->
        render_error(conn, :not_found)
    end
  end

  def submit(conn, _params), do: render_error(conn, :not_found)

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

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

  defp toggle_rsvp_url(token, "accepted") do
    Policy.guest_rsvp_urls(token).decline_url
  end

  defp toggle_rsvp_url(token, _other) do
    Policy.guest_rsvp_urls(token).accept_url
  end

  defp toggle_rsvp_label("accepted"), do: :decline
  defp toggle_rsvp_label(_other), do: :accept

  defp broadcast_rsvp(%{organizer_user_id: user_id, id: meeting_id}) when is_integer(user_id) do
    PubSub.broadcast(
      Tymeslot.PubSub,
      "dashboard_guests:#{user_id}",
      {:guest_rsvp_updated, meeting_id}
    )

    :ok
  end

  defp broadcast_rsvp(_meeting), do: :ok
end
