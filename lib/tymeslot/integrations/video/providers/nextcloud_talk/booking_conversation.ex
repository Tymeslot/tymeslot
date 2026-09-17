defmodule Tymeslot.Integrations.Video.Providers.NextcloudTalk.BookingConversation do
  @moduledoc """
  The Talk conversation a booking gets, and how it is found again.

  Every booking gets a public conversation named after it, whose lobby holds
  guests until the meeting's start.

  ## One conversation per booking

  A room job that gave up waiting, or a server whose answer arrived too late,
  can leave a conversation behind that the booking never learnt about, and a
  retry would create a second one. So a booking's conversation carries a
  reference derived from its meeting id in the description, and creation first
  looks through the organiser's conversations for it, adopting the one an
  earlier attempt made instead of creating another.

  Talk offers no way to create a conversation idempotently. The object types a
  user may attach at creation each bring behaviour a booking cannot have:
  `event` refuses renaming, which a reschedule needs, `instant_meeting` is
  deleted after a day without activity, and the phone types refuse a lobby.
  The description is the one field left that the listing returns in full to
  the owner.

  The lookup lists conversations rather than asking for one by token, since
  only a lookup by token counts towards Nextcloud's brute-force throttling of
  the calling address. The reference is a hash, so the conversation never
  shows the meeting id itself.

  Transport only, like `Tymeslot.Integrations.Video.Providers.NextcloudTalk.Client`:
  a failure comes back as the client reported it, for the provider to judge.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Integrations.Video.Providers.LinkRoom
  alias Tymeslot.Integrations.Video.Providers.NextcloudTalk.Client

  require Logger

  # A public conversation: anyone holding the link may join as a guest.
  @public_conversation 3

  # Lobby state 1 holds everyone but moderators until the timer passes.
  @lobby_for_non_moderators 1

  @max_room_name_length 255

  @doc """
  Returns the booking's conversation as Talk describes it: the one an earlier
  attempt created, or a new one.

  `config` carries the booking's `:event_details` and its `:meeting_id`.
  Without a meeting id nothing earlier can belong to it, so a conversation is
  created straight away.
  """
  @spec find_or_create(Client.credentials(), map()) ::
          {:ok, term()} | {:error, Client.error()}
  def find_or_create(credentials, config) do
    case LinkRoom.slug(Map.get(config, :meeting_id)) do
      {:ok, reference} ->
        with {:ok, nil} <- find(credentials, reference, config),
             do: Client.create_room(credentials, params(config, reference))

      {:error, :empty_meeting_id} ->
        Client.create_room(credentials, params(config, nil))
    end
  end

  @doc """
  The longest `find_or_create/2` can wait on the network, in milliseconds: a
  lookup, then the creation it did not make unnecessary.
  """
  @spec budget_ms() :: pos_integer()
  def budget_ms, do: Client.request_budget_ms(:get) + Client.request_budget_ms(:post)

  @doc """
  The lobby settings that hold guests until `start_time`, as Talk's lobby
  endpoint takes them.
  """
  @spec lobby(DateTime.t() | NaiveDateTime.t()) :: map()
  def lobby(start_time), do: %{"state" => @lobby_for_non_moderators, "timer" => unix(start_time)}

  @doc """
  The conversation name for a booking titled `summary`, cut to Talk's limit,
  or a generic one for a booking without a title.
  """
  @spec room_name(term()) :: String.t()
  def room_name(summary) when is_binary(summary) and summary != "",
    do: String.slice(summary, 0, @max_room_name_length)

  def room_name(_summary), do: dgettext("dashboard_integrations", "Meeting")

  defp find(credentials, reference, config) do
    case Client.list_rooms(credentials) do
      {:ok, rooms} when is_list(rooms) ->
        rooms |> Enum.find(&carries_reference?(&1, reference)) |> adopted(config)

      {:ok, _not_a_list} ->
        {:error, :invalid_response}

      {:error, _reason} = error ->
        error
    end
  end

  defp carries_reference?(%{"description" => description}, reference)
       when is_binary(description),
       do: String.contains?(description, reference)

  defp carries_reference?(_room, _reference), do: false

  defp adopted(nil, _config), do: {:ok, nil}

  defp adopted(room, config) do
    Logger.info("Nextcloud Talk already holds this booking's conversation, adopting it",
      integration_id: Map.get(config, :integration_id),
      meeting_id: Map.get(config, :meeting_id)
    )

    {:ok, room}
  end

  defp params(config, reference) do
    details = Map.get(config, :event_details) || %{}

    %{
      "roomType" => @public_conversation,
      "roomName" => room_name(Map.get(details, :summary))
    }
    |> Map.merge(lobby_params(Map.get(details, :start_time)))
    |> Map.merge(description_params(reference))
  end

  # Without a start time there is nothing for the lobby to wait for, so the
  # conversation opens at once.
  defp lobby_params(nil), do: %{}

  defp lobby_params(start_time),
    do: %{"lobbyState" => @lobby_for_non_moderators, "lobbyTimer" => unix(start_time)}

  defp description_params(nil), do: %{}

  defp description_params(reference) do
    %{
      "description" =>
        dgettext("dashboard_integrations", "Booked through Tymeslot. Reference: %{reference}",
          reference: reference
        )
    }
  end

  defp unix(%DateTime{} = time), do: DateTime.to_unix(time)

  defp unix(%NaiveDateTime{} = time),
    do: time |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix()
end
