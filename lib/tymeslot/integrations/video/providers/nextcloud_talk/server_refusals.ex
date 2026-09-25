defmodule Tymeslot.Integrations.Video.Providers.NextcloudTalk.ServerRefusals do
  @moduledoc """
  What a Nextcloud Talk refusal means for a booking, and what the server's
  capabilities say about the account before a room is asked for.

  Talk tells its refusals apart, identically in Talk 24 and 25, and each one a
  setting on the server causes carries a code of
  `Tymeslot.Integrations.Video.RoomCreationError`, which is recorded on the
  integration and explained to its owner:

    * 403 `{"error": "permissions"}`: only some groups may create
      conversations (`start_conversations`)
    * 403 with no error key, `"Can not use Talk"` in the OCS meta: only some
      groups may use Talk at all (`allowed_groups`), which already refuses the
      lookup that precedes creation
    * 400 `{"error": "password"}`: public conversations need a password
      (`force_passwords`); the message beside it is translated, so only the key
      is read

  A 400 whose key names a field of the request is Tymeslot's own fault, not a
  setting the organiser can change, so it is a configuration error with no code:
  the room job discards it and nothing is recorded against the integration.

  Only a refusal Talk itself worded reaches here: `Client` reports a 400 or 403
  that is not the OCS envelope as an HTTP error, since a proxy in front of
  Nextcloud answers with pages of its own and none of them say anything about
  Talk's settings.
  """

  alias Tymeslot.Integrations.Video.Providers.NextcloudTalk.Client
  alias Tymeslot.Integrations.Video.RoomCreationError

  # The creation request's own fields, as Talk's `CreationException` names
  # them. A 400 about one of these means Tymeslot sent something Talk will not
  # take, whatever the server's settings are.
  @request_data_errors ~w[
    name description type object object-id object-type lobby lobby-timer
    read-only listable message-expiration mention-permissions recording-consent
    permissions sip-enabled avatar classified preset invite
  ]

  @doc """
  What a refusal at creation means for the booking.

  A configuration error is one that repeats on every attempt, which the room
  job discards rather than retrying. Anything else is passed through for the
  circuit breaker and the retry policy to judge, `:unauthorized` and
  `:rate_limited` included: the provider decides what those mean for the
  integration.
  """
  @spec at_creation(Client.error()) :: {:configuration_error, atom()} | term()
  def at_creation({:rejected, 403, "permissions"}),
    do: {:configuration_error, :conversation_creation_restricted}

  def at_creation({:rejected, 403, nil}), do: {:configuration_error, :talk_not_allowed}
  def at_creation({:rejected, 400, "password"}), do: {:configuration_error, :password_required}

  def at_creation({:rejected, 400, error}) when error in @request_data_errors,
    do: {:configuration_error, :invalid_request}

  def at_creation({:rejected, _status, _error}), do: {:configuration_error, :conversation_refused}
  def at_creation(:not_found), do: {:configuration_error, :talk_not_found}
  def at_creation({:redirected, _location}), do: {:configuration_error, :redirected}
  def at_creation(reason), do: reason

  @doc """
  Whether the signed-in account may create the public conversations a booking
  needs, as Talk's capabilities announce it: `can-create` and `force-passwords`
  under `config.conversations`, both present in Talk 24 and 25.

  Refused with the same words the integration's dashboard row uses for the
  matching code. A server that announces neither key is taken to allow it.

  Only ever read from capabilities a request Tymeslot authenticated came back
  with: Nextcloud answers an anonymous request with capabilities of its own,
  where `can-create` is false because nobody is signed in.
  """
  @spec conversation_rights(map()) :: :ok | {:error, {:not_permitted, String.t()}}
  def conversation_rights(spreed) do
    case get_in(spreed, ["config", "conversations"]) do
      %{"can-create" => false} -> not_permitted(:conversation_creation_restricted)
      %{"force-passwords" => true} -> not_permitted(:password_required)
      _allowed -> :ok
    end
  end

  defp not_permitted(code), do: {:error, {:not_permitted, RoomCreationError.message(code)}}
end
