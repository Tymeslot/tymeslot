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

  The description is written in the organiser's language, with the reference
  on a line of its own after the translated text, so no translation can drop
  it. Only a public conversation the integration's account owns is adopted,
  and only when a line of its description is exactly that reference, so a
  conversation the organiser merely takes part in never counts.

  An adopted conversation is brought up to date: a booking rescheduled while
  it had no recorded room would otherwise keep the name and lobby time the
  earlier attempt gave it.

  The lookup lists conversations rather than asking for one by token, since
  only a lookup by token counts towards Nextcloud's brute-force throttling of
  the calling address. The reference is a hash, so the conversation never
  shows the meeting id itself.

  Transport only, like `Tymeslot.Integrations.Video.Providers.NextcloudTalk.Client`:
  a failure comes back as the client reported it, for the provider to judge.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Emails.RecipientLocale
  alias Tymeslot.Integrations.Video.LobbyOpening
  alias Tymeslot.Integrations.Video.Providers.LinkRoom
  alias Tymeslot.Integrations.Video.Providers.NextcloudTalk.Client

  require Logger

  # A public conversation: anyone holding the link may join as a guest.
  @public_conversation 3

  # The participant type of the account that owns a conversation.
  @owner 1

  # Lobby state 1 holds everyone but moderators until the timer passes.
  @lobby_for_non_moderators 1

  @max_room_name_length 255

  # Never translated: it is how an earlier attempt's conversation is found.
  @reference_label "Reference: "

  @doc """
  Returns the booking's conversation as Talk describes it, and whether it was
  `:created` now or `:adopted` from an earlier attempt and brought up to date.

  The two are told apart because an adopted conversation says nothing about
  what the server would do with a new one: it was made when the server still
  allowed it.

  `config` carries the booking's `:event_details`, its `:meeting_id` and the
  organiser's `:user_id`. Without a meeting id nothing earlier can belong to
  it, so a conversation is created straight away.
  """
  @spec find_or_create(Client.credentials(), map()) ::
          {:ok, term(), :created | :adopted} | {:error, Client.error()}
  def find_or_create(credentials, config) do
    case LinkRoom.slug(Map.get(config, :meeting_id)) do
      {:ok, reference} ->
        wanted = params(config, reference)

        case find(credentials, reference, wanted, config) do
          {:ok, nil} -> created(credentials, wanted)
          {:ok, room} -> {:ok, room, :adopted}
          {:error, _reason} = error -> error
        end

      {:error, :empty_meeting_id} ->
        created(credentials, params(config, nil))
    end
  end

  defp created(credentials, wanted) do
    with {:ok, room} <- Client.create_room(credentials, wanted), do: {:ok, room, :created}
  end

  @doc """
  The longest `find_or_create/2` can wait on the network, in milliseconds: a
  lookup, then either the creation it did not make unnecessary or the lobby
  move and rename that bring an adopted conversation up to date.
  """
  @spec budget_ms() :: pos_integer()
  def budget_ms do
    Client.request_budget_ms(:get) +
      max(Client.request_budget_ms(:post), 2 * Client.request_budget_ms(:put))
  end

  @doc """
  The lobby settings that hold guests until a meeting starting at
  `start_time` opens, as Talk's lobby endpoint takes them. An all-day meeting
  passes its first `Date` (see `Tymeslot.Integrations.Video.LobbyOpening`).
  """
  @spec lobby(DateTime.t() | NaiveDateTime.t() | Date.t()) :: map()
  def lobby(start_time), do: %{"state" => @lobby_for_non_moderators, "timer" => unix(start_time)}

  @doc """
  The conversation name for a booking titled `summary`, cut to Talk's limit,
  or a generic one for a booking without a title.
  """
  @spec room_name(term()) :: String.t()
  def room_name(summary) when is_binary(summary) and summary != "",
    do: String.slice(summary, 0, @max_room_name_length)

  def room_name(_summary), do: dgettext("dashboard_integrations", "Meeting")

  defp find(credentials, reference, wanted, config) do
    case Client.list_rooms(credentials) do
      {:ok, rooms} when is_list(rooms) ->
        case Enum.find(rooms, &earlier_attempt?(&1, reference)) do
          nil -> {:ok, nil}
          room -> adopt(credentials, room, wanted, config)
        end

      {:ok, _not_a_list} ->
        {:error, :invalid_response}

      {:error, _reason} = error ->
        error
    end
  end

  defp earlier_attempt?(
         %{"type" => @public_conversation, "participantType" => @owner, "description" => text},
         reference
       )
       when is_binary(text) do
    text
    |> String.split(~r/\R/)
    |> Enum.any?(&(String.trim(&1) == @reference_label <> reference))
  end

  defp earlier_attempt?(_room, _reference), do: false

  defp adopt(credentials, %{"token" => token} = room, wanted, config) when is_binary(token) do
    Logger.info("Nextcloud Talk already holds this booking's conversation, adopting it",
      integration_id: Map.get(config, :integration_id),
      meeting_id: Map.get(config, :meeting_id)
    )

    with :ok <- sync_lobby(credentials, room, wanted, config),
         :ok <- sync_name(credentials, room, wanted, config) do
      {:ok, room}
    end
  end

  # A listed room without a token is no room; the provider refuses it.
  defp adopt(_credentials, room, _wanted, _config), do: {:ok, room}

  defp sync_lobby(credentials, room, %{"lobbyTimer" => timer} = wanted, config) do
    if room["lobbyState"] == wanted["lobbyState"] and room["lobbyTimer"] == timer do
      :ok
    else
      credentials
      |> Client.set_lobby(room["token"], %{"state" => wanted["lobbyState"], "timer" => timer})
      |> settled(:move_lobby, config)
    end
  end

  # A booking without a start time leaves the lobby as it is.
  defp sync_lobby(_credentials, _room, _wanted, _config), do: :ok

  defp sync_name(_credentials, %{"name" => name}, %{"roomName" => name}, _config), do: :ok

  defp sync_name(credentials, room, %{"roomName" => name}, config) do
    credentials
    |> Client.rename_room(room["token"], name)
    |> settled(:rename, config)
  end

  # A refusal (a 400 or 403) will not change on a retry, and the conversation
  # is usable without the change: the organiser moderates it and can open the
  # lobby. Failing for it would leave the booking with no link at all, so it
  # is logged. Anything else fails, for the room job to retry.
  defp settled({:ok, _data}, _action, _config), do: :ok

  defp settled({:error, {:rejected, status, error}}, action, config) do
    Logger.warning("Nextcloud Talk refused to change an adopted conversation",
      integration_id: Map.get(config, :integration_id),
      action: action,
      status: status,
      error: error
    )

    :ok
  end

  defp settled({:error, _reason} = error, _action, _config), do: error

  # Rendered in the organiser's language: the conversation is theirs, and its
  # guests are the organiser's own.
  defp params(config, reference) do
    RecipientLocale.with_user_id_locale(Map.get(config, :user_id), fn ->
      details = Map.get(config, :event_details) || %{}

      %{
        "roomType" => @public_conversation,
        "roomName" => room_name(Map.get(details, :summary))
      }
      |> Map.merge(lobby_params(Map.get(details, :start_time)))
      |> Map.merge(description_params(reference))
    end)
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
        dgettext("dashboard_integrations", "Booked through Tymeslot.") <>
          "\n\n" <> @reference_label <> reference
    }
  end

  defp unix(start_time), do: start_time |> LobbyOpening.opens_at() |> DateTime.to_unix()
end
