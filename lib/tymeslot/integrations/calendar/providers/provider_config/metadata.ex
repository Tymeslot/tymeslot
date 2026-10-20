defmodule Tymeslot.Integrations.Calendar.ProviderConfig.Metadata do
  @moduledoc """
  How each calendar provider is presented: its icon, description, button
  text and the event its button sends, as `Providers.Directory` builds a
  provider's descriptor from them.

  Split out of `Tymeslot.Integrations.Calendar.ProviderConfig`, which keeps
  the facts the domain acts on (families, URLs, circuit breakers) and
  delegates these to it. The descriptions are untranslated msgids,
  translated when read.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  @metadata %{
    caldav: %{
      icon: "caldav",
      description: dgettext_noop("integrations_calendar", "Universal CalDAV server support"),
      button_text: "Connect CalDAV",
      click_event: "connect_provider"
    },
    radicale: %{
      icon: "radicale",
      description:
        dgettext_noop("integrations_calendar", "Lightweight self-hosted calendar server"),
      button_text: "Connect Radicale",
      click_event: "connect_provider"
    },
    nextcloud: %{
      icon: "nextcloud",
      description: dgettext_noop("integrations_calendar", "Self-hosted Nextcloud calendar sync"),
      button_text: "Connect Nextcloud",
      click_event: "connect_provider"
    },
    zimbra: %{
      icon: "zimbra",
      description:
        dgettext_noop("integrations_calendar", "Enterprise Zimbra calendar integration"),
      button_text: "Connect Zimbra",
      click_event: "connect_provider"
    },
    mailbox_org: %{
      icon: "mailbox_org",
      description:
        dgettext_noop(
          "integrations_calendar",
          "Sync calendars from your mailbox.org account"
        ),
      button_text: "Connect mailbox.org",
      click_event: "connect_provider"
    },
    apple: %{
      icon: "apple",
      description:
        dgettext_noop(
          "integrations_calendar",
          "Sync calendars from your Apple iCloud account"
        ),
      button_text: "Connect Apple iCloud",
      click_event: "connect_provider"
    },
    baikal: %{
      icon: "baikal",
      description:
        dgettext_noop(
          "integrations_calendar",
          "PHP-based CalDAV/CardDAV server integration"
        ),
      button_text: "Connect Baikal",
      click_event: "connect_provider"
    },
    ics_url: %{
      icon: "ics_url",
      description:
        dgettext_noop(
          "integrations_calendar",
          "Subscribe to a published calendar feed, read-only"
        ),
      button_text: "Subscribe to a feed",
      click_event: "connect_provider"
    },
    google: %{
      icon: "google",
      description:
        dgettext_noop(
          "integrations_calendar",
          "Full OAuth integration with Google Meet support"
        ),
      button_text: "Connect Google",
      click_event: "connect_provider"
    },
    outlook: %{
      icon: "outlook",
      description:
        dgettext_noop("integrations_calendar", "Microsoft 365 and Outlook.com integration"),
      button_text: "Connect Outlook",
      click_event: "connect_provider"
    },
    exchange: %{
      icon: "exchange",
      description:
        dgettext_noop(
          "integrations_calendar",
          "On-premises Microsoft Exchange Server, two-way sync"
        ),
      button_text: "Connect Exchange",
      click_event: "connect_provider"
    },
    demo: %{
      icon: "demo",
      description: dgettext_noop("integrations_calendar", "Homepage demo provider"),
      button_text: "Demo Enabled",
      click_event: nil
    }
  }

  @typedoc "How one provider is presented."
  @type t :: %{
          icon: String.t(),
          description: String.t(),
          button_text: String.t(),
          click_event: String.t() | nil
        }

  @doc "How `provider` is presented; a generic entry for one not listed."
  @spec metadata(atom()) :: t()
  def metadata(provider) when is_atom(provider) do
    Map.get(@metadata, provider, %{
      icon: Atom.to_string(provider),
      description: "",
      button_text: "Connect",
      click_event: nil
    })
  end

  @doc "The provider's icon identifier."
  @spec icon(atom()) :: String.t()
  def icon(provider), do: metadata(provider).icon

  @doc "The provider's description, translated."
  @spec description(atom()) :: String.t()
  def description(provider),
    do:
      Gettext.dgettext(
        TymeslotWeb.Gettext,
        "integrations_calendar",
        metadata(provider).description
      )

  @doc "The provider's button text."
  @spec button_text(atom()) :: String.t()
  def button_text(provider), do: metadata(provider).button_text

  @doc "The event the provider's button sends."
  @spec click_event(atom()) :: String.t() | nil
  def click_event(provider), do: metadata(provider).click_event
end
