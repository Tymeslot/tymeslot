defmodule TymeslotWeb.Live.Scheduling.SharedAvailabilityGuests do
  @moduledoc """
  Web side of `Tymeslot.Scheduling.SharedAvailability`: reads the `with` query
  parameter of a booking link once at mount and keeps the resolved users on
  the socket for the rest of the flow.

  Assigns:

    * `:shared_availability_guests` - the resolved users, `[]` without a
      `with` parameter
    * `:shared_availability_param` - the normalised parameter value
      (`"michael,sandy"`), for links and redirects that have to carry it
      forward, or `nil`
    * `:shared_availability_source` - `:link` for users named in the link,
      `:booking` for users recovered from the guests of a booking being
      rescheduled (`?reschedule_meeting_uid=`), or `nil`

  A link naming someone who cannot take part does not fall back to booking
  without them. `:shared_availability_error` then carries the reason, the
  theme keeps the booker on its overview step and shows the reason where the
  meeting types would be, and a submit is refused.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.Scheduling.SharedAvailability

  @doc """
  Resolves the `with` parameter against the organiser on the socket.

  Also narrows `:meeting_types` to the types that allow guests, since the
  users named in the link join the booking as guests.
  """
  @spec assign_from_params(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def assign_from_params(socket, params) do
    host_user_id = socket.assigns[:organizer_user_id]

    with true <- is_integer(host_user_id),
         {:ok, [_first | _rest] = usernames} <-
           SharedAvailability.parse_usernames(params[SharedAvailability.query_param()]),
         {:ok, guests} <- SharedAvailability.resolve(usernames, host_user_id) do
      socket
      |> assign(:shared_availability_guests, guests)
      |> assign(:shared_availability_param, Enum.join(usernames, ","))
      |> assign(:shared_availability_source, :link)
      |> assign(
        :meeting_types,
        Enum.filter(socket.assigns[:meeting_types] || [], &allows_guests?/1)
      )
    else
      {:error, _reason} -> assign_unavailable(socket)
      _no_guests -> assign_from_rescheduled_booking(socket, params, host_user_id)
    end
  end

  # A reschedule link carries no `with`: the users to check come from the
  # guests of the booking being moved. Nothing here can fail the page, since the
  # booking already exists; its meeting type stays whatever it was.
  defp assign_from_rescheduled_booking(socket, params, host_user_id) do
    case params["reschedule_meeting_uid"] do
      uid when is_binary(uid) and uid != "" ->
        socket
        |> assign_defaults()
        |> assign(
          :shared_availability_guests,
          SharedAvailability.resolve_for_booking(uid, host_user_id)
        )
        |> assign(:shared_availability_source, :booking)

      _not_rescheduling ->
        assign_defaults(socket)
    end
  end

  @doc """
  Refuses a meeting type that does not allow guests once users are named in
  the link. A direct link to such a type (`/marco/intro?with=michael`) would
  otherwise offer times the booking could never add the other users to.
  """
  @spec check_meeting_type(Phoenix.LiveView.Socket.t(), map() | nil) ::
          Phoenix.LiveView.Socket.t()
  def check_meeting_type(socket, meeting_type) do
    if socket.assigns[:shared_availability_source] == :link and not allows_guests?(meeting_type) do
      assign(
        socket,
        :shared_availability_error,
        dgettext(
          "booking",
          "This meeting type can’t be booked together with other participants."
        )
      )
    else
      socket
    end
  end

  @doc "Whether the link cannot be booked as it stands (`:shared_availability_error`)."
  @spec blocked?(Phoenix.LiveView.Socket.t()) :: boolean()
  def blocked?(socket), do: is_binary(socket.assigns[:shared_availability_error])

  @doc "Whether the flow on this socket books together with other users."
  @spec active?(Phoenix.LiveView.Socket.t() | map()) :: boolean()
  def active?(%Phoenix.LiveView.Socket{assigns: assigns}), do: active?(assigns)
  def active?(%{shared_availability_guests: [_first | _rest]}), do: true
  def active?(_assigns), do: false

  @doc """
  Adds the `with` parameter to a query parameter map, when the flow has one.
  """
  @spec put_query_param(map(), Phoenix.LiveView.Socket.t() | map()) :: map()
  def put_query_param(query_params, %Phoenix.LiveView.Socket{assigns: assigns}),
    do: put_query_param(query_params, assigns)

  def put_query_param(query_params, %{shared_availability_param: value})
      when is_binary(value) and value != "" do
    Map.put(query_params, SharedAvailability.query_param(), value)
  end

  def put_query_param(query_params, _assigns), do: query_params

  @doc """
  The usernames to hand to the booking domain on submit. Only users named in
  the link: a reschedule recovers its own from the booking.
  """
  @spec usernames(Phoenix.LiveView.Socket.t()) :: [String.t()]
  def usernames(socket) do
    if socket.assigns[:shared_availability_source] == :link,
      do: Enum.map(socket.assigns.shared_availability_guests, & &1.username),
      else: []
  end

  defp assign_defaults(socket) do
    socket
    |> assign(:shared_availability_guests, [])
    |> assign(:shared_availability_param, nil)
    |> assign(:shared_availability_source, nil)
    |> assign(:shared_availability_error, nil)
  end

  defp assign_unavailable(socket) do
    socket
    |> assign_defaults()
    |> assign(:meeting_types, [])
    |> assign(
      :shared_availability_error,
      dgettext(
        "booking",
        "One of the participants named in this link isn’t available for booking. Please check the link."
      )
    )
  end

  defp allows_guests?(%{allow_guests: true}), do: true
  defp allows_guests?(_meeting_type), do: false
end
