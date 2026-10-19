defmodule Tymeslot.Emails.Shared.IntegrationLabels do
  @moduledoc """
  What the integration emails call a provider and an integration, and where
  they send the owner to manage it.

  Every integration email names the provider the way the dashboard row does,
  from the provider registries: `Google Calendar`, `Nextcloud Talk`,
  `Calendar subscription`, never a humanised identifier such as
  `Google calendar` or `Nextcloud talk`. Only a provider the registries do
  not know falls back to its humanised identifier. Brand names stay as they
  are in every language; the words around them are translated into the
  current locale.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Integrations.Calendar.ProviderConfig, as: CalendarProviderConfig
  alias Tymeslot.Integrations.Video.ProviderConfig, as: VideoProviderConfig
  alias Tymeslot.Utils.UrlBuilder

  @type integration :: %{
          required(:provider) => atom() | String.t(),
          optional(atom()) => term()
        }

  @typedoc "An integration kind; anything else gets the generic fallbacks."
  @type kind :: :calendar | :video | atom() | String.t()

  @doc """
  The provider's name as the owner knows it: the registry's display name
  (`Zoom`, `Google Calendar`, `Calendar subscription` in the current locale),
  or the humanised identifier for a provider the registry does not know.
  """
  @spec provider_name(integration(), kind()) :: String.t()
  def provider_name(%{provider: provider}, :calendar) do
    case CalendarProviderConfig.parse_known(provider) do
      {:ok, known} -> CalendarProviderConfig.display_name(known)
      {:error, :unknown} -> humanize(provider)
    end
  end

  def provider_name(%{provider: provider}, :video) do
    case VideoProviderConfig.parse_known(provider) do
      {:ok, known} when known != :none -> VideoProviderConfig.display_name(known)
      _unknown -> humanize(provider)
    end
  end

  def provider_name(%{provider: provider}, _kind), do: humanize(provider)

  @doc """
  The integration as a noun phrase: the provider's name with its kind
  (`Zoom video`), or the name alone when it already says what it is
  (`Google Calendar`, `Calendar subscription`, `Custom Video Link`).
  """
  @spec integration_name(integration(), kind()) :: String.t()
  def integration_name(integration, :calendar) do
    name = provider_name(integration, :calendar)

    if CalendarProviderConfig.subscription?(integration.provider) or names?(name, "calendar"),
      do: name,
      else: dgettext("emails_integrations", "%{provider} calendar", provider: name)
  end

  def integration_name(integration, :video) do
    name = provider_name(integration, :video)

    if names?(name, "video"),
      do: name,
      else: dgettext("emails_integrations", "%{provider} video", provider: name)
  end

  def integration_name(integration, kind), do: provider_name(integration, kind)

  @doc "The dashboard page the owner manages integrations of `kind` on."
  @spec settings_url(kind()) :: String.t()
  def settings_url(:calendar), do: UrlBuilder.build_url("/dashboard/integrations?tab=calendars")
  def settings_url(:video), do: UrlBuilder.build_url("/dashboard/integrations?tab=video")
  def settings_url(_kind), do: UrlBuilder.build_url("/dashboard/integrations")

  # Brand names are English in every locale, so the check reads the English
  # word.
  defp names?(name, word), do: name |> String.downcase() |> String.contains?(word)

  defp humanize(provider),
    do: provider |> to_string() |> String.replace("_", " ") |> String.capitalize()
end
