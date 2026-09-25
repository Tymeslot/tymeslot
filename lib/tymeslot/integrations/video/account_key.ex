defmodule Tymeslot.Integrations.Video.AccountKey do
  @moduledoc """
  The key that tells one connected video account from another
  (`provider_account_id`), and whether a key is still free for a user.

  MiroTalk, Jitsi and the custom video link are keyed on an address the
  organiser types, so the same server or link can arrive written several ways.
  `from_url/1` reduces an address to one form by normalising only what does
  not change where it leads: the scheme and host are lower-cased, a default
  port is dropped and a trailing `/` is removed from the path. The path keeps
  its case and the query string stays, since personal meeting links often
  differ only in a `?pwd=` parameter.

  Rows saved before keys were normalised may still hold the address as typed,
  so the check for a URL-keyed provider compares the normalised form of every
  stored key rather than the stored strings.
  """

  alias Ecto.Changeset
  alias Tymeslot.Integrations.Common.OAuth.AccountMatch
  alias Tymeslot.Integrations.Video.VideoIntegrationQueries

  @url_fields %{"mirotalk" => :base_url, "jitsi" => :base_url, "custom" => :custom_meeting_url}

  @doc """
  The field holding the address a provider's integrations are keyed on, or
  `nil` for a provider keyed some other way.
  """
  @spec url_field(String.t() | atom()) :: :base_url | :custom_meeting_url | nil
  def url_field(provider), do: Map.get(@url_fields, to_string(provider))

  @doc """
  The account key for an address, or `nil` for a blank or missing one.

  An address without a scheme and host is only trimmed of surrounding spaces
  and a trailing `/`, so it still yields a key for the changeset to refuse the
  address itself.
  """
  @spec from_url(term()) :: String.t() | nil
  def from_url(url) when is_binary(url) do
    case String.trim(url) do
      "" -> nil
      trimmed -> trimmed |> URI.parse() |> normalise(trimmed)
    end
  end

  def from_url(_url), do: nil

  # `URI.parse/1` already lower-cases the scheme, and `URI.to_string/1` leaves
  # out a port that is the scheme's default.
  defp normalise(%URI{scheme: scheme, host: host} = uri, _trimmed)
       when is_binary(scheme) and is_binary(host) and host != "" do
    URI.to_string(%URI{uri | host: String.downcase(host), path: trim_path(uri.path)})
  end

  defp normalise(_not_an_address, trimmed), do: String.trim_trailing(trimmed, "/")

  defp trim_path(nil), do: nil

  defp trim_path(path) do
    case String.trim_trailing(path, "/") do
      "" -> nil
      trimmed -> trimmed
    end
  end

  @doc """
  Whether `key` is free for another of the user's integrations of `provider`,
  active or not, leaving out the integration `except_id` (the one being
  edited, or `nil` for a new one).
  """
  @spec check_free(pos_integer(), String.t(), String.t() | nil, pos_integer() | nil) ::
          :ok | {:error, :duplicate_integration}
  def check_free(_user_id, _provider, key, _except_id) when key in [nil, ""], do: :ok

  def check_free(user_id, provider, key, except_id) do
    provider = to_string(provider)

    taken? =
      user_id
      |> VideoIntegrationQueries.list_account_keys_for_user(provider, except_id)
      |> Enum.any?(&(comparable(provider, &1) == comparable(provider, key)))

    if taken?, do: {:error, :duplicate_integration}, else: :ok
  end

  defp comparable(provider, key) do
    if url_field(provider), do: from_url(key), else: key
  end

  @doc """
  Turns a save the account-key index refused, because another active
  integration took the key in the meantime, into the same refusal the check
  gives. Any other result is returned unchanged.
  """
  @spec refuse_taken_key({:ok, term()} | {:error, term()}) ::
          {:ok, term()} | {:error, term()}
  def refuse_taken_key({:error, %Changeset{} = changeset} = error) do
    if AccountMatch.unique_account_violation?(changeset),
      do: {:error, :duplicate_integration},
      else: error
  end

  def refuse_taken_key(result), do: result
end
