defmodule TymeslotWeb.GuestRsvpController do
  @moduledoc """
  Public, unauthenticated endpoint for a meeting guest to respond to their
  invitation via the tokenised link in their confirmation email.

  Two-step flow to prevent email link-prefetchers from auto-triggering RSVPs:

    * `GET /guest/:token/:response` — looks up the invitation and renders a
      confirmation landing page with a POST form button. No mutation.
    * `POST /guest/:token/:response` — records the RSVP (the domain notifies
      the organiser's dashboard) and renders the success page.
  """

  use TymeslotWeb, :controller

  alias Tymeslot.Meetings
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.Helpers.ClientIP

  @responses %{"accept" => "accepted", "decline" => "declined"}

  # ---------------------------------------------------------------------------
  # GET — confirmation landing page (read-only)
  # ---------------------------------------------------------------------------

  @spec confirm(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def confirm(conn, %{"token" => token, "response" => response})
      when is_map_key(@responses, response) do
    with :ok <- RateLimiter.check_guest_rsvp_rate_limit(ClientIP.get(conn)),
         {:ok, guest} <- Meetings.get_guest_invitation(token) do
      conn
      |> put_layout(html: false)
      |> render(:confirm,
        meeting: guest.meeting,
        status: Map.fetch!(@responses, response),
        token: token,
        response: response
      )
    else
      error -> render_error(conn, error)
    end
  end

  def confirm(conn, _params), do: render_error(conn, {:error, :not_found})

  # ---------------------------------------------------------------------------
  # POST — record the RSVP, render success
  # ---------------------------------------------------------------------------

  @spec submit(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def submit(conn, %{"token" => token, "response" => response})
      when is_map_key(@responses, response) do
    with :ok <- RateLimiter.check_guest_rsvp_rate_limit(ClientIP.get(conn)),
         {:ok, guest} <- Meetings.record_guest_rsvp(token, Map.fetch!(@responses, response)) do
      conn
      |> put_layout(html: false)
      |> render(:confirmation, meeting: guest.meeting, status: guest.status, token: token)
    else
      error -> render_error(conn, error)
    end
  end

  def submit(conn, _params), do: render_error(conn, {:error, :not_found})

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp render_error(conn, error) do
    {http_status, template} = error_page(error)

    conn
    |> put_status(http_status)
    |> put_layout(html: false)
    |> render(template)
  end

  defp error_page({:error, :rate_limited, _message}), do: {:too_many_requests, :too_many_requests}
  defp error_page({:error, :meeting_closed}), do: {:gone, :closed}
  defp error_page(_error), do: {:not_found, :invalid}
end
