defmodule Tymeslot.Integrations.Video.Providers.Jitsi.Token do
  @moduledoc """
  Mints the HS256 JSON Web Tokens a Jitsi instance accepts for authenticated
  entry, covering both a self-hosted deployment configured with a shared
  secret and 8x8's hosted JaaS.

  One token is minted per participant, which is what lets the organiser hold
  moderator rights while the attendee joins as a guest. The `room` claim is
  always the meeting's own slug rather than the `*` wildcard: these tokens
  travel to external attendees in confirmation emails, and a wildcard would
  admit its holder to every room on the instance.
  """

  alias Joken.Signer

  @type mint_error ::
          :missing_app_id | :missing_secret | :invalid_room | Joken.error_reason()

  @spec mint(keyword()) :: {:ok, String.t()} | {:error, mint_error()}
  def mint(opts) do
    with {:ok, app_id} <- fetch(opts, :app_id),
         {:ok, secret} <- fetch(opts, :secret),
         {:ok, room} <- fetch_room(opts) do
      signer = Signer.create("HS256", secret)

      claims = %{
        "aud" => app_id,
        "iss" => app_id,
        "sub" => Keyword.get(opts, :sub, "*"),
        "room" => room,
        "exp" => DateTime.to_unix(Keyword.fetch!(opts, :expires_at)),
        "context" => %{
          "user" => %{
            "name" => Keyword.get(opts, :name),
            "email" => Keyword.get(opts, :email),
            "moderator" => Keyword.get(opts, :moderator, false)
          }
        }
      }

      case Joken.encode_and_sign(claims, signer) do
        {:ok, token, _claims} -> {:ok, token}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp fetch(opts, :app_id) do
    case Keyword.get(opts, :app_id) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _absent -> {:error, :missing_app_id}
    end
  end

  defp fetch(opts, :secret) do
    case Keyword.get(opts, :secret) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _absent -> {:error, :missing_secret}
    end
  end

  defp fetch_room(opts) do
    case Keyword.fetch!(opts, :room) do
      value when is_binary(value) and value != "" and value != "*" -> {:ok, value}
      _invalid -> {:error, :invalid_room}
    end
  end
end
