defmodule Tymeslot.Integrations.Calendar.CalDAV.FamilyProvider.Callbacks do
  @moduledoc """
  The shared bodies of the callbacks `CalDAV.FamilyProvider` generates that
  differ by member: each takes the member and reads what tells it apart
  from its row in `CalDAV.Family`.
  """

  alias Tymeslot.Integrations.Calendar.CalDAV.Family
  alias Tymeslot.Integrations.Calendar.Providers.CaldavCommon
  alias Tymeslot.Integrations.Calendar.Shared.ProviderCommon
  alias Tymeslot.Integrations.Shared.ProviderConfigHelper

  @doc """
  A member's configuration schema, with the descriptions it was given. A
  member with a fixed server address offers it as the default.
  """
  @spec config_schema(Family.member(), keyword(String.t())) :: map()
  def config_schema(member, descriptions) do
    base_url =
      case Family.row!(member).fixed_url do
        nil -> %{}
        %{url: url} -> %{default: url}
      end

    %{
      base_url: Map.merge(string_field(descriptions[:base_url]), base_url),
      username: string_field(descriptions[:username]),
      password: string_field(descriptions[:password]),
      calendar_paths: %{
        type: :list,
        required: false,
        description: descriptions[:calendar_paths]
      },
      connection_timeout: timeout_field(10_000, "Connection timeout", "10 seconds"),
      request_timeout: timeout_field(30_000, "Request timeout", "30 seconds"),
      discovery_timeout: timeout_field(15_000, "Calendar discovery timeout", "15 seconds")
    }
  end

  defp string_field(description), do: %{type: :string, required: true, description: description}

  defp timeout_field(default, what, spoken) do
    %{
      type: :integer,
      required: false,
      default: default,
      description: "#{what} in milliseconds (default: #{spoken})"
    }
  end

  @doc """
  Validates a submitted configuration: the credentials are present and the
  server address passes `ProviderCommon.validate_caldav_url/3`.

  Structural validation only, in line with every other provider's
  `validate_config/1`: the caller that needs connectivity
  (`Calendar.Creation.prevalidate_config/1`) invokes `validate_config/1` first
  and then `perform_connection_test/1`. Folding a connectivity probe into this
  callback would double-charge a rate-limited connection test that runs both
  in sequence.
  """
  @spec validate_config(Family.member(), map(), String.t()) :: :ok | {:error, String.t()}
  def validate_config(member, config, invalid_url_message) do
    with :ok <-
           ProviderConfigHelper.validate_required_fields(config, [:base_url, :username, :password]) do
      ProviderCommon.validate_caldav_url(member, config[:base_url], invalid_url_message)
    end
  end

  @doc """
  Builds a member's client from a stored or submitted configuration.

  The client is built from the stored address, never repointed at a fixed
  one: a row saved before its member's address was fixed keeps syncing until
  it is reconnected. The fixed address only fills in a missing one.
  """
  @spec new(Family.member(), map()) :: CaldavCommon.caldav_client()
  def new(member, config) do
    fixed_url = Family.row!(member).fixed_url
    base_url = config[:base_url] || (fixed_url && fixed_url.url)

    calendar_paths =
      case config[:calendar_paths] do
        paths when is_list(paths) -> paths
        _other -> []
      end

    CaldavCommon.build_provider_client(
      config,
      member,
      base_url |> String.trim() |> String.trim_trailing("/"),
      calendar_paths
    )
  end
end
