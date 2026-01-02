defmodule TymeslotWeb.Helpers.IntegrationProviders do
  @moduledoc """
  Centralized provider information and formatting for calendar and video integrations.
  Now backed by the unified ProviderDirectory so disabled providers are hidden automatically.
  """

  alias Tymeslot.Integrations.Providers.Directory, as: ProviderDirectory

  @calendar_icons %{
    caldav: :calendar,
    radicale: :server,
    nextcloud: :nextcloud,
    google: :google,
    outlook: :outlook,
    demo: :calendar,
    debug: :server
  }

  @video_icons %{
    mirotalk: :video,
    google_meet: :google_meet,
    teams: :teams,
    custom: :link
  }

  @doc """
  Format provider name for display using ProviderDirectory metadata.
  Accepts provider as string (e.g., "google") or atom.
  """
  @spec format_provider_name(:calendar | :video, atom | String.t()) :: String.t()
  def format_provider_name(type, provider) when type in [:calendar, :video] do
    case resolve_descriptor(type, provider) do
      {:ok, desc} ->
        desc.display_name

      :error ->
        provider
        |> to_string()
        |> String.replace("_", " ")
        |> String.capitalize()
    end
  end

  @doc """
  Get provider icon (local mapping).
  """
  @spec get_provider_icon(:calendar, atom | String.t()) :: atom | nil
  def get_provider_icon(:calendar, provider) do
    type = resolve_type(:calendar, provider)
    Map.get(@calendar_icons, type)
  end

  @spec get_provider_icon(:video, atom | String.t()) :: atom | nil
  def get_provider_icon(:video, provider) do
    type = resolve_type(:video, provider)
    Map.get(@video_icons, type)
  end

  @doc """
  Check if provider requires OAuth using ProviderDirectory metadata.
  """
  @spec oauth_provider?(:calendar | :video, atom | String.t()) :: boolean
  def oauth_provider?(type, provider) when type in [:calendar, :video] do
    case resolve_type(type, provider) do
      nil -> false
      atom_type -> ProviderDirectory.oauth?(type, atom_type) == true
    end
  end

  @doc """
  Get all enabled providers for a type as a map keyed by string provider names.
  This is retained for backwards compatibility with code expecting a map.
  """
  @spec get_providers(:calendar | :video) :: %{
          optional(String.t()) => %{name: String.t(), icon: atom | nil, oauth: boolean}
        }
  def get_providers(type) when type in [:calendar, :video] do
    ProviderDirectory.list(type)
    |> Enum.map(fn d ->
      {Atom.to_string(d.type),
       %{name: d.display_name, icon: get_provider_icon(type, d.type), oauth: d.oauth}}
    end)
    |> Map.new()
  end

  @doc """
  Format token expiry for display.
  """
  @spec format_token_expiry(nil | DateTime.t()) :: String.t()
  def format_token_expiry(nil), do: "Unknown"

  @spec format_token_expiry(DateTime.t()) :: String.t()
  def format_token_expiry(expires_at) do
    case DateTime.compare(expires_at, DateTime.utc_now()) do
      :gt -> "in #{relative_time(expires_at)}"
      _ -> "expired"
    end
  end

  # --- internal helpers ---

  defp resolve_descriptor(type, provider) do
    case resolve_type(type, provider) do
      nil ->
        :error

      atom_type ->
        case ProviderDirectory.get(type, atom_type) do
          %{} = desc -> {:ok, desc}
          _ -> :error
        end
    end
  end

  @spec resolve_type(:calendar | :video, atom | String.t() | any) :: atom | nil
  defp resolve_type(_type, provider) when is_atom(provider) do
    provider
  end

  defp resolve_type(type, provider) when is_binary(provider) do
    Enum.find_value(ProviderDirectory.list(type), fn d ->
      if Atom.to_string(d.type) == provider, do: d.type, else: nil
    end)
  end

  defp resolve_type(_type, _provider), do: nil

  @spec relative_time(DateTime.t()) :: String.t()
  defp relative_time(datetime) do
    diff = DateTime.diff(datetime, DateTime.utc_now(), :second)

    cond do
      diff > 86_400 -> "#{div(diff, 86_400)} day(s)"
      diff > 3600 -> "#{div(diff, 3600)} hour(s)"
      diff > 60 -> "#{div(diff, 60)} minute(s)"
      true -> "#{diff} second(s)"
    end
  end
end
