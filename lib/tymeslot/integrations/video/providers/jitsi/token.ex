defmodule Tymeslot.Integrations.Video.Providers.Jitsi.Token do
  @moduledoc """
  Mints the HS256 JSON Web Tokens a self-hosted Jitsi instance accepts for
  authenticated entry, when the instance is configured with a shared secret.

  One token is minted per participant and admits its holder to one room
  only: the `room` claim is always the meeting's own slug, never the `*`
  wildcard, because these tokens travel to external attendees in
  confirmation emails. Jitsi compares that claim against the lower-cased room
  name, which the lower-case hex slug already satisfies.

  The organiser's token carries `moderator: true` and the attendee's
  `moderator: false`. The flag does not grant rights by itself: it takes
  effect only on a server configured to honour it.
  """

  alias Joken.Signer

  @type mint_error ::
          :missing_app_id | :missing_secret | :invalid_room | Joken.error_reason()

  @spec mint(keyword()) :: {:ok, String.t()} | {:error, mint_error()}
  def mint(opts) do
    with {:ok, app_id} <- fetch_present(opts, :app_id, :missing_app_id),
         {:ok, secret} <- fetch_present(opts, :secret, :missing_secret),
         {:ok, room} <- fetch_room(opts) do
      signer = Signer.create("HS256", secret)

      claims = %{
        "aud" => app_id,
        "iss" => app_id,
        "sub" => Keyword.get(opts, :sub, "*"),
        "room" => room,
        "iat" => DateTime.to_unix(DateTime.utc_now()),
        "exp" => DateTime.to_unix(Keyword.fetch!(opts, :expires_at)),
        "context" => %{"user" => user_claims(opts)}
      }

      case Joken.encode_and_sign(claims, signer) do
        {:ok, token, _claims} -> {:ok, token}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp user_claims(opts) do
    %{"moderator" => Keyword.get(opts, :moderator, false)}
    |> maybe_put("name", Keyword.get(opts, :name))
    |> maybe_put("email", Keyword.get(opts, :email))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp fetch_present(opts, key, error) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _absent -> {:error, error}
    end
  end

  defp fetch_room(opts) do
    with {:ok, room} <- fetch_present(opts, :room, :invalid_room) do
      if room == "*", do: {:error, :invalid_room}, else: {:ok, room}
    end
  end
end
