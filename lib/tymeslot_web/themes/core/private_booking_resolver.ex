defmodule TymeslotWeb.Themes.Core.PrivateBookingResolver do
  @moduledoc """
  Resolves organizer context from a private booking token.

  Used by the Dispatcher for `:private_schedule` and `:private_booking` actions,
  where the meeting type and organizer are encoded in a signed URL token rather
  than derived from a username/slug pair.
  """

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.MeetingTypes
  alias Tymeslot.MeetingTypes.PrivateLinkToken
  alias Tymeslot.Profiles.ProfileQueries

  require Logger

  @doc """
  Decodes the token and assigns organizer context onto the socket.

  On success returns `{:ok, socket}` with `:organizer_profile`, `:organizer_user_id`,
  and `:meeting_types` assigned. The `:meeting_types` list contains only the single
  meeting type encoded in the token, so the scheduling flow never shows other types.

  On failure returns `{:error, reason}` where reason is `:expired` or `:invalid`.
  """
  @spec resolve(String.t(), Phoenix.LiveView.Socket.t()) ::
          {:ok, Phoenix.LiveView.Socket.t()} | {:error, :expired | :invalid}
  def resolve(token, socket) do
    with {:ok, {user_id, meeting_type_id}} <- PrivateLinkToken.verify(token),
         {:ok, profile} <- ProfileQueries.get_by_user_id(user_id),
         mt when is_map(mt) <- MeetingTypes.get_meeting_type(meeting_type_id, user_id) do
      socket =
        socket
        |> assign(:organizer_profile, profile)
        |> assign(:organizer_user_id, user_id)
        |> assign(:meeting_types, [mt])
        |> assign(:username_context, profile.username)
        |> assign(:page_title, "Schedule #{mt.name}")
        |> assign(:is_private_booking, true)

      {:ok, socket}
    else
      {:error, :expired} ->
        {:error, :expired}

      {:error, _reason} ->
        {:error, :invalid}

      nil ->
        # meeting type not found / no longer active
        {:error, :invalid}
    end
  end
end
