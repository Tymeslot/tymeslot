defmodule TymeslotWeb.Components.Dashboard.Integrations.Calendar.CaldavFamilyConfig do
  @moduledoc """
  The connect form for every CalDAV-family calendar provider: generic CalDAV,
  Nextcloud, Radicale, Baikal, Zimbra, mailbox.org and Apple iCloud.

  They share one form (`SharedFormComponents.config_form/1`) and differ only
  in data, held in `@providers`: the name and tagline, the setup guide, the
  suggested integration name and placeholders, and which password hint, if
  any, sits above the form. Whether the server address is fixed (mailbox.org
  and iCloud each run on one host) comes from
  `ProviderConfig.locked_url_for/1`. Pass the provider as `provider`.

  Exchange and calendar subscriptions have forms of their own
  (`ExchangeConfig`, `IcsUrlConfig`): Exchange takes a different credential
  flow and a subscription has no credentials at all.

  A function component: the form's events all go to `target`, the calendar
  settings component that owns the connection state.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Integrations.Calendar.ProviderConfig

  alias TymeslotWeb.Components.Dashboard.Integrations.Calendar.SharedFormComponents,
    as: SharedForm

  alias TymeslotWeb.Components.Dashboard.Integrations.Shared.UIComponents

  @domain "dashboard_calendar_providers"

  # Copy is held as msgids and translated at render time, in the viewer's
  # locale. A provider on a fixed host has no `url_placeholder`.
  @providers %{
    caldav: %{
      dom_id: "caldav",
      title: "CalDAV",
      tagline:
        dgettext_noop("dashboard_calendar_providers", "Connect any CalDAV-compatible server"),
      guide_slug: "caldav",
      suggested_name: dgettext_noop("dashboard_calendar_providers", "My CalDAV"),
      name_placeholder: dgettext_noop("dashboard_calendar_providers", "My CalDAV Calendar"),
      url_placeholder: dgettext_noop("dashboard_calendar_providers", "https://caldav.example.com")
    },
    nextcloud: %{
      dom_id: "nextcloud",
      title: "Nextcloud",
      tagline:
        dgettext_noop("dashboard_calendar_providers", "Sync calendars from your Nextcloud server"),
      guide_slug: "caldav-nextcloud",
      suggested_name: dgettext_noop("dashboard_calendar_providers", "My Nextcloud"),
      name_placeholder: dgettext_noop("dashboard_calendar_providers", "My Nextcloud Calendar"),
      url_placeholder: dgettext_noop("dashboard_calendar_providers", "https://cloud.example.com")
    },
    radicale: %{
      dom_id: "radicale",
      title: "Radicale",
      tagline:
        dgettext_noop("dashboard_calendar_providers", "Lightweight CalDAV server integration"),
      guide_slug: "caldav-radicale",
      suggested_name: dgettext_noop("dashboard_calendar_providers", "My Radicale"),
      name_placeholder: dgettext_noop("dashboard_calendar_providers", "My Radicale Calendar"),
      url_placeholder:
        dgettext_noop("dashboard_calendar_providers", "https://radicale.example.com:5232")
    },
    baikal: %{
      dom_id: "baikal",
      title: "Baikal",
      tagline: dgettext_noop("dashboard_calendar_providers", "PHP-based CalDAV/CardDAV server"),
      guide_slug: "caldav-baikal",
      suggested_name: dgettext_noop("dashboard_calendar_providers", "My Baikal"),
      name_placeholder: dgettext_noop("dashboard_calendar_providers", "My Baikal Calendar"),
      url_placeholder:
        dgettext_noop("dashboard_calendar_providers", "https://baikal.example.com/dav.php")
    },
    zimbra: %{
      dom_id: "zimbra",
      title: "Zimbra",
      tagline:
        dgettext_noop("dashboard_calendar_providers", "Sync calendars from your Zimbra server"),
      guide_slug: "caldav-zimbra",
      suggested_name: dgettext_noop("dashboard_calendar_providers", "My Zimbra"),
      name_placeholder: dgettext_noop("dashboard_calendar_providers", "My Zimbra Calendar"),
      url_placeholder: dgettext_noop("dashboard_calendar_providers", "https://mail.example.com")
    },
    mailbox_org: %{
      dom_id: "mailbox-org",
      title: "mailbox.org",
      tagline:
        dgettext_noop(
          "dashboard_calendar_providers",
          "Sync calendars from your mailbox.org account"
        ),
      guide_slug: "caldav-mailbox-org",
      suggested_name: dgettext_noop("dashboard_calendar_providers", "My mailbox.org"),
      name_placeholder: dgettext_noop("dashboard_calendar_providers", "My mailbox.org Calendar")
    },
    apple: %{
      dom_id: "apple",
      title: "Apple iCloud",
      tagline:
        dgettext_noop(
          "dashboard_calendar_providers",
          "Sync calendars from your Apple iCloud account"
        ),
      guide_slug: "caldav-apple",
      suggested_name: dgettext_noop("dashboard_calendar_providers", "My Apple iCloud"),
      name_placeholder: dgettext_noop("dashboard_calendar_providers", "My Apple iCloud Calendar")
    }
  }

  @doc "The providers this form connects."
  @spec providers() :: [atom()]
  def providers, do: Map.keys(@providers)

  attr :provider, :atom, required: true
  attr :target, :any, required: true
  attr :form_errors, :map, required: true
  attr :form_values, :map, required: true
  attr :discovered_calendars, :list, required: true
  attr :show_calendar_selection, :boolean, required: true
  attr :discovery_credentials, :map, required: true
  attr :saving, :boolean, required: true

  @spec caldav_family_config(map()) :: Phoenix.LiveView.Rendered.t()
  def caldav_family_config(assigns) do
    config = Map.fetch!(@providers, assigns.provider)
    locked_url = ProviderConfig.locked_url_for(assigns.provider)

    assigns =
      assign(assigns,
        config: config,
        locked_url: locked_url,
        url_placeholder: locked_url == nil && Map.get(config, :url_placeholder),
        # The id the form carried as a LiveComponent ("<x>-config" mounted as
        # "<x>-config"), kept so nothing keyed on it moves.
        dom_id: "#{config.dom_id}-config-#{config.dom_id}-config"
      )

    ~H"""
    <div id={@dom_id} class="space-y-6">
      <UIComponents.provider_config_header
        provider={Atom.to_string(@provider)}
        type="calendar"
        title={@config.title}
        tagline={t(@config.tagline)}
        guide_slug={@config.guide_slug}
      />

      <.password_hint provider={@provider} />

      <SharedForm.config_form
        provider={Atom.to_string(@provider)}
        show_calendar_selection={@show_calendar_selection}
        discovered_calendars={@discovered_calendars}
        discovery_credentials={@discovery_credentials}
        form_errors={@form_errors}
        form_values={@form_values}
        saving={@saving}
        target={@target}
        suggested_name={t(@config.suggested_name)}
        name_placeholder={t(@config.name_placeholder)}
        url_placeholder={@url_placeholder && t(@url_placeholder)}
        url_locked={@locked_url != nil}
        url_value={(@locked_url && @locked_url.url) || ""}
        url_locked_tooltip={@locked_url && @locked_url.tooltip}
      />
    </div>
    """
  end

  defp t(msgid), do: Gettext.dgettext(TymeslotWeb.Gettext, @domain, msgid)

  # Nextcloud, mailbox.org and iCloud refuse the account password once
  # two-factor authentication is on (iCloud always), so their forms say where
  # to make an app password. The other servers take an ordinary login.
  attr :provider, :atom, required: true

  defp password_hint(%{provider: :nextcloud} = assigns) do
    ~H"""
    <SharedForm.nextcloud_app_password_hint />
    """
  end

  defp password_hint(%{provider: :mailbox_org} = assigns) do
    ~H"""
    <p class="text-sm text-tymeslot-600 leading-relaxed">
      {raw(
        dgettext(
          "dashboard_calendar_providers",
          "If you have two-factor authentication enabled, generate an application-specific password under %{location} on mailbox.org and use that here instead of your regular password.",
          location:
            ~s(<span class="font-semibold">) <>
              dgettext("dashboard_calendar_providers", "Settings → Security") <> ~s(</span>)
        )
      )}
    </p>
    """
  end

  defp password_hint(%{provider: :apple} = assigns) do
    ~H"""
    <p class="text-sm text-tymeslot-600 leading-relaxed">
      {raw(
        dgettext(
          "dashboard_calendar_providers",
          "iCloud will not accept your Apple ID password here. Generate an %{app_specific_password} at %{link} under %{location}, then enter it below with your Apple ID email.",
          app_specific_password:
            ~s(<span class="font-semibold">) <>
              dgettext("dashboard_calendar_providers", "app-specific password") <> ~s(</span>),
          link:
            ~s(<a href="https://appleid.apple.com" target="_blank" rel="noopener noreferrer" class="font-semibold text-turquoise-600 hover:text-turquoise-700 underline">appleid.apple.com</a>),
          location:
            ~s(<span class="font-semibold">) <>
              dgettext(
                "dashboard_calendar_providers",
                "Sign-In and Security → App-Specific Passwords"
              ) <> ~s(</span>)
        )
      )}
    </p>
    """
  end

  defp password_hint(assigns), do: ~H""
end
